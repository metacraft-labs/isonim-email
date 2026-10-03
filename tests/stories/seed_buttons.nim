## Button stories: the story set of `mailButton`: `buttonMinimal` (the
## default button), `buttonMaximal` (sizes, every tone, the outline and
## link variants, full width, a label that wraps, the three
## alignments), `buttonVml` (rounded px-width buttons Word draws as a
## VML roundrect), `buttonSpacers` (the Word-spacers option), `buttonRtl`
## (Arabic, right to left), `buttonImagesOff` (buttons around a picture,
## captured with images blocked), `buttonDark` (`darkMode = designed`)
## and `buttonInContext` (in a box, beside each other in a cluster, in a
## column row and on a coloured band).
##
## Env-gated like the leaves' stories: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`, so bare runs, the capture regression
## matrix and the story-set pins never see them.
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

proc button(r: EmailRenderer; parent: EmailNode; label: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  var a = @[("href", "https://app.example.com/")]
  for x in attrs:
    a.add(x)
  r.el(parent, "mailButton", styles, a, label)

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
  discard r.el(p, "a", attrs = [("href", "https://example.com/unsubscribe")],
    text = if rtl: "إلغاء الاشتراك" else: "Unsubscribe")

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
  if n.tag in ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li",
      "mailButton"]:
    return inner.strip() & "\n"
  inner

proc render(doc: EmailNode; dark = false): StoryHtml =
  var t = defaultTarget()
  if dark:
    t.darkMode = dmDesigned
  let text = textOf(doc)
  (renderPipeline(doc, t), text)

proc buttonMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome, Ada", "Your account is ready.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Welcome, Ada")
  discard r.el(s, "p", text = "Your account is ready.")
  discard r.button(s, "Open dashboard")
  r.footer(result)

proc buttonMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Buttons", "Sizes, tones, variants, widths and " &
    "alignments.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Buttons")
  discard r.el(s, "p", text = "Small, default and large:")
  discard r.button(s, "Small", [("font-size", "14px"),
    ("padding", "13px 16px")])
  discard r.el(s, "mailSpacer", [("height", "12px")])
  discard r.button(s, "Default")
  discard r.el(s, "mailSpacer", [("height", "12px")])
  discard r.button(s, "Large", [("font-size", "20px"),
    ("line-height", "28px"), ("padding", "16px 32px")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "Every tone, solid:")
  let tones = r.el(s, "mailCluster", [("gap", "8px")])
  for tone in ["primary", "neutral", "info", "success", "warning",
      "danger"]:
    discard r.button(tones, tone.capitalizeAscii(), attrs = [("tone", tone)])
  discard r.el(s, "p", [("margin", "16px 0")], text = "Outline and link:")
  let vs = r.el(s, "mailCluster", [("gap", "8px")])
  discard r.button(vs, "Outline", attrs = [("variant", "outline")])
  discard r.button(vs, "Neutral outline", attrs = [("variant", "outline"),
    ("tone", "neutral")])
  discard r.button(vs, "Link", attrs = [("variant", "link")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "Full width, and a " &
    "long label in a 240px button, which wraps:")
  discard r.button(s, "Pay $42.00 now", [("width", "100%")])
  discard r.el(s, "mailSpacer", [("height", "12px")])
  discard r.button(s, "Confirm your email address and finish setting " &
    "up your account", [("width", "240px")], [("vml", "never")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "Centred and right:")
  discard r.button(s, "Centred", attrs = [("align", "center")])
  discard r.el(s, "mailSpacer", [("height", "12px")])
  discard r.button(s, "Right", attrs = [("align", "right")])
  discard r.el(s, "p", [("margin", "16px 0 0")], text = "This paragraph " &
    "follows the right-aligned button and starts below it.")
  r.footer(result)

proc buttonVmlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Rounded buttons for Outlook", "Fixed-width " &
    "buttons drawn as VML in Word.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Rounded buttons")
  discard r.el(s, "p", text = "A 220px rounded button (VML in Word):")
  discard r.button(s, "Start free trial", [("width", "220px")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "A pill, VML " &
    "always, centred:")
  discard r.button(s, "Book a demo", [("width", "200px"),
    ("border-radius", "22px")], [("vml", "always"), ("align", "center")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "An outline, 260px, " &
    "48px tall:")
  discard r.button(s, "Read the changelog", [("width", "260px"),
    ("height", "48px")], [("variant", "outline")])
  discard r.el(s, "p", [("margin", "16px 0 0")], text = "The end.")
  r.footer(result)

proc buttonSpacersDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Word spacers", "Buttons whose padding Word " &
    "gets from spacers.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Spacer buttons")
  discard r.el(s, "p", text = "The default button with Word spacers:")
  discard r.button(s, "Open dashboard", attrs = [("word_padding",
    "spacers")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "Large, centred:")
  discard r.button(s, "Get started", [("font-size", "20px"),
    ("line-height", "28px"), ("padding", "16px 32px")],
    [("word_padding", "spacers"), ("align", "center")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "Outline:")
  discard r.button(s, "Contact sales", attrs = [("word_padding", "spacers"),
    ("variant", "outline")])
  discard r.el(s, "p", [("margin", "16px 0 0")], text = "The end.")
  r.footer(result)

proc buttonRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("أزرار", "زر افتراضي وزر مستدير وزر بفواصل.", true)
  let s = r.band(result)
  discard r.el(s, "h1", text = "مرحبًا بك")
  discard r.el(s, "p", text = "حسابك جاهز.")
  discard r.button(s, "افتح لوحة التحكم")
  discard r.el(s, "p", [("margin", "16px 0")], text = "زر مستدير بعرض ثابت:")
  discard r.button(s, "ابدأ التجربة", [("width", "220px")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "زر بفواصل وزر محدد:")
  discard r.button(s, "تواصل معنا", attrs = [("word_padding", "spacers")])
  discard r.el(s, "mailSpacer", [("height", "12px")])
  discard r.button(s, "اقرأ المزيد", attrs = [("variant", "outline")])
  r.footer(result, rtl = true)

proc buttonImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your photos are ready", "A picture and the " &
    "buttons under it.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Your photos are ready")
  discard r.el(s, "mailImage", [("width", "280px"),
    ("height", fixtureImageHeight("scene.png", 280))],
    [("src", fixtureImageUrl("scene.png")), ("alt", "The hill at dawn")])
  discard r.el(s, "p", [("margin", "16px 0")], text = "Twelve new photos " &
    "from your trip.")
  discard r.button(s, "View the album")
  let b = r.band(result, "#1f6feb", "24px 0")
  discard r.el(b, "p", [("color", "#ffffff"), ("margin", "0 0 16px")],
    text = "Share it with your family.")
  discard r.button(b, "Share", [("background-color", "#ffffff"),
    ("color", "#1f6feb")])
  r.footer(result)

proc buttonDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.el(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", "Buttons, dark"), ("preheader",
      "The default buttons in their dark colours.")])
  r.setStyle(result, "background-color", tok"color.surface.canvas")
  r.setStyle(result, "@dark:background-color", tok"color.surface.canvas")
  let s = r.el(result, "mailSection", [("padding", "24px 0")])
  r.setStyle(s, "background-color", tok"color.surface.card")
  r.setStyle(s, "@dark:background-color", tok"color.surface.card")
  let h = r.el(s, "h1", text = "Buttons, dark")
  r.setStyle(h, "color", tok"color.text.primary")
  r.setStyle(h, "@dark:color", tok"color.text.primary")
  let p = r.el(s, "p", text = "Solid, outline and link, each with its " &
    "dark pair:")
  r.setStyle(p, "color", tok"color.text.primary")
  r.setStyle(p, "@dark:color", tok"color.text.primary")
  let c = r.el(s, "mailCluster", [("gap", "8px")])
  discard r.button(c, "Open dashboard")
  discard r.button(c, "Outline", attrs = [("variant", "outline")])
  discard r.button(c, "Link", attrs = [("variant", "link")])
  discard r.el(s, "mailSpacer", [("height", "16px")])
  discard r.button(s, "Delete project", attrs = [("tone", "danger")])

proc buttonInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Invoice #2041", "Buttons in a box, a cluster, a " &
    "row of columns and a band.")
  let s = r.band(result)
  discard r.el(s, "h1", text = "Invoice #2041")
  let box = r.el(s, "mailBox", [("background-color", "#f8f9fb"),
    ("border-radius", "8px")])
  discard r.el(box, "p", text = "Team plan, October: $120.00, due on " &
    "1 November.")
  let c = r.el(box, "mailCluster", [("gap", "12px")])
  discard r.button(c, "Pay now")
  discard r.button(c, "Download PDF", attrs = [("variant", "outline")])
  discard r.el(s, "mailSpacer", [("height", "24px")])
  let cols = r.el(s, "mailColumns", attrs = [("strategy", "hybrid")])
  let c1 = r.el(cols, "mailColumn")
  discard r.el(c1, "h2", text = "Billing")
  discard r.el(c1, "p", text = "Change the card or the address.")
  discard r.button(c1, "Billing settings", [("width", "100%")],
    [("tone", "neutral")])
  let c2 = r.el(cols, "mailColumn")
  discard r.el(c2, "h2", text = "Questions")
  discard r.el(c2, "p", text = "Our team answers within a day.")
  discard r.button(c2, "Contact us", [("width", "100%")],
    [("variant", "outline")])
  let b = r.band(result, "#111827", "24px 0")
  r.setStyle(b, "text-align", "center")
  discard r.el(b, "p", [("color", "#f9fafb"), ("margin", "0 0 16px")],
    text = "Upgrade to the business plan for single sign-on.")
  discard r.button(b, "See plans", [("background-color", "#ffffff"),
    ("color", "#111827")], [("align", "center")])
  r.footer(result)

# --- Registration -----------------------------------------------------------

type ButtonStory = tuple[name, description: string;
  build: proc(): EmailNode {.nimcall.}; dark: bool]

let buttonStories*: array[8, ButtonStory] = [
  ("buttonMinimal", "mailButton with its defaults.", buttonMinimalDoc,
    false),
  ("buttonMaximal", "Sizes, tones, outline and link, full width, a " &
    "wrapping label, alignments.", buttonMaximalDoc, false),
  ("buttonVml", "Rounded fixed-width buttons (a VML roundrect in Word).",
    buttonVmlDoc, false),
  ("buttonSpacers", "The Word-spacers option.", buttonSpacersDoc, false),
  ("buttonRtl", "Buttons in Arabic, right to left.", buttonRtlDoc, false),
  ("buttonImagesOff", "Buttons around a picture (capture with images " &
    "off).", buttonImagesOffDoc, false),
  ("buttonDark", "Buttons in their dark colours.", buttonDarkDoc, true),
  ("buttonInContext", "Buttons in a box, a cluster, columns and a band.",
    buttonInContextDoc, false),
]

proc renderOf(build: proc(): EmailNode {.nimcall.};
    dark: bool): StoryRenderProc =
  ## One story's render closure, in a proc of its own so each closure
  ## captures its own story.
  result = proc(): StoryHtml = render(build(), dark)

proc renderButtonStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  for s in buttonStories:
    if s.name == name:
      return render(s.build(), s.dark)
  raise newException(StoryError, "no button story '" & name & "'")

proc registerButtonStories*() =
  ## Registers the buttons' story set (env-gated, see above).
  for s in buttonStories:
    registerStory(Story(name: s.name, group: "button",
      description: s.description, render: renderOf(s.build, s.dark)))

proc registerButtonStoryTrees*() =
  ## The trees the briefs of those stories render from.
  for s in buttonStories:
    registerStoryTree(s.name, s.build)
