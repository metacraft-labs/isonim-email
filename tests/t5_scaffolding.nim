# rule: R-LAY-06, R-LAY-08, R-LAY-09, R-LAY-17
# rule: R-TBL-01, R-TBL-02, R-TBL-04, R-TBL-05, R-TBL-06, R-TBL-14, R-TBL-15
# rule: R-OL-03, R-OL-15
## The div-first scaffolding: `mailSection`, `mailWrapper` and
## `mailStack` lowered to divs for every client and to ghost tables for
## Word, and the construction lint around them.
##
## - A section is a centred `max-width` container with a ghost table of
##   the same px width (R-LAY-06, R-LAY-08, R-OL-03); everything Word
##   must honour is on the ghost cell as well as on the div (R-TBL-02),
##   and alignment is attribute plus CSS, the band centred in Word by
##   the table's `align` (R-TBL-14). A single column merges into it.
## - `full_width` adds the full-bleed band (R-LAY-09); a wrapper is a
##   band whose sections are laid out in its box (R-LAY-17).
## - A stack's gaps are padding plus Word-only spacer rows whose cells
##   are never empty (R-TBL-04, R-TBL-05).
## - The scaffolding emits no table outside Outlook conditionals; the
##   lint flags authored layout tables (R-TBL-01), spans (R-TBL-06),
##   layout tables nested too deep outside the conditionals (R-TBL-15)
##   and `mso-*` properties off the closed list (R-OL-15).
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS.
import std/[strutils, unittest]
import isonim_email
import stories/email_stories

proc newDoc(r: EmailRenderer; dir = "ltr"): EmailNode =
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", "en")
  r.setAttribute(result, "dir", dir)
  r.setAttribute(result, "title", "Scaffolding")

proc child(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  r.appendChild(parent, result)

proc heading(r: EmailRenderer; parent: EmailNode; text = "Title") =
  let h = r.child(parent, "h1")
  r.setTextContent(h, text)

proc para(r: EmailRenderer; parent: EmailNode; text: string) =
  let p = r.child(parent, "p")
  r.setTextContent(p, text)

const contentOpen = "<td align=\"center\"><div>"
const contentClose = "</div></td></tr></table></div></body>"

proc content(html: string): string =
  ## The lowered sections: what sits in the skeleton's content cell.
  let a = html.find(contentOpen)
  let b = html.rfind(contentClose)
  doAssert a >= 0 and b > a, html
  html[a + contentOpen.len ..< b]

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc nonMsoTables(html: string): int =
  ## `<table` openings outside `<!--[if mso]>…<![endif]-->`.
  var i = 0
  while true:
    let t = html.find("<table", i)
    if t < 0:
      return
    let open = html.rfind("<!--[if mso]>", last = t)
    let close = html.rfind("<![endif]-->", last = t)
    if open < 0 or close > open:
      inc result
    i = t + 6

const ghostClose = "<!--[if mso]></td></tr></table><![endif]-->"

suite "mailSection lowers div-first":
  test "test_section_div_first_with_ghost_table":
    # The default section: padding 24px 0 plus the implicit column's
    # 0 24px, a background, the document's direction, left-aligned.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("background-color", "#FFF")])
    r.heading(s)
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    check content(res.html) ==
      "<!--[if mso]><table role=\"presentation\" align=\"center\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\" width=\"600\" " &
      "style=\"width:600px;\"><tr><td bgcolor=\"#ffffff\" " &
      "style=\"padding:24px;background-color:#ffffff;\"><![endif]-->" &
      "<div style=\"margin:0 auto;max-width:600px;" &
      "background-color:#ffffff;\"><div align=\"left\" " &
      "style=\"padding:24px;font-size:16px;text-align:left;" &
      "direction:ltr;\"><h1 style=\"color:#111827;\">Title</h1></div>" &
      "</div>" & ghostClose
    # R-TBL-01: the scaffolding adds no table outside the conditionals;
    # the one left is the document's wrapper.
    check nonMsoTables(res.html) == 1

  test "test_section_without_outlook_output_keeps_the_divs":
    let build = proc(word: bool): string =
      let r = EmailRenderer()
      let doc = newDoc(r)
      let s = r.child(doc, "mailSection", [("background-color", "#ffffff")])
      r.heading(s)
      var t = defaultTarget()
      t.outlookWord = word
      content(renderTree(doc, target = t).html)
    let withWord = build(true)
    let without = build(false)
    check "<!--[if" notin without
    check without ==
      withWord.replace(ghostClose, "").split("<![endif]-->", 1)[1]

  test "test_single_column_padding_merges":
    # Section 24px 0 plus column 0 24px is 24px on the div and the ghost
    # cell alike; an explicit mailColumn and none lower the same.
    let build = proc(explicit: bool): string =
      let r = EmailRenderer()
      let doc = newDoc(r)
      let s = r.child(doc, "mailSection", [("padding", "24px 0")])
      let host = if explicit: r.child(s, "mailColumn",
          [("padding", "0 24px")]) else: s
      r.heading(host)
      r.para(host, "Body")
      let res = renderTree(doc)
      doAssert not hasErrors(res.diagnostics), $res.diagnostics
      content(res.html)
    let implicit = build(false)
    check implicit == build(true)
    check "<td style=\"padding:24px;\">" in implicit
    check "<div align=\"left\" style=\"padding:24px;font-size:16px;" in
      implicit
    # Different paddings stay per side, summed side by side.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("padding", "8px 12px 16px 40px")])
    let c = r.child(s, "mailColumn", [("padding", "5px 30px")])
    r.heading(c)
    let html = content(renderTree(doc).html)
    check "<td style=\"padding:13px 42px 21px 70px;\">" in html
    check "style=\"padding:13px 42px 21px 70px;font-size:16px;" in html

  test "test_ghost_cell_mirrors_what_word_must_honour":
    # R-TBL-02: padding, background and border on both; R-TBL-14:
    # alignment as attribute and CSS on the div and the ghost cell, and
    # the band centred in Word by the table's own align.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("padding", "10px 20px"),
      ("background-color", "#f4f5f7"), ("border", "2px solid #E5E7EB"),
      ("text-align", "center"), ("border-radius", "8px")])
    r.heading(s)
    let html = content(renderTree(doc).html)
    check "<table role=\"presentation\" align=\"center\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" width=\"600\" " &
      "style=\"width:600px;\">" in html
    check "<td bgcolor=\"#f4f5f7\" align=\"center\" style=\"" &
      "padding:10px 44px;background-color:#f4f5f7;" &
      "border:2px solid #e5e7eb;text-align:center;\">" in html
    check "<div style=\"margin:0 auto;max-width:600px;" &
      "background-color:#f4f5f7;border-radius:8px;\">" in html
    # The div's border is drawn by a frame Word does not see (Word has
    # the ghost cell's, and renders div borders unreliably).
    check "<!--[if !mso]><!--><div style=\"border:2px solid #e5e7eb;" &
      "border-radius:8px;\"><!--<![endif]--><div align=\"center\" " &
      "style=\"padding:10px 44px;font-size:16px;text-align:center;" &
      "direction:ltr;\">" in html
    check html.count("<!--[if !mso]><!--></div><!--<![endif]-->") == 1
    # Without Outlook output the frame is a plain div.
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2)
    let s2 = r2.child(doc2, "mailSection", [("border", "2px solid #e5e7eb")])
    r2.heading(s2)
    var t = defaultTarget()
    t.outlookWord = false
    let plain = content(renderTree(doc2, target = t).html)
    check "<div style=\"border:2px solid #e5e7eb;\"><div align=\"left\"" in
      plain
    check "<!--" notin plain
    # Word never centres through margin:auto alone (R-TBL-04).
    check "margin:auto" notin html

  test "test_section_alignment_and_direction_follow_the_document":
    let r = EmailRenderer()
    let doc = newDoc(r, "rtl")
    let s = r.child(doc, "mailSection")
    r.heading(s)
    let own = r.child(doc, "mailSection", attrs = [("direction", "ltr")])
    r.heading(own, "Second")
    let html = content(renderTree(doc).html)
    check "<td align=\"right\" style=\"padding:24px;text-align:right;\">" in
      html
    check "<div align=\"right\" style=\"padding:24px;font-size:16px;" &
      "text-align:right;direction:rtl;\">" in html
    check "<div align=\"left\" style=\"padding:24px;font-size:16px;" &
      "text-align:left;direction:ltr;\">" in html

  test "test_full_width_section_bleeds":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("background-color", "#eeeeee")],
      [("full_width", "true")])
    r.heading(s)
    let html = content(renderTree(doc).html)
    check html.startsWith("<!--[if mso]><table role=\"presentation\" " &
      "width=\"100%\" border=\"0\" cellpadding=\"0\" cellspacing=\"0\">" &
      "<tr><td bgcolor=\"#eeeeee\" style=\"background-color:#eeeeee;\">" &
      "<![endif]--><div style=\"background-color:#eeeeee;\">" &
      "<!--[if mso]><table role=\"presentation\" align=\"center\"")
    check html.endsWith("</div>" & ghostClose & "</div>" & ghostClose)
    # The section inside is unchanged.
    check "<div style=\"margin:0 auto;max-width:600px;" &
      "background-color:#eeeeee;\">" in html

  test "test_column_scaffolding_is_reported_not_dropped":
    # Several columns, a column with its own box, and reversal need the
    # column scaffolding, which does not exist yet: errors, content kept.
    let r = EmailRenderer()
    let doc = newDoc(r)
    r.heading(doc)
    let two = r.child(doc, "mailSection")
    r.para(r.child(two, "mailColumn"), "Left")
    r.para(r.child(two, "mailColumn"), "Right")
    let boxed = r.child(doc, "mailSection")
    r.para(r.child(boxed, "mailColumn", [("background-color", "#ffffff")]),
      "Boxed")
    let narrow = r.child(doc, "mailSection")
    r.para(r.child(narrow, "mailColumn", [("width", "50%")]), "Narrow")
    let rev = r.child(doc, "mailSection",
      attrs = [("reverse_on_mobile", "true")])
    r.para(rev, "Reversed")
    let res = renderTree(doc)
    check codesOf(res.diagnostics) == @[codeLowerMissing, codeLowerMissing,
      codeLowerMissing, codeLowerMissing, codeLowerMissing]
    check "<mailcolumn" notin res.html.toLowerAscii()
    for text in ["Left", "Right", "Boxed", "Narrow", "Reversed"]:
      check text in res.html
    # Negative control: a plain single column is clean.
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2)
    r2.heading(r2.child(r2.child(doc2, "mailSection"), "mailColumn"))
    check renderTree(doc2).diagnostics.len == 0

suite "mailWrapper lowers as a band around its sections":
  test "test_wrapper_nests_its_sections_ghost_tables":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let w = r.child(doc, "mailWrapper", [("padding", "16px 20px"),
      ("background-color", "#eeeeee")])
    let s = r.child(w, "mailSection", [("padding", "12px 0")])
    r.heading(s)
    let html = content(renderTree(doc).html)
    check html ==
      "<!--[if mso]><table role=\"presentation\" align=\"center\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\" width=\"600\" " &
      "style=\"width:600px;\"><tr><td bgcolor=\"#eeeeee\" " &
      "style=\"padding:16px 20px;background-color:#eeeeee;\">" &
      "<![endif]--><div style=\"margin:0 auto;max-width:600px;" &
      "background-color:#eeeeee;\"><div style=\"padding:16px 20px;\">" &
      "<!--[if mso]><table role=\"presentation\" align=\"center\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\" width=\"560\" " &
      "style=\"width:560px;\"><tr><td style=\"padding:12px 24px;\">" &
      "<![endif]--><div style=\"margin:0 auto;max-width:560px;\">" &
      "<div align=\"left\" style=\"padding:12px 24px;font-size:16px;" &
      "text-align:left;direction:ltr;\"><h1 style=\"color:#111827;\">" &
      "Title</h1></div></div>" & ghostClose & "</div></div>" & ghostClose

  test "test_wrapper_border_mirrors_and_narrows":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let w = r.child(doc, "mailWrapper", [("padding", "10px"),
      ("border", "1px solid #cccccc")])
    let s = r.child(w, "mailSection")
    r.heading(s)
    let html = content(renderTree(doc).html)
    check "<td style=\"padding:10px;border:1px solid #cccccc;\">" in html
    check "<!--[if !mso]><!--><div style=\"border:1px solid #cccccc;\">" &
      "<!--<![endif]--><div style=\"padding:10px;\">" in html
    check "width=\"578\" style=\"width:578px;\"" in html
    check "max-width:578px;" in html

suite "mailStack: gaps are padding and spacer rows":
  test "test_stack_gaps_are_padding_and_spacer_rows":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    let st = r.child(s, "mailStack", [("gap", "20px")])
    r.heading(st)
    r.para(st, "Second")
    r.para(st, "Third")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let spacer = "<!--[if mso]><table role=\"presentation\" width=\"100%\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\"><tr><td " &
      "height=\"20\" aria-hidden=\"true\" style=\"height:20px;font-size:0;" &
      "line-height:0;mso-line-height-rule:exactly;\">&nbsp;</td></tr>" &
      "</table><![endif]-->"
    let html = content(res.html)
    check "<div align=\"left\" style=\"text-align:left;\"><h1 " in html
    check (spacer & "<div align=\"left\" style=\"padding-top:20px;" &
      "text-align:left;\"><p style=\"color:#111827;\">Second</p></div>") in html
    check html.count(spacer) == 2
    # The stack leaves no element of its own, and no gap CSS.
    check "<mailstack" notin res.html.toLowerAscii()
    check "gap:" notin res.html
    # The stack's gap prop is not linted as the CSS `gap` property.
    for d in res.diagnostics:
      check "gap" notin d.message

  test "test_stack_default_gap_zero_gap_and_alignment":
    let build = proc(gap, align: string): string =
      let r = EmailRenderer()
      let doc = newDoc(r)
      let st = r.child(r.child(doc, "mailSection"), "mailStack",
        if gap.len > 0: @[("gap", gap)] else: @[],
        if align.len > 0: @[("align", align)] else: @[])
      r.heading(st)
      r.para(st, "Second")
      content(renderTree(doc).html)
    # Default gap: space.4, 16px.
    check "height=\"16\"" in build("", "")
    check "padding-top:16px;" in build("", "")
    # Gap 0 adds nothing: no padding, no spacer row.
    let none = build("0", "")
    check "padding-top" notin none
    check "aria-hidden" notin none
    # Alignment is attribute and CSS on every child (R-TBL-14).
    let centred = build("", "center")
    check centred.count("<div align=\"center\" style=\"") == 2
    check centred.count("text-align:center;") == 2
    # Without Outlook output: the padding stays, the spacer row goes.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let st = r.child(r.child(doc, "mailSection"), "mailStack")
    r.heading(st)
    r.para(st, "Second")
    var t = defaultTarget()
    t.outlookWord = false
    let plain = content(renderTree(doc, target = t).html)
    check "padding-top:16px;" in plain
    check "<!--[if" notin plain

suite "construction lint":
  test "test_lint_flags_layout_tables_outside_constructs":
    let r = EmailRenderer()
    let doc = newDoc(r)
    r.heading(doc)
    let t = r.child(doc, "table")
    let tr = r.child(t, "tr")
    r.setTextContent(r.child(tr, "td"), "Layout")
    let data = r.child(doc, "mailTable", attrs = [("caption", "Items")])
    discard r.child(r.child(data, "table"), "tr")
    let found = lintTree(doc, consumer)
    var unexpected = 0
    for d in found:
      if d.code == codeTblUnexpected:
        inc unexpected
        check d.severity == sevWarning
        check "R-TBL-01" in d.rules
    # The layout table warns; the table inside mailTable does not.
    check unexpected == 1

  test "test_lint_flags_spans":
    let r = EmailRenderer()
    let doc = newDoc(r)
    r.heading(doc)
    let data = r.child(doc, "mailTable", attrs = [("caption", "Items")])
    let table = r.child(data, "table")
    let head = r.child(table, "thead")
    discard r.child(r.child(head, "tr"), "th", attrs = [("colspan", "2")])
    let body = r.child(table, "tbody")
    let row = r.child(body, "tr")
    discard r.child(row, "td", attrs = [("colspan", "2")])
    discard r.child(row, "td", attrs = [("rowspan", "2")])
    var spans: seq[string] = @[]
    for d in lintTree(doc, consumer):
      if d.code == codeTblSpan:
        spans.add(d.message)
        check "R-TBL-06" in d.rules
    # The header-row colspan is allowed; the body colspan and the
    # rowspan are not.
    check spans.len == 2
    check "colspan" in spans[0]
    check "rowspan" in spans[1]

  test "test_lint_flags_layout_tables_nested_too_deep":
    proc nest(r: EmailRenderer; levels: int; mso: bool): EmailNode =
      # A document wrapper table, then `levels` presentation tables.
      result = r.createElement("table")
      r.setAttribute(result, "role", "presentation")
      var cell = r.child(r.child(result, "tr"), "td")
      for i in 1 .. levels:
        let t = r.createElement("table")
        r.setAttribute(t, "role", "presentation")
        if mso and i == levels:
          r.appendChild(cell, msoWrap(t))
        else:
          r.appendChild(cell, t)
        cell = r.child(r.child(t, "tr"), "td")
    let r = EmailRenderer()
    check codesOf(lintTableDepth(nest(r, 4, false))) == @[codeTblDeep]
    check lintTableDepth(nest(r, 3, false)).len == 0
    # What only Word sees does not count.
    check lintTableDepth(nest(r, 4, true)).len == 0

  test "test_lint_mso_properties_closed_list":
    check msoClosedList == ["mso-line-height-rule", "mso-table-lspace",
      "mso-table-rspace", "mso-padding-alt", "mso-hide", "mso-font-alt"]
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    r.heading(s)
    let p = r.child(s, "p", [("mso-text-raise", "4px"),
      ("mso-line-height-rule", "exactly"), ("line-height", "20px")])
    r.setTextContent(p, "Raised")
    let res = renderTree(doc)
    var unlisted: seq[string] = @[]
    for d in res.diagnostics:
      if d.code == codeCssMsoUnlisted:
        unlisted.add(d.message)
        check d.severity == sevWarning
        check "R-OL-15" in d.rules
    check unlisted.len == 1
    check "mso-text-raise" in unlisted[0]
    # Raw payloads and style attributes are read too; class names and
    # conditions are not property names.
    check msoNamesIn("<td style=\"mso-font-width:90%;mso-hide: all\">") ==
      @["mso-font-width", "mso-hide"]
    check msoNamesIn(".e-mso-group-fix{width:100% !important;}").len == 0
    check msoNamesIn("<!--[if mso]><table><![endif]-->").len == 0
    let holder = r.createElement("div")
    r.appendChild(holder,
      msoWrap(raw("<td style=\"mso-border-alt:none\">")))
    check codesOf(lintMsoProperties(holder)) == @[codeCssMsoUnlisted]

  test "test_library_output_stays_on_the_closed_list":
    # Negative control over everything the library emits for the seed
    # stories and the scaffolding: nothing off the list, no deep tables.
    registerSeedStories()
    for name in listStories():
      let html = getStory(name).render().html
      for prop in msoNamesIn(html):
        check prop in msoClosedList
    let r = EmailRenderer()
    let doc = newDoc(r)
    let w = r.child(doc, "mailWrapper", [("padding", "8px")])
    let s = r.child(w, "mailSection", attrs = [("full_width", "true")])
    let st = r.child(s, "mailStack")
    r.heading(st)
    r.para(st, "Body")
    let res = renderTree(doc)
    check res.diagnostics.len == 0
    check "mso-line-height-rule" in res.html
