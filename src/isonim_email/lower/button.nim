## isonim_email/lower/button.nim — `mailButton`.
##
## **Defaults** (`buttonDefaults`, prepended by the style pass so the
## author's own values win): the colours of the `tone` (default
## `primary`) in the `variant` (default `solid`), the theme's
## `button.padding` and `button.font`, the inherited font family, and a
## `radius.md` corner.
##
## | Variant | Fill | Label | Border |
## |---|---|---|---|
## | `solid` | the tone's colour | the colour on it | none |
## | `outline` | none | the tone's text colour | 2px solid, the label's colour; the padding shrinks by 2px a side, so an outline button is as large as a solid one |
## | `link` | none | the tone's text colour, underlined | none, and square |
##
## A tone's colour is `color.accent.primary` (`primary`),
## `color.status.*` (`info`, `success`, `warning`, `danger`) or
## `color.text.primary` (`neutral`); the colour on it is
## `color.accent.primaryText` for `primary`, `color.text.inverse`
## otherwise; its text colour (outline and link labels, which sit on the
## surface) is `color.link` for `primary` and `info`, the tone's colour
## otherwise. Under `darkMode = designed` every default colour gets its
## dark pair.
##
## **The table button** (catalogue R-BTN-01, after MJML's `mj-button`):
##
## ```html
## <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0"><tr><td align="{align}" style="text-align:{align};">
## <table role="presentation" border="0" cellpadding="0" cellspacing="0" align="{align}" style="border-collapse:separate !important;line-height:100%;">
##   <tr><td align="center" bgcolor="{bg}" role="presentation" valign="middle" style="border:{border};border-radius:{r};cursor:auto;mso-padding-alt:{pad};background-color:{bg};">
##     <a href="{href}" target="_blank" style="display:inline-block;background-color:{bg};color:{fg};font-family:{ff};font-size:{fs};font-weight:{fw};line-height:{lh};mso-line-height-rule:exactly;margin:0;text-decoration:none;text-transform:none;padding:{pad};mso-padding-alt:0px;border-radius:{r};">{label}</a>
##   </td></tr>
## </table>
## </td></tr></table>
## ```
##
## The padding is on the link, so its whole area is the link; Word
## ignores a link's padding and reads the cell's `mso-padding-alt`
## instead, so there only the label is clickable and the corners are
## square (R-BTN-02). The outer one-cell table places the button: the
## reset centres every table with `margin:0 auto !important`, so a
## start- or end-aligned button needs its table's `align`, which floats
## it, and a cell is what contains a float in every engine, Word's
## included (without it the button hangs out of its box and the text
## after it flows beside it). A centred button needs no outer table,
## and neither does an item of a `mailCluster`, whose inline item
## shrinks to the button and is placed by the cluster (its table then
## has no `align`).
## `border-collapse:separate` is `!important` because the reset
## collapses every table with `!important`, and a collapsed cell draws
## its border and background square.
##
## A `width` (px or %) goes on the button's table, which includes the
## cell's border, and the link becomes a block that fills the cell
## (`text-align:center`), so the whole width is the link (R-BTN-03).
## A `height` sets the vertical padding (`(height − line height −
## borders) / 2` a side); without one the height is the line height
## plus the padding and the borders.
##
## **The VML variant** (R-BTN-04): with `vml = always`, or `vml = auto`
## when the button is rounded and has a px width, Word gets a
## `v:roundrect` inside `<!--[if mso]>`, and everyone else the table
## button inside `<!--[if !mso]>`:
##
## ```html
## <!--[if mso]><div align="{align}"><v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="{href}" style="height:{h}px;v-text-anchor:middle;width:{w}px;" arcsize="{round(r/h*100)}%" strokecolor="{border or bg}" [strokeweight="{bw}px"] fillcolor="{bg}" | filled="f"><w:anchorlock /><center style="color:{fg};font-family:{ff};font-size:{fs};font-weight:{fw};">{label}</center></v:roundrect></div><![endif]-->
## ```
##
## The roundrect is the link, so Word's whole button is clickable and
## its corners are round; its label cannot wrap, so it must fit: the
## label's width at the text metrics' worst case (`style/metrics`) must
## not exceed the width less the horizontal padding and the borders,
## or the render fails with `E-LAYOUT-LABEL-OVERFLOW`. A VML button
## needs a px width (`E-LAYOUT-VML-SIZE`; a % width is taken of the box
## the button sits in). Characters outside the metrics' ranges add
## `I-LAYOUT-METRICS-APPROX`. A `link` button never uses VML.
##
## **Word spacers** (`word_padding = spacers`, R-BTN-05, an option):
## the link button of goodemailcode.com. No table: a block holding the
## link, whose padding Word gets back from hidden `<i>` elements inside
## `<!--[if mso]>` — an em space `mso-font-width` wide for each side
## (`ph / fs`, in %, at most 500% an em space), raised by
## `mso-text-raise` for the top and bottom padding, the label raised by
## the bottom padding — so Word's whole button is the link, square:
##
## ```html
## <div align="{align}" style="text-align:{align};"><a href="{href}" target="_blank" style="display:inline-block;…;padding:{pad};mso-padding-alt:0;text-underline-color:{bg};border-radius:{r};"><!--[if mso]><i style="mso-font-width:{x}%;mso-text-raise:{(pt+pb)/fs}%" hidden>&emsp;</i><span style="mso-text-raise:{pb/fs}%;"><![endif]-->{label}<!--[if mso]></span><i style="mso-font-width:{x}%;" hidden>&emsp;&#8203;</i><![endif]--></a></div>
## ```
##
## Right to left, the zero-width space goes on both sides. Its
## `mso-text-raise` and `mso-font-width` are outside the closed `mso-*`
## list until a Word-engine capture admits them (R-OL-15), so a render
## using the option reports `W-CSS-MSO-UNLISTED`.
##
## VML and the conditionals come from `mso/` only. Pure tree building:
## identical on the C and JS targets.

import std/[math, strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/units
import ../style/shorthand
import ../style/metrics
import ../mso/cond
import ../mso/vml
import ./section
import ./text
import ./button_style

export button_style

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const maxEmWidth = 500
  ## `mso-font-width`'s ceiling, in % of an em.

# ----------------------------------------------------------------------------
# Lowering
# ----------------------------------------------------------------------------

type ButtonGeometry* = object
  ## A button's resolved box, px.
  padding*: array[4, int]   ## top, right, bottom, left
  border*: int              ## border width, every side
  fontSize*, lineHeight*: float
  height*: int              ## line height + padding + borders

proc px(value: string; fallback = -1.0): float =
  try:
    toPx(value.strip())
  except StyleError, ValueError:
    fallback

proc sidesOf(node: EmailNode; diags: var seq[EmailDiagnostic]):
    array[4, int] =
  let longs = ["padding-top", "padding-right", "padding-bottom",
    "padding-left"]
  let pad = node.styles.getOrDefault("padding", "")
  if pad.len > 0:
    try:
      let s = expandBox(pad)
      for i in 0 .. 3:
        result[i] = int(round(toPx(s[i])))
    except StyleError:
      diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
        message: "mailButton padding '" & pad & "' is not a box",
        origin: node.origin))
  for i, k in longs:
    if k in node.styles:
      let v = px(node.styles[k])
      if v >= 0:
        result[i] = int(round(v))

proc geometry*(node: EmailNode;
    diags: var seq[EmailDiagnostic]): ButtonGeometry =
  ## The button's box from its resolved styles (after the style pass).
  result.padding = sidesOf(node, diags)
  let bs = node.styles.getOrDefault("border-style", "").toLowerAscii()
  if bs notin ["", "none"]:
    result.border = max(0, int(round(px(node.styles.getOrDefault(
      "border-width", "0"), 0))))
  result.fontSize = px(node.styles.getOrDefault("font-size", "16px"), 16)
  let lh = node.styles.getOrDefault("line-height", "")
  result.lineHeight = px(lh, -1)
  if result.lineHeight < 0:
    result.lineHeight = round(result.fontSize * 1.2)
  let given = node.styles.getOrDefault("height", "")
  if given.len > 0:
    let h = px(given)
    if h < 0 or given.endsWith("%"):
      diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
        message: "mailButton height '" & given & "' is not a px length",
        origin: node.origin))
    else:
      # The height sets the vertical padding.
      let rest = max(0, int(round(h)) - int(result.lineHeight) -
        2 * result.border)
      result.padding[0] = rest div 2
      result.padding[2] = rest - rest div 2
  result.height = int(result.lineHeight) + result.padding[0] +
    result.padding[2] + 2 * result.border

proc labelText(node: EmailNode): string =
  if node.kind == enText:
    return node.text
  for c in node.children:
    result.add(labelText(c))

proc cloneLabel(node: EmailNode): EmailNode =
  ## A copy of a label subtree (text and inline elements) for Word's
  ## copy of the label.
  result = EmailNode(kind: node.kind, tag: node.tag, text: node.text,
    attrs: node.attrs, styles: node.styles, fallbacks: node.fallbacks,
    origin: node.origin, cond: node.cond)
  for c in node.children:
    let k = cloneLabel(c)
    k.parent = result
    result.children.add(k)

proc declare(r: EmailRenderer; n: EmailNode;
    decls: openArray[(string, string)]) =
  for (k, v) in decls:
    if v.len > 0:
      r.setStyle(n, k, v)

proc linkStyles(node: EmailNode; g: ButtonGeometry;
    bg, fg, radius, border: string; display: string; centre: bool;
    spacers: bool): seq[(string, string)] =
  ## The link's declarations. With Word spacers the link is the whole
  ## button, so it carries the border too (the table button's border is
  ## its cell's).
  let st = node.styles
  result = @[("display", display)]
  if bg.len > 0:
    result.add(("background-color", bg))
  if spacers and border.len > 0:
    result.add(("border", border))
  result.add(("color", fg))
  if centre:
    result.add(("text-align", "center"))
  for k in ["font-family", "font-size", "font-style", "font-weight",
      "letter-spacing"]:
    if k in st:
      result.add((k, st[k]))
  result.add(("line-height", formatPx(g.lineHeight)))
  result.add(("mso-line-height-rule", "exactly"))
  result.add(("margin", "0"))
  result.add(("text-decoration", st.getOrDefault("text-decoration", "none")))
  result.add(("text-transform", st.getOrDefault("text-transform", "none")))
  result.add(("padding", boxText(g.padding)))
  if spacers:
    result.add(("mso-padding-alt", "0"))
    if bg.len > 0:
      result.add(("text-underline-color", bg))
  else:
    result.add(("mso-padding-alt", "0px"))
  if radius.len > 0:
    result.add(("border-radius", radius))

proc buttonBorder(node: EmailNode; g: ButtonGeometry): string =
  if g.border == 0:
    return ""
  formatPx(float(g.border)) & " " &
    node.styles.getOrDefault("border-style", "solid") & " " &
    colourOf(node, "border-color")

proc lowerButton*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one `mailButton` (styles resolved, see the module comment).
  let r = EmailRenderer()
  var diags: seq[EmailDiagnostic] = @[]
  let variant = variantOf(node)
  let g = geometry(node, diags)
  let href = node.attrs.getOrDefault("href", "").strip()
  let rtl = isRtl(node)
  var align = node.attrs.getOrDefault("align", "").strip().toLowerAscii()
  if align.len > 0 and align notin ["left", "center", "right"]:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailButton align '" & align & "' is not left, center or " &
        "right", origin: node.origin))
    align = ""
  if align.len == 0:
    align = if rtl: "right" else: "left"
  let vml = node.attrs.getOrDefault("vml", "auto").strip().toLowerAscii()
  if vml notin ["auto", "always", "never"]:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailButton vml '" & vml & "' is not auto, always or never",
      origin: node.origin))
  let wordPadding = node.attrs.getOrDefault("word_padding", "cell").strip().
    toLowerAscii()
  if wordPadding notin ["cell", "spacers"]:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailButton word_padding '" & wordPadding & "' is not cell " &
        "or spacers", origin: node.origin))
  let spacers = wordPadding == "spacers"
  if spacers and vml == "always":
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailButton word_padding = spacers with vml = always: Word " &
        "gets one button, choose the spacers or the VML",
      origin: node.origin, rules: @["R-BTN-04", "R-BTN-05"]))
  if variant == "link" and vml == "always":
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailButton variant = link with vml = always: a link " &
        "button has no shape to draw", origin: node.origin,
      rules: @["R-BTN-04"]))
  let label = labelText(node).strip()
  if label.len == 0:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailButton has no label", origin: node.origin))
  let bg = colourOf(node, "background-color")
  let fg = colourOf(node, "color")
  let radius = if variant == "link": "" else: radiusOf(node)
  let border = buttonBorder(node, g)
  # Width: content, a px width or a percentage of the box it sits in.
  let widthRaw = node.styles.getOrDefault("width", "").strip()
  var widthCss = ""
  var widthAttr = ""
  var widthPx = -1
  let container = if node.layout.container > 0: node.layout.container
    else: ctx.target.containerWidth
  if widthRaw.len > 0 and widthRaw != "auto":
    if widthRaw.endsWith("%"):
      try:
        let p = min(100.0, parseFloat(widthRaw[0 ..< ^1]))
        widthCss = formatPx(p).replace("px", "") & "%"
        widthAttr = widthCss
        widthPx = int(round(float(container) * p / 100.0))
      except ValueError:
        discard
    else:
      let w = px(widthRaw)
      if w > 0:
        widthPx = int(round(w))
        widthCss = $widthPx & "px"
        widthAttr = $widthPx
    if widthCss.len == 0:
      diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
        message: "mailButton width '" & widthRaw & "' is not a length",
        origin: node.origin))
  let sized = widthCss.len > 0
  let useVml = ctx.target.outlookWord and wordForm(node) == "vml"
  let cls = node.attrs.getOrDefault("class", "")
  let kids = node.children # Copy: appendChild detaches as it moves.
  var vmlLabel: seq[EmailNode] = @[]
  if useVml:
    for c in kids:
      vmlLabel.add(cloneLabel(c))

  # The link.
  let a = r.createElement("a")
  a.origin = node.origin
  r.setAttribute(a, "href", href)
  r.setAttribute(a, "target", "_blank")
  if cls.len > 0:
    r.setAttribute(a, "class", cls)
  r.declare(a, linkStyles(node, g, bg, fg, radius, border,
    if sized and not spacers: "block" else: "inline-block",
    sized and not spacers, spacers))

  if spacers:
    let fs = max(1.0, g.fontSize)
    let side = max(g.padding[1], g.padding[3])
    var ems = 1
    var widthPct = int(round(float(side) / fs * 100.0))
    while widthPct > maxEmWidth * ems:
      inc ems
    widthPct = int(round(float(side) / fs * 100.0 / float(ems)))
    let space = "&emsp;".repeat(ems)
    let top = int(round(float(g.padding[0] + g.padding[2]) / fs * 100.0))
    let bottom = int(round(float(g.padding[2]) / fs * 100.0))
    let lead = if rtl: space & "&#8203;" else: space
    r.appendChild(a, msoWrap(raw("<i style=\"mso-font-width:" & $widthPct &
      "%;mso-text-raise:" & $top & "%\" hidden>" & lead &
      "</i><span style=\"mso-text-raise:" & $bottom & "%;\">")))
    for c in kids:
      r.appendChild(a, c)
    r.appendChild(a, msoWrap(raw("</span><i style=\"mso-font-width:" &
      $widthPct & "%;\" hidden>" & space & "&#8203;</i>")))
    let d = r.createElement("div")
    d.origin = node.origin
    r.setAttribute(d, "align", align)
    r.setStyle(d, "text-align", align)
    r.appendChild(d, a)
    result = (@[d], diags)
    return
  for c in kids:
    r.appendChild(a, c)

  # The table button.
  let td = r.createElement("td")
  r.setAttribute(td, "align", "center")
  if bg.len > 0:
    r.setAttribute(td, "bgcolor", bg)
  r.setAttribute(td, "role", "presentation")
  r.setAttribute(td, "valign", "middle")
  if cls.len > 0 and bg.len > 0:
    r.setAttribute(td, "class", cls)
  r.setStyle(td, "border", if border.len > 0: border else: "none")
  r.declare(td, [("border-radius", radius), ("cursor", "auto"),
    ("mso-padding-alt", boxText(g.padding)), ("background-color", bg)])
  r.appendChild(td, a)
  let tr = r.createElement("tr")
  r.appendChild(tr, td)
  let table = r.createElement("table")
  table.origin = node.origin
  r.setAttribute(table, "role", "presentation")
  if widthAttr.len > 0:
    r.setAttribute(table, "width", widthAttr)
  r.setAttribute(table, "border", "0")
  r.setAttribute(table, "cellpadding", "0")
  r.setAttribute(table, "cellspacing", "0")
  let full = widthAttr == "100%"
  if not full:
    r.setAttribute(table, "align", align)
  r.setStyle(table, "border-collapse", "separate !important")
  r.setStyle(table, "line-height", "100%")
  if widthCss.len > 0:
    r.setStyle(table, "width", widthCss)
  r.appendChild(table, tr)
  var html = table
  if node.layout.inlineItem:
    # An item of a cluster: the item is an inline box that shrinks to
    # the button and the cluster places it, so the table carries no
    # `align` (nothing to float) and needs no outer cell.
    table.attrs.del("align")
  elif align != "center" and not full:
    # The cell that contains the floated table (see the module comment).
    let cell = r.createElement("td")
    r.setAttribute(cell, "align", align)
    r.setStyle(cell, "text-align", align)
    r.appendChild(cell, table)
    let row = r.createElement("tr")
    r.appendChild(row, cell)
    html = r.createElement("table")
    html.origin = node.origin
    r.setAttribute(html, "role", "presentation")
    r.setAttribute(html, "width", "100%")
    r.setAttribute(html, "border", "0")
    r.setAttribute(html, "cellpadding", "0")
    r.setAttribute(html, "cellspacing", "0")
    r.appendChild(html, row)
  if not useVml:
    result = (@[html], diags)
    return

  # The VML button for Word.
  var w = widthPx
  if w <= 0:
    diags.add(EmailDiagnostic(severity: sevError, code: codeLayoutVmlSize,
      message: "a VML mailButton needs a px width (R-BTN-04); set width, " &
        "or vml = never", origin: node.origin, rules: @["R-BTN-04"]))
    result = (@[html], diags)
    return
  let h = g.height
  let available = float(w - g.padding[1] - g.padding[3] - 2 * g.border)
  let family = node.styles.getOrDefault("font-family", "")
  let m = measureText(label, family, g.fontSize,
    isBoldWeight(node.styles.getOrDefault("font-weight", "400")))
  if m.approx:
    diags.add(EmailDiagnostic(severity: sevInfo,
      code: codeLayoutMetricsApprox,
      message: "the label \"" & label & "\" has characters outside the " &
        "text metrics; its width (" & formatPx(ceil(m.width)) &
        ") is estimated from average advances", origin: node.origin,
      rules: @["R-BTN-04"]))
  if m.width > available:
    diags.add(EmailDiagnostic(severity: sevError,
      code: codeLayoutLabelOverflow,
      message: "the VML button label \"" & label & "\" needs up to " &
        formatPx(ceil(m.width)) & " at " & formatPx(g.fontSize) & " but " &
        "the button leaves it " & formatPx(available) & " (width " & $w &
        "px less padding and borders); a VML label cannot wrap: widen " &
        "the button, shorten the label, or use vml = never (R-BTN-04)",
      origin: node.origin, rules: @["R-BTN-04"]))
  let rpx = if radius.len > 0: px(radius, 0) else: 0.0
  let arc = int(round(rpx / float(max(1, h)) * 100.0))
  let stroke = if g.border > 0: colourOf(node, "border-color")
    elif bg.len > 0: bg else: fg
  let center = r.createElement("center")
  var cst: seq[(string, string)] = @[("color", fg)]
  for k in ["font-family", "font-size", "font-weight"]:
    cst.add((k, node.styles.getOrDefault(k, "")))
  r.declare(center, cst)
  for c in vmlLabel:
    r.appendChild(center, c)
  let shape = roundrectButton(href, w, h, arc, stroke, g.border, bg, center)
  let holder = r.createElement("div")
  r.setAttribute(holder, "align", align)
  r.appendChild(holder, shape)
  result = (@[msoWrap(holder), notMsoWrap(html)], diags)
