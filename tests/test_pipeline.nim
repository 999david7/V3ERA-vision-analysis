## Classification and end-to-end pipeline tests.
##
## These exercise the orchestrator's contract, which is: **degrade, never
## fail**. A missing engine, a blank page or an unconfigured model must produce
## a result with a warning, not an exception -- that is what lets a batch job
## survive a bad page.

import std/[unittest, os, strutils, options, json, sequtils]

import ../src/v3era/core/[types, errors]
import ../src/v3era/imageio/[io, netpbm]
import ../src/v3era/preprocess/[ops, pipeline]
import ../src/v3era/ocr/tesseract
import ../src/v3era/pipeline/[classify, analyze]
import ../src/v3era/vlm/[client, prompts]
import ../src/v3era/util/exec
import ./helpers, ./pdfgen

let haveOcr = tesseractAvailable()
let havePdf = hasCommand("pdftoppm")

var lastRequestBody: string
  ## Set by the stub transport below. A module-level var rather than a captured
  ## local because Nim will not let a gcsafe closure capture GC'd state; the
  ## test suite is single-threaded, so this is safe.

proc uiScreenshot(width = 900; height = 600): Image =
  ## A synthetic UI: coloured chrome running to the edges, flat fills, a small
  ## palette, and text-like bars in the content area.
  result = newImage(width, height, pkRgb)
  for i in 0 ..< result.data.len: result.data[i] = 245
  # Title bar and sidebar reach the border, which is what marks it as chrome.
  for y in 0 ..< 40:
    for x in 0 ..< width:
      let p = (y * width + x) * 3
      result.data[p] = 40
      result.data[p + 1] = 90
      result.data[p + 2] = 180
  for y in 0 ..< height:
    for x in 0 ..< 120:
      let p = (y * width + x) * 3
      result.data[p] = 230
      result.data[p + 1] = 232
      result.data[p + 2] = 240
  for row in 0 ..< 10:
    let y0 = 70 + row * 30
    for y in y0 ..< min(height, y0 + 12):
      for x in 150 ..< width - 60:
        let p = (y * width + x) * 3
        result.data[p] = 30
        result.data[p + 1] = 30
        result.data[p + 2] = 30

proc photoLike(width = 600; height = 400): Image =
  ## Continuous tone with per-pixel noise: no two neighbours are equal, which
  ## is the defining property of camera output.
  result = newImage(width, height, pkRgb)
  var seed = 12345'u32
  for y in 0 ..< height:
    for x in 0 ..< width:
      let p = (y * width + x) * 3
      seed = seed * 1664525'u32 + 1013904223'u32
      let noise = int((seed shr 16) and 0x1F) - 16
      result.data[p] = byte(clamp(120 + x * 100 div width + noise, 0, 255))
      result.data[p + 1] = byte(clamp(90 + y * 120 div height + noise, 0, 255))
      result.data[p + 2] = byte(clamp(160 - x * 60 div width + noise, 0, 255))

proc lineArt(width = 800; height = 600): Image =
  ## Sparse strokes on white, with no regular horizontal banding.
  # Built in a local: Nim forbids closures over `result`, and `box` is one.
  var img = solid(width, height, 255)
  proc box(x0, y0, w, h: int) =
    for x in x0 ..< min(width, x0 + w):
      for t in 0 ..< 3:
        if y0 + t < height: img.data[(y0 + t) * width + x] = 0
        if y0 + h - t >= 0 and y0 + h - t < height:
          img.data[(y0 + h - t) * width + x] = 0
    for y in y0 ..< min(height, y0 + h):
      for t in 0 ..< 3:
        if x0 + t < width: img.data[y * width + x0 + t] = 0
        if x0 + w - t >= 0 and x0 + w - t < width:
          img.data[y * width + x0 + w - t] = 0
  box(60, 60, 200, 120)
  box(500, 60, 200, 120)
  box(280, 350, 240, 140)
  for x in 260 ..< 500:
    for t in 0 ..< 3:
      img.data[(120 + t) * width + x] = 0
  move(img)

suite "classification signals":
  test "flat runs separate synthetic pixels from photographic ones":
    check computeSignals(uiScreenshot()).flatRunRatio > 0.55
    check computeSignals(photoLike()).flatRunRatio < 0.2

  test "a photograph has many distinct colours; a UI has few":
    check computeSignals(photoLike()).uniqueColorRatio >
          computeSignals(uiScreenshot()).uniqueColorRatio

  test "a page has bare margins; a screenshot has chrome at the edges":
    check computeSignals(syntheticPage(800, 600)).borderBackgroundRatio > 0.95
    check computeSignals(uiScreenshot()).borderBackgroundRatio < 0.6

  test "band structure separates lines of type from drawn rules":
    let page = computeSignals(syntheticPage(800, 600))
    let art = computeSignals(lineArt())
    # Both spike the row projection -- that alone proves nothing.
    check page.textLineScore > 1.0
    check art.textLineScore > 1.0
    # The bands themselves are what differ: type is thick and evenly led.
    check page.medianBandHeight >= 8
    check art.medianBandHeight <= 4
    check page.bandRegularity > 0.9
    check page.textBandCount >= 8

  test "an empty image yields zeroed signals rather than a crash":
    let s = computeSignals(Image())
    check s.flatRunRatio == 0.0
    check s.inkCoverage == 0.0

suite "classification verdicts":
  test "a rendered page of text is a document, not a screenshot":
    let c = classify(syntheticPage(800, 600))
    check c.kind == ikScannedDocument
    check c.confidence > 0.5

  test "a UI capture is a screenshot":
    check classify(uiScreenshot()).kind == ikScreenshot

  test "sparse line art is a diagram":
    check classify(lineArt()).kind == ikDiagram

  test "a noisy continuous-tone image is a photo":
    check classify(photoLike()).kind == ikPhoto

  test "a PDF hint overrides the pixels":
    let c = classify(uiScreenshot(), hintedFormat = sfPdf)
    check c.kind == ikPdf
    check c.confidence == 1.0

  test "a short page is still a document, not a diagram":
    # Receipts, memos and cover sheets have only a handful of lines. An
    # earlier band-count floor of four sent them down the diagram path, and a
    # standard-deviation regularity measure sank them on a single stray band.
    let short = syntheticPage(700, 900, lines = 3, lineHeight = 18,
                              leading = 34, margin = 80)
    check classify(short).kind == ikScannedDocument

  test "one stray band does not destroy the regularity score":
    var page = syntheticPage(700, 900, lines = 6, lineHeight = 18,
                             leading = 34, margin = 80)
    # A page number far below the body: one anomalous gap among five.
    fillRect(page, bbox(330, 820, 40, 16), 0'u8)
    check computeSignals(page).bandRegularity > 0.6
    check classify(page).kind == ikScannedDocument

  test "an empty image is unknown and says why":
    let c = classify(Image())
    check c.kind == ikUnknown
    check c.rationale.len > 0

  test "a blank page is unknown rather than being called a diagram":
    let c = classify(solid(600, 800, 255))
    check c.kind == ikUnknown
    check "no discernible content" in c.rationale

  test "every verdict carries the evidence behind it":
    for img in [uiScreenshot(), photoLike(), lineArt(), syntheticPage()]:
      let c = classify(img)
      check c.rationale.len > 0
      check c.signals.flatRunRatio >= 0.0

suite "pipeline over images":
  test "a page runs end to end and reports its stages":
    let res = analyzeImage(syntheticPage(800, 600), "synthetic",
                           defaultAnalyzeOptions())
    check res.kind == ikScannedDocument
    check res.document.pages.len == 1
    check res.totalMs > 0.0
    let stages = res.timings.mapIt(it.stage)
    check stClassify in stages
    check stPreprocess in stages

  test "an explicit kind skips classification":
    var opts = defaultAnalyzeOptions()
    opts.kind = ikDiagram
    opts.runOcr = false
    let res = analyzeImage(lineArt(), "diagram", opts)
    check res.kind == ikDiagram
    check stClassify notin res.timings.mapIt(it.stage)

  test "a blank page is detected and OCR is skipped with a warning":
    var opts = defaultAnalyzeOptions()
    let res = analyzeImage(solid(400, 400, 255), "blank", opts)
    check res.quality.isBlank
    check res.warnings.anyIt("blank" in it)
    check stOcr notin res.timings.mapIt(it.stage)

  test "an empty image warns instead of raising":
    let res = analyzeImage(Image(), "empty", defaultAnalyzeOptions())
    check res.warnings.len > 0
    check res.quality.isBlank

  test "bytes are decoded and the format recorded":
    let pnm = syntheticPage(300, 200).encodePnm()
    var opts = defaultAnalyzeOptions()
    opts.runOcr = false
    let res = analyzeImageBytes(toOpenArrayByte(pnm, 0, pnm.high), "mem", opts)
    check res.format == sfPnm
    check res.timings[0].stage == stDecode

  test "undecodable bytes raise -- there is nothing to degrade to":
    var opts = defaultAnalyzeOptions()
    expect UnsupportedFormatError:
      let junk = "definitely not an image"
      discard analyzeImageBytes(toOpenArrayByte(junk, 0, junk.high), "junk",
                                opts)

  test "a missing file is reported as such":
    expect ImageError:
      discard analyzeFile("/nonexistent/nope.png")

suite "VLM stage degradation":
  test "an unconfigured model is skipped with an explanatory warning":
    var opts = defaultAnalyzeOptions()
    opts.runVlm = true
    opts.runOcr = false
    opts.vlm.apiKey = ""
    let res = analyzeImage(syntheticPage(400, 300), "x", opts)
    check res.vlm.isNone
    check res.warnings.anyIt("VLM skipped" in it)

  test "a configured model is called through the injected transport":
    var opts = defaultAnalyzeOptions()
    opts.runVlm = true
    opts.runOcr = false
    opts.vlm.apiKey = "sk-ant-test"
    lastRequestBody = ""
    opts.transport = proc (url: string; headers: HttpHeaders; body: string;
                           timeoutMs: int): HttpResponse {.gcsafe.} =
      {.cast(gcsafe).}:
        lastRequestBody = body
      HttpResponse(status: 200, body: """
        {"model":"claude-opus-5","stop_reason":"end_turn",
         "content":[{"type":"text","text":"a page of text"}],
         "usage":{"input_tokens":900,"output_tokens":12}}""")

    let res = analyzeImage(syntheticPage(400, 300), "x", opts)
    when defined(v3eraStb):
      check res.vlm.isSome
      check res.vlm.get.text == "a page of text"
      check res.vlm.get.usage.inputTokens == 900
      check "\"image\"" in lastRequestBody
    else:
      # Without stb there is no PNG/JPEG encoder, so the stage declines rather
      # than sending a format no model accepts.
      check res.vlm.isNone
      check res.warnings.anyIt("v3eraStb" in it)

  test "an API failure degrades to a warning, not an exception":
    var opts = defaultAnalyzeOptions()
    opts.runVlm = true
    opts.runOcr = false
    opts.vlm.apiKey = "sk-ant-test"
    opts.vlm.maxRetries = 0
    opts.transport = proc (url: string; headers: HttpHeaders; body: string;
                           timeoutMs: int): HttpResponse {.gcsafe.} =
      HttpResponse(status: 401, body: """{"error":{"message":"bad key"}}""")
    let res = analyzeImage(syntheticPage(400, 300), "x", opts)
    check res.vlm.isNone
    check res.warnings.len > 0

suite "result serialisation":
  test "the JSON projection carries every top-level field":
    var opts = defaultAnalyzeOptions()
    opts.runOcr = false
    let node = analyzeImage(syntheticPage(400, 300), "src", opts).toJson()
    for key in ["source", "format", "kind", "quality", "document", "warnings",
                "timings", "total_ms"]:
      check node.hasKey(key)
    check node["document"]["pages"].len == 1

  test "word boxes are opt-in, because they dominate the payload":
    if not haveOcr:
      skip()
    else:
      let res = analyzeImage(syntheticPage(900, 700), "src",
                             defaultAnalyzeOptions())
      let withoutWords = res.toJson(includeWords = false)
      let withWords = res.toJson(includeWords = true)
      check ($withWords).len >= ($withoutWords).len

  test "markdown rendering never returns an empty string":
    var opts = defaultAnalyzeOptions()
    opts.runOcr = false
    check analyzeImage(syntheticPage(400, 300), "src", opts).markdown().len > 0

if not haveOcr:
  echo "  [skipped] OCR integration tests: libtesseract is not available"
else:
  suite "OCR integration":
    test "a rendered page of real text is recognised":
      if not havePdf:
        skip()
      else:
        let dir = getTempDir() / "v3era-ocr-int"
        createDir(dir)
        defer:
          try: removeDir(dir) except OSError: discard
        let path = dir / "text.pdf"
        writeFile(path, simpleTextPdf([
          "The quick brown fox", "jumps over the lazy dog"], fontSize = 24))

        let res = analyzeFile(path)
        check res.format == sfPdf
        check "quick brown fox" in res.document.text
        check "lazy dog" in res.document.text

    test "OCR of a synthetic bar page returns a page structure, not a crash":
      # The bars are not letters, so no particular text is expected -- what is
      # being checked is that the whole path runs and reports coherently.
      let res = analyzeImage(syntheticPage(900, 700), "bars",
                             defaultAnalyzeOptions())
      check stOcr in res.timings.mapIt(it.stage)
      check res.document.pages.len == 1

if not havePdf:
  echo "  [skipped] PDF pipeline tests: poppler is not available"
else:
  suite "PDF pipeline":
    test "a digital PDF is read from its text layer with no OCR":
      let dir = getTempDir() / "v3era-pdf-pipeline"
      createDir(dir)
      defer:
        try: removeDir(dir) except OSError: discard
      let path = dir / "digital.pdf"
      writeFile(path, textPdf([
        @["First page with a genuine text layer on it."],
        @["Second page, also with real extractable text."]]))

      let res = analyzeFile(path)
      check res.kind == ikPdf
      check res.document.pages.len == 2
      check res.document.pages.allIt(it.fromTextLayer)
      check "First page" in res.document.pages[0].text
      check "Second page" in res.document.pages[1].text
      # No OCR stage should have run at all.
      check stOcr notin res.timings.mapIt(it.stage)

    test "a page range limits the work":
      let dir = getTempDir() / "v3era-pdf-range"
      createDir(dir)
      defer:
        try: removeDir(dir) except OSError: discard
      let path = dir / "many.pdf"
      writeFile(path, textPdf([
        @["Page one has plenty of text on it right here."],
        @["Page two has plenty of text on it right here."],
        @["Page three has plenty of text on it right here."]]))

      var opts = defaultAnalyzeOptions()
      opts.pdf.firstPage = 2
      opts.pdf.lastPage = 2
      let res = analyzeFile(path, opts)
      check res.document.pages.len == 1
      check "Page two" in res.document.pages[0].text

    test "PDF bytes from memory work the same as from disk":
      let pdf = simpleTextPdf(["In-memory document with real text content."])
      let res = analyzeBytes(toOpenArrayByte(pdf, 0, pdf.high), "mem.pdf")
      check res.format == sfPdf
      check res.source == "mem.pdf"
      check "In-memory document" in res.document.text
