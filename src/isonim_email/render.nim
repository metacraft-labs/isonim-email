## isonim_email/render.nim — the render entries.
##
## `renderEmail` runs a template once inside a fresh reactive root and
## carries the tree through the whole pipeline — pattern expansion,
## validate, layout,
## styles, head, a11y, lint, element and document lowering,
## serialisation — returning the
## `RenderedEmail` record: HTML, plain text, diagnostics, sizes, assets
## and the resolved semantic tree. `renderTree` runs the same pipeline
## over a hand-built tree, and `renderAuthoringTree` runs only the
## template stage, returning the raw tree for pass-level tests.
##
## Every parameter is threaded, none is dropped: the theme resolves
## token colours, the target switches the lowering, the profile weights
## the lint, the strict flag turns collected errors into a raise, and
## the asset store resolves the images the tree references. The same
## inputs always yield the same bytes: attribute and style order follow
## tree insertion order end to end.
##
## Backend-independent: tree building plus pure passes, runs on C and JS.

import std/[strutils, tables]
import isonim/core/graph
import ./renderer
import ./target
import ./diagnostics
import ./assets
import ./serialize
import ./style/tokens
import ./lower/document
import ./lower/elements
import ./passes/validate
import ./passes/layout
import ./passes/styles
import ./passes/head
import ./passes/a11y
import ./passes/lint
import ./patterns
import ./primitives

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

export renderer
export target
export diagnostics
export assets
export tokens

type RenderedEmail* = object
  ## One rendered email: the document bytes, the plain-text
  ## alternative, every diagnostic the passes collected, the size
  ## measures, the assets the HTML references, and the resolved
  ## semantic tree (briefs and the text part read from it).
  html*, text*: string
  diagnostics*: seq[EmailDiagnostic]
  htmlBytes*, headCssBytes*: int
  sizeBreakdown*: seq[(string, int)]
  assets*: seq[AssetRef]
  semantic*: EmailNode

proc renderAuthoringTree*[T](tpl: EmailTemplate[T]; data: T): EmailNode =
  ## Runs `tpl` once inside a fresh reactive root and returns the
  ## authoring tree. Signals and memos are legal: one-shot wrappers
  ## run exactly once and nothing observes later writes.
  ##
  ## Asserts the residue invariants before disposing the root: no
  ## `data-hk`, no `data-isonim-*`, no `<script>`, no async resource
  ## the template tracked but never resolved, and no pending async
  ## state (an `AsyncState` signal still `asLoading`, a resource still
  ## pending) that the template read while it ran, and no resource
  ## created under the render's root still pending, whether the template
  ## read it or not. A script, a
  ## hydration attribute or a pending load can never reach email
  ## output, so this raises even when the full render would otherwise
  ## only collect.
  var tree: EmailNode
  var r: EmailRenderer
  var root: OwnerBase
  var probe: ComputationBase
  var disposeRoot: proc()
  try:
    createRoot(proc(dispose: proc()) =
      disposeRoot = dispose
      root = getOwner()
      probe = newAsyncProbe()
      r = newEmailRenderer()
      runWithAsyncProbe(probe, proc() =
        tree = tpl(r, data))
    )
    assertNoReactiveResidue(tree)
    assertNoPendingAsync(r)
    assertNoPendingReads(root, probe, tree)
    assertNoPendingResources(root, tree)
  finally:
    # The probe is unlinked and the root disposed on every path: a
    # template that raises mid-render and a guard that raises after it
    # built must both still run the root's cleanups, or the render
    # leaks.
    releaseAsyncProbe(probe)
    if disposeRoot != nil:
      disposeRoot()
  tree

proc cloneTree*(node: EmailNode; parent: EmailNode = nil): EmailNode =
  ## A deep copy of one tree: kinds, tags, payloads, attributes,
  ## styles and fallback pairs in insertion order, origins, IR fields,
  ## P3's annotations and the pattern expansion mark. The clone feeds
  ## lowering (which moves children into the wrapper cell) while the
  ## original stays whole as the `semantic` tree.
  if node == nil:
    return nil
  result = EmailNode(
    kind: node.kind,
    tag: node.tag,
    text: node.text,
    attrs: node.attrs,
    styles: node.styles,
    fallbacks: node.fallbacks,
    children: @[],
    parent: parent,
    origin: node.origin,
    cond: node.cond,
    priority: node.priority,
    layout: node.layout,
    expanded: node.expanded,
  )
  for c in node.children:
    result.children.add(cloneTree(c, result))

proc isResolvableName(src: string): bool =
  ## True when `src` names a store asset rather than carrying a final
  ## URL: compile-time hashed paths, absolute URLs, `cid:` references
  ## and bare fragments are already resolved and never reach the store.
  if src.len == 0:
    return false
  let lower = src.toLowerAscii()
  if lower.startsWith("cid:") or lower.startsWith("data:"):
    return false
  if "://" in src or src.startsWith("/") or src.startsWith("#"):
    return false
  true

proc isPublishedUrl(url: string): bool =
  ## An absolute https URL with a host: what `AssetStore.publish` must
  ## return.
  let lower = url.toLowerAscii()
  lower.startsWith("https://") and url.len > "https://".len and
    url["https://".len] notin {'/', '?', '#'} and
    not url.contains({' ', '\t', '\r', '\n', '"', '<', '>'})

proc resolveAssets(doc: EmailNode; store: AssetStore): tuple[
    assets: seq[AssetRef]; diagnostics: seq[EmailDiagnostic]] =
  ## P8's asset half. Every `img`/`mailImage` source the tree
  ## references is resolved — a store name through `store.get`, a
  ## compile-time `asset"…"` path through the program's embedded
  ## assets — then published through `store.publish` before the HTML
  ## is serialised, and the node's `src` is rewritten to the URL the
  ## store returned (R-IMG-07: the upload completes before the message
  ## exists). Each distinct asset is listed once, carrying that URL.
  ##
  ## A nil store resolves and publishes nothing: sources stay as
  ## written. An unresolvable name is collected as `E-ASSET-UNKNOWN`,
  ## and a `data:` source as `E-URL-SCHEME` (R-IMG-08 forbids embedded
  ## data URIs). A failing upload hook propagates: sending with an
  ## image that never published is worse than not sending. A publish
  ## that returns no absolute https URL is collected as `E-URL-SCHEME`
  ## (R-IMG-07) and its `src` is left unrewritten and unlisted.
  result = (@[], @[])
  if doc == nil or store == nil:
    return
  var resolved: seq[tuple[src: string; url: string]] = @[]
  var failed: seq[string] = @[]
  var stack: seq[EmailNode] = @[doc]
  while stack.len > 0:
    let node = stack.pop()
    if node == nil:
      continue
    if node.kind == enElement and
        node.tag.toLowerAscii() in ["img", "mailimage"]:
      let src = node.attrs.getOrDefault("src", "")
      var known = ""
      for entry in resolved:
        if entry.src == src:
          known = entry.url
      if known.len > 0:
        node.attrs["src"] = known
      elif src.len > 0 and src notin failed:
        var asset: AssetRef
        var found = false
        let compiled = compiledAssetAt(src)
        if isDataUri(src):
          failed.add(src)
          result.diagnostics.add(EmailDiagnostic(
            severity: sevError, code: codeUrlScheme,
            message: "data: URIs are forbidden (R-IMG-08): '" & src & "'",
            origin: node.origin, rules: @["R-IMG-08"]))
        elif compiled.found:
          asset = compiled.asset
          found = true
        elif isResolvableName(src):
          try:
            asset = store.get(src)
            found = true
          except AssetError as e:
            failed.add(src)
            result.diagnostics.add(toDiagnostic(e.msg,
              origin = node.origin))
        if found:
          let url = store.publish(asset)
          if not isPublishedUrl(url):
            # R-IMG-07: the HTML may only reference what the upload
            # returned, and the upload must return where the image now
            # lives. An empty or non-https answer means it did not.
            failed.add(src)
            result.diagnostics.add(EmailDiagnostic(
              severity: sevError, code: codeUrlScheme,
              message: "publishing asset '" & asset.name & "' returned '" &
                url & "', not an absolute https URL; the upload must " &
                "complete before the HTML references it (R-IMG-07)",
              origin: node.origin, rules: @["R-IMG-07"]))
          else:
            asset.url = url
            resolved.add((src, asset.url))
            node.attrs["src"] = asset.url
            var listed = false
            for a in result.assets:
              if a.url == asset.url:
                listed = true
            if not listed:
              result.assets.add(asset)
    for i in countdown(node.children.high, 0):
      stack.add(node.children[i])

proc firstError(diags: openArray[EmailDiagnostic]): EmailDiagnostic =
  for d in diags:
    if d.severity == sevError:
      return d
  diags[0]

proc renderTree*(doc: EmailNode; theme = defaultTheme();
                target = defaultTarget(); profile = consumer;
                strict = false; assets: AssetStore = nil): RenderedEmail =
  ## Runs the pipeline over `doc`: validate, styles, head, a11y and
  ## lint collect diagnostics; the tree is then cloned, its vocabulary
  ## elements lowered (P4: an element with no lowering is collected as
  ## `E-LOWER-MISSING`, never emitted raw), wrapped in the document
  ## shell and serialised. The original tree is never gutted:
  ## it is returned as `semantic`, carrying the resolved styles and
  ## classes the passes attached.
  ##
  ## Residue (`<script>`, hydration attributes) raises unconditionally
  ## — it must never reach output. Other errors are collected, and
  ## `strict` re-raises the first one; it also raises
  ## `W-CSS-OVER-BUDGET`, since head CSS Gmail is certain to truncate
  ## is an error under `strict` (R-CSS-07), and `W-LAYOUT-MIN-COLUMN`,
  ## a cell row too narrow at 320px (R-TBL-11). The text is empty: the
  ## plain-text pass generates it later, and an honest absence beats
  ## a lossy guess. MIME packaging then sends the HTML alone, never an
  ## empty `text/plain` part (see `toMessage`).
  assertNoReactiveResidue(doc)
  # Patterns expand first, so their expansions go through every pass.
  var diags = expandPatterns(doc, theme, target)
  diags.add(validate(doc))
  # P3 reads the authoring values (P5 rounds percentages to two
  # decimals; the width maths needs them whole) and annotates the tree,
  # so the semantic tree carries the widths too.
  diags.add(solveLayout(doc, theme, target))
  let styled = applyStyles(doc, theme, target, profile)
  diags.add(styled.diagnostics)
  let headRes = assembleHead(styled.head, target,
    columns = columnRules(doc))
  diags.add(headRes.diagnostics)
  diags.add(applyA11y(doc))
  diags.add(lintTree(doc, profile))
  if target.darkMode == dmDesigned:
    # R-DRK-04's dark scheme, as painted by the dark block when it
    # survived the head budget (a dropped block paints nothing dark).
    var darkSurvived = false
    for blk in headRes.blocks:
      if blk.kind == enHeadStyle and blk.priority == darkPriority:
        darkSurvived = true
    if darkSurvived:
      var dark: seq[DarkDecl] = @[]
      for d in styled.head:
        if d.variant == "dark" and d.prop in ["color", "background-color"]:
          dark.add((d.node, d.prop, d.value))
      diags.add(lintDarkContrast(doc, dark))
  let found = resolveAssets(doc, assets)
  diags.add(found.diagnostics)

  # Lowering reads the same tree the passes just walked. P4 lowers the
  # vocabulary elements of the clone (images read their intrinsic
  # size from the assets just published) and collects an error for
  # any element with no lowering; the document shell then wraps it.
  let work = cloneTree(doc)
  diags.add(lowerElements(work, theme, found.assets, target))
  let r = EmailRenderer()
  let sections = r.createElement("div")
  let kids =
    if work == nil: @[]
    else: work.children # Copy: appendChild detaches as it moves.
  for c in kids:
    r.appendChild(sections, c)
  let lowered = lowerDocument(work, sections, headRes.blocks, target)
  # P10 over what is emitted: the closed mso-* list (R-OL-15) and the
  # layout-table depth outside Outlook conditionals (R-TBL-15).
  diags.add(lintMsoProperties(lowered))
  diags.add(lintTableDepth(lowered))
  # The breakdown is counted while the bytes are written (R-SIZE-02),
  # so it partitions the document exactly.
  let (html, sizeBreakdown) = serializeDocumentMeasured(lowered)

  var headCssBytes = 0
  for blk in headRes.blocks:
    if blk.kind == enHeadStyle:
      headCssBytes += blk.text.len
  let htmlBytes = html.len
  diags.add(checkSize(html, target, sizeBreakdown))

  if strict and hasErrors(diags):
    raiseDiagnostic(firstError(diags))
  if strict:
    for d in diags:
      # Warnings `strict` turns into errors: head CSS Gmail will
      # truncate (R-CSS-07), and a cell row too narrow at 320px
      # (R-TBL-11).
      if d.code in [codeCssOverBudget, codeLayoutMinColumn]:
        raiseDiagnostic(d)
  RenderedEmail(
    html: html,
    text: "",
    diagnostics: diags,
    htmlBytes: htmlBytes,
    headCssBytes: headCssBytes,
    sizeBreakdown: sizeBreakdown,
    assets: found.assets,
    semantic: doc,
  )

proc renderEmail*[T](tpl: EmailTemplate[T]; data: T;
                    theme = defaultTheme(); target = defaultTarget();
                    profile = consumer; strict = false;
                    assets: AssetStore = nil): RenderedEmail =
  ## Renders one email: `renderAuthoringTree` plus `renderTree`. The
  ## same template, data, theme, target and profile always yield the
  ## same record, byte for byte.
  renderTree(renderAuthoringTree(tpl, data), theme, target, profile,
    strict, assets)
