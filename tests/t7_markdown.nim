## Markdown bodies (layout-patterns.md §4.7): `mailMarkdown(src)` reads
## its Markdown through isonim-docs's AST and expands into the library's
## leaves, node by node; the constructs the email side adds over that
## AST (emphasis, strikethrough, block quotes, thematic breaks, setext
## headings, hard breaks, autolinks, escapes, character references);
## what it never reads as markup (raw HTML, footnotes:
## `W-MARKDOWN-UNSUPPORTED`) and what it leaves out
## (`E-MARKDOWN-UNSUPPORTED`); relative links (`E-URL-SCHEME`); its
## props; and the text part that follows from the elements.
##
## Every test renders a hand-built tree through the full pipeline
## (`renderTree`) and reads the expansion in the semantic tree, written
## out as a compact outline (`tag[children]`, text as written, styles
## left out) so a test states the whole shape it expects.
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[strutils, tables, unittest]
import isonim_email

proc el(r: EmailRenderer; parent: EmailNode; tag: string;
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

proc bare(html: string): string =
  ## `html` without its `style="…"` attributes.
  var i = 0
  while i < html.len:
    if html.continuesWith(" style=\"", i):
      i = html.find('"', i + 8) + 1
    else:
      result.add(html[i])
      inc i

proc md(src: string; attrs: openArray[(string, string)] = [];
    target = defaultTarget(); rtl = false): RenderedEmail =
  ## A document whose section holds an `h1` and the Markdown body.
  let r = EmailRenderer()
  let doc = r.el(nil, "mailDocument", [("lang", if rtl: "he" else: "en"),
    ("dir", if rtl: "rtl" else: "ltr"), ("title", "Markdown")])
  let s = r.el(doc, "mailSection")
  discard r.el(s, "h1", text = "Markdown")
  discard r.el(s, "mailMarkdown", @[("src", src)] & @attrs)
  renderTree(doc, target = target)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    if d.severity != sevInfo:
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

proc outline(n: EmailNode): string =
  ## `tag[children]` (attributes named in `shown` as `tag(k=v)`), text
  ## as written; the pattern elements an expansion holds are written
  ## with their own expansion inside.
  const shown = ["href", "title", "tone", "label", "variant", "src", "alt",
    "caption", "decorative", "start"]
  if n.kind == enText:
    return n.text
  result = n.tag
  var attrs: seq[string] = @[]
  for k in shown:
    if k in n.attrs:
      attrs.add(k & "=" & n.attrs[k])
  if attrs.len > 0:
    result.add("(" & attrs.join(",") & ")")
  if n.children.len > 0:
    result.add("[")
    for c in n.children:
      result.add(outline(c))
    result.add("]")

proc body(res: RenderedEmail): string =
  ## The outline of the Markdown's expansion in the semantic tree: its
  ## root `mailStack`'s children, the patterns in it expanded.
  let m = res.semantic.find("mailMarkdown")
  require m != nil and m.expanded
  let root = m.children[0]
  check root.tag == "mailStack"
  for c in root.children:
    result.add(outline(c))
    result.add(" ")
  result = result.strip()

proc mapped(src: string; attrs: openArray[(string, string)] = [];
    reported: ref seq[EmailDiagnostic] = nil): string =
  ## The outline of what `src` maps to, before the patterns it holds
  ## (a callout, a code block) expand: the mapping's own shape.
  let r = EmailRenderer()
  let n = r.el(nil, "mailMarkdown", @[("src", src)] & @attrs)
  var diags = reported
  if diags == nil:
    new(diags)
  let ctx = ExpandCtx(theme: defaultTheme(), target: defaultTarget(), r: r,
    diagnostics: diags)
  for c in markdownNodes(ctx, n, readProps[MarkdownProps](n)):
    result.add(outline(c))
    result.add(" ")
  result = result.strip()

proc outlineOf(src: string; attrs: openArray[(string, string)] = []): string =
  ## `mapped`, once the full render of the same body is known to report
  ## no error.
  let res = md(src, attrs)
  for d in res.diagnostics:
    if d.severity == sevError:
      checkpoint(d.code & " " & d.message)
  check not hasErrors(res.diagnostics)
  mapped(src, attrs)

suite "mailMarkdown maps each node to a leaf":
  test "test_markdown_blocks_map_to_leaves":
    # Headings (with the offset), paragraphs, lists, fenced code (its
    # info string ignored, its indentation kept), a table (the hidden
    # caption its header labels), an admonition (a callout in its tone,
    # its word as the label), a button.
    let src = "# Top\n\n### Third\n\nA paragraph\nover two lines.\n\n" &
      "- one\n- **two**\n\n1. first\n2. second\n\n```nim\nlet x = 1\n" &
      "  indented\n```\n\n| Plan | Price |\n|---|---|\n| Pro | **$10** |\n" &
      "\n:::tip\nKeep it short.\n:::\n\n:::button href=\"https://e.x/go\" " &
      "variant=\"secondary\"\nOpen it\n:::\n"
    check outlineOf(src, [("heading_offset", "1")]) ==
      "h2[Top] h4[Third] p[A paragraph over two lines.] " &
      "ul[li[one]li[strong[two]]] ol[li[first]li[second]] " &
      "mailCodeBlock[let x = 1\n  indented] " &
      "mailTable(caption=Plan, Price)[table[thead[tr[th[Plan]th[Price]]]" &
      "tbody[tr[td[Pro]td[strong[$10]]]]]] " &
      "mailCallout(tone=success,label=Tip)[p[Keep it short.]] " &
      "mailButton(href=https://e.x/go,variant=outline)[Open it]"
    # The expansion went through every pass: the code block, the table
    # and the callout are expanded patterns in the semantic tree.
    let res = md(src)
    check res.semantic.find("mailCodeBlock").expanded
    check res.semantic.find("mailCallout").expanded
    check find(res.semantic.find("mailMarkdown"), "h1") != nil
    # The body is a stack, 16px between blocks; the text blocks' own
    # margins give way to it.
    let stack = res.semantic.find("mailMarkdown").children[0]
    check stack.tag == "mailStack"
    check stack.styles["gap"] == "16px"
    for c in stack.children:
      if c.kind == enElement and c.tag in ["p", "h1", "h3", "ul", "ol"]:
        check c.styles["margin"] == "0"
    # Every admonition kind has its tone.
    for (kind, tone, word) in [("note", "info", "Note"), ("tip", "success",
        "Tip"), ("important", "primary", "Important"), ("warning", "warning",
        "Warning"), ("caution", "danger", "Caution"), ("danger", "danger",
        "Danger")]:
      check outlineOf(":::" & kind & "\nBody.\n:::") ==
        "mailCallout(tone=" & tone & ",label=" & word & ")[p[Body.]]"
    # The offset stops at h6.
    check outlineOf("##### Five\n\n###### Six", [("heading_offset", "3")]) ==
      "h6[Five] h6[Six]"

  test "test_markdown_inline_maps_to_leaves":
    # Code, links (a title in the target), autolinks, images as blocks of
    # their own between the paragraphs their text makes.
    check outlineOf("Run `make` or read [the guide](https://e.x/g \"Guide\")" &
      " and <https://e.x/a>, or write <mailto:help@e.x>.") ==
      "p[Run codeInline[make] or read a(href=https://e.x/g,title=Guide)" &
      "[the guide] and a(href=https://e.x/a)[https://e.x/a], or write " &
      "a(href=mailto:help@e.x)[help@e.x].]"
    check outlineOf("Before ![A chart](https://cdn.e.x/c.png) after.",
      [("image_width", "300")]) ==
      "p[Before] mailImage(src=https://cdn.e.x/c.png,alt=A chart) p[after.]"
    let res = md("![A chart](https://cdn.e.x/c.png)", [("image_width",
      "300px")])
    let img = res.semantic.find("mailImage")
    check img.styles["width"] == "300px"
    check img.attrs["fluid_on_mobile"] == "true"
    # An empty alt is a decorative image.
    check outlineOf("![](https://cdn.e.x/c.png)", [("image_width", "300")]) ==
      "mailImage(src=https://cdn.e.x/c.png,alt=,decorative=true)"

  test "test_markdown_emphasis_follows_the_delimiter_rules":
    # CommonMark's delimiter runs: `*` and `_` (intraword `_` is no
    # emphasis), nested strong and emphasis, the rule of three, escapes,
    # and unmatched delimiters left as text.
    check outlineOf("*a* _b_ **c** __d__ ***e*** ~~f~~") ==
      "p[em[a] em[b] strong[c] strong[d] em[strong[e]] s[f]]"
    check outlineOf("snake_case_name and 2 * 3 * 4 and **open") ==
      "p[snake_case_name and 2 * 3 * 4 and **open]"
    # An intraword `_` opens nothing (`foo_bar_` is no emphasis), where
    # an intraword `*` does.
    check outlineOf("foo_bar_ and foo*bar*") ==
      "p[foo_bar_ and fooem[bar]]"
    check outlineOf("\\*not em\\* and \\_not\\_ either") ==
      "p[*not em* and _not_ either]"
    check outlineOf("*foo**bar**baz*") == "p[em[foostrong[bar]baz]]"
    check outlineOf("**[bold link](https://e.x/)** and *`code`*") ==
      "p[strong[a(href=https://e.x/)[bold link]] and em[codeInline[code]]]"
    check outlineOf("[*em* in a link](https://e.x/)") ==
      "p[a(href=https://e.x/)[em[em] in a link]]"
    check outlineOf("~single~ is text") == "p[~single~ is text]"

  test "test_markdown_character_references":
    check outlineOf("&copy; 2026 &amp; &#8212; &#x2192; &bogus; & more") ==
      "p[© 2026 & — → &bogus; & more]"

suite "mailMarkdown reads what the docs AST leaves as text":
  test "test_markdown_quotes_breaks_and_setext_headings":
    # A quote (a lazy continuation line included) read as Markdown
    # again; a thematic break in each of its spellings; setext headings.
    check outlineOf("> A *quote*\ncontinued.\n>\n> - item\n\nAfter.") ==
      "blockquote[p[A em[quote] continued.]ul[li[item]]] p[After.]"
    check outlineOf("One\n\n---\n\nTwo\n\n* * *\n\n___\n") ==
      "p[One] mailDivider p[Two] mailDivider mailDivider"
    check outlineOf("Title\n=====\n\nSub *title*\nover two\n---\n\nText") ==
      "h1[Title] h2[Sub em[title] over two] p[Text]"
    # Nested quotes.
    check outlineOf("> outer\n>\n> > inner") ==
      "blockquote[p[outer]blockquote[p[inner]]]"

  test "test_markdown_hard_line_breaks":
    check outlineOf("Two spaces  \nthen a backslash\\\nthen none\nend") ==
      "p[Two spacesbrthen a backslashbrthen none end]"
    # A trailing marker at a paragraph's end is no break.
    check outlineOf("Last line  \n\nNext") == "p[Last line] p[Next]"

  test "test_markdown_code_and_blocks_are_left_as_written":
    # Inside a fence and a `:::` block, nothing is a quote, a break or a
    # heading underline.
    check outlineOf("```\n> not a quote\n---\n***\n```") ==
      "mailCodeBlock[> not a quote\n---\n***]"
    check outlineOf(":::note\nNot a break:\n---\n:::") ==
      "mailCallout(tone=info,label=Note)[p[Not a break: ---]]"

suite "mailMarkdown never reads markup":
  test "test_markdown_raw_html_and_footnotes_are_text":
    let res = md("Careful <b>here</b>, <!-- a comment --> and [^1].\n\n" &
      "[^1]: The note.\n\n<span>again</span>")
    # One warning per kind, never an error.
    check codesOf(res.diagnostics) == @["W-MARKDOWN-UNSUPPORTED",
      "W-MARKDOWN-UNSUPPORTED"]
    check body(res) == "p[Careful <b>here</b>, <!-- a comment --> and " &
      "[^1].] p[[^1]: The note.] p[<span>again</span>]"
    # Written as text: escaped in the HTML, never a tag.
    check "Careful &lt;b&gt;here&lt;/b&gt;" in res.html
    check "<b>here" notin res.html
    check "<span>again" notin res.html
    # A `<` that is prose is no tag.
    check codesOf(md("a < b and 3<4").diagnostics).len == 0

  test "test_markdown_docs_blocks_are_refused":
    for (src, what) in [(":::tabs\n@tab A\nx\n:::", "tabs"),
        (":::cards\n:::card title=\"A\"\nx\n:::\n:::", "card grid"),
        (":::hero title=\"A\"\n:::", "hero"),
        (":::faq\n:::q title=\"A\"\nx\n:::\n:::", "FAQ"),
        (":::video abc", "video"),
        (":::form submit=\"Go\"\n@field name=\"a\" label=\"A\"\n:::", "form"),
        ("<Widget size=\"2\"/>", "component tag")]:
      let res = md(src & "\n\nKept.")
      check codesOf(res.diagnostics) == @["E-MARKDOWN-UNSUPPORTED"]
      check what in res.diagnostics[0].message
      # The rest of the body is kept.
      check "Kept." in res.html

  test "test_markdown_relative_links_are_refused":
    let res = md("Read [the guide](docs/guide.md) or [home](/).")
    check codesOf(res.diagnostics) == @["E-URL-SCHEME", "E-URL-SCHEME"]
    let fine = md("[ok](https://e.x/), [mail](mailto:a@e.x), " &
      "[phone](tel:+15550100)")
    for d in fine.diagnostics:
      checkpoint(d.code & " " & d.message)
    check "E-URL-SCHEME" notin codesOf(fine.diagnostics)

  test "test_markdown_image_in_text_only_places_is_its_alt":
    let res = md("- ![Logo](https://cdn.e.x/l.png) item")
    check codesOf(res.diagnostics) == @["W-MARKDOWN-UNSUPPORTED"]
    check body(res) == "ul[li[Logo item]]"

suite "mailMarkdown's props and text part":
  test "test_markdown_props_are_checked":
    check "E-VOCAB-BAD-VALUE" in codesOf(md("").diagnostics)
    check "E-VOCAB-BAD-VALUE" in codesOf(md("x", [("heading_offset",
      "6")]).diagnostics)
    check "E-VOCAB-BAD-VALUE" in codesOf(md("x", [("heading_offset",
      "-1")]).diagnostics)
    check "E-VOCAB-BAD-VALUE" in codesOf(md("![a](https://e.x/a.png)",
      [("image_width", "wide")]).diagnostics)
    # An image of unknown size without image_width: the image rule.
    check "E-LAYOUT-IMAGE-WIDTH" in codesOf(md(
      "![a](https://e.x/a.png)").diagnostics)
    # Content inside the element is refused: the Markdown is its src.
    let r = EmailRenderer()
    let doc = r.el(nil, "mailDocument", [("lang", "en"), ("dir", "ltr"),
      ("title", "M")])
    let s = r.el(doc, "mailSection")
    discard r.el(s, "h1", text = "M")
    let m = r.el(s, "mailMarkdown", [("src", "x")])
    discard r.el(m, "p", text = "inside")
    check "E-VOCAB-BAD-VALUE" in codesOf(renderTree(doc).diagnostics)

  test "test_markdown_text_part_follows_the_elements":
    let res = md("## Steps\n\nRun **this**:\n\n```\nmake test\n```\n\n" &
      "> Quoted.\n\n---\n\n- [Docs](https://e.x/d)\n\n| A | B |\n|---|---|\n" &
      "| 1 | 2 |")
    check not hasErrors(res.diagnostics)
    let at = res.text.find("Steps")
    require at >= 0
    check res.text[at .. ^1] == "Steps\n-----\n\nRun this:\n\n" &
      "    make test\n\n  Quoted.\n\n----\n\n- Docs (https://e.x/d)\n\n" &
      "A, B\nA | B\n1 | 2\n"

  test "test_markdown_right_to_left":
    # The quote's bar and padding sit at the start side, the right.
    let res = md("> שלום עולם", rtl = true)
    check not hasErrors(res.diagnostics)
    check "border-right:3px solid" in res.html
    # A table's caption joins its labels with the comma of the language:
    # the Arabic comma in Arabic, a comma in Hebrew.
    let table = "| א | ב |\n|---|---|\n| 1 | 2 |"
    check md(table, rtl = true).semantic.find("mailTable").attrs[
      "caption"] == "א, ב"
    let r = EmailRenderer()
    let doc = r.el(nil, "mailDocument", [("lang", "ar"), ("dir", "rtl"),
      ("title", "جدول")])
    let s = r.el(doc, "mailSection")
    discard r.el(s, "h1", text = "جدول")
    discard r.el(s, "mailMarkdown", [("src", "| أ | ب |\n|---|---|\n| 1 | 2 |")])
    check renderTree(doc).semantic.find("mailTable").attrs["caption"] ==
      "أ\u060c ب"

suite "mailMarkdown nests lists":
  # The docs AST's lists are flat; the source pass reads list items by
  # CommonMark's container rules and reads each item's content as
  # Markdown again, so a sub-list is a list inside its item.
  test "test_markdown_two_level_lists_nest":
    check outlineOf("- one\n  - one-a\n  - one-b\n- two") ==
      "ul[li[oneul[li[one-a]li[one-b]]]li[two]]"
    # An ordered list keeps its numbers: the inner item is not the
    # outer list's second.
    check outlineOf("1. first\n   1. inner\n2. second") ==
      "ol[li[firstol[li[inner]]]li[second]]"

  test "test_markdown_three_level_lists_of_mixed_kinds_nest":
    check outlineOf("1. first\n   - bullet\n     1. deep\n     2. deeper\n" &
      "   - bullet two\n2. second") ==
      "ol[li[firstul[li[bulletol[li[deep]li[deeper]]]li[bullet two]]]" &
      "li[second]]"
    check outlineOf("- a\n  1. x\n  2. y\n     - z\n- b") ==
      "ul[li[aol[li[x]li[yul[li[z]]]]]li[b]]"
    # `*` and `+` bullets, `)` ordered markers, an item's inline content.
    check outlineOf("* **bold** item\n    + `code` inside\n        1) [a link](https://e.x/)") ==
      "ul[li[strong[bold] itemul[li[codeInline[code] insideol[li[" &
      "a(href=https://e.x/)[a link]]]]]]]"

  test "test_markdown_item_text_and_a_sub_list":
    # A paragraph over two lines, then its sub-list: the list follows
    # the item's text inside the same item, tight.
    check outlineOf("- Intro text\n  over two lines.\n  - sub one\n  - sub two\n" &
      "- next") ==
      "ul[li[Intro text over two lines.ul[li[sub one]li[sub two]]]li[next]]"
    # A lazy continuation line belongs to the item's paragraph.
    check outlineOf("- a\nlazy\n- b") == "ul[li[a lazy]li[b]]"
    # A marker alone is an empty item, not a lazy line (nor, after the
    # item's text, a setext underline).
    check outlineOf("- a\n-\n- c") == "ul[li[a]lili[c]]"
    # Text after the sub-list stays in the item.
    check outlineOf("- a\n  - b\n\n  after\n- c") ==
      "ul[li[p[a]ul[li[b]]p[after]]li[p[c]]]"

  test "test_markdown_tight_and_loose_lists":
    # Tight: the items hold their inline content.
    check outlineOf("- a\n- b") == "ul[li[a]li[b]]"
    # A blank line between items: one loose list (not two), its items'
    # paragraphs kept.
    check outlineOf("- a\n\n- b") == "ul[li[p[a]]li[p[b]]]"
    # A blank line between an item's blocks makes it loose too.
    check outlineOf("- Intro\n\n  - sub\n- next") ==
      "ul[li[p[Intro]ul[li[sub]]]li[p[next]]]"
    # A blank line inside the sub-list is the sub-list's: the outer list
    # stays tight, the inner one is loose.
    check outlineOf("- a\n  - b\n\n  - c\n- d") ==
      "ul[li[aul[li[p[b]]li[p[c]]]]li[d]]"
    # Blank lines after the last item end the list.
    check outlineOf("- a\n- b\n\nAfter.") == "ul[li[a]li[b]] p[After.]"
    # In the HTML a tight item holds its text, a loose one its `p`.
    let tight = bare(md("- a\n- b").html)
    check "<ul><li>a</li><li>b</li></ul>" in tight
    let loose = bare(md("- a\n\n- b").html)
    check "<ul><li><p>a</p></li><li><p>b</p></li></ul>" in loose
    # The text part writes items without blank lines between them,
    # loose or tight: both lists read the same.
    check "\n- a\n- b\n" in md("- a\n- b").text
    check "\n- a\n- b\n" in md("- a\n\n- b").text
    # A code block in a loose item.
    check outlineOf("- Run:\n\n  ```\n  make\n  ```\n- Done") ==
      "ul[li[p[Run:]mailCodeBlock[make]]li[p[Done]]]"

  test "test_markdown_list_boundaries_and_start":
    # Another marker kind starts another list.
    check outlineOf("- a\n* b") == "ul[li[a]] ul[li[b]]"
    check outlineOf("1. a\n1) b") == "ol[li[a]] ol[li[b]]"
    # An ordered list keeps its first number.
    check outlineOf("3. c\n4. d") == "ol(start=3)[li[c]li[d]]"
    let started = md("3. c\n4. d")
    check "<ol start=\"3\"" in started.html
    check "\n3. c\n4. d\n" in started.text
    # A list interrupts a paragraph; a thematic break is no item.
    check outlineOf("Text\n- item\n\n* * *") ==
      "p[Text] ul[li[item]] mailDivider"
    # An image in an item is still its alt text, reported.
    let res = md("- a\n  - ![Logo](https://cdn.e.x/l.png) item")
    check codesOf(res.diagnostics) == @["W-MARKDOWN-UNSUPPORTED"]
    check body(res) == "ul[li[aul[li[Logo item]]]]"

  test "test_markdown_nested_list_html":
    let res = md("- one\n  1. inner\n  2. more\n- two")
    check not hasErrors(res.diagnostics)
    let html = res.html
    # The inner list is inside the outer item, after its text.
    let at = html.find(">one<ol")
    check at >= 0
    let outerEnd = html.find("</ol></li>", at)
    check outerEnd > at
    # The inner items indent again on the start side (R-TXT-09); the
    # inner list is the item's last block: no bottom margin.
    let inner = html[at ..< outerEnd]
    check inner.count("<li ") == 2
    check "margin:0 0 8px 24px;" in inner
    check html.continuesWith("<ol style=\"margin:0;padding:0;\">", at + 4)
    # And the other way round: a bullet list inside a numbered item.
    let un = md("1. one\n   - inner\n2. two")
    check not hasErrors(un.diagnostics)
    let u = un.html.find(">one<ul style=\"margin:0;padding:0;\">")
    check u >= 0
    check un.html.find("</ul></li><li ", u) > u
    # In right to left the indent is on the right.
    let rtl = md("- אחד\n  - פנימי", rtl = true)
    check not hasErrors(rtl.diagnostics)
    let ri = rtl.html.find(">אחד<ul")
    check ri >= 0
    check "margin:0 24px 0 0;" in rtl.html[ri .. ^1]

  test "test_markdown_nested_list_text_part":
    # The text part indents a sub-list under its item's text by the
    # marker's width, with no blank line before it; an ordered list
    # keeps its numbers.
    let res = md("Steps:\n\n1. first\n   1. inner\n   2. inner two\n" &
      "      - deep\n2. second\n\n- a\n- b")
    check not hasErrors(res.diagnostics)
    let at = res.text.find("Steps:")
    require at >= 0
    check res.text[at .. ^1] == "Steps:\n\n1. first\n   1. inner\n" &
      "   2. inner two\n      - deep\n2. second\n\n- a\n- b\n"
    # A loose item's paragraphs keep their blank line; its sub-list
    # still follows directly.
    let loose = md("- Intro\n\n  More text.\n  - sub\n- next")
    let l = loose.text.find("- Intro")
    require l >= 0
    check loose.text[l .. ^1] == "- Intro\n\n  More text.\n  - sub\n- next\n"

  test "test_markdown_nested_lists_in_the_brief":
    # The review brief counts a sub-list as a nested list, not as one
    # more list of the body.
    let res = md("- one\n  - one-a\n  - one-b\n- two\n\nAnd:\n\n1. x")
    check not hasErrors(res.diagnostics)
    let lines = patternOf("mailMarkdown").expectedElements(
      res.semantic.find("mailMarkdown"), familyView("apple", "desktop"))
    check lines.len == 1
    check "a paragraph, 2 lists, a nested list, indented under its " &
      "item;" in lines[0]

suite "mailMarkdown starts blocks where CommonMark does":
  # A list interrupts a paragraph only when it is a bullet list or an
  # ordered list starting at 1 whose first item is not empty; a line
  # indented four or more spaces opens no block (indented code is not
  # read: the line is paragraph text).
  proc htmlBody(res: RenderedEmail): string =
    ## The HTML after the heading, styles left out.
    let h = bare(res.html)
    let at = h.find("Markdown</h1>")
    require at >= 0
    h[at .. ^1]

  proc textBody(res: RenderedEmail): string =
    ## The text part after the heading and its rule.
    let at = res.text.find("Markdown\n========\n")
    require at >= 0
    res.text[at + 18 .. ^1]

  test "test_markdown_a_bullet_list_interrupts_a_paragraph":
    check outlineOf("Text\n- item") == "p[Text] ul[li[item]]"
    let res = md("Text\n- item")
    check "<p>Text</p>" in htmlBody(res)
    check "<ul><li>item</li></ul>" in htmlBody(res)
    check textBody(res) == "\nText\n\n- item\n"

  test "test_markdown_an_ordered_list_from_1_interrupts_a_paragraph":
    check outlineOf("Text\n1. item") == "p[Text] ol[li[item]]"
    let res = md("Text\n1. item")
    check "<p>Text</p>" in htmlBody(res)
    check "<ol><li>item</li></ol>" in htmlBody(res)
    check textBody(res) == "\nText\n\n1. item\n"

  test "test_markdown_an_ordered_list_from_2_does_not_interrupt":
    check outlineOf("Text\n2. item") == "p[Text 2. item]"
    let res = md("Text\n2. item")
    check "<p>Text 2. item</p>" in htmlBody(res)
    check "<ol" notin htmlBody(res)
    check textBody(res) == "\nText 2. item\n"
    # Hard-wrapped prose stays one paragraph.
    let src = "Prices rose in\n2026. That year sales fell."
    check outlineOf(src) == "p[Prices rose in 2026. That year sales fell.]"
    let prose = md(src)
    check "<p>Prices rose in 2026. That year sales fell.</p>" in
      htmlBody(prose)
    check "<ol" notin htmlBody(prose)
    check "start=" notin htmlBody(prose)
    check textBody(prose) == "\nPrices rose in 2026. That year sales fell.\n"
    # The same line after a blank line starts the list, with its number.
    check outlineOf("Text\n\n2026. was") == "p[Text] ol(start=2026)[li[was]]"
    # A hard break before it and a setext underline under it still read.
    check outlineOf("Text  \n2026. was") == "p[Textbr2026. was]"
    check outlineOf("Text\n2026. was\n---") == "h2[Text 2026. was]"
    # The same holds in a list item's and in a quote's paragraph.
    check outlineOf("- Text\n  2026. was") == "ul[li[Text 2026. was]]"
    check outlineOf("> Text\n> 2. no") == "blockquote[p[Text 2. no]]"
    # Its text stays as typed, inside a code span the line above opens
    # too.
    check outlineOf("Text `a\n2. b` end") == "p[Text codeInline[a 2. b] end]"
    let code = md("Text `a\n2. b` end")
    check "<code dir=\"ltr\">a 2. b</code>" in htmlBody(code)
    check "&#" notin textBody(code)

  test "test_markdown_an_empty_item_does_not_interrupt":
    check outlineOf("Text\n*\nmore") == "p[Text * more]"
    check outlineOf("Text\n1.\nmore") == "p[Text 1. more]"
    let res = md("Text\n*\nmore")
    check "<p>Text * more</p>" in htmlBody(res)
    check "<ul" notin htmlBody(res)
    check textBody(res) == "\nText * more\n"
    let ord = md("Text\n1.\nmore")
    check "<ol" notin htmlBody(ord)
    check textBody(ord) == "\nText 1. more\n"
    # A `-` alone is still a setext underline.
    check outlineOf("Text\n-\n\nmore") == "h2[Text] p[more]"

  test "test_markdown_an_indented_line_opens_no_block":
    # Not a list: a paragraph of its own, its lines kept.
    let src = "Intro\n\n    - x\n    - y\nafter"
    check outlineOf(src) == "p[Intro] p[- xbr- y] p[after]"
    let res = md(src)
    check "<p>- x<br>- y</p>" in htmlBody(res)
    check "<ul" notin htmlBody(res)
    check textBody(res) == "\nIntro\n\n- x\n- y\n\nafter\n"
    check outlineOf("Intro\n\n    2. two") == "p[Intro] p[2. two]"
    # Nor a heading, a quote or a break.
    let blocks = md("Intro\n\n    # not\n    > no\n\n    ---\nafter")
    check body(blocks) == "p[Intro] p[# notbr> no] p[---] p[after]"
    check "<h1" notin htmlBody(blocks)
    check "<blockquote" notin htmlBody(blocks)
    check "<p># not<br>&gt; no</p>" in htmlBody(blocks)
    check "<p>---</p>" in htmlBody(blocks)
    check textBody(blocks) == "\nIntro\n\n# not\n> no\n\n---\n\nafter\n"
    # Under a paragraph's line, the paragraph's next line.
    check outlineOf("Para\n    - x") == "p[Para - x]"
    let para = md("Para\n    - x")
    check "<p>Para - x</p>" in htmlBody(para)
    check textBody(para) == "\nPara - x\n"
    check outlineOf("Para `a\n    - b` end") ==
      "p[Para codeInline[a - b] end]"
    let code = md("Para `a\n    - b` end")
    check "<code dir=\"ltr\">a - b</code>" in htmlBody(code)
    check "&#" notin textBody(code)

  test "test_markdown_list_items_still_take_their_indented_lines":
    # Indented to an item's content column, a line is the item's: a
    # sub-list, a continuation, a later block after a blank line.
    check outlineOf("- a\n    - b\n- c") == "ul[li[aul[li[b]]]li[c]]"
    check outlineOf("- a\n  - b\n    more\n- c") ==
      "ul[li[aul[li[b more]]]li[c]]"
    check outlineOf("Intro\n\n- a\n\n    - b") ==
      "p[Intro] ul[li[p[a]ul[li[b]]]]"
    check outlineOf("- a\n\n      code\n- b") ==
      "ul[li[p[a]p[code]]li[p[b]]]"
    let res = md("- a\n  - b\n    more\n- c")
    check "<ul><li>a<ul><li>b more</li></ul></li><li>c</li></ul>" in
      htmlBody(res)
    check textBody(res) == "\n- a\n  - b more\n- c\n"
    # Four spaces past the item's column is an indented line in the
    # item: no sub-list.
    check outlineOf("1. a\n\n       - x\n2. b") ==
      "ol[li[p[a]p[- x]]li[p[b]]]"
    let deep = md("1. a\n\n       - x\n2. b")
    check "<ul" notin htmlBody(deep)
    check textBody(deep) == "\n1. a\n\n   - x\n2. b\n"
    # Short of a wide item's column, four spaces are still no marker:
    # the line is a lazy continuation of the item's paragraph.
    check outlineOf("123456. a\n    - b") == "ol(start=123456)[li[a - b]]"
    check outlineOf("123456. a `x\n    - b`") ==
      "ol(start=123456)[li[a codeInline[x - b]]]"
    # After a blank line it is no next item either: the list ends.
    check outlineOf("123456. a\n\n    7. b") ==
      "ol(start=123456)[li[a]] p[7. b]"

suite "mailMarkdown aligns table columns":
  # The delimiter row's alignment: `:---` left, `:---:` centre, `---:`
  # right, `---` none; on every header and body cell of its column.
  proc cellAligns(src: string): seq[string] =
    ## `tag:align` for every cell of the first table `src` maps to,
    ## in order (`-` for none).
    let r = EmailRenderer()
    let n = r.el(nil, "mailMarkdown", [("src", src)])
    var diags: ref seq[EmailDiagnostic]
    new(diags)
    let ctx = ExpandCtx(theme: defaultTheme(), target: defaultTarget(),
      r: r, diagnostics: diags)
    proc walk(x: EmailNode; acc: var seq[string]) =
      if x.kind != enElement:
        return
      if x.tag in ["th", "td"]:
        acc.add(x.tag & ":" & x.styles.getOrDefault("text-align", "-"))
      for c in x.children:
        walk(c, acc)
    for c in markdownNodes(ctx, n, readProps[MarkdownProps](n)):
      walk(c, result)

  const aligned = "| Left | Centre | Right | None |\n" &
    "|:-----|:------:|------:|------|\n" &
    "| `code` | *em* | [link](https://e.x/l) | plain |\n" &
    "| a | **b** | $1.00 | d |"

  test "test_markdown_table_alignment_on_header_and_body_cells":
    check cellAligns(aligned) == @["th:left", "th:center", "th:right", "th:-",
      "td:left", "td:center", "td:right", "td:-",
      "td:left", "td:center", "td:right", "td:-"]
    # The cells keep their inline content.
    check outlineOf(aligned).contains("tr[td[codeInline[code]]td[em[em]]" &
      "td[a(href=https://e.x/l)[link]]td[plain]]")
    # Without colons, or with fewer delimiter cells than cells: none.
    check cellAligns("| A | B |\n|---|---|\n| 1 | 2 |") ==
      @["th:-", "th:-", "td:-", "td:-"]
    check cellAligns("| A | B |\n|--:|\n| 1 | 2 |") ==
      @["th:right", "th:-", "td:right", "td:-"]
    # Spaces inside the delimiter row, and a row without outer pipes'
    # last cell.
    check cellAligns("| A | B | C |\n| :- | :-: | -: |\n| 1 | 2 | 3 |") ==
      @["th:left", "th:center", "th:right", "td:left", "td:center",
        "td:right"]

  proc htmlCells(html: string): seq[(string, string)] =
    ## `(tag:align, text)` for every table cell the HTML writes for the
    ## Markdown table (`valign="top"`), in order: its `align`
    ## attribute, or `class <a>` for its `e-tbl-a-<a>` class in the
    ## stacked form, `-` for neither; and its text, tags left out.
    var k = 0
    while true:
      let th = html.find("<th ", k)
      let td = html.find("<td ", k)
      if th < 0 and td < 0:
        break
      let at = if th < 0: td elif td < 0: th else: min(th, td)
      let e = html.find(">", at)
      k = e
      let tagText = html[at .. e]
      if "valign=\"top\"" notin tagText:
        continue
      var a = "-"
      if tagText.continuesWith(" align=\"", 3):
        a = tagText[11 ..< tagText.find('"', 11)]
      else:
        let c = tagText.find("e-tbl-a-")
        if c >= 0:
          var z = c + 8
          while tagText[z] in Letters:
            inc z
          a = "class " & tagText[c + 8 ..< z]
      let close = html.find("</t" & tagText[2], e)
      var text = ""
      var inTag = false
      for ch in html[e + 1 ..< close]:
        if ch == '<': inTag = true
        elif ch == '>': inTag = false
        elif not inTag: text.add(ch)
      result.add((tagText[1 .. 2] & ":" & a, text))

  test "test_markdown_table_alignment_of_every_cell_in_the_html":
    # Left, centre, right and unaligned columns, cells with code,
    # emphasis and a link. Four columns stack on mobile, so the HTML
    # holds the desktop table and the stacked one.
    let res = md(aligned)
    check not hasErrors(res.diagnostics)
    var got: seq[string] = @[]
    var texts: seq[string] = @[]
    for (a, t) in htmlCells(res.html):
      got.add(a)
      texts.add(t)
    # Desktop: the header cells (an unaligned header keeps the start
    # alignment every header cell has), then the two body rows (an
    # unaligned body cell has no `align`).
    let desktop = @["th:left", "th:center", "th:right", "th:left",
      "td:left", "td:center", "td:right", "td:-",
      "td:left", "td:center", "td:right", "td:-"]
    check got[0 ..< desktop.len] == desktop
    # Stacked: the header row as on desktop, then each body row's cells
    # carry their column's alignment class.
    let stackedRow = @["td:class left", "td:class center",
      "td:class right", "td:-"]
    check got[desktop.len .. ^1] == desktop[0 ..< 4] & stackedRow &
      stackedRow
    # The classes bring the alignment back over the stacked form's
    # start alignment (R-TBL-18).
    check ".e-tbl-a-center{text-align:center !important" in res.html
    # The aligned cells hold their inline content: the code span, the
    # emphasis and the link are inside them.
    check texts[0 ..< desktop.len] == @["Left", "Centre", "Right", "None",
      "code", "em", "link", "plain", "a", "b", "$1.00", "d"]
    let row = res.html.find("<td align=\"left\" valign=\"top\"")
    let rowEnd = res.html.find("</tr>", row)
    let firstRow = res.html[row ..< rowEnd]
    check "<code" in firstRow and "<em" in firstRow and
      "href=\"https://e.x/l\"" in firstRow
    # The text part writes the cells as an unaligned table's.
    check "Left | Centre | Right | None\ncode | em | link " &
      "(https://e.x/l) | plain\na | b | $1.00 | d\n" in res.text

  test "test_markdown_table_alignment_in_the_html":
    # Three columns: the table keeps its desktop form on mobile, and
    # each aligned cell carries `align` and `text-align` (R-TBL-14).
    let res = md("| Item | Qty | Amount |\n|:--|:-:|--:|\n" &
      "| *Widget* | 2 | **$20.00** |")
    check not hasErrors(res.diagnostics)
    let html = res.html
    let th = html[html.find("<th ") .. html.find("</thead>")]
    check th.count("align=\"left\"") == 1
    check th.count("align=\"center\"") == 1
    check th.count("align=\"right\"") == 1
    check "text-align:center;" in th and "text-align:right;" in th
    let tb = html[html.find("<tbody") .. html.find("</tbody>")]
    check tb.count("align=\"left\"") == 1
    check tb.count("align=\"center\"") == 1
    check tb.count("align=\"right\"") == 1
    check "text-align:left;" in tb and "text-align:center;" in tb and
      "text-align:right;" in tb
    # Its own alignment wins over a header cell's start alignment: the
    # right-aligned header is right-aligned, not left.
    let amount = th[th.find("Amount") - 400 .. th.find("Amount")]
    check "align=\"right\"" in amount
    check "align=\"left\"" notin amount[amount.rfind("<th ") .. ^1]
    # GFM's alignment is physical: `:--` is left in right to left too.
    let rtl = md("| א | ב |\n|:--|--:|\n| 1 | 2 |", rtl = true)
    let rb = rtl.html[rtl.html.find("<tbody") .. rtl.html.find("</tbody>")]
    check rb.count("align=\"left\"") == 1
    check rb.count("align=\"right\"") == 1

  test "test_markdown_table_alignment_leaves_the_text_part":
    # No text column is aligned with spaces: an aligned table's text is
    # the unaligned one's.
    let plain = "| Item | Qty | Amount |\n|---|---|---|\n" &
      "| `w-1` | *2* | [$20](https://e.x/i) |"
    let al = "| Item | Qty | Amount |\n|:--|:-:|--:|\n" &
      "| `w-1` | *2* | [$20](https://e.x/i) |"
    let a = md(al)
    check not hasErrors(a.diagnostics)
    check a.text == md(plain).text
    check "Item | Qty | Amount\nw-1 | 2 | $20 (https://e.x/i)\n" in a.text
