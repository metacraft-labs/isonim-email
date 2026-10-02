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
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  sectionTags* = ["mailSection"]
  wrapperTags* = ["mailWrapper"]
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

proc checkMinColumns(row: EmailNode; cols: seq[EmailNode]; s: Solve;
    diags: var seq[EmailDiagnostic]) =
  ## R-TBL-11: a cell row shows its desktop layout whenever CSS is lost
  ## (`cellsStacking`) or always (`cells`), so each cell's content box
  ## at a 320px document must reach its minimum. Paddings and borders
  ## stay fixed while the document narrows, so the row's box shrinks by
  ## exactly what the document loses.
  let rowBox = row.layout.boxExact
  let box320 = max(0.0, rowBox - float(s.docWidth - 320))
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

proc solveNode(node: EmailNode; context: float; s: Solve; rtl: bool;
    diags: var seq[EmailDiagnostic]) =
  if node == nil or node.kind != enElement:
    return
  let tag = node.tag
  if tag in sectionTags:
    solveBand(node, context, s, rtl, sectionPaddingToken, diags)
  elif tag in wrapperTags:
    solveBand(node, context, s, rtl, "", diags)
  elif tag in rowTags:
    solveColumns(node, context, s, rtl, diags)
  elif tag in columnTags:
    # A column outside a section (P1/F1 report the nesting): solved as
    # a lone column of the context, so its children still get a box.
    solveColumn(node, context, 1, false, columnPaddingToken, s, rtl, diags)
    for c in node.children:
      solveNode(c, float(node.layout.box), s, rtl, diags)
  else:
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

const cellsGutterClass* = "e-cells-gutter"
  ## `cellsStacking`: the gutter cell between two cells, hidden once the
  ## row stacks.

proc stackPadClass*(sides: array[4, int]): string =
  ## `cellsStacking`: a cell's padding once stacked (its own padding,
  ## the gutter as a top gap instead of half-gutters at its sides).
  "e-stackpad-" & $sides[0] & "-" & $sides[1] & "-" & $sides[2] & "-" &
    $sides[3]

type ColumnRule* = object
  ## One head rule a row needs: under the `min-width` query (`desktop`)
  ## or under the `max-width` one, for one generated class.
  desktop*: bool
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
    if lb.className.len > 0:
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
  for c in node.children:
    collectRules(c, acc, seen)

proc columnRules*(root: EmailNode): seq[ColumnRule] =
  ## The head rules of every solved row in `root`, deduplicated by
  ## class, in document order (P6 sorts them).
  var seen: seq[string] = @[]
  collectRules(root, result, seen)
