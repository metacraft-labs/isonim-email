## The portable leaf set and a domain view written against it
## (`isonim_email/portable`, `examples/invoice_summary.nim`).
##
## - One source, two renderers: `renderInvoiceSummary` builds under
##   `EmailRenderer` and under IsoNim's `MockRenderer` (the standard
##   renderer of IsoNim's view tests, standing in for the browser one,
##   whose own run is the Chromium test in `tools/web/`), and the text a
##   reader gets is the same, run for run: the email's is read from the
##   rendered HTML as a client shows it (what Word alone reads, inside
##   `<!--[if mso]>`, and what is `display:none` left out).
## - Each leaf, on email, is the library's own leaf or pattern (`p`,
##   `h1`-`h6`, `a`, `mailImage`, `mailKeyValue`, `mailTable`, in a
##   `mailStack`), and on any other renderer semantic HTML (`section`,
##   `p`, `h1`-`h6`, `a`, `picture`/`img`, `figure`/`dl`, `table` with
##   `caption`, `thead`, `th scope="col"`).
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles: `MockRenderer` is IsoNim's own
## test renderer.
import std/[strutils, tables, unicode, unittest]
import isonim_email
import isonim/testing/mock_dom
import invoice_summary
import invoice_summary_email

const
  logo = "https://cdn.example.com/a/northwind.png"
  logoDark = "https://cdn.example.com/a/northwind-dark.png"

proc invoice(): InvoiceSummary = sampleInvoice(logo, logoDark)

proc emailData(): InvoiceEmail =
  InvoiceEmail(frame: LayoutFrame(title: "Invoice INV-2041",
    preheader: "Invoice INV-2041: $7,320.00.",
    address: "Northwind Studio, 12 Harbour Road, Portsmouth"),
    invoice: invoice())

proc viewOnly(r: EmailRenderer; inv: InvoiceSummary): EmailNode =
  ## A document holding the view alone: its text is the view's.
  result = r.node(nil, "mailDocument", [("lang", "en"), ("dir", "ltr"),
    ("title", "Invoice")])
  let card = r.contentCard(result)
  r.appendChild(card, renderInvoiceSummary[EmailRenderer, EmailNode](r, inv))

proc errorsOf(res: RenderedEmail): seq[string] =
  for d in res.diagnostics:
    if d.severity == sevError:
      result.add($d)

# --- the text a reader gets ----------------------------------------------------------

proc words(s: string): seq[string] =
  ## `s` split at white space, no-break and invisible spaces included.
  var t = s
  for ws in ["\u00A0", "\u200B", "\u200C", "\u034F", "\uFEFF", "\u2007"]:
    t = t.replace(ws, " ")
  for w in strutils.splitWhitespace(t):
    result.add(w)

proc mockRuns(n: MockNode; acc: var seq[string]) =
  if n.kind == mnkText:
    acc.add(words(n.text))
  for c in n.children:
    mockRuns(c, acc)

proc decodeEntities(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let semi = s.find(';', i)
      if semi > i and semi - i <= 10:
        let ent = s[i + 1 ..< semi]
        var decoded = ""
        if ent.startsWith("#x") or ent.startsWith("#X"):
          decoded = $Rune(parseHexInt(ent[2 .. ^1]))
        elif ent.startsWith("#"):
          decoded = $Rune(parseInt(ent[1 .. ^1]))
        else:
          case ent
          of "amp": decoded = "&"
          of "lt": decoded = "<"
          of "gt": decoded = ">"
          of "quot": decoded = "\""
          of "apos": decoded = "'"
          of "nbsp": decoded = "\u00A0"
          else: discard
        if decoded.len > 0:
          result.add(decoded)
          i = semi + 1
          continue
    result.add(s[i])
    inc i

const voidTags = ["area", "base", "br", "col", "embed", "hr", "img", "input",
  "link", "meta", "source", "track", "wbr"]

proc htmlRuns(html: string): seq[string] =
  ## The words of `html`'s body as a client that is not Word shows them:
  ## comments (Word's `<!--[if mso]>` copies among them) and elements
  ## with `display:none` contribute nothing.
  let start = html.find("<body")
  var i = if start < 0: 0 else: start
  var stack: seq[tuple[tag: string; hidden: bool]] = @[]
  var text = ""
  template flush() =
    var shown = true
    for e in stack:
      if e.hidden:
        shown = false
    if text.len > 0 and shown:
      result.add(words(decodeEntities(text)))
    text = ""
  while i < html.len:
    if html.continuesWith("<!--", i):
      flush()
      let close = html.find("-->", i + 4)
      i = if close < 0: html.len else: close + 3
    elif html[i] == '<':
      flush()
      let close = html.find('>', i)
      let tagText = html[i + 1 ..< close]
      i = close + 1
      if tagText.startsWith("/"):
        let name = tagText[1 .. ^1].strip().toLowerAscii()
        var j = stack.high
        while j >= 0 and stack[j].tag != name:
          dec j
        if j >= 0:
          stack.setLen(j)
      else:
        var name = ""
        for c in tagText:
          if c in {' ', '\t', '\n', '/', '>'}:
            break
          name.add(c.toLowerAscii())
        if name in voidTags or tagText.endsWith("/"):
          continue
        let style = tagText.toLowerAscii().replace(" ", "")
        stack.add((name, "display:none" in style))
    else:
      text.add(html[i])
      inc i
  flush()

proc childTags(n: EmailNode): seq[string] =
  for c in n.children:
    if c.kind == enElement:
      result.add(c.tag)

proc mockTags(n: MockNode): seq[string] =
  for c in n.children:
    if c.kind == mnkElement:
      result.add(c.tag)

proc textOf(n: EmailNode): string =
  if n.kind == enText:
    return n.text
  for c in n.children:
    result.add(textOf(c))

suite "a domain view on two renderers":
  test "test_domain_view_renders_on_both_targets":
    # The same generic proc, instantiated for each renderer.
    let mock = renderInvoiceSummary[MockRenderer, MockNode](MockRenderer(),
      invoice())
    let tree = renderInvoiceSummary[EmailRenderer, EmailNode](
      EmailRenderer(), invoice())
    check mock.tag == "section"
    check tree.tag == "mailStack"
    var webWords: seq[string] = @[]
    mockRuns(mock, webWords)
    # Non-vacuous: every part of the view is in the web text.
    for part in ["Invoice INV-2041", "Northwind Studio billed Acme Inc.",
        "Invoice details", "Awaiting payment", "What you are paying for",
        "Lines of invoice INV-2041", "Description Qty Amount",
        "Illustrations for the product pages 6 $1,260.00", "Totals",
        "Total due $7,320.00", "View and pay invoice INV-2041",
        "billing@example.com."]:
      check part in webWords.join(" ")
    # The email, rendered as a template is: no error, and the text a
    # reader gets is the web page's, word for word, in the same order.
    let res = renderEmail(viewOnly, invoice(),
      assets = memoryAssetStore("https://assets.example.test"))
    check errorsOf(res).len == 0
    let emailWords = htmlRuns(res.html)
    check emailWords.len > 50
    check emailWords == webWords
    if emailWords != webWords:
      echo "email: ", emailWords.join(" ")
      echo "web:   ", webWords.join(" ")
    # The whole invoice email carries the view's text unchanged between
    # its own footer and card.
    let full = renderEmail(invoiceEmail, emailData(),
      assets = memoryAssetStore("https://assets.example.test"))
    check errorsOf(full).len == 0
    check webWords.join(" ") in htmlRuns(full.html).join(" ")
    # The text part has it too: the key-value rows as `label: value`.
    check "Status: Awaiting payment" in full.text
    check "Total due: $7,320.00" in full.text
    check "INV-2041" in full.text

  test "test_email_leaves_are_the_library_leaves":
    let r = EmailRenderer()
    let v = renderInvoiceSummary[EmailRenderer, EmailNode](r, invoice())
    check childTags(v) == @["mailImage", "h1", "p", "mailKeyValue", "h2",
      "mailTable", "mailKeyValue", "p", "p"]
    check v.styles.getOrDefault("gap", "") == "tok:space.5"
    let img = v.children[0]
    check img.attrs["src"] == logo
    check img.attrs["alt"] == "Northwind Studio"
    check img.attrs["width"] == "120px"
    check img.attrs["height"] == "40px"
    check img.attrs["dark_src"] == logoDark
    check "decorative" notin img.attrs
    let kv = v.children[3]
    check kv.attrs["caption"] == "Invoice details"
    check "total_row" notin kv.attrs
    check childTags(kv) == @["mailKeyValueRow", "mailKeyValueRow",
      "mailKeyValueRow", "mailKeyValueRow"]
    check kv.children[3].attrs["label"] == "Status"
    check kv.children[3].attrs["emphasis"] == "true"
    check textOf(kv.children[3]) == "Awaiting payment"
    check v.children[6].attrs["total_row"] == "true"
    let table = v.children[5]
    check table.attrs["caption"] == "Lines of invoice INV-2041"
    check childTags(table) == @["table"]
    check childTags(table.children[0]) == @["thead", "tbody"]
    let head = table.children[0].children[0].children[0]
    check childTags(head) == @["th", "th", "th"]
    check "text-align" notin head.children[0].styles
    check head.children[2].styles["text-align"] == "right"
    # No inset at the table's outer edges: its text lines up with the
    # key-value lists around it.
    check head.children[0].styles["padding-left"] == "0"
    check "padding-right" notin head.children[0].styles
    check "padding-left" notin head.children[1].styles
    check "padding-right" notin head.children[1].styles
    check head.children[2].styles["padding-right"] == "0"
    let firstRow = table.children[0].children[1].children[0]
    check firstRow.children[2].styles["text-align"] == "right"
    check firstRow.children[2].styles["white-space"] == "nowrap"
    let link = v.children[7]
    check childTags(link) == @["a"]
    check link.children[0].attrs["href"] ==
      "https://example.com/invoices/INV-2041/pay"
    # Right to left, the numbers sit on the left; a decorative image
    # says so.
    let p = r.createElement("mailStack")
    let rtl = leafTable(r, p, LeafTable(caption: "c",
      columns: @[LeafColumn(header: "a"), LeafColumn(header: "b",
        numeric: true)], rows: @[@["x", "1"]], rtl: true))
    let rtlRow = rtl.children[0].children[1].children[0]
    check rtlRow.children[1].styles["text-align"] == "left"
    check rtlRow.children[0].styles["padding-right"] == "0"
    check rtlRow.children[1].styles["padding-left"] == "0"
    let deco = leafImage(r, p, LeafImage(src: logo, width: 24))
    check deco.attrs["decorative"] == "true"
    check "alt" notin deco.attrs
    check "height" notin deco.attrs
    check leafHeading(r, p, "Small", 4).tag == "h4"

  test "test_web_leaves_are_semantic_html":
    let r = MockRenderer()
    let v = renderInvoiceSummary[MockRenderer, MockNode](r, invoice())
    check v.attributes["aria-label"] == "Invoice INV-2041"
    check mockTags(v) == @["picture", "h1", "p", "figure", "h2", "table",
      "figure", "p", "p"]
    let picture = v.children[0]
    check mockTags(picture) == @["source", "img"]
    check picture.children[0].attributes["media"] ==
      "(prefers-color-scheme: dark)"
    check picture.children[0].attributes["srcset"] == logoDark
    let img = picture.children[1]
    check img.attributes["src"] == logo
    check img.attributes["alt"] == "Northwind Studio"
    check img.attributes["width"] == "120"
    check img.attributes["height"] == "40"
    let fig = v.children[3]
    check mockTags(fig) == @["figcaption", "dl"]
    check fig.children[0].styles["position"] == "absolute"
    check fig.children[0].styles["clip"] == "rect(0 0 0 0)"
    let dl = fig.children[1]
    check mockTags(dl) == @["div", "div", "div", "div"]
    check mockTags(dl.children[0]) == @["dt", "dd"]
    check textContent(dl.children[3]) == "StatusAwaiting payment"
    check dl.children[3].styles["font-weight"] == "700"
    check "font-weight" notin dl.children[0].styles
    let totals = v.children[6].children[1]
    check totals.children[2].styles["border-top"] == "1px solid"
    check "border-top" notin totals.children[1].styles
    let table = v.children[5]
    check mockTags(table) == @["caption", "thead", "tbody"]
    check table.children[0].styles["position"] == "absolute"
    let head = table.children[1].children[0]
    check mockTags(head) == @["th", "th", "th"]
    check head.children[0].attributes["scope"] == "col"
    check head.children[0].styles["text-align"] == "start"
    check head.children[2].styles["text-align"] == "end"
    let row = table.children[2].children[0]
    check mockTags(row) == @["td", "td", "td"]
    check row.children[2].styles["text-align"] == "end"
    check row.children[2].styles["white-space"] == "nowrap"
    let link = v.children[7]
    check mockTags(link) == @["a"]
    check link.children[0].attributes["href"] ==
      "https://example.com/invoices/INV-2041/pay"
    # Without a dark copy the image stands alone; decorative is alt="".
    let p = r.createElement("section")
    let deco = leafImage(r, p, LeafImage(src: logo, width: 24))
    check deco.tag == "img"
    check deco.attributes["alt"] == ""
    check mockTags(p) == @["img"]
