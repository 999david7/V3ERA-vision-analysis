## Structured, allocation-light logging on stderr.
##
## Emits either human-readable lines or newline-delimited JSON, selected with
## `setLogFormat`. JSON mode is what you want behind a log shipper; text mode is
## what you want in a terminal. Writes go to stderr so that stdout stays clean
## for machine-readable command output.

import std/[times, strutils, os, locks, json]

type
  LogLevel* = enum
    lvlDebug = "debug"
    lvlInfo = "info"
    lvlWarn = "warn"
    lvlError = "error"

  LogFormat* = enum
    lfText, lfJson

var
  gLevel = lvlInfo
  gFormat = lfText
  gLock: Lock

gLock.initLock()

proc setLogLevel*(l: LogLevel) =
  gLevel = l

proc logLevel*(): LogLevel = gLevel

proc setLogFormat*(f: LogFormat) =
  gFormat = f

proc parseLogLevel*(s: string): LogLevel =
  case s.toLowerAscii()
  of "debug": lvlDebug
  of "info", "": lvlInfo
  of "warn", "warning": lvlWarn
  of "error": lvlError
  else: lvlInfo

proc initLogFromEnv*() =
  ## Honours `V3ERA_LOG_LEVEL` (debug|info|warn|error) and `V3ERA_LOG_FORMAT`
  ## (text|json). Called by both entry points at startup.
  setLogLevel(parseLogLevel(getEnv("V3ERA_LOG_LEVEL", "info")))
  if getEnv("V3ERA_LOG_FORMAT", "text").toLowerAscii() == "json":
    setLogFormat(lfJson)

proc emit(level: LogLevel; msg: string; fields: openArray[(string, string)]) =
  if level < gLevel: return
  var line: string
  if gFormat == lfJson:
    var o = newJObject()
    o["ts"] = %($now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"))
    o["level"] = %($level)
    o["msg"] = %msg
    for (k, v) in fields:
      o[k] = %v
    line = $o
  else:
    line = now().format("HH:mm:ss'.'fff") & " [" & ($level).toUpperAscii() &
      "] " & msg
    for (k, v) in fields:
      line.add ' '
      line.add k
      line.add '='
      # Quote only when the value would otherwise break key=value scanning.
      if v.len == 0 or v.contains(' ') or v.contains('"'):
        line.add escapeJson(v)
      else:
        line.add v
  withLock gLock:
    stderr.writeLine line
    stderr.flushFile()

proc debug*(msg: string; fields: varargs[(string, string)]) =
  emit(lvlDebug, msg, fields)

proc info*(msg: string; fields: varargs[(string, string)]) =
  emit(lvlInfo, msg, fields)

proc warn*(msg: string; fields: varargs[(string, string)]) =
  emit(lvlWarn, msg, fields)

proc error*(msg: string; fields: varargs[(string, string)]) =
  emit(lvlError, msg, fields)

template timed*(label: string; body: untyped) =
  ## Runs `body` and logs its wall-clock duration at debug level.
  block:
    let tStart = epochTime()
    body
    debug(label, {"ms": formatFloat((epochTime() - tStart) * 1000.0, ffDecimal, 1)})
