## The worked example's golden: story `welcome/minimal` (a heading, a
## paragraph and a button in a single-column card on the canvas),
## rendered with `outlookWord` on and the default `darkMode =
## dmAccommodate` (so no dark block), byte-exact against
## `tests/golden/welcome-minimal.html`. The structural checks below pin
## what the example demonstrates independently of the bytes: a
## single-column section with no column scaffolding (its padding merged
## into the inner div and mirrored on the Outlook ghost cell), the
## section background on the div and the ghost cell, no responsive and
## no dark block, the table button with a 44px tap target, and the
## preheader padded to 100 characters.
##
## Golden recorded 2026-10-03 from the render below; changed only on
## purpose, with the reason recorded here.
##
## The `darkMode = dmDesigned` golden, `tests/golden/welcome-minimal-designed.html`,
## recorded 2026-10-03 from the same template rendered designed: the
## accommodate golden plus block 3 and the dark classes, which its
## structural test checks by removing both. Changed only on purpose.
##
## Golden update, 2026-10-03 (catalogue §1 and R-DRK-08, amended first):
## both goldens gained block 6, Thunderbird's one-rule `<style>`
## (`html:has(.moz-text-html){filter:url("#prefers-color-scheme:
## dark")}`), which tells Thunderbird that the message handles its own
## colours (the colour-scheme metas say so to every other client). The
## designed golden's block 3 also gained Thunderbird's `light-dark()`
## copies of its rules after the query, and its seven dark classes were
## renamed: a dark class is now named after both values of each
## declaration (R-DRK-02), so its copy can carry the light one. The
## accommodate golden's diff is that one element; every other byte of
## both is unchanged, and the designed golden less block 3 and its
## classes is still the accommodate golden byte for byte (the test
## below).
##
## Golden update, 2026-10-04 (catalogue §1 and R-TBL-17, amended
## first): in both goldens the wrapper table and the button's outer
## one-cell table (the one that contains its float) gained
## `table-layout:fixed;` at the end of their `style` (two declarations
## per golden), the reset's fixed layout written inline, so a long
## unbroken word cannot widen the message where head CSS is stripped.
## Every other byte is unchanged.
##
## Both renders carry one diagnostic, pinned below: information on the
## button's label under the inversion simulation's full model, not yet
## calibrated (catalogue R-DRK-04).
##
## Backend-independent (tree building + pure passes; the golden loads
## via `staticRead`), so `just test` also runs it on JS. No test doubles.
# rule: R-BTN-01
import std/[os, strutils, unittest]
import isonim_email

const golden = staticRead(parentDir(currentSourcePath()) / "golden" /
  "welcome-minimal.html")
const designedGolden = staticRead(parentDir(currentSourcePath()) /
  "golden" / "welcome-minimal-designed.html")

type Welcome = object
  name, url: string

proc welcomeMinimal*(r: EmailRenderer; d: Welcome): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Welcome to Metacraft",
                 preheader = "Your account is ready.",
                 background_color = tok"color.surface.canvas"):
      mailSection(background_color = tok"color.surface.card"):
        mailColumn:
          h1: text "Welcome, " & d.name
          p: text "Your account is ready."
          mailButton(href = d.url): text "Open dashboard"

story "welcome/minimal", welcomeMinimal, Welcome(name: "Ada",
  url: "https://app.example.com/")

suite "the worked example's golden":
  test "test_welcome_minimal_golden":
    let res = renderEmail(welcomeMinimal, Welcome(name: "Ada",
      url: "https://app.example.com/"))
    # One diagnostic, information: the button's white label on the
    # accent falls below 4.5:1 under R-DRK-04's full-inversion model,
    # which is not calibrated yet (the Gmail app on iOS). Nothing else.
    check res.diagnostics.len == 1
    check res.diagnostics[0].code == codeA11yContrastInvertedInfo
    check res.diagnostics[0].severity == sevInfo
    check "#ffffff on #1f6feb" in res.diagnostics[0].message
    check "full inversion" in res.diagnostics[0].message
    check res.html == golden
    # The registered story renders the same bytes.
    check getStory("welcome/minimal").render().html == golden

  test "test_welcome_minimal_structure":
    let html = renderEmail(welcomeMinimal, Welcome(name: "Ada",
      url: "https://app.example.com/")).html
    # Div-first: no column scaffolding; 24px 0 + 0 24px merge into 24px,
    # on the inner div and on the ghost cell, with the card colour.
    check "<td bgcolor=\"#ffffff\" style=\"padding:24px;" &
      "background-color:#ffffff;\">" in html
    check "<div style=\"margin:0 auto;max-width:600px;" &
      "background-color:#ffffff;\"><div align=\"left\" " &
      "style=\"padding:24px;font-size:16px;text-align:left;" &
      "direction:ltr;\">" in html
    check "e-col" notin html
    # The canvas in its three places.
    check html.count("background-color:#f4f5f7;") == 3
    # No responsive block and no dark block; Thunderbird's block rides
    # with the metas and recolours nothing (R-DRK-08).
    check "@media" notin html
    check "light-dark(" notin html
    check html.count("<style>") == 3
    check "<style>html:has(.moz-text-html){filter:url(\"#prefers-color-" &
      "scheme: dark\")}</style>" in html
    # The button: 20px line + 2 x 12px = 44px.
    check "line-height:20px;" in html and "padding:12px 24px;" in html
    check "mso-padding-alt:12px 24px;" in html
    # The preheader padding: 100 - 22 characters.
    check html.count("&#847;&zwnj;&nbsp;") == 78

proc designedTarget(): EmailTarget =
  result = defaultTarget()
  result.darkMode = dmDesigned

proc withoutDarkCss(html: string): string =
  ## `html` less block 3 (the third `<style>` element, the one holding
  ## the dark rules) and every generated class attribute.
  result = html
  let q = result.find("(prefers-color-scheme: dark)")
  if q >= 0:
    let a = result.rfind("<style>", last = q)
    let b = result.find("</style>", q) + "</style>".len
    result = result[0 ..< a] & result[b .. ^1]
  while true:
    let i = result.find(" class=\"e-")
    if i < 0:
      break
    let j = result.find('"', i + " class=\"".len)
    result = result[0 ..< i] & result[j + 1 .. ^1]

suite "the worked example's designed golden":
  test "test_welcome_minimal_designed_golden":
    # The `dmDesigned` variant: the same story, its dark palette from
    # the tokens it already uses (no `@dark:` in the template).
    let res = renderEmail(welcomeMinimal, Welcome(name: "Ada",
      url: "https://app.example.com/"), target = designedTarget())
    # The designed dark scheme passes; the inversion simulation's one
    # finding (information) is the accommodate golden's (the button
    # under full inversion).
    check res.diagnostics.len == 1
    check res.diagnostics[0].code == codeA11yContrastInvertedInfo
    check res.html == designedGolden

  test "test_welcome_minimal_designed_is_the_golden_plus_dark_css":
    # Removing block 3 and the dark classes gives the accommodate golden
    # back byte for byte: designed adds dark CSS and nothing else.
    check designedGolden != golden
    check withoutDarkCss(designedGolden) == golden
    # Block 3: the media query and the Outlook copies, the page below
    # the message on `body`, and a class on every recoloured element:
    # the wrapper and its table (the canvas), the card, the heading, the
    # paragraph, and the button's cell and link.
    check "@media (prefers-color-scheme: dark){" in designedGolden
    check "body{background-color:#0f1115 !important}" in designedGolden
    check "[data-ogsb] ." in designedGolden
    check "[data-ogsc] ." in designedGolden
    # Thunderbird's copies: one per class rule, and the page below.
    check designedGolden.count(".moz-text-html .e-") == 4
    check "body:has(.moz-text-html){background-color:light-dark(#f4f5f7," &
      "#0f1115) !important}" in designedGolden
    check designedGolden.count(" class=\"e-") == 7
    check "<body xml:lang=\"en\" style=" in designedGolden
