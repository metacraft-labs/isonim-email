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
import std/[strutils, tables, unittest]
import isonim_email
import stories/email_stories
import stories/seed_receipt
import stories/seed_alert
import stories/seed_broken

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

proc renderTwoColumn(): StoryHtml =
  ## The fixture through the current pipeline, its plain-text part
  ## generated like every story's.
  renderStoryPipeline(seedTwoColumn(), defaultTarget())

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
    # A table names its rows' text, and an image without an `align` of
    # its own is centred by the skeleton's content cell.
    check "Table: 1 row: \"Widget: $10.00\"." in receipt
    check "Logo image \"Acme logo\", ~120 px wide, centred, on " &
      "#ffffff." in receipt
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
    # WebKit's one declared difference here is how it draws the logo's
    # alt text with images off (lower/image.nim); nothing degrades
    # with images on.
    check "- with images off, WebKit draws an image's alt text from " &
      "just above the image's box" in apple
    check "button corners" notin apple
    # Every brief, backend A's and a real client's, ends with the
    # standing check that no client excuses: text cut at any edge.
    check apple.endsWith("Always a defect, in every client: text cut at " &
      "any edge of the capture (the tops of the first line's letters " &
      "missing, glyphs on the first or last pixel row or column).\n")
    check "text cut at any edge of the capture" in fixture
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

  test "test_brief_columns_follow_strategy_and_client":
    # The arrangement line follows the row's strategy and what the
    # client does with head CSS: without it a hybrid row stacks at
    # every width, a Fab Four row still switches, a stacking cell row
    # stays side by side; Word shows every row side by side.
    proc rowsDoc(): EmailNode =
      let r = EmailRenderer()
      let doc = r.createElement("mailDocument")
      r.setAttribute(doc, "lang", "en")
      r.setAttribute(doc, "dir", "ltr")
      r.setAttribute(doc, "title", "Rows")
      let h1 = r.createElement("h1")
      r.setTextContent(h1, "Rows")
      r.appendChild(doc, h1)
      for strategy in ["hybrid", "fabFour", "cellsStacking", "cells"]:
        let row = r.createElement("mailColumns")
        r.setAttribute(row, "strategy", strategy)
        for t in ["A", "B"]:
          let col = r.createElement("mailColumn")
          let p = r.createElement("p")
          r.setTextContent(p, strategy & t)
          r.appendChild(col, p)
          r.appendChild(row, col)
        r.appendChild(doc, row)
      # A section of plain content is no row, whatever it holds.
      let plain = r.createElement("mailSection")
      for t in ["One", "Two"]:
        let p = r.createElement("p")
        r.setTextContent(p, t)
        r.appendChild(plain, p)
      r.appendChild(doc, plain)
      doc
    registerStoryTree("briefRows", rowsDoc)
    let rows = Story(name: "briefRows", group: "brief",
      description: "rows of every strategy", render: nil)
    proc arrangement(family, viewport: string): seq[string] =
      for line in expectedBlock(rows, family, viewport, "light").splitLines():
        if "Columns (2)" in line:
          result.add(line.split(". ", 1)[1])
    const stacked = "Columns (2): stacked at this width."
    const side = "Columns (2): side-by-side at this width."
    const cells = side & " The cells share one height."
    check arrangement("chromium-baseline", "mobile") ==
      @[stacked, stacked, stacked, cells]
    check arrangement("chromium-baseline", "desktop") ==
      @[side, side, cells, cells]
    const fabNoCss = stacked & " Without the head CSS the stacked " &
      "columns keep their half-gutter side offsets and have no gap " &
      "between them (declared, R-LAY-18)."
    check arrangement("ganga", "mobile") == @[stacked, fabNoCss, cells, cells]
    const hybridNoCss = stacked & " Without the head CSS these " &
      "columns stack at every width: that is their safe fallback (R-LAY-01)."
    check arrangement("ganga", "desktop") ==
      @[hybridNoCss, side, cells, cells]
    check arrangement("wordApprox", "mobile") == @[side, side, cells, cells]
    # A real client that strips the head CSS reads like GANGA.
    let snappy = clientExpectedBlock(rows, "snappymail", "desktop",
      "light")
    check snappy.count(stacked) == 1
    # The Fab Four keeps its lower bound there (R-LAY-18's max() width).
    check "a Fab Four row keeps its lower bound" in snappy
    check "shrink to nothing" notin snappy
    # A real client's brief ends with the same standing edge check.
    check snappy.endsWith("Always a defect, in every client: text cut " &
      "at any edge of the capture (the tops of the first line's letters " &
      "missing, glyphs on the first or last pixel row or column).\n")

  test "test_brief_images_off_names_alt_texts":
    let off = expectedBlock(getStory("receipt"), "imagesOff",
      "mobile", "light")
    check "- \"Acme logo\" shown as alt text (images off)" in off
    check "Not expected here: hero images (shown as alt text: " &
      "\"Acme logo\")." in off

  test "test_brief_direction_and_family_dark_note":
    # A right-to-left story says so (its text runs from the right); a
    # left-to-right one says nothing about direction.
    let rtl = expectedBlock(getStory("alert"), "chromium-baseline",
      "desktop", "light")
    check "Direction: right to left (`dir=\"rtl\"`, lang `ar`)" in rtl
    check "Direction:" notin expectedBlock(getStory("receipt"),
      "chromium-baseline", "desktop", "light")
    check "Direction: right to left" in clientExpectedBlock(
      getStory("alert"), "kmail", "desktop", "light")
    # Outlook web recolours the message itself in dark; the baseline
    # engine does not, and nothing is said in light.
    let owaDark = expectedBlock(getStory("receipt"), "outlookWeb",
      "desktop", "dark")
    check "Outlook web also recolours the message itself" in owaDark
    check "recolours the message itself" notin expectedBlock(
      getStory("receipt"), "chromium-baseline", "desktop", "dark")
    check "recolours the message itself" notin expectedBlock(
      getStory("receipt"), "outlookWeb", "desktop", "light")

  test "test_brief_unknown_family_fails_loudly":
    var raised = false
    try:
      discard expectedBlock(getStory("receipt"), "nope", "mobile",
        "light")
    except BriefError as e:
      raised = true
      check "nope" in e.msg
    check raised

suite "real-client briefs":
  test "test_client_brief_verification_client_stands_in_for_none":
    # A webmail verification client: the elements from the tree, the
    # stand-in statement, the sanitiser, and the dark statements only
    # in the dark scheme.
    let light = clientExpectedBlock(getStory("receipt"), "roundcube",
      "desktop", "light")
    check "### Expected: receipt — roundcube (verification) — " &
      "desktop 800 — light — selfhosted-webmail (real client)" in light
    check "This client stands in for no audience family" in light
    check "Heading \"Receipt #1234\" (largest text)." in light
    check "\"Acme logo\"" in light
    check "scopes every selector under its message wrapper" in light
    check "Elastic skin turns" notin light
    check "Dark palette" notin light
    let dark = clientExpectedBlock(getStory("receipt"), "roundcube",
      "desktop", "dark")
    check "Elastic skin turns its own chrome dark" in dark
    check "defect (R-TXT-02)" in dark
    check "Dark palette (dark): no @dark overrides — same as light." in dark
    # SnappyMail strips the head: its dark palette line says so, and
    # its degradations name the missing head CSS.
    let sm = clientExpectedBlock(getStory("alert"), "snappymail",
      "mobile", "dark")
    check "mobile 375 — dark — selfhosted-webmail" in sm
    check "the message's own dark rules do not apply" in sm
    check "- no head CSS (no responsive, dark or hover rules)" in sm
    check "Heading \"تنبيه أمني\" (largest text)." in sm
    # A desktop verification client.
    let kmail = clientExpectedBlock(getStory("alert"), "kmail",
      "desktop", "light")
    check "This client stands in for no audience family" in kmail
    check "KMail draws its own header block" in kmail
    check "linux-desktop (real client)" in kmail

  test "test_client_brief_thunderbird_is_the_audience_family":
    let tb = clientExpectedBlock(getStory("alert"), "thunderbird",
      "desktop", "dark")
    check "This is the real client of the `thunderbird` audience " &
      "family, not an emulation." in tb
    check "stands in for no audience family" notin tb
    check "never stretched to the column width" in tb
    # Thunderbird's dark mode (catalogue R-DRK-08): what it does, and
    # what it does to this message (`accommodate`: nothing).
    check "recolours a message on its own" in tb
    check "applies no `@media` rule in a message" in tb
    check "This message (`darkMode = accommodate`) keeps its light " &
      "design on Thunderbird's dark page" in tb
    check "### Expected: alert — thunderbird (thunderbird) — desktop " &
      "800 — dark — linux-desktop (real client)" in tb

  test "test_client_brief_unknown_or_drifted_client_fails":
    var raised = false
    try:
      discard clientExpectedBlock(getStory("receipt"), "mutt",
        "desktop", "light")
    except BriefError as e:
      raised = true
      check "mutt" in e.msg
    check raised
    # Claws Mail's missing bidi reordering is expected for a
    # right-to-left story only.
    check "no bidirectional reordering" in clientExpectedBlock(
      getStory("alert"), "claws-mail", "desktop", "light")
    check "no bidirectional reordering" notin clientExpectedBlock(
      getStory("receipt"), "claws-mail", "desktop", "light")
    check "no bidirectional reordering" notin clientExpectedBlock(
      getStory("alert"), "kmail", "desktop", "light")
    check briefClientMismatch("selfhosted-webmail", "verification",
      "roundcube") == ""
    check "linux-desktop/verification" in briefClientMismatch(
      "selfhosted-webmail", "verification", "kmail")
    check briefClientMismatch("linux-desktop", "verification",
      "thunderbird").len > 0
    check clientBriefName("linux-desktop", "verification", "claws-mail",
      "desktop", "light") ==
      "brief-linux-desktop-verification-claws-mail-desktop-light.md"

suite "the broken-story fixture (methodology checklist item 7)":
  test "test_broken_receipt_loses_its_logo_but_not_its_expectation":
    registerBrokenStories()
    registerStoryTree("receiptB",
      proc(): EmailNode = seedReceipt())
    let intact = getStory("receipt").render().html
    let broken = getStory("receiptB").render().html
    check "<img " in intact
    check "<img " notin broken
    # Only the image went: the rest of the output is byte-identical.
    check dropFirstImage(intact) == broken
    check broken.len < intact.len
    # The brief still expects the logo, as the intact receipt's does.
    let brief = expectedBlock(getStory("receiptB"),
      "chromium-baseline", "desktop", "light")
    check "Logo image \"Acme logo\", ~120 px wide, centred" in brief
    # The fixture refuses HTML it cannot break exactly once.
    for bad in ["<p>no image</p>", "<img src=a><img src=b>"]:
      var raised = false
      try:
        discard dropFirstImage(bad)
      except StoryError:
        raised = true
      check raised

proc markdownListDoc(): EmailNode =
  ## A Markdown body whose only list is in its source.
  let r = EmailRenderer()
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", "en")
  r.setAttribute(result, "title", "Notes")
  let s = r.createElement("mailSection")
  r.appendChild(result, s)
  let h = r.createElement("h1")
  r.setTextContent(h, "Notes")
  r.appendChild(s, h)
  let md = r.createElement("mailMarkdown")
  r.setAttribute(md, "src", "Steps:\n\n- one\n- two")
  r.appendChild(s, md)

proc markdownStrikeDoc(): EmailNode =
  ## A Markdown body with struck text.
  result = markdownListDoc()
  for c in result.children[0].children:
    if c.kind == enElement and c.tag == "mailMarkdown":
      c.attrs["src"] = "Settings are ~~old~~ gone."

suite "review brief: Markdown bodies":
  test "test_markdown_lists_declare_the_webkit_markers":
    # The WebKit builds draw no list markers; a list written in a
    # Markdown body is declared like any other list.
    registerStory(Story(name: "markdownList", group: "markdownList",
      render: proc(): StoryHtml = renderStoryPipeline(markdownListDoc(),
        defaultTarget())))
    registerStoryTree("markdownList", markdownListDoc)
    let apple = expectedBlock(getStory("markdownList"), "apple", "mobile",
      "light")
    check webkitListMarkers in apple
    check webkitListMarkers notin expectedBlock(getStory("markdownList"),
      "chromium-baseline", "mobile", "light")
    # Struck text, likewise (WebKit draws its line low).
    check webkitStrike notin apple
    registerStory(Story(name: "markdownStrike", group: "markdownStrike",
      render: proc(): StoryHtml = renderStoryPipeline(markdownStrikeDoc(),
        defaultTarget())))
    registerStoryTree("markdownStrike", markdownStrikeDoc)
    check webkitStrike in expectedBlock(getStory("markdownStrike"), "apple",
      "mobile", "light")
    check webkitStrike notin expectedBlock(getStory("markdownStrike"),
      "chromium-baseline", "mobile", "light")
    # A body without a list declares nothing of the kind.
    check webkitListMarkers notin expectedBlock(getStory("canary"), "apple",
      "mobile", "light")
