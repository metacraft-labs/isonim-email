## The static vocabulary accepts valid templates and diagnoses the
## rest. Template tests prove the static-vocabulary hook fires only where it should;
## `checkElement` unit tests pin the diagnostic texts (codes, suggestions,
## alternatives, nesting) without compiling failures.
##
## Backend-independent (tree building + pure checks), so `just test` also
## runs it on JS.
import std/[sequtils, strutils, tables, unittest]
import isonim_email
import isonim/dsl/vocabulary

proc docTpl(r: EmailRenderer; name: string): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Welcome", preheader = "Hi there"):
      mailSection(background_color = "#ffffff", padding = "24px"):
        mailColumn(width = "50%"):
          h1: text "Welcome, " & name
          p: text "Your account is ready."
          mailButton(href = "https://app.example.com/"):
            text "Open dashboard"

proc boundaryTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Boundaries"):
      mailWrapper(background_color = "#f4f5f7"):
        mailIf(mso = "true"):
          mailSection:
            mailColumns(strategy = "hybrid", gutter = "16px"):
              mailColumn(width = "50%"):
                tdiv:
                  p(color = "#111827"): text "grouped"
                ul:
                  li: text "one"
      mailTable(caption = "Totals", mobile = "stack"):
        table:
          thead:
            tr:
              th(scope = "col"): text "Item"
              th(scope = "col"): text "Price"
          tbody:
            tr:
              td: text "Widget"
              td(colspan = "2"): text "9.00"
      mailSocial(align = "center", icon_size = "24", mode = "auto"):
        mailSocialItem(network = "x", href = "https://x.example/")
      mailNavbar(align = "center", separator = "·"):
        mailNavLink(href = "https://example.com/"): text "Home"
      textOnly:
        p: text "text readers see this"
      htmlOnly:
        p: text "html readers see this"
      mailRaw:
        raw "<!-- audited -->"

suite "static vocabulary":
  test "valid document template builds the expected tree":
    let tree = renderAuthoringTree(docTpl, "Ada")
    check tree.tag == "mailDocument"
    check tree.attrs["lang"] == "en"
    check tree.attrs["title"] == "Welcome"
    let section = tree.children[0]
    check section.tag == "mailSection"
    check section.styles["background-color"] == "#ffffff"
    let col = section.children[0]
    check col.tag == "mailColumn"
    check col.styles["width"] == "50%"
    check col.children[0].tag == "h1"
    check col.children[0].children[0].text == "Welcome, Ada"
    check col.children[1].tag == "p"
    let btn = col.children[2]
    check btn.tag == "mailButton"
    check btn.attrs["href"] == "https://app.example.com/"

  test "nesting boundaries and transparent wrappers pass":
    let tree = renderAuthoringTree(boundaryTpl, 0)
    check tree.tag == "mailDocument"
    # mailWrapper > mailIf > mailSection > mailColumns > mailColumn.
    let wrapper = tree.children[0]
    check wrapper.tag == "mailWrapper"
    let section = wrapper.children[0].children[0]
    check section.tag == "mailSection"
    let cols = section.children[0]
    check cols.tag == "mailColumns"
    check cols.attrs["strategy"] == "hybrid"
    let col = cols.children[0]
    check col.tag == "mailColumn"
    check col.children[0].tag == "div"
    check col.children[1].tag == "ul"
    # mailTable subtree, social, navbar, text/html-only, raw.
    let tags = tree.children.mapIt(it.tag)
    check tags == @["mailWrapper", "mailTable", "mailSocial", "mailNavbar",
      "textOnly", "htmlOnly", "mailRaw"]
    let tds = tree.children[1].children[0].children[1].children[0].children
    check tds[1].tag == "td"
    check tds[1].attrs["colspan"] == "2"
    check tree.children[2].children[0].tag == "mailSocialItem"
    check tree.children[3].children[0].tag == "mailNavLink"
    check tree.children[6].children[0].kind == enRaw

  test "unknown tag suggests the nearest vocabulary entry":
    let v = buildEmailVocabulary()
    let msg = checkElement(v, "mailSectoin", [], ["width"], "")
    check msg.startsWith("E-VOCAB-UNKNOWN-TAG")
    check "Did you mean 'mailSection'?" in msg

  test "unknown attribute suggests the nearest schema entry":
    let v = buildEmailVocabulary()
    let msg = checkElement(v, "mailSection", ["backgorund_color"], [], "")
    check msg.startsWith("E-VOCAB-UNKNOWN-ATTR")
    check "Did you mean 'background_color'?" in msg

  test "forbidden elements name the alternative or say so":
    let v = buildEmailVocabulary()
    let withAlt = checkElement(v, "img", [], ["src"], "mailColumn")
    check withAlt.startsWith("E-VOCAB-FORBIDDEN-TAG")
    check "Use 'mailImage' instead." in withAlt
    let withoutAlt = checkElement(v, "object", [], [], "mailColumn")
    check withoutAlt.startsWith("E-VOCAB-FORBIDDEN-TAG")
    check "It is not expressible here." in withoutAlt

  test "nesting violations name the allowed parents":
    let v = buildEmailVocabulary()
    let top = checkElement(v, "mailColumn", ["width"], [], "")
    check top.startsWith("E-STRUCT-NESTING")
    check "must not appear at the top level" in top
    check "'mailSection'" in top
    let nested = checkElement(v, "li", [], [], "mailColumn")
    check nested.startsWith("E-STRUCT-NESTING")
    check "must not be a child of 'mailColumn'" in nested
    check "'ul'" in nested

  test "mailDocument is top-level-only":
    let v = buildEmailVocabulary()
    check checkElement(v, "mailDocument", [], ["lang", "title"], "") == ""
    let nested = checkElement(v, "mailDocument", [], ["lang"], "mailSection")
    check nested.startsWith("E-STRUCT-NESTING")

  test "leaves accept any style but only listed attributes":
    let v = buildEmailVocabulary()
    check checkElement(v, "p", ["color", "letter-spacing"], [], "mailColumn") == ""
    check checkElement(v, "p", [], ["lang"], "mailColumn") == ""
    check checkElement(v, "p", [], ["class"], "mailColumn") == ""
    let bad = checkElement(v, "p", [], ["href"], "mailColumn")
    check bad.startsWith("E-VOCAB-UNKNOWN-ATTR")
    check checkElement(v, "mailSection", ["padding"], ["class"],
      "mailDocument") == ""
