## E2e determinism: the canary's full matrix captures byte-identically twice.
##
## Runs the real `email-shots` CLI twice (real driver binary, real pinned
## browsers, real pinned fonts — allowed_mocks: None) into separate
## `--out` dirs with `--no-cache` to force real captures, then compares
## every PNG per relative path: the same PNG set, every byte identical.
## Determinism bar: successive captures must differ only where the
## email changed, or reviewers chase noise.
##
## C-only: spawns node + the driver and reads the run dirs off disk
## (the t6_roundtrip precedent). A missing node, missing shell browsers,
## missing driver or missing/unpinned fonts fails loudly instead of
## skipping.
import std/[algorithm, json, os, osproc, strutils, unittest]

const repoRoot = parentDir(parentDir(currentSourcePath()))
  ## Resolved at compile time, so the test works whatever the
  ## runner's working directory is.

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

proc requirePinnedFonts() =
  ## fontconfig must see ONLY the flake's pinned capture font set
  ## (Liberation, Carlito, Roboto, Noto); host fonts would make
  ## captures host-dependent, silently breaking byte-identical capture.
  let conf = getEnv("FONTCONFIG_FILE")
  if conf.len == 0 or not fileExists(conf):
    raise newException(OSError,
      "FONTCONFIG_FILE is not set to a readable file — refusing to " &
      "skip (allowed_mocks: None). Run under the dev shell (`nix " &
      "develop` in isonim-email; flake.nix pins the capture fonts).")
  discard requireTool("fc-list",
    "Run under the dev shell (`nix develop` in isonim-email).")
  let (families, code) = execCmdEx("fc-list : family",
    workingDir = repoRoot)
  if code != 0:
    raise newException(OSError,
      "`fc-list : family` failed:\n" & families)
  for want in ["Liberation Sans", "Liberation Serif", "Liberation Mono",
      "Carlito", "Roboto", "Noto Sans"]:
    if want notin families:
      raise newException(OSError,
        "pinned font family '" & want & "' is not visible via " &
        "fc-list — refusing to skip (allowed_mocks: None). Run under " &
        "the dev shell (`nix develop` in isonim-email).")
  let (files, filesCode) = execCmdEx("fc-list : file",
    workingDir = repoRoot)
  if filesCode != 0:
    raise newException(OSError,
      "`fc-list : file` failed:\n" & files)
  for line in files.splitLines():
    let path = line.strip()
    if path.len > 0 and not path.startsWith("/nix/store"):
      raise newException(OSError,
        "font file outside the Nix store: " & path & " — host fonts " &
        "would make captures host-dependent (refusing to skip; " &
        "allowed_mocks: None).")

proc runCanary(outDir: string): JsonNode =
  ## One full-matrix canary run of backend a (`--backends a`: the real
  ## Thunderbird of the desktop provider serves the thunderbird family
  ## too, and is not part of this check); returns the parsed index.json.
  let (output, code) = execCmdEx(
    "node tools/capture/email-shots.ts canary --backends a " &
    "--families apple,thunderbird,chromium-baseline,gmailWeb,ganga," &
    "outlookWeb,imagesOff,wordApprox " &
    "--viewports mobile,desktop --schemes light,dark,forced-dark " &
    "--images on --no-cache --out " & outDir, workingDir = repoRoot)
  if code != 0:
    raise newException(OSError,
      "email-shots exited with status " & $code & " (run kept at " &
      outDir & "):\n" & output)
  parseJson(readFile(outDir / "index.json"))

proc pngPaths(outDir: string, index: JsonNode): seq[string] =
  ## Relative PNG paths of the run's `done` entries (8 families ×
  ## 2 viewports × 3 schemes = 48 entries, minus the 4 non-Chromium
  ## forced-dark not-applicables = 44 PNGs).
  result = @[]
  for entry in index:
    if entry["status"].getStr() == "done":
      let png = entry["png"].getStr()
      check png.len > 0
      check fileExists(outDir / png)
      result.add(png)

suite "e2e local capture determinism":
  test "test_e2e_local_capture_is_deterministic":
    discard requireTool("node",
      "Run under the dev shell (`nix develop` in isonim-email).")
    requireShellBrowsers()
    requirePinnedFonts()
    discard requireTool("just",
      "Run under the dev shell (`nix develop` in isonim-email).")

    # Untimed setup: the driver binary.
    let (buildOut, buildCode) = execCmdEx(
      "just email-shots-build", workingDir = repoRoot)
    if buildCode != 0:
      raise newException(OSError,
        "`just email-shots-build` failed:\n" & buildOut)

    let pid = $getCurrentProcessId()
    let outA = getTempDir() / "isonim-e2e-determinism-a-" & pid
    let outB = getTempDir() / "isonim-e2e-determinism-b-" & pid
    removeDir(outA)
    removeDir(outB)
    let indexA = runCanary(outA)
    let indexB = runCanary(outB)
    check indexA.len == 48
    check indexB.len == 48

    # Sorted: index.json follows worker-pool completion order, which
    # legitimately differs between runs — the PNG set must not.
    let pngsA = sorted(pngPaths(outA, indexA))
    let pngsB = sorted(pngPaths(outB, indexB))
    check pngsA.len == 44
    check pngsB == pngsA
    for png in pngsA:
      check readFile(outA / png) == readFile(outB / png)

    # The evidence line: PNG count compared, both run dirs (kept when
    # a check above fails).
    echo "canary full matrix: " & $pngsA.len &
      " PNGs byte-identical across two runs (" & outA & ", " & outB & ")"
    removeDir(outA)
    removeDir(outB)
