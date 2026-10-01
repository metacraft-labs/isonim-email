# rule: R-OL-10
## `display:flex` on a layout container is an error under every
## built-in profile (each gives Word-engine Outlook some weight), and
## under a profile that gives it none it is only the removal warning;
## anywhere else it is removed with a warning.
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

  test "harm is an error only where Word-engine Outlook has weight":
    # Two profiles that differ only in outlookWord's weight: zero, and
    # the smallest share that is still someone's inbox.
    var noWord: array[ClientFamily, float]
    noWord[cfApple] = 0.5
    noWord[cfGmailWeb] = 0.5
    var someWord = noWord
    someWord[cfGmailWeb] = 0.499
    someWord[cfOutlookWord] = 0.001
    let noWordProfile = makeProfile("noWord", noWord)
    let someWordProfile = makeProfile("someWord", someWord)
    for tag in ["mailSection", "mailColumn", "div", "td"]:
      # Weight 0: no error; the declaration is still removed, so the
      # author is told so.
      let quiet = lintTree(handBuilt(tag, "display", "flex"), noWordProfile)
      check quiet.len == 1
      check quiet[0].severity == sevWarning
      check quiet[0].code == "W-SUPPORT-UNSUPPORTED"
      check quiet[0].weight == 0.0
      check "removed" in quiet[0].message
      check not hasErrors(quiet)
      # Weight > 0: the harmful error.
      let loud = lintTree(handBuilt(tag, "display", "flex"), someWordProfile)
      check loud.len == 1
      check loud[0].severity == sevError
      check loud[0].code == "E-CSS-HARMFUL"
      check loud[0].families == {cfOutlookWord}
      check abs(loud[0].weight - 0.001) < 1e-12
      check hasErrors(loud)
    # Through the macro too.
    let tree = renderAuthoringTree(flexDivTpl, 0)
    check not hasErrors(lintTree(tree, noWordProfile))
    check hasErrors(lintTree(tree, someWordProfile))

  test "a rendered email reports flex by the profile's Word-engine weight":
    # renderEmail runs the inline style pass, which removes the
    # declaration before lint sees the tree: the profile has to reach
    # that pass, or a zero-weight profile still fails on harmful display.
    var noWord: array[ClientFamily, float]
    noWord[cfApple] = 0.5
    noWord[cfGmailWeb] = 0.5
    var someWord = noWord
    someWord[cfGmailWeb] = 0.499
    someWord[cfOutlookWord] = 0.001
    proc harmful(ds: seq[EmailDiagnostic]): seq[EmailDiagnostic] =
      for d in ds:
        if "R-OL-10" in d.rules:
          result.add(d)
    let quiet = harmful(renderEmail(flexDivTpl, 0,
      profile = makeProfile("noWord", noWord)).diagnostics)
    check quiet.len == 1
    check quiet[0].severity == sevWarning
    check quiet[0].code == "W-SUPPORT-UNSUPPORTED"
    check "display:flex" in quiet[0].message
    check "removed" in quiet[0].message
    check not hasErrors(quiet)
    let loud = harmful(renderEmail(flexDivTpl, 0,
      profile = makeProfile("someWord", someWord)).diagnostics)
    check loud.len == 1
    check loud[0].severity == sevError
    check loud[0].code == "E-CSS-HARMFUL"
    check abs(loud[0].weight - 0.001) < 1e-12
    # The built-in profiles all weigh Word-engine Outlook: still an error.
    for profile in [consumer, business, developer]:
      let ds = harmful(renderEmail(flexDivTpl, 0,
        profile = profile).diagnostics)
      check ds.len == 1
      check ds[0].code == "E-CSS-HARMFUL"
      check ds[0].severity == sevError

  test "a rendered email warns, not errors, for flex off a container":
    # The inline style pass removes flex on every element before lint sees
    # the tree, so its severity is the one the author gets: off a layout
    # container it must be lint's removal warning under every profile,
    # while a container still errors where Word-engine Outlook has weight.
    proc harmful(ds: seq[EmailDiagnostic]): seq[EmailDiagnostic] =
      for d in ds:
        if "R-OL-10" in d.rules:
          result.add(d)
    for profile in [consumer, business, developer]:
      let rendered = renderEmail(flexParaTpl, 0, profile = profile)
      let para = harmful(rendered.diagnostics)
      check para.len == 1
      check para[0].severity == sevWarning
      check para[0].code == "W-SUPPORT-UNSUPPORTED"
      check "display:flex" in para[0].message
      check "<p>" in para[0].message
      check "was removed" in para[0].message
      check not hasErrors(para)
      check "display:flex" notin rendered.html
      let container = harmful(renderEmail(flexDivTpl, 0,
        profile = profile).diagnostics)
      check container.len == 1
      check container[0].severity == sevError
      check container[0].code == "E-CSS-HARMFUL"
    var noWord: array[ClientFamily, float]
    noWord[cfApple] = 0.5
    noWord[cfGmailWeb] = 0.5
    let quiet = harmful(renderEmail(flexParaTpl, 0,
      profile = makeProfile("noWord", noWord)).diagnostics)
    check quiet.len == 1
    check quiet[0].severity == sevWarning

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
