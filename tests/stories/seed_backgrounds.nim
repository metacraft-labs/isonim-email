## Background-image stories: the story set of `mailHero` and of bands
## with a background image: `heroFullWidth` (a 320px hero across the
## container, its content centred vertically, a headline, a line of
## text and a button), `sectionBackground` (a light striped image behind
## dark text, a dark landscape behind light text across a `full_width`
## band, and a `min_height` hero), `backgroundTile` (a tiled pattern
## behind a section, and behind a wrapper of two white cards),
## `heroRtl` (Arabic, right to left), `heroImagesOff` (every kind of
## background, captured with images blocked: the fallback colours) and
## `heroDark` (`darkMode = designed`: a hero and a band in their dark
## colours).
##
## The images are `tests/stories/assets/hero.png` (1200×640, a dusk
## landscape, dark), `band.png` (1200×400, light warm stripes) and
## `tile.png` (40×40, light dots), on the capture fixture host.
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import fixture_images
import story_kit

const heroFallback = "#1b2a4a"
  ## The landscape's own dark blue: what shows instead of it.
const bandFallback = "#fde9d0"
  ## The stripes' average: what shows instead of them.
const tileFallback = "#eef2f7"
  ## The tile's ground.

proc hero(r: EmailRenderer; parent: EmailNode;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  var s = @[("background-color", heroFallback),
    ("background-image", fixtureImageUrl("hero.png"))]
  for x in styles:
    s.add(x)
  r.el(parent, "mailHero", s, attrs)

proc cta(r: EmailRenderer; parent: EmailNode; label: string): EmailNode =
  r.el(parent, "mailButton", attrs = [("href", "https://app.example.com/"),
    ("align", "center")], text = label)

proc heroFullWidthDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Spring sale", "Twenty percent off everything " &
    "until Sunday.")
  let h = r.hero(result, [("height", "320px"), ("text-align", "center")],
    [("vertical_align", "middle")])
  discard r.el(h, "h1", [("color", "#ffffff")], text = "Spring sale")
  discard r.el(h, "p", [("color", "#e5e7eb"), ("margin", "8px 0 20px")],
    text = "Twenty percent off everything until Sunday.")
  discard r.cta(h, "Shop the sale")
  let s = r.band(result)
  discard r.el(s, "p", text = "The discount applies at checkout. It " &
    "cannot be combined with other offers.")
  r.footer(result)

proc sectionBackgroundDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("This week", "Three bands with background images.")
  let light = r.el(result, "mailSection", [("background-color", bandFallback),
    ("background-image", fixtureImageUrl("band.png")),
    ("padding", "40px 0")], [("background_position", "center top")])
  discard r.el(light, "h1", [("color", "#272522")], text = "This week")
  discard r.el(light, "p", [("color", "#3f3a33")], text = "A light " &
    "striped image behind dark text, its fallback colour the stripes' " &
    "average.")
  let dark = r.el(result, "mailSection", [("background-color", heroFallback),
    ("background-image", fixtureImageUrl("hero.png")),
    ("padding", "48px 0")], [("full_width", "true")])
  discard r.el(dark, "h2", [("color", "#ffffff")], text = "Across the page")
  discard r.el(dark, "p", [("color", "#e5e7eb")], text = "A full-width " &
    "band: the landscape covers the 600px container, the fallback " &
    "colour runs to the edges.")
  let h = r.hero(result, [("min-height", "200px")],
    [("vertical_align", "bottom")])
  discard r.el(h, "h2", [("color", "#ffffff")], text = "At least 200px")
  discard r.el(h, "p", [("color", "#e5e7eb")], text = "A hero with a " &
    "minimum height, its text at the bottom.")
  r.footer(result)

proc backgroundTileDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Patterns", "A tiled background behind a section " &
    "and behind two cards.")
  let tiled = r.el(result, "mailSection", [("background-color", tileFallback),
    ("background-image", fixtureImageUrl("tile.png")),
    ("background-size", "auto"), ("padding", "32px 0")],
    [("background_repeat", "repeat")])
  discard r.el(tiled, "h1", [("color", "#111827")], text = "Patterns")
  discard r.el(tiled, "p", [("color", "#1f2937")], text = "A 20px dot " &
    "pattern repeats behind this section from its top left corner.")
  discard r.el(tiled, "mailButton", attrs = [("href",
    "https://app.example.com/")], text = "See the patterns")
  let w = r.el(result, "mailWrapper", [("background-color", tileFallback),
    ("background-image", fixtureImageUrl("tile.png")),
    ("background-size", "auto"), ("padding", "24px 24px")],
    [("background_repeat", "repeat")])
  for (title, body) in [("First card", "A white card on the pattern."),
      ("Second card", "Another, 16px below the first.")]:
    let c = r.el(w, "mailSection", [("background-color", "#ffffff"),
      ("padding", "16px 0")])
    discard r.el(c, "h2", text = title)
    discard r.el(c, "p", text = body)
    if title == "First card":
      discard r.el(w, "mailSection", [("padding", "8px 0")])
  r.footer(result)

proc heroRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("تخفيضات الربيع", "خصم عشرين بالمئة على كل شيء حتى " &
    "الأحد.", rtl = true)
  let h = r.hero(result, [("height", "300px")], [("vertical_align",
    "middle")])
  discard r.el(h, "h1", [("color", "#ffffff")], text = "تخفيضات الربيع")
  discard r.el(h, "p", [("color", "#e5e7eb"), ("margin", "8px 0 20px")],
    text = "خصم عشرين بالمئة على كل شيء حتى يوم الأحد.")
  discard r.el(h, "mailButton", attrs = [("href", "https://app.example.com/")],
    text = "تسوق الآن")
  let s = r.band(result)
  discard r.el(s, "p", text = "يطبق الخصم عند الدفع.")
  r.footer(result, rtl = true)

proc heroImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Images off", "Every background, its fallback colour " &
    "showing.")
  let h = r.hero(result, [("height", "260px")], [("vertical_align",
    "middle")])
  discard r.el(h, "h1", [("color", "#ffffff")], text = "Images off")
  discard r.el(h, "p", [("color", "#e5e7eb")], text = "With images " &
    "blocked, the hero shows its dark blue fallback and this text stays " &
    "readable.")
  let light = r.el(result, "mailSection", [("background-color", bandFallback),
    ("background-image", fixtureImageUrl("band.png"))])
  discard r.el(light, "p", [("color", "#3f3a33")], text = "A light band: " &
    "its warm fallback colour, dark text.")
  let tiled = r.el(result, "mailSection", [("background-color", tileFallback),
    ("background-image", fixtureImageUrl("tile.png")),
    ("background-size", "auto")], [("background_repeat", "repeat")])
  discard r.el(tiled, "p", [("color", "#1f2937")], text = "A tiled band: " &
    "its pale ground, dark text.")
  r.footer(result)

proc heroDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Spring sale, dark", "A hero and a band in their dark " &
    "colours.")
  let h = r.hero(result, [("height", "300px")], [("vertical_align",
    "middle")])
  # Text over an image keeps one colour in both schemes: the image does
  # not change with the scheme, so a token that flips would put dark
  # text on the dark landscape (the raw colours are reported, a warning).
  discard r.el(h, "h1", [("color", "#ffffff")], text = "Spring sale")
  discard r.el(h, "p", [("color", "#e5e7eb"), ("margin", "8px 0 0")],
    text = "Light text on the dark landscape and on its dark fallback, " &
    "in either scheme.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "p", "Below the hero, a card band in its dark " &
    "colours.")
  r.dkFooter(result)

# --- Registration -----------------------------------------------------------

let backgroundStories*: array[6, KitStory] = [
  ("heroFullWidth", "A 320px hero across the container, its content " &
    "centred.", heroFullWidthDoc, false),
  ("sectionBackground", "A light striped band, a full-width landscape " &
    "band and a min_height hero.", sectionBackgroundDoc, false),
  ("backgroundTile", "A tiled pattern behind a section and behind two " &
    "cards.", backgroundTileDoc, false),
  ("heroRtl", "A hero in Arabic, right to left.", heroRtlDoc, false),
  ("heroImagesOff", "Every kind of background (capture with images off).",
    heroImagesOffDoc, false),
  ("heroDark", "A hero and a band in their dark colours.", heroDarkDoc,
    true),
]

proc backgroundGroup(name: string): string = "background"

proc renderBackgroundStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(backgroundStories, name, "background")

proc registerBackgroundStories*() =
  ## Registers the background story set (env-gated, see above).
  registerKit(backgroundStories, backgroundGroup)

proc registerBackgroundStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(backgroundStories)
