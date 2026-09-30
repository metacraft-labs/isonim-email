# rule: R-MIME-08
# rule: R-MIME-10
## Header round trip against an independent decoder: Python's standard
## `email` package (tests/oracles/mime_header_oracle.py, run by the dev
## shell's python3).
##
## 2,400 deterministic, seeded display names and subjects — `=`, `_`,
## `?`, specials, tabs, edge whitespace, non-ASCII (2-, 3- and 4-byte
## UTF-8), encoded-word look-alikes (`=?UTF-8?Q?…?=`, `=5F`, `?=`),
## and a few folding-length and 1,200-character values — each become a
## message through `toMessage` + `toRfc5322`. Python must decode every
## Subject back to the exact input through both its modern parser and
## the legacy `email.header.decode_header`; every encoded display name
## through `decode_header`; and every display name the modern address
## parser does not normalise (see the note in the loop) through that
## parser too. It must record no parser defects and see no header line
## over 998 characters. Names without control characters also ride as
## an attachment filename, which `get_filename()` must return unchanged
## (quoted-pair escaping and RFC 2231 continuations).
##
## The seed is fixed, so every run checks the same inputs; a failure
## prints the offending input, reproducible by index.
##
## C backend only: writes a temp file and runs python3. No mocks
## (allowed_mocks: None). A missing python3 fails loudly with the
## dev-shell hint instead of skipping.
import std/[base64, json, os, osproc, random, strutils, times, unittest]
import isonim_email

const
  testsDir = parentDir(currentSourcePath())
  oracle = testsDir / "oracles" / "mime_header_oracle.py"
  fuzzSeed = 20260930
  fuzzCount = 2400

const fixed = [
  # The reported corruption, and its neighbours.
  "Zoë_Smith", "Zoë=Smith", "Zoë_=_Smith", "a_b", "a=b", "_", "=", "?",
  "=?", "?=", "=?UTF-8?Q?Zo=C3=AB?=", "=?utf-8?b?Wm/Dqw==?=",
  "Admin =?UTF-8?Q?x?= team", "=5F", "=3D=5F", "_=?x?q?a_b?=_",
  "Ada  Lovelace", " lead", "trail ", "\ttab", "a\tb", "O'Brien",
  "Doe, Jane", "say \"hi\"", "back\\slash", "(comment)", "<angle>",
  "a@b", "[x]", "semi;colon", "colon:", "dot.", "日本語", "🙂 smile",
  "Ω=Ω_Ω?Ω", "ж" & "_".repeat(30), "é".repeat(40),
]

const
  asciiPool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  specialPool = "=_? \"\\(),.:;<>@[]!*+-/'#%&~^`{|}$"
  lookAlikes = ["=?", "?=", "=?UTF-8?Q?", "=?utf-8?B?", "?Q?", "=5F",
    "=3D", "=?x?q?a_b?=", "_=?", "=?=", "?Q?_?="]
  nonAscii = ["é", "ë", "ß", "Ω", "ж", "中", "文", "🙂", "\u00A0",
    "\u200B", "Ä", "ø", "ł", "ğ", "€"]

proc genName(r: var Rand): string =
  ## One seeded name: mostly short, sometimes fold-length, rarely huge.
  let roll = r.rand(999)
  let target =
    if roll < 5: 1150 + r.rand(100)
    elif roll < 100: 60 + r.rand(140)
    else: 1 + r.rand(29)
  while result.len < target:
    let pick = r.rand(99)
    if pick < 40:
      result.add(asciiPool[r.rand(asciiPool.high)])
    elif pick < 65:
      result.add(specialPool[r.rand(specialPool.high)])
    elif pick < 80:
      result.add(nonAscii[r.rand(nonAscii.high)])
    elif pick < 92:
      result.add(lookAlikes[r.rand(lookAlikes.high)])
    elif pick < 97:
      result.add(' ')
    else:
      result.add('\t')

proc hasControl(s: string): bool =
  for c in s:
    if c.byte < 32 or c.byte == 127:
      return true
  false

suite "header round trip against Python's email package":
  test "2,400 seeded names and subjects decode back exactly":
    let python = findExe("python3")
    doAssert python.len > 0,
      "python3 not found: run the suite inside the dev shell " &
      "(nix develop -c just test)"
    var r = initRand(fuzzSeed)
    var names: seq[string] = @[]
    for n in fixed:
      names.add(n)
    while names.len < fuzzCount:
      let n = genName(r)
      if n.len > 0:
        names.add(n)
    check names.len == fuzzCount
    # The corpus really carries what it claims to.
    var withEq, withUnderscore, withQ, withUtf8, withLookAlike = 0
    for n in names:
      if '=' in n: inc withEq
      if '_' in n: inc withUnderscore
      if '?' in n: inc withQ
      if "=?" in n: inc withLookAlike
      for c in n:
        if c.byte > 127:
          inc withUtf8
          break
    check withEq > 500 and withUnderscore > 500 and withQ > 500
    check withUtf8 > 500 and withLookAlike > 200

    var blobs = newJArray()
    for i, n in names:
      let atts =
        if hasControl(n): @[]
        else: @[Attachment(filename: n & ".txt", mime: "text/plain",
          bytes: "x")]
      let msg = toMessage(RenderedEmail(html: "<p>x</p>", text: "x"),
        MessageHeaders(
          fromAddr: mailbox(n, "a@example.com"),
          to: @[mailbox(n, "b@example.com")],
          subject: n,
          date: fromUnix(1767268800)),
        attachments = atts)
      blobs.add(%base64.encode(toRfc5322(msg, "fz" & $i)))

    let work = getTempDir() / ("isonim-email-header-fuzz-" & $getCurrentProcessId())
    createDir(work)
    try:
      let inPath = work / "in.json"
      let outPath = work / "out.json"
      writeFile(inPath, $blobs)
      let (output, code) = execCmdEx(quoteShellCommand(
        [python, oracle, inPath, outPath]))
      doAssert code == 0, "oracle failed:\n" & output
      let results = parseFile(outPath)
      check results.len == names.len
      var failures: seq[string] = @[]
      var legacyChecked, modernChecked, fileChecked = 0
      for i, n in names:
        let res = results[i]
        var problems: seq[string] = @[]
        for field in ["subject", "subject_legacy"]:
          if res[field].getStr() != n:
            problems.add(field & "=" & res[field].getStr().escape())
        let phrase = formatMailbox(mailbox(n, "a@example.com"))
        let encodedWords = phrase.count("=?UTF-8?")
        if encodedWords > 0:
          # An encoded phrase: `email.header.decode_header` is the
          # RFC 2047 oracle for every one of them.
          inc legacyChecked
          if res["from_phrase_legacy"].getStr() != n:
            problems.add("from_phrase_legacy=" &
              res["from_phrase_legacy"].getStr().escape())
        # Python counts NBSP as whitespace too.
        let collapsible = '\t' in n or
          "  " in n.replace("\u00A0", " ")
        if encodedWords > 1 or (encodedWords == 1 and collapsible):
          # The modern address parser normalises decoded phrases where
          # RFC 2047 does not: it inserts a SPACE between adjacent
          # encoded-words (§6.2 says to drop that whitespace, as the
          # legacy decoder above and the Subject path do), and it turns
          # a TAB into a SPACE and collapses whitespace runs inside a
          # decoded word. Those phrases are judged by the legacy decoder
          # alone; every other name must also match the modern parser.
          discard
        else:
          inc modernChecked
          for field in ["from_name", "to_name"]:
            if res[field].getStr() != n:
              problems.add(field & "=" & res[field].getStr().escape())
        # `get_filename()` strips edge whitespace (NBSP included) from
        # whatever it decodes, so a name's leading whitespace cannot
        # come back through Python; the rest must, byte for byte.
        var wantFile = n & ".txt"
        while wantFile.startsWith(" ") or wantFile.startsWith("\u00A0"):
          wantFile = wantFile[(if wantFile[0] == ' ': 1 else: 2) .. ^1]
        if not hasControl(n):
          inc fileChecked
          if res["filename"].getStr() != wantFile:
            problems.add("filename=" & $res["filename"])
        if res["max_header_line"].getInt() > maxHeaderLine:
          problems.add("max_header_line=" & $res["max_header_line"])
        if res["defects"].len > 0:
          problems.add("defects=" & $res["defects"])
        if problems.len > 0:
          failures.add("#" & $i & " " & n.escape() & ": " &
            problems.join(", "))
      if failures.len > 0:
        echo "first failures (of ", failures.len, "):"
        for f in failures[0 ..< min(10, failures.len)]:
          echo "  ", f
      check failures.len == 0
      # Each oracle judged a substantial share of the corpus.
      check legacyChecked > 1000
      check modernChecked > 1000
      check fileChecked > 1500
    finally:
      removeDir(work)
