# rule: R-SND-07
# rule: R-SND-08
## Gmail markup: the typed blocks a template attaches to its
## `mailDocument`, their checks (`E-MARKUP-REQUIRED`, `E-MARKUP-VALUE`),
## their JSON-LD and its escaping, and where the render writes them: at
## the end of the head, one `<script type="application/ld+json">` per
## block without an error, counted in their own size entry and in no
## CSS budget, and invisible to the plain-text part.
##
## The schema.org validation of the emitted blocks (against the pinned
## vocabulary) is `tests/t6_gmail_markup_json_ld_valid.nim`, which reads
## files; this file is backend-independent, so `just test` also runs it
## on JS.
import std/[json, strutils, unittest]
import isonim_email

proc plainTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Invoice 7",
        preheader = "Invoice 7 is ready."):
      h1: text "Invoice 7"
      p: text "Your invoice for October is ready."

proc invoice(): InvoiceMarkup =
  InvoiceMarkup(
    provider: MarkupParty(name: "Acme"),
    totalPaymentDue: MarkupPrice(price: "70.00", priceCurrency: "USD"),
    minimumPaymentDue: MarkupPrice(price: "$20.00"),
    paymentDue: "2026-11-01T08:00:00+00:00",
    scheduledPaymentDate: "2026-10-30",
    paymentStatus: psDue,
    accountId: "123-456-789",
    customer: MarkupParty(name: "Ada Lovelace"),
    orderNumber: "7")

proc viewAction(): EmailMessageMarkup =
  EmailMessageMarkup(action: MarkupAction(kind: maView,
    name: "View invoice", url: "https://example.com/invoices/7"),
    description: "Invoice 7 from Acme")

proc parcel(): ParcelDeliveryMarkup =
  ParcelDeliveryMarkup(
    deliveryAddress: MarkupAddress(streetAddress: "24 Example Plaza",
      addressLocality: "Springfield", addressRegion: "IL",
      addressCountry: "US", postalCode: "62701"),
    expectedArrivalUntil: "2026-10-07T12:00:00-05:00",
    carrier: MarkupOrganization(name: "Acme Express"),
    itemShipped: @[MarkupProduct(name: "Coastline print")],
    orderNumber: "2041",
    merchant: MarkupParty(name: "Acme"))

var nextBlocks: seq[GmailMarkup]
  ## The blocks `markedTpl` attaches (set before each render).

proc markedTpl(r: EmailRenderer; x: int): EmailNode =
  result = plainTpl(r, x)
  for m in nextBlocks:
    result.addGmailMarkup(m)

proc renderWith(blocks: seq[GmailMarkup]; strict = false): RenderedEmail =
  nextBlocks = blocks
  renderEmail(markedTpl, 0, strict = strict)

const openTag = "<script type=\"application/ld+json\">"
const closeTag = "</script>"

proc scripts(html: string): seq[string] =
  ## The text of each JSON-LD script element, read as a parser in script
  ## data reads it: from the start tag to the first `</script`.
  var at = 0
  while true:
    let a = html.find(openTag, at)
    if a < 0:
      break
    let b = html.toLowerAscii().find("</script", a + openTag.len)
    result.add(html[a + openTag.len ..< b])
    at = b

proc codesOf(diags: seq[EmailDiagnostic]): seq[string] =
  for d in diags:
    if d.code.startsWith("E-MARKUP"):
      result.add(d.code)

proc messagesOf(diags: seq[EmailDiagnostic]): string =
  for d in diags:
    result.add(d.message & "\n")

suite "Gmail markup":
  test "the JSON-LD of each type parses and says what was given":
    # rule: R-SND-07
    let inv = parseJson(toJsonLd(gmailMarkup(invoice())))
    check inv["@context"].getStr == "http://schema.org"
    check inv["@type"].getStr == "Invoice"
    check inv["provider"]["@type"].getStr == "Organization"
    check inv["provider"]["name"].getStr == "Acme"
    check inv["totalPaymentDue"]["@type"].getStr == "PriceSpecification"
    check inv["totalPaymentDue"]["price"].getStr == "70.00"
    check inv["totalPaymentDue"]["priceCurrency"].getStr == "USD"
    check inv["minimumPaymentDue"]["price"].getStr == "$20.00"
    check inv["paymentStatus"].getStr == "PaymentDue"
    check inv["referencesOrder"]["orderNumber"].getStr == "7"
    check inv["customer"]["name"].getStr == "Ada Lovelace"
    let msg = parseJson(toJsonLd(gmailMarkup(viewAction())))
    check msg["@type"].getStr == "EmailMessage"
    check msg["potentialAction"]["@type"].getStr == "ViewAction"
    check msg["potentialAction"]["url"].getStr ==
      "https://example.com/invoices/7"
    check not msg.hasKey("publisher") # not given: omitted
    let confirm = parseJson(toJsonLd(gmailMarkup(EmailMessageMarkup(
      action: MarkupAction(kind: maConfirm, name: "Approve",
        handlerUrl: "https://example.com/approve?t=x")))))
    check confirm["potentialAction"]["@type"].getStr == "ConfirmAction"
    check confirm["potentialAction"]["handler"]["@type"].getStr ==
      "HttpActionHandler"
    check confirm["potentialAction"]["handler"]["url"].getStr ==
      "https://example.com/approve?t=x"
    var two = parcel()
    two.itemShipped.add(MarkupProduct(name: "Oak frame"))
    two.orderStatus = osInTransit
    let par = parseJson(toJsonLd(gmailMarkup(two)))
    check par["@type"].getStr == "ParcelDelivery"
    check par["deliveryAddress"]["postalCode"].getStr == "62701"
    check par["itemShipped"].kind == JArray
    check par["itemShipped"].len == 2
    check par["partOfOrder"]["merchant"]["name"].getStr == "Acme"
    check par["partOfOrder"]["orderStatus"].getStr ==
      "http://schema.org/OrderInTransit"
    check not par.hasKey("originAddress")
    # One item is an object, as Gmail's examples write it.
    check parseJson(toJsonLd(gmailMarkup(parcel())))["itemShipped"].kind ==
      JObject
    # Deterministic: the same block, the same bytes.
    check toJsonLd(gmailMarkup(invoice())) == toJsonLd(gmailMarkup(invoice()))

  test "strings are escaped so no value can end the script element":
    # rule: R-SND-08
    let hostile = "</script><script>alert(1)</script><!-- \"q\" \\ & > " &
      "\n\t\x01 \xE2\x80\xA8\xE2\x80\xA9 ünï 漢字"
    let lit = escapeJsonLdString(hostile)
    check '<' notin lit
    check '>' notin lit
    check '&' notin lit
    check "\xE2\x80\xA8" notin lit
    check "\xE2\x80\xA9" notin lit
    check "\\u003c/script\\u003e" in lit
    check "\\u0026" in lit
    check "\\u2028" in lit and "\\u2029" in lit
    check "\\u0001" in lit
    check "ünï 漢字" in lit # other UTF-8 passes through
    # A JSON parser reads the value back unchanged.
    check parseJson(lit).getStr == hostile
    # Rendered: the element's text runs to the end tag the library wrote,
    # and nothing a value holds ends it early.
    var m = viewAction()
    m.description = hostile
    m.action.name = "</SCRIPT >"
    let res = renderWith(@[gmailMarkup(m)])
    check codesOf(res.diagnostics).len == 0
    let found = scripts(res.html)
    check found.len == 1
    check found[0] == toJsonLd(gmailMarkup(m))
    check '<' notin found[0]
    let back = parseJson(found[0])
    check back["description"].getStr == hostile
    check back["potentialAction"]["name"].getStr == "</SCRIPT >"
    check res.html.count("<script") == 1
    check res.html.toLowerAscii().count("</script") == 1

  test "the blocks are written at the end of the head, in order":
    # rule: R-SND-07
    let res = renderWith(@[gmailMarkup(invoice()), gmailMarkup(viewAction())])
    check codesOf(res.diagnostics).len == 0
    let found = scripts(res.html)
    check found.len == 2
    check found[0] == toJsonLd(gmailMarkup(invoice()))
    check found[1] == toJsonLd(gmailMarkup(viewAction()))
    let head = res.html[0 ..< res.html.find("</head>")]
    check head.rfind("</style>") < head.find(openTag)
    check head.endsWith(closeTag)
    check res.html.find(openTag) > res.html.find("<![endif]-->",
      res.html.rfind("<!--[if lte mso 11]>"))
    # Without markup, no script element at all.
    check "<script" notin renderWith(@[]).html

  test "the markup is invisible: the body and the text part are unchanged":
    # rule: R-SND-07
    let plain = renderWith(@[])
    let marked = renderWith(@[gmailMarkup(invoice()),
      gmailMarkup(viewAction()), gmailMarkup(parcel())])
    var stripped = marked.html
    for s in scripts(marked.html):
      stripped = stripped.replace(openTag & s & closeTag, "")
    check stripped == plain.html
    check marked.text == plain.text
    check marked.headCssBytes == plain.headCssBytes

  test "the blocks have their own size entry, in the size":
    # rule: R-SND-07
    let plain = renderWith(@[])
    let marked = renderWith(@[gmailMarkup(invoice()), gmailMarkup(parcel())])
    var bytes = 0
    for s in scripts(marked.html):
      bytes += openTag.len + s.len + closeTag.len
    var keys: seq[string] = @[]
    var total = 0
    for (k, v) in marked.sizeBreakdown:
      keys.add(k)
      total += v
    check "Gmail markup" in keys
    check total == marked.htmlBytes
    for (k, v) in marked.sizeBreakdown:
      if k == "Gmail markup":
        check v == bytes
    for (k, v) in plain.sizeBreakdown:
      if k == "Gmail markup":
        check v == 0
    check marked.htmlBytes == plain.htmlBytes + bytes
    # Every other entry is the same as without the markup.
    for i in 0 ..< plain.sizeBreakdown.len:
      if plain.sizeBreakdown[i][0] != "Gmail markup":
        check marked.sizeBreakdown[i] == plain.sizeBreakdown[i]

  test "a missing required property is E-MARKUP-REQUIRED and not written":
    # rule: R-SND-07
    proc required(m: GmailMarkup): seq[string] =
      codesOf(checkGmailMarkup(m))
    check required(gmailMarkup(invoice())).len == 0
    check required(gmailMarkup(viewAction())).len == 0
    check required(gmailMarkup(parcel())).len == 0
    # EmailMessage: the action's label and its URL.
    var m = viewAction()
    m.action.name = ""
    check required(gmailMarkup(m)) == @["E-MARKUP-REQUIRED"]
    m = viewAction()
    m.action.url = ""
    check required(gmailMarkup(m)) == @["E-MARKUP-REQUIRED"]
    m = EmailMessageMarkup(action: MarkupAction(kind: maSave, name: "Save"))
    check required(gmailMarkup(m)) == @["E-MARKUP-REQUIRED"]
    check "potentialAction.handler.url" in
      messagesOf(checkGmailMarkup(gmailMarkup(m)))
    m = viewAction()
    m.publisher = MarkupOrganization(url: "https://example.com/")
    check required(gmailMarkup(m)) == @["E-MARKUP-REQUIRED"]
    # Invoice: the provider and an amount (the library's requirement).
    var v = invoice()
    v.provider = MarkupParty()
    check required(gmailMarkup(v)) == @["E-MARKUP-REQUIRED"]
    v = invoice()
    v.totalPaymentDue = MarkupPrice()
    check required(gmailMarkup(v)).len == 0 # the minimum is still there
    v.minimumPaymentDue = MarkupPrice()
    check required(gmailMarkup(v)) == @["E-MARKUP-REQUIRED"]
    v = invoice()
    v.totalPaymentDue = MarkupPrice(priceCurrency: "USD")
    check required(gmailMarkup(v)) == @["E-MARKUP-REQUIRED"]
    # ParcelDelivery: each required field on its own.
    for field in ["street", "locality", "region", "country", "postal",
        "until", "carrier", "items", "itemName", "order", "merchant"]:
      var p = parcel()
      case field
      of "street": p.deliveryAddress.streetAddress = ""
      of "locality": p.deliveryAddress.addressLocality = ""
      of "region": p.deliveryAddress.addressRegion = ""
      of "country": p.deliveryAddress.addressCountry = ""
      of "postal": p.deliveryAddress.postalCode = ""
      of "until": p.expectedArrivalUntil = ""
      of "carrier": p.carrier = MarkupOrganization()
      of "items": p.itemShipped = @[]
      of "itemName": p.itemShipped = @[MarkupProduct(sku: "X1")]
      of "order": p.orderNumber = ""
      of "merchant": p.merchant = MarkupParty()
      else: discard
      checkpoint(field)
      check required(gmailMarkup(p)) == @["E-MARKUP-REQUIRED"]
    # Optional fields stay optional.
    var p = parcel()
    p.deliveryAddress.name = ""
    p.originAddress = MarkupAddress()
    check required(gmailMarkup(p)).len == 0
    # A block with an error is not written; the others are.
    var broken = parcel()
    broken.carrier = MarkupOrganization()
    let res = renderWith(@[gmailMarkup(invoice()), gmailMarkup(broken)])
    check codesOf(res.diagnostics) == @["E-MARKUP-REQUIRED"]
    for d in res.diagnostics:
      if d.code == "E-MARKUP-REQUIRED":
        check d.severity == sevError
        check d.rules == @["R-SND-07"]
        check "carrier.name" in d.message
        check "ParcelDelivery" in d.message
    check scripts(res.html) == @[toJsonLd(gmailMarkup(invoice()))]
    expect EmailRenderError:
      discard renderWith(@[gmailMarkup(broken)], strict = true)
    check renderWith(@[gmailMarkup(parcel())], strict = true).html.count(
      openTag) == 1

  test "a value of the wrong form is E-MARKUP-VALUE and not written":
    # rule: R-SND-07
    proc value(m: GmailMarkup): seq[string] =
      codesOf(checkGmailMarkup(m))
    var m = viewAction()
    for url in ["http://example.com/x", "/invoices/7", "javascript:x()",
        "https://", "https:///x", "https://ex ample.com/", "mailto:a@b.c",
        "https://example.com/\"x"]:
      m.action.url = url
      checkpoint(url)
      check value(gmailMarkup(m)) == @["E-MARKUP-VALUE"]
    m = viewAction()
    m.action.handlerUrl = "https://example.com/h"
    check value(gmailMarkup(m)) == @["E-MARKUP-VALUE"] # wrong kind
    m = EmailMessageMarkup(action: MarkupAction(kind: maConfirm, name: "Ok",
      handlerUrl: "https://example.com/h", url: "https://example.com/u"))
    check value(gmailMarkup(m)) == @["E-MARKUP-VALUE"]
    var v = invoice()
    for due in ["2026-11-01", "2026-11-01 08:00:00+00:00",
        "2026-13-01T08:00:00Z", "2026-11-01T24:00Z", "2026-11-01T08:00",
        "2026-11-01T08:00:00", "2026-11-01T08:00:00.5",
        "2026-11-01T08:00:00+0000", "2026-11-01T08:00:00.Z", "tomorrow"]:
      v.paymentDue = due
      checkpoint(due)
      check value(gmailMarkup(v)) == @["E-MARKUP-VALUE"]
    for due in ["2026-11-01T08:00Z", "2026-11-01T08:00:00Z",
        "2026-11-01T08:00:00.250+05:30", "2026-11-01T23:59:59-08:00"]:
      v.paymentDue = due
      checkpoint(due)
      check value(gmailMarkup(v)).len == 0
    v = invoice()
    v.scheduledPaymentDate = "30/10/2026"
    check value(gmailMarkup(v)) == @["E-MARKUP-VALUE"]
    v = invoice()
    v.totalPaymentDue.priceCurrency = "usd"
    check value(gmailMarkup(v)) == @["E-MARKUP-VALUE"]
    v = invoice()
    v.accountId = "\xFF\xFE"
    check value(gmailMarkup(v)) == @["E-MARKUP-VALUE"]
    var p = parcel()
    p.trackingUrl = "http://example.com/track"
    check value(gmailMarkup(p)) == @["E-MARKUP-VALUE"]
    p = parcel()
    p.itemShipped[0].image = "cid:print"
    check value(gmailMarkup(p)) == @["E-MARKUP-VALUE"]
    let res = renderWith(@[gmailMarkup(p)])
    check codesOf(res.diagnostics) == @["E-MARKUP-VALUE"]
    check "<script" notin res.html

  test "every URL must be valid UTF-8":
    # rule: R-SND-07
    # A byte that is not UTF-8 in any URL field is E-MARKUP-VALUE, and
    # the block (with the byte) is not written.
    const badUrl = "https://example.com/\xFF"
    proc value(m: GmailMarkup): seq[string] =
      codesOf(checkGmailMarkup(m))
    var cases: seq[(string, GmailMarkup)] = @[]
    var m = viewAction()
    m.action.url = badUrl
    cases.add(("action url", gmailMarkup(m)))
    m = EmailMessageMarkup(action: MarkupAction(kind: maConfirm,
      name: "Approve", handlerUrl: badUrl))
    cases.add(("handlerUrl", gmailMarkup(m)))
    m = viewAction()
    m.publisher = MarkupOrganization(name: "Acme", url: badUrl)
    cases.add(("publisher url", gmailMarkup(m)))
    var p = parcel()
    p.carrier.url = badUrl
    cases.add(("carrier url", gmailMarkup(p)))
    p = parcel()
    p.itemShipped[0].url = badUrl
    cases.add(("product url", gmailMarkup(p)))
    p = parcel()
    p.itemShipped[0].image = badUrl
    cases.add(("product image", gmailMarkup(p)))
    p = parcel()
    p.trackingUrl = badUrl
    cases.add(("trackingUrl", gmailMarkup(p)))
    for (what, mk) in cases:
      checkpoint(what)
      check value(mk) == @["E-MARKUP-VALUE"]
      check "valid UTF-8" in messagesOf(checkGmailMarkup(mk))
      let res = renderWith(@[mk])
      check "<script" notin res.html
      check "\xFF" notin res.html
    # The same URLs with a valid multi-byte character pass.
    var ok = parcel()
    ok.trackingUrl = "https://example.com/zh/跟踪"
    check value(gmailMarkup(ok)).len == 0

  test "organisations carry a url only where Gmail lists one":
    # rule: R-SND-07
    # The invoice's provider and customer and the parcel's merchant are a
    # name alone; the carrier and the publisher may carry a url.
    let inv = parseJson(toJsonLd(gmailMarkup(invoice())))
    check inv["provider"].len == 2 # @type and name
    check not inv["provider"].hasKey("url")
    check not inv["customer"].hasKey("url")
    var p = parcel()
    p.carrier.url = "https://express.example.com/"
    let par = parseJson(toJsonLd(gmailMarkup(p)))
    check not par["partOfOrder"]["merchant"].hasKey("url")
    check par["carrier"]["url"].getStr == "https://express.example.com/"
    var m = viewAction()
    m.publisher = MarkupOrganization(name: "Acme", url: "https://example.com/")
    check parseJson(toJsonLd(gmailMarkup(m)))["publisher"]["url"].getStr ==
      "https://example.com/"

  test "markup belongs to the mailDocument":
    # rule: R-SND-07
    let r = EmailRenderer()
    let p = r.createElement("p")
    expect EmailRenderError:
      p.addGmailMarkup(gmailMarkup(invoice()))
    let doc = r.createElement("mailDocument")
    doc.addGmailMarkup(gmailMarkup(invoice()))
    check doc.markup.len == 1
