## Structured field extraction from a receipt or invoice.
##
##   nim c -r -d:v3eraStb examples/extract_receipt.nim receipt.jpg
##
## Shows the intended division of labour: OCR reads the characters and gives
## exact geometry, then the model is handed both the image *and* that OCR text
## and asked for structured JSON. The model resolves what OCR got wrong (a "5"
## read as an "S"), and OCR anchors the model against inventing values.
##
## Needs ANTHROPIC_API_KEY. Without it the OCR half still runs and the program
## says what it could not do.

import std/[os, json, strutils, options]

import ../src/v3era

proc main() =
  let args = commandLineParams()
  if args.len != 1:
    quit("usage: extract_receipt <image-or-pdf>", 1)
  let path = args[0]

  initLogFromEnv()

  var opts = optionsFromEnv()
  opts.runOcr = true
  opts.runVlm = true
  opts.vlmTask = vtExtractFields   # carries a JSON schema; see vlm/prompts.nim
  opts.includeOcrInPrompt = true   # hand the OCR text over as a hint
  opts.vlm.effort = efHigh

  let res = analyzeFile(path, opts)

  echo "source     : ", res.source
  echo "kind       : ", res.kind
  echo "quality    : sharpness=", res.quality.sharpness.formatFloat(ffDecimal, 0),
       " contrast=", res.quality.contrast.formatFloat(ffDecimal, 2)
  echo "elapsed    : ", res.totalMs.formatFloat(ffDecimal, 0), " ms"

  for w in res.warnings:
    echo "warning    : ", w

  echo "\n--- OCR text ---"
  echo res.document.text.strip()

  if res.vlm.isNone:
    echo "\nNo model output. Set ANTHROPIC_API_KEY to enable the VLM stage."
    return

  let answer = res.vlm.get
  if answer.refused:
    echo "\nThe model declined this request."
    return

  echo "\n--- extracted fields ---"
  if answer.structured != nil:
    let doc = answer.structured
    echo "document_type: ", doc{"document_type"}.getStr("unknown")
    for field in doc{"fields"}:
      let confidence = field{"confidence"}.getStr("")
      echo "  ", field{"key"}.getStr().alignLeft(24), " ",
           field{"value"}.getStr(),
           (if confidence.len > 0 and confidence != "high":
              "   [" & confidence & " confidence]" else: "")
    let notes = doc{"notes"}.getStr("")
    if notes.len > 0:
      echo "\nnotes: ", notes
  else:
    # The schema should prevent this, but a model can still return prose.
    echo answer.text

  echo "\ntokens: ", answer.usage.inputTokens, " in / ",
       answer.usage.outputTokens, " out",
       (if answer.usage.cacheReadTokens > 0:
          " (" & $answer.usage.cacheReadTokens & " cached)" else: "")

when isMainModule:
  main()
