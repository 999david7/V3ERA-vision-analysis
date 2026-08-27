## The domain model shared by every subsystem.
##
## Everything here is a plain value type: images, geometry, OCR output and the
## final analysis record. Keeping them free of behaviour means the preprocessing,
## OCR, document and VLM layers can be recombined (or replaced) without a
## dependency cycle, and that results serialise to JSON with no adapters.

import std/[json, math, strutils, options]

import ./errors

# ---------------------------------------------------------------------------
# Raster images
# ---------------------------------------------------------------------------

type
  PixelKind* = enum ## Channel count, named. The ordinal *is* the channel count.
    pkGray = 1
    pkGrayAlpha = 2
    pkRgb = 3
    pkRgba = 4

  Image* = object
    ## An 8-bit raster. Rows are tightly packed with no padding, so the stride
    ## is always `width * channels`. Dropping configurable strides removes a
    ## whole class of off-by-one bugs at the C boundary, and the copy cost of
    ## normalising an odd-stride decode is negligible next to OCR.
    width*, height*: int
    channels*: int    ## 1..4, matching `PixelKind`.
    dpi*: int         ## Horizontal resolution; 0 when unknown.
    data*: seq[byte]

func pixelKind*(img: Image): PixelKind {.inline.} =
  PixelKind(img.channels)

func stride*(img: Image): int {.inline.} =
  img.width * img.channels

func byteLen*(img: Image): int {.inline.} =
  img.width * img.height * img.channels

func isEmpty*(img: Image): bool {.inline.} =
  img.width <= 0 or img.height <= 0 or img.data.len == 0

func isGray*(img: Image): bool {.inline.} =
  img.channels == 1

proc newImage*(width, height: int; kind = pkGray; dpi = 0): Image =
  ## Allocates a zero-filled image. Raises `ImageError` on non-positive or
  ## overflowing dimensions -- a decoder handed a hostile header must not be
  ## able to turn a bad size into an under-allocated buffer.
  if width <= 0 or height <= 0:
    raiseImage("invalid image dimensions: " & $width & "x" & $height)
  let ch = ord(kind)
  # 64-bit product guard: on a 64-bit target `int` is 64 bits, so this catches
  # absurd headers well before the multiplication itself could wrap.
  if width.int64 * height.int64 * ch.int64 > int64(high(int32)):
    raiseImage("image too large: " & $width & "x" & $height & "x" & $ch)
  result = Image(
    width: width, height: height, channels: ch, dpi: dpi,
    data: newSeq[byte](width * height * ch))

proc initImage*(width, height, channels: int; data: sink seq[byte];
                dpi = 0): Image =
  ## Wraps an existing buffer, validating that its length matches the geometry.
  if channels < 1 or channels > 4:
    raiseImage("unsupported channel count: " & $channels)
  if width <= 0 or height <= 0:
    raiseImage("invalid image dimensions: " & $width & "x" & $height)
  if data.len != width * height * channels:
    raiseImage("buffer length " & $data.len & " does not match " & $width &
      "x" & $height & "x" & $channels)
  result = Image(width: width, height: height, channels: channels, dpi: dpi,
                 data: data)

func idx*(img: Image; x, y: int): int {.inline.} =
  ## Byte offset of pixel (x, y). No bounds check -- callers in hot loops have
  ## already clamped; use `at` when you want the check.
  (y * img.width + x) * img.channels

proc at*(img: Image; x, y, c: int): byte =
  ## Bounds-checked channel read.
  if x < 0 or y < 0 or x >= img.width or y >= img.height or
     c < 0 or c >= img.channels:
    raiseImage("pixel access out of bounds: (" & $x & "," & $y & "," & $c & ")")
  img.data[img.idx(x, y) + c]

proc `[]=`*(img: var Image; x, y, c: int; v: byte) =
  if x < 0 or y < 0 or x >= img.width or y >= img.height or
     c < 0 or c >= img.channels:
    raiseImage("pixel write out of bounds: (" & $x & "," & $y & "," & $c & ")")
  img.data[img.idx(x, y) + c] = v

func megapixels*(img: Image): float =
  img.width.float * img.height.float / 1_000_000.0

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

type
  BBox* = object
    ## Axis-aligned box in pixel space; `x`,`y` is the top-left corner.
    x*, y*, w*, h*: int

func bbox*(x, y, w, h: int): BBox {.inline.} =
  BBox(x: x, y: y, w: w, h: h)

func right*(b: BBox): int {.inline.} = b.x + b.w
func bottom*(b: BBox): int {.inline.} = b.y + b.h
func area*(b: BBox): int {.inline.} = max(0, b.w) * max(0, b.h)
func isEmpty*(b: BBox): bool {.inline.} = b.w <= 0 or b.h <= 0
func centerX*(b: BBox): float {.inline.} = b.x.float + b.w.float / 2.0
func centerY*(b: BBox): float {.inline.} = b.y.float + b.h.float / 2.0

func union*(a, b: BBox): BBox =
  if a.isEmpty: return b
  if b.isEmpty: return a
  let
    x0 = min(a.x, b.x)
    y0 = min(a.y, b.y)
    x1 = max(a.right, b.right)
    y1 = max(a.bottom, b.bottom)
  bbox(x0, y0, x1 - x0, y1 - y0)

func intersection*(a, b: BBox): BBox =
  let
    x0 = max(a.x, b.x)
    y0 = max(a.y, b.y)
    x1 = min(a.right, b.right)
    y1 = min(a.bottom, b.bottom)
  if x1 <= x0 or y1 <= y0: bbox(0, 0, 0, 0)
  else: bbox(x0, y0, x1 - x0, y1 - y0)

func iou*(a, b: BBox): float =
  ## Intersection over union, the standard box-overlap score.
  let inter = intersection(a, b).area
  if inter == 0: return 0.0
  let uni = a.area + b.area - inter
  if uni <= 0: 0.0 else: inter.float / uni.float

func verticalOverlap*(a, b: BBox): float =
  ## Fraction of the shorter box's height that overlaps the other vertically.
  ## Line grouping uses this rather than IoU because words on one line have
  ## very different widths but near-identical vertical extents.
  let top = max(a.y, b.y)
  let bot = min(a.bottom, b.bottom)
  if bot <= top: return 0.0
  let shorter = min(a.h, b.h)
  if shorter <= 0: 0.0 else: (bot - top).float / shorter.float

func clampTo*(b: BBox; width, height: int): BBox =
  ## Clips a box to an image rectangle, returning an empty box if disjoint.
  intersection(b, bbox(0, 0, width, height))

func expand*(b: BBox; pad: int): BBox =
  bbox(b.x - pad, b.y - pad, b.w + 2 * pad, b.h + 2 * pad)

# ---------------------------------------------------------------------------
# OCR output
# ---------------------------------------------------------------------------

type
  BlockKind* = enum
    bkUnknown = "unknown"
    bkParagraph = "paragraph"
    bkHeading = "heading"
    bkListItem = "list_item"
    bkTable = "table"
    bkCaption = "caption"

  OcrWord* = object
    text*: string
    box*: BBox
    confidence*: float32 ## 0..100, matching Tesseract's scale.

  OcrLine* = object
    text*: string
    box*: BBox
    confidence*: float32
    words*: seq[OcrWord]

  OcrBlock* = object
    kind*: BlockKind
    box*: BBox
    lines*: seq[OcrLine]

  OcrPage* = object
    ## OCR result for a single rendered page or image.
    index*: int            ## 0-based page index within the source document.
    width*, height*: int   ## Geometry of the image the boxes refer to.
    blocks*: seq[OcrBlock]
    meanConfidence*: float32
    deskewAngle*: float    ## Degrees of rotation applied before recognition.
    engine*: string        ## e.g. "tesseract-5.3.4" or "none".
    durationMs*: float

func text*(blk: OcrBlock): string =
  for i, ln in blk.lines:
    if i > 0: result.add '\n'
    result.add ln.text

func text*(page: OcrPage): string =
  for i, blk in page.blocks:
    if i > 0: result.add "\n\n"
    result.add blk.text

func wordCount*(page: OcrPage): int =
  for blk in page.blocks:
    for ln in blk.lines:
      result += ln.words.len

# ---------------------------------------------------------------------------
# Input classification and documents
# ---------------------------------------------------------------------------

type
  InputKind* = enum
    ## What the router decided it is looking at. Drives which pipeline stages
    ## run and which prompt the VLM gets.
    ikUnknown = "unknown"
    ikScreenshot = "screenshot"   ## UI capture: sharp edges, flat colour runs.
    ikPhoto = "photo"             ## Camera image, possibly of a document.
    ikDiagram = "diagram"         ## Chart, schematic, whiteboard, line art.
    ikScannedDocument = "scanned_document"
    ikPdf = "pdf"

  SourceFormat* = enum
    sfUnknown = "unknown"
    sfPng = "png"
    sfJpeg = "jpeg"
    sfWebp = "webp"
    sfGif = "gif"
    sfBmp = "bmp"
    sfTiff = "tiff"
    sfPnm = "pnm"
    sfPdf = "pdf"

func mediaType*(f: SourceFormat): string =
  ## IANA media type, as required by the VLM image/document content blocks.
  case f
  of sfPng: "image/png"
  of sfJpeg: "image/jpeg"
  of sfWebp: "image/webp"
  of sfGif: "image/gif"
  of sfBmp: "image/bmp"
  of sfTiff: "image/tiff"
  of sfPnm: "image/x-portable-anymap"
  of sfPdf: "application/pdf"
  of sfUnknown: "application/octet-stream"

type
  PageContent* = object
    ## One page of a document, after whichever extraction path was taken.
    index*: int
    width*, height*: int
    text*: string
    ocr*: Option[OcrPage] ## Present when the page went through OCR.
    fromTextLayer*: bool  ## True when text came from the PDF's own text layer.

  Document* = object
    source*: string          ## Path or logical identifier of the input.
    format*: SourceFormat
    pageCount*: int
    pages*: seq[PageContent]
    title*: string
    producer*: string

func text*(doc: Document): string =
  for i, p in doc.pages:
    if i > 0: result.add "\n\n"
    result.add p.text

# ---------------------------------------------------------------------------
# Quality metrics and the final result
# ---------------------------------------------------------------------------

type
  ImageQuality* = object
    ## Cheap, explainable signals computed during preprocessing. They gate
    ## expensive stages: a page below `minSharpness` is not worth OCRing at
    ## full resolution, and a near-blank page is not worth sending to a VLM.
    sharpness*: float      ## Variance of the Laplacian.
    meanLuma*: float       ## 0..255.
    inkCoverage*: float    ## Fraction of dark pixels after binarisation.
    contrast*: float       ## Normalised 5th..95th percentile spread, 0..1.
    isBlank*: bool
    estimatedDpi*: int

  Stage* = enum
    stDecode = "decode"
    stClassify = "classify"
    stPreprocess = "preprocess"
    stOcr = "ocr"
    stLayout = "layout"
    stDocument = "document"
    stVlm = "vlm"

  StageTiming* = object
    stage*: Stage
    durationMs*: float
    ok*: bool
    note*: string ## Populated when a stage was skipped or degraded.

  VlmUsage* = object
    inputTokens*: int
    outputTokens*: int
    cacheReadTokens*: int
    cacheCreationTokens*: int
    model*: string

  VlmAnswer* = object
    text*: string
    structured*: JsonNode  ## `nil` unless a JSON schema was requested.
    usage*: VlmUsage
    stopReason*: string
    refused*: bool         ## `stop_reason == "refusal"`.

  AnalysisResult* = object
    ## The single record every entry point returns.
    source*: string
    format*: SourceFormat
    kind*: InputKind
    quality*: ImageQuality
    document*: Document
    vlm*: Option[VlmAnswer]
    timings*: seq[StageTiming]
    warnings*: seq[string]
    totalMs*: float

func totalTokens*(u: VlmUsage): int =
  u.inputTokens + u.outputTokens

proc addWarning*(r: var AnalysisResult; msg: string) =
  ## Warnings are how degradation is reported: a missing OCR engine or an
  ## unreadable page adds one instead of raising.
  if msg notin r.warnings:
    r.warnings.add msg

proc record*(r: var AnalysisResult; stage: Stage; ms: float; ok = true;
             note = "") =
  r.timings.add StageTiming(stage: stage, durationMs: ms, ok: ok, note: note)

# ---------------------------------------------------------------------------
# JSON projection
# ---------------------------------------------------------------------------

func toJson*(b: BBox): JsonNode =
  %*{"x": b.x, "y": b.y, "w": b.w, "h": b.h}

func toJson*(w: OcrWord): JsonNode =
  %*{"text": w.text, "box": w.box.toJson(), "confidence": w.confidence.float}

func toJson*(l: OcrLine): JsonNode =
  result = %*{
    "text": l.text,
    "box": l.box.toJson(),
    "confidence": l.confidence.float,
    "words": newJArray()}
  for w in l.words:
    result["words"].add w.toJson()

func toJson*(b: OcrBlock): JsonNode =
  result = %*{"kind": $b.kind, "box": b.box.toJson(), "lines": newJArray()}
  for l in b.lines:
    result["lines"].add l.toJson()

func toJson*(p: OcrPage; includeWords = true): JsonNode =
  result = %*{
    "index": p.index,
    "width": p.width,
    "height": p.height,
    "mean_confidence": p.meanConfidence.float,
    "deskew_angle": p.deskewAngle,
    "engine": p.engine,
    "duration_ms": p.durationMs,
    "blocks": newJArray()}
  for b in p.blocks:
    var node = b.toJson()
    if not includeWords:
      for lineNode in node["lines"]:
        lineNode.delete("words")
    result["blocks"].add node

func toJson*(q: ImageQuality): JsonNode =
  %*{
    "sharpness": q.sharpness,
    "mean_luma": q.meanLuma,
    "ink_coverage": q.inkCoverage,
    "contrast": q.contrast,
    "is_blank": q.isBlank,
    "estimated_dpi": q.estimatedDpi}

func toJson*(u: VlmUsage): JsonNode =
  %*{
    "model": u.model,
    "input_tokens": u.inputTokens,
    "output_tokens": u.outputTokens,
    "cache_read_tokens": u.cacheReadTokens,
    "cache_creation_tokens": u.cacheCreationTokens}

func toJson*(a: VlmAnswer): JsonNode =
  result = %*{
    "text": a.text,
    "usage": a.usage.toJson(),
    "stop_reason": a.stopReason,
    "refused": a.refused}
  if a.structured != nil:
    result["structured"] = a.structured

func toJson*(p: PageContent; includeOcr: bool; includeWords: bool): JsonNode =
  result = %*{
    "index": p.index,
    "width": p.width,
    "height": p.height,
    "text": p.text,
    "from_text_layer": p.fromTextLayer}
  if includeOcr and p.ocr.isSome:
    result["ocr"] = p.ocr.get.toJson(includeWords)

func toJson*(d: Document; includeOcr = true; includeWords = false): JsonNode =
  result = %*{
    "source": d.source,
    "format": $d.format,
    "page_count": d.pageCount,
    "title": d.title,
    "producer": d.producer,
    "pages": newJArray()}
  for p in d.pages:
    result["pages"].add p.toJson(includeOcr, includeWords)

func toJson*(r: AnalysisResult; includeOcr = true;
             includeWords = false): JsonNode =
  result = %*{
    "source": r.source,
    "format": $r.format,
    "kind": $r.kind,
    "quality": r.quality.toJson(),
    "document": r.document.toJson(includeOcr, includeWords),
    "warnings": %r.warnings,
    "total_ms": r.totalMs,
    "timings": newJArray()}
  for t in r.timings:
    result["timings"].add %*{
      "stage": $t.stage, "duration_ms": t.durationMs, "ok": t.ok,
      "note": t.note}
  if r.vlm.isSome:
    result["vlm"] = r.vlm.get.toJson()

const listMarkers* = ["-", "*", "\u2022", "\u25E6", "\u2023", "\u00B7",
                     "\u2013", "\u2014", "\u25AA", "\u25CF"]
  ## Bullet glyphs OCR commonly returns at the head of a list item.

func stripListMarker*(line: string): string =
  ## Removes a leading bullet glyph and its trailing space.
  ##
  ## Recognised list text arrives *with* its bullet -- Tesseract reads the
  ## glyph like any other. Emitting Markdown without stripping it produces
  ## "- - item", so every renderer has to do this.
  result = line.strip()
  for marker in listMarkers:
    if result.len > marker.len and result.startsWith(marker) and
       result[marker.len] in {' ', '\t'}:
      return result[marker.len .. ^1].strip(leading = true, trailing = false)

func toMarkdown*(page: OcrPage): string =
  ## Renders recognised blocks as Markdown. Headings become `##`, list items
  ## get a bullet, everything else is a paragraph -- enough structure to feed a
  ## downstream LLM or a diff without inventing a document format.
  for blk in page.blocks:
    let body = blk.text.strip()
    if body.len == 0: continue
    case blk.kind
    of bkHeading:
      result.add "## " & body.replace("\n", " ") & "\n\n"
    of bkListItem:
      for line in body.splitLines():
        let t = stripListMarker(line)
        if t.len > 0: result.add "- " & t & "\n"
      result.add "\n"
    of bkCaption:
      result.add "*" & body.replace("\n", " ") & "*\n\n"
    else:
      result.add body & "\n\n"
  result = result.strip() & "\n"
