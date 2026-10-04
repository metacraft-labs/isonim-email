## The render's hot paths, rewritten for speed, against the plain forms
## they replaced: the quoted-printable encoder's single buffered pass,
## the case-insensitive comparisons that read their argument in place,
## the per-thread answers of the pure value parsers (`style/memo.nim`)
## and what each is keyed on, the `var()` scan of the style pass, the
## two-spelling layout prop lookup, the serialiser's conditional count,
## and the spacer row kept per height. Each reference below is the
## plain form, so a fast path that drifts from it fails here even where
## no reference email exercises the input.
##
## Backend-independent (pure string work and tree building), so
## `just test` also runs it on JS.
import std/[random, sets, strutils, tables, unittest]
import isonim_email
import isonim_email/mime/encode
import isonim_email/style/ascii
import isonim_email/style/memo

# --- references ------------------------------------------------------------------

proc referenceQp(s: string): string =
  ## The encoder as it was written atom by atom: one `splitLines` line
  ## at a time, each byte a string of its own.
  proc hexByte(b: byte): string =
    const digits = "0123456789ABCDEF"
    "=" & digits[b shr 4] & digits[b and 0x0F]
  proc isLiteral(b: byte): bool =
    (b >= 33 and b <= 60) or (b >= 62 and b <= 126)
  if s.len == 0:
    return ""
  var lineBuf = ""
  for rawLine in s.splitLines():
    var line = rawLine
    if line.endsWith('\r'):
      line.setLen(line.len - 1)
    var trailStart = line.len
    while trailStart > 0 and line[trailStart - 1] in {' ', '\t'}:
      dec trailStart
    var i = 0
    while i < line.len:
      let b = line[i].byte
      var atom: string
      if i >= trailStart:
        atom = hexByte(b)
      elif b == '.'.byte and lineBuf.len == 0:
        atom = "=2E"
      elif isLiteral(b) or b == ' '.byte or b == '\t'.byte:
        atom = $line[i]
      else:
        atom = hexByte(b)
      let limit = if i == line.len - 1: 76 else: 75
      if lineBuf.len + atom.len > limit:
        result.add(lineBuf & "=\r\n")
        lineBuf.setLen(0)
        if atom == ".":
          atom = "=2E"
      lineBuf.add(atom)
      inc i
    result.add(lineBuf & "\r\n")
    lineBuf.setLen(0)

proc referenceVarRef(value: string): bool =
  "var(" in value.toLowerAscii().replace(" ", "").replace("\t", "")

proc referenceRawValue(node: EmailNode; name: string): string =
  let hy = name.replace("_", "-")
  let us = name.replace("-", "_")
  for key in [hy, us]:
    if key in node.styles:
      return node.styles[key].strip()
  for key in [us, hy]:
    if key in node.attrs:
      return node.attrs[key].strip()
  ""

proc randomText(r: var Rand; alphabet: string; maxLen: int): string =
  let n = r.rand(maxLen)
  for _ in 0 ..< n:
    result.add(alphabet[r.rand(alphabet.high)])

suite "render hot paths against their plain forms":
  test "test_qp_single_pass_matches_atom_by_atom_encoding":
    var cases = @["", "a", ".", "..", " ", "\t", "=", "\r", "\n", "\r\n",
      "a \r\nb\t\n", "\n\n", "\r\r\n", "x\ry", ".leading\n.dot",
      "trailing   ", "caf\xC3\xA9 \xE2\x80\x94 ok"]
    # Lines around the 76-column limit, with dots, `=`, and whitespace
    # at and after every wrap point.
    for n in 70 .. 82:
      for tail in [".", "=", " ", "\t", ".x", "=.", " .", "\xC3\xA9"]:
        cases.add("a".repeat(n) & tail)
        cases.add("a".repeat(n) & tail & "\nnext")
        cases.add(".".repeat(n) & tail)
    # One long line that expands three times over (every byte `=XX`),
    # which grows the output buffer more than once.
    cases.add("=".repeat(20_000))
    cases.add("<td style=\"a:b\">x</td>".repeat(2_000))
    var r = initRand(20261005)
    const alphabet = "aZ09 .\t=\r\n~!<>\"\xC3\xA9\x00\x7F"
    for _ in 0 ..< 3_000:
      cases.add(randomText(r, alphabet, 260))
    var wrapped = 0
    for c in cases:
      let got = encodeQuotedPrintable(c)
      check got == referenceQp(c)
      if "=\r\n" in got:
        inc wrapped
    # Not vacuous: many inputs soft-break.
    check wrapped > 100

  test "test_ascii_comparisons_match_lower_casing":
    var r = initRand(7)
    const alphabet = "aAzZmM-_09@:\xC3\x89\x80 "
    let words = ["", "a", "display", "font-size", "mso-", "mailsection",
      "td", "pre"]
    var hits = 0
    for _ in 0 ..< 3_000:
      var s = randomText(r, alphabet, 12)
      if r.rand(3) == 0:
        # A cased spelling of a word, so equal answers come up too.
        s = words[r.rand(words.high)]
        for i in 0 ..< s.len:
          if r.rand(1) == 0:
            s[i] = toUpperAscii(s[i])
      check hasUpperAscii(s) == (s.toLowerAscii() != s)
      for w in words:
        check eqLowerAscii(s, w) == (s.toLowerAscii() == w)
        if eqLowerAscii(s, w) and w.len > 0:
          inc hits
      check inLowerAscii(s, words) == (s.toLowerAscii() in words)
    check hits > 100

  test "test_case_insensitive_slugs_read_their_input_in_place":
    for (prop, slug) in [("border-radius", "css-border-radius"),
        ("Border-Radius", "css-border-radius"), ("PADDING", "css-padding"),
        ("color", "")]:
      check propertySlug(prop) == slug
    check elementSlug("VIDEO") == "html-video"
    check elementSlug("Img") == "html-img"
    check attributeSlug("ALIGN") == "html-align"
    check atRuleSlug("Font-Face") == "css-at-font-face"
    check valueSlug("DISPLAY", " Flex ") == "css-display-flex"
    check valueSlug("display", "inline-GRID") == "css-display-grid"
    check valueSlug("width", "flex") == ""
    check isLayoutContainer("MailSection")
    check not isLayoutContainer("span")
    check isHarmfulDeclaration("Display", "flex !important")
    check not isHarmfulDeclaration("displays", "flex")
    # A variant key: the harmful check is for inline declarations only;
    # an upper-case property is the same property.
    proc codes(styles: openArray[(string, string)]): seq[string] =
      for d in lintStyles("div", styles, consumer, [], SourceSpan()):
        result.add(d.code)
    check codes([("DISPLAY", "flex")]) == codes([("display", "flex")])
    check codes([("display", "flex")]).len == 1
    check codes([("@dark:display", "flex")]) != codes([("display", "flex")])
    check codes([("@:display", "flex")]) == codes([("display", "flex")])

  test "test_memoised_keeps_answers_and_never_an_error":
    var memo: Table[string, int]
    var computed = 0
    proc answer(s: string): int =
      inc computed
      if s == "bad":
        raise newException(ValueError, "bad input")
      s.len
    check memoised(memo, 4, "abc", answer("abc")) == 3
    check memoised(memo, 4, "abc", answer("abc")) == 3
    check computed == 1
    for i in 0 ..< 2:
      expect ValueError:
        discard memoised(memo, 4, "bad", answer("bad"))
    check computed == 3
    check "bad" notin memo
    # A full table is emptied, never served stale.
    for k in ["a", "bb", "ccc", "dddd", "eeeee", "ffffff"]:
      check memoised(memo, 4, k, answer(k)) == k.len
      check memo.len <= 4
    check memoised(memo, 4, "abc", answer("abc")) == 3

  test "test_value_parsers_keep_answers_per_what_they_read":
    for round in 0 .. 1:
      # A percentage is a width's value and another property's error,
      # in either order.
      if round == 0:
        check normaliseLength("width", "50%") == "50%"
      expect StyleError:
        discard normaliseLength("padding", "50%")
      check normaliseLength("max-width", "12.50%") == "12.5%"
      expect StyleError:
        discard normaliseLength("padding", "12.50%")
      # The font size an `em` or a multiplier reads.
      check toPx("2em", 10.0) == 20.0
      check toPx("2em") == 32.0
      check toPx("2em", 10.0) == 20.0
      check normaliseLength("padding", "2em", 10.0) == "20px"
      check normaliseLength("padding", "2em") == "32px"
      check normaliseLineHeight("1.5", 16.0) == "24px"
      check normaliseLineHeight("1.5", 20.0) == "30px"
      check normaliseLineHeight("150%", 20.0) == "30px"
      check normaliseLineHeight("24px", 20.0) == "24px"
      # Colours: the same value twice, an error twice.
      check normaliseColor("#ABC") == "#aabbcc"
      check parseColor("rgba(0, 0, 0, 0.5)").a == 0.5
      for i in 0 .. 1:
        expect StyleError:
          discard parseColor("var(--x)")
      check expandBox("4px 8px") == ["4px", "8px", "4px", "8px"]
      check expandBox("4px") == ["4px", "4px", "4px", "4px"]
      check parseTypeSpec("16/24/700").weight == "700"
      check parseTypeSpec("16/24").weight == ""
      check endsGeneric("Inter, sans-serif")
      check not endsGeneric("Inter")
    # Inversion reads the three channels, not the alpha.
    let a = invertLightness(Rgba(r: 10, g: 20, b: 30, a: 1.0))
    let b = invertLightness(Rgba(r: 10, g: 20, b: 200, a: 1.0))
    check a != b
    check invertLightness(Rgba(r: 10, g: 20, b: 30, a: 0.5)) == a
    check invertLightness(Rgba(r: 10, g: 20, b: 200, a: 1.0)) == b
    check invertLightness(Rgba(r: 255, g: 255, b: 255, a: 1.0)).r < 40

  test "test_var_scan_matches_the_spaceless_lower_cased_search":
    # Through the style pass: a value with a custom property reference
    # is an error on any property.
    proc flagged(value: string): bool =
      let r = EmailRenderer()
      let n = r.createElement("div")
      n.styles["x-test"] = value
      for d in applyStyles(n, defaultTheme(), defaultTarget()).diagnostics:
        if "custom property reference" in d.message:
          return true
      false
    var r = initRand(11)
    var cases = @["var(--a)", "VAR (--a)", "v a r(", "vvar(", "varvar(",
      "va r\t(", "var", "(var", "rav(", "va(r(", "vavar(", "vavar ("]
    # `var(` mangled: letters cased at random, spaces and tabs put
    # anywhere, a letter now and then replaced or dropped.
    for _ in 0 ..< 600:
      var c = ""
      for ch in "xvar(--y)":
        let roll = r.rand(9)
        if roll == 0:
          continue
        if roll == 1:
          c.add("vVaArR(x"[r.rand(7)])
        elif roll == 2:
          c.add(toUpperAscii(ch))
        else:
          c.add(ch)
        if r.rand(3) == 0:
          c.add([" ", "\t", "  "][r.rand(2)])
      cases.add(c)
    var positives = 0
    for c in cases:
      if c.startsWith("tok:"):
        continue
      check flagged(c) == referenceVarRef(c)
      if referenceVarRef(c):
        inc positives
    check positives > 100
    check cases.len - positives > 100

  test "test_layout_prop_lookup_reads_both_spellings_in_order":
    let r = EmailRenderer()
    let names = ["row_gap", "row-gap", "rowgap", "a-b_c"]
    let keys = ["row_gap", "row-gap", "rowgap", "a-b-c", "a_b_c", "a-b_c"]
    var seen = initHashSet[string]()
    # Every key as a style, an attribute, both or neither.
    for mask in 0 ..< (1 shl (2 * keys.len)):
      let n = r.createElement("mailCluster")
      for i, k in keys:
        if (mask shr i and 1) == 1:
          n.styles[k] = " s-" & k & " "
        if (mask shr (i + keys.len) and 1) == 1:
          n.attrs[k] = " a-" & k & " "
      for name in names:
        check rawValue(n, name) == referenceRawValue(n, name)
        seen.incl(rawValue(n, name))
    # Not vacuous: "" and each of the ten style and attribute keys a
    # name's two spellings reach answer some lookup (`a-b_c` itself is
    # neither spelling of any name).
    check seen.len == 11

  test "test_conditional_count_finds_every_marker":
    let r = EmailRenderer()
    proc doc(payload: string): EmailNode =
      result = r.createElement("div")
      r.appendChild(result, raw(payload))
    check serialize(doc("<!--[if mso]>x<![endif]-->")).len > 0
    check serialize(doc("<<!--[if mso]><<![endif]-->")).len > 0
    for unbalanced in ["<!--[if mso]>", "<![endif]-->",
        "<!--[if mso]><![endif]--><![endif]-->", "<<!--[if x]>"]:
      expect EmailRenderError:
        discard serialize(doc(unbalanced))

  test "test_spacer_row_kept_per_height":
    for round in 0 .. 1:
      let eight = serialize(spacerRow(8))
      let sixteen = serialize(spacerRow(16))
      check "height=\"8\"" in eight and "height:8px;" in eight
      check "height=\"16\"" in sixteen and "height:16px;" in sixteen
      check eight.replace("8", "16") == sixteen

  test "test_style_keys_are_split_and_lower_cased_as_written":
    # A key is a variant only with a non-empty variant before its `:`;
    # `@:color` stays an inline key, `COLOR` is `color`, and a token
    # value resolves in place.
    let r = EmailRenderer()
    let n = r.createElement("span")
    n.styles["@:color"] = "red"
    n.styles["COLOR"] = "#ABCDEF"
    n.styles["Background-Color"] = "tok:color.surface.card"
    let res = applyStyles(n, defaultTheme(), defaultTarget())
    for d in res.diagnostics:
      check "variant" notin d.message
    check n.styles.getOrDefault("@:color", "") == "red"
    check n.styles.getOrDefault("color", "") == "#abcdef"
    check "COLOR" notin n.styles
    check n.styles.getOrDefault("background-color", "") ==
      normaliseColor(defaultTheme().lightFor("color.surface.card"))
    check res.head.len == 0
