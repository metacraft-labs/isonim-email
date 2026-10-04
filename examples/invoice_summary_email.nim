## The invoice email: the domain view `renderInvoiceSummary`
## (`invoice_summary.nim`) rendered through `EmailRenderer` into a
## content card, under a transactional footer. The billing page
## (`invoice_summary_page.nim`) renders the same view from the same source.
import isonim_email
import invoice_summary

type
  InvoiceEmail* = object
    ## The email's data: the frame (language, title, preheader, the
    ## footer) and the invoice.
    frame*: LayoutFrame
    invoice*: InvoiceSummary

proc invoiceEmail*(r: EmailRenderer; d: InvoiceEmail): EmailNode =
  ## The document on the canvas, the invoice summary on a card, then
  ## the footer. The view is the template's only content.
  result = r.node(nil, "mailDocument", [("lang", d.frame.lang),
    ("dir", d.frame.dir), ("title", d.frame.title),
    ("preheader", d.frame.preheader)])
  r.setStyle(result, "background-color", tok"color.surface.canvas")
  let card = r.contentCard(result)
  r.appendChild(card, renderInvoiceSummary[EmailRenderer, EmailNode](r,
    d.invoice))
  r.layoutFooter(result, d.frame)

proc sampleInvoiceEmail*(): InvoiceEmail =
  ## The fixture email: the sample invoice, its marks published by the
  ## render's asset store.
  let inv = sampleInvoice($asset"assets/mark-outlined.png",
    $asset"assets/mark-dark.png")
  InvoiceEmail(
    frame: LayoutFrame(title: "Invoice " & inv.number & " from " &
      inv.issuer, preheader: "Invoice " & inv.number & ": " & inv.total &
      ", due " & inv.due & ".",
      address: "Northwind Studio, 12 Harbour Road, Portsmouth PO1 3AB, " &
        "United Kingdom",
      reason: "You're receiving this because Northwind Studio bills " &
        "your account.",
      legal: "© 2026 Northwind Studio."),
    invoice: inv)
