## The reference emails: one per common email type, written with the
## library's layouts (`receiptLayout`, `securityCodeLayout`,
## `alertLayout`, `digestLayout`, `transactionalLayout`) or composed from
## the same frame and patterns, with the fixed data a story renders.
##
## Together they cover every element of the vocabulary and every layout,
## and the edge cases a message meets in the field:
##
## - long unbroken words and URLs (`receiptHebrew`, `alertCritical`);
## - right to left, Hebrew and Arabic (`receiptHebrew`, `alertArabic`);
## - CJK, Japanese and Chinese (`securityCodeJapanese`, `shippingChinese`);
## - sections of one to four columns (`newsletterColumns`);
## - text over a hero image (`digestGrid`, `eventInvitation`);
## - images that are missing, a 404 (`receiptHebrew`, `digestGrid`);
## - a message near the 90 KB clipping budget (`digestNearBudget`);
## - every colour token of the theme, in the designed dark palette
##   (`darkPalette`).
##
## Each email is an entry of `referenceEmails()`: its name, what it is,
## the layout it uses, whether it renders under `darkMode = designed`,
## its authoring tree and its render. Every one has a real footer whose
## unsubscribe link is visible.
##
## The images are this directory's `assets/` (placeholder artwork),
## published by the render's asset store; a missing image is a URL on
## the reserved `.test` host that answers 404.
import std/strutils
import isonim_email

type
  ReferenceRender* = proc(target: EmailTarget;
    assets: AssetStore): RenderedEmail {.closure.}
    ## Renders the email with `target` (its dark mode set by the entry).

  ReferenceEmail* = object
    ## One reference email.
    name*: string        ## the story name
    description*: string
    layout*: string      ## the layout it uses ("" when composed)
    dark*: bool          ## rendered under `darkMode = designed`
    tree*: proc(): EmailNode {.closure.}
    render*: ReferenceRender

const missingImage* = "https://x.test/0404040404040404/missing-product.png"
  ## An image the host answers with a 404 (the capture host's prefix for
  ## an image a story means to be missing).

let
  logo = $asset"assets/mark-outlined.png"
  logoDark = $asset"assets/mark-dark.png"
  coast = $asset"assets/photo-coast.png"
  city = $asset"assets/photo-city.png"
  field = $asset"assets/photo-field.png"
  forest = $asset"assets/photo-forest.png"
  lake = $asset"assets/photo-lake.png"
  desert = $asset"assets/photo-desert.png"
  amber = $asset"assets/avatar-amber.png"
  indigo = $asset"assets/avatar-indigo.png"
  badgeIos = $asset"assets/badge-ios.png"
  badgeIosDark = $asset"assets/badge-ios-dark.png"
  badgeAndroid = $asset"assets/badge-android.png"
  badgeAndroidDark = $asset"assets/badge-android-dark.png"
  hero = $asset"assets/hero.png"
  countdown = $asset"assets/countdown.gif"

const longWord = "Supercalifragilisticexpialidociousnessless"
  ## A long unbroken word.

const nearBudgetCards* = 17
  ## The cards of `digestNearBudget`: as many as keep its HTML under, and
  ## close to, the 90 KB budget.

proc acme(title, preheader: string; lang = "en"; dir = "ltr"): LayoutFrame =
  ## The fixture brand's frame, in English.
  LayoutFrame(lang: lang, dir: dir, title: title, preheader: preheader,
    brand: "Acme", logo: logo, logoWidth: 120, logoDark: logoDark,
    homeUrl: "https://example.com/",
    links: @[LayoutLink(label: "Orders", href: "https://example.com/orders"),
      LayoutLink(label: "Help", href: "https://example.com/help")],
    viewInBrowser: "https://example.com/view/2041",
    address: "Acme Inc., 1 Example Street, Springfield, IL 62701, USA",
    reason: "You're receiving this because you have an Acme account.",
    legal: "© 2026 Acme Inc. All rights reserved.",
    unsubscribe: "https://example.com/unsubscribe?u=4f2a",
    preferences: "https://example.com/preferences?u=4f2a",
    social: @[LayoutSocial(network: "github", href: "https://github.com/"),
      LayoutSocial(network: "linkedin", href: "https://www.linkedin.com/"),
      LayoutSocial(network: "x", href: "https://x.com/")])

# --- receiptLayout -------------------------------------------------------------

proc receiptTypical*(): ReceiptLayoutProps =
  ReceiptLayoutProps(
    frame: acme("Your receipt from Acme", "Order 2041: $186.40, paid " &
      "with Visa ending 4242."),
    heading: "Thanks for your order",
    intro: "We've received your payment. Your order is on its way.",
    summary: @[LayoutRow(label: "Order", value: "2041"),
      LayoutRow(label: "Date", value: "4 October 2026"),
      LayoutRow(label: "Paid with", value: "Visa ending 4242")],
    items: @[ReceiptItem(description: "Coastline print", detail: "A3, matte",
        qty: "1", amount: "$64.00", thumb: coast),
      ReceiptItem(description: "City at night print", detail: "A2, gloss",
        qty: "2", amount: "$98.00", thumb: city),
      ReceiptItem(description: "Oak frame", detail: "For A3", qty: "1",
        amount: "$14.00", thumb: forest)],
    totals: @[LayoutRow(label: "Subtotal", value: "$176.00"),
      LayoutRow(label: "Shipping", value: "$4.90"),
      LayoutRow(label: "Tax", value: "$5.50"),
      LayoutRow(label: "Total", value: "$186.40")],
    actions: @[LayoutLink(label: "View your order",
        href: "https://example.com/orders/2041"),
      LayoutLink(label: "Download invoice",
        href: "https://example.com/orders/2041/invoice.pdf")],
    note: "Questions about this order? Reply to this email.",
    content: proc(r: EmailRenderer; parent: EmailNode) =
      discard r.node(parent, "mailCoupon", [("code", "THANKS15"),
        ("title", "15% off your next order"),
        ("hint", "Valid until 31 December 2026.")]))

proc receiptHebrew*(): ReceiptLayoutProps =
  ## Amounts keep their currency sign on their line: a no-break space.
  var f = acme("הקבלה שלך מ-Acme", "הזמנה 2041: 186.40 $, שולם בכרטיס " &
    "המסתיים ב-4242.", "he", "rtl")
  f.links = @[LayoutLink(label: "הזמנות", href: "https://example.com/he/orders"),
    LayoutLink(label: "עזרה", href: "https://example.com/he/help")]
  f.address = "Acme בע״מ, רחוב הדוגמה 1, תל אביב"
  f.reason = "קיבלת הודעה זו כי יש לך חשבון ב-Acme."
  f.legal = "© 2026 Acme בע״מ. כל הזכויות שמורות."
  f.viewInBrowserLabel = "צפייה בדפדפן"
  f.unsubscribeLabel = "ביטול הרשמה"
  f.preferencesLabel = "העדפות"
  ReceiptLayoutProps(
    frame: f,
    heading: "תודה על ההזמנה",
    intro: "קיבלנו את התשלום שלך. ההזמנה בדרך אליך.",
    summaryCaption: "סיכום ההזמנה",
    summary: @[LayoutRow(label: "הזמנה", value: "2041"),
      LayoutRow(label: "תאריך", value: "4 באוקטובר 2026"),
      LayoutRow(label: "אמצעי תשלום", value: "ויזה המסתיים ב-4242")],
    itemsCaption: "פריטים",
    itemLabel: "פריט", qtyLabel: "כמות", amountLabel: "סכום",
    items: @[ReceiptItem(description: "הדפס חוף", detail: "A3, מט",
        qty: "1", amount: "64.00\u00a0$", thumb: coast),
      ReceiptItem(description: longWord & " " & longWord, detail:
        "מק״ט ACME-PRINT-2041-XL-" & longWord.toUpperAscii(), qty: "1",
        amount: "98.00\u00a0$", thumb: missingImage, thumbAlt: "הדפס עיר"),
      ReceiptItem(description: "מסגרת אלון", detail: "ל-A3", qty: "1",
        amount: "14.00\u00a0$")],
    totalsCaption: "סכומים",
    totals: @[LayoutRow(label: "סכום ביניים", value: "176.00\u00a0$"),
      LayoutRow(label: "משלוח", value: "4.90\u00a0$"),
      LayoutRow(label: "מע״מ", value: "5.50\u00a0$"),
      LayoutRow(label: "סה״כ", value: "186.40\u00a0$")],
    actions: @[LayoutLink(label: "צפייה בהזמנה",
        href: "https://example.com/he/orders/2041")],
    note: "לשאלות על ההזמנה: https://example.com/he/support/orders/2041/" &
      "questions-about-your-order-and-its-delivery-schedule")

# --- securityCodeLayout -------------------------------------------------------------

proc securityCodeJapanese*(): SecurityCodeLayoutProps =
  var f = acme("Acme のログインコード", "ログインコードは 482913 です。" &
    "14:05 (UTC) まで有効です。", "ja")
  f.links = @[LayoutLink(label: "ヘルプ", href: "https://example.com/ja/help")]
  f.viewInBrowser = ""
  f.address = "Acme株式会社 〒100-0001 東京都千代田区1-1"
  f.reason = "Acme アカウントのログインがリクエストされたため、" &
    "このメールをお送りしています。"
  f.legal = "© 2026 Acme株式会社"
  f.unsubscribeLabel = "配信停止"
  f.preferencesLabel = "通知設定"
  SecurityCodeLayoutProps(
    frame: f,
    heading: "ログインコード",
    intro: "Acme にログインするには、次のコードを入力してください。" &
      "コードは一度だけ使用できます。",
    code: "482913", expires: "14:05 UTC",
    codeLabel: "あなたのコード", expiresLabel: "有効期限",
    magicLink: "https://example.com/ja/magic?t=8c1f", cta: "ワンクリックでログイン",
    warningLabel: "ご注意",
    warningTitle: "心当たりがない場合",
    warning: "このリクエストに心当たりがない場合は、このメールを無視してください。" &
      "パスワードは変更されません。",
    content: proc(r: EmailRenderer; parent: EmailNode) =
      discard r.node(parent, "mailDividerLabel", text = "または")
      let p = r.node(parent, "p", styles = [("margin", "0")])
      r.appendChild(p, r.createTextNode("ボタンが機能しない場合は、" &
        "次のリンクをブラウザに貼り付けてください: "))
      discard r.node(p, "a", [("href", "https://example.com/ja/magic?t=8c1f")],
        text = "https://example.com/ja/magic?t=8c1f"))

# --- alertLayout --------------------------------------------------------------------

proc alertCritical*(): AlertLayoutProps =
  AlertLayoutProps(
    frame: acme("Critical: API error rate above 5%", "api-gateway in " &
      "eu-west-1 has returned 5xx errors for 12 minutes."),
    severity: asCritical,
    heading: "API error rate above 5%",
    status: "api-gateway is failing requests",
    summary: "5.8% of requests to api-gateway have failed with a 5xx " &
      "status for the last 12 minutes. The on-call engineer has been paged.",
    facts: @[LayoutRow(label: "Service", value: "api-gateway"),
      LayoutRow(label: "Region", value: "eu-west-1"),
      LayoutRow(label: "Started", value: "4 October 2026, 13:52 UTC"),
      LayoutRow(label: "Error rate", value: "5.8% (threshold 5%)",
        emphasis: true)],
    codeTitle: "Last errors",
    code: "13:58:02 ERROR upstream timeout after 30000ms " &
      "host=orders-7f9c4b5d8-x2kqz.orders.svc.cluster.local\n" &
      "13:58:03 ERROR GET /v1/orders/2041/" & longWord &
      " 502 Bad Gateway\n13:58:05 WARN  retry 3/3 exhausted",
    actions: @[LayoutLink(label: "Open the incident",
        href: "https://status.example.com/incidents/731"),
      LayoutLink(label: "View the dashboard",
        href: "https://grafana.example.com/d/api-gateway")],
    content: proc(r: EmailRenderer; parent: EmailNode) =
      let tiles = r.node(parent, "mailStatTiles")
      discard r.node(tiles, "mailStat", [("value", "5.8%"),
        ("label", "Errors"), ("tone", "danger")])
      discard r.node(tiles, "mailStat", [("value", "2.4 s"),
        ("label", "p95 latency"), ("tone", "warning")])
      discard r.node(tiles, "mailStat", [("value", "1,204"),
        ("label", "Users affected")])
      let tl = r.node(parent, "mailTimeline")
      discard r.node(tl, "mailTimelineEvent", [("time", "13:52")],
        text = "Error rate crossed 5%.")
      discard r.node(tl, "mailTimelineEvent", [("time", "13:54")],
        text = "On-call engineer paged.")
      discard r.node(tl, "mailTimelineEvent", [("time", "14:04")],
        text = "Rollback of release 2026.10.4 started.")
      let p = r.node(parent, "p", styles = [("margin", "0")])
      r.appendChild(p, r.createTextNode("To silence this alert, run "))
      discard r.node(p, "codeInline", text = "acme alerts mute 731")
      r.appendChild(p, r.createTextNode(".")))

proc alertArabic*(): AlertLayoutProps =
  var f = acme("تحذير: استخدام التخزين أعلى من ٨٠٪", "مساحة التخزين " &
    "في مشروعك ستنفد خلال ثلاثة أيام.", "ar", "rtl")
  f.links = @[LayoutLink(label: "المساعدة", href: "https://example.com/ar/help")]
  f.address = "شركة أكمي، ١ شارع المثال، الرياض"
  f.reason = "تصلك هذه الرسالة لأن لديك حسابًا في أكمي."
  f.legal = "© ٢٠٢٦ شركة أكمي. جميع الحقوق محفوظة."
  f.viewInBrowserLabel = "عرض في المتصفح"
  f.unsubscribeLabel = "إلغاء الاشتراك"
  f.preferencesLabel = "التفضيلات"
  AlertLayoutProps(
    frame: f,
    severity: asWarning,
    severityLabel: "تحذير",
    heading: "استخدام التخزين أعلى من ٨٠٪",
    status: "ستنفد المساحة خلال ثلاثة أيام",
    summary: "يستخدم مشروعك ٨٤٪ من مساحة التخزين. بهذا المعدل ستنفد " &
      "المساحة يوم الأربعاء.",
    factsCaption: "التفاصيل",
    facts: @[LayoutRow(label: "المشروع", value: "متجر أكمي"),
      LayoutRow(label: "المستخدم", value: "٨٤ من ١٠٠ غيغابايت"),
      LayoutRow(label: "النمو اليومي", value: "٥٫٢ غيغابايت")],
    actions: @[LayoutLink(label: "زيادة المساحة",
        href: "https://example.com/ar/storage/upgrade"),
      LayoutLink(label: "عرض الاستخدام",
        href: "https://example.com/ar/storage")])

# --- digestLayout ---------------------------------------------------------------------

proc digestItems(count: int): seq[DigestItem] =
  const photos = [("A coastline at dusk", "coast"), ("A city at night",
    "city"), ("A field of wheat", "field"), ("A forest path", "forest"),
    ("A lake under hills", "lake"), ("Dunes in the desert", "desert")]
  for i in 0 ..< count:
    let (alt, key) = photos[i mod photos.len]
    let image = case key
      of "coast": coast
      of "city": city
      of "field": field
      of "forest": forest
      of "lake": lake
      else: desert
    result.add(DigestItem(title: "Story " & $(i + 1) & ": a field guide " &
      "to quiet places", body: "Six small towns where the evenings are " &
      "long and the trains still stop. A slow weekend, planned for you.",
      image: image, imageAlt: alt,
      cta: "Read the story", href: "https://example.com/stories/" & $(i + 1)))

proc digestGrid*(): DigestLayoutProps =
  var items = digestItems(4)
  items[1].title = "The longest word we know"
  items[1].body = longWord & " is not in the dictionary, but it is in " &
    "this card."
  items[3].image = missingImage
  items[3].imageAlt = "A photograph that did not load"
  items[3].crop = false
  DigestLayoutProps(
    frame: acme("This week at Acme", "Four stories, a sale and a letter " &
      "from a reader."),
    hero: DigestHero(title: "The autumn issue", text: "Long evenings, " &
      "short trips, and the prints our readers sent in.", image: hero,
      cta: "Read the issue", href: "https://example.com/issues/autumn"),
    heading: "This week",
    intro: "Four stories we think you'll like.",
    arrangement: daGrid, columns: 2, items: items,
    content: proc(r: EmailRenderer; parent: EmailNode) =
      let q = r.node(parent, "mailQuote", [("name", "Amara Okafor"),
        ("role", "Reader since 2019"), ("avatar", amber)])
      discard r.node(q, "p", text = "The coastline print is the first " &
        "thing I see every morning. It still makes me smile."))

proc digestZigZag*(): DigestLayoutProps =
  DigestLayoutProps(
    frame: acme("Three slow weekends", "A zig-zag of stories, a gallery " &
      "and the app."),
    heading: "Three slow weekends",
    intro: "Picked by our editors, one for each mood.",
    arrangement: daZigZag, items: digestItems(3),
    content: proc(r: EmailRenderer; parent: EmailNode) =
      let h = r.node(parent, "h2", text = "From our readers")
      r.setStyle(h, "margin", "0")
      let g = r.node(parent, "mailGallery", [("ratio", "1:1"),
        ("columns", "3")])
      for (src, alt) in [(coast, "A coastline at dusk"), (lake,
          "A lake under hills"), (field, "A field of wheat")]:
        discard r.node(g, "mailImage", [("src", src), ("alt", alt),
          ("href", "https://example.com/gallery")])
      let b = r.node(parent, "mailAppBadges")
      discard r.node(b, "mailAppBadge", [("store", "apple"),
        ("href", "https://apps.example.com/ios"), ("image", badgeIos),
        ("dark_image", badgeIosDark), ("width", "135")])
      discard r.node(b, "mailAppBadge", [("store", "google"),
        ("href", "https://apps.example.com/android"), ("image",
        badgeAndroid), ("dark_image", badgeAndroidDark), ("width", "135")]))

proc digestNearBudget*(): DigestLayoutProps =
  ## Enough cards to bring the message close to (and under) the 90 KB
  ## clipping budget.
  DigestLayoutProps(
    frame: acme("The long list", "Every story of the season, near the " &
      "size a message can be before it is clipped."),
    heading: "Every story of the season",
    intro: "A long digest: it stays under the 90 KB that Gmail shows " &
      "before it clips a message.",
    arrangement: daGrid, columns: 2, items: digestItems(nearBudgetCards))

# --- transactionalLayout -------------------------------------------------------------

const releaseNotes* = """
# What changed

Release **2026.10** is out. Deployments are *faster*, logs are easier to
search, and `ACME_LEGACY_ROUTES` is on its way out.

## Highlights

- Builds start up to **40% sooner** on warm runners.
- Log search understands `status:5xx` and `path:/v1/*`.
- The CLI prints a summary after `acme deploy`.

1. Update the CLI: `acme self-update`.
2. Run your next deploy as usual.

```
$ acme deploy --env production
Deploying web@2026.10 to production... done in 41s
```

> "The new log search saved our on-call rotation an hour on Tuesday."
> — a customer

---

| Plan | Build minutes | Price |
|---|---|---|
| Hobby | 500 | Free |
| Team | 5,000 | $20 |

:::warning
`ACME_LEGACY_ROUTES` is ignored from 1 November. Read the
[migration guide](https://example.com/docs/routes) before then.
:::

Thanks for building with us.\
The Acme team
"""
  ## The Markdown body of `notificationMarkdown`: every construct the
  ## element reads.

proc notificationMarkdown*(): TransactionalLayoutProps =
  TransactionalLayoutProps(
    frame: acme("Release 2026.10 is out", "Faster deploys, better log " &
      "search, and one setting going away."),
    heading: "Release 2026.10",
    intro: "Here is what changed this month.",
    markdown: releaseNotes,
    actions: @[LayoutLink(label: "Read the changelog",
      href: "https://example.com/changelog/2026.10")])

proc shippingChinese*(): TransactionalLayoutProps =
  var f = acme("您的订单已发货", "订单 2041 已发货，预计 10 月 7 日送达。",
    "zh-Hans")
  f.links = @[LayoutLink(label: "订单", href: "https://example.com/zh/orders"),
    LayoutLink(label: "帮助", href: "https://example.com/zh/help")]
  f.address = "Acme 有限公司，上海市示例路 1 号"
  f.reason = "您收到此邮件是因为您在 Acme 下了订单。"
  f.legal = "© 2026 Acme 有限公司 保留所有权利。"
  f.viewInBrowserLabel = "在浏览器中查看"
  f.unsubscribeLabel = "退订"
  f.preferencesLabel = "通知设置"
  TransactionalLayoutProps(
    frame: f,
    heading: "您的订单已发货",
    intro: "订单 2041 正在运送途中，预计 10 月 7 日（星期三）送达。",
    content: proc(r: EmailRenderer; parent: EmailNode) =
      let st = r.node(parent, "mailStepper", [("current", "2"),
        ("status", "当前步骤：已发货（第 2 步，共 4 步）"),
        ("text", "第 2 步，共 4 步：已发货。下一步：运输中。")])
      for label in ["已下单", "已发货", "运输中", "已送达"]:
        discard r.node(st, "mailStep", text = label)
      for (img, name, detail) in [(coast, "海岸风景画", "A3，哑光，1 件"),
          (forest, "橡木画框", "适用于 A3，1 件")]:
        let m = r.node(parent, "mailMediaObject", [("image", img),
          ("image_width", "96"), ("image_alt", name), ("image_ratio", "1:1")])
        let p = r.node(m, "p", styles = [("margin", "0")])
        discard r.node(p, "strong", text = name)
        discard r.node(p, "br")
        r.appendChild(p, r.createTextNode(detail))
      let tl = r.node(parent, "mailTimeline")
      discard r.node(tl, "mailTimelineEvent", [("time", "10月4日 09:12")],
        text = "包裹已从上海仓库发出。")
      discard r.node(tl, "mailTimelineEvent", [("time", "10月4日 18:40")],
        text = "包裹已到达杭州转运中心。"),
    actions: @[LayoutLink(label: "跟踪包裹",
      href: "https://example.com/zh/track/2041")])

proc surveyRequest*(): TransactionalLayoutProps =
  TransactionalLayoutProps(
    frame: acme("How did we do?", "Two quick questions about your order."),
    heading: "How did we do?",
    intro: "Your order arrived on Wednesday. Two questions, one click each.",
    content: proc(r: EmailRenderer; parent: EmailNode) =
      let q1 = r.node(parent, "h2", text = "How likely are you to " &
        "recommend Acme to a friend?")
      r.setStyle(q1, "margin", "0")
      discard r.node(parent, "mailRatingScale", [("kind", "nps"),
        ("href", "https://example.com/survey/2041?nps={score}")])
      let q2 = r.node(parent, "h2", text = "How was the delivery?")
      r.setStyle(q2, "margin", "0")
      discard r.node(parent, "mailRatingScale", [("kind", "stars"),
        ("href", "https://example.com/survey/2041?stars={score}"),
        ("low_label", "Poor"), ("high_label", "Excellent")]))

proc darkPalette*(): TransactionalLayoutProps =
  ## Every colour token of the theme, rendered under `darkMode =
  ## designed`: the surfaces, the three text colours, the border, the
  ## accent and its label, the link, and each status colour with its
  ## background.
  TransactionalLayoutProps(
    frame: acme("Your workspace this week", "Builds, deploys and alerts, " &
      "in your colours after dark."),
    heading: "Your workspace this week",
    intro: "A summary of the builds, deploys and alerts of the last " &
      "seven days.",
    content: proc(r: EmailRenderer; parent: EmailNode) =
      let line = r.node(parent, "p", styles = [("margin", "0")])
      for (tone, label) in [("success", "4 deploys"), ("info", "12 builds"),
          ("warning", "1 slow build"), ("danger", "1 alert"),
          ("primary", "New"), ("neutral", "Archived")]:
        discard r.node(line, "mailBadge", [("tone", tone)], text = label)
        r.appendChild(line, r.createTextNode(" "))
      let tiles = r.node(parent, "mailStatTiles")
      discard r.node(tiles, "mailStat", [("value", "99.98%"),
        ("label", "Uptime"), ("tone", "success")])
      discard r.node(tiles, "mailStat", [("value", "41 s"),
        ("label", "Deploy time"), ("tone", "info")])
      discard r.node(tiles, "mailStat", [("value", "1"),
        ("label", "Open alerts"), ("tone", "danger")])
      for (tone, title, body) in [("success", "All deploys succeeded",
          "Four deploys to production, none rolled back."),
          ("info", "Builds are faster", "Warm runners cut start-up by 40%."),
          ("warning", "One slow build", "web#812 took 9 minutes; the " &
            "cache was cold."),
          ("danger", "One open alert", "Disk use on db-2 is above 80%.")]:
        let c = r.node(parent, "mailCallout", [("tone", tone),
          ("title", title)])
        discard r.node(c, "p", text = body)
      r.keyValue(parent, "This week", [LayoutRow(label: "Builds",
        value: "12"), LayoutRow(label: "Deploys", value: "4"),
        LayoutRow(label: "Alerts", value: "1")])
      let cb = r.node(parent, "mailCodeBlock")
      r.appendChild(cb, r.createTextNode("$ acme status\nweb  healthy\n" &
        "db-2 disk 82%"))
      let card = r.node(parent, "mailCard", [("title", "Your plan"),
        ("level", "h2"),
        ("cta", "Manage plan"), ("cta_href", "https://example.com/plan")])
      discard r.node(card, "p", text = "Team plan, 5 seats, renews on " &
        "1 November.")
      let note = r.node(parent, "p", styles = [("margin", "0")])
      r.setStyle(note, "color", tok"color.text.secondary")
      r.appendChild(note, r.createTextNode("Read the "))
      discard r.node(note, "a", [("href", "https://example.com/docs")],
        text = "documentation")
      r.appendChild(note, r.createTextNode(" for every setting.")),
    actions: @[LayoutLink(label: "Open the workspace",
        href: "https://example.com/workspace"),
      LayoutLink(label: "Alert settings",
        href: "https://example.com/alerts")])

# --- Composed from the frame ---------------------------------------------------------

type EventInvitation* = object
  ## The fixed data of `eventInvitation`.
  frame*: LayoutFrame
  title*, intro*: string

proc eventInvitationTemplate*(r: EmailRenderer; d: EventInvitation):
    EmailNode =
  ## The event invitation of layout-patterns.md §4.6: header, hero,
  ## event, button group, footer; with the speakers and a countdown.
  result = r.layoutDocument(d.frame)
  let h = r.node(result, "mailHero", [("vertical_align", "middle")],
    [("background-color", "#1b2a4a"), ("background-image", hero),
    ("min-height", "260px"), ("text-align", "center")])
  discard r.node(h, "h1", styles = [("color", "#ffffff"),
    ("margin", "0 0 8px")], text = "Acme Build Day 2026")
  discard r.node(h, "p", styles = [("color", "#ffffff"), ("margin", "0")],
    text = "A day of talks on shipping software, in Springfield and online.")
  let stack = r.contentCard(result)
  r.heading(stack, d.title, d.intro, "h2")
  let e = r.node(stack, "mailEvent", [("month", "Nov"), ("day", "14"),
    ("date_text", "Saturday, 14 November 2026, 09:30–17:00 CET"),
    ("location", "Springfield Hall, 1 Example Street"),
    ("google", "https://calendar.example.com/google/build-day"),
    ("outlook", "https://calendar.example.com/outlook/build-day"),
    ("ics", "https://calendar.example.com/build-day.ics")])
  discard r.node(e, "h3", styles = [("margin", "0 0 4px")],
    text = "Build Day 2026")
  discard r.node(e, "p", styles = [("margin", "0")], text = "Twelve " &
    "talks, two workshops, and lunch with the people who build Acme.")
  discard r.node(stack, "mailCountdown", [("src", countdown),
    ("width", "280"), ("deadline_text", "Early-bird tickets end " &
    "31 October 2026, 23:59 CET"), ("href", "https://example.com/tickets")])
  let sp = r.node(stack, "h2", text = "Speakers")
  r.setStyle(sp, "margin", "0")
  discard r.node(stack, "mailAvatarName", [("name", "Amara Okafor"),
    ("role", "Staff engineer, Acme"), ("avatar", amber)])
  discard r.node(stack, "mailAvatarName", [("name", "Leo Marchetti"),
    ("role", "Head of platform, Example Corp"), ("avatar", indigo)])
  r.buttonGroup(stack, [LayoutLink(label: "Register",
      href: "https://example.com/build-day/register"),
    LayoutLink(label: "See the programme",
      href: "https://example.com/build-day")])
  r.layoutFooter(result, d.frame)

type NewsletterColumns* = object
  ## The fixed data of `newsletterColumns`.
  frame*: LayoutFrame

proc column(r: EmailRenderer; section: EmailNode; title, body: string;
    image = ""; imageAlt = ""; level = "h2") =
  let c = r.node(section, "mailColumn")
  if image.len > 0:
    # Half of a 600px message, less the column's 24px gutters.
    discard r.node(c, "mailImage", [("src", image), ("alt", imageAlt),
      ("fluid_on_mobile", "true")], [("width", "252px")])
    discard r.node(c, "mailSpacer", styles = [("height", "12px")])
  discard r.node(c, level, styles = [("margin", "0 0 8px")], text = title)
  # The bottom margin spaces the columns when they stack on a phone.
  discard r.node(c, "p", styles = [("margin", "0 0 16px")], text = body)

proc newsletterColumnsTemplate*(r: EmailRenderer; d: NewsletterColumns):
    EmailNode =
  ## Sections of one, two, three and four columns, a full-bleed band,
  ## a wrapper of two sections, a navigation row, a non-stacking group,
  ## rich text, a data table, a Word-only note and a raw snippet.
  result = r.layoutDocument(d.frame)
  let navBand = r.node(result, "mailSection", styles = [("padding",
    "0 0 16px")])
  let nav = r.node(navBand, "mailNavLinks", [("separator", "·")])
  for (label, href) in [("Prints", "https://example.com/prints"),
      ("Frames", "https://example.com/frames"),
      ("Journal", "https://example.com/journal"),
      ("Sale", "https://example.com/sale")]:
    discard r.node(nav, "a", [("href", href)], text = label)
  let one = r.node(result, "mailSection")
  r.setStyle(one, "background-color", tok"color.surface.card")
  column(r, one, "The October newsletter", "One column: the news of " &
    "the month, in a single block of text across the whole message.",
    level = "h1")
  let two = r.node(result, "mailSection")
  r.setStyle(two, "background-color", tok"color.surface.card")
  column(r, two, "Coast", "Two columns: each half the width, side by " &
    "side, stacked on a phone.", coast, "A coastline at dusk")
  column(r, two, "City", "The second of two columns, an image above " &
    "its text like the first.", city, "A city at night")
  let three = r.node(result, "mailSection")
  r.setStyle(three, "background-color", tok"color.surface.card")
  for (t, b) in [("Prints", "Archival inks on cotton paper."),
      ("Frames", "Solid oak, made to order."),
      ("Gifts", "Cards for the prints you love.")]:
    column(r, three, t, b)
  let band = r.node(result, "mailBand", [("background_color", "#e8eefc"),
    ("text_align", "center")])
  for (t, b) in [("12", "new prints"), ("4", "frames"), ("2", "shops"),
      ("1", "sale")]:
    let c = r.node(band, "mailColumn")
    let p = r.node(c, "p", styles = [("margin", "0")])
    discard r.node(p, "strong", styles = [("font-size", "28px"),
      ("line-height", "36px")], text = t)
    discard r.node(p, "br")
    r.appendChild(p, r.createTextNode(b))
  let w = r.node(result, "mailWrapper", styles = [("padding", "16px 24px"),
    ("border", "1px solid #e5e7eb")])
  r.setStyle(w, "background-color", tok"color.surface.subtle")
  let w1 = r.node(w, "mailSection", styles = [("padding", "8px 0")])
  let txt = r.node(w1, "mailText")
  discard r.node(txt, "h2", styles = [("margin", "0 0 8px")],
    text = "In the shop")
  let tp = r.node(txt, "p", styles = [("margin", "0")])
  r.appendChild(tp, r.createTextNode("Rich text in a wrapper: "))
  discard r.node(tp, "strong", text = "bold")
  r.appendChild(tp, r.createTextNode(", "))
  discard r.node(tp, "em", text = "italic")
  r.appendChild(tp, r.createTextNode(" and a "))
  discard r.node(tp, "a", [("href", "https://example.com/shop")],
    text = "link to the shop")
  r.appendChild(tp, r.createTextNode("."))
  let w2 = r.node(w, "mailSection", styles = [("padding", "8px 0")])
  let grp = r.node(w2, "mailGroup")
  for (t, b) in [("Mon–Fri", "9:00–18:00"), ("Sat", "10:00–16:00")]:
    let c = r.node(grp, "mailColumn")
    discard r.node(c, "p", styles = [("margin", "0")], text = t & ": " & b)
  let tableBand = r.node(result, "mailSection")
  r.setStyle(tableBand, "background-color", tok"color.surface.card")
  let mt = r.node(tableBand, "mailTable", [("caption", "Opening hours " &
    "of our shops")])
  let table = r.node(mt, "table")
  let thead = r.node(table, "thead")
  let hr = r.node(thead, "tr")
  # Short labels: three columns fit a 320px phone's content box.
  for h in ["Shop", "Mon–Fri", "Sat"]:
    discard r.node(hr, "th", text = h)
  let tbody = r.node(table, "tbody")
  for row in [["Springfield", "9–18", "10–16"], ["Shelbyville", "10–19",
      "Closed"]]:
    let tr = r.node(tbody, "tr")
    for cell in row:
      discard r.node(tr, "td", text = cell)
  discard r.node(tableBand, "mailDivider")
  let note = r.node(tableBand, "mailIf", [("mso", "true")])
  discard r.node(note, "p", styles = [("margin", "0")], text = "Reading " &
    "this in Outlook? The web version shows every image.")
  let rawBlock = r.node(tableBand, "mailRaw")
  r.appendChild(rawBlock, raw("<p style=\"margin:0;" &
    "font-family:Helvetica, Arial, sans-serif;font-size:14px;" &
    "line-height:20px;color:#4b5563;\">Printed and framed in " &
    "Springfield.</p>"))
  r.layoutFooter(result, d.frame)

proc eventInvitationData*(): EventInvitation =
  EventInvitation(frame: acme("You're invited: Acme Build Day 2026",
    "Saturday, 14 November, in Springfield and online."),
    title: "You're invited", intro: "Join us for a day of talks on " &
    "shipping software.")

proc newsletterColumnsData*(): NewsletterColumns =
  NewsletterColumns(frame: acme("The October newsletter", "Prints, " &
    "frames and the shops' opening hours."))

# --- The set ---------------------------------------------------------------------------

template entry(n, desc, lay: string; isDark: bool; tpl: untyped;
    data: untyped): ReferenceEmail =
  ReferenceEmail(name: n, description: desc, layout: lay, dark: isDark,
    tree: proc(): EmailNode = renderAuthoringTree(tpl, data),
    render: proc(target: EmailTarget; assets: AssetStore): RenderedEmail =
      var t = target
      if isDark:
        t.darkMode = dmDesigned
      renderEmail(tpl, data, target = t, assets = assets))

proc referenceEmails*(): seq[ReferenceEmail] =
  ## The reference set, in a stable order.
  @[
    entry("receiptTypical", "Receipt: summary, three line items with " &
      "thumbnails, totals, a badge and a coupon.", "receiptLayout", false,
      receiptLayout, receiptTypical()),
    entry("receiptHebrew", "Receipt in Hebrew (right to left), with long " &
      "unbroken words, a long URL and a thumbnail that is missing (404).",
      "receiptLayout", false, receiptLayout, receiptHebrew()),
    entry("securityCodeJapanese", "Login code in Japanese, with a magic " &
      "link and the didn't-request-this warning.", "securityCodeLayout",
      false, securityCodeLayout, securityCodeJapanese()),
    entry("alertCritical", "Critical incident: severity band, key facts, " &
      "stat tiles, a timeline and log lines with long tokens.",
      "alertLayout", false, alertLayout, alertCritical()),
    entry("alertArabic", "Storage warning in Arabic (right to left).",
      "alertLayout", false, alertLayout, alertArabic()),
    entry("digestGrid", "Digest: text over a hero image, a grid of four " &
      "cards (one image missing), a reader's quote.", "digestLayout", false,
      digestLayout, digestGrid()),
    entry("digestZigZag", "Digest as a zig-zag, a gallery and app badges.",
      "digestLayout", false, digestLayout, digestZigZag()),
    entry("digestNearBudget", "Digest near the 90 KB clipping budget.",
      "digestLayout", false, digestLayout, digestNearBudget()),
    entry("notificationMarkdown", "Release notes written in Markdown: " &
      "every construct mailMarkdown reads.", "transactionalLayout", false,
      transactionalLayout, notificationMarkdown()),
    entry("shippingChinese", "Shipping update in Chinese: stepper, the " &
      "items as media objects, a timeline.", "transactionalLayout", false,
      transactionalLayout, shippingChinese()),
    entry("surveyRequest", "Survey: an NPS scale and a star rating.",
      "transactionalLayout", false, transactionalLayout, surveyRequest()),
    entry("darkPalette", "Weekly summary in the designed dark palette: " &
      "every colour token of the theme.", "transactionalLayout", true,
      transactionalLayout, darkPalette()),
    entry("eventInvitation", "Event invitation: hero, event, countdown, " &
      "speakers, buttons.", "", false, eventInvitationTemplate,
      eventInvitationData()),
    entry("newsletterColumns", "Newsletter: sections of one to four " &
      "columns, a band, a wrapper, a group, a table, a Word-only note.",
      "", false, newsletterColumnsTemplate, newsletterColumnsData()),
  ]
