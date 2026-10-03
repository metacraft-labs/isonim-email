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
import ./style/css
import ./lower/document
import ./lower/elements
import ./lower/background
import ./passes/validate
import ./passes/layout
import ./passes/styles
import ./passes/head
import ./passes/a11y
import ./passes/lint
import ./patterns
import ./primitives
import ./navigation
import ./content
import ./text
import ./crop

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
  textFlowed*: bool
    ## True when `text` is the plain-text pass's `format=flowed` form: a
    ## line that ends in a space is a soft break (the receiver may join
    ## it to the next line), every other line a hard break. False for a
    ## text supplied by hand, whose lines are all hard breaks.
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

const bandTagsWithImages = ["mailSection", "mailWrapper", "mailHero"]
  ## The bands whose `background_image` P8 resolves and checks.

proc backgroundSlot(node: EmailNode): tuple[inStyles: bool; key: string] =
  ## Where a band's background image sits in the tree: a style or an
  ## attribute, under either spelling, in the order the lowering reads
  ## it (`rawValue`, through `backgroundImageOf`); key "" when none.
  for k in ["background-image", "background_image"]:
    if k in node.styles and node.styles[k].strip().len > 0:
      return (true, k)
  for k in ["background_image", "background-image"]:
    if k in node.attrs and node.attrs[k].strip().len > 0:
      return (false, k)
  (false, "")

proc resolveAssets*(doc: EmailNode; store: AssetStore): tuple[
    assets: seq[AssetRef]; diagnostics: seq[EmailDiagnostic]] =
  ## P8's asset half. Every `img`/`mailImage` source (and dark source,
  ## `dark_src`) and every band's
  ## background image (`background_image`, catalogue R-VML-04) the tree
  ## references is resolved — a store name through `store.get`, a
  ## compile-time `asset"…"` path through the program's embedded
  ## assets — then published through `store.publish` before the HTML
  ## is serialised, and the node's `src` (or background image) is
  ## rewritten to the URL the store returned (R-IMG-07: the upload
  ## completes before the message exists). Each distinct asset is
  ## listed once, carrying that URL.
  ##
  ## A nil store resolves and publishes nothing: sources stay as
  ## written. An unresolvable name is collected as `E-ASSET-UNKNOWN`,
  ## and a `data:` source as `E-URL-SCHEME` (R-IMG-08 forbids embedded
  ## data URIs). A failing upload hook propagates: sending with an
  ## image that never published is worse than not sending. A publish
  ## that returns no absolute https URL is collected as `E-URL-SCHEME`
  ## (R-IMG-07) and its `src` is left unrewritten and unlisted.
  ##
  ## A `mailImage` with `crop` (`W:H` or `circle`, R-IMG-13) is cropped
  ## here, between resolving its source and publishing it
  ## (`crop.cropAsset`): the cropped asset is what is published, listed
  ## and referenced. A crop that cannot be made or checked, an image
  ## whose bytes P8 does not hold (an absolute URL, no store at all)
  ## included, is `E-ASSET-CROP` and the `src` stays as written.
  result = (@[], @[])
  if doc == nil:
    return
  if store == nil:
    # Nothing is resolved, so no crop can be made: each one asked for
    # is reported, never dropped silently.
    var stack: seq[EmailNode] = @[doc]
    while stack.len > 0:
      let node = stack.pop()
      if node.kind == enElement and node.tag == "mailImage" and
          node.attrs.getOrDefault("crop", "").strip().len > 0:
        result.diagnostics.add(EmailDiagnostic(severity: sevError,
          code: codeAssetCrop, message: "mailImage crop = '" &
            node.attrs["crop"] & "' needs the image's bytes, and the " &
            "render was given no asset store: render with one, or crop " &
            "the image before sending and drop crop (R-IMG-13)",
          origin: node.origin, rules: @["R-IMG-13"]))
      for c in node.children:
        stack.add(c)
    return
  var resolved: seq[tuple[src: string; url: string]] = @[]
  var failed: seq[string] = @[]
  var listedAssets: seq[AssetRef] = @[]
  var diags: seq[EmailDiagnostic] = @[]

  proc resolveOne(src: string; node: EmailNode; cropValue = ""): string =
    ## The URL `src` publishes to (cropped by `cropValue`), "" when it
    ## stays as written.
    let key = if cropValue.len > 0: src & "\x00" & cropValue else: src
    for entry in resolved:
      if entry.src == key:
        return entry.url
    if src.len == 0 or src in failed or key in failed:
      return ""
    var asset: AssetRef
    var found = false
    let compiled = compiledAssetAt(src)
    if isDataUri(src):
      failed.add(src)
      diags.add(EmailDiagnostic(
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
        diags.add(toDiagnostic(e.msg, origin = node.origin))
    if not found:
      if cropValue.len > 0 and src notin failed:
        # An image P8 cannot read cannot be cropped (R-IMG-13).
        failed.add(key)
        diags.add(EmailDiagnostic(severity: sevError, code: codeAssetCrop,
          message: "mailImage crop = '" & cropValue & "' cannot crop '" &
            src & "': its bytes are not the render's (an absolute URL); " &
            "give it as an asset name or asset\"…\", or crop it before " &
            "sending and drop crop (R-IMG-13)", origin: node.origin,
          rules: @["R-IMG-13"]))
      return ""
    if cropValue.len > 0:
      let spec = parseCrop(cropValue)
      let cut = if spec.ok: cropAsset(asset, spec)
        else: CropResult(error: "crop is W:H (two positive whole " &
          "numbers) or circle")
      if not cut.ok:
        failed.add(key)
        diags.add(EmailDiagnostic(severity: sevError, code: codeAssetCrop,
          message: "mailImage crop = '" & cropValue & "' of '" &
            asset.name & "': " & cut.error & " (R-IMG-13)",
          origin: node.origin, rules: @["R-IMG-13"]))
        return ""
      asset = cut.asset
    let url = store.publish(asset)
    if not isPublishedUrl(url):
      # R-IMG-07: the HTML may only reference what the upload
      # returned, and the upload must return where the image now
      # lives. An empty or non-https answer means it did not.
      failed.add(key)
      diags.add(EmailDiagnostic(
        severity: sevError, code: codeUrlScheme,
        message: "publishing asset '" & asset.name & "' returned '" &
          url & "', not an absolute https URL; the upload must " &
          "complete before the HTML references it (R-IMG-07)",
        origin: node.origin, rules: @["R-IMG-07"]))
      return ""
    asset.url = url
    resolved.add((key, asset.url))
    var listed = false
    for a in listedAssets:
      if a.url == asset.url:
        listed = true
    if not listed:
      listedAssets.add(asset)
    url

  var stack: seq[EmailNode] = @[doc]
  while stack.len > 0:
    let node = stack.pop()
    if node == nil:
      continue
    if node.kind == enElement and
        node.tag.toLowerAscii() in ["img", "mailimage"]:
      # An image's dark copy (R-IMG-06) publishes like its source.
      let cropValue = if node.tag == "mailImage":
          node.attrs.getOrDefault("crop", "").strip() else: ""
      for key in ["src", "dark_src"]:
        if key == "dark_src" and key notin node.attrs:
          continue
        let url = resolveOne(node.attrs.getOrDefault(key, ""), node,
          cropValue)
        if url.len > 0:
          node.attrs[key] = url
    elif node.kind == enElement and node.tag in bandTagsWithImages:
      let (inStyles, key) = backgroundSlot(node)
      if key.len > 0:
        let url = resolveOne(backgroundImageOf(node), node)
        if url.len > 0:
          if inStyles: node.styles[key] = url
          else: node.attrs[key] = url
    for i in countdown(node.children.high, 0):
      stack.add(node.children[i])
  result = (listedAssets, diags)

proc darkSwapImages*(doc: EmailNode): seq[EmailNode] =
  ## The `mailImage`s with a `dark_src` (R-IMG-06), in document order:
  ## the light images P6 pairs with a dark copy.
  var stack: seq[EmailNode] = @[doc]
  while stack.len > 0:
    let node = stack.pop()
    if node == nil:
      continue
    if node.kind == enElement and node.tag == "mailImage" and
        node.attrs.getOrDefault("dark_src", "").strip().len > 0:
      result.add(node)
    for i in countdown(node.children.high, 0):
      stack.add(node.children[i])

proc checkBackgroundUrls*(doc: EmailNode): seq[EmailDiagnostic] =
  ## P8's check of every band's background image (catalogue R-VML-04):
  ## an absolute https URL, as the asset store publishes one. Word's
  ## VML ignores `cid:` and relative URLs in some versions, so neither
  ## is used; a `data:` URI is forbidden outright (R-IMG-08). A URL with
  ## a quote, a parenthesis, a backslash or white space is refused too:
  ## it would end the CSS `url('…')` early.
  var stack: seq[EmailNode] = @[doc]
  while stack.len > 0:
    let node = stack.pop()
    if node == nil:
      continue
    if node.kind == enElement and node.tag in bandTagsWithImages:
      let url = backgroundImageOf(node)
      if url.len > 0:
        if not isPublishedUrl(url) or
            url.contains({'\'', '(', ')', '\\'}):
          result.add(EmailDiagnostic(severity: sevError,
            code: codeUrlScheme,
            message: node.tag & " background_image '" & url & "' is not " &
              "an absolute https URL: Word's VML needs one, and never " &
              "reads cid: or relative URLs (R-VML-04); publish it " &
              "through an AssetStore", origin: node.origin,
            rules: @["R-VML-04"]))
    for i in countdown(node.children.high, 0):
      stack.add(node.children[i])

proc webFontRules*(target: EmailTarget; theme: EmailTheme): tuple[
    faces: seq[seq[Declaration]]; mso: seq[Rule];
    diagnostics: seq[EmailDiagnostic]] =
  ## The head CSS of `target.webFonts` (R-TXT-07, R-OL-07): one
  ## `@font-face` per font for the fonts block, and, when any is used,
  ## the mso block's `*{font-family:{fallback} !important}`, the body
  ## stack without its web families (Word would otherwise use Times New
  ## Roman). A font whose URL is not absolute https is `E-URL-SCHEME`
  ## and left out.
  var families: seq[string] = @[]
  for f in target.webFonts:
    let url = f.url.strip()
    let lower = url.toLowerAscii()
    if not (lower.startsWith("https://") and url.len > "https://".len and
        url["https://".len] notin {'/', '?', '#'}) or
        url.contains({' ', '\t', '\r', '\n', '"', '\'', '<', '>', '(',
          ')', '\\'}):
      result.diagnostics.add(EmailDiagnostic(severity: sevError,
        code: codeUrlScheme, message: "web font '" & f.family & "' url '" &
          url & "' is not an absolute https URL (R-TXT-07)",
        rules: @["R-TXT-07"]))
      continue
    let format = if f.format.len > 0: f.format else: "woff2"
    result.faces.add(@[
      Declaration(prop: "font-family", value: "'" & f.family & "'"),
      Declaration(prop: "src", value: "url('" & url & "') format('" &
        format & "')"),
      Declaration(prop: "font-weight",
        value: if f.weight.len > 0: f.weight else: "400"),
      Declaration(prop: "font-style",
        value: if f.style.len > 0: f.style else: "normal")])
    families.add(f.family.toLowerAscii())
  if result.faces.len > 0:
    var keep: seq[string] = @[]
    for part in theme.lightFor("font.body").split(','):
      let name = part.strip()
      if name.strip(chars = {'\'', '"'}).toLowerAscii() notin families:
        keep.add(name)
    if keep.len == 0:
      keep = @["Arial", "sans-serif"]
    result.mso.add(Rule(kind: rkStyle, selector: "*", decls: @[
      Declaration(prop: "font-family", value: keep.join(", "),
        important: true)]))

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
  ## a cell row too narrow at 320px (R-TBL-11). The plain-text part
  ## is written by P12 (`text.nim`) from the semantic tree, after the
  ## assets are resolved and before lowering; when it would be empty
  ## (`E-TEXT-EMPTY`) the text is "" and MIME packaging sends the HTML
  ## alone, never an empty `text/plain` part (see `toMessage`).
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
  let fonts = webFontRules(target, theme)
  diags.add(fonts.diagnostics)
  let headRes = assembleHead(styled.head, target, webfonts = fonts.faces,
    msoRules = fonts.mso, columns = columnRules(doc),
    swaps = darkSwapImages(doc))
  diags.add(headRes.diagnostics)
  for blk in headRes.blocks:
    if blk.kind == enHeadStyle and blk.priority == fontsPriority:
      # R-TXT-07: web fonts load in a few families only; the fallback
      # stack is the design everywhere else, an expected degradation.
      var supported: set[ClientFamily] = {}
      for f in ClientFamily:
        if f notin {cfApple, cfSamsung, cfThunderbird, cfOutlookApp}:
          supported.incl(f)
      diags.add(lintHeadCss(blk.text, profile, [expectDegradation(
        lkAtRule, "font-face", supported, "web fonts fall back to the " &
        "stack's next family (R-TXT-07)")]))
  diags.add(applyA11y(doc))
  diags.add(lintTree(doc, profile))
  if target.darkMode != dmNone:
    # R-DRK-04's inversion simulation: the clients that recolour a
    # message themselves do so under `accommodate` and `designed` alike.
    diags.add(lintInversion(doc, profile))
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
  if target.darkMode != dmNone:
    # Adjacent bands that read as one once a client darkens them, or in
    # the designed dark palette (layout-patterns.md §4.1).
    var bandDark: seq[DarkDecl] = @[]
    if target.darkMode == dmDesigned:
      for blk in headRes.blocks:
        if blk.kind == enHeadStyle and blk.priority == darkPriority:
          for d in styled.head:
            if d.variant == "dark" and d.prop == "background-color":
              bandDark.add((d.node, d.prop, d.value))
          break
    diags.add(lintBandsMerge(doc, bandDark))
  let found = resolveAssets(doc, assets)
  diags.add(found.diagnostics)
  if target.darkMode != dmNone:
    # R-DRK-06: a pair's light image shows unswapped in dark mode
    # wherever the dark block does not apply.
    diags.add(lintDarkLogos(doc, found.assets))
  diags.add(checkBackgroundUrls(doc))
  # P12: the plain-text part, from the semantic tree (never the HTML).
  let plain = renderText(doc)
  diags.add(plain.diagnostics)

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
  # P10 over what is emitted: the closed mso-* list (R-OL-15), the
  # layout-table depth outside Outlook conditionals (R-TBL-15) and no
  # sectioning element (R-A11Y-10).
  diags.add(lintMsoProperties(lowered))
  diags.add(lintTableDepth(lowered))
  diags.add(lintSectioning(lowered))
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
    text: plain.text,
    textFlowed: plain.text.len > 0,
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
