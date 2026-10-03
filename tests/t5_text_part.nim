## The plain-text part (`text.nim`): the semantic walk of every element,
## wrapping, links and references, tables, lists, the overrides
## (`textOnly`, `htmlOnly`), targeted content (`mailIf`), raw markup,
## the preheader's absence (R-PRE-04) and the empty-part error.
##
## Each test renders a small hand-built document through the full
## pipeline (`renderTree`) and checks the text it returns, so the walk
## is tested where it runs: after layout and asset resolution, on the
## semantic tree, beside the lowering of the same tree.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[strutils, unittest]
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

proc txt(r: EmailRenderer; parent: EmailNode; s: string) =
  r.appendChild(parent, r.createTextNode(s))

proc newDoc(r: EmailRenderer; preheader = ""): (EmailNode, EmailNode) =
  ## A document with a section to fill (no heading: each test brings
  ## its own content, so the text is exactly what it adds).
  var attrs = @[("lang", "en"), ("dir", "ltr"), ("title", "Text")]
  if preheader.len > 0:
    attrs.add(("preheader", preheader))
  let doc = r.child(nil, "mailDocument", attrs = attrs)
  (doc, r.child(doc, "mailSection"))

proc textOf(doc: EmailNode): string =
  renderTree(doc).text

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

const img = "https://cdn.example.com/a.png"

suite "headings and paragraphs":
  test "test_headings_are_underlined_by_level":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "h1", text = "Welcome, Ada")
    discard r.child(s, "h2", text = "Next steps")
    discard r.child(s, "h3", text = "Billing")
    discard r.child(s, "h4", text = "Fine print")
    check textOf(doc) == "Welcome, Ada\n============\n\n" &
      "Next steps\n----------\n\nBilling\n-------\n\nFine print\n"

  test "test_paragraphs_wrap_at_76_columns_at_spaces":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let words = "The quick brown fox jumps over the lazy dog. "
    discard r.child(s, "p", text = words.repeat(4).strip())
    discard r.child(s, "p", text = "Second paragraph.")
    let text = textOf(doc)
    let lines = text.splitLines()
    for l in lines:
      check l.strip(leading = false).len <= 76
    # A wrapped line ends in a soft break: one trailing space.
    check lines[0] == "The quick brown fox jumps over the lazy dog. The quick " &
      "brown fox jumps over "
    # One blank line between paragraphs, one final newline.
    check text.endsWith("over the lazy dog.\n\nSecond paragraph.\n")
    check "\n\n\n" notin text

  test "test_a_line_takes_exactly_76_columns":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "p", text = "a".repeat(70) & " bcdef g")
    check textOf(doc) == "a".repeat(70) & " bcdef \ng\n"

  test "test_a_long_heading_wraps_and_its_rule_spans_its_longest_line":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "h1", text = "word ".repeat(20).strip())
    let lines = textOf(doc).splitLines()
    check lines[0].len <= 76
    check lines[2] == "=".repeat(lines[0].len)

  test "test_width_counts_code_points_and_nbsp_does_not_break":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    # 38 two-byte letters, a space, 38 more: 77 code points, 154 bytes.
    discard r.child(s, "p", text = "é".repeat(38) & " " & "é".repeat(37))
    discard r.child(s, "p", text = "x".repeat(71) & " 10\u00A0km")
    let lines = textOf(doc).splitLines()
    check lines[0] == "é".repeat(38) & " " & "é".repeat(37)
    check lines[2] == "x".repeat(71) & " "
    check lines[3] == "10\u00A0km"

  test "test_white_space_collapses_and_br_breaks":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let p = r.child(s, "p")
    r.txt(p, "  Hello\n   ")
    discard r.child(p, "strong", text = "Ada")
    r.txt(p, ",  welcome.")
    discard r.child(p, "br")
    r.txt(p, "Second line.")
    check textOf(doc) == "Hello Ada, welcome.\nSecond line.\n"

  test "test_blockquote_is_indented_and_pre_kept_as_written":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let q = r.child(s, "blockquote")
    discard r.child(q, "p", text = "Quoted.")
    discard r.child(s, "pre", text = "line one\n  line two")
    check textOf(doc) == "  Quoted.\n\nline one\n  line two\n"

suite "links and buttons":
  test "test_links_read_text_then_url":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let p = r.child(s, "p")
    r.txt(p, "Read the ")
    discard r.child(p, "a", attrs = [("href", "https://example.com/guide")],
      text = "guide")
    r.txt(p, ", see ")
    discard r.child(p, "a", attrs = [("href", "https://example.com/")],
      text = "example.com")
    r.txt(p, " or write to ")
    discard r.child(p, "a", attrs = [("href", "mailto:help@example.com")],
      text = "help@example.com")
    r.txt(p, ".")
    check textOf(doc) == "Read the guide (https://example.com/guide), see " &
      "https://example.com/ or \nwrite to help@example.com.\n"

  test "test_urls_are_never_broken":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let url = "https://example.com/" & "a".repeat(90)
    let p = r.child(s, "p")
    r.txt(p, "Open ")
    discard r.child(p, "a", attrs = [("href", url)], text = url)
    r.txt(p, " today.")
    check textOf(doc) == "Open \n" & url & " \ntoday.\n"

  test "test_more_than_three_links_become_references":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let p = r.child(s, "p")
    for i, name in ["one", "two", "three", "four"]:
      if i > 0:
        r.txt(p, ", ")
      discard r.child(p, "a", attrs = [("href", "https://example.com/" &
        name)], text = name)
    let p2 = r.child(s, "p")
    discard r.child(p2, "a", attrs = [("href", "https://example.com/five")],
      text = "five")
    check textOf(doc) == "one [1], two [2], three [3], four [4]\n" &
      "[1] https://example.com/one\n[2] https://example.com/two\n" &
      "[3] https://example.com/three\n[4] https://example.com/four\n\n" &
      "five (https://example.com/five)\n"

  test "test_buttons_read_label_colon_url":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "p", text = "Your account is ready.")
    discard r.child(s, "mailButton", attrs = [("href",
      "https://app.example.com/")], text = "Open dashboard")
    check textOf(doc) ==
      "Your account is ready.\n\nOpen dashboard: https://app.example.com/\n"

suite "images":
  test "test_images_read_their_alt_in_brackets":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailImage", [("width", "120px")], [("src", img),
      ("alt", "Acme logo")])
    discard r.child(s, "p", text = "Hello.")
    check textOf(doc) == "[Acme logo]\n\nHello.\n"

  test "test_decorative_images_are_omitted":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailImage", [("width", "120px")], [("src", img),
      ("alt", ""), ("decorative", "true")])
    # Marked decorative, it is left out even when an alt was given.
    discard r.child(s, "mailImage", [("width", "120px")], [("src", img),
      ("alt", "Flourish"), ("decorative", "true")])
    discard r.child(s, "p", text = "Hello.")
    check textOf(doc) == "Hello.\n"

  test "test_linked_images_read_alt_then_url":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailImage", [("width", "120px")], [("src", img),
      ("alt", "Acme"), ("href", "https://example.com/")])
    check textOf(doc) == "Acme (https://example.com/)\n"

  test "test_a_dark_pair_writes_its_alt_once":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailImage", [("width", "120px")], [("src", img),
      ("dark_src", "https://cdn.example.com/a-dark.png"), ("alt", "Acme")])
    var t = defaultTarget()
    t.darkMode = dmDesigned
    let res = renderTree(doc, target = t)
    # The HTML carries the pair; the text names the logo once.
    check res.html.count("alt=\"Acme\"") == 2
    check res.text == "[Acme]\n"

suite "tables and lists":
  proc order(r: EmailRenderer; s: EmailNode; caption = "Order 1042";
      wide = false) =
    let t = r.child(s, "mailTable", attrs = [("caption", caption)])
    let table = r.child(t, "table")
    let head = r.child(r.child(table, "thead"), "tr")
    for h in ["Item", "Qty", "Amount"]:
      discard r.child(head, "th", text = h)
    let body = r.child(table, "tbody")
    for (item, qty, amount) in [("Notebook", "2", "$12.00"),
        ((if wide: "A very long description of the item ".repeat(2) else:
          "Eraser"), "10", "$2.25")]:
      let tr = r.child(body, "tr")
      discard r.child(tr, "td", text = item)
      discard r.child(tr, "td", text = qty)
      discard r.child(tr, "td", text = amount)

  test "test_tables_write_one_row_per_line":
    # Cells joined by " | ", the header row first: nothing is aligned
    # with spaces, so the rows read the same in a proportional face.
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    r.order(s)
    check textOf(doc) == "Order 1042\n" &
      "Item | Qty | Amount\n" &
      "Notebook | 2 | $12.00\n" &
      "Eraser | 10 | $2.25\n"

  test "test_wide_tables_become_label_value_blocks":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    r.order(s, wide = true)
    check textOf(doc) == "Order 1042\n\n" &
      "Item: Notebook\nQty: 2\nAmount: $12.00\n\n" &
      "Item: A very long description of the item A very long description " &
      "of the\n  item\nQty: 10\nAmount: $2.25\n"

  test "test_lists_mark_items_with_a_hanging_indent":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let ul = r.child(s, "ul")
    discard r.child(ul, "li", text = "Short.")
    discard r.child(ul, "li", text = "word ".repeat(16).strip())
    let ol = r.child(s, "ol", attrs = [("start", "9")])
    discard r.child(ol, "li", text = "Nine.")
    discard r.child(ol, "li", text = "Ten.")
    let text = textOf(doc)
    let lines = text.splitLines()
    check lines[0] == "- Short."
    check lines[1].startsWith("- word word")
    check lines[2].startsWith("  word")
    check lines[1].len <= 76
    check text.endsWith("\n\n9. Nine.\n10. Ten.\n")

suite "omitted and targeted content":
  test "test_preheader_is_omitted":
    # rule: R-PRE-04
    let r = EmailRenderer()
    let (doc, s) = newDoc(r, preheader = "Your order shipped today.")
    discard r.child(s, "p", text = "Hello.")
    let res = renderTree(doc)
    check "Your order shipped today." in res.html
    check res.text == "Hello.\n"

  test "test_spacers_are_omitted_and_dividers_are_a_rule":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "p", text = "Above.")
    discard r.child(s, "mailSpacer", [("height", "24px")])
    discard r.child(s, "mailDivider")
    discard r.child(s, "p", text = "Below.")
    check textOf(doc) == "Above.\n\n----\n\nBelow.\n"

  test "test_mailif_word_and_family_content_is_not_text":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(r.child(s, "mailIf", attrs = [("mso", "true")]), "p",
      text = "Word only.")
    discard r.child(r.child(s, "mailIf", attrs = [("mso", "false")]), "p",
      text = "Everyone but Word.")
    discard r.child(r.child(s, "mailIf", attrs = [("family",
      "thunderbird")]), "p", text = "Thunderbird only.")
    let res = renderTree(doc)
    check "Word only." in res.html
    check "Thunderbird only." in res.html
    check res.text == "Everyone but Word.\n"

  test "test_textonly_is_text_only_and_htmlonly_html_only":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "h1", text = "Hi")
    discard r.child(r.child(s, "textOnly"), "p",
      text = "Links: https://example.com/a")
    discard r.child(r.child(s, "htmlOnly"), "p", text = "A picture gallery.")
    let res = renderTree(doc)
    check codesOf(res.diagnostics).len == 0
    check res.text == "Hi\n==\n\nLinks: https://example.com/a\n"
    check "A picture gallery." in res.html
    check "Links:" notin res.html
    check "textonly" notin res.html.toLowerAscii()
    check "htmlonly" notin res.html.toLowerAscii()

  test "test_top_level_overrides_sit_in_sections":
    let r = EmailRenderer()
    let doc = r.child(nil, "mailDocument", attrs = [("lang", "en"),
      ("dir", "ltr"), ("title", "Text")])
    discard r.child(doc, "h1", text = "Hi")
    discard r.child(r.child(doc, "htmlOnly"), "p", text = "HTML side.")
    discard r.child(r.child(doc, "textOnly"), "p", text = "Text side.")
    let res = renderTree(doc)
    check codesOf(res.diagnostics).len == 0
    check res.text == "Hi\n==\n\nText side.\n"
    check "HTML side." in res.html

suite "layout and composite elements":
  test "test_columns_read_in_order_and_short_columns_stay_together":
    let r = EmailRenderer()
    let doc = r.child(nil, "mailDocument", attrs = [("lang", "en"),
      ("dir", "ltr"), ("title", "Text")])
    discard r.child(doc, "h1", text = "Stats")
    let s = r.child(doc, "mailSection")
    for (n, what) in [("3", "builds"), ("1", "open review")]:
      let c = r.child(s, "mailColumn")
      discard r.child(c, "p", text = n)
      discard r.child(c, "p", text = what)
    check textOf(doc) == "Stats\n=====\n\n3\nbuilds\n\n1\nopen review\n"

  test "test_links_in_a_cluster_and_social_items_are_one_per_line":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let nav = r.child(s, "mailNavbar", attrs = [("separator", "·")])
    for name in ["Home", "Docs"]:
      discard r.child(nav, "mailNavLink", attrs = [("href",
        "https://example.com/" & name.toLowerAscii())], text = name)
    let social = r.child(s, "mailSocial")
    for n in ["x", "github"]:
      discard r.child(social, "mailSocialItem", attrs = [("network", n),
        ("href", "https://" & n & ".example/")])
    check textOf(doc) == "Home (https://example.com/home)\n" &
      "Docs (https://example.com/docs)\n\n" &
      "X: https://x.example/\nGitHub: https://github.example/\n"

  test "test_a_cluster_without_urls_is_one_line":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let tags = r.child(s, "mailCluster")
    for t in ["design", "backend", "docs"]:
      discard r.child(tags, "span", text = t)
    let sep = r.child(s, "mailCluster", attrs = [("separator", "/")])
    for t in ["one", "two"]:
      discard r.child(sep, "span", text = t)
    let long = r.child(s, "mailCluster")
    for i in 0 ..< 8:
      discard r.child(long, "span", text = "item number " & $i)
    let text = textOf(doc)
    check text.startsWith("design · backend · docs\n\none / two\n\n")
    # Too long for one line: one item per line.
    check text.endsWith("\n\nitem number 0\nitem number 1\nitem number 2\n" &
      "item number 3\nitem number 4\nitem number 5\nitem number 6\n" &
      "item number 7\n")

  test "test_hero_reads_its_content_not_its_background":
    let r = EmailRenderer()
    let doc = r.child(nil, "mailDocument", attrs = [("lang", "en"),
      ("dir", "ltr"), ("title", "Text")])
    let hero = r.child(doc, "mailHero", [("background-color", "#1f2937")],
      [("background_image", "https://cdn.example.com/hero.jpg"),
        ("height", "300px")])
    discard r.child(hero, "h1", text = "Spring sale")
    discard r.child(hero, "mailButton", attrs = [("href",
      "https://app.example.com/")], text = "Shop")
    let text = textOf(doc)
    check text == "Spring sale\n===========\n\nShop: https://app.example.com/\n"
    check "hero.jpg" notin text

  test "test_raw_markup_reads_as_text":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let raw1 = r.child(s, "mailRaw")
    r.appendChild(raw1, raw("<style>p{color:red}</style><p>Hand &amp; " &
      "written, <a href=\"https://example.com/x\">a link</a>.</p>" &
      "<!--[if mso]><p>Word copy</p><![endif]-->" &
      "<!--[if !mso]><!--><p>Others' copy</p><!--<![endif]-->" &
      "<img src=\"https://cdn.example.com/b.png\" alt=\"Badge\" width=\"40\">"))
    let res = renderTree(doc)
    check res.text == "Hand & written, a link (https://example.com/x).\n\n" &
      "Others' copy\n\n[Badge]\n"

suite "the empty part":
  test "test_an_empty_text_part_is_an_error":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailImage", [("width", "120px")], [("src", img),
      ("alt", ""), ("decorative", "true")])
    discard r.child(s, "mailSpacer")
    let res = renderTree(doc)
    check res.text == ""
    check codeTextEmpty in codesOf(res.diagnostics)
    expect EmailRenderError:
      discard renderTree(doc, strict = true)
    # The message then goes out as HTML alone, never with an empty part.
    let msg = toMessage(res, MessageHeaders(
      fromAddr: mailbox("A", "a@example.com"),
      to: @[mailbox("", "b@example.com")], subject: "x"))
    check codesOf(msg.diagnostics) == @[codeTextOmitted]
    check "text/plain" notin toRfc5322(msg, "seed")

  test "test_a_rendered_text_part_is_sent_flowed":
    # rule: R-MIME-06
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "p", text = "Hello.")
    let res = renderTree(doc)
    let msg = toMessage(res, MessageHeaders(
      fromAddr: mailbox("A", "a@example.com"),
      to: @[mailbox("", "b@example.com")], subject: "x"))
    check msg.diagnostics.len == 0
    let bytes = toRfc5322(msg, "seed")
    check "Content-Type: text/plain; charset=utf-8; format=flowed" in bytes
    check toParts(msg).text == "Hello.\n"

suite "format":
  test "test_no_trailing_space_no_blank_runs_one_final_newline":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let t = r.child(s, "mailTable", attrs = [("caption", "C")])
    let tr = r.child(r.child(t, "table"), "tr")
    discard r.child(tr, "td", text = "a")
    discard r.child(tr, "td", text = "")
    discard r.child(s, "p", text = "   ")
    discard r.child(s, "p", text = "End.")
    let text = textOf(doc)
    check text.endsWith(".\n") and not text.endsWith("\n\n")
    check not text.startsWith("\n")
    check "\n\n\n" notin text
    for l in text.splitLines():
      check l == l.strip(leading = false)

# --- format=flowed, read back by an independent decoder ----------------------
#
# The oracle below is written here from RFC 2045 §6.7 (quoted-printable)
# and RFC 3676 §4 (format=flowed), sharing no code with the library: it
# reads the text/plain part out of the message bytes, decodes it, undoes
# space-stuffing and joins every soft-broken line to the next.

proc textPlainBody(bytes: string): string =
  ## The raw (still encoded) body of the message's text/plain part.
  let at = bytes.find("Content-Type: text/plain")
  doAssert at >= 0
  let start = bytes.find("\r\n\r\n", at) + 4
  # The part ends at the next delimiter of a boundary the message
  # declares (a line of dashes in the text is not one).
  var stop = bytes.len
  var i = bytes.find("boundary=\"")
  while i >= 0:
    let b0 = i + "boundary=\"".len
    let b = bytes[b0 ..< bytes.find('"', b0)]
    let d = bytes.find("\r\n--" & b, start)
    if d >= 0 and d < stop:
      stop = d
    i = bytes.find("boundary=\"", b0)
  bytes[start ..< stop]

proc qpDecode(s: string): string =
  ## RFC 2045 §6.7: `=XX` is a byte, `=` before a line break joins.
  var i = 0
  while i < s.len:
    if s[i] == '=' and i + 2 < s.len + 1 and s.continuesWith("\r\n", i + 1):
      i += 3
    elif s[i] == '=' and i + 2 < s.len:
      result.add(chr(parseHexInt(s[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(s[i])
      inc i

proc flowedDecode(s: string): string =
  ## RFC 3676 §4.2/§4.4 for quote depth 0: remove one stuffed space,
  ## then a line ending in a space (other than `-- `) is soft and is
  ## joined to the next line, its space kept.
  var cur = ""
  var lines: seq[string]
  for raw in s.split("\r\n"):
    var l = raw
    if l.startsWith(" "):
      l = l[1 .. ^1]
    cur.add(l)
    if l.endsWith(" ") and l != "-- ":
      continue
    lines.add(cur)
    cur = ""
  if cur.len > 0:
    lines.add(cur)
  lines.join("\n")

proc sentText(doc: EmailNode): string =
  let res = renderTree(doc)
  check res.textFlowed
  let msg = toMessage(res, MessageHeaders(
    fromAddr: mailbox("A", "a@example.com"),
    to: @[mailbox("", "b@example.com")], subject: "x"))
  flowedDecode(qpDecode(textPlainBody(toRfc5322(msg, "seed"))))

suite "format=flowed":
  test "test_wrapped_lines_end_in_soft_breaks":
    # rule: R-MIME-06
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let para = "The quick brown fox jumps over the lazy dog. ".repeat(5).strip()
    discard r.child(s, "p", text = para)
    let lines = textOf(doc).splitLines()
    check lines.len == 4 # two soft lines, the hard last one, ""
    for l in lines[0 .. 1]:
      check l.endsWith(" ") and not l.endsWith("  ")
    check lines[2].len > 0 and not lines[2].endsWith(" ")

  test "test_a_flowed_reader_rejoins_a_paragraph_into_one_line":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let para = ("Every line the wrapper breaks inside this paragraph is a " &
      "soft break, so a reader that understands format=flowed joins " &
      "them again and wraps the paragraph to its own window, a phone's " &
      "included. >Quoted-looking and From-looking words stay words.")
    discard r.child(s, "p", text = para)
    discard r.child(s, "p", text = "Second paragraph.")
    check sentText(doc) == para & "\n\nSecond paragraph.\n"

  test "test_hard_breaks_stay_hard":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let long = "word ".repeat(20).strip()
    discard r.child(s, "h2", text = long)
    let ul = r.child(s, "ul")
    discard r.child(ul, "li", text = long)
    discard r.child(s, "pre", text = long & "\n" & long)
    let p = r.child(s, "p")
    r.txt(p, "First line.")
    discard r.child(p, "br")
    r.txt(p, "Second line.")
    let q = r.child(s, "blockquote")
    discard r.child(q, "p", text = long)
    let t = r.child(s, "mailTable", attrs = [("caption", "C")])
    let table = r.child(t, "table")
    for i in 0 ..< 2:
      let tr = r.child(table, "tr")
      discard r.child(tr, "td", text = "cell " & $i)
    let text = textOf(doc)
    # Not one line of the text ends in a soft break.
    for l in text.splitLines():
      check not l.endsWith(" ")
    # And a flowed reader keeps every line where it is.
    check sentText(doc) == text
