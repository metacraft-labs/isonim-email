## bench/bench.nim — `just bench`: render, pass, MIME, batch and
## allocation figures in the github-action-benchmark format.
##
## Two modes, chosen by one variable read in one place (`modeFromEnv`):
##
## - **Correctness** (the default; `ISONIM_EMAIL_BENCH_MEASURE` unset or
##   `0`): every story renders once on each path and the bytes are
##   compared; nothing is timed and nothing is written.
## - **Measure** (`ISONIM_EMAIL_BENCH_MEASURE=1`, what `just bench` sets):
##   the figures below, written under `bench-results/`. Any other value
##   is refused: a typo must not read as a quiet run.
##
## `just bench` builds this file twice and runs it in three steps:
##
## 1. `--part=timing` (the release build, `-d:release`): every story's
##    render time, the reference story's render + MIME time, its MIME
##    time alone, the batch rate, and the pre-lowering prototype against
##    the plain path.
## 2. `--part=detail` (the same release build plus
##    `-d:isonimEmailStageTimings -d:nimAllocStats`): per-stage times of
##    the reference story and allocation counts. Its instrumentation
##    would bias the first part's clocks, which is why it is a build of
##    its own.
## 3. `--assemble`: checks both builds wrote the same bytes for every
##    story, writes `benchmark_results.json` (every entry),
##    `benchmark_results_smaller.json` and `benchmark_results_bigger.json`
##    (split on each entry's `better=` token, for a workflow's one `tool:`
##    per file), `report.html`, and compares with the committed baseline
##    (`bench/baseline.json`), writing `comparison.json`.
##
## Method. Every timed figure is wall time from the monotonic clock, in
## the steady state a sender is in: warm-up runs first (the thread's
## caches filled, the images published), then the samples, interleaved
## story by story so a burst of load lands on every story alike rather
## than on one. A figure is the median (p50) and the nearest-rank 95th
## percentile (p95) of its samples, and its `extra` says how many
## samples and of what (`samples=`, `shape=`). The reference story also
## gets the thread's CPU time, which a loaded host inflates far less than
## wall time. Every entry carries the machine's OS and architecture,
## whether it is a reference machine, the host's load averages
## before and after each part and its CPU count; a host whose load per
## CPU stays at or below 0.25 is `host=quiet`, any other `host=loaded`.
## The timing targets are stated for a reference machine, quiet: a
## timing target measured anywhere else reads `…-CONDITION-NOT-external`.
## A reference machine is one whose operator says so, with
## `ISONIM_EMAIL_BENCH_REFERENCE_MACHINE=1` (unset or `0`: not one; any
## other value is refused); the benchmark never reads the host's name,
## and `machine=` is the OS and CPU architecture.
## `--require-quiet-host` refuses to write anything from a loaded host
## (for a dedicated benchmark host). Nothing here fails on a slow
## figure: the figures are recorded, and the comparison with the
## baseline reports a regression beyond `--threshold` (default 1.20)
## without failing unless `--fail-on-regression` is given.

import std/[json, monotimes, os, sequtils, strutils, tables, times]
from std/cpuinfo import countProcessors
when defined(posix):
  import std/posix
import isonim_email
import ./workload
import ./entries

type
  BenchMode = enum
    bmCorrectness, bmMeasure

  Sample = object
    wall, cpu: float ## milliseconds

  Host = object
    loadBefore, loadAfter: float
    cpus: int

  Entry = object
    name, unit: string
    value: float
    extra: string

const
  measureVar = "ISONIM_EMAIL_BENCH_MEASURE"
  partsDir = "parts"

when defined(posix):
  proc getloadavg(loadavg: ptr cdouble; nelem: cint): cint {.importc,
    header: "<stdlib.h>".}

proc load1(): float =
  ## The one-minute load average, or -1 where it cannot be read.
  when defined(posix):
    var la: array[3, cdouble]
    if getloadavg(addr la[0], 3) >= 1:
      return float(la[0])
  -1.0

proc threadCpuMs(): float =
  ## This thread's CPU time, in milliseconds (0 where it cannot be read).
  when defined(posix):
    var ts: Timespec
    if clock_gettime(CLOCK_THREAD_CPUTIME_ID, ts) == 0:
      return float(ts.tv_sec) * 1000.0 + float(ts.tv_nsec) / 1e6
  0.0

proc modeFromEnv(): BenchMode =
  ## The one place the mode is read (see the module comment).
  let v = getEnv(measureVar)
  let m = benchModeOf(v)
  if not m.known:
    stderr.writeLine("bench: " & measureVar & "=" & v & " is not 0 or 1; " &
      "refusing to guess")
    quit(2)
  if m.measure: bmMeasure else: bmCorrectness

proc digestOf(r: RenderedEmail): string =
  sha256Hex(r.html & "\x00" & r.text & "\x00" & packageMime(r))[0 ..< 16]

template timed(body: untyped): Sample =
  let c0 = threadCpuMs()
  let t0 = getMonoTime()
  body
  Sample(wall: float((getMonoTime() - t0).inNanoseconds) / 1e6,
    cpu: threadCpuMs() - c0)

# --- Correctness ---------------------------------------------------------------------

proc correctness(): int =
  ## Every path once, bytes compared; the number of failures.
  for s in benchStories():
    let own = s.plain()
    if own.html.len == 0 or own.text.len == 0:
      stderr.writeLine("FAIL " & s.name & ": empty render")
      inc result
    let mime = packageMime(own)
    if packageMime(own) != mime:
      stderr.writeLine("FAIL " & s.name & ": MIME bytes differ run to run")
      inc result
    let p = s.prelowered(1, false, false)
    let q = s.personalised(1, false, false)
    if packageMime(p.rendered) != packageMime(q):
      stderr.writeLine("FAIL " & s.name & ": pre-lowered (" & $p.path &
        ") and plain messages differ")
      inc result
    stderr.writeLine("ok   " & s.name & " (" & $own.html.len &
      " bytes, recipient 1 via " & $p.path & ")")

# --- Measuring ---------------------------------------------------------------------

proc hostNow(): Host =
  Host(loadBefore: load1(), cpus: countProcessors())

proc samplesFor(quick: bool; full, short: int): int =
  if quick: short else: full

type Part = object
  entries: seq[JsonNode]   ## {name, value, samples, shape}
  digests: Table[string, string]

proc add(p: var Part; name: string; value: float; samples: int;
    shape: string) =
  ## One figure, with the sample count and the shape of one sample (no
  ## defaults: each figure says its own).
  p.entries.add(%*{"name": name, "value": value, "samples": samples,
    "shape": shape})

proc timingPart(quick: bool): Part =
  let stories = benchStories()
  let warm = samplesFor(quick, 5, 2)
  let n = samplesFor(quick, 101, 11)
  # Every story, interleaved.
  var walls = newSeq[seq[float]](stories.len)
  for i, s in stories:
    for _ in 0 ..< warm:
      discard s.plain()
    result.digests[s.name] = digestOf(s.plain())
  for _ in 0 ..< n:
    for i, s in stories:
      let t = timed:
        discard s.plain()
      walls[i].add(t.wall)
  for i, s in stories:
    result.add("render/" & s.name & "/p50", p50(walls[i]), n,
      "one-renderEmail-wall")
    result.add("render/" & s.name & "/p95", p95(walls[i]), n,
      "one-renderEmail-wall")
  # The reference story: render, then MIME, per sample.
  var refStory: BenchStory
  for s in stories:
    if s.name == referenceStory:
      refStory = s
  let refN = samplesFor(quick, 401, 21)
  for _ in 0 ..< samplesFor(quick, 30, 3):
    discard packageMime(refStory.plain())
  var total, totalCpu, mime: seq[float]
  for _ in 0 ..< refN:
    var r: RenderedEmail
    let a = timed:
      r = refStory.plain()
    let b = timed:
      discard packageMime(r)
    total.add(a.wall + b.wall)
    totalCpu.add(a.cpu + b.cpu)
    mime.add(b.wall)
  let r = referenceStory
  result.add("render+mime/" & r & "/p50", p50(total), refN,
    "one-renderEmail+toMessage+toRfc5322-wall")
  result.add("render+mime/" & r & "/p95", p95(total), refN,
    "one-renderEmail+toMessage+toRfc5322-wall")
  result.add("render+mime/" & r & "/cpu-p50", p50(totalCpu), refN,
    "one-renderEmail+toMessage+toRfc5322-thread-cpu")
  result.add("mime/" & r & "/p50", p50(mime), refN,
    "one-toMessage+toRfc5322-wall")
  result.add("mime/" & r & "/p95", p95(mime), refN,
    "one-toMessage+toRfc5322-wall")
  # Batch: personalised messages back to back, one thread.
  let batches = samplesFor(quick, 7, 3)
  let perBatch = samplesFor(quick, 200, 20)
  var rates: seq[float]
  var recipient = 1
  for _ in 0 ..< batches:
    let t = timed:
      for _ in 0 ..< perBatch:
        discard packageMime(refStory.personalised(recipient, false, false))
        inc recipient
    rates.add(float(perBatch) / (t.wall / 1000.0))
  result.add("batch/" & r & "/messages-per-second", p50(rates), batches,
    "batch-of-" & $perBatch & "-personalised-renderEmail+MIME-one-thread")
  # The pre-lowering prototype against the plain path, recipients 1, 2, …
  # (same shape), interleaved; then its first render on a fresh cache.
  let fresh = benchStories()
  var freshRef: BenchStory
  for s in fresh:
    if s.name == referenceStory:
      freshRef = s
  let first = timed:
    discard freshRef.prelowered(0, false, false)
  for k in 1 .. warm:
    discard refStory.prelowered(k, false, false)
    discard refStory.personalised(k, false, false)
  let pn = samplesFor(quick, 201, 21)
  var plainT, skelT: seq[float]
  for k in 1 .. pn:
    var p: tuple[rendered: RenderedEmail; path: PrelowerPath]
    let a = timed:
      p = refStory.prelowered(k, false, false)
    doAssert p.path == ppSkeleton, "recipient " & $k & " took " & $p.path
    let b = timed:
      discard refStory.personalised(k, false, false)
    skelT.add(a.wall)
    plainT.add(b.wall)
  result.add("prelower/" & r & "/plain-p50", p50(plainT), pn,
    "one-personalised-renderEmail-wall")
  result.add("prelower/" & r & "/skeleton-p50", p50(skelT), pn,
    "one-personalised-skeleton-render-wall")
  result.add("prelower/" & r & "/first-render", first.wall, 1,
    "one-first-render-with-classification-and-skeleton-wall")
  # With a per-recipient token in the links, every recipient is a new
  # skeleton key: the prototype renders the plain path and builds a
  # skeleton it never reuses.
  var urlStoryOf: BenchStory
  for s in stories:
    if s.name == urlStory:
      urlStoryOf = s
  for k in 1 .. warm:
    discard urlStoryOf.prelowered(k, false, true)
    discard urlStoryOf.personalised(k, false, true)
  let un = samplesFor(quick, 51, 7)
  var urlPlain, urlPre: seq[float]
  for k in 1 .. un:
    var p: tuple[rendered: RenderedEmail; path: PrelowerPath]
    let a = timed:
      p = urlStoryOf.prelowered(1000 + k, false, true)
    doAssert p.path == ppBuilt, "recipient " & $k & " took " & $p.path
    let b = timed:
      discard urlStoryOf.personalised(1000 + k, false, true)
    urlPre.add(a.wall)
    urlPlain.add(b.wall)
  result.add("prelower/" & urlStory & "/per-recipient-url-plain-p50",
    p50(urlPlain), un, "one-personalised-renderEmail-wall")
  result.add("prelower/" & urlStory & "/per-recipient-url-prelowered-p50",
    p50(urlPre), un, "one-personalised-prototype-render-new-key-wall")
  var onSkeleton = 0
  for s in fresh:
    discard s.prelowered(0, false, false)
    if s.prelowered(1, false, false).path == ppSkeleton:
      inc onSkeleton
  result.add("prelower/reference-set/skeleton-stories", float(onSkeleton),
    1, "count-of-" & $fresh.len & "-stories-whose-recipient-1-took-a-skeleton")

proc detailPart(quick: bool): Part =
  when not (defined(isonimEmailStageTimings) and defined(nimAllocStats)):
    stderr.writeLine("bench: --part=detail needs the detail build " &
      "(-d:isonimEmailStageTimings -d:nimAllocStats)")
    quit(2)
  else:
    let stories = benchStories()
    var refStory: BenchStory
    for s in stories:
      result.digests[s.name] = digestOf(s.plain())
      if s.name == referenceStory:
        refStory = s
    for _ in 0 ..< samplesFor(quick, 20, 3):
      discard refStory.plain()
    let n = samplesFor(quick, 201, 21)
    var per: array[RenderStage, seq[float]]
    var outside: seq[float]
    for _ in 0 ..< n:
      resetStageTimings()
      let t = timed:
        discard refStory.plain()
      var staged = 0.0
      for st in RenderStage:
        per[st].add(float(stageNanos[st]) / 1e6)
        staged += float(stageNanos[st]) / 1e6
      outside.add(t.wall - staged)
    for st in RenderStage:
      result.add("stage/" & referenceStory & "/" & $st & "/p50", p50(per[st]),
        n, "one-stage-of-one-renderEmail-wall")
    # What no stage holds: freeing the intermediate trees and strings as
    # the render returns, and the glue between the stages.
    result.add("stage/" & referenceStory & "/outside-stages/p50",
      p50(outside), n, "one-renderEmail-wall-less-its-stages")
    proc allocs(): int =
      let s = $getAllocStats()
      # `(allocCount: N, deallocCount: M)`
      let a = s.find("allocCount: ")
      parseInt(s[a + "allocCount: ".len ..< s.find(',', a)])
    # Allocation counts are deterministic: three runs must agree.
    var counts: seq[int]
    for _ in 0 ..< 3:
      let before = allocs()
      discard packageMime(refStory.plain())
      counts.add(allocs() - before)
    doAssert counts[0] == counts[1] and counts[1] == counts[2],
      "allocation counts differ run to run: " & $counts
    result.add("alloc/" & referenceStory & "/per-message", float(counts[0]),
      3, "allocations-of-one-renderEmail+MIME-identical-in-3-runs")
    var perKb: Table[int, float]
    for cards in scalingCards:
      let s = digestScaling(cards)
      discard s.plain()
      let before = allocs()
      let r = s.plain()
      let used = allocs() - before
      perKb[cards] = float(used) / (float(r.html.len) / 1024.0)
      result.add("alloc/digestCards" & $cards & "/per-output-KB",
        perKb[cards], 1, "allocations-of-one-renderEmail-per-KB-of-HTML-" &
        $r.html.len & "-bytes")
    result.add("alloc/digestCards17-vs-4/per-KB-ratio", perKb[17] / perKb[4],
      1, "allocations-per-KB-at-17-cards-over-4-cards")

proc writePart(dir, name: string; p: Part; host: Host) =
  var digests = newJObject()
  for k, v in p.digests:
    digests[k] = %v
  let j = %*{"entries": p.entries, "digests": digests,
    "loadBefore": host.loadBefore, "loadAfter": host.loadAfter,
    "cpus": host.cpus}
  createDir(dir / partsDir)
  writeFile(dir / partsDir / (name & ".json"), j.pretty() & "\n")

# --- Assembling ---------------------------------------------------------------------

proc fmt3(x: float): string = formatFloat(x, ffDecimal, 3)

proc htmlEscape(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
    ("\"", "&quot;"))

proc report(entries: seq[Entry]; meta: OrderedTable[string, string];
    comparison: seq[(string, string)]): string =
  ## The self-contained HTML report.
  result = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>isonim-email benchmark</title>
<style>
:root{--bg:#ffffff;--fg:#1f2328;--muted:#59636e;--line:#d1d9e0;--met:#1a7f37;--unmet:#cf222e}
@media (prefers-color-scheme: dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9198a1;--line:#3d444d;--met:#3fb950;--unmet:#f85149}}
body{background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,sans-serif;margin:0 16px 32px;max-width:1100px}
h1{font-size:22px}h2{font-size:17px;margin-top:28px}
table{border-collapse:collapse;width:100%;display:block;overflow-x:auto}
th,td{border-bottom:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.met{color:var(--met)}.unmet{color:var(--unmet)}.muted{color:var(--muted);font-size:12px}
</style></head><body>
<h1>isonim-email benchmark</h1>
"""
  result.add("<table><tbody>\n")
  for k, v in meta:
    result.add("<tr><th>" & htmlEscape(k) & "</th><td>" & htmlEscape(v) &
      "</td></tr>\n")
  result.add("</tbody></table>\n")
  result.add("<h2>Targets</h2><table><thead><tr><th>Entry</th><th>Value" &
    "</th><th>Target</th><th>Verdict</th></tr></thead><tbody>\n")
  for e in entries:
    let x = parseExtra(e.extra)
    if x.getOrDefault("target", "none") != "none":
      let v = x.getOrDefault("verdict")
      let cls = if v.startsWith("met"): "met" else: "unmet"
      result.add("<tr><td>" & htmlEscape(e.name) & "</td><td class=num>" &
        fmt3(e.value) & " " & htmlEscape(e.unit) & "</td><td>" &
        htmlEscape(x["target"]) & "</td><td class=" & cls & ">" &
        htmlEscape(v) & "</td></tr>\n")
  result.add("</tbody></table>\n")
  var groups: OrderedTable[string, seq[Entry]]
  for e in entries:
    let g = e.name.split('/')[0]
    groups.mgetOrPut(g, @[]).add(e)
  for g, es in groups:
    result.add("<h2>" & htmlEscape(g) & "</h2><table><thead><tr><th>Entry" &
      "</th><th>Value</th><th>Provenance</th></tr></thead><tbody>\n")
    for e in es:
      result.add("<tr><td>" & htmlEscape(e.name) & "</td><td class=num>" &
        fmt3(e.value) & " " & htmlEscape(e.unit) & "</td><td class=muted>" &
        htmlEscape(e.extra) & "</td></tr>\n")
    result.add("</tbody></table>\n")
  result.add("<h2>Against the baseline</h2><table><tbody>\n")
  for (k, v) in comparison:
    result.add("<tr><td>" & htmlEscape(k) & "</td><td>" & htmlEscape(v) &
      "</td></tr>\n")
  result.add("</tbody></table>\n</body></html>\n")

proc toJson(es: seq[Entry]): JsonNode =
  result = newJArray()
  for e in es:
    result.add(%*{"name": e.name, "unit": e.unit, "value": e.value,
      "extra": e.extra})

proc assemble(dir, baselinePath: string; threshold: float;
    failOnRegression, requireQuiet: bool): int =
  let timing = parseFile(dir / partsDir / "timing.json")
  let detail = parseFile(dir / partsDir / "detail.json")
  # Both builds must have written the same bytes: the stage timings and
  # allocation counting change no output.
  for k, v in timing["digests"].pairs:
    if detail["digests"].getOrDefault(k).getStr() != v.getStr():
      stderr.writeLine("bench: the detail build rendered '" & k &
        "' differently from the release build")
      return 1
  var loads: seq[float]
  for p in [timing, detail]:
    loads.add(p["loadBefore"].getFloat())
    loads.add(p["loadAfter"].getFloat())
  let cpus = timing["cpus"].getInt()
  var worst = 0.0
  for l in loads:
    worst = max(worst, l)
  let quiet = worst >= 0 and worst / float(cpus) <= quietLoadPerCpu
  let machine = machineLabel()
  let flag = referenceMachineOf(getEnv(referenceMachineVar))
  if not flag.known:
    stderr.writeLine("bench: " & referenceMachineVar & " must be unset, " &
      "0 or 1 (got '" & getEnv(referenceMachineVar) & "')")
    return 2
  let reference = flag.reference
  if requireQuiet and not quiet:
    stderr.writeLine("bench: the host was loaded (load " & fmt3(worst) &
      " on " & $cpus & " CPUs); --require-quiet-host writes nothing")
    return 3
  let commit = getEnv("ISONIM_EMAIL_BENCH_COMMIT", "unknown")
  let date = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  var values: Table[string, JsonNode]
  for p in [timing, detail]:
    for e in p["entries"]:
      values[e["name"].getStr()] = e
  var stories: seq[string]
  for s in benchStories():
    stories.add(s.name)
  var entries: seq[Entry]
  for x in expectedEntries(stories, referenceStory):
    if x.name notin values:
      stderr.writeLine("bench: no figure for '" & x.name & "'")
      return 1
    let v = values[x.name]
    let value = v["value"].getFloat()
    let timingFigure = x.unit in ["ms", "msg/s"]
    let underCondition = quiet and reference
    var extra = targetToken(x.target) & " verdict=" &
      verdictOf(x.target, value, timingFigure, underCondition) & " gap=" &
      (if x.target.present and timingFigure and not underCondition:
        "external" else: "none") & " better=" & $x.better & " samples=" &
      $v["samples"].getInt() & " shape=" & v["shape"].getStr() &
      " build=release" & " host=" & (if quiet: "quiet" else: "loaded") &
      " machine=" & machine & " reference-machine=" &
      (if reference: "yes" else: "no") &
      " load1=" & loads.mapIt(fmt3(it)).join(",") & " cpus=" & $cpus &
      " commit=" & commit & " date=" & date
    if x.name.startsWith("render/") and x.name.endsWith("/p50"):
      let story = x.name.split('/')[1]
      extra.add(" digest=" & timing["digests"][story].getStr())
    entries.add(Entry(name: x.name, unit: x.unit, value: value,
      extra: extra))
  if values.len != entries.len:
    stderr.writeLine("bench: the parts hold figures no entry names")
    return 1
  var smallerEs, biggerEs: seq[Entry]
  for e in entries:
    if parseExtra(e.extra)["better"] == "smaller": smallerEs.add(e)
    else: biggerEs.add(e)
  doAssert smallerEs.len > 0 and biggerEs.len > 0 and
    smallerEs.len + biggerEs.len == entries.len
  writeFile(dir / "benchmark_results.json", toJson(entries).pretty() & "\n")
  writeFile(dir / "benchmark_results_smaller.json",
    toJson(smallerEs).pretty() & "\n")
  writeFile(dir / "benchmark_results_bigger.json",
    toJson(biggerEs).pretty() & "\n")
  # The baseline comparison: recorded, not gated.
  var comparison: seq[(string, string)]
  var regressions = 0
  if fileExists(baselinePath):
    var base: Table[string, JsonNode]
    for e in parseFile(baselinePath):
      base[e["name"].getStr()] = e
    for e in entries:
      if e.name notin base:
        comparison.add((e.name, "new (not in the baseline)"))
        continue
      let b = base[e.name]
      let bv = b["value"].getFloat()
      let bx = parseExtra(b["extra"].getStr())
      let better = parseExtra(e.extra)["better"]
      let ratio = if bv == 0 or e.value == 0: 1.0
        elif better == "smaller": e.value / bv else: bv / e.value
      var note = fmt3(e.value) & " vs " & fmt3(bv) & " " & e.unit &
        " (x" & formatFloat(ratio, ffDecimal, 2) & ", baseline host " &
        bx.getOrDefault("host", "?") & ")"
      if ratio > threshold:
        note = "REGRESSION " & note
        inc regressions
      if "digest" in bx and parseExtra(e.extra)["digest"] != bx["digest"]:
        note.add("; output bytes changed")
      comparison.add((e.name, note))
  else:
    comparison.add(("baseline", "none at " & baselinePath))
  var cj = newJArray()
  for (k, v) in comparison:
    cj.add(%*{"name": k, "comparison": v})
  writeFile(dir / "comparison.json", cj.pretty() & "\n")
  var meta: OrderedTable[string, string]
  meta["date"] = date
  meta["commit"] = commit
  meta["host"] = machine & " (" & (if reference: "a reference machine"
    else: "not a reference machine") & "), " & $cpus & " CPUs, load " &
    loads.mapIt(fmt3(it)).join(", ") & " (" &
    (if quiet: "quiet" else: "loaded") & ")"
  meta["build"] = "-d:release (timing); -d:release " &
    "-d:isonimEmailStageTimings -d:nimAllocStats (stages, allocations)"
  meta["method"] = "warm-up, then interleaved samples; p50 = median, " &
    "p95 = nearest rank; see each entry's samples= and shape="
  meta["baseline"] = if fileExists(baselinePath): baselinePath &
      ", threshold x" & formatFloat(threshold, ffDecimal, 2) & ", " &
      $regressions & " regression(s), not gated"
    else: "none at " & baselinePath & " (nothing compared)"
  writeFile(dir / "report.html", report(entries, meta, comparison))
  # The summary, on stderr.
  stderr.writeLine("isonim-email benchmark (" & meta["host"] & ")")
  for e in entries:
    let x = parseExtra(e.extra)
    if x["verdict"] != "reported" or e.name.startsWith("render/") and
        e.name.endsWith("/p50"):
      stderr.writeLine("  " & alignLeft(e.name, 52) & align(fmt3(e.value),
        10) & " " & alignLeft(e.unit, 8) & " " & x["verdict"])
  stderr.writeLine("baseline: " & meta["baseline"])
  for (k, v) in comparison:
    if v.startsWith("REGRESSION"):
      stderr.writeLine("  " & k & ": " & v)
  stderr.writeLine("wrote " & dir / "benchmark_results.json" & " (" &
    $entries.len & " entries; " & $smallerEs.len & " smaller, " &
    $biggerEs.len & " bigger), report.html, comparison.json")
  if failOnRegression and regressions > 0: 1 else: 0

when isMainModule:
  var part, outDir = ""
  var baseline = "bench/baseline.json"
  var quick, doAssemble, failOnRegression, requireQuiet = false
  var threshold = 1.20
  outDir = "bench-results"
  for a in commandLineParams():
    if a == "--quick": quick = true
    elif a == "--assemble": doAssemble = true
    elif a == "--fail-on-regression": failOnRegression = true
    elif a == "--require-quiet-host": requireQuiet = true
    elif a.startsWith("--part="): part = a["--part=".len .. ^1]
    elif a.startsWith("--out="): outDir = a["--out=".len .. ^1]
    elif a.startsWith("--baseline="): baseline = a["--baseline=".len .. ^1]
    elif a.startsWith("--threshold="):
      threshold = parseFloat(a["--threshold=".len .. ^1])
    else:
      stderr.writeLine("bench: unknown argument " & a)
      quit(2)
  if doAssemble:
    quit(assemble(outDir, baseline, threshold, failOnRegression,
      requireQuiet))
  case modeFromEnv()
  of bmCorrectness:
    let failures = correctness()
    stderr.writeLine("bench: correctness mode (set " & measureVar &
      "=1 to measure): " & $failures & " failure(s), nothing written")
    quit(if failures > 0: 1 else: 0)
  of bmMeasure:
    var host = hostNow()
    var p: Part
    case part
    of "timing":
      when defined(isonimEmailStageTimings) or defined(nimAllocStats):
        stderr.writeLine("bench: --part=timing needs the plain release " &
          "build (the detail build's instrumentation biases its clocks)")
        quit(2)
      else:
        p = timingPart(quick)
    of "detail": p = detailPart(quick)
    else:
      stderr.writeLine("bench: measure mode needs --part=timing or " &
        "--part=detail")
      quit(2)
    host.loadAfter = load1()
    writePart(outDir, part, p, host)
