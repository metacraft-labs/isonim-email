## isonim_email/lower/button_style.nim — a `mailButton`'s default
## declarations (its tone, variant, padding, type and corner), which
## the style pass prepends to the author's own (see `lower/button.nim`
## for the table of tones and variants). A module of its own because
## the style pass imports it, and the lowering imports the style pass.
##
## Pure tree reading: identical on the C and JS targets.

import std/[math, sequtils, strutils, tables]
import ../renderer
import ../target
import ../style/tokens
import ../style/units
import ../style/shorthand

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  tones* = ["neutral", "primary", "info", "success", "warning", "danger"]
  variants* = ["solid", "outline", "link"]
  outlineBorderPx* = 2
    ## An outline button's border width.

type ToneColours = tuple[fill, onFill, text: string]

proc toneColours*(tone: string): ToneColours =
  ## The theme keys of a tone's fill, the colour on it, and its text
  ## colour on a surface.
  case tone
  of "neutral": ("color.text.primary", "color.text.inverse",
    "color.text.primary")
  of "info": ("color.status.info", "color.text.inverse", "color.link")
  of "success", "warning", "danger": ("color.status." & tone,
    "color.text.inverse", "color.status." & tone)
  else: ("color.accent.primary", "color.accent.primaryText", "color.link")

proc toneOf*(node: EmailNode): string =
  let t = node.attrs.getOrDefault("tone", "primary").strip().toLowerAscii()
  if t in tones: t else: "primary"

proc groupIndex(node: EmailNode): int =
  ## The button's place among the buttons of the `mailButtonGroup` it
  ## sits in (its content, or the row its expansion made of it), -1
  ## outside one.
  var g = node.parent
  var depth = 0
  while g != nil and depth < 6:
    if g.kind == enElement and g.tag == "mailButtonGroup":
      break
    g = g.parent
    inc depth
  if g == nil or g.kind != enElement or g.tag != "mailButtonGroup":
    return -1
  var i = 0
  proc walk(x: EmailNode): int =
    if x.kind != enElement:
      return -1
    if x.tag == "mailButton":
      if x == node:
        return i
      inc i
      return -1
    for c in x.children:
      let f = walk(c)
      if f >= 0:
        return f
    -1
  walk(g)

proc variantOf*(node: EmailNode): string =
  ## The button's variant; without one of its own, `solid`, except in a
  ## `mailButtonGroup`, whose first button is the primary action
  ## (`solid`) and the rest secondary (`outline`, layout-patterns.md
  ## §4.5).
  let own = node.attrs.getOrDefault("variant", "").strip().toLowerAscii()
  if own in variants:
    return own
  if own.len == 0 and groupIndex(node) > 0:
    return "outline"
  "solid"

proc hasAny(node: EmailNode; keys: openArray[string]): bool =
  for k in keys:
    if k in node.styles:
      return true
  false

proc inheritedFamily(node: EmailNode): string =
  var a = node.parent
  while a != nil:
    if a.kind == enElement:
      let v = a.styles.getOrDefault("font-family", "")
      if v.len > 0:
        return v
    a = a.parent
  ""

proc buttonDefaults*(node: EmailNode; theme: EmailTheme;
    target: EmailTarget): seq[tuple[prop, value: string]] =
  ## The declarations the style pass prepends to a `mailButton` (see
  ## the module comment); empty for every other element. Raises
  ## `ThemeError` when the theme lacks a key.
  if node == nil or node.kind != enElement or node.tag != "mailButton":
    return
  let variant = variantOf(node)
  let tc = toneColours(toneOf(node))
  let dark = target.darkMode == dmDesigned
  proc paint(res: var seq[tuple[prop, value: string]]; prop, key: string) =
    res.add((prop, "tok:" & key))
    if dark:
      res.add(("@dark:" & prop, "tok:" & key))
  let ownBorder = node.hasAny(["border", "border-width", "border-style",
    "border-color"])
  case variant
  of "solid":
    if "background-color" notin node.styles:
      result.paint("background-color", tc.fill)
    if "color" notin node.styles:
      result.paint("color", tc.onFill)
  of "outline":
    if "color" notin node.styles:
      result.paint("color", tc.text)
    if not ownBorder:
      result.add(("border-width", $outlineBorderPx & "px"))
      result.add(("border-style", "solid"))
      result.paint("border-color", tc.text)
  else:
    if "color" notin node.styles:
      result.paint("color", tc.text)
    if "text-decoration" notin node.styles:
      result.add(("text-decoration", "underline"))
  if variant != "link" and "border-radius" notin node.styles:
    result.add(("border-radius", theme.lightFor("radius.md")))
  if not node.hasAny(["padding", "padding-top", "padding-right",
      "padding-bottom", "padding-left"]):
    var pad = theme.lightFor("button.padding")
    if variant == "outline" and not ownBorder:
      # The border takes its width out of the padding: an outline
      # button is as large as a solid one.
      try:
        let s = expandBox(pad)
        var sides: array[4, int]
        for i in 0 .. 3:
          sides[i] = max(0, int(round(toPx(s[i]))) - outlineBorderPx)
        pad = sides.mapIt(formatPx(float(it))).join(" ")
      except StyleError:
        discard
    result.add(("padding", pad))
  if "font" notin node.styles:
    if "font-family" notin node.styles:
      let fam = inheritedFamily(node)
      result.add(("font-family",
        if fam.len > 0: fam else: theme.lightFor("font.body")))
    var size, line: float
    let spec = expandTypeSpec(theme.lightFor("button.font"))
    for (p, v) in spec:
      try:
        if p == "font-size": size = toPx(v)
        elif p == "line-height": line = toPx(v)
      except StyleError:
        discard
    for (p, v) in spec:
      if p in node.styles:
        continue
      if p == "line-height" and "font-size" in node.styles:
        # A size of the author's own keeps the theme's ratio of line
        # height to size.
        var own = 0.0
        try:
          own = toPx(node.styles["font-size"])
        except StyleError:
          discard
        if own > 0 and size > 0 and line > 0:
          result.add((p, formatPx(round(own * line / size))))
        continue
      result.add((p, v))


proc wordForm*(node: EmailNode): string =
  ## How Word gets the button, read from its styled props: `vml` (a
  ## `v:roundrect`: `vml = always`, or `auto` with a radius and a px
  ## width), `spacers` (`word_padding = spacers`) or `table` (the table
  ## button). A `link` button is always `table`.
  let wp = node.attrs.getOrDefault("word_padding", "cell").strip().
    toLowerAscii()
  if wp == "spacers":
    return "spacers"
  if variantOf(node) == "link":
    return "table"
  let vml = node.attrs.getOrDefault("vml", "auto").strip().toLowerAscii()
  if vml == "always":
    return "vml"
  if vml != "auto":
    return "table"
  let radius = node.styles.getOrDefault("border-radius", "").strip()
  let width = node.styles.getOrDefault("width", "").strip()
  var rounded = false
  try:
    rounded = radius.len > 0 and toPx(radius) > 0
  except StyleError:
    discard
  var pxWidth = false
  if width.len > 0 and not width.endsWith("%"):
    try:
      pxWidth = toPx(width) > 0
    except StyleError:
      discard
  if rounded and pxWidth: "vml" else: "table"
