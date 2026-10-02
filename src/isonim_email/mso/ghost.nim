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

proc spacerRow*(height: int): EmailNode =
  ## The vertical gap Word sees between stacked children (R-TBL-04,
  ## R-TBL-05): a one-cell table whose sized cell is never empty, with
  ## exact line height so the gap is exactly `height` px.
  let table = tagText("table", [("role", "presentation"),
    ("width", "100%"), ("border", "0"), ("cellpadding", "0"),
    ("cellspacing", "0")])
  let td = tagText("td", [("height", $height), ("aria-hidden", "true"),
    ("style", "height:" & $height & "px;font-size:0;line-height:0;" &
      "mso-line-height-rule:exactly;")])
  newMsoIf("mso", @[raw(table & "<tr>" & td & "&nbsp;</td></tr></table>")])

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
