## isonim_email/lower/sidebar.nim — `mailSidebar` lowering: a fixed side
## beside a fluid one.
##
## Avatar and name, icon and text, a date tile and its details, a
## thumbnail and a teaser. The sidebar has two children: the fixed side
## (`fixed` px wide; the first child with `side = left`, the second with
## `side = right`) and the fluid side, which takes the rest less the
## `gap`. Source order is the visual order; in a right-to-left row the
## first child sits on the right.
##
## `switch_below = 0` (never switches): a **two-cell table**, the fixed
## cell `width="{fixed}"`, the fluid cell with no width and the gap as
## its padding on the side facing the fixed cell (_design rule_). The
## fluid cell absorbs the rest in every client, Word included; it never
## stacks, needs no CSS, and gives equal heights and vertical alignment
## (`valign` and `vertical-align`, R-TBL-14). Because it never stacks,
## the fluid side is checked at 320px (R-TBL-11, in P3).
##
## `switch_below > 0`: the hybrid pair (Cerberus thumbnail rows). Each
## side is an inline-block `div`: the fixed side `width:{fixed}px`, the
## fluid side `width:100%;min-width:{switch_below}px;max-width:{rest}px`,
## so the pair wraps without CSS once its row is narrower than
## `fixed + gap + switch_below`. The fluid side's cap is a fallback pair
## (R-CSS-19), the px rest of the row, then `max(calc(100% - {other
## side}px), calc(({switch_below + other side}px - 100%) * 9999))`: the
## rest of the row the client actually gives while that is at least
## `switch_below`, no cap below it, so a client that narrows the row (its
## own page padding) keeps a pair that fits side by side, and a wrapped
## side takes the whole row. The gap is trailing padding inside the
## first side, which is invisible once the sides wrap. Below the
## breakpoint, with head CSS, a class gives each side the full width and
## moves the gap to the top of the second. Word gets a ghost row of two
## cells (R-LAY-07). Heights are equal only side by side in a table, not
## here: a fluid side with a background is ragged (R-TBL-10).
## `reverse_on_mobile` reverses the desktop order of a switching pair as
## a row of columns does (R-LAY-11): `dir="rtl"` on the row, `dir="ltr"`
## restored on each side.
##
## A side of the table that holds no text and paints a background (an
## accent bar, a colour tile) paints its whole cell, so it runs the
## height of the row (the table's equal heights, R-TBL-10). Both
## lowerings break long unbroken words (R-TBL-17).
##
## Image cells (R-TBL-07): a side holding only an image, beside a side
## holding text, gets `&zwnj;` after the image inside an Outlook
## conditional, so that Word applies the cell's vertical alignment to
## the image.
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

proc holdsText(node: EmailNode): bool =
  ## True when `node` holds visible text (no-break spaces, which hold a
  ## cell open, are not text).
  if node.kind == enText:
    return node.text.replace("\u00a0", "").replace("&nbsp;", "").strip().len > 0
  for c in node.children:
    if holdsText(c):
      return true
  false

proc isImageOnly*(side: EmailNode): bool =
  ## True when `side` is nothing but one image: a `mailImage`, or an
  ## element whose only non-blank content is one (a link around it).
  if side.kind != enElement:
    return false
  if side.tag == "mailImage":
    return true
  var found: seq[EmailNode] = @[]
  for c in side.children:
    if c.kind == enText and c.text.strip().len == 0:
      continue
    found.add(c)
  found.len == 1 and isImageOnly(found[0])

proc sideValign(node: EmailNode): string =
  let v = rawValue(node, "valign").toLowerAscii()
  if v in ["top", "middle", "bottom"]: v else: "middle"

proc lowerSidebar*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; holders: seq[EmailNode];
      diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one laid-out `mailSidebar`: `nodes` replace it, `holders`
  ## hold the two sides' content, lowered next.
  let r = EmailRenderer()
  let lb = node.layout
  let sides = itemsOf(node)
  let va = sideValign(node)
  let contentRtl = lb.rtl
  let dir = if contentRtl: "rtl" else: "ltr"
  let start = if contentRtl: "right" else: "left"
  let flowRtl = contentRtl or (lb.reversed and lb.stacks)
  let g = lb.gutterPx
  # The image-cell rule: which side (if any) is an image beside text.
  var zwnjSide = -1
  if sides.len == 2:
    for i in 0 .. 1:
      if isImageOnly(sides[i]) and holdsText(sides[1 - i]):
        zwnjSide = i
  if not lb.stacks:
    # (`reverse_on_mobile` here is P1's error: nothing to reverse.)
    let table = r.createElement("table")
    table.origin = node.origin
    for (k, v) in [("role", "presentation"), ("width", "100%"),
        ("border", "0"), ("cellpadding", "0"), ("cellspacing", "0")]:
      r.setAttribute(table, k, v)
    if contentRtl:
      r.setAttribute(table, "dir", "rtl")
    let tr = r.createElement("tr")
    r.appendChild(table, tr)
    for i, side in sides:
      let td = r.createElement("td")
      td.origin = node.origin
      let fixed = i == lb.fixedIndex
      if fixed:
        r.setAttribute(td, "width", $lb.fixedPx)
      r.setAttribute(td, "valign", va)
      if fixed:
        r.setStyle(td, "width", $lb.fixedPx & "px")
      elif g > 0:
        # The gap, on the fluid cell's side facing the fixed one.
        let facesStart = i > lb.fixedIndex
        let physicalLeft = facesStart xor contentRtl
        r.setStyle(td, if physicalLeft: "padding-left" else: "padding-right",
          formatPx(float(g)))
      r.setStyle(td, "vertical-align", va)
      r.setStyle(td, "text-align", start)
      r.setStyle(td, "direction", dir)
      r.setStyle(td, "word-break", "break-word") # R-TBL-17
      r.setStyle(td, "overflow-wrap", "break-word")
      let paint = colourOf(side, "background-color")
      if paint.len > 0 and side.kind == enElement and not holdsText(side):
        # A side that is decoration only (an accent, a colour tile)
        # paints its whole cell, so it runs the height of the row.
        r.setAttribute(td, "bgcolor", paint)
        r.setStyle(td, "background-color", paint)
        if "class" in side.attrs:
          r.setAttribute(td, "class", side.attrs["class"])
      r.appendChild(td, side)
      if i == zwnjSide and ctx.target.outlookWord:
        r.appendChild(td, msoZwnj())
      r.appendChild(tr, td)
      result.holders.add(td)
    result.nodes = @[table]
    return
  # The switching pair.
  let container = r.createElement("div")
  container.origin = node.origin
  if lb.reversed:
    r.setAttribute(container, "dir", "rtl")
  r.setStyle(container, "font-size", zeroFontSize)
  r.setStyle(container, "text-align", if flowRtl: "right" else: "left")
  r.setStyle(container, "direction", if flowRtl: "rtl" else: "ltr")
  let fluidW = lb.box - lb.fixedPx - g
  for i, side in sides:
    let fixed = i == lb.fixedIndex
    let first = i == 0
    let trailing = if first: g else: 0
    let ghostW = (if fixed: lb.fixedPx else: fluidW) + trailing
    if ctx.target.outlookWord:
      let cell = GhostColumn(width: ghostW, valign: va)
      r.appendChild(container,
        if first: ghostRowOpen(cell, rtl = flowRtl) else: ghostRowNext(cell))
    let outer = r.createElement("div")
    outer.origin = node.origin
    r.setAttribute(outer, "class", sidebarStackClass)
    if lb.reversed:
      r.setAttribute(outer, "dir", dir)
    r.setStyle(outer, "display", "inline-block")
    if fixed:
      r.setStyle(outer, "width", $(lb.fixedPx + trailing) & "px")
      r.setStyle(outer, "max-width", "100%")
    else:
      r.setStyle(outer, "width", "100%")
      r.setStyle(outer, "min-width", $(lb.switchPx + trailing) & "px")
      # A fallback pair (R-CSS-19): the px rest of the row, then the
      # rest of whatever row the client gives, `calc(100% - {other})`,
      # while that is at least `switch_below`, and no cap at all below
      # it (the Fab Four's switch: a huge value then), so a client that
      # narrows the row (its own page padding) keeps the pair side by
      # side, and a pair that wraps takes the whole row, with or without
      # its `min-width`.
      let otherW = lb.fixedPx + (if first: 0 else: g)
      let minW = lb.switchPx + trailing
      r.setStyleWithFallback(outer, "max-width", $(fluidW + trailing) & "px",
        "max(calc(100% - " & $otherW & "px), calc((" & $(minW + otherW) &
        "px - 100%) * 9999))")
    r.setStyle(outer, "vertical-align", va)
    r.setStyle(outer, "font-size", "16px")
    r.setStyle(outer, "text-align", start)
    r.setStyle(outer, "direction", dir)
    r.setStyle(outer, "word-break", "break-word") # R-TBL-17
    r.setStyle(outer, "overflow-wrap", "break-word")
    var pad: array[4, int]
    if trailing > 0:
      if flowRtl: pad[3] = trailing else: pad[1] = trailing
    if ctx.target.outlookWord and trailing > 0:
      r.appendChild(outer, msoBoxOpen(GhostCell(padding: boxText(pad))))
    let padDiv = r.createElement("div")
    padDiv.origin = node.origin
    r.setAttribute(padDiv, "class",
      stackPadClass(if first: [0, 0, 0, 0] else: [g, 0, 0, 0]))
    if trailing > 0:
      r.setStyle(padDiv, "padding", boxText(pad))
    r.appendChild(padDiv, side)
    if i == zwnjSide and ctx.target.outlookWord:
      r.appendChild(padDiv, msoZwnj())
    r.appendChild(outer, padDiv)
    if ctx.target.outlookWord and trailing > 0:
      r.appendChild(outer, ghostTableClose())
    r.appendChild(container, outer)
    result.holders.add(padDiv)
  if ctx.target.outlookWord and sides.len > 0:
    r.appendChild(container, ghostTableClose())
  result.nodes = @[container]
