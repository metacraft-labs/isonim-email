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
import isonim/core/[types, graph, signals, computation, resource]
import isonim/viewmodel
import ./style/tokens
import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

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

  LayoutBox* = object
    ## P3's annotation of one layout element (`passes/layout.nim`): the
    ## width context it sits in, the px width it occupies, and the px
    ## width its children get. `solved` is false on every node P3 did
    ## not lay out (leaves, and every node of a tree P3 never saw).
    solved*: bool
    container*: int       ## The width context the element sits in (px)
    outer*: int           ## Its own px width: the Outlook ghost width
    box*: int             ## Its content box: the children's width context (px)
    boxExact*: float      ## `box` before truncation (columns and groups pass fractions on)
    percent*: float       ## Column or group desktop width, % of the parent box (0 for px widths)
    pxWidth*: bool        ## True when the author gave the width in px
    inlineItem*: bool     ## Buttons: an item of a `mailCluster`, laid out inline (shrink-to-fit)
    padding*: array[4, int] ## Resolved own padding, top, right, bottom, left (px)
    border*: array[4, int]  ## Resolved own border widths, same order (px)
    className*: string    ## Responsive column class (`e-col-…` / `e-colpx-…`), columns and groups only
    # Rows (a section holding columns, a `mailColumns`) and their columns:
    strategy*: string     ## Rows and their columns: `hybrid`, `fabFour`, `cellsStacking` or `cells`
    gutterPx*: int        ## Rows: the gutter between columns (px; 0 for a section's own columns)
    reversed*: bool       ## Rows and their columns: desktop order reversed (`reverse_on_mobile`)
    rtl*: bool            ## Rows and their columns: the row flows right to left (document, section or reversal)
    stacks*: bool         ## Rows and their columns: the columns stack below the breakpoint
    index*, siblings*: int  ## Columns: position in the row and the row's column count
    deskPercent*: float   ## Columns: the desktop class width in % (the width less its gutter share)
    deskPx*: int          ## Columns: the desktop class width in px (px columns)
    gutter*: array[4, int]  ## Columns: the desktop gutter padding, px, top, right, bottom, left
    gutterClass*: string  ## Columns: the desktop gutter class, "" without a gutter
    gutterCss*: string    ## Columns: the desktop gutter class's padding value
    mobileGap*: int       ## Columns: inline `padding-top` while stacked (the gutter, every column but the first)
    # Layout primitives (`mailBox`, `mailGrid`, `mailCluster`, `mailSidebar`):
    columns*: int         ## Grids: items per desktop row
    items*: int           ## Grids and clusters: the item count
    lastRow*: string      ## Grids: `left`, `center` or `stretch`
    fixedIndex*: int      ## Sidebars: which child (0 or 1) is the fixed side
    fixedPx*: int         ## Sidebars: the fixed side's width (px)
    switchPx*: int        ## Sidebars: `switch_below` (px; 0 = never switches)

  EmailNode* = ref object
    kind*: EmailNodeKind
    tag*: string                  ## Element tag or VML shape name
    text*: string                 ## enText / enRaw payload, enHeadStyle CSS
    attrs*: OrderedTable[string, string] ## Insertion order kept → deterministic output
    styles*: OrderedTable[string, string] ## setStyle(prop, value); variant keys allowed (Tailwind @-prefixed keys)
    fallbacks*: OrderedTable[string, string] ## setStyleWithFallback: prop -> the value written just before `styles[prop]`
    children*: seq[EmailNode]
    parent* {.cursor.}: EmailNode ## Untracked: breaks the parent/child cycle
    origin*: SourceSpan           ## Template file:line for diagnostics
    cond*: string                 ## enMsoIf condition (`mso`, `gte mso 9`, …)
    priority*: int                ## enHeadStyle block priority (head-block assembly order)
    layout*: LayoutBox            ## P3 widths (layout elements only; see `LayoutBox`)
    expanded*: bool               ## A pattern element whose expansion replaced its children (`patterns.nim`)

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
  ## Verbatim node, for hand-built trees and the lowering passes. Inside a
  ## `ui(r)` block, `raw expr` does not call this: the macro routes it to
  ## `appendRawHtml` below.
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

proc appendRawHtml*(r: EmailRenderer; parent: EmailNode; html: string) =
  ## `raw expr` inside a `ui(r)` block: the payload becomes ONE verbatim
  ## `enRaw` node appended to `parent`, never parsed into elements here.
  ## The node takes `parent`'s origin (raw payloads get no element hook of
  ## their own), so a diagnostic about it points at the enclosing element.
  ##
  ## Building never rejects a raw node: `raw` is legal only inside
  ## `mailRaw`, and the validation pass reports any other placement as
  ## E-STRUCT-RAW-OUTSIDE on the assembled tree, where composition across
  ## procs is visible.
  let node = raw(html)
  node.origin = parent.origin
  r.appendChild(parent, node)

proc setAttribute*(r: EmailRenderer; node: EmailNode; name, value: string) =
  node.attrs[name] = value

proc setAttribute*(r: EmailRenderer; node: EmailNode; name: string;
                   value: int) =
  ## An integer prop written bare in a template (`mailGrid(columns = 3)`):
  ## stored as its decimal text, the form every reader parses.
  node.attrs[name] = $value

proc setAttribute*(r: EmailRenderer; node: EmailNode; name: string;
                   value: bool) =
  ## A boolean prop written bare (`mailSection(full_width = true)`):
  ## stored as `true` or `false`, the form every reader compares with.
  node.attrs[name] = $value

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
  ## Sets one declaration. It replaces any earlier value of `prop`,
  ## including a fallback pair set by `setStyleWithFallback`.
  node.styles[prop] = value
  node.fallbacks.del(prop)

proc setStyle*(r: EmailRenderer; node: EmailNode; prop: string;
               value: int) =
  ## A value written as a bare integer (`mailSpacer(height = 24)`,
  ## `font_weight = 700`): stored as its decimal text, which the style
  ## pass reads as CSS reads it (a unitless length is px, a weight is a
  ## weight, a unitless `line-height` is a multiplier).
  r.setStyle(node, prop, $value)

proc setStyleWithFallback*(r: EmailRenderer; node: EmailNode;
                           prop, fallback, value: string) =
  ## A fallback pair (catalogue R-CSS-19): the inline style carries
  ## `prop:fallback;prop:value;`, both declarations, in that order, at
  ## `prop`'s place among the node's declarations. A client that
  ## rejects `value` (an unsupported function) keeps `fallback`; one
  ## that understands both takes the later `value`. A style table holds
  ## one value per property, so the fallback rides beside it and only
  ## the serialiser writes it. For output-side nodes built by lowering:
  ## the style pass, which runs before lowering, never sees it.
  node.styles[prop] = value
  node.fallbacks[prop] = fallback

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
  ##
  ## The column is the element's tag (Nim's 0-based line-info column):
  ## the element start in the `tag(args)` form as in the `tag:` form.
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
  registerAsyncResource(r, instantiationInfo(fullPaths = true))

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

# ----------------------------------------------------------------------------
# Pending async state read by the template (isonim's own primitives)
# ----------------------------------------------------------------------------
#
# An isonim signal registers nowhere when it is created: the owner tree
# records computations and cleanups, not signals or resources. What the
# reactive core does record is every tracked READ: a read made while a
# computation is the current listener lands in that computation's
# `sources`. The render therefore runs the template with a probe
# computation as the listener. Every signal the template body reads
# lands in the probe's sources; reads inside the render effects and
# memos the template creates land in theirs, and those computations are
# owned by the render's root. After the template returns, the guard
# walks the probe plus the root's owned computations and inspects each
# source's current value: an `AsyncState` still `asLoading`, or a
# `ResourceState` still `rsPending`/`rsRefreshing` (what `loading`
# reads), is pending async state that shaped the output — the email
# would carry a spinner — so the render fails.
#
# The probe has no body (`fn` is nil). If the template writes a signal
# it read, the core queues the probe as an observer and
# `updateComputation` returns at once on the nil body, so the template
# never re-runs. The probe is unlinked from every source before the
# root is disposed (`releaseAsyncProbe`), so it outlives no render.
#
# Resources need no read at all: every isonim resource registers its
# state with the owner current at its creation, so after the template
# returns the guard also enumerates the resources created under the
# render's root (`ownedResourceStates`: the root and every computation
# it owns) and fails on any still pending, whether or not the template
# read it — a resource whose `data` alone was read would otherwise put
# its initial value ("Loading…") into the email. The read-tracking above
# is still what catches the rest: an `AsyncState` signal (plain signals
# register nowhere), and a pending resource created OUTSIDE the render
# that the template reads.
#
# Limits, stated plainly: reads made under `untrack`, reads of a memo
# created outside the render whose own sources are pending, and anything
# inside a nested `createRoot` (which clears the listener and is not
# owned by its parent, so neither its reads nor its resources are
# reached) are invisible here. `trackAsync` remains the explicit way to
# register such a load.

proc newAsyncProbe*(): ComputationBase =
  ## A body-less computation used as the listener while a template runs,
  ## so the template's top-level signal reads are recorded. Created under
  ## the current owner but never added to its `owned` list: disposing the
  ## root does not touch it; `releaseAsyncProbe` does.
  ComputationBase(sources: @[], sourceSlots: @[], owned: @[], cleanups: @[],
    owner: getOwner(), state: csClean, pure: true, fn: nil)

proc runWithAsyncProbe*(probe: ComputationBase; fn: proc()) =
  ## Runs `fn` with `probe` as the tracking listener, restoring the
  ## previous listener on every path.
  let prev = Listener
  Listener = probe
  try:
    fn()
  finally:
    Listener = prev

proc releaseAsyncProbe*(probe: ComputationBase) =
  ## Unlinks the probe from every signal it observed.
  if probe != nil:
    cleanNode(probe)

proc pendingStateOf(s: SignalStateBase): string =
  ## The pending state `s` currently holds, named for the diagnostic, or
  ## "" when it holds none (or is not an async-state signal at all).
  if s of SignalState[AsyncState]:
    if SignalState[AsyncState](s).value == asLoading:
      return "AsyncState asLoading"
  elif s of MemoSignalState[AsyncState]:
    if MemoSignalState[AsyncState](s).value == asLoading:
      return "AsyncState asLoading (memo)"
  elif s of SignalState[ResourceState]:
    let v = SignalState[ResourceState](s).value
    if v in {rsPending, rsRefreshing}:
      return "resource state " & $v
  elif s of MemoSignalState[ResourceState]:
    let v = MemoSignalState[ResourceState](s).value
    if v in {rsPending, rsRefreshing}:
      return "resource state " & $v & " (memo)"
  ""

proc findPendingRead(o: OwnerBase): string =
  ## Depth-first over `o` and everything it owns: the first pending
  ## state some computation read, or "".
  if o == nil:
    return ""
  if o of ComputationBase:
    for s in ComputationBase(o).sources:
      let found = pendingStateOf(s)
      if found.len > 0:
        return found
  for child in o.owned:
    let found = findPendingRead(child)
    if found.len > 0:
      return found
  ""

proc assertNoPendingResources*(root: OwnerBase; tree: EmailNode) =
  ## Fails the render when a resource created under `root` — in the
  ## template body or inside any computation the root owns — is still
  ## pending (`rsPending`/`rsRefreshing`), read or not. Run before the
  ## root is disposed (disposal clears the record). Raises
  ## `EmailRenderError` (E-STRUCT-REACTIVE-RESIDUE) naming the state and
  ## the template's root element.
  for s in ownedResourceStates(root):
    let v = s.value
    if v in {rsPending, rsRefreshing}:
      let where =
        if tree == nil: "unknown location"
        else: $tree.origin
      raise newException(EmailRenderError,
        "E-STRUCT-REACTIVE-RESIDUE: a resource the template created is " &
        "still pending (resource state " & $v & ") at render time, in " &
        "the template rooted at " & where & " (resolve async resources " &
        "before rendering email; an email cannot show a spinner)")

proc assertNoPendingReads*(root: OwnerBase; probe: ComputationBase;
                           tree: EmailNode) =
  ## Fails the render when the template (through `probe`) or any
  ## computation owned by `root` read async state that is still pending.
  ## Raises `EmailRenderError` (E-STRUCT-REACTIVE-RESIDUE) naming the
  ## pending state and the template's root element.
  var found = findPendingRead(probe)
  if found.len == 0:
    found = findPendingRead(root)
  if found.len > 0:
    let where =
      if tree == nil: "unknown location"
      else: $tree.origin
    raise newException(EmailRenderError,
      "E-STRUCT-REACTIVE-RESIDUE: the template read pending async state (" &
      found & ") at render time, in the template rooted at " & where &
      " (resolve async resources before rendering email; an email cannot " &
      "show a spinner)")
