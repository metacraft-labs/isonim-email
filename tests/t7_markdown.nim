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
    "caption", "decorative"]
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
