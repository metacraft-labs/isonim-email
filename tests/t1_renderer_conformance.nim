## The email renderer implements the RendererBackend contract and the
## `ui(r)` macro builds the expected tree.
##
## Backend-independent (tree building only), so `just test` also runs it on JS.
import std/[sequtils, tables, unittest]
import isonim_email

# The conformance proof, evaluated at compile time: if any required
# RendererBackend proc were missing or mistyped, this file would not build.
static:
  checkRendererBackend[EmailRenderer, EmailNode]()

# The template is vocabulary-valid — a bare top-level `div` with `id`
# fails the vocabulary nesting/attribute checks — while still exercising ordered
# attrs/styles, control flow and the style/attr routing.
proc cardTpl(r: EmailRenderer; title: string; n: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Card"):
      mailSection:
        mailColumn(vertical_align = "top", inner_padding = "4px",
                   background_color = "#fff", padding = "8px"):
          h1: text title
          p: text "static para"
          raw "<!--stamp-->"
          if n > 0:
            span: text "pos"
          ul:
            for i in 0 ..< n:
              li: text "item"

suite "renderer conformance":
  test "ui(r) builds the expected tree with ordered attrs and styles":
    let r = EmailRenderer()
    let root = cardTpl(r, "Hi", 2)
    check root.kind == enElement
    check root.tag == "mailDocument"
    check root.children[0].tag == "mailSection"
    let col = root.children[0].children[0]
    check col.tag == "mailColumn"
    # Style keywords (styleProperties) become styles with `-`; every other
    # keyword becomes an attribute with underscores kept.
    check toSeq(col.attrs.keys) == @["vertical_align", "inner_padding"]
    check col.attrs["vertical_align"] == "top"
    check col.attrs["inner_padding"] == "4px"
    check toSeq(col.styles.keys) == @["background-color", "padding"]
    check col.styles["background-color"] == "#fff"
    check col.styles["padding"] == "8px"
    # h1, p, raw, span (n > 0), ul with li × 2.
    check col.children.len == 5
    check col.children[0].tag == "h1"
    check col.children[0].children[0].text == "Hi"
    check col.children[1].tag == "p"
    check col.children[1].children[0].text == "static para"
    check col.children[2].kind == enRaw
    check col.children[2].text == "<!--stamp-->"
    check col.children[3].tag == "span"
    check col.children[4].tag == "ul"
    check col.children[4].children.len == 2
    check col.children[4].children[0].tag == "li"
    check col.children[4].children[1].tag == "li"
    for c in col.children:
      check c.parent == col

  test "raw appends one verbatim node at the enclosing element's origin":
    # `raw expr` in a ui(r) block goes through appendRawHtml: one enRaw
    # node, payload unparsed, carrying the parent's source span.
    let r = EmailRenderer()
    let root = cardTpl(r, "Hi", 0)
    let col = root.children[0].children[0]
    let rawNode = col.children[2]
    check rawNode.kind == enRaw
    check rawNode.children.len == 0
    check rawNode.parent == col
    check col.origin.line > 0
    check rawNode.origin == col.origin
    # Building accepts it; the placement rule is the validation pass's:
    # this raw sits in a mailColumn, not in mailRaw.
    let diags = validate(root)
    check diags.mapIt(it.code) == @[codeStructRawOutside]
    check diags[0].origin == col.origin
    # The backend proc directly: a payload of several sibling tags is
    # still exactly one node.
    let host = r.createElement("mailRaw")
    r.appendRawHtml(host, "<b>a</b><i>b</i>")
    check host.children.len == 1
    check host.children[0].kind == enRaw
    check host.children[0].text == "<b>a</b><i>b</i>"

  test "tree navigation and mutation follow browser semantics":
    let r = EmailRenderer()
    let parent = r.createElement("div")
    let a = r.createElement("p")
    let b = r.createTextNode("x")
    r.appendChild(parent, a)
    r.appendChild(parent, b)
    check r.firstChild(parent) == a
    check r.nextSibling(a) == b
    check r.nextSibling(b) == nil
    check r.parentNode(a) == parent
    check r.firstChild(a) == nil
    # insertBefore at the reference's slot; unknown reference appends.
    let z = r.createElement("span")
    r.insertBefore(parent, z, b)
    check parent.children == @[a, z, b]
    let tail = r.createElement("em")
    r.insertBefore(parent, tail, r.createElement("nowhere"))
    check parent.children[^1] == tail
    # Appending an attached node moves it (mock_dom parity).
    r.appendChild(parent, a)
    check parent.children == @[z, b, tail, a]
    check a.parent == parent
    # removeChild detaches.
    r.removeChild(parent, b)
    check parent.children == @[z, tail, a]
    check b.parent == nil
    # Attributes and text content.
    r.setAttribute(a, "k", "v")
    check a.attrs["k"] == "v"
    r.removeAttribute(a, "k")
    check "k" notin a.attrs
    r.setTextContent(a, "hello")
    check a.children.len == 1
    check a.children[0].kind == enText
    check a.children[0].text == "hello"
    r.setTextContent(b, "rewritten")
    check b.text == "rewritten"

  test "re-setting a style keeps its original position":
    let r = EmailRenderer()
    let n = r.createElement("div")
    r.setStyle(n, "color", "red")
    r.setStyle(n, "margin", "0")
    r.setStyle(n, "color", "blue")
    check toSeq(n.styles.keys) == @["color", "margin"]
    check n.styles["color"] == "blue"
