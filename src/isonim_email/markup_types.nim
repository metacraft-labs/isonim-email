## isonim_email/markup_types.nim — the typed Gmail markup blocks.
##
## Schema.org objects a template attaches to its `mailDocument` with
## `addGmailMarkup` (`gmail_markup.nim`): an `EmailMessage` with one of
## the actions Gmail supports, an `Invoice`, a `ParcelDelivery`. Each
## type carries only properties Gmail's markup reference documents for
## these uses, in its property tables and examples: a nested
## organisation has a `url` only where Gmail lists one (the carrier, an
## `EmailMessage`'s publisher) and is a name alone elsewhere
## (`MarkupParty`). An empty string (or `psNone`/`osNone`) means
## "omitted".
## The checks, the JSON-LD and the escaping are in `gmail_markup.nim`;
## the render writes the blocks into the head (catalogue R-SND-07,
## R-SND-08, `docs/gmail-markup.md`).
##
## Types only, importing nothing but the client families: the tree
## node (`renderer.nim`) holds a document's blocks, so this module sits
## below it.

import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = {cfGmailWeb, cfGmailApp}

type
  MarkupOrganization* = object
    ## schema.org `Organization` with the `url` Gmail lists for a
    ## parcel's carrier and an `EmailMessage`'s publisher.
    name*: string ## Required wherever an organisation is given.
    url*: string  ## Optional, an absolute https URL.

  MarkupParty* = object
    ## schema.org `Organization`, by name alone: an Invoice's provider
    ## and customer (Gmail lists no sub-property; its example names the
    ## provider) and a parcel's merchant (Gmail lists `name`, and a
    ## Freebase `sameAs` the library does not offer).
    name*: string ## Required wherever a party is given.

  MarkupPrice* = object
    ## schema.org `PriceSpecification`.
    price*: string
      ## "Number or Text": `186.40`, or `$186.40` as Gmail's own
      ## example writes it. Required when the price is given.
    priceCurrency*: string ## ISO 4217, three capitals (`USD`); "" = omitted.

  MarkupActionKind* = enum
    ## The actions Gmail shows for an `EmailMessage`.
    maView = "ViewAction"       ## Go-to: Gmail opens `url`.
    maConfirm = "ConfirmAction" ## One-click: Gmail fetches `handlerUrl` once.
    maSave = "SaveAction"       ## One-click, as `maConfirm`.

  MarkupAction* = object
    ## The `potentialAction` of an `EmailMessage`.
    kind*: MarkupActionKind
    name*: string       ## The button's label (required).
    url*: string        ## `maView` only: the page (required, absolute https).
    handlerUrl*: string
      ## `maConfirm`/`maSave` only: the `HttpActionHandler` URL Gmail
      ## fetches (required, absolute https).

  EmailMessageMarkup* = object
    ## schema.org `EmailMessage`, the carrier of an action.
    action*: MarkupAction            ## `potentialAction` (required).
    description*: string             ## "" = omitted.
    publisher*: MarkupOrganization   ## Name "" = omitted.

  PaymentStatus* = enum
    ## schema.org `PaymentStatusType` members.
    psNone = ""
    psDue = "PaymentDue"
    psPastDue = "PaymentPastDue"
    psComplete = "PaymentComplete"
    psAutomaticallyApplied = "PaymentAutomaticallyApplied"
    psDeclined = "PaymentDeclined"

  InvoiceMarkup* = object
    ## schema.org `Invoice`: a bill.
    provider*: MarkupParty         ## Who bills (required by the library).
    totalPaymentDue*: MarkupPrice
      ## The amount due; this or `minimumPaymentDue` is required.
    minimumPaymentDue*: MarkupPrice ## Price "" = omitted.
    paymentDue*: string
      ## DateTime: `YYYY-MM-DDThh:mm[:ss[.fff]]` with `Z` or `±hh:mm`.
    scheduledPaymentDate*: string  ## Date: `YYYY-MM-DD`.
    paymentStatus*: PaymentStatus
    accountId*, confirmationNumber*, paymentMethodId*: string
    customer*: MarkupParty         ## Name "" = omitted.
    orderNumber*: string           ## `referencesOrder`'s order; "" = omitted.

  MarkupAddress* = object
    ## schema.org `PostalAddress`.
    name*, streetAddress*, addressLocality*, addressRegion*,
      addressCountry*, postalCode*: string

  MarkupProduct* = object
    ## schema.org `Product`.
    name*: string ## Required.
    url*, image*, sku*, description*: string

  OrderStatus* = enum
    ## schema.org `OrderStatus` members.
    osNone = ""
    osProcessing = "OrderProcessing"
    osInTransit = "OrderInTransit"
    osDelivered = "OrderDelivered"
    osPickupAvailable = "OrderPickupAvailable"
    osPaymentDue = "OrderPaymentDue"
    osProblem = "OrderProblem"
    osReturned = "OrderReturned"
    osCancelled = "OrderCancelled"

  ParcelDeliveryMarkup* = object
    ## schema.org `ParcelDelivery`: a shipment on its way.
    deliveryAddress*: MarkupAddress ## Required: every field but `name`.
    originAddress*: MarkupAddress   ## Optional; omitted when all "".
    expectedArrivalFrom*: string    ## DateTime, optional.
    expectedArrivalUntil*: string   ## DateTime, required.
    carrier*: MarkupOrganization    ## Required.
    itemShipped*: seq[MarkupProduct] ## Required, at least one.
    trackingNumber*, trackingUrl*: string
    orderNumber*: string            ## `partOfOrder`'s order number (required).
    merchant*: MarkupParty          ## `partOfOrder`'s merchant (required).
    orderStatus*: OrderStatus

  GmailMarkupKind* = enum
    gmEmailMessage, gmInvoice, gmParcelDelivery

  GmailMarkup* = object
    ## One block: one `<script type="application/ld+json">` in the head.
    case kind*: GmailMarkupKind
    of gmEmailMessage: message*: EmailMessageMarkup
    of gmInvoice: invoice*: InvoiceMarkup
    of gmParcelDelivery: parcel*: ParcelDeliveryMarkup
