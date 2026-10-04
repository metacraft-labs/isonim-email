## isonim_email/layouts/transactional.nim — `transactionalLayout`
## (layout-patterns.md §4.8): the header, a content card (the heading,
## its introduction, a Markdown body, the caller's content, the
## actions) and the footer.
##
## Pure tree building: identical on the C and JS targets.

import ../renderer
import ../target
import ./frame

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  TransactionalLayoutProps* = object
    ## `transactionalLayout`'s props.
    frame*: LayoutFrame
    heading*: string          ## the `h1` (required)
    intro*: string            ## the paragraph under it
    markdown*: string         ## a Markdown body (`mailMarkdown`, its `#` an `h2`)
    content*: LayoutSlot      ## the caller's content, after the Markdown
    actions*: seq[LayoutLink] ## 1–3 buttons (`mailButtonGroup`)

proc transactionalLayout*(r: EmailRenderer; p: TransactionalLayoutProps):
    EmailNode =
  ## Header, content slot, footer.
  result = r.layoutDocument(p.frame)
  let stack = r.contentCard(result)
  r.heading(stack, p.heading, p.intro)
  r.markdownBody(stack, p.markdown)
  r.slotInto(stack, p.content)
  r.buttonGroup(stack, p.actions)
  r.layoutFooter(result, p.frame)
