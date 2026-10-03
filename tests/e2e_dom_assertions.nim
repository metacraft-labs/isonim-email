## E2e Tier-3: the DOM assertions catch a 700px overflow at 320px.
##
## Runs the real `email-shots` CLI (real driver binaries, real pinned
## Chromium — allowed_mocks: None) with `--assert` on the
## `overflowFixed` fixture twin (a fixed 700px table): the run FAILS
## naming the overflow check and the table, the capture carries no
## PNG, and the per-story assertions.json records the overflow entry
## as failed. Negative control: the `overflowFluid` twin (a 100%
## table, otherwise identical) passes every check and the run exits 0.
##
## C-only: spawns node + the drivers and reads the run dirs off disk
## (the t6_roundtrip precedent). A missing node, missing shell
## browsers or missing drivers fails loudly instead of skipping.
import std/[json, os, osproc, strutils, unittest]

const repoRoot = parentDir(parentDir(currentSourcePath()))
  ## Resolved at compile time, so the test works whatever the
  ## runner's working directory is.

const fixtureMatrix = "--families chromium-baseline --viewports 320 " &
  "--schemes light --images on --assert --no-cache"
  ## One capture per twin: Chromium at a 320px viewport, gated.

proc requireTool(bin, hint: string): string =
  result = findExe(bin)
  if result.len == 0:
    raise newException(OSError,
      bin & " not found on PATH — refusing to skip (allowed_mocks: " &
      "None). " & hint)

proc requireShellBrowsers() =
  ## The pinned Chromium/Firefox/WebKit trees must be present; a
  ## download-on-first-run would silently unpin the engines.
  let dir = getEnv("PLAYWRIGHT_BROWSERS_PATH")
  if dir.len == 0 or not dirExists(dir):
    raise newException(OSError,
      "PLAYWRIGHT_BROWSERS_PATH is not set to a readable directory " &
      "— refusing to skip (allowed_mocks: None). Run under the dev " &
      "shell (`nix develop` in isonim-email; flake.nix pins the " &
      "Playwright browsers).")
  var engines = 0
  for kind, path in walkDir(dir):
    if kind in {pcDir, pcLinkToDir} and
        path.lastPathPart.split('-')[0] in ["chromium", "firefox",
          "webkit"]:
      inc engines
  if engines < 3:
    raise newException(OSError,
      "PLAYWRIGHT_BROWSERS_PATH=" & dir & " holds " & $engines &
      " engine trees, want chromium + firefox + webkit — refusing " &
      "to skip (allowed_mocks: None).")

proc runTwin(story, outDir: string): tuple[output: string; code: int] =
  ## One gated twin capture; the caller asserts the exit direction.
  let (output, exitCode) = execCmdEx(
    "node tools/capture/email-shots.ts " & story & " " &
    fixtureMatrix & " --out " & outDir, workingDir = repoRoot)
  (output, exitCode)

proc assertionsOf(outDir, story: string): JsonNode =
  ## The story's assertions.json captures array.
  parseJson(readFile(outDir / story / "assertions.json"))["captures"]

suite "e2e Tier-3 DOM assertions catch overflow":
  test "test_e2e_local_dom_assertions_catch_overflow":
    discard requireTool("node",
      "Run under the dev shell (`nix develop` in isonim-email).")
    requireShellBrowsers()
    discard requireTool("just",
      "Run under the dev shell (`nix develop` in isonim-email).")

    # Untimed setup: the driver binaries.
    let (buildOut, buildCode) = execCmdEx(
      "just email-shots-build", workingDir = repoRoot)
    if buildCode != 0:
      raise newException(OSError,
        "`just email-shots-build` failed:\n" & buildOut)

    # The fixture twins register only under this variable (see
    # tests/stories/seed_overflow.nim); inherited by the CLI runs.
    putEnv("ISONIM_CAPTURE_FIXTURES", "1")

    let pid = $getCurrentProcessId()
    let outFixed = getTempDir() / "isonim-e2e-overflow-fixed-" & pid
    let outFluid = getTempDir() / "isonim-e2e-overflow-fluid-" & pid
    removeDir(outFixed)
    removeDir(outFluid)

    # Direction 1: the 700px table fails the run at 320px.
    let (fixedOut, fixedCode) = runTwin("overflowFixed", outFixed)
    check fixedCode != 0
    check "overflow" in fixedOut
    check "table" in fixedOut
    let fixedIndex = parseJson(readFile(outFixed / "index.json"))
    check fixedIndex.len == 1
    check fixedIndex[0]["story"].getStr() == "overflowFixed"
    check fixedIndex[0]["viewport"].getStr() == "320@1x"
    check fixedIndex[0]["status"].getStr() == "failed"
    check fixedIndex[0]["png"].kind == JNull
    let fixedMeta = parseJson(readFile(
      outFixed / fixedIndex[0]["meta"].getStr()))
    check "overflow" in fixedMeta["fail_reason"].getStr()
    check "table" in fixedMeta["fail_reason"].getStr()
    let fixedCaps = assertionsOf(outFixed, "overflowFixed")
    check fixedCaps.len == 1
    var overflowSeen, axeSeen = false
    for a in fixedCaps[0]["assertions"]:
      if a["check"].getStr() == "overflow":
        overflowSeen = true
        check a["pass"].getBool() == false
      elif a["check"].getStr() == "axe":
        axeSeen = true
      else:
        check a["pass"].getBool() == true
    check overflowSeen
    # axe-core runs after the screenshot, which a capture refused by its
    # DOM checks never takes.
    check not axeSeen

    # Direction 2 (negative control): the fluid twin passes clean.
    let (fluidOut, fluidCode) = runTwin("overflowFluid", outFluid)
    if fluidCode != 0:
      raise newException(OSError,
        "the fluid twin must pass but email-shots exited with " &
        "status " & $fluidCode & " (run kept at " & outFluid & "):\n" &
        fluidOut)
    let fluidIndex = parseJson(readFile(outFluid / "index.json"))
    check fluidIndex.len == 1
    check fluidIndex[0]["status"].getStr() == "done"
    check fileExists(outFluid / fluidIndex[0]["png"].getStr())
    # All seven checks run and pass, axe-core's included.
    var checks: seq[string] = @[]
    for a in assertionsOf(outFluid, "overflowFluid")[0]["assertions"]:
      checks.add(a["check"].getStr())
      check a["pass"].kind == JBool and a["pass"].getBool() == true
    check checks.len == 7 and "axe" in checks

    let reason = fixedMeta["fail_reason"].getStr()
    echo "overflowFixed fails naming overflow + table (" &
      reason[0 .. min(60, reason.high)] &
      "…); overflowFluid passes all seven checks"
    removeDir(outFixed)
    removeDir(outFluid)
