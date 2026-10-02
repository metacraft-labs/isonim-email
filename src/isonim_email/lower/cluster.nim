## isonim_email/lower/cluster.nim — `mailCluster` lowering: inline items
## that wrap.
##
## Navigation, social icons, badges, button pairs, footer links: items
## on one line that wrap onto more when the line is full. The container
## is a `div` with a zero font size written `0.01px` (R-LAY-04) and the
## cluster's `text-align`; each item is an inline-block `div` whose
## padding is the gap, `padding:0 {gap} {row_gap} 0` (the trailing side
## in the direction of the line), with the font size reset. Gaps are
## never `gap` or margins (R-TBL-04). The last item has no trailing gap,
## so a one-line cluster ends flush with its edge whatever its
## alignment; where a line wraps, the line's last item keeps its gap (the
## wrap point is unknown at render time: a declared degradation), and
## every line keeps the row gap below it.
##
## Word gets a single-row ghost table (MJML `mj-social`, `mj-navbar`)
## with one cell per item and the gap as the cell's padding: Word never
## wraps a table row, which is acceptable for a desktop-only client. The
## cells carry no width, so padding them is safe, and every cell has the
## same vertical padding (none), so Word has nothing to equalise
## (R-TBL-03).
##
## A `separator` (`·`) follows every item but the last, inside the item,
## `aria-hidden` (screen readers read the items, not the dots), a gap
## away from it (for Word, which ignores the span's padding, a space).
## A line that wraps ends with its last item's separator, a declared
## degradation like its trailing gap. Items break a word too long for
## the line (`overflow-wrap:break-word`, R-TBL-17). Word's row never
## wraps, so a cluster whose items do not fit one line runs past its box
## there: a declared degradation (keep such clusters short, or let them
## wrap to a `mailGrid`).
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

proc lowerCluster*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; holders: seq[EmailNode];
      diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one laid-out `mailCluster`: `nodes` replace it, `holders`
  ## hold each item, lowered next.
  let r = EmailRenderer()
  let lb = node.layout
  let items = itemsOf(node)
  let g = lb.gutterPx
  let rowGap = lb.mobileGap
  let rtl = lb.rtl
  let start = if rtl: "right" else: "left"
  var align = rawValue(node, "align").toLowerAscii()
  if align notin ["left", "center", "right"]:
    if align.len > 0:
      result.diagnostics.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue, message: "mailCluster align '" & align &
          "' is not left, center or right", origin: node.origin))
    align = start
  let separator = node.attrs.getOrDefault("separator", "")
  let container = r.createElement("div")
  container.origin = node.origin
  r.setStyle(container, "font-size", zeroFontSize)
  r.setStyle(container, "text-align", align)
  r.setStyle(container, "direction", if rtl: "rtl" else: "ltr")
  proc cellPad(trailing: int): string =
    if trailing == 0: ""
    elif rtl: "0 0 0 " & formatPx(float(trailing))
    else: "0 " & formatPx(float(trailing)) & " 0 0"
  for i, item in items:
    let last = i == items.len - 1
    let trailing = if last: 0 else: g
    if ctx.target.outlookWord:
      r.appendChild(container,
        if i == 0: ghostClusterOpen(cellPad(trailing), align, rtl)
        else: ghostClusterNext(cellPad(trailing)))
    let itemDiv = r.createElement("div")
    itemDiv.origin = node.origin
    r.setStyle(itemDiv, "display", "inline-block")
    r.setStyle(itemDiv, "vertical-align", "middle")
    let sides = if rtl: [0, 0, rowGap, trailing] else: [0, trailing, rowGap, 0]
    if max(sides) > 0:
      r.setStyle(itemDiv, "padding", boxText(sides))
    r.setStyle(itemDiv, "font-size", "16px")
    # A long unbroken word breaks inside its item, and only a word too
    # long for the line (R-TBL-17): `overflow-wrap`, which leaves the
    # item's narrowest width alone, so a row Word cannot wrap never
    # squeezes every label into broken words.
    r.setStyle(itemDiv, "overflow-wrap", "break-word")
    r.appendChild(itemDiv, item)
    if separator.len > 0 and not last:
      if ctx.target.outlookWord:
        # Word ignores the span's padding: a space keeps the separator
        # off the item.
        r.appendChild(itemDiv, msoSpace())
      let sep = r.createElement("span")
      sep.origin = node.origin
      r.setAttribute(sep, "aria-hidden", "true")
      r.setStyle(sep, if rtl: "padding-right" else: "padding-left",
        formatPx(float(g)))
      r.setTextContent(sep, separator)
      r.appendChild(itemDiv, sep)
    r.appendChild(container, itemDiv)
    result.holders.add(itemDiv)
  if ctx.target.outlookWord and items.len > 0:
    r.appendChild(container, ghostTableClose())
  result.nodes = @[container]
