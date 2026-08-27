## PDF ingestion.
##
## A PDF is two documents in one: a text layer (present in anything produced
## digitally) and a set of pages that can be rasterised. Extracting the text
## layer costs milliseconds and is exact; rendering and OCRing costs seconds and
## introduces errors. So the rule here is: **use the text layer when there is
## one, and OCR only the pages where there is not.** Mixed documents -- a
## digital report with a scanned annex -- are the common case, so the decision
## is made per page rather than per file.
##
## Rendering and text extraction are delegated to poppler (`pdftoppm`,
## `pdftotext`, `pdfinfo`) or mupdf (`mutool`), invoked as subprocesses rather
## than linked. Linking poppler-glib would drag in GLib and a large ABI surface
## for what is fundamentally a batch operation, and the CLI tools are the
## interface those projects actually keep stable.

import std/[os, strutils, times, algorithm, sequtils, sets]

import ../core/[types, errors, log]
import ../imageio/io
import ../util/exec

type
  PdfBackend* = enum
    pbAuto = "auto"
    pbPoppler = "poppler"
    pbMuPdf = "mupdf"

  PdfInfo* = object
    pageCount*: int
    title*, author*, creator*, producer*: string
    encrypted*: bool
    version*: string
    widthPt*, heightPt*: float

  PdfOptions* = object
    backend*: PdfBackend
    renderDpi*: int      ## Rasterisation resolution for pages needing OCR.
    firstPage*: int      ## 1-based, inclusive. 0 means "from the first".
    lastPage*: int       ## 1-based, inclusive. 0 means "to the last".
    maxPages*: int       ## Safety cap on how many pages are processed.
    timeoutMs*: int
    minTextLayerChars*: int
      ## A page whose text layer yields fewer characters than this is treated
      ## as image-only and sent to OCR. Digital pages typically yield hundreds;
      ## a scanned page yields zero, or a handful of stray marks that some
      ## producers leave behind.

func defaultPdfOptions*(): PdfOptions =
  PdfOptions(backend: pbAuto, renderDpi: 200, maxPages: 200,
             timeoutMs: 120_000, minTextLayerChars: 24)

# ---------------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------------

proc availableBackend*(preferred = pbAuto): PdfBackend =
  ## Resolves `pbAuto` to whichever toolchain is installed, preferring poppler
  ## for its more precise text-layer extraction. Raises `CapabilityError` when
  ## neither is present.
  let havePoppler = hasCommand("pdftoppm") and hasCommand("pdftotext")
  let haveMuPdf = hasCommand("mutool")
  case preferred
  of pbPoppler:
    if not havePoppler:
      raise newCapabilityError("poppler",
        "pdftoppm/pdftotext not found on PATH (Debian/Ubuntu: apt install " &
        "poppler-utils; macOS: brew install poppler)")
    pbPoppler
  of pbMuPdf:
    if not haveMuPdf:
      raise newCapabilityError("mupdf",
        "mutool not found on PATH (Debian/Ubuntu: apt install mupdf-tools)")
    pbMuPdf
  of pbAuto:
    if havePoppler: pbPoppler
    elif haveMuPdf: pbMuPdf
    else:
      raise newCapabilityError("pdf",
        "no PDF toolchain found. Install poppler-utils (preferred) or " &
        "mupdf-tools. Without one, PDFs cannot be rendered or read.")

proc pdfSupportSummary*(): string =
  ## Human-readable capability line for `--version` and `/healthz`.
  var parts: seq[string]
  if hasCommand("pdftoppm"): parts.add "pdftoppm"
  if hasCommand("pdftotext"): parts.add "pdftotext"
  if hasCommand("pdfinfo"): parts.add "pdfinfo"
  if hasCommand("mutool"): parts.add "mutool"
  if parts.len == 0: "none" else: parts.join(", ")

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

proc parsePdfHeader*(data: openArray[byte]): string =
  ## Reads the `%PDF-x.y` version from the first bytes. Returns "" when the
  ## stream is not a PDF at all.
  if data.len < 8: return ""
  for i in 0 ..< 5:
    if data[i] != byte("%PDF-"[i]): return ""
  var v = ""
  var i = 5
  while i < data.len and i < 12 and char(data[i]) in {'0' .. '9', '.'}:
    v.add char(data[i])
    inc i
  v

proc probePdf*(path: string; opts = defaultPdfOptions()): PdfInfo =
  ## Reads page count and metadata. Falls back to a structural scan when
  ## `pdfinfo` is unavailable.
  if not fileExists(path):
    raiseDocument("no such PDF: " & path)

  let head = readFile(path)[0 ..< min(1024, int(getFileSize(path)))]
  result.version = parsePdfHeader(toOpenArrayByte(head, 0, head.high))
  if result.version.len == 0:
    raiseDocument(path & " does not begin with a %PDF- header")

  if hasCommand("pdfinfo"):
    let r = runCommand("pdfinfo", ["-enc", "UTF-8", path], opts.timeoutMs)
    if r.exitCode == 0:
      for line in r.output.splitLines():
        let sep = line.find(':')
        if sep < 0: continue
        let key = line[0 ..< sep].strip()
        let value = line[sep + 1 .. ^1].strip()
        case key
        of "Pages":
          try: result.pageCount = parseInt(value)
          except ValueError: discard
        of "Title": result.title = value
        of "Author": result.author = value
        of "Creator": result.creator = value
        of "Producer": result.producer = value
        of "Encrypted": result.encrypted = not value.startsWith("no")
        of "Page size":
          # "612 x 792 pts (letter)"
          let parts = value.split(' ')
          if parts.len >= 3:
            try:
              result.widthPt = parseFloat(parts[0])
              result.heightPt = parseFloat(parts[2])
            except ValueError: discard
        else: discard
    elif r.output.contains("Command Line Error: Incorrect password"):
      result.encrypted = true

  if result.pageCount == 0 and hasCommand("mutool"):
    let r = runCommand("mutool", ["info", path], opts.timeoutMs)
    if r.exitCode == 0:
      for line in r.output.splitLines():
        if line.startsWith("Pages:"):
          try: result.pageCount = parseInt(line[6 .. ^1].strip())
          except ValueError: discard

  if result.pageCount == 0:
    # Last resort: count page objects in the raw file. This misses documents
    # that compress their object streams, hence the ordering.
    let raw = readFile(path)
    var n = 0
    var i = 0
    while true:
      let hit = raw.find("/Type", i)
      if hit < 0: break
      let after = raw[hit + 5 ..< min(raw.len, hit + 20)].strip()
      if after.startsWith("/Page") and not after.startsWith("/Pages"):
        inc n
      i = hit + 5
    result.pageCount = n

  if result.pageCount <= 0:
    raiseDocument("could not determine the page count of " & path)

# ---------------------------------------------------------------------------
# Page range
# ---------------------------------------------------------------------------

func resolveRange*(info: PdfInfo; opts: PdfOptions): tuple[first, last: int] =
  ## Clamps the requested 1-based page range to what the document has and to
  ## `maxPages`.
  var first = if opts.firstPage > 0: opts.firstPage else: 1
  var last = if opts.lastPage > 0: opts.lastPage else: info.pageCount
  first = max(1, min(first, info.pageCount))
  last = max(first, min(last, info.pageCount))
  if opts.maxPages > 0 and last - first + 1 > opts.maxPages:
    last = first + opts.maxPages - 1
  (first, last)

# ---------------------------------------------------------------------------
# Text layer
# ---------------------------------------------------------------------------

proc extractTextLayer*(path: string; info: PdfInfo;
                       opts = defaultPdfOptions()): seq[string] =
  ## Returns one string per page in the resolved range, empty where the page
  ## has no text layer. Never raises for a page without text -- that is the
  ## signal to OCR it, not an error.
  let (first, last) = resolveRange(info, opts)
  result = newSeq[string](last - first + 1)

  let backend = availableBackend(opts.backend)
  let tmp = getTempDir() / "v3era-text-" & $getCurrentProcessId() & "-" &
    $int(epochTime() * 1000) & ".txt"
  defer: discard tryRemoveFile(tmp)

  try:
    case backend
    of pbPoppler, pbAuto:
      # -layout keeps column structure, which matters for tables and forms.
      # The form feed that pdftotext writes between pages is what splits them.
      discard runChecked("pdftotext",
        ["-layout", "-enc", "UTF-8", "-f", $first, "-l", $last, path, tmp],
        opts.timeoutMs)
    of pbMuPdf:
      discard runChecked("mutool",
        ["draw", "-F", "txt", "-o", tmp, path, $first & "-" & $last],
        opts.timeoutMs)
  except ExecError as e:
    log.warn("text-layer extraction failed; pages will be OCRed",
             {"path": path, "error": e.msg})
    return

  if not fileExists(tmp): return
  let raw = readFile(tmp)
  let pages = raw.split('\f')
  for i in 0 ..< result.len:
    if i < pages.len:
      result[i] = pages[i].strip(leading = false, trailing = true)

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc renderPages*(path: string; pageNumbers: openArray[int]; dpi: int;
                  opts = defaultPdfOptions()): seq[tuple[page: int; image: Image]] =
  ## Rasterises the given 1-based page numbers. Renders to a temporary
  ## directory as PGM, which the native decoder reads without needing stb --
  ## so PDF OCR works in a build with no vendored C at all.
  if pageNumbers.len == 0: return

  let backend = availableBackend(opts.backend)
  let dir = getTempDir() / "v3era-render-" & $getCurrentProcessId() & "-" &
    $int(epochTime() * 1000)
  createDir(dir)
  defer:
    try: removeDir(dir)
    except OSError: discard

  # Render the whole contiguous span in one invocation: process startup
  # dominates for short pages, and poppler parses the document once.
  var sorted = @pageNumbers
  sorted.sort()
  let first = sorted[0]
  let last = sorted[^1]

  case backend
  of pbPoppler, pbAuto:
    discard runChecked("pdftoppm",
      ["-r", $dpi, "-gray", "-f", $first, "-l", $last, path, dir / "p"],
      opts.timeoutMs)
  of pbMuPdf:
    discard runChecked("mutool",
      ["draw", "-r", $dpi, "-c", "gray", "-o", dir / "p-%d.pgm", path,
       $first & "-" & $last],
      opts.timeoutMs)

  let wanted = sorted.toHashSet()
  var found: seq[tuple[page: int; image: Image]]
  for file in walkFiles(dir / "p*"):
    # Both tools name output "<prefix>-<n>.<ext>", zero-padded by poppler.
    let stem = file.splitFile().name
    let dash = stem.rfind('-')
    if dash < 0: continue
    var num = 0
    try: num = parseInt(stem[dash + 1 .. ^1])
    except ValueError: continue
    if num notin wanted: continue
    var img = loadImage(file)
    img.dpi = dpi
    found.add (page: num, image: img)

  found.sort(proc (a, b: tuple[page: int; image: Image]): int =
    cmp(a.page, b.page))
  if found.len == 0:
    raiseDocument("the PDF renderer produced no pages for " & path)
  found

proc renderPage*(path: string; pageNumber: int; dpi: int;
                 opts = defaultPdfOptions()): Image =
  let pages = renderPages(path, [pageNumber], dpi, opts)
  if pages.len == 0:
    raiseDocument("page " & $pageNumber & " could not be rendered")
  pages[0].image

# ---------------------------------------------------------------------------
# Document assembly
# ---------------------------------------------------------------------------

type
  PageSource* = enum
    psTextLayer = "text_layer"
    psNeedsOcr = "needs_ocr"

  PdfPlan* = object
    ## The per-page decision, made once so the caller can render only what it
    ## must and report the split.
    info*: PdfInfo
    first*, last*: int
    textByPage*: seq[string]
    sourceByPage*: seq[PageSource]

proc planPdf*(path: string; opts = defaultPdfOptions()): PdfPlan =
  ## Reads metadata and the text layer, then decides which pages need OCR.
  result.info = probePdf(path, opts)
  if result.info.encrypted:
    raiseDocument(path & " is encrypted; decrypt it before analysis")

  let (first, last) = resolveRange(result.info, opts)
  result.first = first
  result.last = last
  result.textByPage = extractTextLayer(path, result.info, opts)
  result.sourceByPage = newSeq[PageSource](result.textByPage.len)

  for i, text in result.textByPage:
    # Count only glyphs: a scanned page's "text layer" is often a handful of
    # newlines and spaces left by the producer, which a raw length test would
    # mistake for content.
    var glyphs = 0
    for c in text:
      if c notin {' ', '\t', '\n', '\r', '\f'}: inc glyphs
    result.sourceByPage[i] =
      if glyphs >= opts.minTextLayerChars: psTextLayer else: psNeedsOcr

  log.info("PDF planned", {
    "path": path,
    "pages": $(last - first + 1),
    "text_layer": $result.sourceByPage.count(psTextLayer),
    "needs_ocr": $result.sourceByPage.count(psNeedsOcr)})

proc pagesNeedingOcr*(plan: PdfPlan): seq[int] =
  ## 1-based page numbers that must be rendered and recognised.
  for i, src in plan.sourceByPage:
    if src == psNeedsOcr:
      result.add plan.first + i

proc toDocument*(plan: PdfPlan; path: string): Document =
  ## Builds a `Document` from the text-layer pages alone. Callers that own an
  ## OCR engine fill in the remaining pages; `pipeline/analyze.nim` does this.
  result = Document(
    source: path, format: sfPdf, pageCount: plan.info.pageCount,
    title: plan.info.title, producer: plan.info.producer)
  for i, text in plan.textByPage:
    result.pages.add PageContent(
      index: plan.first + i - 1,
      text: (if plan.sourceByPage[i] == psTextLayer: text else: ""),
      fromTextLayer: plan.sourceByPage[i] == psTextLayer)
