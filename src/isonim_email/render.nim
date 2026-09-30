## isonim_email/render.nim — the render entries.
##
## `renderEmail` runs a template once inside a fresh reactive root and
## carries the tree through the whole pipeline — validate, styles, head,
## a11y, lint, document lowering, serialisation — returning the
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
import ./renderer
import ./target
import ./diagnostics
import ./assets
import ./serialize
import ./style/tokens
import ./lower/document
import ./passes/validate
import ./passes/styles
import ./passes/head
import ./passes/a11y
import ./passes/lint

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
  ## `data-hk`, no `data-isonim-*`, no `<script>`, and no async resource
  ## the template tracked but never resolved. A script, a hydration
  ## attribute or a pending load can never reach email output, so this
  ## raises even when the full render would otherwise only collect.
  var tree: EmailNode
  var r: EmailRenderer
  var disposeRoot: proc()
  try:
    createRoot(proc(dispose: proc()) =
      disposeRoot = dispose
      r = newEmailRenderer()
      tree = tpl(r, data)
    )
    assertNoReactiveResidue(tree)
    assertNoPendingAsync(r)
  finally:
    # The root is disposed on every path: a template that raises
    # mid-render and a guard that raises after it built must both
    # still run the root's cleanups, or the render leaks.
    if disposeRoot != nil:
      disposeRoot()
  tree

proc cloneTree(node: EmailNode; parent: EmailNode = nil): EmailNode =
  ## A deep copy of one tree: kinds, tags, payloads, attributes and
  ## styles in insertion order, origins and IR fields. The clone feeds
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
    children: @[],
    parent: parent,
    origin: node.origin,
    cond: node.cond,
    priority: node.priority,
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

proc collectAssets(doc: EmailNode; store: AssetStore): tuple[
    assets: seq[AssetRef]; diagnostics: seq[EmailDiagnostic]] =
  ## Every distinct `img`/`mailImage` source the tree references,
  ## resolved through the store. A nil store resolves nothing (the
  ## render keeps the sources as written); an unresolvable name is
  ## collected as `E-ASSET-UNKNOWN`, and a `data:` source as
  ## `E-URL-SCHEME` (R-IMG-08 forbids embedded data URIs).
  result = (@[], @[])
  if doc == nil or store == nil:
    return
  var seen: seq[string] = @[]
  var stack: seq[EmailNode] = @[doc]
  while stack.len > 0:
    let node = stack.pop()
    if node == nil:
      continue
    if node.kind == enElement and
        node.tag.toLowerAscii() in ["img", "mailimage"]:
      let src = node.attrs.getOrDefault("src", "")
      if src.len > 0 and src notin seen:
        seen.add(src)
        if isDataUri(src):
          result.diagnostics.add(EmailDiagnostic(
            severity: sevError, code: codeUrlScheme,
            message: "data: URIs are forbidden (R-IMG-08): '" & src & "'",
            origin: node.origin, rules: @["R-IMG-08"]))
        elif isResolvableName(src):
          try:
            result.assets.add(store.get(src))
          except AssetError as e:
            result.diagnostics.add(toDiagnostic(e.msg,
              origin = node.origin))
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
  ## lint collect diagnostics; the tree is then cloned, lowered to the
  ## document shell and serialised. The original tree is never gutted:
  ## it is returned as `semantic`, carrying the resolved styles and
  ## classes the passes attached.
  ##
  ## Residue (`<script>`, hydration attributes) raises unconditionally
  ## — it must never reach output. Other errors are collected, and
  ## `strict` re-raises the first one. The text part is empty: the
  ## plain-text pass generates it later, and an honest empty part
  ## beats a lossy guess. MIME packaging carries it through unchanged.
  assertNoReactiveResidue(doc)
  var diags = validate(doc)
  let styled = applyStyles(doc, theme, target)
  diags.add(styled.diagnostics)
  let headRes = assembleHead(styled.head, target)
  diags.add(headRes.diagnostics)
  diags.add(applyA11y(doc))
  diags.add(lintTree(doc, profile))
  let found = collectAssets(doc, assets)
  diags.add(found.diagnostics)

  # Lowering reads the same tree the passes just walked; a failure
  # here aborts the render either way, so strict changes nothing.
  let work = cloneTree(doc)
  let r = EmailRenderer()
  let sections = r.createElement("div")
  let kids =
    if work == nil: @[]
    else: work.children # Copy: appendChild detaches as it moves.
  for c in kids:
    r.appendChild(sections, c)
  let html = serializeDocument(lowerDocument(work, sections,
    headRes.blocks, target))

  var headCssBytes = 0
  for blk in headRes.blocks:
    if blk.kind == enHeadStyle:
      headCssBytes += blk.text.len
  let htmlBytes = html.len
  let sizeBreakdown = @[
    ("headCss", headCssBytes),
    ("markup", htmlBytes - headCssBytes),
  ]
  diags.add(checkSize(html, target, sizeBreakdown))

  if strict and hasErrors(diags):
    raiseDiagnostic(firstError(diags))
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
