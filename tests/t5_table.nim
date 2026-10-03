## `mailTable`, the data table (`lower/data_table.nim`,
## `lower/table_style.nim`), and attribute mirroring on cells.
##
## - The emitted table is data (`role="table"`), carries its own
##   collapse and auto layout, and its cells their padding, top
##   alignment and bottom borders (never the table); header cells are
##   bold and start-aligned.
## - The `caption` prop is the visually hidden caption, hidden from Word
##   too; header cells carry their scope.
## - Mobile: `stack` (the default above 3 columns) and `scroll` are
##   media-query switches whose rules land in the responsive block;
##   `keep` (the default up to 3 columns) changes nothing.
## - `border`, `striped` and their dark pairs; a table in a rounded box
##   keeps its own collapse; a `mailTable` holds exactly one `table`.
## - `valign` mirrors `vertical-align` on cells and rows, and a
##   translucent cell background's `bgcolor` is its blend for every
##   target.
## - Every table story renders without an error.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[strutils, tables, unittest]
import isonim_email
import stories/seed_table

proc child(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

proc newDoc(r: EmailRenderer; rtl = false): (EmailNode, EmailNode) =
  let doc = r.child(nil, "mailDocument", attrs = [
    ("lang", if rtl: "ar" else: "en"), ("dir", if rtl: "rtl" else: "ltr"),
    ("title", "Tables")])
  discard r.child(doc, "h1", text = "Tables")
  (doc, r.child(doc, "mailSection"))

proc dataTable(r: EmailRenderer; parent: EmailNode; heads: openArray[string];
    rows: openArray[seq[string]]; attrs: openArray[(string, string)] = [
      ("caption", "Items")]): EmailNode =
  ## A `mailTable` with a header row of `heads` and body `rows`.
  result = r.child(parent, "mailTable", attrs = attrs)
  let table = r.child(result, "table")
  let hr = r.child(r.child(table, "thead"), "tr")
  for h in heads:
    discard r.child(hr, "th", text = h)
  let body = r.child(table, "tbody")
  for row in rows:
    let tr = r.child(body, "tr")
    for cell in row:
      discard r.child(tr, "td", text = cell)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc body(html: string): string =
  html[html.find("<body") .. ^1]

proc head(html: string): string =
  html[0 ..< html.find("<body")]

proc between(s, a, b: string): string =
  ## The text after the first `a` up to the next `b`.
  let i = s.find(a)
  if i < 0:
    return ""
  let j = s.find(b, i + a.len)
  if j < 0: s[i + a.len .. ^1] else: s[i + a.len ..< j]

suite "mailTable markup":
  test "test_data_table_is_a_table_with_its_cells_styled":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.dataTable(s, ["Item", "Qty", "Amount"],
      [@["Widget", "2", "$20.00"], @["Gadget", "1", "$5.00"]])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "<mailtable" notin html.toLowerAscii()
    # The data table: role="table", never presentation, its own collapse
    # and auto layout (the reset fixes and collapses every table).
    check "<table width=\"100%\" role=\"table\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" style=\"width:100%;" &
      "border-collapse:collapse;" in html
    let tableStyle = between(html, "role=\"table\"", ">")
    check "table-layout:auto !important;" in tableStyle
    check "border-bottom" notin tableStyle
    check "padding:" notin tableStyle
    # Header cells: bold, start-aligned (attribute and CSS), scoped.
    let th = between(html, "<th ", "</th>")
    check "align=\"left\"" in th
    check "valign=\"top\"" in th
    check "scope=\"col\"" in th
    check "font-weight:700;" in th
    check "text-align:left;" in th
    check "padding:8px 12px;" in th
    check "border-bottom-width:1px;border-bottom-style:solid;" &
      "border-bottom-color:#e5e7eb;" in th
    # Body cells: padding, top alignment, the bottom border.
    let td = between(html, "<td valign=\"top\"", "</td>")
    check "padding:8px 12px;" in td
    check "vertical-align:top;" in td
    # Short words never break (a squeezed column would split them).
    check "word-break" notin td
    check "border-bottom-color:#e5e7eb;" in td
    check "font-weight" notin td
    check html.count("<td valign=\"top\"") == 6
    # Three columns: kept as they are on a phone (no classes, no rules).
    check "e-tbl-" notin res.html

  test "test_header_cells_start_right_to_left":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r, rtl = true)
    discard r.dataTable(s, ["الصنف", "المبلغ"], [@["قلم", "٥"]])
    let html = body(renderTree(doc).html)
    let th = between(html, "<th ", "</th>")
    check "align=\"right\"" in th
    check "text-align:right;" in th

  test "test_hidden_caption_and_scopes":
    # rule: R-A11Y-09
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let t = r.dataTable(s, ["Item", "Price"], [@["Widget", "$10"]],
      [("caption", "Order 1042")])
    # A body row headed by a th: scope="row".
    let tr = r.child(t.children[0].children[1], "tr")
    discard r.child(tr, "th", text = "Total")
    discard r.child(tr, "td", text = "$10")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    # The caption is the table's first child, hidden from readers' eyes
    # and from Word.
    check "role=\"table\"" in html
    let afterTable = html[html.find("role=\"table\"") .. ^1]
    check afterTable[afterTable.find(">") + 1 .. ^1].startsWith(
      "<caption style=\"mso-hide:all;position:absolute;width:1px;" &
      "height:1px;overflow:hidden;clip:rect(0 0 0 0);\">Order 1042" &
      "</caption><thead>")
    check html.count("scope=\"col\"") == 2
    check html.count("scope=\"row\"") == 1
    # A caption written as a child of the table is the author's, visible.
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    let t2 = r2.dataTable(s2, ["A", "B"], [@["1", "2"]], [])
    let cap = r2.child(nil, "caption", text = "Visible caption")
    cap.parent = t2.children[0]
    t2.children[0].children.insert(cap, 0)
    let res2 = renderTree(doc2)
    check codeA11yTableCaption notin codesOf(res2.diagnostics)
    check "<caption>Visible caption</caption>" in res2.html
    check "mso-hide:all;position:absolute" notin body(res2.html)

  test "test_a_long_word_breaks_in_its_cell_only":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.dataTable(s, ["Date", "Reference"], [@["1 Oct",
      "INV-2041-A-0000000000000000000000"]])
    let html = body(renderTree(doc).html)
    check html.count("word-break:break-word;") == 1
    let cell = between(html, "1 Oct</td>", "</td>")
    check "word-break:break-word;" in cell

suite "mailTable mobile modes":
  test "test_wide_tables_stack_with_labels":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let t = r.dataTable(s, ["Date", "Item", "Qty", "Amount"],
      [@["1 Oct", "Widget", "2", "$20.00"], @["2 Oct", "Gadget", "1",
        "$5.00"]])
    # A header spanning two columns labels both.
    let hr = t.children[0].children[0].children[0]
    hr.children[2].attrs["colspan"] = "2"
    hr.children.setLen(3)
    # An end-aligned amount cell.
    t.children[0].children[1].children[0].children[3].styles["text-align"] =
      "right"

    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    # Word gets the plain table in its own conditional; everyone else
    # the mobile-first copy.
    let word = between(html, "<!--[if mso]><table width=\"100%\" " &
      "role=\"table\"", "<![endif]-->")
    check "e-tbl" notin word
    check "Date: " notin word
    let web = between(html, "<!--[if !mso]><!--><table width=\"100%\" " &
      "role=\"table\"", "<!--<![endif]-->")
    check "class=\"e-tbl-t\" style=\"width:100%;" in web
    check "display:block;\"><caption" in web
    check "<tbody class=\"e-tbl-g\" style=\"display:block;\">" in web
    check "<tr class=\"e-tbl-head\" style=\"display:none;\">" in web
    check web.count("<tr class=\"e-tbl-r\" style=\"display:block;\">") == 2
    # Every body cell but a row's last: no rule and no bottom padding
    # inline, given back from the breakpoint up.
    check web.count("class=\"e-tbl-c e-tbl-in-1px\"") == 6
    check web.count("class=\"e-tbl-c\" style=\"") == 1
    check web.count("border-bottom-width:0;") == 6
    check web.count("padding-bottom:0;") == 6
    # Each body cell starts with its column's label, shown inline.
    let label = "<span class=\"e-tbl-lbl\" style=\"font-weight:700;\">"
    check (label & "Date: </span>1 Oct") in web
    check (label & "Item: </span>Widget") in web
    # The spanning "Qty" header labels the amount column too.
    check web.count(label & "Qty: </span>") == 4
    check web.count(label & "Qty: </span>$") == 2
    check "Amount" notin html
    # The table comes back from the breakpoint up, also for Thunderbird
    # (which applies no media query); on a phone, lines start at the
    # start.
    let h = head(res.html)
    let desk = between(h, "@media only screen and (min-width: 480px){", "}}")
    for rule in [".e-tbl-t{display:table !important",
        ".e-tbl-g{display:table-row-group !important",
        ".e-tbl-head{display:table-row !important",
        ".e-tbl-r{display:table-row !important",
        ".e-tbl-c{display:table-cell !important",
        ".e-tbl-lbl{display:none !important",
        ".e-tbl-in-1px{border-bottom-width:1px !important;" &
          "padding-bottom:8px !important"]:
      checkpoint(rule)
      check rule in desk
      check (".moz-text-html " & rule) in h
    # A stacked line starts at the start; a cell's own alignment comes
    # back with the table.
    check ".e-tbl-a-right{text-align:right !important" in desk
    check "class=\"e-tbl-c e-tbl-a-right\"" in web
    check "text-align:inherit;" in web
    check "align=\"right\"" notin web
    check "align=\"right\"" in word
    # Without Word: one copy, no conditionals.
    var t2 = defaultTarget()
    t2.outlookWord = false
    let plain = body(renderTree(doc.cloneTree, target = t2).html)
    check plain.count("role=\"table\"") == 1
    check "e-tbl-t" in plain

  test "test_narrow_tables_keep_and_modes_are_chosen":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.dataTable(s, ["A", "B"], [@["1", "2"]],
      [("caption", "Stacked anyway"), ("mobile", "stack")])
    discard r.dataTable(s, ["A", "B", "C", "D", "E"], [@["1", "2", "3",
      "4", "5"]], [("caption", "Kept"), ("mobile", "keep")])
    let res = renderTree(doc)
    let html = body(res.html)
    check html.count("<tr class=\"e-tbl-head\"") == 1
    check html.count("class=\"e-tbl-lbl\"") == 2
    let bad = EmailRenderer()
    let (doc2, s2) = newDoc(bad)
    discard bad.dataTable(s2, ["A"], [@["1"]], [("caption", "x"),
      ("mobile", "wrap")])
    check codeVocabBadValue in codesOf(renderTree(doc2).diagnostics)

  test "test_scroll_keeps_the_desktop_width":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.dataTable(s, ["A", "B", "C", "D", "E", "F"],
      [@["1", "2", "3", "4", "5", "6"]], [("caption", "Wide"),
        ("mobile", "scroll")])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    # The section's box is 600 less its 24px padding a side.
    # In a fixed-layout frame, so the tables around it never grow to the
    # data table's narrowest width without the reset.
    check "<table role=\"presentation\" border=\"0\" cellpadding=\"0\" " &
      "cellspacing=\"0\" width=\"100%\" style=\"width:100%;" &
      "table-layout:fixed;" in html
    check "<div style=\"overflow-x:auto;\"><table width=\"100%\" " &
      "role=\"table\" border=\"0\" cellpadding=\"0\" cellspacing=\"0\" " &
      "class=\"e-tbl-min-552\"" in html
    check "e-tbl-lbl" notin html
    let mq = between(head(res.html), "@media only screen and (max-width: " &
      "479px){", "}}")
    check ".e-tbl-min-552{min-width:552px !important" in mq

suite "mailTable props":
  test "test_border_none_custom_and_bad":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.dataTable(s, ["A", "B"], [@["1", "2"]], [("caption", "None")])
    s.children[^1].styles["border"] = "none"
    discard r.dataTable(s, ["C", "D"], [@["3", "4"]], [("caption", "Own")])
    s.children[^1].styles["border"] = "2px dashed #ff0000"
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    let first = between(html, "None</caption>", "</table>")
    check "border-bottom" notin first
    let second = between(html, "Own</caption>", "</table>")
    check second.count("border-bottom-width:2px;border-bottom-style:" &
      "dashed;border-bottom-color:#ff0000;") == 4
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    discard r2.dataTable(s2, ["A"], [@["1"]])
    s2.children[^1].styles["border"] = "thick"
    check codeVocabBadValue in codesOf(renderTree(doc2).diagnostics)

  test "test_striped_rows_and_dark_pairs":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.dataTable(s, ["A", "B"], [@["1", "2"], @["3", "4"],
      @["5", "6"], @["7", "8"]], [("caption", "Striped"),
        ("striped", "true")])
    let res = renderTree(doc)
    let html = body(res.html)
    # The second and fourth body rows, both cells each.
    check html.count("bgcolor=\"#f8f9fb\"") == 4
    check html.count("background-color:#f8f9fb;") == 4
    let rows = html[html.find("role=\"table\"") .. ^1].split("<tr")
    check "f8f9fb" notin rows[2]
    check "f8f9fb" in rows[3]
    check "f8f9fb" notin rows[4]
    check "f8f9fb" in rows[5]
    # A fresh tree: the render above resolved the first one's styles.
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    discard r2.dataTable(s2, ["A", "B"], [@["1", "2"], @["3", "4"]],
      [("caption", "Striped"), ("striped", "true")])
    var t = defaultTarget()
    t.darkMode = dmDesigned
    let dark = renderTree(doc2, target = t)
    let dh = head(dark.html)
    # The border and the stripe take their dark values.
    check "border-bottom-color:#2f343d !important" in dh
    check "background-color:#22262e !important" in dh

  test "test_table_in_a_rounded_box_keeps_its_collapse":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let box = r.child(s, "mailBox", [("border", "1px solid #e5e7eb"),
      ("border-radius", "12px")])
    discard r.dataTable(box, ["A", "B"], [@["1", "2"]])
    let html = body(renderTree(doc).html)
    check "border-collapse:separate !important" in html
    check "role=\"table\" border=\"0\" cellpadding=\"0\" cellspacing=\"0\" " &
      "style=\"width:100%;border-collapse:collapse;" in html

  test "test_mailtable_holds_exactly_one_table":
    # rule: R-TBL-18
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let t = r.child(s, "mailTable", attrs = [("caption", "Two")])
    discard r.child(r.child(r.child(t, "table"), "tr"), "td", text = "a")
    discard r.child(r.child(r.child(t, "table"), "tr"), "td", text = "b")
    let empty = r.child(s, "mailTable", attrs = [("caption", "None")])
    r.appendChild(empty, r.createTextNode("loose"))
    let res = renderTree(doc)
    var nesting = 0
    for d in res.diagnostics:
      if d.code == codeStructNesting and "R-TBL-18" in d.rules:
        inc nesting
    check nesting == 2
    # The content stays inspectable.
    check "loose" in res.html

suite "attribute mirroring on cells":
  test "test_valign_mirrors_vertical_align":
    # rule: R-OL-09
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let t = r.dataTable(s, ["A", "B"], [@["1", "2"]])
    let tbodyRow = t.children[0].children[1].children[0]
    tbodyRow.children[0].styles["vertical-align"] = "middle"
    tbodyRow.children[1].attrs["valign"] = "bottom"
    let res = renderTree(doc)
    let html = body(res.html)
    check "<td valign=\"middle\"" in html
    check "vertical-align:middle;" in html
    check "<td valign=\"bottom\"" in html
    check "vertical-align:bottom;" in html
    # A row's own valign mirrors too (hand-built rows of a data table).
    let r2 = EmailRenderer()
    let row = r2.child(nil, "tr", attrs = [("valign", "middle")])
    discard applyStyles(row, defaultTheme(), defaultTarget())
    check row.styles["vertical-align"] == "middle"
    let cell = r2.child(nil, "td", [("vertical-align", "baseline")])
    discard applyStyles(cell, defaultTheme(), defaultTarget())
    check "valign" notin cell.attrs

  test "test_translucent_cell_background_mirrors_its_blend":
    # rule: R-OL-09
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let t = r.dataTable(s, ["A", "B"], [@["1", "2"]])
    let cell = t.children[0].children[1].children[0].children[0]
    cell.styles["background-color"] = "rgba(255, 0, 0, 0.5)"
    var plain = defaultTarget()
    plain.outlookWord = false
    for target in [defaultTarget(), plain]:
      let html = body(renderTree(doc.cloneTree, target = target).html)
      # Half red over the white section: #ff7f7f, as an attribute for
      # every target (an attribute cannot carry rgba()).
      check "bgcolor=\"#ff7f7f\"" in html
      check "background-color:rgba(255,0,0,.5)" in html
    # Opaque backgrounds mirror as before.
    cell.styles["background-color"] = "#00ff00"
    check "bgcolor=\"#00ff00\"" in body(renderTree(doc.cloneTree).html)

suite "table stories":
  test "test_table_stories_render":
    for st in tableStories:
      let (html, _) = renderTableStory(st.name)
      checkpoint(st.name)
      check "<mailtable" notin html.toLowerAscii()
      check "role=\"table\"" in html
