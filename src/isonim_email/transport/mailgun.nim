## isonim_email/transport/mailgun.nim — Mailgun MIME sending API.
##
## The thin capture-loop sender. It posts to Mailgun's MIME endpoint
## (`POST <base>/v3/<domain>/messages.mime`): one `to` field per
## envelope recipient, one `o:tag` field per tag, and a `message` file
## part holding exactly the bytes `toRfc5322` produces. What is sent is
## therefore the message the rest of the library builds and tests —
## every header (including `List-Unsubscribe`, `List-Unsubscribe-Post`,
## Cc and Reply-To), every attachment and every `cid:` part — and
## nothing can be dropped on the way. No `h:` field is needed and no
## `o:dkim` option is set, so the ESP's DKIM signature covers
## `List-Unsubscribe`(+Post) per the R-SND-04 metadata on the message.
##
## `mailgunPayload` is pure; `sendMailgun` POSTs it. The API key only
## ever travels in the Authorization header: no error message carries
## it. C backend only (HTTP client).

import std/[base64, httpclient, json, os, strutils]
import ../mime/message

export message

type
  MailgunError* = object of CatchableError
    ## A missing key, no recipient, a failed POST, or an unparseable
    ## reply.

  MailgunPayload* = object
    ## The MIME-endpoint call, built purely by `mailgunPayload`.
    url*: string
    recipients*: seq[string]   ## envelope recipients (To + Cc + Bcc)
    tags*: seq[string]
    message*: string           ## exactly `toRfc5322(m, seed)`

const mailgunKeyEnv* = "MAILGUN_API_KEY"
  ## The env var `sendMailgun` reads when `apiKey` is "".

const mailgunMessageField* = "message"
  ## The MIME endpoint's file part carrying the RFC 5322 bytes.

proc mailgunApiBase*(region: string): string =
  ## `us` (default) or `eu` — Mailgun's two API hosts. Anything else
  ## is a `MailgunError`: silently posting to the wrong region would
  ## misdeliver the capture loop's mail.
  if region == "eu":
    "https://api.eu.mailgun.net"
  elif region == "us":
    "https://api.mailgun.net"
  else:
    raise newException(MailgunError,
      "Mailgun: unknown region '" & region & "' (want \"us\" or \"eu\")")

proc mailgunPayload*(m: EmailMessage; domain: string;
                    tags: seq[string] = @[]; region = "us";
                    deterministicSeed = ""; apiBase = ""): MailgunPayload =
  ## Purely builds the `POST <base>/v3/<domain>/messages.mime` call:
  ## the envelope recipients (`envelopeTo`: To, Cc and Bcc as bare
  ## addresses — Bcc reaches Mailgun only here, never in the headers),
  ## the tags, and the complete message from `toRfc5322`. `apiBase`
  ## "" selects the region's host; a non-empty one replaces it. No
  ## recipient at all is a `MailgunError`.
  let recipients = envelopeTo(m)
  if recipients.len == 0:
    raise newException(MailgunError,
      "Mailgun: no envelope recipients (To/Cc/Bcc are all empty)")
  let base =
    if apiBase.len > 0: apiBase.strip(leading = false, chars = {'/'})
    else: mailgunApiBase(region)
  MailgunPayload(
    url: base & "/v3/" & domain & "/messages.mime",
    recipients: recipients, tags: tags,
    message: toRfc5322(m, deterministicSeed))

proc encodeMultipart*(fields: seq[(string, string)]; fileField = "";
                     fileName = ""; fileMime = "";
                     fileBytes = ""): tuple[contentType,
    body: string] =
  ## `multipart/form-data` with a fixed boundary (test-deterministic),
  ## re-suffixed while it collides with a value. Repeated names are
  ## allowed — one part per `o:tag` — which `HttpClient`'s table
  ## cannot express. One optional file part (`message.mime`) rides
  ## last when `fileField` is set.
  var boundary = "----isonim-mailgun"
  var joined = ""
  for (_, v) in fields:
    joined.add(v)
  joined.add(fileBytes)
  while boundary in joined:
    boundary.add("x")
  var body = ""
  for (name, value) in fields:
    body.add("--" & boundary & "\r\n")
    body.add("Content-Disposition: form-data; name=\"" & name & "\"\r\n")
    body.add("\r\n" & value & "\r\n")
  if fileField.len > 0:
    body.add("--" & boundary & "\r\n")
    body.add("Content-Disposition: form-data; name=\"" & fileField &
      "\"; filename=\"" & fileName & "\"\r\n")
    body.add("Content-Type: " & fileMime & "\r\n")
    body.add("\r\n" & fileBytes & "\r\n")
  body.add("--" & boundary & "--\r\n")
  ("multipart/form-data; boundary=" & boundary, body)

proc payloadFields*(p: MailgunPayload): seq[(string, string)] =
  ## The text fields: one `to` per envelope recipient and one `o:tag`
  ## per tag — no `h:` fields (the headers ride in the message) and no
  ## `o:dkim` anything (R-SND-04). The message is the file part.
  result = @[]
  for rcpt in p.recipients:
    result.add(("to", rcpt))
  for tag in p.tags:
    result.add(("o:tag", tag))

proc payloadMultipart*(p: MailgunPayload): tuple[contentType,
    body: string] =
  ## The complete `multipart/form-data` request body: the text fields
  ## then the `message` file part carrying `p.message` byte for byte.
  encodeMultipart(payloadFields(p), fileField = mailgunMessageField,
    fileName = "message.mime", fileMime = "message/rfc822",
    fileBytes = p.message)

proc sendMailgun*(m: EmailMessage; domain, apiKey: string;
                 tags: seq[string] = @[]; region = "us";
                 deterministicSeed = ""; apiBase = ""): string =
  ## POSTs the payload with basic auth `api:<key>` and returns the
  ## Mailgun id. `apiKey == ""` reads `$MAILGUN_API_KEY` (missing →
  ## `MailgunError`). An https base needs `-d:ssl`. Neither the key nor
  ## its base64 token is ever part of an error message: failures name
  ## the URL, the status and the start of the reply only.
  var key = apiKey
  if key.len == 0:
    key = getEnv(mailgunKeyEnv)
  if key.len == 0:
    raise newException(MailgunError,
      "Mailgun: no API key (pass apiKey or set $" & mailgunKeyEnv & ")")
  let payload = mailgunPayload(m, domain, tags, region, deterministicSeed,
    apiBase)
  let (contentType, body) = payloadMultipart(payload)
  let token = base64.encode("api:" & key)
  let auth = "Basic " & token
  proc redact(text: string): string =
    ## A reply (or a transport error) that echoes the credentials must
    ## not carry them into the exception — in any form this transport
    ## produces: the whole Authorization value, the bare base64 token
    ## (an encoded form of the key) and the key itself (which also
    ## covers the `api:<key>` pair the token encodes).
    text.replace(auth, "<redacted>").replace(token, "<redacted>").
      replace(key, "<redacted>")
  proc snippet(reply: string): string =
    ## Redacted first, then cut, so a truncation cannot split the key
    ## past the redaction.
    let clean = redact(reply)
    clean[0 ..< min(clean.len, 200)]
  var client = newHttpClient(timeout = 30_000)
  try:
    client.headers = newHttpHeaders({
      "Content-Type": contentType,
      "Authorization": auth})
    var resp: Response
    try:
      resp = client.request(payload.url, HttpPost, body)
    except CatchableError as e:
      raise newException(MailgunError,
        "Mailgun: POST " & payload.url & " failed: " & redact(e.msg))
    if resp.code != Http200:
      raise newException(MailgunError,
        "Mailgun: POST " & payload.url & " failed: " & $resp.code &
          " " & snippet(resp.body))
    try:
      resp.body.parseJson()["id"].getStr()
    except CatchableError:
      raise newException(MailgunError,
        "Mailgun: unparseable reply: " &
          snippet(resp.body))
  finally:
    client.close()
