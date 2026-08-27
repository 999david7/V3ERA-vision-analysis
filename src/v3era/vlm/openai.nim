## OpenAI-compatible chat-completions backend.
##
## This is the escape hatch for self-hosted vision models -- vLLM, Ollama,
## llama.cpp's server, LM Studio -- all of which expose the same
## `/v1/chat/completions` shape. It exists so an air-gapped or cost-sensitive
## deployment can keep the rest of the pipeline unchanged.
##
## The shape differs from Anthropic's in three ways that matter here: images
## are `image_url` blocks carrying a `data:` URI rather than base64 fields;
## there is no native PDF input, so documents must be rasterised first; and the
## system prompt is a message rather than a top-level field.

import std/[json, strutils, base64]

import ../core/[types, errors, log]
import ./client

export client

proc buildRequestBody*(cfg: VlmConfig; req: VlmRequest): JsonNode =
  if req.documents.len > 0:
    raiseConfig("the OpenAI-compatible backend has no native PDF input; " &
      "render pages to images first (the analyze pipeline does this " &
      "automatically)")

  var content = newJArray()
  for img in req.images:
    content.add %*{
      "type": "image_url",
      "image_url": {
        "url": "data:" & img.mediaType & ";base64," & base64.encode(img.data)}}
  if req.prompt.len > 0:
    content.add %*{"type": "text", "text": req.prompt}

  var messages = newJArray()
  if req.system.len > 0:
    messages.add %*{"role": "system", "content": req.system}
  messages.add %*{"role": "user", "content": content}

  result = %*{
    "model": cfg.model,
    "max_tokens": cfg.maxTokens,
    "messages": messages}

  if req.jsonSchema != nil:
    # Supported by vLLM and recent llama.cpp; servers that do not understand it
    # ignore the field, and the prompt still asks for JSON.
    result["response_format"] = %*{
      "type": "json_schema",
      "json_schema": {
        "name": (if req.schemaName.len > 0: req.schemaName else: "result"),
        "schema": req.jsonSchema,
        "strict": true}}

proc buildHeaders*(cfg: VlmConfig): HttpHeaders =
  result = @[("content-type", "application/json")]
  if cfg.apiKey.len > 0:
    result.add ("authorization", "Bearer " & cfg.apiKey)

proc parseResponse*(body: string): VlmAnswer =
  var root: JsonNode
  try:
    root = parseJson(body)
  except JsonParsingError as e:
    raise newVlmError("could not parse the API response as JSON: " & e.msg)

  if root.hasKey("error"):
    let err = root["error"]
    let msg =
      if err.kind == JObject: err{"message"}.getStr($err)
      else: $err
    raise newVlmError("API returned an error: " & msg)

  let choices = root{"choices"}
  if choices == nil or choices.kind != JArray or choices.len == 0:
    raise newVlmError("response contained no choices")

  let choice = choices[0]
  result.stopReason = choice{"finish_reason"}.getStr("")
  let msg = choice{"message"}
  if msg != nil:
    let c = msg{"content"}
    if c != nil:
      # Some servers return a string, others the block array Anthropic uses.
      if c.kind == JString:
        result.text = c.getStr()
      elif c.kind == JArray:
        for blk in c:
          if blk{"type"}.getStr("") == "text":
            result.text.add blk{"text"}.getStr("")

  result.usage.model = root{"model"}.getStr("")
  if root.hasKey("usage"):
    let u = root["usage"]
    result.usage.inputTokens = u{"prompt_tokens"}.getInt(0)
    result.usage.outputTokens = u{"completion_tokens"}.getInt(0)

  let trimmed = result.text.strip()
  if trimmed.startsWith("{") or trimmed.startsWith("["):
    try:
      result.structured = parseJson(trimmed)
    except JsonParsingError:
      discard

proc complete*(cfg: VlmConfig; req: VlmRequest;
               transport: Transport = realTransport): VlmAnswer =
  cfg.validate()
  let body = $buildRequestBody(cfg, req)
  let url = joinUrl(cfg.baseUrl, "/v1/chat/completions")
  log.debug("calling an OpenAI-compatible endpoint",
            {"url": url, "model": cfg.model, "images": $req.images.len})
  let resp = postWithRetry(cfg, url, buildHeaders(cfg), body, transport)
  result = parseResponse(resp.body)
