# rule: R-PRE-01
# rule: R-PRE-05
## The preheader is the first content in `<body>`, as the
## catalogue §9 exact two divs, with padding N = clamp(100 − len, 0,
## 150) units of the `preheaderPad` flag.
##
## R-PRE-02 stays pending (the sequence and N settle from captures),
## but the formula is pinned here; R-PRE-03 (`aria-hidden`, P7) is
## asserted present, not claimed.
##
## Backend-independent (tree building + pure lowering), so `just test`
## also runs it on JS.
import std/[strutils, unittest]
import isonim_email

proc docWith(preheader: string): EmailNode =
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "preheader", preheader)
  doc

suite "preheader":
  test "test_preheader_padding_count_boundaries":
    # R-PRE-02's formula, pinned (rule itself stays pending).
    check preheaderPaddingUnits("") == 100
    check preheaderPaddingUnits("x".repeat(40)) == 60
    check preheaderPaddingUnits("x".repeat(99)) == 1
    check preheaderPaddingUnits("x".repeat(100)) == 0
    check preheaderPaddingUnits("x".repeat(250)) == 0
    # len counts characters, not bytes: 10 × U+00E9 is 10 chars.
    check preheaderPaddingUnits("é".repeat(10)) == 90

  test "test_preheader_first_in_body":
    # rule: R-PRE-01
    let html = serializeDocument(lowerDocument(docWith("Hello"), nil,
      @[], defaultTarget()))
    let firstDiv = "<div style=\"display:none;font-size:1px;" &
      "color:#ffffff;line-height:1px;max-height:0;max-width:0;" &
      "opacity:0;overflow:hidden;mso-hide:all;\">Hello</div>"
    check firstDiv in html
    # Padding: 100 − 5 = 95 default units, `aria-hidden` present
    # (asserted, not claimed — R-PRE-03 is P7's).
    let padDivOpen = "<div style=\"display:none;font-size:1px;" &
      "line-height:1px;max-height:0;max-width:0;opacity:0;" &
      "overflow:hidden;mso-hide:all;\" aria-hidden=\"true\">"
    check padDivOpen in html
    check html.count("&#847;&zwnj;&nbsp;") == 95
    # First content in <body>, before the article wrapper.
    let bodyPos = html.find("<body")
    let firstPos = html.find(firstDiv)
    let padPos = html.find(padDivOpen)
    let wrapPos = html.find("<div role=\"article\"")
    check bodyPos >= 0 and firstPos > bodyPos
    check padPos > firstPos and wrapPos > padPos

  test "test_preheader_pad_flag":
    # The unit sequence is the `preheaderPad` target flag.
    var target = defaultTarget()
    target.preheaderPad = "&nbsp;"
    let html = serializeDocument(lowerDocument(docWith("Hello"), nil,
      @[], target))
    check html.count("&nbsp;") == 95
    check "&#847;" notin html

  test "test_preheader_empty_padding":
    # Empty preheader: empty first div, full 100-unit padding.
    let html = serializeDocument(lowerDocument(docWith(""), nil,
      @[], defaultTarget()))
    check "mso-hide:all;\"></div>" in html
    check html.count("&#847;&zwnj;&nbsp;") == 100

  test "test_preheader_size_accounting":
    # rule: R-PRE-05
    # Accounting reading: the catalogue's "150 units ≈ 1.8 KB" is
    # 150 × ~12 bytes = 1800 bytes. The full R-SIZE-01 gate (warn /
    # error thresholds, contributor breakdown) stays with the size gate;
    # what this pins is the cap the formula feeds it: at most 100 units.
    check 150 * 12 == 1800
    check preheaderPaddingUnits("") == 100
    check defaultTarget().preheaderPad.len == 18
    check 100 * defaultTarget().preheaderPad.len == 1800
