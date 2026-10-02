## The MJML conformance fixtures: hand-built trees, their MJML twins,
## and the widths the layout pass gives them.
##
## One fixture is one tree builder. Its MJML twin is generated from the
## same tree (`toMjml`) from the values as authored, with this library's
## defaults written out (MJML's differ), so the two inputs cannot drift
## apart and the converter never reads what the layout pass computed.
## Leaves are paragraphs whose text is a marker (`MK1`, `MK2`, …): the
## Outlook-geometry check finds each leaf by its marker in both outputs.
##
## `lowered` marks the fixtures whose output is compared as Outlook
## geometry (`just test-conformance`); the others hold multi-column rows
## and groups, whose lowering does not exist yet, and are compared at
## the width-solver level only (here and in `tests/t5_layout.nim`).
##
## `widthFacts` flattens the layout pass's annotations into the same
## record the harness extracts from MJML's HTML, in document order: a
## `table` fact per section or wrapper (its ghost-table px width), a
## `cell` fact per column or group (its Outlook px width and its
## responsive width, `%` or px).
##
## Pure tree building: identical on the C and JS targets.

import std/tables
import isonim_email

type
  ConformanceFixture* = object
    name*: string
    description*: string
    lowered*: bool
    build*: proc(): EmailNode {.nimcall.}

  WidthFact* = object
    kind*: string      ## "table" or "cell"
    px*: float         ## ghost-table width, or the cell's Outlook px width
    responsive*: string ## cells: the class width (`50%`, `200px`); tables: ""

const documentBackground* = "#ffffff"
  ## Both twins paint the document white, so a full-bleed band is told
  ## apart from the page.

proc newDoc(width = ""): (EmailRenderer, EmailNode) =
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Conformance")
  r.setStyle(doc, "background-color", documentBackground)
  if width.len > 0:
    r.setStyle(doc, "width", width)
  (r, doc)

proc el(r: EmailRenderer; tag: string; styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)

proc leaf(r: EmailRenderer; parent: EmailNode; marker: string) =
  # The first leaf is the document's `h1` (a document needs one).
  let p = r.createElement(if marker == "MK1": "h1" else: "p")
  r.setTextContent(p, marker)
  r.appendChild(parent, p)

proc add(r: EmailRenderer; parent: EmailNode; kids: varargs[EmailNode]) =
  for k in kids:
    r.appendChild(parent, k)

# --- Lowered fixtures: sections, wrappers, padding, borders, one column.

proc sectionDefault(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("background-color", "#f4f5f7")])
  r.leaf(s, "MK1")
  r.add(doc, s)
  doc

proc sectionColumn(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "10px 20px"),
    ("background-color", "#f4f5f7")])
  let c = r.el("mailColumn", [("padding", "5px 30px")])
  r.leaf(c, "MK1")
  r.leaf(c, "MK2")
  r.add(s, c)
  r.add(doc, s)
  doc

proc sectionBorder(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "24px 0"),
    ("border", "2px solid #e5e7eb"), ("background-color", "#ffffff")])
  r.leaf(s, "MK1")
  r.add(doc, s)
  doc

proc sectionAsymmetric(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "8px 12px 16px 40px"),
    ("background-color", "#e5e7eb")])
  let c = r.el("mailColumn", [("padding", "0")])
  r.leaf(c, "MK1")
  r.add(s, c)
  r.add(doc, s)
  doc

proc sectionFullWidth(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "16px 0"),
    ("background-color", "#eeeeee")], [("full_width", "true")])
  r.leaf(s, "MK1")
  r.add(doc, s)
  doc

proc sectionsStacked(): EmailNode =
  let (r, doc) = newDoc()
  let a = r.el("mailSection", [("padding", "32px 0"),
    ("background-color", "#f4f5f7")])
  r.leaf(a, "MK1")
  let b = r.el("mailSection", [("padding", "0 16px"),
    ("background-color", "#e5e7eb")])
  let c = r.el("mailColumn", [("padding", "4px 8px 12px")])
  r.leaf(c, "MK2")
  r.add(b, c)
  r.add(doc, a, b)
  doc

proc wrapperSections(): EmailNode =
  let (r, doc) = newDoc()
  let w = r.el("mailWrapper", [("padding", "16px 20px"),
    ("background-color", "#eeeeee")])
  let a = r.el("mailSection", [("padding", "12px 0"),
    ("background-color", "#f4f5f7")])
  r.leaf(a, "MK1")
  let b = r.el("mailSection", [("padding", "0")])
  let c = r.el("mailColumn", [("padding", "0 10px")])
  r.leaf(c, "MK2")
  r.add(b, c)
  r.add(w, a, b)
  r.add(doc, w)
  doc

proc wrapperBorder(): EmailNode =
  let (r, doc) = newDoc()
  let w = r.el("mailWrapper", [("padding", "10px"),
    ("border", "1px solid #cccccc"), ("background-color", "#f4f5f7")])
  let a = r.el("mailSection")
  r.leaf(a, "MK1")
  r.add(w, a)
  r.add(doc, w)
  doc

proc documentWidth640(): EmailNode =
  let (r, doc) = newDoc("640px")
  let s = r.el("mailSection", [("background-color", "#f4f5f7")])
  r.leaf(s, "MK1")
  r.add(doc, s)
  doc

# --- Solver-only fixtures: column rows and groups.

proc columnsMixed(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "10px 20px")])
  let a = r.el("mailColumn", [("width", "40%"), ("padding", "0 8px")])
  r.leaf(a, "MK1")
  let b = r.el("mailColumn", [("width", "200px")])
  r.leaf(b, "MK2")
  let g = r.el("mailGroup", [("width", "25%")])
  let c = r.el("mailColumn")
  r.leaf(c, "MK3")
  let d = r.el("mailColumn", [("width", "30%")])
  r.leaf(d, "MK4")
  r.add(g, c, d)
  r.add(s, a, b, g)
  r.add(doc, s)
  doc

proc columnsThirds(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection")
  for m in ["MK1", "MK2", "MK3"]:
    let c = r.el("mailColumn")
    r.leaf(c, m)
    r.add(s, c)
  r.add(doc, s)
  doc

proc columnsThirdsRounded(): EmailNode =
  ## B = 590: each third is 196.67 px and rounds on its own to 197, so
  ## the cells sum to 591 (no remainder moves onto the last one).
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "0 5px")])
  for m in ["MK1", "MK2", "MK3"]:
    let c = r.el("mailColumn")
    r.leaf(c, m)
    r.add(s, c)
  r.add(doc, s)
  doc

proc columnsBorder(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "0 10px"),
    ("border", "3px solid #111111")])
  for (m, w) in [("MK1", "50%"), ("MK2", "50%")]:
    let c = r.el("mailColumn", [("width", w)])
    r.leaf(c, m)
    r.add(s, c)
  r.add(doc, s)
  doc

proc groupPx(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "0")])
  let g = r.el("mailGroup", [("width", "300px")])
  for m in ["MK1", "MK2", "MK3"]:
    let c = r.el("mailColumn")
    r.leaf(c, m)
    r.add(g, c)
  let e = r.el("mailColumn", [("width", "50%")])
  r.leaf(e, "MK4")
  r.add(s, g, e)
  r.add(doc, s)
  doc

proc wrapperColumns(): EmailNode =
  let (r, doc) = newDoc()
  let w = r.el("mailWrapper", [("padding", "0 30px")])
  let s = r.el("mailSection")
  for (m, wd) in [("MK1", "25%"), ("MK2", "75%")]:
    let c = r.el("mailColumn", [("width", wd)])
    r.leaf(c, m)
    r.add(s, c)
  r.add(w, s)
  r.add(doc, w)
  doc

proc conformanceFixtures*(): seq[ConformanceFixture] =
  @[
    ConformanceFixture(name: "section-default", lowered: true,
      description: "default section padding, implicit single column",
      build: sectionDefault),
    ConformanceFixture(name: "section-column", lowered: true,
      description: "one explicit column; its padding merges",
      build: sectionColumn),
    ConformanceFixture(name: "section-border", lowered: true,
      description: "a bordered section", build: sectionBorder),
    ConformanceFixture(name: "section-asymmetric", lowered: true,
      description: "four different paddings, column padding 0",
      build: sectionAsymmetric),
    ConformanceFixture(name: "section-full-width", lowered: true,
      description: "full-bleed background", build: sectionFullWidth),
    ConformanceFixture(name: "sections-stacked", lowered: true,
      description: "two sections, different paddings and backgrounds",
      build: sectionsStacked),
    ConformanceFixture(name: "wrapper-sections", lowered: true,
      description: "a wrapper's padding narrows its sections",
      build: wrapperSections),
    ConformanceFixture(name: "wrapper-border", lowered: true,
      description: "a bordered wrapper", build: wrapperBorder),
    ConformanceFixture(name: "document-width", lowered: true,
      description: "mailDocument(width = 640px)", build: documentWidth640),
    ConformanceFixture(name: "columns-mixed", lowered: false,
      description: "% and px columns beside a % group",
      build: columnsMixed),
    ConformanceFixture(name: "columns-thirds", lowered: false,
      description: "three default-width columns", build: columnsThirds),
    ConformanceFixture(name: "columns-thirds-rounded", lowered: false,
      description: "thirds of 590 px: each column rounds on its own",
      build: columnsThirdsRounded),
    ConformanceFixture(name: "columns-border", lowered: false,
      description: "a bordered section's columns", build: columnsBorder),
    ConformanceFixture(name: "group-px", lowered: false,
      description: "a px group of default columns beside a % column",
      build: groupPx),
    ConformanceFixture(name: "wrapper-columns", lowered: false,
      description: "columns of a section in a padded wrapper",
      build: wrapperColumns),
  ]

# --- Width facts from the layout pass.

proc factsOf(node: EmailNode; acc: var seq[WidthFact]) =
  if node == nil or node.kind != enElement:
    return
  if node.layout.solved:
    case node.tag
    of "mailSection", "mailWrapper":
      acc.add(WidthFact(kind: "table", px: float(node.layout.outer)))
      var columns = false
      for c in node.children:
        if c.kind == enElement and c.tag in ["mailColumn", "mailGroup"]:
          columns = true
      if node.tag == "mailSection" and not columns:
        # Content directly in a section is its implicit single column,
        # a cell as wide as the section's box.
        acc.add(WidthFact(kind: "cell", px: float(node.layout.box),
          responsive: "100%"))
    of "mailColumn", "mailGroup":
      let resp =
        if node.layout.pxWidth: $node.layout.outer & "px"
        else: percentText(node.layout.percent) & "%"
      acc.add(WidthFact(kind: "cell", px: float(node.layout.outer),
        responsive: resp))
    else:
      discard
  for c in node.children:
    factsOf(c, acc)

proc widthFacts*(doc: EmailNode): seq[WidthFact] =
  ## The layout pass's facts for a solved tree, in document order.
  factsOf(doc, result)

# --- The MJML twin.

proc attrText(pairs: openArray[(string, string)]): string =
  for (k, v) in pairs:
    if v.len > 0:
      result.add(" " & k & "=\"" & v & "\"")

proc value(node: EmailNode; name: string): string =
  rawValue(node, name)

proc leavesMjml(node: EmailNode): string =
  for c in node.children:
    if c.kind == enElement and c.tag in ["p", "h1"]:
      var text = ""
      for t in c.children:
        if t.kind == enText:
          text.add(t.text)
      result.add("<mj-text padding=\"0\">" & text & "</mj-text>")

proc columnMjml(col: EmailNode; theme: EmailTheme): string =
  if col.tag == "mailGroup":
    result = "<mj-group" & attrText([("width", value(col, "width"))]) & ">"
    for c in col.children:
      if c.kind == enElement and c.tag == "mailColumn":
        result.add(columnMjml(c, theme))
    return result & "</mj-group>"
  var pad = value(col, "padding")
  if pad.len == 0:
    pad = theme.lightFor(columnPaddingToken)
  "<mj-column" & attrText([("width", value(col, "width")),
    ("padding", pad)]) & ">" & leavesMjml(col) & "</mj-column>"

proc sectionMjml(s: EmailNode; theme: EmailTheme): string =
  var pad = value(s, "padding")
  if pad.len == 0:
    pad = theme.lightFor(sectionPaddingToken)
  let full = if s.attrs.getOrDefault("full_width", "") == "true":
    "full-width" else: ""
  result = "<mj-section" & attrText([("padding", pad),
    ("background-color", value(s, "background-color")),
    ("border", value(s, "border")), ("full-width", full)]) & ">"
  var columns = false
  for c in s.children:
    if c.kind == enElement and c.tag in ["mailColumn", "mailGroup"]:
      columns = true
      result.add(columnMjml(c, theme))
  if not columns:
    result.add("<mj-column padding=\"" &
      theme.lightFor(columnPaddingToken) & "\">" & leavesMjml(s) &
      "</mj-column>")
  result.add("</mj-section>")

proc toMjml*(doc: EmailNode; target = defaultTarget();
    theme = defaultTheme()): string =
  ## The MJML twin of a fixture tree (built fresh: never a tree the
  ## passes have run over).
  var width = value(doc, "width")
  if width.len == 0:
    width = $target.containerWidth & "px"
  result = "<mjml><mj-body width=\"" & width & "\" background-color=\"" &
    documentBackground & "\">"
  for c in doc.children:
    if c.kind != enElement:
      continue
    case c.tag
    of "mailSection":
      result.add(sectionMjml(c, theme))
    of "mailWrapper":
      # A wrapper has no default padding here; MJML's is 20px 0.
      let wpad = if value(c, "padding").len > 0: value(c, "padding")
        else: "0"
      result.add("<mj-wrapper" & attrText([("padding", wpad),
        ("background-color",
        value(c, "background-color")), ("border", value(c, "border"))]) &
        ">")
      for s in c.children:
        if s.kind == enElement and s.tag == "mailSection":
          result.add(sectionMjml(s, theme))
      result.add("</mj-wrapper>")
    else:
      discard
  result.add("</mj-body></mjml>\n")
