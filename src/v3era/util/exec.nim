## Subprocess helper with a hard timeout.
##
## Every external tool is invoked with an argument vector and `poUsePath` --
## never through a shell. Document paths reach this code from HTTP uploads, and
## a shell would turn a filename into an injection vector.
##
## Output is collected only after the process exits, and callers are expected
## to send large output to files rather than pipes: a 60 MB render on a pipe
## nobody is draining deadlocks, and a timeout would not save the data anyway.

import std/[osproc, streams, os, strutils, times]

import ../core/log

type
  ExecResult* = object
    exitCode*: int
    output*: string  ## stdout and stderr, interleaved.
    timedOut*: bool
    durationMs*: float

  ExecError* = object of CatchableError

proc which*(exe: string): string =
  ## Absolute path of `exe` on PATH, or "" when it is not installed.
  ##
  ## `findExe` is used rather than shelling out to `which`, which is neither
  ## portable nor present in minimal containers.
  findExe(exe)

proc hasCommand*(exe: string): bool =
  which(exe).len > 0

proc runCommand*(exe: string; args: openArray[string]; timeoutMs = 60_000;
                 captureOutput = true): ExecResult =
  ## Runs `exe args...` with no shell. On timeout the process is killed and
  ## `timedOut` is set; the exit code is then -1.
  let started = epochTime()
  if not hasCommand(exe) and not fileExists(exe):
    raise newException(ExecError, "command not found on PATH: " & exe)

  var opts = {poUsePath}
  if captureOutput: opts.incl poStdErrToStdOut

  var p = startProcess(exe, args = @args, options = opts)
  defer: p.close()

  let code = p.waitForExit(timeoutMs)
  result.durationMs = (epochTime() - started) * 1000.0

  if p.running():
    # waitForExit returned without the process finishing: it timed out.
    p.terminate()
    discard p.waitForExit(2000)
    if p.running():
      p.kill()
      discard p.waitForExit(2000)
    result.timedOut = true
    result.exitCode = -1
    log.warn("external command timed out",
             {"exe": exe, "timeout_ms": $timeoutMs})
    return

  result.exitCode = code
  if captureOutput:
    result.output = p.outputStream.readAll()

  log.debug("ran external command", {
    "exe": exe, "args": args.join(" "), "exit": $result.exitCode,
    "ms": formatFloat(result.durationMs, ffDecimal, 1)})

proc runChecked*(exe: string; args: openArray[string];
                 timeoutMs = 60_000): string =
  ## Like `runCommand` but raises `ExecError` unless the command succeeded.
  let r = runCommand(exe, args, timeoutMs)
  if r.timedOut:
    raise newException(ExecError,
      exe & " exceeded its " & $timeoutMs & " ms timeout")
  if r.exitCode != 0:
    raise newException(ExecError,
      exe & " exited with status " & $r.exitCode & ": " &
      r.output[0 ..< min(r.output.len, 500)].strip())
  r.output
