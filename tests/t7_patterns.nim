## `defineMailPattern`: a vocabulary element defined by expansion, with
## the two declarations the review brief generator reads.
##
## - A pattern defined here is usable in a `ui(EmailRenderer)` template
##   below its definition (the static vocabulary learns it at compile
##   time; `tests/compile_fail/pattern_unknown_attr.nim` shows its
##   attributes are checked too), expands before every pass, lowers to
##   its expansion, and stays in the semantic tree with its props.
## - Both declarations are mandatory, a name is defined once, a prop
##   that does not parse is `E-VOCAB-BAD-VALUE` at the element.
## - The brief lists a pattern's expected elements and its declared
##   degradations for the client the brief is for, and the layout
##   primitives' declarations follow the client: Word, no CSS, a phone.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
import std/[strutils, tables, unittest]
import isonim_email

type NoteProps = object
  title: string
  tone: string = "info"
  stripes: int = 1

proc noteExpand(n: EmailNode; p: NoteProps; ctx: ExpandCtx): EmailNode =
  if p.title.len == 0:
    raise newException(PatternError, "mailNote needs a title")
  let r = ctx.r
  result = r.createElement("mailBox")
  r.setStyle(result, "background-color",
    if p.tone == "warning": "#fef3c7" else: "#dbeafe")
  let h = r.createElement("h2")
  r.setTextContent(h, (if p.tone == "warning": "Warning: " else: "") &
    p.title)
  r.appendChild(result, h)
  let slot = n.children # Copy: appendChild detaches as it moves.
  for c in slot:
    r.appendChild(result, c)

proc noteExpected(n: EmailNode; p: NoteProps; view: BriefView): seq[string] =
  @["Note \"" & p.title & "\" (" & p.tone & "): a tinted panel, its " &
    "title as a heading, then its text."]

proc noteDegradations(n: EmailNode; p: NoteProps;
    view: BriefView): seq[string] =
  if view.word:
    result.add("the note's panel has square corners in Word")

defineMailPattern(mailNote, NoteProps, noteExpand, noteExpected,
  noteDegradations)

proc noteTpl(r: EmailRenderer; title: string): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Notes"):
      h1: text "Notes"
      mailSection:
        mailNote(title = title, tone = "warning"):
          p: text "The build is slow today."

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc el(r: EmailRenderer; parent: EmailNode; tag: string;
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

proc docWith(build: proc(r: EmailRenderer; s: EmailNode)): EmailNode =
  let r = EmailRenderer()
  result = r.el(nil, "mailDocument", [("lang", "en"), ("dir", "ltr"),
    ("title", "Patterns")])
  discard r.el(result, "h1", text = "Patterns")
  build(r, r.el(result, "mailSection"))

suite "defineMailPattern":
  test "test_pattern_expands_through_the_pipeline":
    let res = renderEmail(noteTpl, "Slow builds")
    check res.diagnostics.len == 0
    # The expansion went through P3, P5 and P4: a box table with the
    # title and the slot's paragraph inside its cell.
    check "<td bgcolor=\"#fef3c7\" style=\"padding:24px;background-color:" &
      "#fef3c7;word-break:break-word;overflow-wrap:break-word;\"><h2" in
      res.html
    check ">Warning: Slow builds</h2><p" in res.html
    check "The build is slow today." in res.html
    check "mailNote" notin res.html and "mailBox" notin res.html
    # The semantic tree keeps the pattern element and its props.
    var note: EmailNode
    var stack = @[res.semantic]
    while stack.len > 0:
      let n = stack.pop()
      if n.kind == enElement and n.tag == "mailNote":
        note = n
      for c in n.children:
        stack.add(c)
    check note != nil
    check note.expanded
    check note.attrs["title"] == "Slow builds"
    check note.children.len == 1 and note.children[0].tag == "mailBox"
    # Expansion is idempotent: a second pass leaves the tree alone.
    check expandPatterns(res.semantic, defaultTheme(),
      defaultTarget()).len == 0
    check note.children.len == 1

  test "test_pattern_declarations_are_mandatory":
    check isPattern("mailNote")
    check isPattern("mailGrid")
    expect PatternError:
      registerPattern(PatternDef(name: "mailHalf",
        expectedElements: proc(n: EmailNode; v: BriefView): seq[string] =
          @["x"]))
    expect PatternError:
      registerPattern(PatternDef(name: "mailHalf2",
        degradations: proc(n: EmailNode; v: BriefView): seq[string] =
          @[]))
    expect PatternError:
      registerPattern(typedPattern[NoteProps]("mailNote", noteExpand,
        noteExpected, noteDegradations))
    check not isPattern("mailHalf")

  test "test_pattern_props_are_typed":
    let doc = docWith(proc(r: EmailRenderer; s: EmailNode) =
      discard r.el(s, "mailNote", [("title", "T"), ("stripes", "many")]))
    let res = renderTree(doc)
    # The bad value, and the element left unexpanded is never emitted.
    check codesOf(res.diagnostics) == @[codeVocabBadValue, codeLowerMissing]
    check "stripes" in res.diagnostics[0].message
    # A refusal of the expansion itself.
    let empty = docWith(proc(r: EmailRenderer; s: EmailNode) =
      discard r.el(s, "mailNote"))
    let res2 = renderTree(empty)
    check codesOf(res2.diagnostics) == @[codeVocabBadValue,
      codeLowerMissing]
    check "needs a title" in res2.diagnostics[0].message
    # Defaults and parsing.
    let n = EmailRenderer().createElement("mailNote")
    EmailRenderer().setAttribute(n, "stripes", "3px")
    let p = readProps[NoteProps](n)
    check p.tone == "info" and p.stripes == 3 and p.title == ""

suite "the brief reads the declarations":
  proc story(name: string; build: proc(): EmailNode): Story =
    registerStoryTree(name, build)
    Story(name: name, group: "patterns",
      render: proc(): StoryHtml = ("", ""))

  test "test_pattern_lines_in_the_brief":
    let s = story("noteBrief", proc(): EmailNode =
      docWith(proc(r: EmailRenderer; s: EmailNode) =
        let n = r.el(s, "mailNote", [("title", "Heads up")])
        discard r.el(n, "p", text = "Body text.")))
    let apple = expectedBlock(s, "apple", "desktop", "light")
    check "Note \"Heads up\" (info): a tinted panel" in apple
    # The slot's content is listed too, after the pattern's line.
    check apple.find("Note \"Heads up\"") <
      apple.find("Paragraph beginning \"Body text.\"")
    check "square corners in Word" notin apple
    let word = expectedBlock(s, "wordApprox", "desktop", "light")
    check "- the note's panel has square corners in Word" in word
    # Real clients get the pattern's lines too.
    check "Note \"Heads up\"" in clientExpectedBlock(s, "roundcube",
      "desktop", "light")

  test "test_primitive_lines_follow_the_client":
    let grid = story("gridBrief", proc(): EmailNode =
      docWith(proc(r: EmailRenderer; s: EmailNode) =
        let g = r.el(s, "mailGrid", [("columns", "3")])
        for i in 1 .. 5:
          discard r.el(g, "p", text = "Item " & $i)))
    proc line(b, prefix: string): string =
      for l in b.splitLines():
        if prefix in l:
          return l
    let desk = line(expectedBlock(grid, "apple", "desktop", "light"), "Grid")
    check "3 items per row" in desk
    check "the last row holds 2 at the start edge" in desk
    let phone = line(expectedBlock(grid, "apple", "mobile", "light"), "Grid")
    check "1 item per row" in phone and "stacked full width" in phone
    # Without CSS a phone shows one item per row: two would need
    # 184 + 184px (the 160px minimum and its gutter) of the 327px box;
    # the degradation says why.
    let ganga = expectedBlock(grid, "ganga", "mobile", "light")
    check "1 item per row" in line(ganga, "Grid")
    check "no narrower than its minimum" in line(ganga, "Grid")
    check "as many per row as fit" in ganga
    check "3 items per row" in line(expectedBlock(grid, "wordApprox",
      "mobile", "light"), "Grid")
    let cluster = story("clusterBrief", proc(): EmailNode =
      docWith(proc(r: EmailRenderer; s: EmailNode) =
        let c = r.el(s, "mailCluster", [("separator", "·")])
        for t in ["Home", "Docs", "Blog"]:
          discard r.el(c, "a", [("href", "https://example.com/")], t)))
    let word = expectedBlock(cluster, "wordApprox", "desktop", "light")
    check "Cluster of 3 items (\"Home\", \"Docs\", \"Blog\")" in word
    check "all on one line" in word
    check "Word never wraps a table row" in word
    check "wraps onto further lines" in expectedBlock(cluster, "apple",
      "mobile", "light")
    let box = story("boxBrief", proc(): EmailNode =
      docWith(proc(r: EmailRenderer; s: EmailNode) =
        let b = r.el(s, "mailBox", [("shadow", "md")])
        r.setStyle(b, "background-color", "#ffffff")
        r.setStyle(b, "border-radius", "8px")
        discard r.el(b, "p", text = "Boxed")))
    let gmail = expectedBlock(box, "gmailWeb", "desktop", "light")
    check "no drop shadow; its 1px border marks its edge" in gmail
    check "a soft drop shadow" notin gmail
    check "a soft drop shadow (md)" in expectedBlock(box, "apple",
      "desktop", "light")
    check "corners are square" in expectedBlock(box, "wordApprox",
      "desktop", "light")
    let side = story("sidebarBrief", proc(): EmailNode =
      docWith(proc(r: EmailRenderer; s: EmailNode) =
        let sb = r.el(s, "mailSidebar", [("fixed", "160px"),
          ("switch_below", "280px")])
        discard r.el(sb, "p", text = "Thumbnail")
        discard r.el(sb, "p", text = "Teaser")))
    check "Sidebar, stacked at this width" in expectedBlock(side, "apple",
      "mobile", "light")
    check "Sidebar: a 160px wide side" in expectedBlock(side, "apple",
      "desktop", "light")
    let snappy = clientExpectedBlock(side, "snappymail", "desktop", "light")
    check "no gap" in snappy
