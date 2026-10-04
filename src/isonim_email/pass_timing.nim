## isonim_email/pass_timing.nim — per-stage timings of the render
## pipeline, for the benchmark.
##
## `renderTree` wraps each stage in `timedStage`. In an ordinary build
## the template is the stage's code and nothing else: no clock is read,
## no counter exists, and the output is the same bytes either way. Built
## with `-d:isonimEmailStageTimings` (the benchmark's own build), each
## stage adds the monotonic nanoseconds it took to `stageNanos`, which
## the benchmark resets and reads around one render.
##
## The stages are the passes as the pipeline runs them. Two passes of
## the design have no stage of their own: the cascade (P2: theme
## defaults and class groups) resolves inside the styles pass and the
## lowerings, and target pruning (P9) is the lowerings not emitting
## Word-only nodes when `outlookWord` is off; their time is inside P5's
## and P4's.
##
## Backend-independent: `std/monotimes` runs on C and JS.

import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run. The
## clocks change no output.
const affects*: set[ClientFamily] = {}

type
  RenderStage* = enum
    ## The stages `renderTree` times, in pipeline order.
    rsTemplate = "template"   ## the template run (`renderAuthoringTree`)
    rsPatterns = "patterns"   ## pattern expansion, before P1
    rsP1 = "P1-validate"      ## validate and the Gmail markup check
    rsP3 = "P3-layout"        ## the width solver
    rsP5 = "P5-styles"        ## styles (with the cascade)
    rsP6 = "P6-head"          ## web fonts and the head blocks
    rsP7 = "P7-a11y"          ## roles and attributes
    rsP8 = "P8-urls"          ## assets published, background URLs
    rsP10 = "P10-lint"        ## every lint and the size check
    rsP12 = "P12-text"        ## the plain-text part
    rsP4 = "P4-lower"         ## clone, element and document lowering
    rsP11 = "P11-serialize"   ## the document's bytes and breakdown

when defined(isonimEmailStageTimings):
  import std/[monotimes, times]

  var stageNanos*: array[RenderStage, int64]
    ## Nanoseconds per stage since the last `resetStageTimings`.

  proc resetStageTimings*() =
    for s in RenderStage:
      stageNanos[s] = 0

  template timedStage*(stage: RenderStage; body: untyped) =
    ## Runs `body`, adding its duration to `stageNanos[stage]`.
    let stageStart = getMonoTime()
    body
    stageNanos[stage] += (getMonoTime() - stageStart).inNanoseconds
else:
  template timedStage*(stage: RenderStage; body: untyped) =
    ## Runs `body` (timings are compiled out).
    body
