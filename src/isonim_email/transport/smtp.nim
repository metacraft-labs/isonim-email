## isonim_email/transport/smtp.nim — generic SMTP relay.
##
## A deliberately thin raw RFC 5321 client over `std/net`: EHLO,
## STARTTLS, AUTH PLAIN, MAIL/RCPT/DATA with dot-stuffing, QUIT. (Nim
## 2.2's stdlib has no smtp module, so the transports speak the
## protocol directly instead of wrapping it.) Reply codes are checked
## at every step; anything unexpected raises `SmtpError` naming the
## step and the reply.
##
## C backend only: sockets. `tls = true` additionally needs `-d:ssl`.

import std/[base64, net, strutils]
import ../mime/message

export message

type SmtpError* = object of CatchableError
  ## A transport failure: connect, TLS, auth, or an unexpected reply.

const smtpTimeoutMs* = 10_000
  ## Per-read socket timeout for the whole dialogue.

proc dotStuff*(data: string): string =
  ## RFC 5321 §4.5.2 transparency: a line starting with `.` gains one
  ## more. Our encoders never emit one (R-MIME-07; base64 has no dot),
  ## but the transport guarantees it regardless of the payload.
  if data.len == 0:
    return ""
  result = newStringOfCap(data.len + 16)
  var atLineStart = true
  var i = 0
  while i < data.len:
    if atLineStart and data[i] == '.':
      result.add('.')
    if data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n':
      result.add("\r\n")
      i += 2
      atLineStart = true
    elif data[i] == '\n':
      result.add("\r\n")
      inc i
      atLineStart = true
    else:
      result.add(data[i])
      inc i
      atLineStart = false

proc readReply(sock: Socket): tuple[code: int; text: string] =
  ## One (possibly multiline) reply: `DDD-…` continuations until the
  ## `DDD …` final line (RFC 5321 §4.2).
  var text = ""
  var code = 0
  while true:
    let line = sock.recvLine(timeout = smtpTimeoutMs)
    var numeric = line.len >= 4
    if numeric:
      for c in line[0 ..< 3]:
        if c notin {'0' .. '9'}:
          numeric = false
    if not numeric:
      raise newException(SmtpError,
        "SMTP: malformed reply line '" & line & "'")
    code = parseInt(line[0 ..< 3])
    if text.len > 0:
      text.add("\n")
    text.add(line)
    if line[3] == ' ':
      return (code, text)
    elif line[3] != '-':
      raise newException(SmtpError,
        "SMTP: malformed reply line '" & line & "'")

proc expect(sock: Socket; want: openArray[int]; step: string): string =
  ## Reads one reply, raising `SmtpError` unless its code is wanted.
  let (code, text) = readReply(sock)
  if code notin want:
    var wantStr = ""
    for i, w in want:
      if i > 0:
        wantStr.add("/")
      wantStr.add($w)
    raise newException(SmtpError,
      "SMTP " & step & ": expected " & wantStr & ", got '" & text & "'")
  text

proc sendLine(sock: Socket; line: string) =
  sock.send(line & "\r\n")

proc smtpInject*(host: string; port: int; envelopeFrom: string;
                envelopeTo: seq[string]; data: string; user = "";
                password = ""; tls = false) =
  ## Injects one message: greeting, EHLO, optional STARTTLS + AUTH
  ## PLAIN, MAIL/RCPT/DATA, QUIT. `user == ""` skips auth (the
  ## Mailpit shape); `tls` needs `-d:ssl` at build time.
  if envelopeTo.len == 0:
    raise newException(SmtpError,
      "SMTP: no envelope recipients (To/Cc/Bcc are all empty)")
  var sock = newSocket()
  try:
    try:
      sock.connect(host, Port(port), timeout = smtpTimeoutMs)
    except OSError as e:
      raise newException(SmtpError,
        "SMTP: cannot connect to " & host & ":" & $port & ": " & e.msg)
    discard expect(sock, [220], "greeting")
    sock.sendLine("EHLO isonim-email")
    discard expect(sock, [250], "EHLO")
    if tls:
      when defined(ssl):
        sock.sendLine("STARTTLS")
        discard expect(sock, [220], "STARTTLS")
        let ctx = newContext()
        wrapConnectedSocket(ctx, sock, handshakeAsClient, host)
        sock.sendLine("EHLO isonim-email")
        discard expect(sock, [250], "EHLO after STARTTLS")
      else:
        raise newException(SmtpError,
          "SMTP: tls = true needs -d:ssl at build time")
    if user.len > 0:
      let token = base64.encode("\0" & user & "\0" & password)
      sock.sendLine("AUTH PLAIN " & token)
      discard expect(sock, [235], "AUTH PLAIN")
    sock.sendLine("MAIL FROM:<" & envelopeFrom & ">")
    discard expect(sock, [250], "MAIL FROM")
    for rcpt in envelopeTo:
      sock.sendLine("RCPT TO:<" & rcpt & ">")
      discard expect(sock, [250, 251], "RCPT TO")
    sock.sendLine("DATA")
    discard expect(sock, [354], "DATA")
    sock.send(dotStuff(data))
    if not data.endsWith("\r\n") and not data.endsWith("\n"):
      sock.send("\r\n")
    sock.send(".\r\n")
    discard expect(sock, [250], "message body")
    sock.sendLine("QUIT")
    discard expect(sock, [221], "QUIT")
  finally:
    sock.close()

proc sendSmtp*(m: EmailMessage; host: string; port: int;
              user, password: string; tls = true;
              deterministicSeed = "") =
  ## Relays one message through a generic SMTP server (auth + TLS by
  ## default). A non-empty `deterministicSeed` derives the boundaries
  ## and a missing Message-ID, so the round-trip test can compare
  ## bytes.
  smtpInject(host, port, m.envelopeFrom, m.envelopeTo,
    toRfc5322(m, deterministicSeed), user, password, tls)
