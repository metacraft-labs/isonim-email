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
## Invalid header values, attachment filenames or media types, and
## invalid deterministic seeds raise `EmailRenderError` carrying
## `E-MIME-HEADER`; a hosted message that references an unpublished
## asset raises `E-ASSET-UNPUBLISHED` (R-IMG-07).
## Everything below error severity that `toMessage` finds rides on
## `EmailMessage.diagnostics`: a token-less unsubscribe URI is still
## emitted with `W-MIME-UNSUB-TOKEN` (R-SND-02 refuses by warning), and
## a rendered email without a plain-text part is sent as HTML alone
## with `I-TEXT-OMITTED` — an empty `text/plain` part is never sent.
##
## With `images = isEmbedded`, each asset the HTML references by its
## published URL is rewritten to `cid:<content-id>` (no angle
## brackets, R-MIME-11) and becomes one `multipart/related` part; an
## asset the HTML does not reference is not embedded, so no part is
## orphaned.
## Backend-independent: pure string code plus the facade clock.

import std/[options, random, strutils, times]
from nim_everywhere/platform import Clock, nowUnixMillis, systemClock
import ./model
import ./headers
import ../render
import ../assets
import ../diagnostics
import ../serialize
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

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
    ## image strategy, the file attachments, and the diagnostics
    ## `toMessage` produced (the render's own stay on `rendered`).
    ## `images = isEmbedded` embeds the referenced `rendered.assets`
    ## as `cid:` parts; `isHosted` leaves the HTML references alone.
    headers*: MessageHeaders
    rendered*: RenderedEmail
    images*: ImageStrategy
    attachments*: seq[Attachment]
    diagnostics*: seq[EmailDiagnostic]

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

const maxAddressLen* = 254
  ## Longest addr-spec: RFC 5321 §4.5.3.1.3 caps a path at 256 octets
  ## including the angle brackets.

proc validateMailbox*(m: Mailbox; field: string): seq[EmailDiagnostic] =
  ## `E-MIME-HEADER` when the address is not a bare addr-spec: it must
  ## contain `@` and stay ASCII (encoded-words never appear inside an
  ## addr-spec, R-MIME-10), and neither value may smuggle a header
  ## break.
  if hasHeaderInjection(m.address) or hasHeaderInjection(m.name):
    result.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
      message: "'" & field & "' mailbox must not contain CR or LF",
      rules: @["R-SND-01"]))
  elif m.address.len > maxAddressLen:
    result.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
      message: "'" & field & "' address is " & $m.address.len &
        " characters (at most " & $maxAddressLen & ", RFC 5321 §4.5.3.1.3)",
      rules: @["R-MIME-10"]))
  elif '@' notin m.address or ' ' in m.address or '\t' in m.address:
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
  ## `Name <addr>`, a bare addr-spec when the name is empty
  ## (R-MIME-10). The name travels as:
  ## - RFC 2047 `phrase` encoded-words when `headerTextNeedsEncoding`
  ##   says so (non-ASCII, control characters, an `=?` look-alike, edge
  ##   whitespace, an overlong word);
  ## - a quoted-string when it holds specials or a whitespace run (a
  ##   phrase's inter-word whitespace is folding whitespace, which
  ##   parsers collapse; a quoted-string keeps it);
  ## - atoms otherwise.
  ## Emits as given — the caller validates with `validateMailbox` (the
  ## headers.nim `unsubscribeHeaders` contract).
  if m.name.len == 0:
    return m.address
  if headerTextNeedsEncoding(m.name):
    return encodeHeaderText(m.name, phrase = true) & " <" & m.address &
      ">"
  var needsQuotes = "  " in m.name
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
  ## Prepares a plain-text part for `format=flowed` (RFC 3676, R-MIME-06).
  ## Every line of the input ends in a hard break, so:
  ## - trailing spaces are trimmed (§4.2 "trim spaces before
  ##   user-inserted hard line breaks": a line ending in a space is a
  ##   *flowed* line, and the receiver would join it to the next);
  ##   the signature separator `-- ` is sent as-is (§4.3);
  ## - a line starting with a space, `>`, or `From ` gains one leading
  ##   space (§4.4 space-stuffing), which a flowed receiver removes.
  ## Lines split on LF (a trailing CR per line is stripped); the
  ## trailing-newline shape of the input is preserved.
  if text.len == 0:
    return ""
  var lines: seq[string] = @[]
  for rawLine in text.splitLines():
    var line = rawLine
    if line.endsWith('\r'):
      line.setLen(line.len - 1)
    if line != "-- ":
      var keep = line.len
      while keep > 0 and line[keep - 1] == ' ':
        dec keep
      line.setLen(keep)
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

const maxMessageIdLen* = 900
  ## Longest supplied Message-ID: a msg-id cannot fold, so it must fit
  ## RFC 5322's 998-character line on its own.

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
    if hasHeaderInjection(h.messageId) or '@' notin h.messageId or
        h.messageId.len > maxMessageIdLen or ' ' in h.messageId or
        '\t' in h.messageId:
      mimeError("Message-ID '" & h.messageId.escape("", "") &
        "' must be <id@domain> without whitespace, at most " &
        $maxMessageIdLen & " characters (R-MIME-12)")
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

const maxSeedLen* = 40
  ## Longest deterministic seed: the seed is the Message-ID's first
  ## dot-atom and the seeded boundary's readable part.

proc isValidSeed*(seed: string): bool =
  ## A seed is a dot-atom of letters, digits, `-` and `_` (1–40 chars,
  ## no leading, trailing or doubled dot), so the derived Message-ID
  ## `<seed.hex@domain>` is a valid RFC 5322 msg-id and the derived
  ## boundary a valid RFC 2046 boundary.
  if seed.len == 0 or seed.len > maxSeedLen:
    return false
  if seed[0] == '.' or seed[^1] == '.' or ".." in seed:
    return false
  for c in seed:
    if not (c.isAlphaNumeric() or c in {'-', '_', '.'}):
      return false
  true

proc checkSeed(seed: string) =
  ## `E-MIME-HEADER` for a seed that cannot derive valid headers.
  if seed.len > 0 and not isValidSeed(seed):
    mimeError("deterministic seed '" & seed & "' must be 1-" &
      $maxSeedLen & " letters, digits, '-', '_' or single inner dots " &
      "(it becomes the Message-ID's local part and the boundary's tag)")

proc checkFilename(filename, what: string) =
  ## `E-MIME-HEADER` for a filename that is empty or carries a control
  ## character (CR and LF included: a header break must never be
  ## smuggled into `Content-Type`/`Content-Disposition`).
  if filename.len == 0:
    mimeError(what & " filename must not be empty")
  for c in filename:
    if c.byte < 32 or c.byte == 127:
      mimeError(what & " filename '" & filename.escape() &
        "' must not contain CR, LF or other control characters")

proc checkMediaType(mime, what: string) =
  ## `E-MIME-HEADER` unless `mime` is a bare `type/subtype` of RFC 2045
  ## token characters.
  let slash = mime.find('/')
  var ok = slash > 0 and slash < mime.len - 1 and
    mime.count('/') == 1
  if ok:
    for c in mime:
      if c != '/' and not (c.isAlphaNumeric() or
          c in {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
            '_', '`', '{', '|', '}', '~'}):
        ok = false
  if not ok:
    mimeError(what & " media type '" & mime.escape() &
      "' must be a bare type/subtype")

proc checkAttachments(attachments: seq[Attachment]) =
  for att in attachments:
    checkFilename(att.filename, "attachment")
    checkMediaType(att.mime, "attachment '" & att.filename & "'")

proc checkPublished(r: RenderedEmail; images: ImageStrategy) =
  ## R-IMG-07: a hosted message may only reference published assets.
  ## `rendered.assets` lists what the HTML references; an empty `url`
  ## means the upload never completed, so the message would send a
  ## reference to an image that is not (yet) there.
  if images != isHosted:
    return
  for a in r.assets:
    if a.url.len == 0:
      raise newException(EmailRenderError, codeAssetUnpublished &
        ": asset '" & a.name & "' is referenced but was never " &
        "published; render with an AssetStore so the upload completes " &
        "before the message is built (R-IMG-07)")

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
  # Errors are impossible here: checkHeaders raised on them above.
  # The token warning is `toMessage`'s to report, on
  # `EmailMessage.diagnostics`; serialising does not repeat it.
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

proc cidRef(a: AssetRef): string =
  ## The `src` attribute that references `a` as an embedded part.
  "src=\"" & cidUrl(contentIdFor(a)) & "\""

proc embeddedHtml(html: string; assets: seq[AssetRef]): tuple[
    html: string; inline: seq[AssetRef]] =
  ## The embedded strategy's HTML and parts. Every `src` that carries
  ## an asset's published URL becomes `cid:<content-id>` — the
  ## Content-ID value without angle brackets (R-MIME-11) — and only
  ## assets the HTML then references become parts, each once.
  ## Idempotent: a second pass finds no URL left to rewrite. An asset
  ## without bytes (a hand-built record) cannot be embedded and raises
  ## `E-ASSET-UNKNOWN` — the store resolves bytes.
  result = (html, @[])
  for a in assets:
    if a.bytes.len == 0 or a.sha256.len < 16:
      raise newException(EmailRenderError,
        "E-ASSET-UNKNOWN: cannot embed asset '" & a.name &
          "' without bytes (resolve it through an AssetStore first)")
  for a in assets:
    if a.url.len > 0:
      result.html = result.html.replace(
        "src=\"" & escapeEmailAttr(a.url) & "\"", cidRef(a))
  for a in assets:
    if cidRef(a) notin result.html:
      continue
    var listed = false
    for known in result.inline:
      if contentIdFor(known) == contentIdFor(a):
        listed = true
    if not listed:
      result.inline.add(a)

proc bodyParts(m: EmailMessage): tuple[html: string; inline: seq[AssetRef]] =
  ## The HTML as sent plus the parts to embed: rewritten for the
  ## embedded strategy, untouched (and nothing inline) for hosted.
  if m.images == isEmbedded:
    embeddedHtml(m.rendered.html, m.rendered.assets)
  else:
    (m.rendered.html, @[])

proc wireRoot(m: EmailMessage; seed: string): MimePart =
  ## The entity tree: `alternative[plain, related[html, images]]`
  ## under `mixed` only with attachments (R-MIME-01/02/03). Without a
  ## plain-text part the HTML (or its `related` wrapper) stands alone:
  ## an empty `text/plain` part is never sent.
  let src =
    if seed.len > 0: seededBoundarySource(seed)
    else: defaultBoundarySource
  let body = bodyParts(m)
  for a in body.inline:
    checkFilename(assetBaseName(a.name), "embedded image")
  let htmlPart = textPart("text/html", body.html)
  let htmlOrRelated =
    if body.inline.len > 0:
      newRelated(htmlPart, embedAssets(body.inline), src, "rel")
    else:
      htmlPart
  let alt =
    if m.rendered.text.len == 0:
      htmlOrRelated
    else:
      newAlternative(textPart("text/plain",
        spaceStuffFlowed(m.rendered.text), flowed = true),
        htmlOrRelated, src, "alt")
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
  ##
  ## Non-error findings land on `diagnostics`: `W-MIME-UNSUB-TOKEN`
  ## for an unsubscribe URI without an opaque token (R-SND-02), and
  ## `I-TEXT-OMITTED` when `r.text` is empty (the message then carries
  ## the HTML alone). With `images = isEmbedded` the stored
  ## `rendered.html` already references its images as `cid:`.
  ##
  ## Attachments are validated too (`E-MIME-HEADER` for an empty
  ## filename, one with CR, LF or another control character, or a
  ## media type that is not a bare `type/subtype`), and a hosted
  ## message whose `rendered.assets` holds an unpublished asset raises
  ## `E-ASSET-UNPUBLISHED` (R-IMG-07: the upload completes before the
  ## message exists).
  let checked = checkHeaders(headers, systemClock())
  checkAttachments(attachments)
  checkPublished(r, images)
  var diags: seq[EmailDiagnostic] = @[]
  if checked.unsubscribe.isSome:
    for d in validateUnsubscribe(checked.unsubscribe.get()):
      if d.severity != sevError:
        diags.add(d)
  if r.text.len == 0:
    diags.add(EmailDiagnostic(severity: sevInfo, code: codeTextOmitted,
      message: "no plain-text part: the message is sent as text/html " &
        "only (an empty text/plain part is never sent)"))
  var rendered = r
  if images == isEmbedded:
    rendered.html = embeddedHtml(r.html, r.assets).html
    rendered.htmlBytes = rendered.html.len
  EmailMessage(headers: checked, rendered: rendered, images: images,
    attachments: attachments, diagnostics: diags)

proc toRfc5322*(m: EmailMessage; deterministicSeed = ""): string =
  ## The complete bytes, ready for SMTP or ESP "raw" APIs. A
  ## non-empty seed derives the boundaries and a missing Message-ID
  ## (tests); without one both are random. A seed outside
  ## `isValidSeed` (it would derive an invalid Message-ID) raises
  ## `E-MIME-HEADER`, as do the attachment and header checks
  ## `toMessage` runs, re-run here for hand-built messages, and a
  ## hosted reference to an unpublished asset raises
  ## `E-ASSET-UNPUBLISHED` (R-IMG-07).
  checkSeed(deterministicSeed)
  checkAttachments(m.attachments)
  checkPublished(m.rendered, m.images)
  try:
    serializeMessage(newMessage(wireHeaders(m, deterministicSeed),
      wireRoot(m, deterministicSeed)))
  except BoundaryError as e:
    mimeError(e.msg)

proc toParts*(m: EmailMessage): tuple[html, text: string;
    headers: seq[(string, string)]; inline: seq[AssetRef]] =
  ## The decoded fields for ESP APIs that take fields: the html as
  ## sent (with `cid:` references under the embedded strategy) and
  ## the text (`""` when there is no plain-text part — a transport
  ## omits the field rather than send it empty), the wire headers as
  ## pairs (a missing Message-ID is omitted — only `toRfc5322`
  ## generates one), and the embedded images (the referenced assets
  ## under `isEmbedded`, else none).
  checkPublished(m.rendered, m.images)
  var heads: seq[(string, string)] = @[]
  for h in wireHeaders(m, ""):
    if h.name == "Message-ID" and m.headers.messageId.len == 0:
      continue
    heads.add((h.name, h.value))
  let body = bodyParts(m)
  (body.html, m.rendered.text, heads, body.inline)

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
