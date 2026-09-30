# rule: R-SIZE-01
# rule: R-SIZE-02
## The size budget (P10). Decoded HTML at or under
## `EmailTarget.sizeBudget` (90,000) is silent; above it warns,
## and above 100,000 errors — Gmail clips at ~102 KB. Diagnostics
## report the byte contributors so authors see what to cut.
##
## The breakdown a render reports is computed while the bytes are
## written; the test re-derives every entry from the finished HTML with
## its own substring scan (Outlook conditionals masked out first) and
## requires the two to agree byte for byte.
##
## Backend-independent (pure string measure), so `just test` also runs
## it on JS.
import std/[strutils, unittest]
import isonim_email

proc sizedTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Size",
        preheader = "Your account is ready."):
      # Only elements with a lowering (an unlowered element would add
      # its own error): a linked call to action stands in for the
      # button, carrying the same URL and inline styles.
      h1: text "Size"
      mailImage(src = "https://cdn.example.com/hero.png?utm_source=" &
        "news&utm_medium=email", alt = "Hero", width = "600px")
      a(href = "https://app.example.com/?utm_campaign=x",
          border_radius = "6px"):
        text "Open dashboard"

proc msoRegions(html: string): seq[(int, int)] =
  ## `[start, end)` of every `<!--[if mso…]>…<![endif]-->` region (the
  ## negated `<!--[if !mso]>` form is not Outlook content).
  var at = 0
  while true:
    let a = html.find("<!--[if ", at)
    if a < 0:
      break
    let b = html.find("<![endif]-->", a)
    if not html.continuesWith("!mso]", a + "<!--[if ".len):
      result.add((a, b + "<![endif]-->".len))
    at = b + 1

proc outsideMso(html: string): string =
  ## The HTML with Outlook regions and the `!mso` markers removed.
  var last = 0
  for (a, b) in msoRegions(html):
    result.add(html[last ..< a])
    last = b
  result.add(html[last .. ^1])
  result = result.replace("<!--[if !mso]><!-->", "").replace(
    "<!--<![endif]-->", "")

proc spans(html, open, close: string; inner: bool): int =
  ## Total length of `open…close` spans (or only what lies between).
  var at = 0
  while true:
    let a = html.find(open, at)
    if a < 0:
      break
    let b = html.find(close, a + open.len)
    result += (if inner: b - (a + open.len) else: b + close.len - a)
    at = b + close.len

proc entry(breakdown: seq[(string, int)]; key: string): int =
  for (k, v) in breakdown:
    if k == key:
      return v
  -1

const breakdown = @[("head CSS", 12_000), ("inline styles", 40_000),
  ("URLs", 8_000), ("preheader padding", 1_800), ("MSO/VML", 20_000)]

suite "size budget":
  test "decoded size is bytes, silence at or under budget":
    # rule: R-SIZE-01
    check decodedHtmlSize("hello") == 5
    check decodedHtmlSize("caf\u00E9") == 5 # multibyte counts bytes

    let target = defaultTarget()
    check target.sizeBudget == 90_000
    check checkSize("<p>hi</p>", target).len == 0
    check checkSize("x".repeat(90_000), target).len == 0

  test "warn above budget, error above the hard limit":
    # rule: R-SIZE-01

    let target = defaultTarget()
    let warn = checkSize("x".repeat(90_001), target)
    check warn.len == 1
    check warn[0].code == codeSizeNearClip
    check warn[0].severity == sevWarning
    check warn[0].rules == @["R-SIZE-01"]
    check "90001" in warn[0].message
    check "90000" in warn[0].message

    # 100,000 still warns; 100,001 errors.
    check checkSize("x".repeat(100_000), target)[0].code ==
      codeSizeNearClip
    let over = checkSize("x".repeat(100_001), target)
    check over.len == 1
    check over[0].code == codeSizeClip
    check over[0].severity == sevError
    check over[0].rules == @["R-SIZE-01"]

    # The warn threshold follows the sizeBudget flag.
    var tiny = defaultTarget()
    tiny.sizeBudget = 100
    check checkSize("x".repeat(100), tiny).len == 0
    check checkSize("x".repeat(101), tiny)[0].code == codeSizeNearClip

  test "diagnostics report the contributors":
    # rule: R-SIZE-02

    let target = defaultTarget()
    let diags = checkSize("x".repeat(95_000), target, breakdown)
    check diags.len == 1
    check diags[0].code == codeSizeNearClip
    check diags[0].rules == @["R-SIZE-01", "R-SIZE-02"]
    check "95000" in diags[0].message
    for (what, bytes) in breakdown:
      check (what & " " & $bytes) in diags[0].message

    # Errors carry the breakdown too.
    let over = checkSize("x".repeat(150_000), target, breakdown)
    check over[0].rules == @["R-SIZE-01", "R-SIZE-02"]
    check "head CSS 12000" in over[0].message

  test "a render computes the contributor breakdown":
    # rule: R-SIZE-02
    let res = renderEmail(sizedTpl, 0)
    let html = res.html
    var keys: seq[string] = @[]
    var total = 0
    for (k, v) in res.sizeBreakdown:
      keys.add(k)
      total += v
    check keys == @["head CSS", "inline styles", "URLs",
      "preheader padding", "MSO/VML", "markup and text"]
    check total == res.htmlBytes
    # Re-derived independently from the finished bytes.
    var mso = 0
    for (a, b) in msoRegions(html):
      mso += b - a
    mso += html.count("<!--[if !mso]><!-->") * "<!--[if !mso]><!-->".len
    mso += html.count("<!--<![endif]-->") * "<!--<![endif]-->".len
    let rest = outsideMso(html)
    let headCss = spans(rest, "<style>", "</style>", inner = false)
    let inline = spans(rest, " style=\"", "\"", inner = false)
    let urls = spans(rest, " href=\"", "\"", inner = true) +
      spans(rest, " src=\"", "\"", inner = true)
    let padding = defaultTarget().preheaderPad.repeat(
      preheaderPaddingUnits("Your account is ready.")).len
    check res.sizeBreakdown.entry("MSO/VML") == mso
    check res.sizeBreakdown.entry("head CSS") == headCss
    check res.sizeBreakdown.entry("inline styles") == inline
    check res.sizeBreakdown.entry("URLs") == urls
    check res.sizeBreakdown.entry("preheader padding") == padding
    check res.sizeBreakdown.entry("markup and text") ==
      res.htmlBytes - mso - headCss - inline - urls - padding
    # Every contributor this story has is non-zero, and the tracking
    # parameters count toward URLs.
    for (k, v) in res.sizeBreakdown:
      check v > 0
    check urls >= ("https://cdn.example.com/hero.png?utm_source=news" &
      "&amp;utm_medium=email").len + "https://app.example.com/?utm_campaign=x".len

  test "an over-budget render reports the computed breakdown":
    # rule: R-SIZE-01
    # rule: R-SIZE-02
    var target = defaultTarget()
    target.sizeBudget = 1_000
    let res = renderEmail(sizedTpl, 0, target = target)
    var diag: EmailDiagnostic
    var found = 0
    for d in res.diagnostics:
      if d.code == codeSizeNearClip:
        diag = d
        inc found
    check found == 1
    check diag.rules == @["R-SIZE-01", "R-SIZE-02"]
    check $res.htmlBytes in diag.message
    for (k, v) in res.sizeBreakdown:
      check (k & " " & $v) in diag.message
