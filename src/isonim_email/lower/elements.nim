## isonim_email/lower/elements.nim — P4 over the element tree.
##
## Walks a tree that the earlier passes have finished with (the render
## entries hand it a clone, so the authoring tree survives as the
## semantic tree) and replaces every vocabulary element that has a
## lowering with its email HTML: the div-first scaffolding
## (`mailSection`, `mailWrapper`, `mailStack`: `lower/section.nim`,
## `lower/wrapper.nim`, `lower/stack.nim`), `mailHero`
## (`lower/hero.nim`), rows of columns
## (`mailColumn`, `mailGroup` and `mailColumns`: `lower/column.nim`),
## the layout primitives (`mailBox`, `mailGrid`, `mailCluster`,
## `mailSidebar`: `lower/box.nim`, `grid.nim`, `cluster.nim`,
## `sidebar.nim`), `mailImage` (`lower/image.nim`), the content leaves
## `mailSpacer`, `mailDivider` and `mailText` (`lower/leaves.nim`),
## `mailButton` (`lower/button.nim`), `mailTable` (`lower/data_table.nim`),
## `mailIf` (`lower/conditional.nim`), `mailRaw` (its payloads, as
## written: R-RAW-01), `textOnly` (nothing: its content is the
## plain-text part's alone), `htmlOnly` (its content, unwrapped), a
## `span` marked `nolink` (R-TXT-06), and
## every expanded
## pattern (`patterns.nim`), which leaves its expansion in its place.
## `mailDocument` is lowered separately, around
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
import ../raw
import ../style/tokens
import ./image
import ./section
import ./wrapper
import ./hero
import ../mso/ghost
import ./stack
import ./column
import ./box
import ./grid
import ./cluster
import ./sidebar
import ./leaves
import ./button
import ./data_table
import ./table_style
import ./conditional
import ./text
import ../passes/layout
import ../patterns
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const loweredHere* = ["mailImage", "mailSection", "mailWrapper", "mailHero",
  "mailStack", "mailColumns", "mailColumn", "mailGroup", "mailBox",
  "mailGrid", "mailCluster", "mailSidebar", "mailSpacer", "mailDivider",
  "mailText", "mailButton", "mailTable", "mailIf", "mailRaw", "textOnly",
  "htmlOnly"]
  ## Elements this pass lowers (plus every expanded pattern, which it
  ## replaces by its expansion).
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
      let (lowered, found) = lowerImage(c, ctx.theme, assets, ctx.target)
      diags.add(found)
      replaceChild(parent, c, lowered)
    elif c.kind == enElement and c.tag == "blockquote":
      # R-TXT-11: webmails fold a `blockquote` away as quoted mail
      # (SnappyMail hides it behind a toggle); the quotation keeps its
      # styles on a `div`.
      c.tag = "div"
      walk(c, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailSpacer":
      let (nodes, found) = lowerSpacer(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
    elif c.kind == enElement and c.tag == "mailDivider":
      let (nodes, found) = lowerDivider(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
    elif c.kind == enElement and c.tag == "mailButton":
      let (nodes, found) = lowerButton(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
    elif c.kind == enElement and c.tag == "mailTable":
      if tableOf(c) == nil:
        # P1 reports it (R-TBL-18); the content stays inspectable.
        walk(c, ctx, assets, diags)
        replaceChild(parent, c, c.children)
      else:
        let stack = tableMode(c) == "stack"
        let (nodes, inner, found) = lowerTable(c, ctx)
        diags.add(found)
        replaceChild(parent, c, nodes)
        walk(inner, ctx, assets, diags)
        if stack:
          # Mobile-first, and Word's own copy (R-TBL-18).
          replaceChild(parent, inner, finishStack(inner, ctx))
    elif c.kind == enElement and c.tag == "mailRaw":
      # R-RAW-01: the payloads as written (P1 read and checked them; the
      # ones it refused were dropped before lowering, see
      # `dropRefusedRaw`).
      walk(c, ctx, assets, diags)
      let kept = c.children
      replaceChild(parent, c, kept)
    elif c.kind == enElement and c.tag == "textOnly":
      # The plain-text part's own content: never written to the HTML.
      replaceChild(parent, c, @[])
    elif c.kind == enElement and c.tag == "htmlOnly":
      # The HTML's own content (left out of the plain-text part).
      walk(c, ctx, assets, diags)
      replaceChild(parent, c, c.children)
    elif c.kind == enElement and c.tag == "mailIf":
      # R-RAW-05, R-RAW-06: the content first, then its conditional.
      walk(c, ctx, assets, diags)
      replaceChild(parent, c, lowerIf(c, ctx.target))
    elif c.kind == enElement and c.tag == "span" and "nolink" in c.attrs:
      # R-TXT-06: no number a data detector would link.
      let on = c.attrs["nolink"].strip().toLowerAscii() == "true"
      c.attrs.del("nolink")
      if on:
        noLinkTexts(c)
      walk(c, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailText":
      let (nodes, inner, found) = lowerText(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
      walk(inner, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailSection":
      let (band, found) = lowerSection(c, ctx)
      diags.add(found)
      if band.row:
        discard lowerInlineRow(c, ctx, band.inner, EmailRenderer())
      replaceChild(parent, c, band.nodes)
      walk(band.inner, ctx, assets, diags)
      if band.hideInner:
        replaceChild(band.inner.parent, band.inner,
          hiddenFromWord(band.inner))
    elif c.kind == enElement and c.tag == "mailHero":
      let (nodes, inner, found) = lowerHero(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
      walk(inner, ctx, assets, diags)
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
      if band.hideInner:
        replaceChild(band.inner.parent, band.inner,
          hiddenFromWord(band.inner))
    elif c.kind == enElement and c.tag == "mailStack":
      let (nodes, wrappers, found) = lowerStack(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
      for w in wrappers:
        walk(w, ctx, assets, diags)
    elif c.kind == enElement and c.expanded and isPattern(c.tag):
      # An expanded pattern (`patterns.nim`) leaves its expansion behind.
      walk(c, ctx, assets, diags)
      replaceChild(parent, c, c.children)
    elif c.kind == enElement and c.tag == "mailBox":
      let (nodes, inner, found) = lowerBox(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
      walk(inner, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailGrid":
      let (nodes, holders, found) = lowerGrid(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
      for h in holders:
        walk(h, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailCluster":
      let (nodes, holders, found) = lowerCluster(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
      for h in holders:
        walk(h, ctx, assets, diags)
    elif c.kind == enElement and c.tag == "mailSidebar":
      let (nodes, holders, found) = lowerSidebar(c, ctx)
      diags.add(found)
      replaceChild(parent, c, nodes)
      for h in holders:
        walk(h, ctx, assets, diags)
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

proc dropRefusedRaw(node: EmailNode) =
  ## Removes every `raw` payload inside a `mailRaw` that P1 refuses
  ## (R-RAW-02): it would break the markup around it, and its error
  ## blocks sending anyway. Warnings (R-RAW-03) do not remove it. Runs before any lowering,
  ## while the authoring ancestors that decide a payload's place are
  ## still there.
  var kept: seq[EmailNode] = @[]
  var changed = false
  for k in node.children:
    if k.kind == enRaw:
      var inRaw = false
      var p = node
      while p != nil:
        if p.kind == enElement and p.tag == "mailRaw":
          inRaw = true
          break
        p = p.parent
      if inRaw and readRaw(k.text, rawContextOf(k)).refused:
        changed = true
        continue
    kept.add(k)
  if changed:
    node.children = kept
  for k in node.children:
    dropRefusedRaw(k)

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
  dropRefusedRaw(root)
  let ctx = LowerCtx(theme: theme, target: target,
    dir: root.attrs.getOrDefault("dir", "ltr"))
  walk(root, ctx, assets, result)
