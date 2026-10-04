## The layouts (layout-patterns.md §4.8): templates that return a whole
## `mailDocument`, built only from patterns and primitives and following
## §4.6's row for their email type; their typed props; the frame they
## share (the header with its links, the web copy, the footer with its
## social row and its unsubscribe and preferences links, a transactional
## footer without them); their colours, all theme tokens, so the
## designed dark palette needs nothing of their own; and their text part.
##
## Every test renders the layout through `renderEmail`, as a template
## is rendered. Backend-independent (tree building + pure passes), so
## `just test` also runs it on JS. No test doubles.
import std/[sets, strutils, tables, unittest]
import isonim_email

const
  logo = "https://cdn.example.com/a/logo.png"
  photo = "https://cdn.example.com/a/photo.png"

proc frame(title = "Hello"; unsubscribe = "https://e.x/unsub?u=1"):
    LayoutFrame =
  LayoutFrame(title: title, preheader: "A preheader.", brand: "Acme",
    logo: logo, logoWidth: 120, homeUrl: "https://e.x/",
    links: @[LayoutLink(label: "Help", href: "https://e.x/help")],
    address: "1 Example Street", unsubscribe: unsubscribe,
    preferences: "https://e.x/prefs",
    social: @[LayoutSocial(network: "github", href: "https://github.com/")])

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

proc all(n: EmailNode; tag: string; acc: var seq[EmailNode]) =
  if n.kind == enElement and n.tag == tag:
    acc.add(n)
  for c in n.children:
    all(c, tag, acc)

proc all(n: EmailNode; tag: string): seq[EmailNode] =
  all(n, tag, result)

proc tags(n: EmailNode; acc: var HashSet[string]) =
  if n.kind == enElement:
    acc.incl(n.tag)
  for c in n.children:
    tags(c, acc)

proc tags(n: EmailNode): HashSet[string] =
  tags(n, result)

proc rawColours(n: EmailNode; acc: var seq[string]) =
  ## Colour values written as literals (not theme tokens) on the
  ## authoring tree: the layout's own colours.
  if n.kind == enElement:
    for k, v in n.styles:
      if ("color" in k or k == "border") and v.len > 0 and
          not v.startsWith("tok:") and "#" in v:
        acc.add(n.tag & " " & k & "=" & v)
  for c in n.children:
    rawColours(c, acc)

proc errorsOf(res: RenderedEmail): seq[string] =
  for d in res.diagnostics:
    if d.severity == sevError:
      result.add(d.code & " " & d.message)

let
  receipt = ReceiptLayoutProps(frame: frame("Receipt"), heading: "Thanks",
    summary: @[LayoutRow(label: "Order", value: "2041")],
    items: @[ReceiptItem(description: "Print", qty: "1", amount: "$10.00")],
    totals: @[LayoutRow(label: "Subtotal", value: "$10.00"),
      LayoutRow(label: "Total", value: "$10.00")],
    actions: @[LayoutLink(label: "View order", href: "https://e.x/o")])
  code = SecurityCodeLayoutProps(frame: frame("Code"), heading: "Your code",
    code: "482913", expires: "14:05 UTC", magicLink: "https://e.x/m",
    warning: "Ignore this message.")
  alert = AlertLayoutProps(frame: frame("Alert"), heading: "API errors",
    status: "Error rate above 5%", summary: "Since 13:52 UTC.",
    facts: @[LayoutRow(label: "Service", value: "api")],
    code: "GET /v1/orders 502", actions: @[LayoutLink(label: "Open",
      href: "https://e.x/i")])
  digest = DigestLayoutProps(frame: frame("Digest"), heading: "This week",
    hero: DigestHero(title: "The issue", image: photo, text: "Read on."),
    items: @[DigestItem(title: "One", body: "A story.", image: photo,
      imageAlt: "A photo", crop: false, cta: "Read", href: "https://e.x/1"),
      DigestItem(title: "Two", body: "Another.", image: photo,
      imageAlt: "A photo", crop: false, cta: "Read", href: "https://e.x/2")])
  transactional = TransactionalLayoutProps(frame: frame("Note"),
    heading: "A note", intro: "Hello.", markdown: "# Part\n\nSome *text*.",
    content: proc(r: EmailRenderer; parent: EmailNode) =
      discard r.node(parent, "p", text = "From the slot."),
    actions: @[LayoutLink(label: "Open", href: "https://e.x/a")])

suite "the layouts are templates built from patterns":
  test "test_layouts_follow_their_coverage_rows":
    # Each layout renders as a template, with no error, holding exactly
    # what its row of the coverage table names, no raw markup.
    let rows = [
      ("receiptLayout", renderEmail(receiptLayout, receipt),
        @["mailHeader", "mailKeyValue", "mailLineItems", "mailButtonGroup",
          "mailFooter"]),
      ("securityCodeLayout", renderEmail(securityCodeLayout, code),
        @["mailHeader", "mailSecurityCode", "mailCallout", "mailFooter"]),
      ("alertLayout", renderEmail(alertLayout, alert),
        @["mailHeader", "mailCallout", "mailKeyValue", "mailCodeBlock",
          "mailButtonGroup", "mailFooter"]),
      ("digestLayout", renderEmail(digestLayout, digest),
        @["mailHeader", "mailHero", "mailGrid", "mailCard", "mailFooter"]),
      ("transactionalLayout", renderEmail(transactionalLayout,
        transactional), @["mailHeader", "mailMarkdown", "mailButtonGroup",
          "mailFooter"])]
    check rows.len == 5
    for (name, res, patterns) in rows:
      for e in errorsOf(res):
        checkpoint(name & ": " & e)
      check errorsOf(res).len == 0
      check res.semantic.tag == "mailDocument"
      let seen = tags(res.semantic)
      for p in patterns:
        if p notin seen:
          checkpoint(name & " lacks " & p)
        check p in seen
      check "mailRaw" notin seen
      # Every pattern of the row is expanded (the hero lowers itself).
      for p in patterns:
        let node = res.semantic.find(p)
        if node != nil and isPattern(p) and p notin ["mailHero", "mailGrid"]:
          check node.expanded
      check res.text.len > 0
    # The security code's callout is the warning one, titled.
    let cres = rows[1][1]
    let callout = cres.semantic.find("mailCallout")
    check callout.attrs["tone"] == "warning"
    check callout.attrs["title"] == "Didn't request this?"
    check "Didn't request this?" in cres.text
    # The receipt's totals end on the total row.
    let kvs = rows[0][1].semantic.all("mailKeyValue")
    check kvs.len == 2
    check kvs[1].attrs["total_row"] == "true"
    check "total_row" notin kvs[0].attrs

  test "test_layout_frame":
    let res = renderEmail(transactionalLayout, transactional)
    let doc = res.semantic
    check doc.attrs["title"] == "Note"
    check doc.attrs["lang"] == "en"
    check doc.attrs["dir"] == "ltr"
    check doc.attrs["preheader"] == "A preheader."
    check renderAuthoringTree(transactionalLayout, transactional).styles[
      "background-color"] == "tok:color.surface.canvas"
    # The header's logo and links; the footer's links and social row.
    let header = doc.find("mailHeader")
    check header.attrs["logo"] == logo
    check header.attrs["logo_alt"] == "Acme"
    check header.find("a").attrs["href"] == "https://e.x/help"
    let footer = doc.find("mailFooter")
    check footer.attrs["unsubscribe"] == "https://e.x/unsub?u=1"
    check footer.attrs["preferences"] == "https://e.x/prefs"
    check "transactional" notin footer.attrs
    check footer.find("mailSocialItem").attrs["network"] == "github"
    check "Unsubscribe (https://e.x/unsub?u=1)" in res.text
    # The content in order: heading, intro, Markdown, slot, actions.
    let stack = doc.find("mailStack")
    var order: seq[string] = @[]
    for c in stack.children:
      if c.kind == enElement:
        order.add(c.tag)
    check order[0 .. 4] == @["h1", "p", "mailMarkdown", "p",
      "mailButtonGroup"]
    # The Markdown's `#` sits under the layout's h1.
    check doc.find("mailMarkdown").find("h2") != nil
    # No web copy unless asked; then the document's first child.
    check doc.find("mailViewInBrowser") == nil
    var f = frame()
    f.viewInBrowser = "https://e.x/view"
    f.unsubscribe = ""
    let t2 = renderEmail(transactionalLayout, TransactionalLayoutProps(
      frame: f, heading: "Hi"))
    check errorsOf(t2).len == 0
    check t2.semantic.children[0].tag == "mailViewInBrowser"
    # Without an unsubscribe link, a transactional footer.
    check t2.semantic.find("mailFooter").attrs["transactional"] == "true"
    # Right to left.
    var rtl = frame()
    rtl.lang = "ar"
    rtl.dir = "rtl"
    let t3 = renderEmail(transactionalLayout, TransactionalLayoutProps(
      frame: rtl, heading: "مرحبا"))
    check errorsOf(t3).len == 0
    check "dir=\"rtl\"" in t3.html
    # A required prop left empty is the pattern's error, never filled in.
    var bad = frame()
    bad.address = ""
    check errorsOf(renderEmail(transactionalLayout, TransactionalLayoutProps(
      frame: bad, heading: "Hi"))).len > 0
    let noHeading = renderEmail(transactionalLayout, TransactionalLayoutProps(
      frame: frame(), heading: ""))
    var codes: seq[string] = @[]
    for d in noHeading.diagnostics:
      codes.add(d.code)
    check "E-A11Y-NO-H1" in codes

  test "test_alert_severity_sets_the_band":
    for (sev, tone, word) in [(asCritical, "danger", "Critical"),
        (asWarning, "warning", "Warning"), (asInfo, "info", "Info"),
        (asResolved, "success", "Resolved")]:
      var a = alert
      a.severity = sev
      let res = renderEmail(alertLayout, a)
      check errorsOf(res).len == 0
      let c = res.semantic.find("mailCallout")
      check c.attrs["tone"] == tone
      check c.attrs["label"] == word
      check (word & ": Error rate above 5%") in res.html
    var own = alert
    own.severityLabel = "Sev 1"
    check renderEmail(alertLayout, own).semantic.find(
      "mailCallout").attrs["label"] == "Sev 1"
    # Without evidence, no code block.
    var bare = alert
    bare.code = ""
    check renderEmail(alertLayout, bare).semantic.find("mailCodeBlock") == nil

  test "test_digest_arrangements":
    let grid = renderEmail(digestLayout, digest)
    check errorsOf(grid).len == 0
    # The hero's title is the h1, the heading an h2, the cards' titles h3.
    let hero = grid.semantic.find("mailHero")
    check hero.find("h1") != nil
    check grid.semantic.find("mailStack").find("h2") != nil
    check grid.semantic.find("mailGrid").attrs["columns"] == "2"
    # Without head CSS a wrapped card keeps its desktop width.
    check grid.semantic.find("mailGrid").attrs["min_item"] == "264px"
    check grid.semantic.find("mailCard").attrs["level"] == "h3"
    var z = digest
    z.arrangement = daZigZag
    z.hero = DigestHero()
    let zig = renderEmail(digestLayout, z)
    check errorsOf(zig).len == 0
    check zig.semantic.find("mailZigZag") != nil
    check zig.semantic.all("mailMediaObject").len == 2
    check zig.semantic.find("mailHero") == nil
    # Without a hero the heading is the h1 and the items h2.
    check zig.semantic.find("mailStack").find("h1") != nil
    check zig.semantic.find("mailMediaObject").find("h2") != nil

  test "test_layout_colours_are_tokens":
    # Every colour a layout writes is a theme token (the digest hero's
    # text over its image aside); the designed palette follows from them.
    for (name, tree) in [
        ("receiptLayout", renderAuthoringTree(receiptLayout, receipt)),
        ("securityCodeLayout", renderAuthoringTree(securityCodeLayout, code)),
        ("alertLayout", renderAuthoringTree(alertLayout, alert)),
        ("transactionalLayout", renderAuthoringTree(transactionalLayout,
          transactional))]:
      var raw: seq[string] = @[]
      rawColours(tree, raw)
      for r in raw:
        checkpoint(name & ": " & r)
      check raw.len == 0
    var digestRaw: seq[string] = @[]
    rawColours(renderAuthoringTree(digestLayout, digest), digestRaw)
    check digestRaw.len == 3 # the hero's fallback colour and its two texts
    var t = defaultTarget()
    t.darkMode = dmDesigned
    for res in [renderEmail(receiptLayout, receipt, target = t),
        renderEmail(alertLayout, alert, target = t)]:
      check errorsOf(res).len == 0
      for d in res.diagnostics:
        check d.code != codeDarkRawColor
      # The canvas and the card in the dark block.
      check "#0f1115" in res.html
      check "#1a1d23" in res.html

  test "test_layout_text_part":
    let res = renderEmail(securityCodeLayout, code)
    check "Your code: 482913 (expires at 14:05 UTC)" in res.text
    check "Sign in: https://e.x/m" in res.text
    check res.text.startsWith("Acme\n")
