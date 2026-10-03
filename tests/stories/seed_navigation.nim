## Navigation stories: the story sets of `mailSocial` and `mailNavbar`:
## `socialMinimal` (three icons, the defaults), `socialMaximal` (every
## built-in network, 32px icons, start-aligned, an application's own
## icon), `socialRtl` (right to left), `socialImagesOff` (captured with
## images blocked: the alt texts), `socialDark` (`darkMode = designed`,
## the dark plates on a dark band) and `socialInContext` (a footer with
## a light and a dark row); `navbarMinimal` (three links), `navbarMaximal`
## (eight links with a separator, one long, that wrap on a phone),
## `navbarRtl`, `navbarImagesOff` (under a logo, images blocked),
## `navbarDark` and `navbarInContext` (a header band with a logo, the
## navbar and a heading below).
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images
import story_kit

proc social(r: EmailRenderer; parent: EmailNode; networks: openArray[string];
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []): EmailNode =
  result = r.el(parent, "mailSocial", styles, attrs)
  for n in networks:
    discard r.el(result, "mailSocialItem", attrs = [("network", n),
      ("href", "https://" & n & ".example/acme")])

proc navbar(r: EmailRenderer; parent: EmailNode; links: openArray[string];
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []): EmailNode =
  result = r.el(parent, "mailNavbar", styles, attrs)
  for l in links:
    discard r.el(result, "mailNavLink", attrs = [("href",
      "https://example.com/" & l.toLowerAscii().replace(" ", "-"))], text = l)

# --- mailSocial -----------------------------------------------------------------

proc socialMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Follow us", "Three social links.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Follow us")
  discard r.el(s, "p", text = "News and releases, where you read them.")
  discard r.social(s, ["x", "linkedin", "github"])
  r.footer(result)

proc socialMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Everywhere we are", "Every built-in network, 32px, " &
    "start-aligned, and an icon of our own.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Everywhere we are")
  discard r.el(s, "p", text = "Ten built-in networks and our own feed " &
    "icon, 32px each, 16px apart, from the start of the line; on a " &
    "phone the row wraps.")
  let row = r.social(s, ["facebook", "x", "linkedin", "instagram",
    "youtube", "github", "mastodon", "bluesky", "email", "website"],
    [("align", "left"), ("icon_size", "32")], [("gap", "16px")])
  discard r.el(row, "mailSocialItem", attrs = [("network", "Acme feed"),
    ("href", "https://example.com/feed"),
    ("icon", fixtureImageUrl("shield.png"))])
  r.footer(result)

proc socialRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("تابعنا", "روابط التواصل الاجتماعي.", rtl = true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "تابعنا")
  discard r.el(s, "p", text = "الأخبار والإصدارات حيث تقرؤها.")
  discard r.social(s, ["x", "youtube", "instagram", "email"],
    [("align", "right")])
  r.footer(result, rtl = true)

proc socialImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Stay in touch", "Social links with images off.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Stay in touch")
  discard r.el(s, "p", text = "With images blocked, each icon shows its " &
    "network's name.")
  discard r.social(s, ["facebook", "x", "linkedin", "youtube"])
  r.footer(result)

proc socialDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Follow us, dark", "Social links in their dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Follow us, dark")
  discard r.dkText(s, "p", "The default plates:")
  discard r.social(s, ["x", "github", "mastodon"])
  # The light plates belong on a band that is dark in every scheme.
  let band = r.el(result, "mailSection", [("background-color", "#111827"),
    ("padding", "24px 0")])
  discard r.el(band, "p", [("color", "#f9fafb")],
    text = "The light plates, on a dark band:")
  discard r.social(band, ["x", "github", "mastodon"], [("mode", "dark")])
  r.dkFooter(result)

proc socialInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Release 2.4", "A footer with social links on a " &
    "light and a dark band.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Release 2.4")
  discard r.el(s, "p", text = "Faster builds and a new dashboard.")
  discard r.el(s, "mailButton", attrs = [("href",
    "https://app.example.com/changelog")], text = "Read the changelog")
  let light = r.band(result, "#f8f9fb")
  r.setStyle(light, "text-align", "center")
  discard r.el(light, "p", [("margin", "0 0 12px")], text = "Follow the " &
    "project")
  discard r.social(light, ["github", "mastodon", "bluesky"])
  let dark = r.band(result, "#111827")
  discard r.el(dark, "p", [("color", "#f9fafb"), ("margin", "0 0 12px"),
    ("text-align", "center")], text = "Talk to us")
  discard r.social(dark, ["email", "x", "linkedin"], [("mode", "dark")])
  r.footer(result)

# --- mailNavbar -----------------------------------------------------------------

proc navbarMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Acme news", "Three links at the top.")
  let s = r.band(result)
  discard r.navbar(s, ["Home", "Docs", "Pricing"])
  discard r.el(s, "h1", [("margin", "16px 0")], text = "Acme news")
  discard r.el(s, "p", text = "What changed this month.")
  r.footer(result)

proc navbarMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("All the links", "Eight links with a separator, one " &
    "long, that wrap on a phone.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "All the links")
  discard r.el(s, "p", text = "Eight links, separated by a dot, from the " &
    "start of the line; the row wraps on a phone.")
  discard r.navbar(s, ["Home", "Product", "Documentation and guides",
    "Pricing", "Blog", "Careers", "Status", "Contact"],
    [("align", "left"), ("separator", "·")])
  discard r.el(s, "p", [("margin", "16px 0 0")], text = "A centred " &
    "navbar with 12px gaps:")
  discard r.navbar(s, ["One", "Two", "Three", longWord],
    styles = [("gap", "12px")])
  r.footer(result)

proc navbarRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("أخبار أكمي", "روابط في الأعلى.", rtl = true)
  let s = r.band(result)
  discard r.navbar(s, ["الرئيسية", "التوثيق", "الأسعار", "اتصل بنا"],
    [("separator", "·")])
  discard r.el(s, "h1", [("margin", "16px 0")], text = "أخبار أكمي")
  discard r.el(s, "p", text = "ما الذي تغيّر هذا الشهر.")
  r.footer(result, rtl = true)

proc navbarImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Acme weekly", "A logo above the navigation, images " &
    "off.")
  let s = r.band(result)
  r.setStyle(s, "text-align", "center")
  discard r.el(s, "mailImage", [("width", "120px"),
    ("height", fixtureImageHeight("logo.png", 120))],
    [("src", fixtureImageUrl("logo.png")), ("alt", "Acme")])
  discard r.navbar(s, ["Home", "Docs", "Blog"])
  discard r.el(s, "h1", [("margin", "16px 0")], text = "Acme weekly")
  discard r.el(s, "p", text = "With images off, the logo shows its alt " &
    "text and the links stay readable.")
  r.footer(result)

proc navbarDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Acme news, dark", "Navigation in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.navbar(s, ["Home", "Docs", "Pricing", "Blog"],
    [("separator", "·")])
  discard r.dkText(s, "h1", "Acme news, dark", [("margin", "16px 0")])
  discard r.dkText(s, "p", "The links take the link colour's dark pair.")
  r.dkFooter(result)

proc navbarInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome to Acme", "A header band with a logo and " &
    "navigation.")
  let head = r.band(result, "#eef2ff", "24px 0 16px")
  r.setStyle(head, "text-align", "center")
  discard r.el(head, "mailImage", [("width", "120px"),
    ("height", fixtureImageHeight("logo.png", 120))],
    [("src", fixtureImageUrl("logo.png")), ("alt", "Acme")])
  discard r.navbar(head, ["Home", "Docs", "Pricing", "Sign in"])
  let s = r.band(result)
  discard r.el(s, "h1", text = "Welcome to Acme")
  discard r.el(s, "p", text = "Your workspace is ready.")
  discard r.el(s, "mailButton", attrs = [("href",
    "https://app.example.com/")], text = "Open your workspace")
  r.footer(result)

# --- Registration -----------------------------------------------------------

let navigationStories*: array[12, KitStory] = [
  ("socialMinimal", "mailSocial with its defaults.", socialMinimalDoc,
    false),
  ("socialMaximal", "Every built-in network, 32px, start-aligned, an icon " &
    "of our own.", socialMaximalDoc, false),
  ("socialRtl", "Social links right to left.", socialRtlDoc, false),
  ("socialImagesOff", "Social links (capture with images off).",
    socialImagesOffDoc, false),
  ("socialDark", "Social links in their dark colours.", socialDarkDoc, true),
  ("socialInContext", "A footer with social links on a light and a dark " &
    "band.", socialInContextDoc, false),
  ("navbarMinimal", "mailNavbar with its defaults.", navbarMinimalDoc,
    false),
  ("navbarMaximal", "Eight links with a separator, one long, wrapping.",
    navbarMaximalDoc, false),
  ("navbarRtl", "Navigation right to left.", navbarRtlDoc, false),
  ("navbarImagesOff", "Navigation under a logo (capture with images off).",
    navbarImagesOffDoc, false),
  ("navbarDark", "Navigation in its dark colours.", navbarDarkDoc, true),
  ("navbarInContext", "A header band with a logo and navigation.",
    navbarInContextDoc, false),
]

proc navigationGroup(name: string): string =
  if name.startsWith("social"): "social" else: "navbar"

proc renderNavigationStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(navigationStories, name, "navigation")

proc registerNavigationStories*() =
  ## Registers the navigation story sets (env-gated, see above).
  registerKit(navigationStories, navigationGroup)

proc registerNavigationStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(navigationStories)
