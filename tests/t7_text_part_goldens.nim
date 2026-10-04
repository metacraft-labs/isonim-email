## The plain-text part of every story.
##
## - Every registered story (the seed set and every capture story set,
##   fixtures included) has a golden text part,
##   `tests/golden/text/<story>.txt`, and renders it byte for byte; no
##   golden is left without its story. A golden is re-recorded only
##   deliberately: `ISONIM_UPDATE_TEXT_GOLDENS=1 just test-file
##   tests/t7_text_part_goldens.nim` writes the current text parts, which
##   are then read and reviewed like any other change.
## - No text part holds markup or CSS: no `<` directly followed by a
##   letter, `/` or `!` (a tag, an end tag, a comment or a doctype), and
##   no CSS declaration (a CSS property name, a colon, a value and a
##   semicolon, or a `{…}` block holding one). A `<` before a space or
##   a digit ("a < b", "<5 minutes") is prose and is not flagged; the
##   detector's own controls pin both sides.
##
## C backend only: reads and writes the golden files.
import std/[os, strutils, unittest]
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

const goldenDir = currentSourcePath().parentDir / "golden" / "text"

registerSeedStories()
registerOverflowStories()
registerSanitiserProbeStory()
registerBrokenStories()
registerContrastFixtures()
registerLayoutStories()
registerPrimitiveStories()
registerLeafStories()
registerButtonStories()
registerTableStories()
registerNavigationStories()
registerRawStories()
registerBackgroundStories()
registerDarkStories()
registerStructureStories()
registerMediaStories()
registerContainerStories()
registerDataStories()
registerActionStories()

const cssProperties = ["color", "background", "background-color",
  "background-image", "border", "border-radius", "border-collapse",
  "display", "font", "font-family", "font-size", "font-weight",
  "line-height", "margin", "padding", "width", "height", "max-width",
  "min-width", "text-align", "text-decoration", "vertical-align",
  "overflow", "opacity", "position", "mso-hide", "color-scheme",
  "word-break", "letter-spacing", "table-layout", "box-sizing"]
  ## The properties whose declarations the generated HTML writes.

proc markupAt(text: string): int =
  ## The offset of the first tag, end tag, comment or doctype opener in
  ## `text`, -1 when there is none.
  for i in 0 ..< text.len - 1:
    if text[i] == '<' and text[i + 1] in Letters + {'/', '!'}:
      return i
  -1

proc cssAt(text: string): int =
  ## The offset of the first CSS declaration in `text`, -1 when there is
  ## none: `prop: value;` or `prop:value;` for a known property or an
  ## `mso-`/`-webkit-` one, or a `{` block with a `:` before its `}`.
  let lower = text.toLowerAscii()
  var i = 0
  while i < lower.len:
    if lower[i] in {'a' .. 'z', '-'} and (i == 0 or lower[i - 1] notin
        {'a' .. 'z', '-', '0' .. '9'}):
      var j = i
      while j < lower.len and lower[j] in {'a' .. 'z', '-'}:
        inc j
      let name = lower[i ..< j]
      if name in cssProperties or name.startsWith("mso-") or
          name.startsWith("-webkit-"):
        var k = j
        while k < lower.len and lower[k] == ' ':
          inc k
        if k < lower.len and lower[k] == ':':
          let stop = lower.find({';', '\n'}, k)
          if stop > k + 1 and lower[stop] == ';':
            return i
      i = j
    else:
      inc i
  let open = lower.find('{')
  if open >= 0:
    let close = lower.find('}', open)
    if close > open and ':' in lower[open .. close]:
      return open
  -1

suite "the text part of every story":
  test "test_text_part_goldens":
    let update = getEnv("ISONIM_UPDATE_TEXT_GOLDENS") == "1"
    var names: seq[string] = @[]
    for s in stories():
      check '/' notin s.name
      names.add(s.name)
      let path = goldenDir / s.name & ".txt"
      let text = s.render().text
      check text.len > 0
      if update:
        createDir(goldenDir)
        writeFile(path, text)
        continue
      check fileExists(path)
      if fileExists(path):
        let golden = readFile(path)
        if text != golden:
          checkpoint("text part of '" & s.name & "' differs from " & path &
            ":\n" & text)
        check text == golden
    check names.len >= 110
    # No golden outlives its story.
    for kind, path in walkDir(goldenDir):
      if path.endsWith(".txt"):
        check path.extractFilename()[0 ..< ^4] in names

  test "test_text_part_goldens_carry_the_mapped_forms":
    # Spot checks across the set: a button is `label: url`, a decorative
    # image is absent, a social icon is `Network: url`, a data table is
    # one line per row, a dark pair's logo is named once, and the canary's
    # preheader is left out.
    let button = getStory("buttonMinimal").render().text
    check "Open dashboard: https://app.example.com/\n" in button
    check "Your account is ready.\n" in button
    let social = getStory("socialMinimal").render().text
    check "GitHub: https://github.example/acme\n" in social
    let table = getStory("tableMinimal").render().text
    check "Item | Qty | Amount\nNotebook | 2 | $12.00\n" in table
    let logo = getStory("darkLogoSwap").render().text
    check logo.count("Acme (https://example.com/)") == 1
    # The feature columns' icons are decorative: each heading opens its
    # column, with nothing in brackets before it.
    let three = getStory("layoutThreeColumns").render().text
    check "one that fits your team.\n\nSecure\n------\n" in three
    check "[]" notin three
    # The canary's preheader repeats its paragraph: the text has it once.
    check getStory("canary").render().text.count(
      "The canary sings at noon.") == 1

  test "test_text_never_contains_html":
    # The detector's controls first: it finds markup and CSS, and it
    # leaves prose comparisons alone.
    check markupAt("a <p>b") == 2
    check markupAt("x </td>") == 2
    check markupAt("<!-- c -->") == 0
    check markupAt("a < b, 3<5, <-") == -1
    check cssAt("x color:#111;") == 2
    check cssAt("Mso-hide: all;") == 0
    check cssAt("p{margin:0}") == 1
    check cssAt("Widget: $10.00\nColor: red\nNote: done; ok") == -1
    for s in stories():
      let text = s.render().text
      let m = markupAt(text)
      if m >= 0:
        checkpoint(s.name & ": markup at " & $m & ": " &
          text[m ..< min(text.len, m + 40)])
      check m < 0
      let c = cssAt(text)
      if c >= 0:
        checkpoint(s.name & ": CSS at " & $c & ": " &
          text[c ..< min(text.len, c + 40)])
      check c < 0
