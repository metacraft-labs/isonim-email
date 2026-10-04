## isonim_email/lower/text.nim — the text leaves' inline defaults.
##
## Plain HTML leaves are the primary text API, and no client styles
## them the same way: a browser's `h1` is 32px with 21px margins,
## Roundcube's page stylesheet (Bootstrap's reboot) makes it 40px at
## weight 500 with no top margin, SnappyMail strips the head and leaves
## the browser default. So every text element carries its own inline
## type, from the theme, and nothing relies on a client default
## (catalogue R-TXT-02, R-TXT-04, R-TXT-09):
##
## | Element | Defaults |
## |---|---|
## | `h1`, `h2`, `h3` | `margin:0 0 {16,12,8}px`, `font-family` (`font.heading`), the `type.h1`…`h3` size, line height and weight |
## | `h4` / `h5`, `h6` | `margin:0 0 8px`, `font.heading`, `type.body` / `type.small` at weight 700 |
## | `p` | `margin:0 0 16px`, the inherited (else `font.body`, `type.body`) family, size and line height |
## | `blockquote` | as `p`, plus `padding:0 0 0 16px` and a `3px solid` start-side border in `color.border.subtle` (mirrored right to left); lowered to a `div` (R-TXT-11) |
## | `pre` | as `p`, in `font.mono` |
## | `ul`, `ol` | `margin:0 0 16px;padding:0;` |
## | `li` | `margin:0 0 8px 24px` (the indent on the start side: right to left, `0 24px 8px 0`), the inherited type |
## | `div` (a grouping block), a `td`/`th` holding text | the inherited type, no margin |
## | `code` | `font.mono` |
##
## Every one of them (lists and `code` aside) also gets
## `overflow-wrap:break-word`: a word too long for its line breaks
## instead of running past the message's edge.
##
## "Inherited" means the nearest ancestor that carries the property
## inline (a `mailText` with `font_size`, the document's `font_family`,
## an enclosing `li`), as CSS inheritance would give it, else the theme.
## A heading's size and weight are its level's, never inherited.
##
## The bottom margin separates a block from the next one, so the last
## element child of its parent gets none (a box or a column then keeps
## the padding it was given on every side), and neither does an item of
## a primitive that spaces its items itself (a `mailStack`'s gap, a
## `mailCluster`'s, a `mailGrid`'s or a `mailColumns` row's gutter, a
## `mailSidebar`'s gap).
##
## An author's own declaration always wins: a default is written only
## for a property the element does not set (a `margin` default is
## skipped when the element sets `margin`; `margin-bottom` alone still
## lands after the default and wins). Given a `font-size` but no
## `line-height`, the line height keeps the ratio of the element's type
## (a 40px `h1` gets 40 × 36 / 28 = 51px), so a larger size never
## overlaps its own lines. The `font` shorthand turns the type defaults
## off.
##
## The defaults are declarations like any other: the style pass (P5,
## `passes/styles.nim`) prepends them to the element's own and
## normalises them, adding `mso-line-height-rule:exactly` beside each px
## line height (R-OL-06). Colours are not set here: the style pass
## gives every text element the colour it would inherit (R-TXT-02) and
## every link its colour and decoration (R-TXT-04), after the
## ancestors' colours are final.
##
## Pure tree reading: identical on the C and JS targets.

import std/[math, strutils, tables, unicode]
import ../renderer
import ../style/tokens
import ../style/units
import ../style/shorthand
import ../style/metrics
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  headingTags* = ["h1", "h2", "h3", "h4", "h5", "h6"]
  typedBlocks = ["p", "blockquote", "pre", "li", "div", "mailtext"]
    ## Blocks that take the inherited type.
  listIndent* = "space.5"
    ## The `li` indent token (24px).
  listItemGap* = "space.2"
    ## The space below an `li` (8px).
  dividerBorderToken* = "color.border.subtle"
    ## The divider's default line colour.

proc headingMargin(tag: string): string =
  case tag
  of "h1": "space.4"
  of "h2": "space.3"
  else: "space.2"

proc headingType(tag: string): tuple[key: string; bold: bool] =
  ## The theme type of a heading level, and whether its weight must be
  ## added (the `type.h*` literals carry their own).
  case tag
  of "h1", "h2", "h3": ("type." & tag, false)
  of "h4": ("type.body", true)
  else: ("type.small", true)

proc isRtl*(node: EmailNode): bool =
  ## True when `node` sits in right-to-left text: the nearest `dir`
  ## attribute or `direction` (attribute or style) on it or above it.
  var n = node
  while n != nil:
    if n.kind == enElement:
      for v in [n.styles.getOrDefault("direction", ""),
          n.attrs.getOrDefault("direction", ""),
          n.attrs.getOrDefault("dir", "")]:
        let s = v.strip().toLowerAscii()
        if s in ["rtl", "ltr"]:
          return s == "rtl"
    n = n.parent
  false

proc isLastElementChild*(node: EmailNode): bool =
  ## True when no element follows `node` among its siblings (text and
  ## comments do not count).
  ## A block that is last inside a `mailIf` or an `htmlOnly` is last
  ## only when the wrapper is (it is transparent: what follows it
  ## follows the block), and a `textOnly`, which writes no HTML, does
  ## not count.
  if node.parent == nil:
    return false
  var seen = false
  for c in node.parent.children:
    if c == node:
      seen = true
    elif seen and c.kind == enElement and c.tag != "textOnly":
      return false
  if seen and node.parent.kind == enElement and
      node.parent.tag in ["mailIf", "htmlOnly"]:
    return isLastElementChild(node.parent)
  seen

proc inherited(node: EmailNode; prop: string): string =
  ## The nearest ancestor's own value of `prop`, "" when none sets it.
  var a = node.parent
  while a != nil:
    if a.kind == enElement:
      let v = a.styles.getOrDefault(prop, "")
      if v.len > 0:
        return v
    a = a.parent
  ""

proc pxOf(value: string; theme: EmailTheme): float =
  ## A length in px (a `tok:` sentinel resolved); 0 when unparseable.
  if not value.startsWith("tok:") and (value.len == 0 or
      (value[0] notin Whitespace and value[^1] notin Whitespace)):
    # Nothing to strip and no sentinel: the value as it is.
    try:
      return toPx(value)
    except StyleError:
      return 0
  var v = value.strip()
  if v.startsWith("tok:"):
    try:
      v = theme.lightFor(v[4 .. ^1])
    except ThemeError:
      return 0
  try:
    toPx(v)
  except StyleError:
    0

proc ratioLineHeight(size: float; specSize, specLine: string;
    theme: EmailTheme): string =
  ## The line height that keeps the spec's ratio at `size` px.
  let s = pxOf(specSize, theme)
  let l = pxOf(specLine, theme)
  if s <= 0 or l <= 0 or size <= 0:
    return specLine
  formatPx(round(size * l / s))

proc flooredLine(lineValue, sizeValue: string; theme: EmailTheme): string =
  ## A default line height never falls below the font's content area
  ## (`style/metrics.minLineHeight`): a tighter one lets the glyphs out
  ## of the line box (R-TXT-02).
  let l = pxOf(lineValue, theme)
  let fs = pxOf(sizeValue, theme)
  if l > 0 and fs > 0 and l < minLineHeight(fs):
    formatPx(minLineHeight(fs))
  else:
    lineValue

proc typeDecls(node: EmailNode; theme: EmailTheme; typeKey: string;
    bold, inherit: bool): seq[tuple[prop, value: string]] =
  ## font-size, line-height (and font-weight) for `node`: from the
  ## nearest ancestor when `inherit` and one sets them, else from the
  ## theme's `typeKey`.
  # The theme's packed literal, as `expandTypeSpec` reads it (a weight
  # only when the literal carries one).
  var spec = parseTypeSpec(theme.lightFor(typeKey))
  var size = move(spec.fontSize)
  var line = move(spec.lineHeight)
  var weight = move(spec.weight)
  if bold and weight.len == 0:
    weight = "700"
  if inherit:
    let s = inherited(node, "font-size")
    if s.len > 0:
      let l = inherited(node, "line-height")
      line = if l.len > 0: l else: ratioLineHeight(pxOf(s, theme), size,
        line, theme)
      size = s
  line = flooredLine(line, size, theme)
  # The node's own styles, read in place (not a copy of the table).
  template own: untyped = node.styles
  if "font-size" notin own:
    result.add(("font-size", size))
    if "line-height" notin own:
      result.add(("line-height", line))
  elif "line-height" notin own:
    result.add(("line-height", flooredLine(ratioLineHeight(
      pxOf(own["font-size"], theme), size, line, theme), own["font-size"],
      theme)))
  if weight.len > 0 and "font-weight" notin own:
    result.add(("font-weight", weight))

proc familyDecl(node: EmailNode; theme: EmailTheme; key: string;
    inherit: bool): seq[tuple[prop, value: string]] =
  if "font-family" in node.styles:
    return
  let a = if inherit: inherited(node, "font-family") else: ""
  result.add(("font-family", if a.len > 0: a else: theme.lightFor(key)))

proc isLayoutItem*(node: EmailNode): bool =
  ## True when `node` is an item of a primitive that spaces its items
  ## itself (a stack's gap, a cluster's, a grid's or a row's gutter, a
  ## sidebar's gap): a margin would add to that spacing.
  node.parent != nil and node.parent.kind == enElement and
    node.parent.tag in ["mailStack", "mailCluster", "mailGrid",
      "mailSidebar", "mailColumns"]

proc marginDecl(node: EmailNode; theme: EmailTheme; gapKey: string;
    indent = false): seq[tuple[prop, value: string]] =
  if "margin" in node.styles:
    return
  let gap = if isLastElementChild(node) or isLayoutItem(node): "0"
    else: theme.lightFor(gapKey)
  if not indent:
    return @[("margin", if gap == "0": "0" else: "0 0 " & gap)]
  let ind = theme.lightFor(listIndent)
  result.add(("margin", if isRtl(node): "0 " & ind & " " & gap & " 0"
    else: "0 0 " & gap & " " & ind))

proc holdsTextDirectly*(node: EmailNode): bool =
  ## True when `node` has a non-blank text child of its own, or text in
  ## a phrase element that is its child (a cell holding only
  ## `<strong>$20</strong>` holds text: the phrase inherits its colour
  ## and type from the cell).
  for c in node.children:
    if c.kind == enText and c.text.strip().len > 0:
      return true
    if c.kind == enElement and c.tag.toLowerAscii() in ["strong", "em", "b",
        "i", "u", "s", "span", "code", "small", "sup", "sub", "codeinline"] and
        holdsTextDirectly(c):
      return true
  false

proc textDefaults*(node: EmailNode;
    theme: EmailTheme): seq[tuple[prop, value: string]] =
  ## The inline defaults `node` lacks (see the module comment), in the
  ## order they are written: margin, padding, family, size, line height,
  ## weight. Empty for every element that is not a text leaf. Raises
  ## `ThemeError` when the theme lacks a key (a theme that loaded has
  ## every key).
  if node == nil or node.kind != enElement:
    return
  let tag = node.tag.toLowerAscii()
  let shorthandFont = "font" in node.styles
  defer:
    # A word too long for its line (a reference, a URL) breaks instead
    # of running past the message's edge; only such a word (R-TXT-02).
    if result.len > 0 and tag notin ["ul", "ol", "code"] and
        "overflow-wrap" notin node.styles and "word-break" notin node.styles:
      result.add(("overflow-wrap", "break-word"))
  if tag in headingTags:
    result.add(marginDecl(node, theme, headingMargin(tag)))
    if not shorthandFont:
      let (key, bold) = headingType(tag)
      result.add(familyDecl(node, theme, "font.heading", true))
      result.add(typeDecls(node, theme, key, bold, false))
  elif tag in ["ul", "ol"]:
    result.add(marginDecl(node, theme, "space.4"))
    if "padding" notin node.styles:
      result.add(("padding", "0"))
  elif tag in typedBlocks:
    case tag
    of "li": result.add(marginDecl(node, theme, listItemGap, indent = true))
    of "div", "mailtext": discard
    of "blockquote":
      result.add(marginDecl(node, theme, "space.4"))
      # A quotation mark on the start side (the element is lowered to a
      # `div`: webmails fold a `blockquote` away as quoted mail).
      let rtl = isRtl(node)
      let pad = theme.lightFor("space.4")
      if "padding" notin node.styles:
        result.add(("padding", if rtl: "0 " & pad & " 0 0" else: "0 0 0 " & pad))
      let side = if rtl: "border-right" else: "border-left"
      if side notin node.styles and "border" notin node.styles:
        result.add((side, "3px solid " & theme.lightFor(dividerBorderToken)))
    else: result.add(marginDecl(node, theme, "space.4"))
    if not shorthandFont:
      result.add(familyDecl(node, theme,
        if tag == "pre": "font.mono" else: "font.body", tag != "pre"))
      result.add(typeDecls(node, theme, "type.body", false, true))
  elif tag in ["td", "th"] and holdsTextDirectly(node):
    if not shorthandFont:
      result.add(familyDecl(node, theme, "font.body", true))
      result.add(typeDecls(node, theme, "type.body", tag == "th", true))
  elif tag == "code" and not shorthandFont:
    result.add(familyDecl(node, theme, "font.mono", false))

proc leafDefaults*(node: EmailNode;
    target: EmailTarget): seq[tuple[prop, value: string]] =
  ## The declarations the style pass prepends to a divider without a
  ## border of its own: `1px solid` in the theme's subtle border colour,
  ## with its dark pair under `darkMode = designed`; and, under
  ## `darkMode = designed`, to an image without a colour of its own: its
  ## alt text's colour (R-IMG-03) with its dark pair, so a blocked
  ## image's alt stays legible on a dark surface. Empty otherwise.
  if node != nil and node.kind == enElement and node.tag == "mailImage":
    if target.darkMode == dmDesigned and "color" notin node.styles:
      result.add(("color", "tok:color.text.secondary"))
      result.add(("@dark:color", "tok:color.text.secondary"))
    return
  if node == nil or node.kind != enElement or node.tag != "mailDivider":
    return
  for k in node.styles.keys:
    if k.startsWith("border"):
      return
  result.add(("border-width", "1px"))
  result.add(("border-style", "solid"))
  result.add(("border-color", "tok:" & dividerBorderToken))
  if target.darkMode == dmDesigned:
    result.add(("@dark:border-color", "tok:" & dividerBorderToken))

const noLinkJoiner* = "\u200D"
  ## The zero-width joiner R-TXT-06 writes between a digit and its
  ## neighbours.

proc noLinkText*(s: string): string =
  ## R-TXT-06: `s` with a zero-width joiner between every digit and the
  ## character next to it, so no run a data detector reads as a phone
  ## number, date or address remains; the text reads and copies the
  ## same.
  var prevDigit = false
  var first = true
  for ch in s.runes:
    let digit = ch.int >= ord('0') and ch.int <= ord('9')
    if not first and (digit or prevDigit):
      result.add(noLinkJoiner)
    result.add($ch)
    prevDigit = digit
    first = false

proc noLinkTexts*(node: EmailNode) =
  ## Applies `noLinkText` to every text node under `node`.
  for c in node.children:
    if c.kind == enText:
      c.text = noLinkText(c.text)
    else:
      noLinkTexts(c)
