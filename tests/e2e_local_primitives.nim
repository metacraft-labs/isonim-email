## E2e: where the layout primitives put their items in a real engine.
##
## Renders clusters, grids and sidebars and measures them in the pinned
## Chromium through backend A's emulations (`tools/capture/
## column_geometry.ts`: the raw engine for a client with head CSS,
## `ganga` for one without any `<style>`, `wordApprox` for Word's ghost
## tables), each item painted a colour of its own and found by it.
##
## - `e2e_local_cluster_wraps_without_css`: a 9-item cluster that fits
##   one line on a desktop wraps onto several under ganga at 320px and
##   keeps every item on one line
##   under wordApprox, at a desktop and at a phone width (Word never
##   wraps a table row).
## - `e2e_local_grid_rows`: a 5-item 3-up grid lays out 3 + 2 on a
##   desktop with and without CSS and in Word, one item per row on a
##   phone with head CSS, and without CSS on a phone as many as fit at
##   their `min_item` (one at 160px, three at 72px); a 4-up grid with two per row on a phone goes
##   2 + 2 there and never 1-up, even without CSS.
## - `e2e_local_sidebar_valign_proxy`: the local proxy of the Word
##   check that an image-only cell sits vertically centred against
##   three lines of text (R-TBL-07): the `&zwnj;` follows the image
##   inside an Outlook conditional, and the image is centred on the
##   text's height with head CSS and without it (the cells' `valign`
##   attributes carry it). Chromium honours `valign` whether or not the
##   `&zwnj;` is there, so this proves the centring the lowering asks
##   for, not Word's need for the character; the Word capture itself
##   waits for a classic Outlook client. wordApprox is not measured: it
##   reveals the `&zwnj;` after an image Chromium lays out as a block,
##   which opens a line under it that Word, which lays images out
##   inline, does not have.
##
## No test doubles: the real library, the real transforms, the real
## pinned browser (allowed_mocks: None). C-only: writes files and spawns
## node. A missing node or browser tree fails loudly instead of
## skipping.
import std/[json, os, osproc, strutils, unittest]
import isonim_email

const repoRoot = parentDir(parentDir(currentSourcePath()))
const colours = ["#fde68a", "#bfdbfe", "#bbf7d0", "#fecaca", "#e9d5ff",
  "#fed7aa", "#a5f3fc", "#d9f99d", "#fbcfe8"]

proc requireTools() =
  if findExe("node").len == 0:
    raise newException(OSError, "node not found on PATH — refusing to " &
      "skip (allowed_mocks: None). Run under the dev shell.")
  let dir = getEnv("PLAYWRIGHT_BROWSERS_PATH")
  if dir.len == 0 or not dirExists(dir):
    raise newException(OSError, "PLAYWRIGHT_BROWSERS_PATH is not set to " &
      "a readable directory — refusing to skip (allowed_mocks: None).")

proc child(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  r.appendChild(parent, result)

proc newDoc(r: EmailRenderer): (EmailNode, EmailNode) =
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Primitives")
  discard r.child(doc, "h1", text = "Primitives")
  (doc, r.child(doc, "mailSection"))

proc clusterDoc(): EmailNode =
  let r = EmailRenderer()
  let (doc, s) = newDoc(r)
  let c = r.child(s, "mailCluster")
  for i in 0 ..< 9:
    discard r.child(c, "a", [("background-color", colours[i]),
      ("display", "inline-block"), ("padding", "8px 12px")],
      [("href", "https://example.com/" & $i)], text = "N" & $(i + 1))
  doc

proc gridDoc(columns, mobile, count: int; minItem = ""): EmailNode =
  let r = EmailRenderer()
  let (doc, s) = newDoc(r)
  var attrs = @[("columns", $columns), ("mobile_columns", $mobile)]
  if minItem.len > 0:
    attrs.add(("min_item", minItem))
  let g = r.child(s, "mailGrid", attrs = attrs)
  for i in 0 ..< count:
    let b = r.child(g, "mailBox", [("background-color", colours[i]),
      ("padding", "8px")])
    discard r.child(b, "p", [("margin", "0")], text = "Item " & $(i + 1))
  doc

proc sidebarDoc(): EmailNode =
  let r = EmailRenderer()
  let (doc, s) = newDoc(r)
  let sb = r.child(s, "mailSidebar", attrs = [("fixed", "64px")])
  # The image is found by its colour: a block with a background,
  # standing in for the picture (no network in captures). It sits in a
  # link, so the side itself paints nothing (a side that paints a
  # background and holds no text would paint its whole cell).
  let link = r.child(sb, "a", attrs = [("href", "https://example.com/ada")])
  discard r.child(link, "mailImage", [("width", "64px"), ("height", "64px"),
    ("background-color", colours[0])],
    [("src", "https://img.example.com/avatar.png"), ("alt", ""),
      ("decorative", "true")])
  let text = r.child(sb, "div", [("background-color", colours[1])])
  discard r.child(text, "p", [("margin", "0"), ("line-height", "24px")],
    text = "Ada Lovelace")
  discard r.child(text, "p", [("margin", "0"), ("line-height", "24px")],
    text = "Analyst of the engine")
  discard r.child(text, "p", [("margin", "0"), ("line-height", "24px")],
    text = "London")
  doc

type Box = tuple[x, y, w, h: float]

proc boxes(m: JsonNode): seq[Box] =
  for c in m["columns"]:
    if c.kind == JObject:
      result.add((c["x"].getFloat(), c["y"].getFloat(),
        c["width"].getFloat(), c["height"].getFloat()))

proc lines(b: seq[Box]): int =
  ## How many lines the boxes sit on (a new line starts below the last).
  var top = -1e9
  for x in b:
    if x.y > top + 2:
      inc result
      top = x.y

proc rowsOf(b: seq[Box]): seq[int] =
  ## Items per line, in order.
  var top = -1e9
  for x in b:
    if x.y > top + 2:
      result.add(0)
      top = x.y
    inc result[^1]

proc measureAll(docs: openArray[(string, EmailNode)]; families,
    viewports: string): JsonNode =
  let dir = repoRoot / "build" / ("e2e-primitives-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  try:
    for (name, doc) in docs:
      let res = renderTree(doc)
      for d in res.diagnostics:
        doAssert d.severity != sevError, name & ": " & $d
      writeFile(dir / name & ".html", res.html)
    let outFile = dir / "geometry.json"
    let cmd = "node tools/capture/column_geometry.ts " & quoteShell(dir) &
      " " & quoteShell(outFile) & " --colours " &
      quoteShell(colours.join(",")) & " --families " & families &
      " --viewports " & viewports
    let (output, code) = execCmdEx(cmd, workingDir = repoRoot)
    doAssert code == 0, "column_geometry failed:\n" & output
    result = parseJson(readFile(outFile))
  finally:
    removeDir(dir)

proc find(all: JsonNode; file, family: string; viewport: int): seq[Box] =
  for m in all:
    if m["file"].getStr() == file & ".html" and
        m["family"].getStr() == family and m["viewport"].getInt() == viewport:
      return boxes(m)
  doAssert false, "no measurement for " & file & " " & family & " " &
    $viewport

suite "e2e: layout primitives in a real engine":
  test "e2e_local_cluster_wraps_without_css":
    requireTools()
    let all = measureAll([("cluster", clusterDoc())],
      "chromium-baseline,ganga,wordApprox", "320,800")
    let ganga320 = find(all, "cluster", "ganga", 320)
    check ganga320.len == 9
    checkpoint("ganga 320: " & $rowsOf(ganga320))
    check lines(ganga320) >= 2
    # Items keep their order, wrapping left to right, top to bottom.
    for i in 1 ..< ganga320.len:
      check ganga320[i].y > ganga320[i - 1].y + 2 or
        ganga320[i].x > ganga320[i - 1].x
    # Never wider than the viewport without CSS.
    for m in all:
      if m["family"].getStr() == "ganga":
        check m["scrollWidth"].getInt() <= m["viewport"].getInt()
    # The gap between neighbours on a line: 12px (the default, space.3).
    check abs(ganga320[1].x - (ganga320[0].x + ganga320[0].w) - 12) <= 1
    # Word: one line, whatever the width.
    for vw in [320, 800]:
      let word = find(all, "cluster", "wordApprox", vw)
      checkpoint("wordApprox " & $vw & ": " & $rowsOf(word))
      check word.len == 9
      check lines(word) == 1
    # Head CSS at 800px: one line; at 320px it wraps as without CSS.
    check lines(find(all, "cluster", "chromium-baseline", 800)) == 1
    check lines(find(all, "cluster", "chromium-baseline", 320)) >= 2

  test "e2e_local_grid_rows":
    requireTools()
    let all = measureAll([("grid3", gridDoc(3, 1, 5)),
      ("grid4x2", gridDoc(4, 2, 4, "72px")),
      ("grid3small", gridDoc(3, 1, 5, "72px"))],
      "chromium-baseline,ganga,wordApprox", "375,800")
    for family in ["chromium-baseline", "ganga", "wordApprox"]:
      let desk = find(all, "grid3", family, 800)
      checkpoint(family & " grid3 800: " & $rowsOf(desk))
      check rowsOf(desk) == @[3, 2]
      # The gutter between neighbours and between rows: 24px.
      check abs(desk[1].x - (desk[0].x + desk[0].w) - 24) <= 1
      check abs(desk[3].y - (desk[0].y + desk[0].h) - 24) <= 1
      # The last row's items line up with the columns above.
      check abs(desk[3].x - desk[0].x) <= 1 and abs(desk[4].x - desk[1].x) <= 1
    # A phone with head CSS: one per row, full width, 24px apart.
    let phone = find(all, "grid3", "chromium-baseline", 375)
    check rowsOf(phone) == @[1, 1, 1, 1, 1]
    for b in phone:
      check abs(b.w - phone[0].w) <= 1
    check phone[0].w > 300
    # Without CSS: items keep their share of the row down to `min_item`
    # (160px by default), then wrap: one per row here, at their minimum.
    let noCss = find(all, "grid3", "ganga", 375)
    check rowsOf(noCss) == @[1, 1, 1, 1, 1]
    check noCss[0].w < 200
    # With a 72px minimum the items shrink with the row and stay 3 up.
    check rowsOf(find(all, "grid3small", "ganga", 375)) == @[3, 2]
    # Four columns, two on a phone: 4-up, then 2 + 2, never 1-up.
    check rowsOf(find(all, "grid4x2", "chromium-baseline", 800)) == @[4]
    check rowsOf(find(all, "grid4x2", "wordApprox", 800)) == @[4]
    check rowsOf(find(all, "grid4x2", "chromium-baseline", 375)) == @[2, 2]
    check rowsOf(find(all, "grid4x2", "ganga", 375)) == @[2, 2]
    check rowsOf(find(all, "grid4x2", "ganga", 800)) == @[2, 2]
    # Nothing overflows a phone.
    for m in all:
      if m["viewport"].getInt() == 375 and m["family"].getStr() != "wordApprox":
        check m["scrollWidth"].getInt() <= 375

  test "e2e_local_sidebar_valign_proxy":
    requireTools()
    let doc = sidebarDoc()
    let html = renderTree(doc).html
    check "<!--[if mso]>&zwnj;<![endif]-->" in html
    let all = measureAll([("sidebar", doc)],
      "chromium-baseline,ganga", "800")
    for family in ["chromium-baseline", "ganga"]:
      let b = find(all, "sidebar", family, 800)
      check b.len == 2
      let (img, text) = (b[0], b[1])
      checkpoint(family & ": image " & $img & ", text " & $text)
      # Three 24px lines beside a 64px image: the text is the taller,
      # and the image's centre is on the text's centre.
      check text.h >= 72
      check abs((img.y + img.h / 2) - (text.y + text.h / 2)) <= 2
      # Side by side: the image, the 16px gap, then the text.
      check abs(text.x - (img.x + img.w) - 16) <= 1
