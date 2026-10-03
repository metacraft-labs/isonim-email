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
## wraps a table row. When every item's width can be estimated (text,
## measured with the text metrics at 16px bold; an image's own width)
## and the items do not fit the box, Word gets a ghost row per line
## instead, broken where the next item would run past the box. The
## cells carry no width, so padding them is safe, and every cell has the
## same vertical padding (none), so Word has nothing to equalise
## (R-TBL-03).
##
## A `separator` (`·`) follows every item but the last, inside the item,
## `aria-hidden` (screen readers read the items, not the dots), in the
## cluster's own text colour when it sets one, a gap
## away from it (for Word, which ignores the span's padding, a space).
## A line that wraps ends with its last item's separator, a declared
## degradation like its trailing gap. Items break a word too long for
## the line (`overflow-wrap:break-word`, R-TBL-17). Word's row never
## wraps, so a cluster whose items do not fit one line runs past its box
## there: a declared degradation (keep such clusters short, or let them
## wrap to a `mailGrid`).
##
## `role = navigation` (a `mailNavLinks`) puts the cluster in a one-cell
## table carrying `role="navigation"` and the `label` as `aria-label`
## (R-A11Y-10: landmark roles go on tables, never on a `<nav>`).
##
## Ghost rows come from `mso/ghost.nim` only. Pure tree building:
## identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/units
import ../style/metrics
import ../passes/layout
import ../mso/ghost
import ./section

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

proc collectText(n: EmailNode): string =
  if n.kind == enText:
    return n.text
  for c in n.children:
    result.add(collectText(c))

proc itemWidth(item: EmailNode): float =
  ## An item's estimated width in px for Word's rows: an image's own
  ## width (an expanded pattern or a link around it looked through),
  ## text at 16px bold (the widest the theme's links and labels get);
  ## -1 for anything else (a button, a box: unknown, no rows broken).
  var n = item
  while n.kind == enElement and (n.tag == "a" or n.expanded) and
      n.children.len == 1:
    n = n.children[0]
  if n.kind == enElement and n.tag in ["mailImage", "img"]:
    let w = rawValue(n, "width")
    if w.endsWith("px"):
      try:
        return parseFloat(w[0 ..< ^2])
      except ValueError:
        return -1
    return -1
  var hasElement = false
  proc scan(x: EmailNode) =
    if x.kind == enElement and x.tag notin ["a", "span", "strong", "b",
        "em", "i", "mailNavLink"]:
      hasElement = true
    for c in x.children:
      scan(c)
  scan(item)
  if hasElement and not item.expanded:
    return -1
  let t = collectText(item).strip()
  if t.len == 0:
    return -1
  measureFace(t, mfLiberationSans, true, 16.0).width

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
  proc cellPad(trailing: int; top = 0): string =
    ## A Word cell's padding: the trailing gap, and, on a ghost row after
    ## the first, the row gap above it.
    if trailing == 0 and top == 0: ""
    else:
      let t = formatPx(float(top))
      let g = formatPx(float(trailing))
      if rtl: t & " 0 0 " & g
      else: t & " " & g & " 0 0"
  # Word's rows: one ghost row, or, when every item's width can be
  # estimated and they do not fit the box, a row per line, broken where
  # the next item would run past the box (Word never wraps a row).
  var wordRowStart: seq[bool] = @[]
  block:
    var widths: seq[float] = @[]
    for item in items:
      widths.add(itemWidth(item))
    var running = 0.0
    for i, w in widths:
      let sep = if separator.len > 0 and i < items.high: float(g) + 12.0
        else: 0.0
      let need = w + sep + (if i < items.high: float(g) else: 0.0)
      let known = min(widths) >= 0
      if i > 0 and known and running + w > float(lb.box):
        wordRowStart.add(true)
        running = need
      else:
        wordRowStart.add(i == 0)
        running += need
  var inLaterRow = false
  for i, item in items:
    let last = i == items.len - 1
    let trailing = if last: 0 else: g
    let wordTrailing =
      if last or (i + 1 < items.len and wordRowStart[i + 1]): 0 else: g
    if ctx.target.outlookWord:
      if i > 0 and wordRowStart[i]:
        r.appendChild(container, ghostTableClose())
        inLaterRow = true
      let top = if inLaterRow: rowGap else: 0
      r.appendChild(container,
        if wordRowStart[i]: ghostClusterOpen(cellPad(wordTrailing, top),
          align, rtl)
        else: ghostClusterNext(cellPad(wordTrailing, top)))
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
      # The cluster's own text colour, when it has one (a navbar's), with
      # its dark class: a separator must not take a client's default
      # colour (R-TXT-02).
      let colour = node.styles.getOrDefault("color", "")
      if colour.len > 0 and not colour.startsWith("tok:"):
        r.setStyle(sep, "color", colour)
        let cls = node.attrs.getOrDefault("class", "")
        if cls.len > 0:
          r.setAttribute(sep, "class", cls)
      r.setStyle(sep, if rtl: "padding-right" else: "padding-left",
        formatPx(float(g)))
      r.setTextContent(sep, separator)
      r.appendChild(itemDiv, sep)
    r.appendChild(container, itemDiv)
    result.holders.add(itemDiv)
  if ctx.target.outlookWord and items.len > 0:
    r.appendChild(container, ghostTableClose())
  let role = node.attrs.getOrDefault("role", "").strip().toLowerAscii()
  if role.len == 0:
    result.nodes = @[container]
  elif role != "navigation":
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailCluster role '" & role &
        "' is not navigation (the one landmark a cluster carries, " &
        "R-A11Y-10)", origin: node.origin, rules: @["R-A11Y-10"]))
    result.nodes = @[container]
  else:
    # R-A11Y-10: a landmark's role goes on a table, the element Yahoo
    # keeps a role on; never a `<nav>`. One cell, full width, the
    # cluster inside it as it would be anywhere else.
    let table = r.createElement("table")
    table.origin = node.origin
    r.setAttribute(table, "role", "navigation")
    let label = node.attrs.getOrDefault("label", "").strip()
    if label.len > 0:
      r.setAttribute(table, "aria-label", label)
    r.setAttribute(table, "width", "100%")
    r.setAttribute(table, "border", "0")
    r.setAttribute(table, "cellpadding", "0")
    r.setAttribute(table, "cellspacing", "0")
    r.setStyle(table, "width", "100%")
    let tr = r.createElement("tr")
    let td = r.createElement("td")
    r.setStyle(td, "padding", "0")
    r.appendChild(td, container)
    r.appendChild(tr, td)
    r.appendChild(table, tr)
    result.nodes = @[table]
