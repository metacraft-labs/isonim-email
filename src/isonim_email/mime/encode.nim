## isonim_email/mime/encode.nim — transfer and header encodings.
##
## Quoted-printable (RFC 2045 §6.7; R-MIME-05, R-MIME-07), base64
## (RFC 2045 §6.8; R-MIME-09), RFC 2047 encoded-words (R-MIME-10) and
## header folding (RFC 5322 §2.2.3; R-MIME-08, R-MIME-12).
## Backend-independent: pure string code, runs on C and JS.

import std/[base64, strutils]
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  qpLineLimit* = 76
    ## RFC 2045 §6.7 rule 5: encoded lines are no more than 76 chars.
  headerFoldLimit* = 78
    ## RFC 5322 §2.1.1: lines SHOULD be no more than 78 chars.
  encodedWordLineLimit* = 76
    ## RFC 2047 §2: a header line carrying encoded-words is limited to
    ## 76 chars (stricter than the §2.1.1 SHOULD).
  encodedWordLimit* = 75
    ## RFC 2047 §2: an encoded-word is at most 75 chars.
  crlf* = "\r\n"

const qpVerbatim = {'!' .. '<', '>' .. '~', ' ', '\t'}
  ## The bytes written as they are where they are literal: RFC 2045
  ## §6.7 rule 2's octets 33–60 and 62–126 (61, `=`, is excluded, so
  ## `=` is always `=3D`), and space and tab mid-line.

proc hexByte(b: byte): string =
  ## `=XX` with uppercase hex (RFC 2045 §6.7 rule 1 mandates uppercase).
  const digits = "0123456789ABCDEF"
  "=" & digits[b shr 4] & digits[b and 0x0F]

proc qpLineBound*(n: int): int =
  ## The longest quoted-printable encoding of one source line of `n`
  ## bytes, its CRLF included: every byte as `=XX`, and a soft break
  ## (`=` CRLF) only once an output line holds at least 73 characters,
  ## so at most one per 73 written.
  3 * n + 3 * (3 * n div 73) + 2

proc encodeQuotedPrintable*(s: string): string =
  ## Encodes text as quoted-printable (RFC 2045 §6.7; R-MIME-05,
  ## R-MIME-07). Input lines are split on LF, CRLF or a lone CR;
  ## every output line ends with CRLF, including the last.
  ## Output lines are ≤ 76 chars with `=` soft breaks; `=` is always
  ## `=3D`; trailing whitespace is `=20`/`=09`; a line never starts
  ## with `.` (emitted as `=2E`, the dot-stuffing guard).
  ##
  ## One pass writing into one buffer: each source line is a slice of
  ## `s` (the line breaks `splitLines` recognises), and each byte is
  ## written as itself or as `=XX` straight into the result, which is
  ## grown before each line to hold the longest encoding the line can
  ## have (`qpLineBound`) and cut to what was written at the end.
  const digits = "0123456789ABCDEF"
  if s.len == 0:
    return ""
  result = newStringUninit(s.len + s.len div 4 + 16)
  var o = 0
  template put(ch: char) =
    result[o] = ch
    inc o
  var first = 0
  while true:
    var last = first
    while last < s.len and s[last] notin {'\c', '\l'}:
      inc last
    let eol = last
    if last < s.len:
      if s[last] == '\l':
        inc last
      else:
        inc last
        if last < s.len and s[last] == '\l':
          inc last
    # Trailing SP/TAB must be encoded (rule 3); find the run so the
    # packer below only sees literal whitespace mid-line (where a soft
    # `=` may legally follow it).
    var trailStart = eol
    while trailStart > first and s[trailStart - 1] in {' ', '\t'}:
      dec trailStart
    let need = o + qpLineBound(eol - first)
    if need > result.len:
      result.setLen(max(need, 2 * result.len))
    var lineLen = 0
    var i = first
    while i < eol:
      # A run of bytes that are written as they are, with room left on
      # the line: a literal byte (rule 2, or whitespace mid-line) before
      # the trailing whitespace and before the line's final byte, not a
      # dot opening an output line, while the line stays within 75.
      # Copied in one go; every other byte takes the full rule below.
      var j = i
      if not (s[i] == '.' and lineLen == 0):
        let stop = min(min(trailStart, eol - 1), i + (qpLineLimit - 1 - lineLen))
        while j < stop and s[j] in qpVerbatim:
          inc j
      if j > i:
        let n = j - i
        when defined(js):
          for k in 0 ..< n:
            result[o + k] = s[i + k]
        else:
          copyMem(addr result[o], unsafeAddr s[i], n)
        o += n
        lineLen += n
        i = j
        continue
      let c = s[i]
      let b = c.byte
      # Literal: rule 2's octets and mid-line whitespace. Encoded:
      # trailing whitespace (=20/=09), a leading dot (R-MIME-07), `=`
      # and every other byte.
      var hex =
        if i >= trailStart: true
        elif c == '.' and lineLen == 0: true
        elif c in qpVerbatim: false
        else: true
      # A soft `=` counts toward the 76 (rule 5), so a line that
      # will break reserves one column; only the final byte of a
      # source line may use all 76.
      let limit =
        if i == eol - 1: qpLineLimit
        else: qpLineLimit - 1
      if lineLen + (if hex: 3 else: 1) > limit:
        put('=')
        put('\r')
        put('\n')
        lineLen = 0
        # A fresh line re-arms the dot guard: a literal `.` that lands
        # at a wrap point must still be `=2E`.
        if c == '.':
          hex = true
      if hex:
        put('=')
        put(digits[b shr 4])
        put(digits[b and 0x0F])
        lineLen += 3
      else:
        put(c)
        inc lineLen
      inc i
    put('\r')
    put('\n')
    if eol == last:
      break
    first = last
  result.setLen(o)

proc encodeBase64*(data: string): string =
  ## Base64 with 76-char CRLF-terminated lines (RFC 2045 §6.8;
  ## R-MIME-09). Empty input encodes to the empty string.
  if data.len == 0:
    return ""
  let raw = base64.encode(data)
  result = newStringOfCap(raw.len + raw.len div qpLineLimit * 2 + 2)
  var i = 0
  while i < raw.len:
    let chunkLen = min(qpLineLimit, raw.len - i)
    result.add(raw[i ..< i + chunkLen])
    result.add(crlf)
    i += chunkLen

proc utf8SeqLen(b: byte): int =
  ## Length of the UTF-8 sequence starting at byte `b`. Continuation
  ## bytes (no valid start here) count as 1 so scanning never stalls.
  if b < 0x80: 1
  elif b < 0xC0: 1
  elif b < 0xE0: 2
  elif b < 0xF0: 3
  elif b < 0xF8: 4
  else: 1

proc isQSafe(b: byte; phrase: bool): bool =
  ## Bytes a Q-encoding may leave literal. The Subject set (RFC 2047
  ## §4.2 rule 3) is printable ASCII except `=`, `?`, `_`; the phrase
  ## set (§5 rule 3) is letters, digits and `!*+-/` only. `=` and `_`
  ## are never literal in either: `=` introduces `=XX` and `_` decodes
  ## to SPACE (§4.2 rules 1-2), so a literal one would corrupt the
  ## decoded text. SPACE is never literal (it becomes `_`).
  if phrase:
    return (b >= 'a'.byte and b <= 'z'.byte) or
      (b >= 'A'.byte and b <= 'Z'.byte) or (b >= '0'.byte and b <= '9'.byte) or
      b in [0x21.byte, 0x2A, 0x2B, 0x2D, 0x2F]
  (b >= 33 and b <= 126) and b != '='.byte and b != '?'.byte and
    b != '_'.byte

proc qEncodeChar(dest: var string; text: string; at: int; phrase: bool) =
  ## Appends one source character (possibly multi-byte) Q-encoded.
  let b = text[at].byte
  if b == ' '.byte:
    dest.add('_')
  elif b < 0x80 and isQSafe(b, phrase):
    dest.add(text[at])
  else:
    let n = min(utf8SeqLen(b), text.len - at)
    for k in 0 ..< n:
      dest.add(hexByte(text[at + k].byte))

proc qEncodedLen(text: string; at: int; phrase: bool): int =
  ## Encoded length of the character at `at` (1 for literal/`_`, 3 per
  ## byte for `=XX`).
  let b = text[at].byte
  if b == ' '.byte:
    1
  elif b < 0x80 and isQSafe(b, phrase):
    1
  else:
    3 * min(utf8SeqLen(b), text.len - at)

proc chooseWordEncoding(text: string): char =
  ## RFC 2047 §4: Q when most characters are ASCII, else B.
  var ascii = 0
  var other = 0
  for c in text:
    if c.byte < 0x80:
      inc ascii
    else:
      inc other
  if other * 2 > ascii: 'B' else: 'Q'

proc isWsp(c: char): bool {.inline.} =
  c == ' ' or c == '\t'

proc longestFoldUnit*(text: string): int =
  ## The longest run folding can never break: a whitespace run plus the
  ## word after it (a fold goes only before whitespace, RFC 5322
  ## §2.2.3), or the first word.
  var i = 0
  while i < text.len:
    let start = i
    while i < text.len and isWsp(text[i]):
      inc i
    while i < text.len and not isWsp(text[i]):
      inc i
    result = max(result, i - start)

proc headerTextNeedsEncoding*(text: string): bool =
  ## True when header text cannot travel as plain ASCII without
  ## changing meaning (R-MIME-10):
  ## - any byte outside printable ASCII (control characters, TAB
  ##   included, and UTF-8);
  ## - anything a decoder could mistake for an encoded-word: `=?`
  ##   opens one (RFC 2047 §6.1 decodes any word shaped
  ##   `=?charset?X?text?=`), so a look-alike is encoded rather than
  ##   left for the reader to "decode";
  ## - leading or trailing whitespace, which parsers strip from an
  ##   unencoded value;
  ## - a word so long that folding cannot keep its line within the
  ##   78-column recommendation (RFC 5322 §2.1.1) — encoded-words split
  ##   it into ≤ 75-char pieces, which also keeps every line far under
  ##   the 998-character hard limit (RFC 5322 §2.1.1 MUST).
  if text.len == 0:
    return false
  for c in text:
    if c.byte < 32 or c.byte > 126:
      return true
  if "=?" in text:
    return true
  if isWsp(text[0]) or isWsp(text[^1]):
    return true
  longestFoldUnit(text) > headerFoldLimit - 1

proc splitWordsB(text: string; charset: string): seq[string] =
  ## Splits raw text into B-encoded words of ≤ 75 chars. Each word
  ## carries an integral number of characters (RFC 2047 §5 forbids
  ## splitting a multi-octet character across words); with the
  ## `=?UTF-8?B?…?=` framing (12 chars) at most 60 base64 chars fit,
  ## i.e. 45 source bytes per word.
  let prefix = "=?" & charset & "?B?"
  let maxB64 = (encodedWordLimit - prefix.len - 2) div 4 * 4
  let maxBytes = maxB64 div 4 * 3
  var at = 0
  while at < text.len:
    var take = min(maxBytes, text.len - at)
    # Back off to a character boundary.
    while take > 0 and at + take < text.len and
        text[at + take].byte in 0x80.byte .. 0xBF.byte:
      dec take
    if take == 0:
      take = min(utf8SeqLen(text[at].byte), text.len - at)
    result.add(prefix & base64.encode(text[at ..< at + take]) & "?=")
    at += take

proc splitWordsQ(text: string; charset: string; phrase: bool): seq[string] =
  ## Splits raw text into Q-encoded words of ≤ 75 chars, breaking only
  ## at character boundaries with `=XX` kept whole (RFC 2047 §5).
  let prefix = "=?" & charset & "?Q?"
  let maxText = encodedWordLimit - prefix.len - 2
  var at = 0
  while at < text.len:
    var word = prefix
    var used = 0
    while at < text.len:
      let n = min(utf8SeqLen(text[at].byte), text.len - at)
      let cost = qEncodedLen(text, at, phrase)
      if used + cost > maxText:
        break
      qEncodeChar(word, text, at, phrase)
      used += cost
      at += n
    word.add("?=")
    result.add(word)

proc encodeHeaderText*(text: string; charset = "UTF-8"; phrase = false): string =
  ## Encodes header text with RFC 2047 encoded-words (R-MIME-10).
  ## Text that `headerTextNeedsEncoding` accepts passes through
  ## verbatim (whitespace runs included); otherwise the whole text is
  ## encoded — B or Q per RFC 2047 §4 (Q when mostly ASCII) — as
  ## ≤ 75-char words separated by CRLF SPACE, so every space survives
  ## inside the words and decoders drop only the separators. `phrase`
  ## selects the restricted Q set for display names (RFC 2047 §5
  ## rule 3).
  if not headerTextNeedsEncoding(text):
    return text
  let words =
    if chooseWordEncoding(text) == 'B':
      splitWordsB(text, charset)
    else:
      splitWordsQ(text, charset, phrase)
  words.join(crlf & " ")

const maxHeaderLine* = 998
  ## RFC 5322 §2.1.1: a line MUST NOT exceed 998 characters (CRLF
  ## excluded).

proc hardSplit(line: string; limit: int): string =
  ## Last resort for a line folding cannot shorten: CRLF SPACE every
  ## `limit - 1` characters, so no line exceeds `limit`. Unfolding
  ## leaves a SPACE at each split — which is why the encodable headers
  ## (Subject, display names) never get here: they fall back to
  ## encoded-words instead.
  result = line[0 ..< min(limit, line.len)]
  var at = min(limit, line.len)
  while at < line.len:
    let take = min(limit - 1, line.len - at)
    result.add(crlf & " " & line[at ..< at + take])
    at += take

proc foldHeader*(name, value: string): string =
  ## Folds one `Name: value` header (RFC 5322 §2.2.3; R-MIME-08).
  ## Lines are ≤ 78 chars where a fold point exists, or ≤ 76 when the
  ## value carries encoded-words (RFC 2047 §2). A fold is a CRLF
  ## inserted *before* existing whitespace, so unfolding (removing the
  ## CRLFs) restores the value byte for byte: whitespace runs, tabs and
  ## all. Existing CRLF WSP folds (as `encodeHeaderText` produces) are
  ## kept. A trailing whitespace run never becomes a line of its own.
  ## No line ever exceeds 998 characters: a word too long for that is
  ## hard-split as a last resort (`hardSplit`).
  let limit =
    if "=?" in value: encodedWordLineLimit
    else: headerFoldLimit
  # Units: a whitespace run plus the word after it; `forced` marks a
  # unit that followed an existing CRLF fold.
  var units: seq[string] = @[]
  var forced: seq[bool] = @[]
  var i = 0
  var pendingForced = false
  while i < value.len:
    if value[i] == '\r' and i + 2 < value.len and value[i + 1] == '\n' and
        isWsp(value[i + 2]):
      pendingForced = true
      i += 2
      continue
    let start = i
    while i < value.len and isWsp(value[i]):
      inc i
    while i < value.len and not isWsp(value[i]) and
        not (value[i] == '\r' and i + 1 < value.len and value[i + 1] == '\n'):
      inc i
    if i == start:
      # A lone CR/LF not starting a fold: keep it inside the unit
      # (callers reject header breaks before folding).
      inc i
    units.add(value[start ..< i])
    forced.add(pendingForced)
    pendingForced = false
  # A trailing whitespace-only unit rides on the unit before it.
  if units.len > 1 and units[^1].len > 0 and isWsp(units[^1][0]):
    var allWsp = true
    for c in units[^1]:
      if not isWsp(c):
        allWsp = false
    if allWsp:
      units[^2].add(units[^1])
      units.setLen(units.len - 1)
      forced.setLen(forced.len - 1)

  var lines: seq[string] = @[name & ":"]
  for u in 0 ..< units.len:
    # The first unit gains the conventional separator after the colon;
    # every later unit starts with whitespace by construction, so a
    # fold before any unit is a legal CRLF-before-WSP.
    let unit = if u == 0: " " & units[u] else: units[u]
    let foldable = isWsp(unit[0])
    # A unit longer than a whole line gains nothing from a fold right
    # after the colon; later units always fold (lossless), and the
    # hard split below takes care of what still exceeds 998.
    let overflow = lines[^1].len + unit.len > limit and
      (u > 0 or unit.len <= limit)
    if foldable and (forced[u] or overflow):
      lines.add(unit)
    else:
      lines[^1].add(unit)
  for k in 0 ..< lines.len:
    if lines[k].len > maxHeaderLine:
      lines[k] = hardSplit(lines[k], maxHeaderLine)
  lines.join(crlf)
