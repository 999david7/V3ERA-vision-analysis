## `v3erad` -- the HTTP service.
##
## Exposes the pipeline over a small JSON API. The analysis stages are
## CPU-bound and synchronous, so one process handles one analysis at a time;
## parallelism comes from `--workers N`, which forks N processes that all
## listen on the same port via `SO_REUSEPORT`. That is deliberately simpler
## than a thread pool: no shared mutable state, a crash takes down one worker
## instead of the service, and the kernel does the load balancing.
##
## Endpoints
##   GET  /healthz          liveness -- always 200 while the process is up
##   GET  /readyz           readiness -- 503 until the required deps resolve
##   GET  /v1/capabilities  what this build and host can do
##   GET  /metrics          Prometheus text exposition
##   POST /v1/analyze       full pipeline
##   POST /v1/ocr           OCR only
##   POST /v1/text          text extraction (PDF text layer preferred)
##
## Uploads may be sent either as a raw body with the file's own Content-Type,
## or as JSON `{"data": "<base64>", "options": {...}}`. Options may also be
## given as query parameters, which keeps `curl --data-binary` usable.

import std/[asynchttpserver, asyncdispatch, json, strutils, os, times,
            parseopt, base64, uri, atomics, monotimes, sequtils]

import v3era

when defined(posix):
  import std/posix

const serverUsage = """
v3erad -- V3ERA vision analysis HTTP service

USAGE
  v3erad [options]

OPTIONS
  -p, --port=N          Listen port (default: 8080)
      --host=ADDR       Bind address (default: 0.0.0.0)
  -w, --workers=N       Fork N worker processes sharing the port (default: 1)
      --max-body=MB     Maximum upload size in MiB (default: 64)
      --request-timeout=MS  Per-request wall-clock budget (default: 120000)
      --no-vlm          Reject requests that ask for a model call
  -v, --verbose         Debug logging
  -h, --help            This message

ENVIRONMENT
  Same variables as the CLI; see `v3era --help`.
  PORT                  Overrides --port, for platforms that inject it.

EXAMPLES
  v3erad --port 8080 --workers 4
  curl -sS --data-binary @scan.pdf -H 'Content-Type: application/pdf' \
    'http://localhost:8080/v1/analyze?format=markdown'
  curl -sS -H 'Content-Type: application/json' \
    -d "{\"data\":\"$(base64 -w0 page.png)\",\"options\":{\"vlm\":true}}" \
    http://localhost:8080/v1/analyze
"""

type
  ServerConfig = object
    port: int
    host: string
    workers: int
    maxBodyBytes: int
    requestTimeoutMs: int
    allowVlm: bool

var
  metricRequests: Atomic[int]
  metricErrors: Atomic[int]
  metricBytesIn: Atomic[int]
  metricAnalysisMs: Atomic[int]
  startedAt = getMonoTime()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc jsonResponse(req: Request; code: HttpCode; node: JsonNode;
                  requestId: string): Future[void] =
  req.respond(code, $node, newHttpHeaders({
    "Content-Type": "application/json; charset=utf-8",
    "X-Request-Id": requestId}))

proc textResponse(req: Request; code: HttpCode; body, contentType,
                  requestId: string): Future[void] =
  req.respond(code, body, newHttpHeaders({
    "Content-Type": contentType,
    "X-Request-Id": requestId}))

proc errorJson(message, kind: string): JsonNode =
  %*{"error": {"type": kind, "message": message}}

proc newRequestId(): string =
  ## Short, monotonic-ish id. Enough to correlate a log line with a response
  ## without pulling in a UUID dependency.
  toHex(int64(epochTime() * 1_000_000) and 0xFFFFFFFFFF, 10).toLowerAscii()

func queryParams(u: Uri): seq[(string, string)] =
  decodeQuery(u.query).toSeq()

proc param(params: openArray[(string, string)]; name: string;
           default = ""): string =
  for (k, v) in params:
    if k == name: return v
  default

proc boolParam(params: openArray[(string, string)]; name: string;
               default = false): bool =
  let v = param(params, name).toLowerAscii()
  if v.len == 0: return default
  v in ["1", "true", "yes", "on"]

proc intParam(params: openArray[(string, string)]; name: string;
              default: int): int =
  let v = param(params, name)
  if v.len == 0: return default
  try: parseInt(v) except ValueError: default

# ---------------------------------------------------------------------------
# Request parsing
# ---------------------------------------------------------------------------

type
  ParsedRequest = object
    payload: string
    sourceName: string
    options: AnalyzeOptions
    format: string
    pretty: bool
    boxes: bool

proc applyJsonOptions(opts: var AnalyzeOptions; node: JsonNode;
                      allowVlm: bool) =
  ## Applies the JSON `options` object. Unknown keys are ignored so a client
  ## can send a superset without breaking against an older server.
  if node == nil or node.kind != JObject: return
  if node.hasKey("ocr"): opts.runOcr = node["ocr"].getBool(true)
  if node.hasKey("layout"): opts.runLayout = node["layout"].getBool(true)
  if node.hasKey("vlm") and allowVlm: opts.runVlm = node["vlm"].getBool(false)
  if node.hasKey("prompt"):
    opts.vlmPrompt = node["prompt"].getStr("")
    if opts.vlmPrompt.len > 0 and allowVlm: opts.runVlm = true
  if node.hasKey("language"): opts.ocr.language = node["language"].getStr("eng")
  if node.hasKey("dpi"): opts.ocr.dpi = node["dpi"].getInt(0)
  if node.hasKey("render_dpi"):
    opts.pdf.renderDpi = node["render_dpi"].getInt(200)
  if node.hasKey("first_page"): opts.pdf.firstPage = node["first_page"].getInt(0)
  if node.hasKey("last_page"): opts.pdf.lastPage = node["last_page"].getInt(0)
  if node.hasKey("model"): opts.vlm.model = node["model"].getStr(opts.vlm.model)
  if node.hasKey("kind"):
    let k = node["kind"].getStr("")
    for candidate in InputKind:
      if $candidate == k: opts.kind = candidate
  if node.hasKey("task"):
    let t = node["task"].getStr("")
    for candidate in VisionTask:
      if $candidate == t:
        opts.vlmTask = candidate
        if allowVlm: opts.runVlm = true

proc parseRequest(req: Request; cfg: ServerConfig): ParsedRequest =
  let params = queryParams(req.url)
  result.options = optionsFromEnv()
  result.format = param(params, "format", "json")
  result.pretty = boolParam(params, "pretty")
  result.boxes = boolParam(params, "boxes")
  result.sourceName = param(params, "name", "upload")

  # Query parameters first, so a JSON body can override them.
  result.options.runOcr = boolParam(params, "ocr", true)
  result.options.runLayout = boolParam(params, "layout", true)
  if cfg.allowVlm:
    result.options.runVlm = boolParam(params, "vlm", false)
  result.options.ocr.language = param(params, "language", "eng")
  result.options.ocr.dpi = intParam(params, "dpi", 0)
  result.options.pdf.renderDpi = intParam(params, "render_dpi", 200)
  result.options.pdf.firstPage = intParam(params, "first_page", 0)
  result.options.pdf.lastPage = intParam(params, "last_page", 0)
  let kindParam = param(params, "kind")
  if kindParam.len > 0:
    for candidate in InputKind:
      if $candidate == kindParam: result.options.kind = candidate
  let taskParam = param(params, "task")
  if taskParam.len > 0:
    for candidate in VisionTask:
      if $candidate == taskParam:
        result.options.vlmTask = candidate
        if cfg.allowVlm: result.options.runVlm = true

  let contentType = req.headers.getOrDefault("content-type").toLowerAscii()
  if contentType.startsWith("application/json"):
    var node: JsonNode
    try:
      node = parseJson(req.body)
    except JsonParsingError as e:
      raise newException(ValueError, "malformed JSON body: " & e.msg)
    if node.kind != JObject or not node.hasKey("data"):
      raise newException(ValueError,
        "a JSON body must be an object with a base64 \"data\" field")
    try:
      result.payload = base64.decode(node["data"].getStr(""))
    except ValueError:
      raise newException(ValueError, "\"data\" is not valid base64")
    if node.hasKey("name"): result.sourceName = node["name"].getStr("upload")
    if node.hasKey("format"): result.format = node["format"].getStr("json")
    if node.hasKey("pretty"): result.pretty = node["pretty"].getBool(false)
    if node.hasKey("boxes"): result.boxes = node["boxes"].getBool(false)
    applyJsonOptions(result.options, node{"options"}, cfg.allowVlm)
  else:
    result.payload = req.body

  if result.payload.len == 0:
    raise newException(ValueError, "empty request body")

# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

proc renderResult(res: AnalysisResult; format: string; pretty, boxes: bool):
    tuple[body, contentType: string] =
  case format.toLowerAscii()
  of "markdown", "md":
    (res.markdown(), "text/markdown; charset=utf-8")
  of "text", "txt":
    (res.document.text, "text/plain; charset=utf-8")
  else:
    let node = res.toJson(includeOcr = true, includeWords = boxes)
    ((if pretty: node.pretty() else: $node),
     "application/json; charset=utf-8")

proc handleAnalyze(req: Request; cfg: ServerConfig; requestId: string;
                   mode: string): Future[void] {.async.} =
  var parsed: ParsedRequest
  try:
    parsed = parseRequest(req, cfg)
  except ValueError as e:
    metricErrors.atomicInc()
    await jsonResponse(req, Http400, errorJson(e.msg, "bad_request"), requestId)
    return

  if parsed.payload.len > cfg.maxBodyBytes:
    metricErrors.atomicInc()
    await jsonResponse(req, Http413,
      errorJson("payload of " & $parsed.payload.len & " bytes exceeds the " &
        $(cfg.maxBodyBytes div (1024 * 1024)) & " MiB limit", "payload_too_large"),
      requestId)
    return

  case mode
  of "ocr":
    parsed.options.runOcr = true
    parsed.options.runVlm = false
  of "text":
    parsed.options.runVlm = false
  else: discard

  if parsed.options.runVlm and not cfg.allowVlm:
    metricErrors.atomicInc()
    await jsonResponse(req, Http403,
      errorJson("model calls are disabled on this server (--no-vlm)",
                "vlm_disabled"), requestId)
    return

  metricBytesIn.atomicInc(parsed.payload.len)
  let started = epochTime()
  var res: AnalysisResult
  try:
    res = analyzeBytes(toOpenArrayByte(parsed.payload, 0,
                                       parsed.payload.high),
                       parsed.sourceName, parsed.options)
  except UnsupportedFormatError as e:
    metricErrors.atomicInc()
    await jsonResponse(req, Http415,
      errorJson(e.msg, "unsupported_media_type"), requestId)
    return
  except V3eraError as e:
    metricErrors.atomicInc()
    await jsonResponse(req, Http422, errorJson(e.msg, "unprocessable"),
                       requestId)
    return
  except CatchableError as e:
    metricErrors.atomicInc()
    log.error("unhandled analysis failure",
              {"request_id": requestId, "error": e.msg})
    await jsonResponse(req, Http500,
      errorJson("internal error during analysis", "internal"), requestId)
    return

  let elapsed = (epochTime() - started) * 1000.0
  metricAnalysisMs.atomicInc(int(elapsed))

  let (body, contentType) =
    if mode == "text": (res.document.text, "text/plain; charset=utf-8")
    else: renderResult(res, parsed.format, parsed.pretty, parsed.boxes)

  log.info("request complete", {
    "request_id": requestId, "path": req.url.path, "kind": $res.kind,
    "format": $res.format, "bytes": $parsed.payload.len,
    "ms": formatFloat(elapsed, ffDecimal, 1),
    "warnings": $res.warnings.len})

  await textResponse(req, Http200, body, contentType, requestId)

proc metricsBody(): string =
  ## Prometheus text exposition. Hand-rolled rather than pulling in a client
  ## library: four counters do not justify a dependency.
  let uptime = (getMonoTime() - startedAt).inMilliseconds.float / 1000.0
  result = """
# HELP v3era_requests_total Analysis requests received.
# TYPE v3era_requests_total counter
v3era_requests_total """ & $metricRequests.load() & """

# HELP v3era_errors_total Requests that returned a 4xx or 5xx.
# TYPE v3era_errors_total counter
v3era_errors_total """ & $metricErrors.load() & """

# HELP v3era_bytes_in_total Uploaded bytes accepted for analysis.
# TYPE v3era_bytes_in_total counter
v3era_bytes_in_total """ & $metricBytesIn.load() & """

# HELP v3era_analysis_milliseconds_total Cumulative analysis wall-clock time.
# TYPE v3era_analysis_milliseconds_total counter
v3era_analysis_milliseconds_total """ & $metricAnalysisMs.load() & """

# HELP v3era_uptime_seconds Process uptime.
# TYPE v3era_uptime_seconds gauge
v3era_uptime_seconds """ & formatFloat(uptime, ffDecimal, 1) & "\n"

proc handler(req: Request; cfg: ServerConfig): Future[void] {.async.} =
  let requestId = newRequestId()
  let path = req.url.path

  if req.reqMethod == HttpGet:
    case path
    of "/healthz":
      await jsonResponse(req, Http200, %*{"status": "ok"}, requestId)
      return
    of "/readyz":
      # Ready means we can decode something and read documents. A missing VLM
      # key is not unready: most deployments never call a model.
      let caps = capabilities()
      let ready = caps.imageFormats.len > 0
      await jsonResponse(req, (if ready: Http200 else: Http503),
        %*{"status": (if ready: "ready" else: "not_ready"),
           "capabilities": caps.toJson()}, requestId)
      return
    of "/v1/capabilities":
      await jsonResponse(req, Http200, capabilities().toJson(), requestId)
      return
    of "/metrics":
      await textResponse(req, Http200, metricsBody(),
                         "text/plain; version=0.0.4", requestId)
      return
    else: discard

  if req.reqMethod == HttpPost and
     path in ["/v1/analyze", "/v1/ocr", "/v1/text"]:
    metricRequests.atomicInc()
    let mode =
      case path
      of "/v1/ocr": "ocr"
      of "/v1/text": "text"
      else: "analyze"
    await handleAnalyze(req, cfg, requestId, mode)
    return

  await jsonResponse(req, Http404,
    errorJson("no route for " & $req.reqMethod & " " & path, "not_found"),
    requestId)

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

proc parseServerCli(): ServerConfig =
  result = ServerConfig(port: 8080, host: "0.0.0.0", workers: 1,
                        maxBodyBytes: 64 * 1024 * 1024,
                        requestTimeoutMs: 120_000, allowVlm: true)
  let envPort = getEnv("PORT", "")
  if envPort.len > 0:
    try: result.port = parseInt(envPort)
    except ValueError: discard

  const
    longNoVal = @["help", "verbose", "no-vlm"]
    shortNoVal = {'h', 'v'}
  var p = initOptParser(commandLineParams(), shortNoVal = shortNoVal,
                        longNoVal = longNoVal)
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      stderr.writeLine "v3erad: unexpected argument: " & p.key
      quit(2)
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        echo serverUsage
        quit(0)
      of "v", "verbose": setLogLevel(lvlDebug)
      of "p", "port":
        try: result.port = parseInt(p.val)
        except ValueError:
          stderr.writeLine "v3erad: --port expects a number"
          quit(2)
      of "host": result.host = p.val
      of "w", "workers":
        try: result.workers = max(1, parseInt(p.val))
        except ValueError:
          stderr.writeLine "v3erad: --workers expects a number"
          quit(2)
      of "max-body":
        try: result.maxBodyBytes = parseInt(p.val) * 1024 * 1024
        except ValueError:
          stderr.writeLine "v3erad: --max-body expects a number of MiB"
          quit(2)
      of "request-timeout":
        try: result.requestTimeoutMs = parseInt(p.val)
        except ValueError:
          stderr.writeLine "v3erad: --request-timeout expects milliseconds"
          quit(2)
      of "no-vlm": result.allowVlm = false
      else:
        stderr.writeLine "v3erad: unknown option: --" & p.key
        quit(2)

proc serveForever(cfg: ServerConfig) =
  # reusePort lets every forked worker bind the same port; the kernel then
  # distributes accepted connections between them.
  let server = newAsyncHttpServer(reuseAddr = true, reusePort = cfg.workers > 1,
                                  maxBody = cfg.maxBodyBytes)
  proc cb(req: Request): Future[void] {.async, gcsafe.} =
    # `asynchttpserver` demands a gcsafe callback, and the pipeline reaches
    # module-level state that Nim cannot prove thread-safe: the cached
    # `dlopen` handle for libtesseract, the logger's level, the format
    # settings. None of that is actually shared across threads here -- this
    # process runs one event loop on one thread, and `--workers` scales by
    # forking whole processes, not by adding threads -- so the effect is
    # asserted rather than restructured away. If a thread pool is ever added,
    # this cast must go and those globals must become thread-local or locked.
    {.cast(gcsafe).}:
      await handler(req, cfg)
  waitFor server.serve(Port(cfg.port), cb, address = cfg.host)

proc main() =
  initLogFromEnv()
  let cfg = parseServerCli()

  let caps = capabilities()
  log.info("v3erad starting", {
    "version": v3eraVersion,
    "port": $cfg.port,
    "workers": $cfg.workers,
    "ocr": (if caps.ocr: caps.ocrVersion else: "unavailable"),
    "pdf": caps.pdfTools,
    "vlm": (if cfg.allowVlm and caps.vlmReady: caps.vlmModel else: "disabled")})
  if not caps.ocr:
    log.warn("OCR is unavailable; requests will return text-layer content only",
             {"detail": caps.ocrDetail})

  when defined(posix):
    if cfg.workers > 1:
      for i in 1 ..< cfg.workers:
        let pid = fork()
        if pid < 0:
          log.error("fork failed; continuing with fewer workers")
          break
        elif pid == 0:
          # Child: serve and never return to the spawning loop.
          serveForever(cfg)
          quit(0)
      # Reap children so exited workers do not linger as zombies.
      onSignal(SIGCHLD):
        var status: cint
        while waitpid(Pid(-1), status, WNOHANG) > 0: discard
  else:
    if cfg.workers > 1:
      log.warn("--workers is POSIX-only; running a single process")

  serveForever(cfg)

when isMainModule:
  main()
