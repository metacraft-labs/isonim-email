## isonim_email/lower/conditional.nim — `mailIf`.
##
## `mailIf` is the one way an author targets clients by name (catalogue
## R-RAW-05, R-RAW-06). Its content is lowered first, like any content;
## the lowered nodes are then put where only the named clients see them:
##
## - `mso = true` (or `family = outlookWord`): inside
##   `<!--[if mso]>…<![endif]-->`;
## - `mso = false`: inside `<!--[if !mso]><!-->…<!--<![endif]-->`;
## - `family = thunderbird`: a block hidden inline
##   (`display:none;max-height:0;overflow:hidden;`) with the class
##   `e-if-tb` (a `span` with `e-if-tb-i` inside text), which a
##   `.moz-text-html` rule in the head shows (`passes/layout.nim`'s
##   `columnRules` names it, P6 writes it); inside `!mso`, since Word
##   is not Thunderbird.
##
## Conditional comments cannot nest: for every client but Word the
## first `-->` ends the outer comment, and Word's own reading ends at
## the first `<![endif]`. So the lowered content's own conditionals are
## flattened into the one around it: inside an `mso` block an inner
## `mso` conditional is unwrapped (its content is Word's already) and
## inner `!mso` content dropped (Word never shows it); inside a `!mso`
## block the reverse. The ghost tables of the content's sections and
## boxes come out right either way: Word keeps both halves of each, or
## nobody gets either.
##
## Without `outlookWord`, `mso = true` content is dropped and `mso =
## false` content is written as it is, with no conditional (no MSO
## output at all, R-OL-01). A `mailIf` whose values P1 refused is
## replaced by its content, unconditioned (the error blocks sending).
##
## Conditionals come from `mso/cond.nim` only. Pure tree building:
## identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../target
import ../mso/cond
import ../passes/validate
import ../passes/layout

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type IfForm* = enum
  ## What a `mailIf` asks for.
  ifInvalid, ifMso, ifNotMso, ifThunderbird, ifMsoAndThunderbird

proc ifForm*(node: EmailNode): IfForm =
  ## The form of a `mailIf` (see the module comment), `ifInvalid` when
  ## P1 refuses its values.
  let hasMso = "mso" in node.attrs
  let hasFamily = "family" in node.attrs
  if hasMso == hasFamily:
    return ifInvalid
  if hasMso:
    case node.attrs["mso"].strip().toLowerAscii()
    of "true": return ifMso
    of "false": return ifNotMso
    else: return ifInvalid
  let (families, bad) = ifFamiliesOf(node)
  if bad.len > 0 or families.len == 0:
    return ifInvalid
  let word = "outlookWord" in families
  let tb = "thunderbird" in families
  if word and tb: ifMsoAndThunderbird
  elif word: ifMso
  else: ifThunderbird

proc ifInline*(node: EmailNode): bool =
  ## True when a `mailIf` sits in text, where its hidden block is a
  ## `span`.
  node.parent != nil and node.parent.kind == enElement and
    node.parent.tag.toLowerAscii() in ifInlineParents

proc copyTree*(n: EmailNode): EmailNode =
  ## A deep copy of a lowered subtree (a second copy of content lowered
  ## once: `mailIf` for Word and Thunderbird, a stacking data table for
  ## Word), its parent unset.
  result = EmailNode(kind: n.kind, tag: n.tag, text: n.text,
    attrs: n.attrs, styles: n.styles, fallbacks: n.fallbacks,
    origin: n.origin, cond: n.cond, priority: n.priority,
    layout: n.layout, expanded: n.expanded)
  for c in n.children:
    let cc = copyTree(c)
    cc.parent = result
    result.children.add(cc)

proc flatten*(nodes: seq[EmailNode]; inMso: bool): seq[EmailNode] =
  ## `nodes` with their conditionals flattened for a block that only
  ## Word (`inMso`) or only every other client sees: the conditionals of
  ## the same side unwrapped, the other side's dropped, at any depth.
  for n in nodes:
    case n.kind
    of enMsoIf:
      if inMso:
        result.add(flatten(n.children, inMso))
    of enNotMso:
      if not inMso:
        result.add(flatten(n.children, inMso))
    of enElement:
      let kids = flatten(n.children, inMso)
      n.children = @[]
      for k in kids:
        k.parent = n
        n.children.add(k)
      result.add(n)
    else:
      result.add(n)
  for r in result:
    r.parent = nil

proc thunderbirdBlock(node: EmailNode; kids: seq[EmailNode]): EmailNode =
  let r = EmailRenderer()
  let inline = ifInline(node)
  result = r.createElement(if inline: "span" else: "div")
  result.origin = node.origin
  r.setAttribute(result, "class",
    if inline: ifThunderbirdInlineClass else: ifThunderbirdClass)
  r.setStyle(result, "display", "none")
  r.setStyle(result, "max-height", "0")
  r.setStyle(result, "overflow", "hidden")
  for k in kids:
    r.appendChild(result, k)

proc lowerIf*(node: EmailNode; target: EmailTarget): seq[EmailNode] =
  ## The nodes that replace one `mailIf` whose content is already
  ## lowered (see the module comment).
  let kids = node.children # Copy: the flattening re-parents.
  for c in kids:
    c.parent = nil
  node.children = @[]
  case ifForm(node)
  of ifInvalid:
    kids
  of ifMso:
    if target.outlookWord: @[msoWrap(flatten(kids, true))] else: @[]
  of ifNotMso:
    if target.outlookWord: @[notMsoWrap(flatten(kids, false))] else: kids
  of ifThunderbird:
    let blk = thunderbirdBlock(node, flatten(kids, false))
    if target.outlookWord: @[notMsoWrap(blk)] else: @[blk]
  of ifMsoAndThunderbird:
    if not target.outlookWord:
      @[thunderbirdBlock(node, kids)]
    else:
      # Word's copy first, then Thunderbird's: the content is lowered
      # once, so the second copy is a deep copy of it.
      var copies: seq[EmailNode] = @[]
      for k in kids:
        copies.add(copyTree(k))
      @[msoWrap(flatten(kids, true)),
        notMsoWrap(thunderbirdBlock(node, flatten(copies, false)))]
