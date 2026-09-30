# rule: R-SIZE-01
# rule: R-SIZE-02
## The size budget (P10). Decoded HTML at or under
## `EmailTarget.sizeBudget` (90,000) is silent; above it warns,
## and above 100,000 errors — Gmail clips at ~102 KB. Diagnostics
## report the byte contributors so authors see what to cut.
##
## Backend-independent (pure string measure), so `just test` also runs
## it on JS.
import std/[strutils, unittest]
import isonim_email

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
