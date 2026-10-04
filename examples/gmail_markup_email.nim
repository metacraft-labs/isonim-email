## Gmail markup on reference emails: the typical receipt carrying an
## `Invoice` block and an `EmailMessage` with a "View order" action, and
## the Chinese shipping update carrying a `ParcelDelivery` block.
##
## Each template is the reference email's own layout with its blocks
## added to the document it returns (`addGmailMarkup`), so the markup is
## built from the same order as the content. The blocks are written in
## the head and paint nothing: the message looks, and its plain-text
## part reads, exactly as the reference email does.
##
## Gmail acts on the blocks only for an authenticated sender registered
## with Google (docs/gmail-markup.md).
import isonim_email
import reference_set

proc receiptMarkup*(): seq[GmailMarkup] =
  ## The blocks of `receiptTypical`'s order 2041: the paid invoice and
  ## the action that opens the order.
  @[gmailMarkup(InvoiceMarkup(
      provider: MarkupParty(name: "Acme"),
      totalPaymentDue: MarkupPrice(price: "186.40", priceCurrency: "USD"),
      paymentStatus: psComplete,
      paymentMethodId: "4242",
      confirmationNumber: "2041",
      orderNumber: "2041")),
    gmailMarkup(EmailMessageMarkup(
      action: MarkupAction(kind: maView, name: "View order",
        url: "https://example.com/orders/2041"),
      description: "Your receipt from Acme for order 2041",
      publisher: MarkupOrganization(name: "Acme",
        url: "https://example.com/")))]

proc shippingMarkup*(): seq[GmailMarkup] =
  ## The block of `shippingChinese`'s parcel: where it goes, by when,
  ## with whom, what it holds and how to track it.
  @[gmailMarkup(ParcelDeliveryMarkup(
    deliveryAddress: MarkupAddress(name: "王小明",
      streetAddress: "示例路 1 号", addressLocality: "上海",
      addressRegion: "上海", addressCountry: "CN", postalCode: "200000"),
    expectedArrivalUntil: "2026-10-07T18:00:00+08:00",
    carrier: MarkupOrganization(name: "Acme Express"),
    itemShipped: @[MarkupProduct(name: "海岸风景画"),
      MarkupProduct(name: "橡木画框")],
    trackingNumber: "AE20412041",
    trackingUrl: "https://example.com/zh/track/2041",
    orderNumber: "2041",
    merchant: MarkupParty(name: "Acme"),
    orderStatus: osInTransit))]

proc receiptWithMarkup*(r: EmailRenderer; p: ReceiptLayoutProps): EmailNode =
  ## `receiptLayout` with `receiptMarkup()` in the head.
  result = receiptLayout(r, p)
  for m in receiptMarkup():
    result.addGmailMarkup(m)

proc shippingWithMarkup*(r: EmailRenderer;
    p: TransactionalLayoutProps): EmailNode =
  ## `transactionalLayout` with `shippingMarkup()` in the head.
  result = transactionalLayout(r, p)
  for m in shippingMarkup():
    result.addGmailMarkup(m)
