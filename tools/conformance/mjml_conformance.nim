## tools/conformance/mjml_conformance.nim — `just test-conformance`.
##
## Checks this library's Outlook geometry against MJML 5's for the
## conformance fixtures (`tests/conformance/fixtures.nim`). Only what
## classic Outlook shows is compared, never markup or bytes: this
## library is div-first and MJML puts a table inside every column, so
## their non-Outlook markup differs on purpose. For each fixture:
##
## 1. its MJML twin is compiled by the pinned MJML (`$ISONIM_EMAIL_MJML`,
##    from the dev shell; nothing is fetched) at strict validation;
## 2. **solver**: the layout pass's widths (ghost-table widths, column
##    and group Outlook px widths, their responsive class widths) equal
##    the ones MJML emits, in document order;
## 3. **geometry** (fixtures whose lowering exists): the Word-engine
##    view of both documents (`tests/conformance/geometry.nim`) has the
##    same ghost-table tree (px widths, centring, backgrounds), the same
##    full-bleed bands, the same content box for every marker leaf (left
##    edge, width, vertical insets, background), and the same
##    responsive class widths other than 100%;
## 4. **recorded widths**: `tests/conformance/mjml_widths.json`, which
##    the unit test `test_width_solver_matches_mjml` reads, still equals
##    what MJML emits now. `--record` rewrites it from MJML's output (a
##    deliberate change, reviewed like a golden).
##
## Outputs land in `build/conformance/` (`<fixture>.mjml`,
## `mjml/<fixture>.html`, `ours/<fixture>.html`, `report.txt`). Exit 0
## when every check passes, 1 otherwise, 2 on a usage or setup error.
##
## C backend only: it writes files and runs MJML.

import std/[json, math, os, osproc, strutils, tables]
import isonim_email
import conformance/fixtures
import conformance/geometry

const widthsPath = "tests/conformance/mjml_widths.json"

proc factJson(f: WidthFact): JsonNode =
  result = %*{"kind": f.kind, "px": f.px}
  if f.responsive.len > 0:
    result["responsive"] = %f.responsive

proc responsiveValue(s: string): tuple[unit: string; value: float] =
  if s.endsWith("%"):
    ("%", parseFloat(s[0 ..< ^1]))
  elif s.endsWith("px"):
    ("px", parseFloat(s[0 ..< ^2]))
  else:
    ("", 0.0)

proc sameFacts*(ours, mjml: seq[WidthFact]; why: var seq[string]): bool =
  ## Tables equal in px; cells equal to MJML's px rounded (MJML writes a
  ## group's cell unrounded, `183.33px`; the ghost cell's attribute is a
  ## whole number); responsive widths equal to 1e-5 %.
  if ours.len != mjml.len:
    why.add("solver: " & $ours.len & " facts, MJML " & $mjml.len)
    return false
  result = true
  for i in 0 ..< ours.len:
    let (a, b) = (ours[i], mjml[i])
    if a.kind != b.kind:
      why.add("solver #" & $i & ": " & a.kind & " vs MJML " & b.kind)
      result = false
      continue
    if a.px != round(b.px):
      why.add("solver #" & $i & " (" & a.kind & "): " & $a.px &
        " px vs MJML " & $b.px)
      result = false
    if a.kind == "cell":
      let (ua, va) = responsiveValue(a.responsive)
      let (ub, vb) = responsiveValue(b.responsive)
      if ua != ub or abs(va - vb) > 1e-5:
        why.add("solver #" & $i & " class width " & a.responsive &
          " vs MJML " & b.responsive)
        result = false

proc sameGeometry(ours, mjml: Geometry; why: var seq[string]): bool =
  result = true
  if ours.ghostTree != mjml.ghostTree:
    why.add("ghost tables " & ours.ghostTree & " vs MJML " & mjml.ghostTree)
    result = false
  if ours.bleeds != mjml.bleeds:
    why.add("full-bleed " & $ours.bleeds & " vs MJML " & $mjml.bleeds)
    result = false
  # Class widths compare as numbers, to 1e-5 as the solver check does:
  # MJML writes a default column's width unnormalised
  # (`33.333333333333336%`), this library to six decimals.
  var sameResponsive = ours.responsive.len == mjml.responsive.len
  if sameResponsive:
    for i in 0 ..< ours.responsive.len:
      let (ua, va) = responsiveValue(ours.responsive[i])
      let (ub, vb) = responsiveValue(mjml.responsive[i])
      if ua != ub or abs(va - vb) > 1e-5:
        sameResponsive = false
  if not sameResponsive:
    why.add("responsive widths " & $ours.responsive & " vs MJML " &
      $mjml.responsive)
    result = false
  var theirs = initTable[string, Leaf]()
  for l in mjml.leaves:
    theirs[l.marker] = l
  if ours.leaves.len != mjml.leaves.len:
    why.add($ours.leaves.len & " leaves vs MJML " & $mjml.leaves.len)
    result = false
  for l in ours.leaves:
    if l.marker notin theirs:
      why.add(l.marker & " missing from MJML's output")
      result = false
      continue
    let m = theirs[l.marker]
    if abs(l.x - m.x) > 0.01 or abs(l.width - m.width) > 0.01 or
        l.top != m.top or l.bottom != m.bottom or
        l.background != m.background:
      why.add(l.marker & ": x " & $l.x & " w " & $l.width & " insets " &
        $l.top & "/" & $l.bottom & " bg " & l.background & " vs MJML x " &
        $m.x & " w " & $m.width & " insets " & $m.top & "/" & $m.bottom &
        " bg " & m.background)
      result = false
  if ours.leaves.len == 0:
    why.add("no leaves found: the comparison would be vacuous")
    result = false

proc main(): int =
  let args = commandLineParams()
  let record = "--record" in args
  let mjml = getEnv("ISONIM_EMAIL_MJML")
  if mjml.len == 0 or not fileExists(mjml):
    stderr.writeLine("test-conformance: $ISONIM_EMAIL_MJML does not name " &
      "the pinned MJML CLI ('" & mjml & "'); run inside the dev shell")
    return 2
  let outDir = "build" / "conformance"
  removeDir(outDir)
  createDir(outDir / "mjml")
  createDir(outDir / "ours")
  let fixtures = conformanceFixtures()
  var inputs: seq[string] = @[]
  for f in fixtures:
    let path = outDir / f.name & ".mjml"
    writeFile(path, toMjml(f.build()))
    inputs.add(path)
  # One MJML process for the whole set, strict validation: a fixture
  # MJML would reject is a broken fixture, not a pass.
  let cmd = quoteShell(mjml) & " " & inputs.quoteShellCommand() &
    " --config.validationLevel=strict -o " & quoteShell(outDir / "mjml" & "/")
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    stderr.writeLine("test-conformance: MJML failed (exit " & $code & "):\n" &
      output)
    return 1

  var report: seq[string] = @[]
  var failures = 0
  var recorded = newJObject()
  var expected = newJObject()
  if fileExists(widthsPath):
    expected = parseFile(widthsPath)
  for f in fixtures:
    let theirsHtml = readFile(outDir / "mjml" / f.name & ".html")
    let theirFacts = widthFactsOfMjml(theirsHtml)
    var arr = newJArray()
    for fact in theirFacts:
      arr.add(factJson(fact))
    recorded[f.name] = arr

    var why: seq[string] = @[]
    # Solver: the layout pass over a fresh tree.
    let solved = f.build()
    discard solveLayout(solved, defaultTheme(), defaultTarget())
    let ourFacts = widthFacts(solved)
    var ok = sameFacts(ourFacts, theirFacts, why)
    if theirFacts.len == 0:
      why.add("MJML's output yielded no width facts: vacuous")
      ok = false
    # Geometry: the full render, Outlook output on.
    if f.lowered:
      let res = renderTree(f.build())
      writeFile(outDir / "ours" / f.name & ".html", res.html)
      if hasErrors(res.diagnostics):
        for d in res.diagnostics:
          if d.severity == sevError:
            why.add("render error: " & $d)
        ok = false
      if not sameGeometry(geometryOf(res.html), geometryOf(theirsHtml), why):
        ok = false
    # Recorded widths.
    if not record and (not expected.hasKey(f.name) or
        expected[f.name] != arr):
      why.add("recorded widths in " & widthsPath & " differ from MJML's " &
        "(re-record deliberately with --record)")
      ok = false
    let what = if f.lowered: "solver+geometry" else: "solver"
    report.add((if ok: "PASS " else: "FAIL ") & f.name & " (" & what &
      ", " & $theirFacts.len & " width facts): " & f.description)
    for w in why:
      report.add("     " & w)
    if not ok:
      inc failures
  if record:
    writeFile(widthsPath, pretty(recorded) & "\n")
    report.add("recorded " & widthsPath)
  let (version, _) = execCmdEx(quoteShell(mjml) & " --version")
  let summary = "test-conformance: " & $(fixtures.len - failures) & "/" &
    $fixtures.len & " fixtures conform to MJML (" &
    version.strip().replace("\n", ", ") & ")"
  report.add(summary)
  writeFile(outDir / "report.txt", report.join("\n") & "\n")
  echo report.join("\n")
  if failures > 0: 1 else: 0

when isMainModule:
  quit(main())
