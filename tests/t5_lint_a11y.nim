## P10 lints a11y — meaningless link text (R-A11Y-06),
## light-scheme contrast (R-A11Y-07), and the R-IMG-04 alt-length
## heuristic. All three are warnings. The client-support checks run
## on the same walk, so assertions filter by code.
##
## Backend-independent (tree walk + pure checks), so `just test`
## also runs it on JS.
import std/[sequtils, strutils, unittest]
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
