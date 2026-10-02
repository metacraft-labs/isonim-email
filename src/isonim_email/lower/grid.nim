## isonim_email/lower/grid.nim — `mailGrid` lowering: n-up items that
## wrap.
##
## A grid of N columns (2-4) is a row of inline-block items, each as
## wide as `(B − (N−1)·gutter)/N` px (`layout.gridItemWidths`), in a
## container with a zero font size written `0.01px` (R-LAY-04) and
## nothing between the items (R-LAY-05). The inline state is the desktop
## grid: an item that does not end its desktop row carries the gutter
## as padding on its trailing side, and every item but the last the
## gutter below it, so N items fill a row exactly, the rows are a
## gutter apart, and items that wrap without CSS keep a gap between
## them too. Items break long unbroken words (R-TBL-17). Each item is `width:100%` capped at its desktop width,
## so it never overflows a narrower row.
##
## - Below the breakpoint, with head CSS, a class makes every item the
##   full width of the row and moves the gutter to the top of every item
##   but the first: one item per row, stacked.
## - Without head CSS the items wrap as many as fit (3 + 1, 2 + 2, …): a
##   declared degradation (layout-patterns.md §3.4).
## - Word gets a ghost table **chunked into rows of N** (`</tr><tr>`),
##   because Word's tables never wrap (Foundation for Emails block-grid);
##   its cells carry the item widths and never padding (R-LAY-07), the
##   gutters going on a single-cell table inside each. An incomplete last
##   row is padded with sized spacer cells (R-TBL-05), so the table's
##   cells stay in columns; a centred or stretched last row gets a ghost
##   table of its own instead.
## - `last_row`: `left` (default) leaves an incomplete last row at the
##   start edge, `center` centres it, `stretch` widens its items to fill
##   it.
## - `align` aligns each item's content (default: the start of the
##   direction), as `mailStack(align)` does.
##
## `mobile_columns = 2` is not lowered here: such a grid is a
## composition (an outer two-column hybrid row of two-item `cells`
## rows), which `primitives.nim` expands before layout.
##
## Ghost rows come from `mso/ghost.nim` only. Pure tree building:
## identical on the C and JS targets.

import std/[math, strutils]
import ../renderer
import ../style/units
import ../diagnostics
import ../target
import ../passes/layout
import ../mso/ghost
import ./section

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

proc sidesText(bottom, trailing: int; rtl: bool): array[4, int] =
  ## Padding sides for a gutter below and one on the trailing side.
  if rtl: [0, 0, bottom, trailing] else: [0, trailing, bottom, 0]

proc lowerGrid*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; holders: seq[EmailNode];
      diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one laid-out `mailGrid` (one item per row on a phone):
  ## `nodes` replace it, and `holders` hold each item, lowered next.
  let r = EmailRenderer()
  let lb = node.layout
  let items = itemsOf(node)
  let n = max(lb.columns, 1)
  let g = lb.gutterPx
  let count = items.len
  let widths = gridItemWidths(lb.box, n, g, count, lb.lastRow)
  let full = gridItemWidths(lb.box, n, g, n, "left")
  let rtl = lb.rtl
  let dir = if rtl: "rtl" else: "ltr"
  let start = if rtl: "right" else: "left"
  var contentAlign = rawValue(node, "align").toLowerAscii()
  if contentAlign notin ["left", "center", "right"]:
    if contentAlign.len > 0:
      result.diagnostics.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue, message: "mailGrid align '" &
          contentAlign & "' is not left, center or right",
        origin: node.origin))
    contentAlign = start
  var minItem = 160
  let given = rawValue(node, "min_item")
  if given.len > 0 and not given.startsWith("tok:"):
    try:
      minItem = int(toPx(given))
    except StyleError, ValueError:
      discard
  let container = r.createElement("div")
  container.origin = node.origin
  r.setStyle(container, "font-size", zeroFontSize)
  r.setStyle(container, "text-align",
    if lb.lastRow == "center": "center" else: start)
  r.setStyle(container, "direction", dir)
  let rest = count mod n
  let lastStart = if rest > 0: count - rest else: count
  let ownTable = rest > 0 and lb.lastRow in ["center", "stretch"]
  for i, item in items:
    let col = i mod n
    let trailing = if col < n - 1 and i < count - 1: g else: 0
    # The row gap below every item but the last: items that wrap where
    # the head CSS is lost keep a gap between them too.
    let bottom = if i < count - 1: g else: 0
    let pad = sidesText(bottom, trailing, rtl)
    let outerW = widths[i] + trailing
    let inOwn = ownTable and i >= lastStart
    # Word keeps a regular grid of slots: an item that drops its gutter
    # still sits in a slot that has one (unless its row has a table of
    # its own).
    let wordPad = sidesText(bottom,
      if inOwn: trailing elif col < n - 1: g else: 0, rtl)
    if ctx.target.outlookWord:
      # Word: a regular grid of slots (the slot keeps its gutter even
      # where the item drops it), except in a last row of its own.
      let slot = if inOwn: outerW
        else: full[col] + (if col < n - 1: g else: 0)
      let cell = GhostColumn(width: slot, valign: "top")
      if i == 0:
        r.appendChild(container, ghostRowOpen(cell, rtl = rtl))
      elif col == 0 and inOwn:
        r.appendChild(container, ghostRowSwitch(cell,
          centred = lb.lastRow == "center", rtl = rtl))
      elif col == 0:
        r.appendChild(container, ghostRowBreak(cell))
      else:
        r.appendChild(container, ghostRowNext(cell))
    let outer = r.createElement("div")
    outer.origin = node.origin
    r.setAttribute(outer, "class", gridItemClass)
    r.setStyle(outer, "display", "inline-block")
    r.setStyle(outer, "width", "100%")
    # The cap is a fallback pair (R-CSS-19): the px width, then
    # `max({min}px, {pct}%)`, its share of the row, so a row a client
    # narrows (its own page padding) still holds N items, and an item
    # never shrinks below `min_item` (it wraps instead). A client
    # without `max()` keeps the px cap.
    let minPx = min(minItem, widths[i]) + trailing
    let pct = floor(float(outerW) / float(max(lb.box, 1)) * 1_000_000.0) /
      10_000.0
    r.setStyleWithFallback(outer, "max-width", $outerW & "px",
      "max(" & $minPx & "px, " & percentText(pct) & "%)")
    r.setStyle(outer, "vertical-align", "top")
    r.setStyle(outer, "font-size", "16px")
    r.setStyle(outer, "text-align", contentAlign)
    r.setStyle(outer, "direction", dir)
    # A long unbroken word breaks inside the item (R-TBL-17).
    r.setStyle(outer, "word-break", "break-word")
    r.setStyle(outer, "overflow-wrap", "break-word")
    r.appendChild(container, outer)
    var opened = false
    if ctx.target.outlookWord and (max(wordPad) > 0 or
        contentAlign in ["center", "right"] and contentAlign != start):
      r.appendChild(outer, msoBoxOpen(GhostCell(
        padding: if max(wordPad) > 0: boxText(wordPad) else: "",
        align: if contentAlign in ["center", "right"]: contentAlign
          else: "")))
      opened = true
    var holder = outer
    if i > 0 or max(pad) > 0:
      # The gutters, swapped for the stacked top gap below the
      # breakpoint (`e-stackpad-…`).
      let padDiv = r.createElement("div")
      padDiv.origin = node.origin
      r.setAttribute(padDiv, "class",
        stackPadClass(if i == 0: [0, 0, 0, 0] else: [g, 0, 0, 0]))
      if max(pad) > 0:
        r.setStyle(padDiv, "padding", boxText(pad))
      r.appendChild(outer, padDiv)
      holder = padDiv
    r.appendChild(holder, item)
    if opened:
      r.appendChild(outer, ghostTableClose())
    result.holders.add(holder)
    if ctx.target.outlookWord and i == count - 1 and rest > 0 and
        not ownTable:
      # The slots the last row does not fill, sized and never empty.
      for c in rest ..< n:
        r.appendChild(container, ghostSpacerCell(
          full[c] + (if c < n - 1: g else: 0)))
  if ctx.target.outlookWord and count > 0:
    r.appendChild(container, ghostTableClose())
  result.nodes = @[container]
