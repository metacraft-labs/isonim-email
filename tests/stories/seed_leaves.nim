## Content leaf stories: the story set of the text leaves (`h1`–`h6`,
## `p`, `a`, lists, `mailText`), `mailImage`, `mailSpacer` and
## `mailDivider`: for each, `Minimal` (required props only), `Maximal`
## (every prop, the longest realistic content), `Rtl` (Arabic, right to
## left), `ImagesOff` (content with images, captured with images
## blocked), `Dark` (`darkMode = designed`, with dark colours) and
## `InContext` (between two different neighbours in a band).
##
## Env-gated like the primitives' stories: the drivers register them
## only under `ISONIM_CAPTURE_LAYOUT=1`, so bare runs, the capture
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

proc txt(r: EmailRenderer; parent: EmailNode; s: string) =
  r.appendChild(parent, r.createTextNode(s))

proc link(r: EmailRenderer; parent: EmailNode; href, s: string;
    styles: openArray[(string, string)] = []): EmailNode =
  r.el(parent, "a", styles, [("href", href)], s)

proc storyDoc(r: EmailRenderer; title, preheader: string;
    rtl = false): EmailNode =
  result = r.el(nil, "mailDocument", [("background-color", "#f4f5f7")],
    [("lang", if rtl: "ar" else: "en"), ("dir", if rtl: "rtl" else: "ltr"),
      ("title", title), ("preheader", preheader)])

proc band(r: EmailRenderer; doc: EmailNode; bg = "#ffffff";
    padding = "24px 0"): EmailNode =
  r.el(doc, "mailSection", [("background-color", bg), ("padding", padding)])

proc footer(r: EmailRenderer; doc: EmailNode; rtl = false) =
  let f = r.el(doc, "mailSection", [("background-color", "#1f2937"),
    ("text-align", "center")], [("full_width", "true")])
  let p = r.el(f, "p", [("color", "#f9fafb")])
  r.txt(p, if rtl: "شركة أكمي، ١ شارع المثال، الرياض · " else:
    "Acme Inc., 1 Example Street, Springfield · ")
  discard r.link(p, "https://example.com/unsubscribe",
    if rtl: "إلغاء الاشتراك" else: "Unsubscribe")

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
  if n.tag in ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "pre",
      "blockquote"]:
    return inner.strip() & "\n"
  inner

proc render(doc: EmailNode; dark = false): StoryHtml =
  var t = defaultTarget()
  if dark:
    t.darkMode = dmDesigned
  let text = textOf(doc)
  (renderPipeline(doc, t), text)

# Dark stories (`darkMode = designed`): every colour is a theme token
# with its dark pair, the document's canvas included.

proc paint(r: EmailRenderer; n: EmailNode; prop: string; t: TokenRef) =
  r.setStyle(n, prop, t)
  r.setStyle(n, "@dark:" & prop, t)

proc dkDoc(r: EmailRenderer; title, preheader: string): EmailNode =
  result = r.el(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", title), ("preheader", preheader)])
  r.paint(result, "background-color", tok"color.surface.canvas")

proc dkBand(r: EmailRenderer; doc: EmailNode;
    surface = tok"color.surface.card"): EmailNode =
  result = r.el(doc, "mailSection", [("padding", "24px 0")])
  r.paint(result, "background-color", surface)

proc dkFooter(r: EmailRenderer; doc: EmailNode) =
  let f = r.dkBand(doc, tok"color.surface.subtle")
  r.setStyle(f, "text-align", "center")
  let p = r.el(f, "p")
  r.paint(p, "color", tok"color.text.secondary")
  r.txt(p, "Acme Inc., 1 Example Street, Springfield · ")
  discard r.link(p, "https://example.com/unsubscribe", "Unsubscribe")

proc img(r: EmailRenderer; parent: EmailNode; name: static string;
    width: int; alt: string; attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []): EmailNode =
  var s = @[("width", $width & "px"),
    ("height", fixtureImageHeight(name, width))]
  for x in styles:
    s.add(x)
  var a = @[("src", fixtureImageUrl(name)), ("alt", alt)]
  for x in attrs:
    a.add(x)
  r.el(parent, "mailImage", s, a)

const longWord = "Supercalifragilisticexpialidociousnessless"
  ## A long unbroken word (the maximal stories' wrapping check).

# --- Text leaves ------------------------------------------------------------

proc textMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome aboard", "A heading, two paragraphs, a link.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Welcome aboard")
  discard r.el(s, "p", text = "Your workspace is ready. Everything you " &
    "set up during the trial is still there.")
  let p = r.el(s, "p")
  r.txt(p, "Questions? Read the ")
  discard r.link(p, "https://example.com/guide", "getting-started guide")
  r.txt(p, " or reply to this message.")
  r.footer(result)

proc textMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Release notes: version 2.7",
    "Every text element, with its defaults and a few of its own.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Release notes: version 2.7, the " &
    "long-awaited single sign-on release")
  let intro = r.el(s, "p")
  r.txt(intro, "This release brings ")
  discard r.el(intro, "strong", text = "single sign-on")
  r.txt(intro, ", a faster editor and ")
  discard r.el(intro, "em", text = "many")
  r.txt(intro, " small fixes. The full list is on the ")
  discard r.link(intro, "https://example.com/changelog", "changelog page")
  r.txt(intro, ".")
  discard r.el(s, "h2", text = "What is new")
  let ul = r.el(s, "ul")
  discard r.el(ul, "li", text = "Single sign-on with any SAML 2.0 " &
    "identity provider, configured from the admin page in a few minutes.")
  discard r.el(ul, "li", text = "The editor opens large files twice as " &
    "fast.")
  discard r.el(ul, "li", text = "Reference: " & longWord)
  discard r.el(s, "h3", text = "Upgrading")
  let ol = r.el(s, "ol")
  discard r.el(ol, "li", text = "Back up your workspace.")
  discard r.el(ol, "li", text = "Install version 2.7 and restart.")
  discard r.el(ol, "li", text = "Sign in again with your provider.")
  discard r.el(s, "h4", text = "Known issues")
  discard r.el(s, "p", text = "Older browsers may need a refresh after " &
    "the first sign-in.")
  discard r.el(s, "h5", text = "Deprecations")
  discard r.el(s, "p", text = "The legacy token API stops on 1 March.")
  discard r.el(s, "h6", text = "Credits")
  discard r.el(s, "blockquote", text = "\"The sign-on setup took us four " &
    "minutes.\" A customer")
  discard r.el(s, "pre", text = "acme upgrade --to 2.7")
  let t = r.el(s, "mailText", [("padding", "16px"),
    ("font-size", "14px"), ("color", "#4b5563"),
    ("background-color", "#f8f9fb")], [("align", "left")])
  discard r.el(t, "p", text = "A mailText block: smaller type and a " &
    "secondary colour its paragraphs inherit.")
  let p = r.el(t, "p")
  r.txt(p, "Its links inherit the colour too: ")
  discard r.link(p, "https://example.com/help", "help centre")
  r.txt(p, ".")
  r.footer(result)

proc textRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("مرحبًا بك", "عنوان وفقرة وقائمة.", true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "مرحبًا بك في مساحة العمل")
  let p = r.el(s, "p")
  r.txt(p, "مساحة عملك جاهزة. اقرأ ")
  discard r.link(p, "https://example.com/guide", "دليل البدء")
  r.txt(p, " للتعرف على الخطوات الأولى.")
  discard r.el(s, "h2", text = "الخطوات التالية")
  let ul = r.el(s, "ul")
  discard r.el(ul, "li", text = "ادعُ فريقك.")
  discard r.el(ul, "li", text = "أنشئ مشروعك الأول.")
  discard r.el(ul, "li", text = "اربط مستودعك.")
  discard r.el(s, "p", text = "شكرًا لاختيارك أكمي.")
  r.footer(result, rtl = true)

proc textImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your order has shipped",
    "Text around a logo and a picture.")
  let head = r.band(result, padding = "24px 0 0")
  discard r.img(head, "logo.png", 120, "Acme")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Your order has shipped")
  discard r.el(s, "p", text = "The parcel left our warehouse this " &
    "morning and should reach you in two days.")
  discard r.img(s, "scene.png", 280, "The mountain print you ordered")
  discard r.el(s, "mailSpacer")
  let p = r.el(s, "p")
  r.txt(p, "Follow it on the ")
  discard r.link(p, "https://example.com/track", "tracking page")
  r.txt(p, ".")
  r.footer(result)

proc textDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your weekly summary", "Text in its dark colours.")
  let s = r.dkBand(result)
  discard r.el(s, "h1", text = "Your weekly summary")
  discard r.el(s, "p", text = "Twelve builds passed and four reviews " &
    "are waiting for you.")
  let ul = r.el(s, "ul")
  discard r.el(ul, "li", text = "Build 412 passed.")
  discard r.el(ul, "li", text = "Review #88 needs your approval.")
  let p = r.el(s, "p")
  r.txt(p, "See everything on your ")
  discard r.link(p, "https://example.com/dashboard", "dashboard")
  r.txt(p, ".")
  let note = r.el(s, "p", [("font-size", "14px")],
    text = "You get this summary every Monday.")
  r.paint(note, "color", tok"color.text.secondary")
  r.dkFooter(result)

proc textInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Invoice #2041", "Text in a box between a header " &
    "and two columns.")
  let head = r.band(result, "#1f6feb", "16px 0")
  discard r.el(head, "p", [("color", "#ffffff"), ("font-weight", "700")],
    text = "Acme Billing")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Invoice #2041")
  let box = r.el(s, "mailBox", [("background-color", "#f8f9fb"),
    ("border-radius", "8px")])
  discard r.el(box, "h2", text = "Summary")
  discard r.el(box, "p", text = "Team plan, October: $120.00. Paid with " &
    "the card ending 4242.")
  let p = r.el(box, "p")
  discard r.link(p, "https://example.com/invoice/2041", "Download the PDF")
  discard r.el(s, "mailSpacer", [("height", "24px")])
  let cols = r.el(s, "mailColumns", attrs = [("strategy", "hybrid")])
  let c1 = r.el(cols, "mailColumn")
  discard r.el(c1, "h3", text = "Billing address")
  discard r.el(c1, "p", text = "1 Example Street, Springfield")
  let c2 = r.el(cols, "mailColumn")
  discard r.el(c2, "h3", text = "Questions")
  let q = r.el(c2, "p")
  discard r.link(q, "mailto:billing@example.com", "billing@example.com")
  r.footer(result)

# --- mailImage --------------------------------------------------------------

proc imageMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A logo", "One image with its required props.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "A logo")
  discard r.img(s, "logo.png", 120, "Acme")
  r.footer(result)

proc imageMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Autumn collection", "Every image prop: fluid, " &
    "linked, aligned, rounded, full width on a phone.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Autumn collection")
  # Fluid: as wide as its box.
  discard r.img(s, "scene.png", 552, "Hills under a yellow sun, the " &
    "collection's cover", attrs = [("href", "https://example.com/autumn")])
  discard r.el(s, "p", [("margin", "16px 0")],
    text = "Below: a half-width picture, a right-aligned rounded one, " &
      "and one that fills a phone's width.")
  discard r.el(s, "mailImage", [("width", "50%")],
    [("src", fixtureImageUrl("scene.png")), ("alt", "The hill at noon")])
  discard r.el(s, "mailSpacer")
  discard r.img(s, "scene.png", 200, "The hill at dusk",
    attrs = [("align", "right")], styles = [("border-radius", "12px")])
  discard r.el(s, "mailSpacer")
  discard r.img(s, "scene.png", 240, "The hill at dawn",
    attrs = [("fluid_on_mobile", "true")])
  r.footer(result)

proc imageRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("مجموعة الخريف", "صورة من اليمين إلى اليسار.", true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "مجموعة الخريف")
  discard r.img(s, "logo.png", 120, "أكمي")
  discard r.el(s, "mailSpacer")
  discard r.el(s, "p", text = "صورة الغلاف بعرض الصندوق:")
  discard r.img(s, "scene.png", 552, "تلال تحت شمس صفراء")
  r.footer(result, rtl = true)

proc imageImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Images off", "Images of every size, captured " &
    "with images blocked.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "What is inside")
  discard r.img(s, "scene.png", 552, "Hills under a yellow sun, the " &
    "cover picture")
  discard r.el(s, "mailSpacer")
  discard r.img(s, "scene.png", 280, "A green hill under a yellow sun")
  discard r.el(s, "mailSpacer")
  let g = r.el(s, "mailGrid", attrs = [("columns", "3"), ("gutter", "8px"),
    ("align", "center")])
  for alt in ["The hill at dawn", "The hill at noon", "The hill at dusk"]:
    discard r.img(g, "scene.png", 160, alt)
  discard r.el(s, "mailSpacer")
  let badges = r.el(s, "mailCluster", [("gap", "16px")],
    [("align", "center")])
  for name in ["Security", "Support", "Uptime"]:
    discard r.img(badges, "shield.png", 48, name)
  discard r.el(s, "mailSpacer")
  let icons = r.el(s, "mailCluster", [("gap", "16px")],
    [("align", "center")])
  for (i, name) in [(0, "Mastodon"), (1, "GitHub"), (2, "YouTube"),
      (3, "Blog")]:
    let a = r.el(icons, "a", attrs = [("href", "https://example.com/s" & $i)])
    discard r.img(a, "shield.png", 32, name)
  r.footer(result)

proc imageDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Autumn collection", "Images on dark surfaces.")
  let s = r.dkBand(result)
  let h = r.el(s, "h1", text = "Autumn collection")
  r.paint(h, "color", tok"color.text.primary")
  discard r.img(s, "logo.png", 120, "Acme")
  discard r.el(s, "mailSpacer")
  discard r.img(s, "scene.png", 552, "Hills under a yellow sun")
  r.dkFooter(result)

proc imageInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("From the blog", "An image in a box between a " &
    "heading and a teaser.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "From the blog")
  let box = r.el(s, "mailBox", [("border", "1px solid #e5e7eb"),
    ("border-radius", "8px")])
  discard r.img(box, "scene.png", 504, "A green hill under a yellow sun",
    attrs = [("href", "https://example.com/post")])
  discard r.el(box, "h2", [("margin", "16px 0 8px")],
    text = "Walking the hills")
  discard r.el(box, "p", text = "Three days, forty kilometres and one " &
    "very patient dog.")
  discard r.el(s, "mailSpacer", [("height", "24px")])
  let sb = r.el(s, "mailSidebar", [("gap", "16px")],
    [("fixed", "96px"), ("valign", "middle")])
  discard r.img(sb, "shield.png", 96, "The castle crest")
  discard r.el(sb, "p", text = "Next week: the castle, its gate and its " &
    "towers.")
  r.footer(result)

# --- mailSpacer -------------------------------------------------------------

proc spacerMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A spacer", "Two paragraphs 16 pixels apart.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "A spacer")
  discard r.el(s, "p", [("margin", "0")], text = "Above the spacer.")
  discard r.el(s, "mailSpacer")
  discard r.el(s, "p", [("margin", "0")], text = "Below the spacer, " &
    "16 pixels lower.")
  r.footer(result)

proc spacerMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Spacers", "Spacers of 4, 24 and 64 pixels between " &
    "tinted bands.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Spacers")
  for h in [4, 24, 64]:
    discard r.el(s, "p", [("margin", "0"), ("background-color", "#eff6ff")],
      text = "A " & $h & "-pixel spacer follows.")
    discard r.el(s, "mailSpacer", [("height", $h & "px")])
  discard r.el(s, "p", [("margin", "0"), ("background-color", "#eff6ff")],
    text = "The end.")
  r.footer(result)

proc spacerRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("فاصل", "فقرتان بينهما فاصل.", true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "فاصل")
  discard r.el(s, "p", [("margin", "0")], text = "فوق الفاصل.")
  discard r.el(s, "mailSpacer", [("height", "32px")])
  discard r.el(s, "p", [("margin", "0")], text = "تحت الفاصل.")
  r.footer(result, rtl = true)

proc spacerImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Pictures apart", "Two pictures with a spacer " &
    "between them.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Pictures apart")
  discard r.img(s, "scene.png", 280, "The hill at dawn")
  discard r.el(s, "mailSpacer", [("height", "24px")])
  discard r.img(s, "scene.png", 280, "The hill at dusk")
  r.footer(result)

proc spacerDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("A spacer", "A spacer on a dark surface.")
  let s = r.dkBand(result)
  let h = r.el(s, "h1", text = "A spacer")
  r.paint(h, "color", tok"color.text.primary")
  discard r.el(s, "p", [("margin", "0")], text = "Above the spacer.")
  discard r.el(s, "mailSpacer", [("height", "32px")])
  discard r.el(s, "p", [("margin", "0")], text = "Below the spacer.")
  r.dkFooter(result)

proc spacerInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Reset your password", "A spacer between a " &
    "paragraph and a box.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Reset your password")
  discard r.el(s, "p", [("margin", "0")], text = "Use this code within " &
    "ten minutes:")
  discard r.el(s, "mailSpacer", [("height", "24px")])
  let box = r.el(s, "mailBox", [("background-color", "#f8f9fb"),
    ("text-align", "center")])
  discard r.el(box, "p", [("font-size", "28px"), ("font-weight", "700"),
    ("letter-spacing", "4px")], text = "482 913")
  discard r.el(s, "mailSpacer", [("height", "24px")])
  discard r.el(s, "p", text = "If you did not ask for this, ignore " &
    "this message.")
  r.footer(result)

# --- mailDivider ------------------------------------------------------------

proc dividerMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A divider", "Two paragraphs and a line between.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "A divider")
  discard r.el(s, "p", [("margin", "0")], text = "Above the line.")
  discard r.el(s, "mailDivider")
  discard r.el(s, "p", [("margin", "0")], text = "Below the line.")
  r.footer(result)

proc dividerMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Dividers", "Dividers with every prop: border, " &
    "padding, width and alignment.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Dividers")
  discard r.el(s, "p", [("margin", "0")], text = "A 2px dashed blue line, " &
    "24 pixels above and below:")
  discard r.el(s, "mailDivider", [("border", "2px dashed #1f6feb"),
    ("padding", "24px 0")])
  discard r.el(s, "p", [("margin", "0")], text = "A half-width line, " &
    "aligned left:")
  discard r.el(s, "mailDivider", [("width", "50%")], [("align", "left")])
  discard r.el(s, "p", [("margin", "0")], text = "A 120px line, centred, " &
    "dotted:")
  discard r.el(s, "mailDivider", [("width", "120px"),
    ("border", "3px dotted #9ca3af")])
  discard r.el(s, "p", [("margin", "0")], text = "The end.")
  r.footer(result)

proc dividerRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("خط فاصل", "فقرتان بينهما خط.", true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "خط فاصل")
  discard r.el(s, "p", [("margin", "0")], text = "فوق الخط.")
  discard r.el(s, "mailDivider", [("width", "50%")], [("align", "right")])
  discard r.el(s, "p", [("margin", "0")], text = "تحت الخط.")
  r.footer(result, rtl = true)

proc dividerImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Two pictures", "A line between two pictures.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Two pictures")
  discard r.img(s, "scene.png", 280, "The hill at dawn")
  discard r.el(s, "mailDivider")
  discard r.img(s, "scene.png", 280, "The hill at dusk")
  r.footer(result)

proc dividerDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("A divider", "The default line in its dark colour.")
  let s = r.dkBand(result)
  let h = r.el(s, "h1", text = "A divider")
  r.paint(h, "color", tok"color.text.primary")
  discard r.el(s, "p", [("margin", "0")], text = "Above the line.")
  discard r.el(s, "mailDivider")
  discard r.el(s, "p", [("margin", "0")], text = "Below the line.")
  r.dkFooter(result)

proc dividerInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Receipt #1234", "Lines between the items of a " &
    "receipt in a box.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Receipt #1234")
  let box = r.el(s, "mailBox", [("border", "1px solid #e5e7eb")])
  for (item, price) in [("Mountain print", "$24.00"),
      ("Castle badge", "$18.00")]:
    discard r.el(box, "p", [("margin", "0")], text = item & ": " & price)
    discard r.el(box, "mailDivider", [("padding", "12px 0")])
  discard r.el(box, "p", [("margin", "0"), ("font-weight", "700")],
    text = "Total: $42.00")
  discard r.el(s, "p", [("margin", "16px 0 0")],
    text = "Thank you for your order.")
  r.footer(result)

# --- Registration -----------------------------------------------------------

type LeafStory = tuple[name, description: string;
  build: proc(): EmailNode {.nimcall.}; dark: bool]

let leafStories*: array[24, LeafStory] = [
  ("textMinimal", "Text leaves with their defaults.", textMinimalDoc, false),
  ("textMaximal", "Every text element, lists, a quote, mailText.",
    textMaximalDoc, false),
  ("textRtl", "Text leaves in Arabic, right to left.", textRtlDoc, false),
  ("textImagesOff", "Text around a logo and a picture (capture with " &
    "images off).", textImagesOffDoc, false),
  ("textDark", "Text leaves in their dark colours.", textDarkDoc, true),
  ("textInContext", "Text in a box and two columns.", textInContextDoc,
    false),
  ("imageMinimal", "mailImage, a logo.", imageMinimalDoc, false),
  ("imageMaximal", "mailImage: fluid, linked, aligned, rounded, full " &
    "width on a phone.", imageMaximalDoc, false),
  ("imageRtl", "mailImage in Arabic.", imageRtlDoc, false),
  ("imageImagesOff", "mailImage of every size (capture with images off).",
    imageImagesOffDoc, false),
  ("imageDark", "mailImage on dark surfaces.", imageDarkDoc, true),
  ("imageInContext", "mailImage in a box and a sidebar.",
    imageInContextDoc, false),
  ("spacerMinimal", "mailSpacer with its default height.",
    spacerMinimalDoc, false),
  ("spacerMaximal", "mailSpacer: 4, 24 and 64 pixels.", spacerMaximalDoc,
    false),
  ("spacerRtl", "mailSpacer in Arabic.", spacerRtlDoc, false),
  ("spacerImagesOff", "mailSpacer between pictures (capture with images " &
    "off).", spacerImagesOffDoc, false),
  ("spacerDark", "mailSpacer, dark.", spacerDarkDoc, true),
  ("spacerInContext", "mailSpacer around a code box.", spacerInContextDoc,
    false),
  ("dividerMinimal", "mailDivider with its defaults.", dividerMinimalDoc,
    false),
  ("dividerMaximal", "mailDivider: border, padding, width, alignment.",
    dividerMaximalDoc, false),
  ("dividerRtl", "mailDivider in Arabic, a half-width line on the right.",
    dividerRtlDoc, false),
  ("dividerImagesOff", "mailDivider between pictures (capture with " &
    "images off).", dividerImagesOffDoc, false),
  ("dividerDark", "mailDivider in its dark colour.", dividerDarkDoc, true),
  ("dividerInContext", "mailDivider between receipt lines in a box.",
    dividerInContextDoc, false),
]

proc groupOf(name: string): string =
  for prefix in ["text", "image", "spacer", "divider"]:
    if name.startsWith(prefix):
      return prefix
  name

proc renderOf(build: proc(): EmailNode {.nimcall.};
    dark: bool): StoryRenderProc =
  ## One story's render closure, in a proc of its own so each closure
  ## captures its own story (a closure made in a loop shares the loop's
  ## variables).
  result = proc(): StoryHtml = render(build(), dark)

proc renderLeafStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  for s in leafStories:
    if s.name == name:
      return render(s.build(), s.dark)
  raise newException(StoryError, "no leaf story '" & name & "'")

proc registerLeafStories*() =
  ## Registers the leaves' story set (env-gated, see above).
  for s in leafStories:
    registerStory(Story(name: s.name, group: groupOf(s.name),
      description: s.description, render: renderOf(s.build, s.dark)))

proc registerLeafStoryTrees*() =
  ## The trees the briefs of those stories render from.
  for s in leafStories:
    registerStoryTree(s.name, s.build)
