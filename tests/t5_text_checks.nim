## Text rules beyond the leaves' defaults (catalogue §10) and web fonts:
##
## - text is real text elements, and a message has an `h1`; heading
##   levels are not skipped;
## - text a reader sees is at least 14px (a warning), 12px (an error);
## - an author's font stack ends in a generic family, and nothing but the
##   reset sets the text-size adjustment;
## - a `nolink` span keeps data detectors off its numbers;
## - web fonts (`EmailTarget.webFonts`): an `@font-face` per font in the
##   fonts block, hidden from Word, Word's fallback for every element in
##   the mso block, `mso-font-alt` on an element whose first family is a
##   web font, an https URL required, and the at-rule declared as an
##   expected degradation outside the families that load web fonts.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[strutils, unittest]
import isonim_email
from isonim_email/lower/text import noLinkText

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

proc newDoc(r: EmailRenderer; h1 = true): (EmailNode, EmailNode) =
  let doc = r.child(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", "Text")])
  let s = r.child(doc, "mailSection")
  if h1:
    discard r.child(s, "h1", text = "Text")
  (doc, s)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc withRule(diags: openArray[EmailDiagnostic]; code,
    rule: string): int =
  for d in diags:
    if d.code == code and rule in d.rules:
      inc result

proc body(html: string): string =
  html[html.find("<body") .. ^1]

proc head(html: string): string =
  html[0 ..< html.find("<body")]

suite "text elements":
  test "test_text_is_real_text_elements_with_an_h1":
    # rule: R-TXT-01
    let r = EmailRenderer()
    let (doc, s) = newDoc(r, h1 = false)
    discard r.child(s, "p", text = "No heading")
    check codeA11yNoH1 in codesOf(renderTree(doc).diagnostics)
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    discard r2.child(s2, "h2", text = "Second")
    discard r2.child(s2, "p", text = "Body")
    let ul = r2.child(s2, "ul")
    discard r2.child(ul, "li", text = "Item")
    discard r2.child(r2.child(s2, "p"), "strong", text = "Strong")
    let res = renderTree(doc2)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    for tag in ["<h1 ", "<h2 ", "<p ", "<ul ", "<li ", "<strong"]:
      checkpoint(tag)
      check tag in html
    # Never text written straight into a styled cell.
    check ">Body</td>" notin html
    check ">Text</td>" notin html

  test "test_heading_levels_are_not_skipped":
    # rule: R-TXT-10
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "h3", text = "Skipped a level")
    check withRule(renderTree(doc).diagnostics, codeA11yHeadingSkip,
      "R-TXT-10") == 1
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    discard r2.child(s2, "h2", text = "Next level")
    check codeA11yHeadingSkip notin codesOf(renderTree(doc2).diagnostics)

suite "text sizes":
  test "test_small_and_tiny_text":
    # rule: R-TXT-03
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "p", [("font-size", "13px")], text = "Small")
    discard r.child(s, "p", [("font-size", "11px")], text = "Tiny")
    discard r.child(s, "p", [("font-size", "14px")], text = "Fine")
    discard r.child(s, "p", [("font-size", "10px")], [("aria-hidden",
      "true")], text = "Hidden")
    # A size inherited from an ancestor counts.
    let box = r.child(s, "mailText", [("font-size", "12px")])
    discard r.child(box, "p", text = "Inherited small")
    let res = renderTree(doc)
    var small, tiny: seq[string] = @[]
    for d in res.diagnostics:
      if d.code == codeA11yFontSmall:
        small.add(d.message)
        check d.severity == sevWarning
        check "R-TXT-03" in d.rules
      if d.code == codeA11yFontTiny:
        tiny.add(d.message)
        check d.severity == sevError
    check small.len == 2
    check "13px" in small[0]
    check "12px" in small[1]
    check tiny.len == 1
    check "11px" in tiny[0]
    # The theme's sizes are clean.
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    discard r2.child(s2, "p", text = "Default")
    check codeA11yFontSmall notin codesOf(renderTree(doc2).diagnostics)

suite "fonts and scaling":
  test "test_font_stacks_end_in_a_generic_family":
    # rule: R-TXT-05
    for (stack, bad) in [("Inter", true), ("Inter, 'Helvetica Neue'", true),
        ("Inter, sans-serif", false), ("'Courier New', monospace", false),
        ("Georgia, serif", false), ("inherit", false)]:
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      discard r.child(s, "p", [("font-family", stack)], text = "Type")
      checkpoint(stack)
      check (withRule(renderTree(doc).diagnostics, codeVocabBadValue,
        "R-TXT-05") == 1) == bad
    # The theme's own stacks.
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "code", text = "mono")
    check withRule(renderTree(doc).diagnostics, codeVocabBadValue,
      "R-TXT-05") == 0

  test "test_nothing_but_the_reset_adjusts_text_size":
    # rule: R-TXT-08
    for (prop, value, bad) in [("-webkit-text-size-adjust", "none", true),
        ("-ms-text-size-adjust", "80%", true), ("text-size-adjust", "none",
        true), ("-webkit-text-size-adjust", "100%", false),
        ("text-size-adjust", "auto", false)]:
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      discard r.child(s, "p", [(prop, value)], text = "Scaled")
      checkpoint(prop & ":" & value)
      check (withRule(renderTree(doc).diagnostics, codeVocabBadValue,
        "R-TXT-08") == 1) == bad
    # The reset's own declaration stays.
    let r = EmailRenderer()
    let (doc, _) = newDoc(r)
    check "*{-ms-text-size-adjust:100%;-webkit-text-size-adjust:100%;}" in
      renderTree(doc).html

  test "test_nolink_spans_keep_numbers_unlinked":
    # rule: R-TXT-06
    check noLinkText("555 123") == "5\u200D5\u200D5\u200D \u200D1\u200D2" &
      "\u200D3"
    check noLinkText("Call now") == "Call now"
    check noLinkText("1 Oct") == "1\u200D Oct"
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let p = r.child(s, "p", text = "Call ")
    discard r.child(p, "span", attrs = [("nolink", "true")],
      text = "+1 555 0100")
    discard r.child(p, "span", attrs = [("nolink", "false")], text = "42")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "<span>+\u200D1\u200D \u200D5\u200D5\u200D5\u200D \u200D0\u200D1" &
      "\u200D0\u200D0</span>" in html
    check "<span>42</span>" in html
    check "nolink" notin html

suite "web fonts":
  test "test_web_fonts_load_with_word_fallbacks":
    # rule: R-TXT-07, R-OL-07
    proc fresh(): EmailNode =
      ## A new tree per render: a render resolves its tree's styles.
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      discard r.child(s, "p", [("font-family",
        "Inter, Helvetica, Arial, sans-serif")], text = "Web font")
      discard r.child(s, "p", text = "Default stack")
      doc
    let doc = fresh()
    var t = defaultTarget()
    t.webFonts = @[WebFont(family: "Inter",
      url: "https://fonts.example/inter.woff2")]
    let res = renderTree(doc, target = t)
    check not hasErrors(res.diagnostics)
    let h = head(res.html)
    # The fonts block: hidden from Word, never in a media query.
    let face = "@font-face{font-family:'Inter';font-style:normal;" &
      "font-weight:400;src:url('https://fonts.example/inter.woff2') " &
      "format('woff2')}"
    check ("<!--[if !mso]><!--><style>" & face & "</style>" &
      "<!--<![endif]-->") in h
    # Word's fallback for every element.
    check "<!--[if mso]><style>*{font-family:Helvetica, Arial, " &
      "sans-serif !important}</style><![endif]-->" in h
    # mso-font-alt where the first family is the web font.
    let html = body(res.html)
    check "font-family:Inter, Helvetica, Arial, sans-serif;" in html
    check "mso-font-alt:Helvetica;" in html
    check html.count("mso-font-alt") == 1
    # The at-rule is an expected degradation outside the families that
    # load web fonts.
    var declared = false
    for d in res.diagnostics:
      if d.code == codeSupportDegradation and "font-face" in d.message:
        declared = true
    check declared
    # Without Word: no mso block, no mso-font-alt; the fonts block stays.
    var plain = t
    plain.outlookWord = false
    let p2 = renderTree(fresh(), target = plain).html
    check "mso-font-alt" notin p2
    check "*{font-family" notin p2
    check "@font-face{" in p2
    # Without web fonts: neither block.
    let none = renderTree(fresh()).html
    check "@font-face" notin none
    check "*{font-family" notin none

  test "test_web_font_urls_must_be_https":
    # rule: R-TXT-07
    for url in ["http://fonts.example/a.woff2", "/fonts/a.woff2",
        "https://fonts.example/a(1).woff2", "data:font/woff2;base64,AA"]:
      let r = EmailRenderer()
      let (doc, _) = newDoc(r)
      var t = defaultTarget()
      t.webFonts = @[WebFont(family: "Inter", url: url, format: "woff2")]
      let res = renderTree(doc, target = t)
      checkpoint(url)
      check withRule(res.diagnostics, codeUrlScheme, "R-TXT-07") == 1
      check "@font-face" notin res.html
