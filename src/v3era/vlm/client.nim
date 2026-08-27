## Shared plumbing for vision-language model backends.
##
## Holds the request/response value types, the retry policy and the HTTP
## transport indirection. The transport is a function value rather than a
## hardcoded `httpclient` call so the request-building and response-parsing
## logic can be tested against recorded payloads without a network or an API
## key -- which is most of what there is to get wrong in an API client.

import std/[httpclient, json, strutils, os, math, random, times, base64]

import ../core/[errors, log]

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

type
  HttpHeaders* = seq[(string, string)]

  HttpResponse* = object
    status*: int
    body*: string
    headers*: HttpHeaders

  Transport* = proc (url: string; headers: HttpHeaders; body: string;
                     timeoutMs: int): HttpResponse {.gcsafe.}
    ## A transport should report failures as `status: 0` rather than raising,
    ## so the retry loop can treat a dropped connection the same as a 503.
    ## (`raises: []` is not declared: `httpclient`'s SSL context initialiser is
    ## itself declared as raising bare `Exception`, and the only way to satisfy
    ## the stricter effect would be to swallow `Defect`s too.)

proc header*(r: HttpResponse; name: string): string =
  let want = name.toLowerAscii()
  for (k, v) in r.headers:
    if k.toLowerAscii() == want: return v
  ""

proc httpPost(url: string; headers: HttpHeaders; body: string;
              timeoutMs: int): HttpResponse {.gcsafe.} =
  ## The production transport. Network and TLS failures are reported as status
  ## 0 rather than raised, so the retry loop treats them uniformly with 5xx.
  try:
    var hdrs = newHttpHeaders()
    for (k, v) in headers:
      hdrs[k] = v
    let client = newHttpClient(timeout = timeoutMs, headers = hdrs)
    defer: client.close()
    let resp = client.request(url, httpMethod = HttpPost, body = body)
    result.status = resp.code.int
    result.body = resp.body
    for k, v in resp.headers.pairs:
      result.headers.add (k, v)
  except CatchableError as e:
    result.status = 0
    result.body = e.msg

let realTransport*: Transport = httpPost
  ## Bound as a value so it satisfies the closure-typed `Transport`, which is
  ## what lets tests substitute a capturing stub.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

type
  VlmProvider* = enum
    vpAnthropic = "anthropic"
    vpOpenAiCompatible = "openai"
      ## Any server speaking the OpenAI chat-completions shape: vLLM, Ollama,
      ## llama.cpp, LM Studio, or a hosted gateway.

  ThinkingMode* = enum
    tmAdaptive = "adaptive" ## Model decides when and how deeply to reason.
    tmOff = "off"

  Effort* = enum
    efLow = "low"
    efMedium = "medium"
    efHigh = "high"
    efXhigh = "xhigh"
    efMax = "max"

  VlmConfig* = object
    provider*: VlmProvider
    model*: string
    baseUrl*: string
    apiKey*: string
    maxTokens*: int
    thinking*: ThinkingMode
    effort*: Effort
    timeoutMs*: int
    maxRetries*: int
    cacheSystemPrompt*: bool
      ## Adds `cache_control` to the system prompt. Worth it whenever the same
      ## instructions are reused across pages or documents, which is the norm
      ## for batch extraction.
    serverSideFallback*: bool
      ## Lets the API re-run a safety-declined request on a fallback model
      ## inside the same call, instead of returning an empty answer.
    maxImageSide*: int
      ## Images are downscaled to this before encoding. Past roughly 1568 px
      ## the model downsamples anyway, so anything larger is pure token cost.

  VlmImage* = object
    data*: string       ## Raw encoded bytes (PNG/JPEG/...), not base64.
    mediaType*: string

  VlmDocument* = object
    data*: string       ## Raw PDF bytes.
    fileName*: string

  VlmRequest* = object
    system*: string
    prompt*: string
    images*: seq[VlmImage]
    documents*: seq[VlmDocument]
    jsonSchema*: JsonNode ## Non-nil requests a structured response.
    schemaName*: string

const
  defaultAnthropicModel* = "claude-opus-5"
  defaultAnthropicBase* = "https://api.anthropic.com"
  anthropicVersion* = "2023-06-01"
  fallbackBeta* = "server-side-fallback-2026-07-01"

func defaultVlmConfig*(): VlmConfig =
  VlmConfig(
    provider: vpAnthropic,
    model: defaultAnthropicModel,
    baseUrl: defaultAnthropicBase,
    maxTokens: 16_000,
    thinking: tmAdaptive,
    effort: efHigh,
    timeoutMs: 300_000,
    maxRetries: 4,
    cacheSystemPrompt: true,
    serverSideFallback: true,
    maxImageSide: 1568)

proc configFromEnv*(): VlmConfig =
  ## Reads configuration from the environment, so a deployment can switch
  ## provider or model without a rebuild.
  ##
  ## `V3ERA_VLM_PROVIDER`, `V3ERA_VLM_MODEL`, `V3ERA_VLM_BASE_URL`,
  ## `V3ERA_VLM_MAX_TOKENS`, `V3ERA_VLM_TIMEOUT_MS`, `ANTHROPIC_API_KEY`
  ## (or `V3ERA_VLM_API_KEY`).
  result = defaultVlmConfig()
  let provider = getEnv("V3ERA_VLM_PROVIDER", "").toLowerAscii()
  if provider == "openai" or provider == "openai-compatible":
    result.provider = vpOpenAiCompatible
    result.baseUrl = getEnv("V3ERA_VLM_BASE_URL", "http://localhost:8000")
    result.model = getEnv("V3ERA_VLM_MODEL", "")
    # Local servers usually have no thinking or effort controls.
    result.thinking = tmOff
    result.serverSideFallback = false
    result.apiKey = getEnv("V3ERA_VLM_API_KEY", getEnv("OPENAI_API_KEY", ""))
  else:
    result.baseUrl = getEnv("V3ERA_VLM_BASE_URL", defaultAnthropicBase)
    result.model = getEnv("V3ERA_VLM_MODEL", defaultAnthropicModel)
    result.apiKey = getEnv("V3ERA_VLM_API_KEY", getEnv("ANTHROPIC_API_KEY", ""))

  let mt = getEnv("V3ERA_VLM_MAX_TOKENS", "")
  if mt.len > 0:
    try: result.maxTokens = parseInt(mt)
    except ValueError:
      log.warn("ignoring non-numeric V3ERA_VLM_MAX_TOKENS", {"value": mt})
  let to = getEnv("V3ERA_VLM_TIMEOUT_MS", "")
  if to.len > 0:
    try: result.timeoutMs = parseInt(to)
    except ValueError:
      log.warn("ignoring non-numeric V3ERA_VLM_TIMEOUT_MS", {"value": to})

proc validate*(cfg: VlmConfig) =
  ## Raises `ConfigError` for a configuration that cannot possibly work, so the
  ## failure names the missing setting instead of surfacing as a 401.
  if cfg.model.len == 0:
    raiseConfig("no VLM model configured (set V3ERA_VLM_MODEL)")
  if cfg.baseUrl.len == 0:
    raiseConfig("no VLM base URL configured")
  if cfg.provider == vpAnthropic and cfg.apiKey.len == 0:
    raiseConfig("no API key: set ANTHROPIC_API_KEY (or V3ERA_VLM_API_KEY)")
  if cfg.maxTokens <= 0:
    raiseConfig("maxTokens must be positive")

func vlmConfigured*(cfg: VlmConfig): bool =
  ## Whether a VLM call could be made. Used to skip the stage quietly rather
  ## than failing an analysis that did not ask for one.
  cfg.model.len > 0 and cfg.baseUrl.len > 0 and
    (cfg.provider != vpAnthropic or cfg.apiKey.len > 0)

# ---------------------------------------------------------------------------
# Retry policy
# ---------------------------------------------------------------------------

func isRetryable*(status: int): bool =
  ## 0 is a transport failure, 408/409/429 and 5xx are the API's own retryable
  ## set. Everything else is a client error that a retry would only repeat.
  status == 0 or status == 408 or status == 409 or status == 429 or
    status >= 500

proc backoffMs*(attempt: int; retryAfter: string; rng: var Rand): int =
  ## Exponential backoff with full jitter, capped at 30 s. An explicit
  ## `retry-after` from the server always wins -- it knows when the limit
  ## actually resets, and ignoring it just burns the next attempt too.
  if retryAfter.len > 0:
    try:
      let secs = parseFloat(retryAfter.strip())
      if secs >= 0.0:
        return int(min(secs * 1000.0, 60_000.0))
    except ValueError: discard
  let base = min(1000.0 * pow(2.0, attempt.float), 30_000.0)
  int(base * rng.rand(0.5 .. 1.0))

proc postWithRetry*(cfg: VlmConfig; url: string; headers: HttpHeaders;
                    body: string; transport: Transport): HttpResponse =
  ## POSTs with retries on transient failures. Raises `VlmError` when the
  ## budget is exhausted or the status is not retryable.
  var rng = initRand(int(epochTime() * 1e6) xor getCurrentProcessId())
  var attempt = 0
  while true:
    let started = epochTime()
    result = transport(url, headers, body, cfg.timeoutMs)
    let elapsed = (epochTime() - started) * 1000.0

    if result.status >= 200 and result.status < 300:
      log.debug("VLM request succeeded", {
        "status": $result.status,
        "attempt": $(attempt + 1),
        "ms": formatFloat(elapsed, ffDecimal, 0)})
      return

    if not isRetryable(result.status) or attempt >= cfg.maxRetries:
      let detail =
        if result.body.len > 600: result.body[0 ..< 600] & "..."
        else: result.body
      raise newVlmError(
        "VLM request failed with status " & $result.status & " after " &
        $(attempt + 1) & " attempt(s): " & detail,
        status = result.status, retryable = isRetryable(result.status))

    let wait = backoffMs(attempt, result.header("retry-after"), rng)
    log.warn("retrying VLM request", {
      "status": $result.status, "attempt": $(attempt + 1),
      "wait_ms": $wait})
    sleep(wait)
    inc attempt

# ---------------------------------------------------------------------------
# Payload helpers
# ---------------------------------------------------------------------------

proc encodeImage*(img: VlmImage): string =
  ## Base64 with no line breaks -- the API rejects wrapped payloads.
  base64.encode(img.data)

func approxImageTokens*(width, height: int): int =
  ## Anthropic's documented estimate: width x height / 750. Used to warn before
  ## a request that would be needlessly expensive, not to change behaviour.
  (width * height) div 750

proc joinUrl*(base, path: string): string =
  if base.endsWith('/'): base[0 ..< base.high] & path
  else: base & path
