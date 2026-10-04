## The container and data patterns: what each expands into, its
## plain-text form, its accessibility obligations and its own
## diagnostics (layout-patterns.md §4.3: `mailCard`, `mailCallout`,
## `mailCodeBlock`, `codeInline`, `mailQuote`; §4.4: `mailKeyValue`,
## `mailLineItems`, `mailStatTiles`, `mailStepper`, `mailTimeline`,
## `mailEvent`), and the checks they brought: text on its own element's
## background, the stepper's and timeline's own tables (R-TBL-01) and
## their visually hidden status line.
##
## Every test renders a hand-built tree through the full pipeline
## (`renderTree`). Backend-independent (tree building + pure passes), so
## `just test` also runs it on JS. No test doubles.
import std/[sequtils, strutils, tables, unittest]
import isonim_email

const photo = "https://cdn.example.com/a/photo.png"

proc el(r: EmailRenderer; parent: EmailNode; tag: string;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

proc newDoc(r: EmailRenderer; rtl = false): (EmailNode, EmailNode) =
  ## A document and its first section, with an `h1` and an `h2` (so an
  ## `h3` follows without a skipped level).
  let doc = r.el(nil, "mailDocument", [("lang", if rtl: "ar" else: "en"),
    ("dir", if rtl: "rtl" else: "ltr"), ("title", "Patterns")])
  let s = r.el(doc, "mailSection")
  discard r.el(s, "h1", text = "Patterns")
  discard r.el(s, "h2", text = "Section")
  (doc, s)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc find(n: EmailNode; tag: string): EmailNode =
  if n == nil:
    return nil
  if n.kind == enElement and n.tag == tag:
    return n
  for c in n.children:
    let f = find(c, tag)
    if f != nil:
      return f
  nil

proc findAll(n: EmailNode; tag: string; acc: var seq[EmailNode]) =
  if n.kind == enElement and n.tag == tag:
    acc.add(n)
  for c in n.children:
    findAll(c, tag, acc)

proc all(n: EmailNode; tag: string): seq[EmailNode] =
  findAll(n, tag, result)

proc body(text: string): string =
  ## The text part after the document's two headings.
  let at = text.find("Section\n-------\n\n")
  if at < 0: text else: text[at + "Section\n-------\n\n".len .. ^1]

proc borderKeys(n: EmailNode): seq[string] =
  ## The border declarations of `n`, its radius aside.
  for k in n.styles.keys:
    if k.startsWith("border") and "radius" notin k:
      result.add(k)

proc designed(): EmailTarget =
  result = defaultTarget()
  result.darkMode = dmDesigned

# --- mailCard --------------------------------------------------------------------

proc cardDoc(attrs: openArray[(string, string)]): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc()
  let c = r.el(s, "mailCard", attrs)
  discard r.el(c, "p", text = "Its body.")
  renderTree(doc)

suite "mailCard":
  test "test_card_is_a_box_of_its_parts":
    # rule: R-TBL-09
    let res = cardDoc([("title", "A card"), ("image", photo),
      ("image_alt", "A photo"), ("cta", "Open"),
      ("cta_href", "https://example.com/open"), ("variant", "elevated")])
    check not hasErrors(res.diagnostics)
    let box = res.semantic.find("mailCard").find("mailBox")
    require box != nil
    check box.attrs["shadow"] == "sm"
    check box.borderKeys.len > 0
    let stack = box.find("mailStack")
    let parts = stack.children.filterIt(it.kind == enElement).mapIt(it.tag)
    check parts == @["htmlOnly", "h3", "div", "mailButton"]
    check "box-shadow:0 1px 3px" in res.html
    check "border:1px solid #e5e7eb" in res.html
    # Text: the title underlined, the body, the CTA; never the image.
    check res.text.body == "A card\n------\n\nIts body.\n\n" &
      "Open: https://example.com/open\n"
    check "photo" notin res.text
    # The heading level is the context's; a plain card has no border.
    let plain = cardDoc([("title", "A card"), ("level", "h2"),
      ("variant", "plain")])
    check not hasErrors(plain.diagnostics)
    check plain.semantic.find("mailCard").find("h2") != nil
    check plain.semantic.find("mailCard").find("mailBox").borderKeys.len == 0
    check "border:1px solid" notin plain.html
    check plain.text.body.startsWith("A card\n------\n\nIts body.\n")

  test "test_card_props_are_checked":
    check codeVocabBadValue in codesOf(cardDoc([("variant",
      "shiny")]).diagnostics)
    check codeVocabBadValue in codesOf(cardDoc([("level", "h1")]).diagnostics)
    # A CTA needs its destination.
    check codeVocabBadValue in codesOf(cardDoc([("cta", "Open")]).diagnostics)
    check codeVocabBadValue notin codesOf(cardDoc([("cta", "Open"),
      ("cta_href", "https://example.com/")]).diagnostics)

# --- mailCallout -----------------------------------------------------------------

proc calloutDoc(attrs: openArray[(string, string)]; rtl = false;
    t = defaultTarget()): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  let c = r.el(s, "mailCallout", attrs)
  discard r.el(c, "p", text = "Its body.")
  renderTree(doc, target = t)

suite "mailCallout":
  test "test_callout_title_starts_with_the_tone_word":
    let res = calloutDoc([("tone", "warning"), ("title", "Disk almost full")])
    check not hasErrors(res.diagnostics)
    check ">Warning: Disk almost full</p>" in res.html
    check res.text.body == "WARNING: Disk almost full\nIts body.\n"
    # A title that already carries the word is not prefixed again.
    let carried = calloutDoc([("tone", "warning"),
      ("title", "Warning: disk almost full")])
    check ">Warning: disk almost full</p>" in carried.html
    check "Warning: Warning" notin carried.html
    check carried.text.body.startsWith("WARNING: disk almost full\n")
    # Without a title, the tone word alone; a label replaces the word.
    check ">Error</p>" in calloutDoc([("tone", "danger")]).html
    check calloutDoc([("tone", "danger")]).text.body.startsWith("ERROR\n")
    let own = calloutDoc([("tone", "info"), ("label", "Heads up"),
      ("title", "New region")])
    check ">Heads up: New region</p>" in own.html
    check own.text.body.startsWith("HEADS UP: New region\n")
    check codeVocabBadValue in codesOf(calloutDoc([("tone",
      "loud")]).diagnostics)

  test "test_callout_accent_is_a_painted_cell":
    # rule: R-TBL-10
    let res = calloutDoc([("tone", "warning"), ("title", "Careful")])
    let sb = res.semantic.find("mailCallout").find("mailSidebar")
    require sb != nil
    check sb.attrs["fixed"] == "4px" and sb.attrs["switch_below"] == "0"
    # The accent paints its whole cell (the row's height), never a
    # border-left; the panel is the tone's background.
    check "<td width=\"4\" valign=\"top\" bgcolor=\"#9a6700\"" in res.html
    check "border-left" notin res.html
    check "background-color:#fff8c5" in res.html
    # Right to left the accent is on the right: the row is `rtl`.
    let rtl = calloutDoc([("tone", "warning"), ("label", "تحذير")],
      rtl = true)
    check not hasErrors(rtl.diagnostics)
    check "dir=\"rtl\"" in rtl.html
    # Designed dark: the accent and the panel take their dark pairs.
    let dark = calloutDoc([("tone", "warning")], t = designed())
    check not hasErrors(dark.diagnostics)
    check "#d29922" in dark.html and "#3d2e00" in dark.html

# --- mailCodeBlock / codeInline -------------------------------------------------------

suite "mailCodeBlock and codeInline":
  test "test_code_block_wraps_and_keeps_its_indentation":
    let r = EmailRenderer()
    let (doc, s) = r.newDoc()
    let c = r.el(s, "mailCodeBlock")
    r.appendChild(c, r.createTextNode("\nproc main() =\n  if ok:\n\techo " &
      "\"hi\"\n"))
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let pre = res.html.split("<pre")[1].split("</pre>")[0]
    check "white-space:pre-wrap;word-break:break-word;" &
      "overflow-wrap:anywhere;" in pre
    check "&#x27;Courier New&#x27;, monospace" in pre
    check "overflow-x" notin res.html and "overflow:scroll" notin res.html
    # Left to right, at the start of its line, in any message.
    check "<pre dir=\"ltr\"" in res.html
    check "direction:ltr;text-align:left;" in pre
    # Leading indentation is no-break spaces (a tab four of them); the
    # newline after `<pre>` is dropped.
    check ">proc main() =\n\u00a0\u00a0if ok:\n\u00a0\u00a0\u00a0\u00a0echo" in
      pre.replace("&nbsp;", "\u00a0")
    # Text: the code verbatim, indented four spaces.
    check res.text.body == "    proc main() =\n      if ok:\n        echo " &
      "\"hi\"\n"
    # Block content is refused.
    let r2 = EmailRenderer()
    let (doc2, s2) = r2.newDoc()
    discard r2.el(r2.el(s2, "mailCodeBlock"), "p", text = "x")
    check codeVocabBadValue in codesOf(renderTree(doc2).diagnostics)

  test "test_code_inline_is_code_in_the_line":
    let r = EmailRenderer()
    let (doc, s) = r.newDoc()
    let p = r.el(s, "p", text = "Run ")
    discard r.el(p, "codeInline", text = "just test")
    r.appendChild(p, r.createTextNode(" first."))
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    check "<code dir=\"ltr\" style=\"" in res.html
    let code = res.html.split("<code")[1].split("</code>")[0]
    check "background-color:#e5e7eb" in code
    check "word-break:break-word" in code
    check "Menlo, Consolas, &#x27;Courier New&#x27;, monospace" in code
    check res.text.body == "Run just test first.\n"

# --- mailQuote -----------------------------------------------------------------------

proc quoteDoc(attrs: openArray[(string, string)]): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc()
  let q = r.el(s, "mailQuote", attrs)
  r.appendChild(q, r.createTextNode("It just works."))
  renderTree(doc)

suite "mailQuote":
  test "test_quote_is_quoted_and_attributed":
    let res = quoteDoc([("name", "Ada Lovelace"), ("role", "CTO, Acme")])
    check not hasErrors(res.diagnostics)
    check "“It just works.”" in res.html
    check "<blockquote" notin res.html
    check res.text.body == "“It just works.”\n\n— Ada Lovelace, CTO, Acme\n"
    # The large glyph is decoration, hidden from screen readers, and
    # replaces the inline marks; the text part keeps them.
    let glyph = quoteDoc([("name", "Ada"), ("glyph", "true")])
    check not hasErrors(glyph.diagnostics)
    check "aria-hidden=\"true\"" in glyph.html.split("“")[0].split(
      "<p")[^1]
    check "“It just" notin glyph.html
    check glyph.text.body.startsWith("“It just works.”\n")
    # An avatar sits beside the name in a media object, decorative.
    let avatar = quoteDoc([("name", "Ada"), ("avatar", photo)])
    check not hasErrors(avatar.diagnostics)
    let m = avatar.semantic.find("mailMediaObject")
    check m != nil and m.attrs["stack"] == "never"
    check "alt=\"\"" in avatar.html
    check codeVocabBadValue in codesOf(quoteDoc([("role",
      "CTO")]).diagnostics)

# --- mailKeyValue ------------------------------------------------------------------

proc kvDoc(rows: openArray[(string, string)]; attrs: openArray[(string,
    string)] = [("caption", "Summary")]; rtl = false): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  let k = r.el(s, "mailKeyValue", attrs)
  for (label, value) in rows:
    discard r.el(k, "mailKeyValueRow", [("label", label)], text = value)
  renderTree(doc)

suite "mailKeyValue":
  test "test_key_value_text_is_label_value_lines":
    let res = kvDoc([("Subtotal", "$120.00"), ("Tax", "$12.00"),
      ("Total", "$132.00")], [("caption", "Summary"), ("total_row", "true")])
    check not hasErrors(res.diagnostics)
    # `label: value` lines, written by the pattern: the table walk would
    # write `Subtotal | $120.00`.
    check res.text.body == "Subtotal: $120.00\nTax: $12.00\nTotal: $132.00\n"
    check "|" notin res.text

  test "test_key_value_is_a_real_table_with_row_headers":
    # rule: R-A11Y-09
    let long = "Paid with the card ending 4242 on 3 October"
    let res = kvDoc([("Subtotal", "$120.00"), ("Payment", long),
      ("Total", "$132.00")], [("caption", "Summary"), ("total_row", "true")])
    check not hasErrors(res.diagnostics)
    check "role=\"table\"" in res.html
    check res.html.count("<th scope=\"row\"") == 3
    check ">Summary</caption>" in res.html
    # A short label keeps its line.
    check "white-space:nowrap" in res.html.split("<th scope=\"row\"")[1].split(">")[0]
    # Short values never wrap; a long one does.
    let cells = res.html.split("<td align=\"right\"")
    check cells.len == 4
    check "white-space:nowrap" in cells[1].split(">")[0]
    check "white-space:nowrap" notin cells[2].split(">")[0]
    check "white-space:nowrap" in cells[3].split(">")[0]
    # The total row: bold under a rule; the others regular weight.
    check "font-weight:700;" in cells[3].split(">")[0]
    check "border-top-width:1px" in cells[3].split(">")[0]
    check "font-weight:400;" in cells[1].split(">")[0]
    # Never stacks.
    check "e-tbl-" notin res.html
    # Right to left the labels are on the right.
    let rtl = kvDoc([("المجموع", "١٠٠")], rtl = true)
    check "<th scope=\"row\" align=\"right\"" in rtl.html
    # A data table needs its caption.
    check codeA11yTableCaption in codesOf(kvDoc([("A", "1")], []).diagnostics)
    check codeVocabBadValue in codesOf(kvDoc([]).diagnostics)

# --- mailLineItems ------------------------------------------------------------------

proc itemsDoc(attrs: openArray[(string, string)]; thumb = false;
    rtl = false): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  var a = @[("caption", "Order 1042")]
  for x in attrs:
    a.add(x)
  let l = r.el(s, "mailLineItems", a)
  discard r.el(l, "mailLineItem", [("description", "Wireless keyboard"),
    ("detail", "SKU KB-42 · $49.00 each"), ("qty", "1"), ("amount", "$49.00"),
    ("thumb", if thumb: photo else: "")])
  discard r.el(l, "mailLineItem", [("description", "USB-C cable"),
    ("qty", "2"), ("amount", "$18.00")])
  renderTree(doc)

suite "mailLineItems":
  test "test_line_items_are_three_columns":
    # rule: R-TBL-18
    let res = itemsDoc([], thumb = true)
    check not hasErrors(res.diagnostics)
    let table = res.semantic.find("mailLineItems").find("table")
    require table != nil
    # At most three columns: the thumbnail is a sidebar inside the
    # description cell, never a fourth.
    for row in table.all("tr"):
      check row.children.filterIt(it.kind == enElement).len == 3
    check table.find("tbody").find("mailSidebar") != nil
    check table.find("mailTable") == nil
    check res.html.count("<th scope=\"col\"") == 3
    check res.html.count("white-space:nowrap") >= 6
    check res.semantic.find("mailTable").attrs["mobile"] == "keep"
    check "e-tbl-" notin res.html
    # Text: as a table; the detail in brackets after the description.
    check res.text.body == "Order 1042\nItem | Qty | Amount\n" &
      "Wireless keyboard (SKU KB-42 · $49.00 each) | 1 | $49.00\n" &
      "USB-C cable | 2 | $18.00\n"

  test "test_line_items_without_quantities_have_two_columns":
    let r = EmailRenderer()
    let (doc, s) = r.newDoc()
    let l = r.el(s, "mailLineItems", [("caption", "C")])
    discard r.el(l, "mailLineItem", [("description", "Lamp"),
      ("amount", "$9.00")])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    check res.html.count("<th scope=\"col\"") == 2
    check res.text.body == "C\nItem | Amount\nLamp | $9.00\n"
    # The outer cells are flush with the text around the table.
    check "padding:8px 12px 8px 0" in res.html
    check "padding:8px 0 8px 12px" in res.html

  test "test_line_items_as_cards":
    let res = itemsDoc([("mobile", "cards")])
    check not hasErrors(res.diagnostics)
    check res.semantic.find("mailLineItems").all("mailKeyValue").len == 2
    check "<th scope=\"col\"" notin res.html
    check "@media" notin res.html.split("</head>")[1]
    check res.text.body == "Item: Wireless keyboard (SKU KB-42 · $49.00 " &
      "each)\nQty: 1\nAmount: $49.00\n\nItem: USB-C cable\nQty: 2\n" &
      "Amount: $18.00\n"
    # A card's thumbnail sits beside its list, never in a value.
    let r0 = EmailRenderer()
    let (doc0, s0) = r0.newDoc()
    let l0 = r0.el(s0, "mailLineItems", [("caption", "C"),
      ("mobile", "cards")])
    discard r0.el(l0, "mailLineItem", [("description", "Lamp"),
      ("amount", "$9.00"), ("thumb", photo)])
    let thumbCard = renderTree(doc0)
    check not hasErrors(thumbCard.diagnostics)
    let side = thumbCard.semantic.find("mailBox").find("mailSidebar")
    check side != nil and side.find("mailKeyValue") != nil
    check codeVocabBadValue in codesOf(itemsDoc([("mobile",
      "stack")]).diagnostics)
    let r = EmailRenderer()
    let (doc, s) = r.newDoc()
    discard r.el(r.el(s, "mailLineItems", [("caption", "C")]),
      "mailLineItem", [("description", "No amount")])
    check codeVocabBadValue in codesOf(renderTree(doc).diagnostics)

# --- mailStatTiles ---------------------------------------------------------------

proc statsDoc(n: int; t = defaultTarget()): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc()
  let tiles = r.el(s, "mailStatTiles")
  for i in 1 .. n:
    discard r.el(tiles, "mailStat", [("value", $(i * 120) & " ms"),
      ("label", "Stat " & $i), ("tone", if i == 2: "success" else: "")])
  renderTree(doc, target = t)

suite "mailStatTiles":
  test "test_stat_tiles_are_cells_or_a_grid":
    # rule: R-TBL-11
    let three = statsDoc(3)
    check not hasErrors(three.diagnostics)
    check codeLayoutMinColumn notin codesOf(three.diagnostics)
    let cols = three.semantic.find("mailColumns")
    require cols != nil
    check cols.attrs["strategy"] == "cells"
    for c in cols.all("mailColumn"):
      check c.styles["min_width"] == "72px"
    # The number and its unit are one text node.
    check ">240 ms</p>" in three.html
    check "color:#1a7f37" in three.html and "#dafbe1" in three.html
    check three.text.body == "Stat 1: 120 ms\nStat 2: 240 ms\nStat 3: " &
      "360 ms\n"
    let four = statsDoc(4)
    check not hasErrors(four.diagnostics)
    let grid = four.semantic.find("mailGrid")
    check grid != nil and grid.attrs["columns"] == "4" and
      grid.attrs["mobile_columns"] == "2"
    check four.semantic.find("mailStatTiles").find("mailColumns") != nil
    check codeVocabBadValue in codesOf(statsDoc(1).diagnostics)
    check codeVocabBadValue in codesOf(statsDoc(5).diagnostics)

# --- mailStepper -----------------------------------------------------------------

proc stepperDoc(labels: openArray[string]; current: string;
    attrs: openArray[(string, string)] = []; rtl = false): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  var a = @attrs
  if current.len > 0:
    a.add(("current", current))
  let st = r.el(s, "mailStepper", a)
  for l in labels:
    discard r.el(st, "mailStep", text = l)
  renderTree(doc)

const fourSteps = ["Ordered", "Shipped", "Out for delivery", "Delivered"]

suite "mailStepper":
  test "test_stepper_requires_status_text":
    # Without its current step the status cannot be written.
    let missing = stepperDoc(fourSteps, "")
    check codesOf(missing.diagnostics).filterIt(it[0] == 'E') ==
      @[codePatternMissingText]
    check codePatternMissingText in codesOf(stepperDoc(fourSteps,
      "7").diagnostics)
    check codePatternMissingText in codesOf(stepperDoc(["Ordered", "",
      "Delivered"], "2").diagnostics)
    # With it: the text part's line and the hidden status line.
    let res = stepperDoc(fourSteps, "2")
    check not hasErrors(res.diagnostics)
    check codePatternMissingText notin codesOf(res.diagnostics)
    check "Step 2 of 4: Shipped. Next: Out for delivery.\n" in res.text
    check "Step 4 of 4: Delivered.\n" in stepperDoc(fourSteps, "4").text
    check ">Current step: Shipped (2 of 4)</p>" in res.html
    let hidden = res.html.split(">Current step:")[0].split("<p")[^1]
    check "position:absolute;width:1px;height:1px;" in hidden
    check "clip:rect(0 0 0 0);" in hidden
    # The labels are the HTML's; the text part has its one line.
    check "Ordered" notin res.text.body

  test "test_stepper_is_a_fixed_two_row_table":
    let res = stepperDoc(fourSteps, "3")
    check not hasErrors(res.diagnostics)
    # Its own table, which R-TBL-01 allows: no W-TBL-UNEXPECTED, and the
    # visually hidden line's dropped position is declared.
    check codeTblUnexpected notin codesOf(res.diagnostics)
    check codeSupportUnsupported notin codesOf(res.diagnostics)
    let st = res.semantic.find("mailStepper")
    let table = st.find("table")
    require table != nil
    let rows = table.children.filterIt(it.kind == enElement and
      it.tag == "tr")
    check rows.len == 2
    check rows[0].children.len == 4 and rows[1].children.len == 4
    for td in rows[0].children:
      check td.attrs["aria-hidden"] == "true" and td.attrs["width"] == "25%"
    # Two steps done (a check), the third current, the fourth a ring.
    check res.html.count(">✓</td>") == 2
    check ">3</td>" in res.html and ">4</td>" in res.html
    check "border-radius:14px" in res.html
    check "border:2px solid #e5e7eb" in res.html
    # Connectors: 2px cells, the accent up to the current step.
    check res.html.count("height=\"2\" bgcolor=\"#1f6feb\"") == 4
    check res.html.count("height=\"2\" bgcolor=\"#e5e7eb\"") == 2
    # The steps stay in the tree around their labels; never stacked.
    check st.all("mailStep").len == 4
    check "e-cells-stack" notin res.html and "@media" notin
      res.html.split("</head>")[1]

  test "test_stepper_step_counts":
    let long = stepperDoc(["A", "B", "C", "D", "E", "F"], "2")
    check codePatternStepperLong in codesOf(long.diagnostics)
    check codePatternStepperLong notin codesOf(stepperDoc(["A", "B", "C",
      "D", "E"], "2").diagnostics)
    check codeVocabBadValue in codesOf(stepperDoc(["A", "B"], "1").diagnostics)
    # Own wording for both lines (a translation).
    let own = stepperDoc(["أ", "ب", "ج"], "2", [("status", "الحالية: ب"),
      ("text", "الخطوة ٢ من ٣")], rtl = true)
    check not hasErrors(own.diagnostics)
    check ">الحالية: ب</p>" in own.html
    check "الخطوة ٢ من ٣\n" in own.text
    check "dir=\"rtl\"" in own.html

# --- mailTimeline ----------------------------------------------------------------

proc timelineDoc(rtl = false): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  let t = r.el(s, "mailTimeline")
  for (time, what) in [("09:12 UTC", "Investigating elevated errors."),
      ("09:40 UTC", "A fix is deployed."), ("10:05 UTC", "Resolved.")]:
    discard r.el(t, "mailTimelineEvent", [("time", time)], text = what)
  renderTree(doc)

suite "mailTimeline":
  test "test_timeline_line_is_a_cell":
    # rule: R-TBL-10
    let res = timelineDoc()
    check not hasErrors(res.diagnostics)
    check codeTblUnexpected notin codesOf(res.diagnostics)
    let table = res.semantic.find("mailTimeline").find("table")
    require table != nil
    let rows = table.children.filterIt(it.kind == enElement and
      it.tag == "tr")
    check rows.len == 6
    for row in rows:
      check row.children.len == 5
    # Fixed layout inline: where head CSS is stripped, an unbroken word
    # in the text cell breaks there instead of widening the table and
    # squeezing the track to nothing.
    check table.styles.getOrDefault("table-layout", "") == "fixed"
    # The line: the middle track cell of each event's second row, 2px,
    # painted; the last event draws none.
    check res.html.count("width=\"2\" bgcolor=\"#e5e7eb\"") == 2
    # The dots: three painted cells, the outer two rounded.
    check res.html.count("bgcolor=\"#1f6feb\"") == 9
    check "border-top-left-radius:8px" in res.html
    check res.text.body == "09:12 UTC — Investigating elevated errors.\n" &
      "09:40 UTC — A fix is deployed.\n10:05 UTC — Resolved.\n"
    # Right to left the dot's rounded sides are mirrored.
    let rtl = timelineDoc(rtl = true)
    check "dir=\"rtl\"" in rtl.html
    let firstDot = rtl.html.split("bgcolor=\"#1f6feb\"")[1].split(">")[0]
    check "border-top-right-radius:8px" in firstDot

# --- mailEvent -------------------------------------------------------------------

proc eventDoc(attrs: openArray[(string, string)]): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc()
  var a = @[("month", "Oct"), ("day", "14")]
  for x in attrs:
    a.add(x)
  let e = r.el(s, "mailEvent", a)
  discard r.el(e, "h3", text = "Launch party")
  renderTree(doc)

suite "mailEvent":
  test "test_event_requires_its_date_line":
    let missing = eventDoc([])
    check codesOf(missing.diagnostics).filterIt(it[0] == 'E') ==
      @[codePatternMissingText]
    let res = eventDoc([("date_text", "Tuesday, 14 October 2026, 18:00 " &
      "CEST"), ("location", "Berlin"), ("google", "https://g.example.com/e"),
      ("ics", "https://example.com/e.ics")])
    check not hasErrors(res.diagnostics)
    # The tile is decoration: hidden from screen readers and the text.
    check ">OCT</p>" in res.html
    let month = res.html.split(">OCT</p>")[0].split("<p")[^1]
    check "aria-hidden=\"true\"" in month
    check "OCT" notin res.text and "\n14\n" notin res.text
    check res.text.body == "Launch party\n------------\n\nTuesday, 14 " &
      "October 2026, 18:00 CEST\n\nBerlin\n\nGoogle Calendar " &
      "(https://g.example.com/e)\nApple Calendar (.ics) " &
      "(https://example.com/e.ics)\n"
    check res.semantic.find("mailEvent").find("mailSidebar").attrs[
      "fixed"] == "64px"
    check codeVocabBadValue in codesOf(eventDoc([("day", "")]).diagnostics)

# --- What the patterns brought ------------------------------------------------------

suite "text on its own background":
  test "test_text_sits_on_its_own_background":
    # rule: R-A11Y-07
    proc pairDiags(fg, bg: string; text = "Label"): seq[string] =
      let r = EmailRenderer()
      let (doc, s) = r.newDoc()
      discard r.el(s, "p", styles = [("color", fg), ("background-color", bg)],
        text = text)
      codesOf(renderTree(doc).diagnostics)
    # White on its own blue reads; white on its own white does not.
    check codeA11yContrast notin pairDiags("#ffffff", "#1f6feb")
    check codeA11yContrast in pairDiags("#ffffff", "#ffffff")
    # A painted cell with no text to read is not text.
    check codeA11yContrast notin pairDiags("#111827", "#1f2937", "\u00a0")
