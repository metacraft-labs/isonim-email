## E2e latency: one reference story × the full backend-A variant
## set, with its timings RECORDED (never asserted).
##
## Runs the real `email-shots` CLI (real driver binary, real pinned
## browsers — allowed_mocks: None) on the canary across every
## backend-A family (the three raw engines plus the five emulations)
## × 2 viewports × 3 schemes: 48 requests, 44 real captures plus 4
## forced-dark not-applicables (the non-Chromium engines).
##
## Wall time on a shared host measures the neighbours, not the code,
## so there is no time budget here. What this test does fail on is
## the recording itself: every provenance must carry timing_ms
## (total + capture, plus setcontent + settle for real captures),
## run.json must carry the run's total and per-step timings and the
## local browser provider's slice, and the run must land in the latency
## history (build/email-shots/latency-history.jsonl) that the CLI
## compares against its rolling median. The measured wall time is
## printed; a regression beyond 50% of the rolling median is a
## warning in the CLI's run summary, echoed here, never a failure.
##
## C-only: spawns node + the driver and reads the run dir off disk
## (the t6_roundtrip precedent). A missing node, missing shell
## browsers or missing driver fails loudly instead of skipping.
import std/[json, os, osproc, sets, strutils, times, unittest]

const repoRoot = parentDir(parentDir(currentSourcePath()))
  ## Resolved at compile time, so the test works whatever the
  ## runner's working directory is.

const backendAFamilies = ["apple", "thunderbird", "chromium-baseline",
  "gmailWeb", "ganga", "outlookWeb", "imagesOff", "wordApprox"]
  ## The full backend-A family set, spelled out so a family dropped
  ## from the CLI's default selection fails this test.

const runSteps = ["build_stories", "briefs", "launch", "captures",
  "assertions", "sheets"]

proc isMs(n: JsonNode): bool =
  ## A recorded duration: a non-negative JSON number.
  n != nil and n.kind in {JInt, JFloat} and n.getFloat() >= 0

proc historyLines(path: string): seq[JsonNode] =
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines():
    if line.strip().len == 0:
      continue
    try:
      result.add parseJson(line)
    except JsonParsingError:
      discard

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

suite "e2e local shots latency":
  test "test_e2e_local_shots_latency":
    discard requireTool("node",
      "Run under the dev shell (`nix develop` in isonim-email).")
    requireShellBrowsers()
    discard requireTool("just",
      "Run under the dev shell (`nix develop` in isonim-email).")

    # Untimed setup: the driver binary (its Nim compile is not part
    # of the measured run, which covers the CLI only).
    let (buildOut, buildCode) = execCmdEx(
      "just email-shots-build", workingDir = repoRoot)
    if buildCode != 0:
      raise newException(OSError,
        "`just email-shots-build` failed:\n" & buildOut)

    let historyPath = repoRoot / "build" / "email-shots" /
      "latency-history.jsonl"
    let historyBefore = historyLines(historyPath).len

    let outDir = getTempDir() / "isonim-e2e-shots-" & $getCurrentProcessId()
    removeDir(outDir)
    # No --families: the CLI's default is the full backend-A set,
    # checked against backendAFamilies below. --full bypasses the
    # changed-only selection so the whole matrix always runs.
    let t0 = epochTime()
    let (output, code) = execCmdEx(
      "node tools/capture/email-shots.ts canary --full " &
      "--viewports mobile,desktop --schemes light,dark,forced-dark " &
      "--images on --no-cache --out " & outDir, workingDir = repoRoot)
    let wallMs = int((epochTime() - t0) * 1000)
    if code != 0:
      raise newException(OSError,
        "email-shots exited with status " & $code & " (run kept at " &
        outDir & "):\n" & output)

    # One JSON line per finished capture on stdout (pipeline step 4).
    # (`execCmdEx` merges stderr — the human progress lines — into
    # `output`, so only the `{` lines are parsed.)
    var streamed = 0
    var warning = ""
    for line in output.splitLines():
      let trimmed = line.strip()
      if "latency warning:" in trimmed:
        warning = trimmed
      if not trimmed.startsWith("{"):
        continue
      let parsed = parseJson(trimmed)
      check parsed.hasKey("status")
      inc streamed

    let index = parseJson(readFile(outDir / "index.json"))
    check streamed == index.len
    # 8 families × 2 viewports × 3 schemes.
    check index.len == backendAFamilies.len * 2 * 3
    var families = initHashSet[string]()
    var done, notApplicable, failed = 0
    for entry in index:
      check entry["story"].getStr() == "canary"
      check entry["backend"].getStr() == "a"
      families.incl entry["family"].getStr()
      check entry["meta"].getStr().len > 0
      let meta = parseJson(readFile(outDir / entry["meta"].getStr()))
      # Timings in every provenance: at least total + capture.
      let timing = meta{"timing_ms"}
      check timing != nil and timing.kind == JObject
      if timing == nil or timing.kind != JObject:
        continue
      check isMs(timing{"total"})
      check isMs(timing{"capture"})
      check meta["backend"].getStr() == "a"
      check meta["cache"].getStr() == "uncached"
      case entry["status"].getStr()
      of "done":
        inc done
        check entry["png"].getStr().len > 0
        check fileExists(outDir / entry["png"].getStr())
        check meta["client"]["build"].getStr().len > 0
        # A real capture spent real time in each step.
        check isMs(timing{"setcontent"})
        check isMs(timing{"settle"})
        check timing{"total"}.getFloat() > 0
      of "not-applicable":
        inc notApplicable
        # Only non-Chromium forced-dark is not-applicable.
        check entry["scheme"].getStr() == "forced-dark"
        check entry["family"].getStr() in ["apple", "thunderbird"]
      of "failed":
        inc failed
      else:
        check false
    check families == toHashSet(backendAFamilies)
    check done == index.len - 4
    check notApplicable == 4
    check failed == 0

    # run.json: the run's total, per-step timings and the local browser
    # provider slice.
    let runJson = parseJson(readFile(outDir / "run.json"))
    let runTiming = runJson{"timing_ms"}
    check runTiming != nil and runTiming.kind == JObject
    var runTotal = -1
    if runTiming != nil and runTiming.kind == JObject:
      check isMs(runTiming{"total"})
      check runTiming{"total"}.getFloat() > 0
      runTotal = runTiming{"total"}.getInt()
      let steps = runTiming{"steps"}
      check steps != nil and steps.kind == JObject
      if steps != nil and steps.kind == JObject:
        for step in runSteps:
          check isMs(steps{step})
    let provider = runJson{"providers", "browser-emulation"}
    check provider != nil
    if provider != nil:
      check provider{"backend"}.getStr() == "a"
      check provider{"health"}.getStr() == "ok"
      check provider{"requests"}.getInt() == index.len
      check isMs(provider{"wall_ms"})
    check runJson{"latency", "recorded"}.getBool()

    # The run landed in the latency history, under this run's id.
    let history = historyLines(historyPath)
    check history.len == historyBefore + 1
    if history.len > 0:
      let last = history[^1]
      check last{"run"}.getStr() == runJson{"run"}.getStr()
      check last{"total_ms"}.getInt() == runTotal
      check last{"requests"}.getInt() == index.len
      check last{"key"}.getStr() == runJson{"latency", "key"}.getStr()

    # The evidence line: measured wall time, recorded — no budget.
    let median = runJson{"latency", "median_ms"}
    echo "canary full backend-A set (" & $index.len & " requests): " &
      $wallMs & " ms wall, " & $runTotal & " ms CLI total; rolling " &
      "median " & (if median != nil and median.kind != JNull: $median &
      " ms" else: "n/a") & "; run at " & outDir
    if warning.len > 0:
      echo warning
    removeDir(outDir)
