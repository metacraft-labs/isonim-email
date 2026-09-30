# rule: R-MIME-05
# rule: R-MIME-07
## The quoted-printable encoder follows RFC 2045 §6.7 on the RFC
## examples plus URL/CSS edge cases: `=` in href query strings,
## trailing space, leading dot, 998+ char lines.
##
## Backend-independent (pure string encoding), so `just test` also runs
## it on JS.
import std/[strutils, unittest]
import isonim_email

proc encodedLines(s: string): seq[string] =
  ## Output lines without their CRLF terminators.
  result = @[]
  for chunk in s.split("\r\n"):
    result.add(chunk)
  # A well-formed encoding ends with CRLF, leaving one empty tail.
  doAssert result.len > 0 and result[^1] == ""
  result.setLen(result.len - 1)

suite "quoted-printable encoder":
  test "test_qp_encoder_rfc2045_examples":
    # rule: R-MIME-05
    # rule: R-MIME-07

    # RFC 2045 §6.7 rule 1 examples: 12 (form feed) is `=0C`, 61 (`=`)
    # is `=3D`, with uppercase hex.
    check encodeQuotedPrintable("a=b\x0Cc") == "a=3Db=0Cc\r\n"
    check encodeQuotedPrintable("\xAB") == "=AB\r\n"

    # RFC 2045 §6.7 soft-break example input. The RFC shows one legal
    # wrapping ("This can be represented, in the Quoted-Printable
    # encoding, as"); the normative rules are ≤ 76 chars and `=` soft
    # breaks. The sentence is 64 chars, so it encodes unwrapped.
    let sentence = "Now's the time for all folk to come to the aid of " &
      "their country."
    check sentence.len == 64
    check encodeQuotedPrintable(sentence) == sentence & "\r\n"

    # A line over 76 chars soft-breaks with `=` at end of line; every
    # output line stays ≤ 76 (rule 5).
    let longLine = "word ".repeat(20).strip()
    let wrapped = encodeQuotedPrintable(longLine)
    let lines = encodedLines(wrapped)
    check lines.len > 1
    for ln in lines:
      check ln.len <= 76
    for ln in lines[0 ..< ^1]:
      check ln.endsWith('=')
    # Rejoining the soft breaks restores the input (mini-decode).
    check wrapped.replace("=\r\n", "").replace("\r\n", "") == longLine

    # URL edge: every `=` in an href query string is `=3D`, or a QP
    # decoder would read `=20`-style escapes out of the URL.
    # Falsifying mutation: leaving `=` unencoded fails this check.
    let href = "<a href=\"https://x.test/u?a=b&c=d\">x</a>"
    let hrefEnc = encodeQuotedPrintable(href)
    check hrefEnc == href.replace("=", "=3D") & "\r\n"
    check hrefEnc.count("=3D") == 3 # href= plus the two query pairs

    # CSS edge: `=` inside a style attribute is encoded the same way.
    check encodeQuotedPrintable("<div style=\"a=b\">t</div>") ==
      "<div style=3D\"a=3Db\">t</div>\r\n"

    # Trailing whitespace is encoded (rule 3): space and tab.
    check encodeQuotedPrintable("hello \nworld") ==
      "hello=20\r\nworld\r\n"
    check encodeQuotedPrintable("a\t\nb") == "a=09\r\nb\r\n"
    # Mid-line whitespace stays literal.
    check encodeQuotedPrintable("a b\tc") == "a b\tc\r\n"

    # Leading-dot guard (R-MIME-07): a line never starts with `.`.
    check encodeQuotedPrintable(".class{color:red}") ==
      "=2Eclass{color:red}\r\n"
    check encodeQuotedPrintable("a\n.b") == "a\r\n=2Eb\r\n"

    # 998+ char lines (RFC 5322 §2.1.1 MUST): the encoder must remove
    # the whole class, so every output line is ≤ 76.
    let huge = "x".repeat(1200)
    let hugeEnc = encodeQuotedPrintable(huge)
    check hugeEnc.len > 0
    for ln in encodedLines(hugeEnc):
      check ln.len <= 76
    check hugeEnc.replace("=\r\n", "").replace("\r\n", "") == huge

    # Non-ASCII bytes become uppercase `=XX` (rule 1).
    check encodeQuotedPrintable("caf\u00E9") == "caf=C3=A9\r\n"

    # Empty input encodes empty; blank lines become bare CRLFs.
    check encodeQuotedPrintable("") == ""
    check encodeQuotedPrintable("a\n\nb") == "a\r\n\r\nb\r\n"

    # Global invariants over every output above: CRLF endings, ≤ 76
    # chars, no leading dot, no trailing literal whitespace.
    for sample in [sentence, longLine, href, huge, "hello \nworld",
        ".class{color:red}", "caf\u00E9"]:
      let enc = encodeQuotedPrintable(sample)
      check enc.endsWith("\r\n")
      check "\n" notin enc.replace("\r\n", "")
      for ln in encodedLines(enc):
        check ln.len <= 76
        check not ln.startsWith('.')
        check not ln.endsWith(' ') and not ln.endsWith('\t')
