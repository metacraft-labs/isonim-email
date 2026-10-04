# Gmail markup: actions and highlights in the inbox

<!-- markdownlint-disable-file MD013 -->
<!-- Line length: the emitted JSON-LD example is one line, as written. -->

Gmail reads [schema.org](https://schema.org/) markup in a message to
show more than the message itself: a button next to the subject in the
inbox list (a _go-to action_ such as "View order", or a _one-click
action_ that Gmail performs for the reader), and summary cards for
bills and parcels. `isonim-email` writes that markup from typed Nim
objects, checks it before it is sent, and puts it where Gmail looks for
it. Catalogue rules R-SND-07 and R-SND-08 (`docs/rendering-rules.md`
§15) are the normative form of this page.

**Writing the markup is the easy half.** Gmail acts on it only for
senders that authenticate their mail and, beyond messages you send to
yourself, have registered with Google. Read
[Before Gmail shows anything](#before-gmail-shows-anything) first.

## What the library writes

Three schema.org types, each with only the properties Gmail's markup
reference documents for them in its property tables and examples. A
nested organisation has a `url` only where Gmail lists one (a parcel's
carrier, a message's publisher): an invoice's provider and customer and
a parcel's merchant are a `MarkupParty`, a name alone:

- **`EmailMessage` with a `ViewAction`**: an `EmailMessageMarkup` whose
  `MarkupAction` has `kind: maView`, a `name` and a `url`. Gmail shows a
  go-to button in the inbox list that opens `url`.
- **`EmailMessage` with a `ConfirmAction` or `SaveAction`**: the same,
  with `kind: maConfirm` or `maSave`, a `name` and a `handlerUrl`. Gmail
  shows a one-click button and requests `handlerUrl` itself, once per
  message.
- **`Invoice`**: an `InvoiceMarkup`. A bill: who bills, how much, when it
  is due, its status.
- **`ParcelDelivery`**: a `ParcelDeliveryMarkup`. A shipment: where it
  goes, by when, the carrier, the items, tracking.

A template attaches blocks to the `mailDocument` it returns. Because the
blocks are built in the template, they come from the same data as the
visible content:

```nim
import isonim_email

proc receiptWithMarkup(r: EmailRenderer; p: ReceiptLayoutProps): EmailNode =
  result = receiptLayout(r, p)
  result.addGmailMarkup(gmailMarkup(InvoiceMarkup(
    provider: MarkupParty(name: "Acme"),
    totalPaymentDue: MarkupPrice(price: "186.40", priceCurrency: "USD"),
    paymentStatus: psComplete,
    orderNumber: "2041")))
  result.addGmailMarkup(gmailMarkup(EmailMessageMarkup(
    action: MarkupAction(kind: maView, name: "View order",
      url: "https://example.com/orders/2041"))))
```

`examples/gmail_markup_email.nim` has this receipt and a parcel delivery
in full; the stories `receiptMarkup` and `shippingMarkup` render them.

The render writes each block as its own element at the end of the
`<head>`, after the style blocks:

```text
<script type="application/ld+json">{"@context":"http://schema.org","@type":"Invoice","provider":{"@type":"Organization","name":"Acme"},"totalPaymentDue":{"@type":"PriceSpecification","price":"186.40","priceCurrency":"USD"},"paymentStatus":"PaymentComplete","referencesOrder":{"@type":"Order","orderNumber":"2041"}}</script>
```

The JSON is one line, with the keys in a fixed order, so the same block
always gives the same bytes. Empty optional properties are left out.
`toJsonLd` returns a block's JSON, if you want to inspect it or paste it
into Google's validator.

### Required properties

A block with a missing required property is `E-MARKUP-REQUIRED` and is
**not written**. The other blocks of the message still are. Gmail ignores
markup that fails its validator, and a block that only says half of what
it means is worse than none. Under `strict = true` the render raises.

- `EmailMessage`: the action's `name` (the button label), and its `url`
  (`maView`) or `handlerUrl` (`maConfirm`, `maSave`).
- `ParcelDelivery`: the delivery address (street, locality, region,
  country, postal code; `name` is optional), `expectedArrivalUntil`, the
  carrier's name, at least one item shipped with its name, the order
  number and the merchant's name.
- `Invoice`: Gmail marks no property required. The library requires the
  provider's name and one amount (`totalPaymentDue` or
  `minimumPaymentDue`), because without them the block describes no bill.
- Everywhere: an organisation that is given needs its `name`, a price
  needs its `price`, a product needs its `name`.

### Values

A value of the wrong form is `E-MARKUP-VALUE`, and its block is not
written either:

- URLs are absolute `https://` URLs. Gmail requires HTTPS for action
  handlers, and an inbox button that opens a plain-HTTP page is no
  better.
- A `DateTime` is `YYYY-MM-DDThh:mm[:ss[.fff]]` followed by `Z` or
  `±hh:mm`, for example `2026-10-07T18:00:00+08:00`. The time zone is
  required. A `Date` is `YYYY-MM-DD`.
- A currency is an ISO 4217 code: three capital letters, such as `USD`.
- `url` belongs to `maView` and `handlerUrl` to the one-click kinds.
  Giving one to the wrong kind is an error, not a silent drop.
- Every string, URLs included, must be valid UTF-8.

### Escaping: a value cannot end the script element

A `<script>` element ends at the first `</script` in its text, whatever
JSON quoting surrounds it. So a product name or a description that
contains `</script>` would end the element early and turn the rest of
the value into markup. The library writes `<`, `>` and `&` in every
string as `\u003c`, `\u003e` and `\u0026`, and U+2028 and U+2029 as
`\u2028` and `\u2029`, besides JSON's own escapes. The element's text
then holds no `<` at all, so neither `</script>` nor `<!--` can appear in
it, and every JSON parser reads the original string back (R-SND-08).

### Size

The blocks are part of the HTML part, so they count toward the size
budget and Gmail's clipping limit (R-SIZE-01). `sizeBreakdown` lists them
as their own entry, `Gmail markup`. They are not CSS, so neither
`headCssBytes` nor `headStyleBudget` counts them. The two blocks of the
`receiptMarkup` story, a bill and an action, take 710 bytes.

### What does not change

- **The look of the message.** A script element in the head paints
  nothing, in every client. The stories `receiptMarkup` and
  `shippingMarkup` render byte for byte as the reference emails
  `receiptTypical` and `shippingChinese`, apart from their blocks.
- **The plain-text part.** It is written from the content, which holds
  no markup.
- **What templates may contain.** A template still cannot write a
  `script` element itself. The data blocks are written by the library,
  from typed objects, after the template has run.

## Before Gmail shows anything

Gmail does not act on markup from just any sender. Writing correct
markup is necessary, but it is not enough.

1. **Authenticate your mail.** Gmail processes markup only in mail
   authenticated with DKIM or SPF, and the authenticated domain must
   match the `From` address's domain as Google's registration guide
   states. This is
   the same set-up the bulk-sender requirements already ask for
   ([`sending.md`](./sending.md)).
2. **Test by sending to yourself.** Markup in a message sent from a
   Gmail address to the same address is shown without registration. Use
   it while developing. Use Google's Email Markup Tester to check a
   block, and paste in the JSON that `toJsonLd` returns.
3. **Register before sending to anyone else.** To have Gmail show your
   markup to your recipients, register the sender with Google:
   - Meet Google's sender quality guidelines: authenticated mail, a
     static `From` address, compliance with the bulk-sender guidelines,
     a history of sending at volume (at least hundreds of messages a day
     for several weeks), and a very low spam-complaint rate.
   - Send a real message with the markup, from your production servers
     (with the same DKIM, SPF, `From` and `Return-Path` as real mail),
     directly to Google's registration address given in the
     registration guide. Do not forward it: Gmail removes markup from
     forwarded mail. The message must pass the Markup Tester with no
     errors.
   - Fill in Google's registration form.
4. **Follow the action guidelines.** Actions are meant for
   transactional mail that people engage with, not for promotional bulk
   mail. Prefer the most direct interaction available (a one-click
   action over a go-to action). A go-to action must deep-link to the page
   where the action is done, and its label should be short, clear and
   without punctuation.
5. **Secure one-click handlers.** Gmail sends a one-click action's
   request to your `handlerUrl` from Google's servers, not from the
   reader's browser:
   - serve it over HTTPS with a valid certificate (the library refuses
     any other URL);
   - put a limited-use token in the URL, so a replayed request does
     nothing;
   - verify the bearer token in the request's `Authorization` header,
     which proves that the request comes from Google and is meant for
     your service. Google sends it only if you ask for it when you
     register.

Until the sender is registered, Gmail shows nothing to your recipients,
and nothing is wrong with the message: other clients ignore the blocks,
and every reader still has the visible content and its links.

## Sources

- Gmail markup reference: overview, go-to actions, one-click actions,
  the `Invoice` and `ParcelDelivery` references, registering with
  Google, and securing actions
  (<https://developers.google.com/workspace/gmail/markup>).
- schema.org vocabulary, release 30.1. The tests validate every emitted
  block against a pinned copy of it (`flake.nix`, `schemaOrg`): every
  type is a schema.org class, every property belongs to its type, and
  every value fits the property's range. `SaveAction`, `handler` and
  `HttpActionHandler` are Gmail's own additions, taken from Gmail's
  reference.
- The HTML Standard, on what ends a `script` element's text, and RFC
  8259 §7 for JSON string escapes.
