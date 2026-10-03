## Layout primitive stories: the story set of `mailBox`, `mailGrid`,
## `mailCluster` and `mailSidebar` (layout-patterns.md §5): for each,
## `Minimal` (required props only), `Maximal` (every prop, the longest
## realistic content, long unbroken words), `Rtl` (Arabic, right to
## left), `ImagesOff` (content with images, captured with images
## blocked), `Dark` (`darkMode = designed`, with dark colours) and
## `InContext` (between two different neighbours in a band).
##
## Env-gated like the layout reference stories: the drivers register
## them only under `ISONIM_CAPTURE_LAYOUT=1`, so bare runs, the capture
## regression matrix and the story-set pins never see them.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images

proc el(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

proc storyDoc(r: EmailRenderer; title, preheader: string;
    rtl = false): EmailNode =
  result = r.el(nil, "mailDocument", [("background-color", "#f4f5f7")],
    [("lang", if rtl: "ar" else: "en"), ("dir", if rtl: "rtl" else: "ltr"),
      ("title", title), ("preheader", preheader)])

proc band(r: EmailRenderer; doc: EmailNode; bg = "#ffffff";
    padding = "24px 0"): EmailNode =
  r.el(doc, "mailSection", [("background-color", bg), ("padding", padding)])

proc heading(r: EmailRenderer; doc: EmailNode; title, intro: string) =
  let s = r.band(doc, padding = "24px 0 8px")
  discard r.el(s, "h1", [("margin", "0 0 8px")], text = title)
  if intro.len > 0:
    discard r.el(s, "p", [("margin", "0")], text = intro)

proc footer(r: EmailRenderer; doc: EmailNode; rtl = false) =
  let f = r.el(doc, "mailSection", [("background-color", "#1f2937"),
    ("text-align", "center")], [("full_width", "true")])
  discard r.el(f, "p", [("color", "#f9fafb"), ("margin", "0")],
    text = if rtl: "شركة أكمي، ١ شارع المثال، الرياض"
      else: "Acme Inc., 1 Example Street, Springfield")

proc textOf(n: EmailNode): string =
  ## The visible text of a tree, one block per line: the stories' plain
  ## text alternative (the plain-text generator will produce these).
  if n.kind == enText:
    return n.text
  if n.kind != enElement:
    return ""
  var inner = ""
  for c in n.children:
    inner.add(textOf(c))
  if n.tag in ["h1", "h2", "h3", "p", "a", "span"]:
    return inner.strip() & "\n"
  inner

proc render(doc: EmailNode; dark = false): StoryHtml =
  var t = defaultTarget()
  if dark:
    t.darkMode = dmDesigned
  let text = textOf(doc)
  (renderPipeline(doc, t), text)

# Dark stories (`darkMode = designed`): every colour is a theme token
# with its dark pair, the document's canvas included, so the dark scheme
# paints the whole message.

proc paint(r: EmailRenderer; n: EmailNode; prop: string; t: TokenRef) =
  r.setStyle(n, prop, t)
  r.setStyle(n, "@dark:" & prop, t)

proc dkBand(r: EmailRenderer; doc: EmailNode; surface: TokenRef;
    padding = "24px 0"): EmailNode =
  result = r.el(doc, "mailSection", [("padding", padding)])
  r.paint(result, "background-color", surface)

proc dkText(r: EmailRenderer; parent: EmailNode; tag, body: string;
    styles: openArray[(string, string)] = [];
    colour = tok"color.text.primary"): EmailNode =
  result = r.el(parent, tag, styles, text = body)
  r.paint(result, "color", colour)

proc dkDoc(r: EmailRenderer; title, preheader: string): EmailNode =
  result = r.el(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", title), ("preheader", preheader)])
  r.paint(result, "background-color", tok"color.surface.canvas")
  let s = r.dkBand(result, tok"color.surface.card", "24px 0 8px")
  discard r.dkText(s, "h1", title, [("margin", "0")])

proc dkFooter(r: EmailRenderer; doc: EmailNode) =
  let f = r.dkBand(doc, tok"color.surface.subtle")
  r.setStyle(f, "text-align", "center")
  discard r.dkText(f, "p", "Acme Inc., 1 Example Street, Springfield",
    [("margin", "0")], tok"color.text.secondary")

const longWord = "Supercalifragilisticexpialidociousnessless"
  ## A long unbroken word (the maximal stories' wrapping check).

# --- mailBox ----------------------------------------------------------------

proc boxMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A box", "One box, its defaults.")
  r.heading(result, "A box", "")
  let s = r.band(result)
  let b = r.el(s, "mailBox")
  discard r.el(b, "p", [("margin", "0")],
    text = "The box keeps its content 24 pixels from its edges.")
  r.footer(result)

proc boxMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your plan renews soon",
    "Two boxes: bordered and rounded, shadowed.")
  r.heading(result, "Your plan renews soon", "Everything about your " &
    "plan, in two boxes.")
  let s = r.band(result, "#f4f5f7")
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  let b = r.el(stack, "mailBox", [("padding", "20px 24px"),
    ("background-color", "#ffffff"), ("border", "1px solid #d1d5db"),
    ("border-radius", "12px")], [("shadow", "md")])
  discard r.el(b, "h2", [("margin", "0 0 8px")], text = "Team plan")
  discard r.el(b, "p", [("margin", "0 0 8px")],
    text = "Your Team plan renews on 1 November for another year. Ten " &
      "projects, shared reviews and an audit log stay with you; nothing " &
      "changes unless you change it.")
  discard r.el(b, "p", [("margin", "0")],
    text = "Reference: " & longWord & longWord)
  let b2 = r.el(stack, "mailBox", [("padding", "16px"),
    ("background-color", "#eff6ff"), ("border-radius", "6px")],
    [("shadow", "sm")])
  discard r.el(b2, "p", [("margin", "0")],
    text = "A softer box: a light shadow, and a 1px border one shade " &
      "darker than its blue, which shows where the shadow does not.")
  r.footer(result)

proc boxRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("خطتك", "صندوق واحد من اليمين إلى اليسار.", true)
  r.heading(result, "خطتك", "كل ما يخص خطتك في صندوق واحد.")
  let s = r.band(result, "#f4f5f7")
  let b = r.el(s, "mailBox", [("background-color", "#ffffff"),
    ("border", "1px solid #d1d5db"), ("border-radius", "8px")],
    [("shadow", "sm")])
  discard r.el(b, "h2", [("margin", "0 0 8px")], text = "خطة الفريق")
  discard r.el(b, "p", [("margin", "0")],
    text = "تتجدد خطتك في الأول من نوفمبر لسنة أخرى. تبقى المشاريع " &
      "العشرة والمراجعات المشتركة كما هي.")
  r.footer(result, rtl = true)

proc boxImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your new workspace",
    "A box with a picture and its text.")
  r.heading(result, "Your new workspace", "")
  let s = r.band(result, "#f4f5f7")
  let b = r.el(s, "mailBox", [("background-color", "#ffffff"),
    ("border", "1px solid #d1d5db"), ("text-align", "center")])
  discard r.el(b, "mailImage", [("width", "280px"),
    ("height", fixtureImageHeight("scene.png", 280))],
    [("src", fixtureImageUrl("scene.png")),
      ("alt", "A green hill under a yellow sun")])
  discard r.el(b, "p", [("margin", "16px 0 0")],
    text = "The picture's alt text takes its place when images are off.")
  r.footer(result)

proc boxDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Night shift", "A box with its own dark colours.")
  let s = r.dkBand(result, tok"color.surface.subtle")
  let b = r.el(s, "mailBox", [("border-radius", "8px")], [("shadow", "sm")])
  r.paint(b, "background-color", tok"color.surface.card")
  discard r.dkText(b, "h2", "Builds overnight", [("margin", "0 0 8px")])
  discard r.dkText(b, "p", "Three builds ran while you slept. All of " &
    "them passed.", [("margin", "0")], tok"color.text.secondary")
  r.dkFooter(result)

proc boxInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order", "A box between a paragraph and a list.")
  r.heading(result, "Your order", "")
  let s = r.band(result, "#eef2ff")
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  discard r.el(stack, "p", [("margin", "0")],
    text = "Thank you. Your order is confirmed and on its way.")
  let b = r.el(stack, "mailBox", [("background-color", "#ffffff"),
    ("border", "1px solid #c7d2fe"), ("padding", "16px")])
  discard r.el(b, "p", [("margin", "0"), ("font-weight", "700")],
    text = "Order #1234 — 2 items — $42.00")
  let after = r.el(stack, "mailCluster", attrs = [("separator", "·")])
  for (label, href) in [("Track", "https://example.com/track"),
      ("Invoice", "https://example.com/invoice"),
      ("Help", "https://example.com/help")]:
    discard r.el(after, "a", attrs = [("href", href)], text = label)
  r.footer(result)

# --- mailGrid ---------------------------------------------------------------

proc card(r: EmailRenderer; grid: EmailNode; title, body: string;
    bg = "#ffffff") =
  let b = r.el(grid, "mailBox", [("background-color", bg),
    ("padding", "16px")])
  discard r.el(b, "h2", [("margin", "0 0 4px"), ("font-size", "18px"),
    ("line-height", "26px")], text = title)
  discard r.el(b, "p", [("margin", "0")], text = body)

proc gridMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Four things", "A two-column grid.")
  r.heading(result, "Four things", "")
  let s = r.band(result)
  let g = r.el(s, "mailGrid", attrs = [("columns", "2")])
  for t in ["Projects", "Reviews", "Builds", "Alerts"]:
    discard r.el(g, "p", [("margin", "0")], text = t)
  r.footer(result)

proc gridMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("This month's releases",
    "Five releases, three to a row, the last row centred.")
  r.heading(result, "This month's releases", "Five releases, three to " &
    "a row on a desktop, one to a row on a phone.")
  let s = r.band(result, "#e5e7eb")
  let g = r.el(s, "mailGrid", attrs = [("columns", "3"),
    ("gutter", "16px"), ("last_row", "center"), ("align", "left"),
    ("min_item", "160px")])
  r.card(g, "Version 2.4", "Faster builds on large workspaces.")
  r.card(g, "Version 2.5", "Shared reviews across teams, with comments " &
    "that follow the code they are about.")
  r.card(g, "Version 2.6", "A new audit log.")
  r.card(g, "Version 2.7", "Single sign-on for " & longWord & ".")
  r.card(g, "Version 2.8", "Workspace templates.")
  r.footer(result)

proc gridRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("إصدارات الشهر", "ثلاثة في الصف.", true)
  r.heading(result, "إصدارات الشهر", "")
  let s = r.band(result, "#e5e7eb")
  let g = r.el(s, "mailGrid", attrs = [("columns", "3")])
  r.card(g, "الإصدار ٢٫٤", "بناء أسرع.")
  r.card(g, "الإصدار ٢٫٥", "مراجعات مشتركة بين الفرق.")
  r.card(g, "الإصدار ٢٫٦", "سجل تدقيق جديد.")
  r.card(g, "الإصدار ٢٫٧", "تسجيل دخول موحد.")
  r.footer(result, rtl = true)

proc gridImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("From the trip", "Six pictures, three to a row.")
  r.heading(result, "From the trip", "")
  let s = r.band(result)
  let g = r.el(s, "mailGrid", attrs = [("columns", "3"),
    ("gutter", "8px"), ("align", "center")])
  for (img, alt) in [("scene.png", "The hill at dawn"),
      ("shield.png", "The castle crest"), ("scene.png", "The hill at noon"),
      ("shield.png", "The gate crest"), ("scene.png", "The hill at dusk"),
      ("shield.png", "The tower crest")]:
    let src = if img == "scene.png": fixtureImageUrl("scene.png")
      else: fixtureImageUrl("shield.png")
    let h = if img == "scene.png": fixtureImageHeight("scene.png", 160)
      else: fixtureImageHeight("shield.png", 160)
    discard r.el(g, "mailImage", [("width", "160px"), ("height", h)],
      [("src", src), ("alt", alt)])
  r.footer(result)

proc gridDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("This week in numbers",
    "Four numbers: four to a row, two on a phone.")
  let s = r.dkBand(result, tok"color.surface.card")
  let g = r.el(s, "mailGrid", attrs = [("columns", "4"),
    ("mobile_columns", "2"), ("gutter", "8px"), ("min_item", "72px"),
    ("align", "center")])
  for (value, label, i) in [("12", "builds", 0), ("4", "reviews", 1),
      ("0", "alerts", 2), ("98%", "uptime", 3)]:
    let b = r.el(g, "mailBox", [("padding", "12px 8px"),
      ("text-align", "center")])
    r.paint(b, "background-color", case i
      of 0: tok"color.status.info.bg"
      of 1: tok"color.status.success.bg"
      of 2: tok"color.status.warning.bg"
      else: tok"color.status.danger.bg")
    discard r.dkText(b, "p", value, [("margin", "0"), ("font-size", "24px"),
      ("line-height", "32px"), ("font-weight", "700")])
    discard r.dkText(b, "p", label, [("margin", "0"), ("font-size", "14px"),
      ("line-height", "20px")])
  r.dkFooter(result)

proc gridInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Pick a plan", "A grid between a paragraph and a " &
    "full-width band.")
  r.heading(result, "Pick a plan", "")
  let s = r.band(result, "#f4f5f7")
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  discard r.el(stack, "p", [("margin", "0")],
    text = "Every plan includes unlimited reviews.")
  let g = r.el(stack, "mailGrid", attrs = [("columns", "2"),
    ("last_row", "stretch")])
  r.card(g, "Starter", "One project.")
  r.card(g, "Team", "Ten projects.")
  r.card(g, "Company", "Unlimited projects and single sign-on.")
  let band = r.el(result, "mailSection", [("background-color", "#1f6feb"),
    ("text-align", "center")], [("full_width", "true")])
  discard r.el(band, "p", [("margin", "0"), ("color", "#ffffff"),
    ("font-weight", "700")], text = "Questions? Reply to this email.")
  r.footer(result)

# --- mailCluster ------------------------------------------------------------

proc links(r: EmailRenderer; c: EmailNode; labels: openArray[string]) =
  for i, l in labels:
    discard r.el(c, "a", attrs = [("href", "https://example.com/" & $i)],
      text = l)

proc clusterMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Three links", "A cluster of links.")
  r.heading(result, "Three links", "")
  let s = r.band(result)
  r.links(r.el(s, "mailCluster"), ["Dashboard", "Settings", "Help"])
  r.footer(result)

proc clusterMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Everything in one place",
    "Nine links that wrap, centred, with separators.")
  r.heading(result, "Everything in one place", "Nine links, centred; " &
    "they wrap onto more lines on a phone.")
  let s = r.band(result)
  let c = r.el(s, "mailCluster", [("gap", "16px"), ("row-gap", "8px")],
    [("align", "center"), ("separator", "·")])
  r.links(c, ["Dashboard", "Projects", "Reviews", "Builds",
    "Billing and invoices", "Team", "Settings", "Help", longWord])
  r.footer(result)

proc clusterRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("روابط", "مجموعة روابط.", true)
  r.heading(result, "روابط", "")
  let s = r.band(result)
  r.links(r.el(s, "mailCluster", attrs = [("separator", "·")]),
    ["لوحة التحكم", "المشاريع", "المراجعات", "الإعدادات", "المساعدة"])
  r.footer(result, rtl = true)

proc clusterImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Follow us", "Four icons in a row.")
  r.heading(result, "Follow us", "")
  let s = r.band(result, "#ffffff")
  let c = r.el(s, "mailCluster", [("gap", "16px")],
    [("align", "center")])
  for (i, name) in [(0, "Mastodon"), (1, "GitHub"), (2, "YouTube"),
      (3, "Blog")]:
    let a = r.el(c, "a", attrs = [("href", "https://example.com/s" & $i)])
    discard r.el(a, "mailImage", [("width", "32px"),
      ("height", fixtureImageHeight("shield.png", 32))],
      [("src", fixtureImageUrl("shield.png")), ("alt", name)])
  r.footer(result)

proc clusterDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your tags", "Five badges in a cluster.")
  let s = r.dkBand(result, tok"color.surface.card")
  let c = r.el(s, "mailCluster", [("gap", "8px")])
  for (label, i) in [("design", 0), ("backend", 1), ("urgent", 2),
      ("docs", 3), ("release", 0)]:
    let badge = r.dkText(c, "span", label, [("display", "inline-block"),
      ("padding", "4px 12px"), ("border-radius", "999px"),
      ("font-size", "14px"), ("line-height", "20px")])
    r.paint(badge, "background-color", case i
      of 0: tok"color.status.info.bg"
      of 1: tok"color.status.success.bg"
      of 2: tok"color.status.danger.bg"
      else: tok"color.status.warning.bg")
  r.dkFooter(result)

proc clusterInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your receipt", "A footer of links between the " &
    "address and the legal text.")
  r.heading(result, "Your receipt", "Thank you for your order.")
  # The band is light enough for the default link colour (#0969da) to
  # keep 4.5:1 on it (4.7:1; on #e5e7eb it was 4.2:1).
  let f = r.band(result, "#f3f4f6")
  let stack = r.el(f, "mailStack", [("gap", "8px")], [("align", "center")])
  discard r.el(stack, "p", [("margin", "0"), ("font-size", "14px")],
    text = "Acme Inc., 1 Example Street, Springfield")
  r.links(r.el(stack, "mailCluster", attrs = [("align", "center"),
    ("separator", "·")]), ["Unsubscribe", "Preferences", "Privacy"])
  discard r.el(stack, "p", [("margin", "0"), ("font-size", "12px"),
    ("color", "#4b5563")],
    text = "You are receiving this because you bought something from us.")
  r.footer(result)

# --- mailSidebar ------------------------------------------------------------

proc avatarRow(r: EmailRenderer; parent: EmailNode; name, role: string;
    imgWidth = "48px"; fixed = "48px") =
  let sb = r.el(parent, "mailSidebar", attrs = [("fixed", fixed)])
  discard r.el(sb, "mailImage", [("width", imgWidth),
    ("height", imgWidth)],
    [("src", fixtureImageUrl("shield.png")), ("alt", name & "'s avatar")])
  let who = r.el(sb, "mailStack", [("gap", "0")])
  discard r.el(who, "p", [("margin", "0"), ("font-weight", "700")],
    text = name)
  discard r.el(who, "p", [("margin", "0"), ("font-size", "14px"),
    ("color", "#4b5563")], text = role)

proc sidebarMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("New reviewer", "An avatar beside a name.")
  r.heading(result, "New reviewer", "")
  let s = r.band(result)
  r.avatarRow(s, "Ada Lovelace", "Reviewer")
  r.footer(result)

proc sidebarMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("From the blog", "A thumbnail beside a teaser, and " &
    "a date tile beside its details.")
  r.heading(result, "From the blog", "")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "24px")])
  let teaser = r.el(stack, "mailSidebar", [("gap", "24px")],
    [("fixed", "160px"), ("switch_below", "280px"), ("valign", "top"),
      ("side", "left")])
  discard r.el(teaser, "mailImage", [("width", "160px"),
    ("height", fixtureImageHeight("scene.png", 160))],
    [("src", fixtureImageUrl("scene.png")),
      ("alt", "A green hill under a yellow sun")])
  let words = r.el(teaser, "mailStack", [("gap", "8px")])
  discard r.el(words, "h2", [("margin", "0")],
    text = "How we made builds twice as fast")
  discard r.el(words, "p", [("margin", "0")],
    text = "We measured every step of a build on our largest workspace, " &
      "found the three slowest, and rewrote them. Here is what changed, " &
      "what did not, and what " & longWord & " means for you.")
  let event = r.el(stack, "mailSidebar", [("gap", "16px")],
    [("fixed", "72px"), ("side", "right"), ("valign", "middle")])
  let details = r.el(event, "mailStack", [("gap", "4px")])
  discard r.el(details, "p", [("margin", "0"), ("font-weight", "700")],
    text = "Release review")
  discard r.el(details, "p", [("margin", "0")],
    text = "Thursday 12 November, 15:00 UTC, online.")
  let tile = r.el(event, "mailBox", [("background-color", "#1f6feb"),
    ("padding", "8px"), ("border-radius", "8px"), ("text-align", "center")])
  discard r.el(tile, "p", [("margin", "0"), ("color", "#ffffff"),
    ("font-size", "14px"), ("line-height", "20px")], text = "NOV")
  discard r.el(tile, "p", [("margin", "0"), ("color", "#ffffff"),
    ("font-size", "28px"), ("line-height", "32px"), ("font-weight", "700")],
    text = "12")
  r.footer(result)

proc sidebarRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("مراجع جديد", "صورة بجانب اسم.", true)
  r.heading(result, "مراجع جديد", "")
  let s = r.band(result)
  r.avatarRow(s, "أدا لوفليس", "مراجِعة")
  r.footer(result, rtl = true)

proc sidebarImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your reviewers", "Three avatars beside names.")
  r.heading(result, "Your reviewers", "")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  for (name, role) in [("Ada Lovelace", "Reviewer"),
      ("Grace Hopper", "Maintainer"), ("Alan Turing", "Guest")]:
    r.avatarRow(stack, name, role, "64px", "64px")
  r.footer(result)

proc sidebarDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("A note", "An accent beside a note, dark designed.")
  let s = r.dkBand(result, tok"color.surface.card")
  let sb = r.el(s, "mailSidebar", [("gap", "0")], [("fixed", "4px"),
    ("valign", "top")])
  let accent = r.el(sb, "div", [("font-size", "1px"), ("line-height", "1px")],
    text = "\u00a0")
  r.paint(accent, "background-color", tok"color.accent.primary")
  let note = r.el(sb, "mailBox", [("padding", "16px")])
  r.paint(note, "background-color", tok"color.status.info.bg")
  discard r.dkText(note, "p", "Note: maintenance on Sunday from 02:00 " &
    "to 03:00 UTC.", [("margin", "0")])
  r.dkFooter(result)

proc sidebarInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Shipped", "Items beside their thumbnails, between " &
    "a heading and a total.")
  r.heading(result, "Shipped", "Your order left the warehouse today.")
  let s = r.band(result, "#f4f5f7")
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  for (name, price) in [("Mountain print", "$24.00"),
      ("Castle badge", "$18.00")]:
    let sb = r.el(stack, "mailSidebar", attrs = [("fixed", "96px"),
      ("switch_below", "200px")])
    discard r.el(sb, "mailImage", [("width", "96px"), ("height",
      if name.startsWith("Mountain"): fixtureImageHeight("scene.png", 96)
      else: fixtureImageHeight("shield.png", 96))],
      [("src", if name.startsWith("Mountain"): fixtureImageUrl("scene.png")
        else: fixtureImageUrl("shield.png")), ("alt", name)])
    let w = r.el(sb, "mailStack", [("gap", "4px")])
    discard r.el(w, "p", [("margin", "0"), ("font-weight", "700")],
      text = name)
    discard r.el(w, "p", [("margin", "0")], text = price)
  discard r.el(stack, "p", [("margin", "0"), ("font-weight", "700"),
    ("text-align", "right")], text = "Total: $42.00")
  r.footer(result)

# --- Registration -----------------------------------------------------------

type PrimitiveStory = tuple[name, description: string;
  build: proc(): EmailNode {.nimcall.}; dark: bool]

let primitiveStories*: array[24, PrimitiveStory] = [
  ("boxMinimal", "mailBox with its defaults.", boxMinimalDoc, false),
  ("boxMaximal", "mailBox: bordered, rounded, shadowed, long content.",
    boxMaximalDoc, false),
  ("boxRtl", "mailBox in Arabic, right to left.", boxRtlDoc, false),
  ("boxImagesOff", "mailBox holding a picture (capture with images off).",
    boxImagesOffDoc, false),
  ("boxDark", "mailBox with its own dark colours.", boxDarkDoc, true),
  ("boxInContext", "mailBox between a paragraph and a cluster.",
    boxInContextDoc, false),
  ("gridMinimal", "mailGrid, two columns.", gridMinimalDoc, false),
  ("gridMaximal", "mailGrid, three columns, five cards, centred last row.",
    gridMaximalDoc, false),
  ("gridRtl", "mailGrid in Arabic.", gridRtlDoc, false),
  ("gridImagesOff", "mailGrid of six pictures (capture with images off).",
    gridImagesOffDoc, false),
  ("gridDark", "mailGrid, four numbers, two per row on a phone, dark.",
    gridDarkDoc, true),
  ("gridInContext", "mailGrid between a paragraph and a band, stretched " &
    "last row.", gridInContextDoc, false),
  ("clusterMinimal", "mailCluster of three links.", clusterMinimalDoc,
    false),
  ("clusterMaximal", "mailCluster of nine links, centred, separated.",
    clusterMaximalDoc, false),
  ("clusterRtl", "mailCluster in Arabic.", clusterRtlDoc, false),
  ("clusterImagesOff", "mailCluster of icons (capture with images off).",
    clusterImagesOffDoc, false),
  ("clusterDark", "mailCluster of badges, dark.", clusterDarkDoc, true),
  ("clusterInContext", "mailCluster in a footer.", clusterInContextDoc,
    false),
  ("sidebarMinimal", "mailSidebar: an avatar beside a name.",
    sidebarMinimalDoc, false),
  ("sidebarMaximal", "mailSidebar: a switching teaser and a date tile.",
    sidebarMaximalDoc, false),
  ("sidebarRtl", "mailSidebar in Arabic.", sidebarRtlDoc, false),
  ("sidebarImagesOff", "mailSidebar avatars (capture with images off).",
    sidebarImagesOffDoc, false),
  ("sidebarDark", "mailSidebar: an accent beside a note, dark.",
    sidebarDarkDoc, true),
  ("sidebarInContext", "mailSidebar items between a heading and a total.",
    sidebarInContextDoc, false),
]

proc groupOf(name: string): string =
  for prefix in ["box", "grid", "cluster", "sidebar"]:
    if name.startsWith(prefix):
      return prefix
  name

proc renderOf(build: proc(): EmailNode {.nimcall.};
    dark: bool): StoryRenderProc =
  ## One story's render closure. A proc of its own, so each closure
  ## captures its own story: a closure made in the loop below would
  ## share the loop's variables and render the last story every time.
  result = proc(): StoryHtml = render(build(), dark)

proc renderPrimitiveStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  for s in primitiveStories:
    if s.name == name:
      return render(s.build(), s.dark)
  raise newException(StoryError, "no primitive story '" & name & "'")

proc registerPrimitiveStories*() =
  ## Registers the primitives' story set (env-gated, see above).
  for s in primitiveStories:
    registerStory(Story(name: s.name, group: groupOf(s.name),
      description: s.description, render: renderOf(s.build, s.dark)))

proc registerPrimitiveStoryTrees*() =
  ## The trees the briefs of those stories render from.
  for s in primitiveStories:
    registerStoryTree(s.name, s.build,
      if s.dark: dmDesigned else: dmAccommodate)
