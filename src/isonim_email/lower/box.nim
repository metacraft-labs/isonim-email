## isonim_email/lower/box.nim — `mailBox` lowering: padding, background,
## border.
##
## The one primitive that is a table by default (catalogue R-TBL-01;
## Blocks Edit, goodemailcode.com container): a single-cell table whose
## cell carries everything, so every client, Word included, honours the
## padding, background and border without a ghost table:
##
## ```html
## <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="border-collapse:{collapse|separate};">
##   <tr><td bgcolor="{bg}" style="padding:{pad};background-color:{bg};border:{border};border-radius:{r};box-shadow:{shadow};">…</td></tr>
## </table>
## ```
##
## - A radius needs `border-collapse:separate` on the table (R-TBL-16),
##   written `!important` because the reset collapses every table with
##   `!important`; Word draws it square. The cell sets `collapse` again,
##   so a table nested in it (a data table) does not inherit `separate`
##   where no head CSS collapses it.
## - The cell breaks long unbroken words (`word-break:break-word`,
##   R-TBL-17).
## - A shadow is decoration only: Gmail web, Word and Yahoo draw none,
##   and dark mode hides it. So a box with a shadow always has a border:
##   its own, or a 1px border one step darker than its background
##   (`darkerStep`, R-TBL-09), which marks the edge wherever the shadow
##   is missing.
## - `outlook_rounded` (the 3×3 table with VML corner arcs) is not
##   built: it ships only once a Word-engine capture shows it works
##   (R-TBL-16). Asking for it is `E-LOWER-MISSING`, never ignored.
##
## Pure tree building: identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/colors
import ../passes/layout
import ./section

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  boxShadows* = [("sm", "0 1px 3px rgba(0,0,0,0.12)"),
    ("md", "0 4px 12px rgba(0,0,0,0.16)")]
    ## `shadow = sm | md` as `box-shadow` values.
  boxShadowSurface* = "#ffffff"
    ## The surface a shadowed box without a background of its own is
    ## taken to sit on, for its border (the default theme's surface).
  boxConsumed = ["background-color", "background_color", "padding",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "border", "border-width", "border-style", "border-color",
    "border-radius", "border_radius", "box-shadow", "shadow",
    "outlook_rounded"]
    ## Declarations the box turns into its own markup.

proc shadowValue*(name: string): string =
  ## The `box-shadow` of `shadow = name`, "" for `none` (or unset).
  for (k, v) in boxShadows:
    if k == name:
      return v
  ""

proc shadowBorder*(background: string): string =
  ## R-TBL-09: the border a shadowed box gets when it has none of its
  ## own, 1px and one step darker than its background.
  let bg = if background.len > 0: background else: boxShadowSurface
  "1px solid " & darkerStep(bg)

proc lowerBox*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; inner: EmailNode;
      diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one laid-out `mailBox`: `nodes` replace it, `inner` (the
  ## cell) holds its content, lowered next.
  let r = EmailRenderer()
  let shadowName = rawValue(node, "shadow").toLowerAscii()
  if shadowName notin ["", "none", "sm", "md"]:
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailBox shadow '" & shadowName &
        "' is not none, sm or md", origin: node.origin,
      rules: @["R-TBL-09"]))
  if rawValue(node, "outlook_rounded").toLowerAscii() == "true":
    result.diagnostics.add(lowerMissing(node, "outlook_rounded (the " &
      "3×3 VML-corner box, shipped only once a Word-engine capture " &
      "shows it works)", "R-TBL-16"))
  let bg = colourOf(node, "background-color")
  let radius = radiusOf(node)
  var (border, uniform) = borderText(node)
  if not uniform:
    result.diagnostics.add(lowerMissing(node, "per-side border",
      "R-TBL-09"))
  let shadow = shadowValue(shadowName)
  if shadow.len > 0 and border.len == 0:
    border = shadowBorder(bg)
  let table = r.createElement("table")
  table.origin = node.origin
  for (k, v) in [("role", "presentation"), ("width", "100%"),
      ("border", "0"), ("cellpadding", "0"), ("cellspacing", "0")]:
    r.setAttribute(table, k, v)
  # The reset's `table{border-collapse:collapse !important}` would win
  # over a plain inline value, and a radius does not render on a
  # collapsed table (R-TBL-16): the inline value is `!important` too.
  r.setStyle(table, "border-collapse",
    if radius.len > 0: "separate !important" else: "collapse")
  let tr = r.createElement("tr")
  r.appendChild(table, tr)
  let td = r.createElement("td")
  td.origin = node.origin
  if bg.len > 0:
    r.setAttribute(td, "bgcolor", bg)
  let lb = node.layout
  if max(lb.padding) > 0:
    r.setStyle(td, "padding", boxText(lb.padding))
  if bg.len > 0:
    r.setStyle(td, "background-color", bg)
  if border.len > 0:
    r.setStyle(td, "border", border)
  if radius.len > 0:
    r.setStyle(td, "border-radius", radius)
    # `border-collapse` inherits: without head CSS (the reset collapses
    # every table) a table nested in the cell would take the box's
    # `separate` and space its cells apart. The cell hands its content
    # `collapse` back.
    r.setStyle(td, "border-collapse", "collapse")
  if shadow.len > 0:
    r.setStyle(td, "box-shadow", shadow)
  # A long unbroken word breaks inside the cell instead of overflowing
  # it (the reset fixes table layout; R-TBL-17).
  r.setStyle(td, "word-break", "break-word")
  r.setStyle(td, "overflow-wrap", "break-word")
  for k, v in node.styles.pairs:
    if k notin boxConsumed:
      r.setStyle(td, k, v)
  let align = rawValue(node, "text-align").toLowerAscii()
  if align in ["center", "right"]:
    r.setAttribute(td, "align", align) # R-TBL-14
  if "class" in node.attrs:
    r.setAttribute(td, "class", node.attrs["class"])
  let kids = node.children # Copy: appendChild detaches as it moves.
  for c in kids:
    r.appendChild(td, c)
  r.appendChild(tr, td)
  result.nodes = @[table]
  result.inner = td
