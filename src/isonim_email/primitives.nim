## isonim_email/primitives.nim — the layout primitives as patterns.
##
## `mailBox`, `mailGrid`, `mailCluster` and `mailSidebar` are vocabulary
## elements with lowerings of their own (`lower/box.nim`, `grid.nim`,
## `cluster.nim`, `sidebar.nim`). Like every pattern they declare what a
## screenshot of them must show and what each client is expected to get
## wrong (`patterns.nim`), which the review brief generator reads. Their
## expansion is nil ("lowered by its own lowering"), except a grid that
## keeps two items per row on a phone, which is itself a composition:
##
## `mailGrid(mobile_columns = 2)` becomes rows of rows. Four columns: per
## desktop row, an outer two-column `hybrid` row (gutter `g`) whose
## columns each hold a two-column `cells` row (gutter `g`), so the grid
## goes 4-up → 2-up and never 1-up, with or without CSS, and Word lays
## the four out on one line (the cells are real tables inside the ghost
## row). Two columns: a `cells` row per pair, which never stacks. Rows
## are spaced by a `mailStack` with the gutter as its gap. An item's
## `min_item` is the cells' 320px minimum (R-TBL-11); an incomplete last
## pair is filled with an empty slot. Three columns with two on a phone
## would orphan an item every second row (`E-PATTERN-GRID-ORPHAN`, P1).
##
## Importing this module registers the four (`render.nim`, `stories.nim`
## and `review/brief.nim` import it for that alone, hence `{.used.}`).
##
## Pure tree building: identical on the C and JS targets.

{.used.}

import std/[strutils, tables, unicode]
import ./renderer
import ./target
import ./patterns
import ./passes/layout
import ./style/units

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  BoxProps* = object
    ## `mailBox` (layout-patterns.md §3.2).
    padding*: string
    background_color*: string
    border*: string
    border_radius*: string
    shadow*: string = "none"
    outlook_rounded*: bool

  GridProps* = object
    ## `mailGrid` (layout-patterns.md §3.4).
    columns*: int = 2
    mobile_columns*: int = 1
    gutter*: string
    min_item*: string
    align*: string
    last_row*: string = "left"

  ClusterProps* = object
    ## `mailCluster` (layout-patterns.md §3.5).
    gap*: string
    row_gap*: string
    align*: string
    separator*: string

  SidebarProps* = object
    ## `mailSidebar` (layout-patterns.md §3.6).
    side*: string = "left"
    fixed*: string
    valign*: string = "middle"
    gap*: string
    switch_below*: string
    reverse_on_mobile*: bool

proc textOf(n: EmailNode): string =
  ## The text under `n`, one space between the texts of its blocks.
  if n.kind == enText:
    return n.text
  for c in n.children:
    let t = textOf(c)
    if t.len > 0 and result.len > 0 and c.kind == enElement:
      result.add(" ")
    result.add(t)

proc shown(n: EmailNode; maxLen = 24): string =
  ## A short, quoted label for an item: its text, else its image's alt.
  var t = strutils.splitWhitespace(textOf(n).strip()).join(" ")
  if t.len == 0:
    var stack = @[n]
    while stack.len > 0 and t.len == 0:
      let x = stack.pop()
      if x.kind == enElement and x.tag == "mailImage":
        t = "image \"" & x.attrs.getOrDefault("alt", "") & "\""
        return t
      for c in x.children:
        stack.add(c)
    return "(empty)"
  if t.runeLen > maxLen:
    t = t.runeSubStr(0, maxLen) & "…"
  "\"" & t & "\""

proc labels(items: seq[EmailNode]; limit = 6): string =
  var parts: seq[string] = @[]
  for i, it in items:
    if i == limit:
      parts.add("…")
      break
    parts.add(shown(it))
  parts.join(", ")

proc pxOr(value, fallback: string): string =
  let v = value.strip()
  if v.len == 0 or v.startsWith("tok:"): fallback else: v

proc boxed(n: EmailNode): bool =
  ## An item that paints a box of its own: a background or a border.
  if n.kind != enElement:
    return false
  rawValue(n, "background-color").len > 0 or
    rawValue(n, "border").len > 0

proc boxAtViewport(n: EmailNode; view: BriefView): int =
  ## The box P3 gave `n` on the desktop, less what the document loses at
  ## this viewport (paddings stay fixed while the document narrows).
  var docW = 600
  var x = n
  while x != nil:
    if x.kind == enElement and x.tag == "mailDocument" and x.layout.solved:
      docW = x.layout.outer
    x = x.parent
  n.layout.box - max(0, docW - view.width)

# --- mailBox ----------------------------------------------------------------

proc boxExpected(n: EmailNode; p: BoxProps; view: BriefView): seq[string] =
  var parts: seq[string] = @[]
  if p.background_color.len > 0:
    parts.add("background " & p.background_color)
  if p.border.len > 0:
    parts.add("a " & p.border & " border")
  elif p.shadow in ["sm", "md"]:
    parts.add("a 1px border one shade darker than its background")
  if p.border_radius.len > 0 and p.border_radius != "0" and not view.word:
    parts.add("rounded corners (" & p.border_radius & ")")
  if p.shadow in ["sm", "md"] and not view.word and view.client != "gmailWeb":
    parts.add("a soft drop shadow (" & p.shadow & ")")
  parts.add(pxOr(p.padding, "24px") & " of padding around its content")
  @["Box: a panel with " & parts.join(", ") & "; its content sits " &
    "inside it."]

proc boxDegradations(n: EmailNode; p: BoxProps;
    view: BriefView): seq[string] =
  if p.shadow in ["sm", "md"] and (view.word or view.client == "gmailWeb" or
      (view.audience and view.family in {cfGmailWeb, cfYahoo,
        cfOutlookWord})):
    result.add("the box has no drop shadow; its 1px border marks its " &
      "edge instead (R-TBL-09)")
  if p.border_radius.len > 0 and p.border_radius != "0" and view.word:
    result.add("the box's corners are square (Word draws no radius, " &
      "R-TBL-16)")

# --- mailGrid ---------------------------------------------------------------

proc gridPerRow(n: EmailNode; p: GridProps; view: BriefView): int =
  ## Items per row in this client at this width.
  let cols = clamp(p.columns, 2, 4)
  if view.word:
    return cols
  if p.mobile_columns == 2:
    if not (view.headCss and view.mediaQueries) or view.narrow:
      return 2
    return cols
  if view.headCss and view.mediaQueries:
    return if view.narrow: 1 else: cols
  # Without media queries the items keep their desktop widths and wrap
  # as many as fit in the row's box at this width.
  let lb = n.layout
  if not lb.solved or lb.items == 0:
    return cols
  # Each item takes its share of the row, but no less than `min_item`
  # (with its trailing gutter): as many as fit at that width.
  let box = max(1, boxAtViewport(n, view))
  let widths = gridItemWidths(lb.box, cols, lb.gutterPx, cols, "left")
  var minItem = 160
  try:
    if p.min_item.len > 0 and not p.min_item.startsWith("tok:"):
      minItem = int(toPx(p.min_item))
  except ValueError:
    discard
  var used = 0.0
  var fit = 0
  for i, w in widths:
    let trailing = if i < cols - 1: lb.gutterPx else: 0
    let share = float(w + trailing) / float(max(lb.box, 1)) * float(box)
    let need = max(float(min(minItem, w) + trailing), share)
    if used + need > float(box) + 0.5:
      break
    used += need
    inc fit
  max(1, fit)

proc gridExpected(n: EmailNode; p: GridProps; view: BriefView): seq[string] =
  let items = itemsOf(n)
  let per = gridPerRow(n, p, view)
  var line = "Grid of " & $items.len & " items (" & labels(items) & "): " &
    $per & (if per == 1: " item" else: " items") & " per row at this " &
    "width"
  if per == 1 and stacksHere(view):
    line.add(", stacked full width with a gap between them")
  elif per == 1:
    line.add(", each no narrower than its minimum, a gap between rows")
  else:
    line.add(", a gap between neighbours and between rows")
  let rest = items.len mod per
  if rest > 0 and per > 1:
    let lr = if p.mobile_columns == 2: "left" else: p.last_row
    line.add("; the last row holds " & $rest &
      (case lr
       of "center": ", centred"
       of "stretch": ", widened to fill the row"
       else: " at the start edge"))
  @[line & "."]

proc gridDegradations(n: EmailNode; p: GridProps;
    view: BriefView): seq[string] =
  if p.mobile_columns != 2 and not view.word and
      not (view.headCss and view.mediaQueries):
    result.add("without media queries the grid's items shrink with " &
      "the row down to their minimum width and then wrap, as many per " &
      "row as fit, so a narrow screen may show a short last row (layout " &
      "patterns §3.4)")
  var anyBoxed = false
  for it in itemsOf(n):
    if boxed(it):
      anyBoxed = true
  if anyBoxed:
    result.add("grid items with a background or a border end at " &
      "different heights where their content differs (ragged bottoms, " &
      "R-TBL-10)")

proc gridExpand(n: EmailNode; p: GridProps; ctx: ExpandCtx): EmailNode =
  ## `mobile_columns = 2` (see the module comment); nil otherwise.
  if p.mobile_columns != 2 or p.columns notin [2, 4]:
    return nil
  let r = ctx.r
  let gutter = if p.gutter.len > 0: p.gutter else: "tok:" & gridGutterToken
  proc el(tag: string; attrs: openArray[(string, string)] = []): EmailNode =
    result = r.createElement(tag)
    result.origin = n.origin
    for (k, v) in attrs:
      r.setAttribute(result, k, v)
  proc pair(a, b: EmailNode): EmailNode =
    var attrs = @[("strategy", "cells"), ("gutter", gutter)]
    if p.min_item.len > 0:
      attrs.add(("min_column", p.min_item))
    result = el("mailColumns", attrs)
    for item in [a, b]:
      let col = el("mailColumn")
      if p.align.len > 0:
        r.setStyle(col, "text-align", p.align)
      if item != nil:
        r.appendChild(col, item)
      else:
        r.appendChild(col, r.createTextNode(" "))
      r.appendChild(result, col)
  let items = itemsOf(n)
  var rows: seq[EmailNode] = @[]
  var i = 0
  while i < items.len:
    let a = items[i]
    let b = if i + 1 < items.len: items[i + 1] else: nil
    if p.columns == 2:
      rows.add(pair(a, b))
      i += 2
    else:
      let outer = el("mailColumns", [("gutter", gutter)])
      for k in 0 .. 1:
        let col = el("mailColumn")
        let x = if i + 2 * k < items.len: items[i + 2 * k] else: nil
        let y = if i + 2 * k + 1 < items.len: items[i + 2 * k + 1] else: nil
        if x != nil:
          r.appendChild(col, pair(x, y))
        else:
          r.appendChild(col, r.createTextNode(" "))
        r.appendChild(outer, col)
      rows.add(outer)
      i += 4
  if rows.len == 1:
    return rows[0]
  result = el("mailStack")
  r.setStyle(result, "gap", gutter)
  for row in rows:
    r.appendChild(result, row)

# --- mailCluster ------------------------------------------------------------

proc clusterExpected(n: EmailNode; p: ClusterProps;
    view: BriefView): seq[string] =
  let items = itemsOf(n)
  var line = "Cluster of " & $items.len & " items (" & labels(items, 9) &
    ") side by side in a line"
  case p.align.toLowerAscii()
  of "center": line.add(", centred")
  of "right": line.add(", right-aligned")
  else: discard
  line.add(", " & pxOr(p.gap, "12px") & " apart")
  if p.separator.len > 0:
    line.add(", separated by \"" & p.separator & "\"")
  if view.word:
    line.add("; all on one line")
  else:
    line.add("; the line wraps onto further lines when it is full, " &
      "never overflowing")
  @[line & "."]

proc clusterDegradations(n: EmailNode; p: ClusterProps;
    view: BriefView): seq[string] =
  if view.word:
    result.add("the cluster stays on one line however narrow (Word " &
      "never wraps a table row; Word is a desktop client); items that do " &
      "not fit the line run past the message's edge (layout patterns " &
      "§3.5)")
  else:
    result.add("a wrapped line ends with its last item's gap" &
      (if p.separator.len > 0: " and separator (\"" & p.separator & "\")"
       else: "") & ", and each line keeps a row gap below it, so a " &
      "wrapped cluster is not flush with its edge (layout-patterns.md §3.5)")

# --- mailSidebar ------------------------------------------------------------

proc sidebarStacked(n: EmailNode; p: SidebarProps; view: BriefView): bool =
  let switching = p.switch_below.len > 0 and p.switch_below.strip() notin
    ["0", "0px"]
  if not switching or view.word:
    return false
  if view.headCss and view.mediaQueries:
    return view.narrow
  # Without media queries the pair wraps once its box is narrower than
  # fixed + gap + switch_below.
  let lb = n.layout
  if not lb.solved:
    return view.narrow
  let box = boxAtViewport(n, view)
  box < lb.fixedPx + lb.gutterPx + lb.switchPx

proc sidebarExpected(n: EmailNode; p: SidebarProps;
    view: BriefView): seq[string] =
  let sides = itemsOf(n)
  if sides.len != 2:
    return @["Sidebar with " & $sides.len & " sides (it needs two)."]
  let fixedIdx = if p.side.toLowerAscii() == "right": 1 else: 0
  let fixedSide = sides[fixedIdx]
  let fluid = sides[1 - fixedIdx]
  let w = pxOr(p.fixed, "?")
  if sidebarStacked(n, p, view):
    return @["Sidebar, stacked at this width: " & shown(sides[0]) &
      " above " & shown(sides[1]) & ", each the full width, a gap " &
      "between them."]
  let where = if fixedIdx == 0: "first" else: "second"
  var line = "Sidebar: a " & w & " wide side (" & shown(fixedSide) &
    ", " & where & " in reading order) beside " & shown(fluid) &
    ", which takes the rest of the row, " & pxOr(p.gap, "16px") &
    " apart; both vertically " &
    (case p.valign.toLowerAscii()
     of "top": "aligned to the top"
     of "bottom": "aligned to the bottom"
     else: "centred against each other")
  let switching = p.switch_below.len > 0 and p.switch_below.strip() notin
    ["0", "0px"]
  if not switching:
    line.add("; side by side at every width")
  @[line & "."]

proc sidebarDegradations(n: EmailNode; p: SidebarProps;
    view: BriefView): seq[string] =
  let switching = p.switch_below.len > 0 and p.switch_below.strip() notin
    ["0", "0px"]
  if switching and not view.word and not (view.headCss and
      view.mediaQueries):
    result.add("where the two sides wrap without media queries, the " &
      "second sits directly under the first, with no gap (layout " &
      "patterns §3.6)")
  if switching and boxed(itemsOf(n)[min(1, itemsOf(n).high)]):
    result.add("a side with a background does not stretch to the " &
      "other side's height (R-TBL-10)")

# --- Registration -----------------------------------------------------------

proc noExpansion[P](n: EmailNode; p: P; ctx: ExpandCtx): EmailNode = nil

proc registerPrimitives() =
  registerPattern(typedPattern[BoxProps]("mailBox", noExpansion[BoxProps],
    boxExpected, boxDegradations))
  registerPattern(typedPattern[GridProps]("mailGrid", gridExpand,
    gridExpected, gridDegradations))
  registerPattern(typedPattern[ClusterProps]("mailCluster",
    noExpansion[ClusterProps], clusterExpected, clusterDegradations))
  registerPattern(typedPattern[SidebarProps]("mailSidebar",
    noExpansion[SidebarProps], sidebarExpected, sidebarDegradations))

registerPrimitives()
