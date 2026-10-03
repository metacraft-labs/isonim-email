## isonim_email/lower/data_table.nim — `mailTable`, the data table
## (catalogue R-TBL-18, R-A11Y-09).
##
## Invoices and line items are real tables. The author's `table` is the
## output's: `role="table"` (P7 marks every other table presentational),
## `border="0" cellpadding="0" cellspacing="0" width="100%"`, and the
## style pass has already given it `width:100%;border-collapse:collapse`
## and its cells their padding, alignment, borders and stripes
## (`lower/table_style.nim`). A `caption` prop becomes the visually
## hidden caption, the table's first child:
##
## ```html
## <caption style="mso-hide:all;position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);">Order 1042</caption>
## ```
##
## **Mobile** (`passes/layout.nim`'s `columnRules` names the rules, P6
## writes them):
##
## - `stack` (default above 3 columns) is mobile-first (`finishStack`,
##   once the cells' content is lowered): inline, the table, its body,
##   rows and cells are blocks, the header row is hidden, every cell but
##   a row's last has no rule or bottom padding, and each body `td`
##   starts with a bold label, its column's header text and `: `
##   (columns matched by position, `colspan` counted; a body `th` heads
##   its row and gets none). From the breakpoint up, rules restore the
##   table, copied for Thunderbird; below it a cell's line starts at the
##   start. A client without head CSS reads the stacked form. Word reads
##   none of this: with `outlookWord` it gets the plain table, a copy in
##   an `mso` conditional, the stacked one inside `!mso`.
## - `scroll`: the table sits in `<div style="overflow-x:auto;">`, itself
##   in a one-cell presentation table with `table-layout:fixed` (without
##   head CSS the auto-layout tables around it would grow to the data
##   table's narrowest width), and, by the class `e-tbl-min-{px}`, keeps
##   its desktop width as a minimum below the breakpoint, so the
##   container scrolls instead of the table squeezing.
## - `keep` (default up to 3 columns): nothing changes.
##
## Pure tree building: identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../passes/layout
import ./section
import ./table_style
import ./conditional
import ../mso/cond

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

proc addClass(node: EmailNode; cls: string) =
  let old = node.attrs.getOrDefault("class", "").strip()
  node.attrs["class"] = if old.len > 0: old & " " & cls else: cls

proc textOf(n: EmailNode): string =
  if n.kind == enText:
    return n.text
  for c in n.children:
    result.add(textOf(c))

proc headerTexts(head: EmailNode): seq[string] =
  ## The header text of each column, a spanning header repeated over
  ## the columns it spans.
  if head == nil:
    return
  for cell in cellsOf(head):
    let t = splitWhitespace(textOf(cell)).join(" ")
    for _ in 1 .. spanOf(cell):
      result.add(t)

proc framed(r: EmailRenderer; node, table: EmailNode): EmailNode =
  ## `table` in `<div style="overflow-x:auto;">`, itself in a one-cell
  ## presentation table with `width:100%;table-layout:fixed`: without
  ## the reset the auto-layout tables around it would grow to the data
  ## table's narrowest width and widen the message past a phone's screen
  ## (R-TBL-18).
  let wrap = r.createElement("div")
  wrap.origin = node.origin
  r.setStyle(wrap, "overflow-x", "auto")
  r.appendChild(wrap, table)
  result = r.createElement("table")
  result.origin = node.origin
  for (k, v) in [("role", "presentation"), ("border", "0"),
      ("cellpadding", "0"), ("cellspacing", "0"), ("width", "100%")]:
    r.setAttribute(result, k, v)
  r.setStyle(result, "width", "100%")
  r.setStyle(result, "table-layout", "fixed")
  let tr = r.createElement("tr")
  let td = r.createElement("td")
  r.appendChild(td, wrap)
  r.appendChild(tr, td)
  r.appendChild(result, tr)

proc lowerTable*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; inner: EmailNode;
      diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one `mailTable`: `nodes` replace it, `inner` (the table)
  ## holds the cells' content, lowered next. A `mailTable` P1 refused
  ## (no single `table`) is replaced by its content.
  let r = EmailRenderer()
  let table = tableOf(node)
  if table == nil:
    result.nodes = node.children
    return
  let mode = tableMode(node)
  let m = node.attrs.getOrDefault("mobile", "").strip().toLowerAscii()
  if m.len > 0 and m notin ["stack", "scroll", "keep"]:
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailTable mobile '" & m &
        "' is not stack, scroll or keep (R-TBL-18)", origin: node.origin,
      rules: @["R-TBL-18"]))
  table.parent = nil
  table.attrs["role"] = "table"
  for (k, v) in [("border", "0"), ("cellpadding", "0"),
      ("cellspacing", "0"), ("width", "100%")]:
    if k notin table.attrs:
      table.attrs[k] = v
  if "table-layout" notin table.styles:
    # The reset fixes every table's layout (R-RST-06), which gives every
    # column the same width; a data table's columns take their
    # content's, so only `!important` inline beats the reset.
    r.setStyle(table, "table-layout", "auto !important")
  let caption = node.attrs.getOrDefault("caption", "").strip()
  if caption.len > 0:
    # R-A11Y-09: read by screen readers, hidden from everyone else,
    # Word included (R-OL-14).
    let cap = r.createElement("caption")
    cap.origin = node.origin
    r.setStyle(cap, "mso-hide", "all")
    r.setStyle(cap, "position", "absolute")
    r.setStyle(cap, "width", "1px")
    r.setStyle(cap, "height", "1px")
    r.setStyle(cap, "overflow", "hidden")
    r.setStyle(cap, "clip", "rect(0 0 0 0)")
    r.setTextContent(cap, caption)
    cap.parent = table
    table.children.insert(cap, 0)
  if mode == "stack":
    # Finished by `finishStack` once the cells' content is lowered.
    result.nodes = @[table]
  elif mode == "scroll":
    table.addClass(scrollMinClass(node.layout.box))
    result.nodes = @[framed(r, node, table)]
  else:
    result.nodes = @[table]
  result.inner = table

proc finishStack*(table: EmailNode; ctx: LowerCtx): seq[EmailNode] =
  ## The nodes a stacking data table becomes once its cells' content is
  ## lowered (R-TBL-18). The table everyone but Word reads is
  ## mobile-first: inline, its rows and cells are blocks, the header row
  ## is hidden and each body `td` starts with its column's label, so a
  ## client without head CSS (or without media queries) reads complete
  ## "label: value" groups; from the breakpoint up, desktop rules (also
  ## copied for Thunderbird, which applies no media query) restore the
  ## table. Word, which reads none of that CSS, gets the plain table, a
  ## copy inside an `mso` conditional, the rest inside `!mso`.
  let r = EmailRenderer()
  var word: EmailNode = nil
  if ctx.target.outlookWord:
    word = flatten(@[copyTree(table)], true)[0]
  let head = headerRow(table)
  let labels = headerTexts(head)
  table.addClass(stackTableClass)
  r.setStyle(table, "display", "block")
  for c in table.children:
    if c.kind == enElement and c.tag == "tbody":
      c.addClass(stackGroupClass)
      r.setStyle(c, "display", "block")
  if head != nil:
    head.addClass(stackHeadClass)
    r.setStyle(head, "display", "none")
  for row in bodyRows(table):
    row.addClass(stackRowClass)
    r.setStyle(row, "display", "block")
    let cells = cellsOf(row)
    var col = 0
    for i, cell in cells:
      cell.addClass(stackCellClass)
      r.setStyle(cell, "display", "block")
      let a = cell.styles.getOrDefault("text-align", "").toLowerAscii()
      if a in ["left", "right", "center"]:
        # A stacked line starts at the start of the line; the cell's own
        # alignment comes back with the table.
        cell.addClass(stackAlignClass(a))
        r.setStyle(cell, "text-align", "inherit")
        cell.attrs.del("align")
      if i < cells.high:
        # Inside a row's group: no rule and no bottom padding until the
        # desktop rule restores them.
        let width = cell.styles.getOrDefault("border-bottom-width", "0")
        cell.addClass(stackInnerClass(width))
        if "border-bottom-width" in cell.styles:
          r.setStyle(cell, "border-bottom-width", "0")
        r.setStyle(cell, "padding-bottom", "0")
      if cell.tag == "td" and col < labels.len and labels[col].len > 0:
        let lbl = r.createElement("span")
        lbl.origin = table.origin
        r.setAttribute(lbl, "class", stackLabelClass)
        r.setStyle(lbl, "font-weight", "700")
        r.setTextContent(lbl, labels[col] & ": ")
        lbl.parent = cell
        cell.children.insert(lbl, 0)
      col += spanOf(cell)
  if word == nil:
    return @[table]
  let web = flatten(@[table], false)[0]
  @[msoWrap(word), notMsoWrap(web)]
