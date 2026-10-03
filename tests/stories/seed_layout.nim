## Layout reference stories: one column of sections and a wrapper, and
## rows of two, three and four columns.
##
## `layoutOneColumn` is the div-first scaffolding as a real message
## would use it: a header
## section with the logo, a wrapper whose grey band holds two white
## sections (the first a stack of heading and paragraphs, the second
## bordered), and a full-width footer band in a dark colour. Every
## block is one column, so each section's column padding merges into
## the section (no column scaffolding). `layoutTwoColumns`,
## `layoutThreeColumns` and `layoutFourColumns` put every row strategy
## where a message would: a section's own columns (an image beside
## text, reversed on desktop; three features), `mailColumns` rows with a
## gutter (cards, a Fab Four row, four short items), cell rows of
## stats and icons, and two groups that keep their pairs side by side.
## They are iterated on in the capture loop like any story, on every
## provider.
##
## Env-gated: the drivers register it only under
## `ISONIM_CAPTURE_LAYOUT=1`, so bare runs, the capture regression
## matrix and the story-set pins never see it (it has no baselines).
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import fixture_images

proc text(r: EmailRenderer; parent: EmailNode; tag, body: string;
    styles: openArray[(string, string)] = []) =
  let el = r.createElement(tag)
  r.setTextContent(el, body)
  for (k, v) in styles:
    r.setStyle(el, k, v)
  r.appendChild(parent, el)

proc layoutOneColumnDoc*(): EmailNode =
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Your weekly summary")
  r.setAttribute(doc, "preheader", "Three builds, one review, no alerts.")
  r.setStyle(doc, "background-color", "#f4f5f7")

  # Header: the logo, centred on white.
  let header = r.createElement("mailSection")
  r.setStyle(header, "background-color", "#ffffff")
  r.setStyle(header, "padding", "16px 0")
  r.setStyle(header, "text-align", "center")
  let logo = r.createElement("mailImage")
  r.setAttribute(logo, "src", fixtureImageUrl("logo.png"))
  r.setAttribute(logo, "alt", "Acme logo")
  r.setStyle(logo, "width", "120px")
  r.appendChild(header, logo)
  r.appendChild(doc, header)

  # A grey wrapper band around two white sections.
  let wrapper = r.createElement("mailWrapper")
  r.setStyle(wrapper, "background-color", "#e5e7eb")
  r.setStyle(wrapper, "padding", "16px 12px")
  let body = r.createElement("mailSection")
  r.setStyle(body, "background-color", "#ffffff")
  let stack = r.createElement("mailStack")
  r.setStyle(stack, "gap", "8px")
  r.text(stack, "h1", "Your weekly summary")
  r.text(stack, "p", "Three builds finished this week and one review " &
    "is waiting for you.")
  r.text(stack, "p", "No alerts were raised.")
  r.appendChild(body, stack)
  r.appendChild(wrapper, body)
  let note = r.createElement("mailSection")
  r.setStyle(note, "background-color", "#ffffff")
  r.setStyle(note, "padding", "16px 0")
  r.setStyle(note, "border", "1px solid #9ca3af")
  r.text(note, "p", "This section has a border and its own padding.")
  r.appendChild(wrapper, note)
  r.appendChild(doc, wrapper)

  # Footer: a full-width dark band.
  let footer = r.createElement("mailSection")
  r.setAttribute(footer, "full_width", "true")
  r.setStyle(footer, "background-color", "#1f2937")
  r.setStyle(footer, "text-align", "center")
  r.text(footer, "p", "Acme Inc., 1 Example Street, Springfield",
    [("color", "#f9fafb")])
  r.appendChild(doc, footer)
  doc

proc renderLayoutOneColumn*(): StoryHtml =
  renderStoryPipeline(layoutOneColumnDoc(), defaultTarget())

# --- Rows of columns.

proc el(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  r.appendChild(parent, result)

proc storyDoc(r: EmailRenderer; title, preheader: string): EmailNode =
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", "en")
  r.setAttribute(result, "dir", "ltr")
  r.setAttribute(result, "title", title)
  r.setAttribute(result, "preheader", preheader)
  r.setStyle(result, "background-color", "#f4f5f7")
  let header = r.el(result, "mailSection", [("background-color", "#ffffff"),
    ("padding", "16px 0"), ("text-align", "center")])
  discard r.el(header, "mailImage", [("width", "120px")],
    [("src", fixtureImageUrl("logo.png")), ("alt", "Acme logo")])

proc intro(r: EmailRenderer; doc: EmailNode; heading, body: string) =
  let s = r.el(doc, "mailSection", [("background-color", "#ffffff"),
    ("padding", "8px 0 16px")])
  r.text(s, "h1", heading)
  r.text(s, "p", body)

proc footer(r: EmailRenderer; doc: EmailNode) =
  let f = r.el(doc, "mailSection", [("background-color", "#1f2937"),
    ("text-align", "center")], [("full_width", "true")])
  r.text(f, "p", "Acme Inc., 1 Example Street, Springfield",
    [("color", "#f9fafb")])

proc card(r: EmailRenderer; row: EmailNode; heading, body: string;
    level = "h3") =
  let c = r.el(row, "mailColumn", [("background-color", "#ffffff"),
    ("padding", "16px")])
  r.text(c, level, heading, [("margin", "0 0 8px")])
  r.text(c, "p", body, [("margin", "0")])

proc stat(r: EmailRenderer; row: EmailNode; value, label, bg: string) =
  let c = r.el(row, "mailColumn", [("background-color", bg),
    ("padding", "12px 8px"), ("text-align", "center"),
    ("vertical-align", "middle")])
  r.text(c, "p", value, [("margin", "0"), ("font-size", "24px"),
    ("line-height", "32px"), ("font-weight", "700")])
  r.text(c, "p", label, [("margin", "0"), ("font-size", "14px"),
    ("line-height", "20px")])

proc layoutTwoColumnsDoc*(): EmailNode =
  let r = EmailRenderer()
  let doc = r.storyDoc("Your new workspace", "A picture, two cards and " &
    "two numbers.")
  r.intro(doc, "Your new workspace", "Everything you set up this week, " &
    "in one place.")
  # An image beside text: the image comes first on a phone and sits on
  # the right on a desktop (reversed, the image column has no text).
  let media = r.el(doc, "mailSection", [("background-color", "#ffffff"),
    ("padding", "0 0 16px")])
  let mediaRow = r.el(media, "mailColumns", attrs = [("gutter", "24px"),
    ("reverse_on_mobile", "true"), ("valign", "middle")])
  let pic = r.el(mediaRow, "mailColumn", [("text-align", "center")])
  discard r.el(pic, "mailImage", [("width", "232px")],
    [("src", fixtureImageUrl("scene.png")), ("alt", "A green hill " &
      "under a yellow sun")])
  let words = r.el(mediaRow, "mailColumn")
  r.text(words, "h2", "A quiet start", [("margin", "0 0 8px")])
  r.text(words, "p", "Your workspace is ready. Invite the team when " &
    "you are, and pick up where you left off on any device.")
  # Two cards with a gutter: side by side on a desktop, stacked with a
  # gap on a phone.
  let band = r.el(doc, "mailSection", [("background-color", "#e5e7eb")])
  let cards = r.el(band, "mailColumns")
  r.card(cards, "Projects", "Two projects are waiting for their first " &
    "build. Each one keeps its history for thirty days.")
  r.card(cards, "Reviews", "One review is open.")
  # Two short numbers in a cell row: never stacked, equal heights.
  let numbers = r.el(doc, "mailSection", [("background-color", "#ffffff")])
  let stats = r.el(numbers, "mailColumns", attrs = [("strategy", "cells"),
    ("gutter", "8px"), ("min_column", "72px")])
  r.stat(stats, "3", "builds", "#dbeafe")
  r.stat(stats, "1", "open review", "#dcfce7")
  r.footer(doc)
  doc

proc layoutThreeColumnsDoc*(): EmailNode =
  let r = EmailRenderer()
  let doc = r.storyDoc("Three ways to start", "Features, plans and numbers.")
  r.intro(doc, "Three ways to start", "Pick the one that fits your team.")
  # A section's own three columns: each an icon, a heading and a line.
  let features = r.el(doc, "mailSection", [("background-color", "#ffffff"),
    ("padding", "0 12px")])
  for (heading, body) in [("Secure", "Every change is signed."),
      ("Fast", "Builds start in seconds and finish in minutes."),
      ("Shared", "Your whole team sees the same state.")]:
    let c = r.el(features, "mailColumn", [("padding", "0 12px")])
    discard r.el(c, "mailImage", [("width", "48px")],
      [("src", fixtureImageUrl("shield.png")), ("alt", ""),
        ("decorative", "true")])
    r.text(c, "h2", heading, [("margin", "8px 0 4px")])
    r.text(c, "p", body, [("margin", "0 0 16px")])
  # Three plans as a Fab Four row: it switches by its own width.
  let band = r.el(doc, "mailSection", [("background-color", "#e5e7eb")])
  let plans = r.el(band, "mailColumns", attrs = [("strategy", "fabFour"),
    ("gutter", "16px")])
  r.card(plans, "Starter", "One project, one seat.")
  r.card(plans, "Team", "Ten projects and shared reviews.")
  r.card(plans, "Company", "Unlimited projects, single sign-on and an " &
    "audit log for every change.")
  # Three numbers in a cell row.
  let numbers = r.el(doc, "mailSection", [("background-color", "#ffffff")])
  let stats = r.el(numbers, "mailColumns", attrs = [("strategy", "cells"),
    ("gutter", "8px"), ("min_column", "72px")])
  r.stat(stats, "12", "builds", "#dbeafe")
  r.stat(stats, "4", "reviews", "#dcfce7")
  r.stat(stats, "0", "alerts", "#fef3c7")
  r.footer(doc)
  doc

proc layoutFourColumnsDoc*(): EmailNode =
  let r = EmailRenderer()
  let doc = r.storyDoc("This week at a glance", "Four short items, a " &
    "schedule and four badges.")
  r.intro(doc, "This week at a glance", "The short version.")
  # Four short items with a gutter: one line each on a desktop, stacked
  # on a phone.
  let band = r.el(doc, "mailSection", [("background-color", "#e5e7eb")])
  let items = r.el(band, "mailColumns", attrs = [("gutter", "16px")])
  r.card(items, "Mon", "Planning.", "h2")
  r.card(items, "Tue", "Builds.", "h2")
  r.card(items, "Wed", "Reviews.", "h2")
  r.card(items, "Thu", "Release.", "h2")
  # Two groups of two: each pair stays side by side on a phone.
  let sched = r.el(doc, "mailSection", [("background-color", "#ffffff"),
    ("padding", "24px 12px 16px")])
  for (a, b) in [(("9:00", "Stand-up"), ("11:00", "Design review")),
      (("14:00", "Pairing"), ("16:00", "Demo"))]:
    let g = r.el(sched, "mailGroup", [("width", "50%")])
    for (time, what) in [a, b]:
      let c = r.el(g, "mailColumn", [("padding", "0 12px")])
      r.text(c, "h3", time, [("margin", "0")])
      r.text(c, "p", what, [("margin", "0 0 8px")])
  # Four badges as image cells: never stacked.
  let badges = r.el(doc, "mailSection", [("background-color", "#ffffff"),
    ("padding", "0 0 24px")])
  let icons = r.el(badges, "mailColumns", attrs = [("strategy", "cells"),
    ("gutter", "8px"), ("min_column", "48px")])
  for name in ["Security", "Speed", "Sharing", "Support"]:
    let c = r.el(icons, "mailColumn", [("text-align", "center")])
    discard r.el(c, "mailImage", [("width", "48px")],
      [("src", fixtureImageUrl("shield.png")), ("alt", name)])
  r.footer(doc)
  doc

proc renderLayoutTwoColumns*(): StoryHtml =
  renderStoryPipeline(layoutTwoColumnsDoc(), defaultTarget())

proc renderLayoutThreeColumns*(): StoryHtml =
  renderStoryPipeline(layoutThreeColumnsDoc(), defaultTarget())

proc renderLayoutFourColumns*(): StoryHtml =
  renderStoryPipeline(layoutFourColumnsDoc(), defaultTarget())

proc registerLayoutStories*() =
  ## Registers the layout reference stories (env-gated, see above).
  registerStory(Story(name: "layoutOneColumn", group: "layout",
    description: "One column: sections, a wrapper, a stack, a bordered " &
      "and a full-width section.", render: renderLayoutOneColumn))
  registerStory(Story(name: "layoutTwoColumns", group: "layout",
    description: "Two columns: an image beside text reversed on " &
      "desktop, two cards with a gutter, a cell row of two numbers.",
    render: renderLayoutTwoColumns))
  registerStory(Story(name: "layoutThreeColumns", group: "layout",
    description: "Three columns: a section's own feature columns, a " &
      "Fab Four row of plans, a cell row of three numbers.",
    render: renderLayoutThreeColumns))
  registerStory(Story(name: "layoutFourColumns", group: "layout",
    description: "Four columns: four short items with a gutter, two " &
      "groups of two, a cell row of four badges.",
    render: renderLayoutFourColumns))
