## isonim_email/stories.nim — the story registry.
##
## A story is a named template plus fixed data. One registry drives
## `just email-shots`, the golden tests, the preview server and the
## IsoNim editor's story contract.
##
## Shape mirrors the editor contract (`isonim/editor/types.nim`:
## `StoryRef` group/name + `StoryItem` description) where it fits; the
## deliberate deviation is that template proc + fixed data are fused
## into a single `render` closure, because capture and goldens need
## only bytes — a live preview can re-split template from data.
##
## Pure tree building plus pure passes: identical on the C and JS
## targets.

import std/[strutils, tables]
import ./renderer
import ./serialize
import ./target
import ./diagnostics
import ./lower/document
import ./passes/validate
import ./passes/styles
import ./passes/head
import ./passes/a11y
import ./style/tokens

type
  StoryHtml* = tuple[html, text: string]
    ## One rendered story: the full document plus its plain-text
    ## alternative (the plain-text generator will produce these;
    ## until then each story carries a fixed literal).

  StoryRenderProc* = proc(): StoryHtml {.closure.}
    ## Template proc + fixed data, fused (see the module comment).

  Story* = object
    ## A registered story: `name` is the registry key (later
    ## `group/variant`, e.g. `invoiceReady/typical`); `group` is the
    ## editor-contract group; `render` runs the current pipeline.
    name*: string
    group*: string
    description*: string
    render*: StoryRenderProc

  StoryError* = object of ValueError
    ## Duplicate registration, unknown story, or a story whose tree
    ## fails validation (stories are fixed, so that is a bug).

var storyRegistry: OrderedTable[string, Story]

proc registerStory*(story: Story) =
  ## Registers `story`. A duplicate name raises `StoryError` — two
  ## templates must never share a key silently.
  if story.name.len == 0:
    raise newException(StoryError, "story name must not be empty")
  if story.name in storyRegistry:
    raise newException(StoryError,
      "duplicate story '" & story.name & "'")
  if story.render == nil:
    raise newException(StoryError,
      "story '" & story.name & "' has no render proc")
  storyRegistry[story.name] = story

proc listStories*(): seq[string] =
  ## Registry keys in registration order.
  result = @[]
  for name in storyRegistry.keys:
    result.add(name)

proc hasStory*(name: string): bool =
  ## True when `name` is registered.
  name in storyRegistry

proc getStory*(name: string): Story =
  ## Looks up `name`, raising `StoryError` when it is unknown.
  if name notin storyRegistry:
    raise newException(StoryError, "unknown story '" & name &
      "' (registered: " & listStories().join(", ") & ")")
  storyRegistry[name]

proc renderPipeline*(doc: EmailNode; target: EmailTarget): string =
  ## The current render path (lower/document.nim over the passes):
  ## validate → P5 styles → P6 head → P7 a11y, then the document
  ## shell and the serialiser. The `mailDocument` node's
  ## own children become the wrapper-cell sections. Raises
  ## `StoryError` when the tree fails validation.
  let found = validate(doc)
  if hasErrors(found):
    raise newException(StoryError,
      "story tree failed validation: " & $found.len &
        " diagnostic(s), first: " & found[0].message)
  let styled = applyStyles(doc, defaultTheme(), target)
  let headRes = assembleHead(styled.head, target)
  discard applyA11y(doc)
  let r = EmailRenderer()
  let sections = r.createElement("div")
  let kids = doc.children # Copy: appendChild detaches as it moves.
  for c in kids:
    r.appendChild(sections, c)
  serializeDocument(lowerDocument(doc, sections, headRes.blocks, target))

proc canaryDoc*(): EmailNode =
  ## The canary: a fixed minimal document (no images, no tokens) for
  ## determinism checks and the latency reference story.
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Canary")
  r.setAttribute(doc, "preheader", "The canary sings at noon.")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Canary")
  r.appendChild(doc, h1)
  let p = r.createElement("p")
  r.setTextContent(p, "The canary sings at noon.")
  r.appendChild(doc, p)
  doc

const canaryText* = "Canary\n\nThe canary sings at noon.\n"
  ## The canary's fixed plain-text alternative (the plain-text
  ## generator will produce these).

proc renderCanary*(): StoryHtml =
  ## Renders the canary through the current pipeline.
  (renderPipeline(canaryDoc(), defaultTarget()), canaryText)

proc canaryStory*(): Story =
  ## The canary as a registry entry.
  Story(name: "canary", group: "canary",
    description: "Fixed minimal document for determinism checks.",
    render: renderCanary)
