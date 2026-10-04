## `mailSocial` and `mailNavbar` (`navigation.nim`), both built on
## `mailCluster`.
##
## - A social row is a cluster of linked images, `icon_size` px square,
##   each with its network's name as alt text, the built-in monogram
##   plates (light or dark) unless the item brings its own icon; the
##   built-in icons are 64×64 PNGs published like any compile-time asset.
## - A navbar is a cluster of links in the link colour, bold, not
##   underlined, with a 44px hit area, 24px apart, wrapped lines 8px
##   apart, the separator hidden from screen readers.
## - Destinations, sizes, networks and children are checked.
## - Every navigation story renders without an error.
##
## Backend-independent (tree building + pure passes + the in-memory
## asset store), so `just test` also runs it on JS. No test doubles.
import std/[sequtils, strutils, unittest]
import isonim_email
import stories/seed_navigation

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
    ("dir", "ltr"), ("title", "Navigation")])
  discard r.child(doc, "h1", text = "Navigation")
  (doc, r.child(doc, "mailSection"))

proc social(r: EmailRenderer; parent: EmailNode; networks: openArray[string];
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []): EmailNode =
  result = r.child(parent, "mailSocial", styles, attrs)
  for n in networks:
    discard r.child(result, "mailSocialItem", attrs = [("network", n),
      ("href", "https://" & n & ".example/")])

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc body(html: string): string =
  html[html.find("<body") .. ^1]

suite "mailSocial":
  test "test_social_row_is_a_cluster_of_linked_icons":
    # rule: R-IMG-12
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.social(s, ["x", "github"])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "<mailsocial" notin html.toLowerAscii()
    # The cluster: centred by default, the items 12px apart.
    check "<div style=\"font-size:0.01px;text-align:center;direction:ltr;\">" in
      html
    check "padding:0 12px 12px 0;" in html
    # Each item: a linked image, 24px, its network's name as alt, the
    # built-in light plate.
    check "<a href=\"https://x.example/\" target=\"_blank\"" in html
    check "src=\"" & socialIcon("x", "light") & "\" alt=\"X\" width=\"24\" " &
      "height=\"24\"" in html
    check "src=\"" & socialIcon("github", "light") & "\" alt=\"GitHub\"" in html
    check "width:24px;" in html
    # Word: one ghost row.
    check html.count("<!--[if mso]><table role=\"presentation\" " &
      "align=\"center\" border=\"0\" cellpadding=\"0\" " &
      "cellspacing=\"0\"><tr><td style=\"padding:0 12px 0 0;\">") == 1

  test "test_social_props":
    # rule: R-IMG-12
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.social(s, ["linkedin"], [("mode", "dark"), ("icon_size", "32"),
      ("align", "left")], [("gap", "16px")])
    let own = r.child(s, "mailSocial")
    discard r.child(own, "mailSocialItem", attrs = [("network", "Acme feed"),
      ("href", "https://example.com/feed"),
      ("icon", "https://cdn.example/feed.png")])
    discard r.child(own, "mailSocialItem", attrs = [("network", "youtube"),
      ("href", "https://youtube.example/"),
      ("icon", "https://cdn.example/yt.png")])
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "src=\"" & socialIcon("linkedin", "dark") & "\" alt=\"LinkedIn\" " &
      "width=\"32\" height=\"32\"" in html
    check "text-align:left;direction:ltr;" in html
    # An own icon replaces the built-in one; an unknown network is its
    # own alt text, a known one keeps its name.
    check "src=\"https://cdn.example/feed.png\" alt=\"Acme feed\"" in html
    check "src=\"https://cdn.example/yt.png\" alt=\"YouTube\"" in html
    check socialIcon("youtube", "light") notin html

  test "test_social_errors":
    # rule: R-IMG-12
    for (attrs, item, want) in [
        (@[("icon_size", "60")], @[("network", "x"), ("href",
          "https://x.example/")], codeVocabBadValue),
        (@[("mode", "sepia")], @[("network", "x"), ("href",
          "https://x.example/")], codeVocabBadValue),
        (@[], @[("network", "myspace"), ("href", "https://m.example/")],
          codeVocabBadValue),
        (@[], @[("network", "x")], codeUrlEmpty),
        (@[], @[("network", "x"), ("href", "javascript:alert(1)")],
          codeUrlScheme)]:
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      let row = r.child(s, "mailSocial", attrs = attrs)
      discard r.child(row, "mailSocialItem", attrs = item)
      checkpoint($attrs & " " & $item)
      # Exactly once: the item's own check, not again on the linked
      # image it expands into.
      check codesOf(renderTree(doc).diagnostics).count(want) == 1
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let row = r.child(s, "mailSocial")
    discard r.child(row, "p", text = "not an item")
    check codeVocabBadValue in codesOf(renderTree(doc).diagnostics)

  test "test_social_icons_are_published_pngs":
    # rule: R-IMG-12
    for (network, _) in socialNetworks:
      for variant in ["light", "dark"]:
        let path = socialIcon(network, variant)
        check path.endsWith("/social-" & network & "-" & variant & ".png")
        let found = compiledAssetAt(path)
        check found.found
        check found.asset.mime == "image/png"
        check found.asset.width == 64
        check found.asset.height == 64
        check found.asset.hasAlpha
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    discard r.social(s, ["email"])
    let res = renderTree(doc, assets = memoryAssetStore("https://cdn.example"))
    check not hasErrors(res.diagnostics)
    let url = "https://cdn.example" & socialIcon("email", "light")
    check "src=\"" & url & "\"" in res.html
    check res.assets.len == 1
    check res.assets[0].url == url

suite "mailNavbar":
  test "test_navbar_is_a_cluster_of_links":
    # rule: R-TXT-12
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let nav = r.child(s, "mailNavbar", attrs = [("separator", "·")])
    for (label, href) in [("Home", "https://example.com/"),
        ("Docs", "https://example.com/docs")]:
      discard r.child(nav, "mailNavLink", attrs = [("href", href)],
        text = label)
    let res = renderTree(doc)
    check not hasErrors(res.diagnostics)
    let html = body(res.html)
    check "<mailnavbar" notin html.toLowerAscii()
    check "<div style=\"font-size:0.01px;text-align:center;direction:ltr;\">" in
      html
    # 24px between links, 8px between wrapped lines.
    check "padding:0 24px 8px 0;" in html
    check "padding:0 0 8px;" in html
    check "<a href=\"https://example.com/\" style=\"color:#0969da;" &
      "text-decoration:none;font-weight:700;font-family:Helvetica, " &
      "Arial, sans-serif;font-size:16px;line-height:24px;" &
      "display:inline-block;padding:10px 0;mso-line-height-rule:" &
      "exactly;\">Home</a>" in html
    # Only a label with a long word may break (Word's one-line row
    # would squeeze every short label into pieces).
    check "word-break" notin html
    # The separator in its own colour (never a client's default).
    check "<span aria-hidden=\"true\" style=\"color:#4b5563;" &
      "padding-left:24px;\">·</span>" in html
    # The dark pair under darkMode = designed (a fresh tree: the render
    # above resolved this one's styles).
    let r2 = EmailRenderer()
    let (doc2, s2) = newDoc(r2)
    let nav2 = r2.child(s2, "mailNavbar")
    discard r2.child(nav2, "mailNavLink", attrs = [("href",
      "https://example.com/")], text = "Home")
    var t = defaultTarget()
    t.darkMode = dmDesigned
    let dark = renderTree(doc2, target = t).html
    check "color:#7aa7ff !important" in dark[0 ..< dark.find("<body")]

  test "test_navbar_props_and_errors":
    # rule: R-TXT-12
    let r = EmailRenderer()
    let (doc, s) = newDoc(r)
    let nav = r.child(s, "mailNavbar", [("gap", "12px")], [("align", "right")])
    discard r.child(nav, "mailNavLink", attrs = [("href",
      "https://example.com/")], text = "One")
    discard r.child(nav, "mailNavLink", attrs = [("href",
      "https://example.com/2")], text = "Two")
    let html = body(renderTree(doc).html)
    check "text-align:right;direction:ltr;" in html
    check "padding:0 12px 8px 0;" in html
    for (link, want) in [(@[("href", "#")], codeUrlEmpty),
        (@[("href", "ftp://example.com/")], codeUrlScheme)]:
      let r2 = EmailRenderer()
      let (doc2, s2) = newDoc(r2)
      let n2 = r2.child(s2, "mailNavbar")
      discard r2.child(n2, "mailNavLink", attrs = link, text = "Home")
      # Exactly once: the link's own check, not again on the `a` it
      # expands into.
      check codesOf(renderTree(doc2).diagnostics).count(want) == 1
    let r3 = EmailRenderer()
    let (doc3, s3) = newDoc(r3)
    let n3 = r3.child(s3, "mailNavbar")
    r3.appendChild(n3, r3.createTextNode("loose text"))
    check codeVocabBadValue in codesOf(renderTree(doc3).diagnostics)

suite "Word rows":
  test "test_word_breaks_a_long_row_into_ghost_rows":
    # rule: R-TXT-12
    # Eight links do not fit 552px on one line: Word, which never wraps
    # a row, gets a ghost row per line; the div row (everyone else) is
    # unchanged. Three links fit: one ghost row.
    proc navDoc(links: openArray[string]): EmailNode =
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      let nav = r.child(s, "mailNavbar", attrs = [("separator", "·")])
      for l in links:
        discard r.child(nav, "mailNavLink", attrs = [("href",
          "https://example.com/")], text = l)
      doc
    let long = body(renderTree(navDoc(["Home", "Product",
      "Documentation and guides", "Pricing", "Blog", "Careers", "Status",
      "Contact"])).html)
    let open = "<!--[if mso]><table role=\"presentation\" align=\"center\" " &
      "border=\"0\" cellpadding=\"0\" cellspacing=\"0\"><tr><td"
    check long.count(open) >= 2
    # The divs keep their gaps: seven trailing gaps, one per link but the
    # last.
    check long.count("padding:0 24px 8px 0;") == 7
    # A later Word row keeps the row gap above it.
    check "<td style=\"padding:8px 24px 0 0;\">" in long
    let short = body(renderTree(navDoc(["Home", "Docs", "Pricing"])).html)
    check short.count(open) == 1

suite "navigation stories":
  test "test_navigation_stories_render":
    for st in navigationStories:
      let (html, _) = renderNavigationStory(st.name)
      checkpoint(st.name)
      check "<mailsocial" notin html.toLowerAscii()
      check "<mailnav" notin html.toLowerAscii()
      if st.name.startsWith("social"):
        # Published to the capture fixture host.
        check "src=\"https://x.test/" in html

  test "test_button_style_bad_href_is_reported_once":
    # rule: R-BTN-07
    # rule: R-TXT-13
    # A navigation link and a social item each expand into a link that
    # carries their href; the bad destination is one finding, R-BTN-07's
    # on the element, not a second R-TXT-13 one on its expansion.
    proc errorsOf(diags: openArray[EmailDiagnostic]): seq[EmailDiagnostic] =
      for d in diags:
        if d.severity == sevError:
          result.add(d)
    # Padded and blank hrefs too: the expansion writes the href stripped.
    for (href, want) in [("/relative", codeUrlScheme), ("#", codeUrlEmpty),
        (" /rel ", codeUrlScheme), (" # ", codeUrlEmpty), ("   ", codeUrlEmpty)]:
      let r = EmailRenderer()
      let (doc, s) = newDoc(r)
      let nav = r.child(s, "mailNavbar")
      discard r.child(nav, "mailNavLink", attrs = [("href", href)],
        text = "Home")
      let row = r.child(s, "mailSocial")
      discard r.child(row, "mailSocialItem", attrs = [("network", "x"),
        ("href", href)])
      let errors = errorsOf(renderTree(doc).diagnostics)
      checkpoint(href)
      check errors.len == 2
      check codesOf(errors) == @[want, want]
      var tags: seq[string] = @[]
      for e in errors:
        check e.rules == @["R-BTN-07"]
        tags.add(e.message.split(' ')[0])
      check "mailNavLink" in tags
      check "mailSocialItem" in tags
