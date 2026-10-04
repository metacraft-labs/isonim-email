## isonim_email/stories.nim — the story registry.
##
## A story is a named template plus fixed data. One registry drives
## `just email-shots`, the golden tests, the preview server and the
## IsoNim editor's story contract.
##
## The public surface is the `story` template (register a template
## with its fixture data, optionally overriding the target and the
## audience profile) and the `stories` iterator. `registerStory`,
## `listStories`, `hasStory` and `getStory` are the registry plumbing
## underneath, used by the capture and review drivers and by stories
## whose bytes are pinned by hand-built trees.
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
import ./render
import ./serialize
import ./target
import ./diagnostics
import ./assets
import ./lower/document
import ./lower/elements
import ./passes/validate
import ./passes/layout
import ./passes/styles
import ./passes/head
import ./passes/a11y
import ./style/tokens
import ./patterns
import ./primitives
import ./navigation
import ./content
import ./text

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  StoryHtml* = tuple[html, text: string]
    ## One rendered story: the full document plus its plain-text
    ## alternative.

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

  StoryEntry* = Story
    ## What the `stories` iterator yields.

  StoryError* = object of ValueError
    ## Duplicate registration, unknown story, or a story whose tree
    ## fails validation (stories are fixed, so that is a bug).

  StoryRender* = object
    ## One story rendered for a reader of its diagnostics (the preview
    ## server, the IsoNim editor): the document and its text part, every
    ## diagnostic the render collected, and the error that refused it
    ## (`error` empty when it rendered).
    html*, text*: string
    diagnostics*: seq[EmailDiagnostic]
    error*: string

var storyRegistry: OrderedTable[string, Story]

var storyDiagnostics: seq[EmailDiagnostic]
  ## What the story being rendered by `renderStoryDiagnosed` collected:
  ## the render paths below add to it as they go, so a story refused
  ## part-way still shows what was found before the refusal.
var collectingStoryDiagnostics = false
  ## True only inside `renderStoryDiagnosed`: a story rendered any other
  ## way (the capture driver, a golden test) keeps nothing.

proc noteStoryDiagnostics*(found: openArray[EmailDiagnostic]) =
  ## Adds `found` to the diagnostics of the story being rendered. A
  ## story whose render closure runs its own pipeline (a reference
  ## email through `renderEmail`) calls this with that render's
  ## diagnostics; `renderStoryPipeline` and the `story` template do it
  ## themselves. Outside `renderStoryDiagnosed` they are not kept.
  if collectingStoryDiagnostics:
    storyDiagnostics.add(found)

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

iterator stories*(): StoryEntry =
  ## Every registered story, in registration order.
  for entry in storyRegistry.values:
    yield entry

proc groupOf(name: string): string =
  ## The editor-contract group: the part of `name` before the first
  ## `/` (`invoiceReady/typical` → `invoiceReady`), or all of it.
  let slash = name.find('/')
  if slash < 0: name
  else: name[0 ..< slash]

proc templateStory*[T](name: string; tpl: EmailTemplate[T]; data: T;
                       target: EmailTarget;
                       profile: AudienceProfile): Story =
  ## The `Story` the `story` template registers: `render` runs the full
  ## `renderEmail` pipeline on the fixture data with the overrides.
  let render = proc(): StoryHtml {.closure.} =
    let res = renderEmail(tpl, data, target = target, profile = profile)
    noteStoryDiagnostics(res.diagnostics)
    (res.html, res.text)
  Story(name: name, group: groupOf(name), description: "",
    render: render)

template story*(name: static string; tpl: typed; data: typed) =
  ## Registers the template `tpl` with its fixture `data` under `name`
  ## (default target and the consumer profile). A duplicate name
  ## raises `StoryError`.
  registerStory(templateStory(name, tpl, data, defaultTarget(), consumer))

template story*(name: static string; tpl: typed; data: typed;
                body: untyped) =
  ## As above, with overrides: `body` runs once, at registration, with
  ## `target` (an `EmailTarget`, default `defaultTarget()`) and
  ## `profile` (an `AudienceProfile`, default `consumer`) in scope as
  ## variables, e.g. `story("alert/no-dark", alertTpl, data): target.darkMode = dmNone`.
  block:
    var target {.inject.} = defaultTarget()
    var profile {.inject.} = consumer
    body
    registerStory(templateStory(name, tpl, data, target, profile))

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

proc renderStoryDiagnosed*(story: Story): StoryRender =
  ## Runs `story` and returns its HTML and text with every diagnostic
  ## its render collected. A `StoryError` (a story refused for an error
  ## its render found) is returned in `error`, not raised, with the
  ## diagnostics found up to it: the preview server and the editor show
  ## a broken story instead of stopping at it.
  let outer = storyDiagnostics
  let wasCollecting = collectingStoryDiagnostics
  storyDiagnostics = @[]
  collectingStoryDiagnostics = true
  try:
    let (html, text) = story.render()
    result.html = html
    result.text = text
  except StoryError as e:
    result.error = e.msg
  finally:
    result.diagnostics = storyDiagnostics
    storyDiagnostics = outer
    collectingStoryDiagnostics = wasCollecting

proc renderStoryPipeline*(doc: EmailNode; target: EmailTarget;
    assets: AssetStore = nil): StoryHtml =
  ## The current render path (lower/document.nim over the passes):
  ## pattern expansion → validate → P3 layout → P5 styles → P6 head → P7 a11y →
  ## P8 assets → P12 plain text → P4 element lowering,
  ## then the document shell and the serialiser. With `assets`, the
  ## images are published through the store before lowering (R-IMG-07).
  ## The `mailDocument`
  ## node's own children become the wrapper-cell sections. Raises
  ## `StoryError` when the tree fails validation or holds an element
  ## with no lowering (`E-LOWER-MISSING`), or when its plain-text part
  ## would be empty (`E-TEXT-EMPTY`): stories are fixed, so any of
  ## them is a bug in the story. Every pass's diagnostics are noted for
  ## `renderStoryDiagnosed` (this path runs no P10 lint: a story's
  ## warnings are what these passes report).
  var found = expandPatterns(doc, defaultTheme(), target)
  found.add(validate(doc))
  noteStoryDiagnostics(found)
  if hasErrors(found):
    raise newException(StoryError,
      "story tree failed validation: " & $found.len &
        " diagnostic(s), first: " & found[0].message)
  let laid = solveLayout(doc, defaultTheme(), target)
  noteStoryDiagnostics(laid)
  if hasErrors(laid):
    raise newException(StoryError,
      "story tree failed layout: " & laid[0].code & ": " & laid[0].message)
  let styled = applyStyles(doc, defaultTheme(), target)
  noteStoryDiagnostics(styled.diagnostics)
  let fonts = webFontRules(target, defaultTheme())
  noteStoryDiagnostics(fonts.diagnostics)
  if hasErrors(fonts.diagnostics):
    raise newException(StoryError,
      "story web fonts: " & fonts.diagnostics[0].message)
  let headRes = assembleHead(styled.head, target, webfonts = fonts.faces,
    msoRules = fonts.mso, columns = columnRules(doc),
    swaps = darkSwapImages(doc))
  noteStoryDiagnostics(headRes.diagnostics)
  noteStoryDiagnostics(applyA11y(doc))
  # With a store, every image is published first and its `src` is the
  # URL the store returned (a story's built-in icons, for one).
  let published = resolveAssets(doc, assets)
  noteStoryDiagnostics(published.diagnostics)
  if hasErrors(published.diagnostics):
    raise newException(StoryError, "story assets: " &
      published.diagnostics[0].message)
  let urls = checkBackgroundUrls(doc)
  noteStoryDiagnostics(urls)
  if hasErrors(urls):
    raise newException(StoryError, "story background: " & urls[0].message)
  # P12 reads the semantic tree, before lowering rewrites it in place.
  let plain = renderText(doc)
  noteStoryDiagnostics(plain.diagnostics)
  if hasErrors(plain.diagnostics):
    raise newException(StoryError, "story text: " &
      plain.diagnostics[0].message)
  let lowered = lowerElements(doc, defaultTheme(), published.assets,
    target = target)
  noteStoryDiagnostics(lowered)
  if hasErrors(lowered):
    var first = lowered[0]
    for d in lowered:
      if d.severity == sevError:
        first = d
        break
    raise newException(StoryError,
      "story tree failed lowering: " & first.code & ": " & first.message)
  let r = EmailRenderer()
  let sections = r.createElement("div")
  let kids = doc.children # Copy: appendChild detaches as it moves.
  for c in kids:
    r.appendChild(sections, c)
  (serializeDocument(lowerDocument(doc, sections, headRes.blocks, target)),
    plain.text)

proc renderPipeline*(doc: EmailNode; target: EmailTarget;
    assets: AssetStore = nil): string =
  ## `renderStoryPipeline`'s HTML.
  renderStoryPipeline(doc, target, assets).html

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

proc renderCanary*(): StoryHtml =
  ## Renders the canary through the current pipeline.
  renderStoryPipeline(canaryDoc(), defaultTarget())

proc canaryStory*(): Story =
  ## The canary as a registry entry.
  Story(name: "canary", group: "canary",
    description: "Fixed minimal document for determinism checks.",
    render: renderCanary)
