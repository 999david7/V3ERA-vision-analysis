## Tesseract 4/5 bindings through the C API (`capi.h`).
##
## The library is resolved with `dlopen` at first use rather than linked, and
## rather than via Nim's `{.dynlib.}` pragma. Both alternatives abort the
## process at startup when libtesseract is absent, which is unacceptable here:
## OCR is one optional stage of several, and a deployment that only runs the
## VLM path must not need Tesseract installed at all. Missing library, missing
## language data and a failed init all surface as `CapabilityError`, which the
## orchestrator turns into a warning on the result.
##
## Only the C API is used. Tesseract's C++ API has no stable ABI, and binding
## it would tie this build to one compiler and one libstdc++.

import std/[dynlib, locks, os, strutils, times, math]

import ../core/[types, errors, log]

# ---------------------------------------------------------------------------
# C API constants
# ---------------------------------------------------------------------------

type
  PageSegMode* = enum
    psmOsdOnly = 0
    psmAutoOsd = 1
    psmAutoOnly = 2
    psmAuto = 3                 ## Full layout analysis. The default.
    psmSingleColumn = 4
    psmSingleBlockVertText = 5
    psmSingleBlock = 6          ## One uniform block; right for a cropped field.
    psmSingleLine = 7
    psmSingleWord = 8
    psmCircleWord = 9
    psmSingleChar = 10
    psmSparseText = 11          ## Scattered text; right for screenshots and UI.
    psmSparseTextOsd = 12
    psmRawLine = 13

  OcrEngineMode* = enum
    oemTesseractOnly = 0
    oemLstmOnly = 1             ## Neural only: best quality on modern traineddata.
    oemTesseractLstmCombined = 2
    oemDefault = 3

  IteratorLevel = enum
    rilBlock = 0
    rilPara = 1
    rilTextline = 2
    rilWord = 3
    rilSymbol = 4

  PolyBlockType = enum
    ptUnknown = 0
    ptFlowingText = 1
    ptHeadingText = 2
    ptPulloutText = 3
    ptEquation = 4
    ptInlineEquation = 5
    ptTable = 6
    ptVerticalText = 7
    ptCaptionText = 8
    ptFlowingImage = 9
    ptHeadingImage = 10
    ptPulloutImage = 11
    ptHorzLine = 12
    ptVertLine = 13
    ptNoise = 14

# ---------------------------------------------------------------------------
# Dynamic symbol table
# ---------------------------------------------------------------------------

type
  TessApi = distinct pointer
  TessResultIter = distinct pointer
  TessPageIter = distinct pointer

  TessSyms = object
    version: proc (): cstring {.cdecl, gcsafe, raises: [].}
    create: proc (): TessApi {.cdecl, gcsafe, raises: [].}
    delete: proc (h: TessApi) {.cdecl, gcsafe, raises: [].}
    init2: proc (h: TessApi; datapath, language: cstring;
                 oem: cint): cint {.cdecl, gcsafe, raises: [].}
    setImage: proc (h: TessApi; data: ptr byte; w, h2, bpp, bpl: cint)
      {.cdecl, gcsafe, raises: [].}
    setSourceResolution: proc (h: TessApi; ppi: cint) {.cdecl, gcsafe, raises: [].}
    setPageSegMode: proc (h: TessApi; mode: cint) {.cdecl, gcsafe, raises: [].}
    setVariable: proc (h: TessApi; name, value: cstring): cint
      {.cdecl, gcsafe, raises: [].}
    recognize: proc (h: TessApi; monitor: pointer): cint
      {.cdecl, gcsafe, raises: [].}
    getUtf8Text: proc (h: TessApi): cstring {.cdecl, gcsafe, raises: [].}
    meanTextConf: proc (h: TessApi): cint {.cdecl, gcsafe, raises: [].}
    getIterator: proc (h: TessApi): TessResultIter {.cdecl, gcsafe, raises: [].}
    clear: proc (h: TessApi) {.cdecl, gcsafe, raises: [].}
    deleteText: proc (t: cstring) {.cdecl, gcsafe, raises: [].}
    iterDelete: proc (it: TessResultIter) {.cdecl, gcsafe, raises: [].}
    iterGetPageIterator: proc (it: TessResultIter): TessPageIter
      {.cdecl, gcsafe, raises: [].}
    iterGetUtf8Text: proc (it: TessResultIter; level: cint): cstring
      {.cdecl, gcsafe, raises: [].}
    iterConfidence: proc (it: TessResultIter; level: cint): cfloat
      {.cdecl, gcsafe, raises: [].}
    pageBegin: proc (it: TessPageIter) {.cdecl, gcsafe, raises: [].}
    pageNext: proc (it: TessPageIter; level: cint): cint
      {.cdecl, gcsafe, raises: [].}
    pageIsAtBeginningOf: proc (it: TessPageIter; level: cint): cint
      {.cdecl, gcsafe, raises: [].}
    pageBoundingBox: proc (it: TessPageIter; level: cint;
                           left, top, right, bottom: ptr cint): cint
      {.cdecl, gcsafe, raises: [].}
    pageBlockType: proc (it: TessPageIter): cint {.cdecl, gcsafe, raises: [].}

const candidateLibs =
  when defined(windows):
    ["libtesseract-5.dll", "libtesseract-4.dll", "tesseract54.dll",
     "tesseract53.dll", "libtesseract.dll"]
  elif defined(macosx):
    ["libtesseract.5.dylib", "libtesseract.4.dylib", "libtesseract.dylib",
     "/opt/homebrew/lib/libtesseract.dylib", "/usr/local/lib/libtesseract.dylib"]
  else:
    ["libtesseract.so.5", "libtesseract.so.4", "libtesseract.so"]

var
  gLock: Lock
  gLoaded = false
  gHandle: LibHandle = nil
  gSyms: TessSyms
  gLoadError = ""
  gLibPath = ""

gLock.initLock()

proc bindSym(h: LibHandle; name: string; missing: var seq[string]): pointer =
  result = symAddr(h, name)
  if result == nil:
    missing.add name

proc tryLoad(): bool =
  ## Caller must hold `gLock`.
  if gLoaded: return gHandle != nil

  gLoaded = true
  var tried: seq[string]

  # An explicit override wins: distributions and containers put the library in
  # places no default list can anticipate.
  var names: seq[string]
  let envPath = getEnv("V3ERA_TESSERACT_LIB", "")
  if envPath.len > 0: names.add envPath
  for n in candidateLibs: names.add n

  for name in names:
    let h = loadLib(name)
    if h != nil:
      gHandle = h
      gLibPath = name
      break
    tried.add name

  if gHandle == nil:
    gLoadError = "could not load libtesseract (tried: " & tried.join(", ") &
      "). Install the runtime library (Debian/Ubuntu: libtesseract5 or " &
      "libtesseract-dev; macOS: brew install tesseract) or point " &
      "V3ERA_TESSERACT_LIB at it."
    return false

  var missing: seq[string]
  template b(field, sym: untyped) =
    gSyms.field = cast[typeof(gSyms.field)](bindSym(gHandle, sym, missing))

  b(version, "TessVersion")
  b(create, "TessBaseAPICreate")
  b(delete, "TessBaseAPIDelete")
  b(init2, "TessBaseAPIInit2")
  b(setImage, "TessBaseAPISetImage")
  b(setSourceResolution, "TessBaseAPISetSourceResolution")
  b(setPageSegMode, "TessBaseAPISetPageSegMode")
  b(setVariable, "TessBaseAPISetVariable")
  b(recognize, "TessBaseAPIRecognize")
  b(getUtf8Text, "TessBaseAPIGetUTF8Text")
  b(meanTextConf, "TessBaseAPIMeanTextConf")
  b(getIterator, "TessBaseAPIGetIterator")
  b(clear, "TessBaseAPIClear")
  b(deleteText, "TessDeleteText")
  b(iterDelete, "TessResultIteratorDelete")
  b(iterGetPageIterator, "TessResultIteratorGetPageIterator")
  b(iterGetUtf8Text, "TessResultIteratorGetUTF8Text")
  b(iterConfidence, "TessResultIteratorConfidence")
  b(pageBegin, "TessPageIteratorBegin")
  b(pageNext, "TessPageIteratorNext")
  b(pageIsAtBeginningOf, "TessPageIteratorIsAtBeginningOf")
  b(pageBoundingBox, "TessPageIteratorBoundingBox")
  b(pageBlockType, "TessPageIteratorBlockType")

  if missing.len > 0:
    unloadLib(gHandle)
    gHandle = nil
    gLoadError = "loaded " & gLibPath & " but it is missing " &
      $missing.len & " expected symbol(s): " & missing.join(", ") &
      ". This usually means the library is not Tesseract 4 or newer."
    return false

  log.debug("libtesseract loaded", {"path": gLibPath, "version": $gSyms.version()})
  true

proc tesseractAvailable*(): bool =
  ## Whether libtesseract can be loaded. Safe to call repeatedly; the result is
  ## cached after the first attempt.
  withLock gLock:
    result = tryLoad()

proc tesseractVersion*(): string =
  ## Version string, or "" when the library is unavailable.
  withLock gLock:
    if not tryLoad(): return ""
    result = $gSyms.version()

proc tesseractLoadError*(): string =
  withLock gLock:
    discard tryLoad()
    result = gLoadError

# ---------------------------------------------------------------------------
# Recognition
# ---------------------------------------------------------------------------

type
  TesseractOptions* = object
    language*: string      ## Tesseract language code(s), e.g. "eng" or "eng+deu".
    dataPath*: string      ## tessdata directory; empty uses TESSDATA_PREFIX.
    pageSegMode*: PageSegMode
    engineMode*: OcrEngineMode
    dpi*: int              ## Source resolution hint; 0 lets Tesseract guess.
    minWordConfidence*: float32 ## Words below this are dropped.
    variables*: seq[(string, string)] ## Raw config variables.

func defaultTesseractOptions*(): TesseractOptions =
  TesseractOptions(
    language: "eng", pageSegMode: psmAuto, engineMode: oemLstmOnly,
    minWordConfidence: 30.0)

func toBlockKind(pt: PolyBlockType): BlockKind =
  case pt
  of ptHeadingText, ptHeadingImage: bkHeading
  of ptTable: bkTable
  of ptCaptionText: bkCaption
  of ptFlowingText, ptPulloutText, ptVerticalText: bkParagraph
  else: bkUnknown

proc takeText(p: cstring): string =
  ## Copies a Tesseract-owned string and releases it.
  if p == nil: return ""
  result = $p
  gSyms.deleteText(p)

proc grayForTesseract(img: Image): Image =
  ## Tesseract wants 8-bit gray with a stride equal to the width, which is
  ## exactly this project's `Image` invariant, so no repacking is needed.
  if img.channels == 1:
    return img
  # Local luma conversion, avoiding a dependency on the preprocess layer (which
  # would make the module graph cyclic: preprocess -> ocr -> preprocess).
  result = newImage(img.width, img.height, pkGray, img.dpi)
  for i in 0 ..< img.width * img.height:
    let p = i * img.channels
    if img.channels >= 3:
      result.data[i] = byte((19595 * img.data[p].int +
                             38470 * img.data[p + 1].int +
                             7471 * img.data[p + 2].int) shr 16)
    else:
      result.data[i] = img.data[p]

proc recognizePage*(img: Image; opts = defaultTesseractOptions();
                    pageIndex = 0): OcrPage =
  ## Runs Tesseract over `img` and returns blocks, lines and word boxes.
  ##
  ## Raises `CapabilityError` when the library or language data is unavailable,
  ## and `OcrError` when recognition itself fails.
  if img.isEmpty:
    raise newException(OcrError, "cannot OCR an empty image")

  let started = epochTime()
  var gray = grayForTesseract(img)

  withLock gLock:
    if not tryLoad():
      raise newCapabilityError("tesseract", gLoadError)

    let api = gSyms.create()
    if pointer(api) == nil:
      raise newException(OcrError, "TessBaseAPICreate returned NULL")
    defer:
      gSyms.clear(api)
      gSyms.delete(api)

    let dataPath: cstring =
      if opts.dataPath.len > 0: opts.dataPath.cstring else: nil
    if gSyms.init2(api, dataPath, opts.language.cstring,
                   cint(ord(opts.engineMode))) != 0:
      raise newCapabilityError("tessdata",
        "Tesseract could not initialise for language '" & opts.language &
        "'. Install the language data (Debian/Ubuntu: tesseract-ocr-" &
        opts.language & ") or set TESSDATA_PREFIX / dataPath to the directory " &
        "containing " & opts.language & ".traineddata.")

    for (k, v) in opts.variables:
      if gSyms.setVariable(api, k.cstring, v.cstring) == 0:
        log.warn("tesseract rejected a config variable",
                 {"name": k, "value": v})

    gSyms.setPageSegMode(api, cint(ord(opts.pageSegMode)))

    gSyms.setImage(api, cast[ptr byte](addr gray.data[0]), cint(gray.width),
                   cint(gray.height), 1, cint(gray.width))

    # Must follow SetImage -- Tesseract discards a resolution set before the
    # image and falls back to estimating one, which it warns about on stderr
    # and which skews its point-size and heading classification.
    let dpi = if opts.dpi > 0: opts.dpi elif gray.dpi > 0: gray.dpi else: 300
    gSyms.setSourceResolution(api, cint(dpi))

    if gSyms.recognize(api, nil) != 0:
      raise newException(OcrError, "Tesseract recognition failed")

    result = OcrPage(
      index: pageIndex, width: gray.width, height: gray.height,
      engine: "tesseract-" & $gSyms.version(),
      meanConfidence: float32(gSyms.meanTextConf(api)))

    let it = gSyms.getIterator(api)
    if pointer(it) == nil:
      # No iterator means no recognised text -- a blank page, not an error.
      result.durationMs = (epochTime() - started) * 1000.0
      return
    defer: gSyms.iterDelete(it)

    let pit = gSyms.iterGetPageIterator(it) # borrowed; must not be deleted
    gSyms.pageBegin(pit)

    # Nim forbids closures over `result`, so blocks accumulate in a local and
    # are moved onto the page once the walk finishes.
    var blocks: seq[OcrBlock]
    var block1: OcrBlock
    var line: OcrLine
    var haveBlock = false
    var haveLine = false

    proc boxOf(level: IteratorLevel): BBox =
      var l, t, r, b: cint
      if gSyms.pageBoundingBox(pit, cint(ord(level)), addr l, addr t, addr r,
                               addr b) == 0:
        return bbox(0, 0, 0, 0)
      bbox(int(l), int(t), int(r - l), int(b - t))

    proc flushLine() =
      if haveLine and line.words.len > 0:
        for i, w in line.words:
          if i > 0: line.text.add ' '
          line.text.add w.text
        var conf = 0.0
        for w in line.words: conf += w.confidence.float
        line.confidence = float32(conf / line.words.len.float)
        block1.lines.add line
      haveLine = false
      line = OcrLine()

    proc flushBlock() =
      flushLine()
      if haveBlock and block1.lines.len > 0:
        blocks.add block1
      haveBlock = false
      block1 = OcrBlock()

    # Walk at word level, using the "is at beginning of" predicates to detect
    # line and block transitions. This is the documented way to reconstruct
    # structure from the C API, which exposes no tree.
    while true:
      if gSyms.pageIsAtBeginningOf(pit, cint(ord(rilBlock))) != 0:
        flushBlock()
        block1 = OcrBlock(
          kind: toBlockKind(PolyBlockType(gSyms.pageBlockType(pit))),
          box: boxOf(rilBlock))
        haveBlock = true

      if gSyms.pageIsAtBeginningOf(pit, cint(ord(rilTextline))) != 0:
        flushLine()
        line = OcrLine(box: boxOf(rilTextline))
        haveLine = true

      let raw = takeText(gSyms.iterGetUtf8Text(it, cint(ord(rilWord))))
      let word = raw.strip()
      if word.len > 0:
        let conf = float32(gSyms.iterConfidence(it, cint(ord(rilWord))))
        if conf >= opts.minWordConfidence:
          if not haveBlock:
            block1 = OcrBlock(kind: bkUnknown, box: boxOf(rilBlock))
            haveBlock = true
          if not haveLine:
            line = OcrLine(box: boxOf(rilTextline))
            haveLine = true
          line.words.add OcrWord(text: word, box: boxOf(rilWord),
                                 confidence: conf)

      if gSyms.pageNext(pit, cint(ord(rilWord))) == 0:
        break

    flushBlock()
    result.blocks = move(blocks)

  result.durationMs = (epochTime() - started) * 1000.0
  log.debug("tesseract page recognised", {
    "page": $pageIndex,
    "blocks": $result.blocks.len,
    "words": $result.wordCount,
    "conf": formatFloat(result.meanConfidence.float, ffDecimal, 1),
    "ms": formatFloat(result.durationMs, ffDecimal, 1)})

proc recognizeText*(img: Image; opts = defaultTesseractOptions()): string =
  ## Plain-text convenience wrapper. Cheaper than `recognizePage` because it
  ## skips the iterator walk entirely.
  if img.isEmpty: return ""
  var gray = grayForTesseract(img)
  withLock gLock:
    if not tryLoad():
      raise newCapabilityError("tesseract", gLoadError)
    let api = gSyms.create()
    if pointer(api) == nil:
      raise newException(OcrError, "TessBaseAPICreate returned NULL")
    defer:
      gSyms.clear(api)
      gSyms.delete(api)
    let dataPath: cstring =
      if opts.dataPath.len > 0: opts.dataPath.cstring else: nil
    if gSyms.init2(api, dataPath, opts.language.cstring,
                   cint(ord(opts.engineMode))) != 0:
      raise newCapabilityError("tessdata",
        "Tesseract could not initialise for language '" & opts.language & "'")
    gSyms.setPageSegMode(api, cint(ord(opts.pageSegMode)))
    gSyms.setImage(api, cast[ptr byte](addr gray.data[0]), cint(gray.width),
                   cint(gray.height), 1, cint(gray.width))
    let dpi = if opts.dpi > 0: opts.dpi elif gray.dpi > 0: gray.dpi else: 300
    gSyms.setSourceResolution(api, cint(dpi))
    result = takeText(gSyms.getUtf8Text(api)).strip()
