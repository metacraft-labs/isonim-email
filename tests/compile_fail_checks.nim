## `nim check` over the compile-failure fixtures in `tests/compile_fail/`,
## shared by tests/t1_compile_fail.nim and
## tests/t2_vocabulary_compile_fail.nim. Not a test file itself.
##
## Every fixture is an independent compiler process, so several run at
## once and the suite waits for the slowest rather than for their sum
## (serially the fixtures cost about 2.5 s each). How many at a time is
## `ISONIM_EMAIL_TEST_JOBS` (the setting the test runners use, and pass
## down; a positive number, so `1` is serial), else the host's cores.
## Each one's stdout and stderr go merged to its own file, exactly what the former per-fixture
## `execCmdEx(... 2>&1)` captured, and nothing is read until its process
## has exited, so a long diagnostic cannot fill a pipe and stall a sibling.
import std/[os, osproc, strutils, tables]

const repoRoot = parentDir(parentDir(currentSourcePath()))

type NimCheckResult* = tuple[output: string, exitCode: int]

proc checkJobs(): int =
  ## The concurrency bound: ISONIM_EMAIL_TEST_JOBS when set (a positive
  ## number, anything else is an error), else the host's processors.
  let v = getEnv("ISONIM_EMAIL_TEST_JOBS")
  if v.len == 0:
    return max(1, countProcessors())
  try:
    result = parseInt(v)
  except ValueError:
    result = 0
  doAssert result >= 1,
    "ISONIM_EMAIL_TEST_JOBS must be a positive number (got '" & v & "')"

proc nimCheckAll*(paths: openArray[string]): Table[string, NimCheckResult] =
  ## `nim check --hints:off <fixture>` for every path, run concurrently from
  ## the repository root (at most checkJobs() at a time), keyed by the path
  ## as given. `config.nims` is found by walking up from the fixture, so no
  ## --path flags are needed; style checks are off so only semantic errors
  ## show.
  let nim = findExe("nim")
  doAssert nim.len > 0, "nim not on PATH (run under nix develop)"
  let jobs = checkJobs()
  let work = getTempDir() / ("isonim-email-compile-fail-" &
    $getCurrentProcessId())
  removeDir(work)
  createDir(work)
  var running: seq[tuple[path, log: string; process: Process]]
  # Collect the oldest running check (each one's output is read only
  # after its process has exited).
  template collectOldest() =
    let (path, log, process) = running[0]
    running.delete(0)
    let exitCode = process.waitForExit()
    process.close()
    result[path] = (readFile(log), exitCode)
  for i, path in paths:
    if running.len >= jobs:
      collectOldest()
    let log = work / ($i & ".log")
    running.add (path, log, startProcess(
      quoteShell(nim) & " check --hints:off " & quoteShell(path) & " > " &
        quoteShell(log) & " 2>&1",
      workingDir = repoRoot, options = {poEvalCommand}))
  while running.len > 0:
    collectOldest()
  removeDir(work)
