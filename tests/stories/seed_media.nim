## Media pattern stories: the story sets of `mailMediaObject`,
## `mailZigZag`, `mailGallery` and `mailCountdown` (layout-patterns.md
## §5): `Minimal`, `Maximal`, `Rtl`, `ImagesOff`, `Dark` and `InContext`
## for each, except `mailZigZag`'s `Rtl`: a zig-zag is refused in a
## right-to-left document (its even rows' reversal, R-LAY-11), which a
## test pins instead.
##
## The photos are `tests/stories/assets/photo-*.png` (flat illustrated
## scenes: 480×360, 480×320 and 360×480, of different ratios on purpose)
## and the countdown `countdown.gif` (560×140, two frames of a
## seven-segment clock whose first frame carries the time left). The
## photos are compile-time assets (`asset"…"`), so the asset pass crops
## them (R-IMG-13) and publishes each crop to the capture fixture host
## (`story_kit.fixtureStore`).
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images
import story_kit

let photos = [
  ("The coast", $asset"assets/photo-coast.png"),
  ("A forest", $asset"assets/photo-forest.png"),
  ("Dunes", $asset"assets/photo-desert.png"),
  ("A lake", $asset"assets/photo-lake.png"),
  ("The city", $asset"assets/photo-city.png"),
  ("A field", $asset"assets/photo-field.png"),
]
  ## (alt, src) of each placeholder photo.

proc intro(r: EmailRenderer; doc: EmailNode; title, body: string;
    bg = "#ffffff") =
  let s = r.band(doc, bg, "24px 0 8px")
  discard r.el(s, "h1", text = title)
  if body.len > 0:
    discard r.el(s, "p", [("margin", "0")], text = body)

proc media(r: EmailRenderer; parent: EmailNode; photo: int;
    attrs: openArray[(string, string)] = []): EmailNode =
  var a = @[("image", photos[photo][1]), ("image_width", "96"),
    ("image_alt", photos[photo][0])]
  for x in attrs:
    var replaced = false
    for i in 0 ..< a.len:
      if a[i][0] == x[0]:
        a[i] = x
        replaced = true
    if not replaced:
      a.add(x)
  r.el(parent, "mailMediaObject", attrs = a)

# --- mailMediaObject ----------------------------------------------------------

proc mediaObjectMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your trip", "A thumbnail beside its text.")
  r.intro(result, "Your trip", "")
  let s = r.band(result)
  let m = r.media(s, 0)
  discard r.el(m, "h2", text = "Coast walk, Saturday")
  discard r.el(m, "p", [("margin", "0")], text = "Meet at the harbour " &
    "at nine; the walk takes three hours.")
  r.footer(result)

proc mediaObjectMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Picked for you", "Every media object prop.")
  r.intro(result, "Picked for you", "A linked square thumbnail on the " &
    "right, centred against long text; on a phone the image comes first.")
  let s = r.band(result)
  let m = r.media(s, 1, [("image_width", "160"), ("image_ratio", "1:1"),
    ("image_href", "https://example.com/forest"), ("side", "right"),
    ("stack", "below"), ("valign", "middle"), ("gap", "24px")])
  discard r.el(m, "h2", text = "A weekend in the forest cabins, with " &
    "every meal included")
  discard r.el(m, "p", text = "Two nights in a timber cabin under the " &
    "pines, breakfast and dinner at the lodge, and a guided walk on " &
    "Sunday morning. Booking reference " & longWord & ".")
  discard r.el(m, "mailButton", attrs = [("href",
    "https://example.com/forest")], text = "See the cabins")
  r.footer(result)

proc mediaObjectRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("رحلتك", "صورة مصغرة بجانب نصها.", rtl = true)
  r.intro(result, "رحلتك", "")
  let s = r.band(result)
  let m = r.media(s, 0, [("image_alt", "الساحل"),
    ("stack", "below")])
  discard r.el(m, "h2", text = "نزهة على الساحل يوم السبت")
  discard r.el(m, "p", [("margin", "0")], text = "نلتقي عند الميناء في " &
    "التاسعة، وتستغرق النزهة ثلاث ساعات.")
  r.footer(result, rtl = true)

proc mediaObjectImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your trip", "Thumbnails with images blocked.")
  r.intro(result, "Your trip", "With images blocked, each thumbnail " &
    "shows its alt text beside its text.")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  let a = r.media(stack, 0, [("image_ratio", "1:1")])
  discard r.el(a, "p", [("margin", "0")], text = "Coast walk, Saturday " &
    "at nine.")
  let b = r.media(stack, 3, [("image_ratio", "1:1"), ("stack", "below")])
  discard r.el(b, "p", [("margin", "0")], text = "Lake swim, Sunday at " &
    "ten.")
  r.footer(result)

proc mediaObjectDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your trip, dark", "A media object in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Your trip, dark")
  let m = r.media(s, 4, [("image_ratio", "1:1")])
  discard r.dkText(m, "h2", "Night tour of the old town")
  discard r.dkText(m, "p", "Starts at the clock tower at eight.",
    [("margin", "0")], tok"color.text.secondary")
  r.dkFooter(result)

proc mediaObjectInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order", "Three items, each a thumbnail beside " &
    "its name.")
  r.intro(result, "Your order", "Three items are on their way.")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  for (i, name, price) in [(0, "Coast print, A3", "$24.00"),
      (2, "Desert print, A4", "$18.00"), (5, "Field print, A3", "$24.00")]:
    let m = r.media(stack, i, [("image_width", "80"),
      ("image_ratio", "1:1"), ("valign", "middle")])
    discard r.el(m, "p", [("margin", "0"), ("font-weight", "700")],
      text = name)
    discard r.el(m, "p", [("margin", "0")], text = price)
  let t = r.band(result, "#eef2ff")
  discard r.el(t, "mailButton", attrs = [("href",
    "https://example.com/orders/1042")], text = "Track your order")
  r.footer(result)

# --- mailZigZag ---------------------------------------------------------------

proc zigRow(r: EmailRenderer; zig: EmailNode; photo: int; title,
    body: string; attrs: openArray[(string, string)] = []) =
  var a = @[("image_width", "260"), ("image_ratio", "4:3")]
  for x in attrs:
    a.add(x)
  let m = r.media(zig, photo, a)
  discard r.el(m, "h2", text = title)
  discard r.el(m, "p", [("margin", "0")], text = body)

proc zigZagMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Two places", "A zig-zag of two rows.")
  r.intro(result, "Two places", "")
  let s = r.band(result)
  let z = r.el(s, "mailZigZag")
  r.zigRow(z, 0, "The coast", "Sand, sea and a long walk at low tide.")
  r.zigRow(z, 1, "The forest", "Pines, a cabin and a quiet morning.")
  r.footer(result)

proc zigZagMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Four places", "A zig-zag of four rows.")
  r.intro(result, "Four places for the summer", "Images alternate sides " &
    "on a wide screen; on a phone every image comes first.")
  let s = r.band(result)
  let z = r.el(s, "mailZigZag", attrs = [("gap", "40px")])
  r.zigRow(z, 0, "The coast", "Sand, sea and a long walk at low tide, " &
    "with a café at the end of the pier that opens at seven.",
    [("image_href", "https://example.com/coast"), ("valign", "middle")])
  r.zigRow(z, 1, "The forest", "Pines, a cabin and a quiet morning; the " &
    "lodge serves breakfast until ten. Reference " & longWord & ".",
    [("image_href", "https://example.com/forest"), ("valign", "middle")])
  r.zigRow(z, 3, "The lake", "A swim before lunch and a boat in the " &
    "afternoon.", [("valign", "middle")])
  r.zigRow(z, 5, "The fields", "Wheat as far as you can see, and a long " &
    "evening light.", [("valign", "middle")])
  r.footer(result)

proc zigZagImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Two places", "A zig-zag with images blocked.")
  r.intro(result, "Two places", "With images blocked, each row shows its " &
    "image's alt text beside its text.")
  let s = r.band(result)
  let z = r.el(s, "mailZigZag")
  r.zigRow(z, 3, "The lake", "A swim before lunch.")
  r.zigRow(z, 4, "The city", "A night tour of the old town.")
  r.footer(result)

proc zigZagDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Two places, dark", "A zig-zag in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Two places, dark")
  let z = r.el(s, "mailZigZag")
  for (i, title, body) in [(4, "The city", "A night tour of the old town."),
      (3, "The lake", "A swim before lunch.")]:
    let m = r.media(z, i, [("image_width", "260"), ("image_ratio", "4:3")])
    discard r.dkText(m, "h2", title)
    discard r.dkText(m, "p", body, [("margin", "0")],
      tok"color.text.secondary")
  r.dkFooter(result)

proc zigZagInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Summer guide", "A zig-zag between a band and a " &
    "button.")
  let b = r.el(result, "mailBand", [("background-color", "#0b3a6e")],
    [("text_align", "center")])
  discard r.el(b, "h1", [("color", "#ffffff")], text = "Summer guide")
  discard r.el(b, "p", [("color", "#ffffff"), ("margin", "0")],
    text = "Three places, one long weekend each.")
  let s = r.band(result)
  let z = r.el(s, "mailZigZag")
  r.zigRow(z, 0, "The coast", "Sand, sea and a long walk at low tide.")
  r.zigRow(z, 1, "The forest", "Pines, a cabin and a quiet morning.")
  r.zigRow(z, 3, "The lake", "A swim before lunch.")
  let t = r.band(result, "#eef2ff")
  r.setStyle(t, "text-align", "center")
  discard r.el(t, "mailButton", attrs = [("href",
    "https://example.com/summer")], text = "Plan your weekend")
  r.footer(result)

# --- mailGallery --------------------------------------------------------------

proc gallery(r: EmailRenderer; parent: EmailNode; picks: openArray[int];
    attrs: openArray[(string, string)] = [];
    alts: openArray[string] = []): EmailNode =
  result = r.el(parent, "mailGallery", attrs = attrs)
  for k, i in picks:
    discard r.el(result, "mailImage", attrs = [("src", photos[i][1]),
      ("alt", if k < alts.len: alts[k] else: photos[i][0]),
      ("href", "https://example.com/photos/" & $i)])

proc galleryMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("New prints", "Three prints, square.")
  r.intro(result, "New prints", "")
  let s = r.band(result)
  discard r.gallery(s, [0, 1, 2])
  r.footer(result)

proc galleryMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("The whole collection", "Six prints, four to a row, " &
    "two on a phone.")
  r.intro(result, "The whole collection", "Every print cropped to 3:2, " &
    "four to a row, two to a row on a phone, 8px apart.")
  let s = r.band(result)
  discard r.gallery(s, [0, 1, 2, 3, 4, 5], [("ratio", "3:2"),
    ("columns", "4"), ("mobile_columns", "2"), ("gutter", "8px")])
  r.footer(result)

proc galleryRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("مطبوعات جديدة", "ثلاث مطبوعات مربعة.", rtl = true)
  r.intro(result, "مطبوعات جديدة", "")
  let s = r.band(result)
  discard r.gallery(s, [0, 1, 2], alts = ["ساحل", "غابة", "صحراء"])
  r.footer(result, rtl = true)

proc galleryImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("New prints", "A gallery with images blocked.")
  r.intro(result, "New prints", "With images blocked, every tile shows " &
    "its alt text.")
  let s = r.band(result)
  discard r.gallery(s, [3, 4, 5, 0], [("columns", "2"), ("ratio", "4:3")],
    alts = ["Lake", "City", "Field", "Coast"])
  r.footer(result)

proc galleryDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("New prints, dark", "A gallery in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "New prints, dark")
  discard r.gallery(s, [4, 3, 0])
  r.dkFooter(result)

proc galleryInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("New prints", "A gallery between a band and a button.")
  r.intro(result, "New prints", "Three new prints this month.", "#fef3c7")
  let s = r.band(result)
  discard r.gallery(s, [5, 0, 1], [("ratio", "4:3")])
  let t = r.band(result, "#eef2ff")
  r.setStyle(t, "text-align", "center")
  discard r.el(t, "mailButton", attrs = [("href",
    "https://example.com/prints")], text = "Shop the prints")
  r.footer(result)

# --- mailCountdown ------------------------------------------------------------

proc countdown(r: EmailRenderer; parent: EmailNode;
    attrs: openArray[(string, string)] = []): EmailNode =
  var a = @[("src", fixtureImageUrl("countdown.gif")), ("width", "280"),
    ("deadline_text", "Offer ends 30 September 2026, 23:59 UTC")]
  for x in attrs:
    var replaced = false
    for i in 0 ..< a.len:
      if a[i][0] == x[0]:
        a[i] = x
        replaced = true
    if not replaced:
      a.add(x)
  r.el(parent, "mailCountdown", attrs = a)

proc countdownMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Last chance", "The sale ends tonight.")
  r.intro(result, "Last chance", "")
  let s = r.band(result)
  discard r.countdown(s)
  r.footer(result)

proc countdownMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Last chance", "Every countdown prop.")
  r.intro(result, "Last chance", "The countdown below is centred and links " &
    "to the sale.")
  let s = r.band(result)
  discard r.countdown(s, [("width", "560"), ("height", "140"),
    ("align", "center"), ("href", "https://example.com/sale"),
    ("deadline_text", "Sale ends 30 September 2026, 23:59 UTC (01:59 " &
      "in Athens)")])
  r.footer(result)

proc countdownRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("الفرصة الأخيرة", "ينتهي التخفيض الليلة.", rtl = true)
  r.intro(result, "الفرصة الأخيرة", "")
  let s = r.band(result)
  discard r.countdown(s, [("width", "560"), ("height", "140"),
    ("deadline_text", "ينتهي العرض في ٣٠ سبتمبر ٢٠٢٦، ٢٣:٥٩ غرينتش")])
  r.footer(result, rtl = true)

proc countdownImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Last chance", "A countdown with images blocked.")
  r.intro(result, "Last chance", "With images blocked, the countdown " &
    "shows its deadline as text.")
  let s = r.band(result)
  discard r.countdown(s, [("width", "560"), ("height", "140")])
  r.footer(result)

proc countdownDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Last chance, dark", "A countdown in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Last chance, dark")
  discard r.countdown(s, [("width", "560"), ("height", "140")])
  r.dkFooter(result)

proc countdownInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Spring sale", "A countdown between a band and a " &
    "button.")
  let b = r.el(result, "mailBand", [("background-color", "#1b2a4a")],
    [("text_align", "center")])
  discard r.el(b, "h1", [("color", "#ffffff")], text = "Spring sale")
  discard r.countdown(b, [("width", "560"), ("height", "140"),
    ("align", "center"), ("color", "#e5e7eb")])
  let t = r.band(result)
  r.setStyle(t, "text-align", "center")
  discard r.el(t, "mailButton", attrs = [("href",
    "https://example.com/sale")], text = "Shop the sale")
  r.footer(result)

# --- Registration -------------------------------------------------------------

let mediaStories*: seq[KitStory] = @[
  ("mediaObjectMinimal", "mailMediaObject: a thumbnail beside its text.",
    mediaObjectMinimalDoc, false),
  ("mediaObjectMaximal", "mailMediaObject: every prop, the image on the " &
    "right, stacking on a phone.", mediaObjectMaximalDoc, false),
  ("mediaObjectRtl", "mailMediaObject right to left.", mediaObjectRtlDoc,
    false),
  ("mediaObjectImagesOff", "Two media objects (capture with images off).",
    mediaObjectImagesOffDoc, false),
  ("mediaObjectDark", "mailMediaObject in its dark colours.",
    mediaObjectDarkDoc, true),
  ("mediaObjectInContext", "Three order items between a heading and a " &
    "button band.", mediaObjectInContextDoc, false),
  ("zigZagMinimal", "mailZigZag: two rows.", zigZagMinimalDoc, false),
  ("zigZagMaximal", "mailZigZag: four rows, linked, centred, long text.",
    zigZagMaximalDoc, false),
  ("zigZagImagesOff", "mailZigZag (capture with images off).",
    zigZagImagesOffDoc, false),
  ("zigZagDark", "mailZigZag in its dark colours.", zigZagDarkDoc, true),
  ("zigZagInContext", "mailZigZag between a band and a button.",
    zigZagInContextDoc, false),
  ("galleryMinimal", "mailGallery: three square prints.", galleryMinimalDoc,
    false),
  ("galleryMaximal", "mailGallery: six prints at 3:2, four to a row, two " &
    "on a phone.", galleryMaximalDoc, false),
  ("galleryRtl", "mailGallery right to left.", galleryRtlDoc, false),
  ("galleryImagesOff", "mailGallery (capture with images off).",
    galleryImagesOffDoc, false),
  ("galleryDark", "mailGallery in its dark colours.", galleryDarkDoc, true),
  ("galleryInContext", "mailGallery between a band and a button.",
    galleryInContextDoc, false),
  ("countdownMinimal", "mailCountdown with its required props.",
    countdownMinimalDoc, false),
  ("countdownMaximal", "mailCountdown: full width, centred, linked.",
    countdownMaximalDoc, false),
  ("countdownRtl", "mailCountdown right to left.", countdownRtlDoc, false),
  ("countdownImagesOff", "mailCountdown (capture with images off).",
    countdownImagesOffDoc, false),
  ("countdownDark", "mailCountdown in its dark colours.", countdownDarkDoc,
    true),
  ("countdownInContext", "mailCountdown in a sale band above a button.",
    countdownInContextDoc, false),
]

proc mediaGroup(name: string): string =
  for prefix in ["mediaObject", "zigZag", "gallery", "countdown"]:
    if name.startsWith(prefix):
      return prefix
  name

proc renderMediaStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(mediaStories, name, "media")

proc registerMediaStories*() =
  ## Registers the media pattern story sets (env-gated, see above).
  registerKit(mediaStories, mediaGroup)

proc registerMediaStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(mediaStories)
