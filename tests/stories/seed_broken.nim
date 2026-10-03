## Review-loop fixture: the receipt with its logo lost on the way out.
##
## Methodology checklist item 7 asks that a reviewer, given the real
## capture of a deliberately broken view and that view's unchanged
## brief, reports the missing element and rates the view 4 or lower.
## `receiptB` is that view: it renders the receipt seed
## through the pipeline and then removes the `img` element from the
## HTML, the way a lowering regression that loses an image would. Its
## brief is built from the intact receipt tree, so the generated
## expectations still list the logo: the break is in the output, never
## in the expectation.
##
## Env-gated like the other capture fixtures: the drivers register it
## only under `ISONIM_CAPTURE_FIXTURES=1`, so bare runs, CI matrices and
## the t7 story-set pins never see it. `just email-review-broken` sets
## it up and prints what the reviewers must be given.
##
## Backend-independent (tree building + string work only).
import std/strutils
import isonim_email
import seed_receipt

proc dropFirstImage*(html: string): string =
  ## `html` without its one `<img …>` element. Raises `StoryError` when
  ## the HTML holds no image or more than one, so the fixture can never
  ## silently stop being broken.
  let first = html.find("<img ")
  if first < 0 or html.find("<img ", first + 1) >= 0:
    raise newException(StoryError,
      "receiptB: expected exactly one <img> in the receipt")
  let close = html.find('>', first)
  if close < 0:
    raise newException(StoryError, "receiptB: unterminated <img>")
  html[0 ..< first] & html[close + 1 .. ^1]

proc renderReceiptLogoDropped*(): StoryHtml =
  ## The receipt seed through the current pipeline, logo removed.
  let (html, text) = renderStoryPipeline(seedReceipt(), defaultTarget())
  (dropFirstImage(html), text)

proc registerBrokenStories*() =
  ## Registers the broken receipt (env-gated; see the module comment).
  registerStory(Story(name: "receiptB", group: "review",
    description: "Review fixture: the receipt with its logo dropped.",
    render: renderReceiptLogoDropped))
