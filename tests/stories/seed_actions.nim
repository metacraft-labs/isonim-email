## Action and inline-item pattern stories: the story sets of
## `mailButtonGroup`, `mailBadge`, `mailAvatarName`, `mailDividerLabel`,
## `mailCoupon`, `mailRatingScale`, `mailSecurityCode` and
## `mailAppBadges` (layout-patterns.md §5): `Minimal`, `Maximal`, `Rtl`,
## `ImagesOff`, `Dark` and `InContext` for each. The patterns without
## images of their own are captured with images off beside an image (a
## logo), so their layout is checked with the image's alt text in its
## place.
##
## The avatars are `tests/stories/assets/avatar-*.png` (192×192
## circular PNGs) and the `photo-*.png` placeholders, both cropped to a
## circle by the asset pass; the app badges are `badge-*.png`
## (placeholder artwork, 270×80 @2x, light and dark), on the capture
## fixture host.
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images
import story_kit

const logoLight = "mark-outlined.png"

let
  amber = $asset"assets/avatar-amber.png"
  indigo = $asset"assets/avatar-indigo.png"
  coast = $asset"assets/photo-coast.png"

proc intro(r: EmailRenderer; doc: EmailNode; title, body: string;
    bg = "#ffffff") =
  let s = r.band(doc, bg, "24px 0 8px")
  discard r.el(s, "h1", text = title)
  if body.len > 0:
    discard r.el(s, "p", [("margin", "0")], text = body)

proc logoBand(r: EmailRenderer; doc: EmailNode) =
  ## A band holding the logo (the images-off stories' image).
  let s = r.band(doc, padding = "24px 0 0")
  discard r.el(s, "mailImage", [("width", "120px"),
    ("height", fixtureImageHeight(logoLight, 120))],
    [("src", fixtureImageUrl(logoLight)), ("alt", "Acme")])

proc para(r: EmailRenderer; parent: EmailNode; text: string;
    last = false): EmailNode =
  r.el(parent, "p", if last: @[("margin", "0")] else: @[], text = text)

proc button(r: EmailRenderer; parent: EmailNode; label, href: string;
    attrs: openArray[(string, string)] = []): EmailNode =
  r.el(parent, "mailButton", attrs = @[("href", href)] & @attrs, text = label)

proc group(r: EmailRenderer; parent: EmailNode;
    buttons: openArray[(string, string)];
    attrs: openArray[(string, string)] = []): EmailNode =
  result = r.el(parent, "mailButtonGroup", attrs = attrs)
  for (label, href) in buttons:
    discard r.button(result, label, href)

proc badge(r: EmailRenderer; parent: EmailNode; label: string;
    tone = ""): EmailNode =
  r.el(parent, "mailBadge", attrs = (if tone.len > 0: @[("tone", tone)]
    else: @[]), text = label)

let
  ios = fixtureImageUrl("badge-ios.png")
  iosDark = fixtureImageUrl("badge-ios-dark.png")
  android = fixtureImageUrl("badge-android.png")
  androidDark = fixtureImageUrl("badge-android-dark.png")

proc badgeItem(r: EmailRenderer; parent: EmailNode; store, href,
    image: string; width: int; darkImage = ""; alt = "") =
  var a = @[("store", store), ("href", href),
    ("image", image), ("width", $width)]
  if darkImage.len > 0:
    a.add(("dark_image", darkImage))
  if alt.len > 0:
    a.add(("alt", alt))
  discard r.el(parent, "mailAppBadge", attrs = a)

# --- mailButtonGroup -----------------------------------------------------------

proc buttonGroupMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Invoice 2041", "Two buttons: pay or download.")
  r.intro(result, "Invoice 2041", "")
  let s = r.band(result)
  discard r.group(s, [("Pay invoice", "https://example.com/pay"),
    ("Download PDF", "https://example.com/invoice.pdf")])
  r.footer(result)

proc buttonGroupMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your plan is about to renew", "Button groups with " &
    "long labels, stacked on phones and wrapping.")
  r.intro(result, "Your plan is about to renew", "Three long actions that " &
    "stack at full width on a phone, then three that wrap. Reference " &
    longWord & ".")
  let s = r.band(result)
  discard r.group(s, [("Renew for another year at the same price",
    "https://example.com/renew"), ("Switch to monthly billing instead",
    "https://example.com/monthly"), ("Cancel the subscription",
    "https://example.com/cancel")], [("gap", "16px"),
    ("stack_on_mobile", "true")])
  let w = r.band(result)
  discard r.el(w, "h2", text = "Or pick an add-on")
  discard r.group(w, [("Add 50 GB of storage", "https://example.com/storage"),
    ("Add a second workspace", "https://example.com/workspace"),
    ("Talk to sales", "https://example.com/sales")], [("align", "center")])
  r.footer(result)

proc buttonGroupRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("الفاتورة ٢٠٤١", "زران: الدفع أو التنزيل.", rtl = true)
  r.intro(result, "الفاتورة ٢٠٤١", "يمكنك دفع الفاتورة الآن أو تنزيلها.")
  let s = r.band(result)
  discard r.group(s, [("ادفع الفاتورة", "https://example.com/pay"),
    ("نزّل الملف", "https://example.com/invoice.pdf")])
  r.footer(result, rtl = true)

proc buttonGroupImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Invoice 2041", "A button group under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "Invoice 2041", "With images blocked, the logo shows " &
    "its alt text; the buttons are text.")
  let s = r.band(result)
  discard r.group(s, [("Pay invoice", "https://example.com/pay"),
    ("Download PDF", "https://example.com/invoice.pdf")],
    [("stack_on_mobile", "true")])
  r.footer(result)

proc buttonGroupDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Invoice, dark", "A button group in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Invoice, dark")
  discard r.dkText(s, "p", "The filled and the outlined button take their " &
    "dark pairs.")
  discard r.group(s, [("Pay invoice", "https://example.com/pay"),
    ("Download PDF", "https://example.com/invoice.pdf")])
  r.dkFooter(result)

proc buttonGroupInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Invoice 2041", "A button group between a summary " &
    "and a note.")
  r.intro(result, "Invoice 2041", "Due on 1 November.")
  let s = r.band(result, "#f4f5f7")
  let kv = r.el(s, "mailKeyValue", attrs = [("caption", "Invoice summary"),
    ("total_row", "true")])
  discard r.el(kv, "mailKeyValueRow", attrs = [("label", "Plan")],
    text = "$120.00")
  discard r.el(kv, "mailKeyValueRow", attrs = [("label", "Total")],
    text = "$120.00")
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  r.appendChild(stack, kv)
  discard r.group(stack, [("Pay invoice", "https://example.com/pay"),
    ("Download PDF", "https://example.com/invoice.pdf")])
  discard r.para(stack, "Questions? Reply to this message.", last = true)
  r.footer(result)

# --- mailBadge -------------------------------------------------------------------

proc badgeMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("What's new", "A badge on a line of its own.")
  r.intro(result, "What's new", "")
  let s = r.el(r.band(result), "mailStack", [("gap", "12px")])
  discard r.badge(s, "New")
  discard r.para(s, "Shared folders are here.", last = true)
  r.footer(result)

proc badgeMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Release status", "Badges in every tone, in a " &
    "sentence, and a long label.")
  r.intro(result, "Release status", "Every tone in a cluster, a badge " &
    "inside a sentence and inside a heading, and a long label that wraps.")
  let s = r.el(r.band(result), "mailStack", [("gap", "16px")])
  let row = r.el(s, "mailCluster", styles = [("gap", "8px")])
  for (label, tone) in [("Neutral", "neutral"), ("Primary", "primary"),
      ("Info", "info"), ("Shipped", "success"), ("Pending", "warning"),
      ("Failed", "danger")]:
    discard r.badge(row, label, tone)
  let h = r.el(s, "h2", text = "Single sign-on ")
  discard r.badge(h, "Beta", "info")
  let p = r.el(s, "p", text = "Your invoice is ")
  discard r.badge(p, "Paid", "success")
  r.txt(p, " and the order is ")
  discard r.badge(p, "Awaiting shipment", "warning")
  r.txt(p, ". Reference " & longWord & ".")
  discard r.badge(s, "Scheduled maintenance this weekend: read-only from " &
    "02:00 to 03:00 UTC", "warning")
  r.footer(result)

proc badgeRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("حالة الطلب", "شارات من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "حالة الطلب", "")
  let s = r.el(r.band(result), "mailStack", [("gap", "12px")])
  let row = r.el(s, "mailCluster", styles = [("gap", "8px")])
  discard r.badge(row, "جديد", "primary")
  discard r.badge(row, "تم الشحن", "success")
  let p = r.el(s, "p", [("margin", "0")], text = "حالة الفاتورة: ")
  discard r.badge(p, "مدفوعة", "success")
  r.footer(result, rtl = true)

proc badgeImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("What's new", "Badges under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "What's new", "With images blocked, the logo shows its " &
    "alt text; the badges are text.")
  let s = r.band(result)
  let row = r.el(s, "mailCluster", styles = [("gap", "8px")])
  discard r.badge(row, "New", "primary")
  discard r.badge(row, "Beta", "info")
  r.footer(result)

proc badgeDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Status, dark", "Badges in their dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Status, dark")
  let st = r.el(s, "mailStack", [("gap", "12px")])
  let row = r.el(st, "mailCluster", styles = [("gap", "8px")])
  for (label, tone) in [("Neutral", "neutral"), ("Primary", "primary"),
      ("Info", "info"), ("Shipped", "success"), ("Pending", "warning"),
      ("Failed", "danger")]:
    discard r.badge(row, label, tone)
  let p = r.dkText(st, "p", "Your invoice is ", [("margin", "0")])
  discard r.badge(p, "Paid", "success")
  r.dkFooter(result)

proc badgeInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your deployments", "Badges beside headings in a list.")
  r.intro(result, "Your deployments", "")
  let s = r.band(result, "#f4f5f7")
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  for (name, label, tone, text) in [("api-gateway", "Live", "success",
      "Deployed 12 minutes ago."), ("billing-worker", "Failed", "danger",
      "The health check timed out.")]:
    let c = r.el(stack, "mailCard", attrs = [("title", name)])
    let body = r.el(c, "mailStack", [("gap", "8px")])
    discard r.badge(body, label, tone)
    discard r.para(body, text, last = true)
  r.footer(result)

# --- mailAvatarName ----------------------------------------------------------------

proc avatarNameMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A new comment", "An avatar beside a name.")
  r.intro(result, "A new comment", "")
  let s = r.band(result)
  discard r.el(s, "mailAvatarName", attrs = [("name", "Ada Lovelace"),
    ("avatar", amber)])
  r.footer(result)

proc avatarNameMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your account manager", "A large avatar, cropped " &
    "from a photo, with a long name and role.")
  r.intro(result, "Your account manager", "A 64px avatar cropped to a " &
    "circle from a landscape photo, a long name and a role that wraps.")
  let s = r.band(result)
  discard r.el(s, "mailAvatarName", attrs = [("name",
    "Maximiliane Charlotte von Hohenberg-Winterfeld"), ("role",
    "Senior customer success manager, enterprise accounts, Europe, " &
    "the Middle East and Africa; reference " & longWord),
    ("avatar", coast), ("avatar_alt", "Maximiliane at the coast"),
    ("size", "64")])
  r.footer(result)

proc avatarNameRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("تعليق جديد", "صورة بجانب اسم.", rtl = true)
  r.intro(result, "تعليق جديد", "")
  let s = r.band(result)
  discard r.el(s, "mailAvatarName", attrs = [("name", "ليلى حسن"),
    ("role", "مديرة المنتج"), ("avatar", indigo)])
  r.footer(result, rtl = true)

proc avatarNameImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A new comment", "Avatars with images blocked.")
  r.intro(result, "A new comment", "With images blocked, the decorative " &
    "avatar shows nothing and the described one its alt text.")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  discard r.el(stack, "mailAvatarName", attrs = [("name", "Ada Lovelace"),
    ("role", "Engineering"), ("avatar", amber)])
  discard r.el(stack, "mailAvatarName", attrs = [("name", "Grace Hopper"),
    ("role", "Compilers"), ("avatar", indigo), ("avatar_alt", "Grace")])
  r.footer(result)

proc avatarNameDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your reviewer, dark", "An avatar and name in dark.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Your reviewer, dark")
  discard r.el(s, "mailAvatarName", attrs = [("name", "Grace Hopper"),
    ("role", "Compilers"), ("avatar", indigo)])
  r.dkFooter(result)

proc avatarNameInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Two new reviewers", "Avatars between a paragraph " &
    "and a button.")
  r.intro(result, "Two new reviewers", "")
  let s = r.band(result, "#f4f5f7")
  discard r.para(s, "These two will review your pull request:")
  let stack = r.el(s, "mailStack", [("gap", "12px")])
  discard r.el(stack, "mailAvatarName", attrs = [("name", "Ada Lovelace"),
    ("role", "Engineering"), ("avatar", amber)])
  discard r.el(stack, "mailAvatarName", attrs = [("name", "Grace Hopper"),
    ("role", "Compilers"), ("avatar", indigo)])
  let after = r.band(result)
  discard r.button(after, "Open the pull request",
    "https://example.com/pr/12")
  r.footer(result)

# --- mailDividerLabel ----------------------------------------------------------------

proc dividerLabelMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Sign in", "A divider labelled \"or\".")
  r.intro(result, "Sign in", "")
  let s = r.band(result)
  discard r.para(s, "Use your password.")
  discard r.el(s, "mailDividerLabel", text = "or")
  discard r.para(s, "Use a code from your app.", last = true)
  r.footer(result)

proc dividerLabelMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Sign in", "A long divider label that wraps.")
  r.intro(result, "Sign in", "A short label keeps one line; a long one " &
    "wraps in the middle of the rule. Reference " & longWord & ".")
  let s = r.band(result)
  discard r.el(s, "mailDividerLabel", text = "or")
  discard r.el(s, "mailDividerLabel", text = "or continue with one of " &
    "your saved recovery codes")
  discard r.el(s, "mailDividerLabel", text = longWord)
  r.footer(result)

proc dividerLabelRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("تسجيل الدخول", "فاصل بعنوان.", rtl = true)
  r.intro(result, "تسجيل الدخول", "")
  let s = r.band(result)
  discard r.para(s, "استخدم كلمة المرور.")
  discard r.el(s, "mailDividerLabel", text = "أو")
  discard r.para(s, "استخدم رمزا من التطبيق.", last = true)
  r.footer(result, rtl = true)

proc dividerLabelImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Sign in", "A labelled divider under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "Sign in", "With images blocked, the logo shows its alt " &
    "text; the divider is cells and text.")
  let s = r.band(result)
  discard r.button(s, "Sign in with a password", "https://example.com/pw")
  discard r.el(s, "mailDividerLabel", text = "or")
  discard r.button(s, "Email me a sign-in link", "https://example.com/link")
  r.footer(result)

proc dividerLabelDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Sign in, dark", "A labelled divider in dark.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Sign in, dark")
  discard r.dkText(s, "p", "Use your password.")
  discard r.el(s, "mailDividerLabel", text = "or")
  discard r.dkText(s, "p", "Use a code from your app.", [("margin", "0")])
  r.dkFooter(result)

proc dividerLabelInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Sign in", "A labelled divider between two buttons.")
  r.intro(result, "Sign in", "")
  let s = r.band(result, "#f4f5f7")
  discard r.button(s, "Sign in with a password", "https://example.com/pw",
    [("align", "center")])
  discard r.el(s, "mailDividerLabel", text = "or")
  discard r.button(s, "Email me a sign-in link", "https://example.com/link",
    [("align", "center"), ("variant", "outline")])
  r.footer(result)

# --- mailCoupon ------------------------------------------------------------------------

proc couponMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A code for you", "A coupon with its code only.")
  r.intro(result, "A code for you", "")
  let s = r.band(result)
  discard r.el(s, "mailCoupon", attrs = [("code", "SPRING20")])
  r.footer(result)

proc couponMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome back", "A coupon with every prop and a " &
    "long code.")
  r.intro(result, "Welcome back", "A long title, a long code and a hint " &
    "with a long reference.")
  let s = r.band(result)
  discard r.el(s, "mailCoupon", attrs = [("title", "20% off everything " &
    "in the spring collection, for the next two weeks"), ("code",
    "WELCOME-BACK-2026-SPRING"), ("hint", "Enter it at checkout. One use " &
    "per account; reference " & longWord & "."), ("label", "Coupon code")])
  r.footer(result)

proc couponRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("رمز خصم", "قسيمة من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "رمز خصم", "")
  let s = r.band(result)
  discard r.el(s, "mailCoupon", attrs = [("title", "خصم ٢٠٪ على طلبك القادم"),
    ("code", "SPRING20"), ("hint", "أدخل الرمز عند الدفع."),
    ("label", "الرمز")])
  r.footer(result, rtl = true)

proc couponImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("A code for you", "A coupon under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "A code for you", "With images blocked, the logo shows " &
    "its alt text; the code is text, never an image.")
  let s = r.band(result)
  discard r.el(s, "mailCoupon", attrs = [("title", "20% off"),
    ("code", "SPRING20"), ("hint", "Enter it at checkout.")])
  r.footer(result)

proc couponDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("A code, dark", "A coupon in its dark colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "A code, dark")
  discard r.el(s, "mailCoupon", attrs = [("title", "20% off"),
    ("code", "SPRING20"), ("hint", "Enter it at checkout.")])
  r.dkFooter(result)

proc couponInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Thanks for your feedback", "A coupon between a " &
    "paragraph and a button.")
  r.intro(result, "Thanks for your feedback", "")
  let s = r.band(result)
  discard r.para(s, "As a thank-you, here is a code for your next order.")
  discard r.el(s, "mailCoupon", attrs = [("title", "15% off"),
    ("code", "THANKS15"), ("hint", "Valid until 30 November.")])
  let after = r.band(result)
  discard r.button(after, "Shop now", "https://example.com/shop")
  r.footer(result)

# --- mailRatingScale -------------------------------------------------------------------

const rateHref = "https://example.com/rate?score={score}"

proc ratingScaleMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("How did we do?", "Five stars.")
  r.intro(result, "How did we do?", "")
  let s = r.band(result)
  discard r.el(s, "mailRatingScale", attrs = [("href", rateHref)])
  r.footer(result)

proc ratingScaleMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("One question", "An NPS scale with long end labels.")
  r.intro(result, "One question", "How likely are you to recommend Acme " &
    "to a friend or colleague? Survey " & longWord & ".")
  let s = r.band(result)
  discard r.el(s, "mailRatingScale", attrs = [("kind", "nps"),
    ("href", rateHref), ("low_label", "Not at all likely"),
    ("high_label", "Extremely likely")])
  r.footer(result)

proc ratingScaleRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("سؤال واحد", "مقياس من اليمين إلى اليسار.", rtl = true)
  r.intro(result, "سؤال واحد", "ما مدى احتمال أن توصي بنا لصديق؟")
  let s = r.band(result)
  discard r.el(s, "mailRatingScale", attrs = [("kind", "nps"),
    ("href", rateHref), ("low_label", "غير محتمل"),
    ("high_label", "محتمل جدا")])
  r.footer(result, rtl = true)

proc ratingScaleImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("How did we do?", "Stars under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "How did we do?", "With images blocked, the logo shows " &
    "its alt text; the stars are text.")
  let s = r.band(result)
  discard r.el(s, "mailRatingScale", attrs = [("href", rateHref),
    ("low_label", "Poor"), ("high_label", "Excellent")])
  r.footer(result)

proc ratingScaleDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("One question, dark", "An NPS scale in dark.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "One question, dark")
  discard r.el(s, "mailRatingScale", attrs = [("kind", "nps"),
    ("href", rateHref)])
  r.dkFooter(result)

proc ratingScaleInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your support ticket", "Stars between a question " &
    "and a note.")
  r.intro(result, "Your support ticket is closed", "")
  let s = r.el(r.band(result, "#f4f5f7"), "mailStack", [("gap", "16px")])
  discard r.el(s, "h2", text = "How was the help you got?")
  discard r.el(s, "mailRatingScale", attrs = [("href", rateHref),
    ("low_label", "Poor"), ("high_label", "Excellent")])
  discard r.para(s, "One click is enough; no form to fill in.", last = true)
  r.footer(result)

# --- mailSecurityCode ------------------------------------------------------------------

proc securityCodeMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your sign-in code", "A code and its expiry.")
  r.intro(result, "Your sign-in code", "")
  let s = r.band(result)
  discard r.el(s, "mailSecurityCode", attrs = [("code", "482913"),
    ("expires", "14:05 UTC")])
  r.footer(result)

proc securityCodeMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Sign in to Acme", "A code, its expiry and a magic " &
    "link.")
  r.intro(result, "Sign in to Acme", "Enter the code, or use the button " &
    "on this device. Request " & longWord & ".")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  discard r.el(stack, "mailSecurityCode", attrs = [("code", "482913"),
    ("expires", "14:05 UTC on Sunday, 4 October 2026"),
    ("label", "Your one-time sign-in code"), ("expires_label",
    "This code stops working at"), ("href", "https://example.com/magic"),
    ("cta", "Sign in on this device")])
  let c = r.el(stack, "mailCallout", attrs = [("tone", "warning"),
    ("title", "Didn't request this?")])
  discard r.para(c, "Ignore this message: nobody can sign in without the " &
    "code.", last = true)
  r.footer(result)

proc securityCodeRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("رمز تسجيل الدخول", "رمز وانتهاء صلاحيته.", rtl = true)
  r.intro(result, "رمز تسجيل الدخول", "")
  let s = r.band(result)
  discard r.el(s, "mailSecurityCode", attrs = [("code", "482913"),
    ("expires", "14:05 UTC"), ("label", "رمزك"),
    ("expires_label", "ينتهي في")])
  r.footer(result, rtl = true)

proc securityCodeImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your sign-in code", "A code under a blocked logo.")
  r.logoBand(result)
  r.intro(result, "Your sign-in code", "With images blocked, the logo " &
    "shows its alt text; the code is text, never an image.")
  let s = r.band(result)
  discard r.el(s, "mailSecurityCode", attrs = [("code", "482913"),
    ("expires", "14:05 UTC")])
  r.footer(result)

proc securityCodeDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Your code, dark", "A security code in dark.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Your code, dark")
  discard r.el(s, "mailSecurityCode", attrs = [("code", "482913"),
    ("expires", "14:05 UTC"), ("href", "https://example.com/magic"),
    ("cta", "Sign in")])
  r.dkFooter(result)

proc securityCodeInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Reset your password", "A code between a paragraph " &
    "and a callout.")
  r.intro(result, "Reset your password", "")
  let s = r.band(result)
  let stack = r.el(s, "mailStack", [("gap", "16px")])
  discard r.para(stack, "Enter this code on the reset page.", last = true)
  discard r.el(stack, "mailSecurityCode", attrs = [("code", "730551"),
    ("expires", "09:30 UTC")])
  let c = r.el(stack, "mailCallout", attrs = [("tone", "warning"),
    ("title", "Didn't request this?")])
  discard r.para(c, "Your password has not changed.", last = true)
  r.footer(result)

# --- mailAppBadges ---------------------------------------------------------------------

proc appBadgesMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Get the app", "One store badge.")
  r.intro(result, "Get the app", "")
  let s = r.band(result)
  let b = r.el(s, "mailAppBadges")
  r.badgeItem(b, "apple", "https://apps.example.com/ios", ios, 135)
  r.footer(result)

proc appBadgesMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Take Acme with you", "Three 48px badges, one with " &
    "an alt of its own.")
  r.intro(result, "Take Acme with you", "Three badges at 48px, the " &
    "largest height; they wrap on a phone. Reference " & longWord & ".")
  let s = r.band(result)
  let b = r.el(s, "mailAppBadges", attrs = [("height", "48")])
  r.badgeItem(b, "apple", "https://apps.example.com/ios", ios, 162)
  r.badgeItem(b, "google", "https://apps.example.com/android", android, 162)
  r.badgeItem(b, "other", "https://apps.example.com/tablet", ios, 162,
    alt = "Download the tablet edition for iOS")
  r.footer(result)

proc appBadgesRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("حمّل التطبيق", "شارتا المتجرين.", rtl = true)
  r.intro(result, "حمّل التطبيق", "")
  let s = r.band(result)
  let b = r.el(s, "mailAppBadges")
  r.badgeItem(b, "apple", "https://apps.example.com/ios", ios, 135,
    alt = "حمّله من متجر التطبيقات")
  r.badgeItem(b, "google", "https://apps.example.com/android", android, 135,
    alt = "احصل عليه من متجر جوجل")
  r.footer(result, rtl = true)

proc appBadgesImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Get the app", "Store badges with images blocked.")
  r.intro(result, "Get the app", "With images blocked, each badge shows " &
    "its alt text.")
  let s = r.band(result)
  let b = r.el(s, "mailAppBadges")
  r.badgeItem(b, "apple", "https://apps.example.com/ios", ios, 135)
  r.badgeItem(b, "google", "https://apps.example.com/android", android, 135)
  r.footer(result)

proc appBadgesDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Get the app, dark", "Store badges swapped for their " &
    "dark variants.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Get the app, dark")
  let b = r.el(s, "mailAppBadges")
  r.badgeItem(b, "apple", "https://apps.example.com/ios", ios, 135,
    darkImage = iosDark)
  r.badgeItem(b, "google", "https://apps.example.com/android", android, 135,
    darkImage = androidDark)
  r.dkFooter(result)

proc appBadgesInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Welcome to Acme", "Store badges between a paragraph " &
    "and the social icons.")
  r.intro(result, "Welcome to Acme", "")
  let s = r.band(result, "#f4f5f7")
  discard r.para(s, "Your account is ready. Get the app to stay in touch " &
    "on the go.")
  let b = r.el(s, "mailAppBadges", attrs = [("align", "left")])
  r.badgeItem(b, "apple", "https://apps.example.com/ios", ios, 135)
  r.badgeItem(b, "google", "https://apps.example.com/android", android, 135)
  let so = r.el(s, "mailSocial", attrs = [("align", "left")])
  discard r.el(so, "mailSocialItem", attrs = [("network", "github"),
    ("href", "https://github.example/acme")])
  discard r.el(so, "mailSocialItem", attrs = [("network", "mastodon"),
    ("href", "https://mastodon.example/@acme")])
  r.footer(result)

# --- Registration ------------------------------------------------------------------------

proc story(name, description: string;
    build: proc(): EmailNode {.nimcall.}; dark: bool): KitStory =
  (name, description, build, dark)

let actionStories*: seq[KitStory] = @[
  story("buttonGroupMinimal", "mailButtonGroup: two buttons.",
    buttonGroupMinimalDoc, false),
  story("buttonGroupMaximal", "mailButtonGroup: three long buttons stacked " &
    "on phones, then three that wrap.", buttonGroupMaximalDoc, false),
  story("buttonGroupRtl", "mailButtonGroup right to left.", buttonGroupRtlDoc,
    false),
  story("buttonGroupImagesOff", "mailButtonGroup under a logo (capture with " &
    "images off).", buttonGroupImagesOffDoc, false),
  story("buttonGroupDark", "mailButtonGroup in its dark colours.",
    buttonGroupDarkDoc, true),
  story("buttonGroupInContext", "mailButtonGroup between a summary and a " &
    "note.", buttonGroupInContextDoc, false),
  story("badgeMinimal", "mailBadge on a line of its own.", badgeMinimalDoc,
    false),
  story("badgeMaximal", "mailBadge: every tone, in text, a long label.",
    badgeMaximalDoc, false),
  story("badgeRtl", "mailBadges right to left.", badgeRtlDoc, false),
  story("badgeImagesOff", "mailBadges under a logo (capture with images " &
    "off).", badgeImagesOffDoc, false),
  story("badgeDark", "mailBadges in their dark colours.", badgeDarkDoc, true),
  story("badgeInContext", "mailBadges in cards.", badgeInContextDoc, false),
  story("avatarNameMinimal", "mailAvatarName with its required props.",
    avatarNameMinimalDoc, false),
  story("avatarNameMaximal", "mailAvatarName: 64px, cropped from a photo, " &
    "long name and role.", avatarNameMaximalDoc, false),
  story("avatarNameRtl", "mailAvatarName right to left.", avatarNameRtlDoc,
    false),
  story("avatarNameImagesOff", "mailAvatarNames (capture with images off).",
    avatarNameImagesOffDoc, false),
  story("avatarNameDark", "mailAvatarName in its dark colours.",
    avatarNameDarkDoc, true),
  story("avatarNameInContext", "mailAvatarNames between a paragraph and a " &
    "button.", avatarNameInContextDoc, false),
  story("dividerLabelMinimal", "mailDividerLabel \"or\".",
    dividerLabelMinimalDoc, false),
  story("dividerLabelMaximal", "mailDividerLabel: a long label and a long " &
    "word.", dividerLabelMaximalDoc, false),
  story("dividerLabelRtl", "mailDividerLabel right to left.",
    dividerLabelRtlDoc, false),
  story("dividerLabelImagesOff", "mailDividerLabel under a logo (capture " &
    "with images off).", dividerLabelImagesOffDoc, false),
  story("dividerLabelDark", "mailDividerLabel in its dark colours.",
    dividerLabelDarkDoc, true),
  story("dividerLabelInContext", "mailDividerLabel between two buttons.",
    dividerLabelInContextDoc, false),
  story("couponMinimal", "mailCoupon with its code only.", couponMinimalDoc,
    false),
  story("couponMaximal", "mailCoupon: every prop, a long code.",
    couponMaximalDoc, false),
  story("couponRtl", "mailCoupon right to left.", couponRtlDoc, false),
  story("couponImagesOff", "mailCoupon under a logo (capture with images " &
    "off).", couponImagesOffDoc, false),
  story("couponDark", "mailCoupon in its dark colours.", couponDarkDoc, true),
  story("couponInContext", "mailCoupon between a paragraph and a button.",
    couponInContextDoc, false),
  story("ratingScaleMinimal", "mailRatingScale: five stars.",
    ratingScaleMinimalDoc, false),
  story("ratingScaleMaximal", "mailRatingScale: NPS with long end labels.",
    ratingScaleMaximalDoc, false),
  story("ratingScaleRtl", "mailRatingScale (NPS) right to left.",
    ratingScaleRtlDoc, false),
  story("ratingScaleImagesOff", "mailRatingScale (stars) under a logo " &
    "(capture with images off).", ratingScaleImagesOffDoc, false),
  story("ratingScaleDark", "mailRatingScale (NPS) in its dark colours.",
    ratingScaleDarkDoc, true),
  story("ratingScaleInContext", "mailRatingScale (stars) between a question " &
    "and a note.", ratingScaleInContextDoc, false),
  story("securityCodeMinimal", "mailSecurityCode: a code and its expiry.",
    securityCodeMinimalDoc, false),
  story("securityCodeMaximal", "mailSecurityCode: every prop, a magic link.",
    securityCodeMaximalDoc, false),
  story("securityCodeRtl", "mailSecurityCode right to left.",
    securityCodeRtlDoc, false),
  story("securityCodeImagesOff", "mailSecurityCode under a logo (capture " &
    "with images off).", securityCodeImagesOffDoc, false),
  story("securityCodeDark", "mailSecurityCode in its dark colours.",
    securityCodeDarkDoc, true),
  story("securityCodeInContext", "mailSecurityCode between a paragraph and " &
    "a callout.", securityCodeInContextDoc, false),
  story("appBadgesMinimal", "mailAppBadges: one badge.", appBadgesMinimalDoc,
    false),
  story("appBadgesMaximal", "mailAppBadges: three 48px badges.",
    appBadgesMaximalDoc, false),
  story("appBadgesRtl", "mailAppBadges right to left.", appBadgesRtlDoc,
    false),
  story("appBadgesImagesOff", "mailAppBadges (capture with images off).",
    appBadgesImagesOffDoc, false),
  story("appBadgesDark", "mailAppBadges with their dark variants.",
    appBadgesDarkDoc, true),
  story("appBadgesInContext", "mailAppBadges between a paragraph and the " &
    "social icons.", appBadgesInContextDoc, false),
]

proc actionGroup(name: string): string =
  for prefix in ["buttonGroup", "badge", "avatarName", "dividerLabel",
      "coupon", "ratingScale", "securityCode", "appBadges"]:
    if name.startsWith(prefix):
      return prefix
  name

proc renderActionStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(actionStories, name, "action")

proc registerActionStories*() =
  ## Registers the action and inline-item pattern story sets (env-gated,
  ## see above).
  registerKit(actionStories, actionGroup)

proc registerActionStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(actionStories)
