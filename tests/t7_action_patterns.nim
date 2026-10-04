## The actions and inline items: what each expands into, its plain-text
## form, its accessibility obligations and its own checks
## (layout-patterns.md §4.5: `mailButtonGroup`, `mailBadge` and its Word
## wrapper, `mailAvatarName`, `mailDividerLabel`, `mailCoupon` and the
## dashed box that paints its parent (R-TBL-08), `mailRatingScale`,
## `mailSecurityCode`, `mailAppBadges`), and the coverage of common
## email types (§4.6): each is built from its patterns with no error.
##
## Every test renders a hand-built tree through the full pipeline
## (`renderTree`), with a memory asset store where an avatar is cropped.
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[sequtils, strutils, tables, unittest]
import isonim_email
from isonim_email/lower/button_style import variantOf

const
  photo = "https://cdn.example.com/a/photo.png"
  badgeArt = "https://cdn.example.com/a/badge.png"
  rate = "https://example.com/rate?s={score}"

proc el(r: EmailRenderer; parent: EmailNode; tag: string;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

proc newDoc(r: EmailRenderer; rtl = false): (EmailNode, EmailNode) =
  ## A document and its first section, with an `h1` and an `h2`.
  let doc = r.el(nil, "mailDocument", [("lang", if rtl: "ar" else: "en"),
    ("dir", if rtl: "rtl" else: "ltr"), ("title", "Patterns")])
  let s = r.el(doc, "mailSection")
  discard r.el(s, "h1", text = "Patterns")
  discard r.el(s, "h2", text = "Section")
  (doc, s)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc find(n: EmailNode; tag: string): EmailNode =
  if n == nil:
    return nil
  if n.kind == enElement and n.tag == tag:
    return n
  for c in n.children:
    let f = find(c, tag)
    if f != nil:
      return f
  nil

proc findAll(n: EmailNode; tag: string; acc: var seq[EmailNode]) =
  if n.kind == enElement and n.tag == tag:
    acc.add(n)
  for c in n.children:
    findAll(c, tag, acc)

proc all(n: EmailNode; tag: string): seq[EmailNode] =
  findAll(n, tag, result)

proc body(text: string): string =
  ## The text part after the document's two headings.
  let at = text.find("Section\n-------\n\n")
  if at < 0: text else: text[at + "Section\n-------\n\n".len .. ^1]

proc elementsOf(n: EmailNode): seq[EmailNode] =
  n.children.filterIt(it.kind == enElement)

proc designed(): EmailTarget =
  result = defaultTarget()
  result.darkMode = dmDesigned

proc noWord(): EmailTarget =
  result = defaultTarget()
  result.outlookWord = false

proc store(): AssetStore =
  let m = memoryAssetStore("https://cdn.example.com")
  result = m
  m.put("avatar.png", encodePng(Pixels(ok: true, width: 8, height: 8,
    rgba: newSeq[uint8](8 * 8 * 4))))

# --- mailButtonGroup -------------------------------------------------------------

proc groupDoc(attrs: openArray[(string, string)] = [];
    labels = @["Pay", "Download"]; rtl = false): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  let g = r.el(s, "mailButtonGroup", attrs)
  for l in labels:
    discard r.el(g, "mailButton", [("href", "https://example.com/" &
      l.toLowerAscii())], text = l)
  renderTree(doc)

suite "mailButtonGroup":
  test "test_button_group_is_a_cluster_of_buttons":
    # rule: R-TBL-12
    let res = groupDoc()
    check not hasErrors(res.diagnostics)
    let g = res.semantic.find("mailButtonGroup")
    let c = g.find("mailCluster")
    require c != nil
    check c.styles["gap"] == "12px" and c.styles["row_gap"] == "12px"
    check c.attrs["align"] == "left"
    let buttons = c.elementsOf
    check buttons.mapIt(it.tag) == @["mailButton", "mailButton"]
    # The first is the primary action, the second secondary: the
    # button's defaults read its place in the group.
    check "variant" notin buttons[0].attrs and "variant" notin buttons[1].attrs
    check variantOf(buttons[0]) == "solid"
    check variantOf(buttons[1]) == "outline"
    check res.html.count("background-color:#1f6feb") >= 1
    check "border:2px solid #0969da" in res.html
    check codeA11yTapTarget notin codesOf(res.diagnostics)
    # Text: each `label: url`, one per line.
    check res.text.body == "Pay: https://example.com/pay\n" &
      "Download: https://example.com/download\n"
    # A button's own variant is kept; right to left starts at the right.
    let own = renderTree((proc(): EmailNode =
      let r = EmailRenderer()
      let (doc, s) = r.newDoc(rtl = true)
      let g = r.el(s, "mailButtonGroup")
      discard r.el(g, "mailButton", [("href", "https://example.com/a"),
        ("variant", "link")], text = "أ")
      doc)())
    let b = own.semantic.find("mailButton")
    check variantOf(b) == "link"
    check own.semantic.find("mailCluster").attrs["align"] == "right"

  test "test_button_group_stacks_on_mobile_as_a_hybrid_row":
    let res = groupDoc([("stack_on_mobile", "true"), ("gap", "16px")])
    check not hasErrors(res.diagnostics)
    let row = res.semantic.find("mailButtonGroup").find("mailColumns")
    require row != nil
    check row.attrs["strategy"] == "hybrid" and row.attrs["gutter"] == "16px"
    let cols = row.elementsOf
    check cols.len == 2
    for col in cols:
      check col.tag == "mailColumn"
      check col.find("mailButton").styles["width"] == "100%"
    # Stacked inline (mobile first), side by side from the breakpoint.
    check "min-width: 480px" in res.html
    check res.text.body == "Pay: https://example.com/pay\n" &
      "Download: https://example.com/download\n"

  test "test_button_group_props_are_checked":
    check codeVocabBadValue in codesOf(groupDoc([("gap", "8px")]).diagnostics)
    check codeVocabBadValue in codesOf(groupDoc(labels = @["A", "B", "C",
      "D"]).diagnostics)
    check codeVocabBadValue notin codesOf(groupDoc(labels = @["A", "B",
      "C"]).diagnostics)
    let r = EmailRenderer()
    let (doc, s) = r.newDoc()
    discard r.el(r.el(s, "mailButtonGroup"), "p", text = "Not a button")
    check codeVocabBadValue in codesOf(renderTree(doc).diagnostics)

# --- mailBadge -------------------------------------------------------------------

proc badgeDoc(inText: bool; target = defaultTarget(); tone = "success";
    label = "Paid"): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc()
  let parent = if inText: r.el(s, "p", text = "Status ") else: s
  discard r.el(parent, "mailBadge", [("tone", tone)], text = label)
  renderTree(doc, target = target)

suite "mailBadge":
  test "test_badge_word_wrapper":
    # rule: R-TBL-01
    # On a line of its own with Outlook output on: the one-cell inline
    # table whose cell carries the padding (Word pads a cell, never a
    # span), and no W-TBL-UNEXPECTED.
    let wrapped = badgeDoc(inText = false)
    check not hasErrors(wrapped.diagnostics)
    check codeTblUnexpected notin codesOf(wrapped.diagnostics)
    let badge = wrapped.semantic.find("mailBadge")
    let table = badge.find("table")
    require table != nil
    check table.styles["display"] == "inline-table"
    let td = table.find("td")
    check td.styles["padding"] == "1px 9px"
    check "border:1px solid #1a7f37" in wrapped.html
    check td.styles["border-radius"] == "999px"
    check badge.find("span") == nil
    check "display:inline-table" in wrapped.html
    check ">Paid</td>" in wrapped.html
    # Inside a line of text the badge stays the span, Outlook or not.
    let inline = badgeDoc(inText = true)
    check not hasErrors(inline.diagnostics)
    let span = inline.semantic.find("mailBadge").find("span")
    require span != nil
    check span.styles["display"] == "inline-block"
    check span.styles["padding"] == "1px 9px"
    check inline.semantic.find("mailBadge").find("table") == nil
    check "<p" in inline.html and "inline-block" in inline.html
    # Without Outlook output, a span everywhere.
    let plain = badgeDoc(inText = false, target = noWord())
    check plain.semantic.find("mailBadge").find("table") == nil
    check "display:inline-table" notin plain.html

  test "test_badge_text_form_and_tone":
    let inline = badgeDoc(inText = true)
    check inline.text.body == "Status [Paid]\n"
    check badgeDoc(inText = false).text.body == "[Paid]\n"
    # The tone's colours, dark-paired under `designed`; a short label on
    # one line, a long one wrapping.
    let res = badgeDoc(inText = true, target = designed(), tone = "warning")
    let span = res.semantic.find("mailBadge").find("span")
    check span.styles["white-space"] == "nowrap"
    check "background-color:#fff8c5" in res.html
    check "border-color:#9a6700" in res.html
    # The label is the primary text colour, never the tone's.
    check span.styles["color"] == "#111827"
    check "@media (prefers-color-scheme: dark)" in res.html
    let long = badgeDoc(inText = true, label = "Scheduled maintenance this " &
      "weekend")
    check "white-space" notin long.semantic.find("mailBadge").find(
      "span").styles
    # The label carries the meaning: none is an error, so is a bad tone.
    check codeVocabBadValue in codesOf(badgeDoc(inText = true,
      label = "").diagnostics)
    check codeVocabBadValue in codesOf(badgeDoc(inText = true,
      tone = "pink").diagnostics)

# --- mailAvatarName ----------------------------------------------------------------

proc avatarDoc(attrs: openArray[(string, string)]; rtl = false):
    RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  discard r.el(s, "mailAvatarName", attrs)
  renderTree(doc, assets = store())

suite "mailAvatarName":
  test "test_avatar_name_is_a_sidebar_with_a_circle_crop":
    let res = avatarDoc([("name", "Ada Lovelace"), ("role", "CTO"),
      ("avatar", "avatar.png")])
    check not hasErrors(res.diagnostics)
    let side = res.semantic.find("mailAvatarName").find("mailSidebar")
    require side != nil
    check side.attrs["fixed"] == "48px" and side.attrs["valign"] == "middle"
    let img = side.find("mailImage")
    check img.attrs["crop"] == "circle"
    check img.attrs["decorative"] == "true" and img.attrs["alt"] == ""
    # The asset pass published a circle of its own.
    check res.assets.anyIt(it.name != "avatar.png")
    let who = side.find("mailStack")
    check who.elementsOf.mapIt(it.tag) == @["p", "p"]
    check res.text.body == "Ada Lovelace — CTO\n"
    # A described avatar keeps its alt; a hosted one opts out of the crop.
    let hosted = avatarDoc([("name", "Ada"), ("avatar", photo),
      ("avatar_alt", "Ada"), ("crop", "none"), ("size", "64")])
    check not hasErrors(hosted.diagnostics)
    let h = hosted.semantic.find("mailImage")
    check h.attrs["alt"] == "Ada" and "crop" notin h.attrs
    check hosted.semantic.find("mailSidebar").attrs["fixed"] == "64px"
    check hosted.text.body == "Ada\n"
    # A hosted avatar cannot be cropped (R-IMG-13).
    check codeAssetCrop in codesOf(avatarDoc([("name", "Ada"),
      ("avatar", photo)]).diagnostics)

  test "test_avatar_name_props_are_checked":
    check codeVocabBadValue in codesOf(avatarDoc([("avatar",
      "avatar.png")]).diagnostics)
    check codeVocabBadValue in codesOf(avatarDoc([("name", "Ada"),
      ("avatar", "avatar.png"), ("size", "24")]).diagnostics)
    check codeVocabBadValue in codesOf(avatarDoc([("name", "Ada"),
      ("avatar", "avatar.png"), ("crop", "4:3")]).diagnostics)

# --- mailDividerLabel ---------------------------------------------------------------

proc dividerDoc(label: string; rtl = false): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  discard r.el(s, "mailDividerLabel", text = label)
  renderTree(doc)

suite "mailDividerLabel":
  test "test_divider_label_is_a_three_cell_table":
    # rule: R-TBL-01
    let res = dividerDoc("or")
    check not hasErrors(res.diagnostics)
    check codeTblUnexpected notin codesOf(res.diagnostics)
    let table = res.semantic.find("mailDividerLabel").find("table")
    require table != nil
    # Its own automatic layout, against the reset's fixed one.
    check table.styles["table-layout"] == "auto !important"
    check "table-layout:auto !important" in res.html
    let cells = table.find("tr").elementsOf
    check cells.len == 3
    for i in [0, 2]:
      check cells[i].attrs["width"] == "50%"
      check cells[i].attrs["aria-hidden"] == "true"
      check cells[i].attrs["valign"] == "middle"
      # The rule: an empty cell's 1px top border, in a table of its own
      # (never a painted cell, which an inverting client darkens).
      let rule = cells[i].find("table").find("td")
      check "bgcolor" notin rule.attrs
    check cells[1].styles["white-space"] == "nowrap"
    check res.html.count("border-top-width:1px;border-top-style:solid;" &
      "border-top-color:#e5e7eb") == 2
    check "bgcolor=\"#e5e7eb\"" notin res.html
    check res.text.body == "—— or ——\n"
    # A short CJK label: word joiners between its ideographs, so a
    # client that drops `white-space` cannot break it into a column of
    # characters; the text part keeps it as written.
    let cjk = dividerDoc("または")
    check "ま\u2060た\u2060は" in cjk.html
    check cjk.text.body == "—— または ——\n"
    check "o\u2060r" notin res.html
    # A long label wraps in the middle 60%, breaking a word too long.
    let long = dividerDoc("or continue with one of your recovery codes")
    let lc = long.semantic.find("mailDividerLabel").find("tr").elementsOf
    check lc[0].attrs["width"] == "20%" and lc[2].attrs["width"] == "20%"
    check lc[1].attrs["width"] == "60%"
    check lc[1].styles["word-break"] == "break-word"
    check "white-space" notin lc[1].styles
    # Designed: Thunderbird's copy of the dark rule carries the rule's
    # colour too (R-DRK-08).
    let r2 = EmailRenderer()
    let (d2, s2) = r2.newDoc()
    discard r2.el(s2, "mailDividerLabel", text = "or")
    let dark = renderTree(d2, target = designed()).html
    check "border-top-color:light-dark(#e5e7eb,#2f343d)" in dark
    # Right to left, the table runs right to left.
    check "dir=\"rtl\"" in dividerDoc("أو", rtl = true).html
    check codeVocabBadValue in codesOf(dividerDoc("").diagnostics)

# --- mailCoupon ------------------------------------------------------------------------

proc couponDoc(attrs: openArray[(string, string)];
    target = defaultTarget()): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc()
  discard r.el(s, "mailCoupon", attrs)
  renderTree(doc, target = target)

suite "mailCoupon":
  test "test_coupon_dashed_box_paints_its_parent":
    # rule: R-TBL-08
    # rule: R-TXT-06
    let res = couponDoc([("code", "SPRING20"), ("title", "20% off"),
      ("hint", "At checkout.")])
    check not hasErrors(res.diagnostics)
    let box = res.semantic.find("mailCoupon").find("mailBox")
    require box != nil
    # The box's table carries the cell's background, so Outlook shows
    # it between the dashes.
    check ("cellspacing=\"0\" bgcolor=\"#f8f9fb\" style=\"border-collapse:" &
      "separate !important;background-color:#f8f9fb;") in res.html
    check "<td bgcolor=\"#f8f9fb\"" in res.html
    check "border:2px dashed #1f6feb" in res.html
    # The code is protected from data detectors: a joiner beside each
    # digit (R-TXT-06), the letters left as they are.
    check "SPRING2‍0" in res.html or "SPRING‍2‍0" in res.html
    check "SPRING20" notin res.html
    check "monospace" in res.html and "letter-spacing:2px" in res.html
    check res.text.body == "20% off\nCode: SPRING20\nAt checkout.\n"
    # Designed: the dashed border and both backgrounds take dark pairs.
    let dark = couponDoc([("code", "X1")], designed())
    check not hasErrors(dark.diagnostics)
    # The box's table carries the cell's dark class too.
    let at = dark.html.find("cellspacing=\"0\" bgcolor=\"#f8f9fb\"")
    require at >= 0
    let tableTag = dark.html[at ..< dark.html.find(">", at)]
    check "class=\"e-" in tableTag
    check codeVocabBadValue in codesOf(couponDoc([("title", "x")]).diagnostics)

  test "test_a_solid_box_does_not_paint_its_parent":
    # rule: R-TBL-08
    # Only a dashed or dotted border needs the parent's colour.
    let r = EmailRenderer()
    let (doc, s) = r.newDoc()
    let b = r.el(s, "mailBox", styles = [("background-color", "#fef3c7"),
      ("border", "2px solid #92400e")])
    discard r.el(b, "p", text = "Boxed")
    let solid = renderTree(doc).html
    check "<td bgcolor=\"#fef3c7\"" in solid
    check solid.count("bgcolor=\"#fef3c7\"") == 1
    let r2 = EmailRenderer()
    let (doc2, s2) = r2.newDoc()
    let d = r2.el(s2, "mailBox", styles = [("background-color", "#fef3c7"),
      ("border", "2px dotted #92400e")])
    discard r2.el(d, "p", text = "Boxed")
    check renderTree(doc2).html.count("bgcolor=\"#fef3c7\"") == 2

# --- mailRatingScale -------------------------------------------------------------------

proc ratingDoc(attrs: openArray[(string, string)]; rtl = false):
    RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc(rtl)
  discard r.el(s, "mailRatingScale", attrs)
  renderTree(doc)

suite "mailRatingScale":
  test "test_rating_stars_are_five_44px_links":
    # rule: R-TBL-12
    let res = ratingDoc([("href", rate)])
    check not hasErrors(res.diagnostics)
    check codeA11yTapTarget notin codesOf(res.diagnostics)
    let c = res.semantic.find("mailRatingScale").find("mailCluster")
    require c != nil
    check c.styles["gap"] == "8px"
    let links = c.elementsOf
    check links.len == 5
    for i, a in links:
      check a.tag == "a"
      check a.attrs["href"] == "https://example.com/rate?s=" & $(i + 1)
      check a.styles["height"] == "44px" and a.styles["width"] == "44px"
      # The glyph is hidden from readers; the hidden text names the score.
      let spans = a.elementsOf
      check spans[0].attrs["aria-hidden"] == "true"
      check spans[0].children[0].text == "★"
      check spans[1].children[0].text == "Rate " & $(i + 1) & " out of 5"
      check spans[1].styles["position"] == "absolute"
    check res.text.body.startsWith("1: https://example.com/rate?s=1\n")
    check res.text.body.count("\n") == 5

  test "test_rating_nps_is_two_rows_of_six":
    let res = ratingDoc([("kind", "nps"), ("href", rate)])
    check not hasErrors(res.diagnostics)
    check codeLayoutMinColumn notin codesOf(res.diagnostics)
    let scale = res.semantic.find("mailRatingScale")
    let rows = scale.all("mailColumns")
    check rows.len == 3 # two rows of scores and the end labels
    check rows[0].attrs["strategy"] == "cells"
    check rows[0].elementsOf.len == 6 and rows[1].elementsOf.len == 6
    # The second row's sixth slot is empty.
    check rows[1].elementsOf[5].find("a") == nil
    let links = scale.all("a")
    check links.len == 11
    check links.mapIt(it.attrs["href"].split("=")[^1]) ==
      toSeq(0 .. 10).mapIt($it)
    # Each link reads "Rate n out of 10": hidden words around the number.
    check ">Rate </span>4<span" in res.html
    check "> out of 10</span>" in res.html
    check "display:block;padding:12px 0" in res.html
    # Default end labels, and the text part's lines.
    check res.text.body.startsWith("0 = Not likely, 10 = Very likely\n" &
      "0: https://example.com/rate?s=0\n")
    check res.text.body.count(": https://example.com/rate") == 11
    # Right to left, the end labels' comma is Arabic.
    let rtl = ratingDoc([("kind", "nps"), ("href", rate),
      ("low_label", "أ"), ("high_label", "ب")], rtl = true)
    check "0 = أ، 10 = ب\n" in rtl.text

  test "test_rating_href_needs_its_score":
    check codeVocabBadValue in codesOf(ratingDoc([("href",
      "https://example.com/rate")]).diagnostics)
    check codeVocabBadValue in codesOf(ratingDoc([("kind", "nps")]).diagnostics)
    check codeVocabBadValue in codesOf(ratingDoc([("kind", "ten"),
      ("href", rate)]).diagnostics)

# --- mailSecurityCode ------------------------------------------------------------------

proc codeDoc(attrs: openArray[(string, string)]): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc()
  discard r.el(s, "mailSecurityCode", attrs)
  renderTree(doc)

suite "mailSecurityCode":
  test "test_security_code_is_text_with_its_expiry":
    # rule: R-TXT-06
    let res = codeDoc([("code", "482913"), ("expires", "14:05 UTC"),
      ("href", "https://example.com/magic"), ("cta", "Sign in")])
    check not hasErrors(res.diagnostics)
    let box = res.semantic.find("mailSecurityCode").find("mailBox")
    require box != nil
    check box.find("mailImage") == nil and "<img" notin res.html.split(
      "<body")[1]
    # Never a detected link: a joiner beside every digit.
    check "4‍8‍2‍9‍1‍3" in res.html
    check ">Expires at 14:05 UTC</p>" in res.html
    check box.find("mailButton").attrs["href"] == "https://example.com/magic"
    check res.text.body == "Your code: 482913 (expires at 14:05 UTC)\n\n" &
      "Sign in: https://example.com/magic\n"
    # The expiry is required; so is a button label with a magic link.
    check codeVocabBadValue in codesOf(codeDoc([("code",
      "482913")]).diagnostics)
    check codeVocabBadValue in codesOf(codeDoc([("code", "482913"),
      ("expires", "14:05 UTC"), ("href", "https://example.com/m")]).diagnostics)

# --- mailAppBadges ---------------------------------------------------------------------

proc badgesDoc(attrs: openArray[(string, string)];
    items: openArray[seq[(string, string)]]; target = defaultTarget()):
    RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = r.newDoc()
  let b = r.el(s, "mailAppBadges", attrs)
  for it in items:
    discard r.el(b, "mailAppBadge", it)
  renderTree(doc, target = target)

let
  apple = @[("store", "apple"), ("href", "https://apps.example.com/ios"),
    ("image", badgeArt), ("width", "135"), ("dark_image",
    "https://cdn.example.com/a/badge-dark.png")]
  google = @[("store", "google"), ("href",
    "https://apps.example.com/android"), ("image", badgeArt),
    ("width", "135")]

suite "mailAppBadges":
  test "test_app_badges_are_a_cluster_of_linked_artwork":
    let res = badgesDoc([], [apple, google])
    check not hasErrors(res.diagnostics)
    let c = res.semantic.find("mailAppBadges").find("mailCluster")
    require c != nil
    # The gap is the larger of 12px and a quarter of the height.
    check c.styles["gap"] == "12px"
    let imgs = c.elementsOf
    check imgs.len == 2
    check imgs[0].attrs["alt"] == "Download on the App Store"
    check imgs[1].attrs["alt"] == "Get it on Google Play"
    check imgs[0].styles["height"] == "40px"
    check imgs[0].attrs["href"] == "https://apps.example.com/ios"
    # Light/dark variants: the dark artwork only under `designed`.
    check "dark_src" notin imgs[0].attrs
    let dark = badgesDoc([], [apple], designed())
    check dark.semantic.find("mailImage").attrs["dark_src"] ==
      "https://cdn.example.com/a/badge-dark.png"
    check res.text.body == "Download on the App Store: " &
      "https://apps.example.com/ios\nGet it on Google Play: " &
      "https://apps.example.com/android\n"
    check badgesDoc([("height", "48")], [apple]).semantic.find(
      "mailCluster").styles["gap"] == "12px"

  test "test_app_badges_props_are_checked":
    check codeVocabBadValue in codesOf(badgesDoc([("height", "32")],
      [apple]).diagnostics)
    check codeVocabBadValue in codesOf(badgesDoc([("height", "48"),
      ("gap", "10px")], [apple]).diagnostics)
    check codeVocabBadValue notin codesOf(badgesDoc([("height", "48"),
      ("gap", "12px")], [apple]).diagnostics)
    # An other store needs its alt; every badge its width.
    check codeVocabBadValue in codesOf(badgesDoc([], [@[("store", "other"),
      ("href", "https://x.example/"), ("image", badgeArt),
      ("width", "135")]]).diagnostics)
    check codeVocabBadValue in codesOf(badgesDoc([], [@[("store", "apple"),
      ("href", "https://x.example/"), ("image", badgeArt)]]).diagnostics)

# --- Coverage of common email types (layout-patterns.md §4.6) -------------------------

type Builder = proc(r: EmailRenderer; s: EmailNode)

proc pat(r: EmailRenderer; s: EmailNode; tag: string;
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  r.el(s, tag, attrs, text = text)

proc header(r: EmailRenderer; doc: EmailNode) =
  let s = r.el(doc, "mailSection")
  let h = r.el(s, "mailHeader", [("logo", photo), ("logo_width", "120"),
    ("logo_alt", "Acme")])
  discard r.el(h, "a", [("href", "https://example.com/help")], text = "Help")

proc footer(r: EmailRenderer; doc: EmailNode) =
  let s = r.el(doc, "mailSection")
  discard r.el(s, "mailFooter", [("address", "1 Example Street"),
    ("unsubscribe", "https://example.com/u")])

proc buttons(r: EmailRenderer; s: EmailNode) =
  let g = r.pat(s, "mailButtonGroup")
  discard r.el(g, "mailButton", [("href", "https://example.com/a")],
    text = "Open")

proc kv(r: EmailRenderer; s: EmailNode) =
  let k = r.pat(s, "mailKeyValue", [("caption", "Summary")])
  discard r.el(k, "mailKeyValueRow", [("label", "Total")], text = "$10.00")

let emailTypes: seq[(string, seq[string], Builder)] = @[
  ("Receipt / invoice", @["mailHeader", "mailKeyValue", "mailLineItems",
    "mailButtonGroup", "mailFooter"], proc(r: EmailRenderer; s: EmailNode) =
      r.kv(s)
      let l = r.pat(s, "mailLineItems", [("caption", "Items")])
      discard r.el(l, "mailLineItem", [("description", "A thing"),
        ("amount", "$10.00")])
      r.buttons(s)),
  ("Password reset / magic link / OTP", @["mailHeader", "mailSecurityCode",
    "mailCallout", "mailFooter"], proc(r: EmailRenderer; s: EmailNode) =
      discard r.pat(s, "mailSecurityCode", [("code", "123456"),
        ("expires", "14:05 UTC"), ("href", "https://example.com/m"),
        ("cta", "Sign in")])
      let c = r.pat(s, "mailCallout", [("tone", "warning"),
        ("title", "Didn't request this?")])
      discard r.el(c, "p", text = "Ignore this message.")),
  ("Shipping / order status", @["mailHeader", "mailStepper", "mailTimeline",
    "mailMediaObject", "mailFooter"], proc(r: EmailRenderer; s: EmailNode) =
      let st = r.pat(s, "mailStepper", [("current", "2")])
      for l in ["Ordered", "Shipped", "Delivered"]:
        discard r.el(st, "mailStep", text = l)
      let t = r.pat(s, "mailTimeline")
      discard r.el(t, "mailTimelineEvent", [("time", "09:00")],
        text = "Shipped.")
      let m = r.pat(s, "mailMediaObject", [("image", photo),
        ("image_width", "64"), ("image_alt", "Print")])
      discard r.el(m, "p", text = "Coast print")),
  ("Alert / incident", @["mailHeader", "mailCallout", "mailKeyValue",
    "mailCodeBlock", "mailButtonGroup", "mailFooter"],
    proc(r: EmailRenderer; s: EmailNode) =
      let c = r.pat(s, "mailCallout", [("tone", "danger"),
        ("title", "API errors")])
      discard r.el(c, "p", text = "Error rate above 5%.")
      r.kv(s)
      let code = r.pat(s, "mailCodeBlock")
      r.appendChild(code, r.createTextNode("GET /v1/orders 500"))
      r.buttons(s)),
  ("Digest / newsletter", @["mailHeader", "mailHero", "mailGrid", "mailCard",
    "mailZigZag", "mailFooter"], proc(r: EmailRenderer; s: EmailNode) =
      let h = r.el(s.parent, "mailHero", styles = [("background-color",
        "#0b3a6e")])
      discard r.el(h, "p", [], [("color", "#ffffff")], text = "This week")
      let s2 = r.el(s.parent, "mailSection")
      let g = r.pat(s2, "mailGrid", [("columns", "2")])
      for i in 0 .. 1:
        let c = r.pat(g, "mailCard", [("title", "Story " & $i)])
        discard r.el(c, "p", text = "Its summary.")
      let z = r.pat(s2, "mailZigZag")
      for i in 0 .. 1:
        let m = r.el(z, "mailMediaObject", [("image", photo),
          ("image_width", "200"), ("image_alt", "A photo")])
        discard r.el(m, "p", text = "Row " & $i)),
  ("Event invitation", @["mailHeader", "mailHero", "mailEvent",
    "mailButtonGroup", "mailFooter"], proc(r: EmailRenderer; s: EmailNode) =
      let h = r.el(s.parent, "mailHero", styles = [("background-color",
        "#0b3a6e")])
      discard r.el(h, "p", [], [("color", "#ffffff")], text = "Launch day")
      let s2 = r.el(s.parent, "mailSection")
      let e = r.pat(s2, "mailEvent", [("month", "Oct"), ("day", "14"),
        ("date_text", "Tuesday, 14 October 2026, 18:00 CEST")])
      discard r.el(e, "h3", text = "Launch")
      r.buttons(s2)),
  ("Survey", @["mailHeader", "mailRatingScale", "mailFooter"],
    proc(r: EmailRenderer; s: EmailNode) =
      discard r.pat(s, "mailRatingScale", [("kind", "nps"), ("href", rate)])),
]

suite "coverage of common email types":
  test "test_common_email_types_are_buildable":
    # Vacuity guard: the seven rows of the coverage table.
    check emailTypes.len == 7
    for (name, patterns, build) in emailTypes:
      let r = EmailRenderer()
      let doc = r.el(nil, "mailDocument", [("lang", "en"), ("dir", "ltr"),
        ("title", name)])
      r.header(doc)
      let s = r.el(doc, "mailSection")
      discard r.el(s, "h1", text = name)
      build(r, s)
      r.footer(doc)
      let res = renderTree(doc)
      for d in res.diagnostics:
        if d.severity == sevError:
          checkpoint(name & ": " & d.code & " " & d.message)
      check not hasErrors(res.diagnostics)
      # Every pattern of the row is in the message, expanded, and none
      # of it is raw markup.
      for p in patterns:
        let node = res.semantic.find(p)
        if node == nil:
          checkpoint(name & " lacks " & p)
        check node != nil
        if node != nil and isPattern(p) and p notin ["mailGrid", "mailHero"]:
          check node.expanded
      check res.semantic.find("mailRaw") == nil
      check res.text.len > 0
