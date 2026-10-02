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
  rawTags = ["mailRaw"]
    ## Siblings MJML does not count (`nonRawSiblings`).
  sectionPaddingToken* = "space.section"
  columnPaddingToken* = "space.gutter"

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

proc solveNode(node: EmailNode; context: float; theme: EmailTheme;
    diags: var seq[EmailDiagnostic])

proc solveColumn(col: EmailNode; parentBox: float; siblings: int;
    inGroup: bool; theme: EmailTheme; diags: var seq[EmailDiagnostic]) =
  ## One `mailColumn` or `mailGroup` in a box of `parentBox` px.
  var spec: WidthSpec
  try:
    spec = widthSpec(col, theme)
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
      if isGroup: paddingOf(col, theme, "")
      else: paddingOf(col, theme, columnPaddingToken)
    lb.border = if isGroup: [0, 0, 0, 0] else: borderOf(col, theme)
  except StyleError, ThemeError:
    diags.add(layoutDiag(col, codeVocabBadValue,
      getCurrentExceptionMsg(), @["R-LAY-01"]))
  let inner = exact - float(lb.padding[1] + lb.padding[3] +
    lb.border[1] + lb.border[3])
  lb.boxExact = inner
  lb.box = int(trunc(inner))
  lb.className = columnClassName(lb.percent, lb.outer, lb.pxWidth)
  col.layout = lb
  if isGroup:
    let kids = col.children
    let m = nonRawCount(kids)
    for c in kids:
      if isColumn(c):
        solveColumn(c, inner, m, true, theme, diags)
      elif c.kind == enElement and c.tag notin rawTags:
        diags.add(layoutDiag(c, codeStructNesting,
          "<" & c.tag & "> inside mailGroup: a group holds mailColumn " &
          "children only (R-LAY-16)", @["R-LAY-16"]))
  else:
    for c in col.children:
      solveNode(c, float(lb.box), theme, diags)

proc solveBand(node: EmailNode; context: float; theme: EmailTheme;
    defaultPadding: string; diags: var seq[EmailDiagnostic]) =
  ## A section or wrapper: occupies the context, boxes it in by its
  ## padding and borders.
  let w = int(trunc(context))
  var lb = LayoutBox(solved: true, container: w, outer: w)
  try:
    lb.padding = paddingOf(node, theme, defaultPadding)
    lb.border = borderOf(node, theme)
  except StyleError, ThemeError:
    diags.add(layoutDiag(node, codeVocabBadValue,
      getCurrentExceptionMsg(), @["R-LAY-08"]))
  lb.box = w - lb.padding[1] - lb.padding[3] - lb.border[1] - lb.border[3]
  lb.boxExact = float(lb.box)
  node.layout = lb
  let kids = node.children
  if tagOf(node) in wrapperTags:
    for c in kids:
      solveNode(c, float(lb.box), theme, diags)
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
    let n = nonRawCount(kids)
    for c in kids:
      if isColumn(c):
        solveColumn(c, float(lb.box), n, false, theme, diags)
  else:
    # The implicit single column: content sits in a box narrowed by the
    # default column padding.
    var colPad: array[4, int]
    try:
      colPad = boxOf("tok:" & columnPaddingToken, theme)
    except StyleError, ThemeError:
      diags.add(layoutDiag(node, codeVocabBadValue,
        getCurrentExceptionMsg(), @["R-LAY-08"]))
    let inner = lb.box - colPad[1] - colPad[3]
    for c in kids:
      solveNode(c, float(inner), theme, diags)

proc solveNode(node: EmailNode; context: float; theme: EmailTheme;
    diags: var seq[EmailDiagnostic]) =
  if node == nil or node.kind != enElement:
    return
  let tag = node.tag
  if tag in sectionTags:
    solveBand(node, context, theme, sectionPaddingToken, diags)
  elif tag in wrapperTags:
    solveBand(node, context, theme, "", diags)
  elif tag in columnTags:
    # A column outside a section (P1/F1 report the nesting): solved as
    # a lone column of the context, so its children still get a box.
    solveColumn(node, context, 1, false, theme, diags)
  else:
    for c in node.children:
      solveNode(c, context, theme, diags)

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
  if root.kind == enElement and root.tag == "mailDocument":
    root.layout = LayoutBox(solved: true, container: w, outer: w, box: w,
      boxExact: float(w))
    for c in root.children:
      solveNode(c, float(w), theme, result)
  else:
    solveNode(root, float(w), theme, result)

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
