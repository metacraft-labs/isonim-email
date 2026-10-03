## Raw-markup and client-targeting stories: the story sets of `mailRaw`
## and `mailIf`: `rawMinimal` (a raw paragraph), `rawMaximal` (a raw
## two-cell table, a Word-only table and an everyone-but-Word block,
## entities, a long unbroken word), `rawRtl`, `rawImagesOff` (a raw image
## captured with images blocked), `rawDark` (raw colours in a
## dark-designed message) and `rawInContext` (between generated
## elements); `ifMinimal` (one paragraph for Word, one for everyone
## else), `ifMaximal` (whole bands for Word or not, nested ghost tables
## and dividers flattened, a Thunderbird-only block and an inline
## Thunderbird-only phrase, a block for both), `ifRtl`, `ifImagesOff`,
## `ifDark` and `ifInContext`.
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images
import story_kit

proc rawBlock(r: EmailRenderer; parent: EmailNode; html: string): EmailNode =
  result = r.el(parent, "mailRaw")
  r.appendChild(result, raw(html))

proc mailIf(r: EmailRenderer; parent: EmailNode;
    attrs: openArray[(string, string)]): EmailNode =
  r.el(parent, "mailIf", attrs = attrs)

# --- mailRaw --------------------------------------------------------------------

proc rawMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A raw paragraph", "Markup the vocabulary does not " &
    "write.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "A raw paragraph")
  discard r.rawBlock(s, "<p style=\"margin:0;font-family:Georgia, serif;" &
    "font-size:18px;line-height:28px;color:#374151;\">Written by hand, " &
    "<em>kept as written</em>.</p>")
  r.footer(result)

proc rawMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Raw markup", "A raw table, a Word-only box and a " &
    "block for every other client.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Raw markup")
  discard r.el(s, "p", text = "A two-cell table written by hand:")
  discard r.rawBlock(s, "<table role=\"presentation\" width=\"100%\" " &
    "border=\"0\" cellpadding=\"0\" cellspacing=\"0\"><tr>" &
    "<td width=\"50%\" valign=\"top\" style=\"padding:12px;" &
    "background-color:#eef2ff;font-family:Helvetica, Arial, sans-serif;" &
    "font-size:16px;line-height:24px;color:#1e1b4b;\">Left &amp; " &
    "first</td><td width=\"50%\" valign=\"top\" style=\"padding:12px;" &
    "background-color:#fef3c7;font-family:Helvetica, Arial, sans-serif;" &
    "font-size:16px;line-height:24px;color:#451a03;word-break:break-word;" &
    "\">" & longWord & "</td></tr></table>")
  discard r.el(s, "p", [("margin", "16px 0")], text = "Word shows a " &
    "yellow table here; every other client shows a blue paragraph:")
  discard r.rawBlock(s, "<!--[if mso]><table role=\"presentation\" " &
    "width=\"100%\" border=\"0\" cellpadding=\"0\" cellspacing=\"0\">" &
    "<tr><td bgcolor=\"#fef3c7\" style=\"padding:8px 12px;" &
    "background-color:#fef3c7;color:#451a03;font-family:Arial, " &
    "sans-serif;font-size:16px;line-height:24px;mso-line-height-rule:" &
    "exactly;\">Word's table</td></tr></table><![endif]-->" &
    "<!--[if !mso]><!--><p style=\"margin:0;padding:8px " &
    "12px;background-color:#1f6feb;color:#ffffff;font-family:Helvetica, " &
    "Arial, sans-serif;font-size:16px;line-height:24px;\">Everyone " &
    "else's paragraph</p><!--<![endif]-->")
  r.footer(result)

proc rawRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("فقرة مكتوبة يدويًا", "ترميز لا تكتبه المفردات.",
    rtl = true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "فقرة مكتوبة يدويًا")
  discard r.rawBlock(s, "<p dir=\"rtl\" style=\"margin:0;font-family:" &
    "Helvetica, Arial, sans-serif;font-size:16px;line-height:24px;" &
    "color:#374151;text-align:right;\">كُتبت يدويًا و<strong>بقيت كما " &
    "هي</strong>.</p>")
  r.footer(result, rtl = true)

proc rawImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A raw image", "An image written by hand, images " &
    "off.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "A raw image")
  discard r.rawBlock(s, "<img src=\"" & fixtureImageUrl("scene.png") &
    "\" width=\"280\" height=\"160\" alt=\"A green hill at dawn\" " &
    "style=\"display:block;border:0;width:280px;height:auto;" &
    "font-family:Helvetica, Arial, sans-serif;font-size:14px;" &
    "line-height:20px;color:#4b5563;\">")
  discard r.el(s, "p", [("margin", "16px 0 0")], text = "The picture " &
    "above is raw markup; with images off it shows its alt text.")
  r.footer(result)

proc rawDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Raw, dark", "Raw markup in a dark-designed message.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Raw, dark")
  discard r.dkText(s, "p", "The raw block below keeps the colours it " &
    "was written with:", [("margin", "0 0 16px")])
  discard r.rawBlock(s, "<p style=\"margin:0;padding:12px;" &
    "background-color:#1f6feb;color:#ffffff;font-family:Helvetica, " &
    "Arial, sans-serif;font-size:16px;line-height:24px;\">White on " &
    "blue, in every scheme.</p>")
  r.dkFooter(result)

proc rawInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Raw between", "A raw block between generated " &
    "elements.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Raw between")
  discard r.el(s, "p", text = "A generated paragraph above.")
  discard r.rawBlock(s, "<div style=\"padding:12px;border:1px solid " &
    "#d1d5db;font-family:Helvetica, Arial, sans-serif;font-size:16px;" &
    "line-height:24px;color:#111827;\">A bordered block, written by hand." &
    "</div>")
  discard r.el(s, "mailSpacer", [("height", "16px")])
  discard r.el(s, "mailButton", attrs = [("href",
    "https://app.example.com/")], text = "A generated button below")
  r.footer(result)

# --- mailIf ---------------------------------------------------------------------

proc ifMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Which client?", "One line for Outlook, one for " &
    "everyone else.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Which client?")
  discard r.el(r.mailIf(s, [("mso", "true")]), "p", text = "You are " &
    "reading this in classic Outlook.")
  discard r.el(r.mailIf(s, [("mso", "false")]), "p", text = "You are " &
    "reading this outside classic Outlook.")
  r.footer(result)

proc ifMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Targeted content", "Bands for Outlook or not, and " &
    "Thunderbird-only content.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Targeted content")
  discard r.el(s, "p", text = "Below: a band for classic Outlook only, a " &
    "band for every other client, then Thunderbird-only content.")
  # Whole bands: their ghost tables and dividers are flattened.
  let word = r.mailIf(result, [("mso", "true")])
  let wb = r.band(word, "#fef3c7")
  discard r.el(wb, "p", text = "Classic Outlook band.")
  discard r.el(wb, "mailDivider")
  discard r.el(wb, "p", text = "Below Word's divider.")
  let others = r.mailIf(result, [("mso", "false")])
  let ob = r.band(others, "#ecfdf5")
  let box = r.el(ob, "mailBox", [("background-color", "#ffffff"),
    ("border", "1px solid #a7f3d0"), ("border-radius", "8px")])
  discard r.el(box, "p", text = "Every client but classic Outlook: a " &
    "rounded box in a band.")
  discard r.el(ob, "mailDivider")
  discard r.el(ob, "p", text = "Below the divider.")
  let s2 = r.band(result)
  discard r.el(r.mailIf(s2, [("family", "thunderbird")]), "p",
    text = "A paragraph only Thunderbird shows.")
  let p = r.el(s2, "p", text = "This sentence ends ")
  discard r.el(r.mailIf(p, [("family", "thunderbird")]), "strong",
    text = "with words only Thunderbird shows, and ")
  r.txt(p, "the same way everywhere.")
  discard r.el(r.mailIf(s2, [("family", "outlookWord, thunderbird")]), "p",
    text = "A paragraph for classic Outlook and Thunderbird.")
  r.footer(result)

proc ifRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("أي برنامج؟", "سطر لأوتلوك وسطر للبقية.", rtl = true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "أي برنامج؟")
  discard r.el(r.mailIf(s, [("mso", "true")]), "p", text = "أنت تقرأ هذا " &
    "في أوتلوك الكلاسيكي.")
  discard r.el(r.mailIf(s, [("mso", "false")]), "p", text = "أنت تقرأ " &
    "هذا خارج أوتلوك الكلاسيكي.")
  r.footer(result, rtl = true)

proc ifImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Pictures by client", "A picture for Outlook, " &
    "another for the rest, images off.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Pictures by client")
  discard r.el(r.mailIf(s, [("mso", "true")]), "mailImage",
    [("width", "120px"), ("height", fixtureImageHeight("logo.png", 120))],
    [("src", fixtureImageUrl("logo.png")), ("alt", "Acme, for Outlook")])
  discard r.el(r.mailIf(s, [("mso", "false")]), "mailImage",
    [("width", "280px"), ("height", fixtureImageHeight("scene.png", 280))],
    [("src", fixtureImageUrl("scene.png")),
      ("alt", "A green hill at dawn")])
  discard r.el(s, "p", [("margin", "16px 0 0")], text = "One picture " &
    "shows in each client.")
  r.footer(result)

proc ifDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Which client, dark", "Targeted content in dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Which client, dark")
  discard r.dkText(r.mailIf(s, [("mso", "true")]), "p", "You are reading " &
    "this in classic Outlook.")
  discard r.dkText(r.mailIf(s, [("mso", "false")]), "p", "You are " &
    "reading this outside classic Outlook.")
  discard r.dkText(r.mailIf(s, [("family", "thunderbird")]), "p",
    "And this in Thunderbird.")
  r.dkFooter(result)

proc ifInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your download", "A tip for Outlook users between " &
    "the steps.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Your download")
  discard r.el(s, "p", text = "Your file is ready.")
  let forWord = r.mailIf(s, [("mso", "true")])
  let tip = r.el(forWord, "mailBox",
    [("background-color", "#fef3c7"), ("padding", "12px")])
  discard r.el(tip, "p", text = "Outlook tip: right-click the button and " &
    "copy the link if it does not open.")
  discard r.el(forWord, "mailSpacer", [("height", "16px")])
  discard r.el(s, "mailButton", attrs = [("href",
    "https://app.example.com/download")], text = "Download")
  r.footer(result)

# --- Registration -----------------------------------------------------------

let rawStories*: array[12, KitStory] = [
  ("rawMinimal", "mailRaw: a raw paragraph.", rawMinimalDoc, false),
  ("rawMaximal", "A raw table, a Word-only table, a block for the rest.",
    rawMaximalDoc, false),
  ("rawRtl", "A raw paragraph right to left.", rawRtlDoc, false),
  ("rawImagesOff", "A raw image (capture with images off).",
    rawImagesOffDoc, false),
  ("rawDark", "Raw colours in a dark-designed message.", rawDarkDoc, true),
  ("rawInContext", "A raw block between generated elements.",
    rawInContextDoc, false),
  ("ifMinimal", "mailIf: one line for Outlook, one for the rest.",
    ifMinimalDoc, false),
  ("ifMaximal", "Bands for Outlook or not, Thunderbird-only content.",
    ifMaximalDoc, false),
  ("ifRtl", "mailIf right to left.", ifRtlDoc, false),
  ("ifImagesOff", "A picture per client (capture with images off).",
    ifImagesOffDoc, false),
  ("ifDark", "Targeted content in dark colours.", ifDarkDoc, true),
  ("ifInContext", "An Outlook tip between the steps.", ifInContextDoc,
    false),
]

proc rawGroup(name: string): string =
  if name.startsWith("raw"): "raw" else: "if"

proc renderRawStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(rawStories, name, "raw")

proc registerRawStories*() =
  ## Registers the raw-markup and targeting story sets (env-gated).
  registerKit(rawStories, rawGroup)

proc registerRawStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(rawStories)
