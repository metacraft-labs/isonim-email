## isonim_email/ir.nim — the email IR: typed MSO/head constructs.
##
## Keeping MSO constructs as typed nodes instead of raw strings is what lets
## P9 prune them, P11 guarantee balanced conditionals, and tests assert on
## them. The node kinds live on `EmailNode` (renderer.nim); this
## module owns the constructors and the structural validation.
##
## Restriction: only `src/isonim_email/mso/`
## (MSO conditionals and VML) and `passes/head.nim` (head style blocks) may
## call these constructors. `tests/t1_ir_restriction.nim` greps `src/` and
## fails on any other call site. Tests themselves are exempt so they can
## build IR trees directly.

import std/[tables, strutils]
import ./renderer
import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

export renderer

const msoConditions* = ["mso", "gte mso 9", "lte mso 11"]
  ## The only conditions the library emits (R-OL-02): plain `mso`, `gte mso 9`
  ## for VML, `lte mso 11` for the group fix. Any other condition is rejected.

proc newMsoIf*(cond: string; children: seq[EmailNode] = @[]): EmailNode =
  ## Outlook-only conditional: `<!--[if <cond>]> … <![endif]-->` (R-OL-01).
  ## Raises `EmailRenderError` on a condition outside `msoConditions`.
  if cond notin msoConditions:
    raise newException(EmailRenderError,
      "unknown MSO condition '" & cond & "' (R-OL-02 allows only: " &
      msoConditions.join(", ") & ")")
  result = EmailNode(
    kind: enMsoIf,
    children: children,
    cond: cond,
  )
  for c in children:
    c.parent = result

proc newNotMso*(children: seq[EmailNode] = @[]): EmailNode =
  ## Everyone-but-Outlook conditional:
  ## `<!--[if !mso]><!--> … <!--<![endif]-->` (R-OL-01).
  result = EmailNode(
    kind: enNotMso,
    children: children,
  )
  for c in children:
    c.parent = result

proc newVml*(shape: string; attrs: openArray[(string, string)] = [];
            children: seq[EmailNode] = @[]): EmailNode =
  ## A VML shape (`v:rect`, `v:roundrect`, `v:fill`, `v:textbox`,
  ## `w:anchorlock`). Only valid inside `MsoIf` (checked by `validateIr`,
  ## which the serialiser runs); px sizes only (the style pass checks this).
  result = EmailNode(
    kind: enVml,
    tag: shape,
    attrs: initOrderedTable[string, string](0),
    styles: initOrderedTable[string, string](0),
    children: children,
  )
  for (k, v) in attrs:
    result.attrs[k] = v
  for c in children:
    c.parent = result

proc newHeadStyle*(css: string; priority: int): EmailNode =
  ## One `<style>` head block with its head-block priority. Only
  ## `passes/head.nim` may call this in `src/`; tests call it directly.
  EmailNode(
    kind: enHeadStyle,
    text: css,
    children: @[],
    priority: priority,
  )

proc validateIr*(node: EmailNode) =
  ## Structural IR invariants, run by the serialiser before emitting:
  ## VML only inside `MsoIf`, `MsoIf` conditions from the closed R-OL-02 set.
  ## Raises `EmailRenderError` naming the offending node.
  if node == nil:
    return
  var underMso = false
  var cur = node.parent
  while cur != nil:
    if cur.kind == enMsoIf:
      underMso = true
      break
    cur = cur.parent
  if node.kind == enVml and not underMso:
    raise newException(EmailRenderError,
      "VML <" & node.tag & "> outside MsoIf " &
      "(VML shapes are only valid inside an MSO conditional)")
  if node.kind == enMsoIf and node.cond notin msoConditions:
    raise newException(EmailRenderError,
      "unknown MSO condition '" & node.cond & "' (R-OL-02 allows only: " &
      msoConditions.join(", ") & ")")
  for child in node.children:
    validateIr(child)
