## isonim_email/lower/stack.nim — `mailStack` lowering (vertical rhythm).
##
## Each child is wrapped in a `div`. Every child after the first gets
## the gap as `padding-top` on its wrapper and, for Word, which ignores
## div padding, a spacer row before it: a one-cell table inside
## `<!--[if mso]>` whose sized cell is never empty (R-TBL-04, R-TBL-05).
## Gaps are never `gap`, negative margins or `margin:auto`. Text
## elements keep their own margins; the gap is added to them, never
## collapsed with them, and a gap of 0 adds nothing at all.
##
## `align` (default: the start of the direction the stack's content
## runs in, left or right) is emitted as attribute and CSS on every
## child wrapper (R-TBL-14), so the stack's alignment holds whatever its
## container's is.
##
## The stack itself leaves no element behind: its wrappers take its
## place in the parent, in authoring order.
##
## Spacer rows come from `mso/ghost.nim` only. Pure tree building:
## identical on the C and JS targets.

import std/[math, strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/units
import ../style/tokens
import ../passes/layout
import ../mso/ghost
import ./section

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const stackGapToken* = "space.4"
  ## The default gap (patterns: `gap = tok"space.4"`, 16px).

proc stackGap*(node: EmailNode; theme: EmailTheme): int =
  ## The gap in whole px: the element's own, else the theme default.
  var v = rawValue(node, "gap")
  if v.len == 0:
    v = theme.lightFor(stackGapToken)
  elif v.startsWith("tok:"):
    v = theme.lightFor(v[4 .. ^1])
  int(trunc(toPx(v)))

proc startOf*(node: EmailNode; ctx: LowerCtx): string =
  ## The start edge of the direction `node`'s content runs in: the
  ## nearest enclosing element's `direction` (its own, or one a lowered
  ## container set) or `dir`, else the document's.
  var n = node
  while n != nil:
    if n.kind == enElement:
      var d = n.styles.getOrDefault("direction", "").strip().toLowerAscii()
      if d.len == 0:
        d = n.attrs.getOrDefault("dir", "").strip().toLowerAscii()
      if d in ["ltr", "rtl"]:
        return if d == "rtl": "right" else: "left"
    n = n.parent
  if ctx.dir.toLowerAscii() == "rtl": "right" else: "left"

proc lowerStack*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; wrappers: seq[EmailNode];
          diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one `mailStack`: `nodes` replace it in its parent, and
  ## `wrappers` are the child divs the caller lowers next.
  let r = EmailRenderer()
  var gap = 0
  try:
    gap = stackGap(node, ctx.theme)
  except StyleError, ThemeError:
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailStack gap: " &
        getCurrentExceptionMsg(), origin: node.origin,
      rules: @["R-TBL-04"]))
  if gap < 0:
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailStack gap " & $gap &
        "px is negative (R-TBL-04: gaps are padding, never negative)",
      origin: node.origin, rules: @["R-TBL-04"]))
    gap = 0
  var align = node.attrs.getOrDefault("align", "").strip().toLowerAscii()
  if align.len == 0:
    align = startOf(node, ctx)
  if align notin ["left", "center", "right"]:
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeVocabBadValue, message: "mailStack align '" & align &
        "' is not left, center or right", origin: node.origin))
    align = "left"
  var first = true
  let kids = node.children # Copy: appendChild detaches as it moves.
  for c in kids:
    if c.kind == enText and c.text.strip().len == 0:
      continue
    let wrap = r.createElement("div")
    wrap.origin = node.origin
    r.setAttribute(wrap, "align", align)
    if not first and gap > 0:
      if ctx.target.outlookWord:
        result.nodes.add(spacerRow(gap))
      r.setStyle(wrap, "padding-top", formatPx(float(gap)))
    r.setStyle(wrap, "text-align", align)
    # Any other resolved declaration (a colour the stack's text
    # inherits) and the stack's classes hold for each child.
    for k, v in node.styles.pairs:
      if k notin ["gap", "text-align", "padding-top"]:
        r.setStyle(wrap, k, v)
    if "class" in node.attrs:
      r.setAttribute(wrap, "class", node.attrs["class"])
    r.appendChild(wrap, c)
    result.nodes.add(wrap)
    result.wrappers.add(wrap)
    first = false
