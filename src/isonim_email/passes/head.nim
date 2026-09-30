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
## Variants: `sm:` means mobile, so its rules sit under
## `@media only screen and (max-width:{breakpoint-1}px)`; desktop is the
## inline style. Every variant rule — responsive, dark and `:hover` —
## carries `!important`, because each must beat an inline value
## (R-CSS-03, R-INT-02). Class names hash the variant with the
## declarations (R-CSS-08), so one variant's rule never matches another
## variant's element. The dark block is not emitted at all under
## `darkMode = dmNone`; otherwise its Outlook copies split by property
## (R-DRK-03): `[data-ogsc]` rules carry `color` only and `[data-ogsb]`
## rules `background-color` only, while the media query carries every
## dark declaration.
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
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies - {cfGanga}

const
  resetPriority = 1
  responsivePriority = 2
  darkPriority = 3
  fontsPriority* = 4
    ## Exported: the document shell wraps this block in `NotMso`.
  decorativePriority = 5
  msoPriority* = 0
    ## Exported: the document shell wraps this block in `MsoIf`.
    ## Outside the 1-5 truncation order: the mso block is
    ## conditional-only, never in the plain-`<style>` sequence Gmail
    ## truncates.

type HeadGroup = object
  ## One element's declarations for one variant, in first-seen order.
  node: EmailNode
  decls: seq[Declaration]

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
  ## Catalogue §2's exact 13-line reset, in order (R-RST-01…11). The
  ## declaration order inside each rule is the catalogue's, NOT
  ## serialiser-sorted: lines 1, 6 and 10 are deliberately unsorted,
  ## so `resetBlockText` emits them verbatim — validated, never
  ## re-sorted.
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
    # Unowned line, in exact content: no R-RST-* rule covers it, but
    # catalogue §2 line 8 carries it, so the reset does too.
    ("a", @[Declaration(prop: "text-decoration", value: "none")]),
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
      result.add(HeadGroup(node: d.node, decls: @[decl]))
    else:
      result[found].decls.add(decl)

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
    message: "head blocks that are never dropped (reset, responsive) " &
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

proc assembleHead*(decls: seq[HeadDecl]; target: EmailTarget;
    webfonts: seq[seq[Declaration]] = @[];
    msoRules: seq[Rule] = @[]
  ): tuple[blocks: seq[EmailNode]; diagnostics: seq[EmailDiagnostic]] =
  ## P6 over one render: prioritised head blocks plus the budget
  ## diagnostics, in block order (mso last). `webfonts`/`msoRules` are
  ## the component feed seam; both default to absent. Raises `StyleError`
  ## (`E-CSS-INVALID`) on any block that fails validation.
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
  var respText = ""
  if respGroups.len > 0:
    var inner: seq[tuple[selector: string; decls: seq[Declaration]]] = @[]
    for (cls, ds) in respGroups:
      inner.add(("." & cls, ds))
      if target.thunderbirdMq:
        inner.add((".moz-text-html ." & cls, ds))
      if target.owaDesktop:
        inner.add(("[owa] ." & cls, ds))
    # `sm:` is the mobile variant: below the breakpoint.
    respText = emitMediaRule("only screen and (max-width: " &
      $(target.breakpoint - 1) & "px)", inner)

  var darkGroups: seq[tuple[cls: string; decls: seq[Declaration]]] = @[]
  var darkAttach: seq[tuple[node: EmailNode; cls: string]] = @[]
  var seenDark: seq[string] = @[]
  let darkGroupsIn =
    if target.darkMode == dmNone: @[] # No dark rules at all.
    else: groupDecls(decls, "dark")
  for g in darkGroupsIn:
    let cls = gen.classFor(g.decls, "dark")
    darkAttach.add((g.node, cls))
    if cls in seenDark:
      continue
    seenDark.add(cls)
    darkGroups.add((cls, g.decls))
  var darkText = ""
  if darkGroups.len > 0:
    var copies: seq[string] = @[]
    var inner: seq[tuple[selector: string; decls: seq[Declaration]]] = @[]
    for (cls, ds) in darkGroups:
      inner.add(("." & cls, ds))
      copies.add(ogsCopies(cls, ds))
    copies.sort()
    darkText = copies.join("") &
      emitMediaRule("(prefers-color-scheme: dark)", inner)

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
  if "decorative" in kept:
    for (node, cls) in hoverAttach:
      node.attachClass(cls)
  if msoText != "":
    blocks.add(newHeadStyle(msoText, msoPriority))
  (blocks, diags)
