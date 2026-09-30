# rule: R-MIME-01
# rule: R-MIME-02
# rule: R-MIME-03
# rule: R-MIME-04
# rule: R-MIME-12
## The message API — `toMessage` binds a rendered email to its
## headers, `toRfc5322` serialises it, `toParts` hands back the
## decoded fields. The worked-example skeleton is pinned byte for
## byte: header order, the seeded Message-ID and boundary shapes, the
## plain-first alternatives and the CRLF framing. Seeded shapes are
## also asserted structurally (prefix, hex, length, validity,
## determinism), so the golden pins regressions, not the derivation
## itself: the derivation is `sha256(seed & ":" & domain)` for the id
## and `sha256(seed & ":" & salt)` for boundaries, cross-checked
## against sha256sum.
##
## Backend-independent (pure string code), so `just test` also runs it
## on JS.
import std/[base64, options, sequtils, strutils, times, unittest]
import isonim_email

proc skeletonMessage(): EmailMessage =
  toMessage(
    RenderedEmail(html: "<p>x</p>", text: "x"),
    MessageHeaders(
      fromAddr: mailbox("Metacraft", "hello@example.com"),
      to: @[mailbox("Ada", "ada@example.com")],
      subject: "Welcome to Metacraft",
      date: fromUnix(1767268800)))

const
  skeletonId = "<t.deddef031483330d@example.com>"
  skeletonBoundary = "=_e_t_2dd9363e8d1a"

proc skeletonGolden(): string =
  ## The worked-example bytes with seed "t", CRLF throughout
  ## (R-MIME-13; the contract shows the same skeleton with plain
  ## newlines for reading).
  @[
    "MIME-Version: 1.0",
    "Date: Thu, 01 Jan 2026 12:00:00 +0000",
    "From: Metacraft <hello@example.com>",
    "To: Ada <ada@example.com>",
    "Subject: Welcome to Metacraft",
    "Message-ID: " & skeletonId,
    "Content-Type: multipart/alternative; boundary=\"" &
      skeletonBoundary & "\"",
    "",
    "--" & skeletonBoundary,
    "Content-Type: text/plain; charset=utf-8; format=flowed",
    "Content-Transfer-Encoding: quoted-printable",
    "",
    "x",
    "--" & skeletonBoundary,
    "Content-Type: text/html; charset=utf-8",
    "Content-Transfer-Encoding: quoted-printable",
    "",
    "<p>x</p>",
    "--" & skeletonBoundary & "--",
    "",
  ].join(crlf)

proc headerNames(bytes: string): seq[string] =
  ## The top-level header names in wire order (no folding in these
  ## fixtures: every header fits on one line).
  let head = bytes[0 ..< bytes.find(crlf & crlf)]
  for line in head.split(crlf):
    result.add(line[0 ..< line.find(':')])

proc isHex(s: string): bool =
  s.len > 0 and s.allIt(it in HexDigits)

suite "message API":
  test "the worked-example skeleton, byte for byte":
    let bytes = toRfc5322(skeletonMessage(), "t")
    check bytes == skeletonGolden()
    # ... and the same inputs derive the same bytes.
    check toRfc5322(skeletonMessage(), "t") == bytes

  test "minimal header order":
    check headerNames(toRfc5322(skeletonMessage(), "t")) == @[
      "MIME-Version", "Date", "From", "To", "Subject", "Message-ID",
      "Content-Type",
    ]

  test "full header order":
    var headers = MessageHeaders(
      fromAddr: mailbox("", "a@example.com"),
      to: @[mailbox("", "b@example.com")],
      cc: @[mailbox("", "c@example.com")],
      bcc: @[mailbox("", "d@example.com")],
      replyTo: @[mailbox("", "e@example.com")],
      subject: "s",
      date: fromUnix(1767268800),
      unsubscribe: some(Unsubscribe(
        httpsUri: "https://example.com/u/opaque-token-0123456789")),
      autoSubmitted: true,
      feedbackId: "f",
      entityRefId: "g",
      extra: @[("X-Extra", "h")])
    let msg = toMessage(RenderedEmail(html: "<p>x</p>", text: "x"),
      headers)
    check headerNames(toRfc5322(msg, "t")) == @[
      "MIME-Version", "Date", "From", "To", "Cc", "Reply-To", "Subject",
      "Message-ID", "List-Unsubscribe", "List-Unsubscribe-Post",
      "Auto-Submitted", "Feedback-ID", "X-Entity-Ref-ID", "X-Extra",
      "Content-Type",
    ]
    # Bcc validates but is never emitted; the envelope carries it.
    check "Bcc" notin headerNames(toRfc5322(msg, "t"))
    check msg.envelopeTo ==
      @["b@example.com", "c@example.com", "d@example.com"]
    check msg.envelopeFrom == "a@example.com"

  test "seeded Message-ID shape":
    let bytes = toRfc5322(skeletonMessage(), "t")
    let head = bytes[0 ..< bytes.find(crlf & crlf)]
    var id = ""
    for line in head.split(crlf):
      if line.startsWith("Message-ID:"):
        id = line["Message-ID:".len .. ^1].strip()
    check id.startsWith("<t.")
    check id.endsWith("@example.com>")
    let hex = id["<t.".len ..< id.find('@')]
    check hex.len == 16
    check isHex(hex)
    # The hex derives from seed and domain, independently reproducible.
    check hex == sha256Hex("t:example.com")[0 ..< 16]
    check id == skeletonId

  test "seeded boundary shape":
    let src = seededBoundarySource("t")
    let alt = src("alt")
    let rel = src("rel")
    let mix = src("mix")
    check alt == skeletonBoundary
    for b in [alt, rel, mix]:
      check b.startsWith("=_e_t_")
      check b.len == "=_e_t_".len + 12
      check isHex(b["=_e_t_".len .. ^1])
      check isValidBoundary(b)
    # Sibling multiparts stay distinct.
    check alt != rel
    check alt != mix
    check rel != mix
    # The hex derives from seed and salt, independently reproducible.
    check alt["=_e_t_".len .. ^1] == sha256Hex("t:alt")[0 ..< 12]
    # A different seed derives different boundaries.
    check seededBoundarySource("u")("alt") != alt
    # An overlong seed still fits the 70-char limit, valid.
    let long = seededBoundarySource("s".repeat(100))("alt")
    check long.len <= maxBoundaryLen
    check isValidBoundary(long)
    check long.startsWith("=_e_")

  test "unseeded Message-ID and boundary":
    let bytes = toRfc5322(skeletonMessage())
    let head = bytes[0 ..< bytes.find(crlf & crlf)]
    var id = ""
    var ct = ""
    for line in head.split(crlf):
      if line.startsWith("Message-ID:"):
        id = line["Message-ID:".len .. ^1].strip()
      if line.startsWith("Content-Type:"):
        ct = line
    check id.startsWith("<")
    check id.endsWith("@example.com>")
    check id.len == 1 + 16 + "@example.com>".len
    check isHex(id[1 ..< id.find('@')])
    let b = ct[ct.find("boundary=\"") + "boundary=\"".len .. ^1]
    check b.endsWith("\"")
    let boundary = b[0 ..< ^1]
    check isValidBoundary(boundary)

  test "attachments ride under multipart/mixed":
    let msg = toMessage(
      RenderedEmail(html: "<p>x</p>", text: "x"),
      MessageHeaders(
        fromAddr: mailbox("", "a@example.com"),
        to: @[mailbox("", "b@example.com")],
        date: fromUnix(1767268800)),
      attachments = @[Attachment(filename: "notes.txt",
        mime: "text/plain", bytes: "hi\n")])
    let bytes = toRfc5322(msg, "t")
    check "Content-Type: multipart/mixed;" in bytes
    check "Content-Type: text/plain; name=\"notes.txt\"" in bytes
    check "Content-Disposition: attachment; filename=\"notes.txt\"" in
      bytes
    check "Content-Transfer-Encoding: base64" in bytes
    check base64.encode("hi\n") in bytes

  test "hosted is the default and ignores stored assets":
    let logo = AssetRef(name: "logo.png", mime: "image/png",
      bytes: "PNGDATA", sha256: sha256Hex("PNGDATA"))
    let msg = toMessage(
      RenderedEmail(html: "<p>x</p>", text: "x", assets: @[logo]),
      MessageHeaders(
        fromAddr: mailbox("", "a@example.com"),
        to: @[mailbox("", "b@example.com")],
        date: fromUnix(1767268800)))
    check msg.images == isHosted
    check msg.attachments.len == 0
    let bytes = toRfc5322(msg, "t")
    check "multipart/alternative" in bytes
    check "multipart/related" notin bytes
    check toParts(msg).inline.len == 0

  test "embedded assets become the related parts":
    let logo = AssetRef(name: "brand/logo.png", mime: "image/png",
      bytes: "PNGDATA", sha256: sha256Hex("PNGDATA"))
    let msg = toMessage(
      RenderedEmail(html: "<p>x</p>", text: "x", assets: @[logo]),
      MessageHeaders(
        fromAddr: mailbox("", "a@example.com"),
        to: @[mailbox("", "b@example.com")],
        date: fromUnix(1767268800)),
      images = isEmbedded)
    let bytes = toRfc5322(msg, "t")
    check "multipart/related" in bytes
    check "type=\"text/html\"" in bytes
    check "Content-ID: <" & contentIdFor(logo) & ">" in bytes
    check "inline; filename=\"logo.png\"" in bytes
    check base64.encode("PNGDATA") in bytes
    check toParts(msg).inline == @[logo]

  test "embedding without bytes raises":
    let hollow = AssetRef(name: "logo.png", mime: "image/png")
    let msg = toMessage(
      RenderedEmail(html: "<p>x</p>", text: "x", assets: @[hollow]),
      MessageHeaders(
        fromAddr: mailbox("", "a@example.com"),
        to: @[mailbox("", "b@example.com")],
        date: fromUnix(1767268800)),
      images = isEmbedded)
    var err = ""
    try:
      discard toRfc5322(msg, "t")
    except EmailRenderError as e:
      err = e.msg
    check err.startsWith("E-ASSET-UNKNOWN:")
    check "logo.png" in err

  test "invalid headers raise at toMessage":
    var headers = MessageHeaders(
      fromAddr: mailbox("", "not-an-address"),
      to: @[mailbox("", "b@example.com")])
    var err = ""
    try:
      discard toMessage(RenderedEmail(html: "<p>x</p>", text: "x"),
        headers)
    except EmailRenderError as e:
      err = e.msg
    check err.startsWith(codeMimeHeader & ":")
    check "not-an-address" in err
