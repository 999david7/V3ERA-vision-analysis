import std/[unittest, strutils, sequtils]

import ../src/v3era/core/types
import ../src/v3era/docparse/layout

proc word(text: string; x, y, w, h: int; conf = 90.0): OcrWord =
  OcrWord(text: text, box: bbox(x, y, w, h), confidence: float32(conf))

proc line(text: string; x, y, w, h: int; words: seq[OcrWord] = @[]): OcrLine =
  OcrLine(text: text, box: bbox(x, y, w, h), confidence: 90.0, words: words)

proc blk(kind: BlockKind; lines: seq[OcrLine]): OcrBlock =
  result = OcrBlock(kind: kind, lines: lines)
  for l in lines:
    result.box = union(result.box, l.box)

suite "line grouping":
  test "words on one baseline become one line, ordered left to right":
    let words = @[
      word("world", 120, 10, 60, 18),
      word("Hello", 10, 12, 55, 18)]
    let lines = groupWordsIntoLines(words)
    check lines.len == 1
    check lines[0].text == "Hello world"
    check lines[0].box.x == 10

  test "vertically separated words become separate lines":
    let words = @[
      word("first", 10, 10, 50, 18),
      word("second", 10, 60, 60, 18)]
    let lines = groupWordsIntoLines(words)
    check lines.len == 2
    check lines[0].text == "first"
    check lines[1].text == "second"

  test "differing glyph heights on one line still group":
    # An ascender-tall word next to an x-height word: their boxes differ in
    # height but overlap almost completely.
    let words = @[
      word("Tall", 10, 8, 40, 24),
      word("xx", 60, 16, 20, 12)]
    check groupWordsIntoLines(words).len == 1

  test "no words gives no lines":
    check groupWordsIntoLines(@[]).len == 0

  test "line confidence averages its words":
    let words = @[word("a", 0, 0, 10, 10, 80.0), word("b", 20, 0, 10, 10, 60.0)]
    check abs(groupWordsIntoLines(words)[0].confidence.float - 70.0) < 0.01

suite "reading order":
  test "a single column reads top to bottom":
    var page = OcrPage(width: 600, height: 800)
    page.blocks = @[
      blk(bkParagraph, @[line("third", 50, 500, 500, 20)]),
      blk(bkParagraph, @[line("first", 50, 100, 500, 20)]),
      blk(bkParagraph, @[line("second", 50, 300, 500, 20)])]
    let ordered = page.inReadingOrder()
    check ordered.blocks.mapIt(it.lines[0].text) == @["first", "second", "third"]

  test "two columns read fully down the left before the right":
    var page = OcrPage(width: 1000, height: 800)
    page.blocks = @[
      blk(bkParagraph, @[line("R1", 560, 100, 380, 20)]),
      blk(bkParagraph, @[line("L1", 60, 100, 380, 20)]),
      blk(bkParagraph, @[line("R2", 560, 400, 380, 20)]),
      blk(bkParagraph, @[line("L2", 60, 400, 380, 20)])]
    check page.detectColumnSplits().len == 1
    check page.inReadingOrder().blocks.mapIt(it.lines[0].text) ==
      @["L1", "L2", "R1", "R2"]

  test "no gutter is found in a full-width layout":
    var page = OcrPage(width: 1000, height: 400)
    page.blocks = @[
      blk(bkParagraph, @[line("wide", 20, 20, 960, 20)]),
      blk(bkParagraph, @[line("also wide", 20, 200, 960, 20)])]
    check page.detectColumnSplits().len == 0

  test "reading order on an empty page is empty":
    check OcrPage(width: 100, height: 100).inReadingOrder().blocks.len == 0

suite "textual cues":
  test "bullets and enumerations read as list items":
    check looksLikeListItem("- first point")
    check looksLikeListItem("* another")
    check looksLikeListItem("• unicode bullet")
    check looksLikeListItem("1. numbered")
    check looksLikeListItem("2) parenthesised")
    check looksLikeListItem("(a) lettered")

  test "prose that merely starts with a number is not a list item":
    check not looksLikeListItem("2024 was a difficult year")
    check not looksLikeListItem("Ordinary sentence.")
    check not looksLikeListItem("-")

  test "headings are short, unpunctuated and prominent":
    check looksLikeHeading("QUARTERLY REPORT")
    check looksLikeHeading("Executive Summary")
    check not looksLikeHeading("This is an ordinary sentence of body text.")
    check not looksLikeHeading("")

suite "block classification":
  test "a large short line becomes a heading and body text does not":
    var page = OcrPage(width: 600, height: 800)
    page.blocks = @[
      blk(bkParagraph, @[line("Annual Report", 50, 40, 300, 40)]),
      blk(bkParagraph, @[
        line("The company performed well over the period under", 50, 120, 500, 20),
        line("review, with revenue increasing across all units.", 50, 150, 500, 20)])]
    page.refineBlockKinds()
    check page.blocks[0].kind == bkHeading
    check page.blocks[1].kind == bkParagraph

  test "a block of bullets becomes a list":
    var page = OcrPage(width: 600, height: 800)
    page.blocks = @[
      blk(bkParagraph, @[
        line("- alpha", 50, 100, 200, 20),
        line("- beta", 50, 130, 200, 20)]),
      blk(bkParagraph, @[line("Body text that runs on for a while.", 50, 200, 400, 20)])]
    page.refineBlockKinds()
    check page.blocks[0].kind == bkListItem

  test "kinds already set by the OCR engine are left alone":
    var page = OcrPage(width: 600, height: 800)
    page.blocks = @[blk(bkTable, @[line("a b", 10, 10, 100, 20)])]
    page.refineBlockKinds()
    check page.blocks[0].kind == bkTable

suite "tables":
  test "aligned columns are recovered as a table":
    var rows: seq[OcrLine]
    let cols = [40, 240, 440]
    for r in 0 ..< 4:
      let y = 100 + r * 30
      var words: seq[OcrWord]
      for c, x in cols:
        words.add word("c" & $c & "r" & $r, x, y, 120, 20)
      rows.add line("", cols[0], y, 520, 20, words)
    var page = OcrPage(width: 600, height: 800, blocks: @[blk(bkParagraph, rows)])

    let tables = page.detectTables()
    check tables.len == 1
    check tables[0].columnEdges.len == 3
    check tables[0].rows.len == 4
    check tables[0].rows[0].cells[0].text == "c0r0"
    check tables[0].rows[3].cells[2].text == "c2r3"

  test "ragged prose is not mistaken for a table":
    var rows: seq[OcrLine]
    for r in 0 ..< 5:
      let y = 100 + r * 30
      var words: seq[OcrWord]
      var x = 40 + r * 17 # every line starts somewhere different
      for c in 0 ..< 4:
        words.add word("w", x, y, 60, 20)
        x += 70 + r * 5
      rows.add line("", 40, y, 500, 20, words)
    var page = OcrPage(width: 600, height: 800, blocks: @[blk(bkParagraph, rows)])
    check page.detectTables().len == 0

  test "a table renders as a GitHub pipe table":
    var rows: seq[OcrLine]
    let headers = ["Item", "Qty", "Price"]
    let values = ["Widget", "3", "9.99"]
    for r in 0 ..< 3:
      let y = 100 + r * 30
      var words: seq[OcrWord]
      for c, x in [40, 240, 440]:
        words.add word((if r == 0: headers[c] else: values[c]), x, y, 120, 20)
      rows.add line("", 40, y, 520, 20, words)
    var page = OcrPage(width: 600, height: 800, blocks: @[blk(bkParagraph, rows)])

    let md = page.detectTables()[0].toMarkdown()
    let lines = md.strip().splitLines()
    check lines[0] == "| Item | Qty | Price |"
    check lines[1] == "| --- | --- | --- |"
    check lines[2] == "| Widget | 3 | 9.99 |"

suite "markdown rendering":
  test "headings, lists and paragraphs each get their own syntax":
    var page = OcrPage(width: 600, height: 800)
    page.blocks = @[
      blk(bkHeading, @[line("Title", 50, 40, 200, 40)]),
      blk(bkParagraph, @[line("Some body text.", 50, 120, 400, 20)]),
      blk(bkListItem, @[line("- one", 50, 200, 200, 20),
                        line("- two", 50, 230, 200, 20)])]
    let md = page.toMarkdown(withTables = false)
    check "## Title" in md
    check "Some body text." in md
    check "- - one" notin md # the OCR'd bullet is not doubled
    check "- one" in md
    check "- two" in md

  test "an empty page renders to just a newline":
    check OcrPage(width: 10, height: 10).toMarkdown(withTables = true).strip() == ""

  test "analyzeLayout orders, classifies and promotes in one pass":
    var rows: seq[OcrLine]
    for r in 0 ..< 4:
      let y = 300 + r * 30
      var words: seq[OcrWord]
      for c, x in [40, 240, 440]:
        words.add word("v", x, y, 120, 20)
      rows.add line("v v v", 40, y, 520, 20, words)

    var page = OcrPage(width: 600, height: 800)
    page.blocks = @[
      blk(bkParagraph, rows),
      blk(bkParagraph, @[line("REPORT", 50, 40, 200, 40)])]

    let analysed = page.analyzeLayout()
    check analysed.blocks[0].kind == bkHeading # reordered to the top
    check analysed.blocks[1].kind == bkTable
    check "| v | v | v |" in analysed.toMarkdown(withTables = true)

suite "page-level helpers":
  test "medianLineHeight ignores a single outlier":
    var page = OcrPage(width: 600, height: 800)
    page.blocks = @[blk(bkParagraph, @[
      line("a", 0, 0, 100, 20),
      line("b", 0, 30, 100, 20),
      line("c", 0, 60, 100, 20),
      line("huge", 0, 90, 100, 200)])]
    check page.medianLineHeight() == 20.0

  test "text and word counts aggregate across blocks":
    var page = OcrPage(width: 600, height: 800)
    page.blocks = @[
      blk(bkParagraph, @[line("one two", 0, 0, 100, 20,
                              @[word("one", 0, 0, 40, 20),
                                word("two", 50, 0, 40, 20)])]),
      blk(bkParagraph, @[line("three", 0, 40, 100, 20,
                              @[word("three", 0, 40, 60, 20)])])]
    check page.wordCount == 3
    check page.text == "one two\n\nthree"
