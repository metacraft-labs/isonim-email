## P10 lints a11y — meaningless link text (R-A11Y-06),
## light-scheme contrast (R-A11Y-07), and the R-IMG-04 alt-length
## heuristic. All three are warnings. The client-support checks run
## on the same walk, so assertions filter by code.
##
## Backend-independent (tree walk + pure checks), so `just test`
## also runs it on JS.
import std/[sequtils, strutils, tables, unittest]
import isonim_email

proc withCode(diags: seq[EmailDiagnostic]; code: string): seq[EmailDiagnostic] =
  diags.filterIt(it.code == code)

proc link(r: EmailRenderer; text: string): EmailNode =
  let a = r.createElement("a")
  r.setAttribute(a, "href", "https://example.com/")
  r.setTextContent(a, text)
  a

proc para(r: EmailRenderer; color: string;
             extra: seq[(string, string)] = @[]): EmailNode =
  let p = r.createElement("p")
  r.setStyle(p, "color", color)
  for (prop, value) in extra:
    r.setStyle(p, prop, value)
  r.setTextContent(p, "Sample copy")
  p

suite "P10 a11y lint":
  test "test_lint_link_placeholders":
    # rule: R-A11Y-06
    let r = EmailRenderer()
    let root = r.createElement("div")
    for text in ["click here", "  Click Here  ", "here", "READ MORE"]:
      r.appendChild(root, link(r, text))
    let nested = r.createElement("a")
    r.setAttribute(nested, "href", "https://example.com/")
    let inner = r.createElement("span")
    r.setTextContent(inner, "here")
    r.appendChild(nested, inner)
    r.appendChild(root, nested)
    let diags = withCode(lintTree(root, consumer), codeA11yLinkText)
    check diags.len == 5
    for d in diags:
      check d.severity == sevWarning
      check d.rules == @["R-A11Y-06"]
    check "click here" in diags[0].message
    # Descriptive text, URLs mid-sentence, and empty links stay silent.
    let clean = r.createElement("div")
    r.appendChild(clean, link(r, "Read the pricing guide"))
    r.appendChild(clean, link(r, "our pricing (https://example.com)"))
    r.appendChild(clean, link(r, ""))
    check withCode(lintTree(clean, consumer), codeA11yLinkText).len == 0

  test "test_lint_link_bare_url":
    # rule: R-A11Y-06
    let r = EmailRenderer()
    let root = r.createElement("div")
    let bare = link(r, "https://example.com/pricing")
    bare.origin = SourceSpan(file: "link.nim", line: 4, col: 9)
    r.appendChild(root, bare)
    r.appendChild(root, link(r, "HTTP://X.TEST/Y"))
    let diags = withCode(lintTree(root, consumer), codeA11yLinkText)
    check diags.len == 2
    check diags[0].severity == sevWarning
    check diags[0].origin == SourceSpan(file: "link.nim", line: 4, col: 9)

  test "test_lint_contrast_threshold":
    # rule: R-A11Y-07
    let r = EmailRenderer()
    let root = r.createElement("div")
    # #777777 on white is 4.48:1 — just under the 4.5 line.
    r.appendChild(root, para(r, "#777777"))
    let diags = withCode(lintTree(root, consumer), codeA11yContrast)
    check diags.len == 1
    check diags[0].severity == sevWarning
    check "4.48:1" in diags[0].message
    check "4.5:1" in diags[0].message
    check diags[0].rules == @["R-A11Y-07"]
    # Black on white (21:1) passes; elements without color, outside
    # the text-element set, or with unparseable colors are skipped.
    let clean = r.createElement("div")
    r.appendChild(clean, para(r, "#000000"))
    let plain = r.createElement("p")
    r.setTextContent(plain, "No color, no check")
    r.appendChild(clean, plain)
    let box = r.createElement("div")
    r.setStyle(box, "color", "#777777")
    r.setTextContent(box, "Not a text element")
    r.appendChild(clean, box)
    r.appendChild(clean, para(r, "not-a-color"))
    check withCode(lintTree(clean, consumer), codeA11yContrast).len == 0

  test "test_lint_contrast_large_text":
    # rule: R-A11Y-07
    # #808080 on white is 3.95:1 — warns at body size, passes large.
    let r = EmailRenderer()
    proc treeWith(size, weight: string): EmailNode =
      let root = r.createElement("div")
      var extra: seq[(string, string)] = @[]
      if size.len > 0:
        extra.add(("font-size", size))
      if weight.len > 0:
        extra.add(("font-weight", weight))
      r.appendChild(root, para(r, "#808080", extra))
      root
    check withCode(lintTree(treeWith("", ""), consumer),
      codeA11yContrast).len == 1
    check withCode(lintTree(treeWith("24px", ""), consumer),
      codeA11yContrast).len == 0
    check withCode(lintTree(treeWith("19px", "bold"), consumer),
      codeA11yContrast).len == 0
    check withCode(lintTree(treeWith("19px", "700"), consumer),
      codeA11yContrast).len == 0
    check withCode(lintTree(treeWith("19px", ""), consumer),
      codeA11yContrast).len == 1
    check withCode(lintTree(treeWith("18px", "bold"), consumer),
      codeA11yContrast).len == 1
    let big = withCode(lintTree(treeWith("16px", ""), consumer),
      codeA11yContrast)
    check "3.95:1" in big[0].message

  test "test_lint_contrast_ancestor_background":
    # rule: R-A11Y-07
    let r = EmailRenderer()
    # White on a black ancestor is 21:1 — the ancestor carries bg.
    let root = r.createElement("div")
    r.setStyle(root, "background-color", "#000000")
    r.appendChild(root, para(r, "#ffffff"))
    check withCode(lintTree(root, consumer), codeA11yContrast).len == 0
    # White with no ancestor background reads against white (1:1).
    let bare = r.createElement("div")
    r.appendChild(bare, para(r, "#ffffff"))
    let diags = withCode(lintTree(bare, consumer), codeA11yContrast)
    check diags.len == 1
    check "1.00:1" in diags[0].message
    # The nearest ancestor wins over outer ones.
    let outer = r.createElement("div")
    r.setStyle(outer, "background-color", "#ffffff")
    let mid = r.createElement("div")
    r.setStyle(mid, "background-color", "#000000")
    r.appendChild(outer, mid)
    r.appendChild(mid, para(r, "#ffffff"))
    check withCode(lintTree(outer, consumer), codeA11yContrast).len == 0

  test "test_lint_alt_length":
    # R-IMG-04 length half (presence is P1's; the R-IMG-04 claim stays
    # pending until the content leaves own the whole row).
    let r = EmailRenderer()
    let root = r.createElement("div")
    let long = r.createElement("mailImage")
    long.origin = SourceSpan(file: "img.nim", line: 2, col: 1)
    r.setAttribute(long, "src", "https://x.test/a.png")
    r.setAttribute(long, "alt", "a".repeat(61))
    r.appendChild(root, long)
    let lowered = r.createElement("img")
    r.setAttribute(lowered, "src", "https://x.test/b.png")
    r.setAttribute(lowered, "alt", "b".repeat(100))
    r.appendChild(root, lowered)
    let diags = withCode(lintTree(root, consumer), codeA11yAltLong)
    check diags.len == 2
    check diags[0].severity == sevWarning
    check diags[0].origin.file == "img.nim"
    check "61" in diags[0].message
    check diags[0].rules == @["R-IMG-04"]
    # Exactly 60 is fine, and missing alt is P1's error, not this
    # check's warning.
    let clean = r.createElement("div")
    let edge = r.createElement("mailImage")
    r.setAttribute(edge, "src", "https://x.test/c.png")
    r.setAttribute(edge, "alt", "c".repeat(60))
    r.appendChild(clean, edge)
    let missing = r.createElement("mailImage")
    r.setAttribute(missing, "src", "https://x.test/d.png")
    r.appendChild(clean, missing)
    check withCode(lintTree(clean, consumer), codeA11yAltLong).len == 0

proc designedDoc(r: EmailRenderer; body: EmailNode): EmailNode =
  ## A minimal document around `body`.
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Dark scheme")
  r.setAttribute(doc, "preheader", "Dark scheme contrast.")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Dark scheme")
  r.setStyle(h1, "color", "#111827")
  r.appendChild(doc, h1)
  r.appendChild(doc, body)
  doc

suite "P10 dark-scheme contrast under darkMode=designed":
  test "test_lint_dark_contrast_pairs":
    # The dark value paints over the nearest background's dark value;
    # an element without a dark value keeps its light one.
    let r = EmailRenderer()
    let p = para(r, "#111827")
    let bare = r.createElement("div")
    r.appendChild(bare, p)
    let onWhite = withCode(lintDarkContrast(bare,
      @[(p, "color", "#f3f4f6")]), codeA11yContrastDark)
    check onWhite.len == 1
    check onWhite[0].severity == sevError
    check onWhite[0].rules == @["R-DRK-04"]
    check "#f3f4f6 on #ffffff" in onWhite[0].message
    # A dark background on an ancestor makes the pair legible.
    let box = r.createElement("div")
    r.setStyle(box, "background-color", "#ffffff")
    let q = para(r, "#111827")
    r.appendChild(box, q)
    check withCode(lintDarkContrast(box, @[(q, "color", "#f3f4f6"),
      (box, "background-color", "#1a1d23")]), codeA11yContrastDark).len == 0
    # Without dark values the pair is the light one.
    check withCode(lintDarkContrast(box, @[]),
      codeA11yContrastDark).len == 0

  test "test_render_container_dark_colour_reaches_uncoloured_text":
    # A container with token colours and dark variants, an uncoloured
    # paragraph inside: the paragraph's dark colour is the container's
    # and its dark pair passes.
    let r = EmailRenderer()
    let box = r.createElement("div")
    r.setStyle(box, "color", "tok:color.text.primary")
    r.setStyle(box, "@dark:color", "tok:color.text.primary")
    r.setStyle(box, "background-color", "tok:color.surface.card")
    r.setStyle(box, "@dark:background-color", "tok:color.surface.card")
    let p = r.createElement("p")
    r.setTextContent(p, "Inherits its colour.")
    r.appendChild(box, p)
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let res = renderTree(designedDoc(r, box), target = designed)
    check withCode(res.diagnostics, codeA11yContrastDark).len == 0
    check p.styles["color"] == "#111827"
    let cls = p.attrs.getOrDefault("class", "")
    check cls != ""
    check ("." & cls & "{color:#f3f4f6 !important}") in res.html

  test "test_render_default_text_on_the_undarkened_skeleton_errors":
    # No ancestor colour and no dark background: the default text gets
    # its dark value (#f3f4f6) and sits on the document background,
    # which has no dark value yet, so the dark pair fails.
    let r = EmailRenderer()
    let p = r.createElement("p")
    r.setTextContent(p, "On the document background.")
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let res = renderTree(designedDoc(r, p), target = designed)
    let found = withCode(res.diagnostics, codeA11yContrastDark)
    check found.len == 1
    check found[0].origin == p.origin
    check "#f3f4f6 on #ffffff" in found[0].message
    # The error says why and what to do about it.
    check "the document background, which has no dark value" in
      found[0].message
    check "put it in a container with a dark background" in
      found[0].message
    # accommodate writes no dark CSS, so there is no dark pair to fail.
    let r2 = EmailRenderer()
    let p2 = r2.createElement("p")
    r2.setTextContent(p2, "On the document background.")
    let plain = renderTree(designedDoc(r2, p2))
    check withCode(plain.diagnostics, codeA11yContrastDark).len == 0

  test "test_render_dark_contrast_needs_the_dark_block":
    # The dark scheme is checked only when the dark head block survives
    # the budget: a dropped block paints nothing dark, so the default
    # text keeps its light colour and the light check covers it.
    let r = EmailRenderer()
    let p = r.createElement("p")
    r.setTextContent(p, "On the document background.")
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    designed.headStyleBudget = 1
    let res = renderTree(designedDoc(r, p), target = designed)
    check withCode(res.diagnostics, codeCssBlockDropped).len > 0
    check "prefers-color-scheme" notin res.html
    check withCode(res.diagnostics, codeA11yContrastDark).len == 0
    # A light background with no dark value on a container: the advice
    # names that background rather than the document's.
    let r2 = EmailRenderer()
    let box = r2.createElement("div")
    r2.setStyle(box, "background-color", "#ffffff")
    let q = r2.createElement("p")
    r2.setTextContent(q, "On a light container.")
    r2.appendChild(box, q)
    designed.headStyleBudget = defaultTarget().headStyleBudget
    let res2 = renderTree(designedDoc(r2, box), target = designed)
    let found = withCode(res2.diagnostics, codeA11yContrastDark)
    check found.len == 1
    check "a background with no dark value" in found[0].message
    check "the document background" notin found[0].message
