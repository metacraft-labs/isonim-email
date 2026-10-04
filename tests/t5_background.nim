# rule: R-VML-01, R-VML-02, R-VML-03, R-VML-04, R-VML-05, R-VML-06, R-VML-07
# rule: R-VML-08
# rule: R-OL-11
## Background images and `mailHero`: a band's image as CSS for every
## client but Word and as a VML rectangle for Word, the hero's cell, the
## flag that guards rectangles growing with their content, the URL rule,
## and the contrast check of text over an image against its fallback
## colour.
##
## - The CSS path is the image's longhands, with the fallback colour, on
##   the element that carries the band's classes (R-VML-01).
## - Word gets the image as `v:rect` + `v:fill` + `v:textbox` (R-VML-01,
##   R-OL-11), its fill placed as MJML 5 places it; a hero needs a px
##   height for it (R-VML-02, R-VML-06); a rectangle that grows with
##   its content needs `vmlFitToText`, and without it Word paints the
##   fallback colour (R-VML-03); the image is an absolute https URL
##   (R-VML-04); the rectangle is not hidden from readers, its text box
##   holds the content as ordinary HTML (R-VML-05).
## - Text over an image is checked against the fallback colour (P10).
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS.
import std/[sequtils, strutils, tables, unittest]
import isonim_email
import stories/story_kit
import stories/seed_backgrounds

const bg = "https://x.test/0123456789abcdef/hero.png"

proc newDoc(r: EmailRenderer; dir = "ltr"; colour = ""): EmailNode =
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", if dir == "rtl": "ar" else: "en")
  r.setAttribute(result, "dir", dir)
  r.setAttribute(result, "title", "Backgrounds")
  if colour.len > 0:
    r.setStyle(result, "background-color", colour)

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
  r.appendChild(parent, result)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc errorsOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    if d.severity == sevError:
      result.add(d.code)

proc fitTarget(): EmailTarget =
  result = defaultTarget()
  result.vmlFitToText = true

proc sectionDoc(styles: openArray[(string, string)];
    attrs: openArray[(string, string)] = []; text = "#ffffff"): EmailNode =
  let r = EmailRenderer()
  result = r.newDoc()
  let s = r.child(result, "mailSection", styles, attrs)
  discard r.child(s, "h1", [("color", text)], text = "Spring sale")

proc heroDoc(styles: openArray[(string, string)];
    attrs: openArray[(string, string)] = [];
    textColour = "#ffffff"): EmailNode =
  let r = EmailRenderer()
  result = r.newDoc()
  let h = r.child(result, "mailHero", styles, attrs)
  discard r.child(h, "h1", [("color", textColour)], text = "Spring sale")

proc between(html, a, b: string): string =
  let i = html.find(a)
  doAssert i >= 0, "missing: " & a & "\n" & html
  let j = html.find(b, i + a.len)
  doAssert j >= 0, "missing: " & b & "\n" & html
  html[i ..< j + b.len]

const cssImage = "background-color:#334455;" &
  "background-image:url(&#x27;" & bg & "&#x27;);" &
  "background-position:center top;background-size:cover;" &
  "background-repeat:no-repeat;"

suite "a section's background image":
  test "test_section_background_css_on_the_inner_div":
    let res = renderTree(sectionDoc([("background-color", "#334455"),
      ("background-image", bg)], [("background_position", "center top")]))
    check errorsOf(res.diagnostics).len == 0
    # The image and its fallback colour on the inner div, which carries
    # the band's padding and classes; the outer div keeps its colour.
    check ("<div align=\"left\" style=\"padding:24px;font-size:16px;" &
      "text-align:left;direction:ltr;" & cssImage & "\">") in res.html
    check ("<div style=\"margin:0 auto;max-width:600px;" &
      "background-color:#334455;\">") in res.html

  test "test_section_background_without_fit_flag_shows_word_the_colour":
    # R-VML-03: a section's rectangle would grow with its content, which
    # is unverified, so by default Word gets the fallback colour on the
    # ghost cell and no VML at all.
    let res = renderTree(sectionDoc([("background-color", "#334455"),
      ("background-image", bg)]))
    check "v:rect" notin res.html
    check "mso-fit-shape-to-text" notin res.html
    check ("<td bgcolor=\"#334455\" style=\"padding:24px;" &
      "background-color:#334455;\">") in res.html
    check codeCssMsoUnlisted notin codesOf(res.diagnostics)

  test "test_section_background_vml_with_fit_flag":
    let res = renderTree(sectionDoc([("background-color", "#334455"),
      ("background-image", bg)], [("background_position", "center top")]),
      target = fitTarget())
    check errorsOf(res.diagnostics).len == 0
    # The ghost cell paints the fallback colour, without the padding,
    # and holds the rectangle (catalogue §6), which holds the padding
    # table Word lays the content out in.
    check ("<!--[if mso]><table role=\"presentation\" align=\"center\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\" width=\"600\" " &
      "style=\"width:600px;\"><tr><td bgcolor=\"#334455\" " &
      "style=\"background-color:#334455;\"><![endif]-->" &
      "<!--[if gte mso 9]><v:rect xmlns:v=\"urn:schemas-microsoft-com:vml\" " &
      "fill=\"true\" stroke=\"false\" style=\"width:600px;\">" &
      "<v:fill type=\"frame\" origin=\"0, -0.5\" position=\"0, -0.5\" " &
      "src=\"" & bg & "\" color=\"#334455\" size=\"1,1\" " &
      "aspect=\"atleast\" /><v:textbox inset=\"0,0,0,0\" " &
      "style=\"mso-fit-shape-to-text:true\"><![endif]-->" &
      "<!--[if mso]><table role=\"presentation\" width=\"100%\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\"><tr>" &
      "<td style=\"padding:24px;direction:ltr;\"><![endif]-->") in res.html
    # Word sees no element with a background inside the rectangle: the
    # outer div has none, the inner div's tags are hidden from Word.
    check "<div style=\"margin:0 auto;max-width:600px;\">" in res.html
    check ("<!--[if !mso]><!--><div align=\"left\" style=\"padding:24px;" &
      "font-size:16px;text-align:left;direction:ltr;" & cssImage &
      "\"><!--<![endif]-->") in res.html
    check ("<!--[if !mso]><!--></div><!--<![endif]--></div>" &
      "<!--[if mso]></td></tr></table><![endif]-->" &
      "<!--[if gte mso 9]></v:textbox></v:rect><![endif]-->" &
      "<!--[if mso]></td></tr></table><![endif]-->") in res.html
    # The fit property is off R-OL-15's closed list: the opt-in is
    # reported until a Word capture admits it.
    check codeCssMsoUnlisted in codesOf(res.diagnostics)

  test "test_vml_fill_follows_mjml":
    # (size, position, repeat) → the v:fill attributes MJML 5 writes.
    let cases = [
      ("cover", "center top", "no-repeat",
        "type=\"frame\" origin=\"0, -0.5\" position=\"0, -0.5\"",
        " size=\"1,1\" aspect=\"atleast\" />"),
      ("contain", "right bottom", "no-repeat",
        "type=\"frame\" origin=\"0.5, 0.5\" position=\"0.5, 0.5\"",
        " size=\"1,1\" aspect=\"atmost\" />"),
      ("cover", "top left", "no-repeat",
        "type=\"frame\" origin=\"-0.5, -0.5\" position=\"-0.5, -0.5\"",
        " size=\"1,1\" aspect=\"atleast\" />"),
      ("cover", "30% 80%", "no-repeat",
        "type=\"frame\" origin=\"-0.2, 0.3\" position=\"-0.2, 0.3\"",
        " size=\"1,1\" aspect=\"atleast\" />"),
      ("auto", "center center", "repeat",
        "type=\"tile\" origin=\"0.5, 0\" position=\"0.5, 0\"", " />"),
      ("40px", "left top", "repeat",
        "type=\"tile\" origin=\"0, 0\" position=\"0, 0\"",
        " size=\"40px\" aspect=\"atmost\" />"),
      ("40px 20px", "center", "no-repeat",
        "type=\"frame\" origin=\"0, 0\" position=\"0, 0\"",
        " size=\"40px,20px\" />")]
    for (size, pos, repeat, placed, sized) in cases:
      let res = renderTree(sectionDoc([("background-color", "#334455"),
        ("background-image", bg), ("background-size", size)],
        [("background_position", pos), ("background_repeat", repeat)]),
        target = fitTarget())
      check errorsOf(res.diagnostics).len == 0
      let fill = between(res.html, "<v:fill ", "/>")
      check fill == "<v:fill " & placed & " src=\"" & bg &
        "\" color=\"#334455\"" & sized
      # The CSS keeps the values as written (px lengths normalised).
      check ("background-position:" & pos & ";") in res.html
      check ("background-repeat:" & repeat & ";") in res.html

  test "test_background_fallback_colour_is_inherited":
    # No colour of its own: the fallback is the nearest enclosing one,
    # painted on the ghost cell, behind the CSS image and in the fill.
    let r = EmailRenderer()
    let doc = r.newDoc(colour = "#102030")
    let s = r.child(doc, "mailSection", [("background-image", bg)])
    discard r.child(s, "h1", [("color", "#ffffff")], text = "Hello")
    let res = renderTree(doc, target = fitTarget())
    check "color=\"#102030\"" in res.html
    check "<td bgcolor=\"#102030\" style=\"background-color:#102030;\">" in
      res.html
    check "background-color:#102030;background-image:url(" in res.html

  test "test_background_bad_values_are_reported":
    for (prop, value) in [("background-size", "50%"),
        ("background_position", "10px 20px"),
        ("background_repeat", "repeat-x")]:
      let res =
        if prop == "background-size":
          renderTree(sectionDoc([("background-color", "#334455"),
            ("background-image", bg), (prop, value)]))
        else:
          renderTree(sectionDoc([("background-color", "#334455"),
            ("background-image", bg)], [(prop, value)]))
      check codesOf(res.diagnostics).count(codeVocabBadValue) == 1
      # The default is used instead, never the bad value.
      check (":" & value & ";") notin res.html

  test "test_background_props_are_never_copied_through":
    let res = renderTree(sectionDoc([("background-color", "#334455"),
      ("background-image", bg), ("background-size", "contain")],
      [("background_position", "left"), ("background_repeat", "repeat")]))
    check "background_position" notin res.html
    check "background_repeat" notin res.html
    check res.html.count("background-image:") == 1
    check codeLowerMissing notin codesOf(res.diagnostics)

  test "test_wrapper_background":
    let r = EmailRenderer()
    let doc = r.newDoc()
    let w = r.child(doc, "mailWrapper", [("background-color", "#223344"),
      ("background-image", bg), ("padding", "20px 0")])
    let s = r.child(w, "mailSection")
    discard r.child(s, "h1", [("color", "#ffffff")], text = "Hello")
    let res = renderTree(doc, target = fitTarget())
    check errorsOf(res.diagnostics).len == 0
    check res.html.count("<v:rect ") == 1
    check "<td style=\"padding:20px 0;\">" in res.html
    check ("<!--[if !mso]><!--><div style=\"padding:20px 0;" &
      "background-color:#223344;background-image:url(") in res.html

  test "test_full_width_band_keeps_the_image_in_its_container":
    # The bleed is the fallback colour; the image covers the band's
    # container, the box Word's rectangle covers too.
    let res = renderTree(sectionDoc([("background-color", "#334455"),
      ("background-image", bg)], [("full_width", "true")]))
    check "<div style=\"background-color:#334455;\">" in res.html
    check res.html.count("background-image:") == 1
    check "padding:24px;font-size:16px;text-align:left;direction:ltr;" &
      "background-color:#334455;background-image:" in res.html

  test "test_dark_class_sits_with_the_image":
    # Under designed dark, the band's dark colour is a class rule; it
    # must repaint the colour behind the image, never cover it: the
    # class and the image are on the same element.
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.child(doc, "mailSection", [("background-image", bg)])
    r.setStyle(s, "background-color", tok"color.surface.card")
    r.setStyle(s, "@dark:background-color", tok"color.surface.card")
    discard r.child(s, "h1", [("color", "#ffffff")], text = "Hello")
    var t = defaultTarget()
    t.darkMode = dmDesigned
    let res = renderTree(doc, target = t)
    # The section's own class (the designed document has one too).
    let cls = s.attrs.getOrDefault("class", "")
    check cls.startsWith("e-")
    let inner = between(res.html, "align=\"left\" class=\"" & cls & "\"",
      ">")
    check "background-image:url(" in inner
    check "padding:24px;" in inner

suite "mailHero":
  test "test_hero_requires_height_for_vml":
    # rule: R-VML-02
    let missing = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg)]))
    check codesOf(missing.diagnostics).count(codeLayoutVmlSize) == 1
    check hasErrors(missing.diagnostics)
    check "v:rect" notin missing.html
    # Fine when Outlook output is off: no VML, no height needed.
    var off = defaultTarget()
    off.outlookWord = false
    let noWord = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg)]), target = off)
    check errorsOf(noWord.diagnostics).len == 0
    check "v:rect" notin noWord.html
    check "<!--[if mso" notin noWord.html
    check "<!--[if gte mso" notin noWord.html
    # Fine with a height, and with a min_height.
    for prop in ["height", "min-height"]:
      let ok = renderTree(heroDoc([("background-color", "#223344"),
        ("background-image", bg), (prop, "320px")]))
      check errorsOf(ok.diagnostics).len == 0
    # A hero without an image needs no VML, so no height.
    let plain = renderTree(heroDoc([("background-color", "#223344")]))
    check errorsOf(plain.diagnostics).len == 0
    # A height that is not px is the same error.
    let pct = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("height", "50%")]))
    check codeLayoutVmlSize in codesOf(pct.diagnostics)

  test "test_hero_fixed_height_markup":
    let res = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("height", "300px")],
      [("vertical_align", "middle")]))
    check errorsOf(res.diagnostics).len == 0
    check ("<!--[if mso]><table role=\"presentation\" align=\"center\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\" width=\"600\" " &
      "style=\"width:600px;\"><tr><td bgcolor=\"#223344\" " &
      "style=\"background-color:#223344;\"><![endif]-->" &
      "<!--[if gte mso 9]><v:rect xmlns:v=\"urn:schemas-microsoft-com:vml\" " &
      "fill=\"true\" stroke=\"false\" style=\"width:600px;height:300px;\">" &
      "<v:fill type=\"frame\" origin=\"0, 0\" position=\"0, 0\" src=\"" & bg &
      "\" color=\"#223344\" size=\"1,1\" aspect=\"atleast\" />" &
      "<v:textbox inset=\"0,0,0,0\"><![endif]-->" &
      "<div style=\"margin:0 auto;max-width:600px;\">" &
      "<!--[if !mso]><!--><div style=\"background-color:#223344;" &
      "background-image:url(&#x27;" & bg & "&#x27;);" &
      "background-position:center center;background-size:cover;" &
      "background-repeat:no-repeat;\"><!--<![endif]-->" &
      "<table role=\"presentation\" width=\"100%\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" style=\"width:100%;" &
      "table-layout:fixed;\"><tr><td height=\"252\" valign=\"middle\" align=\"left\" " &
      "style=\"padding:24px;height:252px;box-sizing:content-box;" &
      "vertical-align:middle;" &
      "font-size:16px;text-align:left;direction:ltr;\">") in res.html
    check ("</td></tr></table><!--[if !mso]><!--></div><!--<![endif]-->" &
      "</div><!--[if gte mso 9]></v:textbox></v:rect><![endif]-->" &
      "<!--[if mso]></td></tr></table><![endif]-->") in res.html

  test "test_hero_min_height_needs_the_fit_flag":
    # R-VML-03: a min_height hero's rectangle grows only with the fit
    # property, so it is drawn only with `vmlFitToText`; by default Word
    # paints the fallback colour, at least min_height tall.
    let plain = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("min-height", "280px")]))
    check errorsOf(plain.diagnostics).len == 0
    check "v:rect" notin plain.html
    check "<td height=\"232\" valign=\"top\"" in plain.html
    check "<td bgcolor=\"#223344\" style=\"background-color:#223344;\">" in
      plain.html
    let fit = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("min-height", "280px")]),
      target = fitTarget())
    check ("style=\"width:600px;height:280px;\">") in fit.html
    check "<v:textbox inset=\"0,0,0,0\" style=\"mso-fit-shape-to-text:true\">" in
      fit.html
    # A fixed height never grows: no fit, flag or not.
    let fixed = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("height", "280px")]), target = fitTarget())
    check "mso-fit-shape-to-text" notin fixed.html

  test "test_hero_bad_values":
    let both = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("height", "300px"),
      ("min-height", "200px")]))
    check codeVocabBadValue in codesOf(both.diagnostics)
    let tight = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("height", "40px")]))
    check codeVocabBadValue in codesOf(tight.diagnostics)
    let valign = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("height", "300px")],
      [("vertical_align", "center")]))
    check codeVocabBadValue in codesOf(valign.diagnostics)

  test "test_hero_right_to_left":
    let r = EmailRenderer()
    let doc = r.newDoc("rtl")
    let h = r.child(doc, "mailHero", [("background-color", "#223344"),
      ("background-image", bg), ("height", "300px")])
    discard r.child(h, "h1", [("color", "#ffffff")], text = "تخفيضات")
    let res = renderTree(doc)
    check errorsOf(res.diagnostics).len == 0
    check ("<td height=\"252\" valign=\"top\" align=\"right\" " &
      "style=\"padding:24px;height:252px;box-sizing:content-box;" &
      "vertical-align:top;" &
      "font-size:16px;text-align:right;direction:rtl;\">") in res.html

  test "test_hero_nesting":
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.child(doc, "mailSection")
    let h = r.child(s, "mailHero", [("height", "200px")])
    discard r.child(h, "h1", text = "Nested")
    check codeStructNesting in codesOf(renderTree(doc).diagnostics)
    let r2 = EmailRenderer()
    let doc2 = r2.newDoc()
    let h2 = r2.child(doc2, "mailHero", [("height", "200px")])
    let c = r2.child(h2, "mailColumn")
    discard r2.child(c, "h1", text = "Column")
    check codeStructNesting in codesOf(renderTree(doc2).diagnostics)

  test "test_vml_is_not_hidden_from_readers":
    # rule: R-VML-05
    # The rectangle holds the content, so it is never aria-hidden; the
    # content in its text box is the ordinary HTML everyone reads.
    let res = renderTree(heroDoc([("background-color", "#223344"),
      ("background-image", bg), ("height", "300px")]))
    let rect = between(res.html, "<v:rect ", ">")
    check "aria-hidden" notin rect
    let box = between(res.html, "<v:textbox", "</v:textbox>")
    check "<h1 " in box
    check "aria-hidden" notin box

suite "the image URL (R-VML-04)":
  test "test_background_url_must_be_absolute_https":
    for url in ["http://x.test/bg.png", "cid:hero@x", "images/bg.png",
        "data:image/png;base64,iVBORw0=", "https://x.test/a'b.png"]:
      let res = renderTree(sectionDoc([("background-color", "#334455"),
        ("background-image", url)]))
      check codeUrlScheme in codesOf(res.diagnostics)
    let ok = renderTree(sectionDoc([("background-color", "#334455"),
      ("background-image", "url('" & bg & "')")]))
    check codeUrlScheme notin codesOf(ok.diagnostics)

  test "test_background_asset_is_published":
    # A store name resolves through the store, and its published URL is
    # what the CSS and the VML reference.
    let store = memoryAssetStore("https://cdn.example.com")
    store.put("hero.png", "fake-png-bytes")
    let res = renderTree(sectionDoc([("background-color", "#334455"),
      ("background-image", "hero.png")]), target = fitTarget(),
      assets = store)
    check codeUrlScheme notin codesOf(res.diagnostics)
    check res.assets.len == 1
    let url = res.assets[0].url
    check url.startsWith("https://cdn.example.com/")
    check ("src=\"" & url & "\"") in res.html
    check ("background-image:url(&#x27;" & url & "&#x27;)") in res.html

suite "text over an image is checked against the fallback colour":
  test "test_hero_contrast_against_fallback":
    # Light text over a light fallback: a warning naming the fallback.
    let light = renderTree(heroDoc([("background-color", "#eeeeee"),
      ("background-image", bg), ("height", "300px")],
      textColour = "#ffffff"))
    var found: seq[EmailDiagnostic] = @[]
    for d in light.diagnostics:
      if d.code == codeA11yContrast:
        found.add(d)
    check found.len == 1
    if found.len == 1:
      check "fallback colour" in found[0].message
      check "R-VML-01" in found[0].rules
    # The same text over a dark fallback: no warning.
    let dark = renderTree(heroDoc([("background-color", "#1f2937"),
      ("background-image", bg), ("height", "300px")],
      textColour = "#ffffff"))
    check codeA11yContrast notin codesOf(dark.diagnostics)

  test "test_image_without_colour_is_checked_against_the_inherited_one":
    # No fallback of its own: the page's white shows when images are
    # blocked, and white text on it is flagged.
    let res = renderTree(sectionDoc([("background-image", bg)]))
    var msg = ""
    for d in res.diagnostics:
      if d.code == codeA11yContrast:
        msg = d.message
    check "fallback colour" in msg
    # A section with a colour and no image keeps the plain message.
    let plain = renderTree(sectionDoc([("background-color", "#eeeeee")]))
    for d in plain.diagnostics:
      if d.code == codeA11yContrast:
        check "fallback" notin d.message

  test "test_background_props_are_declared_degradations":
    # Word's VML and the clients that drop size or position are the
    # lowering's declared fallbacks: reported as degradations, never as
    # unsupported properties.
    let res = renderTree(sectionDoc([("background-color", "#334455"),
      ("background-image", bg), ("background-size", "cover")],
      [("background_position", "center top")]), profile = business)
    check codeSupportUnsupported notin codesOf(res.diagnostics)
    check codeSupportDegradation in codesOf(res.diagnostics)

suite "the background stories":
  test "test_background_stories_render":
    # Every story of the set renders with no error (a story that fails
    # validation, lowering or its URL check raises), and each carries
    # the markup it exists to show.
    for st in backgroundStories:
      let html = renderBackgroundStory(st.name).html
      if st.name in ["heroMinimal", "heroInContext"]:
        # A hero with no background image: the band of colour whose
        # content sits in one cell (R-VML-06), no image and no VML.
        check "background-image:url(" notin html
        check "<v:rect " notin html
        check "<td valign=\"top\" align=\"left\" style=\"padding:" in html
        continue
      check "background-image:url(" in html
      if st.name in ["heroFullWidth", "heroRtl", "heroImagesOff",
          "heroDark"]:
        check "<v:rect " in html

suite "the attribute form of background_image":
  # `background_image` given as an attribute (a hand-built tree) is read
  # by P8 and P10 exactly as the lowering reads and paints it.
  proc attrDoc(url: string; colour = "#334455";
      text = "#ffffff"): EmailNode =
    let r = EmailRenderer()
    result = r.newDoc()
    let s = r.child(result, "mailSection", [("background-color", colour)],
      [("background_image", url)])
    discard r.child(s, "h1", [("color", text)], text = "Spring sale")

  test "test_attribute_background_url_is_checked":
    for url in ["cid:hero", "http://x.test/bg.png", "images/bg.png"]:
      let res = renderTree(attrDoc(url))
      check codeUrlScheme in codesOf(res.diagnostics)
    let ok = renderTree(attrDoc(bg))
    check codeUrlScheme notin codesOf(ok.diagnostics)
    check ("background-image:url(&#x27;" & bg & "&#x27;)") in ok.html

  test "test_attribute_background_asset_is_published":
    let store = memoryAssetStore("https://cdn.example.com")
    store.put("hero.png", "fake-png-bytes")
    let res = renderTree(attrDoc("hero.png"), target = fitTarget(),
      assets = store)
    check codeUrlScheme notin codesOf(res.diagnostics)
    check res.assets.len == 1
    let url = res.assets[0].url
    check ("src=\"" & url & "\"") in res.html
    check ("background-image:url(&#x27;" & url & "&#x27;)") in res.html

  test "test_attribute_background_contrast_names_the_fallback":
    let res = renderTree(attrDoc(bg, colour = "#eeeeee"))
    var msg = ""
    for d in res.diagnostics:
      if d.code == codeA11yContrast:
        msg = d.message
    check "fallback colour" in msg

suite "a fixed-height hero's content fits (R-VML-08)":
  proc fitDoc(height: string; paragraphs = 0;
      styles: openArray[(string, string)] = []): EmailNode =
    let r = EmailRenderer()
    result = r.newDoc()
    var s = @[("background-color", "#223344"), ("background-image", bg),
      ("height", height)]
    for x in styles:
      s.add(x)
    let h = r.child(result, "mailHero", s)
    discard r.child(h, "h1", [("color", "#ffffff"), ("margin", "0"),
      ("line-height", "36px")], text = "Spring sale")
    for i in 0 ..< paragraphs:
      discard r.child(h, "p", [("color", "#ffffff")], text = "Twenty " &
        "percent off everything in the shop until Sunday, online and in " &
        "every store, while stocks last.")

  test "test_hero_content_fits_at_the_boundary":
    # One heading: 36px of line; the cell is the height less 48px of
    # padding. 84px holds it exactly, 83px does not.
    let fits = renderTree(fitDoc("84px"))
    check codeLayoutHeroOverflow notin codesOf(fits.diagnostics)
    check errorsOf(fits.diagnostics).len == 0
    let over = renderTree(fitDoc("83px"))
    check codesOf(over.diagnostics).count(codeLayoutHeroOverflow) == 1
    for d in over.diagnostics:
      if d.code == codeLayoutHeroOverflow:
        check "36px" in d.message
        check "35px" in d.message

  test "test_hero_overflow_counts_wrapped_lines":
    # A heading and three paragraphs in 120px: the review's case.
    let res = renderTree(fitDoc("120px", paragraphs = 3))
    check codeLayoutHeroOverflow in codesOf(res.diagnostics)
    check hasErrors(res.diagnostics)
    # Each paragraph (about 100 characters at 16px) wraps to two lines
    # of 24px at 552px, the first two with their 16px bottom margin
    # (the last paragraph's is zero): 36 + 64 + 64 + 48 = 212px of
    # content; a 260px hero holds it, 259px does not.
    check codeLayoutHeroOverflow notin codesOf(renderTree(fitDoc("260px",
      paragraphs = 3)).diagnostics)
    check codeLayoutHeroOverflow in codesOf(renderTree(fitDoc("259px",
      paragraphs = 3)).diagnostics)

  test "test_hero_overflow_only_where_word_has_a_fixed_rectangle":
    var off = defaultTarget()
    off.outlookWord = false
    check codeLayoutHeroOverflow notin codesOf(renderTree(fitDoc("83px"),
      target = off).diagnostics)
    let r = EmailRenderer()
    let doc = r.newDoc()
    let h = r.child(doc, "mailHero", [("background-color", "#223344"),
      ("background-image", bg), ("min-height", "83px")])
    discard r.child(h, "h1", [("color", "#ffffff"), ("margin", "0"),
      ("line-height", "36px")], text = "Spring sale")
    check codeLayoutHeroOverflow notin codesOf(renderTree(doc).diagnostics)

  test "test_hero_overflow_counts_buttons_and_spacers":
    let r = EmailRenderer()
    let doc = r.newDoc()
    let h = r.child(doc, "mailHero", [("background-color", "#223344"),
      ("background-image", bg), ("height", "168px")])
    discard r.child(h, "h1", [("color", "#ffffff"), ("margin", "0"),
      ("line-height", "36px")], text = "Spring sale")
    discard r.child(h, "mailSpacer", [("height", "40px")])
    discard r.child(h, "mailButton", attrs = [("href",
      "https://app.example.com/")], text = "Shop")
    # 36 + 40 + a 44px button (20px line, 12px padding a side) = 120px:
    # a 168px hero holds it, 167px does not.
    check codeLayoutHeroOverflow notin codesOf(renderTree(doc).diagnostics)
    let r2 = EmailRenderer()
    let doc2 = r2.newDoc()
    let h2 = r2.child(doc2, "mailHero", [("background-color", "#223344"),
      ("background-image", bg), ("height", "167px")])
    discard r2.child(h2, "h1", [("color", "#ffffff"), ("margin", "0"),
      ("line-height", "36px")], text = "Spring sale")
    discard r2.child(h2, "mailSpacer", [("height", "40px")])
    discard r2.child(h2, "mailButton", attrs = [("href",
      "https://app.example.com/")], text = "Shop")
    check codeLayoutHeroOverflow in codesOf(renderTree(doc2).diagnostics)

  test "test_hero_overflow_measures_spacing_and_transform":
    # The heading is measured as drawn. "Spring sale on everything" is
    # one line of the 552px cell (359px at 28px bold); with a 12px
    # letter-spacing it is 659px, two lines: 72px in a 36px cell.
    proc headed(text, height: string;
        styles: openArray[(string, string)]): EmailNode =
      let r = EmailRenderer()
      result = r.newDoc()
      let h = r.child(result, "mailHero", [("background-color", "#223344"),
        ("background-image", bg), ("height", height)])
      var s = @[("color", "#ffffff"), ("margin", "0"),
        ("line-height", "36px")]
      for x in styles:
        s.add(x)
      discard r.child(h, "h1", s, text = text)
    let plain = "Spring sale on everything"
    check codeLayoutHeroOverflow notin codesOf(renderTree(headed(plain,
      "84px", [])).diagnostics)
    check codeLayoutHeroOverflow in codesOf(renderTree(headed(plain,
      "84px", [("letter-spacing", "12px")])).diagnostics)
    check codeLayoutHeroOverflow notin codesOf(renderTree(headed(plain,
      "120px", [("letter-spacing", "12px")])).diagnostics)
    # Uppercase, "Spring sale on everything today" grows from 446px (one
    # line) to 562px (two).
    let longer = "Spring sale on everything today"
    check codeLayoutHeroOverflow notin codesOf(renderTree(headed(longer,
      "84px", [])).diagnostics)
    check codeLayoutHeroOverflow in codesOf(renderTree(headed(longer,
      "84px", [("text-transform", "uppercase")])).diagnostics)
    # Inherited from the hero itself.
    let r = EmailRenderer()
    let doc = r.newDoc()
    let h = r.child(doc, "mailHero", [("background-color", "#223344"),
      ("background-image", bg), ("height", "84px"),
      ("text-transform", "uppercase")])
    discard r.child(h, "h1", [("color", "#ffffff"), ("margin", "0"),
      ("line-height", "36px")], text = longer)
    check codeLayoutHeroOverflow in codesOf(renderTree(doc).diagnostics)

  test "test_hero_overflow_measures_the_widest_face":
    # "Spring sale on almost everything" is 462px in Arial (one line of
    # 552px) and 567px in Courier: a stack that may fall back to
    # Courier New is measured in Courier.
    proc stacked(stack: string): EmailNode =
      let r = EmailRenderer()
      result = r.newDoc()
      let h = r.child(result, "mailHero", [("background-color", "#223344"),
        ("background-image", bg), ("height", "84px")])
      discard r.child(h, "h1", [("color", "#ffffff"), ("margin", "0"),
        ("line-height", "36px"), ("font-family", stack)],
        text = "Spring sale on almost everything")
    check codeLayoutHeroOverflow notin codesOf(renderTree(stacked(
      "Arial, sans-serif")).diagnostics)
    check codeLayoutHeroOverflow in codesOf(renderTree(stacked(
      "Arial, 'Courier New', monospace")).diagnostics)

  test "test_hero_overflow_reports_approximate_metrics":
    let r = EmailRenderer()
    let doc = r.newDoc()
    let h = r.child(doc, "mailHero", [("background-color", "#223344"),
      ("background-image", bg), ("height", "200px")])
    discard r.child(h, "h1", [("color", "#ffffff")], text = "春のセール")
    check codeLayoutMetricsApprox in codesOf(renderTree(doc).diagnostics)
