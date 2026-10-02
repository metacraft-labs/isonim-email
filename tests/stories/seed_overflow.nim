## Tier-3 fixture: a fixed 700px table and its fluid twin.
##
## `seedOverflow(false)` renders a content table pinned to 700px, so
## capturing it at a 320px viewport fails the no-horizontal-overflow
## assertion; `seedOverflow(true)` is the same tree with a 100% table,
## which passes every Tier-3 check. Both twins carry an h1 and a
## 44px-tall Unsubscribe button, so overflow is the ONLY difference
## between them and the fluid twin is a clean negative control.
##
## Env-gated: the drivers register these only under
## `ISONIM_CAPTURE_FIXTURES=1` (set by
## tests/e2e_dom_assertions.nim), so bare runs, CI matrices and the
## t7 story-set pins never see them.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email

proc seedOverflow*(fluid: bool): EmailNode =
  ## h1 + one content table (fixed 700px, or 100% when fluid) +
  ## footer with an Unsubscribe link sized as a 44px button.
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Overflow fixture")
  r.setAttribute(doc, "preheader", "A table wider than the viewport.")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Overflow fixture")
  r.appendChild(doc, h1)
  let table = r.createElement("table")
  if fluid:
    r.setStyle(table, "width", "100%")
  else:
    r.setStyle(table, "width", "700px")
  let tr = r.createElement("tr")
  let td = r.createElement("td")
  r.setTextContent(td, "Widget: $10.00")
  r.appendChild(tr, td)
  r.appendChild(table, tr)
  r.appendChild(doc, table)
  # A plain `p` footer, and no section: the fixture's table must sit
  # directly in the skeleton's full-width content cell, so that the
  # 700px twin overflows the viewport rather than a 600px section.
  let foot = r.createElement("p")
  let unsub = r.createElement("a")
  r.setAttribute(unsub, "href", "https://x.test/unsubscribe")
  r.setStyle(unsub, "display", "inline-block")
  r.setStyle(unsub, "min-height", "44px")
  # 48px tall: 4px of margin over the 44px touch floor, so no
  # engine's sub-pixel rounding can flip the negative control.
  r.setStyle(unsub, "line-height", "48px")
  r.setStyle(unsub, "padding-left", "16px")
  r.setStyle(unsub, "padding-right", "16px")
  r.setTextContent(unsub, "Unsubscribe")
  r.appendChild(foot, unsub)
  r.appendChild(doc, foot)
  doc

const overflowText* = "Overflow fixture\n\n" &
  "A table wider than the viewport.\n"
  ## Fixed plain-text alternative for the twins (the plain-text
  ## generator will produce these).

proc overflowFixedDoc*(): EmailNode =
  ## The fixed-700px tree (brief driver input).
  seedOverflow(false)

proc overflowFluidDoc*(): EmailNode =
  ## The fluid tree (brief driver input).
  seedOverflow(true)

proc renderOverflowFixed*(): StoryHtml =
  ## The fixed twin through the current pipeline.
  (renderPipeline(seedOverflow(false), defaultTarget()), overflowText)

proc renderOverflowFluid*(): StoryHtml =
  ## The fluid twin through the current pipeline.
  (renderPipeline(seedOverflow(true), defaultTarget()), overflowText)
