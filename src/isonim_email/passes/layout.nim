## isonim_email/passes/layout.nim — P3: the layout pass (width solver).
##
## Annotates every layout element of the authoring tree with the widths
## the lowerings need (`EmailNode.layout`, a `LayoutBox`): the width
## context it sits in, the px width it occupies (the width of its Outlook
## ghost table or ghost cell), and the px width its children get. Leaves
## are not annotated; they read the box of their nearest laid-out
## ancestor.
##
## The maths is MJML 5's (`mjml-section`, `mjml-column`, `mjml-group`,
## `mjml-wrapper` and `mjml-core`'s `getBoxWidths`), because Outlook's
## geometry is checked against MJML's output (`just test-conformance`):
##
## - the document's width context `W` is `mailDocument(width)` or the
##   target's `containerWidth`;
## - a section or wrapper occupies `W`; its box is
##   `W − padding-left − padding-right − border-left − border-right`
##   (catalogue §4.1), and a wrapper's box is the width context of the
##   sections inside it (R-LAY-17);
## - a column given in `%` occupies `round(B · pct / 100)` px of its
##   section's box `B`, one given in px occupies its px width, and one
##   with no width occupies `100 / n` % (n = the non-raw siblings).
##   Each column rounds on its own, as MJML does: the px widths may sum
##   to `B` ± 1 per column, never adjusted onto the last one;
## - a column's box (its children's context) is its exact width less
##   its padding and borders, truncated to whole px; a group's box keeps
##   its fraction (MJML passes the group's fractional width to its
##   columns), and a group's columns take their `%` of that;
## - lengths are whole px: padding and border widths truncate as
##   MJML's `parseInt` does.
##
## Rows: a section's own columns are a gutterless `hybrid` row (MJML's
## model, column padding `space.gutter`); a `mailColumns` lays out a row
## in the content box it sits in, with a `strategy` (`hybrid`,
## `fabFour`, `cellsStacking`, `cells`) and a gutter (`space.5`), its
## columns padded by nothing of their own unless they say so. With a
## gutter the maths is MJML 5's `mj-section gutter` (catalogue §4.1,
## R-LAY-14): each column's desktop class width loses its share of the
## gutters, `(n − 1) / n` of one gutter (a px row hands the rounding
## remainder to its first columns, one pixel each), and its desktop
## padding is half a gutter on each inner side (`ceil` leading, `floor`
## trailing, mirrored in a right-to-left row); the Outlook cell keeps
## the full width. Rows of cells (`cells`, `cellsStacking`) are checked
## at a 320px document (R-TBL-11, `W-LAYOUT-MIN-COLUMN`).
##
## A section holds either columns (`mailColumn`, `mailGroup`, plus raw
## content) or content. Content directly in a section is an implicit
## single column with the default column padding (`space.gutter`), so a
## section written with or without its one `mailColumn` lays out the
## same. A section that mixes columns and other content is
## `E-STRUCT-NESTING`.
##
## Defaults are the theme's: section padding `space.section`, column
## padding `space.gutter`, wrapper padding none. Values arrive as the
## authoring tree holds them (P3 runs before P5): template trees carry
## hyphenated CSS names (`background-color`), hand-built trees may carry
## the underscore spelling of the vocabulary (`background_color`), and
## `tok"…"` sentinels resolve through the theme here.
##
## Pure (no IO) and backend-independent.

import std/[math, strutils, tables]
import ../renderer
import ../diagnostics
import ../style/tokens
import ../style/units
import ../style/shorthand
import ../lower/table_style
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  sectionTags* = ["mailSection"]
  wrapperTags* = ["mailWrapper"]
  heroTags* = ["mailHero"]
    ## A band whose content is one cell (a height, a vertical alignment).
  columnTags* = ["mailColumn", "mailGroup"]
    ## The children that put a section in column mode.
  rowTags* = ["mailColumns"]
    ## The layout primitive that lays out a row of columns wherever
    ## content goes.
  rawTags = ["mailRaw"]
    ## Siblings MJML does not count (`nonRawSiblings`).
  sectionPaddingToken* = "space.section"
  columnPaddingToken* = "space.gutter"
  rowGutterToken* = "space.5"
    ## A `mailColumns` row's default gutter (24px).

proc tagOf(node: EmailNode): string =
  if node == nil or node.kind != enElement: "" else: node.tag

proc rawValue*(node: EmailNode; name: string): string =
  ## The authoring value of a layout prop: the style under its CSS
  ## (hyphenated) name, then under the vocabulary's underscore spelling,
  ## then a plain attribute under either. "" when absent.
  let hy = name.replace("_", "-")
  let us = name.replace("-", "_")
  for key in [hy, us]:
    if key in node.styles:
      return node.styles[key].strip()
  for key in [us, hy]:
    if key in node.attrs:
      return node.attrs[key].strip()
  ""

proc resolveTok(value: string; theme: EmailTheme): string =
  ## `tok:<key>` (the `tok"…"` sentinel) → the theme's light literal.
  if value.startsWith("tok:"):
    theme.lightFor(value[4 .. ^1])
  else:
    value

proc truncPx(value: string): int =
  ## A normalised px length (`"24px"`, `"0"`) → whole px, truncated as
  ## MJML's `parseInt` does.
  int(trunc(toPx(value)))

proc boxOf(value: string; theme: EmailTheme): array[4, int] =
  ## A `Box` (1-4 lengths, or a token) → whole px per side.
  let sides = expandBox(resolveTok(value, theme))
  for i in 0 .. 3:
    result[i] = truncPx(sides[i])

proc borderOf(node: EmailNode; theme: EmailTheme): array[4, int] =
  ## The border width per side. `border` sets all four; a side's own
  ## `border-<side>` (hand-built trees) replaces it.
  let all = rawValue(node, "border")
  if all.len > 0 and all.toLowerAscii() notin ["none", "0"]:
    let w = int(trunc(parseBorder(resolveTok(all, theme)).widthPx))
    result = [w, w, w, w]
  const sides = ["border-top", "border-right", "border-bottom",
    "border-left"]
  for i, side in sides:
    let v = rawValue(node, side)
    if v.len > 0:
      if v.toLowerAscii() in ["none", "0"]:
        result[i] = 0
      else:
        result[i] = int(trunc(parseBorder(resolveTok(v, theme)).widthPx))

proc paddingOf(node: EmailNode; theme: EmailTheme;
    defaultToken: string): array[4, int] =
  ## The element's padding: its own `padding` (then side longhands), or
  ## the theme default (`defaultToken`, "" for none).
  let given = rawValue(node, "padding")
  if given.len > 0:
    result = boxOf(given, theme)
  elif defaultToken.len > 0:
    result = boxOf("tok:" & defaultToken, theme)
  const sides = ["padding-top", "padding-right", "padding-bottom",
    "padding-left"]
  for i, side in sides:
    let v = rawValue(node, side)
    if v.len > 0:
      result[i] = truncPx(normaliseLength(side, resolveTok(v, theme)))

proc normalisePercent*(pct: float): float =
  ## A percentage to at most 6 decimals (catalogue §4.1, R-LAY-03).
  round(pct * 1_000_000.0) / 1_000_000.0

proc percentText*(pct: float): string =
  ## The canonical spelling of a normalised percentage: up to 6
  ## decimals, trailing zeros stripped (`33.333333`, `50`).
  let p = normalisePercent(pct)
  if p == trunc(p):
    return $int(p)
  result = formatFloat(p, ffDecimal, 6)
  result = result.strip(leading = false, trailing = true, chars = {'0'})

proc columnClassName*(pct: float; px: int; pxWidth: bool): string =
  ## R-LAY-03: `e-col-{pct}` with `.` → `-`, or `e-colpx-{n}`.
  if pxWidth:
    "e-colpx-" & $px
  else:
    "e-col-" & percentText(pct).replace(".", "-")

type WidthSpec = object
  given: bool
  pxWidth: bool
  value: float  ## px, or percent

proc widthSpec(node: EmailNode; theme: EmailTheme): WidthSpec =
  ## The element's own `width`: `%` keeps its full precision (MJML's
  ## `parseFloat`), px truncates to whole px (its `parseInt`).
  let w = resolveTok(rawValue(node, "width"), theme)
  if w.len == 0:
    return WidthSpec(given: false)
  if w.endsWith("%"):
    let num = w[0 ..< ^1].strip()
    try:
      return WidthSpec(given: true, pxWidth: false, value: parseFloat(num))
    except ValueError:
      raise newException(StyleError,
        "E-VOCAB-BAD-VALUE: '" & w & "' is not a width")
  WidthSpec(given: true, pxWidth: true, value: float(truncPx(w)))

proc layoutDiag(node: EmailNode; code, message: string;
    rules: seq[string] = @[]): EmailDiagnostic =
  EmailDiagnostic(severity: sevError, code: code, message: message,
    origin: node.origin, rules: rules)

proc nonRawCount(children: seq[EmailNode]): int =
  for c in children:
    if c.kind == enElement and c.tag notin rawTags:
      inc result

proc isColumn(node: EmailNode): bool =
  tagOf(node) in columnTags

type Solve = object
  ## What every step of the solver reads: the theme, the document's
  ## width (the 320px check scales from it) and its direction.
  theme: EmailTheme
  docWidth: int
  dir: string

proc solveNode(node: EmailNode; context: float; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic])

proc normalise6(v: float): float =
  ## MJML's `normalizeUnitValue`: six decimals.
  round(v * 1_000_000.0) / 1_000_000.0

proc unitText(v: float; unit: string): string =
  ## A normalised value with its unit; zero is written bare.
  let p = normalise6(v)
  if p == 0.0: "0" else: percentText(p) & unit

proc gutterClassName*(n, index: int; percentUnit: bool; gutterPx: int;
    gutterPercent: float; rtl: bool): string =
  ## The desktop gutter class of the `index`th (0-based) of `n` columns
  ## (catalogue R-LAY-14, MJML's `mj-column-gutter-…`):
  ## `e-gutter-{n}-{i}-{per|px}-{gutter}`, `.` → `-`, `-rtl` when the
  ## row runs right to left.
  let unitTok = if percentUnit: "per" else: "px"
  let g = if percentUnit: percentText(normalise6(gutterPercent))
    else: $gutterPx
  "e-gutter-" & $n & "-" & $(index + 1) & "-" & unitTok & "-" &
    g.replace(".", "-") & (if rtl: "-rtl" else: "")

proc applyGutter(lb: var LayoutBox; gutter, index, n: int; rtl: bool;
    rowBox: float) =
  ## MJML 5's gutter for one column of a row (`mjml-column`
  ## `getDesktopWidth`, `getDesktopPaddingValues`): the desktop class
  ## width loses the column's share of the gutters, `(n − 1) / n` of one
  ## gutter, and the desktop padding is half a gutter on each inner side
  ## (`ceil` on the leading side, `floor` on the trailing one), none on
  ## the row's outer edges. A px row distributes the rounding remainder
  ## over its first columns. The Outlook cell keeps the full width and
  ## takes the half-gutters as padding.
  lb.index = index
  lb.siblings = n
  lb.deskPercent = lb.percent
  lb.deskPx = lb.outer
  lb.gutter = [0, 0, 0, 0]
  lb.gutterClass = ""
  lb.gutterCss = ""
  if gutter <= 0 or n <= 1:
    return
  let first = index == 0
  let last = index == n - 1
  let lead = (gutter + 1) div 2
  let trail = gutter div 2
  if rtl:
    lb.gutter = [0, (if first: 0 else: trail), 0, (if last: 0 else: lead)]
  else:
    lb.gutter = [0, (if last: 0 else: lead), 0, (if first: 0 else: trail)]
  let gp = if rowBox > 0: float(gutter) / rowBox * 100.0 else: 0.0
  if lb.pxWidth:
    let reduction = float(gutter) * float(n - 1) / float(n)
    let reduced = max(0.0, normalise6(float(lb.outer) - reduction))
    let fl = floor(reduced)
    let extra = max(0, min(n, int(round(float(n) * (reduced - fl)))))
    lb.deskPx = int(fl) + (if index < extra: 1 else: 0)
    lb.gutterCss = "0 " & (if lb.gutter[1] == 0: "0" else: $lb.gutter[1] &
      "px") & " 0 " & (if lb.gutter[3] == 0: "0" else: $lb.gutter[3] & "px")
  else:
    let reduction = gp * float(n - 1) / float(n)
    lb.deskPercent = max(0.0, normalise6(lb.percent - reduction))
    let half = gp / 2.0
    let right = if lb.gutter[1] == 0: 0.0 else: half
    let left = if lb.gutter[3] == 0: 0.0 else: half
    lb.gutterCss = "0 " & unitText(right, "%") & " 0 " & unitText(left, "%")
  lb.gutterClass = gutterClassName(n, index, not lb.pxWidth, gutter, gp, rtl)

proc solveColumn(col: EmailNode; parentBox: float; siblings: int;
    inGroup: bool; padToken: string; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic]) =
  ## One `mailColumn` or `mailGroup` in a box of `parentBox` px; its
  ## padding defaults to `padToken` ("" for none).
  var spec: WidthSpec
  try:
    spec = widthSpec(col, s.theme)
  except StyleError as e:
    diags.add(layoutDiag(col, codeVocabBadValue, e.msg, @["R-LAY-01"]))
  let n = max(siblings, 1)
  let isGroup = tagOf(col) == "mailGroup"
  var lb = LayoutBox(solved: true, container: int(trunc(parentBox)))
  var exact: float
  if spec.given and spec.pxWidth:
    lb.pxWidth = true
    exact = spec.value
    lb.percent = 0.0
  else:
    let pct = if spec.given: spec.value else: 100.0 / float(n)
    lb.percent = pct
    exact = parentBox * pct / 100.0
  lb.outer = int(round(exact))
  try:
    lb.padding =
      if isGroup: paddingOf(col, s.theme, "")
      else: paddingOf(col, s.theme, padToken)
    lb.border = if isGroup: [0, 0, 0, 0] else: borderOf(col, s.theme)
  except StyleError, ThemeError:
    diags.add(layoutDiag(col, codeVocabBadValue,
      getCurrentExceptionMsg(), @["R-LAY-01"]))
  let inner = exact - float(lb.padding[1] + lb.padding[3] +
    lb.border[1] + lb.border[3])
  lb.boxExact = inner
  lb.box = int(trunc(inner))
  lb.className = columnClassName(lb.percent, lb.outer, lb.pxWidth)
  lb.deskPercent = lb.percent
  lb.deskPx = lb.outer
  lb.rtl = rtl
  col.layout = lb
  if isGroup:
    let kids = col.children
    let m = nonRawCount(kids)
    var i = 0
    for c in kids:
      if isColumn(c):
        solveColumn(c, inner, m, true, padToken, s, rtl, diags)
        c.layout.index = i
        c.layout.siblings = m
        c.layout.strategy = "hybrid"
        inc i
      elif c.kind == enElement and c.tag notin rawTags:
        diags.add(layoutDiag(c, codeStructNesting,
          "<" & c.tag & "> inside mailGroup: a group holds mailColumn " &
          "children only (R-LAY-16)", @["R-LAY-16"]))
  # A column's children are solved once its row has placed it (the
  # gutter narrows its box): see `solveRow`.

proc hasText(node: EmailNode): bool =
  ## True when `node` or a descendant holds non-blank text.
  if node.kind == enText:
    return node.text.strip().len > 0
  for c in node.children:
    if hasText(c):
      return true
  false

proc columnMinimum(col, row: EmailNode; s: Solve): float =
  ## The narrowest content box a cell may have at 320px (R-TBL-11): the
  ## column's `min_width`, else the row's `min_column`, else 160px for a
  ## column with text and 120px for one without (images, decoration).
  for (node, prop) in [(col, "min-width"), (row, "min_column")]:
    let v = resolveTok(rawValue(node, prop), s.theme)
    if v.len > 0:
      try:
        return float(truncPx(v))
      except StyleError:
        discard
  if hasText(col): 160.0 else: 120.0

proc gridItemWidths*(box, columns, gutter, count: int;
    lastRow: string): seq[int]

proc narrowBox(node: EmailNode; s: Solve): float =
  ## The width `node` (a laid-out row or box) has at a 320px document.
  ## Paddings and borders stay fixed while the document narrows, so a
  ## box shrinks by exactly what the document loses, unless it sits in
  ## something that stacks on a phone: a column of a stacking row, or
  ## an item of a one-up mobile grid, is then the full width of its own
  ## row (its gutter goes to the top), and the box inside it is that
  ## less what lies between them on the desktop.
  let own = node.layout.boxExact
  var n = node.parent
  while n != nil:
    if n.kind == enElement and n.parent != nil:
      let p = n.parent
      if n.tag in columnTags and n.layout.solved and n.layout.stacks and
          p.layout.solved:
        let desk = float(n.layout.outer - n.layout.gutter[1] -
          n.layout.gutter[3])
        return max(0.0, narrowBox(p, s) - (desk - own))
      if p.kind == enElement and p.tag == "mailGrid" and not p.expanded and
          p.layout.solved:
        var idx = 0
        for c in p.children:
          if c == n:
            break
          if c.kind == enElement:
            inc idx
        let widths = gridItemWidths(p.layout.box, p.layout.columns,
          p.layout.gutterPx, p.layout.items, p.layout.lastRow)
        let desk = if idx < widths.len: float(widths[idx]) else: own
        return max(0.0, narrowBox(p, s) - (desk - own))
    n = n.parent
  max(0.0, own - float(s.docWidth - 320))

proc checkMinColumns(row: EmailNode; cols: seq[EmailNode]; s: Solve;
    diags: var seq[EmailDiagnostic]) =
  ## R-TBL-11: a cell row shows its desktop layout whenever CSS is lost
  ## (`cellsStacking`) or always (`cells`), so each cell's content box
  ## at a 320px document must reach its minimum (`narrowBox` gives the
  ## row's box there).
  let box320 = narrowBox(row, s)
  for c in cols:
    let lb = c.layout
    # The cell's desktop share (the gutter is a cell of its own).
    let w320 = if lb.pxWidth: float(lb.deskPx)
      else: box320 * lb.deskPercent / 100.0
    let content = w320 - float(lb.padding[1] + lb.padding[3] +
      lb.border[1] + lb.border[3])
    let minimum = columnMinimum(c, row, s)
    if content < minimum:
      diags.add(EmailDiagnostic(severity: sevWarning,
        code: codeLayoutMinColumn,
        message: "column " & $(lb.index + 1) & " of a " & lb.strategy &
          " row is " & formatFloat(content, ffDecimal, 1) &
          "px wide at a 320px document, below its " & $int(minimum) &
          "px minimum: a cell row " &
          (if lb.strategy == "cells": "never stacks"
           else: "keeps its desktop layout without CSS") & " (R-TBL-11)",
        origin: c.origin, rules: @["R-TBL-11"]))

proc solveRow(row: EmailNode; box: float; padToken: string; s: Solve;
    diags: var seq[EmailDiagnostic]) =
  ## The columns of a row (a section's own columns, or a `mailColumns`)
  ## in a box of `box` px: widths (MJML's maths), then the row's gutter,
  ## then each column's content.
  let lb = row.layout
  let kids = row.children
  let n = nonRawCount(kids)
  var cols: seq[EmailNode] = @[]
  for c in kids:
    if isColumn(c):
      if tagOf(c) == "mailGroup" and tagOf(row) == "mailColumns":
        diags.add(layoutDiag(c, codeStructNesting,
          "mailGroup inside mailColumns: a group belongs in a section " &
          "(R-LAY-16)", @["R-LAY-16"]))
      solveColumn(c, box, n, false, padToken, s, lb.rtl, diags)
      cols.add(c)
    elif c.kind == enElement and c.tag notin rawTags:
      if tagOf(row) == "mailColumns":
        diags.add(layoutDiag(c, codeStructNesting,
          "<" & c.tag & "> inside mailColumns: a row holds mailColumn " &
          "children only (R-LAY-16)", @["R-LAY-16"]))
  var i = 0
  for c in cols:
    var cl = c.layout
    cl.strategy = lb.strategy
    cl.reversed = lb.reversed
    cl.stacks = lb.stacks
    applyGutter(cl, lb.gutterPx, i, n, lb.rtl, box)
    if lb.strategy in ["fabFour", "cellsStacking", "cells"]:
      # No desktop media query: these rows set their widths inline.
      cl.className = ""
      cl.gutterClass = ""
      cl.gutterCss = ""
    else:
      cl.className = columnClassName(cl.deskPercent, cl.deskPx, cl.pxWidth)
    if cl.stacks and lb.gutterPx > 0 and i > 0 and
        lb.strategy != "cells":
      cl.mobileGap = lb.gutterPx
    let inner = cl.boxExact - float(cl.gutter[1] + cl.gutter[3])
    cl.boxExact = inner
    cl.box = int(trunc(inner))
    c.layout = cl
    inc i
  for c in cols:
    if tagOf(c) == "mailGroup":
      for gc in c.children:
        if isColumn(gc):
          for x in gc.children:
            solveNode(x, float(gc.layout.box), s, lb.rtl, diags)
    else:
      for x in c.children:
        solveNode(x, float(c.layout.box), s, lb.rtl, diags)
  if lb.strategy in ["cells", "cellsStacking"]:
    checkMinColumns(row, cols, s, diags)

proc rowDirection(node: EmailNode; s: Solve; inherited: bool): bool =
  ## True when the row's own content runs right to left: its `direction`,
  ## else the enclosing one.
  let own = rawValue(node, "direction").toLowerAscii()
  if own == "rtl": true
  elif own == "ltr": false
  else: inherited

proc isTrue(node: EmailNode; name: string): bool =
  rawValue(node, name).toLowerAscii() == "true"

proc solveBand(node: EmailNode; context: float; s: Solve; rtl: bool;
    defaultPadding: string; diags: var seq[EmailDiagnostic]) =
  ## A section or wrapper: occupies the context, boxes it in by its
  ## padding and borders.
  let w = int(trunc(context))
  var lb = LayoutBox(solved: true, container: w, outer: w)
  try:
    lb.padding = paddingOf(node, s.theme, defaultPadding)
    lb.border = borderOf(node, s.theme)
  except StyleError, ThemeError:
    diags.add(layoutDiag(node, codeVocabBadValue,
      getCurrentExceptionMsg(), @["R-LAY-08"]))
  lb.box = w - lb.padding[1] - lb.padding[3] - lb.border[1] - lb.border[3]
  lb.boxExact = float(lb.box)
  let dirRtl = rowDirection(node, s, rtl)
  lb.rtl = dirRtl
  node.layout = lb
  let kids = node.children
  if tagOf(node) in wrapperTags:
    for c in kids:
      solveNode(c, float(lb.box), s, dirRtl, diags)
    return
  var columns, content = 0
  for c in kids:
    if isColumn(c):
      inc columns
    elif c.kind == enElement and c.tag notin rawTags:
      inc content
    elif c.kind == enText and c.text.strip().len > 0:
      inc content
  if columns > 0 and tagOf(node) in heroTags:
    diags.add(layoutDiag(node, codeStructNesting,
      "mailHero holds content, not columns: put the columns in a " &
      "mailColumns row inside it (R-LAY-16)", @["R-LAY-16"]))
    columns = 0
  if columns > 0 and content > 0:
    diags.add(layoutDiag(node, codeStructNesting,
      "mailSection mixes columns with other content: a section holds " &
      "either mailColumn/mailGroup children or content (an implicit " &
      "single column) (R-LAY-16)", @["R-LAY-16"]))
  if columns > 0:
    # A section's own columns are a hybrid row without a gutter, MJML's
    # model; `stack = never` keeps them side by side like a group's.
    var row = node.layout
    row.strategy = "hybrid"
    row.gutterPx = 0
    row.reversed = isTrue(node, "reverse_on_mobile")
    row.rtl = dirRtl or row.reversed
    row.stacks = rawValue(node, "stack").toLowerAscii() != "never"
    node.layout = row
    solveRow(node, float(lb.box), columnPaddingToken, s, diags)
  else:
    # The implicit single column: content sits in a box narrowed by the
    # default column padding.
    var colPad: array[4, int]
    try:
      colPad = boxOf("tok:" & columnPaddingToken, s.theme)
    except StyleError, ThemeError:
      diags.add(layoutDiag(node, codeVocabBadValue,
        getCurrentExceptionMsg(), @["R-LAY-08"]))
    let inner = lb.box - colPad[1] - colPad[3]
    for c in kids:
      solveNode(c, float(inner), s, dirRtl, diags)

const strategies* = ["hybrid", "fabFour", "cellsStacking", "cells"]
  ## `mailColumns(strategy)`, in the order the strategy table lists them.

proc solveColumns(node: EmailNode; context: float; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic]) =
  ## A `mailColumns` row: as wide as the content box it sits in, its
  ## columns spaced by its gutter (`space.5` by default) and padded by
  ## nothing of their own unless they say so.
  var lb = LayoutBox(solved: true, container: int(trunc(context)),
    outer: int(trunc(context)), box: int(trunc(context)),
    boxExact: context)
  var strategy = rawValue(node, "strategy")
  if strategy.len == 0:
    strategy = "hybrid"
  if strategy notin strategies:
    diags.add(layoutDiag(node, codeVocabBadValue,
      "mailColumns strategy '" & strategy & "' is not one of " &
      strategies.join(", "), @["R-LAY-01"]))
    strategy = "hybrid"
  lb.strategy = strategy
  var g = rawValue(node, "gutter")
  if g.len == 0:
    g = "tok:" & rowGutterToken
  try:
    let gv = resolveTok(g, s.theme)
    if gv.strip().endsWith("%"):
      raise newException(StyleError, "E-VOCAB-BAD-VALUE: mailColumns " &
        "gutter '" & gv & "' must be a px length")
    lb.gutterPx = max(0, truncPx(gv))
  except StyleError, ThemeError:
    diags.add(layoutDiag(node, codeVocabBadValue,
      getCurrentExceptionMsg(), @["R-LAY-14"]))
  lb.reversed = isTrue(node, "reverse_on_mobile")
  lb.rtl = rowDirection(node, s, rtl) or lb.reversed
  lb.stacks = strategy != "cells"
  node.layout = lb
  solveRow(node, context, "", s, diags)

# --- Layout primitives (catalogue §4b; layout-patterns.md §3.2-§3.6) ----------

const
  boxPaddingToken* = "space.5"
    ## `mailBox(padding)` default (24px).
  gridGutterToken* = "space.5"
    ## `mailGrid(gutter)` default (24px, as `mailColumns`).
  clusterGapToken* = "space.3"
    ## `mailCluster(gap)` default (12px).
  sidebarGapToken* = "space.4"
    ## `mailSidebar(gap)` default (16px).
  gridLastRows* = ["left", "center", "stretch"]

proc itemsOf*(node: EmailNode): seq[EmailNode] =
  ## The items of a grid or a cluster, or the sides of a sidebar: every
  ## element child and every non-blank text child, in order.
  for c in node.children:
    if c.kind == enElement or
        (c.kind == enText and c.text.strip().len > 0) or c.kind == enRaw:
      result.add(c)

proc lengthProp(node: EmailNode; name, defaultToken: string; s: Solve;
    diags: var seq[EmailDiagnostic]; rule: string): int =
  ## A px length prop (whole px), or the theme default; a `%` or a bad
  ## value is `E-VOCAB-BAD-VALUE` (and the default is used).
  var v = rawValue(node, name)
  if v.len == 0:
    if defaultToken.len == 0:
      return 0
    v = "tok:" & defaultToken
  try:
    let r = resolveTok(v, s.theme).strip()
    if r.endsWith("%"):
      raise newException(StyleError, "E-VOCAB-BAD-VALUE: " & node.tag &
        " " & name & " '" & r & "' must be a px length")
    result = truncPx(r)
    if result < 0:
      raise newException(StyleError, "E-VOCAB-BAD-VALUE: " & node.tag &
        " " & name & " '" & r & "' is negative")
  except StyleError, ThemeError, ValueError:
    let msg = getCurrentExceptionMsg()
    diags.add(layoutDiag(node, codeVocabBadValue,
      (if msg.startsWith("E-VOCAB-BAD-VALUE: "): msg[19 .. ^1] else: msg),
      @[rule]))
    if defaultToken.len > 0:
      try:
        result = max(0, truncPx(resolveTok("tok:" & defaultToken, s.theme)))
      except StyleError, ThemeError:
        result = 0
    else:
      result = 0

proc solveBox(node: EmailNode; context: float; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic]) =
  ## `mailBox`: a single-cell table as wide as its context, its content
  ## boxed in by its padding (`space.5` by default) and border.
  let w = int(trunc(context))
  var lb = LayoutBox(solved: true, container: w, outer: w)
  try:
    lb.padding = paddingOf(node, s.theme, boxPaddingToken)
    lb.border = borderOf(node, s.theme)
  except StyleError, ThemeError:
    diags.add(layoutDiag(node, codeVocabBadValue,
      getCurrentExceptionMsg(), @["R-TBL-09"]))
  lb.boxExact = context - float(lb.padding[1] + lb.padding[3] +
    lb.border[1] + lb.border[3])
  lb.box = int(trunc(lb.boxExact))
  lb.rtl = rtl
  node.layout = lb
  for c in node.children:
    solveNode(c, lb.boxExact, s, rtl, diags)

proc gridItemWidths*(box, columns, gutter, count: int;
    lastRow: string): seq[int] =
  ## The px width of each of `count` grid items in a `box`-px row of
  ## `columns` with `gutter` px between items: `(B − (N−1)·g)/N`, whole
  ## px, the remainder to the first items of each row, one each (as a px
  ## row of `mailColumns` hands it out). With `lastRow = stretch` the
  ## items of an incomplete last row share its whole width instead.
  let n = max(columns, 1)
  proc share(width, k: int): seq[int] =
    let free = max(0, width - (k - 1) * gutter)
    let base = free div k
    let extra = free - base * k
    for i in 0 ..< k:
      result.add(base + (if i < extra: 1 else: 0))
  let full = share(box, n)
  let rest = count mod n
  for i in 0 ..< count:
    if lastRow == "stretch" and rest > 0 and i >= count - rest:
      result.add(share(box, rest)[i - (count - rest)])
    else:
      result.add(full[i mod n])

proc solveGrid(node: EmailNode; context: float; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic]) =
  ## `mailGrid`: N items per desktop row, as wide as the content box it
  ## sits in, `gutter` px between items and between rows.
  let w = int(trunc(context))
  var lb = LayoutBox(solved: true, container: w, outer: w, box: w,
    boxExact: context, rtl: rowDirection(node, s, rtl), strategy: "grid")
  var n = 2
  let given = rawValue(node, "columns")
  if given.len > 0:
    try:
      n = parseInt(given)
    except ValueError:
      n = 0
  # P1 reports a count outside 2..4; the solver lays out the nearest.
  n = clamp(n, 2, 4)
  lb.columns = n
  lb.gutterPx = lengthProp(node, "gutter", gridGutterToken, s, diags,
    "R-TBL-04")
  var lastRow = rawValue(node, "last_row").toLowerAscii()
  if lastRow.len == 0:
    lastRow = "left"
  if lastRow notin gridLastRows:
    diags.add(layoutDiag(node, codeVocabBadValue, "mailGrid last_row '" &
      lastRow & "' is not " & gridLastRows.join(", ")))
    lastRow = "left"
  lb.lastRow = lastRow
  let items = itemsOf(node)
  lb.items = items.len
  lb.siblings = n
  node.layout = lb
  let widths = gridItemWidths(w, n, lb.gutterPx, items.len, lastRow)
  for i, c in items:
    solveNode(c, float(widths[i]), s, lb.rtl, diags)

proc solveCluster(node: EmailNode; context: float; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic]) =
  ## `mailCluster`: inline items in the content box it sits in, `gap`
  ## px apart (`space.3`), `row_gap` between wrapped lines (the gap).
  let w = int(trunc(context))
  var lb = LayoutBox(solved: true, container: w, outer: w, box: w,
    boxExact: context, rtl: rowDirection(node, s, rtl), strategy: "cluster")
  lb.gutterPx = lengthProp(node, "gap", clusterGapToken, s, diags,
    "R-TBL-04")
  let rowGap = rawValue(node, "row_gap")
  lb.mobileGap = if rowGap.len == 0: lb.gutterPx
    else: lengthProp(node, "row_gap", clusterGapToken, s, diags, "R-TBL-04")
  let items = itemsOf(node)
  lb.items = items.len
  node.layout = lb
  for c in items:
    solveNode(c, context, s, lb.rtl, diags)

proc solveSidebar(node: EmailNode; context: float; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic]) =
  ## `mailSidebar`: two sides, one `fixed` px wide (the first with
  ## `side = left`, the second with `side = right`), the other taking
  ## the rest less the `gap` (`space.4`).
  let w = int(trunc(context))
  var lb = LayoutBox(solved: true, container: w, outer: w, box: w,
    boxExact: context, rtl: rowDirection(node, s, rtl), strategy: "sidebar")
  let side = rawValue(node, "side").toLowerAscii()
  if side notin ["", "left", "right"]:
    diags.add(layoutDiag(node, codeVocabBadValue, "mailSidebar side '" &
      side & "' is not left or right"))
  lb.fixedIndex = if side == "right": 1 else: 0
  if rawValue(node, "fixed").len == 0:
    diags.add(layoutDiag(node, codeVocabBadValue, "mailSidebar needs " &
      "fixed, the px width of its fixed side (layout-patterns.md §3.6)"))
  lb.fixedPx = lengthProp(node, "fixed", "", s, diags, "R-TBL-07")
  lb.gutterPx = lengthProp(node, "gap", sidebarGapToken, s, diags,
    "R-TBL-04")
  lb.switchPx = lengthProp(node, "switch_below", "", s, diags, "R-TBL-07")
  lb.reversed = isTrue(node, "reverse_on_mobile")
  lb.stacks = lb.switchPx > 0
  let sides = itemsOf(node)
  if sides.len != 2:
    diags.add(layoutDiag(node, codeStructNesting, "mailSidebar holds " &
      $sides.len & " children: it lays out exactly two, a fixed side " &
      "and a fluid one (layout-patterns.md §3.6)", @["R-LAY-16"]))
  let fluid = w - lb.fixedPx - lb.gutterPx
  if lb.fixedPx > 0 and fluid <= 0:
    diags.add(layoutDiag(node, codeVocabBadValue, "mailSidebar fixed " &
      $lb.fixedPx & "px plus gap " & $lb.gutterPx & "px leaves nothing " &
      "of its " & $w & "px box for the fluid side"))
  node.layout = lb
  for i, c in sides:
    let box = if i == lb.fixedIndex: lb.fixedPx else: max(0, fluid)
    solveNode(c, float(box), s, lb.rtl, diags)
  if not lb.stacks and sides.len == 2 and fluid > 0:
    # R-TBL-11: a sidebar that never switches keeps both sides on one
    # line at every width, so its fluid side is checked at 320px.
    let fluidSide = sides[1 - lb.fixedIndex]
    let content = narrowBox(node, s) - float(lb.fixedPx + lb.gutterPx)
    var minimum = if hasText(fluidSide): 160.0 else: 120.0
    # A side that declares its own minimum (a cluster of short links
    # that wraps) is held to it, as a column's `min_width` is.
    let own = rawValue(fluidSide, "min_width")
    if own.len > 0:
      try:
        minimum = float(truncPx(resolveTok(own, s.theme)))
      except StyleError:
        diags.add(layoutDiag(fluidSide, codeVocabBadValue, "min_width '" &
          own & "' is not a px length"))
    if content < minimum:
      diags.add(EmailDiagnostic(severity: sevWarning,
        code: codeLayoutMinColumn,
        message: "the fluid side of a mailSidebar that never switches is " &
          formatFloat(content, ffDecimal, 1) & "px wide at a 320px " &
          "document, below its " & $int(minimum) & "px minimum: give it " &
          "switch_below, or a narrower fixed side (R-TBL-11)",
        origin: node.origin, rules: @["R-TBL-11"]))

proc solveNode(node: EmailNode; context: float; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic]) =
  if node == nil or node.kind != enElement:
    return
  let tag = node.tag
  if tag == "mailBox":
    solveBox(node, context, s, rtl, diags)
  elif tag == "mailGrid" and not node.expanded:
    solveGrid(node, context, s, rtl, diags)
  elif tag == "mailCluster":
    solveCluster(node, context, s, rtl, diags)
  elif tag == "mailSidebar":
    solveSidebar(node, context, s, rtl, diags)
  elif tag in sectionTags or tag in heroTags:
    solveBand(node, context, s, rtl, sectionPaddingToken, diags)
  elif tag in wrapperTags:
    solveBand(node, context, s, rtl, "", diags)
  elif tag in rowTags:
    solveColumns(node, context, s, rtl, diags)
  elif tag == "mailTable":
    # A data table takes the box it sits in; its mobile mode and column
    # count ride along for the head rules (R-TBL-18).
    let w = int(trunc(context))
    node.layout = LayoutBox(solved: true, container: w, outer: w, box: w,
      boxExact: context, strategy: tableMode(node),
      columns: columnCount(tableOf(node)))
    # What a stacking table's desktop rules give back to its inner
    # cells: their bottom border's width and bottom padding.
    try:
      let b = tableBorder(node)
      node.layout.className = if b.none: "" else: b.width
    except StyleError:
      node.layout.className = ""
    node.layout.gutterCss = resolveTok("tok:space.2", s.theme)
    for c in node.children:
      solveNode(c, context, s, rtl, diags)
  elif tag in columnTags:
    # A column outside a section (P1/F1 report the nesting): solved as
    # a lone column of the context, so its children still get a box.
    solveColumn(node, context, 1, false, columnPaddingToken, s, rtl, diags)
    for c in node.children:
      solveNode(c, float(node.layout.box), s, rtl, diags)
  else:
    if tag in ["mailImage", "mailDivider", "mailSpacer", "mailText",
        "mailButton"]:
      # Content leaves keep the width they sit in (not `solved`: they
      # lay out nothing of their own): a fluid image's, a divider's and
      # a full-width VML button's Word width.
      node.layout.container = int(context)
      node.layout.inlineItem = node.parent != nil and
        node.parent.kind == enElement and node.parent.tag == "mailCluster"
    for c in node.children:
      solveNode(c, context, s, rtl, diags)

proc documentWidth*(doc: EmailNode; target: EmailTarget;
    theme: EmailTheme): int =
  ## The document's width context `W`: `mailDocument(width)` in px, or
  ## `target.containerWidth`.
  if doc != nil and doc.kind == enElement:
    let w = resolveTok(rawValue(doc, "width"), theme)
    if w.len > 0 and not w.endsWith("%"):
      try:
        return truncPx(w)
      except StyleError:
        discard
  target.containerWidth

proc solveLayout*(root: EmailNode; theme: EmailTheme;
    target: EmailTarget): seq[EmailDiagnostic] =
  ## P3 over one authoring tree (`root` is the `mailDocument`, or any
  ## subtree laid out in the target's container width). Annotates the
  ## layout elements in place and returns the diagnostics in tree order.
  ## Idempotent: solving twice yields the same annotations.
  if root == nil:
    return
  let w = documentWidth(root, target, theme)
  let dir = if root.kind == enElement:
      root.attrs.getOrDefault("dir", "ltr").toLowerAscii() else: "ltr"
  let s = Solve(theme: theme, docWidth: w, dir: dir)
  if root.kind == enElement and root.tag == "mailDocument":
    root.layout = LayoutBox(solved: true, container: w, outer: w, box: w,
      boxExact: float(w))
    for c in root.children:
      solveNode(c, float(w), s, dir == "rtl", result)
  else:
    solveNode(root, float(w), s, dir == "rtl", result)

proc contentBox*(node: EmailNode): int =
  ## The px width content at `node` is laid out in: the box of the
  ## nearest laid-out ancestor (or of `node` itself), 0 when none is.
  var n = node
  while n != nil:
    if n.layout.solved:
      return n.layout.box
    n = n.parent
  0

proc defaultColumnPadding*(theme: EmailTheme): array[4, int] =
  ## The implicit single column's padding (`space.gutter`), whole px.
  boxOf("tok:" & columnPaddingToken, theme)

# --- Head rules the rows need (P6 places them in the responsive block).

const
  cellsStackClass* = "e-cells-stack"
    ## `cellsStacking`: a cell that turns into a full-width block below
    ## the breakpoint.

const gridItemClass* = "e-grid-item"
  ## `mailGrid`: an item that takes its row's full width below the
  ## breakpoint.

const sidebarStackClass* = "e-sb-stack"
  ## `mailSidebar(switch_below > 0)`: a side that takes the full width
  ## below the breakpoint.

const cellsGutterClass* = "e-cells-gutter"
  ## `cellsStacking`: the gutter cell between two cells, hidden once the
  ## row stacks.

const
  stackTableClass* = "e-tbl-t"
    ## A stacking data table (R-TBL-18): a block inline, a table from
    ## the breakpoint up.
  stackGroupClass* = "e-tbl-g"
    ## Its body: a row group from the breakpoint up.
  stackHeadClass* = "e-tbl-head"
    ## Its header row: hidden inline, shown from the breakpoint up.
  stackRowClass* = "e-tbl-r"
    ## A body row: a row from the breakpoint up.
  stackCellClass* = "e-tbl-c"
    ## A body cell: a cell from the breakpoint up; below it, its line
    ## starts at the start of the line.
  stackLabelClass* = "e-tbl-lbl"
    ## The column label in a body cell: shown inline, hidden from the
    ## breakpoint up.

proc stackAlignClass*(align: string): string =
  ## A stacked cell whose own alignment (`left`, `right`, `center`) the
  ## desktop rules give back; stacked, its line starts at the start.
  "e-tbl-a-" & align

proc stackInnerClass*(width: string): string =
  ## A stacked cell other than its row's last (no rule, no bottom
  ## padding inline): the desktop rule that gives back a `width` bottom
  ## border and the bottom padding.
  "e-tbl-in-" & width.replace(".", "-")

const
  ifThunderbirdClass* = "e-if-tb"
    ## A `mailIf(family = thunderbird)` block, shown by
    ## `.moz-text-html .e-if-tb` (R-RAW-06).
  ifThunderbirdInlineClass* = "e-if-tb-i"
    ## The same inside text, a `span`.
  ifInlineParents* = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "a",
    "span", "strong", "em", "b", "i", "u", "s", "small", "sup", "sub",
    "code", "td", "th", "caption"]
    ## Parents whose `mailIf` content is inline: the hidden block is a
    ## `span` there (a `div` inside a `p` is invalid HTML).

proc scrollMinClass*(px: int): string =
  ## A scrolling data table's desktop width, kept as its minimum below
  ## the breakpoint (R-TBL-18).
  "e-tbl-min-" & $px

proc stackPadClass*(sides: array[4, int]): string =
  ## `cellsStacking`: a cell's padding once stacked (its own padding,
  ## the gutter as a top gap instead of half-gutters at its sides).
  "e-stackpad-" & $sides[0] & "-" & $sides[1] & "-" & $sides[2] & "-" &
    $sides[3]

type ColumnRule* = object
  ## One head rule a row needs: under the `min-width` query (`desktop`)
  ## or under the `max-width` one, for one generated class; or, with
  ## `thunderbird`, a rule for Thunderbird alone (`.moz-text-html`,
  ## outside any query: `mailIf(family = thunderbird)`, R-RAW-06).
  desktop*: bool
  thunderbird*: bool
  cls*: string
  decls*: seq[tuple[prop, value: string; important: bool]]

proc pxSides(s: array[4, int]): string =
  var parts: array[4, string]
  for i in 0 .. 3:
    parts[i] = if s[i] == 0: "0" else: $s[i] & "px"
  parts[0] & " " & parts[1] & " " & parts[2] & " " & parts[3]

proc fabStackedPadding*(lb: LayoutBox): array[4, int] =
  ## `fabFour`: the gutter `div`'s padding once stacked, the top gap in
  ## place of the half-gutters.
  [lb.mobileGap, 0, 0, 0]

proc stackedPadding*(lb: LayoutBox): array[4, int] =
  ## A stacked cell's padding: its own, plus the gutter as a top gap
  ## (the gutter cells beside it are hidden once the row stacks).
  [lb.padding[0] + lb.mobileGap, lb.padding[1], lb.padding[2],
    lb.padding[3]]

proc mergesWithSection*(col: EmailNode): bool =
  ## True for a section's one `mailColumn` that the section lowering
  ## merges into the section (R-LAY-08): no background, border or
  ## radius of its own, the section's full width, no reversal. It gets
  ## no column markup, so its class would be dead head CSS.
  let p = col.parent
  if col.kind != enElement or col.tag != "mailColumn" or p == nil or
      p.kind != enElement or p.tag != "mailSection" or p.layout.reversed:
    return false
  var cols = 0
  for c in p.children:
    if c.kind == enElement and c.tag in ["mailColumn", "mailGroup"]:
      inc cols
  if cols != 1:
    return false
  if rawValue(col, "background-color").len > 0 or max(col.layout.border) > 0 or
      rawValue(col, "border-radius") notin ["", "0"]:
    return false
  not col.layout.pxWidth and col.layout.percent == 100.0

proc collectRules(node: EmailNode; acc: var seq[ColumnRule];
    seen: var seq[string]) =
  if node == nil or node.kind != enElement:
    return
  let lb = node.layout
  if lb.solved and node.tag in columnTags:
    proc add(acc: var seq[ColumnRule]; seen: var seq[string];
        r: ColumnRule) =
      let key = (if r.desktop: "d:" else: "m:") & r.cls
      if key notin seen:
        seen.add(key)
        acc.add(r)
    if lb.className.len > 0 and not mergesWithSection(node):
      let w = if lb.pxWidth: $lb.deskPx & "px"
        else: percentText(lb.deskPercent) & "%"
      add(acc, seen, ColumnRule(desktop: true, cls: lb.className,
        decls: @[("width", w, true), ("max-width", w, false)]))
    if lb.gutterClass.len > 0:
      add(acc, seen, ColumnRule(desktop: true, cls: lb.gutterClass,
        decls: @[("padding", lb.gutterCss, true)]))
    if lb.strategy == "cellsStacking":
      add(acc, seen, ColumnRule(desktop: false, cls: cellsStackClass,
        decls: @[("display", "block", true), ("width", "100%", true)]))
      if lb.siblings > 1 and lb.gutter[1] + lb.gutter[3] > 0:
        add(acc, seen, ColumnRule(desktop: false, cls: cellsGutterClass,
          decls: @[("display", "none", true)]))
      if lb.mobileGap > 0:
        let st = stackedPadding(lb)
        add(acc, seen, ColumnRule(desktop: false, cls: stackPadClass(st),
          decls: @[("padding", pxSides(st), true)]))
    if lb.strategy == "fabFour" and max(lb.gutter) + lb.mobileGap > 0:
      let st = fabStackedPadding(lb)
      add(acc, seen, ColumnRule(desktop: false, cls: stackPadClass(st),
        decls: @[("padding", pxSides(st), true)]))
  if node.tag == "mailIf" and "thunderbird" in
      node.attrs.getOrDefault("family", "").toLowerAscii():
    # R-RAW-06: the hidden block, shown in Thunderbird only.
    let inline = node.parent != nil and node.parent.kind == enElement and
      node.parent.tag.toLowerAscii() in ifInlineParents
    let cls = if inline: ifThunderbirdInlineClass else: ifThunderbirdClass
    if "t:" & cls notin seen:
      seen.add("t:" & cls)
      acc.add(ColumnRule(thunderbird: true, cls: cls,
        decls: @[("display", if inline: "inline" else: "block", true),
          ("max-height", "none", true), ("overflow", "visible", true)]))
  if lb.solved and node.tag == "mailTable":
    # R-TBL-18's mobile modes, below the breakpoint.
    proc addOnce(acc: var seq[ColumnRule]; seen: var seq[string];
        cls: string; decls: seq[tuple[prop, value: string;
        important: bool]]) =
      if "m:" & cls notin seen:
        seen.add("m:" & cls)
        acc.add(ColumnRule(desktop: false, cls: cls, decls: decls))
    if lb.strategy == "stack":
      # Mobile-first: the stacked form is inline; from the breakpoint up
      # these restore the table (copied for Thunderbird, R-LAY-12).
      proc addDesk(acc: var seq[ColumnRule]; seen: var seq[string];
          cls: string; decls: seq[tuple[prop, value: string;
          important: bool]]) =
        if "d:" & cls notin seen:
          seen.add("d:" & cls)
          acc.add(ColumnRule(desktop: true, cls: cls, decls: decls))
      addDesk(acc, seen, stackTableClass, @[("display", "table", true)])
      addDesk(acc, seen, stackGroupClass, @[("display", "table-row-group",
        true)])
      addDesk(acc, seen, stackHeadClass, @[("display", "table-row", true)])
      addDesk(acc, seen, stackRowClass, @[("display", "table-row", true)])
      addDesk(acc, seen, stackCellClass, @[("display", "table-cell", true)])
      addDesk(acc, seen, stackLabelClass, @[("display", "none", true)])
      let width = if lb.className.len > 0: lb.className else: "0"
      addDesk(acc, seen, stackInnerClass(width), @[("border-bottom-width",
        width, true), ("padding-bottom", lb.gutterCss, true)])
      for a in ["left", "right", "center"]:
        addDesk(acc, seen, stackAlignClass(a), @[("text-align", a, true)])
    elif lb.strategy == "scroll":
      addOnce(acc, seen, scrollMinClass(lb.box),
        @[("min-width", $lb.box & "px", true)])
  if lb.solved and ((node.tag == "mailGrid" and not node.expanded and
      lb.items > 0) or (node.tag == "mailSidebar" and lb.switchPx > 0)):
    # A one-up mobile grid and a switching sidebar stack below the
    # breakpoint: each item (side) the full width of its row, the gap
    # moved to the top of every one but the first.
    let cls = if node.tag == "mailGrid": gridItemClass else: sidebarStackClass
    let key = "m:" & cls
    if key notin seen:
      seen.add(key)
      acc.add(ColumnRule(desktop: false, cls: cls,
        decls: @[("max-width", "100%", true), ("width", "100%", true)]))
    for sides in [[0, 0, 0, 0], [lb.gutterPx, 0, 0, 0]]:
      let pad = stackPadClass(sides)
      if "m:" & pad notin seen:
        seen.add("m:" & pad)
        acc.add(ColumnRule(desktop: false, cls: pad,
          decls: @[("padding", pxSides(sides), true)]))
  for c in node.children:
    collectRules(c, acc, seen)

proc columnRules*(root: EmailNode): seq[ColumnRule] =
  ## The head rules of every solved row in `root`, deduplicated by
  ## class, in document order (P6 sorts them).
  var seen: seq[string] = @[]
  collectRules(root, result, seen)
