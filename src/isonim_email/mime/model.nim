## isonim_email/mime/model.nim — message model and multipart builders.
##
## Builds the message tree (`multipart/mixed` only with attachments,
## `multipart/alternative` plain-first per RFC 2046 §5.1.4,
## `multipart/related` with mandatory `type` per RFC 2387 §3.1) and
## serialises it with CRLF line endings (R-MIME-13). Boundaries come
## from an injectable `BoundarySource` — fixed under test, random
## otherwise — and are verified absent from every part body
## (RFC 2046 §5.1.1; R-MIME-04).
## Backend-independent: pure string code, runs on C and JS.

import std/[random, strutils]
import ./encode
import ../assets

export encode

const maxBoundaryLen* = 70
  ## RFC 2046 §5.1.1: at most 70 chars, not counting `--`.

type
  MimeHeader* = object
    ## One header field; serialised folded (R-MIME-08).
    name*: string
    value*: string

  BoundarySource* = proc (salt: string): string {.closure.}
    ## Produces a candidate multipart boundary. `salt` distinguishes
    ## sibling multiparts (`"alt"`, `"rel"`, `"mix"`). Tests inject a
    ## fixed source; production uses `defaultBoundarySource`.

  MimePartKind* = enum
    mpkSingle, mpkMultipart

  MimePart* = ref object
    ## A MIME entity: headers plus either an encoded body or children.
    headers*: seq[MimeHeader]
    case kind*: MimePartKind
    of mpkSingle:
      body*: string ## Already transfer-encoded (QP/base64) bytes.
    of mpkMultipart:
      subtype*: string ## `alternative` | `related` | `mixed`.
      boundary*: string
      typeParam*: string ## `related` root type (`text/html`); else "".
      children*: seq[MimePart]

  InlineImage* = object
    ## A `cid:`-referenced image (R-MIME-11): `contentId` is the bare
    ## id (no brackets); the header carries `<…>` per RFC 2392.
    contentId*: string
    contentType*: string
    filename*: string
    data*: string ## Raw bytes; base64-encoded by `imagePart`.

  Attachment* = object
    ## One file attachment: name, media type and raw bytes (base64-encoded
    ## by `attachmentPart`).
    filename*, mime*: string
    bytes*: string

  MimeMessage* = object
    ## Top-level message: headers plus the root entity. Named for the
    ## MIME level on purpose — `message.EmailMessage` (headers plus the
    ## rendered email) is the sender-facing handle, and this is the
    ## wire form `toRfc5322` derives from it.
    headers*: seq[MimeHeader]
    root*: MimePart

proc isBoundaryChar(c: char): bool =
  ## RFC 2046 §5.1.1 `bcharsnospace` (spaces legal mid-boundary but
  ## never emitted: a trailing space would be stripped by gateways).
  c.isAlphaNumeric() or c in {'\'', '(', ')', '+', '_', ',', '-', '.',
    '/', ':', '=', '?'}

proc isValidBoundary*(s: string): bool =
  ## 1–70 `bcharsnospace` chars (R-MIME-04).
  if s.len == 0 or s.len > maxBoundaryLen:
    return false
  for c in s:
    if not isBoundaryChar(c):
      return false
  true

proc sanitizeSalt(salt: string): string =
  result = newStringOfCap(salt.len)
  for c in salt:
    if isBoundaryChar(c):
      result.add(c)
    else:
      result.add('-')

var boundaryCounter = 0
var boundaryRandomized = false

proc defaultBoundarySource*(salt: string): string =
  ## Production boundary source: `=_`-prefixed random hex, which per
  ## the RFC 2045 §6.7 NOTE can never appear in a QP body.
  if not boundaryRandomized:
    randomize()
    boundaryRandomized = true
  inc boundaryCounter
  "=_isonim_" & sanitizeSalt(salt) & "_" & boundaryCounter.toHex(4) &
    "_" & rand(uint32).toHex(8)

proc fixedBoundarySource*(tag: string): BoundarySource =
  ## Test boundary source: every call returns `tag` plus a per-call
  ## counter, so sibling multiparts stay distinct and deterministic.
  var n = 0
  result = proc (salt: string): string {.closure.} =
    inc n
    tag & "-" & sanitizeSalt(salt) & "-" & $n

proc seededBoundarySource*(seed: string): BoundarySource =
  ## Test boundary source derived from a seed: `=_e_<seed>_<hex>`,
  ## where the hex derives from seed and salt, so sibling multiparts
  ## stay distinct, every call is deterministic, and the shape can
  ## never appear in a QP body (the `=_` prefix, RFC 2045 §6.7 NOTE).
  ## The seed plaintext is capped so overlong seeds still fit the
  ## 70-char limit.
  let clean = sanitizeSalt(seed)
  let flat = clean[0 ..< min(clean.len, 53)]
  result = proc (salt: string): string {.closure.} =
    "=_e_" & flat & "_" & sha256Hex(seed & ":" & salt)[0 ..< 12]

type BoundaryError* = object of ValueError
  ## A boundary source produced an invalid boundary. Message assembly
  ## converts it to `E-MIME-HEADER` rather than crash.

proc uniqueBoundary*(src: BoundarySource; salt: string;
                     bodies: openArray[string]): string =
  ## A boundary from `src` verified absent from every body
  ## (RFC 2046 §5.1.1: delimiters must not appear in the encapsulated
  ## material). Retries with a fresh salt suffix until one fits. An
  ## invalid candidate raises `BoundaryError` naming it.
  var attempt = 0
  while true:
    let candidate =
      if attempt == 0: src(salt)
      else: src(salt & "-retry" & $attempt)
    if not isValidBoundary(candidate):
      raise newException(BoundaryError,
        "boundary source produced an invalid boundary: '" & candidate &
          "' (1-70 characters from the RFC 2046 bcharsnospace set)")
    var found = false
    for body in bodies:
      if candidate in body:
        found = true
        break
    if not found:
      return candidate
    inc attempt

proc header*(name, value: string): MimeHeader =
  MimeHeader(name: name, value: value)

proc textPart*(mimeType, rawBody: string; charset = "utf-8";
               flowed = false): MimePart =
  ## A QP-encoded text part (R-MIME-05, R-MIME-06). `flowed` adds
  ## `format=flowed` (RFC 3676) for the plain-text alternative.
  var contentType = mimeType & "; charset=" & charset
  if flowed:
    contentType.add("; format=flowed")
  MimePart(kind: mpkSingle, headers: @[
    header("Content-Type", contentType),
    header("Content-Transfer-Encoding", "quoted-printable"),
  ], body: encodeQuotedPrintable(rawBody))

const
  maxQuotedFilename* = 60
    ## Longest filename emitted as a plain quoted-string parameter; a
    ## longer one uses RFC 2231 continuations so no header line grows
    ## past the fold limit.
  rfc2231SegmentLen* = 40
    ## Longest percent-encoded RFC 2231 segment: with its
    ## `filename*NN*=UTF-8''` head and `;` it stays within 78 columns.

proc isAttributeChar(c: char): bool =
  ## RFC 2231 §7 `attribute-char`: any printable ASCII except SPACE,
  ## `*`, `'`, `%` and the RFC 2045 tspecials.
  c.isAlphaNumeric() or c in {'!', '#', '$', '&', '+', '-', '.', '^',
    '_', '`', '|', '~'}

proc isPlainFilename(filename: string): bool =
  ## Printable ASCII only (no controls, no UTF-8), short, without edge
  ## spaces (readers strip them) and without `=?` (readers decode
  ## RFC 2047 look-alikes even inside a quoted parameter): safe as a
  ## quoted-string once `"` and `\` are escaped.
  if filename.len == 0 or filename.len > maxQuotedFilename:
    return false
  if filename[0] == ' ' or filename[^1] == ' ' or "=?" in filename:
    return false
  for c in filename:
    if c.byte < 32 or c.byte > 126:
      return false
  true

proc filenameParam*(key, filename: string): string =
  ## One `; key=…` parameter carrying `filename` safely:
  ## - short printable ASCII: a quoted-string with `"` and `\`
  ##   backslash-escaped (RFC 5322 §3.2.4 `quoted-pair`);
  ## - anything else (UTF-8, control bytes, a long name): RFC 2231
  ##   `key*0*=UTF-8''…; key*1*=…` — percent-encoded octets in ≤ 40-char
  ##   segments, never splitting a `%XX`.
  ## Control bytes (CR and LF included) can therefore never reach the
  ## header raw: callers reject them first (`E-MIME-HEADER`), and this
  ## percent-encodes whatever gets past.
  if isPlainFilename(filename):
    var quoted = ""
    for c in filename:
      if c in {'"', '\\'}:
        quoted.add('\\')
      quoted.add(c)
    return "; " & key & "=\"" & quoted & "\""
  const digits = "0123456789ABCDEF"
  var atoms: seq[string] = @[]
  for c in filename:
    if isAttributeChar(c):
      atoms.add($c)
    else:
      atoms.add("%" & digits[c.byte shr 4] & digits[c.byte and 0x0F])
  var segments: seq[string] = @[""]
  for a in atoms:
    if segments[^1].len + a.len > rfc2231SegmentLen:
      segments.add("")
    segments[^1].add(a)
  result = ""
  for i, seg in segments:
    result.add("; " & key & "*" & $i & "*=")
    if i == 0:
      result.add("UTF-8''")
    result.add(seg)

proc imagePart*(img: InlineImage): MimePart =
  ## A base64 inline image with `Content-ID: <…>` and
  ## `Content-Disposition: inline` (R-MIME-09, R-MIME-11). The filename
  ## is escaped by `filenameParam`.
  MimePart(kind: mpkSingle, headers: @[
    header("Content-Type", img.contentType &
      filenameParam("name", img.filename)),
    header("Content-Transfer-Encoding", "base64"),
    header("Content-ID", "<" & img.contentId & ">"),
    header("Content-Disposition", "inline" &
      filenameParam("filename", img.filename)),
  ], body: encodeBase64(img.data))

proc attachmentPart*(att: Attachment): MimePart =
  ## A base64 attachment (`multipart/mixed` member, R-MIME-03). The
  ## filename is escaped by `filenameParam`.
  MimePart(kind: mpkSingle, headers: @[
    header("Content-Type", att.mime & filenameParam("name", att.filename)),
    header("Content-Transfer-Encoding", "base64"),
    header("Content-Disposition", "attachment" &
      filenameParam("filename", att.filename)),
  ], body: encodeBase64(att.bytes))

proc serializePart*(part: MimePart): string

proc serializeMultipartFraming(part: MimePart): string =
  ## The delimiter framing plus children, without any header block.
  result = ""
  for child in part.children:
    result.add("--" & part.boundary & crlf)
    var childBytes = serializePart(child)
    # The CRLF before the next delimiter is attached to the
    # boundary (§5.1.1 NOTE): bodies already end with one (QP and
    # base64 terminate every line), but an empty body needs it.
    if not childBytes.endsWith(crlf):
      childBytes.add(crlf)
    result.add(childBytes)
  result.add("--" & part.boundary & "--" & crlf)

proc newMultipart*(subtype: string; children: seq[MimePart];
                   src: BoundarySource; salt: string;
                   typeParam = ""): MimePart =
  ## Frames `children` as one multipart entity, choosing a boundary
  ## absent from the serialised children (R-MIME-04). Children are
  ## serialised first so the check covers their encoded bodies.
  var bodies = newSeq[string](children.len)
  for i, child in children:
    bodies[i] = serializePart(child)
  let boundary = uniqueBoundary(src, salt, bodies)
  MimePart(kind: mpkMultipart, headers: @[],
    subtype: subtype, boundary: boundary, typeParam: typeParam,
    children: children)

proc newAlternative*(plain, htmlOrRelated: MimePart;
                     src: BoundarySource = defaultBoundarySource;
                     salt = "alt"): MimePart =
  ## `multipart/alternative`, plain first and HTML last (RFC 2046
  ## §5.1.4: increasing faithfulness, preferred format last;
  ## R-MIME-01).
  newMultipart("alternative", @[plain, htmlOrRelated], src, salt)

proc newRelated*(root: MimePart; images: seq[MimePart];
                 src: BoundarySource = defaultBoundarySource;
                 salt = "rel"; rootType = "text/html"): MimePart =
  ## `multipart/related` with the root first and the mandatory
  ## `type` parameter (RFC 2387 §3.1; R-MIME-02).
  newMultipart("related", @[root] & images, src, salt,
    typeParam = rootType)

proc newMixed*(content: MimePart; attachments: seq[MimePart];
               src: BoundarySource = defaultBoundarySource;
               salt = "mix"): MimePart =
  ## `multipart/mixed` wrapping content plus attachments (R-MIME-03).
  newMultipart("mixed", @[content] & attachments, src, salt)

proc contentTypeValue(part: MimePart): string =
  ## The `Content-Type` value for a multipart entity; the boundary is
  ## always quoted (RFC 2046 §5.1.1: never hurts).
  result = "multipart/" & part.subtype & "; boundary=\"" &
    part.boundary & "\""
  if part.typeParam.len > 0:
    result.add("; type=\"" & part.typeParam & "\"")

proc serializeHeaders(headers: openArray[MimeHeader]): string =
  result = ""
  for h in headers:
    result.add(foldHeader(h.name, h.value))
    result.add(crlf)

proc serializePart*(part: MimePart): string =
  ## Serialises one entity with CRLF endings (R-MIME-13). Multipart
  ## framing follows RFC 2046 §5.1.1: `--boundary` delimiters, a
  ## `--boundary--` close, and the CRLF before each delimiter attached
  ## to the boundary.
  case part.kind
  of mpkSingle:
    result = serializeHeaders(part.headers) & crlf & part.body
  of mpkMultipart:
    result = serializeHeaders(part.headers)
    result.add(foldHeader("Content-Type", contentTypeValue(part)))
    result.add(crlf & crlf)
    result.add(serializeMultipartFraming(part))

proc newMessage*(headers: seq[MimeHeader]; root: MimePart): MimeMessage =
  ## Assembles headers plus the root entity.
  MimeMessage(headers: headers, root: root)

proc serializeMessage*(msg: MimeMessage): string =
  ## The full message bytes: folded headers, a blank line, the root
  ## entity's body, all CRLF-terminated (R-MIME-13). The root's own
  ## headers belong to the message header block — a multipart root's
  ## `Content-Type`, and a single-part root's `Content-Type` and
  ## `Content-Transfer-Encoding` — so the blank line separates exactly
  ## the header block from the body (RFC 5322 §2.1; emitting the root's
  ## headers past it would strand them in the body).
  result = serializeHeaders(msg.headers)
  result.add(serializeHeaders(msg.root.headers))
  if msg.root.kind == mpkMultipart:
    result.add(foldHeader("Content-Type", contentTypeValue(msg.root)))
    result.add(crlf)
  result.add(crlf)
  case msg.root.kind
  of mpkSingle:
    result.add(msg.root.body)
  of mpkMultipart:
    result.add(serializeMultipartFraming(msg.root))
