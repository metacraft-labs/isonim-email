## Data-table stories: the story set of `mailTable`: `tableMinimal`
## (three columns, the defaults), `tableMaximal` (five columns that
## stack on a phone, a striped body, a spanning header, right-aligned
## amounts, a long unbroken reference), `tableScroll` (six columns that
## scroll on a phone), `tableRtl` (Arabic, right to left), `tableImagesOff`
## (thumbnails in the cells, captured with images blocked), `tableDark`
## (`darkMode = designed`) and `tableInContext` (in a rounded box between
## a paragraph and a button, a custom border).
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`, so bare runs, the capture regression
## matrix and the story-set pins never see them.
##
## Backend-independent (tree building only), like the seed builders.
import std/tables
import isonim_email
import fixture_images
import story_kit

proc dataTable(r: EmailRenderer; parent: EmailNode; heads: openArray[string];
    rows: openArray[seq[string]]; attrs: openArray[(string, string)];
    endCols: openArray[int] = []): EmailNode =
  ## A `mailTable` with a header row and body rows; the columns in
  ## `endCols` are aligned to the end of the line (amounts).
  result = r.el(parent, "mailTable", attrs = attrs)
  let table = r.el(result, "table")
  let hr = r.el(r.el(table, "thead"), "tr")
  let rtl = parent != nil and (block:
    var a = parent
    var found = false
    while a != nil:
      if a.attrs.getOrDefault("dir", "") == "rtl":
        found = true
      a = a.parent
    found)
  let endSide = if rtl: "left" else: "right"
  for i, h in heads:
    let th = r.el(hr, "th", text = h)
    if i in endCols:
      r.setStyle(th, "text-align", endSide)
      r.setStyle(th, "white-space", "nowrap")
  let body = r.el(table, "tbody")
  for row in rows:
    let tr = r.el(body, "tr")
    for i, cell in row:
      let td = r.el(tr, "td", text = cell)
      if i in endCols:
        # Amounts never break (a credit's minus sign stays with it).
        r.setStyle(td, "text-align", endSide)
        r.setStyle(td, "white-space", "nowrap")

proc tableMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order", "Three items, shipped today.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Your order")
  discard r.el(s, "p", text = "Order 1042, shipped today.")
  discard r.dataTable(s, ["Item", "Qty", "Amount"], [
    @["Notebook", "2", "$12.00"], @["Pencils, pack of 12", "1", "$4.50"],
    @["Eraser", "3", "$2.25"]], [("caption", "Items in order 1042")],
    [1, 2])
  r.footer(result)

proc tableMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Invoice 2041", "Five columns, striped, stacking on " &
    "a phone.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Invoice 2041")
  discard r.el(s, "p", text = "Every line of the invoice. On a phone, " &
    "each line becomes a group of label and value lines.")
  let t = r.dataTable(s, ["Date", "Description", "Reference", "Qty",
    "Amount"], [
    @["1 Oct", "Team plan, October", "INV-2041-A", "1", "$120.00"],
    @["3 Oct", "Extra seats (prorated for the rest of the month)",
      "INV-2041-B", "4", "$36.40"],
    @["9 Oct", "Storage add-on", longWord, "2", "$10.00"],
    @["15 Oct", "Support credit", "CR-77", "1", "−$20.00"]],
    [("caption", "Invoice 2041 lines"), ("striped", "true"),
      ("mobile", "stack")], [3, 4])
  # Dates never break between day and month.
  for part in t.children[0].children:
    for tr in part.children:
      r.setStyle(tr.children[0], "white-space", "nowrap")
  # A total row: its label spans the first four columns.
  let body = t.children[0].children[1]
  let total = r.el(body, "tr")
  let th = r.el(total, "th", [("text-align", "right")], [("colspan", "4")],
    "Total")
  discard th
  discard r.el(total, "td", [("text-align", "right"),
    ("font-weight", "700")], text = "$146.40")
  r.footer(result)

proc tableScrollDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Usage report", "Six columns that scroll sideways " &
    "on a phone.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Usage report")
  discard r.el(s, "p", text = "Builds per day this week, Monday to " &
    "Friday. On a phone, scroll the table sideways to see every day.")
  discard r.dataTable(s, ["Project", "Mon", "Tue", "Wed", "Thu", "Fri"], [
    @["api-server", "41", "38", "52", "47", "33"],
    @["web-client", "12", "19", "8", "22", "15"],
    @["docs", "3", "0", "5", "2", "1"]],
    [("caption", "Builds per project and day"), ("mobile", "scroll")],
    [1, 2, 3, 4, 5])
  r.footer(result)

proc tableRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("طلبك", "ثلاثة أصناف، شُحنت اليوم.", rtl = true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "طلبك")
  discard r.el(s, "p", text = "الطلب ١٠٤٢، شُحن اليوم.")
  discard r.dataTable(s, ["الصنف", "الكمية", "المبلغ", "ملاحظة"], [
    @["دفتر", "٢", "١٢٫٠٠ ر.س", "هدية"], @["أقلام", "١", "٤٫٥٠ ر.س", "—"],
    @["ممحاة", "٣", "٢٫٢٥ ر.س", "—"]],
    [("caption", "أصناف الطلب ١٠٤٢")], [1, 2])
  r.footer(result, rtl = true)

proc tableImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your cart", "Pictures of the items beside their " &
    "names.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Your cart")
  let mt = r.el(s, "mailTable", attrs = [("caption", "Items in your cart")])
  let table = r.el(mt, "table")
  let hr = r.el(r.el(table, "thead"), "tr")
  discard r.el(hr, "th", text = "Picture")
  discard r.el(hr, "th", text = "Item")
  discard r.el(hr, "th", [("text-align", "right")], text = "Price")
  let body = r.el(table, "tbody")
  for (src, alt, name, price) in [(fixtureImageUrl("shield.png"),
      "A green shield", "Shield badge", "$3.00"),
      (fixtureImageUrl("logo.png"), "The Acme logo", "Acme sticker",
        "$1.50")]:
    let tr = r.el(body, "tr")
    let cell = r.el(tr, "td")
    discard r.el(cell, "mailImage", [("width", "48px")],
      [("src", src), ("alt", alt)])
    discard r.el(tr, "td", text = name)
    discard r.el(tr, "td", [("text-align", "right")], text = price)
  discard r.el(s, "p", [("margin", "16px 0 0")], text = "Prices include " &
    "tax.")
  r.footer(result)

proc tableDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Usage, dark", "A striped table in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Usage, dark")
  let t = r.dataTable(s, ["Service", "Requests", "Errors"], [
    @["api", "1,204", "3"], @["web", "866", "0"], @["worker", "310", "1"],
    @["cron", "24", "0"]], [("caption", "Requests per service"),
      ("striped", "true")], [1, 2])
  # Every text colour is a token with its dark pair.
  for row in t.children[0].children:
    for tr in row.children:
      for cell in tr.children:
        r.paint(cell, "color", tok"color.text.primary")
  r.dkFooter(result)

proc tableInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Receipt", "A table in a rounded box, between a " &
    "paragraph and a button.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Receipt")
  discard r.el(s, "p", text = "Thanks for your order. Your receipt:")
  let box = r.el(s, "mailBox", [("background-color", "#f8f9fb"),
    ("border", "1px solid #d1d5db"), ("border-radius", "12px"),
    ("padding", "8px")])
  let t = r.dataTable(box, ["Item", "Amount"], [
    @["Team plan", "$120.00"], @["Tax", "$24.00"], @["Total", "$144.00"]],
    [("caption", "Receipt lines")], [1])
  r.setStyle(t, "border", "1px solid #d1d5db")
  discard r.el(s, "mailSpacer", [("height", "16px")])
  discard r.el(s, "mailButton", attrs = [("href",
    "https://app.example.com/billing")], text = "View billing")
  let b = r.band(result, "#eef2ff")
  discard r.el(b, "p", text = "Questions about this receipt? Reply to this " &
    "email.")
  r.footer(result)

# --- Registration -----------------------------------------------------------

let tableStories*: array[7, KitStory] = [
  ("tableMinimal", "mailTable with its defaults.", tableMinimalDoc, false),
  ("tableMaximal", "Five columns that stack, striped, a spanning total, " &
    "a long reference.", tableMaximalDoc, false),
  ("tableScroll", "Six columns that scroll sideways on a phone.",
    tableScrollDoc, false),
  ("tableRtl", "A table in Arabic, right to left.", tableRtlDoc, false),
  ("tableImagesOff", "Thumbnails in the cells (capture with images off).",
    tableImagesOffDoc, false),
  ("tableDark", "A striped table in its dark colours.", tableDarkDoc, true),
  ("tableInContext", "A table in a rounded box, between a paragraph and " &
    "a button.", tableInContextDoc, false),
]

proc tableGroup(name: string): string = "table"

proc renderTableStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(tableStories, name, "table")

proc registerTableStories*() =
  ## Registers the data tables' story set (env-gated, see above).
  registerKit(tableStories, tableGroup)

proc registerTableStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(tableStories)
