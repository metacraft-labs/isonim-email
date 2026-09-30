# rule: R-SND-01
# rule: R-SND-04
## The Mailgun transport sends the complete message. `sendMailgun` is
## driven end to end against a local HTTP server that records the raw
## request; the test parses the `multipart/form-data` body with its own
## reader and checks that
##   - the request goes to `/v3/<domain>/messages.mime` with basic auth,
##   - the `message` file part is byte-identical to `toRfc5322`,
##   - the `to` fields are exactly the envelope recipients (To, Cc and
##     Bcc) and the `o:tag` fields exactly the tags, with no `h:` and no
##     `o:dkim` field,
##   - the message that arrives carries List-Unsubscribe,
##     List-Unsubscribe-Post, the other owned headers, Cc, Reply-To, the
##     attachment and the inline `cid:` image (parsed from the received
##     bytes, not from the builder),
##   - the API key never reaches an error message.
##
## Mock justification (allowed_mocks): the capture server stands in for
## Mailgun's HTTP API. A real Mailgun account would need a live key and
## network access, would send real mail, and would not show the test
## the request it received; a local socket server that records the
## exact bytes is the only way to assert what the transport puts on the
## wire. Everything else is real: the library's own message builder,
## `std/httpclient` over a real TCP connection, and a byte-level parse
## of what arrived. What the mock cannot show — that Mailgun accepts
## the field names — is pinned to Mailgun's published API reference
## for `POST /v3/{domain_name}/messages.mime` (`to`, `message`,
## `o:tag`).
##
## C backend only: sockets, a thread and a PNG fixture read off disk.
import std/[base64, net, options, os, strutils, times,
  unittest]
import isonim_email

const testsDir = parentDir(currentSourcePath())

# ------------------------------------------------------ capture server

type Captured = object
  ## One request the capture server received, verbatim.
  reqLine: string
  headers: seq[(string, string)]
  body: string

proc captureWorker(arg: tuple[port, status: int; reply: string;
                               echoAuth: bool;
                               ch: ptr Channel[Captured]]) {.thread.} =
  ## Accepts exactly one connection, records the request and answers
  ## `status` with `reply` (plus the received Authorization header when
  ## `echoAuth`, the way a careless proxy would).
  var server = newSocket()
  var hit = Captured(reqLine: "(none)")
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(arg.port), "127.0.0.1")
    server.listen()
    var client = newSocket()
    try:
      server.accept(client)
      var lines: seq[string] = @[]
      while true:
        let line = client.recvLine(timeout = 10_000)
        if line.len == 0 or line == "\r\n":
          break
        lines.add(line)
      var contentLen = 0
      var auth = ""
      if lines.len > 0:
        hit.reqLine = lines[0]
        for h in lines[1 .. ^1]:
          let colon = h.find(':')
          if colon > 0:
            let name = h[0 ..< colon].strip()
            let value = h[colon + 1 .. ^1].strip()
            hit.headers.add((name, value))
            if name.toLowerAscii() == "content-length":
              contentLen = parseInt(value)
            if name.toLowerAscii() == "authorization":
              auth = value
      var remaining = contentLen
      while remaining > 0:
        let chunk = client.recv(min(remaining, 65536), timeout = 10_000)
        if chunk.len == 0:
          break
        hit.body.add(chunk)
        remaining -= chunk.len
      let reply = arg.reply & (if arg.echoAuth: " auth=" & auth else: "")
      client.send("HTTP/1.1 " & $arg.status & " X\r\n" &
        "Content-Type: application/json\r\n" &
        "Content-Length: " & $reply.len & "\r\n" &
        "Connection: close\r\n\r\n" & reply)
    finally:
      client.close()
  except CatchableError as e:
    hit.reqLine = "ERROR: " & e.msg
  finally:
    server.close()
    arg.ch[].send(hit)

proc freePort(): int =
  var sock = newSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = sock.getLocalAddr()
  sock.close()
  port.int

proc waitListening(port: int) =
  ## Polls until the worker listens. The worker accepts exactly one
  ## connection, so readiness is probed without connecting: binding the
  ## port fails once a listener holds it.
  for _ in 0 ..< 200:
    var probe = newSocket()
    try:
      probe.setSockOpt(OptReuseAddr, true)
      probe.bindAddr(Port(port), "127.0.0.1")
      probe.close()
      sleep(10)
    except OSError:
      probe.close()
      return
  doAssert false, "capture server never listened on " & $port

proc capture(status: int; reply: string; echoAuth: bool;
             send: proc (base: string)): Captured =
  ## Runs `send` against a fresh capture server and returns what the
  ## server received. `send` may raise; the server is always joined.
  var ch: Channel[Captured]
  ch.open()
  let port = freePort()
  var thr: Thread[tuple[port, status: int; reply: string; echoAuth: bool;
    ch: ptr Channel[Captured]]]
  createThread(thr, captureWorker, (port, status, reply, echoAuth,
    addr ch))
  try:
    waitListening(port)
    send("http://127.0.0.1:" & $port)
  finally:
    result = ch.recv()
    joinThread(thr)
    ch.close()

proc headerOf(c: Captured; name: string): string =
  for (n, v) in c.headers:
    if n.toLowerAscii() == name.toLowerAscii():
      return v
  ""

# ------------------------------------------- the test's own form reader

type FormPart = object
  name, filename, contentType, value: string

proc dispositionParam(disp, param: string): string =
  let key = param & "=\""
  let at = disp.find(key)
  if at < 0:
    return ""
  let start = at + key.len
  disp[start ..< disp.find('"', start)]

proc parseForm(contentType, body: string): seq[FormPart] =
  ## RFC 7578 by hand: split on the boundary from the Content-Type, each
  ## part's headers from its value at the first blank line.
  let marker = "boundary="
  let at = contentType.find(marker)
  doAssert at >= 0, "no boundary in " & contentType
  let boundary = contentType[at + marker.len .. ^1].strip(chars = {'"'})
  let delim = "--" & boundary
  doAssert body.startsWith(delim & "\r\n")
  doAssert body.endsWith("\r\n" & delim & "--\r\n")
  let inner = body[delim.len + 2 ..< body.len - (delim.len + 6)]
  for blob in inner.split("\r\n" & delim & "\r\n"):
    let sep = blob.find("\r\n\r\n")
    doAssert sep >= 0, "form part without a header/value split"
    var part = FormPart(value: blob[sep + 4 .. ^1])
    for line in blob[0 ..< sep].split("\r\n"):
      let colon = line.find(':')
      let name = line[0 ..< colon].toLowerAscii()
      let value = line[colon + 1 .. ^1].strip()
      if name == "content-disposition":
        doAssert value.startsWith("form-data;")
        part.name = dispositionParam(value, "name")
        part.filename = dispositionParam(value, "filename")
      elif name == "content-type":
        part.contentType = value
    result.add(part)

proc values(form: seq[FormPart]; name: string): seq[string] =
  for p in form:
    if p.name == name:
      result.add(p.value)

# --------------------------------------- the test's own message reader

type Entity = ref object
  headers: seq[(string, string)]
  body: string
  children: seq[Entity]

proc hdr(e: Entity; name: string): string =
  for (n, v) in e.headers:
    if n.toLowerAscii() == name.toLowerAscii():
      return v
  ""

proc hdrCount(e: Entity; name: string): int =
  for (n, _) in e.headers:
    if n.toLowerAscii() == name.toLowerAscii():
      inc result

proc parseEntity(blob: string): Entity =
  let sep = blob.find("\r\n\r\n")
  doAssert sep >= 0, "entity without a header/body split"
  result = Entity(body: blob[sep + 4 .. ^1])
  for line in blob[0 ..< sep].split("\r\n"):
    if line.len > 0 and line[0] in {' ', '\t'}:
      result.headers[^1][1].add(" " & line.strip())
    else:
      let colon = line.find(':')
      doAssert colon > 0, "bad header line: " & line
      result.headers.add((line[0 ..< colon], line[colon + 1 .. ^1].strip()))
  let ct = result.hdr("Content-Type")
  if ct.toLowerAscii().startsWith("multipart/"):
    let at = ct.find("boundary=")
    var boundary = ct[at + 9 .. ^1]
    let semi = boundary.find(';')
    if semi >= 0:
      boundary = boundary[0 ..< semi]
    boundary = boundary.strip(chars = {'"', ' '})
    let delim = "--" & boundary
    var rest = result.body
    let first = rest.find(delim & "\r\n")
    doAssert first >= 0
    let close = rest.find("\r\n" & delim & "--")
    doAssert close >= 0
    rest = rest[first + delim.len + 2 ..< close]
    for child in rest.split("\r\n" & delim & "\r\n"):
      result.children.add(parseEntity(child))

proc walk(e: Entity; into: var seq[Entity]) =
  into.add(e)
  for c in e.children:
    walk(c, into)

proc decodeQp(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '=' and i + 2 < s.len and s[i + 1 .. i + 2] == "\r\n":
      i += 3
    elif s[i] == '=' and i + 2 < s.len:
      result.add(char(parseHexInt(s[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(s[i])
      inc i

proc decodeBody(e: Entity): string =
  case e.hdr("Content-Transfer-Encoding").toLowerAscii()
  of "base64": base64.decode(e.body.replace("\r\n", ""))
  of "quoted-printable": decodeQp(e.body)
  else: e.body

# ------------------------------------------------------- the message

const
  mgKey = "key-0123456789abcdef-secret"
  mgSeed = "t6mailgun"
  mgTokenUri = "https://example.com/u/opaque-token-0123456789"
  mgMailto = "mailto:unsub@example.com"
  mgAttach = "attachment line one\nline two héllo\n"

proc mailgunMessage(pngBytes: string): EmailMessage =
  let logo = loadAsset("logo.png", pngBytes)
  let html = "<p>Hello</p><p><img src=\"cid:" & contentIdFor(logo) &
    "\" alt=\"logo\"></p>"
  toMessage(
    RenderedEmail(html: html, text: "Hello plain.", assets: @[logo]),
    MessageHeaders(
      fromAddr: mailbox("Sender", "sender@example.com"),
      to: @[mailbox("Récipient", "to1@example.com"),
        mailbox("", "to2@example.com")],
      cc: @[mailbox("Copy", "cc@example.com")],
      bcc: @[mailbox("", "hidden@example.com")],
      replyTo: @[mailbox("Replies", "reply@example.com")],
      subject: "A complete message",
      messageId: "<t6-mailgun-1@example.com>",
      date: fromUnix(1780000000'i64),
      unsubscribe: some(Unsubscribe(httpsUri: mgTokenUri,
        mailto: mgMailto)),
      autoSubmitted: true,
      feedbackId: "campaign:list:sender",
      entityRefId: "entity-42",
      extra: @[("X-Campaign", "spring")]),
    isEmbedded,
    @[Attachment(filename: "notes.txt", mime: "text/plain",
      bytes: mgAttach)])

suite "mailgun transport":
  let pngBytes = readFile(testsDir / "fixtures" / "t6_rgb.png")
  let msg = mailgunMessage(pngBytes)
  let expected = toRfc5322(msg, mgSeed)

  test "the message part is exactly the toRfc5322 bytes":
    var id = ""
    let got = capture(200,
      """{"id":"<20260930.1@example.com>","message":"Queued. Thank you."}""",
      false,
      proc (base: string) =
        id = sendMailgun(msg, "example.com", mgKey, @["receipt", "v2"],
          deterministicSeed = mgSeed, apiBase = base))
    check id == "<20260930.1@example.com>"
    check got.reqLine == "POST /v3/example.com/messages.mime HTTP/1.1"
    check got.headerOf("Authorization") ==
      "Basic " & base64.encode("api:" & mgKey)
    let form = parseForm(got.headerOf("Content-Type"), got.body)

    # The message: one file part, byte for byte the library's bytes.
    let messages = form.values("message")
    check messages.len == 1
    check messages[0] == expected
    for p in form:
      if p.name == "message":
        check p.filename.len > 0
        check p.contentType == "message/rfc822"

    # Recipients: the envelope, To + Cc + Bcc, bare addresses, in order.
    check form.values("to") == @["to1@example.com", "to2@example.com",
      "cc@example.com", "hidden@example.com"]
    check form.values("o:tag") == @["receipt", "v2"]
    # Nothing else: no h: field, no o:dkim exclusion (R-SND-04).
    for p in form:
      check p.name in ["to", "o:tag", "message"]
      check not p.name.toLowerAscii().startsWith("o:dkim")
      check not p.name.toLowerAscii().startsWith("h:")

  test "the sent message carries every owned header, cc, reply-to, the attachment and the inline image":
    let got = capture(200, """{"id":"<x@example.com>"}""", false,
      proc (base: string) =
        discard sendMailgun(msg, "example.com", mgKey,
          deterministicSeed = mgSeed, apiBase = base))
    let form = parseForm(got.headerOf("Content-Type"), got.body)
    let sent = form.values("message")
    check sent.len == 1
    let root = parseEntity(sent[0])

    # R-SND-01: exactly one of each unsubscribe header, as built.
    check root.hdrCount("List-Unsubscribe") == 1
    check root.hdrCount("List-Unsubscribe-Post") == 1
    check root.hdr("List-Unsubscribe") ==
      "<" & mgTokenUri & ">, <" & mgMailto & ">"
    check root.hdr("List-Unsubscribe-Post") == "List-Unsubscribe=One-Click"
    check root.hdr("Auto-Submitted") == "auto-generated"
    check root.hdr("Feedback-ID") == "campaign:list:sender"
    check root.hdr("X-Entity-Ref-ID") == "entity-42"
    check root.hdr("X-Campaign") == "spring"
    check root.hdr("Message-ID") == "<t6-mailgun-1@example.com>"
    check root.hdr("Subject") == "A complete message"
    check root.hdr("From") == "Sender <sender@example.com>"
    check "to1@example.com" in root.hdr("To")
    check "to2@example.com" in root.hdr("To")
    check root.hdr("Cc") == "Copy <cc@example.com>"
    check root.hdr("Reply-To") == "Replies <reply@example.com>"
    # Bcc reaches Mailgun as a `to` field only, never as a header.
    check root.hdrCount("Bcc") == 0
    check "hidden@example.com" notin sent[0]

    # The tree: the attachment and the cid: image arrive decoded intact.
    check root.hdr("Content-Type").startsWith("multipart/mixed")
    var all: seq[Entity] = @[]
    walk(root, all)
    var attachment, image, html: Entity
    for e in all:
      let ct = e.hdr("Content-Type").toLowerAscii()
      if e.hdr("Content-Disposition").toLowerAscii().startsWith(
          "attachment"):
        attachment = e
      elif ct.startsWith("image/png"):
        image = e
      elif ct.startsWith("text/html"):
        html = e
    check attachment != nil
    check image != nil
    check html != nil
    if attachment != nil:
      check "notes.txt" in attachment.hdr("Content-Disposition")
      check decodeBody(attachment) == mgAttach
    if image != nil and html != nil:
      let cid = image.hdr("Content-ID")
      check cid.startsWith("<") and cid.endsWith(">")
      check decodeBody(image) == pngBytes
      check ("cid:" & cid[1 .. ^2]) in decodeBody(html)
      var related = false
      for e in all:
        if e.hdr("Content-Type").toLowerAscii().startsWith(
            "multipart/related") and image in e.children:
          related = true
      check related

  test "credentials stay out of errors":
    # A failing reply that echoes the Authorization header: the error
    # names the status, never the key or the token derived from it.
    var err = ""
    let got = capture(401, "Forbidden " & mgKey, true,
      proc (base: string) =
        try:
          discard sendMailgun(msg, "example.com", mgKey,
            apiBase = base)
        except MailgunError as e:
          err = e.msg)
    check got.reqLine.startsWith("POST ")
    check "401" in err
    check "<redacted>" in err
    check mgKey notin err
    check base64.encode("api:" & mgKey) notin err

    # A connection refused: the transport error is wrapped, key-free.
    let dead = freePort()
    try:
      discard sendMailgun(msg, "example.com", mgKey,
        apiBase = "http://127.0.0.1:" & $dead)
      check false
    except MailgunError as e:
      check "messages.mime" in e.msg
      check mgKey notin e.msg

    # No key: the error names the env var, and nothing is sent.
    let oldKey = getEnv(mailgunKeyEnv)
    try:
      delEnv(mailgunKeyEnv)
      try:
        discard sendMailgun(msg, "example.com", "")
        check false
      except MailgunError as e:
        check mailgunKeyEnv in e.msg
    finally:
      if oldKey.len > 0:
        putEnv(mailgunKeyEnv, oldKey)

  test "payload, region hosts and multipart encoding":
    let payload = mailgunPayload(msg, "example.com", @["a"],
      deterministicSeed = mgSeed)
    check payload.url ==
      "https://api.mailgun.net/v3/example.com/messages.mime"
    check payload.message == expected
    check mailgunPayload(msg, "example.com", region = "eu").url ==
      "https://api.eu.mailgun.net/v3/example.com/messages.mime"
    check mailgunPayload(msg, "example.com",
      apiBase = "http://127.0.0.1:9/").url ==
      "http://127.0.0.1:9/v3/example.com/messages.mime"
    try:
      discard mailgunApiBase("xx")
      check false
    except MailgunError as e:
      check "xx" in e.msg

    # No envelope recipient: refused before any I/O.
    var nobody = msg
    nobody.headers.to = @[]
    nobody.headers.cc = @[]
    nobody.headers.bcc = @[]
    try:
      discard mailgunPayload(nobody, "example.com")
      check false
    except MailgunError as e:
      check "recipients" in e.msg

    # Deterministic; repeated names kept; a boundary that occurs in the
    # message bytes is re-suffixed until it does not.
    let (ct1, body1) = payloadMultipart(payload)
    check payloadMultipart(payload) == (ct1, body1)
    check body1.count("name=\"to\"") == 4
    var colliding = payload
    colliding.message = "carries ----isonim-mailgun inside\r\n"
    let (ct3, body3) = payloadMultipart(colliding)
    check "----isonim-mailgunx" in ct3
    let form3 = parseForm(ct3, body3)
    check form3.values("message") == @[colliding.message]
    let boundary3 = ct3.rsplit("boundary=", maxsplit = 1)[1]
    check boundary3 notin body3.replace("--" & boundary3, "")
