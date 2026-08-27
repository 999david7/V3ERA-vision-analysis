## Layout analysis over recognised word boxes.
##
## OCR gives text and geometry but very little structure: Tesseract labels a
## block "flowing text" whether it is a title, a bullet list or a table row.
## This module recovers the structure that downstream consumers actually need
## -- reading order across columns, heading level, list items and tabular
## alignment -- from geometry plus light textual cues.
##
## Everything is heuristic, and deliberately conservative: mislabelling a
## paragraph as a heading is worse than leaving it a paragraph, because the
## error propagates into whatever the text feeds next.

import std/[algorithm, strutils, math, sequtils, unicode]

import ../core/types

# ---------------------------------------------------------------------------
# Line geometry
# ---------------------------------------------------------------------------

proc groupWordsIntoLines*(words: seq[OcrWord];
                          overlapThreshold = 0.5): seq[OcrLine] =
  ## Groups loose word boxes into lines. Needed for OCR backends that report
  ## words without structure, and for re-flowing after a crop.
  ##
  ## Words join a line when their vertical extents overlap by more than
  ## `overlapThreshold` of the shorter box, which tolerates the height
  ## differences between "x" and "Ë†lj" far better than a baseline comparison.
  if words.len == 0: return

  var sorted = words
  sorted.sort(proc (a, b: OcrWord): int =
    result = cmp(a.box.y, b.box.y)
    if result == 0: result = cmp(a.box.x, b.box.x))

  var current: seq[OcrWord]
  var currentBox = BBox()

  proc flush(acc: var seq[OcrLine]; items: var seq[OcrWord]; box: BBox) =
    if items.len == 0: return
    items.sort(proc (a, b: OcrWord): int = cmp(a.box.x, b.box.x))
    var line = OcrLine(box: box, words: items)
    var conf = 0.0
    for i, w in items:
      if i > 0: line.text.add ' '
      line.text.add w.text
      conf += w.confidence.float
    line.confidence = float32(conf / items.len.float)
    acc.add line
    items = @[]

  for w in sorted:
    if current.len == 0:
      current.add w
      currentBox = w.box
    elif verticalOverlap(currentBox, w.box) >= overlapThreshold:
      current.add w
      currentBox = union(currentBox, w.box)
    else:
      flush(result, current, currentBox)
      current.add w
      currentBox = w.box
  flush(result, current, currentBox)

func medianLineHeight*(page: OcrPage): float =
  ## Median text-line height, the yardstick every other threshold is measured
  ## against. Using the median rather than the mean keeps a single oversized
  ## title from moving the scale.
  var heights: seq[int]
  for blk in page.blocks:
    for ln in blk.lines:
      if ln.box.h > 0: heights.add ln.box.h
  if heights.len == 0: return 0.0
  heights.sort()
  heights[heights.len div 2].float

# ---------------------------------------------------------------------------
# Reading order
# ---------------------------------------------------------------------------

proc detectColumnSplits*(page: OcrPage; minGapRatio = 0.06): seq[int] =
  ## Finds x-coordinates where a full-height vertical gutter separates columns.
  ##
  ## Works on the horizontal coverage profile: a column boundary is a run of x
  ## positions that no block spans, wide enough to be a gutter rather than
  ## word spacing.
  if page.width <= 0 or page.blocks.len == 0: return

  var covered = newSeq[bool](page.width)
  for blk in page.blocks:
    let b = blk.box.clampTo(page.width, page.height)
    for x in b.x ..< b.right:
      covered[x] = true

  let minGap = max(12, int(page.width.float * minGapRatio))
  var runStart = -1
  for x in 0 ..< page.width:
    if not covered[x]:
      if runStart < 0: runStart = x
    else:
      if runStart >= 0 and x - runStart >= minGap:
        # Ignore gutters touching the margins -- those are just whitespace.
        if runStart > 0 and x < page.width:
          result.add (runStart + x) div 2
      runStart = -1

proc readingOrder*(page: OcrPage): seq[int] =
  ## Indices of `page.blocks` in reading order: column by column, top to
  ## bottom within each. Falls back to plain top-to-bottom for single-column
  ## pages, which is what most documents are.
  result = toSeq(0 ..< page.blocks.len)
  if page.blocks.len <= 1: return

  let splits = detectColumnSplits(page)

  func columnOf(b: BBox): int =
    for i, s in splits:
      if b.centerX < s.float: return i
    splits.len

  let blocks = page.blocks
  result.sort(proc (a, b: int): int =
    if splits.len > 0:
      result = cmp(columnOf(blocks[a].box), columnOf(blocks[b].box))
      if result != 0: return
    result = cmp(blocks[a].box.y, blocks[b].box.y)
    if result == 0: result = cmp(blocks[a].box.x, blocks[b].box.x))

proc inReadingOrder*(page: OcrPage): OcrPage =
  ## A copy of `page` with its blocks reordered.
  result = page
  let order = page.readingOrder()
  result.blocks = @[]
  for i in order:
    result.blocks.add page.blocks[i]

# ---------------------------------------------------------------------------
# Block classification
# ---------------------------------------------------------------------------

func looksLikeListItem*(text: string): bool =
  let t = text.strip()
  if t.len < 2: return false
  for b in listMarkers:
    if t.startsWith(b) and t.len > b.len and t[b.len] in {' ', '\t'}:
      return true
  # Enumerated forms: "1.", "1)", "(a)", "iv." -- require a following space so
  # a decimal number at the start of a sentence is not swept up.
  var i = 0
  if t[0] == '(': i = 1
  let start = i
  while i < t.len and (t[i] in Digits or t[i] in {'a' .. 'z', 'A' .. 'Z'}):
    inc i
    if i - start > 4: return false
  if i == start: return false
  if i < t.len and t[i] in {'.', ')'} and i + 1 < t.len and t[i + 1] == ' ':
    return true
  false

func looksLikeHeading*(text: string): bool =
  ## Textual cues only; the geometric test lives in `refineBlockKinds`.
  let t = text.strip()
  if t.len == 0 or t.len > 120: return false
  if t.countLines() > 2: return false
  # Headings rarely end in sentence punctuation.
  if t[^1] in {'.', ',', ';', ':'} and not t.endsWith("..."): return false

  var letters = 0
  var upper = 0
  for r in t.runes:
    if r.isAlpha:
      inc letters
      if r.isUpper: inc upper
  if letters == 0: return false
  # ALL CAPS, or Title Case in a short line.
  upper.float / letters.float > 0.75 or t.split(' ').len <= 8

proc refineBlockKinds*(page: var OcrPage) =
  ## Upgrades `bkUnknown`/`bkParagraph` blocks to headings and list items using
  ## relative text size and the textual cues above.
  ##
  ## Size is compared against the page's median line height, so the same rule
  ## works at any DPI without a magic pixel constant.
  let median = page.medianLineHeight()
  if median <= 0.0: return

  for blk in page.blocks.mitems:
    if blk.kind notin {bkUnknown, bkParagraph}: continue
    if blk.lines.len == 0: continue

    let body = blk.text
    if blk.lines.allIt(looksLikeListItem(it.text)):
      blk.kind = bkListItem
      continue

    var tallest = 0
    for ln in blk.lines:
      tallest = max(tallest, ln.box.h)

    # A heading is set noticeably larger than body text, *and* reads like one.
    # Requiring both keeps a single tall line of body text -- one with a
    # parenthesis or a capital that overshoots -- from being promoted.
    let oversized = tallest.float > median * 1.35
    if blk.lines.len <= 3 and looksLikeHeading(body) and
       (oversized or blk.lines.len == 1):
      blk.kind = bkHeading
    elif blk.kind == bkUnknown:
      blk.kind = bkParagraph

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

type
  TableCell* = object
    text*: string
    box*: BBox

  TableRow* = object
    cells*: seq[TableCell]
    box*: BBox

  Table* = object
    box*: BBox
    rows*: seq[TableRow]
    columnEdges*: seq[int] ## x positions separating columns.

proc columnEdgesFor(lines: seq[OcrLine]; tolerance: int): seq[int] =
  ## Finds x positions where words consistently start, across lines. Real
  ## columns line up; prose does not.
  if lines.len < 2: return
  var starts: seq[int]
  for ln in lines:
    for w in ln.words:
      starts.add w.box.x
  if starts.len == 0: return
  starts.sort()

  # Cluster the starts, then keep clusters that most lines contribute to.
  var clusters: seq[tuple[centre, count, lineMask: int]]
  var i = 0
  while i < starts.len:
    var j = i
    var sum = 0
    while j < starts.len and starts[j] - starts[i] <= tolerance:
      sum += starts[j]
      inc j
    clusters.add (centre: sum div (j - i), count: j - i, lineMask: 0)
    i = j

  # A column must appear in at least 60% of the lines.
  let need = max(2, (lines.len * 3) div 5)
  for c in clusters:
    if c.count >= need:
      result.add c.centre
  result.sort()

proc detectTables*(page: OcrPage; minRows = 3): seq[Table] =
  ## Finds tabular regions: runs of lines whose words align into at least two
  ## consistent columns.
  ##
  ## Ruling lines are not used. Many real tables have none, and the ones that
  ## do usually align anyway, so alignment alone is both more general and
  ## simpler than trying to detect rules on a binarised page.
  let median = page.medianLineHeight()
  let tolerance = max(6, int(median * 0.6))

  for blk in page.blocks:
    if blk.lines.len < minRows: continue
    let edges = columnEdgesFor(blk.lines, tolerance)
    if edges.len < 2: continue

    var tbl = Table(box: blk.box, columnEdges: edges)
    for ln in blk.lines:
      var row = TableRow(box: ln.box)
      row.cells.setLen(edges.len)
      for i in 0 ..< edges.len:
        row.cells[i] = TableCell()
      for w in ln.words:
        # Assign each word to the rightmost column edge at or left of it.
        var col = 0
        for i, e in edges:
          if w.box.x + tolerance >= e: col = i
        if row.cells[col].text.len > 0: row.cells[col].text.add ' '
        row.cells[col].text.add w.text
        row.cells[col].box = union(row.cells[col].box, w.box)
      tbl.rows.add row
    if tbl.rows.len >= minRows:
      result.add tbl

func toMarkdown*(tbl: Table): string =
  ## GitHub-flavoured pipe table. The first row is taken as the header, which
  ## is right far more often than not for extracted tables.
  if tbl.rows.len == 0: return ""
  let cols = tbl.columnEdges.len

  proc renderRow(r: TableRow): string =
    result = "|"
    for i in 0 ..< cols:
      let cell = if i < r.cells.len: r.cells[i].text.strip() else: ""
      result.add " " & cell.replace("|", "\\|") & " |"

  result = renderRow(tbl.rows[0]) & "\n|"
  for _ in 0 ..< cols:
    result.add " --- |"
  result.add "\n"
  for i in 1 ..< tbl.rows.len:
    result.add renderRow(tbl.rows[i]) & "\n"

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc analyzeLayout*(page: OcrPage): OcrPage =
  ## The full pass: reading order, then block classification, then table
  ## promotion. Returns a new page; the input is untouched.
  result = page.inReadingOrder()
  result.refineBlockKinds()
  let tables = result.detectTables()
  if tables.len > 0:
    # Mark the blocks a table was recovered from, so the Markdown renderer
    # knows to emit a pipe table rather than lines of prose.
    for tbl in tables:
      for blk in result.blocks.mitems:
        if blk.box == tbl.box:
          blk.kind = bkTable

proc toMarkdown*(page: OcrPage; withTables: bool): string =
  ## Markdown for a page, optionally rendering detected tables as pipe tables.
  if not withTables:
    return types.toMarkdown(page)

  let tables = page.detectTables()
  for blk in page.blocks:
    # Tables are rendered from their cells, so they are handled before the
    # empty-body check: a table's *line* text is often blank when the OCR
    # engine reported words without joining them into lines.
    if blk.kind == bkTable:
      var rendered = false
      for tbl in tables:
        if tbl.box == blk.box:
          result.add tbl.toMarkdown() & "\n"
          rendered = true
          break
      if rendered: continue

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
