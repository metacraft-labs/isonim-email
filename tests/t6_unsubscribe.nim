# rule: R-SND-01
# rule: R-SND-02
# rule: R-SND-05
# rule: R-SND-03
## The headers the library owns. One-click
## unsubscribe emits both RFC 8058 headers with one https URI plus the
## optional mailto, and nothing without the option; the URI needs an
## opaque token (warning), the https scheme with a host, and RFC 3986
## syntax within a bounded length (error); transactional helpers set
## `Auto-Submitted`, and the Gmail ids ride along. The sender's side of
## the one-click contract (`checkOneClickRequest`, `oneClickResponse`)
## is pinned here on request shapes; tests/t6_roundtrip.nim runs it in
## a real HTTP server.
##
## Backend-independent (pure string headers), so `just test` also runs
## it on JS.
import std/[options, strutils, unittest]
import isonim_email

proc valueOf(headers: seq[MimeHeader]; name: string): string =
  for h in headers:
    if h.name == name:
      return h.value
  ""

proc countNamed(headers: seq[MimeHeader]; name: string): int =
  for h in headers:
    if h.name == name:
      inc result

const tokenUri = "https://example.com/u/opaque-token-0123456789"

suite "owned headers":
  test "test_list_unsubscribe_one_click_headers":
    # rule: R-SND-01

    # With unsubscribe supplied: exactly one List-Unsubscribe with the
    # https URI first plus the mailto, and the fixed Post value.
    let (withHeaders, withDiags) = ownedHeaders(unsubscribe = some(
      Unsubscribe(httpsUri: tokenUri, mailto: "mailto:unsub@example.com")))
    check withDiags.len == 0
    check countNamed(withHeaders, "List-Unsubscribe") == 1
    check countNamed(withHeaders, "List-Unsubscribe-Post") == 1
    check valueOf(withHeaders, "List-Unsubscribe") ==
      "<" & tokenUri & ">, <mailto:unsub@example.com>"
    check valueOf(withHeaders, "List-Unsubscribe-Post") ==
      "List-Unsubscribe=One-Click"
    check valueOf(withHeaders, "List-Unsubscribe-Post") ==
      listUnsubscribePostValue

    # The mailto is optional; one https URI alone still validates.
    let (soloHeaders, soloDiags) = ownedHeaders(
      unsubscribe = some(Unsubscribe(httpsUri: tokenUri)))
    check soloDiags.len == 0
    check valueOf(soloHeaders, "List-Unsubscribe") == "<" & tokenUri & ">"

    # Without it: neither header, and silence.
    let (bareHeaders, bareDiags) = ownedHeaders()
    check bareDiags.len == 0
    check countNamed(bareHeaders, "List-Unsubscribe") == 0
    check countNamed(bareHeaders, "List-Unsubscribe-Post") == 0

  test "unsubscribe uri without https is an error, not a header":
    # rule: R-SND-01

    let (headers, diags) = ownedHeaders(
      unsubscribe = some(Unsubscribe(httpsUri: "http://example.com/u/" &
        "opaque-token-0123456789")))
    check diags.len == 1
    check diags[0].code == codeMimeHeader
    check diags[0].severity == sevError
    check diags[0].rules == @["R-SND-01"]
    check countNamed(headers, "List-Unsubscribe") == 0
    check countNamed(headers, "List-Unsubscribe-Post") == 0

    # A smuggled header break is rejected the same way.
    let (injHeaders, injDiags) = ownedHeaders(
      unsubscribe = some(Unsubscribe(httpsUri: tokenUri &
        "\r\nBcc: evil@example.com")))
    check injDiags.len == 1
    check injDiags[0].code == codeMimeHeader
    check countNamed(injHeaders, "List-Unsubscribe") == 0

    # As is a mailto that is not a mailto: address.
    let (_, mailDiags) = ownedHeaders(unsubscribe = some(
      Unsubscribe(httpsUri: tokenUri, mailto: "https://example.com/u")))
    check mailDiags.len == 1
    check mailDiags[0].code == codeMimeHeader

  test "unsubscribe uri without an opaque token warns":
    # rule: R-SND-02

    # No 16-char run in path or query: the headers still go out (a
    # warning refuses, it does not drop), with W-MIME-UNSUB-TOKEN.
    let (headers, diags) = ownedHeaders(unsubscribe = some(
      Unsubscribe(httpsUri: "https://example.com/unsubscribe")))
    check diags.len == 1
    check diags[0].code == codeMimeUnsubToken
    check diags[0].severity == sevWarning
    check diags[0].rules == @["R-SND-02"]
    check countNamed(headers, "List-Unsubscribe") == 1
    check countNamed(headers, "List-Unsubscribe-Post") == 1

    # The boundary: 15 chars warns, 16 is silent.
    check hasOpaqueToken("https://example.com/u/123456789012345") == false
    check hasOpaqueToken("https://example.com/u/1234567890123456") == true
    # Query tokens count too.
    check hasOpaqueToken(
      "https://example.com/u?token=0123456789abcdef&x=1") == true
    # The host never counts.
    check hasOpaqueToken("https://0123456789abcdef.example.com/") == false
    let (_, quietDiags) = ownedHeaders(
      unsubscribe = some(Unsubscribe(httpsUri: tokenUri)))
    check quietDiags.len == 0

  test "transactional helpers set auto-submitted":
    # rule: R-SND-05

    let (headers, diags) =
      ownedHeaders(autoSubmitted = true)
    check diags.len == 0
    check valueOf(headers, "Auto-Submitted") == "auto-generated"

    let (bareHeaders, _) = ownedHeaders()
    check countNamed(bareHeaders, "Auto-Submitted") == 0

  test "feedback and entity ids ride along when supplied":
    # No rule claim: the library owns these headers but the catalogue
    # has no rows for them.
    let (headers, diags) = ownedHeaders(
      feedbackId = "campaign-7:mail-42:metacraft",
      entityRefId = "invoice-12345")
    check diags.len == 0
    check valueOf(headers, "Feedback-ID") == "campaign-7:mail-42:metacraft"
    check valueOf(headers, "X-Entity-Ref-ID") == "invoice-12345"

    let (bareHeaders, _) = ownedHeaders()
    check countNamed(bareHeaders, "Feedback-ID") == 0
    check countNamed(bareHeaders, "X-Entity-Ref-ID") == 0

    # A header break in an id is dropped with E-MIME-HEADER.
    let (injHeaders, injDiags) =
      ownedHeaders(entityRefId = "abc\nBcc: evil@example.com")
    check injDiags.len == 1
    check injDiags[0].code == codeMimeHeader
    check countNamed(injHeaders, "X-Entity-Ref-ID") == 0

proc uriDiags(uri: string; mailto = ""): seq[EmailDiagnostic] =
  validateUnsubscribe(Unsubscribe(httpsUri: uri, mailto: mailto))

const urlencoded = "application/x-www-form-urlencoded"

proc oneClick(meth, contentType, body: string;
              extra: seq[(string, string)] = @[]): OneClickVerdict =
  var headers = @[("Content-Type", contentType)]
  headers.add(extra)
  checkOneClickRequest(OneClickRequest(httpMethod: meth,
    headers: headers, body: body))

proc formData(fields: seq[(string, string)]; boundary = "b0UnD"): string =
  for (name, value) in fields:
    result.add("--" & boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"" & name & "\"\r\n\r\n" &
      value & "\r\n")
  result.add("--" & boundary & "--\r\n")

suite "unsubscribe URI validation and the one-click endpoint":
  test "the https URI must be one well-formed absolute URI":
    # rule: R-SND-01
    # Accepted: escapes, a port, an IPv6 host, a query, upper-case
    # scheme.
    for ok in [tokenUri,
        "https://example.com:8443/u/opaque-token-0123456789",
        "HTTPS://example.com/u/opaque%2Dtoken-0123456789",
        "https://[2001:db8::1]/u/opaque-token-0123456789",
        "https://example.com/u?t=opaque-token-0123456789&l=news"]:
      check uriDiags(ok).len == 0
    # Rejected, each with E-MIME-HEADER naming the problem.
    for (bad, why) in [
        ("https://example.com/u/opaque token-0123456789", "' '"),
        ("https://example.com/u/<opaque-token-0123456789>", "'<'"),
        ("https://example.com/u/\"opaque-token-0123456789", "'\"'"),
        ("https://example.com/u/tökén-opaque-0123456789", "0xC3"),
        ("https://example.com/u/opaque-token-0123456789%zz", "%XX"),
        ("https://example.com/u/opaque-token-0123456789%4", "%XX"),
        ("https://user:pw@example.com/u/opaque-token-0123456789",
          "userinfo"),
        ("https:///u/opaque-token-0123456789", "no host"),
        ("https://example.com:80a/u/opaque-token-0123456789", "port"),
        ("https://example.com/u/" & "t".repeat(maxUnsubUriLen), "at most"),
        ("https://example.com/u/opaque-token-0123456789\t", "0x09"),
        ("ftp://example.com/u/opaque-token-0123456789", "https"),
        ("", "empty")]:
      let d = uriDiags(bad)
      check d.len == 1
      check d[0].code == codeMimeHeader
      check d[0].rules == @["R-SND-01"]
      check why in d[0].message
    # The mailto half: a mailto: URI with an addr-spec and URI syntax.
    check uriDiags(tokenUri, "mailto:unsub@example.com?subject=x").len == 0
    for bad in ["mailto:unsub example.com", "mailto:unsub@",
        "mailto:@example.com", "mailto:un sub@example.com",
        "mailto:unsub@example.com>", "unsub@example.com"]:
      let d = uriDiags(tokenUri, bad)
      check d.len == 1
      check d[0].code == codeMimeHeader
    # An accepted URI keeps the header on one line well under 998.
    let (headers, _) = ownedHeaders(unsubscribe = some(Unsubscribe(
      httpsUri: "https://example.com/u/" & "t".repeat(maxUnsubUriLen - 30),
      mailto: "mailto:unsub@example.com")))
    let folded = foldHeader("List-Unsubscribe",
      valueOf(headers, "List-Unsubscribe"))
    for line in folded.split("\r\n"):
      check line.len <= maxHeaderLine
    check folded.replace("\r\n ", " ") == "List-Unsubscribe: " &
      valueOf(headers, "List-Unsubscribe")

  test "the one-click check accepts both RFC 8058 body shapes":
    # rule: R-SND-03
    let form = oneClick("POST", urlencoded, "List-Unsubscribe=One-Click")
    check form.ok
    check form.reason == ""
    # Percent- and plus-escaping decode before the comparison.
    check oneClick("POST", urlencoded & "; charset=utf-8",
      "List%2DUnsubscribe=One%2DClick").ok
    let multi = oneClick("POST", "multipart/form-data; boundary=b0UnD",
      formData(@[("List-Unsubscribe", "One-Click")]))
    check multi.ok
    check oneClick("POST", "Multipart/Form-Data; boundary=\"q q\"",
      formData(@[("List-Unsubscribe", "One-Click")], "q q")).ok
    # Header names match case-insensitively.
    check checkOneClickRequest(OneClickRequest(httpMethod: "POST",
      headers: @[("content-type", urlencoded)],
      body: "List-Unsubscribe=One-Click")).ok

  test "the one-click check refuses anything else":
    # rule: R-SND-03
    proc refused(v: OneClickVerdict; why: string): bool =
      not v.ok and why in v.reason
    let body = "List-Unsubscribe=One-Click"
    check refused(oneClick("GET", urlencoded, body), "POST")
    check refused(oneClick("post", urlencoded, body), "POST")
    check refused(oneClick("POST", urlencoded, body,
      @[("Cookie", "session=abc")]), "cookies")
    check refused(oneClick("POST", urlencoded, body,
      @[("authorization", "Basic YTpi")]), "authorization")
    check refused(oneClick("POST", "text/plain", body), "multipart")
    check refused(oneClick("POST", "", body), "multipart")
    check refused(oneClick("POST", urlencoded, "List-Unsubscribe=Yes"),
      "One-Click")
    check refused(oneClick("POST", urlencoded, ""), "'='")
    check refused(oneClick("POST", urlencoded,
      body & "&email=a%40example.com"), "single field")
    check refused(oneClick("POST", urlencoded, "List-Unsubscribe=One%2"),
      "%XX")
    check refused(oneClick("POST", "multipart/form-data", formData(
      @[("List-Unsubscribe", "One-Click")])), "boundary")
    check refused(oneClick("POST", "multipart/form-data; boundary=b0UnD",
      formData(@[("List-Unsubscribe", "Yes")])), "One-Click")
    check refused(oneClick("POST", "multipart/form-data; boundary=b0UnD",
      formData(@[("List-Unsubscribe", "One-Click"), ("x", "y")])),
      "single field")
    check refused(oneClick("POST", "multipart/form-data; boundary=b0UnD",
      "--b0UnD\r\nno blank line"), "closed")

  test "the one-click response is never a redirect":
    # rule: R-SND-03
    let okResp = oneClickResponse(OneClickVerdict(ok: true))
    check okResp.status == 200
    let badResp = oneClickResponse(OneClickVerdict(reason: "why"))
    check badResp.status == 400
    check "why" in badResp.body
    for resp in [okResp, badResp]:
      check resp.status notin 300 .. 399
      for (name, _) in resp.headers:
        check name.toLowerAscii() != "location"
    # The accepted body is exactly the header value the library emits.
    check oneClickKey & "=" & oneClickValue == listUnsubscribePostValue
