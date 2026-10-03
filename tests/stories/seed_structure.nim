## Structure pattern stories: the story sets of `mailHeader`,
## `mailViewInBrowser`, `mailBand`, `mailFooter` and `mailNavLinks`
## (layout-patterns.md §5): for each, `Minimal` (required props only),
## `Maximal` (every prop, the longest realistic content, long unbroken
## words), `Rtl` (Arabic, right to left), `ImagesOff` (content with
## images, captured with images blocked), `Dark` (`darkMode = designed`,
## every colour a theme token with its dark pair) and `InContext`
## (between two different neighbours).
##
## The logos are `tests/stories/assets/mark-outlined.png` (240×80, a dark
## mark with a white outline) and `mark-dark.png` (the same mark, light,
## for dark backgrounds), on the capture fixture host.
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images
import story_kit

const
  logoLight = "mark-outlined.png"
  logoDark = "mark-dark.png"

proc links(r: EmailRenderer; parent: EmailNode; labels: openArray[string]) =
  for l in labels:
    discard r.link(parent, "https://example.com/" &
      l.toLowerAscii().replace(" ", "-"), l)

proc header(r: EmailRenderer; parent: EmailNode;
    labels: openArray[string] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  var a = @[("logo", fixtureImageUrl(logoLight)), ("logo_width", "120"),
    ("logo_alt", "Acme")]
  for x in attrs:
    a.add(x)
  result = r.el(parent, "mailHeader", attrs = a)
  r.links(result, labels)

proc intro(r: EmailRenderer; doc: EmailNode; title, body: string) =
  let s = r.band(doc)
  discard r.el(s, "h1", text = title)
  if body.len > 0:
    discard r.el(s, "p", [("margin", "0")], text = body)

# --- mailHeader ---------------------------------------------------------------

proc headerMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your receipt", "A header with its logo alone.")
  let s = r.band(result, padding = "24px 0 8px")
  discard r.header(s)
  r.intro(result, "Your receipt", "Thank you for your order.")
  r.footer(result)

proc headerMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Everything in the header", "A linked logo with a " &
    "dark version, centred above five links.")
  let s = r.band(result, padding = "24px 0 8px")
  discard r.header(s, ["Documentation", "Pricing", "Changelog",
    "Community", longWord], [("href", "https://example.com/"),
    ("logo_dark", fixtureImageUrl(logoDark)), ("align", "center")])
  r.intro(result, "Everything in the header", "Five links do not fit " &
    "beside the logo, so they sit centred under it and wrap on a phone; " &
    "the last one is a single long word.")
  r.footer(result)

proc headerRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("إيصالك", "شعار ورابطان من اليمين إلى اليسار.",
    rtl = true)
  let s = r.band(result, padding = "24px 0 8px")
  let h = r.el(s, "mailHeader", attrs = [("logo", fixtureImageUrl(
    logoLight)), ("logo_width", "120"), ("logo_alt", "أكمي"),
    ("href", "https://example.com/")])
  discard r.link(h, "https://example.com/help", "المساعدة")
  discard r.link(h, "https://example.com/account", "حسابي")
  r.intro(result, "إيصالك", "شكرا لطلبك. الشعار في البداية والروابط في " &
    "النهاية.")
  r.footer(result, rtl = true)

proc headerImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Images off", "A header whose logo is blocked.")
  let s = r.band(result, padding = "24px 0 8px")
  discard r.header(s, ["Docs", "Pricing", "Sign in"],
    [("href", "https://example.com/")])
  r.intro(result, "Images off", "With images blocked, the logo shows " &
    "its alt text, the brand's name, beside the three links.")
  r.footer(result)

proc headerDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Acme, dark", "A header in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card", "24px 0 8px")
  let h = r.el(s, "mailHeader", attrs = [("logo", fixtureImageUrl(
    logoLight)), ("logo_width", "120"), ("logo_alt", "Acme"),
    ("logo_dark", fixtureImageUrl(logoDark)),
    ("href", "https://example.com/")])
  for l in ["Docs", "Pricing"]:
    let a = r.link(h, "https://example.com/" & l.toLowerAscii(), l)
    r.paint(a, "color", tok"color.link")
  discard r.dkText(s, "p", "In a dark scheme the logo swaps to its light " &
    "version and the links take the link colour's dark pair.",
    [("margin", "16px 0 0")])
  let body = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(body, "h1", "Acme, dark")
  r.dkFooter(result)

proc headerInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order has shipped", "A header between the " &
    "page and a coloured band.")
  let s = r.band(result, padding = "16px 0")
  discard r.header(s, ["Track", "Orders", "Help"],
    [("href", "https://example.com/")])
  let b = r.el(result, "mailBand", [("background-color", "#eef2ff")],
    [("padding", "24px 0")])
  discard r.el(b, "h1", text = "Your order has shipped")
  discard r.el(b, "p", [("margin", "0")], text = "It arrives on Thursday.")
  let c = r.band(result)
  discard r.el(c, "p", [("margin", "0")], text = "The header sits on " &
    "white above the tinted band, with nothing between them.")
  r.footer(result)

# --- mailViewInBrowser --------------------------------------------------------

proc viewInBrowserMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("The weekly digest", "Five stories this week.")
  discard r.el(result, "mailViewInBrowser", attrs = [("href",
    "https://example.com/view/2026-41")])
  r.intro(result, "The weekly digest", "Five stories this week.")
  r.footer(result)

proc viewInBrowserMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("The weekly digest", "Five stories this week.")
  discard r.el(result, "mailViewInBrowser", attrs = [("href",
    "https://example.com/view/2026-41"), ("label", "Trouble reading " &
    "this message? Open it in your browser: " & longWord),
    ("align", "center")])
  r.intro(result, "The weekly digest", "The link above is centred, wraps " &
    "on a phone, and ends in one long word.")
  r.footer(result)

proc viewInBrowserRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("النشرة الأسبوعية", "خمس قصص هذا الأسبوع.", rtl = true)
  discard r.el(result, "mailViewInBrowser", attrs = [("href",
    "https://example.com/view/2026-41"), ("label", "اعرضها في المتصفح")])
  r.intro(result, "النشرة الأسبوعية", "الرابط أعلاه في الطرف الأيسر.")
  r.footer(result, rtl = true)

proc viewInBrowserImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("The weekly digest", "Images are blocked.")
  discard r.el(result, "mailViewInBrowser", attrs = [("href",
    "https://example.com/view/2026-41")])
  let s = r.band(result, padding = "16px 0 8px")
  discard r.header(s, ["Archive"], [("href", "https://example.com/")])
  r.intro(result, "The weekly digest", "With images blocked, the link " &
    "above still reads, above the logo's alt text.")
  r.footer(result)

proc viewInBrowserDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("The weekly digest, dark", "The link in its dark " &
    "colours.")
  discard r.el(result, "mailViewInBrowser", attrs = [("href",
    "https://example.com/view/2026-41")])
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "The weekly digest, dark")
  discard r.dkText(s, "p", "The small grey link above takes its dark " &
    "pair in a dark scheme.")
  r.dkFooter(result)

proc viewInBrowserInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Spring launch", "Everything new this season.")
  discard r.el(result, "mailViewInBrowser", attrs = [("href",
    "https://example.com/view/spring")])
  let b = r.el(result, "mailBand", [("background-color", "#0b3a6e")],
    [("text_align", "center")])
  discard r.el(b, "h1", [("color", "#ffffff")], text = "Spring launch")
  discard r.el(b, "p", [("color", "#ffffff"), ("margin", "0")],
    text = "Everything new this season, in one place.")
  let s = r.band(result)
  discard r.el(s, "p", text = "Inside a band, the same link is a plain " &
    "row of its own:")
  discard r.el(s, "mailViewInBrowser", attrs = [("href",
    "https://example.com/view/spring"), ("label", "Read it online"),
    ("align", "left")])
  r.footer(result)

# --- mailBand -----------------------------------------------------------------

proc bandMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A band", "One coloured band.")
  r.intro(result, "A band", "Below, a band of colour from edge to edge.")
  let b = r.el(result, "mailBand", [("background-color", "#fef3c7")])
  discard r.el(b, "p", [("margin", "0")], text = "Free shipping on every " &
    "order this week.")
  r.footer(result)

proc bandMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Spring launch", "A deep band with everything in it.")
  let b = r.el(result, "mailBand", [("background-color", "#0b3a6e"),
    ("padding", "40px 0")], [("text_align", "center")])
  discard r.el(b, "h1", [("color", "#ffffff")], text = "Spring launch: " &
    "everything new this season")
  discard r.el(b, "p", [("color", "#ffffff")], text = "The band runs from " &
    "edge to edge of the reading pane while its content stays in the " &
    "message's column, 40px from its top and bottom: " & longWord & ".")
  discard r.el(b, "mailButton", [("background-color", "#ffffff"),
    ("color", "#0b3a6e")], [("href", "https://example.com/spring"),
    ("align", "center")], text = "See what is new")
  r.footer(result)

proc bandRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("شريط ملون", "شريط من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "شريط ملون", "في الأسفل شريط يمتد من حافة إلى حافة.")
  let b = r.el(result, "mailBand", [("background-color", "#fef3c7")])
  discard r.el(b, "p", [("margin", "0")], text = "شحن مجاني على كل " &
    "الطلبات هذا الأسبوع.")
  r.footer(result, rtl = true)

proc bandImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("New this week", "A band holding an image.")
  r.intro(result, "New this week", "The band below holds an image and its " &
    "caption.")
  let b = r.el(result, "mailBand", [("background-color", "#e0f2fe")],
    [("text_align", "center")])
  discard r.el(b, "mailImage", [("width", "280px"),
    ("height", fixtureImageHeight("scene.png", 280))],
    [("src", fixtureImageUrl("scene.png")), ("alt", "A green valley at dawn")])
  discard r.el(b, "p", [("margin", "12px 0 0")], text = "Our new office, " &
    "seen from the hill.")
  r.footer(result)

proc bandDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("A band, dark", "A band in its dark colours.")
  let top = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(top, "h1", "A band, dark", [("margin", "0")])
  let b = r.el(result, "mailBand")
  r.paint(b, "background-color", tok"color.status.info.bg")
  discard r.dkText(b, "p", "A tinted band from edge to edge, its tint " &
    "and text paired for the dark scheme.", [("margin", "0")])
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "p", "Below the band, the card surface.")
  r.dkFooter(result)

proc bandInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Three bands", "A light, a brand and a dark band, " &
    "one after another.")
  r.intro(result, "Three bands", "Adjacent bands differ enough to read " &
    "as three in light and in dark mode.")
  let a = r.el(result, "mailBand", [("background-color", "#fcd34d")])
  discard r.el(a, "p", [("margin", "0")], text = "An amber band.")
  let b = r.el(result, "mailBand", [("background-color", "#0b3a6e")])
  discard r.el(b, "p", [("margin", "0"), ("color", "#ffffff")],
    text = "A deep blue band.")
  let c = r.el(result, "mailBand", [("background-color", "#ffffff")])
  discard r.el(c, "p", [("margin", "0")], text = "A white band.")
  r.footer(result)

# --- mailFooter ---------------------------------------------------------------

proc footerBand(r: EmailRenderer; doc: EmailNode; bg = "#f4f5f7"): EmailNode =
  r.el(doc, "mailBand", [("background-color", bg), ("padding", "32px 0")])

proc footerMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your receipt", "A footer with its required parts.")
  r.intro(result, "Your receipt", "Thank you for your order.")
  let f = r.footerBand(result)
  discard r.el(f, "mailFooter", attrs = [("address",
    "Acme Inc., 1 Example Street, Springfield"),
    ("unsubscribe", "https://example.com/unsubscribe?t=7f3a9c2e5b1d4a60")])

proc footerMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("The weekly digest", "A footer with every part.")
  r.intro(result, "The weekly digest", "Every part of the footer below, " &
    "its address on three lines and its legal text long.")
  let f = r.footerBand(result)
  let foot = r.el(f, "mailFooter", attrs = [("address",
    "Acme Incorporated\n1 Example Street, Suite 400\nSpringfield, " &
    "IL 62701, United States"),
    ("unsubscribe", "https://example.com/unsubscribe?t=7f3a9c2e5b1d4a60"),
    ("unsubscribe_label", "Unsubscribe from the weekly digest"),
    ("preferences", "https://example.com/preferences"),
    ("preferences_label", "Email preferences"),
    ("reason", "You are receiving this because you subscribed to the " &
      "weekly digest at example.com."),
    ("legal", "Acme and the Acme logo are trademarks of Acme " &
      "Incorporated. Prices exclude tax. Reference " & longWord & "."),
    ("align", "center")])
  let social = r.el(foot, "mailSocial")
  for n in ["x", "linkedin", "github", "youtube"]:
    discard r.el(social, "mailSocialItem", attrs = [("network", n),
      ("href", "https://" & n & ".example/acme")])

proc footerRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("إيصالك", "تذييل من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "إيصالك", "شكرا لطلبك.")
  let f = r.footerBand(result)
  discard r.el(f, "mailFooter", attrs = [("address",
    "شركة أكمي، ١ شارع المثال، الرياض"),
    ("unsubscribe", "https://example.com/unsubscribe?t=7f3a9c2e5b1d4a60"),
    ("unsubscribe_label", "إلغاء الاشتراك"),
    ("preferences", "https://example.com/preferences"),
    ("preferences_label", "التفضيلات"),
    ("reason", "تصلك هذه الرسالة لأنك مشترك في نشرتنا.")])

proc footerImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("The weekly digest", "A footer whose social icons " &
    "are blocked.")
  r.intro(result, "The weekly digest", "With images blocked, the social " &
    "icons in the footer show their networks' names.")
  let f = r.footerBand(result)
  let foot = r.el(f, "mailFooter", attrs = [("address",
    "Acme Inc., 1 Example Street, Springfield"),
    ("unsubscribe", "https://example.com/unsubscribe?t=7f3a9c2e5b1d4a60"),
    ("preferences", "https://example.com/preferences")])
  let social = r.el(foot, "mailSocial")
  for n in ["x", "github", "email"]:
    discard r.el(social, "mailSocialItem", attrs = [("network", n),
      ("href", if n == "email": "mailto:hello@example.com"
        else: "https://" & n & ".example/acme")])

proc footerDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("The weekly digest, dark", "A footer in its dark " &
    "colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "The weekly digest, dark")
  discard r.dkText(s, "p", "The footer below takes its dark pairs: the " &
    "grey text, the links, the social plates.")
  let f = r.el(result, "mailBand", attrs = [("padding", "32px 0")])
  r.paint(f, "background-color", tok"color.surface.subtle")
  let foot = r.el(f, "mailFooter", attrs = [("address",
    "Acme Inc., 1 Example Street, Springfield"),
    ("unsubscribe", "https://example.com/unsubscribe?t=7f3a9c2e5b1d4a60"),
    ("preferences", "https://example.com/preferences"),
    ("legal", "Acme is a trademark of Acme Inc.")])
  let social = r.el(foot, "mailSocial")
  for n in ["x", "github"]:
    discard r.el(social, "mailSocialItem", attrs = [("network", n),
      ("href", "https://" & n & ".example/acme")])

proc footerInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order has shipped", "A footer under the " &
    "message's last band.")
  r.intro(result, "Your order has shipped", "It arrives on Thursday.")
  let s = r.band(result, "#eef2ff")
  discard r.el(s, "mailButton", attrs = [("href",
    "https://example.com/track")], text = "Track your parcel")
  let f = r.el(result, "mailBand", [("background-color", "#1f2937"),
    ("padding", "32px 0")])
  let foot = r.el(f, "mailFooter", attrs = [("address",
    "Acme Inc., 1 Example Street, Springfield"),
    ("unsubscribe", "https://example.com/unsubscribe?t=7f3a9c2e5b1d4a60"),
    ("legal", "Acme is a trademark of Acme Inc."),
    # On the dark band the footer's text reads light.
    ("color", "#d1d5db")])
  let social = r.el(foot, "mailSocial", attrs = [("mode", "dark")])
  for n in ["x", "github"]:
    discard r.el(social, "mailSocialItem", attrs = [("network", n),
      ("href", "https://" & n & ".example/acme")])

# --- mailNavLinks -------------------------------------------------------------

proc navLinksMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome", "Three navigation links.")
  let s = r.band(result, padding = "16px 0")
  let n = r.el(s, "mailNavLinks")
  r.links(n, ["Home", "Docs", "Support"])
  r.intro(result, "Welcome", "The navigation above is three links in a " &
    "centred row.")
  r.footer(result)

proc navLinksMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome", "Five links, start-aligned, separated.")
  let s = r.band(result, padding = "16px 0")
  let n = r.el(s, "mailNavLinks", attrs = [("gap", "16px"),
    ("align", "left"), ("separator", "·"), ("label", "Main navigation")])
  r.links(n, ["Home", "Documentation", "Pricing and plans",
    "Community forum", longWord])
  r.intro(result, "Welcome", "Five links, the most a navigation holds, " &
    "start-aligned and separated by dots; on a phone the row wraps.")
  r.footer(result)

proc navLinksRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("مرحبا", "روابط التنقل من اليمين إلى اليسار.",
    rtl = true)
  let s = r.band(result, padding = "16px 0")
  let n = r.el(s, "mailNavLinks", attrs = [("align", "right"),
    ("label", "التنقل")])
  for (slug, label) in [("home", "الرئيسية"), ("docs", "المستندات"),
      ("support", "الدعم")]:
    discard r.link(n, "https://example.com/" & slug, label)
  r.intro(result, "مرحبا", "ثلاثة روابط في صف من اليمين.")
  r.footer(result, rtl = true)

proc navLinksImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome", "Navigation under a blocked logo.")
  let s = r.band(result, padding = "16px 0", bg = "#ffffff")
  r.setStyle(s, "text-align", "center")
  discard r.el(s, "mailImage", [("width", "120px"),
    ("height", fixtureImageHeight(logoLight, 120))],
    [("src", fixtureImageUrl(logoLight)), ("alt", "Acme")])
  let n = r.el(s, "mailNavLinks")
  r.links(n, ["Home", "Docs", "Pricing", "Sign in"])
  r.intro(result, "Welcome", "With images blocked, the logo's alt text " &
    "sits above the navigation.")
  r.footer(result)

proc navLinksDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Welcome, dark", "Navigation in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card", "8px 0 16px")
  let n = r.el(s, "mailNavLinks", attrs = [("separator", "·")])
  r.links(n, ["Home", "Docs", "Pricing"])
  let body = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(body, "h1", "Welcome, dark")
  discard r.dkText(body, "p", "The links above take the link colour's " &
    "dark pair.")
  r.dkFooter(result)

proc navLinksInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome to Acme", "A header band with a logo and " &
    "navigation above a hero.")
  let head = r.band(result, "#eef2ff", "24px 0 8px")
  r.setStyle(head, "text-align", "center")
  discard r.el(head, "mailImage", [("width", "120px"),
    ("height", fixtureImageHeight(logoLight, 120))],
    [("src", fixtureImageUrl(logoLight)), ("alt", "Acme")])
  let n = r.el(head, "mailNavLinks")
  r.links(n, ["Home", "Docs", "Pricing", "Sign in"])
  let hero = r.el(result, "mailHero", [("background-color", "#0b3a6e"),
    ("padding", "40px 0")], [("vertical_align", "middle")])
  discard r.el(hero, "h1", [("color", "#ffffff")], text = "Welcome to Acme")
  discard r.el(hero, "p", [("color", "#ffffff"), ("margin", "0")],
    text = "Your workspace is ready.")
  r.footer(result)

# --- Registration -------------------------------------------------------------

let structureStories*: seq[KitStory] = @[
  ("headerMinimal", "mailHeader: the logo alone.", headerMinimalDoc, false),
  ("headerMaximal", "mailHeader: a linked logo with a dark version, " &
    "centred above five links.", headerMaximalDoc, false),
  ("headerRtl", "mailHeader right to left.", headerRtlDoc, false),
  ("headerImagesOff", "mailHeader with three links (capture with images " &
    "off).", headerImagesOffDoc, false),
  ("headerDark", "mailHeader in its dark colours, the logo swapped.",
    headerDarkDoc, true),
  ("headerInContext", "mailHeader above a tinted band.", headerInContextDoc,
    false),
  ("viewInBrowserMinimal", "mailViewInBrowser with its defaults.",
    viewInBrowserMinimalDoc, false),
  ("viewInBrowserMaximal", "mailViewInBrowser: a long label, centred.",
    viewInBrowserMaximalDoc, false),
  ("viewInBrowserRtl", "mailViewInBrowser right to left.",
    viewInBrowserRtlDoc, false),
  ("viewInBrowserImagesOff", "mailViewInBrowser above a header (capture " &
    "with images off).", viewInBrowserImagesOffDoc, false),
  ("viewInBrowserDark", "mailViewInBrowser in its dark colours.",
    viewInBrowserDarkDoc, true),
  ("viewInBrowserInContext", "mailViewInBrowser above a brand band, and " &
    "inside a band.", viewInBrowserInContextDoc, false),
  ("bandMinimal", "mailBand with its colour only.", bandMinimalDoc, false),
  ("bandMaximal", "mailBand: deep, padded, centred, a heading and a " &
    "button.", bandMaximalDoc, false),
  ("bandRtl", "mailBand right to left.", bandRtlDoc, false),
  ("bandImagesOff", "mailBand holding an image (capture with images off).",
    bandImagesOffDoc, false),
  ("bandDark", "mailBand in its dark colours.", bandDarkDoc, true),
  ("bandInContext", "Three adjacent bands.", bandInContextDoc, false),
  ("footerMinimal", "mailFooter: its address and unsubscribe link.",
    footerMinimalDoc, false),
  ("footerMaximal", "mailFooter with every part and a social row.",
    footerMaximalDoc, false),
  ("footerRtl", "mailFooter right to left.", footerRtlDoc, false),
  ("footerImagesOff", "mailFooter with social icons (capture with images " &
    "off).", footerImagesOffDoc, false),
  ("footerDark", "mailFooter in its dark colours.", footerDarkDoc, true),
  ("footerInContext", "mailFooter on a dark band under the message.",
    footerInContextDoc, false),
  ("navLinksMinimal", "mailNavLinks: three links.", navLinksMinimalDoc,
    false),
  ("navLinksMaximal", "mailNavLinks: five links, separated, start-aligned.",
    navLinksMaximalDoc, false),
  ("navLinksRtl", "mailNavLinks right to left.", navLinksRtlDoc, false),
  ("navLinksImagesOff", "mailNavLinks under a logo (capture with images " &
    "off).", navLinksImagesOffDoc, false),
  ("navLinksDark", "mailNavLinks in its dark colours.", navLinksDarkDoc,
    true),
  ("navLinksInContext", "mailNavLinks in a header band above a hero.",
    navLinksInContextDoc, false),
]

proc structureGroup(name: string): string =
  for prefix in ["header", "viewInBrowser", "band", "footer", "navLinks"]:
    if name.startsWith(prefix):
      return prefix
  name

proc renderStructureStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(structureStories, name, "structure")

proc registerStructureStories*() =
  ## Registers the structure pattern story sets (env-gated, see above).
  registerKit(structureStories, structureGroup)

proc registerStructureStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(structureStories)
