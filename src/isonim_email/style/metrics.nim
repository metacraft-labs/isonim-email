## isonim_email/style/metrics.nim — conservative text widths.
##
## A checking aid, never a layout engine: the only consequence of a
## width computed here is a lowering choice or a diagnostic. The advance
## widths come from `metrics_data.nim`, generated from the font files
## the captures render with (`just text-metrics`): Liberation Sans,
## Serif and Mono for Arial/Helvetica, Times and Courier (their metric
## twins), Carlito for Calibri, Roboto, and Noto Sans for every other
## family, each in a regular and a bold face, for the Basic Latin,
## Latin-1, Latin Extended-A and General Punctuation ranges.
##
## A character outside those ranges (or one the face lacks) counts as
## Noto Sans' average advance, or a full em for the wide CJK, Hangul
## and full-width ranges, and makes the measurement approximate
## (`TextMeasure.approx`, which fit checks report as
## `I-LAYOUT-METRICS-APPROX`). A width is the sum of the advances ×
## size / units per em, × 1.05 as a safety margin, so an estimate errs
## on the wide side: a fit check that passes here fits on screen.
##
## A font stack's width is its worst case: the widest of the faces its
## named families map to (a generic family counts only in a stack with
## no named family), so whichever of them a client has, the text fits.
##
## `measureStyled` adds the two properties that widen text drawn in the
## same face: `text-transform` (measured as drawn) and `letter-spacing`
## (added after every character). The fit checks measure through it.
##
## Pure arithmetic: identical on the C and JS targets.

import std/[math, strutils, unicode]
import ../target
import ../metrics_data

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  MetricsFamily* = enum
    ## The metric faces' families.
    mfLiberationSans, mfLiberationSerif, mfLiberationMono, mfCarlito,
    mfRoboto, mfNotoSans

  TextMeasure* = object
    ## A width estimate, px.
    width*: float
    approx*: bool ## Some character was outside the table's ranges

const
  faces: array[MetricsFamily, array[2, MetricsFace]] = [
    [liberationSansFace, liberationSansBoldFace],
    [liberationSerifFace, liberationSerifBoldFace],
    [liberationMonoFace, liberationMonoBoldFace],
    [carlitoFace, carlitoBoldFace],
    [robotoFace, robotoBoldFace],
    [notoSansFace, notoSansBoldFace]]
    ## Indexed by family, then by `ord(bold)` (an integer index: the
    ## JS backend does not index an array by `bool`).
  safety* = 1.05
    ## The margin every estimate carries.
  wideEm = 1.0
    ## CJK, Hangul and full-width forms: one em.
  contentAreaEm* = 1.2
    ## A font's content area (ascent plus descent) in ems, rounded up
    ## over the default stacks' fonts (Arial and Helvetica 1.15, Roboto
    ## 1.17, Georgia 1.14). A line height below it lets the glyphs reach
    ## out of their line box, and a line at the top of a reading pane
    ## loses its tops.
  genericFamilies = ["serif", "sans-serif", "monospace", "cursive",
    "fantasy", "system-ui", "ui-sans-serif", "ui-serif", "ui-monospace",
    "-apple-system", "blinkmacsystemfont"]

proc familyOf*(name: string): MetricsFamily =
  ## The metric face a CSS family name maps to.
  let n = name.strip().strip(chars = {'"', '\''}).strip().toLowerAscii()
  case n
  of "arial", "helvetica", "helvetica neue", "liberation sans", "arimo":
    mfLiberationSans
  of "times", "times new roman", "liberation serif", "tinos", "serif":
    mfLiberationSerif
  of "courier", "courier new", "liberation mono", "cousine", "monospace",
      "consolas", "menlo", "monaco", "ui-monospace":
    mfLiberationMono
  of "calibri", "carlito":
    mfCarlito
  of "roboto":
    mfRoboto
  else:
    mfNotoSans

proc stackFamilies*(stack: string): seq[MetricsFamily] =
  ## The faces a font stack is measured with: its named families' faces
  ## (deduplicated, in order), or its generic family's when it names
  ## none; Liberation Sans (Arial) for an empty stack.
  var generic: seq[MetricsFamily] = @[]
  for part in stack.split(','):
    let n = part.strip().strip(chars = {'"', '\''}).toLowerAscii()
    if n.len == 0:
      continue
    let f = familyOf(n)
    if n in genericFamilies:
      if f notin generic:
        generic.add(f)
    elif f notin result:
      result.add(f)
  if result.len == 0:
    result = generic
  if result.len == 0:
    result = @[mfLiberationSans]

proc isWide(c: int): bool =
  (c >= 0x1100 and c <= 0x11FF) or (c >= 0x2E80 and c <= 0xA4CF) or
    (c >= 0xAC00 and c <= 0xD7AF) or (c >= 0xF900 and c <= 0xFAFF) or
    (c >= 0xFF00 and c <= 0xFF60)

proc tableIndex(c: int): int =
  ## The character's slot in a face's advances, -1 when outside.
  var base = 0
  for (lo, hi) in metricsRanges:
    if c >= lo and c <= hi:
      return base + c - lo
    base += hi - lo + 1
  -1

proc advanceEm(family: MetricsFamily; bold: bool; r: Rune;
    approx: var bool): float =
  let face = faces[family][ord(bold)]
  let c = int(r)
  let i = tableIndex(c)
  if i >= 0 and face.advances[i] > 0:
    return float(face.advances[i]) / float(face.unitsPerEm)
  approx = true
  if isWide(c):
    return wideEm
  let noto = faces[mfNotoSans][ord(bold)]
  float(noto.averageAdvance) / float(noto.unitsPerEm)

proc measureFace*(text: string; family: MetricsFamily; bold: bool;
    sizePx: float; margin = true): TextMeasure =
  ## `text` set on one line in one face at `sizePx`, in px, with the
  ## safety margin unless `margin` is false (a best estimate, for a
  ## choice that is wrong either way when it errs). Whitespace runs
  ## count as one space each, as HTML collapses them.
  var em = 0.0
  var lastSpace = false
  for r in text.runes:
    if r.isWhiteSpace:
      if not lastSpace:
        em += advanceEm(family, bold, Rune(0x20), result.approx)
      lastSpace = true
    else:
      em += advanceEm(family, bold, r, result.approx)
      lastSpace = false
  result.width = em * sizePx * (if margin: safety else: 1.0)

proc measureText*(text, stack: string; sizePx: float; bold = false;
    margin = true): TextMeasure =
  ## The worst case of `text` over a font stack (see the module
  ## comment): the widest of its faces.
  for f in stackFamilies(stack):
    let m = measureFace(text, f, bold, sizePx, margin)
    if m.width > result.width:
      result.width = m.width
    result.approx = result.approx or m.approx

proc transformText*(text, transform: string): string =
  ## `text` as CSS `text-transform` draws it: `uppercase` and
  ## `lowercase` change every letter, `capitalize` the first letter of
  ## each word; anything else (`none`, empty) leaves it as written.
  case transform.strip().toLowerAscii()
  of "uppercase":
    result = unicode.toUpper(text)
  of "lowercase":
    result = unicode.toLower(text)
  of "capitalize":
    var atStart = true
    for r in text.runes:
      if r.isWhiteSpace:
        atStart = true
        result.add($r)
      elif atStart:
        result.add($r.toUpper)
        atStart = false
      else:
        result.add($r)
  else:
    result = text

proc drawnChars*(text: string): int =
  ## The characters `measureFace` sets for `text`: each whitespace run
  ## counts once, as HTML collapses it.
  var lastSpace = false
  for r in text.runes:
    if r.isWhiteSpace:
      if not lastSpace:
        inc result
      lastSpace = true
    else:
      inc result
      lastSpace = false

proc letterSpacingPx*(value: string; sizePx: float): float =
  ## A `letter-spacing` value in px: a px (or unitless) length, an `em`
  ## multiple of the font size; `normal`, an empty or unparseable value
  ## none.
  let v = value.strip().toLowerAscii()
  if v.len == 0 or v == "normal":
    return 0
  try:
    if v.endsWith("rem"):
      return parseFloat(v[0 ..< ^3].strip()) * 16.0
    if v.endsWith("em"):
      return parseFloat(v[0 ..< ^2].strip()) * sizePx
    if v.endsWith("px"):
      return parseFloat(v[0 ..< ^2].strip())
    parseFloat(v)
  except ValueError:
    0

proc measureStyled*(text, stack: string; sizePx: float; bold = false;
    letterSpacingPx = 0.0; transform = ""): TextMeasure =
  ## `measureText` for text drawn with `letter-spacing` and
  ## `text-transform`, the two properties that change a text's width
  ## without changing its face: the transform is applied first (an
  ## uppercase label is wider than its source), then the spacing is
  ## added after every character set. A negative spacing counts as
  ## none, so the estimate stays an upper bound.
  let shown = transformText(text, transform)
  result = measureText(shown, stack, sizePx, bold)
  if letterSpacingPx > 0:
    result.width += float(drawnChars(shown)) * letterSpacingPx

proc isBoldWeight*(weight: string): bool =
  ## True for a CSS weight drawn with a bold face (600 and above).
  let w = weight.strip().toLowerAscii()
  if w in ["bold", "bolder"]:
    return true
  try:
    parseInt(w) >= 600
  except ValueError:
    false

proc textWidth*(text: string; sizePx: float; margin = true): float =
  ## The estimated width of `text` in Arial (Liberation Sans) regular,
  ## the default body face, in px (see `measureFace`).
  measureFace(text, mfLiberationSans, false, sizePx, margin).width

proc longestWordWidth*(text: string; sizePx: float;
    margin = true): float =
  ## The estimated width of the widest word of `text` (the narrowest
  ## a box can be before a word overflows it).
  var word = ""
  for r in text.runes:
    if r.isWhiteSpace:
      result = max(result, textWidth(word, sizePx, margin))
      word = ""
    else:
      word.add($r)
  max(result, textWidth(word, sizePx, margin))

proc minLineHeight*(sizePx: float): float =
  ## The smallest whole-px line height that holds a line's glyphs at
  ## `sizePx` (`contentAreaEm`).
  ceil(sizePx * contentAreaEm)
