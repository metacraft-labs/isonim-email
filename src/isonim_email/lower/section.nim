## isonim_email/lower/section.nim — `mailSection` lowering (div-first).
##
## A section is a horizontal band: a centred container `W` px wide
## (catalogue R-LAY-08), drawn for everyone but Outlook as two `div`s and
## for Outlook as a ghost table that only Word sees (R-LAY-06):
##
## ```html
## <!--[if mso]><table role="presentation" align="center" border="0" cellpadding="0" cellspacing="0" width="{W}" style="width:{W}px;"><tr><td bgcolor="{bg}" style="padding:{pad};background-color:{bg};"><![endif]-->
## <div style="margin:0 auto;max-width:{W}px;background-color:{bg};">
##   <div align="{align}" style="padding:{pad};font-size:16px;text-align:{align};direction:{dir};">{content}</div>
## </div>
## <!--[if mso]></td></tr></table><![endif]-->
## ```
##
## Every property Word must honour (padding, background, border,
## alignment other than its default) is on the div for everyone else
## **and** on the ghost cell for Word (R-TBL-02): Word ignores div
## padding, widths and backgrounds. A border is the exception on the
## div side: it is drawn by a frame `div` around the inner div that Word
## does not see (`<!--[if !mso]><!-->` around its tags), because Word
## renders div borders unreliably and would draw the border twice. Word centres the band through the
## table's `align="center"`, never through `margin:auto` (R-TBL-14).
##
## A single-column section has no column scaffolding: the column's
## padding merges into the section's (section `24px 0` plus column
## `0 24px` is `24px`), on the inner div and on the ghost cell alike.
## Content directly in a section is that single column, with the
## default column padding. The inner div resets `font-size` to 16px,
## the merged column's own reset (R-LAY-04). A column that needs its own
## box (a background, a border, a width below 100%, inner padding) or
## a section with several columns needs the column scaffolding, whose
## lowering is not built yet: that is `E-LOWER-MISSING`, never a silent
## drop.
##
## `full_width` (R-LAY-09) wraps the band in a full-width `div` and,
## for Word, a 100% table, both painting the background edge to edge.
##
## A background image (catalogue R-VML-01, `lower/background.nim`) goes
## on the inner div, with its fallback colour, as CSS for everyone but
## Word. Word gets the fallback colour on the ghost cell; with the
## target's `vmlFitToText` (R-VML-03) it gets the image as a `v:rect`
## that grows with the content instead, the padding on a one-cell table
## inside it, and the inner div's tags hidden from it (`hideInner`), so
## nothing inside the rectangle paints a background over the image.
##
## The section's alignment defaults to the start of its direction (left
## for `ltr`, right for `rtl`); its direction defaults to the
## document's. Author classes (including the ones the head pass
## generated) and any other resolved declaration go to the inner div,
## which is where the section's padding lives.
##
## Ghost tables come from `mso/ghost.nim` only. Pure tree building:
## identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/units
import ../style/colors
import ../style/tokens
import ../passes/layout
import ../passes/styles
import ../mso/ghost
import ../mso/vml
import ./background
from ../passes/head import darkClassAttr

export background

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const innerFontSize* = "16px"
  ## The font-size reset of a single-column section's inner div
  ## (R-LAY-04, the column's own reset).

const zeroFontSize* = "0.01px"
  ## The font-size of a box that lays out no text of its own: the
  ## container of inline-block columns (R-LAY-04) and a gutter cell
  ## (R-TBL-05). Not `0`: WebKitGTK 2.52 (Evolution 3.58, Geary 46)
  ## renders no message holding a box whose font-size is zero, and
  ## Playwright's WebKit build crashes on one, while a hundredth of a
  ## pixel lays out the same in every engine captured.

type LowerCtx* = object
  ## What every scaffolding lowering needs from the render.
  theme*: EmailTheme
  target*: EmailTarget
  dir*: string        ## The document's `dir` (`ltr`, `rtl` or `auto`)

const
  bandConsumed = ["background-color", "background_color", "padding",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "border", "border-width", "border-style", "border-color",
    "border-radius", "border_radius", "text-align", "text_align"]
    ## Declarations a band lowering turns into its own markup.

proc lowerMissing*(node: EmailNode; what, rule: string): EmailDiagnostic =
  EmailDiagnostic(severity: sevError, code: codeLowerMissing,
    message: node.tag & " " & what & " has no lowering yet (" & rule &
      "); it is reported, never dropped silently",
    origin: node.origin, rules: @[rule])

proc boxText*(sides: array[4, int]): string =
  ## Whole-px sides as a minimal CSS shorthand (`24px`, `24px 0`).
  var s: array[4, string]
  for i in 0 .. 3:
    s[i] = formatPx(float(sides[i]))
  compressBox(s)

proc colourOf*(node: EmailNode; prop: string): string =
  ## A resolved colour declaration as 6-digit hex, "" when absent.
  let v = rawValue(node, prop)
  if v.len == 0:
    return ""
  try:
    normaliseColor(v)
  except StyleError:
    v

proc borderText*(node: EmailNode): tuple[css: string; uniform: bool] =
  ## The element's border as one `border` value (`1px solid #e5e7eb`)
  ## from P3's widths and P5's style and colour; "" when it has none.
  ## `uniform` is false when the sides differ, which only a hand-built
  ## tree can express.
  let b = node.layout.border
  result.uniform = b[0] == b[1] and b[1] == b[2] and b[2] == b[3]
  if b[0] == 0 and b[1] == 0 and b[2] == 0 and b[3] == 0:
    return
  var style = rawValue(node, "border-style")
  var colour = colourOf(node, "border-color")
  let short = rawValue(node, "border")
  if (style.len == 0 or colour.len == 0) and short.len > 0:
    for part in short.splitWhitespace():
      let p = part.toLowerAscii()
      if p in ["solid", "dashed", "dotted"]:
        style = p
      elif p.startsWith("#") or p.startsWith("rgb"):
        try:
          colour = normaliseColor(part)
        except StyleError:
          colour = part
  if style.len == 0:
    style = "solid"
  result.css = formatPx(float(max(b))) & " " & style &
    (if colour.len > 0: " " & colour else: "")

proc radiusOf*(node: EmailNode): string =
  let v = rawValue(node, "border-radius")
  if v.len == 0 or v == "0":
    return ""
  try:
    normaliseLength("border-radius", v)
  except StyleError:
    v

proc directionOf*(node: EmailNode; ctx: LowerCtx): string =
  ## The section's own `direction`, else the document's (`ltr`/`rtl`
  ## only: `auto` sets none).
  let own = rawValue(node, "direction").toLowerAscii()
  if own in ["ltr", "rtl"]:
    return own
  let doc = ctx.dir.toLowerAscii()
  if doc in ["ltr", "rtl"]: doc else: ""

proc alignOf*(node: EmailNode; dir: string): string =
  ## `text_align`, else the start of the direction.
  let own = rawValue(node, "text-align").toLowerAscii()
  if own in ["left", "center", "right"]:
    return own
  if dir == "rtl": "right" else: "left"

proc addSides(a, b: array[4, int]): array[4, int] =
  for i in 0 .. 3:
    result[i] = a[i] + b[i]

proc carryOver(src, dst: EmailNode; consumed: openArray[string];
    r: EmailRenderer) =
  ## Every declaration of `src` a lowering did not consume, then its
  ## classes, onto `dst`.
  for k, v in src.styles.pairs:
    if k notin consumed and k notin backgroundProps:
      r.setStyle(dst, k, v)
  if "class" in src.attrs:
    r.setAttribute(dst, "class", src.attrs["class"])

type Band* = object
  ## A lowered band: the nodes that replace the authoring element, and
  ## the inner div the content goes into.
  nodes*: seq[EmailNode]
  inner*: EmailNode
  row*: bool  ## The section holds a row of columns, still to be placed in `inner`
  hideInner*: bool
    ## Word must not see the inner div (it carries the image's CSS
    ## inside Word's `v:rect`): once its content is lowered, the caller
    ## replaces its tags by `!mso` conditionals (`hiddenFromWord`)

proc bandNodes*(node: EmailNode; ctx: LowerCtx; padding: array[4, int];
    background, border, radius, align: string; ghostAlign: bool;
    innerStyles: openArray[(string, string)]; consumed: openArray[string];
    r: EmailRenderer; image = BandBackground()): Band =
  ## The shared band shape (section and wrapper): ghost table open,
  ## outer div (centring, max-width, background), inner div (padding,
  ## border, then `innerStyles`, then a background image's CSS),
  ## ghost table close. With an image and `vmlFitToText`, Word gets the
  ## image as a `v:rect` that grows with the content (R-VML-01,
  ## R-VML-03) inside the ghost cell, and the padding on a one-cell
  ## table inside the rectangle; without the flag Word paints the
  ## fallback colour on the ghost cell, as when images are blocked
  ## (R-OL-11).
  let w = node.layout.outer
  let pad = boxText(padding)
  let vmlCase = ctx.target.outlookWord and image.src.len > 0 and
    ctx.target.vmlFitToText
  let outer = r.createElement("div")
  outer.origin = node.origin
  r.setStyle(outer, "margin", "0 auto")
  r.setStyle(outer, "max-width", $w & "px")
  if background.len > 0 and not vmlCase:
    r.setStyle(outer, "background-color", background)
  if radius.len > 0:
    r.setStyle(outer, "border-radius", radius)
  let inner = r.createElement("div")
  inner.origin = node.origin
  if align.len > 0:
    r.setAttribute(inner, "align", align)
  r.setStyle(inner, "padding", pad)
  for (k, v) in innerStyles:
    r.setStyle(inner, k, v)
  # The image goes on the inner div, which carries the band's classes:
  # a dark rule repaints the colour behind the image, never over it.
  for (k, v) in cssDeclarations(image):
    r.setStyle(inner, k, v)
  if image.src.len > 0 and radius.len > 0 and border.len == 0:
    r.setStyle(inner, "border-radius", radius)
  carryOver(node, inner, consumed, r)
  if border.len > 0:
    # The border is drawn by a div of its own around the inner div. Word
    # draws it on the ghost cell and renders div borders unreliably, so
    # with Outlook output that div is hidden from Word.
    var css = "border:" & border & ";"
    if radius.len > 0:
      css.add("border-radius:" & radius & ";")
    if ctx.target.outlookWord:
      r.appendChild(outer, notMsoOpen("<div style=\"" & css & "\">"))
      r.appendChild(outer, inner)
      r.appendChild(outer, notMsoClose("div"))
    else:
      let frame = r.createElement("div")
      frame.origin = node.origin
      r.setStyle(frame, "border", border)
      if radius.len > 0:
        r.setStyle(frame, "border-radius", radius)
      r.appendChild(frame, inner)
      r.appendChild(outer, frame)
  else:
    r.appendChild(outer, inner)
  result.inner = inner
  let ghostAlignment = if ghostAlign and align notin ["", "left"]: align
    else: ""
  if vmlCase:
    # Word sees the ghost cell (the fallback colour, the border), the
    # rectangle and a one-cell table with the padding; no element with
    # a background of its own inside the rectangle, where Word would
    # paint it over the image.
    let b = node.layout.border
    let cell = GhostCell(background: background, border: border)
    let f = image.fill
    var dir = ""
    for (k, v) in innerStyles:
      if k == "direction":
        dir = v
    result.nodes = @[ghostTableOpen(w, cell),
      vmlBackgroundOpen(w - b[1] - b[3], 0, image.src, image.color,
        f.kind, f.origin, f.position, f.size, f.aspect, fit = true),
      msoBoxOpen(GhostCell(padding: pad, align: ghostAlignment,
        direction: dir)),
      outer, ghostTableClose(), vmlBackgroundClose(), ghostTableClose()]
    result.hideInner = true
  elif ctx.target.outlookWord:
    let cell = GhostCell(padding: pad, background: background,
      border: border, align: ghostAlignment)
    result.nodes = @[ghostTableOpen(w, cell), outer, ghostTableClose()]
  else:
    result.nodes = @[outer]

proc mergesIntoSection*(col, section: EmailNode): bool =
  ## A section's one `mailColumn` merges into the section (R-LAY-08)
  ## when it needs no box of its own: no background, no border, no
  ## radius, the section's full width, and no reversal.
  if col.tag != "mailColumn" or section.layout.reversed:
    return false
  if colourOf(col, "background-color").len > 0 or max(col.layout.border) > 0 or
      radiusOf(col).len > 0:
    return false
  not col.layout.pxWidth and col.layout.percent == 100.0

proc lowerSection*(node: EmailNode; ctx: LowerCtx):
    tuple[band: Band; diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one laid-out `mailSection`. Its content (the merged single
  ## column's children, or its own) is moved into `band.inner`; the
  ## caller lowers that content next and swaps `band.nodes` in for the
  ## section.
  let r = EmailRenderer()
  var diags: seq[EmailDiagnostic] = @[]
  let image = readBackground(node, diags)

  var columns: seq[EmailNode] = @[]
  for c in node.children:
    if c.kind == enElement and c.tag in columnTags:
      columns.add(c)
  var padding = node.layout.padding
  var content: seq[EmailNode] = node.children
  var fontSize = innerFontSize
  var row = false
  if columns.len == 0:
    padding = addSides(padding, defaultColumnPadding(ctx.theme))
  elif columns.len == 1 and mergesIntoSection(columns[0], node):
    # The single column merges into the section (no column scaffolding).
    let col = columns[0]
    padding = addSides(padding, col.layout.padding)
    var merged: seq[EmailNode] = @[]
    for c in node.children:
      if c == col:
        for gc in col.children:
          merged.add(gc)
      else:
        merged.add(c)
    content = merged
  else:
    # A row: several columns, a group, or one column with a box or a
    # width of its own. The inner div holds inline-block columns
    # (R-LAY-04).
    fontSize = zeroFontSize
    row = true

  let dir = directionOf(node, ctx)
  let align = alignOf(node, dir)
  var innerStyles = @[("font-size", fontSize), ("text-align", align)]
  if dir.len > 0:
    innerStyles.add(("direction", dir))
  let (border, uniform) = borderText(node)
  if not uniform:
    diags.add(lowerMissing(node, "per-side border", "R-TBL-02"))
  var background = colourOf(node, "background-color")
  if image.src.len > 0:
    # R-VML-01: an image always has its fallback colour behind it.
    background = image.color
  let radius = radiusOf(node)
  var consumed = @bandConsumed
  consumed.add(["font-size", "direction"])
  if row and node.layout.reversed:
    # R-LAY-11: the row runs right to left on desktop; each column
    # restores its own direction.
    innerStyles = @[("font-size", fontSize), ("text-align", align),
      ("direction", "rtl")]
  var band = bandNodes(node, ctx, padding, background, border, radius,
    align, ghostAlign = true, innerStyles, consumed, r, image)
  if row and node.layout.reversed:
    r.setAttribute(band.inner, "dir", "rtl")
  if not row and columns.len == 1 and "class" in columns[0].attrs:
    # The merged column's classes (head rules on its padding) land
    # where its padding now is.
    var parts = band.inner.attrs.getOrDefault("class", "").splitWhitespace()
    for cls in columns[0].attrs["class"].splitWhitespace():
      if cls notin parts:
        parts.add(cls)
    r.setAttribute(band.inner, "class", parts.join(" "))
  band.row = row
  if not row:
    # A row's columns are placed by `lower/column.nim` (the caller).
    for c in content:
      r.appendChild(band.inner, c)

  if node.attrs.getOrDefault("full_width", "").toLowerAscii() == "true":
    # R-LAY-09: the full-bleed band around the unchanged section.
    let bleed = r.createElement("div")
    bleed.origin = node.origin
    if background.len > 0:
      r.setStyle(bleed, "background-color", background)
      # The band's dark colour, edge to edge as in light (R-DRK-02).
      let dark = node.attrs.getOrDefault(darkClassAttr, "")
      if dark.len > 0:
        r.setAttribute(bleed, "class", dark)
    for n in band.nodes:
      r.appendChild(bleed, n)
    if ctx.target.outlookWord:
      band.nodes = @[fullWidthTableOpen(background), bleed, ghostTableClose()]
    else:
      band.nodes = @[bleed]
  (band, diags)
