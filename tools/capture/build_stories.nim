## tools/capture/build_stories.nim — story → MIME builder.
##
## Pipeline step 1: renders every selected story with the library in
## the current working tree and writes `build/email-shots/<run>/`
## (`<story>.eml` + `<story>.html` + `manifest.json`). The HTML file
## rides along so backend A can `setContent` without parsing MIME;
## the manifest maps story → files for the capture CLI.
##
## Deterministic: fixed Date (2026-01-01T12:00:00Z, the capture clock)
## and per-story deterministic boundaries/Message-ID, so the same
## tree always yields the same bytes.
##
## Usage: build-stories <outDir> [STORY…] (no stories = all).
import std/[os, json, times]
import isonim_email
import stories/email_stories
import stories/seed_broken
import stories/seed_layout
import stories/seed_primitives
import stories/seed_leaves
import stories/seed_buttons
import stories/seed_table
import stories/seed_navigation
import stories/seed_raw
import stories/seed_backgrounds
import stories/seed_dark
import stories/seed_contrast

# `mime_sha256` uses the library's `sha256Hex`
# (`src/isonim_email/assets.nim`, re-exported by the umbrella). The
# FIPS "abc" vector is pinned by `tests/t6_assets` through
# `hostedPath`.

const fixedDateSecs = 1767268800'i64
  ## 2026-01-01T12:00:00Z in unix seconds — the capture clock.

proc buildStory(outDir, name: string): JsonNode =
  let story = getStory(name) # Raises StoryError naming the known set.
  let (html, text) = story.render()
  let rendered = RenderedEmail(html: html, text: text)
  let msg =
    try:
      toMessage(rendered, MessageHeaders(
        fromAddr: mailbox("IsoNim Shots", "shots@example.test"),
        to: @[mailbox("", "qa@example.test")],
        subject: "[shots] " & name,
        date: fromUnix(fixedDateSecs)))
    except EmailRenderError as e:
      raise newException(StoryError, "story '" & name &
        "' failed MIME assembly: " & e.msg)
  let emlPath = outDir / name & ".eml"
  let htmlPath = outDir / name & ".html"
  createDir(parentDir(emlPath))
  createDir(parentDir(htmlPath))
  let rfc5322 = toRfc5322(msg, name)
  writeFile(emlPath, rfc5322)
  writeFile(htmlPath, html)
  %*{"story": name, "eml": name & ".eml", "html": name & ".html",
      "mime_sha256": sha256Hex(rfc5322)}

proc main(): int =
  let args = commandLineParams()
  if args.len < 1:
    stderr.writeLine("usage: build-stories <outDir> [STORY…]")
    return 2
  registerSeedStories()
  if getEnv("ISONIM_CAPTURE_FIXTURES") == "1":
    # Tier-3 fixtures: visible to the drivers only under this
    # variable (set by tests/e2e_dom_assertions.nim), so bare runs,
    # CI matrices and the t7 story-set pins never see them.
    registerOverflowStories()
    registerSanitiserProbeStory()
    registerBrokenStories()
    # The contrast fixtures, one failing in each scheme
    # (tests/stories/seed_contrast.nim).
    registerContrastFixtures()
  if getEnv("ISONIM_CAPTURE_LAYOUT") == "1":
    # The layout reference stories (tests/stories/seed_layout.nim):
    # iterated on in the capture loop, outside the regression matrix.
    registerLayoutStories()
    # The layout primitives' story set (tests/stories/seed_primitives.nim).
    registerPrimitiveStories()
    # The content leaves' story set (tests/stories/seed_leaves.nim).
    registerLeafStories()
    # The buttons' story set (tests/stories/seed_buttons.nim).
    registerButtonStories()
    # The data tables', the navigation and the raw-markup and
    # targeting story sets (tests/stories/seed_table.nim,
    # seed_navigation.nim, seed_raw.nim).
    registerTableStories()
    registerNavigationStories()
    registerRawStories()
    # The background images' and heroes' story set
    # (tests/stories/seed_backgrounds.nim).
    registerBackgroundStories()
    # The dark-mode story set (tests/stories/seed_dark.nim).
    registerDarkStories()
  let outDir = args[0]
  let wanted =
    if args.len > 1: args[1 .. ^1]
    else: listStories()
  createDir(outDir)
  var entries: seq[JsonNode] = @[]
  try:
    for name in wanted:
      entries.add(buildStory(outDir, name))
  except StoryError as e:
    stderr.writeLine("build-stories: " & e.msg)
    return 1
  writeFile(outDir / "manifest.json",
    $(%*{"stories": entries}) & "\n")
  0

when isMainModule:
  quit(main())
