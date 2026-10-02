## The layout pass (P3): the width solver the scaffolding lowerings and
## the column strategies read.
##
## The widths are MJML 5's, and the main test proves it against MJML's
## own output: `tests/conformance/mjml_widths.json` holds what the
## pinned MJML emits for every conformance fixture (ghost-table widths,
## column and group Outlook px widths, their responsive class widths),
## and `just test-conformance` fails whenever that file stops matching
## MJML's live output. This test needs no MJML of its own, so it runs in
## `just test` on both backends.
##
## The other tests pin the maths the catalogue states (§4.1): the box of
## a section, a wrapper and a column, the document's width context, the
## implicit single column, independent rounding, full-precision
## percentages, and the structural error for a section that mixes
## columns with content.
##
## Backend-independent (tree building, the pass, and JSON parsing of a
## file embedded at compile time), so `just test` also runs it on JS.
import std/[json, math, strutils, tables, unittest]
import isonim_email
import conformance/fixtures

const recordedWidths = staticRead("conformance/mjml_widths.json")

proc responsiveValue(s: string): tuple[unit: string; value: float] =
  if s.endsWith("%"):
    ("%", parseFloat(s[0 ..< ^1]))
  elif s.endsWith("px"):
    ("px", parseFloat(s[0 ..< ^2]))
  else:
    ("", 0.0)

proc solved(doc: EmailNode; target = defaultTarget()): EmailNode =
  let diags = solveLayout(doc, defaultTheme(), target)
  doAssert not hasErrors(diags), $diags
  doc

proc newDoc(r: EmailRenderer): EmailNode =
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", "en")
  r.setAttribute(result, "title", "Layout")

proc child(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = []): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  r.appendChild(parent, result)

suite "P3 widths match MJML 5":
  test "test_width_solver_matches_mjml":
    let recorded = parseJson(recordedWidths)
    let fixtures = conformanceFixtures()
    check fixtures.len == recorded.len
    var cells, tables = 0
    for f in fixtures:
      check recorded.hasKey(f.name)
      let theirs = recorded[f.name]
      let ours = widthFacts(solved(f.build()))
      check ours.len > 0
      check ours.len == theirs.len
      for i in 0 ..< min(ours.len, theirs.len):
        let t = theirs[i]
        check ours[i].kind == t["kind"].getStr()
        # MJML writes a group's cell unrounded; the ghost cell is whole px.
        check ours[i].px == round(t["px"].getFloat())
        if ours[i].kind == "cell":
          inc cells
          let (ua, va) = responsiveValue(ours[i].responsive)
          let (ub, vb) = responsiveValue(t["responsive"].getStr())
          check ua == ub
          check abs(va - vb) < 1e-5
        else:
          inc tables
    # Non-vacuity: the fixtures exercise columns, groups, wrappers and
    # gutters (where the class width is the desktop width less the
    # gutter share, so it differs from the cell's share of the row).
    check cells >= 38
    check tables >= 19
    var gutterFixtures = 0
    for f in fixtures:
      if f.name.startsWith("gutter-"):
        inc gutterFixtures
    check gutterFixtures >= 4

suite "P3 width maths (catalogue §4.1)":
  test "test_section_box_is_width_less_padding_and_borders":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("padding", "8px 12px 16px 40px"),
      ("border", "3px solid #111111")])
    discard solved(doc)
    check doc.layout.box == 600
    check s.layout.container == 600
    check s.layout.outer == 600
    check s.layout.padding == [8, 12, 16, 40]
    check s.layout.border == [3, 3, 3, 3]
    check s.layout.box == 600 - 12 - 40 - 3 - 3

  test "test_section_defaults_and_implicit_column":
    # Default section padding `space.section` (24px 0); content directly
    # in it sits in the implicit column's box (`space.gutter`, 0 24px).
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    let p = r.child(s, "p")
    discard solved(doc)
    check s.layout.padding == [24, 0, 24, 0]
    check s.layout.box == 600
    check contentBox(p) == 600
    check defaultColumnPadding(defaultTheme()) == [0, 24, 0, 24]

  test "test_document_width_and_target_set_the_context":
    let r = EmailRenderer()
    let doc = newDoc(r)
    r.setStyle(doc, "width", "640px")
    let s = r.child(doc, "mailSection", [("padding", "0")])
    discard solved(doc)
    check s.layout.outer == 640
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2)
    let s2 = r2.child(doc2, "mailSection", [("padding", "0")])
    var t = defaultTarget()
    t.containerWidth = 680
    discard solved(doc2, t)
    check s2.layout.outer == 680

  test "test_wrapper_box_is_its_sections_context":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let w = r.child(doc, "mailWrapper", [("padding", "16px 20px"),
      ("border", "1px solid #cccccc")])
    let s = r.child(w, "mailSection", [("padding", "0 10px")])
    discard solved(doc)
    check w.layout.padding == [16, 20, 16, 20]
    check w.layout.box == 600 - 40 - 2
    check s.layout.outer == 558
    check s.layout.box == 538

  test "test_columns_round_on_their_own":
    # B = 590: thirds are 196.67 px; each rounds to 197 (sum 591), as
    # MJML does: no remainder is moved onto the last column.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("padding", "0 5px")])
    var cols: seq[EmailNode] = @[]
    for i in 0 .. 2:
      cols.add(r.child(s, "mailColumn"))
    discard solved(doc)
    for c in cols:
      check c.layout.outer == 197
      check c.layout.className == "e-col-33-333333"
      check abs(c.layout.percent - 100.0 / 3.0) < 1e-9

  test "test_column_px_and_percent_widths_and_boxes":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("padding", "10px 20px")])
    let a = r.child(s, "mailColumn", [("width", "40%"), ("padding", "0 8px")])
    let b = r.child(s, "mailColumn", [("width", "200px"),
      ("border", "2px solid #000000")])
    let g = r.child(s, "mailGroup", [("width", "25%")])
    let c = r.child(g, "mailColumn")
    let d = r.child(g, "mailColumn", [("width", "30%")])
    discard solved(doc)
    check a.layout.outer == 224
    check a.layout.box == 224 - 16
    check a.layout.className == "e-col-40"
    check b.layout.outer == 200
    check b.layout.pxWidth
    check b.layout.className == "e-colpx-200"
    # Default column padding (0 24px) plus the border.
    check b.layout.box == 200 - 48 - 4
    check g.layout.outer == 140
    check g.layout.box == 140
    check c.layout.outer == 70
    check d.layout.outer == 42

  test "test_percentages_keep_full_precision":
    # 12.4166% of 600 is 74.4996 px: 74. Rounded to two decimals (12.42%,
    # what the style pass writes inline) it would be 74.52, so 75. The
    # pass reads the value as authored, before the style pass, through
    # the full render too.
    let build = proc(): EmailNode =
      let r = EmailRenderer()
      result = newDoc(r)
      let h = r.createElement("h1")
      r.setTextContent(h, "Layout")
      r.appendChild(result, h)
      let s = r.child(result, "mailSection", [("padding", "0")])
      discard r.child(s, "mailColumn", [("width", "12.4166%")])
      discard r.child(s, "mailColumn", [("width", "87.5834%")])
    let direct = solved(build())
    check direct.children[1].children[0].layout.outer == 74
    let res = renderTree(build())
    let col = res.semantic.children[1].children[0]
    check col.layout.solved
    check col.layout.outer == 74
    check col.styles["width"] == "12.42%"

  test "test_section_mixing_columns_and_content_is_a_nesting_error":
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    discard r.child(s, "mailColumn")
    discard r.child(s, "p")
    let diags = solveLayout(doc, defaultTheme(), defaultTarget())
    check diags.len == 1
    check diags[0].code == codeStructNesting
    check diags[0].severity == sevError
    check "R-LAY-16" in diags[0].rules
    # Negative control: columns alone, or content alone, are clean.
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2)
    let s2 = r2.child(doc2, "mailSection")
    discard r2.child(s2, "mailColumn")
    discard r2.child(s2, "mailColumn")
    let s3 = r2.child(doc2, "mailSection")
    discard r2.child(s3, "p")
    check solveLayout(doc2, defaultTheme(), defaultTarget()).len == 0

  test "test_layout_tokens_and_underscore_spelling":
    # A `tok"…"` padding resolves through the theme; a hand-built tree's
    # underscore spelling reads like the template's CSS name.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection", [("padding", "tok:space.6")])
    let w = r.child(doc, "mailWrapper")
    r.setStyle(w, "border_radius", "4px")
    discard solved(doc)
    check s.layout.padding == [32, 32, 32, 32]
    check s.layout.box == 600 - 64
    check w.layout.padding == [0, 0, 0, 0]

suite "P3 gutters (MJML 5)":
  test "test_gutter_shares_follow_mjml_5":
    # A mailColumns row sits in the implicit column's box (600 - 48 =
    # 552); a 24px gutter between three default columns: each class
    # width loses 2/3 of 24/552 of the row, each Outlook cell keeps its
    # full third, the half-gutters sit on the inner sides only.
    let r = EmailRenderer()
    let doc = newDoc(r)
    let s = r.child(doc, "mailSection")
    let row = r.child(s, "mailColumns")
    var cols: seq[EmailNode] = @[]
    for i in 0 .. 2:
      cols.add(r.child(row, "mailColumn"))
    discard solved(doc)
    check row.layout.box == 552
    check row.layout.gutterPx == 24 # the default, space.5
    for c in cols:
      check c.layout.outer == 184
      check abs(c.layout.deskPercent - 30.434783) < 1e-9
      check c.layout.className == "e-col-30-434783"
      check c.layout.padding == [0, 0, 0, 0] # none of their own
    check cols[0].layout.gutter == [0, 12, 0, 0]
    check cols[1].layout.gutter == [0, 12, 0, 12]
    check cols[2].layout.gutter == [0, 0, 0, 12]
    check cols[0].layout.gutterClass == "e-gutter-3-1-per-4-347826"
    check cols[1].layout.gutterCss == "0 2.173913% 0 2.173913%"
    check cols[0].layout.mobileGap == 0
    check cols[1].layout.mobileGap == 24
    # The column's content box leaves the half-gutters out.
    check cols[1].layout.box == 184 - 24
    # px columns and an odd gutter: 25 · 2/3 off each, floored, the
    # remainder (round(3 · 1/3) = 1 px) to the first column.
    let r2 = EmailRenderer()
    let doc2 = newDoc(r2)
    let row2 = r2.child(r2.child(doc2, "mailSection"), "mailColumns")
    r2.setAttribute(row2, "gutter", "25px")
    var px: seq[EmailNode] = @[]
    for w in ["185px", "184px", "183px"]:
      px.add(r2.child(row2, "mailColumn", [("width", w)]))
    discard solved(doc2)
    check px[0].layout.deskPx == 169
    check px[1].layout.deskPx == 167
    check px[2].layout.deskPx == 166
    check px[0].layout.gutter == [0, 13, 0, 0]
    check px[1].layout.gutter == [0, 13, 0, 12]
    check px[2].layout.gutter == [0, 0, 0, 12]
    check px[1].layout.gutterCss == "0 13px 0 12px"
    # Right to left (the document's direction): mirrored.
    let r3 = EmailRenderer()
    let doc3 = newDoc(r3)
    r3.setAttribute(doc3, "dir", "rtl")
    let row3 = r3.child(r3.child(doc3, "mailSection"), "mailColumns")
    r3.setAttribute(row3, "gutter", "25px")
    let a = r3.child(row3, "mailColumn")
    let b = r3.child(row3, "mailColumn")
    discard solved(doc3)
    check a.layout.gutter == [0, 0, 0, 13]
    check b.layout.gutter == [0, 12, 0, 0]
    check a.layout.gutterClass.endsWith("-rtl")
    # Negative control: a section's own columns have no gutter.
    let r4 = EmailRenderer()
    let doc4 = newDoc(r4)
    let s4 = r4.child(doc4, "mailSection")
    let c4 = r4.child(s4, "mailColumn")
    discard r4.child(s4, "mailColumn")
    discard solved(doc4)
    check s4.layout.gutterPx == 0
    check c4.layout.gutter == [0, 0, 0, 0]
    check c4.layout.deskPercent == 50.0
    check c4.layout.gutterClass == ""
