## The review-brief generator.
##
## The per-(story, family, viewport, scheme) block derives from the
## rendered semantic tree: headings, buttons, images, column
## arrangement, footer, dark palette and declared degradations. Carries
## the two-column fixture story and the button-removal falsifying
## mutation (performed on a variant builder; the fixture itself is the
## revert control).
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS.
import std/[strutils, unittest]
import isonim_email
import stories/email_stories
import stories/seed_receipt
import stories/seed_alert

registerSeedStories()
registerStoryTree("canary", canaryDoc)
registerStoryTree("receipt", proc(): EmailNode = seedReceipt())
registerStoryTree("alert", proc(): EmailNode = seedAlert())

proc seedTwoColumn*(includeButton = true): EmailNode =
  ## Two-column brief fixture: an `h1`, an optional rounded CTA
  ## button, a hybrid two-column row (`h2` + copy per column), a logo
  ## image and a footer section with Unsubscribe/Preferences links.
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Two columns")
  r.setAttribute(doc, "preheader", "Two columns side by side.")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Two columns, one brief")
  r.appendChild(doc, h1)
  if includeButton:
    let btn = r.createElement("mailButton")
    r.setAttribute(btn, "href", "https://x.test/pay")
    r.setStyle(btn, "background_color", "#1f6feb")
    r.setStyle(btn, "color", "#ffffff")
    r.setStyle(btn, "border_radius", "6px")
    r.setTextContent(btn, "Pay $42.00")
    r.appendChild(doc, btn)
  let cols = r.createElement("mailColumns")
  r.setAttribute(cols, "strategy", "hybrid")
  for pair in [("Left", "Copy on the left."),
      ("Right", "Copy on the right.")]:
    let col = r.createElement("mailColumn")
    let h2 = r.createElement("h2")
    r.setTextContent(h2, pair[0])
    r.appendChild(col, h2)
    let p = r.createElement("p")
    r.setTextContent(p, pair[1])
    r.appendChild(col, p)
    r.appendChild(cols, col)
  r.appendChild(doc, cols)
  let img = r.createElement("mailImage")
  r.setAttribute(img, "src", "https://x.test/logo.png")
  r.setAttribute(img, "alt", "Acme logo")
  r.setStyle(img, "width", "140px")
  r.setAttribute(img, "align", "left")
  r.appendChild(doc, img)
  let foot = r.createElement("mailSection")
  let unsub = r.createElement("a")
  r.setAttribute(unsub, "href", "https://x.test/unsub?x=1")
  r.setTextContent(unsub, "Unsubscribe")
  r.appendChild(foot, unsub)
  let prefs = r.createElement("a")
  r.setAttribute(prefs, "href", "https://x.test/prefs")
  r.setTextContent(prefs, "Preferences")
  r.appendChild(foot, prefs)
  r.appendChild(doc, foot)
  doc

const twoColumnText = "Two columns, one brief\n\nPay $42.00\n"
  ## Fixed plain-text alternative for the fixture (the plain-text
  ## generator will produce these).

proc renderTwoColumn(): StoryHtml =
  ## The fixture through the current pipeline.
  (renderPipeline(seedTwoColumn(), defaultTarget()), twoColumnText)

registerStory(Story(name: "twoColumn", group: "brief",
  description: "Two-column brief fixture.",
  render: renderTwoColumn))
registerStoryTree("twoColumn", proc(): EmailNode = seedTwoColumn())

suite "review brief":
  test "test_expected_elements_generated_from_tree":
    # A seed story: headings, image alts, footer, no degradations.
    let receipt = expectedBlock(getStory("receipt"), "gmailWeb",
      "mobile", "light")
    check "### Expected: receipt — gmailWeb — mobile 375 — light — " &
      "backend A (emulation)" in receipt
    check "Heading \"Receipt #1234\" (largest text)." in receipt
    check "\"Acme logo\"" in receipt
    check "Footer: none (no links, no unsubscribe)." in receipt
    check "- (none)" in receipt
    check "Not expected here: dark colours (Gmail web does not " &
      "apply dark mode to the body)." in receipt
    # The fixture: button labels + colours, footer links.
    let fixture = expectedBlock(getStory("twoColumn"), "gmailWeb",
      "mobile", "light")
    check "Button \"Pay $42.00\": filled #1f6feb, #ffffff label, " &
      "rounded 6px." in fixture
    check "Logo image \"Acme logo\", ~140 px wide, left-aligned, " &
      "on #ffffff." in fixture
    check "Footer: links \"Unsubscribe\" and \"Preferences\"; " &
      "unsubscribe link present." in fixture
    # Column arrangement flips with the viewport width.
    check "Columns (2): stacked at this width." in fixture
    let wide = expectedBlock(getStory("twoColumn"), "gmailWeb",
      "desktop", "light")
    check "Columns (2): side-by-side at this width." in wide
    check "### Expected: twoColumn — gmailWeb — desktop 800 — " &
      "light — backend A (emulation)" in wide
    # Per-family degradations: rounded corners degrade in Word, and
    # nowhere else in the backend-A matrix.
    let word = expectedBlock(getStory("twoColumn"), "wordApprox",
      "desktop", "light")
    check "- button corners render square; only the label text is " &
      "a link (R-BTN-02)" in word
    let apple = expectedBlock(getStory("twoColumn"), "apple",
      "desktop", "light")
    check "- (none)" in apple
    check "backend A (local engine)" in apple
    # Falsifying mutation, performed + reverted: without the button
    # the label leaves the block; with it (above) it stays.
    registerStoryTree("twoColumn-no-button",
      proc(): EmailNode = seedTwoColumn(false))
    let mutated = Story(name: "twoColumn-no-button", group: "brief",
      description: "button-removal mutation", render: nil)
    let noBtn = expectedBlock(mutated, "gmailWeb", "mobile", "light")
    check "Pay $42.00" notin noBtn
    check "Button" notin noBtn
    check "Columns (2): stacked at this width." in noBtn

  test "test_brief_images_off_names_alt_texts":
    let off = expectedBlock(getStory("receipt"), "imagesOff",
      "mobile", "light")
    check "- \"Acme logo\" shown as alt text (images off)" in off
    check "Not expected here: hero images (shown as alt text: " &
      "\"Acme logo\")." in off

  test "test_brief_unknown_family_fails_loudly":
    var raised = false
    try:
      discard expectedBlock(getStory("receipt"), "nope", "mobile",
        "light")
    except BriefError as e:
      raised = true
      check "nope" in e.msg
    check raised
