## Anthropic Messages API backend.
##
## Speaks `POST /v1/messages` directly over HTTP: Nim has no official Anthropic
## SDK, and the wire format is small and stable enough that a hand-written
## client is less risk than an unmaintained third-party wrapper.
##
## Request shape notes, because these are the parts that are easy to get wrong:
##   * Images go in as `image` content blocks ahead of the text, which is where
##     the model attends to them best.
##   * PDFs go in as `document` blocks and are handled natively, so a
##     text-bearing PDF needs no rasterisation on our side at all.
##   * `thinking: {type: "adaptive"}` is the current control; the old
##     `budget_tokens` form is rejected outright by this model family.
##   * A safety decline arrives as HTTP 200 with `stop_reason: "refusal"`, not
##     as an error, so `stop_reason` must be checked before reading content.

import std/[json, strutils]

import ../core/[types, errors, log]
import ./client

export client

proc buildRequestBody*(cfg: VlmConfig; req: VlmRequest): JsonNode =
  ## Assembles the JSON body. Split out from the call so it can be asserted on
  ## directly in tests.
  var content = newJArray()

  # Documents and images first, prompt last: the API documents better results
  # when the media precedes the question about it.
  for doc in req.documents:
    content.add %*{
      "type": "document",
      "source": {
        "type": "base64",
        "media_type": "application/pdf",
        "data": client.encodeImage(VlmImage(data: doc.data))}}

  for img in req.images:
    content.add %*{
      "type": "image",
      "source": {
        "type": "base64",
        "media_type": img.mediaType,
        "data": client.encodeImage(img)}}

  if req.prompt.len > 0:
    content.add %*{"type": "text", "text": req.prompt}

  result = %*{
    "model": cfg.model,
    "max_tokens": cfg.maxTokens,
    "messages": [{"role": "user", "content": content}]}

  if req.system.len > 0:
    var sysBlock = %*{"type": "text", "text": req.system}
    if cfg.cacheSystemPrompt:
      # The system prompt is the stable prefix across every page of a batch,
      # so it is the one breakpoint worth spending.
      sysBlock["cache_control"] = %*{"type": "ephemeral"}
    result["system"] = %[sysBlock]

  if cfg.thinking == tmAdaptive:
    result["thinking"] = %*{"type": "adaptive"}

  var outputConfig = %*{"effort": $cfg.effort}
  if req.jsonSchema != nil:
    # Structured outputs constrain the response to the schema, which removes
    # the "model wrapped its JSON in prose" failure mode entirely.
    outputConfig["format"] = %*{
      "type": "json_schema",
      "schema": req.jsonSchema}
    if req.schemaName.len > 0:
      outputConfig["format"]["name"] = %req.schemaName
  result["output_config"] = outputConfig

  if cfg.serverSideFallback:
    # Routes a safety decline to a fallback model inside the same call rather
    # than returning an empty answer. "default" lets the server pick by
    # refusal category, so no model list has to be maintained here.
    result["fallbacks"] = %"default"

proc buildHeaders*(cfg: VlmConfig): HttpHeaders =
  result = @[
    ("content-type", "application/json"),
    ("x-api-key", cfg.apiKey),
    ("anthropic-version", anthropicVersion)]
  if cfg.serverSideFallback:
    result.add ("anthropic-beta", fallbackBeta)

proc parseResponse*(body: string): VlmAnswer =
  ## Extracts text, usage and stop reason from a Messages API response.
  var root: JsonNode
  try:
    root = parseJson(body)
  except JsonParsingError as e:
    raise newVlmError("could not parse the API response as JSON: " & e.msg)

  if root.kind != JObject:
    raise newVlmError("unexpected API response shape")

  if root.hasKey("error"):
    let err = root["error"]
    raise newVlmError("API returned an error: " &
      err{"type"}.getStr("unknown") & ": " & err{"message"}.getStr(""))

  result.stopReason = root{"stop_reason"}.getStr("")
  result.refused = result.stopReason == "refusal"

  # `content` is a list of blocks; concatenate the text ones. Thinking blocks
  # are deliberately skipped -- they are summaries or empty, never the answer.
  if root.hasKey("content") and root["content"].kind == JArray:
    for blk in root["content"]:
      if blk{"type"}.getStr("") == "text":
        result.text.add blk{"text"}.getStr("")

  # The model that actually served the turn, which differs from the requested
  # one whenever a server-side fallback fired.
  result.usage.model = root{"model"}.getStr("")
  if root.hasKey("usage"):
    let u = root["usage"]
    result.usage.inputTokens = u{"input_tokens"}.getInt(0)
    result.usage.outputTokens = u{"output_tokens"}.getInt(0)
    result.usage.cacheReadTokens = u{"cache_read_input_tokens"}.getInt(0)
    result.usage.cacheCreationTokens = u{"cache_creation_input_tokens"}.getInt(0)

  if result.refused:
    let details = root{"stop_details"}
    let category =
      if details != nil and details.kind == JObject:
        details{"category"}.getStr("unspecified")
      else: "unspecified"
    log.warn("the model declined this request",
             {"category": category,
              "explanation": (if details != nil:
                                details{"explanation"}.getStr("") else: "")})

  # Structured output arrives as JSON text; parse it so callers do not have to
  # guess whether they got prose or data.
  let trimmed = result.text.strip()
  if trimmed.startsWith("{") or trimmed.startsWith("["):
    try:
      result.structured = parseJson(trimmed)
    except JsonParsingError:
      discard

proc complete*(cfg: VlmConfig; req: VlmRequest;
               transport: Transport = realTransport): VlmAnswer =
  ## Runs one Messages API request with retries and returns the answer.
  cfg.validate()
  let body = $buildRequestBody(cfg, req)
  let url = joinUrl(cfg.baseUrl, "/v1/messages")

  var totalPixels = 0
  for img in req.images:
    totalPixels += img.data.len # bytes, a lower bound on cost; logged only
  log.debug("calling the Anthropic Messages API", {
    "model": cfg.model, "images": $req.images.len,
    "documents": $req.documents.len, "body_bytes": $body.len})

  let resp = postWithRetry(cfg, url, buildHeaders(cfg), body, transport)
  result = parseResponse(resp.body)

  log.info("VLM call complete", {
    "model": result.usage.model,
    "stop_reason": result.stopReason,
    "input_tokens": $result.usage.inputTokens,
    "output_tokens": $result.usage.outputTokens,
    "cache_read": $result.usage.cacheReadTokens})
