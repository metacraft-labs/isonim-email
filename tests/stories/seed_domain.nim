## Domain view stories: `invoiceSummary`, the invoice email of
## `examples/invoice_summary_email.nim`, whose content is the domain
## view `renderInvoiceSummary` (`examples/invoice_summary.nim`) built
## from the portable leaves; the billing page renders the same view
## (`examples/invoice_summary_page.nim`).
##
## Env-gated like the other element sets: the drivers register it only
## under `ISONIM_CAPTURE_LAYOUT=1`, outside the regression matrix.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import story_kit
import invoice_summary_email

proc invoiceSummaryDoc*(): EmailNode =
  invoiceEmail(EmailRenderer(), sampleInvoiceEmail())

const domainStories*: seq[KitStory] = @[
  (name: "invoiceSummary", description: "An invoice's summary, the " &
    "domain view the billing page renders from the same source: the " &
    "issuer's mark, details, lines, totals and the payment link.",
    build: invoiceSummaryDoc, dark: false),
]

proc domainGroup(name: string): string = "domain"

proc registerDomainStories*() =
  ## Registers the domain view stories (env-gated, see above).
  registerKit(domainStories, domainGroup)

proc registerDomainStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(domainStories)
