## bench/entries.nim — the benchmark's entries: their names, units and
## targets, and how an entry's `extra` field is written and read.
##
## Shared by the benchmark (`bench.nim`), which writes them, and
## `tests/t8_bench.nim`, which reads the committed baseline against
## them: the names the source produces and the names in the file must be
## the same set, and every entry must carry its provenance.
##
## Backend-independent string work.

import std/[algorithm, math, strutils, tables]
import isonim_email

type
  Better* = enum
    ## The direction a figure improves in: it decides which of the two
    ## split files an entry goes to (`benchmark_results_<better>.json`).
    smaller = "smaller", bigger = "bigger"

  Target* = object
    ## A published target, or none (`reported`).
    present*: bool
    atMost*: bool    ## `value <= limit` when true, `value >= limit` otherwise
    limit*: float
    label*: string   ## the token written after `target<=` / `target>=`

const
  renderTargetMs* = 1.0
    ## Render, every pass, serialise, text and MIME, p50, for the
    ## reference story.
  batchTargetPerSecond* = 1000.0
    ## Personalised messages per second on one core, in batch.
  allocRatioTarget* = 1.10
    ## Allocations per output KB, at 17 digest cards over 4 cards: at
    ## most 10% higher (proportional to the output, or better).
  scalingCards* = [4, 8, 17]
  urlStory* = "receiptTypical"
    ## The story whose unsubscribe and preferences links carry a
    ## per-recipient token in the pre-lowering measurement.
  verdictTokens* = ["met", "unmet", "reported", "met-CONDITION-NOT-external",
    "unmet-CONDITION-NOT-external"]
  referenceMachineVar* = "ISONIM_EMAIL_BENCH_REFERENCE_MACHINE"
    ## Set to `1` by the operator of a machine the timing targets are
    ## stated for (a reference machine); unset or `0` on any other. The
    ## benchmark does not recognise machines itself: the assertion is the
    ## operator's, and each entry records it (`reference-machine=`).
  quietLoadPerCpu* = 0.25
    ## A host whose one-minute load per CPU stays at or below this, before
    ## and after each part, is quiet.

proc noTarget*(): Target = Target(present: false)
proc atMost*(limit: float; label: string): Target =
  Target(present: true, atMost: true, limit: limit, label: label)
proc atLeast*(limit: float; label: string): Target =
  Target(present: true, atMost: false, limit: limit, label: label)

proc targetToken*(t: Target): string =
  if not t.present: "target=none"
  elif t.atMost: "target<=" & t.label
  else: "target>=" & t.label

proc stageNames*(): seq[string] =
  for s in RenderStage:
    result.add($s)

proc expectedEntries*(stories: openArray[string];
    referenceStory: string): seq[tuple[name, unit: string; better: Better;
    target: Target]] =
  ## Every entry the benchmark writes, in the order it writes them.
  for s in stories:
    result.add(("render/" & s & "/p50", "ms", smaller, noTarget()))
    result.add(("render/" & s & "/p95", "ms", smaller, noTarget()))
  let r = referenceStory
  result.add(("render+mime/" & r & "/p50", "ms", smaller,
    atMost(renderTargetMs, "1ms")))
  result.add(("render+mime/" & r & "/p95", "ms", smaller, noTarget()))
  result.add(("render+mime/" & r & "/cpu-p50", "ms", smaller, noTarget()))
  result.add(("mime/" & r & "/p50", "ms", smaller, noTarget()))
  result.add(("mime/" & r & "/p95", "ms", smaller, noTarget()))
  result.add(("batch/" & r & "/messages-per-second", "msg/s", bigger,
    atLeast(batchTargetPerSecond, "1000msg/s")))
  result.add(("prelower/" & r & "/plain-p50", "ms", smaller, noTarget()))
  result.add(("prelower/" & r & "/skeleton-p50", "ms", smaller, noTarget()))
  result.add(("prelower/" & r & "/first-render", "ms", smaller, noTarget()))
  result.add(("prelower/reference-set/skeleton-stories", "stories", bigger,
    noTarget()))
  result.add(("prelower/" & urlStory & "/per-recipient-url-plain-p50", "ms",
    smaller, noTarget()))
  result.add(("prelower/" & urlStory & "/per-recipient-url-prelowered-p50",
    "ms", smaller, noTarget()))
  for s in stageNames():
    result.add(("stage/" & r & "/" & s & "/p50", "ms", smaller, noTarget()))
  result.add(("stage/" & r & "/outside-stages/p50", "ms", smaller,
    noTarget()))
  result.add(("alloc/" & r & "/per-message", "allocations", smaller,
    noTarget()))
  for n in scalingCards:
    result.add(("alloc/digestCards" & $n & "/per-output-KB",
      "allocations/KB", smaller, noTarget()))
  result.add(("alloc/digestCards17-vs-4/per-KB-ratio", "ratio", smaller,
    atMost(allocRatioTarget, "1.10")))

proc meets*(t: Target; value: float): bool =
  if t.atMost: value <= t.limit else: value >= t.limit

proc referenceMachineOf*(value: string): tuple[known, reference: bool] =
  ## The reference-machine flag's value: unset or `0` is not a reference
  ## machine, `1` is, and anything else is not known (and refused), so a
  ## typo never reads as a reference machine.
  case value
  of "", "0": (true, false)
  of "1": (true, true)
  else: (false, false)

proc machineLabel*(): string =
  ## The `machine=` provenance token: the OS and CPU architecture the
  ## figures were taken on (never the host's name).
  hostOS & "-" & hostCPU

proc verdictOf*(t: Target; value: float; timing, underCondition: bool):
    string =
  ## The machine-readable verdict: the number's own verdict first, then
  ## whether it was taken under its target's condition. A timing target's
  ## condition is a reference machine, quiet; a count does not depend on
  ## the host.
  if not t.present:
    return "reported"
  result = if meets(t, value): "met" else: "unmet"
  if timing and not underCondition:
    result.add("-CONDITION-NOT-external")

proc parseExtra*(extra: string): Table[string, string] =
  ## `key=value` tokens of an entry's `extra`, split on spaces. A
  ## `target<=X` / `target>=X` token reads as key `target`, value `<=X`.
  for tok in extra.splitWhitespace():
    if tok.startsWith("target<=") or tok.startsWith("target>="):
      result["target"] = tok["target".len .. ^1]
      continue
    let eq = tok.find('=')
    if eq > 0:
      result[tok[0 ..< eq]] = tok[eq + 1 .. ^1]

proc benchModeOf*(value: string): tuple[known, measure: bool] =
  ## The measure flag's value: unset or `0` is correctness mode, `1`
  ## measure mode, and anything else is not known (and refused).
  case value
  of "", "0": (true, false)
  of "1": (true, true)
  else: (false, false)

proc p50*(xs: seq[float]): float =
  ## The median.
  var s = xs
  s.sort()
  if s.len mod 2 == 1: s[s.len div 2]
  else: (s[s.len div 2 - 1] + s[s.len div 2]) / 2

proc p95*(xs: seq[float]): float =
  ## The 95th percentile, nearest rank.
  var s = xs
  s.sort()
  s[max(0, int(ceil(0.95 * float(s.len))) - 1)]
