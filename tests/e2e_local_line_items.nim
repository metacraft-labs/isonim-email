## E2e: line items stay readable at 320px without CSS.
##
## `e2e_local_line_items_readable_at_320` captures the `lineItemsMaximal`
## story (three columns, thumbnails, details and long names; registered
## under `ISONIM_CAPTURE_LAYOUT=1`) through the real `email-shots` CLI,
## in the pinned Chromium under the `ganga` emulation (Gmail with no
## `<style>` at all, so nothing but the inline design applies) at a
## 320px viewport, and reads the capture's Tier-3 DOM assertions: no
## element overflows the viewport (`overflow`) and no text renders below
## the minimum body size (`bodyfont`). The PNG is exactly the viewport's
## width, so nothing widened the page either. The run is not gated with
## `--assert`: the story's footer link is not a 44px tap target, which
## the `touch` check reports and this test is not about.
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

suite "line items at 320px":
  test "e2e_local_line_items_readable_at_320":
    requireTools()
    let (buildOut, buildCode) = execCmdEx("just email-shots-build",
      workingDir = repoRoot)
    if buildCode != 0:
      raise newException(OSError, "`just email-shots-build` failed:\n" &
        buildOut)
    putEnv("ISONIM_CAPTURE_LAYOUT", "1")
    let outDir = getTempDir() / "isonim-e2e-line-items-" &
      $getCurrentProcessId()
    removeDir(outDir)
    let (output, code) = execCmdEx("node tools/capture/email-shots.ts " &
      "lineItemsMaximal --families ganga --viewports 320 --schemes light " &
      "--images on --no-cache --out " & outDir, workingDir = repoRoot)
    if code != 0:
      raise newException(OSError, "email-shots exited with " & $code &
        " (run kept at " & outDir & "):\n" & output)
    let index = parseJson(readFile(outDir / "index.json"))
    check index.len == 1
    check index[0]["viewport"].getStr() == "320@1x"
    check index[0]["status"].getStr() == "done"
    # The story is the three-column table it claims to be.
    let html = readFile(outDir / "lineItemsMaximal.html")
    check html.count("<th scope=\"col\"") == 3
    check html.count("white-space:nowrap") >= 6
    # Nothing widened the page past the phone.
    check pngWidth(outDir / index[0]["png"].getStr()) == 320
    var seen: seq[string] = @[]
    let caps = parseJson(readFile(outDir / "lineItemsMaximal" /
      "assertions.json"))["captures"]
    check caps.len == 1
    for a in caps[0]["assertions"]:
      let name = a["check"].getStr()
      if name in ["overflow", "bodyfont"]:
        seen.add(name)
        if not a["pass"].getBool():
          checkpoint(name & ": " & $a)
        check a["pass"].getBool()
    check seen.len == 2
    removeDir(outDir)
