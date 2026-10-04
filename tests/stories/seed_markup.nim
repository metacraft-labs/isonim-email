## Gmail markup stories: `receiptMarkup` (the typical receipt with an
## `Invoice` block and a "View order" action) and `shippingMarkup` (the
## Chinese shipping update with a `ParcelDelivery` block), from
## `examples/gmail_markup_email.nim`. Each renders exactly as its
## reference email but for the JSON-LD in the head, which paints
## nothing; `tests/t6_gmail_markup_json_ld_valid.nim` checks that.
##
## Env-gated like the other element sets: the drivers register them
## only under `ISONIM_CAPTURE_LAYOUT=1`, outside the regression matrix.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import story_kit
import reference_set
import gmail_markup_email

proc renderReceiptMarkup*(target = defaultTarget()): RenderedEmail =
  renderEmail(receiptWithMarkup, receiptTypical(), target = target,
    assets = fixtureStore())

proc renderShippingMarkup*(target = defaultTarget()): RenderedEmail =
  renderEmail(shippingWithMarkup, shippingChinese(), target = target,
    assets = fixtureStore())

proc storyOf(name: string;
    render: proc(target: EmailTarget): RenderedEmail {.nimcall.}):
    StoryRenderProc =
  ## The story's render closure, refused on an error as every story is.
  result = proc(): StoryHtml =
    let res = render(defaultTarget())
    noteStoryDiagnostics(res.diagnostics)
    for d in res.diagnostics:
      if d.severity == sevError:
        raise newException(StoryError, "markup story '" & name & "': " &
          d.code & ": " & d.message)
    (res.html, res.text)

proc registerMarkupStories*() =
  ## Registers the Gmail markup stories (env-gated, see above).
  registerStory(Story(name: "receiptMarkup", group: "markup",
    description: "The typical receipt with Gmail markup in the head: " &
      "an Invoice and a View order action.",
    render: storyOf("receiptMarkup", renderReceiptMarkup)))
  registerStory(Story(name: "shippingMarkup", group: "markup",
    description: "The Chinese shipping update with Gmail markup in the " &
      "head: a ParcelDelivery.",
    render: storyOf("shippingMarkup", renderShippingMarkup)))

proc registerMarkupStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerStoryTree("receiptMarkup", proc(): EmailNode =
    renderAuthoringTree(receiptWithMarkup, receiptTypical()), dmAccommodate)
  registerStoryTree("shippingMarkup", proc(): EmailNode =
    renderAuthoringTree(shippingWithMarkup, shippingChinese()),
    dmAccommodate)
