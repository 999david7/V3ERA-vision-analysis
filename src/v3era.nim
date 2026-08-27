## V3ERA -- a modular vision analysis system.
##
## Import this module to get the whole library:
##
## ```nim
## import v3era
##
## let result = analyzeFile("invoice.pdf")
## echo result.document.text
## echo result.toJson().pretty()
## ```
##
## Or reach for one layer at a time -- `v3era/preprocess/ops`,
## `v3era/ocr/tesseract`, `v3era/vlm/anthropic` and the rest stand alone and
## depend only on `core/`.
##
## Capabilities are resolved at runtime, not at link time. `capabilities()`
## reports what this particular build and host can actually do, and every
## optional stage degrades to a warning on the result rather than an exception.

import std/[strutils, json]

import v3era/core/types
import v3era/core/errors
import v3era/core/log
import v3era/imageio/io
import v3era/imageio/sniff
import v3era/imageio/netpbm
import v3era/imageio/stbimage
import v3era/preprocess/ops
import v3era/preprocess/deskew
import v3era/preprocess/pipeline
import v3era/ocr/tesseract
import v3era/docparse/pdf
import v3era/docparse/layout
import v3era/vlm/client
import v3era/vlm/anthropic
import v3era/vlm/openai
import v3era/vlm/prompts
import v3era/pipeline/classify
import v3era/pipeline/analyze
import v3era/util/exec

export types, errors, log
export io, sniff, netpbm, stbimage
export ops, deskew, pipeline
export tesseract
export pdf, layout
export client, prompts
export classify, analyze
export exec

# `anthropic` and `openai` both define `complete`, `buildRequestBody`,
# `buildHeaders` and `parseResponse`. Re-exporting both unqualified would make
# every call site ambiguous, so they stay reachable as `anthropic.complete(...)`
# and `openai.complete(...)`.
export anthropic.complete
export openai.complete

const
  v3eraVersion* = "0.1.0"

type
  Capabilities* = object
    ## What this build, on this host, can do right now.
    version*: string
    imageFormats*: seq[string]
    stbImage*: bool
    ocr*: bool
    ocrVersion*: string
    ocrDetail*: string ## Why OCR is unavailable, when it is.
    pdfTools*: string
    vlmProvider*: string
    vlmModel*: string
    vlmReady*: bool

proc capabilities*(): Capabilities =
  ## Probes every optional dependency. Cheap enough to call per request; the
  ## library caches the expensive parts (the Tesseract `dlopen`) internally.
  result.version = v3eraVersion
  result.stbImage = stbimage.stbAvailable
  for f in decodableFormats():
    result.imageFormats.add $f
  result.ocr = tesseractAvailable()
  if result.ocr:
    result.ocrVersion = tesseractVersion()
  else:
    result.ocrDetail = tesseractLoadError()
  result.pdfTools = pdfSupportSummary()

  let cfg = configFromEnv()
  result.vlmProvider = $cfg.provider
  result.vlmModel = cfg.model
  result.vlmReady = cfg.vlmConfigured()

proc toJson*(c: Capabilities): JsonNode =
  %*{
    "version": c.version,
    "image_formats": c.imageFormats,
    "stb_image": c.stbImage,
    "ocr": c.ocr,
    "ocr_version": c.ocrVersion,
    "ocr_detail": c.ocrDetail,
    "pdf_tools": c.pdfTools,
    "vlm_provider": c.vlmProvider,
    "vlm_model": c.vlmModel,
    "vlm_ready": c.vlmReady}

proc describeCapabilities*(): string =
  ## Human-readable capability report, used by `v3era --version`.
  let c = capabilities()
  result = "V3ERA " & c.version & "\n"
  result.add "  image decode : " & c.imageFormats.join(", ") &
    (if c.stbImage: " (stb_image enabled)" else: " (stb_image not compiled in)") &
    "\n"
  result.add "  ocr          : " &
    (if c.ocr: "tesseract " & c.ocrVersion
     else: "unavailable -- " & c.ocrDetail) & "\n"
  result.add "  pdf          : " & c.pdfTools & "\n"
  result.add "  vlm          : " & c.vlmProvider & " / " &
    (if c.vlmModel.len > 0: c.vlmModel else: "(no model set)") &
    (if c.vlmReady: "" else: "  [not configured]") & "\n"
