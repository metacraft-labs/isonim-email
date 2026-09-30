## isonim_email/renderer.nim — EmailRenderer, the email tree builder.
##
## `EmailRenderer` implements the `checkRendererBackend[B, E]` contract
## (`isonim/renderers/abstract_renderer.nim`) following the `MockRenderer` /
## `MockNode` (`isonim/testing/mock_dom.nim`) and `TerminalRenderer`
## (`isonim-tui`) precedent: an in-memory tree of `EmailNode`s built by the
## renderer-mode `ui(r)` macro.
##
## Scope: ordered attributes and styles, a `SourceSpan` origin on every
## node, raw nodes, `addEventListener` as a compile-time error, and the
## residue guards the render entries run before disposing the root.
## Lowering passes, vocabulary and diagnostics are layered on separately;
## until then violations raise `EmailRenderError` with the stable
## diagnostic codes. The render entries themselves
## (`renderAuthoringTree`, `renderEmail`) live in `render.nim`, which
## threads the theme, target, profile, strict flag and asset store.

import std/[strutils, tables]
import isonim/renderers/abstract_renderer
import isonim/core/owner
import isonim/viewmodel
import ./style/tokens

export abstract_renderer
export owner
export viewmodel

type
  SourceSpan* = object
    ## Template location carried by every node for diagnostics.
    file*: string
    line*, col*: int

  EmailNodeKind* = enum
    enElement   ## Authoring element (`mailSection`, `p`, `div`, …) or lowered HTML
    enText      ## Escaped text payload
    enRaw       ## Verbatim payload (only valid inside `mailRaw`; the validation pass checks this)
    enMsoIf     ## IR: `<!--[if <cond>]> … <![endif]-->` (R-OL-01)
    enNotMso    ## IR: `<!--[if !mso]><!--> … <!--<![endif]-->` (R-OL-01)
    enVml       ## IR: a VML shape; `tag` holds the shape name (`v:rect`, …)
    enHeadStyle ## IR: one `<style>` block; `text` holds the CSS

  EmailNode* = ref object
    kind*: EmailNodeKind
    tag*: string                  ## Element tag or VML shape name
    text*: string                 ## enText / enRaw payload, enHeadStyle CSS
    attrs*: OrderedTable[string, string] ## Insertion order kept → deterministic output
    styles*: OrderedTable[string, string] ## setStyle(prop, value); variant keys allowed (Tailwind @-prefixed keys)
    children*: seq[EmailNode]
    parent* {.cursor.}: EmailNode ## Untracked: breaks the parent/child cycle
    origin*: SourceSpan           ## Template file:line for diagnostics
    cond*: string                 ## enMsoIf condition (`mso`, `gte mso 9`, …)
    priority*: int                ## enHeadStyle block priority (head-block assembly order)

  EmailAsyncResource* = ref object
    ## One async load a template started. Created pending (`asLoading`)
    ## by `trackAsync`, which stamps the call site; the template sets
    ## `state` to `asReady` or `asError` once the load resolves. Anything
    ## still pending when the render disposes its root fails the render.
    state*: AsyncState
    origin*: SourceSpan

  AsyncRegistry = ref object
    ## The render-owned set of tracked resources. A ref so every copy of
    ## the renderer value registers into the same render; only renders
    ## own one (see `newEmailRenderer`), so nothing leaks across renders.
    resources: seq[EmailAsyncResource]

  EmailRenderer* = object
    ## Email tree builder. Value type like `MockRenderer`: the tree holds
    ## the nodes, and `asyncReg` — nil on a bare renderer, a shared ref
    ## on one a render owns — collects the template's async resources.
    ## (There is deliberately no `diagnostics` field: violations raise
    ## `EmailRenderError` instead of collecting.)
    asyncReg: AsyncRegistry

  EmailRenderError* = object of ValueError
    ## Render-time violation carrying a stable diagnostic code in its
    ## message (e.g. `E-STRUCT-REACTIVE-RESIDUE`). Raised by the render
    ## entries, `assertNoReactiveResidue`, the IR constructors and the
    ## serialiser until the diagnostics pipeline lands.

  EmailTemplate*[T] = proc (r: EmailRenderer; data: T): EmailNode
    ## A template is an ordinary Nim proc, not generic: only
    ## `EmailRenderer` can lower `mail*` elements.

proc initEmailNode(kind: EmailNodeKind; origin = SourceSpan()): EmailNode =
  ## `origin` defaults to empty. The `ui(r)` macro fills element origins
  ## itself through the `noteElement` hook right after creation, so
  ## `createElement` needs no lineinfo of its own; hand-written builders
  ## pass real spans, and diagnostics print `unknown location` for the
  ## empty ones (text nodes, raw nodes, macro-synthesised wrappers).
  EmailNode(
    kind: kind,
    attrs: initOrderedTable[string, string](),
    styles: initOrderedTable[string, string](),
    children: @[],
    origin: origin,
  )

# ----------------------------------------------------------------------------
# Required RendererBackend procs (the conformance surface)
# ----------------------------------------------------------------------------

proc createElement*(r: EmailRenderer; tag: string): EmailNode =
  result = initEmailNode(enElement)
  result.tag = tag

proc createTextNode*(r: EmailRenderer; text: string): EmailNode =
  result = initEmailNode(enText)
  result.text = text

proc raw*(s: string): EmailNode =
  ## Verbatim node. The renderer-mode `ui(r)` macro emits `raw(x)` as a plain
  ## Nim call, so this proc must be in scope where templates are written
  ## (re-exported through the `isonim_email` umbrella).
  result = initEmailNode(enRaw)
  result.text = s

proc detach(child: EmailNode) =
  if child.parent != nil:
    let oldParent = child.parent
    var oldIdx = -1
    for i, c in oldParent.children:
      if c == child:
        oldIdx = i
        break
    if oldIdx >= 0:
      oldParent.children.delete(oldIdx)
    child.parent = nil

proc appendChild*(r: EmailRenderer; parent, child: EmailNode) =
  ## Browser `appendChild` semantics (mock_dom parity): a child that is
  ## already attached is detached first, then appended.
  detach(child)
  child.parent = parent
  parent.children.add(child)

proc insertBefore*(r: EmailRenderer; parent, child, reference: EmailNode) =
  ## Browser `insertBefore` semantics (mock_dom parity): detach first,
  ## then insert at the reference's slot, or append when the reference is
  ## absent (including `nil`).
  detach(child)
  child.parent = parent
  var idx = -1
  if reference != nil:
    for i, c in parent.children:
      if c == reference:
        idx = i
        break
  if idx >= 0:
    parent.children.insert(child, idx)
  else:
    parent.children.add(child)

proc removeChild*(r: EmailRenderer; parent, child: EmailNode) =
  child.parent = nil
  var idx = -1
  for i, c in parent.children:
    if c == child:
      idx = i
      break
  if idx >= 0:
    parent.children.delete(idx)

proc setAttribute*(r: EmailRenderer; node: EmailNode; name, value: string) =
  node.attrs[name] = value

proc removeAttribute*(r: EmailRenderer; node: EmailNode; name: string) =
  node.attrs.del(name)

proc setTextContent*(r: EmailRenderer; node: EmailNode; text: string) =
  if node.kind in {enText, enRaw, enHeadStyle}:
    node.text = text
  else:
    for c in node.children:
      c.parent = nil
    node.children.setLen(0)
    let textNode = initEmailNode(enText, node.origin)
    textNode.text = text
    textNode.parent = node
    node.children.add(textNode)

proc setStyle*(r: EmailRenderer; node: EmailNode; prop, value: string) =
  node.styles[prop] = value

proc setStyle*(r: EmailRenderer; node: EmailNode; prop: string;
               token: TokenRef) =
  ## A `tok"…"` style value: stored as a `tok:<key>` sentinel — no CSS
  ## value ever starts with `tok:` — and resolved against the render's
  ## theme by P5 (`passes/styles.nim`), which also reads the sentinel
  ## to tell token colours from raw ones.
  node.styles[prop] = "tok:" & token.key

template addEventListener*(r: EmailRenderer; node: EmailNode;
                           event: static string; handler: untyped) =
  ## Email cannot carry event handlers: any `on*` attribute in a template is
  ## a compile-time error (E-VOCAB-EVENT-HANDLER; the static
  ## vocabulary check enforces it for real).
  ##
  ## The empty event name is reserved for the `checkRendererBackend`
  ## conformance probe, which passes `""`: it expands to a no-op so the probe
  ## type-checks. This carve-out is safe because the `ui(r)` macro only emits
  ## `addEventListener` for `on*` attributes, whose event names are never
  ## empty (`isEventHandler` requires more than the bare `on` prefix).
  ##
  ## A plain `{.error.}` proc cannot be used here: on Nim 2.2.4 an `{.error.}`
  ## call inside a generic body aborts compilation even under `compiles()`,
  ## so it would make `checkRendererBackend[EmailRenderer, EmailNode]` itself
  ## uncompilable instead of proving conformance.
  when event == "":
    discard
  else:
    {.error: "E-VOCAB-EVENT-HANDLER: email cannot carry event handlers " &
      "(event '" & event &
      "'): remove the on* attribute or move it to a web-only branch".}

proc firstChild*(r: EmailRenderer; node: EmailNode): EmailNode =
  if node == nil or node.children.len == 0: nil
  else: node.children[0]

proc nextSibling*(r: EmailRenderer; node: EmailNode): EmailNode =
  if node == nil or node.parent == nil: return nil
  let siblings = node.parent.children
  for i, c in siblings:
    if c == node and i + 1 < siblings.len:
      return siblings[i + 1]
  return nil

proc parentNode*(r: EmailRenderer; node: EmailNode): EmailNode =
  if node == nil: nil else: node.parent

proc parseSourceSpan*(loc: string): SourceSpan =
  ## Parses one `file:line:col` element location from the `ui(r)` macro's
  ## per-element hook into a span. Split from the right so a filename
  ## containing `:` still parses; anything unparsable yields an empty span
  ## (rendered as `unknown location`) rather than raising.
  let lastSep = loc.rfind(':')
  if lastSep < 0:
    return SourceSpan()
  let midSep = loc[0 ..< lastSep].rfind(':')
  if midSep < 0:
    return SourceSpan()
  var lineNum, colNum: int
  try:
    lineNum = parseInt(loc[midSep + 1 ..< lastSep])
    colNum = parseInt(loc[lastSep + 1 .. ^1])
  except ValueError:
    return SourceSpan()
  if lineNum <= 0 or colNum < 0:
    return SourceSpan()
  SourceSpan(file: loc[0 ..< midSep], line: lineNum, col: colNum)

proc noteElement*(el: EmailNode; id, tag, loc, parentId: string) =
  ## The `ui(r)` macro's per-element hook, typed on the email element
  ## handle: overload resolution prefers this over the macro's own untyped
  ## seam, so every element a template creates carries the macro's
  ## lineinfo in its origin. Only `loc` is read; the scene-graph id, tag
  ## and parent id are accepted and ignored. Text nodes have no hook call
  ## and keep empty origins.
  el.origin = parseSourceSpan(loc)

# ----------------------------------------------------------------------------
# Compile-time conformance (the isonim-tui idiom)
# ----------------------------------------------------------------------------

when not compiles(checkRendererBackend[EmailRenderer, EmailNode]()):
  {.error: "EmailRenderer does not implement RendererBackend".}

# ----------------------------------------------------------------------------
# Residue guards (run by the render entries in render.nim)
# ----------------------------------------------------------------------------

const reactiveResidueAttrs = ["data-hk"]
  ## Attribute names that must never appear in an email tree, plus the
  ## `data-isonim-` prefix checked separately below.

proc isResidueAttr(name: string): bool =
  if name in reactiveResidueAttrs:
    return true
  name.len > 12 and name[0 .. 11] == "data-isonim-"

proc `$`*(s: SourceSpan): string =
  ## `file:line:col`, or `unknown location` for empty spans (text nodes,
  ## raw nodes and hand-built trees without an explicit origin).
  if s.file.len == 0:
    "unknown location"
  else:
    s.file & ":" & $s.line & ":" & $s.col

proc assertNoReactiveResidue*(node: EmailNode) =
  ## The residue check, run by the render entries on every template
  ## output: no `data-hk`, no `data-isonim-*`, no `<script>`. Raises
  ## `EmailRenderError` (E-STRUCT-REACTIVE-RESIDUE) naming the template
  ## origin of the offending node.
  if node == nil:
    return
  if node.kind == enElement and node.tag == "script":
    raise newException(EmailRenderError,
      "E-STRUCT-REACTIVE-RESIDUE: <script> in email tree at " & $node.origin &
      " (email cannot carry scripts)")
  for name in node.attrs.keys:
    if isResidueAttr(name):
      raise newException(EmailRenderError,
        "E-STRUCT-REACTIVE-RESIDUE: hydration attribute '" & name &
        "' in email tree at " & $node.origin &
        " (no data-hk / data-isonim-* in email output)")
  for child in node.children:
    assertNoReactiveResidue(child)

proc assertNoPendingAsync*(states: openArray[AsyncState]) =
  ## Async resources must be resolved before rendering: an email cannot
  ## show a spinner. `asLoading` raises; `asIdle` (nothing started),
  ## `asReady` and `asError` pass — the last two are resolved.
  for st in states:
    if st == asLoading:
      raise newException(EmailRenderError,
        "E-STRUCT-REACTIVE-RESIDUE: pending async resource (asLoading) at " &
        "render time (resolve async resources before rendering email)")

proc newEmailRenderer*(): EmailRenderer =
  ## A renderer that owns an async registry. `renderAuthoringTree` builds
  ## templates with this so resources a template tracks register against
  ## the render; every copy of the value shares the one registry.
  EmailRenderer(asyncReg: AsyncRegistry(resources: @[]))

proc registerAsyncResource(r: EmailRenderer;
    loc: tuple[filename: string, line: int, column: int]): EmailAsyncResource =
  ## Records one pending resource against the render that owns `r`. Called
  ## by `trackAsync`, which captures the call site. Raises when `r` owns
  ## no registry: a bare `EmailRenderer()` outside a render has nothing to
  ## register against, and silently dropping the resource would hide a
  ## pending load instead of failing the render.
  if r.asyncReg == nil:
    raise newException(ValueError,
      "trackAsync outside a render: build the renderer with " &
      "newEmailRenderer (renderEmail does this) so the resource registers " &
      "against the render")
  result = EmailAsyncResource(state: asLoading,
    origin: SourceSpan(file: loc.filename, line: loc.line, col: loc.column))
  r.asyncReg.resources.add(result)

template trackAsync*(r: EmailRenderer): EmailAsyncResource =
  ## Starts one async load inside a template and registers it against the
  ## render that owns `r`, stamped with this call's file:line. The
  ## resource starts pending; set `state` to `asReady` or `asError` once
  ## it resolves — anything still pending when the render disposes its
  ## root fails the render, citing this call site.
  registerAsyncResource(r, instantiationInfo())

proc assertNoPendingAsync*(r: EmailRenderer) =
  ## The render-owned half of the async guard: every resource the
  ## template tracked against this render must have resolved. A bare
  ## renderer (no registry) or an empty registry passes; the first
  ## still-pending resource raises, citing its `trackAsync` call site.
  if r.asyncReg == nil:
    return
  for res in r.asyncReg.resources:
    if res.state == asLoading:
      raise newException(EmailRenderError,
        "E-STRUCT-REACTIVE-RESIDUE: pending async resource (asLoading) at " &
        $res.origin & " (resolve async resources before rendering email)")
