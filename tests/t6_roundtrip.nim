# rule: R-MIME-01
# rule: R-MIME-02
# rule: R-MIME-03
# rule: R-MIME-04
# rule: R-MIME-06
# rule: R-MIME-08
# rule: R-MIME-09
# rule: R-MIME-10
# rule: R-MIME-11
# rule: R-MIME-12
# rule: R-MIME-13
# rule: R-SND-03
# rule: R-SND-04
# rule: R-SND-06
## Message assembly + transports + the Mailpit round trip. A message
## with HTML + text + inline image + attachment is built by `toMessage`,
## sent to a real Mailpit spawned
## by the test, and comes back with identical parts; the raw view
## parses as the intended tree. The same file pins the assembly units
## (Date, Message-ID, flowed stuffing, boundaries), the R-SND-03
## one-click endpoint (the library's request check and response in a
## real HTTP server, POSTed to from a library-built message's headers),
## the R-SND-04 DKIM metadata, and the R-SND-06 doc. (The Mailgun
## transport is pinned by tests/t6_mailgun.nim.)
##
## C backend only: spawns Mailpit and a fixture HTTP server, reads the
## PNG fixture and docs/ off disk. No mocks anywhere (allowed_mocks:
## None); a missing mailpit binary fails loudly instead of skipping.
import std/[base64, httpclient, json, net, options, os, osproc,
  strutils, times, unittest]
from nim_everywhere/platform import nowUnixMillis, systemClock
import isonim_email

const testsDir = parentDir(currentSourcePath())

# ------------------------------------------------------- test oracles

type ParsedPart = ref object
  ## A raw message (or sub-part) parsed by splitting headers from body
  ## and walking multipart boundaries — the test's own reader, so the
  ## round trip is checked by different code than the assembly.
  headers: seq[(string, string)]
  body: string
  children: seq[ParsedPart]

proc parsedHeader(p: ParsedPart; name: string): string =
  for (n, v) in p.headers:
    if n.toLowerAscii() == name.toLowerAscii():
      return v
  ""

proc parseHeaders(head: string): seq[(string, string)] =
  result = @[]
  var name = ""
  var value = ""
  var have = false
  for line in head.split("\r\n"):
    if line.len > 0 and line[0] in {' ', '\t'} and have:
      # Unfold: one joining space, except onto an empty value (a
      # header starting on the continuation line has no leading
      # space in its value).
      if value.len > 0 and not value.endsWith(' '):
        value.add(" ")
      value.add(line.strip())
    else:
      if have:
        result.add((name, value))
      let colon = line.find(':')
      doAssert colon > 0, "bad header line: '" & line & "'"
      name = line[0 ..< colon]
      value = line[colon + 1 .. ^1].strip()
      have = true
  if have:
    result.add((name, value))

proc splitParts(body, boundary: string): seq[string] =
  ## The raw child blobs between `--boundary` … `--boundary--`. The
  ## CRLF before each delimiter belongs to the delimiter (RFC 2046
  ## §5.1.1), so blobs carry no trailing CRLF.
  let delim = "--" & boundary
  let close = delim & "--"
  result = @[]
  var current = ""
  var inPart = false
  for line in body.split("\r\n"):
    if line == delim:
      if inPart:
        result.add(current)
      current = ""
      inPart = true
    elif line == close:
      if inPart:
        result.add(current)
      return
    elif inPart:
      if current.len > 0:
        current.add("\r\n")
      current.add(line)
  doAssert false, "multipart body has no close delimiter"

proc boundaryOf(contentType: string): string =
  let key = "boundary="
  let at = contentType.toLowerAscii().find(key)
  doAssert at >= 0, "multipart without boundary: '" & contentType & "'"
  var v = contentType[at + key.len .. ^1].strip()
  if v.startsWith('"'):
    v = v[1 ..< v.find('"', 1)]
  else:
    let semi = v.find(';')
    if semi >= 0:
      v = v[0 ..< semi]
  v.strip()

proc parsePart(blob: string): ParsedPart =
  let sep = blob.find("\r\n\r\n")
  doAssert sep >= 0, "part without a header/body split"
  result = ParsedPart(headers: parseHeaders(blob[0 ..< sep]),
    body: blob[sep + 4 .. ^1], children: @[])
  let ct = parsedHeader(result, "Content-Type")
  if ct.toLowerAscii().startsWith("multipart/"):
    for child in splitParts(result.body, boundaryOf(ct)):
      result.children.add(parsePart(child))

proc qpDecode(s: string): string =
  ## The test's own quoted-printable reader: `=XX` bytes and `=`
  ## soft breaks. Independent of `encodeQuotedPrintable`.
  var i = 0
  while i < s.len:
    if s[i] == '=' and i + 2 < s.len and s[i + 1] == '\r' and
        s[i + 2] == '\n':
      i += 3
    elif s[i] == '=' and i + 1 < s.len and s[i + 1] == '\n':
      i += 2
    elif s[i] == '=' and i + 2 < s.len and s[i + 1] in HexDigits and
        s[i + 2] in HexDigits:
      result.add(chr(parseHexInt(s[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(s[i])
      inc i

proc decodeQText(t: string): string =
  var i = 0
  while i < t.len:
    if t[i] == '_':
      result.add(' ')
      inc i
    elif t[i] == '=' and i + 2 < t.len:
      result.add(chr(parseHexInt(t[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(t[i])
      inc i

proc decodeWords(s: string): string =
  ## Undoes `encodeHeaderText`: `=?UTF-8?B/Q?…?=` words, with the
  ## whitespace between adjacent words ignored (RFC 2047 §6.2).
  ## Accepts raw folded values too (CRLF between the words).
  var i = 0
  while i < s.len:
    if s[i] == '=' and i + 1 < s.len and s[i + 1] == '?':
      # Structural parse: the terminator is the first "?=" past the
      # `charset?encoding?` head (the encoded text itself holds no
      # '?', but may start with `=XX`, which a naive find would
      # mistake for the end).
      let q1 = s.find('?', i + 2)
      doAssert q1 >= 0, "bad encoded-word"
      let q2 = s.find('?', q1 + 1)
      doAssert q2 >= 0, "bad encoded-word"
      let done = s.find("?=", q2 + 1)
      doAssert done >= 0, "unterminated encoded-word"
      doAssert s[i + 2 ..< q1].toUpperAscii() == "UTF-8"
      let enc = s[q1 + 1 ..< q2].toUpperAscii()
      if enc == "B":
        result.add(base64.decode(s[q2 + 1 ..< done]))
      else:
        doAssert enc == "Q", "bad encoded-word"
        result.add(decodeQText(s[q2 + 1 ..< done]))
      i = done + 2
      var j = i
      while j < s.len and s[j] in {' ', '\t', '\r', '\n'}:
        inc j
      if j + 1 < s.len and s[j] == '=' and s[j + 1] == '?':
        i = j
    else:
      result.add(s[i])
      inc i

proc unstuffFlowed(text: string): string =
  ## Undoes `spaceStuffFlowed`: one leading space removed from every
  ## line that has one (RFC 3676 §4.4).
  var lines: seq[string] = @[]
  for line in text.splitLines():
    if line.len > 0 and line[0] == ' ':
      lines.add(line[1 .. ^1])
    else:
      lines.add(line)
  lines.join("\n")

proc decodedLines(body: string): seq[string] =
  ## QP-decoded content lines: the trailing CRLF the encoder appends
  ## is framing, not content.
  var lines = qpDecode(body).split("\r\n")
  if lines.len > 0 and lines[^1] == "":
    lines.setLen(lines.len - 1)
  lines

proc hasBareLineBreak(s: string): bool =
  ## True when a CR or LF is not part of a CRLF pair (R-MIME-13).
  for i in 0 ..< s.len:
    if s[i] == '\n' and (i == 0 or s[i - 1] != '\r'):
      return true
    if s[i] == '\r' and (i + 1 >= s.len or s[i + 1] != '\n'):
      return true
  false

proc encodedWordsIn(s: string): seq[string] =
  ## Every `=?…?=` token in `s`, parsed structurally (the terminator
  ## is the first "?=" past the `charset?encoding?` head — see
  ## `decodeWords`).
  result = @[]
  var i = 0
  while i + 1 < s.len:
    if s[i] == '=' and s[i + 1] == '?':
      let q1 = s.find('?', i + 2)
      doAssert q1 >= 0
      let q2 = s.find('?', q1 + 1)
      doAssert q2 >= 0
      let done = s.find("?=", q2 + 1)
      doAssert done >= 0
      result.add(s[i .. done + 1])
      i = done + 2
    else:
      inc i

# ------------------------------------------------------- the message

const
  rtSubject = "Héllo — flowed & encoded ✓✓✓ with enough length to " &
    "force several encoded-words across the fold"
  rtHtmlBefore = "<p>Hello <a href=\"https://example.com/welcome?user=42" &
    "&token=abc-def\">confirm</a>, héllo!</p>\n" &
    "<p><img src=\"cid:"
  rtHtmlAfter = "\" alt=\"logo\"></p>\n" &
    "<p>This line is deliberately long so the quoted-printable " &
    "encoder must wrap it with a soft break somewhere.</p>\n" &
    "<p>Trailing spaces ride encoded:   </p>\n" &
    "<p>Last line.</p>"
  rtText = "Hello plain,\n" &
    "> a quoted line,\n" &
    "From the team,\n" &
    " an indented line,\n" &
    "last line with unicode héllo."
  rtAttach = "attachment line one\nline two with unicode héllo\n"
  rtDateSecs = 1780000000'i64
  rtDateHeader = "Thu, 28 May 2026 20:26:40 +0000"
  rtMessageId = "<t6-roundtrip-1@example.com>"
  rtTokenUri = "https://example.com/u/opaque-token-0123456789"
  rtSeed = "t6roundtrip"

proc rtHtml(logoId: string): string =
  ## The round-trip HTML, referencing the embedded logo's content id.
  rtHtmlBefore & logoId & rtHtmlAfter

proc roundtripLogo(pngBytes: string): AssetRef =
  loadAsset("logo.png", pngBytes)

proc roundtripHeaders(): MessageHeaders =
  MessageHeaders(
    fromAddr: mailbox("Tēst Sënder", "sender@example.com"),
    to: @[mailbox("Récipient", "recipient@example.com")],
    bcc: @[mailbox("", "archivist@example.com")],
    subject: rtSubject,
    messageId: rtMessageId,
    date: fromUnix(rtDateSecs),
    unsubscribe: some(Unsubscribe(httpsUri: rtTokenUri)))

proc roundtripRendered(pngBytes: string): RenderedEmail =
  let logo = roundtripLogo(pngBytes)
  RenderedEmail(
    html: rtHtml(contentIdFor(logo)), text: rtText, assets: @[logo])

proc roundtripAttachments(): seq[Attachment] =
  @[Attachment(filename: "notes.txt", mime: "text/plain",
    bytes: rtAttach)]

proc roundtripMessage(pngBytes: string): EmailMessage =
  toMessage(roundtripRendered(pngBytes), roundtripHeaders(), isEmbedded,
    roundtripAttachments())

# ------------------------------------------------------- mailpit rig

proc freePort(): int =
  var sock = newSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = sock.getLocalAddr()
  sock.close()
  port.int

proc startMailpit(): tuple[p: Process; smtpPort, httpPort: int;
                          httpBase, dir: string] =
  let bin = findExe("mailpit")
  if bin.len == 0:
    raise newException(MailpitError,
      "mailpit binary not found on PATH — refusing to skip " &
      "(allowed_mocks: None). Run under the dev shell (`nix develop` " &
      "in isonim-email; flake.nix carries mailpit) so the real " &
      "catcher is on PATH.")
  let smtpPort = freePort()
  var httpPort = freePort()
  while httpPort == smtpPort:
    httpPort = freePort()
  let dir = getTempDir() / "isonim-t6-roundtrip-" & $getCurrentProcessId()
  createDir(dir)
  let p = startProcess(bin, workingDir = dir, args = @[
    "-l", "127.0.0.1:" & $httpPort, "-s", "127.0.0.1:" & $smtpPort,
    "-d", dir / "mp.db", "--disable-version-check", "-q"],
    options = {poUsePath})
  let httpBase = "http://127.0.0.1:" & $httpPort
  var ready = false
  for _ in 0 ..< 150:
    if peekExitCode(p) != -1:
      close(p)
      raise newException(MailpitError,
        "mailpit exited during startup (see " & dir & ")")
    var client = newHttpClient(timeout = 1000)
    try:
      discard client.getContent(httpBase & "/api/v1/messages")
      ready = true
    except CatchableError:
      sleep(100)
    finally:
      client.close()
    if ready:
      break
  if not ready:
    try:
      terminate(p)
    except OSError:
      discard
    close(p)
    raise newException(MailpitError,
      "mailpit never became ready on " & httpBase)
  (p, smtpPort, httpPort, httpBase, dir)

proc stopMailpit(p: Process; dir: string) =
  try:
    terminate(p)
  except OSError:
    discard
  try:
    discard waitForExit(p)
  except OSError:
    discard
  close(p)
  try:
    removeDir(dir)
  except OSError:
    discard

# ------------------------------------------------- unsubscribe rig

type FixtureHit = object
  ## One request the R-SND-03 fixture server recorded, with the
  ## library's verdict on it and the status the server answered.
  reqLine: string
  headers: seq[(string, string)]
  body: string
  verdict: OneClickVerdict
  status: int

proc fixtureWorker(arg: tuple[port, hits: int;
                               ch: ptr Channel[FixtureHit]]) {.thread.} =
  ## A minimal sender's server built on the library's one-click half
  ## (R-SND-03, docs/sending.md): every request goes through
  ## `checkOneClickRequest`, and the answer is exactly what
  ## `oneClickResponse` returns. Every accepted connection yields
  ## exactly one hit — including dropped ones — so the main thread's
  ## recvs always terminate.
  var server = newSocket()
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(arg.port), "127.0.0.1")
    server.listen()
    for _ in 0 ..< arg.hits:
      var client = newSocket()
      try:
        server.accept(client)
        var lines: seq[string] = @[]
        while true:
          # `recvLine` returns the lone "\r\n" for a blank line, not
          # "" (only a disconnect reads "").
          let line = client.recvLine(timeout = 5000)
          if line.len == 0 or line == "\r\n":
            break
          lines.add(line)
        if lines.len == 0:
          arg.ch[].send(FixtureHit(reqLine: "(closed)",
            headers: @[], body: ""))
        else:
          var heads: seq[(string, string)] = @[]
          var contentLen = 0
          for h in lines[1 .. ^1]:
            let colon = h.find(':')
            if colon > 0:
              let name = h[0 ..< colon].strip()
              heads.add((name, h[colon + 1 .. ^1].strip()))
              if name.toLowerAscii() == "content-length":
                contentLen = parseInt(heads[^1][1])
          var body = ""
          var remaining = contentLen
          while remaining > 0:
            let chunk = client.recv(min(remaining, 65536),
              timeout = 5000)
            if chunk.len == 0:
              break
            body.add(chunk)
            remaining -= chunk.len
          let verdict = checkOneClickRequest(OneClickRequest(
            httpMethod: lines[0].split(' ')[0], headers: heads,
            body: body))
          let resp = oneClickResponse(verdict)
          var wire = "HTTP/1.1 " & $resp.status &
            (if resp.status == 200: " OK" else: " Bad Request") & "\r\n"
          for (n, v) in resp.headers:
            wire.add(n & ": " & v & "\r\n")
          wire.add("Content-Length: " & $resp.body.len & "\r\n" &
            "Connection: close\r\n\r\n" & resp.body)
          client.send(wire)
          arg.ch[].send(FixtureHit(reqLine: lines[0], headers: heads,
            body: body, verdict: verdict, status: resp.status))
      except CatchableError as e:
        arg.ch[].send(FixtureHit(reqLine: "ERROR: " & e.msg,
          headers: @[], body: ""))
      finally:
        client.close()
  except CatchableError as e:
    for _ in 0 ..< arg.hits:
      arg.ch[].send(FixtureHit(reqLine: "ERROR: " & e.msg,
        headers: @[], body: ""))
  finally:
    server.close()

proc fixtureHeader(hit: FixtureHit; name: string): string =
  for (n, v) in hit.headers:
    if n.toLowerAscii() == name.toLowerAscii():
      return v
  ""

proc dummyConnect(port: int) =
  ## Releases a worker stuck on `accept` (cleanup path only).
  try:
    var d = newSocket()
    d.connect("127.0.0.1", Port(port), timeout = 500)
    d.close()
  except CatchableError:
    discard

suite "message assembly, transports and round trip":
  test "test_mime_roundtrip_through_mailpit":
    # rule: R-MIME-01
    # rule: R-MIME-02
    # rule: R-MIME-03
    # rule: R-MIME-04
    # rule: R-MIME-06
    # rule: R-MIME-08
    # rule: R-MIME-09
    # rule: R-MIME-10
    # rule: R-MIME-11
    # rule: R-MIME-12
    # rule: R-MIME-13

    let pngBytes = readFile(testsDir / "fixtures" / "t6_rgb.png")
    check pngBytes.len > 0
    let logoId = contentIdFor(roundtripLogo(pngBytes))
    let html = rtHtml(logoId)
    let msg = roundtripMessage(pngBytes)
    check msg.envelopeFrom == "sender@example.com"
    check msg.envelopeTo == @["recipient@example.com",
      "archivist@example.com"]

    # The sent bytes: CRLF throughout, every line within the MUST,
    # and our own headers within the SHOULD.
    let sent = toRfc5322(msg, rtSeed)
    check not hasBareLineBreak(sent)
    for line in sent.split("\r\n"):
      check line.len <= 998
    let sentHead = sent[0 ..< sent.find("\r\n\r\n")]
    for line in sentHead.split("\r\n"):
      if "=?" in line:
        check line.len <= 76
      else:
        check line.len <= 78
    let subjectWords = encodedWordsIn(sentHead)
    check subjectWords.len > 1
    for w in subjectWords:
      check w.len <= 75
    check "?=\r\n =?" in sentHead
    # We never emit Bcc (the envelope carries it).
    check parsedHeader(parsePart(sent), "Bcc") == ""

    let rig = startMailpit()
    try:
      let id = sendMailpit(msg, port = rig.smtpPort,
        httpPort = rig.httpPort, deterministicSeed = rtSeed)
      check id.len > 0

      # The raw view: CRLF, within the MUST, and our bytes untouched
      # at the tail (Mailpit only prepends Received/Return-Path).
      let raw = fetchRaw(rig.httpBase, id)
      check not hasBareLineBreak(raw)
      for line in raw.split("\r\n"):
        check line.len <= 998
      check raw.endsWith(sent)
      check parsedHeader(parsePart(raw), "Message-ID") == rtMessageId

      # The tree walk: mixed[alternative[plain, related[html,
      # image]], attachment].
      let root = parsePart(raw)
      check parsedHeader(root, "Content-Type").startsWith(
        "multipart/mixed")
      check root.children.len == 2
      let alt = root.children[0]
      check parsedHeader(alt, "Content-Type").startsWith(
        "multipart/alternative")
      check alt.children.len == 2
      let plain = alt.children[0]
      check parsedHeader(plain, "Content-Type").startsWith("text/plain")
      check "charset=utf-8" in
        parsedHeader(plain, "Content-Type").toLowerAscii()
      check "format=flowed" in
        parsedHeader(plain, "Content-Type").toLowerAscii()
      check parsedHeader(plain, "Content-Transfer-Encoding") ==
        "quoted-printable"
      check decodedLines(plain.body) ==
        spaceStuffFlowed(rtText).splitLines()
      check unstuffFlowed(decodedLines(plain.body).join("\n")) == rtText
      let rel = alt.children[1]
      let relCt = parsedHeader(rel, "Content-Type")
      check relCt.startsWith("multipart/related")
      check "type=\"text/html\"" in relCt.toLowerAscii()
      check rel.children.len == 2
      let htmlPart = rel.children[0]
      check parsedHeader(htmlPart, "Content-Type").startsWith("text/html")
      check "charset=utf-8" in
        parsedHeader(htmlPart, "Content-Type").toLowerAscii()
      check decodedLines(htmlPart.body) == html.splitLines()
      let img = rel.children[1]
      check parsedHeader(img, "Content-Type").startsWith("image/png")
      check parsedHeader(img, "Content-ID") == "<" & logoId & ">"
      check parsedHeader(img, "Content-Disposition") ==
        "inline; filename=\"logo.png\""
      check "cid:" & logoId in html
      check parsedHeader(img, "Content-Transfer-Encoding") == "base64"
      for line in img.body.split("\r\n"):
        if line.len > 0:
          check line.len <= 76
      check base64.decode(img.body) == pngBytes
      let att = root.children[1]
      check parsedHeader(att, "Content-Transfer-Encoding") == "base64"
      check parsedHeader(att, "Content-Disposition") ==
        "attachment; filename=\"notes.txt\""
      check base64.decode(att.body) == rtAttach

      # Every multipart boundary is valid and absent from the bodies
      # it frames.
      for mp in [root, alt, rel]:
        let b = boundaryOf(parsedHeader(mp, "Content-Type"))
        check isValidBoundary(b)
        for child in mp.children:
          check b notin child.body

      # The top headers: version, Date, Message-ID, encoded names.
      check parsedHeader(root, "MIME-Version") == "1.0"
      check parsedHeader(root, "Date") == rtDateHeader
      check parsedHeader(root, "Message-ID") == rtMessageId
      check decodeWords(parsedHeader(root, "Subject")) == rtSubject
      let fromVal = parsedHeader(root, "From")
      check fromVal.endsWith("<sender@example.com>")
      check "=?" notin fromVal[fromVal.find('<') .. ^1]
      check decodeWords(fromVal[0 ..< fromVal.find('<')].strip()) ==
        "Tēst Sënder"
      let toVal = parsedHeader(root, "To")
      check toVal.endsWith("<recipient@example.com>")
      check "=?" notin toVal[toVal.find('<') .. ^1]
      check parsedHeader(root, "List-Unsubscribe") ==
        "<" & rtTokenUri & ">"
      check parsedHeader(root, "List-Unsubscribe-Post") ==
        "List-Unsubscribe=One-Click"
      # Mailpit prepends Bcc for the envelope-only recipient (its
      # own header, ahead of our untouched bytes).
      check parsedHeader(root, "Bcc") == "archivist@example.com"

      # Mailpit's own decoding agrees (independent oracle; line
      # endings normalised — the raw walk above is the byte-exact
      # half).
      let summary = fetchSummary(rig.httpBase, id)
      check summary["Text"].getStr().replace("\r", "") ==
        spaceStuffFlowed(rtText)
      check summary["HTML"].getStr().replace("\r", "") == html
      check summary["Subject"].getStr() == rtSubject
      check summary["From"]["Name"].getStr() == "Tēst Sënder"
      check summary["From"]["Address"].getStr() == "sender@example.com"
      check summary["MessageID"].getStr() == "t6-roundtrip-1@example.com"
      check summary["ListUnsubscribe"]["Links"][0].getStr() == rtTokenUri
      check summary["ListUnsubscribe"]["HeaderPost"].getStr() ==
        "List-Unsubscribe=One-Click"
      check summary["ListUnsubscribe"]["Errors"].getStr() == ""
      check summary["Inline"][0]["ContentID"].getStr() == logoId
      check summary["Attachments"][0]["FileName"].getStr() == "notes.txt"

      # The generic relay delivers to the same catcher (no auth, no
      # TLS — the catcher shape; production relays use both). Unseeded,
      # like production: only the explicit Message-ID is asserted.
      var relayHeaders = roundtripHeaders()
      relayHeaders.messageId = "<t6-relay-2@example.com>"
      let relayMsg = toMessage(roundtripRendered(pngBytes), relayHeaders,
        isEmbedded, roundtripAttachments())
      sendSmtp(relayMsg, "127.0.0.1", rig.smtpPort, "", "",
        tls = false)
      let relayId = waitForLatest(rig.httpBase, 1)
      check parsedHeader(parsePart(fetchRaw(rig.httpBase, relayId)),
        "Message-ID") == "<t6-relay-2@example.com>"
    finally:
      stopMailpit(rig.p, rig.dir)

  test "assembly shapes, seeds and validation":
    # rule: R-MIME-01
    # rule: R-MIME-03
    # rule: R-MIME-04
    # rule: R-MIME-12

    proc minimalRendered(html = "<p>x</p>"; text = "x"): RenderedEmail =
      RenderedEmail(html: html, text: text)

    proc minimalHeaders(): MessageHeaders =
      MessageHeaders(
        fromAddr: mailbox("", "a@example.com"),
        to: @[mailbox("", "b@example.com")])

    proc minimal(): EmailMessage =
      toMessage(minimalRendered(), minimalHeaders())

    proc idOf(bytes: string): string =
      parsedHeader(parsePart(bytes), "Message-ID")

    proc boundaryOfRoot(bytes: string): string =
      boundaryOf(parsedHeader(parsePart(bytes), "Content-Type"))

    # No images, no attachments: the root IS the alternative.
    let plain = minimal()
    let plainBytes = toRfc5322(plain, "u1")
    let plainRoot = parsePart(plainBytes)
    check parsedHeader(plainRoot, "Content-Type").startsWith(
      "multipart/alternative")
    check plainRoot.children.len == 2

    # The seed fixes boundaries and the Message-ID: the same inputs
    # are byte-identical.
    let seedId = idOf(plainBytes)
    check seedId.startsWith("<u1.")
    check seedId.endsWith("@example.com>")
    check seedId.len == "<u1.".len + 16 + "@example.com>".len
    for c in seedId["<u1.".len ..< seedId.find('@')]:
      check c in HexDigits
    let seedBoundary = boundaryOfRoot(plainBytes)
    check seedBoundary.startsWith("=_e_u1_")
    check isValidBoundary(seedBoundary)
    check toRfc5322(minimal(), "u1") == plainBytes
    # A different seed derives different bytes.
    check idOf(toRfc5322(minimal(), "u2")) != seedId
    check boundaryOfRoot(toRfc5322(minimal(), "u2")) != seedBoundary

    # The id domain derives from the From address.
    var dommedHeaders = minimalHeaders()
    dommedHeaders.fromAddr = mailbox("", "a@x.test")
    let dommed = toMessage(minimalRendered(), dommedHeaders)
    check idOf(toRfc5322(dommed, "u1")).endsWith("@x.test>")

    # Without a seed the id is random hex at the From domain.
    let wildId = idOf(toRfc5322(minimal()))
    check wildId.startsWith("<") and wildId.endsWith("@example.com>")
    check wildId.len == 1 + 16 + "@example.com>".len
    for c in wildId[1 ..< wildId.find('@')]:
      check c in HexDigits

    # An explicit date is honoured; a zero date reads the facade clock.
    var datedHeaders = minimalHeaders()
    datedHeaders.date = fromUnix(1709164800)
    let dated = toMessage(minimalRendered(), datedHeaders)
    check parsedHeader(parsePart(toRfc5322(dated, "u1")), "Date") ==
      "Thu, 29 Feb 2024 00:00:00 +0000"
    let before = nowUnixMillis(systemClock())
    let clocked = toMessage(minimalRendered(), minimalHeaders())
    let after = nowUnixMillis(systemClock())
    let clockedDate = parsedHeader(parsePart(toRfc5322(clocked, "u1")),
      "Date")
    check clockedDate == rfc5322Date(before) or
      clockedDate == rfc5322Date(after)

    # A boundary candidate present in the bodies is retried, not
    # reused. `=_`-prefixed boundaries can never appear in QP output
    # (every `=` encodes as `=3D`) or base64 output (no `_` in the
    # alphabet), so no seed can collide through `toRfc5322`; this
    # drives the framing check directly with the fixed source.
    let colliding = MimePart(kind: mpkSingle, headers: @[],
      body: "carries u1-alt-1 literally")
    let framed = newMultipart("alternative",
      @[colliding, colliding], fixedBoundarySource("u1"), "alt")
    check framed.boundary == "u1-alt-retry1-2"
    check isValidBoundary(framed.boundary)
    for child in framed.children:
      check framed.boundary notin child.body

    # Invalid addresses and header values raise, never emit.
    proc mimeMsg(headers: MessageHeaders): string =
      try:
        discard toMessage(minimalRendered(), headers)
        ""
      except EmailRenderError as e:
        e.msg
    var badFromHeaders = minimalHeaders()
    badFromHeaders.fromAddr = mailbox("", "not-an-address")
    let badFromMsg = mimeMsg(badFromHeaders)
    check badFromMsg.startsWith(codeMimeHeader & ":")
    check "not-an-address" in badFromMsg
    var badSubjectHeaders = minimalHeaders()
    badSubjectHeaders.subject = "hi\nBcc: evil@example.com"
    check mimeMsg(badSubjectHeaders).startsWith(codeMimeHeader & ":")
    var badExtraHeaders = minimalHeaders()
    badExtraHeaders.extra = @[("X-Ok", "fine"), ("X-Bad", "a\rb")]
    let badExtraMsg = mimeMsg(badExtraHeaders)
    check badExtraMsg.startsWith(codeMimeHeader & ":")
    check "X-Bad" in badExtraMsg
    var goodExtraHeaders = minimalHeaders()
    goodExtraHeaders.extra = @[("X-Ok", "fine")]
    let goodExtra = toMessage(minimalRendered(), goodExtraHeaders)
    check parsedHeader(parsePart(toRfc5322(goodExtra, "u1")),
      "X-Ok") == "fine"

    # An invalid supplied Message-ID raises, naming the id rule.
    var badIdHeaders = minimalHeaders()
    badIdHeaders.messageId = "no-at-sign"
    let badIdMsg = mimeMsg(badIdHeaders)
    check badIdMsg.startsWith(codeMimeHeader & ":")
    check "R-MIME-12" in badIdMsg
    check "no-at-sign" in badIdMsg
    # A bare id normalises to brackets.
    var bareIdHeaders = minimalHeaders()
    bareIdHeaders.messageId = "u9@example.com"
    let bareId = toMessage(minimalRendered(), bareIdHeaders)
    check idOf(toRfc5322(bareId, "u1")) == "<u9@example.com>"

    # Display names quote when they must (no rule: mailbox shaping).
    check formatMailbox(mailbox("Doe, Jane", "j@example.com")) ==
      "\"Doe, Jane\" <j@example.com>"
    check formatMailbox(mailbox("say \"hi\"", "j@example.com")) ==
      "\"say \\\"hi\\\"\" <j@example.com>"
    check formatMailbox(mailbox("", "j@example.com")) == "j@example.com"

    # toParts hands back the decoded fields.
    let parts = toParts(plain)
    check parts.html == "<p>x</p>"
    check parts.text == "x"
    check ("From", "a@example.com") in parts.headers
    check ("To", "b@example.com") in parts.headers
    check parts.inline.len == 0
    # A missing Message-ID stays missing until toRfc5322 generates it.
    for (name, _) in parts.headers:
      check name != "Message-ID"
    var idHeaders = minimalHeaders()
    idHeaders.messageId = "<set@example.com>"
    let withId = toMessage(minimalRendered(), idHeaders)
    check ("Message-ID", "<set@example.com>") in
      toParts(withId).headers

  test "rfc5322 date conversion":
    # rule: R-MIME-12

    # Expected strings from GNU date -u (independent oracle).
    check rfc5322Date(0) == "Thu, 01 Jan 1970 00:00:00 +0000"
    check rfc5322Date(1709164800000) == "Thu, 29 Feb 2024 00:00:00 +0000"
    check rfc5322Date(1780000000000) == "Thu, 28 May 2026 20:26:40 +0000"
    check rfc5322Date(-1000) == "Wed, 31 Dec 1969 23:59:59 +0000"
    check rfc5322Date(1500) == "Thu, 01 Jan 1970 00:00:01 +0000"

  test "flowed space-stuffing is lossless":
    # rule: R-MIME-06

    check spaceStuffFlowed("") == ""
    let text = "plain\n> quoted\nFrom the team\n indented\nFromX\n"
    let stuffed = spaceStuffFlowed(text)
    check stuffed.splitLines() == @["plain", " > quoted",
      " From the team", "  indented", "FromX", ""]
    check unstuffFlowed(stuffed) == text
    check unstuffFlowed(spaceStuffFlowed(rtText)) == rtText

  test "unsubscribe post fixture pins the server contract":
    # rule: R-SND-03

    # The mail-receiver side, driven from a library-built message: the
    # URI comes out of the serialised List-Unsubscribe header, the body
    # out of List-Unsubscribe-Post. The server side is the library's
    # `checkOneClickRequest` + `oneClickResponse` in a real HTTP server.
    # The fixture has no TLS, so the https URI is POSTed over plain
    # http to the same host, port and path (the scheme is the one
    # thing swapped). Five accepts: the readiness probe, two one-click
    # POSTs (both body shapes), and two that must be refused (a cookie,
    # a GET). No checks until every hit is received: each accepted
    # connection yields exactly one hit, so the recvs below terminate.
    const totalHits = 5
    const token = "Zx8Kq2Lm9Tt4Vw7Rb3Nc"
    var ch: Channel[FixtureHit]
    ch.open()
    let port = freePort()
    var thr: Thread[tuple[port, hits: int; ch: ptr Channel[FixtureHit]]]
    createThread(thr, fixtureWorker, (port, totalHits, addr ch))
    var got: seq[FixtureHit] = @[]
    var responses: seq[Response] = @[]
    let msg = toMessage(RenderedEmail(html: "<p>x</p>", text: "x"),
      MessageHeaders(fromAddr: mailbox("", "a@example.com"),
        to: @[mailbox("", "b@example.com")],
        unsubscribe: some(Unsubscribe(
          httpsUri: "https://127.0.0.1:" & $port & "/u/" & token,
          mailto: "mailto:unsub@example.com"))))
    let root = parsePart(toRfc5322(msg, "u1"))
    let listHeader = parsedHeader(root, "List-Unsubscribe")
    let postBody = parsedHeader(root, "List-Unsubscribe-Post")
    check postBody == "List-Unsubscribe=One-Click"
    let httpsUri = listHeader[listHeader.find('<') + 1 ..<
      listHeader.find('>')]
    check httpsUri == "https://127.0.0.1:" & $port & "/u/" & token
    let target = "http://" & httpsUri["https://".len .. ^1]
    try:
      var serverUp = false
      for _ in 0 ..< 100:
        var probe = newSocket()
        try:
          probe.connect("127.0.0.1", Port(port), timeout = 200)
          serverUp = true
          break
        except CatchableError:
          sleep(50)
        finally:
          probe.close()
      doAssert serverUp, "fixture server never listened"
      got.add(ch.recv())
      doAssert got[0].reqLine == "(closed)"

      # A bare client, as a mailbox provider sends it: no cookie jar,
      # no auth, and no redirect following (a 3xx would show as is).
      var client = newHttpClient(maxRedirects = 0)
      try:
        client.headers = newHttpHeaders({
          "Content-Type": "application/x-www-form-urlencoded"})
        responses.add(client.post(target, body = postBody))
        got.add(ch.recv())

        let eq = postBody.find('=')
        var mp = newMultipartData()
        mp[postBody[0 ..< eq]] = postBody[eq + 1 .. ^1]
        client.headers = newHttpHeaders()
        responses.add(client.post(target, multipart = mp))
        got.add(ch.recv())

        client.headers = newHttpHeaders({
          "Content-Type": "application/x-www-form-urlencoded",
          "Cookie": "session=abc"})
        responses.add(client.post(target, body = postBody))
        got.add(ch.recv())

        client.headers = newHttpHeaders()
        responses.add(client.get(target))
        got.add(ch.recv())
      finally:
        client.close()
    finally:
      for _ in got.len ..< totalHits:
        dummyConnect(port)
      while got.len < totalHits:
        got.add(ch.recv())
      joinThread(thr)
      ch.close()

    check got.len == totalHits
    check responses.len == 4
    # Every request reached the path the header named.
    for hit in got[1 .. ^1]:
      check (" /u/" & token & " ") in hit.reqLine
    # The two one-click POSTs: accepted by the library, 200 back.
    let form = got[1]
    check form.reqLine.startsWith("POST ")
    check fixtureHeader(form, "Content-Type") ==
      "application/x-www-form-urlencoded"
    check fixtureHeader(form, "Cookie") == ""
    check fixtureHeader(form, "Authorization") == ""
    check form.body == "List-Unsubscribe=One-Click"
    check form.verdict.ok
    let multi = got[2]
    check fixtureHeader(multi, "Content-Type").startsWith(
      "multipart/form-data; boundary=")
    check "name=\"List-Unsubscribe\"" in multi.body
    check multi.verdict.ok
    check responses[0].code == Http200
    check responses[1].code == Http200
    check responses[0].body == "unsubscribed"
    # A POST carrying a cookie, and a GET: refused, 400, never a 3xx.
    check not got[3].verdict.ok
    check "cookies" in got[3].verdict.reason
    check not got[4].verdict.ok
    check "POST" in got[4].verdict.reason
    check responses[2].code == Http400
    check responses[3].code == Http400
    for resp in responses:
      check resp.code.int notin 300 .. 399
      for k, _ in resp.headers.pairs():
        check k.toLowerAscii() != "location"

  test "dkim metadata":
    # rule: R-SND-04

    # The metadata half: the message names the unsubscribe pair for
    # DKIM when it carries one. The transport half (the Mailgun request
    # sets no `o:dkim` exclusion and carries the headers byte for byte)
    # is pinned by tests/t6_mailgun.nim against a capture server.
    let pngBytes = readFile(testsDir / "fixtures" / "t6_rgb.png")
    let msg = roundtripMessage(pngBytes)
    check msg.dkimHeaders ==
      @["List-Unsubscribe", "List-Unsubscribe-Post"]
    var bareHeaders = roundtripHeaders()
    bareHeaders.unsubscribe = none(Unsubscribe)
    let noUnsub = toMessage(roundtripRendered(pngBytes), bareHeaders,
      isEmbedded, roundtripAttachments())
    check noUnsub.dkimHeaders.len == 0

  test "bulk sender requirements are documented":
    # rule: R-SND-06

    let doc = readFile(testsDir / ".." / "docs" / "sending.md")
    for token in ["SPF", "DKIM", "DMARC", "0.3%", "5,000",
        "List-Unsubscribe", "List-Unsubscribe=One-Click", "cookie",
        "redirect", "t6_roundtrip"]:
      check token in doc
