## isonim_email/mime/encode.nim — transfer and header encodings.
##
## Quoted-printable (RFC 2045 §6.7; R-MIME-05, R-MIME-07), base64
## (RFC 2045 §6.8; R-MIME-09), RFC 2047 encoded-words (R-MIME-10) and
## header folding (RFC 5322 §2.2.3; R-MIME-08, R-MIME-12).
## Backend-independent: pure string code, runs on C and JS.

import std/[base64, strutils]

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

proc isQpLiteral(b: byte): bool =
  ## RFC 2045 §6.7 rule 2: octets 33–60 and 62–126 may be literal.
  ## 61 (`=`) is excluded, so `=` is always `=3D`.
  (b >= 33 and b <= 60) or (b >= 62 and b <= 126)

proc hexByte(b: byte): string =
  ## `=XX` with uppercase hex (RFC 2045 §6.7 rule 1 mandates uppercase).
  const digits = "0123456789ABCDEF"
  "=" & digits[b shr 4] & digits[b and 0x0F]

proc encodeQuotedPrintable*(s: string): string =
  ## Encodes text as quoted-printable (RFC 2045 §6.7; R-MIME-05,
  ## R-MIME-07). Input lines are split on LF (a trailing CR per line is
  ## stripped); every output line ends with CRLF, including the last.
  ## Output lines are ≤ 76 chars with `=` soft breaks; `=` is always
  ## `=3D`; trailing whitespace is `=20`/`=09`; a line never starts
  ## with `.` (emitted as `=2E`, the dot-stuffing guard).
  if s.len == 0:
    return ""
  result = newStringOfCap(s.len + s.len div 40 + 16)
  var lineBuf = newStringOfCap(qpLineLimit + 4)

  proc flushLine(res: var string; buf: var string; soft: bool) =
    if soft:
      buf.add('=')
    res.add(buf)
    res.add(crlf)
    buf.setLen(0)

  for rawLine in s.splitLines():
    var line = rawLine
    # splitLines keeps \r on CRLF input; canonical form is CRLF out.
    if line.endsWith('\r'):
      line.setLen(line.len - 1)
    # Trailing SP/TAB must be encoded (rule 3); find the run so the
    # packer below only sees literal whitespace mid-line (where a soft
    # `=` may legally follow it).
    var trailStart = line.len
    while trailStart > 0 and line[trailStart - 1] in {' ', '\t'}:
      dec trailStart
    var i = 0
    while i < line.len:
      let b = line[i].byte
      var atom: string
      if i >= trailStart:
        atom = hexByte(b) # trailing whitespace: =20/=09
      elif b == '.'.byte and lineBuf.len == 0:
        atom = "=2E" # leading-dot guard (R-MIME-07)
      elif isQpLiteral(b):
        atom = $line[i]
      elif b == ' '.byte or b == '\t'.byte:
        atom = $line[i] # mid-line whitespace stays literal
      else:
        atom = hexByte(b) # `=` and bytes outside 33–60/62–126
      # A soft `=` counts toward the 76 (rule 5), so a line that
      # will break reserves one column; only the final line of a
      # source line may use all 76.
      let limit =
        if i == line.len - 1: qpLineLimit
        else: qpLineLimit - 1
      if lineBuf.len + atom.len > limit:
        flushLine(result, lineBuf, soft = true)
        # A fresh line re-arms the dot guard: a literal `.` that lands
        # at a wrap point must still be `=2E`.
        if atom == ".":
          atom = "=2E"
      lineBuf.add(atom)
      inc i
    flushLine(result, lineBuf, soft = false)

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
  ## set (§5 rule 3) is further restricted to letters, digits and
  ## `!*+-/=_`. SPACE is never literal (it becomes `_`).
  if phrase:
    return (b >= 'a'.byte and b <= 'z'.byte) or
      (b >= 'A'.byte and b <= 'Z'.byte) or (b >= '0'.byte and b <= '9'.byte) or
      b in [0x21.byte, 0x2A, 0x2B, 0x2D, 0x2F, 0x3D, 0x5F]
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

proc needsEncoding(text: string): bool =
  for c in text:
    if c.byte < 32 or c.byte > 126:
      return true
  false

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
  ## Pure-ASCII text passes through; otherwise B or Q is chosen per
  ## RFC 2047 §4 (Q when mostly ASCII) and long text becomes several
  ## ≤ 75-char words separated by CRLF SPACE. `phrase` selects the
  ## restricted Q set for display names (RFC 2047 §5 rule 3).
  if not needsEncoding(text):
    return text
  let words =
    if chooseWordEncoding(text) == 'B':
      splitWordsB(text, charset)
    else:
      splitWordsQ(text, charset, phrase)
  words.join(crlf & " ")

proc foldHeader*(name, value: string): string =
  ## Folds one `Name: value` header (RFC 5322 §2.2.3; R-MIME-08).
  ## Lines are ≤ 78 chars, or ≤ 76 when the value carries
  ## encoded-words (RFC 2047 §2). Existing CRLF SPACE folds (as
  ## produced by `encodeHeaderText`) are kept; further breaks go
  ## before spaces with a single-space continuation.
  let limit =
    if "=?" in value: encodedWordLineLimit
    else: headerFoldLimit
  # Split into words, remembering which separators were forced folds.
  var words: seq[string] = @[]
  var forced: seq[bool] = @[] # forced[i]: break before words[i]
  var cur = ""
  var i = 0
  var pendingForced = false
  while i < value.len:
    if value[i] == '\r' and i + 2 < value.len and value[i + 1] == '\n' and
        value[i + 2] in {' ', '\t'}:
      if cur.len > 0:
        words.add(cur)
        forced.add(pendingForced)
        cur = ""
      pendingForced = true
      i += 3
    elif value[i] in {' ', '\t'}:
      if cur.len > 0:
        words.add(cur)
        forced.add(pendingForced)
        cur = ""
        pendingForced = false
      while i < value.len and value[i] in {' ', '\t'}:
        inc i
    else:
      cur.add(value[i])
      inc i
  if cur.len > 0:
    words.add(cur)
    forced.add(pendingForced)
  if words.len == 0:
    return name & ":"

  proc curLineLen(s: string): int =
    let p = s.rfind(crlf)
    if p < 0: s.len
    else: s.len - p - crlf.len

  # Every word, including the first, may start a continuation line: a
  # 75-char encoded-word never fits beside `Subject: ` in 76 columns.
  result = name & ":"
  for w in 0 ..< words.len:
    if forced[w] or curLineLen(result) + 1 + words[w].len > limit:
      result.add(crlf & " " & words[w])
    else:
      result.add(" " & words[w])
