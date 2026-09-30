## isonim_email/mime/headers.nim — headers the library owns.
##
## `List-Unsubscribe` + `List-Unsubscribe-Post` per RFC 8058 (R-SND-01,
## R-SND-02), `Auto-Submitted` (R-SND-05), `Feedback-ID` and
## `X-Entity-Ref-ID`. Each is behind an explicit option on
## `ownedHeaders`; without it the header is absent. Values are checked
## for CRLF injection and the unsubscribe URI for the https scheme
## (`E-MIME-HEADER`) and an opaque token (`W-MIME-UNSUB-TOKEN`).
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

proc validateUnsubscribe*(u: Unsubscribe): seq[EmailDiagnostic] =
  ## `E-MIME-HEADER` when the URI is not https or a value carries a
  ## header break (R-SND-01); `W-MIME-UNSUB-TOKEN` when the URI has no
  ## opaque token (R-SND-02). A broken URI skips the token check.
  if u.httpsUri.len == 0 or hasHeaderInjection(u.httpsUri) or
      not u.httpsUri.startsWith("https://"):
    result.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
      message: "List-Unsubscribe URI must be a single https URI, got '" &
        u.httpsUri & "' (R-SND-01)",
      rules: @["R-SND-01"]))
  elif not hasOpaqueToken(u.httpsUri):
    result.add(EmailDiagnostic(severity: sevWarning,
      code: codeMimeUnsubToken,
      message: "List-Unsubscribe URI has no query or path token of at " &
        "least 16 characters (R-SND-02)",
      rules: @["R-SND-02"]))
  if u.mailto.len > 0 and (hasHeaderInjection(u.mailto) or
      not u.mailto.toLowerAscii().startsWith("mailto:") or
      '@' notin u.mailto):
    result.add(EmailDiagnostic(severity: sevError, code: codeMimeHeader,
      message: "List-Unsubscribe mailto must be a mailto: address, got '" &
        u.mailto & "' (R-SND-01)",
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
