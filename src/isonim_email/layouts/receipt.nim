## isonim_email/layouts/receipt.nim — `receiptLayout`
## (layout-patterns.md §4.8; the receipt row of §4.6): the header, a
## content card (the heading, the order summary as a `mailKeyValue`, the
## items as `mailLineItems`, the totals as a `mailKeyValue` whose last
## row is the total, the actions as a `mailButtonGroup`, a note) and the
## footer.
##
## Pure tree building: identical on the C and JS targets.

import ../renderer
import ../target
import ./frame

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  ReceiptItem* = object
    ## One line of the receipt (`mailLineItem`).
    description*, amount*: string ## required
    detail*: string               ## the second line (SKU, unit price)
    qty*: string
    thumb*: string                ## a thumbnail's Url
    thumbAlt*: string             ## "" = decorative

  ReceiptLayoutProps* = object
    ## `receiptLayout`'s props.
    frame*: LayoutFrame
    heading*: string                    ## the `h1` (required)
    intro*: string
    summaryCaption*: string = "Order summary"
    summary*: seq[LayoutRow]            ## order number, date, payment
    itemsCaption*: string = "Items"
    itemLabel*: string = "Item"
    qtyLabel*: string = "Qty"
    amountLabel*: string = "Amount"
    items*: seq[ReceiptItem]
    totalsCaption*: string = "Totals"
    totals*: seq[LayoutRow]             ## subtotal, tax …, then the total
    actions*: seq[LayoutLink]           ## 1–3 buttons
    note*: string                       ## a closing paragraph
    content*: LayoutSlot                ## the caller's content, after the actions

proc receiptLayout*(r: EmailRenderer; p: ReceiptLayoutProps): EmailNode =
  ## Header, summary, line items, totals, actions, footer.
  result = r.layoutDocument(p.frame)
  let stack = r.contentCard(result)
  r.heading(stack, p.heading, p.intro)
  r.keyValue(stack, p.summaryCaption, p.summary)
  if p.items.len > 0:
    let li = r.node(stack, "mailLineItems", [("caption", p.itemsCaption),
      ("item_label", p.itemLabel), ("qty_label", p.qtyLabel),
      ("amount_label", p.amountLabel)])
    for it in p.items:
      discard r.node(li, "mailLineItem", [("description", it.description),
        ("detail", it.detail), ("qty", it.qty), ("amount", it.amount),
        ("thumb", it.thumb), ("thumb_alt", it.thumbAlt)])
  r.keyValue(stack, p.totalsCaption, p.totals, totalRow = true)
  r.buttonGroup(stack, p.actions)
  if p.note.len > 0:
    let n = r.node(stack, "p", text = p.note)
    r.setStyle(n, "margin", "0")
  r.slotInto(stack, p.content)
  r.layoutFooter(result, p.frame)
