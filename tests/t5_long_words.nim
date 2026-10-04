# rule: R-TBL-17
## Long unbroken words where head CSS is stripped (catalogue R-TBL-17):
## the reset's `table-layout:fixed` is written inline on every layout
## table outside Outlook conditionals that has a width of its own, the
## document's wrapper table included, so an auto-layout table cannot
## grow to a long word and widen the message; a data table keeps its own
## automatic layout, and a `mailCluster` item is capped at its line.
## `tests/e2e_local_overflow_320.nim` measures the effect in a browser.
##
## Backend-independent (tree building + pure passes + string work), so
## `just test` also runs it on JS. No test doubles.
import std/[strutils, unittest]
import isonim_email

proc el(r: EmailRenderer; parent: EmailNode; tag: string;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

const longWord = "Supercalifragilisticexpialidociousnessless"

proc withoutMso(html: string): string =
  ## `html` with every Outlook conditional block removed.
  var i = 0
  while i < html.len:
    let a = html.find("<!--[if mso", i)
    if a < 0:
      result.add(html[i .. ^1])
      break
    result.add(html[i ..< a])
    let b = html.find("<![endif]-->", a)
    i = if b < 0: html.len else: b + "<![endif]-->".len

proc tableTags(html: string): seq[string] =
  var i = 0
  while true:
    let a = html.find("<table", i)
    if a < 0:
      break
    let b = html.find(">", a)
    result.add(html[a .. b])
    i = b + 1

proc docWithEverything(): EmailNode =
  let r = EmailRenderer()
  result = r.el(nil, "mailDocument", [("lang", "en"), ("dir", "ltr"),
    ("title", "Long words")])
  let s = r.el(result, "mailSection")
  discard r.el(s, "h1", text = "Long words")
  discard r.el(s, "p", text = "Reference " & longWord & ".")
  discard r.el(r.el(s, "mailBox"), "p", text = longWord)
  let sb = r.el(s, "mailSidebar", [("fixed", "64px")])
  discard r.el(sb, "p", text = "Side")
  discard r.el(sb, "p", text = longWord)
  let row = r.el(s, "mailColumns", [("strategy", "cells")])
  for i in 0 .. 1:
    discard r.el(r.el(row, "mailColumn"), "p", text = "Cell " & $i)
  let t = r.el(s, "mailTable", [("caption", "Data")])
  let tr = r.el(r.el(t, "table"), "tr")
  discard r.el(tr, "td", text = longWord)
  discard r.el(s, "mailButton", [("href", "https://example.com/"),
    ("align", "left")], text = "Open")
  let c = r.el(s, "mailCluster")
  for l in ["One", longWord]:
    discard r.el(c, "a", [("href", "https://example.com/")], text = l)

suite "long words without head CSS":
  test "test_layout_tables_fix_their_layout_inline":
    let res = renderTree(docWithEverything())
    check not hasErrors(res.diagnostics)
    let body = withoutMso(res.html.split("<body")[1])
    let tags = tableTags(body)
    var layout, data = 0
    for tag in tags:
      if "role=\"table\"" in tag:
        # The data table keeps its own automatic layout (R-TBL-18).
        inc data
        check "table-layout:auto !important" in tag
      elif "role=\"presentation\"" in tag and "width=" in tag:
        inc layout
        if "table-layout:fixed" notin tag:
          checkpoint("no fixed layout: " & tag)
        check "table-layout:fixed" in tag
    # Vacuity guard: the wrapper, a box, a sidebar, a cell row and the
    # data table's frame are all there.
    check data == 1
    check layout == 5
    # The document's wrapper table first of all (§1).
    check tags[0].endsWith("style=\"background-color:#ffffff;" &
      "table-layout:fixed;\">")
    # Outlook's ghost tables are Word's alone: untouched.
    for tag in tableTags(res.html):
      if "table-layout" in tag:
        check tag in body

  test "test_cluster_items_are_capped_at_their_line":
    let res = renderTree(docWithEverything())
    let body = res.html.split("<body")[1]
    check body.count("display:inline-block;vertical-align:middle;") == 2
    check body.count("overflow-wrap:break-word;max-width:100%;" &
      "box-sizing:border-box;") == 2
