## isonim_email/mso/ghost.nim — Outlook ghost tables.
##
## The Word engine ignores `width`, `max-width` and padding on `div`s,
## so every div-first container gets a table that only Word sees
## (R-OL-03, R-LAY-06): opened in one `<!--[if mso]>` before the
## container's `div` and closed in another after it. The open and the
## close are separate conditionals around ordinary content, so their
## payloads are unbalanced HTML and ride as raw nodes inside typed
## `MsoIf`s (as `mso/document.nim`'s settings payload does); the
## conditional itself stays typed, so the serialiser still checks the
## balance of the comments and prunes nothing it cannot see.
##
## Everything here is built from values the lowerings computed; the
## attribute text is escaped with the serialiser's email attribute
## escaping, so a colour or a class can never break out of its quotes.
##
## Allowed IR site: `tests/t1_ir_restriction.nim` admits constructor
## calls from `mso/`.
##
## Pure tree building: identical on the C and JS targets.

import std/tables
import ../ir
import ../serialize
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run. Every
## family: the ghost tables reach Word only, but the band's border frame
## (`notMsoOpen`) is `<!--[if !mso]>` content, which every family but
## Word renders.
const affects*: set[ClientFamily] = allFamilies

export ir

type GhostCell* = object
  ## What a ghost cell mirrors from its container (R-TBL-02): the
  ## padding, background, border and alignment Word must honour. Empty
  ## strings are omitted.
  padding*: string     ## CSS `padding` value (`24px`, `24px 0`)
  background*: string  ## 6-digit hex, mirrored as `bgcolor` and CSS
  border*: string      ## CSS `border` value (`1px solid #e5e7eb`)
  align*: string       ## `center`/`right`, mirrored as `align` and CSS (R-TBL-14)
  direction*: string   ## `rtl`/`ltr`, CSS only (a cell Word lays a band's content in)

proc tagText(tag: string; attrs: openArray[(string, string)]): string =
  ## `<tag a="v" …>`, attribute values escaped, empty values skipped.
  result = "<" & tag
  for (k, v) in attrs:
    if v.len > 0:
      result.add(" " & k & "=\"" & escapeEmailAttr(v) & "\"")
  result.add(">")

proc cellStyle(cell: GhostCell): string =
  if cell.padding.len > 0:
    result.add("padding:" & cell.padding & ";")
  if cell.background.len > 0:
    result.add("background-color:" & cell.background & ";")
  if cell.border.len > 0:
    result.add("border:" & cell.border & ";")
  if cell.align.len > 0:
    result.add("text-align:" & cell.align & ";")
  if cell.direction.len > 0:
    result.add("direction:" & cell.direction & ";")

proc cellTag(cell: GhostCell): string =
  tagText("td", [("bgcolor", cell.background), ("align", cell.align),
    ("style", cellStyle(cell))])

proc ghostTableOpen*(width: int; cell: GhostCell): EmailNode =
  ## R-LAY-06: `<!--[if mso]><table role="presentation" align="center"
  ## border="0" cellpadding="0" cellspacing="0" width="{W}"
  ## style="width:{W}px;"><tr><td …><![endif]-->`. Word centres the box
  ## through the table's `align` (R-TBL-14), never through `margin:auto`.
  let table = tagText("table", [("role", "presentation"),
    ("align", "center"), ("border", "0"), ("cellpadding", "0"),
    ("cellspacing", "0"), ("width", $width),
    ("style", "width:" & $width & "px;")])
  newMsoIf("mso", @[raw(table & "<tr>" & cellTag(cell))])

proc ghostTableClose*(): EmailNode =
  ## `<!--[if mso]></td></tr></table><![endif]-->`: closes a ghost
  ## table (and a full-width table, which has the same shape).
  newMsoIf("mso", @[raw("</td></tr></table>")])

proc fullWidthTableOpen*(background: string): EmailNode =
  ## R-LAY-09: the full-bleed band Word sees around a `full_width`
  ## section: a 100% table whose one cell paints the background.
  let table = tagText("table", [("role", "presentation"),
    ("width", "100%"), ("border", "0"), ("cellpadding", "0"),
    ("cellspacing", "0")])
  newMsoIf("mso", @[raw(table & "<tr>" &
    cellTag(GhostCell(background: background)))])

proc spacerRowText(height: int): string =
  ## `spacerRow`'s payload, written every time.
  let table = tagText("table", [("role", "presentation"),
    ("width", "100%"), ("border", "0"), ("cellpadding", "0"),
    ("cellspacing", "0")])
  let td = tagText("td", [("height", $height), ("aria-hidden", "true"),
    ("style", "height:" & $height & "px;font-size:0;line-height:0;" &
      "mso-line-height-rule:exactly;")])
  table & "<tr>" & td & "&nbsp;</td></tr></table>"

var spacerRowMemo {.threadvar.}: Table[int, string]
  ## `spacerRow`'s payload per height, as written once on this thread: a
  ## stack writes one between every two children, at a few heights.

proc spacerRow*(height: int): EmailNode =
  ## The vertical gap Word sees between stacked children (R-TBL-04,
  ## R-TBL-05): a one-cell table whose sized cell is never empty, with
  ## exact line height so the gap is exactly `height` px.
  var text: string
  spacerRowMemo.withValue(height, kept):
    text = kept[]
  do:
    text = spacerRowText(height)
    if spacerRowMemo.len >= 1024:
      spacerRowMemo.clear()
    spacerRowMemo[height] = text
  newMsoIf("mso", @[raw(text)])

proc notMsoOpen*(tagText: string): EmailNode =
  ## `<!--[if !mso]><!-->{tagText}<!--<![endif]-->`: the opening tag of
  ## an element every client but Word renders. Its closing tag comes in
  ## a second conditional (`notMsoClose`) after content both see. Used
  ## for a band's border: Word draws the border on the ghost cell, and
  ## renders `div` borders unreliably (caniemail css-border), so it
  ## must not see the div's.
  newNotMso(@[raw(tagText)])

proc notMsoClose*(tag: string): EmailNode =
  ## `<!--[if !mso]><!--></{tag}><!--<![endif]-->`.
  newNotMso(@[raw("</" & tag & ">")])

proc openTagText*(node: EmailNode): string =
  ## The start tag `node` serialises to (attributes, then its styles).
  let shell = EmailNode(kind: enElement, tag: node.tag, attrs: node.attrs,
    styles: node.styles, fallbacks: node.fallbacks)
  let html = serialize(shell)
  html[0 ..< html.len - ("</" & node.tag & ">").len]

proc hiddenFromWord*(node: EmailNode): seq[EmailNode] =
  ## `node`'s own tags hidden from Word, its children kept for everyone:
  ## `<!--[if !mso]><!-->{start tag}<!--<![endif]-->`, the children,
  ## `<!--[if !mso]><!--></{tag}><!--<![endif]-->`. For a box whose
  ## background Word must not paint (inside a background `v:rect`,
  ## R-VML-01), while the content stays Word's.
  result = @[notMsoOpen(openTagText(node))]
  for c in node.children:
    result.add(c)
  result.add(notMsoClose(node.tag))

type GhostColumn* = object
  ## One cell of a multi-column ghost row (R-LAY-07): the column's px
  ## width and its vertical alignment. Never padding: a cell's `width`
  ## does not include its padding in every engine, so the half-gutters
  ## and the column's own padding go on a single-cell table inside the
  ## cell (`msoBoxOpen`).
  width*: int
  valign*: string

proc columnCellTag(c: GhostColumn): string =
  var style = "width:" & $c.width & "px;"
  if c.valign.len > 0:
    style.add("vertical-align:" & c.valign & ";")
  tagText("td", [("valign", c.valign), ("width", $c.width),
    ("style", style)])

proc ghostRowOpen*(first: GhostColumn; rtl = false;
    background = ""): EmailNode =
  ## R-LAY-07: `<!--[if mso]><table role="presentation" border="0"
  ## cellpadding="0" cellspacing="0" width="100%"><tr><td valign
  ## width style="width;vertical-align"><![endif]-->` before the
  ## first column. The row fills its box (the cells carry the px
  ## widths); `dir="rtl"` runs the cells right to left (R-LAY-11), and a
  ## group's row paints the group's background.
  var attrs = @[("role", "presentation"), ("border", "0"),
    ("cellpadding", "0"), ("cellspacing", "0"), ("width", "100%")]
  if background.len > 0:
    attrs.add(("bgcolor", background))
  if rtl:
    attrs.add(("dir", "rtl"))
  newMsoIf("mso", @[raw(tagText("table", attrs) & "<tr>" &
    columnCellTag(first))])

proc ghostRowNext*(next: GhostColumn): EmailNode =
  ## `<!--[if mso]></td><td …><![endif]-->` between two columns.
  newMsoIf("mso", @[raw("</td>" & columnCellTag(next))])

proc msoBoxOpen*(cell: GhostCell): EmailNode =
  ## Padding or a box inside a ghost cell, for Word only: a single-cell
  ## 100% table whose cell carries the half-gutters and the column's
  ## padding, or the column's own box (padding, background, border).
  ## The row's cells themselves stay unpadded, so Word has no vertical
  ## padding to equalise across them (R-TBL-03) and a background never
  ## reaches into the gutter. Closed by `ghostTableClose`.
  let table = tagText("table", [("role", "presentation"),
    ("width", "100%"), ("border", "0"), ("cellpadding", "0"),
    ("cellspacing", "0")])
  newMsoIf("mso", @[raw(table & "<tr>" & cellTag(cell))])

proc ghostRowBreak*(next: GhostColumn): EmailNode =
  ## `<!--[if mso]></td></tr><tr><td …><![endif]-->`: the next row of a
  ## chunked ghost table. Word's tables never wrap, so a grid's ghost
  ## table is cut into rows of N cells (R-LAY-07).
  newMsoIf("mso", @[raw("</td></tr><tr>" & columnCellTag(next))])

proc ghostSpacerCell*(width: int): EmailNode =
  ## `<!--[if mso]></td><td width="{w}" aria-hidden="true" style="…">&nbsp;<![endif]-->`:
  ## a sized cell that stands for an item a grid's last row does not
  ## have, so the row keeps its cells' widths (R-TBL-05: explicit size,
  ## hidden, never empty). It is closed by whatever follows it.
  let td = tagText("td", [("width", $width), ("aria-hidden", "true"),
    ("style", "width:" & $width & "px;font-size:0;line-height:0;" &
      "mso-line-height-rule:exactly;")])
  newMsoIf("mso", @[raw("</td>" & td & "&nbsp;")])

proc ghostRowSwitch*(first: GhostColumn; centred: bool;
    rtl = false): EmailNode =
  ## `<!--[if mso]></td></tr></table><table …><tr><td …><![endif]-->`:
  ## closes a chunked ghost table and opens one of its own for a last
  ## row whose cells differ from the rows above (a centred or stretched
  ## grid row): centred by `align="center"`, or filling its box.
  var attrs = @[("role", "presentation")]
  if centred:
    attrs.add(("align", "center"))
  attrs.add([("border", "0"), ("cellpadding", "0"), ("cellspacing", "0")])
  if not centred:
    attrs.add(("width", "100%"))
  if rtl:
    attrs.add(("dir", "rtl"))
  newMsoIf("mso", @[raw("</td></tr></table>" & tagText("table", attrs) &
    "<tr>" & columnCellTag(first))])

proc ghostClusterOpen*(padding, align: string; rtl = false): EmailNode =
  ## A cluster's single-row ghost table (MJML `mj-social`, `mj-navbar`):
  ## `<!--[if mso]><table role="presentation" [align] border="0"
  ## cellpadding="0" cellspacing="0"><tr><td style="padding:{gap}"><![endif]-->`.
  ## The cells carry no width, only the gap; Word lays the items out on
  ## one line, which it never wraps.
  var attrs = @[("role", "presentation")]
  if align in ["center", "right"]:
    attrs.add(("align", align))
  attrs.add([("border", "0"), ("cellpadding", "0"), ("cellspacing", "0")])
  if rtl:
    attrs.add(("dir", "rtl"))
  newMsoIf("mso", @[raw(tagText("table", attrs) & "<tr>" &
    cellTag(GhostCell(padding: padding)))])

proc ghostClusterNext*(padding: string): EmailNode =
  ## `<!--[if mso]></td><td style="padding:{gap}"><![endif]-->`.
  newMsoIf("mso", @[raw("</td>" & cellTag(GhostCell(padding: padding)))])

proc msoSpace*(): EmailNode =
  ## `<!--[if mso]>&nbsp;&nbsp;&nbsp;<![endif]-->`: about 12px of space
  ## only Word sees, where everyone else gets padding Word ignores (the
  ## gap before a cluster's separator).
  newMsoIf("mso", @[raw("&nbsp;&nbsp;&nbsp;")])

proc msoZwnj*(): EmailNode =
  ## `<!--[if mso]>&zwnj;<![endif]-->` after the image of a cell that
  ## holds only an image beside a cell of text (R-TBL-07): with a text
  ## character in the cell, Word applies the cell's `valign` to the
  ## image. Only Word needs it; elsewhere a character after a block
  ## image would open a line of its own under it.
  newMsoIf("mso", @[raw("&zwnj;")])

proc ghostDivider*(width: int; border, align: string): EmailNode =
  ## A divider's line for Word (MJML `mj-divider`): `<!--[if mso]><table
  ## role="presentation" align="{align}" border="0" cellpadding="0"
  ## cellspacing="0" width="{w}" style="width:{w}px;border-top:{border};"><tr><td
  ## style="height:0;font-size:0;line-height:0;…">&nbsp;</td></tr></table><![endif]-->`.
  ## A table with a px width, because Word ignores a paragraph's width
  ## and draws its border across the whole cell.
  var attrs = @[("role", "presentation")]
  if align in ["center", "right"]:
    attrs.add(("align", align))
  attrs.add([("border", "0"), ("cellpadding", "0"), ("cellspacing", "0"),
    ("width", $width), ("style", "width:" & $width & "px;border-top:" &
      border & ";")])
  let td = tagText("td", [("aria-hidden", "true"), ("style",
    "height:0;font-size:0;line-height:0;mso-line-height-rule:exactly;")])
  newMsoIf("mso", @[raw(tagText("table", attrs) & "<tr>" & td &
    "&nbsp;</td></tr></table>")])
