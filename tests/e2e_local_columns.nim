## E2e: where the column strategies put their columns in real engines.
##
## Renders 2- and 3-column rows of every `mailColumns` strategy, and
## the multi-column sections a template writes most, then measures them
## in the pinned Chromium through backend A's emulations
## (`tools/capture/column_geometry.ts`: the raw engine for a client with
## head CSS, `ganga` for one without any `<style>`, `wordApprox` for
## Word's ghost tables), at a phone and a desktop width. Each column is
## painted a colour of its own and found by it. Text lengths differ per
## column, so a row whose columns do not share a height shows it.
##
## - `test_column_strategy_matrix`: the documented behaviour of each
##   strategy (patterns, catalogue R-LAY-01, R-LAY-18…20): which rows
##   stack where, which keep equal heights. Negative control: a hybrid
##   row side by side has unequal heights, a cells row equal ones.
## - `e2e_local_columns_stack_without_head_css`: with every `<style>`
##   removed (ganga), multi-column sections stack to the full width of
##   their row at both widths and nothing overflows the phone viewport.
##
## No test doubles: the real library, the real transforms, the real
## pinned browser (allowed_mocks: None). C-only: writes files and spawns
## node. A missing node or browser tree fails loudly instead of
## skipping.
import std/[json, os, osproc, strutils, unittest]
import isonim_email

const repoRoot = parentDir(parentDir(currentSourcePath()))
const colours = ["#fde68a", "#bfdbfe", "#bbf7d0"]
const texts = [
  "The first column carries the longest text of the row, so that it " &
    "wraps over several lines at every width the test looks at and " &
    "stands taller than its neighbours whenever they share a line.",
  "Short.",
  "A middle length text that wraps once or twice."]

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
    attrs: openArray[(string, string)] = []): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  r.appendChild(parent, result)

proc newDoc(r: EmailRenderer): EmailNode =
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", "en")
  r.setAttribute(result, "dir", "ltr")
  r.setAttribute(result, "title", "Columns")
  let h = r.child(result, "h1")
  r.setTextContent(h, "Columns")

proc fill(r: EmailRenderer; col: EmailNode; i: int) =
  let p = r.child(col, "p", [("margin", "0")])
  r.setTextContent(p, texts[i])

proc strategyDoc(strategy: string; n: int): EmailNode =
  let r = EmailRenderer()
  result = newDoc(r)
  let row = r.child(r.child(result, "mailSection"), "mailColumns",
    attrs = [("strategy", strategy), ("gutter", "16px"),
      ("min_column", "72px")])
  for i in 0 ..< n:
    r.fill(r.child(row, "mailColumn", [("background-color", colours[i]),
      ("padding", "8px")]), i)

proc sectionDoc(n: int): EmailNode =
  ## A section's own columns (the shorthand), as templates write them.
  let r = EmailRenderer()
  result = newDoc(r)
  let s = r.child(result, "mailSection")
  for i in 0 ..< n:
    r.fill(r.child(s, "mailColumn", [("background-color", colours[i])]), i)

type Box = tuple[x, y, w, h: float]

proc boxes(m: JsonNode): seq[Box] =
  ## The boxes of the colours found, in colour (source) order; a
  ## fixture with fewer columns leaves the later colours unfound.
  for c in m["columns"]:
    if c.kind == JObject:
      result.add((c["x"].getFloat(), c["y"].getFloat(),
        c["width"].getFloat(), c["height"].getFloat()))

proc stacked(b: seq[Box]; tolerance = 2.0): bool =
  ## Every column under the previous one, left edges aligned to
  ## `tolerance` px.
  for i in 1 ..< b.len:
    if b[i].y < b[i - 1].y + b[i - 1].h - 1 or
        abs(b[i].x - b[0].x) > tolerance:
      return false
  true

proc sideBySide(b: seq[Box]): bool =
  ## Every column on the first one's line, left to right.
  for i in 1 ..< b.len:
    if abs(b[i].y - b[0].y) > 2 or b[i].x <= b[i - 1].x + b[i - 1].w - 1:
      return false
  true

proc equalHeights(b: seq[Box]): bool =
  for x in b:
    if abs(x.h - b[0].h) > 1:
      return false
  true

proc measureAll(docs: openArray[(string, EmailNode)];
    families: string): JsonNode =
  ## Renders the documents into a run directory of their own, measures
  ## them at 375 and 800 px, and removes the directory again.
  let dir = repoRoot / "build" / ("e2e-columns-" & $getCurrentProcessId())
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
      quoteShell(colours.join(",")) &
      " --families " & families & " --viewports 375,800"
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

suite "e2e: column strategies in a real engine":
  test "test_column_strategy_matrix":
    requireTools()
    var docs: seq[(string, EmailNode)] = @[]
    for strategy in ["hybrid", "fabFour", "cellsStacking", "cells"]:
      for n in [2, 3]:
        docs.add((strategy & "-" & $n, strategyDoc(strategy, n)))
    let all = measureAll(docs, "chromium-baseline,ganga,wordApprox")
    check all.len == 8 * 3 * 2
    # Stacking: S = stacked, R = side by side, per (family, viewport).
    const expected = [
      # strategy,       head CSS 375, 800; ganga 375, 800; Word 800
      ("hybrid", "SRSSR"),
      ("fabFour", "SRSRR"),
      ("cellsStacking", "SRRRR"),
      ("cells", "RRRRR")]
    for (strategy, want) in expected:
      for n in [2, 3]:
        let name = strategy & "-" & $n
        let views = [find(all, name, "chromium-baseline", 375),
          find(all, name, "chromium-baseline", 800),
          find(all, name, "ganga", 375), find(all, name, "ganga", 800),
          find(all, name, "wordApprox", 800)]
        for i, b in views:
          checkpoint(name & ", view " & $i & " (" & $want[i] & "): " & $b)
          check b.len == n
          if want[i] == 'S':
            # Without CSS a stacked Fab Four column keeps its inner
            # half-gutters (8px here): the declared degradation.
            let tolerance = if strategy == "fabFour" and i == 2: 9.0
              else: 2.0
            check stacked(b, tolerance)
          else:
            check sideBySide(b)
            # Equal heights are what the cell strategies promise, side
            # by side, in every view; inline-block columns are ragged.
            if strategy in ["cells", "cellsStacking"]:
              check equalHeights(b)
            else:
              check not equalHeights(b)
    # The negative control, spelt out: side by side on a desktop with
    # head CSS, a hybrid row is ragged and a cells row is not.
    check not equalHeights(find(all, "hybrid-2", "chromium-baseline", 800))
    check equalHeights(find(all, "cells-2", "chromium-baseline", 800))

  test "e2e_local_columns_stack_without_head_css":
    requireTools()
    let docs = [("section-2", sectionDoc(2)), ("section-3", sectionDoc(3)),
      ("row-2", strategyDoc("hybrid", 2)), ("row-3", strategyDoc("hybrid", 3))]
    let all = measureAll(docs, "ganga")
    check all.len == 4 * 2
    for m in all:
      let b = boxes(m)
      let vw = float(m["viewport"].getInt())
      check b.len == (if m["file"].getStr().endsWith("-3.html"): 3 else: 2)
      check stacked(b)
      # Full width: each column spans its row (the section's content
      # box: the whole band for a section's own columns, less the
      # implicit column's 24px each side for a mailColumns row).
      let full = if m["file"].getStr().startsWith("section"): min(vw, 600.0)
        else: min(vw, 600.0) - 48
      for x in b:
        check abs(x.w - full) <= 1
      # Readable: nothing wider than the viewport.
      check m["scrollWidth"].getInt() <= m["viewport"].getInt()
