# rule: R-SND-01
# rule: R-SND-02
# rule: R-SND-05
## The headers the library owns. One-click
## unsubscribe emits both RFC 8058 headers with one https URI plus the
## optional mailto, and nothing without the option; the URI needs an
## opaque token (warning) and the https scheme (error); transactional
## helpers set `Auto-Submitted`, and the Gmail ids ride along.
##
## Backend-independent (pure string headers), so `just test` also runs
## it on JS.
import std/[options, unittest]
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
