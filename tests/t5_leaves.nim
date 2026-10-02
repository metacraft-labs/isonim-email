## `mailSpacer` and `mailDivider` (`lower/leaves.nim`), a table nested
## in a rounded box, and the content leaves' story set.
##
## - A spacer is a hidden block exactly its height, with a sized Word
##   cell instead of it for Word; a divider is a bordered paragraph in a
##   padded block, with a px-wide Word table, its line taking the theme's
##   colour and, under `darkMode = designed`, its dark pair.
## - A table nested in a rounded `mailBox` does not inherit the box's
##   `border-collapse:separate`.
## - Every leaf story renders without an error and each registry entry
##   renders its own story.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[strutils, unittest]
import isonim_email
import stories/seed_leaves

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

proc newDoc(r: EmailRenderer): (EmailNode, EmailNode) =
  let doc = r.child(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", "Leaves")])
  discard r.child(doc, "h1", text = "Leaves")
  (doc, r.child(doc, "mailSection"))

proc body(html: string): string =
  html[html.find("<body") .. ^1]

suite "mailSpacer":
  test "test_spacer_is_a_hidden_block_of_its_height":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailSpacer")
    discard r.child(s, "mailSpacer", [("height", "48px")])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "<mailspacer" notin html.toLowerAscii()
    # The default height is the theme's space.4.
    check "<!--[if !mso]><!--><div aria-hidden=\"true\" style=\"height:16px;" &
      "line-height:16px;font-size:16px;\">&#8202;</div><!--<![endif]-->" in
      html
    check "<div aria-hidden=\"true\" style=\"height:48px;line-height:48px;" &
      "font-size:48px;\">&#8202;</div>" in html
    # Word gets a sized cell instead.
    check "<td height=\"48\" aria-hidden=\"true\" style=\"height:48px;" &
      "font-size:0;line-height:0;mso-line-height-rule:exactly;\">&nbsp;" in
      html
    var t = defaultTarget()
    t.outlookWord = false
    let plain = body(renderTree(doc.cloneTree, target = t).html)
    check "<td height=" notin plain
    check plain.count("&#8202;") == 2

  test "test_spacer_height_must_be_px":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailSpacer", [("height", "50%")])
    check codeVocabBadValue in (block:
      var codes: seq[string] = @[]
      for d in renderTree(doc).diagnostics:
        codes.add(d.code)
      codes)

suite "mailDivider":
  test "test_divider_defaults":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailDivider")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "<mailDivider" notin html
    # Everyone but Word: the line is a paragraph's top border in a
    # padded block.
    check "<!--[if !mso]><!--><div style=\"padding:16px 0;\"><p style=\"" &
      "border-top:1px solid #e5e7eb;font-size:1px;line-height:0;" &
      "margin:0 auto;width:100%;\">&nbsp;</p></div><!--<![endif]-->" in html
    # Word: a padded cell around a px-wide table drawing the line (the
    # section's 552px box).
    check "<td style=\"padding:16px 0;\"><![endif]--><!--[if mso]><table " &
      "role=\"presentation\" align=\"center\" border=\"0\" cellpadding=\"0\" " &
      "cellspacing=\"0\" width=\"552\" style=\"width:552px;border-top:1px " &
      "solid #e5e7eb;\">" in html

  test "test_divider_props":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailDivider", [("border", "2px dashed #1f6feb"),
      ("padding", "24px 0"), ("width", "50%")], [("align", "left")])
    discard r.child(s, "mailDivider", [("width", "120px")])
    let html = body(renderTree(doc).html)
    check "<div style=\"padding:24px 0;\"><p style=\"border-top:2px dashed " &
      "#1f6feb;font-size:1px;line-height:0;margin:0;width:50%;\">" in html
    check "width=\"276\" style=\"width:276px;border-top:2px dashed #1f6feb;\"" in
      html
    check "margin:0 auto;width:120px;" in html
    check "width=\"120\" style=\"width:120px;border-top:1px solid #e5e7eb;\"" in
      html

  test "test_divider_dark_pair_under_designed":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailDivider")
    var t = defaultTarget()
    t.darkMode = dmDesigned
    let html = renderTree(doc, target = t).html
    # color.border.subtle's dark value, through the paragraph's class.
    check "border-color:#2f343d !important" in html
    let p = html.split("<p class=\"")
    check p.len == 2
    let cls = p[1].split("\"")[0]
    check ("." & cls & "{border-color:#2f343d !important") in html

suite "tables nested in a rounded box":
  test "test_nested_table_does_not_inherit_separate":
    # `border-collapse` inherits; without head CSS a data table in a
    # rounded box would take the box's `separate`. The box's cell hands
    # `collapse` back.
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let b = r.child(s, "mailBox", [("border-radius", "8px"),
      ("border", "1px solid #e5e7eb")])
    discard r.child(b, "p", text = "Inside")
    let html = body(renderTree(doc).html)
    let table = html.find("border-collapse:separate !important;")
    check table >= 0
    let cell = html.find("<td ", table)
    check "border-collapse:collapse;" in html[cell ..< html.find('>', cell)]

suite "the content leaves' story set":
  test "test_leaf_stories_render":
    var names: seq[string] = @[]
    for s in leafStories:
      names.add(s.name)
      var t = defaultTarget()
      if s.dark:
        t.darkMode = dmDesigned
      let res = renderTree(s.build(), target = t)
      for d in res.diagnostics:
        checkpoint(s.name & ": " & $d)
        check d.severity != sevError
        check d.code notin [codeTblUnexpected, codeTblDeep,
          codeCssMsoUnlisted, codeLowerMissing]
    for prefix in ["text", "image", "spacer", "divider"]:
      for kind in ["Minimal", "Maximal", "Rtl", "ImagesOff", "Dark",
          "InContext"]:
        check (prefix & kind) in names

  test "test_each_leaf_story_renders_its_own_tree":
    registerLeafStories()
    var seen: seq[string] = @[]
    for s in leafStories:
      let (html, _) = getStory(s.name).render()
      check html == renderLeafStory(s.name).html
      check html notin seen
      seen.add(html)
