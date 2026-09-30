# rule: R-MIME-08
# rule: R-MIME-10
## Header encoding and folding, pinned against the RFC texts:
## - RFC 2047 Q-encoding never leaves `=` or `_` literal (in a phrase
##   or in unstructured text): `_` decodes to SPACE and `=` opens an
##   escape, so a literal one corrupts the decoded name;
## - no header line exceeds 998 characters (RFC 5322 §2.1.1): Subject
##   and display names fall back to encoded-words, other headers to a
##   hard split;
## - folding inserts CRLF only before existing whitespace, so unfolding
##   restores the value byte for byte (runs of spaces, tabs);
## - ASCII that looks like an encoded-word (`=?…?=`) is encoded, never
##   left for a decoder to "decode";
## - filenames are escaped (quoted-pair or RFC 2231), never raw.
##
## The decoder below is test-local: it reads encoded-words the way
## RFC 2047 §6 describes, independently of the encoder. The same
## properties are fuzzed against Python's `email` package in
## tests/t6_header_fuzz.nim.
##
## Backend-independent (pure string code), so `just test` also runs it
## on JS.
import std/[base64, strutils, unittest]
import isonim_email

proc unfold(s: string): string =
  ## RFC 5322 §2.2.3 unfolding: remove every CRLF that precedes WSP.
  s.replace("\r\n ", " ").replace("\r\n\t", "\t")

proc qDecode(t: string): string =
  var i = 0
  while i < t.len:
    if t[i] == '_':
      result.add(' ')
      inc i
    elif t[i] == '=' and i + 2 < t.len:
      result.add(char(parseHexInt(t[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(t[i])
      inc i

proc decodeWord(w: string): tuple[ok: bool; text: string] =
  ## One `=?charset?enc?text?=` word, or not-a-word.
  if not (w.startsWith("=?") and w.endsWith("?=")):
    return (false, "")
  let inner = w[2 ..< w.len - 2]
  let parts = inner.split('?')
  if parts.len != 3:
    return (false, "")
  case parts[1].toUpperAscii()
  of "Q": (true, qDecode(parts[2]))
  of "B": (true, base64.decode(parts[2]))
  else: (false, "")

proc decodeHeaderText(value: string): string =
  ## RFC 2047 §6.2: encoded-words decode; linear whitespace between two
  ## adjacent encoded-words is dropped; everything else is kept.
  let s = unfold(value)
  var i = 0
  var lastWasWord = false
  var pendingWs = ""
  while i < s.len:
    if s[i] in {' ', '\t'}:
      pendingWs.add(s[i])
      inc i
      continue
    var j = i
    while j < s.len and s[j] notin {' ', '\t'}:
      inc j
    let tok = s[i ..< j]
    let dw = decodeWord(tok)
    if dw.ok:
      if not lastWasWord:
        result.add(pendingWs)
      result.add(dw.text)
    else:
      result.add(pendingWs)
      result.add(tok)
    pendingWs = ""
    lastWasWord = dw.ok
    i = j
  result.add(pendingWs)

proc headerLines(folded: string): seq[string] =
  folded.split("\r\n")

proc maxLine(folded: string): int =
  for l in headerLines(folded):
    result = max(result, l.len)

proc qWords(s: string): seq[string] =
  ## The Q-encoded words in `s`, framing stripped.
  var at = 0
  while true:
    let a = s.find("?Q?", at)
    if a < 0:
      break
    let b = s.find("?=", a + 3)
    result.add(s[a + 3 ..< b])
    at = b + 2

proc valueOf(folded, name: string): string =
  ## The unfolded value: what follows `Name: ` (the separator space
  ## after the colon is not part of the value).
  let u = unfold(folded)
  doAssert u.startsWith(name & ": "), u
  u[name.len + 2 .. ^1]

proc subjectOf(subject: string): string =
  foldHeader("Subject", encodeHeaderText(subject))

suite "header encoding and folding":
  test "q-encoded phrases never carry a literal = or _":
    # rule: R-MIME-10
    for name in ["Zoë_Smith", "Zoë=Smith", "Zoë_=_Smith", "ü_", "=ü",
        "a_b_c ü", "x=?y ü", "Ünder_score and=equals"]:
      let formatted = formatMailbox(mailbox(name, "z@example.com"))
      let phrase = formatted[0 ..< formatted.rfind(" <")]
      if "?Q?" in phrase:
        # Every `=` opens a `=XX` escape, and every literal `_` stands
        # for a SPACE of the name — so there is no literal `=` or `_`.
        var underscores = 0
        for w in qWords(phrase):
          underscores += w.count('_')
          var i = 0
          while i < w.len:
            if w[i] == '=':
              check i + 2 < w.len
              check w[i + 1] in HexDigits and w[i + 2] in HexDigits
              i += 3
            else:
              inc i
        check underscores == name.count(' ')
      check decodeHeaderText(phrase) == name
    # The exact bytes for the reported case: `_` is `=5F`, not literal.
    check encodeHeaderText("Zoë_Smith", phrase = true) ==
      "=?UTF-8?Q?Zo=C3=AB=5FSmith?="
    check encodeHeaderText("Zoë=Smith", phrase = true) ==
      "=?UTF-8?Q?Zo=C3=AB=3DSmith?="
    # Unstructured text (Subject) excludes them as well.
    check encodeHeaderText("Zoë_Smith = ok") ==
      "=?UTF-8?Q?Zo=C3=AB=5FSmith_=3D_ok?="

  test "a q-encoded phrase keeps only letters, digits and !*+-/":
    # rule: R-MIME-10
    let all = "é" & " !\"#$%&'()*+,-./0123456789:;<=>?@AZ[\\]^_`az{|}~"
    let word = encodeHeaderText(all, phrase = true)
    check word.startsWith("=?UTF-8?Q?")
    for w in qWords(word):
      var i = 0
      while i < w.len:
        if w[i] == '=':
          check w[i + 1] in HexDigits and w[i + 2] in HexDigits
          i += 3
        else:
          check w[i].isAlphaNumeric() or w[i] in {'!', '*', '+', '-', '/',
            '_'}
          inc i
    check decodeHeaderText(word) == all

  test "no header line exceeds 998 characters":
    # rule: R-MIME-08
    # A 1,200-character unbroken subject: encoded-words, each line ≤ 76.
    let long = "x".repeat(1200)
    let subj = subjectOf(long)
    check maxLine(subj) <= encodedWordLineLimit
    check decodeHeaderText(valueOf(subj, "Subject")) == long
    # Mixed: words, then one unbroken 1,200-character token.
    let mixed = "Your report: " & "abcdefghij".repeat(120) & " is ready"
    let mixedSubj = subjectOf(mixed)
    check maxLine(mixedSubj) <= encodedWordLineLimit
    check decodeHeaderText(valueOf(mixedSubj, "Subject")) == mixed
    # A 1,200-character display name: encoded, decodes back.
    let name = "N".repeat(1200)
    let fromHeader = foldHeader("From", formatMailbox(mailbox(name,
      "a@example.com")))
    check maxLine(fromHeader) <= encodedWordLineLimit
    let unfolded = valueOf(fromHeader, "From")
    check unfolded.endsWith(" <a@example.com>")
    check decodeHeaderText(unfolded[0 ..< unfolded.rfind(" <")]) == name
    # A header nothing can encode: hard-split, every line ≤ 998.
    let raw = foldHeader("X-Trace", "t".repeat(2500))
    check maxLine(raw) <= maxHeaderLine
    check headerLines(raw).len == 3
    check headerLines(raw)[0].len == maxHeaderLine
    # Undoing the split (not an RFC unfold: the split is lossy, which
    # is why encodable headers never take this path) gives the value.
    check raw.replace("\r\n ", "") == "X-Trace: " & "t".repeat(2500)
    # Many short words: ordinary folding, every line ≤ 78.
    var many: seq[string] = @[]
    for k in 0 ..< 300:
      many.add("word" & $k)
    let wordy = foldHeader("Subject", encodeHeaderText(many.join(" ")))
    check maxLine(wordy) <= headerFoldLimit
    check unfold(wordy) == "Subject: " & many.join(" ")

  test "folding preserves whitespace byte for byte":
    # rule: R-MIME-08
    # Runs of spaces survive, on one line and across folds.
    check subjectOf("a  b   c") == "Subject: a  b   c"
    var spaced = ""
    for k in 0 ..< 40:
      spaced.add("w" & $k & (if k mod 3 == 0: "   " else: " "))
    spaced = spaced.strip()
    let folded = subjectOf(spaced)
    check headerLines(folded).len > 1
    check maxLine(folded) <= headerFoldLimit
    check unfold(folded) == "Subject: " & spaced
    # No continuation line is whitespace only, and each one starts
    # with the whitespace it was folded before.
    for l in headerLines(folded)[1 .. ^1]:
      check l[0] == ' '
      check l.strip().len > 0
    # Tabs and edge whitespace cannot travel raw (parsers strip edges,
    # a tab is a control character): encoded, and every space and tab
    # comes back.
    for s in ["a\tb", " leading", "trailing ", "  both  "]:
      let enc = subjectOf(s)
      check "=?" in enc
      check decodeHeaderText(valueOf(enc, "Subject")) == s
    # Display names with a whitespace run are quoted, which keeps it.
    check formatMailbox(mailbox("Ada  Lovelace", "a@example.com")) ==
      "\"Ada  Lovelace\" <a@example.com>"
    check formatMailbox(mailbox("Ada Lovelace", "a@example.com")) ==
      "Ada Lovelace <a@example.com>"

  test "ascii that looks like an encoded-word is encoded":
    # rule: R-MIME-10
    for s in ["=?UTF-8?Q?hi?=", "see =?utf-8?b?aGk=?= here", "a=?b",
        "=?x"]:
      let enc = encodeHeaderText(s)
      check enc != s
      check decodeHeaderText(enc) == s
      # The look-alike never appears on the wire as a word of its own.
      if s.startsWith("=?UTF-8?Q?hi"):
        check "=?UTF-8?Q?hi?=" notin unfold(enc)
    let name = formatMailbox(mailbox("=?UTF-8?Q?Admin?=", "a@example.com"))
    check "=?UTF-8?Q?Admin?=" notin name
    check decodeHeaderText(name[0 ..< name.rfind(" <")]) ==
      "=?UTF-8?Q?Admin?="
    # Plain ASCII without the opener still travels as is.
    check encodeHeaderText("a ?= b") == "a ?= b"
    check encodeHeaderText("Welcome to Metacraft") == "Welcome to Metacraft"

  test "filenames are escaped, never raw":
    # Short printable ASCII: a quoted-string with quoted-pairs.
    check filenameParam("filename", "report.pdf") ==
      "; filename=\"report.pdf\""
    check filenameParam("filename", "a\"b\\c.txt") ==
      "; filename=\"a\\\"b\\\\c.txt\""
    # UTF-8: RFC 2231 extended value, percent-encoded.
    check filenameParam("filename", "résumé.pdf") ==
      "; filename*0*=UTF-8''r%C3%A9sum%C3%A9.pdf"
    # Control bytes can never reach the header raw.
    let cr = filenameParam("filename", "a\r\nBcc: x@evil.test")
    check '\r' notin cr and '\n' notin cr
    check "%0D%0A" in cr
    # A long name: RFC 2231 continuations of ≤ 40 characters, never
    # splitting a %XX, each on a foldable parameter boundary.
    let longName = "é".repeat(80) & ".txt"
    let p = filenameParam("filename", longName)
    check "filename*0*=UTF-8''" in p
    check "filename*1*=" in p
    for seg in p.split("; ")[1 .. ^1]:
      let v = seg[seg.find('=') + 1 .. ^1].replace("UTF-8''", "")
      check v.len <= rfc2231SegmentLen
      check not v.endsWith("%") and not (v.len >= 2 and v[^2] == '%')
    let folded = foldHeader("Content-Disposition", "attachment" & p)
    check maxLine(folded) <= headerFoldLimit
    # Serialised parts carry the escaped form.
    let part = serializePart(attachmentPart(Attachment(
      filename: "a\"b.txt", mime: "text/plain", bytes: "x")))
    check "Content-Disposition: attachment; filename=\"a\\\"b.txt\"" in part
    check "Content-Type: text/plain; name=\"a\\\"b.txt\"" in part
