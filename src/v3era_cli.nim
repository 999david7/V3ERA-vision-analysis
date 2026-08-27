## `v3era` -- the command-line entry point.
##
## Reads images and PDFs, runs the pipeline, and writes JSON, Markdown or plain
## text. Designed to compose: results go to stdout, diagnostics go to stderr, so
## `v3era analyze page.png --format json | jq` behaves.

import std/[os, strutils, parseopt, json, options]

import v3era

const usage = """
v3era -- vision analysis for screenshots, photos, diagrams, scans and PDFs

USAGE
  v3era <command> [options] <input>...

COMMANDS
  analyze <input>...   Full pipeline: classify, preprocess, OCR, optional VLM
  ocr <input>...       OCR only; prints recognised text
  text <input>...      Extract text, preferring a PDF's own text layer
  classify <input>...  Report the detected input kind and the evidence for it
  preprocess <input>   Write the preprocessed image (see --out)
  info <input>...      Container, geometry and quality metrics
  capabilities         Report which optional dependencies are available

OUTPUT
  -f, --format=FMT     json | markdown | text   (default: text)
  -o, --out=PATH       Write to PATH instead of stdout
      --pretty         Indent JSON output
      --boxes          Include per-word boxes in JSON (verbose)

PIPELINE
  -k, --kind=KIND      Force the input kind: screenshot | photo | diagram |
                       scanned_document | pdf   (default: auto-detect)
      --no-ocr         Skip OCR
      --no-layout      Skip layout analysis (reading order, headings, tables)
      --psm=N          Tesseract page-segmentation mode (0-13)
  -l, --lang=CODE      OCR language, e.g. eng, deu, eng+fra   (default: eng)
      --dpi=N          Source resolution hint for OCR
      --binarize=MODE  none | otsu | sauvola
      --max-dim=N      Cap the longest side after preprocessing

PDF
      --pages=A-B      Page range, 1-based and inclusive
      --render-dpi=N   Rasterisation DPI for pages needing OCR (default: 200)

VISION MODEL
      --vlm            Send the input to a vision-language model
      --task=TASK      describe | transcribe | extract_fields |
                       describe_diagram | summarize | screenshot
      --prompt=TEXT    Custom prompt (implies --vlm, disables the task schema)
      --model=NAME     Override the model
      --effort=LEVEL   low | medium | high | xhigh | max
      --no-thinking    Disable adaptive thinking

GENERAL
  -v, --verbose        Debug logging on stderr
  -q, --quiet          Errors only
      --version        Version and capability report
  -h, --help           This message

ENVIRONMENT
  ANTHROPIC_API_KEY    API key for the default (Anthropic) backend
  V3ERA_VLM_PROVIDER   anthropic | openai      (openai = any compatible server)
  V3ERA_VLM_MODEL      Model name
  V3ERA_VLM_BASE_URL   API base URL
  V3ERA_LOG_LEVEL      debug | info | warn | error
  V3ERA_LOG_FORMAT     text | json
  V3ERA_TESSERACT_LIB  Explicit path to libtesseract

EXAMPLES
  v3era analyze scan.pdf --format markdown
  v3era ocr receipt.jpg --lang eng
  v3era analyze diagram.png --vlm --task describe_diagram --format json --pretty
  v3era analyze form.pdf --vlm --task extract_fields --pretty
  v3era classify *.png
"""

type
  OutputFormat = enum
    ofText, ofJson, ofMarkdown

  CliOptions = object
    command: string
    inputs: seq[string]
    format: OutputFormat
    outPath: string
    pretty: bool
    boxes: bool
    analyze: AnalyzeOptions
    maxDim: int
    binarize: Option[BinarizeMode]

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine "v3era: " & msg
  stderr.writeLine "Try 'v3era --help' for usage."
  quit(2)

proc parseKind(s: string): InputKind =
  case s.toLowerAscii().replace('-', '_')
  of "screenshot": ikScreenshot
  of "photo": ikPhoto
  of "diagram": ikDiagram
  of "scanned_document", "scan", "document": ikScannedDocument
  of "pdf": ikPdf
  of "auto", "": ikUnknown
  else: fail("unknown input kind: " & s)

proc parseTask(s: string): VisionTask =
  case s.toLowerAscii().replace('-', '_')
  of "describe": vtDescribe
  of "transcribe": vtTranscribe
  of "extract_fields", "extract": vtExtractFields
  of "describe_diagram", "diagram": vtDescribeDiagram
  of "summarize", "summarise": vtSummarize
  of "screenshot": vtScreenshotAnalysis
  else: fail("unknown task: " & s)

proc parseEffortLevel(s: string): Effort =
  case s.toLowerAscii()
  of "low": efLow
  of "medium": efMedium
  of "high": efHigh
  of "xhigh": efXhigh
  of "max": efMax
  else: fail("unknown effort level: " & s)

proc parseFormat(s: string): OutputFormat =
  case s.toLowerAscii()
  of "text", "txt": ofText
  of "json": ofJson
  of "markdown", "md": ofMarkdown
  else: fail("unknown output format: " & s)

proc parsePageRange(s: string): tuple[first, last: int] =
  let parts = s.split('-')
  try:
    if parts.len == 1:
      let n = parseInt(parts[0].strip())
      return (n, n)
    elif parts.len == 2:
      let a = parts[0].strip()
      let b = parts[1].strip()
      return ((if a.len > 0: parseInt(a) else: 0),
              (if b.len > 0: parseInt(b) else: 0))
  except ValueError: discard
  fail("could not parse a page range from '" & s & "' (expected N or A-B)")

proc parseCli(): CliOptions =
  result.format = ofText
  result.analyze = optionsFromEnv()

  # parseopt only treats the next argument as an option's value when the option
  # is not listed as valueless, so both `--format json` and `--format=json`
  # work. Getting this list wrong silently swallows the next argument.
  const
    longNoVal = @["help", "version", "verbose", "quiet", "pretty", "boxes",
                  "no-ocr", "no-layout", "vlm", "no-thinking"]
    shortNoVal = {'h', 'v', 'q'}

  var p = initOptParser(commandLineParams(), shortNoVal = shortNoVal,
                        longNoVal = longNoVal)
  var positional: seq[string]
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      positional.add p.key
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        echo usage
        quit(0)
      of "version":
        stdout.write describeCapabilities()
        quit(0)
      of "v", "verbose": setLogLevel(lvlDebug)
      of "q", "quiet": setLogLevel(lvlError)
      of "f", "format": result.format = parseFormat(p.val)
      of "o", "out": result.outPath = p.val
      of "pretty": result.pretty = true
      of "boxes": result.boxes = true
      of "k", "kind": result.analyze.kind = parseKind(p.val)
      of "no-ocr": result.analyze.runOcr = false
      of "no-layout": result.analyze.runLayout = false
      of "l", "lang": result.analyze.ocr.language = p.val
      of "dpi":
        try: result.analyze.ocr.dpi = parseInt(p.val)
        except ValueError: fail("--dpi expects a number")
      of "psm":
        try:
          let n = parseInt(p.val)
          if n < 0 or n > 13: fail("--psm expects 0-13")
          result.analyze.ocr.pageSegMode = PageSegMode(n)
        except ValueError: fail("--psm expects a number")
      of "binarize":
        case p.val.toLowerAscii()
        of "none": result.binarize = some(bmNone)
        of "otsu": result.binarize = some(bmOtsu)
        of "sauvola": result.binarize = some(bmSauvola)
        else: fail("--binarize expects none, otsu or sauvola")
      of "max-dim":
        try: result.maxDim = parseInt(p.val)
        except ValueError: fail("--max-dim expects a number")
      of "pages":
        let (a, b) = parsePageRange(p.val)
        result.analyze.pdf.firstPage = a
        result.analyze.pdf.lastPage = b
      of "render-dpi":
        try: result.analyze.pdf.renderDpi = parseInt(p.val)
        except ValueError: fail("--render-dpi expects a number")
      of "vlm": result.analyze.runVlm = true
      of "task":
        result.analyze.vlmTask = parseTask(p.val)
        result.analyze.runVlm = true
      of "prompt":
        result.analyze.vlmPrompt = p.val
        result.analyze.runVlm = true
      of "model": result.analyze.vlm.model = p.val
      of "effort": result.analyze.vlm.effort = parseEffortLevel(p.val)
      of "no-thinking": result.analyze.vlm.thinking = tmOff
      else:
        fail("unknown option: --" & p.key)

  if positional.len == 0:
    echo usage
    quit(1)
  result.command = positional[0]
  result.inputs = positional[1 .. ^1]

proc effectivePreprocess(o: CliOptions; kind: InputKind): PreprocessConfig =
  result = profileFor(kind)
  if o.binarize.isSome: result.binarize = o.binarize.get
  if o.maxDim > 0: result.maxDimension = o.maxDim

proc applyOverrides(o: var CliOptions) =
  ## Materialises the preprocessing overrides once a kind is known. Only set
  ## when the user actually asked for something, so the per-kind profiles stay
  ## in charge by default.
  if o.binarize.isSome or o.maxDim > 0:
    o.analyze.preprocess = some(effectivePreprocess(o, o.analyze.kind))

proc emit(o: CliOptions; content: string) =
  if o.outPath.len > 0:
    writeFile(o.outPath, content)
    stderr.writeLine "wrote " & o.outPath & " (" & $content.len & " bytes)"
  else:
    stdout.write content
    if content.len > 0 and not content.endsWith("\n"):
      stdout.write "\n"

proc renderResult(o: CliOptions; res: AnalysisResult): string =
  case o.format
  of ofJson:
    let node = res.toJson(includeOcr = true, includeWords = o.boxes)
    if o.pretty: node.pretty() else: $node
  of ofMarkdown:
    res.markdown()
  of ofText:
    res.document.text

proc printHumanSummary(res: AnalysisResult) =
  ## The one-line-per-input summary that goes to stderr in text mode, so stdout
  ## stays pipeable.
  var parts = @[
    "kind=" & $res.kind,
    "format=" & $res.format,
    "pages=" & $res.document.pages.len,
    "ms=" & formatFloat(res.totalMs, ffDecimal, 0)]
  var words = 0
  for p in res.document.pages:
    if p.ocr.isSome: words += p.ocr.get.wordCount
  if words > 0: parts.add "words=" & $words
  if res.vlm.isSome:
    parts.add "vlm_tokens=" & $res.vlm.get.usage.totalTokens
  stderr.writeLine "  " & res.source & ": " & parts.join(" ")
  for w in res.warnings:
    stderr.writeLine "  warning: " & w

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

proc cmdAnalyze(o: var CliOptions): int =
  applyOverrides(o)
  var results: seq[AnalysisResult]
  for input in o.inputs:
    try:
      let res = analyzeFile(input, o.analyze)
      results.add res
      if o.format == ofText:
        printHumanSummary(res)
    except V3eraError as e:
      stderr.writeLine "v3era: " & input & ": " & e.msg
      result = 1
    except OSError as e:
      stderr.writeLine "v3era: " & input & ": " & e.msg
      result = 1

  if results.len == 0: return max(result, 1)

  if o.format == ofJson and results.len > 1:
    var arr = newJArray()
    for r in results:
      arr.add r.toJson(includeOcr = true, includeWords = o.boxes)
    emit(o, if o.pretty: arr.pretty() else: $arr)
  else:
    var chunks: seq[string]
    for r in results:
      chunks.add renderResult(o, r)
    emit(o, chunks.join(if o.format == ofMarkdown: "\n\n---\n\n" else: "\n"))

proc cmdOcr(o: var CliOptions): int =
  o.analyze.runOcr = true
  o.analyze.runVlm = false
  applyOverrides(o)
  var chunks: seq[string]
  for input in o.inputs:
    try:
      let res = analyzeFile(input, o.analyze)
      for w in res.warnings:
        stderr.writeLine "v3era: " & input & ": " & w
      chunks.add(
        if o.format == ofMarkdown: res.markdown()
        elif o.format == ofJson:
          let n = res.toJson(includeOcr = true, includeWords = o.boxes)
          (if o.pretty: n.pretty() else: $n)
        else: res.document.text)
    except V3eraError as e:
      stderr.writeLine "v3era: " & input & ": " & e.msg
      result = 1
  if chunks.len > 0:
    emit(o, chunks.join("\n"))

proc cmdText(o: var CliOptions): int =
  ## Text extraction that prefers a PDF's own text layer and only OCRs the
  ## pages without one -- the fast path for digital documents.
  applyOverrides(o)
  var chunks: seq[string]
  for input in o.inputs:
    try:
      let res = analyzeFile(input, o.analyze)
      chunks.add res.document.text
      for w in res.warnings:
        stderr.writeLine "v3era: " & input & ": " & w
    except V3eraError as e:
      stderr.writeLine "v3era: " & input & ": " & e.msg
      result = 1
  if chunks.len > 0:
    emit(o, chunks.join("\n\n"))

proc cmdClassify(o: CliOptions): int =
  var arr = newJArray()
  for input in o.inputs:
    try:
      let img = loadImage(input)
      let c = classify.classify(img)
      let s = c.signals
      if o.format == ofJson:
        arr.add %*{
          "source": input,
          "kind": $c.kind,
          "confidence": c.confidence,
          "rationale": c.rationale,
          "signals": {
            "flat_run_ratio": s.flatRunRatio,
            "unique_color_ratio": s.uniqueColorRatio,
            "colorfulness": s.colorfulness,
            "background_ratio": s.backgroundRatio,
            "border_background_ratio": s.borderBackgroundRatio,
            "ink_coverage": s.inkCoverage,
            "text_line_score": s.textLineScore,
            "text_band_count": s.textBandCount,
            "median_band_height": s.medianBandHeight,
            "band_regularity": s.bandRegularity,
            "sharpness": s.sharpness,
            "aspect": s.aspect}}
      else:
        echo input, ": ", c.kind, "  (confidence ",
          formatFloat(c.confidence, ffDecimal, 2), " -- ", c.rationale, ")"
        echo "    flat_runs=", formatFloat(s.flatRunRatio, ffDecimal, 3),
          " unique_colors=", formatFloat(s.uniqueColorRatio, ffDecimal, 3),
          " background=", formatFloat(s.backgroundRatio, ffDecimal, 3),
          " border_bg=", formatFloat(s.borderBackgroundRatio, ffDecimal, 3),
          " ink=", formatFloat(s.inkCoverage, ffDecimal, 4),
          " bands=", $s.textBandCount,
          "/h", $s.medianBandHeight,
          "/reg", formatFloat(s.bandRegularity, ffDecimal, 2)
    except V3eraError as e:
      stderr.writeLine "v3era: " & input & ": " & e.msg
      result = 1
  if o.format == ofJson:
    emit(o, if o.pretty: arr.pretty() else: $arr)

proc cmdPreprocess(o: CliOptions): int =
  if o.inputs.len != 1:
    fail("preprocess takes exactly one input")
  let input = o.inputs[0]
  let outPath =
    if o.outPath.len > 0: o.outPath
    else: input.changeFileExt("") & ".preprocessed.pnm"
  try:
    let img = loadImage(input)
    let kind =
      if o.analyze.kind != ikUnknown: o.analyze.kind
      else: classify.classify(img).kind
    let (prepared, report) = img.preprocess(effectivePreprocess(o, kind))
    prepared.saveImage(outPath)
    stderr.writeLine "kind=" & $kind & " stages=" & report.applied.join(",")
    stderr.writeLine $report.inputWidth & "x" & $report.inputHeight & " -> " &
      $report.outputWidth & "x" & $report.outputHeight
    echo outPath
  except V3eraError as e:
    stderr.writeLine "v3era: " & input & ": " & e.msg
    return 1

proc cmdInfo(o: CliOptions): int =
  var arr = newJArray()
  for input in o.inputs:
    try:
      let raw = readFile(input)
      let fmt = detectFormat(raw)
      var node = %*{"source": input, "format": $fmt,
                    "bytes": raw.len}
      if fmt == sfPdf:
        let info = probePdf(input)
        node["pages"] = %info.pageCount
        node["title"] = %info.title
        node["producer"] = %info.producer
        node["encrypted"] = %info.encrypted
        node["pdf_version"] = %info.version
      else:
        let img = loadImage(input)
        node["width"] = %img.width
        node["height"] = %img.height
        node["channels"] = %img.channels
        node["quality"] = measureQuality(img).toJson()
      if o.format == ofJson:
        arr.add node
      else:
        echo input, ": ", node.pretty()
    except V3eraError as e:
      stderr.writeLine "v3era: " & input & ": " & e.msg
      result = 1
  if o.format == ofJson:
    emit(o, if o.pretty: arr.pretty() else: $arr)

proc cmdCapabilities(o: CliOptions): int =
  if o.format == ofJson:
    let n = capabilities().toJson()
    emit(o, if o.pretty: n.pretty() else: $n)
  else:
    stdout.write describeCapabilities()

# ---------------------------------------------------------------------------

proc main(): int =
  initLogFromEnv()
  var o = parseCli()

  if o.command != "capabilities" and o.inputs.len == 0:
    fail("'" & o.command & "' needs at least one input file")

  case o.command
  of "analyze", "analyse": cmdAnalyze(o)
  of "ocr": cmdOcr(o)
  of "text": cmdText(o)
  of "classify": cmdClassify(o)
  of "preprocess": cmdPreprocess(o)
  of "info": cmdInfo(o)
  of "capabilities", "caps": cmdCapabilities(o)
  else:
    fail("unknown command: " & o.command)

when isMainModule:
  try:
    quit(main())
  except V3eraError as e:
    stderr.writeLine "v3era: " & e.msg
    quit(1)
  except IOError as e:
    stderr.writeLine "v3era: " & e.msg
    quit(1)
