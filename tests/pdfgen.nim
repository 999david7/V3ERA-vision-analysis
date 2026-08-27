## Builds small, standards-valid PDFs in memory.
##
## The document tests need real PDFs -- with a real text layer, real page
## boxes and a real cross-reference table -- but checking binary fixtures into
## the repository makes them opaque and unmaintainable. Generating them keeps
## every byte of the test input visible in source.
##
## Only base-14 fonts are used, so no font programme has to be embedded.

import std/strutils

proc escapePdfString(s: string): string =
  for c in s:
    case c
    of '(', ')', '\\': result.add '\\' & c
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    else: result.add c

proc textPdf*(pages: openArray[seq[string]]; fontSize = 18;
              pageWidth = 612; pageHeight = 792): string =
  ## One page per outer element, one line of text per inner element.
  doAssert pages.len > 0, "a PDF needs at least one page"

  # Object numbering: 1 = catalog, 2 = page tree, 3 = font,
  # then two objects per page (page dict, content stream).
  let firstPageObj = 4
  var objects: seq[string]

  proc addObj(body: string) =
    objects.add body

  var kids: seq[string]
  for i in 0 ..< pages.len:
    kids.add $(firstPageObj + i * 2) & " 0 R"

  addObj "<< /Type /Catalog /Pages 2 0 R >>"
  addObj "<< /Type /Pages /Kids [" & kids.join(" ") & "] /Count " &
    $pages.len & " >>"
  addObj "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " &
    "/Encoding /WinAnsiEncoding >>"

  for i, lines in pages:
    let contentObj = firstPageObj + i * 2 + 1
    addObj "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " & $pageWidth &
      " " & $pageHeight & "] /Resources << /Font << /F1 3 0 R >> >> " &
      "/Contents " & $contentObj & " 0 R >>"

    var stream = "BT\n/F1 " & $fontSize & " Tf\n" & $(fontSize + 8) & " TL\n"
    stream.add "72 " & $(pageHeight - 90) & " Td\n"
    for line in lines:
      stream.add "(" & escapePdfString(line) & ") Tj T*\n"
    stream.add "ET\n"
    addObj "<< /Length " & $stream.len & " >>\nstream\n" & stream & "endstream"

  # Serialise, recording each object's byte offset for the xref table.
  result = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"
  var offsets = newSeq[int](objects.len + 1)
  for i, body in objects:
    offsets[i + 1] = result.len
    result.add $(i + 1) & " 0 obj\n" & body & "\nendobj\n"

  let xrefStart = result.len
  result.add "xref\n0 " & $(objects.len + 1) & "\n"
  result.add "0000000000 65535 f \n"
  for i in 1 .. objects.len:
    result.add align($offsets[i], 10, '0') & " 00000 n \n"
  result.add "trailer\n<< /Size " & $(objects.len + 1) &
    " /Root 1 0 R >>\nstartxref\n" & $xrefStart & "\n%%EOF\n"

proc simpleTextPdf*(lines: openArray[string]; fontSize = 18): string =
  textPdf([@lines], fontSize)
