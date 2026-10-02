## isonim_email/lower/leaves.nim — `mailSpacer`, `mailDivider`,
## `mailText`.
##
## **Spacer** (`height`, default `space.4`, 16px): a block exactly
## `height` px tall that holds nothing a reader sees.
##
## ```html
## <!--[if mso]><table …><tr><td height="{h}" aria-hidden="true" style="height:{h}px;font-size:0;line-height:0;mso-line-height-rule:exactly;">&nbsp;</td></tr></table><![endif]-->
## <!--[if !mso]><!--><div aria-hidden="true" style="height:{h}px;line-height:{h}px;font-size:{h}px;">&#8202;</div><!--<![endif]-->
## ```
##
## The div holds a hair space at its own height in font size and line
## height, so no client collapses it (an empty block is dropped by
## some) and no client's minimum font size makes it taller. Word gets a
## sized table cell instead (R-TBL-05), the same spacer row the stacks
## use. Without `outlookWord` only the div is written.
##
## **Divider** (`border`, default `1px solid` `color.border.subtle`;
## `padding`, default `16px 0`; `width`, default 100%; `align`, default
## centre), after MJML's `mj-divider`: a paragraph whose top border is
## the line, in a padded block, and for Word a table with a px width
## (Word ignores the paragraph's width) inside a padded ghost cell:
##
## ```html
## <!--[if mso]><table …><tr><td style="padding:{pad};"><![endif]-->
## <!--[if mso]><table role="presentation" align="center" … width="{px}" style="width:{px}px;border-top:{border};">…</table><![endif]-->
## <!--[if !mso]><!--><div style="padding:{pad};"><p style="border-top:{border};font-size:1px;line-height:0;margin:0 auto;width:{w};">&nbsp;</p></div><!--<![endif]-->
## <!--[if mso]></td></tr></table><![endif]-->
## ```
##
## The paragraph is hidden from Word, so Word draws one line, the
## table's. The paragraph holds a no-break space at a line height of
## zero: never empty (some sanitisers drop empty elements), never
## taller than its border. A `width` in px or % is the line's; Word's
## px width is that share of the box the divider sits in, less its
## padding. The border's colour comes from the style pass, which gives
## a divider without a border the theme's default and, under
## `darkMode = designed`, its dark pair as a class (R-DRK-02) that the
## paragraph carries.
##
## **mailText** (`padding`, `align`, `color`, `font_family`,
## `font_size`, `font_weight`, `line_height`): a convenience block for
## rich text, a `div` carrying its padding, alignment and type, and for
## Word a padded ghost cell (R-TBL-02: Word ignores a div's padding).
## Its children are ordinary text leaves: their defaults (`lower/text`)
## inherit the block's type.
##
## Ghost tables come from `mso/ghost.nim` only. Pure tree building:
## identical on the C and JS targets.

import std/[math, strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/tokens
import ../style/units
import ../style/shorthand
import ../passes/layout
import ../mso/cond
import ../mso/ghost
import ./section
import ./text

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  spacerDefault* = "space.4"
    ## The spacer's default height token (16px).
  dividerPadding* = "16px 0"
    ## The divider's default padding.

proc pxLen(value: string): int =
  try:
    int(round(toPx(value)))
  except StyleError:
    -1

proc lowerSpacer*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; diagnostics: seq[EmailDiagnostic]] =
  let r = EmailRenderer()
  let given = rawValue(node, "height")
  var h = if given.len > 0: pxLen(given)
    else: pxLen(ctx.theme.lightFor(spacerDefault))
  if h < 0 or (given.len > 0 and given.strip().endsWith("%")):
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailSpacer height '" & given &
        "' is not a px length", origin: node.origin))
    h = pxLen(ctx.theme.lightFor(spacerDefault))
  let d = r.createElement("div")
  d.origin = node.origin
  r.setAttribute(d, "aria-hidden", "true")
  let hp = $h & "px"
  r.setStyle(d, "height", hp)
  r.setStyle(d, "line-height", hp)
  r.setStyle(d, "font-size", hp)
  r.appendChild(d, raw("&#8202;"))
  if ctx.target.outlookWord:
    result.nodes = @[spacerRow(h), notMsoWrap(d)]
  else:
    result.nodes = @[d]

proc lowerDivider*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; diagnostics: seq[EmailDiagnostic]] =
  let r = EmailRenderer()
  var pad = rawValue(node, "padding")
  if pad.len == 0:
    pad = dividerPadding
  var sides = [0, 0, 0, 0]
  try:
    let s = expandBox(pad)
    for i in 0 .. 3:
      sides[i] = int(round(toPx(s[i])))
  except StyleError:
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailDivider padding '" & pad &
        "' is not a box", origin: node.origin))
  let bw = rawValue(node, "border-width")
  let bs = rawValue(node, "border-style")
  let bc = rawValue(node, "border-color")
  let border = (if bw.len > 0: bw else: "1px") & " " &
    (if bs.len > 0: bs else: "solid") & " " &
    (if bc.len > 0: bc else: ctx.theme.lightFor(dividerBorderToken))
  let container = if node.layout.container > 0: node.layout.container
    else: ctx.target.containerWidth
  let inner = max(1, container - sides[1] - sides[3])
  var width = rawValue(node, "width").strip()
  if width.len == 0:
    width = "100%"
  var px = inner
  if width.endsWith("%"):
    try:
      px = max(1, int(round(float(inner) * min(100.0,
        parseFloat(width[0 ..< ^1])) / 100.0)))
    except ValueError:
      result.diagnostics.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue, message: "mailDivider width '" & width &
          "' is not a length", origin: node.origin))
      width = "100%"
  else:
    let w = pxLen(width)
    if w > 0:
      px = min(w, inner)
      width = $px & "px"
    else:
      result.diagnostics.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue, message: "mailDivider width '" & width &
          "' is not a length", origin: node.origin))
      width = "100%"
  var align = node.attrs.getOrDefault("align", "center").toLowerAscii()
  if align notin ["left", "center", "right"]:
    align = "center"
  let padText = boxText(sides)
  let d = r.createElement("div")
  d.origin = node.origin
  if max(sides) > 0:
    r.setStyle(d, "padding", padText)
  let p = r.createElement("p")
  p.origin = node.origin
  r.setStyle(p, "border-top", border)
  r.setStyle(p, "font-size", "1px")
  r.setStyle(p, "line-height", "0")
  r.setStyle(p, "margin", case align
    of "left": "0"
    of "right": "0 0 0 auto"
    else: "0 auto")
  r.setStyle(p, "width", width)
  if "class" in node.attrs:
    r.setAttribute(p, "class", node.attrs["class"])
  r.appendChild(p, raw("&nbsp;"))
  r.appendChild(d, p)
  if ctx.target.outlookWord:
    var nodes: seq[EmailNode] = @[]
    let padded = max(sides) > 0
    if padded:
      nodes.add(msoBoxOpen(GhostCell(padding: padText)))
    nodes.add(ghostDivider(px, border, align))
    nodes.add(notMsoWrap(d))
    if padded:
      nodes.add(ghostTableClose())
    result.nodes = nodes
  else:
    result.nodes = @[d]

proc lowerText*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; inner: EmailNode;
      diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one `mailText`: `nodes` replace it, `inner` (the div) holds
  ## its content, lowered next.
  let r = EmailRenderer()
  let d = r.createElement("div")
  d.origin = node.origin
  var align = node.attrs.getOrDefault("align", "").strip().toLowerAscii()
  if align.len > 0 and align notin ["left", "center", "right"]:
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailText align '" & align &
        "' is not left, center or right", origin: node.origin))
    align = ""
  let pad = rawValue(node, "padding")
  var padText = ""
  if pad.len > 0:
    try:
      var sides = [0, 0, 0, 0]
      let s = expandBox(pad)
      for i in 0 .. 3:
        sides[i] = int(round(toPx(s[i])))
      if max(sides) > 0:
        padText = boxText(sides)
    except StyleError:
      result.diagnostics.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue, message: "mailText padding '" & pad &
          "' is not a box", origin: node.origin))
  if padText.len > 0:
    r.setStyle(d, "padding", padText)
  if align.len > 0:
    r.setAttribute(d, "align", align)
    r.setStyle(d, "text-align", align)
  for k, v in node.styles.pairs:
    if k notin ["padding", "padding-top", "padding-right", "padding-bottom",
        "padding-left", "text-align"]:
      r.setStyle(d, k, v)
  if "class" in node.attrs:
    r.setAttribute(d, "class", node.attrs["class"])
  let kids = node.children # Copy: appendChild detaches as it moves.
  for c in kids:
    r.appendChild(d, c)
  let bg = colourOf(node, "background-color")
  let word = ctx.target.outlookWord and
    (padText.len > 0 or align in ["center", "right"] or bg.len > 0)
  if word:
    # R-TBL-02: Word ignores a div's padding and background; its cell
    # carries them.
    result.nodes = @[msoBoxOpen(GhostCell(padding: padText, background: bg,
      align: if align in ["center", "right"]: align else: "")), d,
      ghostTableClose()]
  else:
    result.nodes = @[d]
  result.inner = d
