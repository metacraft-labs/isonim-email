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
##
## Two other modes serve the preview server (`just email-preview`):
## - `build-stories --list` prints the registered stories as JSON
##   (`{"stories": [{"story", "group", "description"}…]}`) and renders
##   nothing;
## - `build-stories --preview <outDir> [STORY…]` writes each story's
##   `<story>.html` and `<story>.txt`, and a manifest whose entries also
##   carry the story's group, description, every diagnostic its render
##   collected (with its source span) and, for a story whose render
##   refused it, the error instead of files. No MIME is assembled, and a
##   refused story does not stop the others.
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
import stories/seed_structure
import stories/seed_media
import stories/seed_containers
import stories/seed_data
import stories/seed_actions
import stories/seed_markdown
import stories/seed_reference
import stories/seed_domain
import stories/seed_markup

# `mime_sha256` uses the library's `sha256Hex`
# (`src/isonim_email/assets.nim`, re-exported by the umbrella). The
# FIPS "abc" vector is pinned by `tests/t6_assets` through
# `hostedPath`.

const fixedDateSecs = 1767268800'i64
  ## 2026-01-01T12:00:00Z in unix seconds — the capture clock.

proc buildStory(outDir, name: string): JsonNode =
  let story = getStory(name) # Raises StoryError naming the known set.
  let (html, text) = story.render()
  # Story texts are the plain-text pass's flowed form (soft breaks
  # end in a space).
  let rendered = RenderedEmail(html: html, text: text,
    textFlowed: text.len > 0)
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

proc diagnosticJson(d: EmailDiagnostic): JsonNode =
  %*{"severity": $d.severity, "code": d.code, "message": d.message,
     "file": d.origin.file, "line": d.origin.line, "col": d.origin.col,
     "rules": d.rules}

proc previewStory(outDir, name: string): JsonNode =
  ## One story for the preview server: its files when it rendered, its
  ## diagnostics either way.
  let story = getStory(name)
  let res = renderStoryDiagnosed(story)
  var diags = newJArray()
  for d in res.diagnostics:
    diags.add(diagnosticJson(d))
  result = %*{"story": name, "group": story.group,
    "description": story.description, "diagnostics": diags}
  if res.error.len > 0:
    result["error"] = %res.error
    return
  let htmlPath = outDir / name & ".html"
  createDir(parentDir(htmlPath))
  writeFile(htmlPath, res.html)
  writeFile(outDir / name & ".txt", res.text)
  result["html"] = %(name & ".html")
  result["text"] = %(name & ".txt")

proc main(): int =
  var args = commandLineParams()
  let listOnly = args.len > 0 and args[0] == "--list"
  let preview = args.len > 0 and args[0] == "--preview"
  if listOnly or preview:
    args = args[1 .. ^1]
  if args.len < 1 and not listOnly:
    stderr.writeLine("usage: build-stories [--preview] <outDir> [STORY…]\n" &
      "       build-stories --list")
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
    # The content patterns' story sets (tests/stories/seed_structure.nim,
    # seed_media.nim, seed_containers.nim, seed_data.nim,
    # seed_actions.nim).
    registerStructureStories()
    registerMediaStories()
    registerContainerStories()
    registerDataStories()
    registerActionStories()
    # The Markdown bodies' story set (tests/stories/seed_markdown.nim)
    # and the reference emails (examples/reference_set.nim, through
    # tests/stories/seed_reference.nim).
    registerMarkdownStories()
    registerReferenceStories()
    # The domain view stories (tests/stories/seed_domain.nim: the
    # invoice email of examples/invoice_summary_email.nim).
    registerDomainStories()
    # The Gmail markup stories (tests/stories/seed_markup.nim: two
    # reference emails with JSON-LD in the head).
    registerMarkupStories()
  if listOnly:
    var list = newJArray()
    for s in stories():
      list.add(%*{"story": s.name, "group": s.group,
        "description": s.description})
    stdout.write($(%*{"stories": list}) & "\n")
    return 0
  let outDir = args[0]
  let wanted =
    if args.len > 1: args[1 .. ^1]
    else: listStories()
  createDir(outDir)
  var entries: seq[JsonNode] = @[]
  try:
    for name in wanted:
      entries.add(if preview: previewStory(outDir, name)
        else: buildStory(outDir, name))
  except StoryError as e:
    stderr.writeLine("build-stories: " & e.msg)
    return 1
  writeFile(outDir / "manifest.json",
    $(%*{"stories": entries}) & "\n")
  0

when isMainModule:
  quit(main())
