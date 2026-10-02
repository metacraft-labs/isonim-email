# rule: R-IMG-02, R-IMG-03, R-IMG-04, R-IMG-08, R-IMG-09, R-IMG-11, R-TBL-13, R-OL-13, R-A11Y-10
## `mailImage` (`lower/image.nim`) beyond the fixed-size stack of
## tests/t5_lower_elements.nim:
##
## - `test_image_invariants`: every image, whatever its form, carries
##   the width attribute, `border:0`, `height:auto` and its styled alt,
##   and `display:block` unless it is the inline form of a narrow image
##   alone in its holder;
## - fluid images are split for Samsung and Word (R-IMG-11);
##   `fluid_on_mobile` becomes full width below the breakpoint through a
##   class (R-IMG-09); an explicit `align` places the image;
## - the alt text: a narrow image alone in its holder is written inline,
##   an alt WebKit cannot show is reported, a known height keeps a box
##   one alt line tall, the alt must contrast with its background
##   (R-IMG-03); `alt` is required and a long one warns (R-IMG-04);
## - an image-only holder gets a zero font size and line height
##   (R-TBL-13, R-IMG-02);
## - WebP and SVG are errors where Word or Gmail have weight (R-IMG-08,
##   R-OL-13);
## - no sectioning element is ever emitted (R-A11Y-10), and header cells
##   get their scope (R-A11Y-09's scope half).
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[sequtils, strutils, tables, unittest]
import isonim_email

proc child(r: EmailRenderer; parent: EmailNode; tag: string;
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

proc newDoc(r: EmailRenderer): (EmailNode, EmailNode) =
  let doc = r.child(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", "Images")])
  discard r.child(doc, "h1", text = "Images")
  (doc, r.child(doc, "mailSection"))

proc img(r: EmailRenderer; parent: EmailNode; width, alt: string;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []): EmailNode =
  var s = @[("width", width)]
  for x in styles:
    s.add(x)
  var a = @[("src", "https://x.test/pic.png"), ("alt", alt)]
  for x in attrs:
    a.add(x)
  r.child(parent, "mailImage", s, a)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc imgTags(html: string): seq[string] =
  ## Every `<img …>` opening tag, in document order.
  var i = 0
  while true:
    let a = html.find("<img ", i)
    if a < 0:
      return
    let b = html.find('>', a)
    result.add(html[a .. b])
    i = b

proc styleOfTag(tag: string): string =
  let s = tag.find("style=\"")
  tag[s + 7 ..< tag.find('"', s + 7)]

const altStack = "font-family:Helvetica, Arial, sans-serif;" &
  "font-size:14px;line-height:20px;color:#4b5563;"

suite "every image keeps its invariants":
  test "test_image_invariants":
    # A matrix of every form: fixed, fluid (percentage and full width),
    # fluid on a phone, linked, aligned, rounded, the narrow inline form
    # and a decorative image.
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.img(s, "120px", "Logo")
    discard r.img(s, "552px", "Cover", styles = [("height", "300px")])
    discard r.img(s, "50%", "Half")
    discard r.img(s, "240px", "Phone", attrs = [("fluid_on_mobile", "true")])
    discard r.img(s, "200px", "Linked", attrs = [("href", "https://x.test/"),
      ("align", "right")], styles = [("border-radius", "8px")])
    let c = r.child(s, "mailCluster", [("gap", "16px")])
    let a = r.child(c, "a", attrs = [("href", "https://x.test/m")])
    discard r.img(a, "32px", "Mastodon")
    discard r.child(s, "mailImage", [("width", "64px")],
      [("src", "https://x.test/d.png"), ("alt", ""), ("decorative", "true")])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let tags = imgTags(res.html)
    # Two copies of each of the three fluid images.
    check tags.len == 10
    var inline = 0
    for t in tags:
      checkpoint(t)
      check " width=\"" in t
      check " alt=\"" in t
      let st = styleOfTag(t)
      check "border:0;" in st
      check "height:auto;" in st
      check "outline:none;" in st
      check "-ms-interpolation-mode:bicubic;" in st
      if "display:block;" notin st:
        # Only the narrow icon, alone in its link in its cluster item.
        check "alt=\"Mastodon\"" in t
        check "display:" notin st
        inc inline
      # Word's copy of a fluid image included.
      check altStack in st
    check inline == 1

suite "fluid images":
  test "test_fluid_images_split_for_samsung_and_word":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.img(s, "100%", "Cover")
    discard r.img(s, "600px", "Wide")
    discard r.img(s, "50%", "Half")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = res.html
    # Word's copy: the px width (the section's 552px box), in an mso
    # conditional; everyone else's: width="100%", never a px attribute.
    check "<!--[if mso]><img src=\"https://x.test/pic.png\" alt=\"Cover\" " &
      "width=\"552\" style=\"display:block;" in html
    check "<!--[if !mso]><!--><img src=\"https://x.test/pic.png\" " &
      "alt=\"Cover\" width=\"100%\" style=\"display:block;" in html
    check "width:100%;max-width:552px;" in html
    # A px width wider than its box fills it, at the box's width.
    check "alt=\"Wide\" width=\"552\"" in html
    # A percentage keeps its share as the CSS width.
    check "alt=\"Half\" width=\"276\"" in html
    check "width:50%;max-width:276px;" in html
    for t in imgTags(html):
      if "width=\"100%\"" notin t:
        # Every px-width image of these three is Word's copy.
        let at = html.find(t)
        check html.rfind("<!--[if mso]>", last = at) >
          html.rfind("<![endif]-->", last = at)
    # Without Word, one image each, no conditional.
    var t = defaultTarget()
    t.outlookWord = false
    let plain = renderTree(doc.cloneTree, target = t).html
    check imgTags(plain).len == 3
    check "<!--[if" notin plain.split("<body")[1]

  test "test_fluid_on_mobile_goes_full_width_on_a_phone":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.img(s, "240px", "Phone", attrs = [("fluid_on_mobile", "true")])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let tags = imgTags(res.html)
    check tags.len == 2
    # Desktop: the fixed width stays inline; a class carries the rule.
    let web = tags[1]
    check "width=\"100%\"" in web
    check "width:240px;max-width:100%;" in web
    check " class=\"" in web
    let cls = web.split(" class=\"")[1].split("\"")[0]
    let rule = "." & cls & "{"
    check rule in res.html
    let body = res.html.split(rule)[1].split("}")[0]
    check "width:100% !important" in body
    check "max-width:100% !important" in body
    # The rule sits under the phone query.
    let q = res.html.rfind("@media", last = res.html.find(rule))
    check "(max-width: 479px)" in res.html[q ..< res.html.find(rule)]

  test "test_explicit_align_places_the_image":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.img(s, "120px", "Right", attrs = [("align", "right")])
    discard r.img(s, "120px", "Left", attrs = [("align", "left")])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    check "<div align=\"right\" style=\"text-align:right;\"><img " &
      "src=\"https://x.test/pic.png\" alt=\"Right\" width=\"120\" " &
      "style=\"display:block;margin:0 0 0 auto;" in res.html
    check "<div align=\"left\" style=\"text-align:left;\"><img " &
      "src=\"https://x.test/pic.png\" alt=\"Left\" width=\"120\" " &
      "style=\"display:block;border:0;" in res.html
    let bad = renderTree(block:
      let r2 = EmailRenderer()
      let (d2, s2) = newDoc(r2)
      discard r2.img(s2, "120px", "X", attrs = [("align", "middle")])
      d2)
    check codeVocabBadValue in codesOf(bad.diagnostics)

suite "alt text":
  test "test_narrow_image_alone_in_its_holder_is_written_inline":
    # A 32px icon whose alt is wider than it, alone in its cluster item:
    # inline (its whole alt shows in Chromium and Gecko), reported for
    # WebKit. A short alt fits and stays a block. The same narrow icon
    # beside text stays a block (it is not alone).
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let c = r.child(s, "mailCluster", [("gap", "16px")])
    discard r.img(c, "32px", "Mastodon")
    discard r.img(c, "32px", "X")
    let p = r.child(s, "mailText")
    discard r.img(p, "32px", "Mastodon icon")
    discard r.child(p, "p", text = "Follow us")
    let res = renderTree(doc)
    let tags = imgTags(res.html)
    check tags.len == 3
    let mastodon = styleOfTag(tags[0])
    check "display:" notin mastodon
    check "vertical-align:middle;" in mastodon
    check "overflow-wrap:normal;word-break:normal;" in mastodon
    check "width:32px;" in mastodon
    check "max-width" notin mastodon
    check "display:block;" in styleOfTag(tags[1])
    check "display:block;" in styleOfTag(tags[2])
    var fits: seq[string] = @[]
    for d in res.diagnostics:
      if d.code == codeImgAltFit:
        check d.severity == sevWarning
        check d.families == {cfApple}
        check d.rules == @["R-IMG-03"]
        fits.add(d.message)
    check fits.len == 2
    check "'Mastodon'" in fits[0]
    check "'Mastodon icon'" in fits[1]

  test "test_known_height_keeps_a_box_one_alt_line_tall":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.img(s, "160px", "The hill at dawn",
      styles = [("height", "91px")])
    discard r.img(s, "160px", "Unknown height")
    discard r.img(s, "240px", "A thin wordmark", styles = [("height", "16px")])
    let tags = imgTags(renderTree(doc).html)
    check "min-height:20px;" in styleOfTag(tags[0])
    check "height=\"91\"" in tags[0]
    # Unknown, or too thin to ever be one alt line tall: no minimum,
    # which would stretch the loaded image.
    check "min-height" notin styleOfTag(tags[1])
    check "min-height" notin styleOfTag(tags[2])

  test "test_alt_must_read_on_its_background":
    let r = EmailRenderer()
    let (doc, _) = newDoc(r)
    let dark = r.child(doc, "mailSection", [("background-color", "#1f2937")])
    discard r.img(dark, "120px", "Logo")
    let light = r.child(doc, "mailSection", [("background-color", "#ffffff")])
    discard r.img(light, "120px", "Logo")
    let res = renderTree(doc)
    var low = 0
    for d in res.diagnostics:
      if d.code == codeA11yContrast and "R-IMG-03" in d.rules:
        inc low
        check "#1f2937" in d.message
    check low == 1

  test "test_alt_is_required_and_long_alt_warns":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailImage", [("width", "120px")],
      [("src", "https://x.test/a.png")])
    discard r.child(s, "mailImage", [("width", "120px")],
      [("src", "https://x.test/b.png"), ("alt", "")])
    discard r.img(s, "552px", "A".repeat(61))
    discard r.img(s, "552px", "A".repeat(60))
    let codes = codesOf(renderTree(doc).diagnostics)
    check codes.count(codeA11yAltMissing) == 2
    check codes.count(codeA11yAltLong) == 1

suite "image-only holders":
  test "test_image_only_holders_close_the_line_under_images":
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let col = r.child(r.child(s, "mailColumns"), "mailColumn")
    discard r.img(col, "120px", "One")
    discard r.img(col, "120px", "Two")
    let col2 = r.child(r.child(s, "mailColumns"), "mailColumn")
    discard r.img(col2, "120px", "Three")
    discard r.child(col2, "p", text = "Caption")
    let html = renderTree(doc).html
    let one = html.find("alt=\"One\"")
    let holder = html.rfind("<div ", last = one)
    check "font-size:0.01px;" in html[holder ..< one]
    check "line-height:0;" in html[holder ..< one]
    let three = html.find("alt=\"Three\"")
    let holder3 = html.rfind("<div ", last = three)
    check "line-height:0;" notin html[holder3 ..< three]

suite "formats":
  test "test_webp_and_svg_are_errors_where_word_or_gmail_read":
    for (src, bad) in [("https://x.test/a.webp", true),
        ("https://x.test/a.svg?v=2", true), ("https://x.test/a.png", false),
        ("https://x.test/a.JPG", false), ("https://x.test/a", false)]:
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      discard r.child(s, "mailImage", [("width", "120px")],
        [("src", src), ("alt", "A")])
      let res = renderTree(doc, profile = consumer)
      var found: seq[EmailDiagnostic] = @[]
      for d in res.diagnostics:
        if d.code == codeAssetFormat:
          found.add(d)
      check found.len == (if bad: 1 else: 0)
      if bad:
        check found[0].severity == sevError
        check found[0].rules == @["R-IMG-08", "R-OL-13"]
        check cfOutlookWord in found[0].families
    # A profile that gives neither Word nor Gmail weight: no error.
    var w: array[ClientFamily, float]
    w[cfApple] = 1.0
    let appleOnly = AudienceProfile(name: "apple", weights: w)
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "mailImage", [("width", "120px")],
      [("src", "https://x.test/a.webp"), ("alt", "A")])
    check codeAssetFormat notin codesOf(renderTree(doc,
      profile = appleOnly).diagnostics)

suite "accessibility of what is emitted":
  test "test_sectioning_elements_are_never_emitted":
    # The lowered document of a real render holds none; a lowering that
    # produced one would be caught on what is emitted.
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.child(s, "p", text = "Body")
    let res = renderTree(doc)
    check codeA11ySectioning notin codesOf(res.diagnostics)
    for tag in ["nav", "main", "article", "section", "header", "footer",
        "aside", "details", "summary"]:
      check ("<" & tag) notin res.html
      let lowered = r.child(nil, "div")
      discard r.child(r.child(lowered, "div"), tag, text = "x")
      let found = lintSectioning(lowered)
      check found.len == 1
      check found[0].code == codeA11ySectioning
      check found[0].rules == @["R-A11Y-10"]

  test "test_header_cells_get_their_scope":
    let r = EmailRenderer()
    let t = r.child(nil, "mailTable", attrs = [("caption", "Items")])
    let table = r.child(t, "table")
    let head = r.child(r.child(table, "thead"), "tr")
    discard r.child(head, "th", text = "Item")
    let row = r.child(r.child(table, "tbody"), "tr")
    discard r.child(row, "th", text = "Widget")
    discard r.child(row, "td", text = "$10")
    let own = r.child(row, "th", attrs = [("scope", "colgroup")], text = "x")
    discard applyA11y(t)
    check head.children[0].attrs["scope"] == "col"
    check row.children[0].attrs["scope"] == "row"
    check own.attrs["scope"] == "colgroup"
