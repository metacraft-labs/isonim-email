# rule: R-TBL-07, R-TBL-09, R-TBL-10, R-TBL-12, R-TBL-16, R-TBL-17
## The layout primitives `mailBox`, `mailGrid`, `mailCluster` and
## `mailSidebar`, lowered (`lower/box.nim`, `grid.nim`, `cluster.nim`,
## `sidebar.nim`), laid out (P3), linted (P10) and validated (P1).
##
## - A box is a single-cell table; a shadow always comes with a border
##   one step darker than the background (R-TBL-09); a radius needs
##   `border-collapse:separate` and the 3×3 Outlook corner box is not
##   built, so asking for it is reported (R-TBL-16).
## - A grid is a row of inline-block items with Word's ghost table
##   chunked into rows of N, the last row padded with sized spacer
##   cells; two per row on a phone is a composition of rows; three
##   columns with two on a phone is an error.
## - A cluster is inline items with the gap as padding and a single-row
##   ghost table; interactive items keep 8px apart (R-TBL-12).
## - A sidebar is a two-cell table, or a hybrid pair when it switches;
##   an image-only side beside text gets `&zwnj;` for Word (R-TBL-07).
## - Items of rows that do not share a height and paint a box are
##   flagged `I-TBL-RAGGED` (R-TBL-10).
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[strutils, unittest]
import isonim_email
import stories/seed_primitives

proc newDoc(r: EmailRenderer; dir = "ltr"): EmailNode =
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", if dir == "rtl": "ar" else: "en")
  r.setAttribute(result, "dir", dir)
  r.setAttribute(result, "title", "Primitives")
  let h = r.createElement("h1")
  r.setTextContent(h, "Primitives")
  r.appendChild(result, h)

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
  r.appendChild(parent, result)

proc inSection(): (EmailRenderer, EmailNode, EmailNode) =
  let r = EmailRenderer()
  let doc = newDoc(r)
  (r, doc, r.child(doc, "mailSection"))

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc body(html: string): string =
  html[html.find("<body") .. ^1]

proc msoPayload(html: string): string =
  ## Everything Word alone sees, concatenated in order.
  var i = 0
  while true:
    let a = html.find("<!--[if mso]>", i)
    if a < 0:
      return
    let e = html.find("<![endif]-->", a)
    result.add(html[a + 13 ..< e])
    i = e

proc responsive(html: string): string =
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

proc noErrors(res: RenderedEmail) =
  for d in res.diagnostics:
    checkpoint($d)
    check d.severity != sevError

suite "mailBox":
  test "test_box_is_a_single_cell_table":
    let (r, doc, s) = inSection()
    let b = r.child(s, "mailBox", [("background-color", "#f3f4f6")])
    discard r.child(b, "p", text = "Boxed")
    let rounded = r.child(s, "mailBox", [("border", "1px solid #9ca3af"),
      ("border-radius", "8px"), ("padding", "12px 16px")])
    discard r.child(rounded, "p", text = "Rounded")
    let res = renderTree(doc)
    noErrors(res)
    # Default padding space.5 (24px); background as bgcolor and CSS.
    check "<table role=\"presentation\" width=\"100%\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:" &
      "collapse;table-layout:fixed;\"><tr><td bgcolor=\"#f3f4f6\" style=\"padding:24px;" &
      "background-color:#f3f4f6;word-break:break-word;overflow-wrap:break-word;\"><p" in res.html
    # R-TBL-16: a radius rides on the cell, the table separate, with
    # `!important` against the reset's `border-collapse:collapse
    # !important`.
    check "style=\"border-collapse:separate !important;" &
      "table-layout:fixed;\"><tr><td " &
      "style=\"padding:12px 16px;border:1px solid #9ca3af;" &
      "border-radius:8px;border-collapse:collapse;word-break:break-word;" &
      "overflow-wrap:break-word;\"><p" in res.html
    # The cell hands its content `collapse` back: `border-collapse`
    # inherits, and without head CSS a data table nested in the box
    # would space its cells apart.
    # A real table everyone sees: no ghost table around it.
    check "border-collapse:collapse" notin msoPayload(res.html)
    # The content box: 552 less the padding.
    check b.layout.box == 552 - 48

  test "test_box_shadow_always_has_border":
    # R-TBL-09: every shadowed box has a border; without one of its own,
    # 1px, one step (0.1 OKLCH L) darker than its background.
    for (bg, shadow) in [("#ffffff", "sm"), ("#dbeafe", "md"),
        ("#1f2937", "sm"), ("", "md")]:
      let (r, doc, s) = inSection()
      var styles: seq[(string, string)] = @[]
      if bg.len > 0:
        styles.add(("background-color", bg))
      let b = r.child(s, "mailBox", styles, [("shadow", shadow)])
      discard r.child(b, "p", text = "Shadowed")
      let res = renderTree(doc)
      noErrors(res)
      let surface = if bg.len > 0: bg else: "#ffffff"
      let border = darkerStep(surface)
      checkpoint(bg & " " & shadow & " -> " & border)
      check "border:1px solid " & border & ";" in res.html
      check "box-shadow:" & shadowValue(shadow) & ";" in res.html
      # Darker, never the same colour.
      check border != surface
      let (l0, _, _) = rgbToOklch(parseColor(surface))
      let (l1, _, _) = rgbToOklch(parseColor(border))
      check abs((l0 - l1) - colourStep) < 0.02
    # An author's own border stays, and is not doubled.
    let (r, doc, s) = inSection()
    let b = r.child(s, "mailBox", [("border", "2px solid #2563eb")],
      [("shadow", "sm")])
    discard r.child(b, "p", text = "Own border")
    let html = renderTree(doc).html
    check "border:2px solid #2563eb;box-shadow:" in html
    check body(html).count("border:") == 1
    # Negative control: no shadow, no border added.
    let (r2, doc2, s2) = inSection()
    discard r2.child(r2.child(s2, "mailBox",
      [("background-color", "#ffffff")]), "p", text = "Plain")
    check "border:1px" notin renderTree(doc2).html

  test "test_box_outlook_rounded_is_reported":
    # R-TBL-16: the 3×3 VML-corner box ships only with Word-engine
    # evidence; asking for it is reported, the box still lowers square.
    let (r, doc, s) = inSection()
    let b = r.child(s, "mailBox", [("border-radius", "12px"),
      ("background-color", "#ffffff")], [("outlook_rounded", "true")])
    discard r.child(b, "p", text = "Rounded for Outlook")
    let res = renderTree(doc)
    check codesOf(res.diagnostics) == @[codeLowerMissing]
    check "R-TBL-16" in res.diagnostics[0].rules
    check "border-radius:12px" in res.html
    check "v:shape" notin res.html and "v:roundrect" notin res.html

suite "mailGrid":
  test "test_grid_mso_rows_chunked":
    # Five items three to a row: Word's ghost table is cut into two rows
    # (3 + 2), the last padded with one sized spacer cell; everyone else
    # gets five inline-block items.
    let (r, doc, s) = inSection()
    let g = r.child(s, "mailGrid", attrs = [("columns", "3")])
    for i in 1 .. 5:
      discard r.child(g, "p", text = "Item " & $i)
    let res = renderTree(doc)
    noErrors(res)
    let mso = msoPayload(res.html)
    check mso.count("</td></tr><tr>") == 1
    let rows = mso[mso.find("<table role=\"presentation\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" width=\"100%\"><tr>") .. ^1]
    let first = rows[0 ..< rows.find("</tr><tr>")]
    let second = rows[rows.find("</tr><tr>") .. ^1]
    # Row cells: 3 slots, then 2 items + 1 spacer, in the same columns
    # (192 = 168 + the 24px gutter, 168 for the row's last slot).
    check first.count("<td valign=\"top\"") == 3
    check second.count("<td valign=\"top\"") == 2
    check "width=\"192\"" in first and "width=\"168\"" in first
    check "</td><td width=\"168\" aria-hidden=\"true\" style=\"width:" &
      "168px;font-size:0;line-height:0;mso-line-height-rule:exactly;\">" &
      "&nbsp;" in second
    check res.html.count("class=\"e-grid-item\"") == 5
    # Negative control: six items fill both rows, no spacer.
    discard r.child(g, "p", text = "Item 6")
    let full = renderTree(doc).html
    check "aria-hidden=\"true\" style=\"width:168px;font-size:0" notin
      msoPayload(full)
    check msoPayload(full).count("</td></tr><tr>") == 1

  test "test_grid_items_and_gutters":
    let (r, doc, s) = inSection()
    let g = r.child(s, "mailGrid", attrs = [("columns", "3")])
    for i in 1 .. 4:
      discard r.child(g, "p", text = "Item " & $i)
    let res = renderTree(doc)
    let html = body(res.html)
    # (552 − 2·24)/3 = 168; an item that does not end its row carries the
    # gutter on its trailing side, and every item but the last the gutter
    # below it (so items that wrap without CSS keep a gap too).
    check html.count("max-width:192px;") == 2
    check "<div class=\"e-stackpad-0-0-0-0\" style=\"padding:0 24px 24px 0;\">" in
      html
    check "<div class=\"e-stackpad-24-0-0-0\" style=\"padding:0 24px 24px 0;\">" in
      html
    check "<div class=\"e-stackpad-24-0-0-0\" style=\"padding:0 0 24px;\">" in
      html
    check "<div class=\"e-stackpad-24-0-0-0\"><p" in html # the last item
    # Word: the last item drops its gutter, but its slot keeps one, so
    # its content box matches the column above (168px).
    check "<td style=\"padding:0 24px 0 0;\"><![endif]--><div class=\"" &
      "e-stackpad-24-0-0-0\"><p" in html
    # The cap is a fallback pair (R-CSS-19): px, then its share of the
    # row floored to 4 decimals, never below `min_item` (160) plus the
    # trailing gutter, so a row a client narrows still holds N items.
    check html.count("max-width:192px;max-width:max(184px, 34.7826%);") == 2
    check "max-width:168px;max-width:max(160px, 30.4347%);" in html
    # Items break long words (R-TBL-17).
    check html.count("direction:ltr;word-break:break-word;overflow-wrap:break-word;\"><!--") == 4
    # The container: a zero font size (R-LAY-04), nothing in between.
    check "<div style=\"font-size:0.01px;text-align:left;direction:ltr;\">" &
      "<!--[if mso]>" in html
    # Below the breakpoint, with head CSS: one per row, gap on top.
    let css = responsive(res.html)
    let mobile = css[css.find("max-width: 479px") .. ^1]
    check ".e-grid-item{max-width:100% !important;width:100% !important}" in
      mobile
    check ".e-stackpad-24-0-0-0{padding:24px 0 0 0 !important}" in mobile
    check ".e-stackpad-0-0-0-0{padding:0 0 0 0 !important}" in mobile
    # Widths: px remainder to the first items of each row.
    check gridItemWidths(553, 3, 24, 4, "left") == @[169, 168, 168, 169]
    check gridItemWidths(552, 3, 24, 4, "stretch") == @[168, 168, 168, 552]
    check gridItemWidths(552, 2, 16, 3, "stretch") == @[268, 268, 552]

  test "test_grid_last_row_center_and_stretch":
    for lastRow in ["center", "stretch"]:
      let (r, doc, s) = inSection()
      let g = r.child(s, "mailGrid", attrs = [("columns", "3"),
        ("last_row", lastRow)])
      for i in 1 .. 4:
        discard r.child(g, "p", text = "Item " & $i)
      let res = renderTree(doc)
      noErrors(res)
      let mso = msoPayload(res.html)
      # The last row in a ghost table of its own, no spacer cells. (The
      # other match is the heading's implicit section closing before the
      # grid's section opens.)
      check mso.count("</td></tr></table><table role=\"presentation\"") == 2
      check "aria-hidden=\"true\" style=\"width:" notin mso
      if lastRow == "center":
        check "<table role=\"presentation\" align=\"center\" border=\"0\"" in
          mso
        check "font-size:0.01px;text-align:center;" in res.html
        # The last item has no trailing gutter: centred exactly.
        check "max-width:168px;" in res.html
      else:
        check "width=\"552\" style=\"width:552px;" in mso
        check "max-width:552px;" in res.html

  test "test_grid_two_per_row_on_a_phone":
    # Four columns, two on a phone: per desktop row an outer hybrid row
    # of two cells rows, so it goes 4-up → 2-up, never 1-up.
    let (r, doc, s) = inSection()
    let g = r.child(s, "mailGrid", attrs = [("columns", "4"),
      ("mobile_columns", "2"), ("min_item", "72px")])
    for i in 1 .. 4:
      discard r.child(g, "p", text = "S" & $i)
    let res = renderTree(doc)
    noErrors(res)
    check res.diagnostics.len == 0
    check g.expanded
    let html = body(res.html)
    check html.count("e-gutter-2-") == 2 # the outer hybrid row's columns
    check html.count("<td width=\"9.090909%\" aria-hidden=\"true\"") == 2
    check "e-grid-item" notin html
    # Item widths match a 4-up grid: ((552 − 24)/2 − 24)/2 = 120.
    let tbls = html.count("<td valign=\"top\" width=\"45.454545%\"")
    check tbls == 4
    # Five items: the last pair holds one item and an empty slot.
    let (r5, doc5, s5) = inSection()
    let g5 = r5.child(s5, "mailGrid", attrs = [("columns", "4"),
      ("mobile_columns", "2"), ("min_item", "72px")])
    for i in 1 .. 5:
      discard r5.child(g5, "p", text = "S" & $i)
    let res5 = renderTree(doc5)
    noErrors(res5)
    for i in 1 .. 5:
      check ">S" & $i & "</p>" in res5.html
    # The empty slot holds a no-break space, never nothing (R-TBL-05).
    check ">\u00a0</td>" in res5.html
    # Three columns with two on a phone orphan an item: P1 error.
    let (r3, doc3, s3) = inSection()
    let g3 = r3.child(s3, "mailGrid", attrs = [("columns", "3"),
      ("mobile_columns", "2")])
    discard r3.child(g3, "p", text = "x")
    check codePatternGridOrphan in codesOf(renderTree(doc3).diagnostics)
    # Out-of-range counts are bad values.
    let (r6, doc6, s6) = inSection()
    let g6 = r6.child(s6, "mailGrid", attrs = [("columns", "6")])
    discard r6.child(g6, "p", text = "x")
    check codeVocabBadValue in codesOf(renderTree(doc6).diagnostics)

suite "mailCluster":
  test "test_cluster_items_and_single_row_ghost_table":
    let (r, doc, s) = inSection()
    let c = r.child(s, "mailCluster", attrs = [("separator", "·")])
    for i in 1 .. 3:
      discard r.child(c, "a", attrs = [("href",
        "https://example.com/" & $i)], text = "Link " & $i)
    let res = renderTree(doc)
    noErrors(res)
    let html = body(res.html)
    # Gap 12px (space.3) as trailing padding, the row gap below, the
    # last item flush; font size reset in a zero-size container.
    check html.count("<div style=\"display:inline-block;vertical-align:" &
      "middle;padding:0 12px 12px 0;font-size:16px;overflow-wrap:break-word;" &
      "max-width:100%;box-sizing:border-box;\">") == 2
    check html.count("<div style=\"display:inline-block;vertical-align:" &
      "middle;padding:0 0 12px;font-size:16px;overflow-wrap:break-word;" &
      "max-width:100%;box-sizing:border-box;\">") == 1
    check "<div style=\"font-size:0.01px;text-align:left;direction:ltr;\">" in
      html
    # The separator follows every item but the last, hidden from AT, in
    # the colour the cluster's text would inherit (R-TXT-02: a client's
    # dark default must not paint it).
    check html.count("<span aria-hidden=\"true\" style=\"color:#111827;" &
      "padding-left:12px;\">·</span>") == 2
    # Word ignores the span's padding: a space only Word sees.
    check html.count("</a><!--[if mso]>&nbsp;&nbsp;&nbsp;<![endif]--><span") ==
      2
    # Word: one row, one cell per item, the gap as cell padding.
    let mso = msoPayload(res.html)
    check mso.count("</tr><tr>") == 0
    check "<table role=\"presentation\" border=\"0\" cellpadding=\"0\" " &
      "cellspacing=\"0\"><tr><td style=\"padding:0 12px 0 0;\">" in mso
    check mso.count("<td style=\"padding:0 12px 0 0;\">") == 2
    check mso.count("</td><td>") == 1
    # Right to left: the gap and the separator on the left.
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2, "rtl")
    let c2 = r2.child(r2.child(doc2, "mailSection"), "mailCluster",
      attrs = [("align", "center"), ("gap", "16px")])
    for t in ["أ", "ب"]:
      discard r2.child(c2, "a", attrs = [("href", "https://example.com/")],
        text = t)
    let rtl = renderTree(doc2).html
    check "padding:0 0 16px 16px;" in rtl
    check "<table role=\"presentation\" align=\"center\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" dir=\"rtl\"><tr><td style=" &
      "\"padding:0 0 0 16px;\">" in msoPayload(rtl)

  test "test_cluster_tap_target_spacing":
    # R-TBL-12: interactive items keep ≥ 8px between hit areas.
    proc cluster(gap, rowGap: string; links = true): seq[string] =
      let (r, doc, s) = inSection()
      var styles: seq[(string, string)] = @[]
      if gap.len > 0:
        styles.add(("gap", gap))
      if rowGap.len > 0:
        styles.add(("row-gap", rowGap))
      let c = r.child(s, "mailCluster", styles)
      for i in 1 .. 3:
        if links:
          discard r.child(c, "a", attrs = [("href", "https://example.com/")],
            text = "L" & $i)
        else:
          discard r.child(c, "span", text = "B" & $i)
      for d in renderTree(doc).diagnostics:
        if d.code == codeA11yTapTarget:
          check "R-TBL-12" in d.rules
          result.add(d.message)
    check cluster("4px", "").len == 2 # the gap, and the row gap it sets
    check cluster("8px", "").len == 0
    check cluster("", "").len == 0 # the 12px default
    check cluster("12px", "6px").len == 1
    check "row_gap" in cluster("12px", "6px")[0]
    # Negative control: badges are not tap targets.
    check cluster("4px", "", links = false).len == 0

suite "mailSidebar":
  test "test_sidebar_two_cell_table":
    let (r, doc, s) = inSection()
    let sb = r.child(s, "mailSidebar", attrs = [("fixed", "64px")])
    discard r.child(sb, "p", text = "Tile")
    discard r.child(sb, "p", text = "Details beside the tile.")
    let right = r.child(s, "mailSidebar", attrs = [("fixed", "120px"),
      ("side", "right"), ("valign", "top"), ("gap", "24px")])
    discard r.child(right, "p", text = "Fluid first")
    discard r.child(right, "p", text = "Fixed second")
    let res = renderTree(doc)
    noErrors(res)
    let html = body(res.html)
    check "<table role=\"presentation\" width=\"100%\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" style=\"table-layout:fixed;\">" &
      "<tr><td width=\"64\" " &
      "valign=\"middle\" style=\"width:64px;vertical-align:middle;" &
      "text-align:left;direction:ltr;word-break:break-word;overflow-wrap:break-word;\"><p" in html
    check "<td valign=\"middle\" style=\"padding-left:16px;vertical-align:" &
      "middle;text-align:left;direction:ltr;word-break:break-word;overflow-wrap:break-word;\"><p" in
      html
    # Fixed side second: the gap on the fluid cell's right.
    check "<td valign=\"top\" style=\"padding-right:24px;vertical-align:" &
      "top;" in html
    check "<td width=\"120\" valign=\"top\" style=\"width:120px;" in html
    # The boxes: fixed, and the rest less the gap.
    check sb.children[0].kind == enElement
    # No ghost table: the table is the construct (R-TBL-01).
    check "<td width=\"64\"" notin msoPayload(res.html)
    # Right to left: the table runs rtl, the gap faces the fixed cell.
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2, "rtl")
    let sb2 = r2.child(r2.child(doc2, "mailSection"), "mailSidebar",
      attrs = [("fixed", "64px")])
    discard r2.child(sb2, "p", text = "أ")
    discard r2.child(sb2, "p", text = "ب")
    let rtl = renderTree(doc2).html
    check "cellspacing=\"0\" dir=\"rtl\" style=\"table-layout:fixed;\">" &
      "<tr><td width=\"64\"" in rtl
    check "padding-right:16px;vertical-align:middle;text-align:right;" &
      "direction:rtl;" in rtl

  test "test_sidebar_image_cell_zwnj":
    # R-TBL-07: an image-only side beside text gets `&zwnj;` after the
    # image, for Word only (elsewhere it would open a line under it).
    proc render(fixedImage, fluidText, word, switching: bool): string =
      let (r, doc, s) = inSection()
      var attrs = @[("fixed", "64px")]
      if switching:
        attrs.add(("switch_below", "200px"))
      let sb = r.child(s, "mailSidebar", attrs = attrs)
      if fixedImage:
        discard r.child(sb, "mailImage", [("width", "64px")],
          [("src", "https://img.example.com/a.png"), ("alt", "Avatar")])
      else:
        discard r.child(sb, "p", text = "Tile")
      if fluidText:
        discard r.child(sb, "p", text = "Line one. Line two. Line three.")
      else:
        discard r.child(sb, "mailImage", [("width", "64px")],
          [("src", "https://img.example.com/b.png"), ("alt", "Other")])
      var t = defaultTarget()
      t.outlookWord = word
      body(renderTree(doc, target = t).html)
    const zwnj = "<!--[if mso]>&zwnj;<![endif]-->"
    for switching in [false, true]:
      let html = render(true, true, true, switching)
      check html.count(zwnj) == 1
      # Right after the image, inside its cell.
      let img = html.find("<img ")
      check html.find(zwnj, img) == html.find('>', img) + 1
      # Negative controls: text beside text, image beside image, and no
      # Outlook output.
      check zwnj notin render(false, true, true, switching)
      check zwnj notin render(true, false, true, switching)
      check zwnj notin render(true, true, false, switching)

  test "test_sidebar_switching_pair":
    let (r, doc, s) = inSection()
    let sb = r.child(s, "mailSidebar", attrs = [("fixed", "160px"),
      ("switch_below", "280px")])
    discard r.child(sb, "p", text = "Thumbnail side")
    discard r.child(sb, "p", text = "Teaser text")
    let res = renderTree(doc)
    noErrors(res)
    let html = body(res.html)
    # 552 = (160 + 16) + 376: the first side carries the gap inside.
    check "<div class=\"e-sb-stack\" style=\"display:inline-block;" &
      "width:176px;max-width:100%;vertical-align:middle;" in html
    check "<div class=\"e-sb-stack\" style=\"display:inline-block;" &
      "width:100%;min-width:280px;max-width:376px;max-width:max(calc(100% " &
      "- 176px), calc((456px - 100%) * 9999));vertical-align:middle;" in
      html
    check "<div class=\"e-stackpad-0-0-0-0\" style=\"padding:0 16px 0 0;\">" in
      html
    check "<div class=\"e-stackpad-16-0-0-0\"><p" in html
    let mso = msoPayload(res.html)
    check "<td valign=\"middle\" width=\"176\" style=\"width:176px;" &
      "vertical-align:middle;\">" in mso
    check "<td valign=\"middle\" width=\"376\" style=\"width:376px;" in mso
    let css = responsive(res.html)
    check ".e-sb-stack{max-width:100% !important;width:100% !important}" in
      css
    check ".e-stackpad-16-0-0-0{padding:16px 0 0 0 !important}" in css
    # Reversal flips the desktop order through `dir`.
    r.setAttribute(sb, "reverse_on_mobile", "true")
    let rev = body(renderTree(doc).html)
    check "<div dir=\"rtl\" style=\"font-size:0.01px;text-align:right;" &
      "direction:rtl;\">" in rev
    check rev.count("<div class=\"e-sb-stack\" dir=\"ltr\"") == 2
    check "padding:0 0 0 16px;" in rev

  test "test_sidebar_checks":
    # A sidebar that never switches is checked at 320px (R-TBL-11):
    # 272 − 200 − 16 = 56px of text.
    let (r, doc, s) = inSection()
    let sb = r.child(s, "mailSidebar", attrs = [("fixed", "200px")])
    discard r.child(sb, "p", text = "Wide tile")
    discard r.child(sb, "p", text = "Squeezed text")
    let warned = renderTree(doc).diagnostics
    check codesOf(warned) == @[codeLayoutMinColumn]
    check "56.0px" in warned[0].message
    r.setAttribute(sb, "switch_below", "200px")
    check renderTree(doc).diagnostics.len == 0
    # A missing fixed width, a third child, a reversal that cannot be.
    let (r2, doc2, s2) = inSection()
    let bad = r2.child(s2, "mailSidebar",
      attrs = [("reverse_on_mobile", "true")])
    for t in ["a", "b", "c"]:
      discard r2.child(bad, "p", text = t)
    let codes = codesOf(renderTree(doc2).diagnostics)
    check codeVocabBadValue in codes # no fixed; reversal never switching
    check codeStructNesting in codes

suite "rows of unequal heights and the construction checks":
  test "test_ragged_items_are_flagged":
    # R-TBL-10: a boxed item in a row that does not share a height.
    proc infos(build: proc(r: EmailRenderer; s: EmailNode)): seq[string] =
      let (r, doc, s) = inSection()
      build(r, s)
      for d in renderTree(doc).diagnostics:
        if d.code == codeTblRagged:
          check d.severity == sevInfo
          check "R-TBL-10" in d.rules
          result.add(d.message)
    check infos(proc(r: EmailRenderer; s: EmailNode) =
      let row = r.child(s, "mailColumns")
      for t in ["A", "B"]:
        discard r.child(r.child(row, "mailColumn",
          [("background-color", "#ffffff")]), "p", text = t)).len == 1
    check infos(proc(r: EmailRenderer; s: EmailNode) =
      let g = r.child(s, "mailGrid", attrs = [("columns", "2")])
      for t in ["A", "B", "C"]:
        discard r.child(r.child(g, "mailBox",
          [("border", "1px solid #e5e7eb")]), "p", text = t)).len == 1
    # Negative controls: a cells row gives one height; unboxed items.
    check infos(proc(r: EmailRenderer; s: EmailNode) =
      let row = r.child(s, "mailColumns", attrs = [("strategy", "cells"),
        ("min_column", "72px")])
      for t in ["A", "B"]:
        discard r.child(r.child(row, "mailColumn",
          [("background-color", "#ffffff")]), "p", text = t)).len == 0
    check infos(proc(r: EmailRenderer; s: EmailNode) =
      let g = r.child(s, "mailGrid", attrs = [("columns", "2")])
      for t in ["A", "B"]:
        discard r.child(g, "p", text = t)).len == 0

  test "test_primitives_pass_the_construction_lint":
    # R-TBL-01: the box and the sidebar are table constructs; nothing a
    # primitive emits is an unexpected table, too deep, or an unlisted
    # mso-* property.
    let (r, doc, s) = inSection()
    let g = r.child(s, "mailGrid", attrs = [("columns", "2")])
    for i in 1 .. 3:
      let b = r.child(g, "mailBox", [("background-color", "#ffffff")],
        [("shadow", "sm")])
      let sb = r.child(b, "mailSidebar", attrs = [("fixed", "48px")])
      discard r.child(sb, "mailImage", [("width", "48px")],
        [("src", "https://img.example.com/a.png"), ("alt", "Icon")])
      discard r.child(sb, "p", text = "Item " & $i)
    let c = r.child(s, "mailCluster")
    discard r.child(c, "a", attrs = [("href", "https://example.com/")],
      text = "One")
    discard r.child(c, "a", attrs = [("href", "https://example.com/")],
      text = "Two")
    let res = renderTree(doc)
    for code in [codeTblUnexpected, codeTblDeep, codeCssMsoUnlisted,
        codeLowerMissing]:
      check code notin codesOf(res.diagnostics)
    check codeTblRagged in codesOf(res.diagnostics)
    noErrors(res)

suite "the primitives' story set":
  test "test_primitive_stories_render":
    # Every story of the set (layout-patterns.md §5) renders through the
    # pipeline without an error or a construction warning, and each
    # primitive has its six.
    var perGroup: seq[string] = @[]
    for s in primitiveStories:
      perGroup.add(s.name)
      let res = renderTree(s.build(), target = (block:
        var t = defaultTarget()
        if s.dark:
          t.darkMode = dmDesigned
        t))
      for d in res.diagnostics:
        checkpoint(s.name & ": " & $d)
        check d.severity != sevError
        check d.code notin [codeTblUnexpected, codeTblDeep,
          codeCssMsoUnlisted, codeLayoutMinColumn, codeA11yTapTarget]
    for prefix in ["box", "grid", "cluster", "sidebar"]:
      for kind in ["Minimal", "Maximal", "Rtl", "ImagesOff", "Dark",
          "InContext"]:
        check (prefix & kind) in perGroup

  test "test_each_primitive_story_renders_its_own_tree":
    # The registry's render closures each render their own story (a
    # closure capturing a loop variable would render the last story for
    # all of them).
    registerPrimitiveStories()
    var seen: seq[string] = @[]
    for s in primitiveStories:
      let (html, _) = getStory(s.name).render()
      check html == renderPrimitiveStory(s.name).html
      check html notin seen
      seen.add(html)

suite "fixes from the capture loop":
  test "test_sidebar_decoration_side_paints_its_cell":
    # A side without text that paints a background (an accent bar)
    # paints its whole cell, so it runs the height of the row; a side
    # with text keeps its background to itself.
    let (r, doc, s) = inSection()
    let sb = r.child(s, "mailSidebar", attrs = [("fixed", "4px")])
    discard r.child(sb, "div", [("background-color", "#1f6feb"),
      ("font-size", "1px")], text = "\u00a0")
    discard r.child(sb, "p", [("background-color", "#ddf4ff")],
      text = "A note beside its accent.")
    let html = body(renderTree(doc).html)
    check "<td width=\"4\" valign=\"middle\" bgcolor=\"#1f6feb\" " &
      "style=\"width:4px;vertical-align:middle;text-align:left;" &
      "direction:ltr;word-break:break-word;overflow-wrap:break-word;background-color:#1f6feb;\">" in
      html
    check "bgcolor=\"#ddf4ff\"" notin html

  test "test_stack_aligns_to_the_start_of_its_direction":
    # A stack without `align` aligns to the start of the direction its
    # content runs in: right in a right-to-left document or section.
    let r = EmailRenderer()
    let doc = newDoc(r, "rtl")
    let st = r.child(r.child(doc, "mailSection"), "mailStack")
    discard r.child(st, "p", text = "أ")
    let html = body(renderTree(doc).html)
    check "<div align=\"right\" style=\"text-align:right;\"><p" in html
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2)
    let sec = r2.child(doc2, "mailSection", attrs = [("direction", "rtl")])
    discard r2.child(r2.child(sec, "mailStack"), "p", text = "ب")
    check "<div align=\"right\" style=\"text-align:right;\"><p" in
      body(renderTree(doc2).html)
    let r3 = EmailRenderer()
    let doc3 = newDoc(r3)
    discard r3.child(r3.child(r3.child(doc3, "mailSection"), "mailStack"),
      "p", text = "x")
    check "<div align=\"left\" style=\"text-align:left;\"><p" in
      body(renderTree(doc3).html)

  test "test_document_dark_background_reaches_the_canvas":
    # The document's own `@dark:` background (a class P6 attaches to it)
    # reaches the wrapper and its table, which paint the canvas.
    let r = EmailRenderer()
    let doc = newDoc(r)
    r.setStyle(doc, "background-color", tok"color.surface.canvas")
    r.setStyle(doc, "@dark:background-color", tok"color.surface.canvas")
    discard r.child(r.child(doc, "mailSection"), "p", text = "x")
    var t = defaultTarget()
    t.darkMode = dmDesigned
    let html = renderTree(doc, target = t).html
    let cls = block:
      let a = html.find("aria-roledescription=\"email\"")
      let c = html.find("class=\"", a) + 7
      html[c ..< html.find('"', c)]
    check cls.startsWith("e-")
    check html.count("class=\"" & cls & "\"") == 2
    check "." & cls & "{background-color:#0f1115 !important}" in html
