## `ui(r)` elements carry their template call site in `origin`: the
## macro's per-element hook stamps every element node with its source
## span, so diagnostics cite real file:line instead of "unknown
## location". Collected diagnostics keep the span of the node they were
## raised against.
##
## Backend-independent (tree building + span parsing), so `just test`
## also runs it on JS.
import std/[strutils, unittest]
import isonim_email

proc spanTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Spans"):
      mailSection:
        h1: text "Hi"
        p: text "body"

proc noLangTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(title = "No lang"):
      mailSection:
        h1: text "No lang"

proc multiTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "One"):
      mailSection:
        h1: text "One"
    mailDocument(lang = "en", title = "Two"):
      mailSection:
        h1: text "Two"

proc allElements(node: EmailNode): seq[EmailNode] =
  if node.kind == enElement:
    result.add(node)
  for c in node.children:
    result.add(allElements(c))

suite "template source spans":
  test "elements carry their template call site":
    let tree = renderAuthoringTree(spanTpl, 0)
    check tree.tag == "mailDocument"
    check tree.origin.file.endsWith("t1_source_spans.nim")
    check tree.origin.line == 14
    check tree.origin.col > 0
    let sec = tree.children[0]
    check sec.tag == "mailSection"
    check sec.origin.line == 15
    # `tag:` elements are anchored at the tag's first character (Nim's
    # 0-based column: six spaces of indentation). `tag(args)` elements
    # are anchored at the `(`, which the renderer cannot correct (see
    # `noteElement`).
    check sec.origin.col == 6
    let h1 = sec.children[0]
    check h1.tag == "h1"
    check h1.origin.line == 16
    let p = sec.children[1]
    check p.tag == "p"
    check p.origin.line == 17

  test "collected diagnostics cite the node span, not unknown location":
    let res = renderEmail(noLangTpl, 0)
    check hasErrors(res.diagnostics)
    var langDiag: EmailDiagnostic
    var found = false
    for d in res.diagnostics:
      if d.code == codeA11yLangMissing:
        langDiag = d
        found = true
    check found
    check langDiag.origin.file.endsWith("t1_source_spans.nim")
    check langDiag.origin.line == 21
    let rendered = $langDiag
    check "t1_source_spans.nim:" & $langDiag.origin.line in rendered
    check "unknown location" notin rendered

  test "every element has a span; text nodes honestly do not":
    let tree = renderAuthoringTree(spanTpl, 0)
    let els = allElements(tree)
    check els.len == 4
    for el in els:
      check el.origin.file.len > 0
      check el.origin.line > 0
    let h1 = tree.children[0].children[0]
    check h1.children[0].kind == enText
    check h1.children[0].origin.file.len == 0
    check $h1.children[0].origin == "unknown location"

  test "macro-synthesised fragment roots keep empty origins":
    let tree = renderAuthoringTree(multiTpl, 0)
    check tree.tag == "div"
    check tree.origin.file.len == 0
    check tree.children.len == 2
    for doc in tree.children:
      check doc.tag == "mailDocument"
      check doc.origin.file.endsWith("t1_source_spans.nim")
      check doc.origin.line > 0

  test "span parsing rejects garbage without raising":
    let good = parseSourceSpan("tests/t1_source_spans.nim:12:4")
    check good.file == "tests/t1_source_spans.nim"
    check good.line == 12
    check good.col == 4
    let drive = parseSourceSpan("C:/src/mail.nim:3:9")
    check drive.file == "C:/src/mail.nim"
    check drive.line == 3
    check drive.col == 9
    for bad in ["", "no-colons", "a:1:x", "a:x:1", "a:0:1", "a:1"]:
      check parseSourceSpan(bad).file.len == 0
      check $parseSourceSpan(bad) == "unknown location"
