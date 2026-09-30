## E2e latency: one reference story × the full variant set
## completes within the latency budget with timings recorded.
##
## Runs the real `email-shots` CLI (real driver binary, real pinned
## browsers — allowed_mocks: None) on the canary across 3 families ×
## 2 viewports × 3 schemes: 14 real captures plus 4 forced-dark
## not-applicables (non-Chromium engines). Every
## provenance must carry timing_ms with at least total + capture.
##
## C-only: spawns node + the driver and reads the run dir off disk
## (the t6_roundtrip precedent). A missing node, missing shell
## browsers or missing driver fails loudly instead of skipping.
import std/[json, os, osproc, strutils, times, unittest]

const repoRoot = parentDir(parentDir(currentSourcePath()))
  ## Resolved at compile time, so the test works whatever the
  ## runner's working directory is.

const latencyBudgetMs = 5000
  ## The iteration budget for the local slice: the full variant set
  ## of one story lands in seconds. The threshold
  ## stays 5 s (the reference-workstation budget); a slower host must
  ## record its measured numbers in a comment here, not move it.
  ## Measured 2026-09-27 on this workstation (isonim-email@b688de1):
  ## 2018/1974/2038 ms across three consecutive CLI runs.
  ## Slower host: 4184/4387 ms across two consecutive CLI runs
  ## (recorded here per the rule above; threshold untouched).
  ## Verify session 2026-09-28 (same base + verify fixes, 24-core
  ## shared host): 27 solo probes at load 55–176 failed at
  ## 5778–9310 ms plus one 10437 ms in-suite failure at load 111
  ## (unrelated CI builds); green once the storm passed — 3538 ms
  ## solo at load ~58, then 3150 ms in the full green suite at
  ## load ~8. Threshold untouched.

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
    # of the capture budget, which covers the CLI run only).
    let (buildOut, buildCode) = execCmdEx(
      "just email-shots-build", workingDir = repoRoot)
    if buildCode != 0:
      raise newException(OSError,
        "`just email-shots-build` failed:\n" & buildOut)

    let outDir = getTempDir() / "isonim-e2e-shots-" & $getCurrentProcessId()
    removeDir(outDir)
    let t0 = epochTime()
    let (output, code) = execCmdEx(
      "node tools/capture/email-shots.ts canary " &
      "--families apple,thunderbird,chromium-baseline " &
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
    for line in output.splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("{"):
        continue
      let parsed = parseJson(trimmed)
      check parsed.hasKey("status")
      inc streamed

    let index = parseJson(readFile(outDir / "index.json"))
    check streamed == index.len
    # 3 families × 2 viewports × 3 schemes.
    check index.len == 18
    var done, notApplicable, failed = 0
    for entry in index:
      check entry["story"].getStr() == "canary"
      check entry["backend"].getStr() == "a"
      check entry["meta"].getStr().len > 0
      let meta = parseJson(readFile(outDir / entry["meta"].getStr()))
      # Timings in every provenance: at least total + capture.
      check meta["timing_ms"].hasKey("total")
      check meta["timing_ms"].hasKey("capture")
      check meta["backend"].getStr() == "a"
      check meta["cache"].getStr() == "uncached"
      case entry["status"].getStr()
      of "done":
        inc done
        check entry["png"].getStr().len > 0
        check fileExists(outDir / entry["png"].getStr())
        check meta["client"]["build"].getStr().len > 0
      of "not-applicable":
        inc notApplicable
        # Only non-Chromium forced-dark is not-applicable.
        check entry["scheme"].getStr() == "forced-dark"
        check entry["family"].getStr() in ["apple", "thunderbird"]
      of "failed":
        inc failed
      else:
        check false
    check done == 14
    check notApplicable == 4
    check failed == 0

    # The evidence line: measured wall time against the budget, plus
    # the run dir (kept when a check below fails). The threshold
    # stays 5 s — the reference-workstation budget; a slower host
    # records its numbers here, not by moving it.
    echo "canary full variant set: " & $wallMs & " ms (budget " &
      $latencyBudgetMs & " ms), run at " & outDir
    check wallMs <= latencyBudgetMs
    removeDir(outDir)
