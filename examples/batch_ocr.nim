## Batch OCR over a directory, emitting one JSON object per line.
##
##   nim c -r -d:v3eraStb examples/batch_ocr.nim ./scans > out.jsonl
##
## Demonstrates the property that makes batch work practical: a page that
## cannot be read produces a record with a warning rather than aborting the
## run. Only a genuinely undecodable file is skipped, and it is still counted.
##
## The VLM stage is deliberately off here -- batch OCR should not silently
## spend money per page.

import std/[os, json, strutils, times, options, algorithm]

import ../src/v3era

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    quit("usage: batch_ocr <directory> [--markdown]", 1)
  let dir = args[0]
  let asMarkdown = "--markdown" in args

  if not dirExists(dir):
    quit("not a directory: " & dir, 1)

  initLogFromEnv()

  let caps = capabilities()
  if not caps.ocr:
    stderr.writeLine "warning: no OCR engine (" & caps.ocrDetail & ")"
    stderr.writeLine "         PDFs with a text layer will still be read."

  var opts = defaultAnalyzeOptions()
  opts.runOcr = true
  opts.runVlm = false

  var paths: seq[string]
  for path in walkDirRec(dir):
    if formatFromExtension(path) != sfUnknown:
      paths.add path
  paths.sort()

  if paths.len == 0:
    quit("no recognisable images or PDFs under " & dir, 1)

  let started = epochTime()
  var succeeded = 0
  var degraded = 0
  var skipped = 0
  var totalWords = 0

  for i, path in paths:
    stderr.write "\r[" & $(i + 1) & "/" & $paths.len & "] " &
      path.extractFilename().alignLeft(48)[0 ..< 48]
    try:
      let res = analyzeFile(path, opts)
      var words = 0
      for p in res.document.pages:
        if p.ocr.isSome: words += p.ocr.get.wordCount
      totalWords += words

      if res.warnings.len > 0: inc degraded else: inc succeeded

      var record = %*{
        "path": path,
        "format": $res.format,
        "kind": $res.kind,
        "pages": res.document.pages.len,
        "words": words,
        "ms": res.totalMs,
        "warnings": res.warnings}
      record["text"] = %(if asMarkdown: res.markdown() else: res.document.text)
      echo record
    except V3eraError as e:
      # Undecodable input: record it and keep going. One bad file must not end
      # a ten-thousand-page run.
      inc skipped
      echo %*{"path": path, "error": e.msg}

  stderr.writeLine ""
  stderr.writeLine "processed " & $paths.len & " file(s) in " &
    formatFloat(epochTime() - started, ffDecimal, 1) & "s: " &
    $succeeded & " clean, " & $degraded & " with warnings, " &
    $skipped & " unreadable; " & $totalWords & " words recognised"

when isMainModule:
  main()
