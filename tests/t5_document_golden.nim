# rule: R-DOC-01
# rule: R-DOC-02
# rule: R-DOC-03
# rule: R-DOC-04
# rule: R-DOC-05
# rule: R-DOC-06
# rule: R-DOC-07
# rule: R-DOC-08
# rule: R-DOC-09
# rule: R-DOC-10
# rule: R-DOC-11
# rule: R-DOC-12
# rule: R-DOC-13
# rule: R-DOC-14
# rule: R-RST-01
# rule: R-RST-02
# rule: R-RST-03
# rule: R-RST-04
# rule: R-RST-05
# rule: R-RST-06
# rule: R-RST-07
# rule: R-RST-08
# rule: R-RST-09
# rule: R-RST-10
# rule: R-RST-11
# rule: R-RST-13
# rule: R-CSS-02
# rule: R-CSS-07
## An empty `mailDocument` lowers to the catalogue §1 skeleton,
## byte-exact against `tests/golden/skeleton_{word,noword}.html` with
## `outlookWord` on and off. The goldens pin the bytes;
## the structural tests below pin every rule's placement independently
## of them (R-DOC-01…13, R-RST-01…11 and 13 — not R-RST-12, which stays
## pending).
##
## R-CSS-07 is claimed here for separate `<style>` elements in
## priority order; the dropping half stays covered by
## tests/t4_head_budget.nim. R-CSS-02 is claimed through the
## membership audit over the assembled head.
##
## Golden update, 2026-09-30: both goldens were re-recorded because
## their head blocks pinned output that contradicted the catalogue:
## - R-DRK-03: the dark block's `[data-ogsb]` copy carried `color`;
##   `[data-ogsc]` copies now carry `color` only and `[data-ogsb]`
##   copies `background-color` only (the fixture's dark group gained a
##   background colour so both copies stay pinned);
## - `sm:` is the mobile variant, so the responsive fixture rule sits
##   under `max-width: 479px`, not `min-width: 480px`;
## - R-INT-02: the `:hover` rule carries `!important`;
## - R-CSS-08: class names hash the variant, so the generated names
##   changed.
## Every other byte is unchanged.
##
## Golden update, 2026-10-01: both goldens were re-recorded because
## they pinned a dark block under the default `darkMode =
## dmAccommodate`. R-DRK-02 (amended) emits dark CSS only under
## `dmDesigned`; `dmAccommodate` keeps the colour-scheme metas
## (R-DOC-07) and writes no dark CSS. The diff is one hunk per golden:
## the whole third `<style>` element (`[data-ogsb] .e-2bi{…}`,
## `[data-ogsc] .e-2bi{…}` and the `prefers-color-scheme` query) is
## gone. Every other byte is unchanged, including the metas and the
## other generated class names (`e-1b9`, `e-3oj`). The removed bytes
## stay pinned: `test_document_skeleton_designed_adds_dark_block`
## requires the `dmDesigned` render to be the golden with exactly that
## element put back in block-3 position.
##
## Golden update, 2026-10-01 (second): both goldens lost the
## ` class="body"` attribute of `<body>` (R-DOC-14, catalogue §1
## amended first): Roundcube copies a body class over the `rcmBody`
## class its scoped head rules select, so with it none of the
## message's head CSS applied there. One hunk per golden, that
## attribute only; every other byte is unchanged.
##
## Backend-independent (tree building + pure passes; the goldens load
## via `staticRead`), so `just test` also runs it on JS.
import std/[algorithm, os, strutils, unittest]
import isonim_email

const goldenDir = parentDir(currentSourcePath()) / "golden"
const wordGolden = staticRead(goldenDir / "skeleton_word.html")
const nowordGolden = staticRead(goldenDir / "skeleton_noword.html")

proc hd(node: EmailNode; variant, prop, value: string): HeadDecl =
  HeadDecl(variant: variant, prop: prop, value: value, node: node,
    origin: SourceSpan())

proc fullHead(target: EmailTarget): seq[EmailNode] =
  ## Full P6 assembly: reset + responsive + dark + fonts +
  ## decorative + mso, nothing dropped. The dark block exists only
  ## under `darkMode = dmDesigned`: `dmNone` and `dmAccommodate` write
  ## no dark CSS.
  var big = target
  big.headStyleBudget = 1_000_000
  let r = EmailRenderer()
  let sm = r.createElement("div")
  let dark = r.createElement("p")
  let hover = r.createElement("a")
  let decls = @[
    hd(sm, "sm", "width", "100%"),
    hd(dark, "dark", "color", "#e5e7eb"),
    hd(dark, "dark", "background-color", "#111827"),
    hd(hover, "hover", "text-decoration", "underline"),
  ]
  let webfonts = @[@[Declaration(prop: "font-family", value: "Custom"),
    Declaration(prop: "src", value: "url(a.woff2)")]]
  # The mso feed uses a client-targeting selector (catalogue §2), so the
  # R-CSS-02 audit below covers the conditional block too; the component
  # work owns the real feeder content.
  let msoRules = @[Rule(kind: rkStyle, selector: "#outlook a",
    decls: @[Declaration(prop: "padding", value: "0")])]
  let res = assembleHead(decls, big, webfonts, msoRules)
  doAssert res.diagnostics.len == 0
  doAssert res.blocks.len == (if target.darkMode == dmDesigned: 6 else: 5)
  res.blocks

proc emptyDoc(): EmailNode =
  EmailRenderer().createElement("mailDocument")

proc render(outlookWord: bool; darkMode = defaultTarget().darkMode): string =
  ## The default target (`dmAccommodate`) unless a dark mode is given.
  var target = defaultTarget()
  target.outlookWord = outlookWord
  target.darkMode = darkMode
  serializeDocument(lowerDocument(emptyDoc(), nil, fullHead(target),
    target))

const resetLines = [
  "html,body{margin:0 auto !important;padding:0 !important;" &
    "height:100% !important;width:100% !important;}",
  "*{-ms-text-size-adjust:100%;-webkit-text-size-adjust:100%;}",
  "div[style*=\"margin: 16px 0\"]{margin:0 !important;}",
  "#MessageViewBody,#MessageWebViewDiv{width:100% !important;}",
  "table,td{mso-table-lspace:0pt !important;" &
    "mso-table-rspace:0pt !important;}",
  "table{border-spacing:0 !important;border-collapse:collapse !important;" &
    "table-layout:fixed !important;margin:0 auto !important;}",
  "img{-ms-interpolation-mode:bicubic;border:0;height:auto;" &
    "line-height:100%;outline:none;text-decoration:none;}",
  "a{text-decoration:none;}",
  "#outlook a{padding:0;}",
  "a[x-apple-data-detectors],.unstyle-auto-detected-links a,.aBn{" &
    "border-bottom:0 !important;cursor:default !important;" &
    "color:inherit !important;text-decoration:none !important;" &
    "font-size:inherit !important;font-family:inherit !important;" &
    "font-weight:inherit !important;line-height:inherit !important;}",
  ".im{color:inherit !important;}",
  ".a6S{display:none !important;opacity:0.01 !important;}",
  "img.g-img+div{display:none !important;}",
]

const resetSelectors = [
  "html,body", "*", "div[style*=\"margin: 16px 0\"]",
  "#MessageViewBody,#MessageWebViewDiv", "table,td", "table", "img",
  "a", "#outlook a",
  "a[x-apple-data-detectors],.unstyle-auto-detected-links a,.aBn",
  ".im", ".a6S", "img.g-img+div",
]

proc topLevelRules(blockText: string): seq[string] =
  ## Splits a block into top-level rules: an `@media` rule's inner
  ## braces never split.
  var depth = 0
  var start = 0
  for i, c in blockText:
    if c == '{':
      inc depth
    elif c == '}':
      dec depth
      if depth == 0:
        result.add(blockText[start .. i])
        start = i + 1
  doAssert depth == 0, "unbalanced braces in head block"

template auditHeadMembership(blocks: seq[EmailNode]) =
  ## R-CSS-02: every top-level head rule is an `@media` rule, a
  ## pseudo-class rule, a client-targeting selector (catalogue §2, R-DRK-03),
  ## or `@font-face` — nothing else. A template, like `checkIncreasing`:
  ## a `check` inside a proc prints its failure and fails the process,
  ## but marks no test failed; expanded into the test, it does.
  var media, faces, hover, ogsc, reset = 0
  for b in blocks:
    for rule in topLevelRules(b.text):
      let sel = rule[0 ..< rule.find('{')].strip()
      if rule.startsWith("@media"):
        inc media
        # Inner rules ride inside the @media (responsive/dark
        # element classes plus the thunderbird/owa copies); each
        # must still be a valid selector.
        for r in topLevelRules(rule[rule.find('{') + 1 ..< ^1]):
          check validSelector(r[0 ..< r.find('{')].strip())
      elif rule.startsWith("@font-face"):
        inc faces
      elif ":hover" in sel:
        inc hover
        check sel.endsWith(":hover")
      elif sel.startsWith("[data-ogsc] .") or
          sel.startsWith("[data-ogsb] ."):
        inc ogsc
      else:
        inc reset
        check sel in resetSelectors
  # Vacuity guards: the audit must have seen every allowed kind.
  check media == 2
  check faces == 1
  check hover == 1
  check ogsc == 2
  check reset == 13 + 1 # The catalogue §2 lines plus the mso feed's `#outlook a`.

template checkIncreasing(html: string; markers: openArray[string]) =
  var lastPos = -1
  for m in markers:
    let p = html.find(m)
    check p > lastPos
    lastPos = p

suite "document golden skeleton":
  test "test_document_skeleton_golden_word":
    # rule: R-DOC-01
    # rule: R-DOC-12
    # rule: R-CSS-07
    let html = render(true)
    check html == wordGolden
    # R-DOC-01: the exact doctype opens the document.
    check html.startsWith("<!doctype html><html")

  test "test_document_skeleton_golden_noword":
    let html = render(false)
    check html == nowordGolden
    check html.startsWith("<!doctype html><html")

  test "test_document_skeleton_designed_adds_dark_block":
    # rule: R-DOC-07
    # The default target accommodates dark mode: metas, no dark CSS.
    # `dmDesigned` adds block 3 and changes nothing else, byte for byte.
    const darkBlock = "<style>" &
      "[data-ogsb] .e-2bi{background-color:#111827 !important}" &
      "[data-ogsc] .e-2bi{color:#e5e7eb !important}" &
      "@media (prefers-color-scheme: dark){.e-2bi{" &
      "background-color:#111827 !important;color:#e5e7eb !important}}" &
      "</style>"
    const fontsOpen = "<!--[if !mso]><!--><style>@font-face"
    check defaultTarget().darkMode == dmAccommodate
    for (word, golden) in [(true, wordGolden), (false, nowordGolden)]:
      let accommodate = render(word)
      check "<meta name=\"color-scheme\" content=\"light dark\">" in
        accommodate
      check "prefers-color-scheme" notin accommodate
      check "data-ogs" notin accommodate
      check "e-2bi" notin accommodate
      let at = golden.find(fontsOpen)
      check at > 0
      check render(word, dmDesigned) ==
        golden[0 ..< at] & darkBlock & golden[at .. ^1]

  test "test_document_head_metas":
    # rule: R-DOC-02
    # rule: R-DOC-03
    # rule: R-DOC-04
    # rule: R-DOC-05
    # rule: R-DOC-06
    # rule: R-DOC-07
    for html in [render(true), render(false)]:
      # R-DOC-02: lang/dir on <html>, duplicated on the wrapper
      # (clients strip them from <html>); xml:lang on <body>.
      check "<html lang=\"en\" dir=\"ltr\"" in html
      check "aria-label=\"\" lang=\"en\" dir=\"ltr\"" in html
      check "<body xml:lang=\"en\"" in html
      # R-DOC-03…07: the metas in skeleton order.
      checkIncreasing(html, [
        "<meta charset=\"utf-8\">",
        "<meta name=\"viewport\" content=\"width=device-width, " &
          "initial-scale=1, user-scalable=yes\">",
        "<!--[if !mso]><!--><meta http-equiv=\"X-UA-Compatible\" " &
          "content=\"IE=edge\"><!--<![endif]-->",
        "<meta name=\"format-detection\" content=\"telephone=no, " &
          "date=no, address=no, email=no, url=no\">",
        "<meta name=\"x-apple-disable-message-reformatting\">",
        "<meta name=\"color-scheme\" content=\"light dark\">",
        "<meta name=\"supported-color-schemes\" content=\"light dark\">",
        "<title></title>",
      ])
    # R-DOC-07: no pair when darkMode is none.
    var target = defaultTarget()
    target.darkMode = dmNone
    let html = serializeDocument(lowerDocument(emptyDoc(), nil,
      fullHead(target), target))
    # The metas go, and so do the dark rules.
    check "<meta name=\"color-scheme\"" notin html
    check "<meta name=\"supported-color-schemes\"" notin html
    check "prefers-color-scheme" notin html
    check "data-ogs" notin html

  test "test_document_outlook_conditionals":
    # rule: R-DOC-08
    let word = render(true)
    let noword = render(false)
    let settings = "<!--[if mso]><noscript><xml>" &
      "<o:OfficeDocumentSettings><o:AllowPNG/>" &
      "<o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings>" &
      "</xml></noscript><![endif]-->"
    check settings in word
    check settings notin noword
    check "[if mso]" notin noword
    let groupFix = "<!--[if lte mso 11]><style>" &
      ".e-mso-group-fix{width:100% !important;}" &
      "</style><![endif]-->"
    check groupFix in word
    check groupFix notin noword
    check "lte mso 11" notin noword

  test "test_document_body_and_wrapper":
    # rule: R-DOC-09
    # rule: R-DOC-10
    # rule: R-DOC-11
    # rule: R-DOC-13
    for html in [render(true), render(false)]:
      # R-DOC-09: the background in three places (Gmail and Yahoo
      # drop <body> styles).
      check html.count("background-color:#ffffff") == 3
      # R-DOC-10: the article landmark.
      check "<div role=\"article\" aria-roledescription=\"email\" " &
        "aria-label=\"\" lang=\"en\" dir=\"ltr\"" in html
      # R-DOC-11: the doubled font size.
      check "background-color:#ffffff;font-size:medium;" &
        "font-size:max(16px, 1rem);" in html
      # R-DOC-13: word-spacing on <body>. Backend-effect
      # confirmation rides with later capture evidence.
      check "<body xml:lang=\"en\" style=\"margin:0;" &
        "padding:0;word-spacing:normal;background-color:#ffffff;\">" in
        html
      # R-DOC-14: no class on <body> (Roundcube would put it in place
      # of the class its scoped head rules select).
      # rule: R-DOC-14
      check "class=" notin html.split("<body")[1].split(">")[0]
      # The wrapper table carries no align attribute; the cell does.
      check "<table role=\"presentation\" width=\"100%\" border=\"0\" " &
        "cellpadding=\"0\" cellspacing=\"0\" " &
        "style=\"background-color:#ffffff;\">" in html
      check "<tr><td align=\"center\"></td></tr>" in html

  test "test_document_style_block_order":
    # rule: R-DOC-12
    # rule: R-CSS-07
    # Every block is present only under `dmDesigned` (the dark block
    # needs it); the default target has one <style> fewer.
    let word = render(true, dmDesigned)
    let noword = render(false, dmDesigned)
    # Separate <style> elements in priority order (R-CSS-07's
    # emission half; t4_head_budget covers the dropping half).
    check word.count("<style>") == 7
    check noword.count("<style>") == 5
    check render(true).count("<style>") == 6
    check render(false).count("<style>") == 4
    checkIncreasing(word, [
      "<style>html,body{margin:0 auto !important;",
      "@media only screen and (max-width: 479px)",
      "(prefers-color-scheme: dark)",
      "<!--[if !mso]><!--><style>@font-face{font-family:Custom;" &
        "src:url(a.woff2)}</style><!--<![endif]-->",
      ":hover",
      "<!--[if mso]><style>#outlook a{padding:0}</style><![endif]-->",
      "<!--[if lte mso 11]><style>",
    ])
    checkIncreasing(noword, [
      "<style>html,body{margin:0 auto !important;",
      "@media only screen and (max-width: 479px)",
      "(prefers-color-scheme: dark)",
      "<!--[if !mso]><!--><style>@font-face",
      ":hover",
    ])
    check "<!--[if mso]><style>" notin noword
    # R-DOC-12: every <style> sits in <head>, before any element
    # that uses its classes.
    for html in [word, noword]:
      let headEnd = html.find("</head>")
      var pos = 0
      while true:
        let p = html.find("<style>", pos)
        if p < 0:
          break
        check p < headEnd
        pos = p + 1
      check html.find("<style>", html.find("<body")) < 0

  test "test_document_reset_lines":
    # rule: R-RST-01
    # rule: R-RST-02
    # rule: R-RST-03
    # rule: R-RST-04
    # rule: R-RST-05
    # rule: R-RST-06
    # rule: R-RST-07
    # rule: R-RST-08
    # rule: R-RST-09
    # rule: R-RST-10
    # rule: R-RST-11
    # rule: R-RST-13
    # The catalogue §2 exact 13 lines, each present and in order
    # (R-RST-12 stays pending). The order is the catalogue's, which is
    # not sorted order: R-CSS-16 sorts generated rules only, and the
    # reset is emitted verbatim.
    check sorted(resetLines) != @resetLines
    for html in [render(true), render(false)]:
      checkIncreasing(html, resetLines)

  test "test_head_membership_audit":
    # rule: R-CSS-02
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    auditHeadMembership(fullHead(designed))

  test "test_document_sections_land_in_cell":
    # A non-empty document nests its sections in the wrapper cell.
    let r = EmailRenderer()
    let sections = r.createElement("div")
    r.setTextContent(sections, "Hi")
    let html = serializeDocument(lowerDocument(emptyDoc(), sections,
      @[], defaultTarget()))
    check "<tr><td align=\"center\"><div>Hi</div></td></tr>" in html
