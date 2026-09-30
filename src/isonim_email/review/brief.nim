## isonim_email/review/brief.nim — the review-brief generator.
##
## Renders the "expected on the screenshot" block for one
## (story, family, viewport, scheme) from the story's rendered semantic
## tree: the authoring tree through validate → P5 styles → P7 a11y (the
## `renderPipeline` passes up to lowering — lowering consumes the tree,
## so the brief stops before it). `tools/review/brief_driver.nim` emits
## one `brief-<family>-<viewport>-<scheme>.md` per combination; the
## static half of the brief is
## `tools/review/email-visual-review-brief.md`.
##
## Trees reach the brief through a side registry (`registerStoryTree`):
## `Story` fuses template + data into a bytes-only `render` closure
## (stories.nim), so the semantic tree is registered alongside by the
## driver and the tests. A story without one fails loudly.
##
## Pure tree building plus pure passes: identical on the C and JS
## targets.

import std/[strutils, tables, unicode]
import ../renderer
import ../stories
import ../target
import ../diagnostics
import ../passes/lint
import ../passes/validate
import ../passes/styles
import ../passes/a11y
import ../style/tokens

type
  StoryTreeProc* = proc(): EmailNode {.closure.}
    ## Builds a fresh semantic tree for a story (one call per brief:
    ## the passes mutate, so trees are never shared).

  BriefError* = object of ValueError
    ## Unknown brief family, or a story with no registered tree.

var storyTrees = initTable[string, StoryTreeProc]()

proc registerStoryTree*(name: string; build: StoryTreeProc) =
  ## Registers the tree builder for `name`. Re-registering replaces:
  ## tests re-register fixtures freely.
  if name.len == 0:
    raise newException(BriefError, "story name must not be empty")
  if build == nil:
    raise newException(BriefError,
      "story '" & name & "' has no tree builder")
  storyTrees[name] = build

proc hasStoryTree*(name: string): bool =
  ## True when `name` has a registered tree builder.
  name in storyTrees

# ----------------------------------------------------------------------------
# Capture-matrix mirror (duplicate by design)
# ----------------------------------------------------------------------------
# Families, viewports and schemes repeat the `email-shots.ts` matrix
# constants (`FAMILIES`, `NAMED_VIEWPORTS`, the default `--schemes`):
# TS/Nim sharing is awkward, so the two are duplicated with this
# comment — update both together. The dark stance, display names and
# backend labels below are the brief's own working table.

const briefFamilies* = ["apple", "thunderbird", "chromium-baseline",
  "gmailWeb", "ganga", "outlookWeb", "imagesOff", "wordApprox"]
  ## Backend-A capture families (mirrors `FAMILIES`).

const briefViewports* = [("mobile", 375), ("desktop", 800)]
  ## Named viewports (mirrors `NAMED_VIEWPORTS`).

const briefSchemes* = ["light", "dark", "forced-dark"]
  ## Colour schemes (mirrors the `--schemes` vocabulary).

proc checkFamily(family: string) =
  if family notin briefFamilies:
    raise newException(BriefError, "unknown brief family '" & family &
      "' (known: " & briefFamilies.join(", ") & ")")

proc familyApproximation*(family: string): bool =
  ## True when backend A emulates the family (mirrors the
  ## `approximation` flag of `FAMILIES`).
  checkFamily(family)
  family != "apple"

proc familyHonoursDark*(family: string): bool =
  ## True when the family applies dark mode to the body. Gmail web
  ## does not; GANGA strips all head CSS, so `@dark` head rules
  ## cannot apply (families.nim); the Word engine has no email dark
  ## mode. `imagesOff` inherits Chromium: the transform only swaps
  ## images for alt-text boxes.
  checkFamily(family)
  family notin ["gmailWeb", "ganga", "wordApprox"]

proc familyDisplay*(family: string): string =
  ## The family name as readers see it in the "Not expected" line.
  checkFamily(family)
  case family
  of "apple": "Apple Mail"
  of "thunderbird": "Thunderbird"
  of "chromium-baseline": "the baseline engine"
  of "gmailWeb": "Gmail web"
  of "ganga": "GANGA"
  of "outlookWeb": "Outlook web"
  of "imagesOff": "images-off rendering"
  else: "Word-engine Outlook" # wordApprox; checkFamily ruled out else

proc familyLintFamily*(family: string): tuple[found: bool;
    fam: ClientFamily] =
  ## The `ClientFamily` whose declared degradations apply to `family`.
  ## `wordApprox` reads `cfOutlookWord` (it approximates classic
  ## Outlook — never a stand-in for Word);
  ## `imagesOff`
  ## and `chromium-baseline` have none (alt-text path / no
  ## degradations).
  checkFamily(family)
  case family
  of "apple": (true, cfApple)
  of "thunderbird": (true, cfThunderbird)
  of "gmailWeb": (true, cfGmailWeb)
  of "ganga": (true, cfGanga)
  of "outlookWeb": (true, cfOutlookWeb)
  of "wordApprox": (true, cfOutlookWord)
  else: (false, cfApple)

proc viewportWidth*(viewport: string): int =
  ## The layout width: named widths from `NAMED_VIEWPORTS`, else the
  ## leading number of a custom viewport (`600@2x` → 600), else the
  ## target breakpoint.
  for (name, width) in briefViewports:
    if viewport == name:
      return width
  var width = 0
  var digits = 0
  for c in viewport:
    if c notin {'0' .. '9'}:
      break
    width = width * 10 + (c.ord - '0'.ord)
    inc digits
    if width > 100_000:
      break
  if digits > 0:
    return width
  defaultTarget().breakpoint

proc viewportLabel*(viewport: string): string =
  ## `mobile 375` for named viewports, the token as-is otherwise.
  for (name, width) in briefViewports:
    if viewport == name:
      return name & " " & $width
  viewport

proc declaredDegradations*(): seq[ExpectedDegradation] =
  ## The components' declared fallbacks known so far. Component work
  ## extends this list with the CSS their lowering emits (the lint.nim
  ## seed precedent).
  @[
    expectDegradation(lkProperty, "border-radius", {cfOutlookWord},
      "button corners render square; only the label text is a link " &
      "(R-BTN-02)"),
  ]

# ----------------------------------------------------------------------------
# Tree readers
# ----------------------------------------------------------------------------

proc normKey(key: string): string =
  ## Style-key comparison form: lower-cased, `@variant:` prefix
  ## dropped, snake_case folded to kebab-case. The brief walks the
  ## pre-lowering tree either side of P5 normalisation, so both
  ## spellings match.
  var k = key.toLowerAscii()
  if k.startsWith("@"):
    let sep = k.find(':')
    if sep > 0:
      k = k[sep + 1 .. ^1]
  k.replace("_", "-")

proc styleValue(node: EmailNode; prop: string): string =
  ## First style value for `prop` under either spelling, or "".
  let want = normKey(prop)
  for key, value in node.styles.pairs:
    if normKey(key) == want:
      return value
  ""

proc attrValue(node: EmailNode; name: string): string =
  ## First attribute value for `name` (case-insensitive), or "".
  let want = name.toLowerAscii()
  for key, value in node.attrs.pairs:
    if key.toLowerAscii() == want:
      return value
  ""

proc collectText(node: EmailNode): string =
  ## Every descendant `enText` payload in document order (the lint.nim
  ## collector, restated — that one is private).
  if node == nil:
    return ""
  if node.kind == enText:
    return node.text
  for c in node.children:
    result.add(collectText(c))

proc tagLower(node: EmailNode): string =
  if node.kind == enElement: node.tag.toLowerAscii() else: ""

proc docBackground(doc: EmailNode): string =
  ## The document background, mirroring lower/document.nim's fallback
  ## order (attrs, then styles, then the `#ffffff` default).
  let a = attrValue(doc, "background_color")
  if a.len > 0:
    return a
  let s = styleValue(doc, "background-color")
  if s.len > 0:
    return s
  "#ffffff"

proc splitSize(value: string): tuple[num, unit: string] =
  var i = 0
  while i < value.len and value[i] in {'0' .. '9', '.', ' '}:
    inc i
  (value[0 ..< i].strip(), value[i .. ^1].strip().toLowerAscii())

proc formatSize(value: string): string =
  ## `140px` → `140 px`; anything else passes through.
  let (num, unit) = splitSize(value)
  if num.len > 0 and unit in ["px", "em", "rem", "pt"]:
    num & " " & unit
  else:
    value

proc joinNames(names: seq[string]): string =
  case names.len
  of 0: ""
  of 1: names[0]
  of 2: names[0] & " and " & names[1]
  else: names[0 .. ^2].join(", ") & " and " & names[^1]

# ----------------------------------------------------------------------------
# Present-list lines (one per element, in document order)
# ----------------------------------------------------------------------------

proc headingLine(node: EmailNode; firstH1: var bool): string =
  let text = collectText(node).strip()
  if tagLower(node) == "h1":
    if not firstH1:
      firstH1 = true
      return "Heading \"" & text & "\" (largest text)."
    return "Heading \"" & text & "\"."
  "Heading " & tagLower(node) & " \"" & text & "\"."

proc paragraphLine(node: EmailNode): string =
  let text = collectText(node).strip()
  const maxLen = 45
  let shown =
    if text.runeLen > maxLen: text.runeSubStr(0, maxLen) & "…"
    else: text
  "Paragraph beginning \"" & shown & "\"."

proc buttonLine(node: EmailNode): string =
  let label = collectText(node).strip()
  let title =
    if label.len > 0: "\"" & label & "\""
    else: "(no label)"
  var parts: seq[string] = @[]
  let bg = styleValue(node, "background-color")
  if bg.len > 0:
    parts.add("filled " & bg)
  else:
    parts.add("no fill")
  let fg = styleValue(node, "color")
  if fg.len > 0:
    parts.add(fg & " label")
  let rad = styleValue(node, "border-radius")
  if rad.len > 0:
    parts.add("rounded " & rad)
  if styleValue(node, "width").strip() == "100%":
    parts.add("full-width")
  "Button " & title & ": " & parts.join(", ") & "."

proc imageLine(node: EmailNode; bg: string): tuple[line, alt: string] =
  let alt = attrValue(node, "alt")
  let shown = if alt.len > 0: alt else: "(no alt)"
  var role = "Image"
  if "logo" in alt.toLowerAscii():
    role = "Logo image"
  elif "hero" in alt.toLowerAscii():
    role = "Hero image"
  var parts: seq[string] = @[]
  var width = styleValue(node, "width")
  if width.len == 0:
    width = attrValue(node, "width")
  if width.len > 0:
    parts.add("~" & formatSize(width) & " wide")
  var height = styleValue(node, "height")
  if height.len == 0:
    height = attrValue(node, "height")
  if height.len > 0:
    parts.add(formatSize(height) & " tall")
  let align = attrValue(node, "align")
  if align.len > 0:
    parts.add(align & "-aligned")
  parts.add("on " & bg)
  (role & " \"" & shown & "\", " & parts.join(", ") & ".", alt)

proc countTag(node: EmailNode; tag: string): int =
  if node == nil:
    return 0
  if tagLower(node) == tag:
    inc result
  for c in node.children:
    result += countTag(c, tag)

proc tableLine(node: EmailNode; width, breakpoint: int): string =
  let rows = countTag(node, "tr")
  var title = "Table"
  let caption = attrValue(node, "caption")
  if caption.len > 0:
    title &= " \"" & caption & "\""
  result = title & ": " & $rows &
    (if rows == 1: " row." else: " rows.")
  if tagLower(node) == "mailtable":
    case attrValue(node, "mobile").toLowerAscii()
    of "stack":
      if width < breakpoint:
        result &= " **Stacked** (label: value) at this width."
    of "scroll":
      if width < breakpoint:
        result &= " Scrolls horizontally at this width."
    else:
      discard

proc columnCount(node: EmailNode): int =
  for c in node.children:
    if tagLower(c) == "mailcolumn":
      inc result
  if result == 0:
    for c in node.children:
      if c.kind == enElement:
        inc result

proc columnsLine(node: EmailNode; width, breakpoint: int): string =
  ## Stacked vs side-by-side from the viewport width and the
  ## `mailColumns`/`stack` attrs: `strategy=cells` and `stack=never`
  ## never stack; anything else stacks below the target breakpoint.
  let stacked =
    if tagLower(node) == "mailcolumns":
      attrValue(node, "strategy").toLowerAscii() != "cells" and
        width < breakpoint
    else:
      attrValue(node, "stack").toLowerAscii() != "never" and
        width < breakpoint
  "Columns (" & $columnCount(node) & "): " &
    (if stacked: "stacked" else: "side-by-side") & " at this width."

proc walkItems(node: EmailNode; bg: string; width, breakpoint: int;
               items: var seq[string]; images: var seq[string];
               firstH1: var bool) =
  ## Present-list lines plus image alts, in document order. Containers
  ## recurse silently; only `mailColumns` (and multi-column
  ## `mailSection`) add an arrangement line of their own.
  if node == nil:
    return
  if node.kind != enElement:
    for c in node.children:
      walkItems(c, bg, width, breakpoint, items, images, firstH1)
    return
  var curBg = bg
  let nodeBg = styleValue(node, "background-color")
  if nodeBg.len > 0:
    curBg = nodeBg
  case tagLower(node)
  of "h1", "h2", "h3", "h4", "h5", "h6":
    items.add(headingLine(node, firstH1))
  of "p", "mailtext":
    items.add(paragraphLine(node))
  of "mailbutton", "button":
    items.add(buttonLine(node))
  of "mailimage", "img":
    let (line, alt) = imageLine(node, curBg)
    items.add(line)
    images.add(alt)
  of "mailtable", "table":
    items.add(tableLine(node, width, breakpoint))
  of "mailcolumns":
    items.add(columnsLine(node, width, breakpoint))
    for c in node.children:
      walkItems(c, curBg, width, breakpoint, items, images, firstH1)
  of "mailsection":
    var cols = 0
    for c in node.children:
      if tagLower(c) == "mailcolumn":
        inc cols
    if cols >= 2:
      items.add(columnsLine(node, width, breakpoint))
    for c in node.children:
      walkItems(c, curBg, width, breakpoint, items, images, firstH1)
  else:
    for c in node.children:
      walkItems(c, curBg, width, breakpoint, items, images, firstH1)

proc linksUnder(node: EmailNode; acc: var seq[tuple[text, href: string]]) =
  ## (text, href) of every `a`/`mailNavLink` in document order.
  if node == nil:
    return
  if tagLower(node) in ["a", "mailnavlink"]:
    let text = collectText(node).strip()
    acc.add((text, attrValue(node, "href")))
  for c in node.children:
    linksUnder(c, acc)

proc footerLine(doc: EmailNode): string =
  ## The last top-level child bearing links is the footer; the line
  ## names its links and the unsubscribe presence.
  var links: seq[tuple[text, href: string]] = @[]
  for c in doc.children:
    var found: seq[tuple[text, href: string]] = @[]
    linksUnder(c, found)
    if found.len > 0:
      links = found
  if links.len == 0:
    return "Footer: none (no links, no unsubscribe)."
  var names: seq[string] = @[]
  var unsub = false
  for (text, href) in links:
    names.add("\"" & (if text.len > 0: text else: "(no text)") & "\"")
    if "unsub" in text.toLowerAscii() or "unsub" in href.toLowerAscii():
      unsub = true
  "Footer: links " & joinNames(names) & "; " &
    (if unsub: "unsubscribe link present." else: "no unsubscribe link.")

proc darkOverrides(doc: EmailNode): tuple[bg, fg: seq[string]] =
  ## Distinct `@dark:` background/text colours, first-seen. Read off
  ## the pre-pass tree: P5 splits variants out into head declarations.
  if doc == nil:
    return (@[], @[])
  if doc.kind == enElement:
    for key, value in doc.styles.pairs:
      if key.toLowerAscii().startsWith("@dark:"):
        case normKey(key)
        of "background-color":
          if value notin result.bg:
            result.bg.add(value)
        of "color":
          if value notin result.fg:
            result.fg.add(value)
        else:
          discard
  for c in doc.children:
    let sub = darkOverrides(c)
    for v in sub.bg:
      if v notin result.bg:
        result.bg.add(v)
    for v in sub.fg:
      if v notin result.fg:
        result.fg.add(v)

proc darkLine(dark: tuple[bg, fg: seq[string]]; scheme: string): string =
  var parts: seq[string] = @[]
  if dark.bg.len > 0:
    parts.add("background " & dark.bg.join(", "))
  if dark.fg.len > 0:
    parts.add("text " & dark.fg.join(", "))
  if parts.len == 0:
    return "Dark palette (" & scheme &
      "): no @dark overrides — same as light."
  "Dark palette (" & scheme & "): " & parts.join(", ") & "."

# ----------------------------------------------------------------------------
# Declared degradations
# ----------------------------------------------------------------------------

proc stylePresent(node: EmailNode; prop, value: string): bool =
  if node == nil:
    return false
  if node.kind == enElement:
    let want = normKey(prop)
    for key, got in node.styles.pairs:
      if normKey(key) == want and
          (value.len == 0 or
            got.strip().toLowerAscii() == value.strip().toLowerAscii()):
        return true
  for c in node.children:
    if stylePresent(c, prop, value):
      return true
  false

proc tagPresent(node: EmailNode; tag: string): bool =
  if node == nil:
    return false
  if tagLower(node) == tag.toLowerAscii():
    return true
  for c in node.children:
    if tagPresent(c, tag):
      return true
  false

proc attrPresent(node: EmailNode; name: string): bool =
  if node == nil:
    return false
  if node.kind == enElement and attrValue(node, name).len > 0:
    return true
  for c in node.children:
    if attrPresent(c, name):
      return true
  false

proc declarationApplies(doc: EmailNode; d: ExpectedDegradation): bool =
  ## True when the declaration's construct appears in the tree. Names
  ## match in the declaration key space (lint.nim), with `_`/`-`
  ## folded: the tree may sit either side of P5 normalisation.
  case d.kind
  of lkProperty:
    stylePresent(doc, d.name, "")
  of lkValue:
    let sep = d.name.find('=')
    if sep <= 0:
      return false
    stylePresent(doc, d.name[0 ..< sep], d.name[sep + 1 .. ^1])
  of lkElement:
    tagPresent(doc, d.name)
  of lkAttribute:
    attrPresent(doc, d.name)
  of lkSelector, lkAtRule:
    # Head-CSS matching needs the P6 tree; the brief stops before
    # lowering, so no selector/at-rule declaration can apply here.
    # (None is declared yet.)
    false

proc degradationLines(family: string; doc: EmailNode;
                      images: seq[string]): seq[string] =
  ## `imagesOff` names the alt texts replacing images; every other
  ## family lists the declared degradations whose construct the tree
  ## carries.
  if family == "imagesOff":
    for alt in images:
      result.add("\"" & (if alt.len > 0: alt else: "(no alt)") &
        "\" shown as alt text (images off)")
    if result.len == 0:
      result.add("(none)")
    return
  let (found, fam) = familyLintFamily(family)
  if found:
    for d in declaredDegradations():
      if fam in d.families and declarationApplies(doc, d):
        result.add(if d.note.len > 0: d.note
                   else: d.name & " degrades as declared")
  if result.len == 0:
    result.add("(none)")

proc notExpectedLine(family: string; images: seq[string]): string =
  var parts: seq[string] = @[]
  if not familyHonoursDark(family):
    parts.add("dark colours (" & familyDisplay(family) &
      " does not apply dark mode to the body)")
  if family == "imagesOff" and images.len > 0:
    var alts: seq[string] = @[]
    for alt in images:
      alts.add("\"" & (if alt.len > 0: alt else: "(no alt)") & "\"")
    parts.add("hero images (shown as alt text: " & alts.join(", ") & ")")
  if parts.len == 0:
    "(none)"
  else:
    parts.join("; ")

# ----------------------------------------------------------------------------
# The block
# ----------------------------------------------------------------------------

proc renderedTree(story: Story): tuple[doc: EmailNode;
    dark: tuple[bg, fg: seq[string]]] =
  ## The story's rendered semantic tree: a fresh builder tree through
  ## validate → P5 → P7, plus the pre-pass `@dark:` snapshot.
  if story.name notin storyTrees:
    raise newException(BriefError, "story '" & story.name &
      "' has no registered tree builder" &
      " — register one with registerStoryTree")
  let build = storyTrees[story.name]
  let doc = build()
  let dark = darkOverrides(doc)
  let found = validate(doc)
  if hasErrors(found):
    raise newException(BriefError, "story '" & story.name &
      "' tree failed validation: " & $found.len &
      " diagnostic(s), first: " & found[0].message)
  discard applyStyles(doc, defaultTheme(), defaultTarget())
  discard applyA11y(doc)
  (doc, dark)

proc expectedBlock*(story: Story; family, viewport, scheme: string): string =
  ## The expected-screenshot block for one (story, family, viewport,
  ## scheme): the `Present, top to bottom` list from the rendered
  ## semantic tree, the family's declared degradations, and what is
  ## not expected here. Ends with a newline (file-ready).
  checkFamily(family)
  let width = viewportWidth(viewport)
  let breakpoint = defaultTarget().breakpoint
  let (doc, dark) = renderedTree(story)
  var items: seq[string] = @[]
  var images: seq[string] = @[]
  var firstH1 = false
  walkItems(doc, docBackground(doc), width, breakpoint, items, images,
    firstH1)
  items.add(footerLine(doc))
  if familyHonoursDark(family) and scheme != "light":
    items.add(darkLine(dark, scheme))
  let backendKind =
    if familyApproximation(family): "emulation" else: "local engine"
  result = "### Expected: " & story.name & " — " & family & " — " &
    viewportLabel(viewport) & " — " & scheme & " — backend A (" &
    backendKind & ")\n"
  result.add("\nPresent, top to bottom:\n")
  for i, item in items:
    result.add($(i + 1) & ". " & item & "\n")
  result.add("\nExpected degradations in this client:\n")
  for d in degradationLines(family, doc, images):
    result.add("- " & d & "\n")
  result.add("\nNot expected here: " & notExpectedLine(family, images) &
    ".\n")

proc numberedItems(`block`: string): seq[string] =
  ## The `N. text` items of an expected block, numbers stripped. Only
  ## the `Present` list is numbered (degradations are `-` bullets),
  ## so every numbered line anywhere in the block is an element.
  for line in `block`.splitLines():
    let stripped = line.strip()
    var i = 0
    while i < stripped.len and stripped[i] in {'0' .. '9'}:
      inc i
    if i > 0 and i + 1 < stripped.len and stripped[i] == '.' and
        stripped[i + 1] == ' ':
      result.add(stripped[i + 2 .. ^1])

proc diffExpectedBlocks*(baseline, current: string): seq[string] =
  ## Baseline `Present` items absent from the current block, in
  ## baseline order — the mechanical half of methodology checklist
  ## item 7 (a reviewer diffing what was approved against what the
  ## tree renders now). Item identity is the full line text.
  let now = numberedItems(current)
  for item in numberedItems(baseline):
    if item notin now:
      result.add(item)
