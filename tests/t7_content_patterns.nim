## The content patterns: what each expands into, its plain-text form,
## its accessibility obligations and its own diagnostics (layout
## patterns §4: the structure patterns `mailHeader`, `mailViewInBrowser`,
## `mailBand`, `mailFooter`, `mailNavLinks`; the hero and media patterns
## `mailHero`, `mailMediaObject`, `mailZigZag`, `mailGallery`,
## `mailCountdown`), and the checks they brought: adjacent bands that
## merge in dark mode (`W-DARK-BANDS-MERGE`), a footer's 12px legal text,
## the navigation landmark, the social icons' light/dark pair, an
## image's own alt colour and a sidebar side's own minimum.
##
## `test_patterns_expand_only_to_vocabulary` covers every pattern the
## registry holds: each needs a sample here, so a pattern added later
## without one fails it.
##
## Every test renders a hand-built tree through the full pipeline
## (`renderTree`), with a memory asset store where images are cropped.
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[sequtils, strutils, tables, unittest]
import isonim_email

const
  logo = "https://cdn.example.com/a/logo.png"
  photo = "https://cdn.example.com/a/photo.png"

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

proc newDoc(r: EmailRenderer; rtl = false; preheader = ""): EmailNode =
  var attrs = @[("lang", if rtl: "ar" else: "en"),
    ("dir", if rtl: "rtl" else: "ltr"), ("title", "Patterns")]
  if preheader.len > 0:
    attrs.add(("preheader", preheader))
  result = r.el(nil, "mailDocument", attrs)

proc section(r: EmailRenderer; doc: EmailNode; heading = true): EmailNode =
  result = r.el(doc, "mailSection")
  if heading:
    discard r.el(result, "h1", text = "Patterns")

proc links(r: EmailRenderer; parent: EmailNode; labels: openArray[string]) =
  for l in labels:
    discard r.el(parent, "a", [("href", "https://example.com/" &
      l.toLowerAscii())], text = l)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc find(n: EmailNode; tag: string): EmailNode =
  ## The first element `tag` under `n`, depth first.
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

proc designed(): EmailTarget =
  result = defaultTarget()
  result.darkMode = dmDesigned

# --- Every pattern expands into the vocabulary ---------------------------------

type Sample = proc(r: EmailRenderer; s: EmailNode)
  ## Puts one instance of a pattern into section `s`.

proc samples(): OrderedTable[string, Sample] =
  ## One instance of every registered pattern (with content where it
  ## takes some), for the vocabulary check.
  result["mailBox"] = proc(r: EmailRenderer; s: EmailNode) =
    discard r.el(r.el(s, "mailBox"), "p", text = "Boxed")
  result["mailGrid"] = proc(r: EmailRenderer; s: EmailNode) =
    let g = r.el(s, "mailGrid", [("columns", "4"), ("mobile_columns", "2")])
    for i in 1 .. 4:
      discard r.el(g, "p", text = "Item " & $i)
  result["mailCluster"] = proc(r: EmailRenderer; s: EmailNode) =
    r.links(r.el(s, "mailCluster"), ["One", "Two"])
  result["mailSidebar"] = proc(r: EmailRenderer; s: EmailNode) =
    let sb = r.el(s, "mailSidebar", [("fixed", "64px")])
    discard r.el(sb, "p", text = "Side")
    discard r.el(sb, "p", text = "Main")
  result["mailSocial"] = proc(r: EmailRenderer; s: EmailNode) =
    let so = r.el(s, "mailSocial")
    discard r.el(so, "mailSocialItem", [("network", "x"),
      ("href", "https://x.example/acme")])
  result["mailSocialItem"] = result["mailSocial"]
  result["mailNavbar"] = proc(r: EmailRenderer; s: EmailNode) =
    let nb = r.el(s, "mailNavbar")
    discard r.el(nb, "mailNavLink", [("href", "https://example.com/")],
      text = "Home")
  result["mailNavLink"] = result["mailNavbar"]
  result["mailHeader"] = proc(r: EmailRenderer; s: EmailNode) =
    r.links(r.el(s, "mailHeader", [("logo", logo), ("logo_width", "120"),
      ("logo_alt", "Acme")]), ["Docs", "Help"])
  result["mailViewInBrowser"] = proc(r: EmailRenderer; s: EmailNode) =
    discard r.el(s, "mailViewInBrowser", [("href", "https://example.com/v")])
  result["mailBand"] = proc(r: EmailRenderer; s: EmailNode) =
    # A band is a top-level element: placed after the section.
    let b = r.el(s.parent, "mailBand", styles = [("background-color",
      "#fef3c7")])
    discard r.el(b, "p", text = "In the band")
  result["mailFooter"] = proc(r: EmailRenderer; s: EmailNode) =
    discard r.el(s, "mailFooter", [("address", "1 Example Street"),
      ("unsubscribe", "https://example.com/u"),
      ("preferences", "https://example.com/p"), ("legal", "Legal.")])
  result["mailNavLinks"] = proc(r: EmailRenderer; s: EmailNode) =
    r.links(r.el(s, "mailNavLinks"), ["Home", "Docs"])
  result["mailHero"] = proc(r: EmailRenderer; s: EmailNode) =
    let h = r.el(s.parent, "mailHero", styles = [("background-color",
      "#0b3a6e")])
    discard r.el(h, "p", [], [("color", "#ffffff")], text = "Hero")
  result["mailMediaObject"] = proc(r: EmailRenderer; s: EmailNode) =
    let m = r.el(s, "mailMediaObject", [("image", photo),
      ("image_width", "96"), ("image_alt", "A photo")])
    discard r.el(m, "p", text = "Its text")
  result["mailZigZag"] = proc(r: EmailRenderer; s: EmailNode) =
    let z = r.el(s, "mailZigZag")
    for i in 0 .. 1:
      let m = r.el(z, "mailMediaObject", [("image", photo),
        ("image_width", "200"), ("image_alt", "A photo")])
      discard r.el(m, "p", text = "Row " & $i)
  result["mailGallery"] = proc(r: EmailRenderer; s: EmailNode) =
    let g = r.el(s, "mailGallery", [("columns", "2")])
    for i in 0 .. 1:
      # A store name: the gallery crops its images (R-IMG-13).
      discard r.el(g, "mailImage", [("src", "photo.png"),
        ("alt", "Photo " & $i),
        ("href", "https://example.com/" & $i)])
  result["mailCountdown"] = proc(r: EmailRenderer; s: EmailNode) =
    discard r.el(s, "mailCountdown", [("src", photo), ("width", "280"),
      ("deadline_text", "Ends 30 September 2026, 23:59 UTC")])

const
  ownLowering = ["mailBox", "mailCluster", "mailSidebar", "mailHero"]
    ## The primitives (and the hero) lowered by a lowering of their own:
    ## no expansion.
  partA = ["mailHeader", "mailViewInBrowser", "mailBand", "mailFooter",
    "mailNavLinks", "mailHero", "mailMediaObject", "mailZigZag",
    "mailGallery", "mailCountdown"]
    ## The structure and media patterns (layout patterns §4.1, §4.2).

proc checkExpansion(n: EmailNode; vocab: seq[string];
    bad: var seq[string]) =
  ## Every node of an expansion: a vocabulary element, a registered
  ## pattern, or text; never raw markup.
  case n.kind
  of enElement:
    if n.tag == "mailRaw" or (n.tag notin vocab and not isPattern(n.tag)):
      bad.add(n.tag)
  of enText:
    discard
  else:
    bad.add($n.kind)
  for c in n.children:
    checkExpansion(c, vocab, bad)

suite "the patterns expand only into the vocabulary":
  test "test_patterns_expand_only_to_vocabulary":
    let names = patternNames()
    # Vacuity guard: the registry is not empty, every structure and
    # media pattern is in it, and every registered pattern has a sample.
    check names.len >= 18
    for p in partA:
      check isPattern(p)
    let table = samples()
    for name in names:
      check name in table
    var vocab: seq[string] = @[]
    for t in buildEmailVocabulary().tags:
      vocab.add(t.name)
    let store = memoryAssetStore("https://cdn.example.com")
    store.put("photo.png", encodePng(Pixels(ok: true, width: 8, height: 6,
      rgba: newSeq[uint8](8 * 6 * 4))))
    for name, build in table.pairs:
      let r = EmailRenderer()
      let doc = r.newDoc()
      build(r, r.section(doc))
      let res = renderTree(doc, assets = store)
      for d in res.diagnostics:
        if d.severity == sevError:
          checkpoint(name & ": " & d.code & " " & d.message)
      check not hasErrors(res.diagnostics)
      let node = res.semantic.find(name)
      check node != nil
      if node == nil:
        continue
      if name in ownLowering:
        # Lowered by its own lowering: never expanded.
        check not node.expanded
        continue
      check node.expanded
      var bad: seq[string] = @[]
      for c in node.children:
        checkExpansion(c, vocab, bad)
      if bad.len > 0:
        checkpoint(name & " expands into " & bad.join(", "))
      check bad.len == 0
      # Nothing of the pattern element itself reaches the HTML.
      check ("<" & name.toLowerAscii()) notin res.html.toLowerAscii()

# --- mailHeader -----------------------------------------------------------------

proc headerDoc(labels: openArray[string]; rtl = false;
    attrs: openArray[(string, string)] = []): EmailNode =
  let r = EmailRenderer()
  result = r.newDoc(rtl)
  let s = r.section(result, heading = false)
  var a = @[("logo", logo), ("logo_width", "120"), ("logo_alt", "Acme")]
  for x in attrs:
    a.add(x)
  r.links(r.el(s, "mailHeader", a), labels)
  discard r.el(r.section(result), "p", text = "Body.")

suite "mailHeader":
  test "test_header_puts_up_to_three_links_beside_the_logo":
    let res = renderTree(headerDoc(["Docs", "Pricing", "Help"]))
    check not hasErrors(res.diagnostics)
    check codeLayoutMinColumn notin codesOf(res.diagnostics)
    let header = res.semantic.find("mailHeader")
    let side = header.find("mailSidebar")
    require side != nil
    check side.attrs["fixed"] == "120px" and side.attrs["valign"] == "middle"
    let items = side.children.filterIt(it.kind == enElement)
    check items[0].tag == "mailImage" and items[0].attrs["alt"] == "Acme"
    check items[1].tag == "mailCluster" and items[1].attrs["align"] == "right"
    check items[1].children.len == 3
    # Text: the brand name, then the links one per line.
    check res.text.startsWith("Acme\n\nDocs (https://example.com/docs)\n" &
      "Pricing (https://example.com/pricing)\nHelp (https://example.com/" &
      "help)\n\n")

  test "test_header_stacks_more_links_under_the_centred_logo":
    let res = renderTree(headerDoc(["One", "Two", "Three", "Four"]))
    check not hasErrors(res.diagnostics)
    let header = res.semantic.find("mailHeader")
    check header.find("mailSidebar") == nil
    let stack = header.find("mailStack")
    check stack != nil and stack.attrs["align"] == "center"
    check header.find("mailImage").attrs["align"] == "center"
    check header.find("mailCluster").attrs["align"] == "center"

  test "test_header_alone_and_right_to_left":
    let alone = renderTree(headerDoc([]))
    check not hasErrors(alone.diagnostics)
    let h = alone.semantic.find("mailHeader")
    check h.find("mailSidebar") == nil
    check h.find("mailImage").attrs["align"] == "left"
    check alone.text.startsWith("Acme\n\n")
    let rtl = renderTree(headerDoc(["Docs"], rtl = true))
    check not hasErrors(rtl.diagnostics)
    check rtl.semantic.find("mailCluster").attrs["align"] == "left"

  test "test_header_props_and_content_are_checked":
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.section(doc)
    discard r.el(s, "mailHeader", [("logo", logo), ("logo_alt", "Acme")])
    check codeVocabBadValue in codesOf(renderTree(doc).diagnostics)
    let wrong = headerDoc([])
    discard r.el(wrong.find("mailHeader"), "p", text = "Not a link")
    check codeVocabBadValue in codesOf(renderTree(wrong).diagnostics)
    # Without logo_alt the logo has no alt text (R-IMG-04).
    let r2 = EmailRenderer()
    let noAlt = r2.newDoc()
    discard r2.el(r2.section(noAlt), "mailHeader", [("logo", logo),
      ("logo_width", "120")])
    check codeA11yAltMissing in codesOf(renderTree(noAlt).diagnostics)

  test "test_header_dark_logo_is_swapped":
    # rule: R-IMG-06
    let res = renderTree(headerDoc(["Docs"], attrs = [("logo_dark",
      "https://cdn.example.com/a/logo-dark.png")]), target = designed())
    check not hasErrors(res.diagnostics)
    check "logo-dark.png" in res.html
    check darkShowClass in res.html

# --- mailViewInBrowser -----------------------------------------------------------

suite "mailViewInBrowser":
  test "test_view_in_browser_follows_the_preheader":
    # rule: R-PRE-01
    let r = EmailRenderer()
    let doc = r.newDoc(preheader = "Five stories this week.")
    discard r.el(doc, "mailViewInBrowser", [("href",
      "https://example.com/view/41")])
    discard r.el(r.section(doc), "p", text = "Body.")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let pre = res.html.find("Five stories this week.")
    let link = res.html.find(">View in browser</a>")
    let h1 = res.html.find(">Patterns</h1>")
    check pre >= 0 and pre < link and link < h1
    # A band of its own, 12px from the top, the link at the end of the
    # line, small and grey.
    check "padding:12px 24px 0;" in res.html
    let p = res.semantic.find("mailViewInBrowser").find("p")
    check p.styles["text-align"] == "right"
    check p.styles["font-size"] == "14px"
    check res.text.startsWith("View in browser: https://example.com/view/" &
      "41\n\nPatterns\n")

  test "test_view_in_browser_in_a_band_is_a_paragraph":
    let r = EmailRenderer()
    let doc = r.newDoc()
    discard r.el(r.section(doc), "mailViewInBrowser", [("href",
      "https://example.com/v"), ("label", "Read it online")])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    check res.semantic.all("mailSection").len == 1
    check "Read it online: https://example.com/v\n" in res.text
    let r2 = EmailRenderer()
    let bad = r2.newDoc()
    discard r2.el(r2.section(bad), "mailViewInBrowser")
    check codeVocabBadValue in codesOf(renderTree(bad).diagnostics)

# --- mailBand ---------------------------------------------------------------------

suite "mailBand":
  test "test_band_is_a_full_width_section":
    # rule: R-LAY-09
    let r = EmailRenderer()
    let doc = r.newDoc()
    discard r.section(doc)
    let b = r.el(doc, "mailBand", [("padding", "40px 0")],
      [("background-color", "#0b3a6e")])
    discard r.el(b, "p", [], [("color", "#ffffff")], text = "Band")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let sec = res.semantic.find("mailBand").find("mailSection")
    check sec.attrs["full_width"] == "true"
    check "<table role=\"presentation\" width=\"100%\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\"><tr><td bgcolor=\"#0b3a6e\"" in
      res.html
    check "padding:40px 24px;" in res.html
    let r2 = EmailRenderer()
    let bad = r2.newDoc()
    discard r2.section(bad)
    discard r2.el(r2.el(bad, "mailBand"), "p", text = "No colour")
    check codeVocabBadValue in codesOf(renderTree(bad).diagnostics)

  test "test_band_carries_its_dark_colours":
    let r = EmailRenderer()
    let doc = r.newDoc()
    discard r.section(doc)
    let b = r.el(doc, "mailBand")
    r.setStyle(b, "background-color", tok"color.status.info.bg")
    r.setStyle(b, "@dark:background-color", tok"color.status.info.bg")
    discard r.el(b, "p", text = "Band")
    let res = renderTree(doc, target = designed())
    check not hasErrors(res.diagnostics)
    let sec = res.semantic.find("mailBand").find("mailSection")
    check "class" in sec.attrs # the dark pair's class (R-DRK-02)
    check "prefers-color-scheme: dark" in res.html
    # The full-width div repaints in the dark scheme too: its edges are
    # never left light.
    let cls = sec.attrs["class"]
    check ("<div class=\"" & cls & "\" style=\"background-color:") in res.html
    check "dark_class" notin res.html

suite "adjacent bands that merge in dark mode":
  proc bands(colours: openArray[(string, string)];
      t = defaultTarget()): seq[EmailDiagnostic] =
    let r = EmailRenderer()
    let doc = r.newDoc()
    discard r.section(doc)
    for (light, dark) in colours:
      let b = r.el(doc, "mailBand", styles = [("background-color", light)])
      if dark.len > 0:
        r.setStyle(b, "@dark:background-color", dark)
      discard r.el(b, "p", [], [("color", "#000000")], text = "Band")
    renderTree(doc, target = t).diagnostics.filterIt(it.code ==
      codeDarkBandsMerge)

  test "test_bands_that_merge_after_inversion_warn":
    # A light grey band (darkened to a dark grey) above a dark grey one.
    let merged = bands([("#bdbdbd", ""), ("#222222", "")])
    check merged.len == 1
    check "partial inversion" in merged[0].message
    # Controls: white above the same dark grey stays apart; two bands of
    # one colour were never two.
    check bands([("#ffffff", ""), ("#222222", "")]).len == 0
    check bands([("#ffffff", ""), ("#ffffff", "")]).len == 0
    # No dark mode at all: nothing recolours the message.
    var none = defaultTarget()
    none.darkMode = dmNone
    check bands([("#bdbdbd", ""), ("#222222", "")], none).len == 0

  test "test_bands_that_merge_in_the_designed_palette_warn":
    let merged = bands([("#ffffff", "#1f2937"), ("#c7d2fe", "#1f2937")],
      designed())
    check merged.len == 1
    check "designed dark colours" in merged[0].message
    check bands([("#ffffff", "#1f2937"), ("#c7d2fe", "#4b5563")],
      designed()).len == 0

# --- mailFooter -------------------------------------------------------------------

proc footerDoc(attrs: openArray[(string, string)];
    t = defaultTarget()): RenderedEmail =
  let r = EmailRenderer()
  let doc = r.newDoc()
  discard r.el(r.section(doc), "p", text = "Body.")
  let f = r.el(doc, "mailSection")
  r.setStyle(f, "background-color", tok"color.surface.subtle")
  r.setStyle(f, "@dark:background-color", tok"color.surface.subtle")
  let foot = r.el(f, "mailFooter", attrs)
  let so = r.el(foot, "mailSocial")
  discard r.el(so, "mailSocialItem", [("network", "x"),
    ("href", "https://x.example/acme")])
  renderTree(doc, target = t)

suite "mailFooter":
  test "test_footer_lays_out_its_parts_in_order":
    let res = footerDoc([("address", "Acme Inc.\n1 Example Street"),
      ("unsubscribe", "https://example.com/u"),
      ("preferences", "https://example.com/p"),
      ("reason", "You subscribed at example.com."),
      ("legal", "Acme is a trademark.")])
    check not hasErrors(res.diagnostics)
    check res.text.endsWith("Body.\n\nX: https://x.example/acme\n\n" &
      "You subscribed at example.com.\n\nAcme Inc.\n1 Example Street\n\n" &
      "Unsubscribe (https://example.com/u)\nPreferences " &
      "(https://example.com/p)\n\nAcme is a trademark.\n")
    check "Acme Inc.<br>1 Example Street" in res.html
    check "font-size:12px;line-height:18px;" in res.html
    check ">·</span>" in res.html

  test "test_footer_needs_an_address_and_an_unsubscribe_link":
    check codeVocabBadValue in codesOf(footerDoc([("unsubscribe",
      "https://example.com/u")]).diagnostics)
    check codeVocabBadValue in codesOf(footerDoc([("address",
      "1 Example Street")]).diagnostics)
    let receipt = footerDoc([("address", "1 Example Street"),
      ("transactional", "true")])
    check not hasErrors(receipt.diagnostics)
    check "Unsubscribe" notin receipt.text

  test "test_footer_legal_text_is_12px_without_a_warning":
    # rule: R-TXT-03
    let res = footerDoc([("address", "1 Example Street"),
      ("unsubscribe", "https://example.com/u"), ("legal", "Legal.")])
    check codeA11yFontSmall notin codesOf(res.diagnostics)
    # Control: the same 12px text outside a footer warns.
    let r = EmailRenderer()
    let doc = r.newDoc()
    discard r.el(r.section(doc), "p", styles = [("font-size", "12px")],
      text = "Legal.")
    check codeA11yFontSmall in codesOf(renderTree(doc).diagnostics)

  test "test_footer_contrast_holds_in_every_palette":
    # Light, designed dark, and both inversion models (information
    # findings included): the footer's grey passes all four.
    for t in [defaultTarget(), designed()]:
      let res = footerDoc([("address", "1 Example Street"),
        ("unsubscribe", "https://example.com/u"),
        ("preferences", "https://example.com/p"),
        ("reason", "Why."), ("legal", "Legal.")], t)
      for d in res.diagnostics:
        check d.code notin [codeA11yContrast, codeA11yContrastDark,
          codeA11yContrastInverted, codeA11yContrastInvertedInfo]

# --- mailNavLinks -----------------------------------------------------------------

proc navDoc(n: int; label = ""): RenderedEmail =
  let r = EmailRenderer()
  let doc = r.newDoc()
  let s = r.section(doc)
  let nav = r.el(s, "mailNavLinks", if label.len > 0: @[("label", label)]
    else: @[])
  var labels: seq[string] = @[]
  for i in 1 .. n:
    labels.add("Link" & $i)
  r.links(nav, labels)
  renderTree(doc)

suite "mailNavLinks":
  test "test_nav_links_are_a_navigation_landmark":
    # rule: R-A11Y-10
    let res = navDoc(3, "Main")
    check not hasErrors(res.diagnostics)
    check "<table role=\"navigation\" aria-label=\"Main\" width=\"100%\"" in
      res.html
    check "<nav" notin res.html
    check res.html.count(">Link") == 3
    check "font-weight:700;" in res.html
    check "Link1 (https://example.com/link1)\nLink2 " &
      "(https://example.com/link2)\n" in res.text
    check "aria-label=\"Navigation\"" in navDoc(2).html

  test "test_more_than_five_links_warn":
    check codePatternNavLong notin codesOf(navDoc(5).diagnostics)
    let long = navDoc(6)
    check codePatternNavLong in codesOf(long.diagnostics)
    check not hasErrors(long.diagnostics)

# --- mailHero -----------------------------------------------------------------------

suite "mailHero":
  test "test_hero_carries_review_declarations":
    check isPattern("mailHero")
    let r = EmailRenderer()
    let doc = r.newDoc()
    let h = r.el(doc, "mailHero", [("vertical_align", "middle")],
      [("background-color", "#0b3a6e"), ("min-height", "300px")])
    discard r.el(h, "h1", [], [("color", "#ffffff")], text = "Sale")
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let hero = res.semantic.find("mailHero")
    check not hero.expanded
    let def = patternOf("mailHero")
    let lines = def.expectedElements(hero, familyView("apple", "desktop"))
    check lines.len == 1
    check "at least 300px tall" in lines[0] and "vertically centred" in
      lines[0]
    r.setStyle(hero, "background-image", photo)
    check def.degradations(hero, familyView("wordApprox",
      "desktop")).len == 1
    check def.degradations(hero, familyView("apple", "desktop")).len == 0

# --- mailMediaObject ----------------------------------------------------------------

proc mediaDoc(attrs: openArray[(string, string)]; rtl = false;
    store: AssetStore = nil): RenderedEmail =
  let r = EmailRenderer()
  let doc = r.newDoc(rtl)
  let s = r.section(doc)
  var a = @[("image", photo), ("image_width", "96"), ("image_alt", "A photo")]
  for x in attrs:
    a.add(x)
  let m = r.el(s, "mailMediaObject", a)
  discard r.el(m, "p", text = "Its text.")
  renderTree(doc, assets = store)

suite "mailMediaObject":
  test "test_media_object_never_stacks_or_stacks_below":
    let never = mediaDoc([("side", "right")])
    check not hasErrors(never.diagnostics)
    let sb = never.semantic.find("mailSidebar")
    check sb.attrs["switch_below"] == "0" and sb.attrs["side"] == "right"
    check sb.children[1].tag == "mailImage"
    let below = mediaDoc([("side", "right"), ("stack", "below")])
    check not hasErrors(below.diagnostics)
    let sb2 = below.semantic.find("mailSidebar")
    check sb2.attrs["switch_below"] == "280px"
    check sb2.attrs["reverse_on_mobile"] == "true"
    # The image first in the source: a phone shows it first.
    check sb2.children[0].tag == "mailImage"
    # Beside a wide image the text switches lower, so the pair stays side
    # by side in a desktop pane a little under 600px:
    # 600 - 2 × 24 - 260 - 16 - 24 = 252.
    let wide = mediaDoc([("image_width", "260"), ("stack", "below")])
    check wide.semantic.find("mailSidebar").attrs["switch_below"] == "252px"
    check codeLayoutMinColumn notin codesOf(wide.diagnostics)
    check "dir=\"rtl\"" in below.html
    # Text: the alt, then the text; nothing of a decorative image.
    # Source order: the image on the right comes after the text.
    check "Its text.\n\n[A photo]\n" in never.text
    let deco = mediaDoc([("decorative", "true"), ("image_alt", "")])
    check not hasErrors(deco.diagnostics)
    check "[" notin deco.text
    # A right-hand image that stacks cannot be reversed right to left
    # (R-LAY-11).
    check codeLayoutReverseText in codesOf(mediaDoc([("side", "right"),
      ("stack", "below")], rtl = true).diagnostics)

  test "test_media_object_ratio_crops_its_image":
    # rule: R-IMG-13
    let s = memoryAssetStore("https://cdn.example.com")
    s.put("photo.png", encodePng(Pixels(ok: true, width: 40, height: 20,
      rgba: newSeq[uint8](40 * 20 * 4))))
    let res = mediaDoc([("image", "photo.png"), ("image_ratio", "1:1")],
      store = s)
    check not hasErrors(res.diagnostics)
    check res.assets.len == 1 and res.assets[0].name == "photo-1x1.png"
    check codeVocabBadValue in codesOf(mediaDoc([("image_ratio",
      "circle")]).diagnostics)

# --- mailZigZag ------------------------------------------------------------------

proc zigDoc(rows: int; rtl = false; extra = false): RenderedEmail =
  let r = EmailRenderer()
  let doc = r.newDoc(rtl)
  let z = r.el(r.section(doc), "mailZigZag")
  for i in 0 ..< rows:
    let m = r.el(z, "mailMediaObject", [("image", photo),
      ("image_width", "200"), ("image_alt", "Row " & $i)])
    discard r.el(m, "p", text = "Text " & $i)
  if extra:
    discard r.el(z, "p", text = "Not a row")
  renderTree(doc)

suite "mailZigZag":
  test "test_zigzag_alternates_the_desktop_side":
    let res = zigDoc(3)
    check not hasErrors(res.diagnostics)
    let rows = res.semantic.find("mailZigZag").all("mailMediaObject")
    check rows.mapIt(it.attrs["side"]) == @["left", "right", "left"]
    for row in rows:
      check row.attrs["stack"] == "below"
      # Image first in every row's source.
      check row.find("mailSidebar").children[0].tag == "mailImage"
    let sides = res.semantic.all("mailSidebar")
    check sides.mapIt(it.attrs.getOrDefault("reverse_on_mobile", "")) ==
      @["", "true", ""]
    check "[Row 0]\n\nText 0\n\n[Row 1]\n\nText 1\n" in res.text

  test "test_zigzag_is_refused_right_to_left":
    check codeLayoutReverseText in codesOf(zigDoc(2, rtl = true).diagnostics)
    check codeVocabBadValue in codesOf(zigDoc(2, extra = true).diagnostics)

# --- mailGallery -----------------------------------------------------------------

proc galleryDoc(attrs: openArray[(string, string)]; n: int;
    store: AssetStore = nil; src = photo): RenderedEmail =
  let r = EmailRenderer()
  let doc = r.newDoc()
  let g = r.el(r.section(doc), "mailGallery", attrs)
  for i in 0 ..< n:
    discard r.el(g, "mailImage", [("src", src), ("alt", "Photo " & $i),
      ("href", "https://example.com/" & $i)])
  renderTree(doc, assets = store)

suite "mailGallery":
  test "test_gallery_is_a_grid_of_cropped_images":
    # rule: R-IMG-13
    let s = memoryAssetStore("https://cdn.example.com")
    s.put("wide.png", encodePng(Pixels(ok: true, width: 60, height: 30,
      rgba: newSeq[uint8](60 * 30 * 4))))
    let res = galleryDoc([("ratio", "4:3")], 3, s, "wide.png")
    check not hasErrors(res.diagnostics)
    let grid = res.semantic.find("mailGrid")
    check grid.attrs["columns"] == "3" and grid.attrs["mobile_columns"] == "1"
    check grid.attrs["min_item"] == "120px"
    for img in grid.all("mailImage"):
      check img.attrs["crop"] == "4:3"
    check res.assets.len == 1
    check res.assets[0].name == "wide-4x3.png"
    check res.assets[0].width == 40 and res.assets[0].height == 30
    check "object-fit" notin res.html
    # Text: each image as `alt (url)`, one per line.
    check "Photo 0 (https://example.com/0)\nPhoto 1 (https://example.com/1)" &
      "\nPhoto 2 (https://example.com/2)\n" in res.text
    # Four columns keep two to a row on a phone.
    let four = galleryDoc([("columns", "4")], 4)
    check four.semantic.find("mailGrid").attrs["mobile_columns"] == "2"
    check four.semantic.find("mailGrid").expanded

  test "test_gallery_ratio_and_content_are_checked":
    check codeVocabBadValue in codesOf(galleryDoc([("ratio", "circle")],
      2).diagnostics)
    check codeVocabBadValue in codesOf(galleryDoc([], 0).diagnostics)

# --- mailCountdown ---------------------------------------------------------------

proc countdownDoc(attrs: openArray[(string, string)]): RenderedEmail =
  let r = EmailRenderer()
  let doc = r.newDoc()
  var a = @[("src", "https://cdn.example.com/a/countdown.gif"),
    ("width", "280")]
  for x in attrs:
    a.add(x)
  discard r.el(r.section(doc), "mailCountdown", a)
  renderTree(doc)

suite "mailCountdown":
  test "test_countdown_alt_and_text_are_the_deadline":
    # rule: R-OL-13
    let res = countdownDoc([("deadline_text",
      "Offer ends 30 September 2026, 23:59 UTC"),
      ("href", "https://example.com/sale")])
    check not hasErrors(res.diagnostics)
    check "alt=\"Offer ends 30 September 2026, 23:59 UTC\"" in res.html
    check "Offer ends 30 September 2026, 23:59 UTC " &
      "(https://example.com/sale)\n" in res.text
    check "[Offer" notin res.text

  test "test_countdown_without_deadline_is_missing_text":
    let res = countdownDoc([])
    check codesOf(res.diagnostics).filterIt(it[0] == 'E') ==
      @[codePatternMissingText]
    check codePatternMissingText notin codesOf(countdownDoc([(
      "deadline_text", "Ends Sunday 23:59 UTC")]).diagnostics)

# --- What the patterns brought -------------------------------------------------

suite "social icons in light and dark":
  proc socialHtml(t: EmailTarget; attrs: openArray[(string, string)] = [];
      item: openArray[(string, string)] = [("network", "x")]): string =
    let r = EmailRenderer()
    let doc = r.newDoc()
    let so = r.el(r.section(doc), "mailSocial", attrs)
    var a = @[("href", "https://x.example/acme")]
    for x in item:
      a.add(x)
    discard r.el(so, "mailSocialItem", a)
    let res = renderTree(doc, target = t)
    check not hasErrors(res.diagnostics)
    res.html

  test "test_auto_icons_are_a_light_and_dark_pair_when_designed":
    # rule: R-IMG-12
    let d = socialHtml(designed())
    check "social-x-light.png" in d and "social-x-dark.png" in d
    check darkShowClass in d
    # Accommodate writes no dark CSS: the light plate alone.
    let a = socialHtml(defaultTarget())
    check "social-x-dark.png" notin a
    # A fixed mode is one variant.
    check "social-x-dark.png" notin socialHtml(designed(), [("mode", "light")])
    # An application's own icon takes its dark variant from dark_icon.
    let own = socialHtml(designed(), item = [("network", "feed"),
      ("icon", "https://cdn.example.com/feed.png"),
      ("dark_icon", "https://cdn.example.com/feed-dark.png")])
    check "feed-dark.png" in own

suite "an image's alt colour":
  test "test_alt_contrast_reads_the_images_own_colour":
    # rule: R-IMG-03
    proc altDiags(colour: string): seq[string] =
      let r = EmailRenderer()
      let doc = r.newDoc()
      let s = r.el(doc, "mailSection", styles = [("background-color",
        "#1f2937")])
      discard r.el(s, "h1", styles = [("color", "#ffffff")], text = "Dark")
      let img = r.el(s, "mailImage", [("src", photo), ("alt", "A photo")],
        [("width", "200px")])
      if colour.len > 0:
        r.setStyle(img, "color", colour)
      codesOf(renderTree(doc).diagnostics)
    check codeA11yContrast in altDiags("")
    check codeA11yContrast notin altDiags("#e5e7eb")

suite "a sidebar side's own minimum":
  test "test_a_fluid_side_declares_its_own_minimum":
    # rule: R-TBL-11
    proc minDiags(own: string): seq[string] =
      let r = EmailRenderer()
      let doc = r.newDoc()
      let sb = r.el(r.section(doc), "mailSidebar", [("fixed", "120px")])
      discard r.el(sb, "p", text = "Logo")
      let side = r.el(sb, "p", text = "Links that wrap")
      if own.len > 0:
        r.setAttribute(side, "min_width", own)
      codesOf(renderTree(doc).diagnostics)
    check codeLayoutMinColumn in minDiags("")
    check codeLayoutMinColumn notin minDiags("120px")
    check codeLayoutMinColumn in minDiags("140px")

suite "what is never drawn is never linted":
  test "test_text_only_content_and_pattern_styles_are_not_linted":
    let r = EmailRenderer()
    let doc = r.newDoc()
    let s = r.el(doc, "mailSection", styles = [("background-color",
      "#1b2a4a")])
    discard r.el(s, "h1", styles = [("color", "#ffffff")], text = "Sale")
    # The text part's copy has no colour of its own: on the dark band it
    # would fail contrast, but it is never drawn.
    discard r.el(r.el(s, "textOnly"), "p", text = "Text-only line.")
    # A pattern's own styles are props, not CSS: `gap` is not linted as
    # the flexbox property.
    let nav = r.el(r.el(doc, "mailSection"), "mailNavLinks",
      styles = [("gap", "16px")])
    r.links(nav, ["Home"])
    let res = renderTree(doc)
    check codeA11yContrast notin codesOf(res.diagnostics)
    check codeSupportUnsupported notin codesOf(res.diagnostics)
    # Control: the same paragraph drawn fails.
    let r2 = EmailRenderer()
    let doc2 = r2.newDoc()
    let s2 = r2.el(doc2, "mailSection", styles = [("background-color",
      "#1b2a4a")])
    discard r2.el(s2, "h1", styles = [("color", "#ffffff")], text = "Sale")
    discard r2.el(s2, "p", text = "Drawn line.")
    check codeA11yContrast in codesOf(renderTree(doc2).diagnostics)
