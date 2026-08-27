## PDF tests.
##
## Cases that need poppler or mupdf are skipped (loudly) when neither is
## installed, so the suite is green on a machine without them and still proves
## the integration where they exist.

import std/[unittest, os, strutils, sequtils]

import ../src/v3era/core/[types, errors]
import ../src/v3era/docparse/pdf
import ../src/v3era/util/exec
import ./pdfgen

let toolchainPresent = hasCommand("pdftoppm") or hasCommand("mutool")

var tmpDir: string

proc setupDir(): string =
  if tmpDir.len == 0:
    tmpDir = getTempDir() / "v3era-pdf-tests-" & $getCurrentProcessId()
    createDir(tmpDir)
  tmpDir

proc writePdf(name: string; content: string): string =
  result = setupDir() / name
  writeFile(result, content)

suite "pdf header parsing":
  test "the version is read from the header":
    check parsePdfHeader(toOpenArrayByte("%PDF-1.7\nrest", 0, 12)) == "1.7"
    check parsePdfHeader(toOpenArrayByte("%PDF-2.0\n", 0, 8)) == "2.0"

  test "a non-PDF stream returns no version":
    check parsePdfHeader(toOpenArrayByte("not a pdf", 0, 8)) == ""
    check parsePdfHeader(toOpenArrayByte("%PD", 0, 2)) == ""

suite "page range resolution":
  let info = PdfInfo(pageCount: 20)

  test "an unset range covers the whole document":
    check resolveRange(info, defaultPdfOptions()) == (1, 20)

  test "an explicit range is honoured":
    var o = defaultPdfOptions()
    o.firstPage = 3
    o.lastPage = 7
    check resolveRange(info, o) == (3, 7)

  test "a range past the end is clamped":
    var o = defaultPdfOptions()
    o.firstPage = 15
    o.lastPage = 999
    check resolveRange(info, o) == (15, 20)

  test "maxPages caps the span":
    var o = defaultPdfOptions()
    o.maxPages = 5
    check resolveRange(info, o) == (1, 5)

  test "an inverted range collapses instead of going negative":
    var o = defaultPdfOptions()
    o.firstPage = 10
    o.lastPage = 2
    let (first, last) = resolveRange(info, o)
    check first <= last

suite "generated PDF fixtures":
  test "the generator produces a structurally valid PDF":
    let pdf = simpleTextPdf(["Hello world"])
    check pdf.startsWith("%PDF-1.4")
    check pdf.endsWith("%%EOF\n")
    check "xref" in pdf
    check "/Type /Catalog" in pdf
    check "startxref" in pdf

  test "multi-page documents declare the right page count":
    let pdf = textPdf([@["page one"], @["page two"], @["page three"]])
    check "/Count 3" in pdf

suite "pdf toolchain":
  test "the summary names whichever tools are installed":
    let summary = pdfSupportSummary()
    if toolchainPresent:
      check summary != "none"
    else:
      check summary == "none"

  test "asking for a missing backend raises a CapabilityError":
    if not hasCommand("mutool"):
      expect CapabilityError:
        discard availableBackend(pbMuPdf)
    else:
      check availableBackend(pbMuPdf) == pbMuPdf

if not toolchainPresent:
  echo "  [skipped] PDF integration tests: no poppler or mupdf on PATH"
else:
  suite "pdf metadata":
    test "the page count is read back":
      let path = writePdf("three.pdf",
        textPdf([@["one"], @["two"], @["three"]]))
      let info = probePdf(path)
      check info.pageCount == 3
      check info.version.startsWith("1.")
      check not info.encrypted

    test "page geometry is reported in points":
      let path = writePdf("letter.pdf", simpleTextPdf(["x"]))
      let info = probePdf(path)
      check abs(info.widthPt - 612.0) < 1.0
      check abs(info.heightPt - 792.0) < 1.0

    test "a missing file is a DocumentError":
      expect DocumentError:
        discard probePdf(setupDir() / "definitely-not-here.pdf")

    test "a file that is not a PDF is rejected by the header check":
      let path = writePdf("fake.pdf", "this is plain text, not a PDF at all")
      expect DocumentError:
        discard probePdf(path)

  suite "text layer":
    test "text is extracted per page without rendering anything":
      let path = writePdf("layers.pdf", textPdf([
        @["Alpha page content"],
        @["Beta page content"]]))
      let info = probePdf(path)
      let pages = extractTextLayer(path, info)
      check pages.len == 2
      check "Alpha" in pages[0]
      check "Beta" in pages[1]
      check "Beta" notin pages[0]

    test "a page range limits what is extracted":
      let path = writePdf("range.pdf", textPdf([
        @["one"], @["two"], @["three"], @["four"]]))
      var o = defaultPdfOptions()
      o.firstPage = 2
      o.lastPage = 3
      let pages = extractTextLayer(path, probePdf(path, o), o)
      check pages.len == 2
      check "two" in pages[0]
      check "three" in pages[1]

  suite "planning":
    test "a digital PDF needs no OCR at all":
      let path = writePdf("digital.pdf", simpleTextPdf([
        "The quick brown fox jumps over the lazy dog",
        "and then keeps going for a while longer."]))
      let plan = planPdf(path)
      check plan.info.pageCount == 1
      check plan.sourceByPage == @[psTextLayer]
      check plan.pagesNeedingOcr().len == 0

    test "a page with too little text is routed to OCR":
      # One glyph is below minTextLayerChars, which is what a scanned page's
      # residual text layer looks like.
      let path = writePdf("sparse.pdf", simpleTextPdf(["x"]))
      let plan = planPdf(path)
      check plan.sourceByPage == @[psNeedsOcr]
      check plan.pagesNeedingOcr() == @[1]

    test "mixed documents are split page by page":
      let path = writePdf("mixed.pdf", textPdf([
        @["This page has a full and genuine text layer on it."],
        @["."],
        @["This third page also has plenty of real text content."]]))
      let plan = planPdf(path)
      check plan.sourceByPage == @[psTextLayer, psNeedsOcr, psTextLayer]
      check plan.pagesNeedingOcr() == @[2]

    test "the resulting document carries only text-layer content":
      let path = writePdf("doc.pdf", textPdf([
        @["Page one has real text on it, plenty of it."],
        @["."]]))
      let doc = planPdf(path).toDocument(path)
      check doc.format == sfPdf
      check doc.pages.len == 2
      check doc.pages[0].fromTextLayer
      check "Page one" in doc.pages[0].text
      check not doc.pages[1].fromTextLayer
      check doc.pages[1].text == ""

  suite "rendering":
    test "a page rasterises at the requested resolution":
      let path = writePdf("render.pdf", simpleTextPdf(["Rendered content"]))
      let img = renderPage(path, 1, 150)
      # US Letter at 150 DPI is 1275x1650.
      check img.width == 1275
      check img.height == 1650
      check img.dpi == 150
      check img.channels == 1

    test "several pages render in one invocation, in order":
      let path = writePdf("multi.pdf", textPdf([
        @["one"], @["two"], @["three"]]))
      let pages = renderPages(path, [1, 2, 3], 72)
      check pages.len == 3
      check pages.mapIt(it.page) == @[1, 2, 3]
      for p in pages:
        check not p.image.isEmpty

    test "rendering respects DPI proportionally":
      let path = writePdf("dpi.pdf", simpleTextPdf(["x"]))
      check renderPage(path, 1, 72).width == 612
      check renderPage(path, 1, 144).width == 1224
