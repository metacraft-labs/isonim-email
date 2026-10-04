# Portable leaves and domain views

<!-- markdownlint-disable-file MD013 MD060 -->

A domain view is a piece of an application written once and rendered
wherever its content appears: an invoice's summary on the billing page
and in the invoice email, an order's status in the account area and in
the shipping notification. In IsoNim it is a proc generic over the
renderer,

```nim
proc renderInvoiceSummary*[R, E](r: R; inv: InvoiceSummary): E
```

and this library supplies the leaves it is written against: six that
email and the web both have (text, heading, link, image, key-value,
data table) and the root a view is built in. Each leaf has two
implementations, chosen at compile time by the renderer type: on
`EmailRenderer` it lowers to this library's own leaves and patterns, so
the email gets everything they do (client-safe tables, Word's fallbacks,
the text part, dark mode); on any other renderer (IsoNim's web renderer,
`MockRenderer`, a native one) it writes semantic HTML.

## The leaves

```nim
import isonim_email   # or isonim_email/portable

type
  LeafImage* = object
    src*: string        # Url (on email: an asset name or an asset"…" path)
    alt*: string        # "" = decorative
    width*: int         # display width, px (required)
    height*: int        # display height, px; 0 = from the image's ratio
    darkSrc*: string    # the image for a dark scheme; "" = none
  LeafRow* = object
    label*, value*: string
    emphasis*: bool
  LeafColumn* = object
    header*: string
    numeric*: bool      # aligned to the end of the line, never wrapped
  LeafTable* = object
    caption*: string    # the table's accessible name (visually hidden)
    columns*: seq[LeafColumn]
    rows*: seq[seq[string]]
    rtl*: bool          # the table runs right to left

proc leafView*[R, E](r: R; label: string): E
proc leafText*[R, E](r: R; parent: E; text: string): E
proc leafHeading*[R, E](r: R; parent: E; text: string;
                        level: range[1 .. 6] = 2): E
proc leafLink*[R, E](r: R; parent: E; label, href: string): E
proc leafImage*[R, E](r: R; parent: E; image: LeafImage): E
proc leafKeyValue*[R, E](r: R; parent: E; caption: string;
                         rows: openArray[LeafRow]; totalRow = false): E
proc leafTable*[R, E](r: R; parent: E; table: LeafTable): E
```

Each leaf appends what it builds to `parent` and returns it (the result
may be discarded); `leafView` makes the view's root, which the caller
places.

| Leaf           | `EmailRenderer`                                                     | Any other renderer                                                                                                                                             |
| -------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `leafView`     | `mailStack`, 24px between its leaves                                | `<section aria-label="…">`                                                                                                                                     |
| `leafText`     | `p`                                                                 | `<p>`                                                                                                                                                          |
| `leafHeading`  | `h1`-`h6`                                                           | `<h1>`-`<h6>`                                                                                                                                                  |
| `leafLink`     | `p` holding `a href`                                                | `<p>` holding `<a href>`                                                                                                                                       |
| `leafImage`    | `mailImage` (`alt`, or `decorative`; `width`, `height`, `dark_src`) | `<img alt width height>`, in a `<picture>` with a `prefers-color-scheme: dark` `<source>` when `darkSrc` is set                                                |
| `leafKeyValue` | `mailKeyValue` of `mailKeyValueRow`s                                | `<figure>`: a visually hidden `<figcaption>`, then a `<dl>` of `<div><dt>…</dt><dd>…</dd></div>` rows; an emphasised or total row bold, the total under a rule |
| `leafTable`    | `mailTable` holding `table > thead/tbody`                           | `<table>`: a visually hidden `<caption>`, `<thead>` of `<th scope="col">`, `<tbody>` of `<td>`                                                                 |

A numeric column's cells sit at the end of the line and never wrap: on
email `text-align` right (left when `rtl`), on the web `text-align:end`.
The two renderings carry the same text in the same order: a caption is
text on both sides, visually hidden on both.

The web half writes a few structural inline styles (the hidden caption,
the key-value rows, numeric alignment) and leaves the rest (type,
colours, spacing) to the page's stylesheet; `leaf-keyvalue` and
`leaf-table` classes are there to hook it. A leaf adds no check of its
own: on email the element it writes is checked by the render as that
element is in any template, and the web half writes what it is given.

## Writing a domain view

Use only the leaves, never a `mail*` element or a DOM API, and call the
view with its renderer types given, as IsoNim's generic views are:

```nim
proc renderInvoiceSummary*[R, E](r: R; inv: InvoiceSummary): E =
  result = leafView[R, E](r, "Invoice " & inv.number)
  leafHeading(r, result, "Invoice " & inv.number, 1)
  leafKeyValue(r, result, "Invoice details", [
    LeafRow(label: "Issued", value: inv.issued),
    LeafRow(label: "Status", value: inv.status, emphasis: true)])
  leafTable(r, result, LeafTable(caption: "Lines",
    columns: @[LeafColumn(header: "Description"),
      LeafColumn(header: "Amount", numeric: true)],
    rows: inv.rows))
  leafLink(r, result, "View and pay", inv.payUrl)

# In an email template:
r.appendChild(card, renderInvoiceSummary[EmailRenderer, EmailNode](r, inv))
# On a web page (nim js):
let view = renderInvoiceSummary[WebRenderer, Element](WebRenderer(), inv)
# In a view test:
let tree = renderInvoiceSummary[MockRenderer, MockNode](MockRenderer(), inv)
```

The choice between the two implementations is a compile-time branch on
the renderer type, not an overload: an explicitly instantiated generic
view would otherwise bind the generic overload and write web HTML into
an email.

## The example

`examples/invoice_summary.nim` holds `renderInvoiceSummary` and its
fixture. The same source renders:

- into the invoice email, `examples/invoice_summary_email.nim` (the
  `invoiceSummary` story: `ISONIM_CAPTURE_LAYOUT=1 just email-shots
invoiceSummary`);
- into the billing page, `examples/invoice_summary_page.html` with its
  script `examples/invoice_summary_page.nim`, rendered by IsoNim's web
  renderer. `just example-page` builds the script with `nim js`, opens
  the page in the pinned Chromium, and saves what the script built as
  static HTML (`build/examples/invoice-summary/index.html`, no script
  left), with screenshots at desktop and phone widths in the light and
  dark schemes beside it.

`tests/t7_domain_view.nim` renders the view under `EmailRenderer` and
`MockRenderer` and checks that the email a client shows has the web
rendering's text, word for word; `tools/web/static_page.test.ts` does
the same with the page the browser renderer built, in Chromium.
