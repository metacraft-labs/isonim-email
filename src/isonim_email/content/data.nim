## isonim_email/content/data.nim — the data patterns
## (layout-patterns.md §4.4): `mailKeyValue`, `mailLineItems`,
## `mailStatTiles`, `mailStepper`, `mailTimeline` and `mailEvent`.
##
## - `mailKeyValue(caption, total_row)` holding `mailKeyValueRow(label,
##   emphasis)`s, each holding its value: a `mailTable` (a real table:
##   the keys are `th scope="row"`), values end-aligned and `nowrap`
##   when short, the total row bold under a rule. Its text part is
##   `label: value` lines, written by the pattern.
## - `mailLineItems(caption, mobile, item_label, qty_label,
##   amount_label, thumb_width)` holding `mailLineItem(description,
##   detail, qty, amount, thumb, thumb_alt)`s: a 3-column `mailTable`
##   (description | qty | amount) readable at 320px, the detail a second
##   line and a thumbnail a nested `mailSidebar` in the description
##   cell; `mobile = cards` makes each item a bordered `mailBox` holding
##   a `mailKeyValue`, every client's rendering.
## - `mailStatTiles` holding 2–4 `mailStat(value, label, tone)`s: a
##   `cells` row of painted tiles (2–3) or a 4-up grid that keeps two
##   per row on a phone; its text part is `label: value` lines.
## - `mailStepper(current, status, text)` holding 3–5 `mailStep`s: its
##   special lowering, a two-row table the expansion writes (markers
##   between connector halves, then the labels), a visually hidden
##   status line, and its text-part line `Step n of m: …`. More than five
##   steps is `E-PATTERN-STEPPER-LONG`, a status it cannot write
##   `E-PATTERN-MISSING-TEXT` (P1, `passes/validate.nim`). The steps stay
##   in the tree as expanded patterns around their labels, so P1 counts
##   them.
## - `mailTimeline` holding `mailTimelineEvent(time)`s: its special
##   lowering, one table of two rows per event (a 16px dot beside the
##   time, then a 2px line cell beside the text, continuous because a
##   row's cells share its height); its text part is `time — event`
##   lines.
## - `mailEvent(month, day, date_text, location, google, outlook, ics, …)`
##   holding its details: a `mailSidebar` of a date tile (hidden from
##   screen readers and the text part) beside the details, the full date
##   line, the location and the calendar links; without `date_text`,
##   `E-PATTERN-MISSING-TEXT` (P1).
##
## Item elements other than `mailStep` are read and placed by their
## pattern (`defineMailItem`): they never reach the output themselves.
## Importing this module registers the patterns.
##
## Pure tree building: identical on the C and JS targets.

{.used.}

import std/[strutils, tables, unicode]
import ../renderer
import ../target
import ../patterns
import ../style/tokens
import ./kit

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  KeyValueProps* = object
    ## `mailKeyValue` (layout-patterns.md §4.4).
    caption*: string
    total_row*: bool

  KeyValueRowProps* = object
    ## `mailKeyValueRow`, an item of `mailKeyValue`.
    label*: string
    emphasis*: bool

  LineItemsProps* = object
    ## `mailLineItems`.
    caption*: string
    mobile*: string = "auto"
    item_label*: string = "Item"
    qty_label*: string = "Qty"
    amount_label*: string = "Amount"
    thumb_width*: int = 48

  LineItemProps* = object
    ## `mailLineItem`, an item of `mailLineItems`.
    description*: string
    detail*: string
    qty*: string
    amount*: string
    thumb*: string
    thumb_alt*: string

  StatTilesProps* = object ## `mailStatTiles` (no props: its stats are its content).

  StatProps* = object
    ## `mailStat`, an item of `mailStatTiles`.
    value*: string
    label*: string
    tone*: string = "neutral"

  StepperProps* = object
    ## `mailStepper`.
    current*: int
    status*: string
    text*: string

  StepProps* = object ## `mailStep`: its label is its content.

  TimelineProps* = object ## `mailTimeline` (no props: its events are its content).

  TimelineEventProps* = object
    ## `mailTimelineEvent`, an item of `mailTimeline`.
    time*: string

  EventProps* = object
    ## `mailEvent`.
    month*: string
    day*: string
    date_text*: string
    location*: string
    google*: string
    outlook*: string
    ics*: string
    google_label*: string = "Google Calendar"
    outlook_label*: string = "Outlook"
    ics_label*: string = "Apple Calendar (.ics)"

const
  shortValueChars* = 20
    ## A key-value value this short (an amount) does not wrap.
  statsMin* = 2
  statsMax* = 4
    ## The stats a `mailStatTiles` holds.
  statMinWidth* = "72px"
    ## A stat tile's 320px minimum (a short item, R-TBL-11).
  stepperMin* = 3
  stepperMax* = 5
    ## The steps a `mailStepper` holds (more is E-PATTERN-STEPPER-LONG).
  stepMarkerPx* = 28
    ## A step marker's diameter.
  stepConnectorPx* = 2
    ## A connector's thickness.
  timelineDotPx* = 16
  timelineLinePx* = 2
  timelineGapPx* = 12
    ## The timeline's track: a 16px dot of three cells (7, 2, 7) and the
    ## gap before the text.
  eventTilePx* = 64
    ## The event's date tile.
  doneGlyph* = "✓"
    ## A done step's marker.

defineMailItem(mailKeyValueRow, "mailKeyValue", KeyValueRowProps)
defineMailItem(mailLineItem, "mailLineItems", LineItemProps)
defineMailItem(mailStat, "mailStatTiles", StatProps)
defineMailItem(mailTimelineEvent, "mailTimeline", TimelineEventProps)

proc textOf(n: EmailNode): string =
  if n.kind == enText:
    return n.text
  for c in n.children:
    result.add(textOf(c))

proc quoted(s: string; limit = 32): string =
  var t = strutils.splitWhitespace(s).join(" ")
  if t.runeLen > limit:
    t = t.runeSubStr(0, limit) & "…"
  "\"" & t & "\""

proc noLines[P](n: EmailNode; p: P; view: BriefView): seq[string] = @[]

proc layoutTable(ctx: ExpandCtx; n: EmailNode;
    styles: openArray[(string, string)] = []): EmailNode =
  ## A presentation table (R-LAY-15), right to left where `n` is.
  result = el(ctx, n, "table", attrs = [("role", "presentation"),
    ("width", "100%"), ("border", "0"), ("cellpadding", "0"),
    ("cellspacing", "0"), ("dir", if isRtl(n): "rtl" else: "")],
    styles = @[("width", "100%")] & @styles)

proc spacerCell(ctx: ExpandCtx; n: EmailNode;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []): EmailNode =
  ## A cell that holds nothing visible: a no-break space at a
  ## (non-zero) zero font size, never empty (R-TBL-05, R-LAY-04).
  result = el(ctx, n, "td", attrs = @[("aria-hidden", "true")] & @attrs,
    styles = @[("padding", "0"), ("font-size", "0.01px"),
      ("line-height", "0"), ("mso-line-height-rule", "exactly")] & @styles,
    text = "\u00a0")

proc border(ctx: ExpandCtx; node: EmailNode; side = "";
    width = "1px"; token = "color.border.subtle") =
  ## A solid border in a theme colour, dark-paired under `designed`: a
  ## box's (the `border` shorthand the layout pass reads), or one side's
  ## of a cell.
  if side.len == 0:
    ctx.r.setStyle(node, "border", width & " solid " &
      ctx.theme.lightFor(token))
    if ctx.darkDesigned():
      ctx.r.setStyle(node, "@dark:border-color", "tok:" & token)
    return
  let pre = "border-" & side & "-"
  ctx.r.setStyle(node, pre & "width", width)
  ctx.r.setStyle(node, pre & "style", "solid")
  paint(ctx, node, pre & "color", token)

# --- mailKeyValue ---------------------------------------------------------------

proc keyValueTable(ctx: ExpandCtx; n: EmailNode; caption: string;
    rows: seq[tuple[label: string; value: seq[EmailNode];
      emphasis: bool]]; totalRow: bool): EmailNode =
  ## The key-value data table: one row per entry, the label a row
  ## header, the value end-aligned.
  result = el(ctx, n, "mailTable", attrs = [("caption", caption.strip()),
    ("mobile", "keep")], styles = [("border", "none")])
  let table = el(ctx, n, "table")
  let body = el(ctx, n, "tbody")
  let start = startSide(n)
  let stop = endSide(n)
  for i, row in rows:
    let total = totalRow and i == rows.high
    let bold = row.emphasis or total
    let tr = el(ctx, n, "tr")
    let pad = if total: "12px" else: "6px"
    let th = el(ctx, n, "th", attrs = [("scope", "row"), ("align", start)],
      styles = [("padding", if start == "left": pad & " 16px 6px 0"
        else: pad & " 0 6px 16px"), ("text-align", start),
        ("font-weight", if bold: "700" else: "400")], text = row.label)
    if row.label.runeLen <= shortValueChars:
      # A short label keeps its line: a wide value (a nested table)
      # would otherwise squeeze it into a column of letters.
      ctx.r.setStyle(th, "white-space", "nowrap")
    let td = el(ctx, n, "td", attrs = [("align", stop)],
      styles = [("padding", pad & " 0 6px"), ("text-align", stop),
        ("font-weight", if bold: "700" else: "400")])
    var valueText = ""
    for v in row.value:
      valueText.add(plainText(v))
    if valueText.strip().runeLen <= shortValueChars:
      # An amount never breaks ("$1,20 / 0.00").
      ctx.r.setStyle(td, "white-space", "nowrap")
    moveInto(ctx, td, row.value)
    if total:
      border(ctx, th, "top")
      border(ctx, td, "top")
    add(ctx, tr, th, td)
    add(ctx, body, tr)
  add(ctx, table, body)
  add(ctx, result, table)

proc keyValueLines(rows: seq[tuple[label: string; value: seq[EmailNode];
    emphasis: bool]]): seq[string] =
  for row in rows:
    var v = ""
    for x in row.value:
      let t = plainText(x)
      if t.len > 0:
        if v.len > 0:
          v.add(' ')
        v.add(t)
    result.add(row.label & ": " & v)

proc keyValueExpand(n: EmailNode; p: KeyValueProps;
    ctx: ExpandCtx): EmailNode =
  let items = slotOf(n, ["mailKeyValueRow"], "mailKeyValueRow items")
  if items.len == 0:
    raise newException(PatternError, "mailKeyValue needs at least one " &
      "mailKeyValueRow")
  var rows: seq[tuple[label: string; value: seq[EmailNode];
    emphasis: bool]] = @[]
  for it in items:
    let rp = readProps[KeyValueRowProps](it)
    let label = required(it, rp.label, "a label", "a row is a label and " &
      "its value")
    rows.add((label, slot(it), rp.emphasis))
  let lines = keyValueLines(rows)
  let table = keyValueTable(ctx, n, p.caption, rows, p.total_row)
  for it in items:
    ctx.r.removeChild(n, it)
  htmlAndText(ctx, n, table, [linesPara(ctx, n, lines)])

proc keyValueExpected(n: EmailNode; p: KeyValueProps;
    view: BriefView): seq[string] =
  var labels: seq[string] = @[]
  for c in slot(n):
    if c.kind == enElement:
      labels.add("\"" & c.attrs.getOrDefault("label", "") & "\"")
  var emphasised: seq[string] = @[]
  for c in slot(n):
    if c.kind == enElement and
        c.attrs.getOrDefault("emphasis", "").toLowerAscii() == "true":
      emphasised.add("\"" & c.attrs.getOrDefault("label", "") & "\"")
  @["Key-value list: " & $labels.len & " rows (" & labels.join(", ") &
    "), each label at the " & startSide(n) & " and its value on the same " &
    "line at the " & endSide(n) & " edge, never stacked" &
    (if emphasised.len > 0: "; the emphasised row" &
      (if emphasised.len > 1: "s " else: " ") & emphasised.join(", ") &
      " bold" else: "") &
    (if p.total_row: "; the last row bold, under a thin rule" else: "") &
    "."]

# --- mailLineItems ---------------------------------------------------------------

proc descriptionCell(ctx: ExpandCtx; n: EmailNode; ip: LineItemProps;
    thumbWidth: int): seq[EmailNode] =
  ## The description, its detail under it (and in brackets in the text
  ## part), beside the thumbnail when there is one.
  var parts: seq[EmailNode] = @[]
  parts.add(el(ctx, n, "p", styles = [("margin", "0")],
    text = ip.description.strip()))
  if ip.detail.strip().len > 0:
    let d = el(ctx, n, "p", styles = [("margin", "0")],
      text = ip.detail.strip())
    useType(ctx, d, "type.small")
    paint(ctx, d, "color", "color.text.secondary")
    parts.add(htmlAndText(ctx, n, d,
      [el(ctx, n, "span", text = "(" & ip.detail.strip() & ")")]))
  if ip.thumb.strip().len == 0:
    return parts
  let sb = el(ctx, n, "mailSidebar", attrs = [("side", "left"),
    ("fixed", $thumbWidth & "px"), ("valign", "top"),
    ("switch_below", "0")], styles = [("gap", "tok:space.3")])
  let alt = ip.thumb_alt.strip()
  let img = el(ctx, n, "mailImage", attrs = [("src", ip.thumb.strip()),
    ("decorative", if alt.len == 0: "true" else: "")],
    styles = [("width", $thumbWidth & "px")])
  ctx.r.setAttribute(img, "alt", alt)
  let text = el(ctx, n, "div")
  moveInto(ctx, text, parts)
  add(ctx, sb, img, text)
  @[sb]

proc lineItemsExpand(n: EmailNode; p: LineItemsProps;
    ctx: ExpandCtx): EmailNode =
  let items = slotOf(n, ["mailLineItem"], "mailLineItem items")
  if items.len == 0:
    raise newException(PatternError, "mailLineItems needs at least one " &
      "mailLineItem")
  let mode = oneOf(n, p.mobile, "mobile", ["auto", "cards"])
  if p.thumb_width <= 0:
    raise newException(PatternError, "mailLineItems thumb_width = " &
      $p.thumb_width & " is not a positive px width")
  var props: seq[LineItemProps] = @[]
  for it in items:
    let ip = readProps[LineItemProps](it)
    discard required(it, ip.description, "a description",
      "a line item says what was bought")
    discard required(it, ip.amount, "an amount", "a line item says what " &
      "it costs")
    props.add(ip)
  for it in items:
    ctx.r.removeChild(n, it)
  let start = startSide(n)
  let stop = endSide(n)
  if mode == "cards":
    # Every client's rendering: one bordered card per item, each a
    # key-value list (no media query decides it).
    result = el(ctx, n, "mailStack", styles = [("gap", "tok:space.3")])
    for ip in props:
      let box = el(ctx, n, "mailBox", styles = [("padding", "8px 16px"),
        ("border-radius", "8px")])
      paint(ctx, box, "background-color", "color.surface.card")
      border(ctx, box)
      let kv = el(ctx, n, "mailKeyValue", attrs = [("caption",
        ip.description.strip())])
      let first = el(ctx, n, "mailKeyValueRow", attrs = [("label",
        p.item_label)])
      var bare = ip
      bare.thumb = ""
      for part in descriptionCell(ctx, n, bare, p.thumb_width):
        add(ctx, first, part)
      add(ctx, kv, first)
      if ip.qty.strip().len > 0:
        add(ctx, kv, el(ctx, n, "mailKeyValueRow", attrs = [("label",
          p.qty_label)], text = ip.qty.strip()))
      add(ctx, kv, el(ctx, n, "mailKeyValueRow", attrs = [("label",
        p.amount_label), ("emphasis", "true")], text = ip.amount.strip()))
      if ip.thumb.strip().len > 0:
        # The thumbnail beside the card's list, never in a value.
        let sb = el(ctx, n, "mailSidebar", attrs = [("side", "left"),
          ("fixed", $p.thumb_width & "px"), ("valign", "top"),
          ("switch_below", "0")], styles = [("gap", "tok:space.3")])
        let alt = ip.thumb_alt.strip()
        let img = el(ctx, n, "mailImage", attrs = [("src", ip.thumb.strip()),
          ("decorative", if alt.len == 0: "true" else: "")],
          styles = [("width", $p.thumb_width & "px")])
        ctx.r.setAttribute(img, "alt", alt)
        add(ctx, sb, img, kv)
        add(ctx, box, sb)
      else:
        add(ctx, box, kv)
      add(ctx, result, box)
    return
  result = el(ctx, n, "mailTable", attrs = [("caption", p.caption.strip()),
    ("mobile", "keep")])
  # No quantities, no quantity column.
  var withQty = false
  for ip in props:
    if ip.qty.strip().len > 0:
      withQty = true
  # The outer cells are flush with the text around the table (no
  # padding on the table's outer edges).
  let first = if start == "left": "8px 12px 8px 0" else: "8px 0 8px 12px"
  let last = if start == "left": "8px 0 8px 12px" else: "8px 12px 8px 0"
  let table = el(ctx, n, "table")
  let head = el(ctx, n, "thead")
  let hr = el(ctx, n, "tr")
  add(ctx, hr, el(ctx, n, "th", attrs = [("scope", "col"), ("align", start)],
    styles = [("text-align", start), ("padding", first)],
    text = p.item_label))
  var labels = @[p.amount_label]
  if withQty:
    labels.insert(p.qty_label, 0)
  for i, label in labels:
    add(ctx, hr, el(ctx, n, "th", attrs = [("scope", "col"),
      ("align", stop)], styles = [("text-align", stop),
        ("white-space", "nowrap"),
        ("padding", if i == labels.high: last else: "8px 12px")],
      text = label))
  add(ctx, head, hr)
  let body = el(ctx, n, "tbody")
  for ip in props:
    let tr = el(ctx, n, "tr")
    let d = el(ctx, n, "td", styles = [("padding", first)])
    for part in descriptionCell(ctx, n, ip, p.thumb_width):
      add(ctx, d, part)
    add(ctx, tr, d)
    var values = @[ip.amount.strip()]
    if withQty:
      values.insert(ip.qty.strip(), 0)
    for i, v in values:
      add(ctx, tr, el(ctx, n, "td", attrs = [("align", stop)],
        styles = [("text-align", stop), ("white-space", "nowrap"),
          ("padding", if i == values.high: last else: "8px 12px")],
        text = v))
    add(ctx, body, tr)
  add(ctx, table, head, body)
  add(ctx, result, table)

proc lineItemsExpected(n: EmailNode; p: LineItemsProps;
    view: BriefView): seq[string] =
  var names: seq[string] = @[]
  for c in slot(n):
    if c.kind == enElement:
      names.add(quoted(c.attrs.getOrDefault("description", "")))
  if p.mobile == "cards":
    return @["Line items as cards: " & $names.len & " bordered cards, one " &
      "under another (" & names.join(", ") & "), each listing Item, Qty " &
      "and Amount as label and value on one line, the amount bold."]
  var withQty, withDetail = false
  for c in slot(n):
    if c.kind == enElement:
      if c.attrs.getOrDefault("qty", "").strip().len > 0:
        withQty = true
      if c.attrs.getOrDefault("detail", "").strip().len > 0:
        withDetail = true
  let cols = if withQty: "3 columns (" & p.item_label & " | " & p.qty_label &
      " | " & p.amount_label & ")"
    else: "2 columns (" & p.item_label & " | " & p.amount_label & ")"
  @["Line items: a table of " & cols & " with a bold header row and " &
    $names.len & " rows (" & names.join(", ") & ")" &
    (if withDetail: ", a detail in smaller grey text under a description"
     else: "") & "; " & (if withQty: "quantities and amounts" else:
       "amounts") & " aligned to the " & endSide(n) & " edge, never " &
    "wrapped; the table's outer text flush with the text around it; " &
    "nothing cut off or past the message's edge at any width."]

# --- mailStatTiles ---------------------------------------------------------------

proc statColours*(tone: string): tuple[fg, bg: string] =
  ## The theme keys of a stat tile's number and background.
  case tone
  of "neutral": ("color.text.primary", "color.surface.subtle")
  of "primary": ("color.accent.primary", "color.surface.subtle")
  else: ("color.status." & tone, "color.status." & tone & ".bg")

proc statTilesExpand(n: EmailNode; p: StatTilesProps;
    ctx: ExpandCtx): EmailNode =
  let items = slotOf(n, ["mailStat"], "mailStat items")
  if items.len < statsMin or items.len > statsMax:
    raise newException(PatternError, "mailStatTiles holds " & $statsMin &
      " to " & $statsMax & " mailStat items (found " & $items.len & ")")
  var stats: seq[StatProps] = @[]
  for it in items:
    let sp = readProps[StatProps](it)
    discard required(it, sp.value, "a value", "a stat is a number")
    discard required(it, sp.label, "a label", "a number says what it counts")
    discard oneOf(it, sp.tone, "tone", ["neutral", "primary", "info",
      "success", "warning", "danger"])
    stats.add(sp)
  for it in items:
    ctx.r.removeChild(n, it)
  proc fill(holder: EmailNode; sp: StatProps) =
    let (fg, _) = statColours(sp.tone.strip().toLowerAscii())
    # The number and its unit are one text node (screen readers read
    # them together).
    # Three tiles share a phone's width: a smaller number.
    let three = stats.len == 3
    let v = el(ctx, n, "p", styles = [("margin", "0"),
      ("font-size", if three: "24px" else: "28px"),
      ("line-height", if three: "30px" else: "34px"), ("font-weight", "700"),
      ("text-align", "center")], text = sp.value.strip())
    paint(ctx, v, "color", fg)
    let l = el(ctx, n, "p", styles = [("margin", "0"),
      ("text-align", "center")], text = sp.label.strip())
    useType(ctx, l, "type.small")
    paint(ctx, l, "color", "color.text.secondary")
    add(ctx, holder, v, l)
  var html: EmailNode
  if stats.len <= 3:
    # The tile is its column's cell: the cells share a height.
    html = el(ctx, n, "mailColumns", attrs = [("strategy", "cells"),
      ("gutter", "12px"), ("valign", "middle")])
    for sp in stats:
      let (_, bg) = statColours(sp.tone.strip().toLowerAscii())
      let col = el(ctx, n, "mailColumn", attrs = [("vertical_align",
        "middle")], styles = [("padding", "16px 4px"),
          ("border-radius", "8px"), ("min_width", statMinWidth)])
      paint(ctx, col, "background-color", bg)
      fill(col, sp)
      add(ctx, html, col)
  else:
    html = el(ctx, n, "mailGrid", attrs = [("columns", "4"),
      ("mobile_columns", "2"), ("gutter", "12px"),
      ("min_item", statMinWidth)])
    for sp in stats:
      let (_, bg) = statColours(sp.tone.strip().toLowerAscii())
      let box = el(ctx, n, "mailBox", styles = [("padding", "16px 4px"),
        ("border-radius", "8px")])
      paint(ctx, box, "background-color", bg)
      fill(box, sp)
      add(ctx, html, box)
  var lines: seq[string] = @[]
  for sp in stats:
    lines.add(sp.label.strip() & ": " & sp.value.strip())
  htmlAndText(ctx, n, html, [linesPara(ctx, n, lines)])

proc statTilesExpected(n: EmailNode; p: StatTilesProps;
    view: BriefView): seq[string] =
  var parts: seq[string] = @[]
  for c in slot(n):
    if c.kind == enElement:
      parts.add("\"" & c.attrs.getOrDefault("value", "") & "\" over \"" &
        c.attrs.getOrDefault("label", "") & "\"")
  let count = parts.len
  let perRow = if count == 4 and not view.word and
      ((view.headCss and view.mediaQueries and view.narrow) or
       (not (view.headCss and view.mediaQueries))): 2 else: count
  @["Stat tiles: " & $count & " tinted tiles with rounded corners (" &
    parts.join(", ") & "), " & $perRow & " per row at this width" &
    (if count <= 3: ", side by side at every width and of equal height"
     else: "") & "; each a large bold number centred above its small " &
    "grey label."]

proc statTilesDegradations(n: EmailNode; p: StatTilesProps;
    view: BriefView): seq[string] =
  var count = 0
  for c in slot(n):
    if c.kind == enElement:
      inc count
  if view.word:
    result.add("Word draws the tiles' corners square (R-TBL-16)")
  if count == 4 and not view.word:
    result.add("the four tiles' heights follow their own labels: a label " &
      "that wraps makes its tile taller than its neighbours (R-TBL-10)")

# --- mailStepper -----------------------------------------------------------------

proc stepExpand(n: EmailNode; p: StepProps; ctx: ExpandCtx): EmailNode =
  ## A step becomes its label, where its stepper placed it.
  result = el(ctx, n, "span")
  let kids = n.children # Copy: appendChild detaches as it moves.
  moveInto(ctx, result, kids)

proc stepLabels*(n: EmailNode): seq[string] =
  ## The labels of a stepper's steps, in order, wherever they sit (its
  ## content, or its expansion's label row).
  proc walk(x: EmailNode; acc: var seq[string]) =
    if x.kind != enElement:
      return
    if x.tag == "mailStep":
      acc.add(plainText(x))
      return
    for c in x.children:
      walk(c, acc)
  for c in n.children:
    walk(c, result)

proc stepperLines*(labels: seq[string]; current: int):
    tuple[status, text: string] =
  ## The status line and the text-part line, "" when `current` names no
  ## step or its step has no label.
  let m = labels.len
  if current < 1 or current > m or labels[current - 1].len == 0:
    return ("", "")
  let label = labels[current - 1]
  result.status = "Current step: " & label & " (" & $current & " of " &
    $m & ")"
  result.text = "Step " & $current & " of " & $m & ": " & label & "."
  if current < m and labels[current].len > 0:
    result.text.add(" Next: " & labels[current] & ".")

proc connector(ctx: ExpandCtx; n: EmailNode; done: bool): EmailNode =
  ## Half a connector: a 2px line, a sized `bgcolor` cell in a table of
  ## its own (a cell in the marker's row would be the marker's height).
  result = el(ctx, n, "td", attrs = [("valign", "middle")],
    styles = [("padding", "0"), ("vertical-align", "middle")])
  let t = layoutTable(ctx, n)
  let tr = el(ctx, n, "tr")
  let line = spacerCell(ctx, n, [("height", $stepConnectorPx)],
    [("height", $stepConnectorPx & "px")])
  paint(ctx, line, "background-color",
    if done: "color.accent.primary" else: "color.border.subtle")
  add(ctx, tr, line)
  add(ctx, t, tr)
  add(ctx, result, t)

proc stepperExpand(n: EmailNode; p: StepperProps;
    ctx: ExpandCtx): EmailNode =
  let steps = slotOf(n, ["mailStep"], "mailStep items")
  if steps.len < stepperMin:
    raise newException(PatternError, "mailStepper needs " & $stepperMin &
      " to " & $stepperMax & " steps (found " & $steps.len & ")")
  var labels: seq[string] = @[]
  for s in steps:
    labels.add(plainText(s))
  let m = steps.len
  let cur = p.current
  let (status0, text0) = stepperLines(labels, cur)
  let status = if p.status.strip().len > 0: p.status.strip() else: status0
  let line = if p.text.strip().len > 0: p.text.strip() else: text0
  let share = formatFloat(100.0 / float(m), ffDecimal, 2)
    .strip(leading = false, chars = {'0'}).strip(leading = false,
      chars = {'.'}) & "%"
  let table = layoutTable(ctx, n, [("table-layout", "fixed")])
  # Row 1: the markers, each between its connectors' halves.
  let markers = el(ctx, n, "tr")
  for i in 0 ..< m:
    let k = i + 1
    let td = el(ctx, n, "td", attrs = [("width", share), ("align", "center"),
      ("valign", "middle"), ("aria-hidden", "true")],
      styles = [("width", share), ("padding", "0")])
    let inner = layoutTable(ctx, n, [("border-collapse",
      "separate !important")])
    let tr = el(ctx, n, "tr")
    if i > 0:
      add(ctx, tr, connector(ctx, n, k <= cur))
    else:
      add(ctx, tr, spacerCell(ctx, n))
    let state = if k < cur: "done" elif k == cur: "current" else: "next"
    let size = if state == "next": stepMarkerPx - 2 * stepConnectorPx
      else: stepMarkerPx
    let marker = el(ctx, n, "td", attrs = [("width", $size),
      ("height", $size), ("align", "center"), ("valign", "middle")],
      styles = [("width", $size & "px"), ("height", $size & "px"),
        ("padding", "0"), ("border-radius", $(size div 2) & "px"),
        ("text-align", "center"), ("vertical-align", "middle"),
        ("font-size", "14px"), ("line-height", $size & "px"),
        ("font-weight", "700")],
      text = if state == "done": doneGlyph else: $k)
    if state == "next":
      paint(ctx, marker, "background-color", "color.surface.card")
      paint(ctx, marker, "color", "color.text.secondary")
      border(ctx, marker, width = $stepConnectorPx & "px")
    else:
      paint(ctx, marker, "background-color", "color.accent.primary")
      paint(ctx, marker, "color", "color.accent.primaryText")
    add(ctx, tr, marker)
    if i < m - 1:
      add(ctx, tr, connector(ctx, n, k + 1 <= cur))
    else:
      add(ctx, tr, spacerCell(ctx, n))
    add(ctx, inner, tr)
    add(ctx, td, inner)
    add(ctx, markers, td)
  # Row 2: the labels, each centred under its marker.
  let names = el(ctx, n, "tr")
  for i, s in steps:
    let td = el(ctx, n, "td", attrs = [("width", share), ("align", "center"),
      ("valign", "top")], styles = [("width", share),
        ("padding", "8px 0 0"), ("text-align", "center"),
        ("vertical-align", "top")])
    let para = el(ctx, n, "p", styles = [("margin", "0"),
      ("text-align", "center"),
      ("font-weight", if i + 1 == cur: "700" else: "400")])
    useType(ctx, para, "type.small")
    paint(ctx, para, "color", if i + 1 <= cur: "color.text.primary"
      else: "color.text.secondary")
    add(ctx, para, s)
    add(ctx, td, para)
    add(ctx, names, td)
  add(ctx, table, markers, names)
  let html = el(ctx, n, "div")
  if status.len > 0:
    add(ctx, html, visuallyHidden(ctx, n, status))
  add(ctx, html, table)
  htmlAndText(ctx, n, html, [el(ctx, n, "p", text = line)])

proc stepperExpected(n: EmailNode; p: StepperProps;
    view: BriefView): seq[string] =
  var labels: seq[string] = @[]
  for c in slot(n):
    if c.kind == enElement:
      labels.add(quoted(textOf(c)))
  @["Stepper: " & $labels.len & " numbered circles in one row, joined by " &
    "thin lines from circle to circle, with their labels (" &
    labels.join(", ") & ") centred under them, never stacked or wrapped " &
    "into two rows; steps before step " & $p.current & " show a check " &
    "mark, step " & $p.current & " is filled and its label bold, later " &
    "steps are outlined circles with grey numbers; the line is coloured " &
    "up to the current step and grey after it. Nothing overflows at any " &
    "width."]

proc stepperDegradations(n: EmailNode; p: StepperProps;
    view: BriefView): seq[string] =
  var steps = 0
  for c in slot(n):
    if c.kind == enElement:
      inc steps
  if steps >= 5 and view.width < 480:
    result.add("five steps share a phone's width, about 60px each: a " &
      "label word longer than that (\"confirmed\", \"warehouse\") breaks " &
      "inside its step rather than overflow it (layout-patterns.md §4.4: " &
      "keep labels short)")
  if view.word:
    result.add("Word draws the step markers as squares, not circles " &
      "(border-radius, R-TBL-16)")

# --- mailTimeline ---------------------------------------------------------------

proc timelineExpand(n: EmailNode; p: TimelineProps;
    ctx: ExpandCtx): EmailNode =
  let events = slotOf(n, ["mailTimelineEvent"], "mailTimelineEvent items")
  if events.len == 0:
    raise newException(PatternError, "mailTimeline needs at least one " &
      "mailTimelineEvent")
  var times: seq[string] = @[]
  for ev in events:
    times.add(required(ev, readProps[TimelineEventProps](ev).time,
      "a time", "an event says when it happened"))
  let rtl = isRtl(n)
  let side = (timelineDotPx - timelineLinePx) div 2
  let r = $(timelineDotPx div 2) & "px"
  # Fixed layout, inline: where head CSS is stripped (and with it the
  # reset's), an auto-layout table would let an unbroken word in the
  # text cell widen the table past a phone and squeeze the track's
  # cells to nothing; fixed, the track keeps its widths and the word
  # breaks in its cell.
  let table = layoutTable(ctx, n, [("border-collapse",
    "separate !important"), ("table-layout", "fixed")])
  var lines: seq[string] = @[]
  for i, ev in events:
    let last = i == events.high
    let content = slot(ev)
    var said = ""
    for c in content:
      let t = plainText(c)
      if t.len > 0:
        if said.len > 0:
          said.add(' ')
        said.add(t)
    lines.add(times[i] & " — " & said)
    # The event's first row: the dot (three painted cells, the outer two
    # rounded) beside the time.
    let a = el(ctx, n, "tr")
    # The dot's outer cells are rounded on their outer side (the start
    # cell on the start side: mirrored right to left).
    for (w, round) in [(side, if rtl: "right" else: "left"),
        (timelineLinePx, ""), (side, if rtl: "left" else: "right")]:
      let dot = spacerCell(ctx, n, [("width", $w), ("height",
        $timelineDotPx)], [("width", $w & "px"),
          ("height", $timelineDotPx & "px")])
      if round.len > 0:
        ctx.r.setStyle(dot, "border-top-" & round & "-radius", r)
        ctx.r.setStyle(dot, "border-bottom-" & round & "-radius", r)
      paint(ctx, dot, "background-color", "color.accent.primary")
      add(ctx, a, dot)
    add(ctx, a, spacerCell(ctx, n, [("width", $timelineGapPx)],
      [("width", $timelineGapPx & "px")]))
    let time = el(ctx, n, "td", attrs = [("valign", "middle")],
      styles = [("padding", "0"), ("vertical-align", "middle"),
        ("font-size", "14px"), ("line-height", $timelineDotPx & "px"),
        ("font-weight", "700"), ("white-space", "nowrap")],
      text = times[i])
    paint(ctx, time, "color", "color.text.secondary")
    add(ctx, a, time)
    # Its second row: the line (none after the last event) beside the
    # text.
    let b = el(ctx, n, "tr")
    add(ctx, b, spacerCell(ctx, n, [("width", $side)],
      [("width", $side & "px")]))
    let lineCell = spacerCell(ctx, n, [("width", $timelineLinePx)],
      [("width", $timelineLinePx & "px")])
    if not last:
      paint(ctx, lineCell, "background-color", "color.border.subtle")
    add(ctx, b, lineCell)
    add(ctx, b, spacerCell(ctx, n, [("width", $side)],
      [("width", $side & "px")]))
    add(ctx, b, spacerCell(ctx, n, [("width", $timelineGapPx)],
      [("width", $timelineGapPx & "px")]))
    let text = el(ctx, n, "td", attrs = [("valign", "top")],
      styles = [("padding", if last: "4px 0 0" else: "4px 0 20px"),
        ("vertical-align", "top")])
    moveInto(ctx, text, content)
    add(ctx, b, text)
    add(ctx, table, a, b)
  for ev in events:
    ctx.r.removeChild(n, ev)
  htmlAndText(ctx, n, table, [linesPara(ctx, n, lines)])

proc timelineExpected(n: EmailNode; p: TimelineProps;
    view: BriefView): seq[string] =
  var times: seq[string] = @[]
  for c in slot(n):
    if c.kind == enElement:
      times.add("\"" & c.attrs.getOrDefault("time", "") & "\"")
  @["Timeline: " & $times.len & " events one under another (" &
    times.join(", ") & "), each a round dot at the " & startSide(n) &
    " beside its time in bold grey, its text under the time; a thin grey " &
    "line runs down from each dot to the next without a break, and none " &
    "below the last."]

proc timelineDegradations(n: EmailNode; p: TimelineProps;
    view: BriefView): seq[string] =
  if view.word:
    result.add("Word draws the timeline's dots square (border-radius, " &
      "R-TBL-16)")

# --- mailEvent ------------------------------------------------------------------

proc eventExpand(n: EmailNode; p: EventProps; ctx: ExpandCtx): EmailNode =
  let month = required(n, p.month, "a month", "the date tile's first row")
  let day = required(n, p.day, "a day", "the date tile's number")
  result = el(ctx, n, "mailSidebar", attrs = [("side", "left"),
    ("fixed", $eventTilePx & "px"), ("valign", "top"),
    ("switch_below", "0")], styles = [("gap", "tok:space.4")])
  # The tile is decoration: the date line says the date in full.
  let tile = el(ctx, n, "mailBox", styles = [("padding", "0"),
    ("border-radius", "8px")])
  paint(ctx, tile, "background-color", "color.surface.card")
  border(ctx, tile)
  let m = el(ctx, n, "p", attrs = [("aria-hidden", "true")],
    styles = [("margin", "0"), ("padding", "4px 0"), ("font-size", "12px"),
      ("line-height", "16px"), ("font-weight", "700"),
      ("text-align", "center"), ("letter-spacing", "1px"),
      ("border-top-left-radius", "7px"), ("border-top-right-radius", "7px")],
      text = unicode.toUpper(month))
  paint(ctx, m, "background-color", "color.accent.primary")
  paint(ctx, m, "color", "color.accent.primaryText")
  let d = el(ctx, n, "p", attrs = [("aria-hidden", "true")],
    styles = [("margin", "0"), ("padding", "2px 0 4px"),
      ("font-size", "28px"), ("line-height", "40px"),
      ("font-weight", "700"), ("text-align", "center")], text = day)
  add(ctx, tile, m, d)
  let tileHtml = el(ctx, n, "htmlOnly")
  add(ctx, tileHtml, tile)
  let stack = el(ctx, n, "mailStack", styles = [("gap", "tok:space.2")])
  let details = slot(n)
  if details.len > 0:
    let dv = el(ctx, n, "div")
    moveInto(ctx, dv, details)
    add(ctx, stack, dv)
  if p.date_text.strip().len > 0:
    add(ctx, stack, el(ctx, n, "p", styles = [("margin", "0"),
      ("font-weight", "700")], text = p.date_text.strip()))
  if p.location.strip().len > 0:
    add(ctx, stack, el(ctx, n, "p", styles = [("margin", "0")],
      text = p.location.strip()))
  var links: seq[EmailNode] = @[]
  for (href, label) in [(p.google, p.google_label),
      (p.outlook, p.outlook_label), (p.ics, p.ics_label)]:
    if href.strip().len > 0:
      links.add(el(ctx, n, "a", attrs = [("href", href.strip())],
        text = label.strip()))
  if links.len > 0:
    let row = el(ctx, n, "mailCluster", attrs = [("align", startSide(n))],
      styles = [("gap", "tok:space.4"), ("row-gap", "8px")])
    moveInto(ctx, row, links)
    add(ctx, stack, row)
  add(ctx, result, tileHtml, stack)

proc eventExpected(n: EmailNode; p: EventProps;
    view: BriefView): seq[string] =
  var links: seq[string] = @[]
  for (href, label) in [(p.google, p.google_label),
      (p.outlook, p.outlook_label), (p.ics, p.ics_label)]:
    if href.len > 0:
      links.add("\"" & label & "\"")
  @["Event: a 64px date tile at the " & startSide(n) & " (a coloured " &
    "band with \"" & unicode.toUpper(p.month.strip()) & "\" above a large " &
    "\"" & p.day.strip() & "\", rounded, bordered) beside the details" &
    (if slot(n).len > 0: " " & quoted(textOf(n)) else: "") &
    ", the date line \"" & p.date_text.strip() & "\" in bold" &
    (if p.location.len > 0: ", the location \"" & p.location.strip() & "\""
     else: "") &
    (if links.len > 0: ", and the links " & links.join(", ") & " in a row"
     else: "") & "; the tile and the details side by side at every width."]

proc eventDegradations(n: EmailNode; p: EventProps;
    view: BriefView): seq[string] =
  if view.word:
    result.add("Word draws the date tile's corners square (R-TBL-16)")

# --- Registration -------------------------------------------------------------------

defineMailPattern(mailKeyValue, KeyValueProps, keyValueExpand,
  keyValueExpected, noLines[KeyValueProps])
defineMailPattern(mailLineItems, LineItemsProps, lineItemsExpand,
  lineItemsExpected, noLines[LineItemsProps])
defineMailPattern(mailStatTiles, StatTilesProps, statTilesExpand,
  statTilesExpected, statTilesDegradations)
defineMailPattern(mailStepper, StepperProps, stepperExpand, stepperExpected,
  stepperDegradations)
defineMailPattern(mailStep, StepProps, stepExpand, noLines[StepProps],
  noLines[StepProps])
defineMailPattern(mailTimeline, TimelineProps, timelineExpand,
  timelineExpected, timelineDegradations)
defineMailPattern(mailEvent, EventProps, eventExpand, eventExpected,
  eventDegradations)
