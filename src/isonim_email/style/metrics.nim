## isonim_email/style/metrics.nim — conservative text widths.
##
## A checking aid, never a layout engine: the only consequence of a
## width computed here is a lowering choice or a diagnostic. The table
## is the advance widths of Arial (and the metric-compatible Liberation
## Sans and Helvetica, whose standard metrics are the same) for printable
## ASCII, in thousandths of an em. Every other character counts as the
## average advance of a sans-serif face (0.6 em), or a full em for the
## wide CJK, Hangul and full-width ranges. A width is the sum of the
## advances × size, × 1.05 as a safety margin, so an estimate errs on
## the wide side: a fit check that passes here fits on screen.
##
## Pure arithmetic: identical on the C and JS targets.

import std/[math, unicode]
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  arialAdvances: array[32 .. 126, int] = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333,
    278, 278, # space ! " # $ % & ' ( ) * + , - . /
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, # 0-9
    278, 278, 584, 584, 584, 556, 1015, # : ; < = > ? @
    667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, # A-M
    722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, # N-Z
    278, 278, 278, 469, 556, 333, # [ \ ] ^ _ `
    556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, # a-m
    556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, # n-z
    334, 260, 334, 584] # { | } ~
    ## Arial / Helvetica advances (1/1000 em), U+0020–U+007E.
  otherAdvance = 600
    ## Any other character: a sans-serif face's average advance.
  wideAdvance = 1000
    ## CJK, Hangul and full-width forms: one em.
  safety* = 1.05
    ## The margin every estimate carries.
  contentAreaEm* = 1.2
    ## A font's content area (ascent plus descent) in ems, rounded up
    ## over the default stacks' fonts (Arial and Helvetica 1.15, Roboto
    ## 1.17, Georgia 1.14). A line height below it lets the glyphs reach
    ## out of their line box, and a line at the top of a reading pane
    ## loses its tops.

proc advance(r: Rune): int =
  let c = int(r)
  if c >= 32 and c <= 126:
    arialAdvances[c]
  elif (c >= 0x1100 and c <= 0x11FF) or (c >= 0x2E80 and c <= 0xA4CF) or
      (c >= 0xAC00 and c <= 0xD7AF) or (c >= 0xF900 and c <= 0xFAFF) or
      (c >= 0xFF00 and c <= 0xFF60):
    wideAdvance
  else:
    otherAdvance

proc textWidth*(text: string; sizePx: float; margin = true): float =
  ## The estimated width of `text` set on one line at `sizePx`, in px,
  ## with the safety margin unless `margin` is false (a best estimate,
  ## for a choice that is wrong either way when it errs). Whitespace
  ## runs count as one space each, as HTML collapses them.
  var em = 0
  var lastSpace = false
  for r in text.runes:
    if r.isWhiteSpace:
      if not lastSpace:
        em += arialAdvances[32]
      lastSpace = true
    else:
      em += advance(r)
      lastSpace = false
  float(em) / 1000.0 * sizePx * (if margin: safety else: 1.0)

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
