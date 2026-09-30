## isonim_email/lower/elements.nim — P4 over the element tree.
##
## Walks a tree that the earlier passes have finished with (the render
## entries hand it a clone, so the authoring tree survives as the
## semantic tree) and replaces every vocabulary element that has a
## lowering with its email HTML. Today that is `mailImage`
## (`lower/image.nim`); `mailDocument` is lowered separately, around
## the result, by `lower/document.nim`.
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

import std/[sets, strutils]
import isonim/dsl/vocabulary
import ../renderer
import ../diagnostics
import ../assets
import ../vocabulary as emailVocabulary
import ../style/tokens
import ./image

const loweredHere* = ["mailImage"]
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

proc walk(parent: EmailNode; theme: EmailTheme;
    assets: openArray[AssetRef]; diags: var seq[EmailDiagnostic]) =
  let kids = parent.children # Copy: replacement edits the seq.
  for c in kids:
    if c == nil:
      continue
    if c.kind == enElement and c.tag == "mailImage":
      let (lowered, found) = lowerImage(c, theme, assets)
      diags.add(found)
      replaceChild(parent, c, @[lowered])
    elif c.kind == enElement and c.tag notin loweredElsewhere and
        needsLowering(c.tag):
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeLowerMissing,
        message: "<" & c.tag & "> has no lowering yet: it would reach " &
          "the output as a raw custom tag, which mail clients strip",
        origin: c.origin, rules: @[]))
      walk(c, theme, assets, diags)
      replaceChild(parent, c, c.children)
    else:
      walk(c, theme, assets, diags)

proc lowerElements*(root: EmailNode; theme: EmailTheme;
    assets: openArray[AssetRef] = []): seq[EmailDiagnostic] =
  ## P4 in place over `root`'s descendants (`root` itself — the
  ## `mailDocument` — is left for the document lowering). Returns the
  ## diagnostics in document order.
  if root == nil:
    return
  walk(root, theme, assets, result)
