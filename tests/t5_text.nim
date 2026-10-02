# rule: R-TXT-02, R-TXT-04, R-TXT-09, R-TXT-11, R-OL-04, R-LAY-08
## The text leaves' inline defaults (`lower/text.nim`, applied by the
## style pass) and their lowering:
##
## - every heading, paragraph, list item and quotation carries its
##   margin, family, size, line height (with Word's exact rule) and
##   weight from the theme, the last block of its parent and an item of
##   a spacing primitive without a bottom margin; the author's own
##   declarations win, a larger size keeps its type's line-height ratio,
##   and type is inherited from an ancestor that sets it (`mailText`);
## - every link carries its colour and decoration (R-TXT-04);
## - lists reset their margin and padding and indent their items on the
##   start side (R-TXT-09), with no `mso-special-format`;
## - a quotation is lowered to a styled `div` (R-TXT-11);
## - `mailText` is a padded, aligned block with Word's ghost cell;
## - bare integer and boolean props compile in templates;
## - a default line height never falls below the font's content area;
## - content placed directly in the document is an implicit section
##   (R-LAY-08), so it never sits flush against the message's edges.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[strutils, tables, unittest]
import isonim_email

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

proc newDoc(r: EmailRenderer; dir = "ltr"; heading = true): EmailNode =
  result = r.child(nil, "mailDocument", attrs = [("lang",
    if dir == "rtl": "ar" else: "en"), ("dir", dir), ("title", "Text")])
  if heading:
    # A message needs an h1 (R-A11Y-03); in its own band, so the
    # sections under test start clean.
    discard r.child(r.child(result, "mailSection"), "h1", text = "Text")

proc styleOf(html, open: string; nth = 1): string =
  ## The style attribute of the `nth` element whose opening tag starts
  ## with `open` (e.g. `<h2`).
  var at = -1
  for i in 1 .. nth:
    at = html.find(open & " ", at + 1)
  if at < 0:
    return ""
  let tag = html[at ..< html.find('>', at)]
  let s = tag.find("style=\"")
  if s < 0:
    return ""
  tag[s + 7 ..< tag.find('"', s + 7)]

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

const family = "font-family:Helvetica, Arial, sans-serif;"

suite "text leaves carry their type inline":
  test "test_heading_and_paragraph_defaults":
    let r = EmailRenderer()
    let doc = newDoc(r, heading = false)
    let s = r.child(doc, "mailSection")
    for t in ["h1", "h2", "h3", "h4", "h5", "h6"]:
      discard r.child(s, t, text = t)
    discard r.child(s, "p", text = "First")
    discard r.child(s, "p", text = "Last")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = res.html
    check styleOf(html, "<h1") == "margin:0 0 16px;" & family &
      "font-size:28px;line-height:36px;font-weight:700;" &
      "overflow-wrap:break-word;color:#111827;mso-line-height-rule:exactly;"
    check styleOf(html, "<h2") == "margin:0 0 12px;" & family &
      "font-size:22px;line-height:30px;font-weight:700;" &
      "overflow-wrap:break-word;color:#111827;mso-line-height-rule:exactly;"
    check styleOf(html, "<h3") == "margin:0 0 8px;" & family &
      "font-size:18px;line-height:26px;font-weight:700;" &
      "overflow-wrap:break-word;color:#111827;mso-line-height-rule:exactly;"
    check "font-size:16px;line-height:24px;font-weight:700;" in
      styleOf(html, "<h4")
    check "font-size:14px;line-height:20px;font-weight:700;" in
      styleOf(html, "<h5")
    check "font-size:14px;line-height:20px;font-weight:700;" in
      styleOf(html, "<h6")
    check styleOf(html, "<p") == "margin:0 0 16px;" & family &
      "font-size:16px;line-height:24px;overflow-wrap:break-word;" &
      "color:#111827;mso-line-height-rule:exactly;"
    # An overlong word breaks rather than running past the edge.
    check "overflow-wrap:break-word;" notin styleOf(html, "<ul")
    # The last block of its parent has no bottom margin.
    check "<p style=\"margin:0;" & family in html

  test "test_author_values_win_and_sizes_keep_their_ratio":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    discard r.child(s, "h1", [("font-size", "40px")], text = "Big")
    discard r.child(s, "p", [("margin-bottom", "4px"), ("color", "#333333"),
      ("font-weight", "400")], text = "Mine")
    discard r.child(s, "p", [("font", "12px/16px Georgia, serif")],
      text = "Shorthand")
    discard r.child(s, "p", text = "End")
    let html = renderTree(doc).html
    # 40 × 36 / 28 = 51.4 → 51px.
    let big = styleOf(html, "<h1", 2)
    check "font-size:40px;" in big
    check "line-height:51px;" in big
    let mine = styleOf(html, "<p")
    check mine.startsWith("margin:0 0 16px;")
    check "margin-bottom:4px;" in mine
    check mine.find("margin-bottom:4px;") > mine.find("margin:0 0 16px;")
    check mine.count("color:") == 1
    check "color:#333333;" in mine
    # A `font` shorthand turns the type defaults off.
    let short = html.split("<p ")[2]
    check "font-size:" notin short.split(">")[0]

  test "test_type_is_inherited_from_an_ancestor":
    let r = EmailRenderer()
    let doc = newDoc(r)
    r.setStyle(doc, "font-family", "Georgia, serif")
    let s = r.child(doc, "mailSection")
    let t = r.child(s, "mailText", [("font-size", "14px"),
      ("padding", "8px 16px")], [("align", "center")])
    discard r.child(t, "h2", text = "Heading")
    discard r.child(t, "p", text = "Small")
    let html = renderTree(doc).html
    # 14px from the block, its line height at body type's ratio (24/16).
    check "font-family:Georgia, serif;font-size:14px;line-height:21px;" in
      styleOf(html, "<p")
    # A heading takes the family, but keeps its level's size.
    check "font-family:Georgia, serif;font-size:22px;line-height:30px;" in
      styleOf(html, "<h2")

  test "test_items_of_spacing_primitives_have_no_margin":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let st = r.child(r.child(doc, "mailSection"), "mailStack",
      [("gap", "12px")])
    discard r.child(st, "p", text = "One")
    discard r.child(st, "p", text = "Two")
    let html = renderTree(doc).html
    check html.count("<p style=\"margin:0;") == 2

  test "test_word_rule_follows_each_px_line_height":
    # rule: R-OL-04
    # Block text keeps its vertical margin (it is one of the elements
    # that may carry one); Word's exact line height rides with each px
    # line height, and only when Word is targeted.
    let r = EmailRenderer()
    let doc = newDoc(r)
    discard r.child(r.child(doc, "mailSection"), "p", text = "One")
    var t = defaultTarget()
    t.outlookWord = false
    let without = renderTree(doc.cloneTree, target = t)
    check "mso-line-height-rule" notin styleOf(without.html, "<p")
    let withWord = renderTree(doc.cloneTree)
    check "line-height:24px;overflow-wrap:break-word;color:#111827;" &
      "mso-line-height-rule:exactly;" in
      styleOf(withWord.html, "<p")
    check codeLayoutMarginConverted notin codesOf(withWord.diagnostics)

suite "links":
  test "test_links_carry_colour_and_decoration":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    let body = r.child(s, "p")
    discard r.child(body, "a", attrs = [("href", "https://x.test/a")],
      text = "body link")
    let foot = r.child(s, "p", [("color", "#f9fafb"),
      ("background-color", "#1f2937")])
    discard r.child(foot, "a", attrs = [("href", "https://x.test/b")],
      text = "footer link")
    let own = r.child(s, "p")
    discard r.child(own, "a", [("color", "#cf222e"),
      ("text-decoration", "none")], [("href", "https://x.test/c")],
      text = "own")
    let pic = r.child(s, "a", attrs = [("href", "https://x.test/d")])
    discard r.child(pic, "mailImage", [("width", "120px")],
      [("src", "https://x.test/logo.png"), ("alt", "Logo")])
    let html = renderTree(doc).html
    check "<a href=\"https://x.test/a\" style=\"color:#1f6feb;" &
      "text-decoration:underline;\">" in html
    # In text the author coloured, a link keeps that colour, underlined.
    check "<a href=\"https://x.test/b\" style=\"color:#f9fafb;" &
      "text-decoration:underline;\">" in html
    check "<a href=\"https://x.test/c\" style=\"color:#cf222e;" &
      "text-decoration:none;\">" in html
    # A link around images only is not underlined.
    check "<a href=\"https://x.test/d\" style=\"color:#1f6feb;" &
      "text-decoration:none;\">" in html

  test "test_link_dark_pair_under_designed":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let p = r.child(r.child(doc, "mailSection"), "p")
    discard r.child(p, "a", attrs = [("href", "https://x.test/a")],
      text = "body link")
    var t = defaultTarget()
    t.darkMode = dmDesigned
    let html = renderTree(doc, target = t).html
    # color.link's dark value reaches the dark block through a class.
    check "#7aa7ff" in html
    var t2 = defaultTarget()
    t2.darkMode = dmAccommodate
    check "#7aa7ff" notin renderTree(doc.cloneTree, target = t2).html

suite "lists":
  test "test_lists_reset_and_indent_on_the_start_side":
    for dir in ["ltr", "rtl"]:
      let r = EmailRenderer()
      let doc = newDoc(r, dir)
      let s = r.child(doc, "mailSection")
      let ul = r.child(s, "ul")
      discard r.child(ul, "li", text = "One")
      discard r.child(ul, "li", text = "Two")
      discard r.child(s, "p", text = "After")
      let html = renderTree(doc).html
      check styleOf(html, "<ul") == "margin:0 0 16px;padding:0;"
      let li = styleOf(html, "<li")
      if dir == "ltr":
        check li.startsWith("margin:0 0 8px 24px;" & family)
        check "<li style=\"margin:0 0 0 24px;" in html
      else:
        check li.startsWith("margin:0 24px 8px 0;" & family)
        check "<li style=\"margin:0 24px 0 0;" in html
      check "font-size:16px;line-height:24px;" in li
      # Not until a Word-engine capture admits it (R-OL-15).
      check "mso-special-format" notin html

suite "quotations":
  test "test_blockquote_lowers_to_a_styled_div":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    discard r.child(s, "blockquote", text = "Quoted")
    discard r.child(s, "p", text = "After")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    check "<blockquote" notin res.html
    check "<div style=\"margin:0 0 16px;padding:0 0 0 16px;" &
      "border-left:3px solid #e5e7eb;" & family in res.html
    # The semantic tree keeps the quotation.
    check res.semantic.children[1].children[0].tag == "blockquote"

suite "mailText":
  test "test_mail_text_is_a_padded_block":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    let t = r.child(s, "mailText", [("padding", "8px 16px"),
      ("background-color", "#f8f9fb")], [("align", "center")])
    discard r.child(t, "p", text = "Inside")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    check "<mailtext" notin res.html.toLowerAscii()
    # Its own type (the theme's body type: it is a text block too) and
    # background on the div.
    check "<div align=\"center\" style=\"padding:8px 16px;" &
      "text-align:center;" & family & "font-size:16px;line-height:24px;" &
      "overflow-wrap:break-word;background-color:#f8f9fb;" in res.html
    # Word's cell carries the padding, background and alignment.
    check "<td bgcolor=\"#f8f9fb\" align=\"center\" style=\"padding:8px " &
      "16px;background-color:#f8f9fb;text-align:center;\">" in res.html
    var t2 = defaultTarget()
    t2.outlookWord = false
    check "<!--[if mso]>" notin renderTree(doc.cloneTree,
      target = t2).html.split("<body")[1]

proc propsTpl(r: EmailRenderer; n: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Props"):
      h1: text "Props"
      mailSection(full_width = true):
        mailGrid(columns = 3, gutter = "8px"):
          p: text "a"
          p: text "b"
          p: text "c"
        mailSpacer(height = 24)

suite "bare props in templates":
  test "test_bare_integer_and_boolean_props_compile":
    # `mailGrid(columns = 3)`, `full_width = true` and `height = 24`
    # compile and lower as their quoted forms do.
    let tree = renderAuthoringTree(propsTpl, 0)
    let sec = tree.children[1]
    check sec.attrs["full_width"] == "true"
    check sec.children[0].attrs["columns"] == "3"
    check sec.children[1].styles["height"] == "24"
    let res = renderEmail(propsTpl, 0)
    check not hasErrors(res.diagnostics)
    check res.html.count("e-grid-item") >= 3
    check "height:24px;line-height:24px;font-size:24px;" in res.html

suite "the top of the message":
  test "test_default_line_height_never_below_the_content_area":
    # A theme whose heading type is tighter than its glyphs: the default
    # line height is raised to the content area (28 × 1.2 = 34px); the
    # theme's own scale is above it everywhere.
    var theme = defaultTheme()
    theme.values["type.h1"] = ThemePair(light: "28px/28px/700",
      dark: "28px/28px/700")
    let r = EmailRenderer()
    let doc = newDoc(r, heading = false)
    discard r.child(r.child(doc, "mailSection"), "h1", text = "Tight")
    let html = renderTree(doc, theme = theme).html
    check "font-size:28px;line-height:34px;" in styleOf(html, "<h1")
    let plain = renderTree(block:
      let r2 = EmailRenderer()
      let d2 = newDoc(r2, heading = false)
      discard r2.child(r2.child(d2, "mailSection"), "h1", text = "Theme")
      d2).html
    check "font-size:28px;line-height:36px;" in styleOf(plain, "<h1")
    # An author's own line height is the author's.
    let own = renderTree(block:
      let r3 = EmailRenderer()
      let d3 = newDoc(r3, heading = false)
      discard r3.child(r3.child(d3, "mailSection"), "h1",
        [("line-height", "28px")], text = "Mine")
      d3).html
    check "line-height:28px;" in styleOf(own, "<h1")

  test "test_loose_document_content_is_an_implicit_section":
    # rule: R-LAY-08
    let r = EmailRenderer()
    let doc = newDoc(r, heading = false)
    discard r.child(doc, "h1", text = "Loose")
    discard r.child(doc, "p", text = "Also loose")
    discard r.child(doc, "mailSection")
    discard r.child(doc, "p", text = "Loose again")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let sem = res.semantic
    check sem.children.len == 3
    check sem.children[0].tag == "mailSection"
    check sem.children[0].children.len == 2
    check sem.children[2].tag == "mailSection"
    # The heading gets the section's padding (24px all round).
    check "padding:24px;font-size:16px;text-align:left;direction:ltr;\">" &
      "<h1 " in res.html
    # Idempotent: a second expansion leaves the tree as it is.
    discard expandPatterns(sem, defaultTheme(), defaultTarget())
    check sem.children.len == 3
    # A column outside a row is not wrapped: it stays a nesting error.
    let r2 = EmailRenderer()
    let d2 = newDoc(r2)
    discard r2.child(r2.child(d2, "mailColumn"), "p", text = "Stray")
    check codeStructNesting in codesOf(renderTree(d2).diagnostics)
