## isonim_email/lower/table_style.nim — a data table's default
## declarations (catalogue R-TBL-18), which the style pass prepends to
## the author's own: the `table` of a `mailTable` is `width:100%` with a
## collapse of its own, and each of its cells carries its padding, its
## top alignment, the table's border as its bottom border and, in every
## second body row of a `striped` table, the subtle surface colour; a
## header cell is bold and start-aligned. Colours are theme tokens, so
## `darkMode = designed` pairs them like any other (R-DRK-02). A module
## of its own because the style pass imports it, and the lowering
## (`lower/data_table.nim`) imports the style pass.
##
## Pure tree reading: identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../target
import ../style/tokens
import ../style/shorthand

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  tableBorderToken* = "color.border.subtle"
    ## The default cell border's colour.
  tableStripeToken* = "color.surface.subtle"
    ## A striped row's background.

proc dataTableOf*(node: EmailNode): EmailNode =
  ## The `mailTable` a `table`, row, section or cell belongs to (its
  ## nearest), or nil.
  var a = node.parent
  var depth = 0
  while a != nil and depth < 4:
    if a.kind == enElement:
      if a.tag == "mailTable":
        return a
      if a.tag notin ["table", "thead", "tbody", "tr"]:
        return nil
    a = a.parent
    inc depth
  nil

proc tableOf*(dataTable: EmailNode): EmailNode =
  ## The `table` a `mailTable` holds, or nil.
  if dataTable == nil:
    return nil
  for c in dataTable.children:
    if c.kind == enElement and c.tag == "table":
      return c
  nil

proc rowsOf*(table: EmailNode): seq[EmailNode] =
  ## Every row of a data table in order, through `thead`/`tbody`.
  if table == nil:
    return
  for c in table.children:
    if c.kind != enElement:
      continue
    if c.tag == "tr":
      result.add(c)
    elif c.tag in ["thead", "tbody"]:
      for r in c.children:
        if r.kind == enElement and r.tag == "tr":
          result.add(r)

proc cellsOf*(row: EmailNode): seq[EmailNode] =
  for c in row.children:
    if c.kind == enElement and c.tag in ["td", "th"]:
      result.add(c)

proc headerRow*(table: EmailNode): EmailNode =
  ## The row that heads the columns: the first row of the `thead`, else
  ## a first row of header cells only; nil when there is none.
  if table == nil:
    return nil
  for c in table.children:
    if c.kind == enElement and c.tag == "thead":
      for r in c.children:
        if r.kind == enElement and r.tag == "tr":
          return r
  let rows = rowsOf(table)
  if rows.len == 0:
    return nil
  let cells = cellsOf(rows[0])
  if cells.len == 0:
    return nil
  for cell in cells:
    if cell.tag != "th":
      return nil
  rows[0]

proc bodyRows*(table: EmailNode): seq[EmailNode] =
  ## The rows below the header row (every row when there is none).
  let head = headerRow(table)
  for r in rowsOf(table):
    if r != head and not (r.parent != nil and r.parent.kind == enElement and
        r.parent.tag == "thead"):
      result.add(r)

proc spanOf*(cell: EmailNode): int =
  try:
    max(1, parseInt(cell.attrs.getOrDefault("colspan", "1").strip()))
  except ValueError:
    1

proc columnCount*(table: EmailNode): int =
  ## The widest row's cells, `colspan` counted (R-TBL-18).
  for r in rowsOf(table):
    var n = 0
    for c in cellsOf(r):
      n += spanOf(c)
    result = max(result, n)

proc tableMode*(dataTable: EmailNode): string =
  ## A `mailTable`'s mobile mode: its `mobile`, else `stack` for more
  ## than 3 columns and `keep` otherwise (R-TBL-18). An unknown value
  ## reads as the default (P4 reports it).
  let m = dataTable.attrs.getOrDefault("mobile", "").strip().toLowerAscii()
  if m in ["stack", "scroll", "keep"]:
    return m
  if columnCount(tableOf(dataTable)) > 3: "stack" else: "keep"

proc tableRtl(node: EmailNode): bool =
  var a = node
  while a != nil:
    if a.kind == enElement:
      let own = a.styles.getOrDefault("direction",
        a.attrs.getOrDefault("direction", "")).toLowerAscii()
      if own in ["ltr", "rtl"]:
        return own == "rtl"
      let d = a.attrs.getOrDefault("dir", "").toLowerAscii()
      if d in ["ltr", "rtl"]:
        return d == "rtl"
    a = a.parent
  false

type TableBorder* = tuple[none: bool; width, style, color: string;
  token: bool]

proc tableBorder*(dataTable: EmailNode): TableBorder =
  ## The cells' bottom border from a `mailTable`'s `border`: none, the
  ## author's (a `Border`), or the default `1px solid` in the subtle
  ## border colour (a token). Raises `StyleError` on a value that is
  ## neither `none` nor a `Border`.
  var v = dataTable.styles.getOrDefault("border",
    dataTable.attrs.getOrDefault("border", "")).strip()
  if v.len == 0:
    return (false, "1px", "solid", "tok:" & tableBorderToken, true)
  if v.toLowerAscii() in ["none", "0", "0px"]:
    return (true, "", "", "", false)
  if v.startsWith("tok:"):
    return (false, "1px", "solid", v, true)
  let b = parseBorder(v)
  (false, $int(b.widthPx) & "px", b.style, b.color.toHex(), false)

const longWordChars* = 20
  ## A word longer than this breaks inside its cell or link (R-TBL-17).

proc hasLongWord*(node: EmailNode): bool =
  ## True when some text under `node` holds a word longer than
  ## `longWordChars` characters.
  if node.kind == enText:
    for w in node.text.splitWhitespace():
      if w.len > longWordChars:
        return true
    return false
  for c in node.children:
    if hasLongWord(c):
      return true
  false

proc hasStyle(node: EmailNode; prefix: string): bool =
  for k in node.styles.keys:
    if k.startsWith(prefix):
      return true
  false

proc tableDefaults*(node: EmailNode; theme: EmailTheme;
    target: EmailTarget): seq[tuple[prop, value: string]] =
  ## The declarations the style pass prepends to the `table` and the
  ## cells of a `mailTable` (see the module comment); empty for every
  ## other element. Raises `StyleError` on a bad `border` and
  ## `ThemeError` when the theme lacks a key.
  if node == nil or node.kind != enElement or
      node.tag notin ["table", "td", "th"]:
    return
  let dt = dataTableOf(node)
  if dt == nil:
    return
  if node.tag == "table":
    result.add(("width", "100%"))
    result.add(("border-collapse", "collapse"))
    return
  let dark = target.darkMode == dmDesigned
  result.add(("padding", theme.lightFor("space.2") & " " &
    theme.lightFor("space.3")))
  if "valign" notin node.attrs:
    # An author's `valign` attribute stands for the CSS (R-OL-09).
    result.add(("vertical-align", "top"))
  if hasLongWord(node):
    # A long unbroken word (a reference, a URL) breaks inside its cell
    # instead of widening the table past the message (R-TBL-17). Only
    # there: on every cell it would let the table squeeze short columns
    # into broken words.
    result.add(("word-break", "break-word"))
  let b = tableBorder(dt)
  if not b.none and not node.hasStyle("border"):
    result.add(("border-bottom-width", b.width))
    result.add(("border-bottom-style", b.style))
    result.add(("border-bottom-color", b.color))
    if dark and b.token:
      result.add(("@dark:border-bottom-color", b.color))
  if node.tag == "th":
    result.add(("font-weight", "700"))
    if "align" notin node.attrs:
      result.add(("text-align", if tableRtl(node): "right" else: "left"))
  if dt.attrs.getOrDefault("striped", "").toLowerAscii() == "true" and
      "background-color" notin node.styles and
      "background" notin node.styles:
    let row = node.parent
    let rows = bodyRows(tableOf(dt))
    let at = rows.find(row)
    if at >= 0 and at mod 2 == 1:
      result.add(("background-color", "tok:" & tableStripeToken))
      if dark:
        result.add(("@dark:background-color", "tok:" & tableStripeToken))
