## VLM client tests.
##
## Every case runs against a stub transport, so the suite exercises request
## construction, response parsing and the retry policy with no network, no API
## key and no cost. That is the part of an API client that actually breaks.

import std/[unittest, json, strutils, base64, random, options]

import ../src/v3era/core/[types, errors]
import ../src/v3era/vlm/[client, anthropic, openai, prompts]

type
  Capture = ref object
    ## Records what the client sent, and scripts what it gets back.
    urls: seq[string]
    bodies: seq[string]
    headers: seq[HttpHeaders]
    responses: seq[HttpResponse]
    calls: int

proc stub(c: Capture): Transport =
  ## A transport that records the request and replays scripted responses,
  ## repeating the last one once the script runs out.
  result = proc (url: string; headers: HttpHeaders; body: string;
                 timeoutMs: int): HttpResponse {.gcsafe.} =
    c.urls.add url
    c.bodies.add body
    c.headers.add headers
    let i = min(c.calls, c.responses.high)
    inc c.calls
    if c.responses.len == 0:
      return HttpResponse(status: 200, body: "{}")
    c.responses[i]

proc ok(body: string): HttpResponse =
  HttpResponse(status: 200, body: body)

const sampleResponse = """
{
  "id": "msg_01ABC",
  "type": "message",
  "role": "assistant",
  "model": "claude-opus-5",
  "content": [
    {"type": "thinking", "thinking": ""},
    {"type": "text", "text": "A scanned invoice from Acme Ltd."}
  ],
  "stop_reason": "end_turn",
  "usage": {
    "input_tokens": 1820,
    "output_tokens": 42,
    "cache_read_input_tokens": 1500,
    "cache_creation_input_tokens": 0
  }
}
"""

proc testConfig(): VlmConfig =
  result = defaultVlmConfig()
  result.apiKey = "sk-ant-test"
  result.maxRetries = 2

suite "anthropic request construction":
  test "images and prompt land in one user message, media first":
    let cfg = testConfig()
    let req = VlmRequest(
      system: "sys", prompt: "what is this?",
      images: @[VlmImage(data: "PNGBYTES", mediaType: "image/png")])
    let body = anthropic.buildRequestBody(cfg, req)

    check body["model"].getStr() == "claude-opus-5"
    check body["max_tokens"].getInt() == 16_000
    let content = body["messages"][0]["content"]
    check content.len == 2
    check content[0]["type"].getStr() == "image"
    check content[0]["source"]["media_type"].getStr() == "image/png"
    check content[0]["source"]["data"].getStr() == base64.encode("PNGBYTES")
    check content[1]["type"].getStr() == "text"
    check content[1]["text"].getStr() == "what is this?"

  test "base64 payloads carry no line breaks":
    let cfg = testConfig()
    # Long enough that a wrapping encoder would insert newlines.
    let big = "x".repeat(500)
    let body = anthropic.buildRequestBody(cfg, VlmRequest(
      prompt: "p", images: @[VlmImage(data: big, mediaType: "image/png")]))
    let encoded = body["messages"][0]["content"][0]["source"]["data"].getStr()
    check '\n' notin encoded
    check '\r' notin encoded

  test "a PDF becomes a document block, not an image":
    let body = anthropic.buildRequestBody(testConfig(), VlmRequest(
      prompt: "read it",
      documents: @[VlmDocument(data: "%PDF-1.4", fileName: "a.pdf")]))
    let first = body["messages"][0]["content"][0]
    check first["type"].getStr() == "document"
    check first["source"]["media_type"].getStr() == "application/pdf"

  test "the system prompt is sent as a cacheable block":
    var cfg = testConfig()
    cfg.cacheSystemPrompt = true
    let body = anthropic.buildRequestBody(cfg, VlmRequest(system: "instructions",
                                                prompt: "go"))
    check body["system"][0]["text"].getStr() == "instructions"
    check body["system"][0]["cache_control"]["type"].getStr() == "ephemeral"

  test "caching can be turned off":
    var cfg = testConfig()
    cfg.cacheSystemPrompt = false
    let body = anthropic.buildRequestBody(cfg, VlmRequest(system: "s", prompt: "g"))
    check not body["system"][0].hasKey("cache_control")

  test "adaptive thinking is sent, and budget_tokens never is":
    var cfg = testConfig()
    cfg.thinking = tmAdaptive
    let body = anthropic.buildRequestBody(cfg, VlmRequest(prompt: "p"))
    check body["thinking"]["type"].getStr() == "adaptive"
    # budget_tokens is rejected outright by this model family.
    check not body["thinking"].hasKey("budget_tokens")
    check "budget_tokens" notin $body

  test "thinking is omitted entirely when disabled":
    var cfg = testConfig()
    cfg.thinking = tmOff
    check not anthropic.buildRequestBody(cfg, VlmRequest(prompt: "p")).hasKey("thinking")

  test "effort goes inside output_config, not at the top level":
    var cfg = testConfig()
    cfg.effort = efXhigh
    let body = anthropic.buildRequestBody(cfg, VlmRequest(prompt: "p"))
    check body["output_config"]["effort"].getStr() == "xhigh"
    check not body.hasKey("effort")

  test "a schema requests structured output through output_config.format":
    let req = VlmRequest(prompt: "extract", jsonSchema: fieldExtractionSchema(),
                         schemaName: "extract_fields")
    let body = anthropic.buildRequestBody(testConfig(), req)
    let format = body["output_config"]["format"]
    check format["type"].getStr() == "json_schema"
    check format["name"].getStr() == "extract_fields"
    check format["schema"]["required"][0].getStr() == "document_type"

  test "server-side fallback sends both the parameter and its beta header":
    var cfg = testConfig()
    cfg.serverSideFallback = true
    let body = anthropic.buildRequestBody(cfg, VlmRequest(prompt: "p"))
    check body["fallbacks"].getStr() == "default"
    var found = false
    for (k, v) in anthropic.buildHeaders(cfg):
      if k == "anthropic-beta" and v == "server-side-fallback-2026-07-01":
        found = true
    check found

  test "fallback can be disabled, and then neither half is sent":
    var cfg = testConfig()
    cfg.serverSideFallback = false
    check not anthropic.buildRequestBody(cfg, VlmRequest(prompt: "p")).hasKey("fallbacks")
    for (k, _) in anthropic.buildHeaders(cfg):
      check k != "anthropic-beta"

  test "required headers are present and correct":
    let headers = anthropic.buildHeaders(testConfig())
    var seen: seq[string]
    for (k, v) in headers:
      seen.add k
      if k == "anthropic-version": check v == "2023-06-01"
      if k == "x-api-key": check v == "sk-ant-test"
    check "content-type" in seen
    check "x-api-key" in seen
    check "anthropic-version" in seen

suite "anthropic response parsing":
  test "text, usage and stop reason are extracted":
    let answer = anthropic.parseResponse(sampleResponse)
    check answer.text == "A scanned invoice from Acme Ltd."
    check answer.stopReason == "end_turn"
    check not answer.refused
    check answer.usage.inputTokens == 1820
    check answer.usage.outputTokens == 42
    check answer.usage.cacheReadTokens == 1500
    check answer.usage.totalTokens == 1862
    check answer.usage.model == "claude-opus-5"

  test "thinking blocks are not concatenated into the answer":
    check "thinking" notin anthropic.parseResponse(sampleResponse).text

  test "a refusal is surfaced, not raised":
    let body = """
    {"model":"claude-opus-5","content":[],"stop_reason":"refusal",
     "stop_details":{"type":"refusal","category":"cyber",
                     "explanation":"declined"},
     "usage":{"input_tokens":10,"output_tokens":0}}"""
    let answer = anthropic.parseResponse(body)
    check answer.refused
    check answer.stopReason == "refusal"
    check answer.text == ""

  test "a fallback response reports the model that actually served it":
    let body = """
    {"model":"claude-opus-4-8","content":[{"type":"text","text":"hi"}],
     "stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":1}}"""
    check anthropic.parseResponse(body).usage.model == "claude-opus-4-8"

  test "JSON output is parsed into the structured field":
    let body = """
    {"model":"m","stop_reason":"end_turn",
     "content":[{"type":"text","text":"{\"document_type\":\"invoice\"}"}],
     "usage":{"input_tokens":1,"output_tokens":1}}"""
    let answer = anthropic.parseResponse(body)
    check answer.structured != nil
    check answer.structured["document_type"].getStr() == "invoice"

  test "prose leaves the structured field nil":
    check anthropic.parseResponse(sampleResponse).structured == nil

  test "an API error object becomes a VlmError":
    expect VlmError:
      discard anthropic.parseResponse(
        """{"type":"error","error":{"type":"invalid_request_error",
            "message":"bad model"}}""")

  test "malformed JSON becomes a VlmError, not a crash":
    expect VlmError:
      discard anthropic.parseResponse("{not json at all")

  test "multiple text blocks are concatenated in order":
    let body = """
    {"model":"m","stop_reason":"end_turn","content":[
      {"type":"text","text":"one "},{"type":"text","text":"two"}],
     "usage":{"input_tokens":1,"output_tokens":1}}"""
    check anthropic.parseResponse(body).text == "one two"

suite "retry policy":
  test "429 and 5xx and transport failures are retryable; 4xx are not":
    check isRetryable(429)
    check isRetryable(500)
    check isRetryable(503)
    check isRetryable(0)
    check isRetryable(408)
    check not isRetryable(400)
    check not isRetryable(401)
    check not isRetryable(404)
    check not isRetryable(422)

  test "backoff grows and stays inside the cap":
    var rng = initRand(42)
    let first = backoffMs(0, "", rng)
    let later = backoffMs(5, "", rng)
    check first >= 500
    check first <= 1000
    check later <= 30_000
    check later > first

  test "an explicit retry-after wins over the computed backoff":
    var rng = initRand(1)
    check backoffMs(0, "2", rng) == 2000
    check backoffMs(7, "0.5", rng) == 500
    # A nonsense header falls back to the computed value rather than failing.
    check backoffMs(0, "soon", rng) > 0

  test "a 429 followed by a 200 succeeds after one retry":
    let c = Capture(responses: @[
      HttpResponse(status: 429, body: "rate limited",
                   headers: @[("retry-after", "0")]),
      ok(sampleResponse)])
    var cfg = testConfig()
    cfg.maxRetries = 3
    let answer = anthropic.complete(cfg, VlmRequest(prompt: "p"), stub(c))
    check c.calls == 2
    check answer.text == "A scanned invoice from Acme Ltd."

  test "the retry budget is finite and the last status is reported":
    let c = Capture(responses: @[
      HttpResponse(status: 500, body: "boom", headers: @[("retry-after", "0")])])
    var cfg = testConfig()
    cfg.maxRetries = 2
    try:
      discard anthropic.complete(cfg, VlmRequest(prompt: "p"), stub(c))
      check false
    except VlmError as e:
      check e.status == 500
      check e.retryable
      check c.calls == 3 # the initial attempt plus two retries

  test "a 400 is not retried":
    let c = Capture(responses: @[
      HttpResponse(status: 400, body: """{"error":{"message":"bad"}}""")])
    try:
      discard anthropic.complete(testConfig(), VlmRequest(prompt: "p"), stub(c))
      check false
    except VlmError as e:
      check e.status == 400
      check not e.retryable
      check c.calls == 1

suite "configuration":
  test "a missing API key is caught before any request is made":
    var cfg = defaultVlmConfig()
    cfg.apiKey = ""
    check not cfg.vlmConfigured()
    let c = Capture()
    expect ConfigError:
      discard anthropic.complete(cfg, VlmRequest(prompt: "p"), stub(c))
    check c.calls == 0

  test "an OpenAI-compatible endpoint needs no key":
    var cfg = defaultVlmConfig()
    cfg.provider = vpOpenAiCompatible
    cfg.baseUrl = "http://localhost:8000"
    cfg.model = "qwen2-vl"
    cfg.apiKey = ""
    check cfg.vlmConfigured()

  test "the request goes to /v1/messages under the configured base":
    let c = Capture(responses: @[ok(sampleResponse)])
    var cfg = testConfig()
    cfg.baseUrl = "https://example.test"
    discard anthropic.complete(cfg, VlmRequest(prompt: "p"), stub(c))
    check c.urls[0] == "https://example.test/v1/messages"

  test "a trailing slash on the base URL does not double up":
    check joinUrl("https://x.test/", "/v1/messages") ==
          "https://x.test/v1/messages"
    check joinUrl("https://x.test", "/v1/messages") ==
          "https://x.test/v1/messages"

suite "openai-compatible backend":
  test "images become data URIs in image_url blocks":
    var cfg = defaultVlmConfig()
    cfg.provider = vpOpenAiCompatible
    cfg.model = "qwen2-vl"
    let body = openai.buildRequestBody(cfg, VlmRequest(
      system: "sys", prompt: "describe",
      images: @[VlmImage(data: "RAW", mediaType: "image/png")]))
    check body["messages"][0]["role"].getStr() == "system"
    let content = body["messages"][1]["content"]
    check content[0]["type"].getStr() == "image_url"
    check content[0]["image_url"]["url"].getStr() ==
      "data:image/png;base64," & base64.encode("RAW")

  test "a PDF is rejected with an actionable message":
    var cfg = defaultVlmConfig()
    cfg.provider = vpOpenAiCompatible
    cfg.model = "m"
    try:
      discard openai.buildRequestBody(cfg, VlmRequest(
        documents: @[VlmDocument(data: "%PDF-1.4")]))
      check false
    except ConfigError as e:
      check "render" in e.msg

  test "a chat-completions response is parsed":
    let body = """
    {"model":"qwen2-vl","choices":[{"finish_reason":"stop",
      "message":{"role":"assistant","content":"a diagram"}}],
     "usage":{"prompt_tokens":100,"completion_tokens":5}}"""
    let answer = openai.parseResponse(body)
    check answer.text == "a diagram"
    check answer.stopReason == "stop"
    check answer.usage.inputTokens == 100
    check answer.usage.outputTokens == 5

  test "block-array content is also accepted":
    let body = """
    {"model":"m","choices":[{"finish_reason":"stop","message":
      {"content":[{"type":"text","text":"from blocks"}]}}]}"""
    check openai.parseResponse(body).text == "from blocks"

  test "an empty choices array is an error, not an empty answer":
    expect VlmError:
      discard openai.parseResponse("""{"model":"m","choices":[]}""")

suite "prompts":
  test "every task has an instruction except the custom one":
    for task in VisionTask:
      if task == vtCustom:
        check taskInstruction(task).len == 0
      else:
        check taskInstruction(task).len > 40

  test "each input kind maps to a sensible default task":
    check defaultTaskFor(ikScreenshot) == vtScreenshotAnalysis
    check defaultTaskFor(ikDiagram) == vtDescribeDiagram
    check defaultTaskFor(ikPdf) == vtTranscribe
    check defaultTaskFor(ikScannedDocument) == vtTranscribe

  test "OCR context is wrapped in a delimiter the model can see":
    let p = withOcrContext("Describe it.", "Total: 12.34")
    check "<ocr>" in p
    check "</ocr>" in p
    check "Total: 12.34" in p

  test "empty OCR text leaves the instruction untouched":
    check withOcrContext("Describe it.", "   ") == "Describe it."

  test "over-long OCR text is truncated visibly":
    let p = withOcrContext("go", "x".repeat(5000), maxChars = 100)
    check "truncated" in p
    check p.len < 400

  test "only the structured tasks carry a schema":
    check schemaFor(vtExtractFields) != nil
    check schemaFor(vtDescribeDiagram) != nil
    check schemaFor(vtDescribe) == nil
    check schemaFor(vtTranscribe) == nil

  test "schemas are strict objects, as structured outputs requires":
    for task in [vtExtractFields, vtDescribeDiagram]:
      let s = schemaFor(task)
      check s["type"].getStr() == "object"
      check not s["additionalProperties"].getBool()
      check s["required"].len > 0

  test "the system prompt tells the model not to invent values":
    check "Never infer" in systemPrompt
    check "OCR" in systemPrompt
