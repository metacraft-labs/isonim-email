# rule: R-LAY-01, R-LAY-02, R-LAY-03, R-LAY-04, R-LAY-07, R-LAY-10
# rule: R-LAY-11, R-LAY-12, R-LAY-13, R-LAY-14, R-LAY-18, R-LAY-19
# rule: R-LAY-15, R-LAY-16, R-LAY-20, R-TBL-03, R-TBL-11, R-OL-08
# rule: R-CSS-19
## Rows of columns: a section's own columns and the `mailColumns`
## primitive with its four strategies, lowered div-first (or as a cell
## table where table layout is the point) with Word's ghost row, and the
## responsive block they need.
##
## - Hybrid columns are mobile first: inline `width:100%`, the desktop
##   width from a `min-width` class named after it (R-LAY-01…03), in a
##   container with a zero font size (`0.01px`: WebKitGTK renders no
##   message with a true zero, R-LAY-04), Word's widths from a ghost row
##   whose cells carry the half-gutters and, when the row allows it, the
##   column's padding (R-LAY-07, R-TBL-03).
## - Gutters are MJML 5's (R-LAY-14): the desktop class width loses the
##   gutter share, px rows hand the remainder to their first columns,
##   half-gutters sit on the inner sides from a desktop class, and the
##   stacked gap is inline.
## - Groups keep their columns' desktop percentage (R-LAY-10); reversal
##   flips only the desktop order through `dir` (R-LAY-11); the
##   Thunderbird and OWA copies cover the desktop column rules only
##   (R-LAY-12, R-LAY-13).
## - The Fab Four, stacking-cell and cell strategies (R-LAY-18…20), the
##   Fab Four width as a fallback pair (R-CSS-19), and the 320px check
##   of cell rows (R-TBL-11).
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS.
import std/[strutils, tables, unittest]
import isonim_email

proc newDoc(r: EmailRenderer; dir = "ltr"): EmailNode =
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", "en")
  r.setAttribute(result, "dir", dir)
  r.setAttribute(result, "title", "Columns")
  let h = r.createElement("h1")
  r.setTextContent(h, "Columns")
  r.appendChild(result, h)

proc child(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  r.appendChild(parent, result)

proc para(r: EmailRenderer; parent: EmailNode; text: string) =
  let p = r.child(parent, "p")
  r.setTextContent(p, text)

proc image(r: EmailRenderer; parent: EmailNode) =
  discard r.child(parent, "mailImage", [("width", "120px")],
    [("src", "https://img.example.com/a.png"), ("alt", "A picture")])

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc responsive(html: string): string =
  ## The responsive `<style>` block's CSS: the one holding a width query.
  var i = 0
  while true:
    let s = html.find("<style>", i)
    if s < 0:
      return ""
    let e = html.find("</style>", s)
    let css = html[s + 7 ..< e]
    if "-width: " in css:
      return css
    i = e

proc rowDoc(strategy: string; gutter = ""; cols = 2;
    colStyles: seq[seq[(string, string)]] = @[];
    texts = true): (EmailRenderer, EmailNode, EmailNode) =
  let r = EmailRenderer()
  let doc = newDoc(r)
  let s = r.child(doc, "mailSection")
  var attrs = @[("strategy", strategy)]
  if gutter.len > 0:
    attrs.add(("gutter", gutter))
  let row = r.child(s, "mailColumns", attrs = attrs)
  for i in 0 ..< cols:
    let st = if i < colStyles.len: colStyles[i] else: @[]
    let c = r.child(row, "mailColumn", st)
    if texts:
      r.para(c, "Column " & $(i + 1))
    else:
      r.image(c)
  (r, doc, row)

suite "hybrid columns":
  test "test_hybrid_columns_are_mobile_first":
    # No box the library emits outside Outlook's conditionals has a
    # font size of exactly zero, which WebKitGTK cannot render.
    # A section's own columns: no gutter, MJML's default padding.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    r.para(r.child(s, "mailColumn"), "Left")
    r.para(r.child(s, "mailColumn"), "Right")
    let px = r.child(doc, "mailSection")
    r.para(r.child(px, "mailColumn", [("width", "200px")]), "Fixed")
    r.para(r.child(px, "mailColumn", [("width", "400px")]), "Rest")
    let thirds = r.child(doc, "mailSection")
    for t in ["A", "B", "C"]:
      r.para(r.child(thirds, "mailColumn"), t)
    let res = renderTree(doc)
    check res.diagnostics.len == 0
    # R-LAY-04: the section's inner div holds inline-blocks, font-size 0.
    check "<div align=\"left\" style=\"padding:24px 0;font-size:0.01px;" &
      "text-align:left;direction:ltr;\">" in res.html
    # R-LAY-01: inline 100% (stacked without head CSS), no inline
    # max-width, the column's padding on its inner div (and, for Word,
    # on a single-cell table around it, R-LAY-07).
    check "<div class=\"e-col-50\" style=\"display:inline-block;" &
      "width:100%;vertical-align:top;font-size:16px;text-align:left;" &
      "direction:ltr;\"><!--[if mso]><table role=\"presentation\" " &
      "width=\"100%\" border=\"0\" cellpadding=\"0\" cellspacing=\"0\">" &
      "<tr><td style=\"padding:0 24px;\"><![endif]--><div " &
      "style=\"padding:0 24px;\"><p" in res.html
    check "max-width:300px" notin res.html
    # R-LAY-02/03: one rule per distinct class, under the min-width
    # query, named after the width; thirds dedupe to one class.
    let body = res.html[res.html.find("<body") .. ^1]
    var outside = body
    while "<!--[if mso]>" in outside:
      let a = outside.find("<!--[if mso]>")
      outside = outside[0 ..< a] &
        outside[outside.find("<![endif]-->", a) + 12 .. ^1]
    check "font-size:0;" notin outside
    check "font-size:0.01px;" in outside
    let css = responsive(res.html)
    check css.startsWith("@media only screen and (min-width: 480px){")
    for rule in [".e-col-50{max-width:50%;width:50% !important}",
        ".e-colpx-200{max-width:200px;width:200px !important}",
        ".e-colpx-400{max-width:400px;width:400px !important}",
        ".e-col-33-333333{max-width:33.333333%;width:33.333333% !important}"]:
      check rule in css
    # The rule and its Thunderbird copy, once each.
    check css.count(".e-col-33-333333{") == 2
    check res.html.count("class=\"e-col-33-333333\"") == 3
    # Negative control: without columns there is no responsive block.
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2)
    r2.para(r2.child(doc2, "mailSection"), "One column")
    check responsive(renderTree(doc2).html) == ""

  test "test_ghost_row_carries_widths_and_gutters":
    # R-LAY-07: a fill-width ghost row, one fixed-width, unpadded cell
    # per column; the half-gutters on a single-cell table inside each
    # (R-TBL-02).
    let (_, doc, _) = rowDoc("hybrid", "24px")
    let html = renderTree(doc).html
    check "<!--[if mso]><table role=\"presentation\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" width=\"100%\"><tr><td " &
      "valign=\"top\" width=\"276\" style=\"width:276px;" &
      "vertical-align:top;\"><![endif]-->" in html
    check "<!--[if mso]></td><td valign=\"top\" width=\"276\" " &
      "style=\"width:276px;vertical-align:top;\"><![endif]-->" in html
    # The content sits inside those tables.
    check "<tr><td style=\"padding:0 12px 0 0;\"><![endif]--><div><p" in html
    check "<tr><td style=\"padding:0 0 0 12px;\"><![endif]--><div><p" in html
    # The row, the two gutter tables, the section and the heading's
    # implicit section (the document's loose content) close.
    check html.count("<!--[if mso]></td></tr></table><![endif]-->") == 5
    # No cell of the ghost row is padded.
    check "width:276px;padding" notin html
    # Without Outlook output there is no ghost row at all.
    let (_, doc2, _) = rowDoc("hybrid", "24px")
    var t = defaultTarget()
    t.outlookWord = false
    let plain = renderTree(doc2, target = t).html
    check "<!--[if" notin plain[plain.find("<body") .. ^1]
    check plain.count("display:inline-block") == 2

  test "test_one_padded_cell_per_row":
    # R-TBL-03: the ghost row's cells are never padded, so columns with
    # different vertical padding each get a single-cell table of their
    # own for Word, which therefore has nothing to equalise.
    let (_, nested, _) = rowDoc("hybrid", "0", 2,
      @[@[("padding", "8px 16px")], @[("padding", "0 4px 20px")]])
    let n = renderTree(nested).html
    check n.count("style=\"width:276px;vertical-align:top;\"") == 2
    check "<!--[if mso]><table role=\"presentation\" width=\"100%\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\"><tr><td " &
      "style=\"padding:8px 16px;\"><![endif]-->" in n
    check "<td style=\"padding:0 4px 20px;\"><![endif]-->" in n
    # A cell row with different vertical padding nests a padded table
    # per cell instead of padding the cells.
    let (_, cells, _) = rowDoc("cells", "0", 2,
      @[@[("padding", "8px 16px")], @[("padding", "0 4px 20px")]])
    let c = renderTree(cells).html
    check "<td style=\"padding:8px 0;\">" in c
    check "<td style=\"padding:0 0 20px;\">" in c
    check "style=\"width:50%;padding:0 16px;" in c

  test "test_no_whitespace_between_columns":
    # R-LAY-05: whitespace the author leaves between columns never
    # reaches the output, with or without the conditionals between them.
    for word in [true, false]:
      let r = EmailRenderer()
      let doc = newDoc(r)
      let s = r.child(doc, "mailSection")
      let row = r.child(s, "mailColumns", attrs = [("gutter", "0")])
      for i in 1 .. 3:
        r.appendChild(row, r.createTextNode("\n  "))
        r.para(r.child(row, "mailColumn"), "Cell " & $i)
      r.appendChild(row, r.createTextNode("\n"))
      var t = defaultTarget()
      t.outlookWord = word
      let html = renderTree(doc, target = t).html
      check "\n" notin html[html.find("<body") .. ^1]
      let starts = html.count("<div class=\"e-col-33-333333\"")
      check starts == 3
      # Every column but the first opens right after the previous one
      # (or the conditional between them) closes.
      let joint = if word: "</div><!--[if mso]></td><td "
        else: "</div><div class=\"e-col-33-333333\""
      check html.count(joint) == 2

  test "test_group_keeps_desktop_percent":
    # R-LAY-10: the group is one inline-block with its own class and
    # the group fix; its columns keep their percentage inline and get a
    # ghost row of their own inside the group's ghost cell.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("padding", "0")])
    let g = r.child(s, "mailGroup", [("width", "50%"),
      ("background-color", "#eeeeee")])
    r.para(r.child(g, "mailColumn", [("padding", "0")]), "G1")
    r.para(r.child(g, "mailColumn", [("padding", "0")]), "G2")
    r.para(r.child(s, "mailColumn", [("width", "50%")]), "Solo")
    let res = renderTree(doc)
    # Only the information that the grey group is ragged beside its
    # neighbour (R-TBL-10).
    check codesOf(res.diagnostics) == @[codeTblRagged]
    let html = res.html
    # No line-height of its own: its columns' text keeps its own.
    check "<div class=\"e-col-50 e-mso-group-fix\" style=\"display:" &
      "inline-block;width:100%;vertical-align:top;font-size:0.01px;" &
      "text-align:left;direction:ltr;background-color:#eeeeee;\">" in html
    check "line-height:0" notin html
    check "<table role=\"presentation\" border=\"0\" cellpadding=\"0\" " &
      "cellspacing=\"0\" width=\"100%\" bgcolor=\"#eeeeee\"><tr><td " &
      "valign=\"top\" width=\"150\" style=\"width:150px;" &
      "vertical-align:top;\">" in html
    check html.count("style=\"display:inline-block;width:50%;") == 2
    check "<td valign=\"top\" width=\"300\" style=\"width:300px;" &
      "vertical-align:top;\">" in html
    # The stacking column next to it is 100% inline.
    check html.count("display:inline-block;width:100%;") == 2

suite "gutters (MJML 5)":
  test "test_gutter_shares_and_stacking_gap":
    # A % row: each column loses (n-1)/n of the gutter in %, the class
    # pads the inner sides, the stacked gap is inline.
    let (_, doc, _) = rowDoc("hybrid", "24px")
    let html = renderTree(doc).html
    # The class pads outside the width, whatever the client's own
    # box-sizing.
    check "<div class=\"e-col-47-826087 e-gutter-2-1-per-4-347826\" " &
      "style=\"display:inline-block;width:100%;box-sizing:content-box;" &
      "vertical-align:top;font-size:16px;" in html
    check "<div class=\"e-col-47-826087 e-gutter-2-2-per-4-347826\" " &
      "style=\"display:inline-block;width:100%;box-sizing:content-box;" &
      "vertical-align:top;padding-top:24px;font-size:16px;" in html
    let css = responsive(html)
    check ".e-col-47-826087{max-width:47.826087%;width:47.826087% " &
      "!important}" in css
    check ".e-gutter-2-1-per-4-347826{padding:0 2.173913% 0 0 " &
      "!important}" in css
    check ".e-gutter-2-2-per-4-347826{padding:0 0 0 2.173913% " &
      "!important}" in css
    # A px row with an odd gutter: 2/3 of 25px off each column, the
    # remainder to the first column, 13px leading and 12px trailing.
    let r = EmailRenderer()
    let pdoc = newDoc(r)
    let row = r.child(r.child(pdoc, "mailSection"), "mailColumns",
      attrs = [("gutter", "25px")])
    for w in ["185px", "184px", "183px"]:
      r.para(r.child(row, "mailColumn", [("width", w)]), w)
    let p = renderTree(pdoc).html
    let pcss = responsive(p)
    for rule in [".e-colpx-169{max-width:169px;width:169px !important}",
        ".e-colpx-167{max-width:167px;width:167px !important}",
        ".e-colpx-166{max-width:166px;width:166px !important}",
        ".e-gutter-3-1-px-25{padding:0 13px 0 0 !important}",
        ".e-gutter-3-2-px-25{padding:0 13px 0 12px !important}",
        ".e-gutter-3-3-px-25{padding:0 0 0 12px !important}"]:
      check rule in pcss
    check "width=\"185\" style=\"width:185px;vertical-align:top;" in p
    check "width=\"184\" style=\"width:184px;vertical-align:top;" in p
    check "width=\"183\" style=\"width:183px;vertical-align:top;" in p
    for pad in ["0 13px 0 0", "0 13px 0 12px", "0 0 0 12px"]:
      check "<td style=\"padding:" & pad & ";\"><![endif]-->" in p
    # Negative control: a section's own columns have no gutter.
    let r2 = EmailRenderer()
    let d2 = newDoc(r2)
    let s2 = r2.child(d2, "mailSection")
    r2.para(r2.child(s2, "mailColumn"), "A")
    r2.para(r2.child(s2, "mailColumn"), "B")
    let h2 = renderTree(d2).html
    check "e-gutter" notin h2
    check "padding-top" notin h2

suite "reversal":
  test "test_mobile_reversal_through_dir":
    # R-LAY-11: an image beside text, reversed on desktop only: the row
    # runs right to left, every column back to left to right, the
    # source order (the mobile and reading order) unchanged.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection",
      attrs = [("reverse_on_mobile", "true")])
    r.image(r.child(s, "mailColumn"))
    r.para(r.child(s, "mailColumn"), "Text beside the picture")
    let res = renderTree(doc)
    check res.diagnostics.len == 0
    let html = res.html
    check "<div align=\"left\" dir=\"rtl\" style=\"padding:24px 0;" &
      "font-size:0.01px;text-align:left;direction:rtl;\">" in html
    check "width=\"100%\" dir=\"rtl\"><tr>" in html
    check html.count("<div dir=\"ltr\" class=\"e-col-50\" style=\"" &
      "display:inline-block;width:100%;vertical-align:top;" &
      "font-size:16px;text-align:left;direction:ltr;\">") == 2
    check html.find("<img") < html.find("Text beside the picture")
    # A gutter row reversed: the half-gutters mirror (-rtl classes).
    let r3 = EmailRenderer()
    let d3 = newDoc(r3)
    let row = r3.child(r3.child(d3, "mailSection"), "mailColumns",
      attrs = [("reverse_on_mobile", "true"), ("gutter", "24px")])
    r3.image(r3.child(row, "mailColumn"))
    r3.para(r3.child(row, "mailColumn"), "Words")
    let h3 = renderTree(d3).html
    check "<div dir=\"rtl\" style=\"font-size:0.01px;text-align:left;" &
      "direction:rtl;\">" in h3
    check ".e-gutter-2-1-per-4-347826-rtl{padding:0 0 0 2.173913% " &
      "!important}" in responsive(h3)
    check h3.find("<td style=\"padding:0 0 0 12px;\">") <
      h3.find("<td style=\"padding:0 12px 0 0;\">")
    # Restricted: two text columns, a right-to-left document, a cells
    # row.
    let r4 = EmailRenderer()
    let d4 = newDoc(r4)
    let both = r4.child(d4, "mailSection",
      attrs = [("reverse_on_mobile", "true")])
    r4.para(r4.child(both, "mailColumn"), "One")
    r4.para(r4.child(both, "mailColumn"), "Two")
    check codesOf(renderTree(d4).diagnostics) == @[codeLayoutReverseText]
    let r5 = EmailRenderer()
    let d5 = newDoc(r5, "rtl")
    let rtl = r5.child(d5, "mailSection",
      attrs = [("reverse_on_mobile", "true")])
    r5.image(r5.child(rtl, "mailColumn"))
    r5.para(r5.child(rtl, "mailColumn"), "نص")
    check codesOf(renderTree(d5).diagnostics) == @[codeLayoutReverseText]
    let r6 = EmailRenderer()
    let d6 = newDoc(r6)
    let cells = r6.child(r6.child(d6, "mailSection"), "mailColumns",
      attrs = [("strategy", "cells"), ("reverse_on_mobile", "true"),
        ("min_column", "72px")])
    r6.image(r6.child(cells, "mailColumn"))
    r6.para(r6.child(cells, "mailColumn"), "Words")
    check codeVocabBadValue in codesOf(renderTree(d6).diagnostics)

suite "client copies":
  test "test_thunderbird_and_owa_copies_cover_desktop_rules":
    let build = proc(t: EmailTarget): string =
      let r = EmailRenderer()
      let doc = newDoc(r)
      let s = r.child(doc, "mailSection")
      let a = r.child(s, "mailColumn")
      r.para(a, "A")
      r.setStyle(a.children[0], "@sm:padding", "8px")
      r.para(r.child(s, "mailColumn"), "B")
      responsive(renderTree(doc, target = t).html)
    # Default: the Thunderbird copy right after the min-width query,
    # outside it (Thunderbird applies no media query in a message), no
    # OWA copy; the phone rule is never copied.
    let def = build(defaultTarget())
    let q = def.find("@media only screen and (max-width: 479px)")
    check q > 0
    check "}}.moz-text-html .e-col-50{max-width:50%;width:50% !important}" &
      "@media only screen and (max-width: 479px){" in def
    check ".moz-text-html" notin def[q .. ^1]
    check "[owa]" notin def
    # OWA on, Thunderbird off: the OWA copy follows the min-width query,
    # outside it.
    var t = defaultTarget()
    t.owaDesktop = true
    t.thunderbirdMq = false
    let owa = build(t)
    check ".moz-text-html" notin owa
    check "}}[owa] .e-col-50{max-width:50%;width:50% !important}" &
      "@media only screen and (max-width: 479px){" in owa
    check owa.count("[owa]") == 1

suite "strategies":
  test "test_fab_four_columns":
    # R-LAY-18: the width switches without a media query; half-gutters
    # inside the column; the stacked gap from a max-width class.
    let (_, doc, _) = rowDoc("fabFour", "24px")
    let html = renderTree(doc).html
    check "<div style=\"display:inline-block;vertical-align:top;" &
      "width:calc((480px - 100%) * 480);" &
      "width:max(50%, calc((480px - 100%) * 480));min-width:50%;" &
      "max-width:100%;font-size:16px;text-align:left;direction:ltr;\">" &
      "<div class=\"e-stackpad-0-0-0-0\" style=\"padding:0 12px 0 0;\">" in
      html
    check "<div class=\"e-stackpad-24-0-0-0\" style=\"padding:0 0 0 12px;\">" in
      html
    let css = responsive(html)
    check "min-width" notin css
    check css == "@media only screen and (max-width: 479px)" &
      "{.e-stackpad-0-0-0-0{padding:0 0 0 0 !important}" &
      ".e-stackpad-24-0-0-0{padding:24px 0 0 0 !important}}"
    check "<td valign=\"top\" width=\"276\"" in html

  test "test_fab_four_width_is_a_fallback_pair":
    # R-LAY-18, R-CSS-19: each Fab Four column's inline style carries
    # the bare calc() width and then the max() width that keeps its
    # lower bound, both, in that order, at the width's place (before
    # min-width), for % and px rows; nothing else is doubled.
    proc styleOf(html: string; at: int): string =
      let s = html.rfind("style=\"", last = at) + 7
      html[s ..< html.find('"', s)]
    let pct = renderTree(rowDoc("fabFour", "", 3)[1]).html
    let px = block:
      let (_, doc, _) = rowDoc("fabFour", "", 2,
        @[@[("width", "200px")], @[("width", "400px")]])
      renderTree(doc).html
    for (html, w, n) in [(pct, "33.333333%", 3), (px, "200px", 1),
        (px, "400px", 1)]:
      let calc = "calc((480px - 100%) * 480)"
      let pair = "width:" & calc & ";width:max(" & w & ", " & calc &
        ");min-width:" & w & ";"
      check html.count(pair) == n
      let st = styleOf(html, html.find(pair))
      check st.startsWith("display:inline-block;vertical-align:top;" & pair &
        "max-width:100%;")
      check st.count("width:") == 4 # the pair, min-width, max-width
    # setStyle replaces a pair whole; the fallback never outlives it.
    let r = EmailRenderer()
    let d = r.createElement("div")
    r.setStyleWithFallback(d, "width", "calc(1px + 1%)", "max(1px, 2%)")
    r.setStyle(d, "width", "10px")
    check d.fallbacks.len == 0
    check d.styles["width"] == "10px"

  test "test_clone_tree_copies_fallback_pairs":
    # R-CSS-19: the render lowers a deep copy of the tree (`cloneTree`),
    # so a fallback pair must survive the copy, as its own value: the
    # clone serialises the pair, and editing it leaves the original.
    let r = EmailRenderer()
    let root = r.createElement("div")
    let d = r.createElement("div")
    r.setStyle(d, "display", "inline-block")
    r.setStyleWithFallback(d, "width", "calc(1px + 1%)", "max(1px, 2%)")
    r.setStyle(d, "min-width", "1px")
    r.appendChild(root, d)
    root.expanded = true
    let copy = cloneTree(root)
    check copy.expanded
    let c = copy.children[0]
    check c.fallbacks.len == 1
    check c.fallbacks["width"] == "calc(1px + 1%)"
    check serialize(c) == serialize(d)
    check "width:calc(1px + 1%);width:max(1px, 2%);min-width:1px;" in
      serialize(c)
    r.setStyle(c, "width", "10px")
    check d.fallbacks["width"] == "calc(1px + 1%)"

  test "test_cells_stacking_row":
    # R-LAY-19: one row of cells, the gutter a cell of its own, stacked
    # below the breakpoint by classes.
    let (_, doc, _) = rowDoc("cellsStacking", "24px", 2,
      @[@[("background-color", "#fde68a"), ("min-width", "100px")],
        @[("min-width", "100px")]])
    let res = renderTree(doc)
    check res.diagnostics.len == 0
    let html = res.html
    check "<table role=\"presentation\" width=\"100%\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" style=\"table-layout:fixed;\">" &
      "<tr><td class=\"e-cells-stack\" bgcolor=\"#fde68a\" valign=\"top\" width=\"47.826087%\" " &
      "style=\"width:47.826087%;vertical-align:top;" &
      "background-color:#fde68a;font-size:16px;text-align:left;" &
      "direction:ltr;\">" in html
    check "<td class=\"e-cells-gutter\" width=\"4.347826%\" " &
      "aria-hidden=\"true\" style=\"width:4.347826%;font-size:0.01px;" &
      "line-height:0;mso-line-height-rule:exactly;\">&nbsp;</td>" in html
    check "<td class=\"e-cells-stack e-stackpad-24-0-0-0\" valign=\"top\"" in
      html
    check responsive(html) == "@media only screen and (max-width: 479px)" &
      "{.e-cells-gutter{display:none !important}.e-cells-stack" &
      "{display:block !important;width:100% !important}" &
      ".e-stackpad-24-0-0-0{padding:24px 0 0 0 !important}}"
    # No ghost row: Word renders the cell table itself.
    check "<!--[if mso]><table role=\"presentation\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" width=\"100%\"" notin html

  test "test_cells_row":
    # R-LAY-20: the same table, never stacking: no classes, no rules.
    let (_, doc, _) = rowDoc("cells", "8px", 3,
      @[@[("min-width", "72px")], @[("min-width", "72px")],
        @[("min-width", "72px")]])
    let res = renderTree(doc)
    check res.diagnostics.len == 0
    let html = res.html
    check html.count("<td valign=\"top\" width=\"32.36715%\"") == 3
    check html.count("<td width=\"1.449275%\" aria-hidden=\"true\"") == 2
    check "class=" notin html[html.find("<body") .. ^1]
    check responsive(html) == ""

  test "test_column_boxes":
    # A column with a background, border, radius and padding: the box
    # is the column's inner div for everyone, the border on a frame Word
    # does not see, and a box of its own inside the ghost cell for Word.
    let (_, doc, _) = rowDoc("hybrid", "24px", 2,
      @[@[("background-color", "#e5e7eb"), ("padding", "8px"),
        ("border", "1px solid #9ca3af"), ("border-radius", "4px")]])
    let res = renderTree(doc)
    # Only the information that the boxed column is ragged (R-TBL-10).
    check codesOf(res.diagnostics) == @[codeTblRagged]
    let html = res.html
    # Word: the unpadded ghost cell, the half-gutter table, then the
    # column's box table (so the background stays out of the gutter).
    check "width=\"276\" style=\"width:276px;vertical-align:top;\">" &
      "<![endif]--><div class=\"e-col-47-826087 e-gutter-2-1-per-4-347826\"" in
      html
    check "<tr><td style=\"padding:0 12px 0 0;\"><![endif]--><!--[if mso]>" &
      "<table role=\"presentation\" width=\"100%\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\"><tr><td " &
      "bgcolor=\"#e5e7eb\" style=\"padding:8px;background-color:#e5e7eb;" &
      "border:1px solid #9ca3af;\"><![endif]--><!--[if !mso]><!--><div " &
      "style=\"border:1px solid #9ca3af;border-radius:4px;\"><!--<![endif]-->" &
      "<div style=\"padding:8px;background-color:#e5e7eb;" &
      "border-radius:4px;\"><p" in html
    # Without Outlook output the frame is a plain div around the box.
    let (_, doc2, _) = rowDoc("hybrid", "24px", 2,
      @[@[("border", "1px solid #9ca3af")]])
    var t = defaultTarget()
    t.outlookWord = false
    let plain = renderTree(doc2, target = t).html
    check "<div style=\"border:1px solid #9ca3af;\"><div><p" in plain
    check "<!--[if" notin plain[plain.find("<body") .. ^1]

  test "test_column_alignment_reaches_word":
    # R-TBL-14: a column's own alignment is attribute and CSS on the
    # innermost Word table of a hybrid column, and on a cell.
    let (_, doc, _) = rowDoc("hybrid", "24px", 2,
      @[@[("text-align", "center")]])
    let html = renderTree(doc).html
    check "<td align=\"center\" style=\"padding:0 12px 0 0;" &
      "text-align:center;\"><![endif]--><div style=\"text-align:center;\">" in
      html
    let (_, cdoc, _) = rowDoc("cells", "8px", 2,
      @[@[("text-align", "center"), ("min-width", "72px")],
        @[("min-width", "72px")]])
    let cells = renderTree(cdoc).html
    check cells.count("valign=\"top\" width=\"49.275362%\" " &
      "align=\"center\" style=") == 1
    check cells.count("width=\"49.275362%\" style=") == 1

  test "test_stack_never_keeps_columns_side_by_side":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", attrs = [("stack", "never")])
    r.para(r.child(s, "mailColumn"), "A")
    r.para(r.child(s, "mailColumn"), "B")
    let html = renderTree(doc).html
    check html.count("display:inline-block;width:50%;") == 2
    check "width:100%;vertical-align" notin html

  test "test_row_structure_errors":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    let row = r.child(s, "mailColumns", attrs = [("strategy", "grid")])
    r.para(r.child(row, "mailColumn"), "A")
    r.para(row, "Stray")
    let pct = r.child(r.child(doc, "mailSection"), "mailColumns",
      attrs = [("gutter", "5%")])
    r.para(r.child(pct, "mailColumn"), "B")
    let stray = r.child(doc, "mailColumn")
    r.para(stray, "Loose")
    let res = renderTree(doc)
    check codesOf(res.diagnostics) == @[codeVocabBadValue,
      codeStructNesting, codeVocabBadValue, codeStructNesting]
    for text in ["A", "Stray", "B", "Loose"]:
      check text in res.html
    check "<mailcolumn" notin res.html.toLowerAscii()

  test "test_layout_tables_carry_presentation_attributes":
    # R-LAY-15: every layout table the rows and the scaffolding emit,
    # inside Outlook conditionals or not, has role="presentation",
    # border, cellpadding, cellspacing and a width attribute; R-OL-08:
    # every fixed-width table and cell has its px width as an attribute
    # as well as in CSS.
    var tables, fixed = 0
    for strategy in ["hybrid", "fabFour", "cellsStacking", "cells"]:
      let (_, doc, _) = rowDoc(strategy, "16px", 3,
        @[@[("background-color", "#e5e7eb"), ("min-width", "72px")],
          @[("min-width", "72px")], @[("min-width", "72px")]])
      let html = renderTree(doc).html
      let body = html[html.find("<body") .. ^1]
      var i = 0
      while true:
        let t = body.find("<table", i)
        if t < 0:
          break
        let tag = body[t ..< body.find('>', t)]
        for attr in [" role=\"presentation\"", " border=\"0\"",
            " cellpadding=\"0\"", " cellspacing=\"0\"", " width=\""]:
          check attr in tag
        inc tables
        i = t + 6
      # Every table or cell whose CSS width is px.
      for opener in ["<table", "<td"]:
        i = 0
        while true:
          let t = body.find(opener, i)
          if t < 0:
            break
          let tag = body[t ..< body.find('>', t)]
          i = t + opener.len
          let st = tag.find("style=\"")
          if st < 0:
            continue
          let style = tag[st + 7 ..< tag.find('"', st + 7)]
          for decl in style.split(';'):
            if decl.startsWith("width:") and decl.endsWith("px"):
              check (" width=\"" & decl[6 ..< ^2] & "\"") in tag
              inc fixed
    # Non-vacuity: the four strategies emit tables and fixed widths.
    check tables >= 12
    check fixed >= 8

suite "the 320px check":
  test "test_320px_lint_for_cell_rows":
    # R-TBL-11: three text columns in a stacking cell row are 82px wide
    # at a 320px document, under the 160px text minimum.
    let (_, text, _) = rowDoc("cellsStacking", "24px", 3)
    let warned = renderTree(text).diagnostics
    check codesOf(warned) == @[codeLayoutMinColumn, codeLayoutMinColumn,
      codeLayoutMinColumn]
    for d in warned:
      check d.severity == sevWarning
      check "R-TBL-11" in d.rules
      check "82.8px" in d.message
    # Three stats declaring 72px minima, 8px apart, fit: 88px each.
    let (r, stats, row) = rowDoc("cells", "8px", 3)
    r.setAttribute(row, "min_column", "72px")
    check renderTree(stats).diagnostics.len == 0
    # Negative control: the same stats without their minima are text.
    let (_, plain, _) = rowDoc("cells", "8px", 3)
    check renderTree(plain).diagnostics.len == 3
    # Image-only columns default to 120px: 2 images at 129px pass.
    let (_, imgs, _) = rowDoc("cells", "8px", 2, texts = false)
    check renderTree(imgs).diagnostics.len == 0
    # A hybrid row stacks, so it is never checked.
    let (_, hybrid, _) = rowDoc("hybrid", "24px", 3)
    check renderTree(hybrid).diagnostics.len == 0
    # strict turns the warning into an error.
    let (_, strictDoc, _) = rowDoc("cellsStacking", "24px", 3)
    expect EmailRenderError:
      discard renderTree(strictDoc, strict = true)
