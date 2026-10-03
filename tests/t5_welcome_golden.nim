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
## Backend-independent (tree building + pure passes; the golden loads
## via `staticRead`), so `just test` also runs it on JS. No test doubles.
# rule: R-BTN-01
import std/[os, strutils, unittest]
import isonim_email

const golden = staticRead(parentDir(currentSourcePath()) / "golden" /
  "welcome-minimal.html")

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
    check res.diagnostics.len == 0
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
    # No responsive block and no dark block.
    check "@media" notin html
    check "prefers-color-scheme" notin html
    # The button: 20px line + 2 x 12px = 44px.
    check "line-height:20px;" in html and "padding:12px 24px;" in html
    check "mso-padding-alt:12px 24px;" in html
    # The preheader padding: 100 - 22 characters.
    check html.count("&#847;&zwnj;&nbsp;") == 78
