## isonim_email/transport/mailgun.nim — Mailgun messages API.
##
## The thin capture-loop sender: `mailgunPayload` purely builds the
## messages-API fields (unit-tested, no network) and `sendMailgun`
## POSTs them. The payload carries one `o:tag` part per tag and sets
## NO `o:dkim` exclusion, so the ESP's DKIM signature covers
## `List-Unsubscribe`(+Post) per the R-SND-04 metadata on the message.
##
## C backend only: HTTPS POST. Never called in tests.

import std/[base64, httpclient, json, os, strutils]
import ../mime/message

export message

type
  MailgunError* = object of CatchableError
    ## A missing key, a failed POST, or an unparseable reply.

  MailgunPayload* = object
    ## The messages-API call, built purely by `mailgunPayload`.
    url*: string
    fromField*, toField*: string
    subject*, html*, text*: string
    tags*: seq[string]

const mailgunKeyEnv* = "MAILGUN_API_KEY"
  ## The env var `sendMailgun` reads when `apiKey` is "".

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

proc headerValue(headers: seq[(string, string)]; name: string): string =
  ## The first header value for `name`, or "" when absent.
  for (n, v) in headers:
    if n == name:
      return v
  ""

proc mailgunPayload*(m: EmailMessage; domain: string;
                    tags: seq[string] = @[];
                    region = "us"): MailgunPayload =
  ## Purely builds the `POST <base>/v3/<domain>/messages` fields from
  ## the message's decoded parts (From/To/Subject headers plus the
  ## html+text). The `toField` is the header form; Bcc stays out of
  ## the payload's visible fields exactly as it stays out of the
  ## headers. Asserts the R-SND-04 half this side owns: nothing here
  ## excludes the unsubscribe headers from DKIM (there is no `o:dkim`
  ## field at all).
  let parts = toParts(m)
  MailgunPayload(
    url: mailgunApiBase(region) & "/v3/" & domain & "/messages",
    fromField: headerValue(parts.headers, "From"),
    toField: headerValue(parts.headers, "To"),
    subject: headerValue(parts.headers, "Subject"),
    html: parts.html, text: parts.text, tags: tags)

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
  ## The form fields: from/to/subject/html/text plus one `o:tag` per
  ## tag — and no `o:dkim` anything (R-SND-04).
  result = @[("from", p.fromField), ("to", p.toField),
    ("subject", p.subject), ("html", p.html), ("text", p.text)]
  for tag in p.tags:
    result.add(("o:tag", tag))

proc sendMailgun*(m: EmailMessage; domain, apiKey: string;
                 tags: seq[string] = @[];
                 region = "us"): string =
  ## POSTs the payload with basic auth `api:<key>` and
  ## returns the Mailgun id. `apiKey == ""` reads `$MAILGUN_API_KEY`
  ## (missing → `MailgunError`). Needs `-d:ssl`; never called in
  ## tests — they pin `mailgunPayload` + `encodeMultipart` only.
  var key = apiKey
  if key.len == 0:
    key = getEnv(mailgunKeyEnv)
  if key.len == 0:
    raise newException(MailgunError,
      "Mailgun: no API key (pass apiKey or set $" & mailgunKeyEnv & ")")
  let payload = mailgunPayload(m, domain, tags, region)
  let (contentType, body) = encodeMultipart(payloadFields(payload))
  var client = newHttpClient(timeout = 30_000)
  try:
    client.headers = newHttpHeaders({
      "Content-Type": contentType,
      "Authorization": "Basic " & base64.encode("api:" & key)})
    let resp = client.request(payload.url, HttpPost, body)
    if resp.code != Http200:
      raise newException(MailgunError,
        "Mailgun: POST " & payload.url & " failed: " & $resp.code &
          " " & resp.body[0 ..< min(resp.body.len, 200)])
    try:
      resp.body.parseJson()["id"].getStr()
    except JsonParsingError as e:
      raise newException(MailgunError,
        "Mailgun: unparseable reply: " & e.msg)
  finally:
    client.close()
