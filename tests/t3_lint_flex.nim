# rule: R-OL-10
## `display:flex` on a layout container is an error under every
## built-in profile; anywhere else it is removed with a warning.
##
## `display` is not a vocabulary attribute of the `mail*` layout elements
## (layout comes from structure, so the vocabulary check rejects it there by design), which
## is why the section/column cases below hand-build their trees while the
## `div` case goes through the real `ui(r)` macro (`div` allows any style).
##
## Backend-independent (tree building + pure lint), so `just test` also
## runs it on JS.
import std/[strutils, unittest]
import isonim_email

proc flexDivTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Flex"):
      mailSection:
        mailColumn:
          tdiv(display = "flex"):
            p: text "laid out by flex"

proc gridDivTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Grid"):
      mailSection:
        mailColumn:
          tdiv(display = "grid"):
            p: text "laid out by grid"

proc blockDivTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Block"):
      mailSection:
        mailColumn:
          tdiv(display = "block"):
            p: text "ordinary block"

proc flexParaTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Flex para"):
      mailSection:
        mailColumn:
          p(display = "flex"): text "flex paragraph"

proc handBuilt(tag, prop, value: string): EmailNode =
  let r = EmailRenderer()
  let node = r.createElement(tag)
  node.origin = SourceSpan(file: "flex.nim", line: 7, col: 3)
  r.setStyle(node, prop, value)
  node

suite "lint flags flex layout as harmful":
  test "test_lint_flags_flex_layout_as_harmful":
    # Through the macro: a flex div errors under every built-in profile.
    let tree = renderAuthoringTree(flexDivTpl, 0)
    for profile in [consumer, business, developer]:
      let diags = lintTree(tree, profile)
      check diags.len == 1
      check diags[0].severity == sevError
      check diags[0].code == "E-CSS-HARMFUL"
      check diags[0].code == codeCssHarmful
      check diags[0].families == {cfOutlookWord}
      check diags[0].rules == @["R-OL-10"]
      check "display:flex" in diags[0].message
      check "<div>" in diags[0].message
      check hasErrors(diags)
    # Grid collapses the same way.
    let grid = renderAuthoringTree(gridDivTpl, 0)
    for profile in [consumer, business, developer]:
      let diags = lintTree(grid, profile)
      check diags.len == 1
      check diags[0].severity == sevError
      check diags[0].code == "E-CSS-HARMFUL"
      check "display:grid" in diags[0].message

  test "hand-built section and column containers error too":
    for tag in ["mailSection", "mailColumn", "mailGroup", "mailDocument",
        "mailStack", "table", "td"]:
      for profile in [consumer, business, developer]:
        let diags = lintTree(handBuilt(tag, "display", "flex"), profile)
        check diags.len == 1
        check diags[0].severity == sevError
        check diags[0].code == "E-CSS-HARMFUL"
        check tag in diags[0].message
        check diags[0].origin.file == "flex.nim"

  test "flex anywhere else is removed with a warning":
    let tree = renderAuthoringTree(flexParaTpl, 0)
    for profile in [consumer, business, developer]:
      let diags = lintTree(tree, profile)
      check diags.len == 1
      check diags[0].severity == sevWarning
      check diags[0].code == "W-SUPPORT-UNSUPPORTED"
      check diags[0].rules == @["R-OL-10"]
      check "removed" in diags[0].message
      check not hasErrors(diags)
    # Content elements warn the same way.
    for tag in ["mailButton", "mailImage", "mailText", "p", "span"]:
      let diags = lintTree(handBuilt(tag, "display", "inline-grid"),
        business)
      check diags.len == 1
      check diags[0].severity == sevWarning
      check "display:inline-grid" in diags[0].message

  test "ordinary display values stay silent":
    check lintTree(renderAuthoringTree(blockDivTpl, 0), business).len == 0
    check lintTree(handBuilt("mailSection", "display", "block"),
      business).len == 0
    check lintTree(handBuilt("p", "display", "inline"), consumer).len == 0
    check lintTree(handBuilt("div", "display", "none"), consumer).len == 0

  test "harmful matching is case- and priority-tolerant":
    check isHarmfulDeclaration("display", "flex")
    check isHarmfulDeclaration("DISPLAY", "Flex")
    check isHarmfulDeclaration("display", "grid !IMPORTANT")
    check isHarmfulDeclaration("display", "inline-flex")
    check not isHarmfulDeclaration("display", "block")
    check not isHarmfulDeclaration("display", "flexbox")
    check not isHarmfulDeclaration("position", "flex")
    check harmfulDisplayValue("grid !important") == "grid"
    check harmfulDisplayValue("block") == ""
    # Variant (head-bound) flex skips the harmful path: Word ignores head
    # rules entirely, so nothing collapses. It still data-checks.
    let diags = lintStyles("mailSection",
      [("@dark:display", "flex")], business, [], SourceSpan())
    check diags.len == 1
    check diags[0].severity == sevWarning
    check diags[0].code == "W-SUPPORT-UNSUPPORTED"

  test "layout containers are the structural set":
    for tag in ["mailDocument", "mailWrapper", "mailSection", "mailColumn",
        "mailGroup", "mailColumns", "mailStack", "mailBox", "mailGrid",
        "mailCluster", "mailSidebar", "div", "table", "td", "body"]:
      check isLayoutContainer(tag)
    for tag in ["mailButton", "mailImage", "mailText", "mailDivider",
        "mailSpacer", "p", "h1", "span", "a", "img"]:
      check not isLayoutContainer(tag)
