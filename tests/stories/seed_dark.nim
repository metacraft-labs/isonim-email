## Dark-mode stories: the story set of the dark-mode system.
## `darkDesigned` (`darkMode = designed`, every colour a theme token and
## no `@dark:` anywhere: the dark palette comes from the tokens, the
## document's own surface included, down to the page below the
## message), `darkLogoSwap` (a logo with its dark image, `dark_src`,
## swapped by the dark block; the light logo carries a white outline so
## it reads where no swap happens) and `darkBrand` (the default
## `accommodate`: a brand palette picked to pass the inversion
## simulation, the deep brand band and its pale callout, for the
## clients that recolour the message themselves).
##
## The logos are `tests/stories/assets/mark-outlined.png` (240×80, a
## dark mark with a 3px white outline, transparent around it) and
## `mark-dark.png` (the same mark, light, for dark backgrounds), on the
## capture fixture host.
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import fixture_images
import story_kit

proc tokText(r: EmailRenderer; parent: EmailNode; tag, body: string;
    styles: openArray[(string, string)] = [];
    colour = ""): EmailNode =
  ## A text element; its colour a token when given, else the default
  ## the style pass gives it (paired with its dark value).
  result = r.el(parent, tag, styles, text = body)
  if colour.len > 0:
    r.setStyle(result, "color", TokenRef(key: colour))

proc tokBand(r: EmailRenderer; doc: EmailNode; surface: string;
    padding = "24px 0"): EmailNode =
  result = r.el(doc, "mailSection", [("padding", padding)])
  r.setStyle(result, "background-color", TokenRef(key: surface))

proc darkDesignedDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.el(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", "Your weekly summary"),
    ("preheader", "Three builds, one release.")])
  let s = r.tokBand(result, "color.surface.card")
  discard r.tokText(s, "h1", "Your weekly summary")
  let p = r.tokText(s, "p", "Three builds ran this week and one " &
    "release went out. ")
  discard r.link(p, "https://example.com/builds", "See every build")
  r.txt(p, ".")
  discard r.el(s, "mailDivider")
  discard r.tokText(s, "p", "Next release: Thursday.",
    colour = "color.text.secondary")
  discard r.el(s, "mailButton", attrs = [("href",
    "https://example.com/dashboard")], text = "Open the dashboard")
  let f = r.tokBand(result, "color.surface.subtle")
  r.setStyle(f, "text-align", "center")
  let fp = r.tokText(f, "p", "Acme Inc., 1 Example Street, Springfield · ",
    [("margin", "0")], "color.text.secondary")
  discard r.link(fp, "https://example.com/unsubscribe", "Unsubscribe")

proc darkLogoSwapDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.el(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", "Welcome to Acme"),
    ("preheader", "Your account is ready.")])
  r.setStyle(result, "background-color", tok"color.surface.canvas")
  let head = r.tokBand(result, "color.surface.card", "24px 0 8px")
  r.setStyle(head, "text-align", "center")
  discard r.el(head, "mailImage", [("width", "120px")], [
    ("src", fixtureImageUrl("mark-outlined.png")),
    ("dark_src", fixtureImageUrl("mark-dark.png")),
    ("alt", "Acme"), ("href", "https://example.com/")])
  let s = r.tokBand(result, "color.surface.card", "8px 0 24px")
  discard r.tokText(s, "h1", "Welcome to Acme")
  discard r.tokText(s, "p", "Your account is ready. The logo above " &
    "has a dark version for dark mode.")
  r.dkFooter(result)

proc darkBrandDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Spring launch", "A brand band that survives " &
    "inversion.")
  let band = r.band(result, "#0b3a6e")
  r.setStyle(band, "text-align", "center")
  discard r.el(band, "h1", [("color", "#ffffff")],
    text = "Spring launch")
  discard r.el(band, "p", [("color", "#ffffff"), ("margin", "0")],
    text = "Everything new this season, in one place.")
  let s = r.band(result)
  discard r.el(s, "p", [("color", "#1f2937")], text = "The deep blue " &
    "band keeps its white text readable when a client inverts it, and " &
    "so does the callout below.")
  let callout = r.el(s, "mailBox", [("background-color", "#eef4fb"),
    ("padding", "16px"), ("border", "1px solid #b9cde6")])
  discard r.el(callout, "p", [("color", "#0b3a6e"), ("margin", "0"),
    ("font-weight", "700")], text = "Early access opens on Monday.")
  r.footer(result)

const darkStories*: seq[KitStory] = @[
  ("darkDesigned", "A designed message whose dark palette comes from its " &
    "tokens alone.", darkDesignedDoc, true),
  ("darkLogoSwap", "A logo swapped for its dark version in dark mode.",
    darkLogoSwapDoc, true),
  ("darkBrand", "A brand palette picked to survive inversion " &
    "(accommodate).", darkBrandDoc, false),
]

proc darkGroup(name: string): string = "dark"

proc renderDarkStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(darkStories, name, "dark")

proc registerDarkStories*() =
  ## Registers the dark story set (env-gated, see above).
  registerKit(darkStories, darkGroup)

proc registerDarkStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(darkStories)
