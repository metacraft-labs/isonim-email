## The benchmark (`bench/`), its committed baseline and the stage clocks
## of the render.
##
## - The benchmark's stories are the reference set, in its order, plus
##   the invoice email, and each renders the reference set's own bytes.
## - The committed baseline (`bench/baseline.json`) is read as the
##   artifact it is: the entries the benchmark's source writes, each
##   with its unit, direction, target and a verdict that agrees with its
##   value and its host, and the provenance every figure must carry (the
##   sample count and the shape of one sample, the build, the host's load
##   and CPU count, the machine, the commit). A source change that adds,
##   renames or re-targets a figure makes this fail until the baseline is
##   re-recorded.
## - The measure flag takes 0 or 1 and refuses anything else; the
##   percentiles are the median and the nearest rank.
## - An ordinary build has no stage clocks at all.
##
## C backend only: it reads the baseline off disk and renders the
## reference set, whose images are read at compile time from examples/.
import std/[json, os, strutils, tables, unittest]
import isonim_email
import reference_set
import ../bench/workload
import ../bench/entries

const baselinePath = parentDir(parentDir(currentSourcePath())) / "bench" /
  "baseline.json"

proc storyNames(): seq[string] =
  for s in benchStories():
    result.add(s.name)

suite "benchmark":
  test "test_bench_stories_are_the_reference_set":
    let stories = benchStories()
    let refs = referenceEmails()
    check stories.len == refs.len + 1
    for i, e in refs:
      check stories[i].name == e.name
      let mine = stories[i].plain()
      let theirs = e.render(defaultTarget(), memoryAssetStore("https://x.test"))
      check mine.html == theirs.html
      check mine.text == theirs.text
    check stories[^1].name == referenceStory

  test "test_bench_baseline_artifact":
    let base = parseFile(baselinePath)
    let expected = expectedEntries(storyNames(), referenceStory)
    # Not vacuous: the source names every figure it writes.
    check expected.len >= 50
    check base.kind == JArray
    check base.len == expected.len
    var smallerN, biggerN = 0
    for i in 0 ..< min(base.len, expected.len):
      let e = base[i]
      let x = expected[i]
      checkpoint(x.name)
      check e["name"].getStr() == x.name
      check e["unit"].getStr() == x.unit
      let value = e["value"].getFloat()
      check value >= 0
      let extra = e["extra"].getStr()
      for tok in extra.splitWhitespace():
        check '=' in tok or tok.startsWith("target<=") or
          tok.startsWith("target>=")
      let f = parseExtra(extra)
      for key in ["target", "verdict", "gap", "better", "samples", "shape",
          "build", "host", "machine", "reference-machine", "load1", "cpus",
          "commit", "date"]:
        check key in f
      check f.getOrDefault("better") == $x.better
      if f.getOrDefault("better") == "smaller": inc smallerN
      else: inc biggerN
      let wantTarget = if not x.target.present: "none"
        elif x.target.atMost: "<=" & x.target.label
        else: ">=" & x.target.label
      check f.getOrDefault("target") == wantTarget
      check parseInt(f.getOrDefault("samples", "0")) >= 1
      check f.getOrDefault("shape").len > 0
      check f.getOrDefault("build") == "release"
      let cpus = parseInt(f.getOrDefault("cpus", "0"))
      check cpus >= 1
      var worst = 0.0
      let loads = f.getOrDefault("load1").split(',')
      check loads.len == 4
      for l in loads:
        worst = max(worst, parseFloat(l))
      let quiet = worst / float(max(cpus, 1)) <= quietLoadPerCpu
      check f.getOrDefault("host") == (if quiet: "quiet" else: "loaded")
      check f.getOrDefault("machine").len > 0
      let refToken = f.getOrDefault("reference-machine")
      check refToken in ["yes", "no"]
      let reference = refToken == "yes"
      let timing = x.unit in ["ms", "msg/s"]
      let verdict = f.getOrDefault("verdict")
      check verdict in verdictTokens
      check verdict == verdictOf(x.target, value, timing, quiet and reference)
      check f.getOrDefault("gap") ==
        (if verdict.endsWith("-CONDITION-NOT-external"): "external"
         else: "none")
      if x.name.startsWith("render/") and x.name.endsWith("/p50"):
        check f.getOrDefault("digest").len == 16
    check smallerN > 0 and biggerN > 0
    check smallerN + biggerN == expected.len

  test "test_bench_measure_flag":
    check benchModeOf("") == (true, false)
    check benchModeOf("0") == (true, false)
    check benchModeOf("1") == (true, true)
    for typo in ["yes", "true", "2", " 1", "on"]:
      check not benchModeOf(typo).known

  test "test_bench_reference_machine_flag":
    # The operator asserts a reference machine; the host's name is never
    # read, and a typo is refused rather than read as either answer.
    check referenceMachineOf("") == (true, false)
    check referenceMachineOf("0") == (true, false)
    check referenceMachineOf("1") == (true, true)
    for typo in ["yes", "true", "2", " 1", "on"]:
      check not referenceMachineOf(typo).known
    check machineLabel() == hostOS & "-" & hostCPU

  test "test_bench_percentiles":
    check p50(@[3.0, 1.0, 2.0]) == 2.0
    check p50(@[4.0, 1.0, 3.0, 2.0]) == 2.5
    var xs: seq[float]
    for i in 1 .. 100:
      xs.add(float(101 - i))
    check p95(xs) == 95.0
    check p95(@[7.0]) == 7.0

  test "test_stage_clocks_are_compiled_out":
    # Only the benchmark's detail build (-d:isonimEmailStageTimings)
    # reads a clock per stage; an ordinary build has no counters.
    check not declared(stageNanos)
    check not declared(resetStageTimings)
    var ran = false
    timedStage(rsP5):
      ran = true
    check ran
