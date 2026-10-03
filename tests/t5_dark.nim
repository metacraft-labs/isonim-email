## The dark-mode system: the token-driven dark pairs and the dark block
## (`passes/styles.nim`, `passes/head.nim`), the designed skeleton's
## surface and the page below the message, the shadowed box's dark
## border, the inversion simulation and the logo check
## (`passes/lint.nim`), the PNG reader behind it (`imaging.nim`), and
## the dark-image swap (`lower/image.nim`).
##
## Backend-independent (tree building + pure passes; the fixture images
## load via `staticRead`), so `just test` also runs it on JS. No test
## doubles: the asset store is the library's in-memory one.
# rule: R-DRK-01
# rule: R-DRK-02
# rule: R-DRK-03
# rule: R-DRK-04
# rule: R-DRK-05
# rule: R-DRK-06
# rule: R-IMG-06
# rule: R-A11Y-05
# rule: R-OL-14
# rule: R-TBL-09
import std/[os, strutils, tables, unittest]
import isonim_email
import stories/seed_dark

proc codesOfAll(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

const assetsDir = parentDir(currentSourcePath()) / "stories" / "assets"
const outlinedPng = staticRead(assetsDir / "mark-outlined.png")
const barePng = staticRead(assetsDir / "mark-bare.png")
const darkPng = staticRead(assetsDir / "mark-dark.png")
const logoPng = staticRead(assetsDir / "logo.png")
const iconPng = staticRead(parentDir(parentDir(currentSourcePath())) /
  "src" / "isonim_email" / "assets" / "social" / "social-github-light.png")

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

proc newDoc(r: EmailRenderer): EmailNode =
  r.child(nil, "mailDocument", attrs = [("lang", "en"), ("dir", "ltr"),
    ("title", "Dark"), ("preheader", "Dark mode.")])

proc target(mode: DarkModeStrategy): EmailTarget =
  result = defaultTarget()
  result.darkMode = mode

proc withCode(diags: openArray[EmailDiagnostic];
    code: string): seq[EmailDiagnostic] =
  for d in diags:
    if d.code == code:
      result.add(d)

proc inverted(diags: openArray[EmailDiagnostic]): seq[EmailDiagnostic] =
  ## The inversion simulation's findings, at either severity.
  for d in diags:
    if d.code in [codeA11yContrastInvertedInfo, codeA11yContrastInverted]:
      result.add(d)

proc darkBlock(html: string): string =
  ## Block 3's text, "" when there is none.
  let i = html.find("(prefers-color-scheme: dark)")
  if i < 0:
    return ""
  let a = html.rfind("<style>", last = i)
  html[a ..< html.find("</style>", i)]

proc tokenDoc(r: EmailRenderer): tuple[doc, section, p: EmailNode] =
  ## A document whose colours are all tokens, with no `@dark:` at all.
  let doc = r.newDoc()
  r.setStyle(doc, "background-color", tok"color.surface.canvas")
  let s = r.child(doc, "mailSection")
  r.setStyle(s, "background-color", tok"color.surface.card")
  discard r.child(s, "h1", text = "Hello")
  let p = r.child(s, "p", text = "Secondary text.")
  r.setStyle(p, "color", tok"color.text.secondary")
  (doc, s, p)

suite "dark pairs come from the tokens (R-DRK-02, R-DRK-03)":
  test "test_token_colours_get_their_dark_rules":
    let r = EmailRenderer()
    let (doc, s, p) = r.tokenDoc()
    let res = renderTree(doc, target = target(dmDesigned))
    check withCode(res.diagnostics, codeA11yContrastDark).len == 0
    check withCode(res.diagnostics, codeDarkRawColor).len == 0
    let blk = darkBlock(res.html)
    for (node, decl) in [(doc, "background-color:#0f1115 !important"),
        (s, "background-color:#1a1d23 !important"),
        (p, "color:#c3c8d0 !important")]:
      let cls = node.attrs.getOrDefault("class", "")
      checkpoint(node.tag & " " & cls)
      check cls.startsWith("e-")
      check ("." & cls & "{" & decl & "}") in blk
    # R-DRK-03: the Outlook copies split by property.
    let pc = p.attrs["class"]
    check ("[data-ogsc] ." & pc & "{color:#c3c8d0 !important}") in blk
    check ("[data-ogsb] ." & pc) notin blk
    let sc = s.attrs["class"]
    check ("[data-ogsb] ." & sc & "{background-color:#1a1d23 !important}") in
      blk
    check ("[data-ogsc] ." & sc) notin blk
    # The generated class is R-CSS-08's, never an `e-dk-` name.
    check "e-dk-" notin res.html

  test "test_no_dark_css_outside_designed":
    for mode in [dmNone, dmAccommodate]:
      let r = EmailRenderer()
      let (doc, s, _) = r.tokenDoc()
      let res = renderTree(doc, target = target(mode))
      checkpoint($mode)
      check "prefers-color-scheme" notin res.html
      check "data-ogs" notin res.html
      check "class" notin s.attrs
      check "class" notin doc.attrs

  test "test_an_elements_own_dark_declaration_wins":
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.child(doc, "mailSection")
    r.setStyle(s, "background-color", tok"color.surface.card")
    r.setStyle(s, "@dark:background-color", "#000000")
    discard r.child(s, "h1", text = "Hello")
    let res = renderTree(doc, target = target(dmDesigned))
    let blk = darkBlock(res.html)
    check ("." & s.attrs["class"] & "{background-color:#000000 !important}") in
      blk
    # The section's own rule and its Outlook copy, nothing else.
    check blk.count("." & s.attrs["class"] & "{") == 2

  test "test_a_token_with_one_value_needs_no_rule":
    var theme = defaultTheme()
    theme.values["color.surface.card"] = ThemePair(light: "#ffffff",
      dark: "#ffffff")
    let r = EmailRenderer()
    let doc = r.newDoc()
    r.setStyle(doc, "background-color", tok"color.surface.canvas")
    let s = r.child(doc, "mailSection")
    r.setStyle(s, "background-color", tok"color.surface.card")
    discard r.child(s, "h1", [("color", "#111827")], text = "Hello")
    discard renderTree(doc, theme = theme, target = target(dmDesigned))
    check "class" notin s.attrs

  test "test_raw_colours_warn_and_get_no_dark_rule":
    # A raw colour under designed has no dark value to emit.
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.child(doc, "mailSection", [("background-color", "#334155")])
    discard r.child(s, "h1", [("color", "#ffffff")], text = "Hello")
    let res = renderTree(doc, target = target(dmDesigned))
    check withCode(res.diagnostics, codeDarkRawColor).len == 2
    check "class" notin s.attrs
    # Not under accommodate.
    let r2 = EmailRenderer()
    let doc2 = r2.newDoc()
    let s2 = r2.child(doc2, "mailSection", [("background-color", "#334155")])
    discard r2.child(s2, "h1", [("color", "#ffffff")], text = "Hello")
    check withCode(renderTree(doc2).diagnostics, codeDarkRawColor).len == 0

  test "test_designed_document_surface_and_the_page_below":
    # A designed document with no background is `color.surface.card`:
    # the light bytes keep the skeleton's #ffffff, and the dark block
    # paints the wrapper, its table and the page below the message
    # (`body`, selected as an element: it carries no class, R-DOC-14).
    let r = EmailRenderer()
    let doc = r.newDoc()
    discard r.child(doc, "h1", text = "Hello")
    let res = renderTree(doc, target = target(dmDesigned))
    check withCode(res.diagnostics, codeA11yContrastDark).len == 0
    let cls = doc.attrs["class"]
    check "<body xml:lang=\"en\" style=\"margin:0;padding:0;word-spacing:" &
      "normal;background-color:#ffffff;\">" in res.html
    check ("aria-label=\"Dark\" lang=\"en\" dir=\"ltr\" class=\"" & cls &
      "\" style=\"background-color:#ffffff;") in res.html
    check ("cellspacing=\"0\" class=\"" & cls &
      "\" style=\"background-color:#ffffff;\">") in res.html
    let blk = darkBlock(res.html)
    check "body{background-color:#1a1d23 !important}" in blk
    check "[data-ogsb] body" notin blk
    # Without a document dark value there is no body rule.
    let r2 = EmailRenderer()
    let doc2 = r2.newDoc()
    r2.setStyle(doc2, "background-color", "#ffffff")
    let s2 = r2.child(doc2, "mailSection")
    r2.setStyle(s2, "background-color", tok"color.surface.card")
    discard r2.child(s2, "h1", text = "Hello")
    check "body{" notin darkBlock(renderTree(doc2,
      target = target(dmDesigned)).html)

  test "test_shadowed_box_border_follows_the_dark_background":
    # R-TBL-09: the derived border is one step darker than the box's
    # background, in the dark scheme too.
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.child(doc, "mailSection")
    r.setStyle(s, "background-color", tok"color.surface.subtle")
    let b = r.child(s, "mailBox", attrs = [("shadow", "sm")])
    r.setStyle(b, "background-color", tok"color.surface.card")
    discard r.child(b, "h1", text = "Hello")
    let res = renderTree(doc, target = target(dmDesigned))
    let cls = b.attrs["class"]
    let rule = "." & cls & "{background-color:#1a1d23 !important;" &
      "border-color:" & darkerStep("#1a1d23") & " !important}"
    check rule in darkBlock(res.html)
    check ("border:1px solid " & darkerStep("#ffffff")) in res.html
    # A box with a border of its own keeps it.
    let r2 = EmailRenderer()
    let doc2 = r2.newDoc()
    let b2 = r2.child(doc2, "mailBox", [("border", "1px solid #e5e7eb")],
      [("shadow", "sm")])
    r2.setStyle(b2, "background-color", tok"color.surface.card")
    discard r2.child(b2, "h1", text = "Hello")
    check "border-color:" notin darkBlock(renderTree(doc2,
      target = target(dmDesigned)).html)

  test "test_no_blend_mode_hack":
    # R-DRK-05: the Gmail iOS blend-mode wrappers are never written.
    let r = EmailRenderer()
    let (doc, _, _) = r.tokenDoc()
    let html = renderTree(doc, target = target(dmDesigned)).html
    check "mix-blend-mode" notin html
    check "gmail-blend" notin html

  test "test_families_that_never_apply_the_dark_block":
    # R-DRK-01: everything but apple, outlookApp, outlookWeb, samsung,
    # thunderbird and fastmail shows the light image of a pair.
    check noSwapFamilies == allFamilies - {cfApple, cfOutlookApp,
      cfOutlookWeb, cfSamsung, cfThunderbird, cfFastmail}

suite "the inversion simulation (R-DRK-04)":
  test "test_inversion_simulation_flags_mud":
    # Mid-tone brand colours that pass in light and invert into mud:
    # white on a #2563a8 band is 6.12:1, and full inversion makes it
    # black on a mid blue, 3.53:1; #2f6db5 text on white is 5.28:1 and
    # 3.06:1 inverted (partial and full alike).
    proc palette(fg, bg: string; mode = dmAccommodate): RenderedEmail =
      let r = EmailRenderer()
      let doc = r.newDoc()
      let s = r.child(doc, "mailSection", [("background-color", bg)])
      discard r.child(s, "p", [("color", fg)], text = "Brand band")
      discard r.child(s, "p", [("color", fg)], text = "Same pair.")
      renderTree(doc, target = target(mode))
    let mud = palette("#ffffff", "#2563a8")
    check withCode(mud.diagnostics, codeA11yContrast).len == 0
    let found = withCode(mud.diagnostics, codeA11yContrastInvertedInfo)
    check found.len == 1
    check "#ffffff on #2563a8" in found[0].message
    check "full inversion" in found[0].message
    check "the same pair on 1 more element" in found[0].message
    check found[0].families == fullInverters
    # Information until the model is calibrated (R-DRK-04): neither
    # model is yet, so nothing here is a warning.
    check found[0].severity == sevInfo
    check "uncalibrated model: for information" in found[0].message
    check modelCalibrated == [false, false]
    for d in mud.diagnostics:
      check d.code != codeA11yContrastInverted
    # Partial inversion: mid-tone text on white.
    let partial = palette("#2f6db5", "#ffffff")
    check withCode(partial.diagnostics, codeA11yContrast).len == 0
    var models: seq[string] = @[]
    for d in withCode(partial.diagnostics, codeA11yContrastInvertedInfo):
      check "#2f6db5 on #ffffff" in d.message
      models.add(if "partial inversion" in d.message: "partial" else: "full")
    check "partial" in models
    # A safe palette: near-black on white, and white on near-black.
    check inverted(palette("#111827", "#ffffff").diagnostics).len == 0
    check inverted(palette("#ffffff", "#111827").diagnostics).len == 0
    # Designed mail is simulated too: the inverting clients ignore its
    # dark block.
    check withCode(palette("#ffffff", "#2563a8", dmDesigned).diagnostics,
      codeA11yContrastInvertedInfo).len == 1

  test "test_dark_mode_none_emits_nothing_dark":
    # Negative control: no color-scheme meta, no dark rules, and no
    # inversion simulation (the message accepts the client's defaults).
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.child(doc, "mailSection", [("background-color", "#2563a8")])
    discard r.child(s, "h1", [("color", "#ffffff")], text = "Brand band")
    let res = renderTree(doc, target = target(dmNone))
    check "color-scheme" notin res.html
    check "prefers-color-scheme" notin res.html
    check "data-ogs" notin res.html
    check inverted(res.diagnostics).len == 0

  test "test_inversion_models":
    let white = parseColor("#ffffff")
    let ink = parseColor("#111827")
    # Partial: a light background darkens, dark text lightens; a dark
    # background and light text stay.
    let (f1, b1) = invertPair(ink, white, imPartial)
    check b1.toHex() == "#000000"
    check relLuminance(f1) > 0.4
    let (f2, b2) = invertPair(white, ink, imPartial)
    check f2.toHex() == "#ffffff"
    check b2.toHex() == "#111827"
    # Full: both turn around.
    let (f3, b3) = invertPair(white, ink, imFull)
    check f3.toHex() == "#000000"
    check b3.toHex() == invertLightness(ink).toHex()
    # Lightness inversion keeps hue and chroma.
    let blue = parseColor("#1f6feb")
    let (l0, c0, h0) = rgbToOklch(blue)
    let (l1, c1, h1) = rgbToOklch(invertLightness(blue))
    check abs(l0 + l1 - 1.0) < 0.02
    check abs(c0 - c1) < 0.03
    check abs(h0 - h1) < 3.0

  test "test_inversion_is_weighted_by_the_profile":
    # A profile with no weight on the inverting families is not checked.
    var weights: array[ClientFamily, float]
    weights[cfApple] = 1.0
    let appleOnly = makeProfile("appleOnly", weights)
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.child(doc, "mailSection", [("background-color", "#2563a8")])
    discard r.child(s, "p", [("color", "#ffffff")], text = "Brand band")
    check inverted(renderTree(doc, profile = appleOnly).diagnostics).len == 0
    let r2 = EmailRenderer()
    let doc2 = r2.newDoc()
    let s2 = r2.child(doc2, "mailSection", [("background-color", "#2563a8")])
    discard r2.child(s2, "p", [("color", "#ffffff")], text = "Brand band")
    let d = withCode(renderTree(doc2, profile = consumer).diagnostics,
      codeA11yContrastInvertedInfo)
    check d.len == 1
    check abs(d[0].weight - consumer.weights[cfGmailApp]) < 1e-9

  test "test_default_palette_under_the_models":
    # What the uncalibrated models say about the default theme, pinned
    # so a change to either is seen: body text passes both; the link
    # and the accent button fall into mud (see the catalogue's R-DRK-04).
    proc pairOf(fg, bg: string; model: InversionModel): float =
      let (f, b) = invertPair(parseColor(fg), parseColor(bg), model)
      contrastRatio(f, b)
    let t = defaultTheme()
    let primary = t.lightFor("color.text.primary")
    let card = t.lightFor("color.surface.card")
    for m in InversionModel:
      check pairOf(primary, card, m) >= 4.5
    check pairOf(t.lightFor("color.link"), card, imPartial) < 4.5
    check pairOf(t.lightFor("color.accent.primaryText"),
      t.lightFor("color.accent.primary"), imPartial) >= 4.5
    check pairOf(t.lightFor("color.accent.primaryText"),
      t.lightFor("color.accent.primary"), imFull) < 4.5

proc logoDoc(r: EmailRenderer; src, darkSrc: string; href = "";
    width = "120px"): tuple[doc, img: EmailNode] =
  let doc = r.newDoc()
  let s = r.child(doc, "mailSection")
  r.setStyle(s, "background-color", tok"color.surface.card")
  var attrs = @[("src", src), ("dark_src", darkSrc), ("alt", "Acme")]
  if href.len > 0:
    attrs.add(("href", href))
  let img = r.child(s, "mailImage", [("width", width)], attrs)
  discard r.child(s, "h1", text = "Hello")
  (doc, img)


suite "the dark-image swap (R-IMG-06, R-A11Y-05, R-OL-14)":
  test "test_dark_src_writes_the_pair_under_designed":
    let r = EmailRenderer()
    let (doc, _) = r.logoDoc("https://x.test/logo.png",
      "https://x.test/logo-dark.png", href = "https://example.com/")
    let res = renderTree(doc, target = target(dmDesigned))
    check codeLowerMissing notin codesOfAll(res.diagnostics)
    let html = res.html
    let a = html.find("<a href=\"https://example.com/\"")
    check a >= 0
    let link = html[a ..< html.find("</a>", a)]
    # Both images in the link, light first.
    let light = link.find("<img src=\"https://x.test/logo.png\"")
    let dark = link.find("<img src=\"https://x.test/logo-dark.png\"")
    check light >= 0 and dark > light
    let lightTag = link[light ..< link.find(">", light)]
    let darkTag = link[dark ..< link.find(">", dark)]
    check "e-dk-hide" in lightTag
    check "e-dk-show" notin lightTag
    check "e-dk-show" in darkTag
    check "e-dk-hide" notin darkTag
    check "style=\"display:none;" in darkTag
    check "mso-hide:all;" in darkTag
    check "display:none" notin lightTag
    # R-A11Y-05 (settled): both carry the alt; the hidden one is out of
    # the accessibility tree through display:none, so neither is
    # aria-hidden (an aria-hidden dark copy would stay hidden from
    # readers after the swap, when the light one is display:none).
    check "alt=\"Acme\"" in lightTag and "alt=\"Acme\"" in darkTag
    check "aria-hidden" notin lightTag and "aria-hidden" notin darkTag
    # The swap rules, with their Outlook copies.
    let blk = darkBlock(html)
    check ".e-dk-hide{display:none !important}" in blk
    check ".e-dk-show{display:block !important}" in blk
    check "[data-ogsc] .e-dk-hide{display:none !important}" in blk
    check "[data-ogsc] .e-dk-show{display:block !important}" in blk

  test "test_dark_copy_without_word_has_no_mso_hide":
    var t = target(dmDesigned)
    t.outlookWord = false
    let r = EmailRenderer()
    let (doc, _) = r.logoDoc("https://x.test/logo.png",
      "https://x.test/logo-dark.png")
    let html = renderTree(doc, target = t).html
    let i = html.find("<img src=\"https://x.test/logo-dark.png\"")
    check i >= 0
    let tag = html[i ..< html.find(">", i)]
    check "display:none;" in tag
    check "mso-hide" notin tag

  test "test_fluid_dark_copy_sits_beside_the_web_image":
    let r = EmailRenderer()
    let (doc, _) = r.logoDoc("https://x.test/scene.png",
      "https://x.test/scene-dark.png", width = "100%")
    let html = renderTree(doc, target = target(dmDesigned)).html
    # Word's copy is the light image only; the dark one is hidden from
    # Word by its conditional.
    check html.count("https://x.test/scene-dark.png") == 1
    check "<!--[if !mso]><!--><img src=\"https://x.test/scene-dark.png\"" in
      html
    let i = html.find("<img src=\"https://x.test/scene-dark.png\"")
    check "mso-hide" notin html[i ..< html.find(">", i)]

  test "test_one_image_without_the_dark_block":
    # accommodate and none write no dark block, and a dark block dropped
    # for budget leaves no swap: the light image alone.
    for mode in [dmNone, dmAccommodate]:
      let r = EmailRenderer()
      let (doc, img) = r.logoDoc("https://x.test/logo.png",
        "https://x.test/logo-dark.png")
      let res = renderTree(doc, target = target(mode))
      checkpoint($mode)
      check "logo-dark.png" notin res.html
      check "e-dk-" notin res.html
      check "class" notin img.attrs
    var tight = target(dmDesigned)
    tight.headStyleBudget = 1
    let r = EmailRenderer()
    let (doc, _) = r.logoDoc("https://x.test/logo.png",
      "https://x.test/logo-dark.png")
    let res = renderTree(doc, target = tight)
    check withCode(res.diagnostics, codeCssBlockDropped).len > 0
    check "logo-dark.png" notin res.html
    check "e-dk-" notin res.html

  test "test_p7_marks_neither_image":
    # The pair does not exist on the authoring tree P7 walks, and its
    # lowering writes no aria-hidden: nothing in the swap is hidden
    # from readers by attribute.
    let r = EmailRenderer()
    let (doc, img) = r.logoDoc("https://x.test/logo.png",
      "https://x.test/logo-dark.png")
    let res = renderTree(doc, target = target(dmDesigned))
    check "aria-hidden" notin img.attrs
    let body = res.html[res.html.find("<div role=\"article\"") .. ^1]
    check "aria-hidden" notin body

  test "test_dark_src_is_published_like_src":
    let store = memoryAssetStore("https://cdn.example.com")
    store.put("mark.png", outlinedPng)
    store.put("mark-dark.png", darkPng)
    let r = EmailRenderer()
    let (doc, img) = r.logoDoc("mark.png", "mark-dark.png")
    let res = renderTree(doc, target = target(dmDesigned), assets = store)
    check res.assets.len == 2
    check img.attrs["src"].startsWith("https://cdn.example.com/")
    check img.attrs["dark_src"].startsWith("https://cdn.example.com/")
    check img.attrs["dark_src"].endsWith("/mark-dark.png")
    check ("<img src=\"" & img.attrs["dark_src"] & "\"") in res.html

proc be32s(n: int): string =
  result = newString(4)
  for i in 0 .. 3:
    result[i] = chr((n shr (8 * (3 - i))) and 0xFF)

proc be32u(n: uint32): string =
  result = newString(4)
  for i in 0 .. 3:
    result[i] = chr(int((n shr uint32(8 * (3 - i))) and 0xFF'u32))

proc refCrc(data: string): uint32 =
  ## CRC-32, written out here independently of the decoder's (a
  ## table-driven form).
  var table: array[256, uint32]
  for i in 0 ..< 256:
    var c = uint32(i)
    for _ in 0 ..< 8:
      c = if (c and 1'u32) == 1'u32: 0xEDB88320'u32 xor (c shr 1)
        else: c shr 1
    table[i] = c
  var c = not 0'u32
  for ch in data:
    c = table[int((c xor uint32(ord(ch))) and 0xFF'u32)] xor (c shr 8)
  not c

proc refAdler(data: string): uint32 =
  var a = 1'u32
  var b = 0'u32
  for ch in data:
    a = (a + uint32(ord(ch))) mod 65521'u32
    b = (b + a) mod 65521'u32
  b * 65536'u32 + a

proc chunk(t, body: string): string =
  be32s(body.len) & t & body & be32u(refCrc(t & body))

proc storedPng(w, h, colorType, depth: int; scanlines: string;
    plte = ""; trns = ""; header = "\x78\x01"; badNlen = false;
    badAdler = false): string =
  ## A PNG whose IDAT is zlib with one stored (uncompressed) block: the
  ## decoder's stored-block path, and filtered rows written by hand;
  ## valid CRCs and Adler-32 unless asked otherwise.
  var z = header & "\x01"
  z.add(chr(scanlines.len and 0xFF) & chr(scanlines.len shr 8))
  var inv = (not scanlines.len) and 0xFFFF
  if badNlen:
    inv = inv xor 1
  z.add(chr(inv and 0xFF) & chr(inv shr 8))
  z.add(scanlines)
  z.add(be32u(refAdler(scanlines) xor (if badAdler: 1'u32 else: 0'u32)))
  result = "\x89PNG\r\n\x1A\n" & chunk("IHDR", be32s(w) & be32s(h) &
    chr(depth) & chr(colorType) & "\0\0\0")
  if plte.len > 0: result.add(chunk("PLTE", plte))
  if trns.len > 0: result.add(chunk("tRNS", trns))
  result.add(chunk("IDAT", z) & chunk("IEND", ""))

proc filtered(rows: seq[seq[int]]; filters: seq[int]; bpp: int): string =
  ## `rows` (bytes) under the given scanline filter per row.
  var prev = newSeq[int](rows[0].len)
  for y, row in rows:
    result.add(chr(filters[y]))
    for x, v in row:
      let a = if x >= bpp: row[x - bpp] else: 0
      let b = prev[x]
      let c = if x >= bpp: prev[x - bpp] else: 0
      let pred = case filters[y]
        of 0: 0
        of 1: a
        of 2: b
        of 3: (a + b) div 2
        else:
          let p = a + b - c
          if abs(p - a) <= abs(p - b) and abs(p - a) <= abs(p - c): a
          elif abs(p - b) <= abs(p - c): b
          else: c
      result.add(chr((v - pred + 256) and 0xFF))
    prev = row

suite "a logo with no swap must be dark-safe (R-DRK-06)":
  test "test_png_filters_and_formats":
    # Every scanline filter over RGBA rows, through a stored block.
    let rows = @[@[10, 200, 30, 255, 250, 5, 90, 128],
      @[12, 190, 60, 0, 240, 15, 80, 255],
      @[200, 100, 50, 255, 1, 2, 3, 4],
      @[7, 70, 170, 9, 99, 199, 249, 255],
      @[0, 255, 0, 255, 255, 0, 255, 0]]
    let rgba = decodePng(storedPng(2, 5, 6, 8, filtered(rows,
      @[0, 1, 2, 3, 4], 4)))
    check rgba.ok
    var want: seq[uint8] = @[]
    for row in rows:
      for v in row:
        want.add(uint8(v))
    check rgba.rgba == want
    # A 2-bit palette with tRNS: index 1 transparent.
    let pal = decodePng(storedPng(4, 1, 3, 2, "\0" & chr(0b00_01_10_00),
      plte = "\xff\0\0" & "\0\xff\0" & "\0\0\xff",
      trns = "\xff\x00"))
    check pal.ok
    check pal.rgba == @[255'u8, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 255,
      255, 0, 0, 255]
    # 16-bit grey with alpha: the high byte, scaled.
    let grey = decodePng(storedPng(1, 1, 4, 16, "\0\x80\x00\xff\xff"))
    check grey.ok
    check grey.rgba == @[128'u8, 128, 128, 255]
    # Interlaced images are not read (the flag set with a valid CRC).
    let one = "\0\x10\x20\x30\x40"
    check decodePng(storedPng(1, 1, 6, 8, one)).ok
    let ihdr = chunk("IHDR", be32s(1) & be32s(1) & "\x08\x06\0\0\x01")
    let plain = storedPng(1, 1, 6, 8, one)
    check not decodePng(plain[0 ..< 8] & ihdr & plain[33 .. ^1]).ok

  test "test_inflate_fixed_codes_and_short_distances":
    # zlib's output (level 9: a fixed-Huffman block) for runs repeating
    # with periods 1 to 13: distance codes 0 to 8, with their extra bits.
    const stream = "\x78\xda\x4b\x4c\x44\x02\x49\xb8\x60\x32\x31\x28" &
      "\x85\x54\x9c\x4a\x09\x91\x46\x2d\x32\x9d\x16\x54\x06\xad\xe9" &
      "\x4c\x7a\x32\xb2\x06\x8a\x95\x3d\x18\x98\x39\x83\x8d\x9d\x3b" &
      "\xc8\x38\x00\xb8\x21\xae\xe4"
    var plain = ""
    for period in 1 .. 13:
      for _ in 0 ..< 12:
        for k in 0 ..< period:
          plain.add(chr(ord('a') + k))
    check inflate(stream, 2) == plain
    # A bound on the output: the stream is refused once past it.
    expect CatchableError:
      discard inflate(stream, 2, maxLen = 100)
    check inflate(stream, 2, maxLen = plain.len) == plain

  test "test_png_decoding":
    let px = decodePng(outlinedPng)
    check px.ok
    check px.width == 240 and px.height == 80
    proc at(x, y: int): array[4, uint8] =
      let o = (y * px.width + x) * 4
      [px.rgba[o], px.rgba[o + 1], px.rgba[o + 2], px.rgba[o + 3]]
    check at(40, 40) == [31'u8, 41, 55, 255]    # the mark
    check at(0, 0) == [0'u8, 0, 0, 0]           # transparent
    check at(14, 40) == [255'u8, 255, 255, 255] # the outline
    # Every pixel, against the decoded bytes of an independent decoder
    # (Python's zlib, unfiltered by hand), by digest.
    proc digest(p: Pixels): string =
      var raw = newString(p.rgba.len)
      for i, v in p.rgba:
        raw[i] = chr(v)
      sha256Hex(raw)
    check digest(px) ==
      "ec662149c1ca754e6a4491f2063d927ecf26f26114f212987a9fd692614b77d8"
    check digest(decodePng(barePng)) ==
      "c95e720755ff081a2b0bae8ee25ad373d866322ec437c805fa61e2dc11e813c8"
    check digest(decodePng(darkPng)) ==
      "e6f527e498af2a5f6d21825bfebda663ac6c5c8c27d568ead2869ae27cbb9e2e"
    check digest(decodePng(logoPng)) ==
      "06d76eddfc965cd7572cbdd4ceaeae5ea2a04dc2b487854c48d5e3370f02e693"
    check digest(decodePng(iconPng)) ==
      "9902347d0dc7a8ad410f5c601c93cc042270bc6852886eb575b9f44bf36bc80a"
    # Other encoders' output (the fixture logo, a built-in icon).
    check decodePng(logoPng).ok
    check decodePng(iconPng).ok
    check not decodePng("not a png").ok
    check not decodePng(outlinedPng[0 ..< 60]).ok

  test "test_png_integrity_is_verified":
    # The CRC-32 and Adler-32 implementations, against their standard
    # check values.
    check crc32("123456789") == 0xCBF43926'u32
    check adler32("Wikipedia") == 0x11E60398'u32
    # A flipped byte in IHDR's CRC, and in IDAT's.
    var badIhdr = outlinedPng
    badIhdr[29] = chr(ord(badIhdr[29]) xor 1)
    check not decodePng(badIhdr).ok
    let idatAt = outlinedPng.find("IDAT") - 4
    let idatLen = (ord(outlinedPng[idatAt + 2]) shl 8) or
      ord(outlinedPng[idatAt + 3])
    var badIdat = outlinedPng
    let crcAt = idatAt + 8 + idatLen
    badIdat[crcAt + 3] = chr(ord(badIdat[crcAt + 3]) xor 1)
    check not decodePng(badIdat).ok
    # A flipped data byte: the CRC catches it.
    var badData = outlinedPng
    badData[idatAt + 20] = chr(ord(badData[idatAt + 20]) xor 1)
    check not decodePng(badData).ok
    # zlib's own checks, with every chunk CRC valid: the Adler-32, a
    # stored block's NLEN, and the header (FCHECK, the method, a preset
    # dictionary).
    let rows = "\0\x10\x20\x30\x40"
    check decodePng(storedPng(1, 1, 6, 8, rows)).ok
    check not decodePng(storedPng(1, 1, 6, 8, rows, badAdler = true)).ok
    check not decodePng(storedPng(1, 1, 6, 8, rows, badNlen = true)).ok
    check not decodePng(storedPng(1, 1, 6, 8, rows, header = "\x78\x02")).ok
    # Valid FCHECK, but compression method 9; and a 64 KiB window.
    check not decodePng(storedPng(1, 1, 6, 8, rows, header = "\x79\x18")).ok
    check not decodePng(storedPng(1, 1, 6, 8, rows, header = "\x88\x1c")).ok
    check not decodePng(storedPng(1, 1, 6, 8, rows, header = "\x78\x20")).ok
    # More data than the scanlines need, or less: not decoded.
    check not decodePng(storedPng(1, 1, 6, 8, rows & "\0")).ok
    check not decodePng(storedPng(1, 2, 6, 8, rows)).ok

  test "test_oversized_logo_is_not_decoded":
    # Over 4096 × 4096 pixels the image is not decompressed: the logo
    # check reports it unchecked, as information.
    let big = storedPng(4097, 4096, 6, 8, "\0")
    let px = decodePng(big)
    check not px.ok
    check px.tooLarge
    check px.rgba.len == 0
    check not decodePng(storedPng(4096, 4096, 6, 8, "\0")).tooLarge
    check logoVerdict(big).verdict == lvTooLarge
    let store = memoryAssetStore("https://cdn.example.com")
    store.put("mark.png", big)
    store.put("mark-dark.png", darkPng)
    let r = EmailRenderer()
    let (doc, _) = r.logoDoc("mark.png", "mark-dark.png")
    let res = renderTree(doc, target = target(dmDesigned), assets = store)
    let unchecked = withCode(res.diagnostics, codeDarkLogoUnchecked)
    check unchecked.len == 1
    check unchecked[0].severity == sevInfo
    check "too large" in unchecked[0].message
    check withCode(res.diagnostics, codeDarkLogoUnsafe).len == 0

  test "test_logo_verdicts":
    check logoVerdict(outlinedPng).verdict == lvSafe
    let bare = logoVerdict(barePng)
    check bare.verdict == lvUnsafe
    check bare.failsOn == "near-black"
    let light = logoVerdict(darkPng)
    check light.verdict == lvUnsafe
    check light.failsOn == "white"
    # A plate: the built-in icons carry their own (R-IMG-12).
    check logoVerdict(iconPng).verdict == lvSafe
    check logoVerdict("GIF89a").verdict == lvUnknown

  test "test_unsafe_light_logo_warns":
    proc render(light: string; mode = dmDesigned): RenderedEmail =
      let store = memoryAssetStore("https://cdn.example.com")
      store.put("mark.png", light)
      store.put("mark-dark.png", darkPng)
      let r = EmailRenderer()
      let (doc, _) = r.logoDoc("mark.png", "mark-dark.png")
      renderTree(doc, target = target(mode), assets = store)
    let bad = withCode(render(barePng).diagnostics, codeDarkLogoUnsafe)
    check bad.len == 1
    check "near-black" in bad[0].message
    check bad[0].families == noSwapFamilies
    check withCode(render(outlinedPng).diagnostics,
      codeDarkLogoUnsafe).len == 0
    # Under accommodate every client shows the light image: checked too.
    check withCode(render(barePng, dmAccommodate).diagnostics,
      codeDarkLogoUnsafe).len == 1
    check withCode(render(barePng, dmNone).diagnostics,
      codeDarkLogoUnsafe).len == 0

suite "the dark stories":
  test "test_dark_stories_render":
    for st in darkStories:
      checkpoint(st.name)
      var t = defaultTarget()
      if st.dark:
        t.darkMode = dmDesigned
      let res = renderTree(st.build(), target = t)
      check not hasErrors(res.diagnostics)
      check withCode(res.diagnostics, codeA11yContrast).len == 0
      check withCode(res.diagnostics, codeDarkRawColor).len == 0
    # The brand palette was picked against the inversion simulation.
    let brand = renderTree(darkBrandDoc())
    check inverted(brand.diagnostics).len == 0
    # The designed stories' dark palette is the tokens', page included.
    let designed = renderDarkStory("darkDesigned").html
    check "body{background-color:#1a1d23 !important}" in designed
    check "@dark" notin designed
    let logo = renderDarkStory("darkLogoSwap").html
    # The dark copy, its rule and the rule's Outlook copy.
    check logo.count("e-dk-show") == 3
    check "mark-dark.png" in logo
