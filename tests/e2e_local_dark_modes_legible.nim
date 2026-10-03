## E2e Tier-3: every registered story stays legible under light, dark and
## forced dark.
##
## Runs the real `email-shots` CLI (real driver binaries, the pinned
## Chromium; allowed_mocks: None) over every registered story (the
## layout, primitive, leaf, button, table, navigation, raw, background
## and dark sets included: `ISONIM_CAPTURE_LAYOUT=1`), desktop and
## mobile, in the three schemes, and reads each capture's `contrast`
## assertion from its provenance: every visible element holding text
## reaches 4.5:1 (3:1 when large) against its background, from the
## computed colours in light and dark and from the screenshot's pixels
## under forced dark, where Blink's automatic dark mode recolours what it
## paints and not the computed styles (`tools/capture/pixel_contrast.ts`).
## Forced dark darkens the light design whatever the message declares,
## so its captures differ from the dark ones.
##
## The known failures are listed below, each with its reason; the list
## is exact both ways: a capture that fails and is not listed fails the
## test, and so does a listed one that passes (the list cannot go stale).
##
## Non-vacuity: three fixtures (`tests/stories/seed_contrast.nim`, under
## `ISONIM_CAPTURE_FIXTURES=1`) each fail the assertion in exactly one
## scheme and pass it in the other two, so the check is shown to be live
## in light, in dark and under forced dark.
##
## C-only: spawns node and the drivers and reads the run directories off
## disk (the e2e_dom_assertions precedent). A missing node, missing shell
## browsers or missing drivers fails loudly instead of skipping.
import std/[json, os, osproc, sets, strutils, tables, unittest]

const repoRoot = parentDir(parentDir(currentSourcePath()))
  ## Resolved at compile time, so the test works whatever the
  ## runner's working directory is.

const matrix = "--full --families chromium-baseline " &
  "--viewports desktop,mobile --schemes light,dark,forced-dark --no-cache"
  ## The pinned Chromium, both widths, the three schemes, no cache (every
  ## PNG and assertion is this run's).

const knownFailures = [
  # Dark text over a light background image: Blink's automatic dark mode
  # lightens the text and leaves the image as it is (measured; the
  # catalogue's R-DRK-04 models it, and its lint reports the pair). No
  # message can stop a client's forced inversion, and whether the Gmail
  # app treats background images the same way is still to be measured
  # there; the stories show the case on purpose.
  ("sectionBackground", "desktop", "forced-dark"),
  ("sectionBackground", "mobile", "forced-dark"),
  ("backgroundTile", "desktop", "forced-dark"),
  ("backgroundTile", "mobile", "forced-dark"),
  ("heroImagesOff", "desktop", "forced-dark"),
  ("heroImagesOff", "mobile", "forced-dark"),
]

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

type Capture = object
  story, viewport, scheme, png: string
  pass: bool
  detail: string

proc runMatrix(env, stories, outDir: string): seq[Capture] =
  ## One CLI run; every capture's `contrast` assertion.
  removeDir(outDir)
  let (output, code) = execCmdEx(env & " node tools/capture/email-shots.ts " &
    stories & " " & matrix & " --out " & outDir, workingDir = repoRoot)
  if code != 0:
    raise newException(OSError, "email-shots exited with status " & $code &
      " (run kept at " & outDir & "):\n" & output)
  for e in parseJson(readFile(outDir / "index.json")):
    if e["status"].getStr() != "done":
      raise newException(OSError, "capture not done: " & $e)
    let meta = parseJson(readFile(outDir / e["meta"].getStr()))
    var c = Capture(story: e["story"].getStr(),
      viewport: e["viewport"].getStr(),
      scheme: e["scheme"].getStr(), png: outDir / e["png"].getStr())
    var found = 0
    for a in meta["assertions"]:
      if a["check"].getStr() == "contrast":
        inc found
        c.pass = a["pass"].getBool()
        c.detail = a["detail"].getStr()
    doAssert found == 1, c.story & " " & c.scheme & ": " & $found &
      " contrast assertions"
    result.add(c)

proc numberBefore(text, marker: string): int =
  ## The whole number written just before `marker` in `text` (-1: none).
  let i = text.find(marker)
  if i < 0:
    return -1
  var j = i
  while j > 0 and text[j - 1] in Digits:
    dec j
  if j == i: -1 else: parseInt(text[j ..< i])

proc measured(c: Capture): int =
  ## How many elements or text runs the assertion read (0: vacuous):
  ## "(N element(s) with text checked" from the computed check, "of N
  ## text run(s)" from the pixel one.
  max(numberBefore(c.detail, " element(s) with text checked"),
    numberBefore(c.detail, " text run(s) below"))

suite "e2e every story stays legible in light, dark and forced dark":
  test "e2e_local_dark_modes_legible":
    discard requireTool("node",
      "Run under the dev shell (`nix develop` in isonim-email).")
    discard requireTool("just",
      "Run under the dev shell (`nix develop` in isonim-email).")
    requireShellBrowsers()
    let (buildOut, buildCode) = execCmdEx(
      "just email-shots-build", workingDir = repoRoot)
    if buildCode != 0:
      raise newException(OSError,
        "`just email-shots-build` failed:\n" & buildOut)
    let pid = $getCurrentProcessId()

    # Every registered story.
    let outAll = getTempDir() / "isonim-e2e-dark-modes-" & pid
    let caps = runMatrix("ISONIM_CAPTURE_LAYOUT=1", "", outAll)
    var stories = initHashSet[string]()
    for c in caps:
      stories.incl(c.story)
    check stories.len >= 100
    check caps.len == stories.len * 6
    var failing = initHashSet[(string, string, string)]()
    var byKey = initTable[(string, string, string), Capture]()
    for c in caps:
      byKey[(c.story, c.viewport, c.scheme)] = c
      checkpoint(c.story & " " & c.viewport & " " & c.scheme & ": " &
        c.detail)
      check measured(c) >= 1
      if c.scheme == "forced-dark":
        check c.detail.startsWith("measured on the forced-dark pixels")
      if not c.pass:
        failing.incl((c.story, c.viewport, c.scheme))
    var known = initHashSet[(string, string, string)]()
    for k in knownFailures:
      known.incl(k)
    for f in failing - known:
      checkpoint("unexpected failure: " & $f & ": " & byKey[f].detail)
    for k in known - failing:
      checkpoint("listed but passing: " & $k)
    check failing == known
    # Forced dark is not the dark scheme: every story's forced-dark
    # capture differs from its dark one (a message declaring
    # `color-scheme: light dark` used to make them equal).
    for s in stories:
      for v in ["desktop", "mobile"]:
        checkpoint(s & " " & v)
        check readFile(byKey[(s, v, "forced-dark")].png) !=
          readFile(byKey[(s, v, "dark")].png)

    # The fixtures: each fails in its own scheme only.
    let outFix = getTempDir() / "isonim-e2e-dark-modes-fixtures-" & pid
    let fix = runMatrix("ISONIM_CAPTURE_FIXTURES=1",
      "contrastLightBroken contrastDarkBroken contrastForcedBroken", outFix)
    check fix.len == 18
    let broken = {"contrastLightBroken": "light",
      "contrastDarkBroken": "dark",
      "contrastForcedBroken": "forced-dark"}.toTable
    for c in fix:
      checkpoint(c.story & " " & c.viewport & " " & c.scheme & ": " &
        c.detail)
      check c.pass == (broken[c.story] != c.scheme)
    echo $caps.len & " captures of " & $stories.len & " stories: " &
      $(caps.len - failing.len) & " legible, " & $failing.len &
      " listed failures; the three fixtures fail in their own scheme only"
    removeDir(outAll)
    removeDir(outFix)
