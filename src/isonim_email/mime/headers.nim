## isonim_email/mime/headers.nim — headers the library owns.
##
## `List-Unsubscribe` + `List-Unsubscribe-Post` per RFC 8058 (R-SND-01,
## R-SND-02), `Auto-Submitted` (R-SND-05), `Feedback-ID` and
## `X-Entity-Ref-ID`. Each is behind an explicit option on
## `ownedHeaders`; without it the header is absent. Values are checked
## for CRLF injection and the unsubscribe URIs for RFC 3986 syntax, the
## https scheme with a host, and a bounded length (`E-MIME-HEADER`), and
## for an opaque token (`W-MIME-UNSUB-TOKEN`).
## Headers are `model.MimeHeader`, so `toMessage` applies them to
## the assembled message untouched.

import std/[options, strutils]
import ./model
import ../diagnostics

const
  listUnsubscribePostValue* = "List-Unsubscribe=One-Click"
    ## The fixed RFC 8058 §3.1 `List-Unsubscribe-Post` value.
  minUnsubTokenLen* = 16
    ## Shortest opaque token R-SND-02 accepts in the URI path or query.

type Unsubscribe* = object
  ## The full unsubscribe URI plus an optional `mailto:`.
  httpsUri*: string
  mailto*: string

proc hasHeaderInjection*(value: string): bool =
  ## True when the value smuggles a header break (rejected everywhere).
  '\r' in value or '\n' in value

proc isTokenChar(c: char): bool =
  c.isAlphaNumeric() or c in {'-', '_'}

proc hasOpaqueToken*(uri: string): bool =
  ## A run of ≥ 16 token chars in the URI path or query (R-SND-02):
  ## the URI identifies recipient and list by itself.
  var rest = uri
  let scheme = rest.find("://")
  if scheme >= 0:
    rest = rest[scheme + 3 .. ^1]
  var start = rest.find('/')
  if start < 0:
    start = rest.find('?')
  if start < 0:
    return false
  var run = 0
  for i in start ..< rest.len:
    if isTokenChar(rest[i]):
      inc run
      if run >= minUnsubTokenLen:
        return true
    else:
      run = 0
  false

const maxUnsubUriLen* = 900
  ## Longest accepted unsubscribe URI (each of https and mailto): the
  ## `List-Unsubscribe` line must stay under RFC 5322's 998 characters
  ## without whitespace inside the angle brackets, which RFC 2369 §2
  ## forbids inserting.

proc isUriChar(c: char): bool =
  ## RFC 3986 §2: unreserved, gen-delims and sub-delims (`%` is checked
  ## separately, as the start of a `%XX` escape).
  c.isAlphaNumeric() or c in {'-', '.', '_', '~', ':', '/', '?', '#',
    '[', ']', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';',
    '='}

proc uriSyntaxProblem(uri: string): string =
  ## "" when every character is legal in an RFC 3986 URI and every `%`
  ## starts a `%XX` escape; otherwise what is wrong. Whitespace, `<`,
  ## `>`, `"`, controls and raw UTF-8 all land here: inside a
  ## `List-Unsubscribe` bracket they would end the URI early or be
  ## dropped by the reader (RFC 2369 §2).
  if uri.len > maxUnsubUriLen:
    return "is " & $uri.len & " characters (at most " & $maxUnsubUriLen &
      ")"
  var i = 0
  while i < uri.len:
    let c = uri[i]
    if c == '%':
      if i + 2 >= uri.len or uri[i + 1] notin HexDigits or
          uri[i + 2] notin HexDigits:
        return "has a '%' that does not start a %XX escape"
      i += 3
      continue
    if not isUriChar(c):
      return "contains " & (if c.byte < 32 or c.byte > 126:
        "the byte 0x" & c.byte.toHex(2) else: "'" & $c & "'") &
        ", which must be percent-encoded"
    inc i
  ""

proc httpsUriProblem*(uri: string): string =
  ## "" when `uri` is one absolute https URI with a host, no userinfo
  ## and legal URI syntax (R-SND-01); otherwise what is wrong.
  if uri.len == 0:
    return "is empty"
  if not uri.toLowerAscii().startsWith("https://"):
    return "is not an https URI"
  let syntax = uriSyntaxProblem(uri)
  if syntax.len > 0:
    return syntax
  let rest = uri["https://".len .. ^1]
  var authEnd = rest.len
  for k, c in rest:
    if c in {'/', '?', '#'}:
      authEnd = k
      break
  let authority = rest[0 ..< authEnd]
  if '@' in authority:
    return "carries userinfo (credentials never belong in the URI)"
  var host = authority
  if host.startsWith("["):
    let close = host.find(']')
    if close < 0:
      return "has an unterminated IPv6 host"
    let after = host[close + 1 .. ^1]
    if after.len > 0 and not (after.startsWith(":") and
        after.len > 1 and after[1 .. ^1].allCharsInSet(Digits)):
      return "has an invalid port"
  else:
    let colon = host.find(':')
    if colon >= 0:
      let port = host[colon + 1 .. ^1]
      if port.len == 0 or not port.allCharsInSet(Digits):
        return "has an invalid port"
      host = host[0 ..< colon]
    if host.len == 0:
      return "has no host"
  ""

proc mailtoProblem*(uri: string): string =
  ## "" when `uri` is a `mailto:` URI with an addr-spec (`@`) and legal
  ## URI syntax; otherwise what is wrong.
  if not uri.toLowerAscii().startsWith("mailto:"):
    return "is not a mailto: URI"
  let syntax = uriSyntaxProblem(uri)
  if syntax.len > 0:
    return syntax
  let address = uri["mailto:".len .. ^1].split('?')[0]
  let at = address.find('@')
  if at <= 0 or at == address.len - 1:
    return "has no addr-spec (local@domain)"
  ""

proc validateUnsubscribe*(u: Unsubscribe): seq[EmailDiagnostic] =
  ## `E-MIME-HEADER` when the URI is not one absolute https URI with a
  ## host and RFC 3986 syntax (R-SND-01: no whitespace, brackets,
  ## quotes, controls or raw UTF-8, no userinfo, at most
  ## `maxUnsubUriLen` characters) or the mailto is not a `mailto:`
  ## address with the same syntax; `W-MIME-UNSUB-TOKEN` when the https
  ## URI has no opaque token (R-SND-02). A broken URI skips the token
  ## check.
  let problem = httpsUriProblem(u.httpsUri)
  if problem.len > 0:
    result.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
      message: "List-Unsubscribe URI must be a single https URI, got '" &
        u.httpsUri.escape("", "") & "': it " & problem & " (R-SND-01)",
      rules: @["R-SND-01"]))
  elif not hasOpaqueToken(u.httpsUri):
    result.add(EmailDiagnostic(severity: sevWarning,
      code: codeMimeUnsubToken,
      message: "List-Unsubscribe URI has no query or path token of at " &
        "least 16 characters (R-SND-02)",
      rules: @["R-SND-02"]))
  if u.mailto.len > 0:
    let mproblem = mailtoProblem(u.mailto)
    if mproblem.len > 0:
      result.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
        message: "List-Unsubscribe mailto must be a mailto: address, " &
          "got '" & u.mailto.escape("", "") & "': it " & mproblem &
          " (R-SND-01)",
        rules: @["R-SND-01"]))

proc unsubscribeHeaders*(u: Unsubscribe): seq[MimeHeader] =
  ## Both RFC 8058 headers: one `List-Unsubscribe` with the https URI
  ## first plus the optional `mailto:`, and the fixed Post value.
  ## Emits as given — the caller validates with `validateUnsubscribe`.
  var value = "<" & u.httpsUri & ">"
  if u.mailto.len > 0:
    value.add(", <" & u.mailto & ">")
  @[header("List-Unsubscribe", value),
    header("List-Unsubscribe-Post", listUnsubscribePostValue)]

proc checkedIdHeader(name, value: string;
                     diags: var seq[EmailDiagnostic]): bool =
  ## Rejects an entity id carrying a header break (`E-MIME-HEADER`).
  if hasHeaderInjection(value):
    diags.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
      message: "'" & name & "' value must not contain CR or LF (R-SND-01)",
      rules: @["R-SND-01"]))
    return false
  true

proc ownedHeaders*(unsubscribe: Option[Unsubscribe] = none(Unsubscribe);
                   autoSubmitted = false;
                   feedbackId = "";
                   entityRefId = ""): tuple[headers: seq[MimeHeader];
                                            diagnostics: seq[EmailDiagnostic]] =
  ## The headers the library owns, each behind its option: no option,
  ## no header. An invalid unsubscribe URI or entity id is omitted and
  ## reported (`E-MIME-HEADER`); a token-less URI is still emitted with
  ## a warning (R-SND-02 refuses by warning, not by dropping).
  result = (@[], @[])
  if unsubscribe.isSome:
    let u = unsubscribe.get()
    let found = validateUnsubscribe(u)
    result.diagnostics.add(found)
    if not hasErrors(found):
      result.headers.add(unsubscribeHeaders(u))
  if autoSubmitted:
    result.headers.add(header("Auto-Submitted", "auto-generated"))
  if feedbackId.len > 0 and
      checkedIdHeader("Feedback-ID", feedbackId, result.diagnostics):
    result.headers.add(header("Feedback-ID", feedbackId))
  if entityRefId.len > 0 and
      checkedIdHeader("X-Entity-Ref-ID", entityRefId, result.diagnostics):
    result.headers.add(header("X-Entity-Ref-ID", entityRefId))
