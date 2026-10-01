# rule: R-CSS-01
## R-CSS-01 — head CSS is progressive enhancement. A seed
## document rendered through lower+head stays correct with every
## `<style>` removed (the `ganga` family's reality): every text
## node and every inline style declaration survives byte-identically
## and the stripped document re-parses.
##
## Backend-independent (tree building + pure passes + string work),
## so `just test` also runs it on JS.
import std/[strutils, unittest]
import isonim_email
import stories/seed_receipt

proc textsOf(root: EmailNode): seq[string] =
  ## Every text-node payload in the tree.
  if root == nil:
    return @[]
  if root.kind == enText:
    result.add(root.text)
  for c in root.children:
    for t in textsOf(c):
      result.add(t)

proc styleSpans(html: string): seq[string] =
  ## Every `style="…"` attribute span in the serialised bytes.
  var i = 0
  while true:
    let s = html.find("style=\"", i)
    if s < 0:
      break
    let e = html.find("\"", s + 7)
    doAssert e > s, "unterminated style attribute"
    result.add(html[s .. e])
    i = e + 1

proc stripStyleBlocks(html: string): string =
  ## The document with every `<style…>…</style>` block excised.
  result = html
  while true:
    let s = result.find("<style")
    if s < 0:
      break
    let openEnd = result.find(">", s)
    doAssert openEnd > s, "unterminated style open tag"
    let c = result.find("</style>", openEnd)
    doAssert c > openEnd, "unclosed style block"
    result = result[0 ..< s] & result[c + 8 .. ^1]

const voidTags = ["meta", "img", "br", "hr", "link", "input", "source",
  "wbr", "col", "base"]

proc balancedTags(html: string): bool =
  ## A minimal well-formedness re-parse: comments and doctype
  ## skipped, void and self-closing tags unpushed, every other open
  ## tag matched by its closer in stack order.
  var stack: seq[string] = @[]
  var i = 0
  while i < html.len:
    let s = html.find('<', i)
    if s < 0:
      break
    if html[s ..< min(s + 4, html.len)] == "<!--":
      let e = html.find("-->", s + 4)
      if e < 0:
        return false
      i = e + 3
      continue
    let e = html.find('>', s + 1)
    if e < 0:
      return false
    let inner = html[s + 1 ..< e].strip()
    i = e + 1
    if inner.len == 0:
      return false
    if inner[0] == '!' or inner[0] == '?':
      continue
    if inner[0] == '/':
      let name = inner[1 .. ^1].split({' ', '\t', '\n', '\r'})[0]
        .toLowerAscii()
      if stack.len == 0 or stack.pop() != name:
        return false
    else:
      var body = inner
      var selfClose = false
      if body.endsWith("/"):
        selfClose = true
        body = body[0 ..< ^1].strip()
      let name = body.split({' ', '\t', '\n', '\r'})[0].toLowerAscii()
      if name in voidTags or selfClose:
        continue
      stack.add(name)
  stack.len == 0

suite "ganga strip":
  test "test_ganga_strip_keeps_text_and_inline_styles":
    let story = seedReceipt()
    check validate(story).len == 0
    let styled = applyStyles(story, defaultTheme(), defaultTarget())
    var target = defaultTarget()
    target.outlookWord = false
    target.headStyleBudget = 1_000_000
    target.darkMode = dmDesigned # Only the designed strategy has dark CSS.
    # A three-block head (reset + responsive + dark) so the strip
    # removes plain and @media-carrying blocks alike.
    let decls = styled.head & @[
      HeadDecl(variant: "sm", prop: "width", value: "100%",
        node: story, origin: SourceSpan()),
      HeadDecl(variant: "dark", prop: "color", value: "#e5e7eb",
        node: story, origin: SourceSpan()),
    ]
    let headed = assembleHead(decls, target)
    check headed.diagnostics.len == 0
    check headed.blocks.len == 3
    let html = lowerDocument(story, story, headed.blocks, target)
    discard applyA11y(html)
    let full = serializeDocument(html)
    check full.count("<style") == 3
    let texts = textsOf(html)
    check texts.len >= 1
    let spans = styleSpans(full)
    check spans.len >= 1
    let stripped = stripStyleBlocks(full)
    check "<style" notin stripped
    check "</style>" notin stripped
    for t in texts:
      check t in stripped
    for s in spans:
      check s in stripped
    check stripped.startsWith("<!doctype html>")
    check balancedTags(stripped)
