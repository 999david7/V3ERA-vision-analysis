## The orchestrator: bytes in, `AnalysisResult` out.
##
## Routes an input through classification, preprocessing, OCR, layout analysis
## and optionally a vision-language model, recording what each stage cost and
## what it skipped.
##
## The governing rule is **degrade, do not fail**. Tesseract missing, poppler
## missing, no API key, an unreadable page -- each of those adds a warning to
## the result and the remaining stages still run. Only an input that cannot be
## decoded at all raises. A batch job over ten thousand scans must not stop
## because page 4,000 is corrupt.

import std/[times, strutils, options, os, sequtils, json]

import ../core/[types, errors, log]
import ../imageio/[io, sniff]
import ../preprocess/[ops, pipeline]
import ../ocr/tesseract
import ../docparse/[pdf, layout]
import ../vlm/[client, anthropic, openai, prompts]
import ../util/exec
import ./classify

type
  AnalyzeOptions* = object
    ## Everything the pipeline can be told to do. Defaults are the useful
    ## middle: classify, preprocess, OCR, no model call.
    kind*: InputKind          ## `ikUnknown` classifies automatically.
    runOcr*: bool
    runLayout*: bool
    runVlm*: bool
    vlmTask*: VisionTask
    vlmPrompt*: string        ## Overrides the task's prompt when non-empty.
    includeOcrInPrompt*: bool ## Send OCR text alongside the image.
    sendPdfNatively*: bool
      ## Hand the PDF straight to the model instead of rasterised pages. Cheaper
      ## and higher fidelity on the Anthropic backend, unsupported elsewhere.
    ocr*: TesseractOptions
    preprocess*: Option[PreprocessConfig] ## Overrides the profile choice.
    vlm*: VlmConfig
    pdf*: PdfOptions
    maxVlmImages*: int
      ## Cap on pages sent to the model in one call. Each page costs roughly
      ## 1.5k tokens, so an uncapped 200-page document is a surprise bill.
    transport*: Transport

proc defaultAnalyzeOptions*(): AnalyzeOptions =
  AnalyzeOptions(
    kind: ikUnknown, runOcr: true, runLayout: true, runVlm: false,
    vlmTask: vtDescribe, includeOcrInPrompt: true, sendPdfNatively: true,
    ocr: defaultTesseractOptions(), vlm: defaultVlmConfig(),
    pdf: defaultPdfOptions(), maxVlmImages: 8, transport: realTransport)

proc optionsFromEnv*(): AnalyzeOptions =
  result = defaultAnalyzeOptions()
  result.vlm = configFromEnv()

# ---------------------------------------------------------------------------
# Stage helpers
# ---------------------------------------------------------------------------

template timeStage(res: var AnalysisResult; stageId: Stage; body: untyped) =
  block:
    let stageStart = epochTime()
    body
    res.record(stageId, (epochTime() - stageStart) * 1000.0)

func psmFor(kind: InputKind): PageSegMode =
  ## Page-segmentation mode matters as much as the image does. Screenshots and
  ## diagrams have scattered labels rather than columns of prose, and Tesseract's
  ## column finder actively hurts there.
  case kind
  of ikScreenshot, ikDiagram: psmSparseText
  else: psmAuto

proc runOcrStage(res: var AnalysisResult; img: Image; kind: InputKind;
                 opts: AnalyzeOptions; pageIndex: int): Option[OcrPage] =
  ## OCR one prepared image, converting a missing engine into a warning.
  var ocrOpts = opts.ocr
  if ocrOpts.pageSegMode == psmAuto:
    ocrOpts.pageSegMode = psmFor(kind)
  try:
    var page = recognizePage(img, ocrOpts, pageIndex)
    if opts.runLayout:
      page = page.analyzeLayout()
    result = some(page)
  except CapabilityError as e:
    res.addWarning("OCR skipped: " & e.msg)
    log.warn("OCR capability unavailable", {"detail": e.msg})
  except OcrError as e:
    res.addWarning("OCR failed: " & e.msg)
    log.warn("OCR failed", {"detail": e.msg})

proc encodeForVlm(img: Image; maxSide: int): VlmImage =
  ## Downscales and encodes a page for transmission. Falls back through the
  ## formats this build can produce; PNM is accepted by no model, so a build
  ## without stb cannot send images and says so.
  let scaled = img.fitLongestSide(maxSide)
  let fmt = bestEncodableFormat(scaled)
  if fmt == sfPnm:
    raise newCapabilityError("image-encoder",
      "sending images to a VLM needs PNG or JPEG encoding; rebuild with " &
      "-d:v3eraStb (see scripts/fetch_vendor.sh)")
  VlmImage(data: encodeImage(scaled, fmt), mediaType: fmt.mediaType)

proc callVlm(cfg: VlmConfig; req: VlmRequest;
             transport: Transport): VlmAnswer =
  case cfg.provider
  of vpAnthropic: anthropic.complete(cfg, req, transport)
  of vpOpenAiCompatible: openai.complete(cfg, req, transport)

proc runVlmStage(res: var AnalysisResult; opts: AnalyzeOptions;
                 images: seq[VlmImage]; documents: seq[VlmDocument];
                 ocrText: string) =
  if not opts.vlm.vlmConfigured():
    res.addWarning("VLM skipped: no model or API key configured " &
      "(set ANTHROPIC_API_KEY)")
    return
  if images.len == 0 and documents.len == 0:
    res.addWarning("VLM skipped: nothing to send")
    return

  var instruction =
    if opts.vlmPrompt.len > 0: opts.vlmPrompt
    else: taskInstruction(opts.vlmTask)
  if opts.includeOcrInPrompt and ocrText.strip().len > 0:
    instruction = withOcrContext(instruction, ocrText)

  let req = VlmRequest(
    system: systemPrompt,
    prompt: instruction,
    images: images,
    documents: documents,
    jsonSchema: (if opts.vlmPrompt.len > 0: nil else: schemaFor(opts.vlmTask)),
    schemaName: $opts.vlmTask)

  try:
    let answer = callVlm(opts.vlm, req, opts.transport)
    if answer.refused:
      res.addWarning("the model declined to answer this request")
    res.vlm = some(answer)
  except VlmError as e:
    res.addWarning("VLM call failed: " & e.msg)
    log.warn("VLM call failed", {"detail": e.msg, "status": $e.status})
  except ConfigError as e:
    res.addWarning("VLM misconfigured: " & e.msg)
  except CapabilityError as e:
    res.addWarning("VLM skipped: " & e.msg)

# ---------------------------------------------------------------------------
# Raster inputs
# ---------------------------------------------------------------------------

proc analyzeImage*(img: Image; source: string;
                   opts = defaultAnalyzeOptions()): AnalysisResult =
  ## Runs the pipeline over an already-decoded image.
  let started = epochTime()
  result.source = source
  result.format = sfUnknown

  if img.isEmpty:
    result.addWarning("input decoded to an empty image")
    result.quality = ImageQuality(isBlank: true)
    return

  var kind = opts.kind
  if kind == ikUnknown:
    timeStage(result, stClassify):
      let c = classify.classify(img)
      kind = c.kind
      if c.kind == ikUnknown:
        result.addWarning("could not classify the input: " & c.rationale)
  result.kind = kind

  var prepared: Image
  var report: PreprocessReport
  timeStage(result, stPreprocess):
    let cfg =
      if opts.preprocess.isSome: opts.preprocess.get else: profileFor(kind)
    (prepared, report) = img.preprocess(cfg)
  result.quality = report.quality
  if report.deskewAngle != 0.0 or report.quadrantTurns != 0:
    log.debug("orientation corrected", {
      "turns": $report.quadrantTurns,
      "angle": formatFloat(report.deskewAngle, ffDecimal, 2)})

  var page = PageContent(index: 0, width: img.width, height: img.height)

  if opts.runOcr and not result.quality.isBlank:
    timeStage(result, stOcr):
      let ocr = runOcrStage(result, prepared, kind, opts, 0)
      if ocr.isSome:
        var o = ocr.get
        o.deskewAngle = report.deskewAngle
        page.ocr = some(o)
        page.text = o.text
  elif result.quality.isBlank:
    result.addWarning("page looks blank; OCR skipped")

  result.document = Document(
    source: source, format: sfUnknown, pageCount: 1, pages: @[page])

  if opts.runVlm:
    timeStage(result, stVlm):
      try:
        let vlmImage = encodeForVlm(img, opts.vlm.maxImageSide)
        runVlmStage(result, opts, @[vlmImage], @[], page.text)
      except CapabilityError as e:
        result.addWarning("VLM skipped: " & e.msg)

  result.totalMs = (epochTime() - started) * 1000.0

proc analyzeImageBytes*(data: openArray[byte]; source: string;
                        opts = defaultAnalyzeOptions()): AnalysisResult =
  ## Decodes then analyses. The decode is the one stage allowed to raise: if we
  ## cannot get pixels there is nothing to degrade to.
  let started = epochTime()
  let fmt = detectFormat(data)
  var img: Image
  var decodeMs = 0.0
  block:
    let t0 = epochTime()
    img = decodeImage(data, fmt)
    decodeMs = (epochTime() - t0) * 1000.0

  result = analyzeImage(img, source, opts)
  result.format = fmt
  result.document.format = fmt
  # Splice the decode timing in ahead of the stages it preceded.
  result.timings.insert(StageTiming(stage: stDecode, durationMs: decodeMs,
                                    ok: true), 0)
  result.totalMs = (epochTime() - started) * 1000.0

# ---------------------------------------------------------------------------
# PDF inputs
# ---------------------------------------------------------------------------

proc analyzePdf*(path: string; opts = defaultAnalyzeOptions()): AnalysisResult =
  ## Analyses a PDF: text layer where there is one, render plus OCR where there
  ## is not.
  let started = epochTime()
  result.source = path
  result.format = sfPdf
  result.kind = ikPdf

  var plan: PdfPlan
  timeStage(result, stDocument):
    try:
      plan = planPdf(path, opts.pdf)
    except CapabilityError as e:
      # No toolchain at all: the file may still be sendable to a VLM natively,
      # so record the loss and continue rather than aborting.
      result.addWarning("PDF toolchain unavailable: " & e.msg)
    except DocumentError as e:
      result.addWarning("PDF could not be read: " & e.msg)

  if plan.info.pageCount == 0:
    result.document = Document(source: path, format: sfPdf)
  else:
    result.document = plan.toDocument(path)

    let needOcr = plan.pagesNeedingOcr()
    if opts.runOcr and needOcr.len > 0:
      timeStage(result, stOcr):
        var rendered: seq[tuple[page: int; image: Image]]
        try:
          rendered = renderPages(path, needOcr, opts.pdf.renderDpi, opts.pdf)
        except CapabilityError as e:
          result.addWarning("cannot render pages for OCR: " & e.msg)
        except DocumentError as e:
          result.addWarning("page rendering failed: " & e.msg)
        except ExecError as e:
          result.addWarning("page rendering failed: " & e.msg)

        for (pageNo, raster) in rendered:
          let slot = pageNo - plan.first
          if slot < 0 or slot >= result.document.pages.len: continue
          let (prepared, report) = raster.preprocess(
            if opts.preprocess.isSome: opts.preprocess.get
            else: documentProfile())
          if report.quality.isBlank:
            result.document.pages[slot].text = ""
            continue
          let ocr = runOcrStage(result, prepared, ikPdf, opts, pageNo - 1)
          if ocr.isSome:
            var o = ocr.get
            o.deskewAngle = report.deskewAngle
            result.document.pages[slot].ocr = some(o)
            result.document.pages[slot].text = o.text
          result.document.pages[slot].width = raster.width
          result.document.pages[slot].height = raster.height

        # Quality is reported for the first page that was actually rasterised;
        # a whole-document figure would be meaningless.
        if rendered.len > 0:
          result.quality = measureQuality(rendered[0].image)

    let ocrPages = plan.sourceByPage.count(psNeedsOcr)
    if ocrPages > 0 and not opts.runOcr:
      result.addWarning($ocrPages & " page(s) have no text layer and OCR was " &
        "not requested")

  if opts.runVlm:
    timeStage(result, stVlm):
      var images: seq[VlmImage]
      var documents: seq[VlmDocument]
      if opts.sendPdfNatively and opts.vlm.provider == vpAnthropic:
        # The Anthropic API reads PDFs directly, which preserves vector text
        # and avoids a rasterisation round trip entirely.
        try:
          documents.add VlmDocument(data: readFile(path),
                                    fileName: path.extractFilename())
        except IOError as e:
          result.addWarning("could not read the PDF for the VLM: " & e.msg)
      else:
        let wanted =
          if plan.info.pageCount == 0: @[1]
          else: toSeq(plan.first .. min(plan.last,
                                        plan.first + opts.maxVlmImages - 1))
        try:
          for (_, raster) in renderPages(path, wanted, opts.pdf.renderDpi,
                                         opts.pdf):
            images.add encodeForVlm(raster, opts.vlm.maxImageSide)
        except CatchableError as e:
          result.addWarning("could not render pages for the VLM: " & e.msg)
        if plan.info.pageCount > opts.maxVlmImages:
          result.addWarning("only the first " & $opts.maxVlmImages &
            " page(s) were sent to the model")
      runVlmStage(result, opts, images, documents, result.document.text)

  result.totalMs = (epochTime() - started) * 1000.0

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

proc analyzeBytes*(data: openArray[byte]; source = "<memory>";
                   opts = defaultAnalyzeOptions()): AnalysisResult =
  ## Analyses any supported input from memory. PDFs are staged to a temporary
  ## file because every PDF tool works on paths.
  let fmt = detectFormat(data)
  if fmt == sfPdf:
    let tmp = getTempDir() / "v3era-in-" & $getCurrentProcessId() & "-" &
      $int(epochTime() * 1000) & ".pdf"
    writeFile(tmp, cast[string](@data))
    defer: discard tryRemoveFile(tmp)
    result = analyzePdf(tmp, opts)
    result.source = source
    result.document.source = source
  else:
    result = analyzeImageBytes(data, source, opts)

proc analyzeFile*(path: string;
                  opts = defaultAnalyzeOptions()): AnalysisResult =
  ## Analyses a file on disk, routing on content rather than extension.
  if not fileExists(path):
    raiseImage("no such file: " & path)
  let size = getFileSize(path)
  if size <= 0:
    raiseImage("file is empty: " & path)

  # Sniff from a small prefix so a 200 MB PDF is not read twice.
  var head = newString(min(1024, int(size)))
  block:
    let f = open(path, fmRead)
    defer: f.close()
    discard f.readBuffer(addr head[0], head.len)

  if detectFormat(head) == sfPdf:
    analyzePdf(path, opts)
  else:
    analyzeImageBytes(toOpenArrayByte(readFile(path), 0, int(size) - 1),
                      path, opts)

proc markdown*(res: AnalysisResult; withTables = true): string =
  ## The document's text as Markdown, using layout structure where OCR
  ## provided it and falling back to the plain text layer otherwise.
  for i, page in res.document.pages:
    if i > 0: result.add "\n\n---\n\n"
    if page.ocr.isSome:
      result.add page.ocr.get.toMarkdown(withTables)
    else:
      result.add page.text
  result = result.strip() & "\n"
