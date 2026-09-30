## isonim_email/mime/message.nim — message assembly.
##
## `toMessage` binds a rendered email to its headers, `toRfc5322`
## serialises the result to wire bytes, and `toParts` hands the decoded
## fields to ESP field APIs. The tree over the `model` builders is the
## same one the MIME rules pin down (`multipart/mixed` only with
## attachments, `multipart/alternative` plain-first per RFC 2046
## §5.1.4, `multipart/related` with mandatory `type` per RFC 2387
## §3.1), with `Date` (via the nim-everywhere time facade),
## `Message-ID` and `MIME-Version` (R-MIME-12), RFC 2047 display names
## (R-MIME-10), flowed space-stuffing (R-MIME-06) and the R-SND-04 DKIM
## metadata.
##
## Invalid header values raise `EmailRenderError` carrying `E-MIME-HEADER`
## — the contract returns the message, not diagnostics, so there is
## nothing to collect into. A token-less unsubscribe URI is still
## emitted; `validateUnsubscribe` reports the R-SND-02 warning for
## callers that want it.
## Backend-independent: pure string code plus the facade clock.

import std/[options, random, strutils, times]
from nim_everywhere/platform import Clock, nowUnixMillis, systemClock
import ./model
import ./headers
import ../render
import ../assets
import ../diagnostics

type
  Mailbox* = object
    ## A display name plus a bare addr-spec.
    name*, address*: string

  MessageHeaders* = object
    ## The sender-facing headers. `messageId` "" means generated (at
    ## `toRfc5322` time, so a seed can derive it); a zero `date` reads
    ## the facade clock at `toMessage` time.
    fromAddr*: Mailbox
    to*, cc*, bcc*: seq[Mailbox]
    replyTo*: seq[Mailbox]
    subject*: string
    messageId*: string
    date*: Time
    unsubscribe*: Option[Unsubscribe]
    autoSubmitted*: bool
    feedbackId*, entityRefId*: string
    extra*: seq[(string, string)]

  EmailMessage* = object
    ## One email ready to send: headers plus the rendered email, the
    ## image strategy, and the file attachments. `images = isEmbedded`
    ## embeds `rendered.assets` as `cid:` parts; `isHosted` leaves the
    ## HTML references alone.
    headers*: MessageHeaders
    rendered*: RenderedEmail
    images*: ImageStrategy
    attachments*: seq[Attachment]

proc mailbox*(name, address: string): Mailbox =
  ## A display name plus a bare addr-spec.
  Mailbox(name: name, address: address)

# ------------------------------------------------------------------ date

const
  dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
    "Sep", "Oct", "Nov", "Dec"]

proc two(n: int | int64): string =
  if n < 10: "0" & $n
  else: $n

proc rfc5322Date*(unixMillis: int64): string =
  ## RFC 5322 §3.3 date-time in UTC: `Thu, 28 May 2026 20:26:40
  ## +0000` (R-MIME-12). A manual days→civil conversion (Howard
  ## Hinnant's algorithm), so the C and JS backends agree byte for
  ## byte without touching local timezones.
  var unixSecs = unixMillis div 1000
  if unixMillis < 0 and unixMillis mod 1000 != 0:
    dec unixSecs # floor, not truncate
  var days = unixSecs div 86400
  var rem = unixSecs mod 86400
  if rem < 0:
    rem += 86400
    dec days
  let hh = rem div 3600
  let mm = (rem mod 3600) div 60
  let ss = rem mod 60
  let z = days + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  var y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = mp + (if mp < 10: 3 else: -9)
  if m <= 2:
    inc y
  let wday = ((days + 4) mod 7 + 7) mod 7 # 1970-01-01 was a Thursday
  dayNames[wday] & ", " & two(d) & " " & monthNames[m - 1] & " " & $y &
    " " & two(hh) & ":" & two(mm) & ":" & two(ss) & " +0000"

# ----------------------------------------------------------- mailboxes

const mailboxSpecials = {'(', ')', '<', '>', '[', ']', ':', ';', '@',
  '\\', ',', '.', '"'}

proc validateMailbox*(m: Mailbox; field: string): seq[EmailDiagnostic] =
  ## `E-MIME-HEADER` when the address is not a bare addr-spec: it must
  ## contain `@` and stay ASCII (encoded-words never appear inside an
  ## addr-spec, R-MIME-10), and neither value may smuggle a header
  ## break.
  if hasHeaderInjection(m.address) or hasHeaderInjection(m.name):
    result.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
      message: "'" & field & "' mailbox must not contain CR or LF",
      rules: @["R-SND-01"]))
  elif '@' notin m.address:
    result.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
      message: "'" & field & "' address '" & m.address &
        "' is not an addr-spec (R-MIME-10)",
      rules: @["R-MIME-10"]))
  else:
    for c in m.address:
      if c.byte > 126:
        result.add(EmailDiagnostic(severity: sevError,
          code: codeMimeHeader,
          message: "'" & field & "' address must be ASCII " &
            "(encoded-words never appear inside an addr-spec, " &
            "R-MIME-10)",
          rules: @["R-MIME-10"]))
        break

proc formatMailbox*(m: Mailbox): string =
  ## `Name <addr>`, with quoting when the name needs it and RFC 2047
  ## `phrase` encoded-words when it is not ASCII (R-MIME-10); a bare
  ## addr-spec when the name is empty. Emits as given — the caller
  ## validates with `validateMailbox` (the headers.nim
  ## `unsubscribeHeaders` contract).
  if m.name.len == 0:
    return m.address
  var needsEncoding = false
  for c in m.name:
    if c.byte > 126 or c.byte < 32:
      needsEncoding = true
      break
  if needsEncoding:
    return encodeHeaderText(m.name, phrase = true) & " <" & m.address &
      ">"
  var needsQuotes = m.name[0] == ' ' or m.name[^1] == ' '
  if not needsQuotes:
    for c in m.name:
      if c in mailboxSpecials:
        needsQuotes = true
        break
  if not needsQuotes:
    return m.name & " <" & m.address & ">"
  var quoted = "\""
  for c in m.name:
    if c in {'\\', '"'}:
      quoted.add('\\')
    quoted.add(c)
  quoted.add("\" <" & m.address & ">")
  quoted

# ------------------------------------------------------------- assembly

proc spaceStuffFlowed*(text: string): string =
  ## RFC 3676 §4.4 space-stuffing (R-MIME-06): a line starting with a
  ## space, `>`, or `From ` gains one leading space, so a flowed
  ## receiver's unstuffing restores the original bytes. Lines split on
  ## LF (a trailing CR per line is stripped); the trailing-newline
  ## shape of the input is preserved.
  if text.len == 0:
    return ""
  var lines: seq[string] = @[]
  for rawLine in text.splitLines():
    var line = rawLine
    if line.endsWith('\r'):
      line.setLen(line.len - 1)
    if line.len > 0 and (line[0] == ' ' or line[0] == '>' or
        line.startsWith("From ")):
      line = " " & line
    lines.add(line)
  lines.join("\n")

var messageRandomized = false

proc randomHex(n: int): string =
  if not messageRandomized:
    randomize()
    messageRandomized = true
  const digits = "0123456789abcdef"
  result = newStringOfCap(n)
  for _ in 0 ..< n:
    result.add(digits[rand(15)])

proc domainOf(address: string): string =
  let at = address.rfind('@')
  if at >= 0 and at + 1 < address.len:
    address[at + 1 .. ^1]
  else:
    ""

proc mimeError(message: string) {.noreturn.} =
  raise newException(EmailRenderError, codeMimeHeader & ": " & message)

proc checkMailbox(m: Mailbox; field: string) =
  let found = validateMailbox(m, field)
  if hasErrors(found):
    raiseDiagnostic(found[0])

proc checkHeaders(h: MessageHeaders; clock: Clock): MessageHeaders =
  ## Validates every header value, raising `E-MIME-HEADER` on the
  ## first invalid one, and normalises: `messageId` gains `<>`, a zero
  ## `date` resolves through `clock`. Idempotent, so `toRfc5322`
  ## re-runs it over stored headers (a hand-built message gets the
  ## same gate as one built by `toMessage`).
  result = h
  checkMailbox(h.fromAddr, "From")
  for m in h.to:
    checkMailbox(m, "To")
  for m in h.cc:
    checkMailbox(m, "Cc")
  for m in h.bcc:
    checkMailbox(m, "Bcc")
  for m in h.replyTo:
    checkMailbox(m, "Reply-To")
  if hasHeaderInjection(h.subject):
    mimeError("Subject must not contain CR or LF")
  if h.messageId.len > 0:
    if hasHeaderInjection(h.messageId) or '@' notin h.messageId:
      mimeError("Message-ID '" & h.messageId &
        "' must be <id@domain> without CR or LF (R-MIME-12)")
    if h.messageId.startsWith("<") and h.messageId.endsWith(">"):
      result.messageId = h.messageId
    else:
      result.messageId = "<" & h.messageId & ">"
  if h.unsubscribe.isSome:
    for d in validateUnsubscribe(h.unsubscribe.get()):
      if d.severity == sevError:
        raiseDiagnostic(d)
  for (name, value) in h.extra:
    if name.len == 0 or hasHeaderInjection(name) or ':' in name or
        hasHeaderInjection(value):
      mimeError("extra header '" & name & "' must not contain CR, " &
        "LF or ':'")
  if h.date == fromUnix(0):
    result.date = fromUnix(nowUnixMillis(clock) div 1000)

proc messageIdFor(headers: MessageHeaders; seed: string): string =
  ## The stored id, or a generated `<id@sender-domain>` (R-MIME-12):
  ## derived from the seed under test, random otherwise. The seeded
  ## shape is `<seed.hex@domain>`, the boundary source's sibling.
  if headers.messageId.len > 0:
    return headers.messageId
  var domain = domainOf(headers.fromAddr.address)
  if domain.len == 0:
    domain = "localhost"
  let idPart =
    if seed.len > 0: seed & "." & sha256Hex(seed & ":" & domain)[0 ..< 16]
    else: randomHex(16)
  "<" & idPart & "@" & domain & ">"

proc addressHeader(boxes: seq[Mailbox]): string =
  ## One address list, formatted and joined. Validated by
  ## `checkHeaders` before this runs, so formatting cannot fail.
  var parts: seq[string] = @[]
  for m in boxes:
    parts.add(formatMailbox(m))
  parts.join(", ")

proc wireHeaders(m: EmailMessage; seed: string): seq[MimeHeader] =
  ## The message headers in wire order: version, Date, addresses,
  ## Subject, Message-ID, the owned headers, then extras. The
  ## multipart Content-Type rides last (the serialiser appends it).
  let h = checkHeaders(m.headers, systemClock())
  result = @[
    header("MIME-Version", "1.0"),
    header("Date", rfc5322Date(h.date.toUnix * 1000)),
    header("From", formatMailbox(h.fromAddr)),
  ]
  let toHeader = addressHeader(h.to)
  if toHeader.len > 0:
    result.add(header("To", toHeader))
  let ccHeader = addressHeader(h.cc)
  if ccHeader.len > 0:
    result.add(header("Cc", ccHeader))
  let replyHeader = addressHeader(h.replyTo)
  if replyHeader.len > 0:
    result.add(header("Reply-To", replyHeader))
  if h.subject.len > 0:
    result.add(header("Subject", encodeHeaderText(h.subject)))
  result.add(header("Message-ID", messageIdFor(h, seed)))
  let owned = ownedHeaders(unsubscribe = h.unsubscribe,
    autoSubmitted = h.autoSubmitted, feedbackId = h.feedbackId,
    entityRefId = h.entityRefId)
  # Errors are impossible here: checkHeaders raised on them above, so
  # only the token warning can ride along, and it has no channel on
  # this return path (see the module comment).
  result.add(owned.headers)
  for (name, value) in h.extra:
    result.add(header(name, value))

proc embedAssets(assets: seq[AssetRef]): seq[MimePart] =
  ## The `cid:` parts for the embedded strategy. An asset without
  ## bytes cannot be embedded — the store resolves bytes, so this only
  ## fires on hand-built records.
  for a in assets:
    if a.bytes.len == 0:
      raise newException(EmailRenderError,
        "E-ASSET-UNKNOWN: cannot embed asset '" & a.name &
          "' without bytes (resolve it through an AssetStore first)")
    result.add(imagePart(InlineImage(
      contentId: contentIdFor(a), contentType: a.mime,
      filename: assetBaseName(a.name), data: a.bytes)))

proc wireRoot(m: EmailMessage; seed: string): MimePart =
  ## The entity tree: `alternative[plain, related[html, images]]`
  ## under `mixed` only with attachments (R-MIME-01/02/03).
  let src =
    if seed.len > 0: seededBoundarySource(seed)
    else: defaultBoundarySource
  let plain = textPart("text/plain", spaceStuffFlowed(m.rendered.text),
    flowed = true)
  let htmlPart = textPart("text/html", m.rendered.html)
  let htmlOrRelated =
    if m.images == isEmbedded and m.rendered.assets.len > 0:
      newRelated(htmlPart, embedAssets(m.rendered.assets), src, "rel")
    else:
      htmlPart
  let alt = newAlternative(plain, htmlOrRelated, src, "alt")
  if m.attachments.len == 0:
    return alt
  var attParts: seq[MimePart] = @[]
  for att in m.attachments:
    attParts.add(attachmentPart(att))
  newMixed(alt, attParts, src, "mix")

proc toMessage*(r: RenderedEmail; headers: MessageHeaders;
                images = isHosted;
                attachments: seq[Attachment] = @[]): EmailMessage =
  ## Binds a rendered email to its headers. Every value is validated
  ## up front (`E-MIME-HEADER` on the first invalid one); the stored
  ## headers are the normalised form. Bcc validates but is never
  ## emitted — the envelope carries it.
  let checked = checkHeaders(headers, systemClock())
  EmailMessage(headers: checked, rendered: r, images: images,
    attachments: attachments)

proc toRfc5322*(m: EmailMessage; deterministicSeed = ""): string =
  ## The complete bytes, ready for SMTP or ESP "raw" APIs. A
  ## non-empty seed derives the boundaries and a missing Message-ID
  ## (tests); without one both are random. Seeds are test tags — keep
  ## them to letters, digits and dots so the derived Message-ID stays
  ## a valid msg-id.
  serializeMessage(newMessage(wireHeaders(m, deterministicSeed),
    wireRoot(m, deterministicSeed)))

proc toParts*(m: EmailMessage): tuple[html, text: string;
    headers: seq[(string, string)]; inline: seq[AssetRef]] =
  ## The decoded fields for ESP APIs that take fields: the original
  ## html+text, the wire headers as pairs (a missing Message-ID is
  ## omitted — only `toRfc5322` generates one), and the embedded
  ## images (empty unless the strategy is `isEmbedded`).
  var heads: seq[(string, string)] = @[]
  for h in wireHeaders(m, ""):
    if h.name == "Message-ID" and m.headers.messageId.len == 0:
      continue
    heads.add((h.name, h.value))
  let inline =
    if m.images == isEmbedded: m.rendered.assets
    else: @[]
  (m.rendered.html, m.rendered.text, heads, inline)

proc envelopeFrom*(m: EmailMessage): string =
  ## The SMTP envelope sender: the From address.
  m.headers.fromAddr.address

proc envelopeTo*(m: EmailMessage): seq[string] =
  ## The SMTP envelope recipients: To plus Cc plus Bcc, bare
  ## addresses. Bcc stays out of the headers exactly as it stays out
  ## of the payload's visible fields.
  for mbox in m.headers.to & m.headers.cc & m.headers.bcc:
    result.add(mbox.address)

proc dkimHeaders*(m: EmailMessage): seq[string] =
  ## The headers a DKIM signature must cover (R-SND-04): the
  ## unsubscribe pair when the message carries one, else nothing.
  if m.headers.unsubscribe.isSome:
    @["List-Unsubscribe", "List-Unsubscribe-Post"]
  else:
    @[]
