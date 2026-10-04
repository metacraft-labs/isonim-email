## isonim_email/gmail_markup.nim — Gmail markup: checks and JSON-LD.
##
## The typed blocks of `markup_types.nim` (an `EmailMessage` with a
## `ViewAction`, `ConfirmAction` or `SaveAction`; an `Invoice`; a
## `ParcelDelivery`) are attached to a `mailDocument` with
## `addGmailMarkup`. The render checks each one (`checkGmailMarkup`,
## catalogue R-SND-07: `E-MARKUP-REQUIRED` for a missing property,
## `E-MARKUP-VALUE` for a value of the wrong form) and writes the blocks
## without an error into the head as `<script type="application/ld+json">`
## elements (`lower/document.nim`).
##
## The JSON is written here, one line per block, keys in a fixed order,
## so the same block always yields the same bytes. Its strings are
## escaped for the script element they sit in (R-SND-08): `<`, `>` and
## `&` become `\u003c`, `\u003e` and `\u0026`, so no value can end the
## element with `</script>` or start `<!--`, and U+2028/U+2029 become
## `\u2028`/`\u2029`.
##
## Gmail acts on the blocks only for authenticated, registered senders:
## see `docs/gmail-markup.md`.
##
## Pure string work: identical on the C and JS targets.

import std/[strutils, unicode]
import ./renderer
import ./target
import ./diagnostics

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = {cfGmailWeb, cfGmailApp}

export markup_types

const schemaContext* = "http://schema.org"
  ## The `@context` every block names, as Gmail's markup reference
  ## writes it.

proc gmailMarkup*(m: EmailMessageMarkup): GmailMarkup =
  GmailMarkup(kind: gmEmailMessage, message: m)

proc gmailMarkup*(m: InvoiceMarkup): GmailMarkup =
  GmailMarkup(kind: gmInvoice, invoice: m)

proc gmailMarkup*(m: ParcelDeliveryMarkup): GmailMarkup =
  GmailMarkup(kind: gmParcelDelivery, parcel: m)

proc addGmailMarkup*(doc: EmailNode; markup: GmailMarkup) =
  ## Attaches one block to `doc`, which must be a `mailDocument`; the
  ## render writes the blocks in the order they were added. Raises
  ## `EmailRenderError` on any other node: markup belongs to the
  ## message, and a block on an inner element would be lost.
  if doc == nil or doc.kind != enElement or doc.tag != "mailDocument":
    raise newException(EmailRenderError, codeStructNesting & ": Gmail " &
      "markup is attached to the mailDocument, not to " &
      (if doc == nil: "nil" else: "<" & doc.tag & ">") & " (R-SND-07)")
  doc.markup.add(markup)

proc typeName*(m: GmailMarkup): string =
  ## The block's schema.org type.
  case m.kind
  of gmEmailMessage: "EmailMessage"
  of gmInvoice: "Invoice"
  of gmParcelDelivery: "ParcelDelivery"

# --- JSON ----------------------------------------------------------------

const hexDigits = "0123456789abcdef"

proc unicodeEscape(code: int): string =
  "\\u" & hexDigits[(code shr 12) and 15] & hexDigits[(code shr 8) and 15] &
    hexDigits[(code shr 4) and 15] & hexDigits[code and 15]

proc escapeJsonLdString*(s: string): string =
  ## `s` as a JSON string literal, quotes included, safe inside a
  ## `<script>` element (R-SND-08): JSON's own escapes (`"`, `\`, the
  ## control characters), plus `<`, `>`, `&` as `\u003c`, `\u003e`,
  ## `\u0026` and U+2028/U+2029 as `\u2028`/`\u2029`. Other UTF-8
  ## passes through. A JSON parser reads back exactly `s`.
  result = newStringOfCap(s.len + 2)
  result.add '"'
  var i = 0
  while i < s.len:
    let c = s[i]
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '<', '>', '&': result.add unicodeEscape(ord(c))
    of '\x00' .. '\x07', '\x0B', '\x0E' .. '\x1F':
      result.add unicodeEscape(ord(c))
    of '\xE2':
      # U+2028 and U+2029 (E2 80 A8 / E2 80 A9): line terminators in
      # some script readers, escaped as is common practice.
      if i + 2 < s.len and s[i + 1] == '\x80' and s[i + 2] in {'\xA8', '\xA9'}:
        result.add(if s[i + 2] == '\xA8': "\\u2028" else: "\\u2029")
        i += 2
      else:
        result.add c
    else: result.add c
    inc i
  result.add '"'

type JsonFields = seq[(string, string)]
  ## An object's members in writing order: the key and the value's JSON.

proc obj(fields: JsonFields): string =
  result = "{"
  for i, (k, v) in fields:
    if i > 0:
      result.add ","
    result.add escapeJsonLdString(k)
    result.add ":"
    result.add v
  result.add "}"

proc addStr(f: var JsonFields; key, value: string) =
  ## A text member, omitted when `value` is "".
  if value.len > 0:
    f.add((key, escapeJsonLdString(value)))

proc typed(t: string): JsonFields = @[("@type", escapeJsonLdString(t))]

proc given(o: MarkupOrganization): bool = o.name.len > 0 or o.url.len > 0
proc given(o: MarkupParty): bool = o.name.len > 0
proc given(p: MarkupPrice): bool = p.price.len > 0 or p.priceCurrency.len > 0
proc given(a: MarkupAddress): bool =
  a.name.len > 0 or a.streetAddress.len > 0 or a.addressLocality.len > 0 or
    a.addressRegion.len > 0 or a.addressCountry.len > 0 or
    a.postalCode.len > 0

proc json(o: MarkupOrganization): string =
  var f = typed("Organization")
  f.addStr("name", o.name)
  f.addStr("url", o.url)
  obj(f)

proc json(o: MarkupParty): string =
  var f = typed("Organization")
  f.addStr("name", o.name)
  obj(f)

proc json(p: MarkupPrice): string =
  var f = typed("PriceSpecification")
  f.addStr("price", p.price)
  f.addStr("priceCurrency", p.priceCurrency)
  obj(f)

proc json(a: MarkupAddress): string =
  var f = typed("PostalAddress")
  f.addStr("name", a.name)
  f.addStr("streetAddress", a.streetAddress)
  f.addStr("addressLocality", a.addressLocality)
  f.addStr("addressRegion", a.addressRegion)
  f.addStr("addressCountry", a.addressCountry)
  f.addStr("postalCode", a.postalCode)
  obj(f)

proc json(p: MarkupProduct): string =
  var f = typed("Product")
  f.addStr("name", p.name)
  f.addStr("url", p.url)
  f.addStr("image", p.image)
  f.addStr("sku", p.sku)
  f.addStr("description", p.description)
  obj(f)

proc json(a: MarkupAction): string =
  var f = typed($a.kind)
  f.addStr("name", a.name)
  case a.kind
  of maView:
    f.addStr("url", a.url)
  of maConfirm, maSave:
    var h = typed("HttpActionHandler")
    h.addStr("url", a.handlerUrl)
    f.add(("handler", obj(h)))
  obj(f)

proc toJsonLd*(m: GmailMarkup): string =
  ## The block's JSON-LD: one line, `@context` then `@type`, then the
  ## properties in the order `markup_types.nim` declares them, omitted
  ## when empty; nested objects carry their `@type`. Strings are escaped
  ## by `escapeJsonLdString` (R-SND-08).
  var f: JsonFields = @[("@context", escapeJsonLdString(schemaContext)),
    ("@type", escapeJsonLdString(typeName(m)))]
  case m.kind
  of gmEmailMessage:
    let e = m.message
    f.add(("potentialAction", json(e.action)))
    f.addStr("description", e.description)
    if given(e.publisher):
      f.add(("publisher", json(e.publisher)))
  of gmInvoice:
    let v = m.invoice
    if given(v.provider):
      f.add(("provider", json(v.provider)))
    if given(v.totalPaymentDue):
      f.add(("totalPaymentDue", json(v.totalPaymentDue)))
    if given(v.minimumPaymentDue):
      f.add(("minimumPaymentDue", json(v.minimumPaymentDue)))
    f.addStr("paymentDue", v.paymentDue)
    f.addStr("scheduledPaymentDate", v.scheduledPaymentDate)
    # Gmail's Invoice reference writes the status as the member's name.
    f.addStr("paymentStatus", $v.paymentStatus)
    f.addStr("accountId", v.accountId)
    f.addStr("confirmationNumber", v.confirmationNumber)
    f.addStr("paymentMethodId", v.paymentMethodId)
    if given(v.customer):
      f.add(("customer", json(v.customer)))
    if v.orderNumber.len > 0:
      var o = typed("Order")
      o.addStr("orderNumber", v.orderNumber)
      f.add(("referencesOrder", obj(o)))
  of gmParcelDelivery:
    let p = m.parcel
    f.add(("deliveryAddress", json(p.deliveryAddress)))
    if given(p.originAddress):
      f.add(("originAddress", json(p.originAddress)))
    f.addStr("expectedArrivalFrom", p.expectedArrivalFrom)
    f.addStr("expectedArrivalUntil", p.expectedArrivalUntil)
    f.add(("carrier", json(p.carrier)))
    if p.itemShipped.len == 1:
      f.add(("itemShipped", json(p.itemShipped[0])))
    elif p.itemShipped.len > 1:
      var items = "["
      for i, item in p.itemShipped:
        if i > 0:
          items.add ","
        items.add json(item)
      items.add "]"
      f.add(("itemShipped", items))
    f.addStr("trackingNumber", p.trackingNumber)
    f.addStr("trackingUrl", p.trackingUrl)
    var o = typed("Order")
    o.addStr("orderNumber", p.orderNumber)
    o.add(("merchant", json(p.merchant)))
    if p.orderStatus != osNone:
      # Gmail's order reference writes the status as its schema.org IRI.
      o.addStr("orderStatus", schemaContext & "/" & $p.orderStatus)
    f.add(("partOfOrder", obj(o)))
  obj(f)

# --- Checks ----------------------------------------------------------------

proc isHttpsUrl*(url: string): bool =
  ## An absolute https URL with a host and nothing a JSON-LD consumer
  ## or a mail pipeline could misread (white space, quotes, angle
  ## brackets, backslashes, controls).
  let lower = url.toLowerAscii()
  if not lower.startsWith("https://") or url.len <= "https://".len or
      url["https://".len] in {'/', '?', '#', '@'}:
    return false
  for c in url:
    if c <= ' ' or c in {'"', '\'', '<', '>', '\\', '`', '\x7F'}:
      return false
  true

proc digitsAt(s: string; at, n: int): int =
  ## The number in `s[at ..< at + n]`, -1 unless it is n digits.
  if at + n > s.len:
    return -1
  result = 0
  for i in at ..< at + n:
    if s[i] notin Digits:
      return -1
    result = result * 10 + (ord(s[i]) - ord('0'))

proc dateEnd(s: string): int =
  ## The end of a valid `YYYY-MM-DD` at the start of `s`, or -1.
  if s.len < 10 or s[4] != '-' or s[7] != '-':
    return -1
  let y = digitsAt(s, 0, 4)
  let mo = digitsAt(s, 5, 2)
  let d = digitsAt(s, 8, 2)
  if y < 0 or mo < 1 or mo > 12 or d < 1 or d > 31:
    return -1
  10

proc isIsoDate*(s: string): bool =
  ## schema.org `Date`: `YYYY-MM-DD`.
  dateEnd(s) == 10 and s.len == 10

proc isIsoDateTime*(s: string): bool =
  ## schema.org `DateTime` as Gmail's examples write it:
  ## `YYYY-MM-DDThh:mm[:ss[.f…]]` followed by `Z` or `±hh:mm`.
  if dateEnd(s) != 10 or s.len < 17 or s[10] != 'T' or s[13] != ':':
    return false
  let h = digitsAt(s, 11, 2)
  let mi = digitsAt(s, 14, 2)
  if h < 0 or h > 23 or mi < 0 or mi > 59:
    return false
  var i = 16
  if i < s.len and s[i] == ':':
    let sec = digitsAt(s, i + 1, 2)
    if sec < 0 or sec > 59:
      return false
    i += 3
    if i < s.len and s[i] == '.':
      inc i
      let start = i
      while i < s.len and s[i] in Digits:
        inc i
      if i == start:
        return false
  if i == s.len - 1 and s[i] == 'Z':
    return true
  if i + 6 == s.len and s[i] in {'+', '-'} and s[i + 3] == ':':
    let oh = digitsAt(s, i + 1, 2)
    let om = digitsAt(s, i + 4, 2)
    return oh >= 0 and oh <= 23 and om >= 0 and om <= 59
  false

proc isCurrencyCode(s: string): bool =
  s.len == 3 and s[0] in {'A' .. 'Z'} and s[1] in {'A' .. 'Z'} and
    s[2] in {'A' .. 'Z'}

proc checkGmailMarkup*(m: GmailMarkup;
    origin = SourceSpan()): seq[EmailDiagnostic] =
  ## R-SND-07's checks of one block: `E-MARKUP-REQUIRED` for each
  ## property Gmail's reference requires (or the library requires of an
  ## Invoice) that is missing, `E-MARKUP-VALUE` for each value of the
  ## wrong form. A block with any of them is not written.
  let t = typeName(m)
  var diags: seq[EmailDiagnostic] = @[]

  proc missing(path, why: string) =
    diags.add(EmailDiagnostic(severity: sevError, code: codeMarkupRequired,
      message: "Gmail markup " & t & ": " & path & " is required (" & why &
        "); the block is not written", origin: origin,
      families: {cfGmailWeb, cfGmailApp}, rules: @["R-SND-07"]))

  proc bad(path, value, want: string) =
    diags.add(EmailDiagnostic(severity: sevError, code: codeMarkupValue,
      message: "Gmail markup " & t & ": " & path & " = '" & value &
        "' is not " & want & "; the block is not written", origin: origin,
      families: {cfGmailWeb, cfGmailApp}, rules: @["R-SND-07"]))

  const reference = "Gmail's markup reference marks it required"

  proc text(path, value: string; required = false; why = reference) =
    if value.len == 0:
      if required:
        missing(path, why)
    elif validateUtf8(value) >= 0:
      bad(path, value, "valid UTF-8")

  proc url(path, value: string; required = false) =
    if value.len == 0:
      if required:
        missing(path, reference)
    elif not isHttpsUrl(value):
      bad(path, value, "an absolute https URL")
    elif validateUtf8(value) >= 0:
      bad(path, value, "valid UTF-8")

  proc dateTime(path, value: string; required = false) =
    if value.len == 0:
      if required:
        missing(path, reference)
    elif not isIsoDateTime(value):
      bad(path, value, "an ISO 8601 date and time with a zone " &
        "(YYYY-MM-DDThh:mm[:ss](Z|±hh:mm))")

  proc org(path: string; o: MarkupOrganization; required = false;
           why = reference) =
    if not given(o):
      if required:
        missing(path & ".name", why)
      return
    text(path & ".name", o.name, required = true,
      why = "every organisation given needs its name")
    url(path & ".url", o.url)

  proc party(path: string; o: MarkupParty; required = false;
             why = reference) =
    text(path & ".name", o.name, required, why)

  proc price(path: string; p: MarkupPrice) =
    if not given(p):
      return
    text(path & ".price", p.price, required = true,
      why = "every price given needs its amount")
    if p.priceCurrency.len > 0 and not isCurrencyCode(p.priceCurrency):
      bad(path & ".priceCurrency", p.priceCurrency,
        "an ISO 4217 code (three capital letters)")

  proc address(path: string; a: MarkupAddress; required: bool) =
    if not required and not given(a):
      return
    text(path & ".name", a.name)
    text(path & ".streetAddress", a.streetAddress, required)
    text(path & ".addressLocality", a.addressLocality, required)
    text(path & ".addressRegion", a.addressRegion, required)
    text(path & ".addressCountry", a.addressCountry, required)
    text(path & ".postalCode", a.postalCode, required)

  case m.kind
  of gmEmailMessage:
    let e = m.message
    let a = e.action
    text("potentialAction.name", a.name, required = true)
    case a.kind
    of maView:
      url("potentialAction.url", a.url, required = true)
      if a.handlerUrl.len > 0:
        bad("potentialAction.handlerUrl", a.handlerUrl,
          "used by a ViewAction (it opens url; handlerUrl is for " &
          "ConfirmAction and SaveAction)")
    of maConfirm, maSave:
      url("potentialAction.handler.url", a.handlerUrl, required = true)
      if a.url.len > 0:
        bad("potentialAction.url", a.url, "used by a " & $a.kind &
          " (Gmail fetches handlerUrl; url is for ViewAction)")
    text("description", e.description)
    org("publisher", e.publisher)
  of gmInvoice:
    let v = m.invoice
    const libraryWhy = "Gmail marks no Invoice property required; " &
      "without who bills and how much the block states no bill"
    party("provider", v.provider, required = true, why = libraryWhy)
    if not given(v.totalPaymentDue) and not given(v.minimumPaymentDue):
      missing("totalPaymentDue (or minimumPaymentDue)", libraryWhy)
    price("totalPaymentDue", v.totalPaymentDue)
    price("minimumPaymentDue", v.minimumPaymentDue)
    dateTime("paymentDue", v.paymentDue)
    if v.scheduledPaymentDate.len > 0 and
        not isIsoDate(v.scheduledPaymentDate):
      bad("scheduledPaymentDate", v.scheduledPaymentDate,
        "an ISO 8601 date (YYYY-MM-DD)")
    text("accountId", v.accountId)
    text("confirmationNumber", v.confirmationNumber)
    text("paymentMethodId", v.paymentMethodId)
    party("customer", v.customer)
    text("referencesOrder.orderNumber", v.orderNumber)
  of gmParcelDelivery:
    let p = m.parcel
    address("deliveryAddress", p.deliveryAddress, required = true)
    address("originAddress", p.originAddress, required = false)
    dateTime("expectedArrivalFrom", p.expectedArrivalFrom)
    dateTime("expectedArrivalUntil", p.expectedArrivalUntil,
      required = true)
    org("carrier", p.carrier, required = true)
    if p.itemShipped.len == 0:
      missing("itemShipped", reference)
    for i, item in p.itemShipped:
      let path = "itemShipped[" & $i & "]"
      text(path & ".name", item.name, required = true)
      url(path & ".url", item.url)
      url(path & ".image", item.image)
      text(path & ".sku", item.sku)
      text(path & ".description", item.description)
    text("trackingNumber", p.trackingNumber)
    url("trackingUrl", p.trackingUrl)
    text("partOfOrder.orderNumber", p.orderNumber, required = true)
    party("partOfOrder.merchant", p.merchant, required = true)
  diags

proc gmailMarkupBlocks*(doc: EmailNode): tuple[json: seq[string];
    diagnostics: seq[EmailDiagnostic]] =
  ## P1's half of R-SND-07: each block `doc` carries checked, and the
  ## JSON-LD of those with no error, in the order they were added. A
  ## nil document, or one without markup, yields nothing.
  if doc == nil:
    return
  for m in doc.markup:
    let found = checkGmailMarkup(m, doc.origin)
    result.diagnostics.add(found)
    if not hasErrors(found):
      result.json.add(toJsonLd(m))
