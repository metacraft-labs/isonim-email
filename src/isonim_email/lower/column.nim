## isonim_email/lower/column.nim — rows of columns (div-first).
##
## A row is a section's own `mailColumn`/`mailGroup` children (MJML's
## model: a hybrid row with no gutter) or a `mailColumns` primitive,
## which lays out a row wherever content goes, with a strategy and a
## gutter. P3 (`passes/layout.nim`) has solved every width; this module
## turns them into markup. Four strategies (catalogue R-LAY-01…07,
## R-LAY-18…20):
##
## - `hybrid`: inline-block `div`s, mobile first (R-LAY-01): inline
##   `width:100%` so the columns stack wherever the head CSS is lost,
##   the desktop width from the `min-width` class (R-LAY-02, R-LAY-03).
##   A gutter (R-LAY-14) is a top gap inline (the stacked state) and
##   half-gutters on the inner sides from a desktop class, MJML 5's model.
## - `fabFour`: inline-block `div`s whose width switches without a media
##   query, `width:calc(({bp}px - 100%) * {bp})` between `min-width:{w}`
##   and `max-width:100%`, followed by the same width as
##   `max({w}, calc(…))`, which keeps the lower bound where `min-width`
##   is removed (R-LAY-18, a fallback pair); half-gutters inside the column,
##   turned into the stacked top gap by a `max-width` class.
## - `cellsStacking` and `cells`: one table row of cells, equal in
##   height, stacked below the breakpoint by a class (`cellsStacking`,
##   R-LAY-19) or never (`cells`, R-LAY-20).
##
## Inline-block rows sit in a container with a zero font size, written
## `0.01px` (R-LAY-04; `section.zeroFontSize` says why)
## and nothing between their columns (R-LAY-05): whitespace the author
## left between columns is dropped. Word gets the multi-column ghost
## row (R-LAY-07): fixed-width cells that carry no padding (a cell's
## `width` does not include its padding in every engine). The
## half-gutters and the column's own padding go on a single-cell table
## inside the ghost cell, and a column with a background or a border
## gets one more inside that, so the background stays out of the
## gutter; no cell of the row is padded, so Word has no vertical
## padding to equalise across it (R-TBL-03). Cell rows are real tables
## Word renders as they are; a row of cells whose vertical paddings
## differ nests a single-cell table per cell for the same reason.
##
## Reversal (`reverse_on_mobile`, R-LAY-11): the row runs right to left
## (`dir="rtl"` on the row, on its ghost table or its cell table) and
## every column restores `dir="ltr"`, so the authoring order stays the
## reading and mobile order and only the desktop order flips.
##
## Ghost rows come from `mso/ghost.nim` only. Pure tree building:
## identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/units
import ../passes/layout
import ../mso/ghost
import ./section

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  columnFontSize* = "16px"
    ## Each column resets the row's zero font size (R-LAY-04).
  columnConsumed = ["background-color", "background_color", "padding",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "border", "border-width", "border-style", "border-color",
    "border-radius", "border_radius", "width", "min-width", "min_width",
    "vertical-align", "vertical_align"]
    ## Declarations the column lowering turns into its own markup.

type Row* = object
  ## A lowered row: the nodes that go where the row was, and the
  ## elements each column's content now sits in (lowered next).
  nodes*: seq[EmailNode]
  holders*: seq[EmailNode]

proc valignOf(col, row: EmailNode): string =
  for (node, prop) in [(col, "vertical_align"), (row, "valign"),
      (row, "vertical_align")]:
    let v = rawValue(node, prop).toLowerAscii()
    if v in ["top", "middle", "bottom"]:
      return v
  "top"

proc hasBox(col: EmailNode): bool =
  ## The column paints a box of its own: a background or a border.
  colourOf(col, "background-color").len > 0 or
    max(col.layout.border) > 0

proc sum(a, b: array[4, int]): array[4, int] =
  for i in 0 .. 3:
    result[i] = a[i] + b[i]

proc columnDir(row: EmailNode; ctx: LowerCtx): string =
  ## The direction a column's content runs in: the document's when the
  ## row is reversed (reversal flips the desktop order only), else the
  ## row's own.
  if row.layout.reversed:
    let d = ctx.dir.toLowerAscii()
    return if d in ["ltr", "rtl"]: d else: "ltr"
  if row.layout.rtl: "rtl" else: "ltr"

proc columnBox(col: EmailNode; ctx: LowerCtx; padding: array[4, int];
    r: EmailRenderer): tuple[nodes: seq[EmailNode]; inner: EmailNode] =
  ## The column's own box for everyone but Word: a `div` with its
  ## padding, background and radius, inside a border frame Word does not
  ## see (as a section's, R-LAY-08). `nodes` go into the column, `inner`
  ## takes the content; a column with nothing to carry gets no box
  ## (`nodes` empty, `inner` nil: the content goes into the column).
  var carries = max(padding) > 0 or "class" in col.attrs or
    colourOf(col, "background-color").len > 0 or radiusOf(col).len > 0 or
    max(col.layout.border) > 0
  for k in col.styles.keys:
    if k notin columnConsumed:
      carries = true
  if not carries:
    return (@[], nil)
  let inner = r.createElement("div")
  inner.origin = col.origin
  if max(padding) > 0:
    r.setStyle(inner, "padding", boxText(padding))
  let bg = colourOf(col, "background-color")
  if bg.len > 0:
    r.setStyle(inner, "background-color", bg)
  let radius = radiusOf(col)
  if radius.len > 0:
    r.setStyle(inner, "border-radius", radius)
  for k, v in col.styles.pairs:
    if k notin columnConsumed:
      r.setStyle(inner, k, v)
  if "class" in col.attrs:
    r.setAttribute(inner, "class", col.attrs["class"])
  let (border, _) = borderText(col)
  if border.len == 0:
    return (@[inner], inner)
  var css = "border:" & border & ";"
  if radius.len > 0:
    css.add("border-radius:" & radius & ";")
  if ctx.target.outlookWord:
    return (@[notMsoOpen("<div style=\"" & css & "\">"), inner,
      notMsoClose("div")], inner)
  let frame = r.createElement("div")
  frame.origin = col.origin
  r.setStyle(frame, "border", border)
  if radius.len > 0:
    r.setStyle(frame, "border-radius", radius)
  r.appendChild(frame, inner)
  (@[frame], inner)

proc addClass(r: EmailRenderer; node: EmailNode; cls: string) =
  if cls.len == 0:
    return
  var parts = node.attrs.getOrDefault("class", "").splitWhitespace()
  if cls notin parts:
    parts.add(cls)
  r.setAttribute(node, "class", parts.join(" "))

proc ghostOf(col: EmailNode; valign: string): GhostColumn =
  ## A column's ghost cell: its px width and alignment, never padding
  ## (the cell's `width` would not include it everywhere).
  GhostColumn(width: col.layout.outer, valign: valign)

proc inlineColumn(col, row: EmailNode; ctx: LowerCtx;
    r: EmailRenderer): tuple[node, holder: EmailNode; ghost: GhostColumn] =
  ## One `mailColumn` of a `hybrid` or `fabFour` row.
  let lb = col.layout
  let valign = valignOf(col, row)
  let dir = columnDir(row, ctx)
  let align = if dir == "rtl": "right" else: "left"
  let outer = r.createElement("div")
  outer.origin = col.origin
  if row.layout.reversed:
    r.setAttribute(outer, "dir", dir)
  if lb.strategy == "fabFour":
    let bp = $ctx.target.breakpoint
    r.setStyle(outer, "display", "inline-block")
    r.setStyle(outer, "vertical-align", valign)
    let w = if lb.pxWidth: $lb.outer & "px"
      else: percentText(lb.percent) & "%"
    let fab = "calc((" & bp & "px - 100%) * " & bp & ")"
    # The `max()` form carries its own lower bound, for a sanitiser
    # that drops `min-width` but keeps both functions (SnappyMail); the
    # bare `calc()` before it stays for a client without `max()`
    # (R-LAY-18, a fallback pair by R-CSS-19).
    r.setStyleWithFallback(outer, "width", fab,
      "max(" & w & ", " & fab & ")")
    r.setStyle(outer, "min-width", w)
    r.setStyle(outer, "max-width", "100%")
  else:
    r.addClass(outer, lb.className)
    r.addClass(outer, lb.gutterClass)
    r.setStyle(outer, "display", "inline-block")
    let w = if lb.stacks: "100%"
      elif lb.pxWidth: $lb.outer & "px"
      else: percentText(lb.percent) & "%"
    r.setStyle(outer, "width", w)
    if lb.gutterClass.len > 0:
      # The desktop class pads the column outside its width (MJML 5's
      # model): a client whose own CSS sets `border-box` (Roundcube)
      # would take the half-gutters out of the width instead.
      r.setStyle(outer, "box-sizing", "content-box")
    r.setStyle(outer, "vertical-align", valign)
    if lb.mobileGap > 0:
      r.setStyle(outer, "padding-top", formatPx(float(lb.mobileGap)))
  r.setStyle(outer, "font-size", columnFontSize)
  r.setStyle(outer, "text-align", align)
  r.setStyle(outer, "direction", dir)
  var parent = outer
  if lb.strategy == "fabFour" and max(lb.gutter) + lb.mobileGap > 0:
    # The Fab Four sizes the column's own box, so the half-gutters sit
    # inside it. Stacked, a class turns them into the top gap; without
    # CSS they stay (a declared degradation).
    let gut = r.createElement("div")
    gut.origin = col.origin
    r.addClass(gut, stackPadClass(fabStackedPadding(lb)))
    if max(lb.gutter) > 0:
      r.setStyle(gut, "padding", boxText(lb.gutter))
    r.appendChild(outer, gut)
    parent = gut
  # Word: the ghost cell carries the width only; the half-gutters and
  # the column's own box are single-cell tables inside it (R-LAY-07),
  # so no cell of the row is padded (R-TBL-03) and a background stays
  # out of the gutter.
  let boxed = hasBox(col)
  # The column's own alignment, for Word on the innermost of those
  # tables (R-TBL-14): Word aligns by the cell, not by the div.
  let ownAlign = rawValue(col, "text-align").toLowerAscii()
  let wordAlign = if ownAlign in ["center", "right"]: ownAlign else: ""
  var opened = 0
  if ctx.target.outlookWord:
    let ownPad = if boxed: [0, 0, 0, 0] else: lb.padding
    let outerPad = sum(lb.gutter, ownPad)
    if max(outerPad) > 0:
      r.appendChild(parent, msoBoxOpen(GhostCell(padding: boxText(outerPad),
        align: if boxed: "" else: wordAlign)))
      inc opened
    if boxed:
      r.appendChild(parent, msoBoxOpen(GhostCell(
        padding: if max(lb.padding) > 0: boxText(lb.padding) else: "",
        background: colourOf(col, "background-color"),
        border: borderText(col).css, align: wordAlign)))
      inc opened
  var (boxNodes, inner) = columnBox(col, ctx, lb.padding, r)
  if inner == nil and opened > 0:
    # The content must sit between Word's tables: a plain div holds it.
    inner = r.createElement("div")
    inner.origin = col.origin
    boxNodes = @[inner]
  for n in boxNodes:
    r.appendChild(parent, n)
  if inner == nil:
    inner = parent
  for i in 0 ..< opened:
    r.appendChild(parent, ghostTableClose())
  (outer, inner, ghostOf(col, valign))

proc groupColumn(group, row: EmailNode; ctx: LowerCtx;
    r: EmailRenderer): tuple[node: EmailNode; holders: seq[EmailNode];
      ghost: GhostColumn] =
  ## A `mailGroup` (R-LAY-10): one inline-block that does not stack, its
  ## columns keeping their desktop percentage, with a ghost row of its
  ## own for Word.
  let lb = group.layout
  let valign = valignOf(group, row)
  let dir = columnDir(row, ctx)
  let bg = colourOf(group, "background-color")
  let outer = r.createElement("div")
  outer.origin = group.origin
  r.addClass(outer, lb.className)
  r.addClass(outer, "e-mso-group-fix")
  if row.layout.reversed:
    r.setAttribute(outer, "dir", dir)
  r.setStyle(outer, "display", "inline-block")
  r.setStyle(outer, "width", "100%")
  r.setStyle(outer, "vertical-align", valign)
  r.setStyle(outer, "font-size", zeroFontSize)
  r.setStyle(outer, "text-align", if dir == "rtl": "right" else: "left")
  r.setStyle(outer, "direction", dir)
  if bg.len > 0:
    r.setStyle(outer, "background-color", bg)
  var cols: seq[EmailNode] = @[]
  for c in group.children:
    if c.kind == enElement and c.tag == "mailColumn":
      cols.add(c)
  var first = true
  var holders: seq[EmailNode] = @[]
  for c in cols:
    let (node, holder, ghost) = inlineColumn(c, group, ctx, r)
    if ctx.target.outlookWord:
      r.appendChild(outer, if first: ghostRowOpen(ghost, background = bg)
        else: ghostRowNext(ghost))
    r.appendChild(outer, node)
    holders.add(holder)
    first = false
  if ctx.target.outlookWord and cols.len > 0:
    r.appendChild(outer, ghostTableClose())
  (outer, holders, GhostColumn(width: lb.outer, valign: valign))

proc moveContent(col, holder: EmailNode; r: EmailRenderer) =
  let kids = col.children # Copy: appendChild detaches as it moves.
  for k in kids:
    r.appendChild(holder, k)

proc rowColumns(row: EmailNode): seq[EmailNode] =
  for c in row.children:
    if c.kind == enElement and c.tag in columnTags:
      result.add(c)

proc isBlank(node: EmailNode): bool =
  node.kind == enText and node.text.strip().len == 0

proc lowerInlineRow*(row: EmailNode; ctx: LowerCtx; into: EmailNode;
    r: EmailRenderer): seq[EmailNode] =
  ## A `hybrid` or `fabFour` row appended to `into` (an element with
  ## a zero font size): the ghost row around the columns, nothing between
  ## them (whitespace the author left there is dropped, R-LAY-05).
  ## Anything else the row holds (raw content; misplaced content P3
  ## reported) keeps its place. Returns the elements the columns'
  ## content now sits in.
  let cols = rowColumns(row)
  var first = true
  let kids = row.children # Copy: moving content edits the seq.
  for c in kids:
    if c notin cols:
      if not isBlank(c):
        r.appendChild(into, c)
      continue
    var node: EmailNode
    var ghost: GhostColumn
    if c.tag == "mailGroup":
      let g = groupColumn(c, row, ctx, r)
      node = g.node
      ghost = g.ghost
      var i = 0
      for gc in c.children:
        if gc.kind == enElement and gc.tag == "mailColumn":
          moveContent(gc, g.holders[i], r)
          result.add(g.holders[i])
          inc i
    else:
      let one = inlineColumn(c, row, ctx, r)
      node = one.node
      ghost = one.ghost
      moveContent(c, one.holder, r)
      result.add(one.holder)
    if ctx.target.outlookWord:
      r.appendChild(into, if first: ghostRowOpen(ghost, rtl = row.layout.rtl)
        else: ghostRowNext(ghost))
    r.appendChild(into, node)
    first = false
  if ctx.target.outlookWord and cols.len > 0:
    r.appendChild(into, ghostTableClose())

proc gutterCell(row: EmailNode; r: EmailRenderer): EmailNode =
  ## The gutter between two cells of a cell row: a sized cell that is
  ## never empty (R-TBL-05), so a cell's background or border stays
  ## inside its own cell and every cell keeps the row's height. Hidden
  ## once a `cellsStacking` row stacks.
  let lb = row.layout
  let w = if row.layout.boxExact > 0:
      percentText(float(lb.gutterPx) / lb.boxExact * 100.0) & "%"
    else: $lb.gutterPx & "px"
  let td = r.createElement("td")
  td.origin = row.origin
  if lb.strategy == "cellsStacking":
    r.setAttribute(td, "class", cellsGutterClass)
  r.setAttribute(td, "width", w)
  r.setAttribute(td, "aria-hidden", "true")
  r.setStyle(td, "width", w)
  r.setStyle(td, "font-size", zeroFontSize)
  r.setStyle(td, "line-height", "0")
  r.setStyle(td, "mso-line-height-rule", "exactly")
  r.appendChild(td, raw("&nbsp;"))
  td

proc cellRow(row: EmailNode; ctx: LowerCtx; r: EmailRenderer):
    tuple[table: EmailNode; holders: seq[EmailNode]] =
  ## A `cellsStacking` or `cells` row: one table row of cells, which
  ## gives them equal heights and vertical alignment everywhere,
  ## Word included (R-LAY-19, R-LAY-20). The gutter is a cell of its
  ## own between two columns, and the columns take the desktop widths
  ## that leave room for it (MJML 5's shares, as in a hybrid row).
  let cols = rowColumns(row)
  let table = r.createElement("table")
  table.origin = row.origin
  for (k, v) in [("role", "presentation"), ("width", "100%"),
      ("border", "0"), ("cellpadding", "0"), ("cellspacing", "0")]:
    r.setAttribute(table, k, v)
  if row.layout.rtl:
    r.setAttribute(table, "dir", "rtl")
  var anyRadius = false
  for c in cols:
    if radiusOf(c).len > 0:
      anyRadius = true
  if anyRadius:
    r.setStyle(table, "border-collapse", "separate")
  let tr = r.createElement("tr")
  r.appendChild(table, tr)
  var sameV = true
  for c in cols:
    let p = c.layout.padding
    if p[0] != cols[0].layout.padding[0] or p[2] != cols[0].layout.padding[2]:
      sameV = false
  var first = true
  for c in cols:
    let lb = c.layout
    if not first and row.layout.gutterPx > 0:
      r.appendChild(tr, gutterCell(row, r))
    first = false
    let dir = columnDir(row, ctx)
    let valign = valignOf(c, row)
    let td = r.createElement("td")
    td.origin = c.origin
    if lb.strategy == "cellsStacking":
      r.addClass(td, cellsStackClass)
      if lb.mobileGap > 0:
        r.addClass(td, stackPadClass(stackedPadding(lb)))
    if row.layout.reversed:
      r.setAttribute(td, "dir", dir)
    let bg = colourOf(c, "background-color")
    if bg.len > 0:
      r.setAttribute(td, "bgcolor", bg)
    r.setAttribute(td, "valign", valign)
    let w = if lb.pxWidth: $lb.deskPx else: percentText(lb.deskPercent) & "%"
    r.setAttribute(td, "width", w)
    r.setStyle(td, "width", if lb.pxWidth: w & "px" else: w)
    var pad = lb.padding
    var nestedPad: array[4, int]
    if not sameV and (lb.padding[0] > 0 or lb.padding[2] > 0):
      # R-TBL-03: a row whose cells differ in vertical padding pads a
      # single-cell table inside each cell instead.
      nestedPad = [lb.padding[0], 0, lb.padding[2], 0]
      pad[0] = 0
      pad[2] = 0
    if max(pad) > 0:
      r.setStyle(td, "padding", boxText(pad))
    r.setStyle(td, "vertical-align", valign)
    if bg.len > 0:
      r.setStyle(td, "background-color", bg)
    let (border, _) = borderText(c)
    if border.len > 0:
      r.setStyle(td, "border", border)
    let radius = radiusOf(c)
    if radius.len > 0:
      r.setStyle(td, "border-radius", radius)
    r.setStyle(td, "font-size", columnFontSize)
    r.setStyle(td, "text-align", if dir == "rtl": "right" else: "left")
    r.setStyle(td, "direction", dir)
    for k, v in c.styles.pairs:
      if k notin columnConsumed:
        r.setStyle(td, k, v)
    let tdAlign = td.styles.getOrDefault("text-align", "").toLowerAscii()
    if tdAlign in ["center", "right"]:
      r.setAttribute(td, "align", tdAlign) # R-TBL-14
    if "class" in c.attrs:
      for cls in c.attrs["class"].splitWhitespace():
        r.addClass(td, cls)
    var holder = td
    if max(nestedPad) > 0:
      let inner = r.createElement("table")
      for (k, v) in [("role", "presentation"), ("width", "100%"),
          ("border", "0"), ("cellpadding", "0"), ("cellspacing", "0")]:
        r.setAttribute(inner, k, v)
      let itr = r.createElement("tr")
      let itd = r.createElement("td")
      r.setStyle(itd, "padding", boxText(nestedPad))
      r.appendChild(itr, itd)
      r.appendChild(inner, itr)
      r.appendChild(td, inner)
      holder = itd
    moveContent(c, holder, r)
    result.holders.add(holder)
    r.appendChild(tr, td)
  result.table = table

proc lowerColumns*(row: EmailNode; ctx: LowerCtx):
    tuple[row: Row; diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one laid-out `mailColumns`: `row.nodes` replace it, and
  ## `row.holders` hold each column's content, lowered next.
  let r = EmailRenderer()
  let lb = row.layout
  if lb.strategy in ["cells", "cellsStacking"]:
    let cols = rowColumns(row)
    var others: seq[EmailNode] = @[]
    for c in row.children:
      if c notin cols and not isBlank(c):
        others.add(c)
    let (table, holders) = cellRow(row, ctx, r)
    # Anything but columns (P3 reported it) follows the table, kept.
    result.row = Row(nodes: @[table] & others, holders: holders & others)
    return
  let container = r.createElement("div")
  container.origin = row.origin
  if lb.reversed:
    r.setAttribute(container, "dir", "rtl")
  r.setStyle(container, "font-size", zeroFontSize)
  let dir = columnDir(row, ctx)
  r.setStyle(container, "text-align", if dir == "rtl": "right" else: "left")
  if lb.reversed:
    r.setStyle(container, "direction", "rtl")
  let holders = lowerInlineRow(row, ctx, container, r)
  result.row = Row(nodes: @[container], holders: holders)
