## isonim_email/mime/one_click.nim — the sender's side of RFC 8058.
##
## The library emits `List-Unsubscribe` + `List-Unsubscribe-Post`;
## the endpoint the URI names belongs to the sender (R-SND-03). This
## module is the reusable half of that endpoint: `checkOneClickRequest`
## decides whether an incoming HTTP request is an RFC 8058 one-click
## unsubscribe POST, and `oneClickResponse` answers it — 200 when it
## is, 400 when it is not, and never a redirect (RFC 8058 §3.1: "The
## mail sender MUST NOT return an HTTPS redirect").
##
## A one-click POST:
## - uses the `POST` method;
## - carries no `Cookie` and no `Authorization` header (RFC 8058 §3.1:
##   "The POST request MUST NOT include cookies, HTTP authorization, or
##   any other context information");
## - has the body `List-Unsubscribe=One-Click` (the `List-Unsubscribe-Post`
##   value), either as `multipart/form-data` (RFC 7578; SHOULD) or as
##   `application/x-www-form-urlencoded` (MAY), as the single field.
##
## Framework-free and transport-free (plain strings), so any HTTP
## server can call it; runs on C and JS.

import std/strutils
import ./headers

type
  OneClickRequest* = object
    ## The parts of an HTTP request the check reads. Header names match
    ## case-insensitively.
    httpMethod*: string
    headers*: seq[(string, string)]
    body*: string

  OneClickVerdict* = object
    ## `ok` when the request is a one-click unsubscribe POST; otherwise
    ## `reason` says which requirement failed.
    ok*: bool
    reason*: string

  OneClickResponse* = object
    ## What the endpoint answers: a 200 or a 400, never a 3xx, and
    ## never a `Location` header.
    status*: int
    headers*: seq[(string, string)]
    body*: string

const
  oneClickKey* = "List-Unsubscribe"
  oneClickValue* = "One-Click"

proc headerValue(req: OneClickRequest; name: string): tuple[found: bool;
    value: string] =
  for (n, v) in req.headers:
    if n.strip().toLowerAscii() == name.toLowerAscii():
      return (true, v.strip())
  (false, "")

proc mediaType(contentType: string): string =
  contentType.split(';')[0].strip().toLowerAscii()

proc paramOf(contentType, param: string): string =
  ## One `param=value` of a Content-Type, quotes removed.
  let parts = contentType.split(';')
  for k in 1 ..< parts.len:
    let p = parts[k].strip()
    let eq = p.find('=')
    if eq > 0 and p[0 ..< eq].strip().toLowerAscii() == param:
      var v = p[eq + 1 .. ^1].strip()
      if v.len >= 2 and v[0] == '"' and v[^1] == '"':
        v = v[1 ..< ^1]
      return v
  ""

proc formDecode(s: string): tuple[ok: bool; value: string] =
  ## `application/x-www-form-urlencoded` decoding: `+` is SPACE and
  ## `%XX` an octet; a broken escape fails.
  var i = 0
  var value = ""
  while i < s.len:
    case s[i]
    of '+':
      value.add(' ')
      inc i
    of '%':
      if i + 2 >= s.len or s[i + 1] notin HexDigits or
          s[i + 2] notin HexDigits:
        return (false, "")
      value.add(char(parseHexInt(s[i + 1 .. i + 2])))
      i += 3
    else:
      value.add(s[i])
      inc i
  (true, value)

proc checkUrlEncoded(body: string): OneClickVerdict =
  var text = body
  if text.endsWith("\r\n"):
    text.setLen(text.len - 2)
  let pairs = text.split('&')
  if pairs.len != 1:
    return OneClickVerdict(reason: "the form must carry the single " &
      "field List-Unsubscribe=One-Click, got " & $pairs.len & " fields")
  let eq = pairs[0].find('=')
  if eq < 0:
    return OneClickVerdict(reason: "the form field has no '='")
  let key = formDecode(pairs[0][0 ..< eq])
  let value = formDecode(pairs[0][eq + 1 .. ^1])
  if not key.ok or not value.ok:
    return OneClickVerdict(reason: "the form field has a broken %XX escape")
  if key.value != oneClickKey or value.value != oneClickValue:
    return OneClickVerdict(reason: "the form field must be " &
      "List-Unsubscribe=One-Click, got '" & body.escape("", "") & "'")
  OneClickVerdict(ok: true)

proc checkMultipart(contentType, body: string): OneClickVerdict =
  ## RFC 7578: parts delimited by `--boundary`, each with a
  ## `Content-Disposition: form-data; name="…"` header, closed by
  ## `--boundary--`.
  let boundary = paramOf(contentType, "boundary")
  if boundary.len == 0:
    return OneClickVerdict(reason: "multipart/form-data without a boundary")
  let delim = "--" & boundary
  let close = body.find(delim & "--")
  if close < 0:
    return OneClickVerdict(reason: "multipart body is not closed by " &
      "its boundary")
  var fields: seq[tuple[name, value: string]] = @[]
  var at = body.find(delim)
  while at >= 0 and at < close:
    let start = at + delim.len
    let next = body.find(delim, start)
    var part = body[start ..< next]
    if part.startsWith("\r\n"):
      part = part[2 .. ^1]
    if part.endsWith("\r\n"):
      part.setLen(part.len - 2)
    let split = part.find("\r\n\r\n")
    if split < 0:
      return OneClickVerdict(reason: "a multipart part has no header block")
    var name = ""
    for line in part[0 ..< split].split("\r\n"):
      let colon = line.find(':')
      if colon > 0 and line[0 ..< colon].strip().toLowerAscii() ==
          "content-disposition":
        let disp = line[colon + 1 .. ^1]
        if mediaType(disp) != "form-data":
          return OneClickVerdict(reason: "a multipart part is not form-data")
        name = paramOf(disp, "name")
    fields.add((name, part[split + 4 .. ^1]))
    at = next
  if fields.len != 1:
    return OneClickVerdict(reason: "the form must carry the single " &
      "field List-Unsubscribe=One-Click, got " & $fields.len & " fields")
  if fields[0].name != oneClickKey or fields[0].value != oneClickValue:
    return OneClickVerdict(reason: "the form field must be " &
      "List-Unsubscribe=One-Click, got '" & fields[0].name.escape("", "") &
      "=" & fields[0].value.escape("", "") & "'")
  OneClickVerdict(ok: true)

proc checkOneClickRequest*(req: OneClickRequest): OneClickVerdict =
  ## Whether `req` is an RFC 8058 one-click unsubscribe POST (R-SND-03);
  ## see the module header for the three requirements.
  if req.httpMethod != "POST":
    return OneClickVerdict(reason: "method must be POST, got '" &
      req.httpMethod.escape("", "") & "'")
  if req.headerValue("Cookie").found:
    return OneClickVerdict(reason: "the POST must not carry cookies " &
      "(RFC 8058 §3.1)")
  if req.headerValue("Authorization").found:
    return OneClickVerdict(reason: "the POST must not carry HTTP " &
      "authorization (RFC 8058 §3.1)")
  let ct = req.headerValue("Content-Type")
  case mediaType(ct.value)
  of "application/x-www-form-urlencoded":
    checkUrlEncoded(req.body)
  of "multipart/form-data":
    checkMultipart(ct.value, req.body)
  else:
    OneClickVerdict(reason: "the body must be multipart/form-data or " &
      "application/x-www-form-urlencoded, got '" &
      ct.value.escape("", "") & "'")

proc oneClickResponse*(verdict: OneClickVerdict): OneClickResponse =
  ## The endpoint's answer: 200 once the request is a one-click POST
  ## (the caller unsubscribes the recipient the URI identifies before
  ## sending it), 400 naming the failed requirement otherwise. Never a
  ## redirect: no 3xx status, no `Location` header (RFC 8058 §3.1).
  if verdict.ok:
    OneClickResponse(status: 200,
      headers: @[("Content-Type", "text/plain; charset=utf-8")],
      body: "unsubscribed")
  else:
    OneClickResponse(status: 400,
      headers: @[("Content-Type", "text/plain; charset=utf-8")],
      body: "not a one-click unsubscribe request: " & verdict.reason)

static:
  # The body the check accepts is exactly the header value the library
  # emits, so the two halves cannot drift apart.
  doAssert oneClickKey & "=" & oneClickValue == listUnsubscribePostValue
