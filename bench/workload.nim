## bench/workload.nim — what the benchmark renders, shared with the tests
## that check it.
##
## The stories are the reference emails (`examples/reference_set.nim`,
## in its order) and the invoice email (`examples/invoice_summary_email.nim`),
## the reference story of the render targets. Each is held with its
## template and data typed, so the benchmark can render it on the plain
## path, personalise it, and render it through the pre-lowering
## prototype (`prelower.nim`). `tests/t8_bench.nim` checks that this
## list stays the reference set, and that a story rendered here is the
## same bytes as the reference set's own render.
##
## Every story renders with one in-memory asset store on the capture
## fixture host, kept for the story's life: a sender publishes an image
## once and keeps sending it.

import std/times
import isonim_email
import reference_set
import invoice_summary_email
import ./prelower

export prelower

const
  referenceStory* = "invoiceSummary"
    ## The story the render targets are stated for.
  fixtureHost = "https://x.test"

type
  BenchStory* = object
    ## One story, with its paths.
    name*: string
    plain*: proc(): RenderedEmail
      ## The plain render of the story's own data.
    personalised*: proc(n: int; longer, urls: bool): RenderedEmail
      ## The plain render of recipient `n`'s copy (`personalised` in
      ## prelower.nim; recipient 0 is the story's own data).
    prelowered*: proc(n: int; longer, urls: bool): tuple[
      rendered: RenderedEmail; path: PrelowerPath]
      ## Recipient `n`'s copy through the pre-lowering prototype.
    prelowerStats*: proc(): PrelowerStats
    slots*: proc(): tuple[strings, slots, sensitive: int]
    nodes*: proc(): int
      ## The element nodes of the story's authoring tree.

proc elementCount(n: EmailNode): int =
  if n == nil:
    return 0
  if n.kind == enElement:
    inc result
  for c in n.children:
    result += elementCount(c)

proc storyOf[T](name: string; tpl: EmailTemplate[T]; data: T;
    dark = false): BenchStory =
  var target = defaultTarget()
  if dark:
    target.darkMode = dmDesigned
  let store = memoryAssetStore(fixtureHost)
  let cache = newPrelowerCache(tpl, target = target, assets = store)
  var classified = false
  proc ensure() =
    # The prototype classifies the data's strings on its first render;
    # personalising reads that classification.
    if not classified:
      discard cache.renderPrelowered(data)
      classified = true
  proc copyFor(n: int; longer, urls: bool): T =
    ensure()
    cache.personalised(data, n, longer, urls)
  BenchStory(
    name: name,
    plain: proc(): RenderedEmail =
      renderEmail(tpl, data, target = target, assets = store),
    personalised: proc(n: int; longer, urls: bool): RenderedEmail =
      renderEmail(tpl, copyFor(n, longer, urls), target = target,
        assets = store),
    prelowered: proc(n: int; longer, urls: bool): tuple[
        rendered: RenderedEmail; path: PrelowerPath] =
      cache.renderPrelowered(copyFor(n, longer, urls)),
    prelowerStats: proc(): PrelowerStats =
      cache.stats,
    slots: proc(): tuple[strings, slots, sensitive: int] =
      ensure()
      cache.slotCount(data),
    nodes: proc(): int =
      elementCount(renderAuthoringTree(tpl, data)))

proc benchStories*(): seq[BenchStory] =
  ## The reference emails in the reference set's order, then the
  ## reference story.
  @[
    storyOf("receiptTypical", receiptLayout, receiptTypical()),
    storyOf("receiptHebrew", receiptLayout, receiptHebrew()),
    storyOf("securityCodeJapanese", securityCodeLayout, securityCodeJapanese()),
    storyOf("alertCritical", alertLayout, alertCritical()),
    storyOf("alertArabic", alertLayout, alertArabic()),
    storyOf("digestGrid", digestLayout, digestGrid()),
    storyOf("digestZigZag", digestLayout, digestZigZag()),
    storyOf("digestNearBudget", digestLayout, digestNearBudget()),
    storyOf("notificationMarkdown", transactionalLayout, notificationMarkdown()),
    storyOf("shippingChinese", transactionalLayout, shippingChinese()),
    storyOf("surveyRequest", transactionalLayout, surveyRequest()),
    storyOf("darkPalette", transactionalLayout, darkPalette(), dark = true),
    storyOf("eventInvitation", eventInvitationTemplate, eventInvitationData()),
    storyOf("newsletterColumns", newsletterColumnsTemplate,
      newsletterColumnsData()),
    storyOf(referenceStory, invoiceEmail, sampleInvoiceEmail()),
  ]

proc digestScaling*(cards: int): BenchStory =
  ## The near-budget digest cut to its first `cards` cards: the same
  ## template with more or less output, for allocations against size.
  var d = digestNearBudget()
  doAssert cards >= 1 and cards <= d.items.len
  d.items.setLen(cards)
  storyOf("digestCards" & $cards, digestLayout, d)

proc benchHeaders*(): MessageHeaders =
  ## Fixed headers: the MIME bytes depend only on the render.
  MessageHeaders(fromAddr: mailbox("Acme", "hello@example.com"),
    to: @[mailbox("Ada", "ada@example.com")],
    subject: "Your message from Acme",
    date: fromUnix(1767268800))

proc packageMime*(r: RenderedEmail): string =
  ## The message's bytes, as a sender hands them to SMTP: `toMessage`
  ## then `toRfc5322`, with a fixed seed so they are reproducible.
  toRfc5322(toMessage(r, benchHeaders()), deterministicSeed = "bench")
