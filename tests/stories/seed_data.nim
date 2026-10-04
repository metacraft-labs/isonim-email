## Data pattern stories: the story sets of `mailKeyValue`,
## `mailLineItems`, `mailStatTiles`, `mailStepper`, `mailTimeline` and
## `mailEvent` (layout-patterns.md §5): `Minimal`, `Maximal`, `Rtl`,
## `ImagesOff`, `Dark` and `InContext` for each. The patterns without
## images of their own are captured with images off beside an image (a
## logo, a thumbnail), so their layout is checked with the image's alt
## text in its place.
##
## The thumbnails are the compile-time `photo-*.png` placeholders and
## `shield.png`, on the capture fixture host.
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images
import story_kit

const logoLight = "mark-outlined.png"

proc intro(r: EmailRenderer; doc: EmailNode; title, body: string;
    bg = "#ffffff") =
  let s = r.band(doc, bg, "24px 0 8px")
  discard r.el(s, "h1", text = title)
  if body.len > 0:
    discard r.el(s, "p", [("margin", "0")], text = body)

proc logoBand(r: EmailRenderer; doc: EmailNode) =
  ## A band holding the logo (the images-off stories' image).
  let s = r.band(doc, padding = "24px 0 0")
  discard r.el(s, "mailImage", [("width", "120px"),
    ("height", fixtureImageHeight(logoLight, 120))],
    [("src", fixtureImageUrl(logoLight)), ("alt", "Acme")])

proc kv(r: EmailRenderer; parent: EmailNode;
    rows: openArray[(string, string)]; caption = "Order summary";
    total = true): EmailNode =
  result = r.el(parent, "mailKeyValue", attrs = [("caption", caption),
    ("total_row", if total: "true" else: "")])
  for (label, value) in rows:
    discard r.el(result, "mailKeyValueRow", attrs = [("label", label)],
      text = value)

proc item(r: EmailRenderer; parent: EmailNode; description, detail, qty,
    amount: string; thumb = "") =
  discard r.el(parent, "mailLineItem", attrs = [("description", description),
    ("detail", detail), ("qty", qty), ("amount", amount), ("thumb", thumb)])

# --- mailKeyValue ---------------------------------------------------------------

proc keyValueMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your receipt", "A key-value summary.")
  r.intro(result, "Your receipt", "")
  let s = r.band(result)
  discard r.kv(s, [("Subtotal", "$120.00"), ("Tax", "$12.00")],
    total = false)
  r.footer(result)

proc keyValueMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your receipt", "A summary with every prop and " &
    "long rows.")
  r.intro(result, "Your receipt", "Order 1042, paid 3 October 2026.")
  let s = r.band(result)
  let k = r.el(s, "mailKeyValue", attrs = [("caption", "Order summary"),
    ("total_row", "true")])
  for (label, value, emph) in [("Subtotal", "$1,204.00", false),
      ("Shipping (express, signature required, insured up to $500)",
        "$32.50", false), ("Discount code SUMMER-" & longWord, "−$120.00",
        false), ("Payment", "Visa ending 4242, charged on 3 October 2026",
        false), ("Tax (VAT 20%)", "$223.30", true),
      ("Total", "$1,339.80", false)]:
    discard r.el(k, "mailKeyValueRow", attrs = [("label", label),
      ("emphasis", if emph: "true" else: "")], text = value)
  r.footer(result)

proc keyValueRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("إيصالك", "ملخص من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "إيصالك", "")
  let s = r.band(result)
  discard r.kv(s, [("المجموع الفرعي", "١٢٠٫٠٠ ر.س"), ("الضريبة",
    "١٨٫٠٠ ر.س"), ("الإجمالي", "١٣٨٫٠٠ ر.س")], "ملخص الطلب")
  r.footer(result, rtl = true)

proc keyValueImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your receipt", "A summary under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "Your receipt", "With images blocked, the logo shows " &
    "its alt text above the summary.")
  let s = r.band(result)
  discard r.kv(s, [("Subtotal", "$120.00"), ("Tax", "$12.00"),
    ("Total", "$132.00")])
  r.footer(result)

proc keyValueDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your receipt, dark", "A summary in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Your receipt, dark")
  discard r.kv(s, [("Subtotal", "$120.00"), ("Tax", "$12.00"),
    ("Total", "$132.00")])
  r.dkFooter(result)

proc keyValueInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your receipt", "A summary between line items and " &
    "a button.")
  r.intro(result, "Your receipt", "")
  let s = r.band(result)
  let li = r.el(s, "mailLineItems", attrs = [("caption", "Items")])
  r.item(li, "Wireless keyboard", "SKU KB-42", "1", "$49.00")
  r.item(li, "USB-C cable", "SKU CB-07", "2", "$18.00")
  let t = r.band(result, "#f4f5f7")
  discard r.kv(t, [("Subtotal", "$67.00"), ("Shipping", "Free"),
    ("Total", "$67.00")])
  let b = r.band(result)
  discard r.el(b, "mailButton", attrs = [("href",
    "https://example.com/orders/1042")], text = "View your order")
  r.footer(result)

# --- mailLineItems --------------------------------------------------------------

proc lineItemsMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order", "Line items with their required props.")
  r.intro(result, "Your order", "")
  let s = r.band(result)
  let li = r.el(s, "mailLineItems", attrs = [("caption", "Order 1042")])
  discard r.el(li, "mailLineItem", attrs = [("description",
    "Wireless keyboard"), ("amount", "$49.00")])
  discard r.el(li, "mailLineItem", attrs = [("description", "USB-C cable"),
    ("amount", "$18.00")])
  r.footer(result)

proc lineItemsMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Invoice 2026-118", "Line items with thumbnails, " &
    "details and long names.")
  r.intro(result, "Invoice 2026-118", "Readable at 320px: three columns, " &
    "the SKU and unit price under each name.")
  let s = r.band(result)
  let li = r.el(s, "mailLineItems", attrs = [("caption", "Invoice " &
    "2026-118"), ("item_label", "Description"), ("qty_label", "Qty"),
    ("amount_label", "Amount"), ("thumb_width", "48")])
  r.item(li, "Ergonomic split keyboard with walnut wrist rests and " &
    "replaceable switches", "SKU KB-SPLIT-42 · $189.00 each", "1",
    "$189.00", $asset"assets/photo-forest.png")
  r.item(li, "Braided USB-C to USB-C cable, 2 m", "SKU CB-07 · $9.00 each",
    "12", "$108.00", $asset"assets/photo-lake.png")
  r.item(li, "Gift wrapping " & longWord, "Reference " & longWord, "1",
    "$4.50")
  r.footer(result)

proc lineItemsRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("طلبك", "بنود من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "طلبك", "")
  let s = r.band(result)
  let li = r.el(s, "mailLineItems", attrs = [("caption", "الطلب ١٠٤٢"),
    ("item_label", "البند"), ("qty_label", "الكمية"), ("amount_label",
      "المبلغ")])
  r.item(li, "لوحة مفاتيح لاسلكية", "رمز KB-42", "١", "١٨٤ ر.س")
  r.item(li, "كابل USB-C", "رمز CB-07", "٢", "٦٨ ر.س")
  r.footer(result, rtl = true)

proc lineItemsImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order", "Line items whose thumbnails are " &
    "blocked.")
  r.intro(result, "Your order", "With images blocked, the thumbnails " &
    "show their alt text beside each name.")
  let s = r.band(result)
  let li = r.el(s, "mailLineItems", attrs = [("caption", "Order 1042"),
    ("thumb_width", "64")])
  for (name, photo, alt) in [("Coast print, A3",
      $asset"assets/photo-coast.png", "Coast"), ("Desert print, A4",
      $asset"assets/photo-desert.png", "Dunes")]:
    discard r.el(li, "mailLineItem", attrs = [("description", name),
      ("detail", "Matte paper"), ("qty", "1"), ("amount", "$24.00"),
      ("thumb", photo), ("thumb_alt", alt)])
  r.footer(result)

proc lineItemsDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your order, dark", "Line items in their dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Your order, dark")
  let li = r.el(s, "mailLineItems", attrs = [("caption", "Order 1042")])
  r.item(li, "Wireless keyboard", "SKU KB-42 · $49.00 each", "1", "$49.00")
  r.item(li, "USB-C cable", "SKU CB-07 · $9.00 each", "2", "$18.00")
  let c = r.el(s, "mailLineItems", attrs = [("caption", "Order 1043"),
    ("mobile", "cards")])
  r.item(c, "Desk lamp", "SKU LP-3", "1", "$39.00")
  r.dkFooter(result)

proc lineItemsInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order", "Line items as cards between a " &
    "heading and a summary.")
  r.intro(result, "Your order", "Each item is a card on every screen.")
  let s = r.band(result, "#f4f5f7")
  let li = r.el(s, "mailLineItems", attrs = [("caption", "Order 1042"),
    ("mobile", "cards")])
  r.item(li, "Wireless keyboard", "SKU KB-42 · $49.00 each", "1", "$49.00",
    $asset"assets/photo-field.png")
  r.item(li, "USB-C cable", "SKU CB-07 · $9.00 each", "2", "$18.00")
  let t = r.band(result)
  discard r.kv(t, [("Subtotal", "$67.00"), ("Total", "$67.00")])
  r.footer(result)

# --- mailStatTiles --------------------------------------------------------------

proc stats(r: EmailRenderer; parent: EmailNode;
    items: openArray[(string, string, string)]): EmailNode =
  result = r.el(parent, "mailStatTiles")
  for (value, label, tone) in items:
    discard r.el(result, "mailStat", attrs = [("value", value),
      ("label", label), ("tone", tone)])

proc statTilesMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your week", "Two stat tiles.")
  r.intro(result, "Your week", "")
  let s = r.band(result)
  discard r.stats(s, [("42", "Deploys", ""), ("99.98%", "Uptime", "")])
  r.footer(result)

proc statTilesMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your month", "Three and four stat tiles in every " &
    "tone.")
  r.intro(result, "Your month", "Three tiles share a phone's width; four " &
    "go two to a row.")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  discard r.stats(stack, [("1,204", "Orders shipped this month", "primary"),
    ("98.7%", "Delivered on time", "success"), ("$48k", "Revenue", "")])
  discard r.stats(stack, [("12", "Open incidents needing attention",
    "danger"), ("3", "Warnings", "warning"), ("7", "Notes", "info"),
    ("214", longWord, "neutral")])
  r.footer(result)

proc statTilesRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("أسبوعك", "مربعات أرقام من اليمين إلى اليسار.",
    rtl = true)
  r.intro(result, "أسبوعك", "")
  let s = r.band(result)
  discard r.stats(s, [("٤٢", "عمليات النشر", ""), ("٩٩٫٩٨٪", "وقت التشغيل",
    "success"), ("٣", "الحوادث", "warning")])
  r.footer(result, rtl = true)

proc statTilesImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your week", "Stat tiles under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "Your week", "With images blocked, the logo shows its " &
    "alt text above the tiles.")
  let s = r.band(result)
  discard r.stats(s, [("42", "Deploys", ""), ("99.98%", "Uptime",
    "success"), ("3", "Incidents", "warning"), ("0", "Rollbacks", "")])
  r.footer(result)

proc statTilesDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your week, dark", "Stat tiles in their dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Your week, dark")
  discard r.stats(s, [("42", "Deploys", "primary"), ("99.98%", "Uptime",
    "success"), ("3", "Incidents", "danger")])
  r.dkFooter(result)

proc statTilesInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your week", "Stat tiles between a band and a " &
    "callout.")
  let b = r.el(result, "mailBand", [("background-color", "#0b3a6e"),
    ("padding", "32px 0")])
  discard r.el(b, "h1", [("color", "#ffffff")], text = "Your week")
  let s = r.band(result)
  discard r.stats(s, [("42", "Deploys", ""), ("99.98%", "Uptime",
    "success"), ("3", "Incidents", "warning")])
  let t = r.band(result)
  let c = r.el(t, "mailCallout", attrs = [("tone", "info"),
    ("title", "Weekly report")])
  discard r.el(c, "p", [("margin", "0")], text = "Sent every Monday.")
  r.footer(result)

# --- mailStepper ----------------------------------------------------------------

proc stepper(r: EmailRenderer; parent: EmailNode; labels: openArray[string];
    current: int; attrs: openArray[(string, string)] = []): EmailNode =
  var a = @[("current", $current)]
  for x in attrs:
    a.add(x)
  result = r.el(parent, "mailStepper", attrs = a)
  for l in labels:
    discard r.el(result, "mailStep", text = l)

proc stepperMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order has shipped", "Three steps, the second " &
    "current.")
  r.intro(result, "Your order has shipped", "")
  let s = r.band(result)
  discard r.stepper(s, ["Ordered", "Shipped", "Delivered"], 2)
  r.footer(result)

proc stepperMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Out for delivery", "Five steps with long labels.")
  r.intro(result, "Out for delivery", "Five steps whose labels cannot " &
    "fit a phone in one row: the stepper is drawn vertically, each label " &
    "beside its marker.")
  let s = r.band(result)
  discard r.stepper(s, ["Order placed", "Payment confirmed",
    "Shipped from warehouse", "Out for delivery", "Delivered " & longWord],
    4)
  r.footer(result)

proc stepperRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("تم شحن طلبك", "خطوات من اليمين إلى اليسار.",
    rtl = true)
  r.intro(result, "تم شحن طلبك", "")
  let s = r.band(result)
  discard r.stepper(s, ["تم الطلب", "تم الشحن", "قيد التوصيل", "تم التسليم"],
    2, [("status", "الخطوة الحالية: تم الشحن (٢ من ٤)"),
      ("text", "الخطوة ٢ من ٤: تم الشحن. التالي: قيد التوصيل.")])
  r.footer(result, rtl = true)

proc stepperImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order has shipped", "A stepper under a " &
    "blocked logo.")
  r.logoBand(result)
  r.intro(result, "Your order has shipped", "With images blocked, the " &
    "logo shows its alt text; the stepper has no images.")
  let s = r.band(result)
  discard r.stepper(s, ["Ordered", "Shipped", "Out for delivery",
    "Delivered"], 2)
  r.footer(result)

proc stepperDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your order, dark", "A stepper in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Your order, dark")
  discard r.stepper(s, ["Ordered", "Shipped", "Out for delivery",
    "Delivered"], 3)
  r.dkFooter(result)

proc stepperInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order has shipped", "A stepper between a " &
    "heading and the items.")
  r.intro(result, "Your order has shipped", "It arrives on Thursday.")
  let s = r.band(result, "#eef2ff")
  discard r.stepper(s, ["Ordered", "Shipped", "Out for delivery",
    "Delivered"], 2)
  let t = r.el(r.band(result), "mailStack", [("gap", "16px")])
  let m = r.el(t, "mailMediaObject", attrs = [("image",
    $asset"assets/photo-coast.png"), ("image_width", "64"),
    ("image_alt", "Print"), ("image_ratio", "1:1"),
    ("valign", "middle")])
  discard r.el(m, "p", [("margin", "0")], text = "Coast print, A3 — $24.00")
  discard r.el(t, "mailButton", attrs = [("href",
    "https://example.com/track")], text = "Track your parcel")
  r.footer(result)

# --- mailTimeline ---------------------------------------------------------------

proc timeline(r: EmailRenderer; parent: EmailNode;
    events: openArray[(string, string)]): EmailNode =
  result = r.el(parent, "mailTimeline")
  for (time, text) in events:
    discard r.el(result, "mailTimelineEvent", attrs = [("time", time)],
      text = text)

proc timelineMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Incident resolved", "A timeline of two events.")
  r.intro(result, "Incident resolved", "")
  let s = r.band(result)
  discard r.timeline(s, [("09:12 UTC", "Investigating elevated errors."),
    ("10:05 UTC", "Resolved.")])
  r.footer(result)

proc timelineMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Incident report", "A long timeline with long " &
    "events.")
  r.intro(result, "Incident report", "Every update, newest last.")
  let s = r.band(result)
  let t = r.el(s, "mailTimeline")
  for (time, text) in [("14 Oct, 09:12 UTC", "We are investigating " &
      "elevated error rates on the API in the EU region."),
      ("14 Oct, 09:40 UTC", "The cause is a failed configuration push; " &
        "rolling it back."), ("14 Oct, 10:05 UTC", "Error rates are back " &
          "to normal. Reference " & longWord & "."),
      ("15 Oct, 08:00 UTC", "Post-incident review published.")]:
    let ev = r.el(t, "mailTimelineEvent", attrs = [("time", time)])
    discard r.el(ev, "p", [("margin", "0")], text = text)
  r.footer(result)

proc timelineRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("تم حل المشكلة", "خط زمني من اليمين إلى اليسار.",
    rtl = true)
  r.intro(result, "تم حل المشكلة", "")
  let s = r.band(result)
  discard r.timeline(s, [("٠٩:١٢", "نحقق في ارتفاع الأخطاء."),
    ("٠٩:٤٠", "تم نشر إصلاح."), ("١٠:٠٥", "تم الحل.")])
  r.footer(result, rtl = true)

proc timelineImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Incident resolved", "A timeline under a blocked " &
    "logo.")
  r.logoBand(result)
  r.intro(result, "Incident resolved", "With images blocked, the logo " &
    "shows its alt text; the timeline has no images.")
  let s = r.band(result)
  discard r.timeline(s, [("09:12 UTC", "Investigating."),
    ("09:40 UTC", "Fix deployed."), ("10:05 UTC", "Resolved.")])
  r.footer(result)

proc timelineDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Incident resolved, dark", "A timeline in its dark " &
    "colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Incident resolved, dark")
  discard r.timeline(s, [("09:12 UTC", "Investigating."),
    ("09:40 UTC", "Fix deployed."), ("10:05 UTC", "Resolved.")])
  r.dkFooter(result)

proc timelineInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Incident report", "A timeline between a callout " &
    "and a button.")
  r.intro(result, "Incident report", "")
  let s = r.band(result)
  let c = r.el(s, "mailCallout", attrs = [("tone", "success"),
    ("title", "Resolved")])
  discard r.el(c, "p", [("margin", "0")], text = "All systems normal.")
  let t = r.band(result, "#f4f5f7")
  discard r.timeline(t, [("09:12 UTC", "Investigating."),
    ("09:40 UTC", "Fix deployed."), ("10:05 UTC", "Resolved.")])
  let b = r.band(result)
  discard r.el(b, "mailButton", attrs = [("href",
    "https://example.com/status")], text = "Status page")
  r.footer(result)

# --- mailEvent ------------------------------------------------------------------

proc event(r: EmailRenderer; parent: EmailNode;
    attrs: openArray[(string, string)]; title: string;
    level = "h2"): EmailNode =
  result = r.el(parent, "mailEvent", attrs = attrs)
  discard r.el(result, level, [("margin", "0")], text = title)

proc eventMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("You're invited", "An event with its required props.")
  r.intro(result, "You're invited", "")
  let s = r.band(result)
  discard r.event(s, [("month", "Oct"), ("day", "14"), ("date_text",
    "Tuesday, 14 October 2026, 18:00 CEST")], "Launch party")
  r.footer(result)

proc eventMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("You're invited", "An event with every prop.")
  r.intro(result, "You're invited", "")
  let s = r.band(result)
  let e = r.el(s, "mailEvent", attrs = [("month", "Oct"), ("day", "14"),
    ("date_text", "Tuesday, 14 October 2026, 18:00–21:30 CEST (doors " &
      "open at 17:30)"), ("location", "The Old Brewery, Brauereistraße " &
      "12, 10115 Berlin, second floor, ring " & longWord),
    ("google", "https://calendar.example.com/google/launch"),
    ("outlook", "https://calendar.example.com/outlook/launch"),
    ("ics", "https://example.com/launch.ics")])
  discard r.el(e, "h2", [("margin", "0 0 8px")], text = "Product launch " &
    "party and live demo of the new release")
  discard r.el(e, "p", [("margin", "0")], text = "Drinks, a short talk " &
    "and a hands-on demo. Bring a friend.")
  r.footer(result)

proc eventRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("دعوة", "حدث من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "أنت مدعو", "")
  let s = r.band(result)
  discard r.event(s, [("month", "أكتوبر"), ("day", "١٤"), ("date_text",
    "الثلاثاء ١٤ أكتوبر ٢٠٢٦، الساعة ١٨:٠٠"), ("location", "الرياض"),
    ("ics", "https://example.com/launch.ics"), ("ics_label", "إضافة إلى " &
      "التقويم")], "حفل الإطلاق")
  r.footer(result, rtl = true)

proc eventImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("You're invited", "An event under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "You're invited", "With images blocked, the logo shows " &
    "its alt text; the date tile is text and stays.")
  let s = r.band(result)
  discard r.event(s, [("month", "Nov"), ("day", "3"), ("date_text",
    "Monday, 3 November 2026, 10:00 GMT"), ("google",
    "https://calendar.example.com/google/demo")], "Live demo")
  r.footer(result)

proc eventDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("You're invited, dark", "An event in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "You're invited, dark")
  let e = r.el(s, "mailEvent", attrs = [("month", "Oct"), ("day", "14"),
    ("date_text", "Tuesday, 14 October 2026, 18:00 CEST"),
    ("location", "Berlin"), ("google",
      "https://calendar.example.com/google/launch")])
  discard r.dkText(e, "h2", "Launch party", [("margin", "0")])
  r.dkFooter(result)

proc eventInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Events this month", "Two events between a hero " &
    "and a button.")
  let hero = r.el(result, "mailHero", [("background-color", "#0b3a6e"),
    ("padding", "32px 0")])
  discard r.el(hero, "h1", [("color", "#ffffff")], text = "Events this month")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "24px")])
  discard r.event(stack, [("month", "Oct"), ("day", "14"), ("date_text",
    "Tuesday, 14 October 2026, 18:00 CEST"), ("location", "Berlin"),
    ("ics", "https://example.com/launch.ics")], "Launch party")
  discard r.event(stack, [("month", "Oct"), ("day", "28"), ("date_text",
    "Tuesday, 28 October 2026, 17:00 GMT"), ("location", "Online"),
    ("google", "https://calendar.example.com/google/qa")], "Q&A session")
  let b = r.band(result, "#f4f5f7")
  discard r.el(b, "mailButton", attrs = [("href",
    "https://example.com/events")], text = "All events")
  r.footer(result)

# --- Registration -------------------------------------------------------------

proc story(name, description: string;
    build: proc(): EmailNode {.nimcall.}; dark: bool): KitStory =
  (name, description, build, dark)

let dataStories*: seq[KitStory] = @[
  story("keyValueMinimal", "mailKeyValue: two rows.", keyValueMinimalDoc, false),
  story("keyValueMaximal", "mailKeyValue: long labels and values, an emphasised " &
    "row and a total.", keyValueMaximalDoc, false),
  story("keyValueRtl", "mailKeyValue right to left.", keyValueRtlDoc, false),
  story("keyValueImagesOff", "mailKeyValue under a logo (capture with images " &
    "off).", keyValueImagesOffDoc, false),
  story("keyValueDark", "mailKeyValue in its dark colours.", keyValueDarkDoc,
    true),
  story("keyValueInContext", "mailKeyValue between line items and a button.",
    keyValueInContextDoc, false),
  story("lineItemsMinimal", "mailLineItems: descriptions and amounts.",
    lineItemsMinimalDoc, false),
  story("lineItemsMaximal", "mailLineItems: thumbnails, details, long names.",
    lineItemsMaximalDoc, false),
  story("lineItemsRtl", "mailLineItems right to left.", lineItemsRtlDoc, false),
  story("lineItemsImagesOff", "mailLineItems with thumbnails (capture with " &
    "images off).", lineItemsImagesOffDoc, false),
  story("lineItemsDark", "mailLineItems (table and cards) in their dark " &
    "colours.", lineItemsDarkDoc, true),
  story("lineItemsInContext", "mailLineItems as cards above a summary.",
    lineItemsInContextDoc, false),
  story("statTilesMinimal", "mailStatTiles: two tiles.", statTilesMinimalDoc,
    false),
  story("statTilesMaximal", "mailStatTiles: three and four tiles, every tone.",
    statTilesMaximalDoc, false),
  story("statTilesRtl", "mailStatTiles right to left.", statTilesRtlDoc, false),
  story("statTilesImagesOff", "mailStatTiles under a logo (capture with images " &
    "off).", statTilesImagesOffDoc, false),
  story("statTilesDark", "mailStatTiles in their dark colours.",
    statTilesDarkDoc, true),
  story("statTilesInContext", "mailStatTiles between a band and a callout.",
    statTilesInContextDoc, false),
  story("stepperMinimal", "mailStepper: three steps.", stepperMinimalDoc, false),
  story("stepperMaximal", "mailStepper: five steps, long labels.",
    stepperMaximalDoc, false),
  story("stepperRtl", "mailStepper right to left.", stepperRtlDoc, false),
  story("stepperImagesOff", "mailStepper under a logo (capture with images " &
    "off).", stepperImagesOffDoc, false),
  story("stepperDark", "mailStepper in its dark colours.", stepperDarkDoc, true),
  story("stepperInContext", "mailStepper on a tinted band above the items.",
    stepperInContextDoc, false),
  story("timelineMinimal", "mailTimeline: two events.", timelineMinimalDoc,
    false),
  story("timelineMaximal", "mailTimeline: four long events.", timelineMaximalDoc,
    false),
  story("timelineRtl", "mailTimeline right to left.", timelineRtlDoc, false),
  story("timelineImagesOff", "mailTimeline under a logo (capture with images " &
    "off).", timelineImagesOffDoc, false),
  story("timelineDark", "mailTimeline in its dark colours.", timelineDarkDoc,
    true),
  story("timelineInContext", "mailTimeline between a callout and a button.",
    timelineInContextDoc, false),
  story("eventMinimal", "mailEvent with its required props.", eventMinimalDoc,
    false),
  story("eventMaximal", "mailEvent with every prop.", eventMaximalDoc, false),
  story("eventRtl", "mailEvent right to left.", eventRtlDoc, false),
  story("eventImagesOff", "mailEvent under a logo (capture with images off).",
    eventImagesOffDoc, false),
  story("eventDark", "mailEvent in its dark colours.", eventDarkDoc, true),
  story("eventInContext", "Two mailEvents between a hero and a button.",
    eventInContextDoc, false),
]

proc dataGroup(name: string): string =
  for prefix in ["keyValue", "lineItems", "statTiles", "stepper",
      "timeline", "event"]:
    if name.startsWith(prefix):
      return prefix
  name

proc renderDataStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(dataStories, name, "data")

proc registerDataStories*() =
  ## Registers the data pattern story sets (env-gated, see above).
  registerKit(dataStories, dataGroup)

proc registerDataStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(dataStories)
