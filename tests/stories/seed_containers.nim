## Container pattern stories: the story sets of `mailCard`,
## `mailCallout`, `mailCodeBlock`, `codeInline` and `mailQuote`
## (layout-patterns.md §5): for each, `Minimal` (required props only),
## `Maximal` (every prop, the longest realistic content, long unbroken
## words), `Rtl` (Arabic, right to left), `ImagesOff` (content with
## images, captured with images blocked), `Dark` (`darkMode = designed`,
## every colour a theme token with its dark pair) and `InContext`
## (between two different neighbours).
##
## The card photos are the compile-time `photo-*.png` placeholders
## (cropped by the asset pass); the avatars are
## `tests/stories/assets/avatar-*.png` (192×192 circular PNGs, a
## silhouette, transparent outside the circle) and the callout icon
## `shield.png`, on the capture fixture host.
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images
import story_kit

let
  coast = $asset"assets/photo-coast.png"
  forest = $asset"assets/photo-forest.png"
  lake = $asset"assets/photo-lake.png"

proc intro(r: EmailRenderer; doc: EmailNode; title, body: string;
    bg = "#ffffff") =
  let s = r.band(doc, bg, "24px 0 8px")
  discard r.el(s, "h1", text = title)
  if body.len > 0:
    discard r.el(s, "p", [("margin", "0")], text = body)

proc para(r: EmailRenderer; parent: EmailNode; text: string;
    last = true): EmailNode =
  r.el(parent, "p", if last: @[("margin", "0")] else: @[], text = text)

# --- mailCard -------------------------------------------------------------------

proc cardMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your plan", "A card with its body only.")
  r.intro(result, "Your plan", "")
  let s = r.band(result, "#f4f5f7")
  let c = r.el(s, "mailCard")
  discard r.para(c, "Your plan renews on 1 November. Nothing to do.")
  r.footer(result)

proc cardMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Picked for you", "A card with every prop.")
  r.intro(result, "Picked for you", "An elevated card with an image " &
    "cropped to 16:9, a long title, its text and a button.", "#f4f5f7")
  let s = r.band(result, "#f4f5f7")
  discard r.el(s, "h2", text = "This week")
  let c = r.el(s, "mailCard", attrs = [("title", "Two nights by the " &
    "coast, with breakfast and a guided walk on Sunday morning"),
    ("level", "h3"), ("image", coast), ("image_alt", "The coast at low tide"),
    ("image_ratio", "16:9"), ("cta", "See the dates"),
    ("cta_href", "https://example.com/coast"), ("variant", "elevated")])
  discard r.para(c, "A cottage above the harbour, breakfast at the pier " &
    "café and a walk to the lighthouse with a local guide. Booking " &
    "reference " & longWord & ".")
  r.footer(result)

proc cardRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("خطتك", "بطاقة من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "خطتك", "")
  let s = r.band(result, "#f4f5f7")
  discard r.el(s, "h2", text = "التجديد")
  let c = r.el(s, "mailCard", attrs = [("title", "تتجدد خطتك قريبا"),
    ("cta", "إدارة الخطة"), ("cta_href", "https://example.com/plan")])
  discard r.para(c, "تتجدد خطتك في الأول من نوفمبر. لا حاجة لأي إجراء.")
  r.footer(result, rtl = true)

proc cardImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Two trips", "Cards with images blocked.")
  r.intro(result, "Two trips", "With images blocked, each card's image " &
    "shows its alt text above the title.", "#f4f5f7")
  let s = r.band(result, "#f4f5f7")
  discard r.el(s, "h2", text = "Coming up")
  let grid = r.el(s, "mailGrid", attrs = [("columns", "2"),
    ("gutter", "16px")])
  for (img, alt, title) in [(forest, "Pines above a cabin", "The forest"),
      (lake, "A lake at dawn", "The lake")]:
    let c = r.el(grid, "mailCard", attrs = [("title", title), ("image", img),
      ("image_alt", alt), ("image_ratio", "4:3"), ("cta", "Book"),
      ("cta_href", "https://example.com/book")])
    discard r.para(c, "Two nights, breakfast included.")
  r.footer(result)

proc cardDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your plan, dark", "A card in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.canvas")
  discard r.dkText(s, "h1", "Your plan, dark")
  discard r.dkText(s, "h2", "Renewal")
  let c = r.el(s, "mailCard", attrs = [("title", "Renews on 1 November"),
    ("cta", "Manage plan"), ("cta_href", "https://example.com/plan"),
    ("variant", "elevated")])
  discard r.dkText(c, "p", "The card and its border take their dark " &
    "pairs.", [("margin", "0")], tok"color.text.secondary")
  r.dkFooter(result)

proc cardInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("What's new", "Cards between a band and a button.")
  let b = r.el(result, "mailBand", [("background-color", "#0b3a6e"),
    ("padding", "32px 0")])
  discard r.el(b, "h1", [("color", "#ffffff")], text = "What's new")
  discard r.el(b, "p", [("color", "#ffffff"), ("margin", "0")],
    text = "Two changes this month.")
  let s = r.band(result, "#f4f5f7")
  discard r.el(s, "h2", text = "Changes")
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  for (title, text) in [("Faster exports", "Exports now finish in half " &
      "the time."), ("Shared folders", "Invite a team to a folder.")]:
    let c = r.el(stack, "mailCard", attrs = [("title", title)])
    discard r.para(c, text)
  let after = r.band(result)
  discard r.el(after, "mailButton", attrs = [("href",
    "https://example.com/changelog")], text = "Read the changelog")
  r.footer(result)

# --- mailCallout ----------------------------------------------------------------

proc calloutMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Maintenance", "A callout with its body only.")
  r.intro(result, "Maintenance", "")
  let s = r.band(result)
  let c = r.el(s, "mailCallout")
  discard r.para(c, "The service is read-only on Sunday from 02:00 to " &
    "03:00 UTC.")
  r.footer(result)

proc calloutMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Account security", "Every callout prop.")
  r.intro(result, "Account security", "")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  let c = r.el(stack, "mailCallout", attrs = [("tone", "success"),
    ("title", "Two-step sign-in is now on for every device you use"),
    ("icon", fixtureImageUrl("shield.png"))])
  discard r.para(c, "Every new sign-in now asks for a code from your " &
    "phone, including sign-ins from a browser you have used before. " &
    "Reference " & longWord & ".", last = false)
  let more = r.el(c, "p", [("margin", "0")])
  discard r.link(more, "https://example.com/devices", "Manage your devices")
  for (tone, title) in [("danger", "Payment failed"), ("success",
      "Backup complete"), ("info", "New region available"), ("neutral",
      "Scheduled maintenance"), ("primary", "Beta feature")]:
    let t = r.el(stack, "mailCallout", attrs = [("tone", tone),
      ("title", title)])
    discard r.para(t, "One line of body text.")
  r.footer(result)

proc calloutRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("كلمة المرور", "تنبيه من اليمين إلى اليسار.",
    rtl = true)
  r.intro(result, "تم تغيير كلمة المرور", "")
  let s = r.band(result)
  let c = r.el(s, "mailCallout", attrs = [("tone", "warning"),
    ("label", "تحذير"), ("title", "لم تغير كلمة المرور؟")])
  discard r.para(c, "إذا لم تكن أنت، فأعد تعيين كلمة المرور الآن.")
  r.footer(result, rtl = true)

proc calloutImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Security notice", "A callout with its icon blocked.")
  r.intro(result, "Security notice", "With images blocked, the icon " &
    "disappears (it is decorative) and the title still names the tone.")
  let s = r.band(result)
  let c = r.el(s, "mailCallout", attrs = [("tone", "success"),
    ("title", "Your account is protected"), ("icon",
      fixtureImageUrl("shield.png"))])
  discard r.para(c, "Two-step sign-in is on for every device.")
  r.footer(result)

proc calloutDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Notices, dark", "Callouts in their dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Notices, dark")
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  for (tone, title) in [("warning", "Disk almost full"), ("danger",
      "Payment failed"), ("success", "Backup complete"), ("info",
      "New region available")]:
    let c = r.el(stack, "mailCallout", attrs = [("tone", tone),
      ("title", title)])
    discard r.dkText(c, "p", "The panel and its accent take their dark " &
      "pairs.", [("margin", "0")])
  r.dkFooter(result)

proc calloutInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Incident report", "A callout between a heading " &
    "and a table.")
  r.intro(result, "Elevated error rates", "Between 09:12 and 10:05 UTC " &
    "some requests failed.")
  let s = r.el(r.band(result), "mailStack", [("gap", "16px")])
  let c = r.el(s, "mailCallout", attrs = [("tone", "danger"),
    ("title", "Action needed")])
  discard r.para(c, "Retry the jobs that failed in that window.")
  let tbl = r.el(s, "mailTable", attrs = [("caption", "Affected jobs")])
  let table = r.el(tbl, "table")
  let head = r.el(r.el(table, "thead"), "tr")
  discard r.el(head, "th", text = "Job")
  discard r.el(head, "th", text = "Status")
  let row = r.el(r.el(table, "tbody"), "tr")
  discard r.el(row, "td", text = "nightly-export")
  discard r.el(row, "td", text = "failed")
  r.footer(result)

# --- mailCodeBlock --------------------------------------------------------------

proc code(r: EmailRenderer; parent: EmailNode; text: string): EmailNode =
  result = r.el(parent, "mailCodeBlock")
  r.txt(result, text)

proc codeBlockMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your API key", "A code block.")
  r.intro(result, "Your API key", "Install the client:")
  let s = r.band(result)
  discard r.code(s, "npm install @acme/client")
  r.footer(result)

proc codeBlockMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Build failed", "A long, indented, highlighted " &
    "code block.")
  r.intro(result, "Build failed", "The step below failed on main. Long " &
    "lines wrap inside the panel, from its edge.")
  let s = r.band(result)
  let c = r.el(s, "mailCodeBlock")
  for (text, colour) in [("proc ", "#8250df"), ("deploy", "#0550ae"),
      ("(target: string) =\n  ", ""), ("let", "#8250df"),
      (" url = \"https://deploy.example.com/projects/acme/environments/" &
        "production/releases/" & longWord & "\"\n  if ", ""),
      ("not", "#8250df"), (" reachable(url):\n\traise newException(" &
        "IOError, ", ""), ("\"unreachable: \"", "#0a3069"),
      (" & url)\n", "")]:
    if colour.len > 0:
      discard r.el(c, "span", [("color", colour)], text = text)
    else:
      r.txt(c, text)
  r.footer(result)

proc codeBlockRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("مفتاحك", "كتلة شيفرة في رسالة من اليمين إلى " &
    "اليسار.", rtl = true)
  r.intro(result, "مفتاح الواجهة", "ثبّت العميل:")
  let s = r.band(result)
  discard r.code(s, "npm install @acme/client\nacme login --key KEY")
  r.footer(result, rtl = true)

proc codeBlockImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Deploy notes", "A code block under an image.")
  r.intro(result, "Deploy notes", "With images blocked, the diagram " &
    "shows its alt text above the commands.")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  discard r.el(stack, "mailImage", [("width", "280px")], [("src",
    fixtureImageUrl("scene.png")), ("alt", "Deploy diagram")])
  discard r.code(stack, "git push origin main\nacme deploy --env production")
  r.footer(result)

proc codeBlockDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your API key, dark", "A code block in its dark " &
    "colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Your API key, dark")
  let c = r.el(s, "mailCodeBlock")
  let k = r.el(c, "span", text = "export")
  r.paint(k, "color", tok"color.link")
  r.txt(c, " ACME_KEY=sk_live_example\nacme whoami")
  r.dkFooter(result)

proc codeBlockInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Get started", "A code block between steps.")
  r.intro(result, "Get started", "")
  let s = r.band(result)
  discard r.para(s, "1. Install the command-line tool:", last = false)
  discard r.code(s, "brew install acme")
  discard r.el(s, "p", [("margin", "16px 0")],
    text = "2. Sign in with your key:")
  discard r.code(s, "acme login")
  let b = r.band(result, "#eef2ff")
  discard r.el(b, "mailButton", attrs = [("href",
    "https://example.com/docs")], text = "Read the guide")
  r.footer(result)

# --- codeInline -----------------------------------------------------------------

proc inline(r: EmailRenderer; parent: EmailNode;
    parts: openArray[(string, bool)]; styles: openArray[(string, string)] =
      [("margin", "0")]): EmailNode =
  ## A paragraph of text and inline code (`true` parts are code).
  result = r.el(parent, "p", styles)
  for (text, isCode) in parts:
    if isCode:
      discard r.el(result, "codeInline", text = text)
    else:
      r.txt(result, text)

proc codeInlineMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Run the tests", "Inline code in a sentence.")
  r.intro(result, "Run the tests", "")
  let s = r.band(result)
  discard r.inline(s, [("Run ", false), ("just test", true),
    (" before you push.", false)])
  r.footer(result)

proc codeInlineMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Configuration", "Long inline code that wraps.")
  r.intro(result, "Configuration", "")
  let s = r.band(result)
  discard r.inline(s, [("Set ", false), ("ACME_DEPLOY_TOKEN", true),
    (" in your environment, then point ", false),
    ("https://deploy.example.com/" & longWord, true),
    (" at the release you want; ", false), ("--dry-run", true),
    (" prints what would change without touching ", false),
    ("production", true), (".", false)])
  r.footer(result)

proc codeInlineRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("الاختبارات", "شيفرة داخل جملة.", rtl = true)
  r.intro(result, "شغّل الاختبارات", "")
  let s = r.band(result)
  discard r.inline(s, [("شغّل ", false), ("just test", true),
    (" قبل الدفع.", false)])
  r.footer(result, rtl = true)

proc codeInlineImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("New command", "Inline code beside an image.")
  r.intro(result, "New command", "With images blocked, the icon shows " &
    "its alt text beside the sentence.")
  let s = r.band(result)
  let sb = r.el(s, "mailSidebar", [("gap", "12px")], [("fixed", "48px"),
    ("valign", "middle")])
  discard r.el(sb, "mailImage", [("width", "48px")], [("src",
    fixtureImageUrl("shield.png")), ("alt", "Tip")])
  discard r.inline(sb, [("Try ", false), ("acme audit", true),
    (" to check every key.", false)])
  r.footer(result)

proc codeInlineDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Run the tests, dark", "Inline code in its dark " &
    "colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Run the tests, dark")
  let p = r.inline(s, [("Run ", false), ("just test", true),
    (" before you push.", false)])
  r.paint(p, "color", tok"color.text.primary")
  r.dkFooter(result)

proc codeInlineInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Release notes", "Inline code in a list and a " &
    "paragraph.")
  r.intro(result, "Release notes", "")
  let s = r.band(result)
  let ul = r.el(s, "ul")
  for parts in [@[("New ", false), ("--json", true), (" output.", false)],
      @[("Faster ", false), ("sync", true), (".", false)]]:
    let li = r.el(ul, "li")
    for (text, isCode) in parts:
      if isCode:
        discard r.el(li, "codeInline", text = text)
      else:
        r.txt(li, text)
  discard r.inline(s, [("Upgrade with ", false), ("acme update", true),
    (".", false)])
  let b = r.band(result, "#f4f5f7")
  discard r.para(b, "Questions? Reply to this message.")
  r.footer(result)

# --- mailQuote ------------------------------------------------------------------

proc quoteMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("What customers say", "A quotation with its name.")
  r.intro(result, "What customers say", "")
  let s = r.band(result)
  let q = r.el(s, "mailQuote", attrs = [("name", "Ada Lovelace")])
  r.txt(q, "It just works, every time.")
  r.footer(result)

proc quoteMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Customer story", "A quotation with every prop.")
  r.intro(result, "Customer story", "", "#f4f5f7")
  let s = r.band(result, "#f4f5f7")
  let q = r.el(s, "mailQuote", attrs = [("name", "Grace Hopper-Okonkwo"),
    ("role", "Head of Platform Engineering, Example Logistics Group"),
    ("avatar", fixtureImageUrl("avatar-indigo.png")), ("glyph", "true")])
  discard r.el(q, "p", text = "We moved forty services in a weekend and " &
    "nobody noticed, which is the highest praise an infrastructure " &
    "change can get.")
  discard r.el(q, "p", text = "Our on-call pages dropped by half in the " &
    "first month. Ticket " & longWord & " was the last one.")
  r.footer(result)

proc quoteRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("آراء العملاء", "اقتباس من اليمين إلى اليسار.",
    rtl = true)
  r.intro(result, "آراء العملاء", "")
  let s = r.band(result)
  let q = r.el(s, "mailQuote", attrs = [("name", "ليلى حسن"),
    ("role", "مديرة العمليات"), ("avatar",
      fixtureImageUrl("avatar-amber.png"))])
  r.txt(q, "يعمل دائما، في كل مرة.")
  r.footer(result, rtl = true)

proc quoteImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Customer story", "A quotation whose avatar is " &
    "blocked.")
  r.intro(result, "Customer story", "With images blocked, the avatar " &
    "(described for screen readers) shows its alt text beside the name.")
  let s = r.band(result)
  let q = r.el(s, "mailQuote", attrs = [("name", "Ada Lovelace"),
    ("role", "CTO, Example Co"), ("avatar",
      fixtureImageUrl("avatar-indigo.png")), ("avatar_alt", "Ada")])
  r.txt(q, "It just works, every time.")
  r.footer(result)

proc quoteDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Customer story, dark", "A quotation in its dark " &
    "colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Customer story, dark")
  let q = r.el(s, "mailQuote", attrs = [("name", "Ada Lovelace"),
    ("role", "CTO, Example Co"), ("avatar",
      fixtureImageUrl("avatar-indigo.png")), ("glyph", "true")])
  let p = r.dkText(q, "p", "It just works, every time.")
  discard p
  r.dkFooter(result)

proc quoteInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Why teams switch", "Two quotations between a " &
    "band and a button.")
  let b = r.el(result, "mailBand", [("background-color", "#eef2ff"),
    ("padding", "32px 0")])
  discard r.el(b, "h1", text = "Why teams switch")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "32px")])
  for (name, role, text, img) in [("Ada Lovelace", "CTO, Example Co",
      "It just works, every time.", "avatar-indigo.png"),
      ("Linus Park", "Founder, Small Shop", "Setup took ten minutes.",
        "avatar-amber.png")]:
    let q = r.el(stack, "mailQuote", attrs = [("name", name),
      ("role", role), ("avatar", if img == "avatar-indigo.png":
        fixtureImageUrl("avatar-indigo.png") else:
        fixtureImageUrl("avatar-amber.png"))])
    r.txt(q, text)
  let after = r.band(result, "#f4f5f7")
  discard r.el(after, "mailButton", attrs = [("href",
    "https://example.com/start")], text = "Start a free trial")
  r.footer(result)

# --- Registration -------------------------------------------------------------

proc story(name, description: string;
    build: proc(): EmailNode {.nimcall.}; dark: bool): KitStory =
  (name, description, build, dark)

let containerStories*: seq[KitStory] = @[
  story("cardMinimal", "mailCard with its body only.", cardMinimalDoc, false),
  story("cardMaximal", "mailCard: elevated, a 16:9 image, a long title, a " &
    "button.", cardMaximalDoc, false),
  story("cardRtl", "mailCard right to left.", cardRtlDoc, false),
  story("cardImagesOff", "Two mailCards with images (capture with images off).",
    cardImagesOffDoc, false),
  story("cardDark", "mailCard in its dark colours.", cardDarkDoc, true),
  story("cardInContext", "mailCards between a band and a button.",
    cardInContextDoc, false),
  story("calloutMinimal", "mailCallout with its body only.", calloutMinimalDoc,
    false),
  story("calloutMaximal", "mailCallout: an icon, a long title, a button; and " &
    "every tone.", calloutMaximalDoc, false),
  story("calloutRtl", "mailCallout right to left.", calloutRtlDoc, false),
  story("calloutImagesOff", "mailCallout with an icon (capture with images " &
    "off).", calloutImagesOffDoc, false),
  story("calloutDark", "mailCallouts in their dark colours.", calloutDarkDoc,
    true),
  story("calloutInContext", "mailCallout between a heading and a table.",
    calloutInContextDoc, false),
  story("codeBlockMinimal", "mailCodeBlock: one line.", codeBlockMinimalDoc,
    false),
  story("codeBlockMaximal", "mailCodeBlock: long, indented and highlighted.",
    codeBlockMaximalDoc, false),
  story("codeBlockRtl", "mailCodeBlock in a right-to-left message.",
    codeBlockRtlDoc, false),
  story("codeBlockImagesOff", "mailCodeBlock under an image (capture with " &
    "images off).", codeBlockImagesOffDoc, false),
  story("codeBlockDark", "mailCodeBlock in its dark colours.", codeBlockDarkDoc,
    true),
  story("codeBlockInContext", "mailCodeBlocks between steps.",
    codeBlockInContextDoc, false),
  story("codeInlineMinimal", "codeInline in a sentence.", codeInlineMinimalDoc,
    false),
  story("codeInlineMaximal", "codeInline: long code that wraps.",
    codeInlineMaximalDoc, false),
  story("codeInlineRtl", "codeInline in a right-to-left sentence.",
    codeInlineRtlDoc, false),
  story("codeInlineImagesOff", "codeInline beside an icon (capture with images " &
    "off).", codeInlineImagesOffDoc, false),
  story("codeInlineDark", "codeInline in its dark colours.", codeInlineDarkDoc,
    true),
  story("codeInlineInContext", "codeInline in a list and a paragraph.",
    codeInlineInContextDoc, false),
  story("quoteMinimal", "mailQuote with its name only.", quoteMinimalDoc, false),
  story("quoteMaximal", "mailQuote: the glyph, an avatar, two paragraphs.",
    quoteMaximalDoc, false),
  story("quoteRtl", "mailQuote right to left.", quoteRtlDoc, false),
  story("quoteImagesOff", "mailQuote with an avatar (capture with images off).",
    quoteImagesOffDoc, false),
  story("quoteDark", "mailQuote in its dark colours.", quoteDarkDoc, true),
  story("quoteInContext", "Two mailQuotes between a band and a button.",
    quoteInContextDoc, false),
]

proc containerGroup(name: string): string =
  for prefix in ["card", "callout", "codeBlock", "codeInline", "quote"]:
    if name.startsWith(prefix):
      return prefix
  name

proc renderContainerStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(containerStories, name, "container")

proc registerContainerStories*() =
  ## Registers the container pattern story sets (env-gated, see above).
  registerKit(containerStories, containerGroup)

proc registerContainerStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(containerStories)
