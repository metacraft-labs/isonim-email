## E2e: no story widens a 320px phone where head CSS is stripped.
##
## `e2e_local_no_story_overflows_320_without_head_css` captures every
## story the capture CLI knows (`--full`, the capture story sets
## registered by `ISONIM_CAPTURE_LAYOUT=1`) through the real
## `email-shots` CLI, in the pinned Chromium under the `ganga` emulation
## (Gmail with no `<style>` at all, so only the inline design applies)
## at a 320px viewport, and reads each capture's Tier-3 `overflow`
## assertion: nothing is wider than the viewport. Each PNG is exactly
## 320px wide. It is the check that found a timeline whose table grew to
## a long word, and a long word in a plain paragraph that widened the
## whole message through the document's wrapper table (catalogue
## R-TBL-17).
##
## No test doubles: the real library, the real transform, the real
## pinned browser (allowed_mocks: None). C-only: spawns node and reads
## the run directory off disk. A missing node or browser tree fails
## loudly instead of skipping.
import std/[json, os, osproc, strutils, unittest]

const repoRoot = parentDir(parentDir(currentSourcePath()))

proc requireTools() =
  if findExe("node").len == 0 or findExe("just").len == 0:
    raise newException(OSError, "node or just not found on PATH — " &
      "refusing to skip (allowed_mocks: None). Run under the dev shell.")
  let dir = getEnv("PLAYWRIGHT_BROWSERS_PATH")
  if dir.len == 0 or not dirExists(dir):
    raise newException(OSError, "PLAYWRIGHT_BROWSERS_PATH is not set to " &
      "a readable directory — refusing to skip (allowed_mocks: None).")

proc pngWidth(path: string): int =
  ## The width in an IHDR chunk (bytes 16-19, big-endian).
  let s = readFile(path)
  (ord(s[16]) shl 24) or (ord(s[17]) shl 16) or (ord(s[18]) shl 8) or
    ord(s[19])

suite "every story at 320px without head CSS":
  test "e2e_local_no_story_overflows_320_without_head_css":
    requireTools()
    let (buildOut, buildCode) = execCmdEx("just email-shots-build",
      workingDir = repoRoot)
    if buildCode != 0:
      raise newException(OSError, "`just email-shots-build` failed:\n" &
        buildOut)
    putEnv("ISONIM_CAPTURE_LAYOUT", "1")
    let outDir = getTempDir() / "isonim-e2e-overflow-320-" &
      $getCurrentProcessId()
    removeDir(outDir)
    let (output, code) = execCmdEx("node tools/capture/email-shots.ts " &
      "--full --backends a --families ganga --viewports 320 " &
      "--schemes light --images on --no-cache --out " & outDir,
      workingDir = repoRoot)
    if code != 0:
      raise newException(OSError, "email-shots exited with " & $code &
        " (run kept at " & outDir & "):\n" & output)
    let index = parseJson(readFile(outDir / "index.json"))
    # Vacuity guard: the seed stories and every capture story set.
    check index.len >= 270
    var stories: seq[string] = @[]
    for e in index:
      let story = e["story"].getStr()
      stories.add(story)
      check e["status"].getStr() == "done"
      check e["viewport"].getStr() == "320@1x"
      check pngWidth(outDir / e["png"].getStr()) == 320
      let caps = parseJson(readFile(outDir / story /
        "assertions.json"))["captures"]
      var seen = false
      for a in caps[0]["assertions"]:
        if a["check"].getStr() == "overflow":
          seen = true
          if not a["pass"].getBool():
            checkpoint(story & ": " & $a)
          check a["pass"].getBool()
      check seen
    check "textMaximal" in stories and "quoteMaximal" in stories
    removeDir(outDir)
