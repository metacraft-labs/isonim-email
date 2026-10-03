## `mailRaw` (`raw.nim`, P1 and P10) and `mailIf`
## (`lower/conditional.nim`).
##
## - Raw markup is emitted byte for byte, and linted like generated
##   HTML: its elements, attributes and inline CSS reach P1's and P10's
##   checks; every `mailRaw` is reported for audit.
## - `mailRaw` is no sanitiser: markup that would break the message
##   built around the payload is an error (tags, comments and quotes
##   left open, unbalanced tags and conditionals, table parts outside
##   the payload's own table, conditions outside the closed set, any
##   comment inside a conditional, including the one a `mailIf` writes),
##   while markup clients strip (scripts, event handlers, `javascript:`
##   URLs) is written byte for byte with a warning.
## - `mailIf(mso)` wraps its lowered content in the Word or not-Word
##   conditional, flattening the content's own conditionals (comments
##   cannot nest); `mailIf(family = thunderbird)` hides its block inline
##   and shows it by a `.moz-text-html` rule; its values are checked.
## - Every raw and targeting story renders without an error.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[sequtils, strutils, unittest]
import isonim_email
import stories/seed_raw

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
    ("dir", "ltr"), ("title", "Raw")])
  discard r.child(doc, "h1", text = "Raw")
  (doc, r.child(doc, "mailSection"))

proc rawIn(r: EmailRenderer; parent: EmailNode; html: string): EmailNode =
  result = r.child(parent, "mailRaw")
  r.appendChild(result, raw(html))

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc rawDiags(html: string): seq[EmailDiagnostic] =
  ## The diagnostics of one raw payload in a minimal document.
  let r = EmailRenderer()
  let (doc, s) = newDoc(r)
  discard r.rawIn(s, html)
  renderTree(doc).diagnostics

proc body(html: string): string =
  html[html.find("<body") .. ^1]

proc head(html: string): string =
  html[0 ..< html.find("<body")]

suite "mailRaw":
  test "test_mailraw_is_linted":
    # rule: R-RAW-01, R-RAW-04
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.rawIn(s, "<table><tr><td style=\"display:flex;" &
      "mso-text-raise:4px;\"><a href=\"https://e.example/\">click here</a>" &
      "</td></tr></table>")
    discard r.rawIn(s, "<p style=\"color:#777777;\">Grey on white</p>" &
      "<img src=\"https://e.example/a.webp\" alt=\"\" width=\"20\">")
    let res = renderTree(doc)
    let codes = codesOf(res.diagnostics)
    # Every use is counted for audit.
    check codes.count(codeRawUsed) == 2
    for d in res.diagnostics:
      if d.code == codeRawUsed:
        check d.severity == sevInfo
    # P10 sees the raw elements, attributes and CSS like generated HTML:
    # a layout table, flex in a cell, link text, an unlisted mso-*
    # property, contrast, an image format.
    check codeTblUnexpected in codes
    check codeCssHarmful in codes
    check codeA11yLinkText in codes
    check codeCssMsoUnlisted in codes
    check codeA11yContrast in codes
    check codeAssetFormat in codes
    # P1's checks too: alt text and sectioning elements.
    let p1 = rawDiags("<section><img src=\"https://e.example/a.png\"></section>")
    check codeA11ySectioning in codesOf(p1)
    check codeA11yAltMissing in codesOf(p1)
    # A clean payload is information only.
    let clean = rawDiags("<p style=\"color:#111827;font-size:16px;\">Fine " &
      "&amp; dandy<br>still</p><img src=\"https://e.example/a.png\" " &
      "alt=\"\" width=\"20\" />")
    check codesOf(clean) == @[codeRawUsed]

  test "test_raw_is_kept_verbatim":
    # rule: R-RAW-01, R-RAW-04
    let payload = "<div style=\"padding:12px;border:1px solid #d1d5db;" &
      "color:#111827;font-size:16px;\">Hand &amp; written<br>" &
      "<!-- a note --></div><!--[if mso]><v:rect fill=\"true\" " &
      "style=\"width:20px;height:20px;\"><v:fill color=\"#1f6feb\" />" &
      "</v:rect><![endif]-->"
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.rawIn(s, payload)
    let res = renderTree(doc)
    check codesOf(res.diagnostics) == @[codeRawUsed]
    check payload in res.html
    check "<mailraw" notin res.html.toLowerAscii()
    # Placement: raw outside mailRaw is an error.
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    r2.appendChild(r2.child(s2, "p"), raw("<b>loose</b>"))
    check codeStructRawOutside in codesOf(renderTree(doc2).diagnostics)

  test "test_raw_breakout_and_malformed_markup_refused":
    # rule: R-RAW-02
    for payload in [
        "</td></tr></table>",                      # closes the layout around it
        "<div>never closed",                       # swallows what follows
        "<div/>",                                  # HTML keeps it open
        "<b><i>misnested</b></i>",                 # closes over an open element
        "<b><i>misnested</b>",
        "<td>x</td>",                              # closes the host cell
        "<tr><td>x</td></tr>",
        "<tbody></tbody>",
        "<caption>x</caption>",
        "<div><td>x</td></div>",                   # nested, still the host's
        "<![endif]-->",                            # closes a conditional around it
        "<!--<![endif]-->",
        "<!--[if mso]><p>open</p>",                # conditional not closed
        "<!--[if mso]>",
        "<!--[if mso]><p><![endif]-->",            # element open at its end
        "<!--[IF mso]><p><![ENDIF]-->",            # matched without case
        "<!--[if mso]><!--[if mso]>x<![endif]--><![endif]-->",
        "<!--[if mso]><!-- note -->x<![endif]-->", # a comment inside one
        "<!--[if mso]><p title=\"-->\">x</p><![endif]-->",  # ends it early
        "<!--[if mso]><p title=\"--!>\">x</p><![endif]-->",
        "<!--[if gte mso 15]>x<![endif]-->",       # outside the closed set
        "<!--[if gt mso 15]>x<![endif]-->",
        "<!--[if !mso]>x<![endif]-->",             # hidden from everyone
        "<!--[if mso]><!-->x<!--<![endif]-->",     # Word's content shown to all
        "<!--[if !mso]><!-->x<![endif]-->",        # closed in the other form
        "<!--[if mso]><div><![endif]--></div>",    # closes across a conditional
        "<!-- --!></td></tr></table> -->",         # --!> ends the comment
        "<noembed><p title=\"</noembed><b>\">x</p></noembed>",
        "<xmp><p title=\"</xmp><b>\">x</p></xmp>",
        "<plaintext>",                             # the rest is text
        "<plaintext></plaintext>",                 # no end tag ends it
        "<style>p{}",                              # raw text never closed
        "<p title=\"open>x</p>",                  # unterminated quote
        "<p",                                      # unterminated tag
        "<br",
        "<br title=\"open>",
        "<!-- never closed",
        "<!x never closed",
        "<!-- [if mso]> -->",                      # looks like a conditional
        # noscript is refused: its content is text with scripting on and
        # markup with it off, and scripts never run in email.
        "<noscript></td></tr></table></noscript>",
        "<noscript><b title=\"</noscript><table>\">x</b></noscript>",
        "<noscript><p title=\"</noscript><plaintext>\">x</p></noscript>",
        "<noscript><p>harmless with scripting off</p></noscript>",
        "<NOSCRIPT></NOSCRIPT>",
        "<noscript><!--</noscript>",
        "<noscript><plaintext></noscript>",
        # Inline SVG and MathML are refused: a parser reads parts of them
        # as HTML (on HTML tags, in foreignObject, title, mi, and the
        # content of style or script there), which this reader does not
        # follow. Breaking cases and harmless ones alike.
        "<svg><b><td></td></b></svg>",
        "<svg><p><td></td></p></svg>",
        "<svg><b/><td/></svg>",
        "<svg><foreignObject><td/></foreignObject></svg>",
        "<svg><foreignObject><plaintext/></foreignObject></svg>",
        "<svg><foreignObject><textarea/></foreignObject></svg>",
        "<math><mi><td>x</td></mi></math>",
        "<svg><title><td>x</td></title></svg>",
        "<svg><title></td></tr></table>x</title></svg>",
        "<svg><style></td></style></svg>x",
        "<svg><textarea></td></textarea></svg>x",
        "<svg><script></td></script></svg>x",
        "<math><style></td></style></math>x",
        "<math><mi><style></td></style></mi></math>x",
        "<svg><title><!-- </title></svg> --></title></svg>x",
        "<svg><![CDATA[</svg><td>]]>x</svg>",
        "<svg><path d=\"M0 0\"/></svg>",
        "<svg><title>t</title><g><rect width=\"1\" height=\"1\"/></g></svg>",
        "<SVG></SVG>",
        "<math><mi>x</mi></math>",
        # In a script, <!-- can keep a parser in script text past
        # </script>.
        "<script><!--<script></script>",
        "<script><!-- x --></script>",
        "<style><!-- p{} --></style>"]:
      checkpoint(payload)
      let diags = rawDiags(payload)
      check codeRawMalformed in codesOf(diags)
      for d in diags:
        if d.code == codeRawMalformed:
          check d.severity == sevError
    check rawDiags("<noscript></noscript>").anyIt(it.code ==
      codeRawMalformed and "scripts never run" in it.message)
    # The refusal of inline SVG says why, and points to an image.
    for d in rawDiags("<svg><path d=\"M0 0\"/></svg>"):
      if d.code == codeRawMalformed and "SVG" in d.message:
        check "use an image" in d.message
    check rawDiags("<svg></svg>").anyIt(it.code == codeRawMalformed and
      "SVG" in it.message)
    # A refused payload is not written.
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.rawIn(s, "<p>kept</p>")
    discard r.rawIn(s, "</td></tr></table><p>dropped</p>")
    let res = renderTree(doc)
    check "<p>kept</p>" in res.html
    check "dropped" notin res.html
    # The condition outside the set names R-OL-02.
    var named = false
    for d in rawDiags("<!--[if mso 12]>x<![endif]-->"):
      if d.code == codeRawMalformed and "R-OL-02" in d.rules:
        named = true
    check named
    # In a text element, a block closes the paragraph around it; in a
    # link, a link closes the link.
    for (host, payload) in [("p", "<div>x</div>"), ("p", "<p>x</p>"),
        ("p", "<ul><li>x</li></ul>"),
        ("a", "<a href=\"https://e.example/\">x</a>")]:
      checkpoint(host & " " & payload)
      let r2 = EmailRenderer()
      let (doc2, s2) = newDoc(r2)
      let h = r2.child(s2, host, attrs = (if host == "a":
        @[("href", "https://e.example/")] else: @[]))
      discard r2.rawIn(h, payload)
      check codeRawMalformed in codesOf(renderTree(doc2).diagnostics)
    # In a list item, an li outside a list the payload opens closes the
    # host item (a parser closes an open li through div and p); inside
    # the payload's own list it is fine.
    for (payload, refused) in [("<li>x</li>", true),
        ("<div><li>x</li></div>", true), ("<p><li>x</li></p>", true),
        ("<ul><li>x</li></ul>", false), ("<div><ol><li>x</li></ol></div>", false)]:
      checkpoint("li " & payload)
      let r3 = EmailRenderer()
      let (doc3, s3) = newDoc(r3)
      discard r3.rawIn(r3.child(r3.child(s3, "ul"), "li"), payload)
      let codes = codesOf(renderTree(doc3).diagnostics)
      check (codeRawMalformed in codes) == refused
    # Outside a list item, a bare li is no structural error.
    check codeRawMalformed notin codesOf(rawDiags("<li>x</li>"))
    # The same constructs read cleanly when balanced, in the set and in
    # place; comments are read as a browser reads them.
    for payload in ["<!--[if mso]><div>x</div><![endif]-->",
        "<!--[IF MSO]><div>x</div><![ENDIF]-->",
        "<!--[if !mso]><!--><p>y</p><!--<![endif]-->",
        "<!--[if gte mso 9]><v:roundrect arcsize=\"10%\"><v:textbox>" &
          "<p>z</p></v:textbox></v:roundrect><![endif]-->",
        "<table role=\"presentation\"><tr><td>a</td></tr></table>",
        "<table><tbody><tr><td><table><tr><td>b</td></tr></table></td>" &
          "</tr></tbody></table>",
        "<!-- a note --><p>x</p>", "<!--><p>x</p>", "<!---><p>x</p>",
        "<!-- a --!><p>x</p>", "<p title=\"a > b\">x</p>",
        "<p>1 < 2 &amp; 3 > 2</p>", "<br></br><img src=\"https://e.example/" &
          "a.png\" alt=\"\"></img>",
        "<p title=\"-->\">top level: no comment around it</p>",
        "<style>p{color:#111827}</style><p>x</p>",
        "<textarea><b></textarea>",
        "<script>var a = 1 < 2;</script>"]:
      checkpoint(payload)
      check codeRawMalformed notin codesOf(rawDiags(payload))

  test "test_raw_unsupported_content_is_written_with_a_warning":
    # rule: R-RAW-03
    # Not a sanitiser: what clients strip is written byte for byte, with
    # a warning saying so.
    for payload in [
        "<script>alert(1)</script>",
        "<iframe src=\"https://e.example/\"></iframe>",
        "<object data=\"https://e.example/x\"></object>",
        "<embed src=\"https://e.example/x\">",
        "<form action=\"https://e.example/\"><input name=\"q\"></form>",
        "<p onclick=\"alert(1)\">x</p>",
        "<img src=\"https://e.example/a.png\" alt=\"\" OnError=\"x()\">",
        "<a href=\"javascript:alert(1)\">x</a>",
        "<a href=\"JaVa&#x9;Script:alert(1)\">x</a>",
        "<a href=\" java\tscript:alert(1)\">x</a>",
        "<a href=\"&#106;avascript:alert(1)\">x</a>",
        "<a href=\"vbscript:x\">x</a>",
        "<v:rect style=\"width:10px;height:10px;\"></v:rect>"]:
      checkpoint(payload)
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      discard r.rawIn(s, payload)
      let res = renderTree(doc)
      let codes = codesOf(res.diagnostics)
      check codeRawUnsupported in codes
      check codeRawMalformed notin codes
      for d in res.diagnostics:
        if d.code == codeRawUnsupported:
          check d.severity == sevWarning
          check "strip" in d.message or "remove" in d.message or
            "show none" in d.message
      check payload in res.html
    # Markup that used to be refused for what it might do, and that
    # breaks nothing, is written as it is, with no raw finding.
    for payload in [
        "<a href=\"data:text/html,x\">x</a>",
        "<img src=\"data:image/png;base64,AAAA\" alt=\"x\">",
        "<p style=\"width:expression(alert(1))\">x</p>",
        "<p style=\"behavior:url(x.htc)\">x</p>",
        "<p style=\"background:url(javascript:alert(1))\">x</p>",
        "<!DOCTYPE html>", "<![CDATA[x]]>", "<?xml version=\"1.0\"?>",
        "<meta charset=\"utf-8\">", "<base href=\"https://e.example/\">",
        "<!--><b>after an empty comment</b>-->",
        "<p title=\"--><b>x</b>\">x</p>",
        "<p id=\"a\" id=\"b\">x</p>", "<p class=a<b>x</p>",
        "<img/src=x/onerror=alert(1)>",
        "<x:thing></x:thing>"]:
      checkpoint(payload)
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      discard r.rawIn(s, payload)
      let res = renderTree(doc)
      let codes = codesOf(res.diagnostics)
      check codeRawMalformed notin codes
      check codeRawUnsupported notin codes
      check payload in res.html
    # A safe URL and plain CSS have no finding.
    check codesOf(rawDiags("<a href=\"mailto:a@b.example\" " &
      "style=\"color:#0969da;\">mail</a>")) == @[codeRawUsed]

suite "mailIf":
  test "test_mailif_mso_lowers_to_the_conditionals":
    # rule: R-RAW-05
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(r.child(s, "mailIf", attrs = [("mso", "true")]), "p",
      text = "Word only")
    discard r.child(r.child(s, "mailIf", attrs = [("mso", "false")]), "p",
      text = "Not Word")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "<mailif" notin html.toLowerAscii()
    check "<!--[if mso]><p style=\"" in html
    check "\">Word only</p><![endif]-->" in html
    check "<!--[if !mso]><!--><p style=\"" in html
    check "\">Not Word</p><!--<![endif]-->" in html
    # Without Word: the Word content goes, the rest is plain.
    var t = defaultTarget()
    t.outlookWord = false
    let plain = body(renderTree(doc.cloneTree, target = t).html)
    check "Word only" notin plain
    check "Not Word" in plain
    check "<!--[if" notin plain
    # family = outlookWord is mso = true.
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    discard r2.child(r2.child(s2, "mailIf", attrs = [("family",
      "outlookWord")]), "p", text = "Word by family")
    check "<!--[if mso]><p style=" in renderTree(doc2).html

  test "test_mailif_flattens_nested_conditionals":
    # rule: R-RAW-05
    let r = EmailRenderer()
    let doc = r.child(nil, "mailDocument", attrs = [("lang", "en"),
      ("dir", "ltr"), ("title", "Flat")])
    discard r.child(r.child(doc, "mailSection"), "h1", text = "Flat")
    let word = r.child(doc, "mailIf", attrs = [("mso", "true")])
    let ws = r.child(word, "mailSection", [("background-color", "#fef3c7")])
    discard r.child(ws, "p", text = "Word band")
    discard r.child(ws, "mailDivider")
    let others = r.child(doc, "mailIf", attrs = [("mso", "false")])
    let os = r.child(others, "mailSection", [("background-color", "#ecfdf5")])
    discard r.child(os, "p", text = "Other band")
    discard r.child(os, "mailDivider")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    # Word's block: one conditional around the band, its ghost tables
    # and the divider's table unwrapped inside it, the divider's
    # not-Word paragraph gone.
    let wi = html.find("Word band")
    let wStart = html.rfind("<!--[if mso]>", last = wi)
    let wEnd = html.find("<![endif]-->", wi)
    let wordBlock = html[wStart + "<!--[if mso]>".len ..< wEnd]
    check "<!--" notin wordBlock
    check "<table role=\"presentation\" align=\"center\"" in wordBlock
    check "border-top:1px solid #e5e7eb" in wordBlock
    # The not-Word block: no Word conditional inside, the divider's
    # paragraph kept, no ghost table.
    let oi = html.find("Other band")
    let oStart = html.rfind("<!--[if !mso]><!-->", last = oi)
    let oEnd = html.find("<!--<![endif]-->", oi)
    let otherBlock = html[oStart + "<!--[if !mso]><!-->".len ..< oEnd]
    check "<!--" notin otherBlock
    check "<table" notin otherBlock
    check "<p style=\"border-top:1px solid #e5e7eb;" in otherBlock
    # Balanced, as the serialiser asserts.
    check html.count("<!--[if") == html.count("<![endif]-->")

  test "test_mailif_family_thunderbird":
    # rule: R-RAW-06
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(r.child(s, "mailIf", attrs = [("family", "thunderbird")]),
      "p", text = "Thunderbird block")
    let p = r.child(s, "p", text = "Ends ")
    discard r.child(r.child(p, "mailIf", attrs = [("family", "thunderbird")]),
      "strong", text = "inline")
    discard r.child(r.child(s, "mailIf", attrs = [("family",
      "outlookWord, thunderbird")]), "p", text = "Both")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "<!--[if !mso]><!--><div class=\"e-if-tb\" style=\"display:none;" &
      "max-height:0;overflow:hidden;\"><p style=" in html
    check "Ends <!--[if !mso]><!--><span class=\"e-if-tb-i\" " &
      "style=\"display:none;max-height:0;overflow:hidden;\"><strong" in html
    # Both: Word's copy first, then Thunderbird's.
    let both = html.find("Both")
    check html.rfind("<!--[if mso]>", last = both) >
      html.rfind("e-if-tb", last = both)
    check html.count("Both</p>") == 2
    # Shown by Thunderbird's own class, outside any media query.
    let h = head(res.html)
    check ".moz-text-html .e-if-tb{display:block !important;max-height:" &
      "none !important;overflow:visible !important}" in h
    check ".moz-text-html .e-if-tb-i{display:inline !important;" in h
    let at = h.find(".moz-text-html .e-if-tb{")
    var inQuery = false
    var mq = h.find("@media")
    while mq >= 0:
      if at > mq and at < h.find("}}", mq):
        inQuery = true
      mq = h.find("@media", mq + 1)
    check not inQuery
    # Written whatever thunderbirdMq says.
    var t = defaultTarget()
    t.thunderbirdMq = false
    check ".moz-text-html .e-if-tb{" in renderTree(doc.cloneTree,
      target = t).html

  test "test_a_block_before_a_mailif_keeps_its_margin":
    # rule: R-RAW-05
    # The conditional is transparent: the last block inside it is last
    # only when the mailIf is, so the paragraph before it, and the last
    # paragraph inside it, keep the margin that separates them from
    # what follows.
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "p", text = "Before")
    discard r.child(r.child(s, "mailIf", attrs = [("family", "thunderbird")]),
      "p", text = "Inside")
    discard r.child(s, "p", text = "After")
    let html = body(renderTree(doc).html)
    # "Before" and "Inside" keep 16px; only "After", the section's last
    # block, has none.
    check html.count("<p style=\"margin:0 0 16px;") == 2
    check html.count("<p style=\"margin:0;") == 1

  test "test_mailif_values_are_checked":
    # rule: R-OL-02, R-RAW-05, R-RAW-06
    for attrs in [@[("mso", "15")], @[("mso", "gte mso 9")],
        @[("family", "gmailWeb")], @[("family", "")],
        @[("mso", "true"), ("family", "thunderbird")], @[]]:
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      discard r.child(r.child(s, "mailIf", attrs = attrs), "p", text = "x")
      checkpoint($attrs)
      let res = renderTree(doc)
      check codeVocabBadValue in codesOf(res.diagnostics)
      # Refused, the content is written unconditioned (the error blocks
      # sending), never as a raw tag.
      check "<mailif" notin res.html.toLowerAscii()
      check ">x</p>" in res.html
    var mso = false
    for d in rawDiags("<!--[if lt mso 12]>x<![endif]-->"):
      if "R-OL-02" in d.rules:
        mso = true
    check mso
    # Inside the library a condition outside the set raises.
    expect EmailRenderError:
      discard msoCond("gte mso 15")

  test "test_mailif_refuses_comments_in_its_raw_content":
    # rule: R-RAW-02, R-RAW-05
    # The mailIf's own conditional is already around the payload, and
    # comments do not nest: a comment, a conditional or a stray '-->'
    # inside would end it early and show Word-only content to everyone.
    for (attrs, payload) in [
        (@[("mso", "true")], "<!--[if mso]><p>a</p><![endif]--><p>b</p>"),
        (@[("mso", "false")], "<!--[if !mso]><!--><p>a</p><!--<![endif]-->"),
        (@[("mso", "true")], "<!-- c --><p>d</p>"),
        (@[("mso", "true")], "<p title=\"-->\">x</p>"),
        (@[("mso", "true")], "<p title=\"a --!> b\">x</p>"),
        (@[("mso", "true")], "<p title=\"<![endif]\">x</p>"),
        (@[("family", "thunderbird")], "<!--[if mso]><p>a</p><![endif]-->"),
        (@[("family", "outlookWord")], "<!--><p>x</p>")]:
      checkpoint($attrs & " " & payload)
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      let m = r.child(s, "mailIf", attrs = attrs)
      discard r.rawIn(m, payload)
      let res = renderTree(doc)
      check codeRawMalformed in codesOf(res.diagnostics)
      # Not written: Word's conditional stays one comment.
      let html = body(res.html)
      check html.count("<!--[if") == html.count("<![endif]-->")
      check payload notin html
    # A mailTable (whose stacking mode copies the table into Word's
    # conditional) and a mailButton (whose VML form holds its content
    # in one) are conditional contexts too.
    for payload in ["<!-- c -->x", "<b title=\"-->\">x</b>"]:
      block:
        checkpoint("mailTable cell " & payload)
        let r = EmailRenderer()
        let (doc, s) = newDoc(r)
        let t = r.child(r.child(s, "mailTable", attrs = [("caption",
          "Items")]), "table")
        let hr = r.child(r.child(t, "thead"), "tr")
        for h in ["A", "B", "C", "D"]:
          discard r.child(hr, "th", text = h)
        let tr = r.child(r.child(t, "tbody"), "tr")
        discard r.rawIn(r.child(tr, "td"), payload)
        for v in ["b", "c", "d"]:
          discard r.child(tr, "td", text = v)
        let res = renderTree(doc)
        check codeRawMalformed in codesOf(res.diagnostics)
        check payload notin res.html
      block:
        checkpoint("mailButton " & payload)
        let r = EmailRenderer()
        let (doc, s) = newDoc(r)
        discard r.rawIn(r.child(s, "mailButton", attrs = [("href",
          "https://e.example/")]), payload)
        let res = renderTree(doc)
        check codeRawMalformed in codesOf(res.diagnostics)
        check payload notin res.html
    # The same content without comments is written inside the
    # conditional, unchanged.
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.rawIn(r.child(s, "mailIf", attrs = [("mso", "true")]),
      "<p title=\"a &gt; b\">Word only</p>")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    check "<!--[if mso]><p title=\"a &gt; b\">Word only</p><![endif]-->" in
      body(res.html)

suite "raw and targeting stories":
  test "test_raw_stories_render":
    for st in rawStories:
      let (html, _) = renderRawStory(st.name)
      checkpoint(st.name)
      check "<mailraw" notin html.toLowerAscii()
      check "<mailif" notin html.toLowerAscii()
      check html.count("<!--[if") == html.count("<![endif]-->")
