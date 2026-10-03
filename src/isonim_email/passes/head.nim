## isonim_email/passes/head.nim — P6: the head style pass.
##
## Assembles prioritised `<style>` blocks from P5's `HeadDecl`s: reset (1),
## responsive (2), dark (3), fonts (4), decorative (5), plus the
## conditional-only mso block (outside the truncation order). Every
## declaration and query validates through `style/css.nim`; selectors go
## through `validSelector` or the documented P6-only extensions below —
## anything else is `E-CSS-INVALID`, an error, never a warning.
##
## Selector extensions (all cited; the P6-only split is final):
## - generated-class patterns `.<safe>:hover` (decorative: R-CSS-02
##   head membership plus R-INT-02) and `[owa] .<safe>` (responsive
##   OWA copy, R-LAY-13): tight shapes over P6-generated safe class
##   names only. R-CSS-09 admits neither spelling in css.nim, by
##   design — the serialiser stays class/element/ID plus the fixed
##   client-targeting set.
## - `.moz-text-html` and `[data-ogsc]`/`[data-ogsb]` copies need no
##   extension: css.nim admits those patterns already.
## (The old `headLiteralSelectors` bypass is retired: `.aBn`/`.a6S`
## are now css.nim literals under R-RST-09/11, and `u+.body` is gone —
## catalogue §2 carries no Yahoo line and no rule admits the spelling.)
##
## Budget (R-CSS-07): total bytes over reset+responsive+dark+fonts+
## decorative; while over `headStyleBudget` whole blocks drop from the
## lowest priority up (decorative, fonts, dark — never reset, responsive
## or mso), one `W-CSS-BLOCK-DROPPED` diagnostic per dropped block. When
## the blocks that are never dropped still exceed the budget, one
## `W-CSS-OVER-BUDGET` follows (Gmail will truncate them). A dropped
## block leaves no dangling class: classes attach to elements only for
## surviving blocks.
##
## The responsive block is mobile first, MJML's model: the rows' column
## widths and desktop gutters sit under
## `@media only screen and (min-width:{breakpoint}px)` (R-LAY-02, with
## the Thunderbird copy when `thunderbirdMq`, R-LAY-12, and the OWA copy
## when `owaDesktop`, R-LAY-13, both after the query and outside it:
## neither client applies a media query in a message); stacked cells,
## stacking gaps and `sm:` rules sit under
## `@media only screen and (max-width:{breakpoint-1}px)`. Only the
## desktop column rules are copied for Thunderbird and OWA: a copy of a
## mobile rule outside the query would give OWA's desktop the phone
## layout.
##
## Variants: `sm:` means mobile, so its rules sit under the `max-width`
## query; desktop is the inline style. Every variant rule — responsive, dark and `:hover` —
## carries `!important`, because each must beat an inline value
## (R-CSS-03, R-INT-02). Class names hash the variant with the
## declarations (R-CSS-08), so one variant's rule never matches another
## variant's element. The dark block is emitted only under
## `darkMode = dmDesigned` (R-DRK-02): `dmNone` writes no dark CSS, and
## `dmAccommodate` keeps the colour-scheme metas and the inversion lint
## but recolours nothing, so it writes no dark CSS either. Under
## `dmDesigned` the Outlook copies split by property (R-DRK-03):
## `[data-ogsc]` rules carry `color` only and `[data-ogsb]` rules
## `background-color` only, while the media query carries every dark
## declaration (border colours included). The media query also paints
## the page below the message: the document's dark background on the
## `body` element, which carries no class (R-DOC-14). With `dark_src`
## images (`swaps`) it holds R-IMG-06's fixed swap rules,
## `.e-dk-hide{display:none}` and `.e-dk-show{display:block}`, with
## their `[data-ogsc]` copies; the light image of each pair gets
## `e-dk-hide` only when the dark block survives, and the image
## lowering writes the dark copy only then.
##
## Rule order (R-CSS-16): the rules P6 generates are sorted, which is
## cascade-safe because each generated class is one rule per variant.
## The reset block is not generated: it is catalogue §2's text, emitted
## verbatim in the catalogue's order, never re-sorted.
##
## `webfonts`/`msoRules` arrive as parameters: the component work owns
## feeding them; this pass only places them (`@font-face`
## top-level, never in `@media`; mso never budgeted).
##
## Cross-pass note: P5 rejects `@md:` keys (the one breakpoint) and
## the variant-preserving Tailwind expansion only surfaces those keys while `md` stays in build-tailwind's
## `--variants` list — the md:p-6 fragility test in t4_styles.nim compiles
## that class through the real map so a dropped tag fails loudly. This
## literal mention keeps the class in the extractor's content scan, which
## covers src/.
##
## Pure (no IO) and backend-independent.

import std/[algorithm, strutils, tables]
import ../diagnostics
import ../ir
import ../style/classes
import ./styles
import ./layout
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies - {cfGanga}

const
  resetPriority = 1
  responsivePriority = 2
  darkPriority* = 3
    ## Exported: the renderer checks the dark scheme only when this
    ## block survived the budget.
  fontsPriority* = 4
    ## Exported: the document shell wraps this block in `NotMso`.
  decorativePriority = 5
  msoPriority* = 0
    ## Exported: the document shell wraps this block in `MsoIf`.
    ## Outside the 1-5 truncation order: the mso block is
    ## conditional-only, never in the plain-`<style>` sequence Gmail
    ## truncates.
  thunderbirdPriority* = 6
    ## Thunderbird's block (R-DRK-08), after the decorative block: one
    ## rule, never dropped.
  thunderbirdRoot* = "html:has(.moz-text-html)"
    ## Thunderbird's message root: the only root holding its message
    ## wrapper (R-DRK-08).
  thunderbirdBody* = "body:has(.moz-text-html)"
    ## Thunderbird's message body, for the page below the message.
  thunderbirdSignal* = "url(\"#prefers-color-scheme: dark\")"
    ## R-DRK-08: the root `filter` that tells Thunderbird the message
    ## handles its own colours (it skips its dark adaptation when the
    ## root's computed filter names `prefers-color-scheme: dark`); it
    ## references no element, so no filter applies.

type HeadGroup = object
  ## One element's declarations for one variant, in first-seen order.
  node: EmailNode
  decls: seq[Declaration]
  lights: seq[string]
    ## Each declaration's light twin (`HeadDecl.light`; dark only).

proc isHeadPatternSelector(selector: string): bool =
  ## `.<safe>:hover` (decorative, priority 5) and `[owa] .<safe>`
  ## (responsive OWA copy) over P6-generated safe classes only. Both
  ## spellings fail css.nim's validSelector by design (R-CSS-09 admits
  ## no pseudo-classes — t4_head_css pins `.a:hover` rejected — and no
  ## `[owa]`); the tight shape (exact prefix plus a validClassName tail
  ## P6 itself generated) keeps this from becoming a general bypass.
  ## Rule-text gap: no catalogue rule admits these spellings yet.
  if selector.startsWith("[owa] ."):
    return validClassName(selector[7 .. ^1])
  if selector.startsWith(".") and selector.endsWith(":hover"):
    return validClassName(selector[1 ..< ^6])
  false

proc emitStyleRule(selector: string; decls: seq[Declaration]): string =
  ## One validated style rule: declarations through css.nim's
  ## `serializeDecls` (which runs `checkDeclaration` on each), the
  ## selector through `validSelector` or the documented P6 extensions —
  ## anything else is `E-CSS-INVALID` (an error).
  if decls.len == 0:
    raise invalidCss("selector '" & selector &
      "' has no declarations (R-CSS-05: no empty declarations)")
  let sel = selector.strip()
  checkCssText("selector", sel)
  if isHeadPatternSelector(sel) or validSelector(sel):
    return sel & "{" & serializeDecls(decls) & "}"
  raise invalidCss("selector '" & selector &
    "' is not a class, element or ID selector from the fixed " &
    "client-targeting set (R-CSS-09)")

proc emitMediaRule(query: string;
    rules: seq[tuple[selector: string; decls: seq[Declaration]]]): string =
  ## css.nim's `@media` shape (checked query, sorted inner rules,
  ## R-CSS-16) over P6-validated rules, so `[owa]` copies ride along.
  checkQuery(query)
  if rules.len == 0:
    raise invalidCss("@media '" & query &
      "' has no rules (R-CSS-05: no empty declarations)")
  var parts: seq[string] = @[]
  for r in rules:
    parts.add(emitStyleRule(r.selector, r.decls))
  parts.sort()
  "@media " & query.strip() & "{" & parts.join("") & "}"

proc resetRules(): seq[tuple[selector: string; decls: seq[Declaration]]] =
  ## Catalogue §2's exact 13-line reset, in order (R-RST-01…11, 13).
  ## Both orders are the catalogue's, NOT serialiser-sorted: the rule
  ## order (R-CSS-16 sorts generated rules only; the reset is emitted
  ## in the order its sources wrote and verified it) and the
  ## declaration order inside each rule (lines 1, 6 and 10 are
  ## deliberately unsorted). `resetBlockText` emits them verbatim —
  ## validated, never re-sorted.
  @[
    ("html,body", @[ # R-RST-01
      Declaration(prop: "margin", value: "0 auto", important: true),
      Declaration(prop: "padding", value: "0", important: true),
      Declaration(prop: "height", value: "100%", important: true),
      Declaration(prop: "width", value: "100%", important: true)]),
    ("*", @[ # R-RST-02
      Declaration(prop: "-ms-text-size-adjust", value: "100%"),
      Declaration(prop: "-webkit-text-size-adjust", value: "100%")]),
    ("div[style*=\"margin: 16px 0\"]", @[ # R-RST-03
      Declaration(prop: "margin", value: "0", important: true)]),
    ("#MessageViewBody,#MessageWebViewDiv", @[ # R-RST-04
      Declaration(prop: "width", value: "100%", important: true)]),
    ("table,td", @[ # R-RST-05
      Declaration(prop: "mso-table-lspace", value: "0pt",
        important: true),
      Declaration(prop: "mso-table-rspace", value: "0pt",
        important: true)]),
    ("table", @[ # R-RST-06
      Declaration(prop: "border-spacing", value: "0", important: true),
      Declaration(prop: "border-collapse", value: "collapse",
        important: true),
      Declaration(prop: "table-layout", value: "fixed",
        important: true),
      Declaration(prop: "margin", value: "0 auto", important: true)]),
    ("img", @[ # R-RST-07
      Declaration(prop: "-ms-interpolation-mode", value: "bicubic"),
      Declaration(prop: "border", value: "0"),
      Declaration(prop: "height", value: "auto"),
      Declaration(prop: "line-height", value: "100%"),
      Declaration(prop: "outline", value: "none"),
      Declaration(prop: "text-decoration", value: "none")]),
    ("a", @[ # R-RST-13
      Declaration(prop: "text-decoration", value: "none")]),
    ("#outlook a", @[ # R-RST-08
      Declaration(prop: "padding", value: "0")]),
    ("a[x-apple-data-detectors],.unstyle-auto-detected-links a,.aBn", @[ # R-RST-09
      Declaration(prop: "border-bottom", value: "0", important: true),
      Declaration(prop: "cursor", value: "default", important: true),
      Declaration(prop: "color", value: "inherit", important: true),
      Declaration(prop: "text-decoration", value: "none",
        important: true),
      Declaration(prop: "font-size", value: "inherit",
        important: true),
      Declaration(prop: "font-family", value: "inherit",
        important: true),
      Declaration(prop: "font-weight", value: "inherit",
        important: true),
      Declaration(prop: "line-height", value: "inherit",
        important: true)]),
    (".im", @[ # R-RST-10
      Declaration(prop: "color", value: "inherit", important: true)]),
    (".a6S", @[ # R-RST-11
      Declaration(prop: "display", value: "none", important: true),
      Declaration(prop: "opacity", value: "0.01", important: true)]),
    ("img.g-img+div", @[ # R-RST-11
      Declaration(prop: "display", value: "none", important: true)]),
  ]

proc resetBlockText*(): string =
  ## Validates the catalogue §2 reset (every selector through `validSelector`,
  ## every declaration through `checkDeclaration` — a failure is
  ## `E-CSS-INVALID`, never silent) and emits the exact bytes:
  ## catalogue declaration order, lower-case ` !important`, trailing
  ## `;` per rule. `serializeDecls` cannot serve here: it re-sorts
  ## declarations and drops the trailing semicolon.
  var parts: seq[string] = @[]
  for r in resetRules():
    let sel = r.selector.strip()
    checkCssText("selector", sel)
    if not validSelector(sel):
      raise invalidCss("selector '" & r.selector &
        "' is not a class, element or ID selector from the fixed " &
        "client-targeting set (R-CSS-09)")
    if r.decls.len == 0:
      raise invalidCss("selector '" & r.selector &
        "' has no declarations (R-CSS-05: no empty declarations)")
    var ds: seq[string] = @[]
    for d in r.decls:
      checkDeclaration(d)
      ds.add(d.prop.toLowerAscii() & ":" & d.value.strip() &
        (if d.important: " !important" else: ""))
    parts.add(sel & "{" & ds.join(";") & ";}")
  parts.join("")

proc groupDecls(decls: seq[HeadDecl]; variant: string): seq[HeadGroup] =
  ## One variant's declarations grouped by element, groups in first-seen
  ## order (P5 emits in tree order, so this is deterministic). Variants
  ## P5 never produces are unread — P5 owns variant routing (it errors
  ## on `md:`/unknown itself), P6 reads only the three it knows.
  for d in decls:
    if d.variant != variant:
      continue
    # Every variant rule carries `!important` (R-CSS-03: head rules
    # that must beat inline styles). A responsive, dark or hover
    # override without it loses to the inline value in every client
    # (R-INT-02 for `:hover`).
    let decl = Declaration(prop: d.prop, value: d.value, important: true)
    var found = -1
    for i, g in result:
      if g.node == d.node:
        found = i
        break
    if found < 0:
      result.add(HeadGroup(node: d.node, decls: @[decl], lights: @[d.light]))
    else:
      result[found].decls.add(decl)
      result[found].lights.add(d.light)

proc attachClass(node: EmailNode; cls: string) =
  ## Appends a generated class to the element's `class` attribute
  ## (space-separated, de-duplicated), preserving author classes.
  var parts = node.attrs.getOrDefault("class", "").splitWhitespace()
  if cls notin parts:
    parts.add(cls)
  node.attrs["class"] = parts.join(" ")

proc blockDropped(blockName: string; blockBytes, totalBytes,
    budget: int): EmailDiagnostic =
  EmailDiagnostic(
    severity: sevWarning, code: codeCssBlockDropped,
    message: "head block '" & blockName & "' (" & $blockBytes &
      " bytes) dropped: head CSS " & $totalBytes & " bytes exceeds " &
      "headStyleBudget " & $budget & " (R-CSS-07)",
    origin: SourceSpan(), families: {}, weight: 0.0, rules: @["R-CSS-07"],
  )

proc overBudget(protectedBytes, budget: int): EmailDiagnostic =
  EmailDiagnostic(
    severity: sevWarning, code: codeCssOverBudget,
    message: "head blocks that are never dropped (reset, responsive, " &
      "Thunderbird's) " &
      "total " & $protectedBytes & " bytes, over headStyleBudget " &
      $budget & ": Gmail will truncate them (R-CSS-07)",
    origin: SourceSpan(), families: {cfGmailWeb, cfGmailApp}, weight: 0.0,
    rules: @["R-CSS-07"],
  )

proc ogsCopies(cls: string; decls: seq[Declaration]): seq[string] =
  ## R-DRK-03's Outlook copies, split by property: `[data-ogsc]` (text
  ## recolouring) carries the `color` declarations only and
  ## `[data-ogsb]` (background recolouring) the `background-color`
  ## declarations only. A group with neither gets no copy.
  var fg, bg: seq[Declaration] = @[]
  for d in decls:
    case d.prop.toLowerAscii()
    of "color": fg.add(d)
    of "background-color": bg.add(d)
    else: discard
  if fg.len > 0:
    result.add(emitStyleRule("[data-ogsc] ." & cls, fg))
  if bg.len > 0:
    result.add(emitStyleRule("[data-ogsb] ." & cls, bg))

const
  darkClassAttr* = "dark_class"
    ## Where P6 leaves a section's dark class for its lowering (a
    ## full-width band's outer div repaints in the dark scheme too).
  darkHideClass* = "e-dk-hide"
    ## The light image of a `dark_src` pair (R-IMG-06): hidden by the
    ## dark block.
  darkShowClass* = "e-dk-show"
    ## The dark image of a pair: inline `display:none`, shown by the dark
    ## block.

proc swapRules(): seq[tuple[selector: string; decls: seq[Declaration]]] =
  ## R-IMG-06's swap: in the dark scheme the light image goes and the
  ## dark one shows.
  @[("." & darkHideClass, @[Declaration(prop: "display", value: "none",
      important: true)]),
    ("." & darkShowClass, @[Declaration(prop: "display", value: "block",
      important: true)])]

proc documentDarkBackground(groups: seq[HeadGroup]):
    tuple[decls: seq[Declaration]; lights: seq[string]] =
  ## The document's dark background, for the page below the message
  ## (`<body>`, which carries no class: R-DOC-14): the `body` element is
  ## selected instead. With its light twin, for Thunderbird's copy.
  for g in groups:
    if g.node != nil and g.node.kind == enElement and
        g.node.tag == "mailDocument":
      for i, d in g.decls:
        if d.prop.toLowerAscii() == "background-color":
          result = (@[d], @[g.lights[i]])

proc lightDark(light, dark: string): string =
  ## `light-dark({light},{dark})`: the colour a Thunderbird copy carries.
  "light-dark(" & light & "," & dark & ")"

proc thunderbirdCopy(decls: seq[Declaration];
    lights: seq[string]): seq[Declaration] =
  ## R-DRK-08: a dark rule's declarations as Thunderbird's copy, each
  ## `light-dark({light},{dark})`, so the message root's colour scheme
  ## picks one (Thunderbird applies no media query). A declaration with
  ## no light twin has no copy.
  for i, d in decls:
    if i < lights.len and lights[i].len > 0:
      result.add(Declaration(prop: d.prop,
        value: lightDark(lights[i], d.value), important: true))

proc pairedDecls(decls: seq[Declaration];
    lights: seq[string]): seq[Declaration] =
  ## The declarations a dark class is named after (R-CSS-08): each with
  ## its light twin, so two elements sharing a dark value but not a light
  ## one get two classes, and Thunderbird's copy of each is exact.
  for i, d in decls:
    var x = d
    if i < lights.len and lights[i].len > 0:
      x.value = lightDark(lights[i], d.value)
    result.add(x)

proc assembleHead*(decls: seq[HeadDecl]; target: EmailTarget;
    webfonts: seq[seq[Declaration]] = @[];
    msoRules: seq[Rule] = @[];
    columns: seq[ColumnRule] = @[];
    swaps: seq[EmailNode] = @[]
  ): tuple[blocks: seq[EmailNode]; diagnostics: seq[EmailDiagnostic]] =
  ## P6 over one render: prioritised head blocks plus the budget
  ## diagnostics, in block order (mso last). `webfonts`/`msoRules` are
  ## the component feed seam; both default to absent. `columns` are the
  ## rows' rules (`layout.columnRules`): the desktop column widths and
  ## gutters under the `min-width` query, the stacked cells and gaps
  ## under the `max-width` one. Raises `StyleError` (`E-CSS-INVALID`) on
  ## any block that fails validation.
  var gen = initClassGen()
  var diags: seq[EmailDiagnostic] = @[]

  let resetText = resetBlockText()

  var respGroups: seq[tuple[cls: string; decls: seq[Declaration]]] = @[]
  var respAttach: seq[tuple[node: EmailNode; cls: string]] = @[]
  var seenResp: seq[string] = @[]
  for g in groupDecls(decls, "sm"):
    let cls = gen.classFor(g.decls, "sm")
    respAttach.add((g.node, cls))
    if cls in seenResp:
      continue
    seenResp.add(cls)
    respGroups.add((cls, g.decls))
  var desktop, mozCopies, owaCopies: seq[tuple[selector: string;
    decls: seq[Declaration]]]
  var mobile: seq[tuple[selector: string; decls: seq[Declaration]]] = @[]
  for c in columns:
    var ds: seq[Declaration] = @[]
    for d in c.decls:
      ds.add(Declaration(prop: d.prop, value: d.value,
        important: d.important))
    if c.thunderbird:
      # R-RAW-06: Thunderbird alone, by its own class, outside any
      # query (Thunderbird applies none), whatever `thunderbirdMq` says:
      # the author asked for it by name.
      mozCopies.add((".moz-text-html ." & c.cls, ds))
    elif c.desktop:
      # R-LAY-02 with its copies, both outside the query: Thunderbird
      # (R-LAY-12) and OWA (R-LAY-13) apply no media query in a
      # message, and both are desktop clients. Only the desktop column
      # rules are copied.
      desktop.add(("." & c.cls, ds))
      if target.thunderbirdMq:
        mozCopies.add((".moz-text-html ." & c.cls, ds))
      if target.owaDesktop:
        owaCopies.add(("[owa] ." & c.cls, ds))
    else:
      mobile.add(("." & c.cls, ds))
  for (cls, ds) in respGroups:
    # `sm:` is the mobile variant: below the breakpoint, never copied
    # for Thunderbird or OWA (they are copies of desktop widths only).
    mobile.add(("." & cls, ds))
  var respText = ""
  if desktop.len > 0:
    # Mobile first: the column widths hold from the breakpoint up.
    respText.add(emitMediaRule("only screen and (min-width: " &
      $target.breakpoint & "px)", desktop))
  for copies in [mozCopies, owaCopies]:
    if copies.len > 0:
      var parts: seq[string] = @[]
      for r in copies:
        parts.add(emitStyleRule(r.selector, r.decls))
      parts.sort()
      respText.add(parts.join(""))
  if mobile.len > 0:
    respText.add(emitMediaRule("only screen and (max-width: " &
      $(target.breakpoint - 1) & "px)", mobile))

  var darkGroups: seq[tuple[cls: string; decls: seq[Declaration];
    lights: seq[string]]] = @[]
  var darkAttach: seq[tuple[node: EmailNode; cls: string]] = @[]
  var seenDark: seq[string] = @[]
  let darkGroupsIn =
    # Dark CSS is the designed dark palette: only `dmDesigned` has one.
    if target.darkMode != dmDesigned: @[]
    else: groupDecls(decls, "dark")
  for g in darkGroupsIn:
    let cls = gen.classFor(pairedDecls(g.decls, g.lights), "dark")
    darkAttach.add((g.node, cls))
    if cls in seenDark:
      continue
    seenDark.add(cls)
    darkGroups.add((cls, g.decls, g.lights))
  var darkText = ""
  let designed = target.darkMode == dmDesigned
  if darkGroups.len > 0 or (designed and swaps.len > 0):
    var copies, tbCopies: seq[string] = @[]
    var inner: seq[tuple[selector: string; decls: seq[Declaration]]] = @[]
    for (cls, ds, lights) in darkGroups:
      inner.add(("." & cls, ds))
      copies.add(ogsCopies(cls, ds))
      # R-DRK-08: Thunderbird applies no media query; its copy carries
      # both schemes' values, outside the query (R-LAY-12's prefix).
      let tb = thunderbirdCopy(ds, lights)
      if tb.len > 0:
        tbCopies.add(emitStyleRule(".moz-text-html ." & cls, tb))
    let page = documentDarkBackground(darkGroupsIn)
    if page.decls.len > 0:
      # The page below the message keeps the body's colour, and the body
      # carries no class (R-DOC-14): the element is selected. Outlook's
      # recolouring has no body to paint, so no copy.
      inner.add(("body", page.decls))
      let tb = thunderbirdCopy(page.decls, page.lights)
      if tb.len > 0:
        tbCopies.add(emitStyleRule(thunderbirdBody, tb))
    if designed and swaps.len > 0:
      # R-IMG-06: the image swap, with its Outlook copy (R-DRK-03). No
      # Thunderbird copy: `display` has no scheme-conditional value, so
      # Thunderbird shows the light image (R-DRK-08, R-DRK-06).
      for (sel, ds) in swapRules():
        inner.add((sel, ds))
        copies.add(emitStyleRule("[data-ogsc] " & sel, ds))
    copies.sort()
    tbCopies.sort()
    darkText = copies.join("") &
      emitMediaRule("(prefers-color-scheme: dark)", inner) &
      tbCopies.join("")

  # R-DRK-08: Thunderbird's block. Whenever the colour-scheme metas say
  # the message handles both schemes (any strategy but `none`), the
  # message tells Thunderbird so in the one way it reads: its root's
  # `filter`. Its own `<style>`, so a client that drops a block over the
  # `:has()` selector loses nothing else.
  let thunderbirdText =
    if target.darkMode == dmNone: ""
    else: emitStyleRule(thunderbirdRoot, @[Declaration(prop: "filter",
      value: thunderbirdSignal)])

  var fontsText = ""
  if webfonts.len > 0:
    var faces: seq[string] = @[]
    for face in webfonts:
      faces.add(serializeFontFaceRule(face))
    faces.sort()
    fontsText = faces.join("")

  var hoverGroups: seq[tuple[cls: string; decls: seq[Declaration]]] = @[]
  var hoverAttach: seq[tuple[node: EmailNode; cls: string]] = @[]
  var seenHover: seq[string] = @[]
  for g in groupDecls(decls, "hover"):
    let cls = gen.classFor(g.decls, "hover")
    hoverAttach.add((g.node, cls))
    if cls in seenHover:
      continue
    seenHover.add(cls)
    hoverGroups.add((cls, g.decls))
  var hoverText = ""
  if hoverGroups.len > 0:
    var parts: seq[string] = @[]
    for (cls, ds) in hoverGroups:
      parts.add(emitStyleRule("." & cls & ":hover", ds))
    parts.sort()
    hoverText = parts.join("")

  var msoText = ""
  if msoRules.len > 0:
    msoText = serializeBlock(msoRules)

  type BudgetBlock = object
    name: string
    text: string
    priority: int
  var budgeted: seq[BudgetBlock] = @[BudgetBlock(name: "reset",
    text: resetText, priority: resetPriority)]
  if respText != "":
    budgeted.add(BudgetBlock(name: "responsive", text: respText,
      priority: responsivePriority))
  if darkText != "":
    budgeted.add(BudgetBlock(name: "dark", text: darkText,
      priority: darkPriority))
  if fontsText != "":
    budgeted.add(BudgetBlock(name: "fonts", text: fontsText,
      priority: fontsPriority))
  if hoverText != "":
    budgeted.add(BudgetBlock(name: "decorative", text: hoverText,
      priority: decorativePriority))

  proc totalBytes(): int =
    # Thunderbird's block is never dropped but counts (R-CSS-07).
    result = thunderbirdText.len
    for b in budgeted:
      result += b.text.len

  for victim in ["decorative", "fonts", "dark"]:
    if totalBytes() <= target.headStyleBudget:
      break
    var idx = -1
    for i, b in budgeted:
      if b.name == victim:
        idx = i
        break
    if idx < 0:
      continue
    diags.add(blockDropped(victim, budgeted[idx].text.len, totalBytes(),
      target.headStyleBudget))
    budgeted.delete(idx)
  if totalBytes() > target.headStyleBudget:
    # Only the never-dropped blocks remain over budget.
    diags.add(overBudget(totalBytes(), target.headStyleBudget))

  var blocks: seq[EmailNode] = @[]
  var kept: seq[string] = @[]
  for b in budgeted:
    kept.add(b.name)
    blocks.add(newHeadStyle(b.text, b.priority))
  if "responsive" in kept:
    for (node, cls) in respAttach:
      node.attachClass(cls)
  if "dark" in kept:
    for (node, cls) in darkAttach:
      node.attachClass(cls)
      if node.kind == enElement and node.tag == "mailSection":
        # A full-width band paints its colour on an outer div too
        # (R-LAY-09): the lowering gives that div the dark class.
        node.attrs[darkClassAttr] = cls
    if designed:
      # The image lowering writes the dark copy only for a light image
      # carrying this class: a dropped dark block leaves one image.
      for node in swaps:
        node.attachClass(darkHideClass)
  if "decorative" in kept:
    for (node, cls) in hoverAttach:
      node.attachClass(cls)
  if thunderbirdText != "":
    blocks.add(newHeadStyle(thunderbirdText, thunderbirdPriority))
  if msoText != "":
    blocks.add(newHeadStyle(msoText, msoPriority))
  (blocks, diags)
