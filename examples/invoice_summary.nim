## A domain view written once for an email and a web page:
## `renderInvoiceSummary`, an invoice's summary built only from the
## portable leaves (`isonim_email/portable`). The same source renders
## into the invoice email (`invoice_summary_email.nim`, through `EmailRenderer`)
## and into the billing page (`invoice_summary_page.nim`, through IsoNim's
## browser renderer), and under `MockRenderer` in the tests.
##
## The view holds no renderer-specific code: which elements each leaf
## writes is the leaf's business, chosen by the renderer type it is
## instantiated with.
import isonim_email/portable

type
  InvoiceLine* = object
    ## One line of an invoice.
    description*, qty*, amount*: string

  InvoiceSummary* = object
    ## What the summary shows. Amounts arrive formatted.
    number*: string
    issuer*, customer*: string
    logo*, logoDark*: string ## the issuer's mark, for light and dark
    issued*, due*, status*: string
    lines*: seq[InvoiceLine]
    subtotal*, taxLabel*, tax*, total*: string
    payUrl*: string
    note*: string

proc renderInvoiceSummary*[R, E](r: R; inv: InvoiceSummary): E =
  ## The issuer's mark, the heading, who billed whom, the invoice's
  ## details, its lines, its totals, where to pay, and a closing note.
  result = leafView[R, E](r, "Invoice " & inv.number)
  leafImage(r, result, LeafImage(src: inv.logo, alt: inv.issuer,
    width: 120, height: 40, darkSrc: inv.logoDark))
  leafHeading(r, result, "Invoice " & inv.number, 1)
  leafText(r, result, inv.issuer & " billed " & inv.customer & " on " &
    inv.issued & ".")
  leafKeyValue(r, result, "Invoice details", [
    LeafRow(label: "Invoice number", value: inv.number),
    LeafRow(label: "Issued", value: inv.issued),
    LeafRow(label: "Due", value: inv.due),
    LeafRow(label: "Status", value: inv.status, emphasis: true)])
  leafHeading(r, result, "What you are paying for", 2)
  var rows: seq[seq[string]] = @[]
  for line in inv.lines:
    rows.add(@[line.description, line.qty, line.amount])
  leafTable(r, result, LeafTable(caption: "Lines of invoice " & inv.number,
    columns: @[LeafColumn(header: "Description"),
      LeafColumn(header: "Qty", numeric: true),
      LeafColumn(header: "Amount", numeric: true)],
    rows: rows))
  leafKeyValue(r, result, "Totals", [
    LeafRow(label: "Subtotal", value: inv.subtotal),
    LeafRow(label: inv.taxLabel, value: inv.tax),
    LeafRow(label: "Total due", value: inv.total)], totalRow = true)
  leafLink(r, result, "View and pay invoice " & inv.number, inv.payUrl)
  if inv.note.len > 0:
    leafText(r, result, inv.note)

proc sampleInvoice*(logo, logoDark: string): InvoiceSummary =
  ## The fixture invoice; the images are given by the host, which
  ## publishes them its own way (an email's asset store, a page's files).
  InvoiceSummary(
    number: "INV-2041",
    issuer: "Northwind Studio", customer: "Acme Inc.",
    logo: logo, logoDark: logoDark,
    issued: "4 October 2026", due: "18 October 2026",
    status: "Awaiting payment",
    lines: @[
      InvoiceLine(description: "Website redesign, phase 2",
        qty: "1", amount: "$4,800.00"),
      InvoiceLine(description: "Illustrations for the product pages",
        qty: "6", amount: "$1,260.00"),
      InvoiceLine(description: "Hosting, October", qty: "1",
        amount: "$40.00")],
    subtotal: "$6,100.00", taxLabel: "Tax (20%)", tax: "$1,220.00",
    total: "$7,320.00",
    payUrl: "https://example.com/invoices/INV-2041/pay",
    note: "Questions about this invoice? Write to billing@example.com.")
