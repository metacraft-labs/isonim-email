## isonim_email/lower/elements.nim — P4 over the element tree.
##
## Walks a tree that the earlier passes have finished with (the render
## entries hand it a clone, so the authoring tree survives as the
## semantic tree) and replaces every vocabulary element that has a
## lowering with its email HTML: the div-first scaffolding
## (`mailSection`, `mailWrapper`, `mailStack`: `lower/section.nim`,
## `lower/wrapper.nim`, `lower/stack.nim`), rows of columns
## (`mailColumn`, `mailGroup` and `mailColumns`: `lower/column.nim`) and
## `mailImage` (`lower/image.nim`). `mailDocument` is lowered separately, around
## the result, by `lower/document.nim`.
##
## The scaffolding reads P3's widths (`passes/layout.nim`); a tree that
## reaches this pass unsolved is laid out first. A container is
## lowered before its content, so content lowers inside the markup it
## will sit in (an image reads its alignment from the section's inner
## div, not from the authoring element).
##
## The invariant this pass owns: a vocabulary element with no lowering
## is an error (`E-LOWER-MISSING`), never emitted as a raw custom tag.
## Browsers render an unknown tag as an inline box and mail clients
## strip it, so a raw `<mailButton>` would silently lose the button.
## The element is replaced by its children (so the content stays
## inspectable in the output) and the error blocks sending.
##
## "Vocabulary element" means every non-leaf entry of the static
## vocabulary (`vocabulary.nim`: the mechanics elements, the layout
## primitives, the conditional wrappers) plus any other `mail*` tag,
## which covers content patterns and misspellings in hand-built trees.
## HTML leaves (`h1`, `p`, `a`, `table`, …) are their own lowering and
## pass through unchanged.
##
## Pure tree building: identical on the C and JS targets.

import std/[sets, strutils, tables]
import isonim/dsl/vocabulary
import ../renderer
import ../diagnostics
import ../assets
import ../vocabulary as emailVocabulary
import ../style/tokens
import ./image
import ./section
import ./wrapper
import ./stack
import ./column
import ../passes/layout
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const loweredHere* = ["mailImage", "mailSection", "mailWrapper",
  "mailStack", "mailColumns", "mailColumn", "mailGroup"]
  ## Elements this pass lowers.
const loweredElsewhere* = ["mailDocument"]
  ## Elements lowered by the render entries themselves (the document
  ## shell wraps the lowered tree).

var vocabElementsCache: HashSet[string]
var vocabElementsReady = false

proc vocabularyElements*(): HashSet[string] =
  ## The non-leaf tags of the static vocabulary: every tag that is not
  ## an HTML leaf (leaves accept any style keyword).
  if not vocabElementsReady:
    vocabElementsCache = initHashSet[string]()
    for t in buildEmailVocabulary().tags:
      if not t.allowAnyStyle:
        vocabElementsCache.incl(t.name)
    vocabElementsReady = true
  vocabElementsCache

proc needsLowering*(tag: string): bool =
  ## True for a vocabulary element (see the module comment); false for
  ## HTML leaves and for the lowered HTML itself.
  tag in vocabularyElements() or
    (tag.len > 4 and tag.startsWith("mail") and tag[4] in {'A' .. 'Z'})

proc replaceChild(parent, old: EmailNode; repl: seq[EmailNode]) =
  let at = parent.children.find(old)
  var kids: seq[EmailNode] = @[]
  for i, c in parent.children:
    if i == at:
      for n in repl:
        n.parent = parent
        kids.add(n)
    else:
      kids.add(c)
  parent.children = kids
  old.parent = nil

proc walk(parent: EmailNode; ctx: LowerCtx;
    assets: openArray[AssetRef]; diags: var seq[EmailDiagnostic]) =
  let kids = parent.children # Copy: replacement edits the seq.
  for c in kids:
    if c == nil:
      continue
    if c.kind == enElement and c.tag == "mailImage":
      let (lowered, found) = lowerImage(c, ctx.theme, assets)
      diags.add(found)
      replaceChild(parent, c, @[lowered])
    elif c.kind == enElement and c.tag == "mailSection":
      let (band, found) = lowerSection(c, ctx)
      diags.add(found)
      if band.row:
        discard lowerInlineRow(c, ctx, band.inner, EmailRenderer())
      replaceChild(parent, c, band.nodes)
      walk(band.inner, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailColumns":
      let (row, found) = lowerColumns(c, ctx)
      diags.add(found)
      replaceChild(parent, c, row.nodes)
      for h in row.holders:
        walk(h, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailWrapper":
      let (band, found) = lowerWrapper(c, ctx)
      diags.add(found)
      replaceChild(parent, c, band.nodes)
      walk(band.inner, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailStack":
      let (nodes, wrappers, found) = lowerStack(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
      for w in wrappers:
        walk(w, ctx, assets, diags)
    elif c.kind == enElement and c.tag in ["mailColumn", "mailGroup"]:
      # A column is lowered by its row; one anywhere else is misplaced
      # (a hand-built tree: templates cannot express it).
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeStructNesting,
        message: "<" & c.tag & "> outside a mailSection or mailColumns " &
          "row (R-LAY-16)", origin: c.origin, rules: @["R-LAY-16"]))
      walk(c, ctx, assets, diags)
      replaceChild(parent, c, c.children)
    elif c.kind == enElement and c.tag notin loweredElsewhere and
        needsLowering(c.tag):
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeLowerMissing,
        message: "<" & c.tag & "> has no lowering yet: it would reach " &
          "the output as a raw custom tag, which mail clients strip",
        origin: c.origin, rules: @[]))
      walk(c, ctx, assets, diags)
      replaceChild(parent, c, c.children)
    else:
      walk(c, ctx, assets, diags)

proc lowerElements*(root: EmailNode; theme: EmailTheme;
    assets: openArray[AssetRef] = []; target = defaultTarget()):
    seq[EmailDiagnostic] =
  ## P4 in place over `root`'s descendants (`root` itself — the
  ## `mailDocument` — is left for the document lowering). Returns the
  ## diagnostics in document order. A root P3 has not laid out is laid
  ## out here first (its layout diagnostics are then returned too).
  if root == nil:
    return
  if not root.layout.solved:
    result.add(solveLayout(root, theme, target))
  let ctx = LowerCtx(theme: theme, target: target,
    dir: root.attrs.getOrDefault("dir", "ltr"))
  walk(root, ctx, assets, result)
