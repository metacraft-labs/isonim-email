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
## The background fixtures render with `vmlFitToText` on, so a band's
## image reaches Word as the `v:rect` that grows with its content, the
## form MJML's `mj-section` writes; their VML (the rectangle's size,
## whether it grows, and the `v:fill`) is compared too. A hero is
## compared by its leaves and its rectangle only (`leavesOnly`): MJML's
## `mj-hero` draws the image as an absolutely placed `v:image` behind
## an inner px table and gives Word its colour on an inner cell, so the
## ghost-table trees differ by construction, while what Word lays out
## (where the text sits, on which colour, over which rectangle) is
## comparable.
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
    vmlFit*: bool      ## Rendered with `vmlFitToText` on
    leavesOnly*: bool  ## Geometry: leaves, VML and class widths only

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

# --- Background images (rendered with `vmlFitToText`) and heroes.

const bgImage* = "https://example.com/conformance/bg.png"
const tileImage* = "https://example.com/conformance/tile.png"

proc sectionBackground(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("background-color", "#334455"),
    ("background-image", bgImage), ("background-size", "cover")],
    [("background_position", "center top")])
  r.leaf(s, "MK1")
  r.leaf(s, "MK2")
  r.add(doc, s)
  doc

proc sectionTile(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "16px 8px"),
    ("background-color", "#eeeeee"), ("background-image", tileImage),
    ("background-size", "auto")], [("background_repeat", "repeat")])
  let c = r.el("mailColumn", [("padding", "4px 30px")])
  r.leaf(c, "MK1")
  r.add(s, c)
  r.add(doc, s)
  doc

proc sectionTileSized(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("background-color", "#eeeeee"),
    ("background-image", tileImage), ("background-size", "40px")],
    [("background_position", "right 30%"), ("background_repeat", "repeat")])
  r.leaf(s, "MK1")
  r.add(doc, s)
  doc

proc sectionBackgroundContain(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "40px 0"),
    ("background-color", "#102030"), ("background-image", bgImage),
    ("background-size", "contain")],
    [("background_position", "right bottom")])
  r.leaf(s, "MK1")
  r.add(doc, s)
  doc

proc wrapperBackground(): EmailNode =
  let (r, doc) = newDoc()
  let w = r.el("mailWrapper", [("padding", "20px 0"),
    ("background-color", "#223344"), ("background-image", bgImage),
    ("background-size", "cover")],
    [("background_position", "center center")])
  let a = r.el("mailSection")
  r.leaf(a, "MK1")
  let b = r.el("mailSection", [("background-color", "#f4f5f7")])
  r.leaf(b, "MK2")
  r.add(w, a, b)
  r.add(doc, w)
  doc

proc heroFixed(): EmailNode =
  let (r, doc) = newDoc()
  let h = r.el("mailHero", [("background-color", "#2a2a2a"),
    ("background-image", bgImage), ("height", "300px"),
    ("padding", "40px 0")])
  r.leaf(h, "MK1")
  r.leaf(h, "MK2")
  r.add(doc, h)
  doc

proc heroPadded(): EmailNode =
  let (r, doc) = newDoc()
  let h = r.el("mailHero", [("background-color", "#123456"),
    ("background-image", bgImage), ("height", "240px"),
    ("padding", "32px 36px 20px")])
  r.leaf(h, "MK1")
  r.add(doc, h)
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

# --- Rows with a gutter: `mailColumns` in a section's implicit column.

proc row(r: EmailRenderer; section: EmailNode; gutter: string;
    attrs: openArray[(string, string)] = []): EmailNode =
  result = r.el("mailColumns", attrs = @[("gutter", gutter)] & @attrs)
  r.add(section, result)

proc gutterThirds(): EmailNode =
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("background-color", "#f4f5f7")])
  let row = r.row(s, "24px")
  for m in ["MK1", "MK2", "MK3"]:
    let c = r.el("mailColumn")
    r.leaf(c, m)
    r.add(row, c)
  r.add(doc, s)
  doc

proc gutterPxRemainder(): EmailNode =
  ## px columns and an odd gutter: each column loses 2/3 of 25px, and
  ## the rounding remainder goes to the first columns (MJML's
  ## `getDesktopWidth`); the half-gutters are 13px and 12px.
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "16px 0")])
  let row = r.row(s, "25px")
  for (m, w) in [("MK1", "185px"), ("MK2", "184px"), ("MK3", "183px")]:
    let c = r.el("mailColumn", [("width", w)])
    r.leaf(c, m)
    r.add(row, c)
  r.add(doc, s)
  doc

proc gutterBoxes(): EmailNode =
  ## % columns with a gutter; one paints a background and pads itself,
  ## the other pads differently, so Word gets a box per column.
  let (r, doc) = newDoc()
  let s = r.el("mailSection", [("padding", "10px 20px")])
  let row = r.row(s, "16px")
  let a = r.el("mailColumn", [("width", "25%"),
    ("background-color", "#e5e7eb"), ("padding", "8px")])
  r.leaf(a, "MK1")
  let b = r.el("mailColumn", [("width", "75%"), ("padding", "0 4px 12px")])
  r.leaf(b, "MK2")
  r.leaf(b, "MK3")
  r.add(row, a, b)
  r.add(doc, s)
  doc

proc gutterOddPercent(): EmailNode =
  ## Four default columns and an odd gutter in a wrapper's section.
  let (r, doc) = newDoc()
  let w = r.el("mailWrapper", [("padding", "0 12px")])
  let s = r.el("mailSection", [("padding", "8px 4px")])
  let row = r.row(s, "15px")
  for m in ["MK1", "MK2", "MK3", "MK4"]:
    let c = r.el("mailColumn")
    r.leaf(c, m)
    r.add(row, c)
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
    ConformanceFixture(name: "columns-mixed", lowered: true,
      description: "% and px columns beside a % group",
      build: columnsMixed),
    ConformanceFixture(name: "columns-thirds", lowered: true,
      description: "three default-width columns", build: columnsThirds),
    ConformanceFixture(name: "columns-thirds-rounded", lowered: true,
      description: "thirds of 590 px: each column rounds on its own",
      build: columnsThirdsRounded),
    ConformanceFixture(name: "columns-border", lowered: true,
      description: "a bordered section's columns", build: columnsBorder),
    ConformanceFixture(name: "group-px", lowered: true,
      description: "a px group of default columns beside a % column",
      build: groupPx),
    ConformanceFixture(name: "wrapper-columns", lowered: true,
      description: "columns of a section in a padded wrapper",
      build: wrapperColumns),
    ConformanceFixture(name: "gutter-thirds", lowered: true,
      description: "mailColumns: three default columns, a 24px gutter",
      build: gutterThirds),
    ConformanceFixture(name: "gutter-px-remainder", lowered: true,
      description: "px columns, a 25px gutter: the remainder goes first",
      build: gutterPxRemainder),
    ConformanceFixture(name: "gutter-boxes", lowered: true,
      description: "a gutter between a padded background column and a " &
        "column with other vertical padding", build: gutterBoxes),
    ConformanceFixture(name: "gutter-odd-percent", lowered: true,
      description: "four default columns, a 15px gutter, in a wrapper",
      build: gutterOddPercent),
    ConformanceFixture(name: "section-background", lowered: true,
      vmlFit: true, description: "a background image, cover, centre top",
      build: sectionBackground),
    ConformanceFixture(name: "section-background-tile", lowered: true,
      vmlFit: true, description: "a tiled background image (auto, " &
        "repeat) behind a padded column", build: sectionTile),
    ConformanceFixture(name: "section-background-tile-sized", lowered: true,
      vmlFit: true, description: "a 40px tile placed right, 30% down",
      build: sectionTileSized),
    ConformanceFixture(name: "section-background-contain", lowered: true,
      vmlFit: true, description: "a background image, contain, right " &
        "bottom", build: sectionBackgroundContain),
    ConformanceFixture(name: "wrapper-background", lowered: true,
      vmlFit: true, description: "a wrapper's background image behind " &
        "two sections", build: wrapperBackground),
    ConformanceFixture(name: "hero-fixed", lowered: true, leavesOnly: true,
      description: "a 300px hero with a background image (mj-hero " &
        "fixed-height)", build: heroFixed),
    ConformanceFixture(name: "hero-padded", lowered: true, leavesOnly: true,
      description: "a 240px hero with uneven padding", build: heroPadded),
  ]

# --- Width facts from the layout pass.

proc factsOf(node: EmailNode; acc: var seq[WidthFact]) =
  if node == nil or node.kind != enElement:
    return
  if node.layout.solved:
    case node.tag
    of "mailHero":
      # MJML's hero: one centred px table (its inner table has no
      # `align`, so it is not a ghost-table fact).
      acc.add(WidthFact(kind: "table", px: float(node.layout.outer)))
    of "mailSection", "mailWrapper":
      acc.add(WidthFact(kind: "table", px: float(node.layout.outer)))
      var columns = false
      for c in node.children:
        if c.kind == enElement and c.tag in ["mailColumn", "mailGroup",
            "mailColumns"]:
          columns = true
      if node.tag == "mailSection" and not columns:
        # Content directly in a section is its implicit single column,
        # a cell as wide as the section's box.
        acc.add(WidthFact(kind: "cell", px: float(node.layout.box),
          responsive: "100%"))
    of "mailColumn", "mailGroup":
      # The class width: the desktop width, less the gutter share.
      let resp =
        if node.layout.pxWidth: $node.layout.deskPx & "px"
        else: percentText(node.layout.deskPercent) & "%"
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

proc leavesMjml(node: EmailNode; padding = "0"): string =
  for c in node.children:
    if c.kind == enElement and c.tag in ["p", "h1"]:
      var text = ""
      for t in c.children:
        if t.kind == enText:
          text.add(t.text)
      result.add("<mj-text padding=\"" & padding & "\">" & text &
        "</mj-text>")

proc backgroundMjml(n: EmailNode): seq[(string, string)] =
  ## A band's background image as MJML's attributes, this library's
  ## defaults written out (MJML's position default is `top center`).
  let url = value(n, "background-image")
  if url.len == 0:
    return @[]
  var size = value(n, "background-size")
  if size.len == 0:
    size = "cover"
  var pos = value(n, "background_position")
  if pos.len == 0:
    pos = "center center"
  var repeat = value(n, "background_repeat")
  if repeat.len == 0:
    repeat = "no-repeat"
  @[("background-url", url), ("background-size", size),
    ("background-position", pos), ("background-repeat", repeat)]

proc heroMjml(h: EmailNode; theme: EmailTheme): string =
  ## `mj-hero mode="fixed-height"`: the image box is the hero's own
  ## size, and the implicit column's padding goes on each text.
  let height = value(h, "height")
  var pad = value(h, "padding")
  if pad.len == 0:
    pad = theme.lightFor(sectionPaddingToken)
  "<mj-hero" & attrText([("mode", "fixed-height"), ("height", height),
    ("padding", pad), ("background-color", value(h, "background-color")),
    ("background-url", value(h, "background-image")),
    ("background-width", "600px"), ("background-height", height)]) & ">" &
    leavesMjml(h, theme.lightFor(columnPaddingToken)) & "</mj-hero>"

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

proc rowOf(s: EmailNode): EmailNode =
  ## The section's `mailColumns` row, when it is the section's content.
  for c in s.children:
    if c.kind == enElement and c.tag == "mailColumns":
      return c
  nil

proc sideText(v: array[4, int]): string =
  $v[0] & "px " & $v[1] & "px " & $v[2] & "px " & $v[3] & "px"

proc sectionMjml(s: EmailNode; theme: EmailTheme): string =
  var pad = value(s, "padding")
  if pad.len == 0:
    pad = theme.lightFor(sectionPaddingToken)
  let full = if s.attrs.getOrDefault("full_width", "") == "true":
    "full-width" else: ""
  let row = rowOf(s)
  var gutter = ""
  if row != nil:
    # A row in the section's implicit column: MJML puts the column
    # padding on the section and the gutter on the section too.
    let sp = expandBox(pad)
    let cp = expandBox(theme.lightFor(columnPaddingToken))
    var sum: array[4, int]
    for i in 0 .. 3:
      sum[i] = int(toPx(sp[i]) + toPx(cp[i]))
    pad = sideText(sum)
    gutter = value(row, "gutter")
  result = "<mj-section" & attrText(@[("padding", pad),
    ("background-color", value(s, "background-color")),
    ("border", value(s, "border")), ("full-width", full),
    ("gutter", gutter)] & backgroundMjml(s)) & ">"
  if row != nil:
    for c in row.children:
      if c.kind == enElement and c.tag == "mailColumn":
        var cpad = value(c, "padding")
        if cpad.len == 0:
          cpad = "0"
        result.add("<mj-column" & attrText([("width", value(c, "width")),
          ("padding", cpad),
          ("background-color", value(c, "background-color"))]) & ">" &
          leavesMjml(c) & "</mj-column>")
    return result & "</mj-section>"
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
    of "mailHero":
      result.add(heroMjml(c, theme))
    of "mailWrapper":
      # A wrapper has no default padding here; MJML's is 20px 0.
      let wpad = if value(c, "padding").len > 0: value(c, "padding")
        else: "0"
      result.add("<mj-wrapper" & attrText(@[("padding", wpad),
        ("background-color",
        value(c, "background-color")), ("border", value(c, "border"))] &
        backgroundMjml(c)) & ">")
      for s in c.children:
        if s.kind == enElement and s.tag == "mailSection":
          result.add(sectionMjml(s, theme))
      result.add("</mj-wrapper>")
    else:
      discard
  result.add("</mj-body></mjml>\n")
