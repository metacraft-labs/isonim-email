## isonim_email/passes/lint.nim — P10: the client-support lint.
##
## Checks every emitted CSS property, value keyword, selector kind,
## at-rule, HTML element and attribute against the pinned caniemail data,
## weighting each family's support by the audience profile:
##
## - harmful in a weighted family (layout `display:flex`) → error;
## - unsupported in families totalling ≥ 5% weight, no fallback → warning;
## - unsupported, with an `ExpectedDegradation` from the component → info.
##
## Partial (`a`) counts as supported and unknown (`u`) abstains; see
## `support/families.nim` for why. Below-threshold gaps with no declared
## fallback are accepted loss and stay silent.
##
## Seed calibration: a mapping is seeded only when (a) its slug exists in
## the pinned data, (b) it does not fire on constructs the rendering
## rules require under any built-in profile on the pinned data, and (c) a
## warning would name an author action. Deliberately unmapped, with reasons:
##
## - `display:none`, `overflow`, `opacity` — required by the R-PRE hiding
##   stack (the normative preheader uses all three);
## - `cursor`, `z-index`, `visibility`, `text-decoration`, `font-kerning` —
##   ignored-is-harmless or cosmetic, no author action;
## - `word-spacing` — the normative document body sets it;
## - `target`, `lang`, `dir`, `width`, `height`, `background` attributes —
##   required or best-practice; worst case is "ignored";
## - `@media` — required for responsive; the data's Gmail `n` is wrong
##   (width-only MQs work in Gmail);
## - class/id/type/descendant/child/sibling/grouping/chaining/universal
##   selectors — same contradiction (class, element and ID selectors
##   work in Gmail); only attribute selectors (stripped by Gmail) map.
##
## Component work extends the seeds with the CSS their lowering emits.
## This pass lints the authoring tree (no lowering exists yet); P10 moves
## to the IR when the pipeline lands. `enHeadStyle` blocks are linted
## through `lintHeadCss`; `raw` payloads are not parsed (unaudited).
##
## The a11y lint covers meaningless link text (R-A11Y-06),
## light-scheme text/background contrast (R-A11Y-07), and the
## R-IMG-04 alt-length heuristic. All three are warnings.

import std/[math, strutils, tables]
import ../diagnostics
import ../renderer
import ../style/colors
import ../support/families
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

export diagnostics

const supportWarnThreshold* = 0.05
  ## Unsupported in families totalling at least this profile weight, with
  ## no declared fallback, is a warning.

type
  LintKind* = enum
    lkProperty, lkValue, lkSelector, lkAtRule, lkElement, lkAttribute

  SelectorKind* = enum
    skClass, skId, skType, skAttribute, skUniversal, skDescendant, skChild,
    skAdjacentSibling, skGeneralSibling, skGrouping, skChaining

  ExpectedDegradation* = object
    ## A component's declared fallback: `name` in the match
    ## key space of its kind (lower-cased property, `prop=value`, selector
    ## kind id, at-rule name without `@`, tag, attribute), `families` the
    ## families the fallback covers, `note` the human-readable fallback
    ## (e.g. "square corners in Word"), which also feeds the review brief.
    kind*: LintKind
    name*: string
    families*: set[ClientFamily]
    note*: string

proc expectDegradation*(kind: LintKind; name: string;
                        families: set[ClientFamily];
                        note = ""): ExpectedDegradation =
  ExpectedDegradation(kind: kind, name: name, families: families, note: note)

# ----------------------------------------------------------------------------
# Feature mappings: lint input → caniemail slug ("" = unmapped, skipped)
# ----------------------------------------------------------------------------

proc propertySlug*(prop: string): string =
  ## CSS property → caniemail slug.
  case prop.toLowerAscii()
  of "border-radius": "css-border-radius"
  of "margin", "margin-top", "margin-right", "margin-bottom", "margin-left":
    "css-margin"
  of "padding", "padding-top", "padding-right", "padding-bottom",
      "padding-left":
    "css-padding"
  of "width": "css-width"
  of "height": "css-height"
  of "max-width": "css-max-width"
  of "min-width": "css-min-width"
  of "display": "css-display"
  of "position": "css-position"
  of "float": "css-float"
  of "clear": "css-clear"
  of "box-sizing": "css-box-sizing"
  of "gap": "css-gap"
  of "justify-content": "css-justify-content"
  of "align-items": "css-align-items"
  of "flex-direction": "css-flex-direction"
  of "flex-wrap": "css-flex-wrap"
  of "border": "css-border"
  of "border-collapse": "css-border-collapse"
  of "border-spacing": "css-border-spacing"
  of "background": "css-background"
  of "background-color": "css-background-color"
  of "background-image": "css-background-image"
  of "background-size": "css-background-size"
  of "background-position": "css-background-position"
  of "background-repeat": "css-background-repeat"
  of "box-shadow": "css-box-shadow"
  of "table-layout": "css-table-layout"
  of "text-align": "css-text-align"
  of "vertical-align": "css-vertical-align"
  of "line-height": "css-line-height"
  of "direction": "css-direction"
  of "font": "css-font"
  of "font-size": "css-font-size"
  of "font-weight": "css-font-weight"
  of "letter-spacing": "css-letter-spacing"
  of "text-transform": "css-text-transform"
  of "text-indent": "css-text-indent"
  of "word-wrap": "css-word-wrap"
  of "white-space": "css-white-space"
  of "list-style": "css-list-style"
  of "list-style-type": "css-list-style-type"
  of "list-style-position": "css-list-style-position"
  else: ""

proc valueSlug*(prop, value: string): string =
  ## `(property, value keyword)` → caniemail slug.
  case prop.toLowerAscii() & "=" & value.toLowerAscii().strip()
  of "display=flex", "display=inline-flex": "css-display-flex"
  of "display=grid", "display=inline-grid": "css-display-grid"
  else: ""

proc selectorKindId*(kind: SelectorKind): string =
  case kind
  of skClass: "class"
  of skId: "id"
  of skType: "type"
  of skAttribute: "attribute"
  of skUniversal: "universal"
  of skDescendant: "descendant"
  of skChild: "child"
  of skAdjacentSibling: "adjacent-sibling"
  of skGeneralSibling: "general-sibling"
  of skGrouping: "grouping"
  of skChaining: "chaining"

proc selectorSlug*(kind: SelectorKind): string =
  ## Selector kind → caniemail slug. Only attribute selectors map (see the
  ## header note); the classifier still recognises every kind.
  case kind
  of skAttribute: "css-selector-attribute"
  else: ""

proc atRuleSlug*(name: string): string =
  ## At-rule name (without `@`) → caniemail slug.
  case name.toLowerAscii()
  of "font-face": "css-at-font-face"
  of "import": "css-at-import"
  of "supports": "css-at-supports"
  of "keyframes": "css-at-keyframes"
  else: ""

proc elementSlug*(tag: string): string =
  ## HTML element → caniemail slug.
  case tag.toLowerAscii()
  of "video": "html-video"
  of "audio": "html-audio"
  of "picture": "html-picture"
  of "svg": "html-svg"
  of "form": "html-form"
  of "style": "html-style"
  of "link": "html-link"
  of "input": "html-input-text"
  of "button": "html-button-submit"
  of "img": "html-img"
  else: ""

proc attributeSlug*(attr: string): string =
  ## HTML attribute → caniemail slug.
  case attr.toLowerAscii()
  of "align": "html-align"
  of "valign": "html-valign"
  of "cellspacing": "html-cellspacing"
  of "cellpadding": "html-cellpadding"
  else: ""

# ----------------------------------------------------------------------------
# Harmful values (R-OL-10)
# ----------------------------------------------------------------------------

proc isLayoutContainer*(tag: string): bool =
  ## Tags whose box positions other content: the `mail*` structural set,
  ## the document root, and the lowered structural elements. `display:flex`
  ## /`grid` on one of these collapses the layout in Word-engine Outlook
  ## (error); anywhere else it is removed with a warning (R-OL-10).
  tag.toLowerAscii() in [
    "maildocument", "mailwrapper", "mailsection", "mailcolumn", "mailgroup",
    "mailstack", "mailbox", "mailcolumns", "mailgrid", "mailcluster",
    "mailsidebar", "div", "table", "thead", "tbody", "tr", "td", "th",
    "html", "body",
  ]

proc harmfulDisplayValue*(value: string): string =
  ## The flex/grid keyword in a `display` value, or "" when absent. Strips
  ## a trailing `!important`: harm is about the keyword, not the priority.
  var v = value.strip().toLowerAscii()
  if v.endsWith("!important"):
    v = v[0 ..< ^"!important".len].strip()
  if v in ["flex", "inline-flex", "grid", "inline-grid"]:
    v
  else:
    ""

proc isHarmfulDeclaration*(prop, value: string): bool =
  prop.toLowerAscii() == "display" and harmfulDisplayValue(value) != ""

# ----------------------------------------------------------------------------
# Severity core
# ----------------------------------------------------------------------------

proc profileWeight*(profile: AudienceProfile;
                    families: set[ClientFamily]): float =
  for f in families:
    result += profile.weights[f]

proc formatPercent*(w: float): string =
  let rounded = round(w * 100.0, 1)
  let s = $rounded
  if s.endsWith(".0"):
    s[0 .. ^3]
  else:
    s

proc formatFamilies*(families: set[ClientFamily]): string =
  var ids: seq[string] = @[]
  for f in ClientFamily:
    if f in families:
      ids.add(f.familyId())
  ids.join(", ")

proc checkFeature*(slug, what: string; kind: LintKind; name: string;
                   profile: AudienceProfile;
                   expected: openArray[ExpectedDegradation];
                   origin: SourceSpan): seq[EmailDiagnostic] =
  ## One data-driven finding for caniemail `slug`, described as `what`.
  ## Returns zero or one diagnostic per the severity table. `name` is the
  ## declaration match key (see `ExpectedDegradation`).
  let affected = unsupportedFamilies(slug)
  if affected == {}:
    return @[]
  let weight = profileWeight(profile, affected)
  var declared: set[ClientFamily] = {}
  var note = ""
  for e in expected:
    if e.kind == kind and e.name.toLowerAscii() == name.toLowerAscii():
      declared.incl(e.families)
      if note.len == 0:
        note = e.note
  let uncovered = affected - declared
  if uncovered == {}:
    var msg = what & " degrades in " & formatFamilies(affected) &
      " as declared"
    if note.len > 0:
      msg.add(" (" & note & ")")
    return @[EmailDiagnostic(
      severity: sevInfo, code: codeSupportDegradation, message: msg,
      origin: origin, families: affected, weight: weight, rules: @[],
    )]
  let uncoveredWeight = profileWeight(profile, uncovered)
  if uncoveredWeight + 1e-9 >= supportWarnThreshold:
    let msg = what & " is unsupported in " & formatFamilies(uncovered) &
      " (" & formatPercent(uncoveredWeight) & "% of " & profile.name &
      " opens); declare the fallback or avoid " & name
    return @[EmailDiagnostic(
      severity: sevWarning, code: codeSupportUnsupported, message: msg,
      origin: origin, families: uncovered, weight: uncoveredWeight,
      rules: @[],
    )]
  if declared != {}:
    # Declared, with a below-threshold residue of accepted loss: still an
    # expected degradation, recorded as info.
    var msg = what & " degrades in " & formatFamilies(affected) &
      " as declared"
    if note.len > 0:
      msg.add(" (" & note & ")")
    return @[EmailDiagnostic(
      severity: sevInfo, code: codeSupportDegradation, message: msg,
      origin: origin, families: affected, weight: weight, rules: @[],
    )]
  @[]

# ----------------------------------------------------------------------------
# Head CSS scanning (selector and at-rule checks)
# ----------------------------------------------------------------------------

proc stripCssComments*(css: string): string =
  ## Removes `/* … */` spans (non-nesting); an unterminated comment drops
  ## the rest. Selectors and at-rules are never read out of comments.
  result = newStringOfCap(css.len)
  var i = 0
  while i < css.len:
    if i + 1 < css.len and css[i] == '/' and css[i + 1] == '*':
      let tail = css.find("*/", i + 2)
      if tail < 0:
        break
      i = tail + 2
    else:
      result.add(css[i])
      inc i

proc atRulesIn*(css: string): seq[string] =
  ## At-rule names (without `@`, lower-cased) in source order, deduped.
  ## Vendor prefixes are kept (`-moz-document` stays `-moz-document`);
  ## strings are opaque so `@` in `content` never reads as a rule.
  let clean = stripCssComments(css)
  var i = 0
  var inStr = '\0'
  while i < clean.len:
    let c = clean[i]
    if inStr != '\0':
      if c == inStr:
        inStr = '\0'
      inc i
    elif c in {'"', '\''}:
      inStr = c
      inc i
    elif c == '@':
      var j = i + 1
      while j < clean.len and
          clean[j] in {'A' .. 'Z', 'a' .. 'z', '-'}:
        inc j
      if j > i + 1:
        let name = clean[i + 1 ..< j].toLowerAscii()
        if name notin result:
          result.add(name)
      i = j
    else:
      inc i

proc splitSelectorList*(s: string): seq[string] =
  ## Comma-split respecting brackets, parens and strings.
  var depth = 0
  var inStr = '\0'
  var cur = ""
  for c in s:
    if inStr != '\0':
      cur.add(c)
      if c == inStr:
        inStr = '\0'
    elif c in {'"', '\''}:
      inStr = c
      cur.add(c)
    elif c in {'(', '['}:
      inc depth
      cur.add(c)
    elif c in {')', ']'}:
      dec depth
      cur.add(c)
    elif c == ',' and depth == 0:
      if cur.strip().len > 0:
        result.add(cur.strip())
      cur = ""
    else:
      cur.add(c)
  if cur.strip().len > 0:
    result.add(cur.strip())

proc splitCompounds*(sel: string): tuple[compounds: seq[string];
    combinators: seq[char]] =
  ## Splits a single selector into compounds and the combinator between
  ## each pair (`' '` descendant, `'>'`, `'+'`, `'~'`). Bracket, paren and
  ## string spans are opaque, so attribute values never split.
  var compounds: seq[string] = @[]
  var combinators: seq[char] = @[]
  var i = 0
  let n = sel.len
  while i < n:
    while i < n and sel[i] in {' ', '\t', '\n', '\r'}:
      inc i
    if i >= n:
      break
    if sel[i] in {'>', '+', '~'}:
      # Leading combinator (invalid CSS, or our grouping marker's
      # neighbour): skip it rather than misreading the rest.
      inc i
      continue
    var depth = 0
    var inStr = '\0'
    var cur = ""
    while i < n:
      let c = sel[i]
      if inStr != '\0':
        cur.add(c)
        if c == inStr:
          inStr = '\0'
        inc i
      elif c in {'"', '\''}:
        inStr = c
        cur.add(c)
        inc i
      elif c in {'(', '['}:
        inc depth
        cur.add(c)
        inc i
      elif c in {')', ']'}:
        dec depth
        cur.add(c)
        inc i
      elif depth == 0 and (c in {' ', '\t', '\n', '\r'} or
          c in {'>', '+', '~'}):
        break
      else:
        cur.add(c)
        inc i
    if cur.strip().len > 0:
      compounds.add(cur.strip())
    # The separator run: explicit combinator wins over whitespace.
    var explicit = '\0'
    var hasWs = false
    while i < n and (sel[i] in {' ', '\t', '\n', '\r'} or
        sel[i] in {'>', '+', '~'}):
      if sel[i] in {'>', '+', '~'}:
        explicit = sel[i]
      else:
        hasWs = true
      inc i
    # Peek: a trailing run with nothing after it separates nothing.
    var rest = false
    var j = i
    while j < n and sel[j] in {' ', '\t', '\n', '\r'}:
      inc j
    if j < n:
      rest = true
    if rest:
      if explicit != '\0':
        combinators.add(explicit)
      elif hasWs:
        combinators.add(' ')
  (compounds, combinators)

proc compoundKinds(compound: string): set[SelectorKind] =
  ## Kinds used inside one compound. Bracket spans and strings are opaque,
  ## so `[href="a.b"]` is attribute-only.
  var visible = ""
  var depth = 0
  var inStr = '\0'
  var hasAttr = false
  for c in compound:
    if inStr != '\0':
      if c == inStr:
        inStr = '\0'
    elif c in {'"', '\''}:
      inStr = c
    elif c == '[':
      inc depth
      hasAttr = true
    elif c == ']':
      dec depth
    elif depth == 0:
      visible.add(c)
  if hasAttr:
    result.incl(skAttribute)
  if '.' in visible:
    result.incl(skClass)
  if '#' in visible:
    result.incl(skId)
  if '*' in visible:
    result.incl(skUniversal)
  if compound.len > 0 and compound[0] in {'A' .. 'Z', 'a' .. 'z'}:
    result.incl(skType)
  # Chaining: two or more simple selectors on the same compound
  # (`div.a`, `.a.b`, `a[href]`). Occurrences count, not kinds.
  var chained = 0
  for c in visible:
    if c in {'.', '#'}:
      inc chained
  for c in compound:
    if c == '[':
      inc chained
  if skType in result:
    inc chained
  if chained >= 2:
    result.incl(skChaining)

proc classifySelector*(sel: string): set[SelectorKind] =
  ## Every selector kind a single (comma-free) selector uses.
  ## Pseudo-classes and pseudo-elements are not classified (no seed:
  ## `:hover` is required for webmail hover states).
  let (compounds, combinators) = splitCompounds(sel.strip())
  for compound in compounds:
    result.incl(compoundKinds(compound))
  for c in combinators:
    case c
    of '>': result.incl(skChild)
    of '+': result.incl(skAdjacentSibling)
    of '~': result.incl(skGeneralSibling)
    else: result.incl(skDescendant)

proc selectorsIn*(css: string): seq[string] =
  ## Selectors in source order. Tolerant of `@media` nesting: every `{`
  ## contributes the text since the previous boundary, and `@`-led
  ## preludes are dropped. A rule with a selector list also yields the
  ## grouping marker `","` (handled by `lintHeadCss`).
  let clean = stripCssComments(css)
  var boundary = 0
  var i = 0
  while i < clean.len:
    if clean[i] == '{':
      let prelude = clean[boundary ..< i].strip()
      if prelude.len > 0 and not prelude.startsWith("@"):
        let sels = splitSelectorList(prelude)
        result.add(sels)
        if sels.len > 1:
          result.add(",")
      boundary = i + 1
    elif clean[i] == '}' or clean[i] == ';':
      boundary = i + 1
    inc i

proc lintHeadCss*(css: string; profile: AudienceProfile;
                  expected: openArray[ExpectedDegradation] = [];
                  origin = SourceSpan()): seq[EmailDiagnostic] =
  ## At-rule and selector checks over one head CSS block. Findings share
  ## the block's origin and dedupe per (kind, name).
  var seen: seq[string] = @[]
  for name in atRulesIn(css):
    let slug = atRuleSlug(name)
    if slug.len == 0:
      continue
    let key = "at-rule:" & name
    if key in seen:
      continue
    seen.add(key)
    result.add(checkFeature(slug, "@" & name, lkAtRule, name, profile,
      expected, origin))
  for sel in selectorsIn(css):
    if sel == ",":
      let slug = selectorSlug(skGrouping)
      if slug.len == 0 or "selector:grouping" in seen:
        continue
      seen.add("selector:grouping")
      result.add(checkFeature(slug, "selector grouping", lkSelector,
        "grouping", profile, expected, origin))
      continue
    for kind in classifySelector(sel):
      let slug = selectorSlug(kind)
      if slug.len == 0:
        continue
      let key = "selector:" & selectorKindId(kind)
      if key in seen:
        continue
      seen.add(key)
      result.add(checkFeature(slug,
        "selector '" & sel.strip() & "' (" & selectorKindId(kind) & ")",
        lkSelector, selectorKindId(kind), profile, expected, origin))

# ----------------------------------------------------------------------------
# Tree walk (property, value, element and attribute checks)
# ----------------------------------------------------------------------------

proc splitVariantKey*(key: string): tuple[variant, base: string] =
  ## Splits a Tailwind variant style key (`@dark:border-radius`) into its
  ## variant and base property; plain keys yield `("", key)`.
  if key.startsWith("@"):
    let sep = key.find(':')
    if sep > 0:
      return (key[1 ..< sep], key[sep + 1 .. ^1])
  ("", key)

proc lintStyles*(tag: string;
                 styles: openArray[(string, string)];
                 profile: AudienceProfile;
                 expected: openArray[ExpectedDegradation];
                 origin: SourceSpan): seq[EmailDiagnostic] =
  ## Property and value checks over one node's declarations.
  for (rawProp, value) in styles:
    let (variant, prop) = splitVariantKey(rawProp)
    let base = prop.toLowerAscii()
    # Harmful values apply to inline declarations only: Word ignores head
    # rules entirely, so a variant (head-bound) flex cannot collapse it.
    if variant.len == 0 and isHarmfulDeclaration(base, value):
      let keyword = harmfulDisplayValue(value)
      let harmfulFams = {cfOutlookWord}
      let w = profileWeight(profile, harmfulFams)
      if isLayoutContainer(tag):
        result.add(EmailDiagnostic(
          severity: sevError, code: codeCssHarmful,
          message: "display:" & keyword & " on <" & tag &
            "> collapses in Word-engine Outlook; use mailColumns or " &
            "mailStack instead",
          origin: origin, families: harmfulFams, weight: w,
          rules: @["R-OL-10"],
        ))
      else:
        result.add(EmailDiagnostic(
          severity: sevWarning, code: codeSupportUnsupported,
          message: "display:" & keyword & " on <" & tag &
            "> is not supported in email and will be removed; " &
            "restructure to avoid it",
          origin: origin, families: harmfulFams, weight: w,
          rules: @["R-OL-10"],
        ))
      continue
    let vs = valueSlug(base, value)
    if vs.len > 0:
      result.add(checkFeature(vs, base & ":" & value.strip().toLowerAscii(),
        lkValue, base & "=" & value.strip().toLowerAscii(), profile,
        expected, origin))
    let ps = propertySlug(base)
    if ps.len > 0:
      var what = base
      if variant.len > 0:
        what.add(" (@" & variant & " variant)")
      result.add(checkFeature(ps, what, lkProperty, base, profile,
        expected, origin))

# ----------------------------------------------------------------------------
# Accessibility checks (R-A11Y-06, R-A11Y-07, R-IMG-04 length)
# ----------------------------------------------------------------------------

proc collectText(node: EmailNode): string =
  ## Every descendant `enText` payload in document order. `enRaw`
  ## payloads stay unaudited, as everywhere else in this pass.
  if node == nil:
    return ""
  if node.kind == enText:
    return node.text
  for c in node.children:
    result.add(collectText(c))

proc lintLinkText(node: EmailNode): seq[EmailDiagnostic] =
  ## R-A11Y-06: link text that is meaningless out of context —
  ## "click here", "here", "read more", or a bare URL — warns.
  if node.kind != enElement or node.tag.toLowerAscii() != "a":
    return @[]
  let shown = collectText(node).strip()
  let text = shown.toLowerAscii()
  if text in ["click here", "here", "read more"] or
      text.startsWith("http://") or text.startsWith("https://"):
    return @[EmailDiagnostic(
      severity: sevWarning, code: codeA11yLinkText,
      message: "link text \"" & shown &
        "\" is not meaningful out of context (R-A11Y-06)",
      origin: node.origin, rules: @["R-A11Y-06"],
    )]
  @[]

proc channelLuminance(c: int): float =
  ## One sRGB channel's linearised contribution (WCAG 2 relative
  ## luminance).
  let s = c.float / 255.0
  if s <= 0.03928:
    s / 12.92
  else:
    pow((s + 0.055) / 1.055, 2.4)

proc relativeLuminance(c: Rgba): float =
  0.2126 * channelLuminance(c.r) + 0.7152 * channelLuminance(c.g) +
    0.0722 * channelLuminance(c.b)

proc contrastRatio(a, b: Rgba): float =
  ## WCAG contrast of two opaque colours, 1..21.
  let hi = max(relativeLuminance(a), relativeLuminance(b))
  let lo = min(relativeLuminance(a), relativeLuminance(b))
  (hi + 0.05) / (lo + 0.05)

proc fontSizePx(value: string): float =
  ## Trailing-`px` sizes in pixels; anything else is 0, which is
  ## never large (unknown sizes take the strict threshold).
  let v = value.strip().toLowerAscii()
  if not v.endsWith("px"):
    return 0.0
  try:
    parseFloat(v[0 ..< ^2].strip())
  except ValueError:
    0.0

proc isBoldWeight(value: string): bool =
  ## `bold`, or a numeric weight of at least 700.
  let v = value.strip().toLowerAscii()
  if v == "bold":
    return true
  try:
    parseFloat(v) >= 700.0
  except ValueError:
    false

proc lintContrast(node: EmailNode;
                 ancestors: seq[EmailNode]): seq[EmailDiagnostic] =
  ## R-A11Y-07: WCAG contrast below 4.5:1 warns (below 3:1 for large
  ## text: 24px+, or 18.66px+ bold). Foreground from the element's
  ## own `color` (absent means skipped), background from the nearest
  ## ancestor `background-color`, else white. Unparseable colours
  ## are skipped: P2 owns bad values, not this check.
  ##
  ## Light-scheme pairs only: dark-mode and inversion simulation
  ## (R-DRK-04, `E-A11Y-CONTRAST` / `W-A11Y-CONTRAST-INVERTED`)
  ## arrive with calibrated Gmail/Outlook.com models — this check
  ## never inverts.
  if node.kind != enElement:
    return @[]
  if node.tag.toLowerAscii() notin ["h1", "h2", "h3", "h4", "h5", "h6",
      "p", "li", "span", "a", "td"]:
    return @[]
  if "color" notin node.styles:
    return @[]
  var bgValue = ""
  for i in countdown(ancestors.high, 0):
    if ancestors[i] != nil and
        "background-color" in ancestors[i].styles:
      bgValue = ancestors[i].styles["background-color"]
      break
  let white = Rgba(r: 255, g: 255, b: 255, a: 1.0)
  var fg, bg: Rgba
  try:
    fg = parseColor(node.styles["color"])
    bg = if bgValue.len > 0: parseColor(bgValue) else: white
  except ValueError:
    return @[]
  if bg.a < 1.0:
    bg = blendOver(bg, white)
  if fg.a < 1.0:
    fg = blendOver(fg, bg)
  let size = fontSizePx(node.styles.getOrDefault("font-size", ""))
  let large = size >= 24.0 or
    (size >= 18.66 and isBoldWeight(node.styles.getOrDefault(
      "font-weight", "")))
  let threshold = if large: 3.0 else: 4.5
  let ratio = contrastRatio(fg, bg)
  if ratio < threshold:
    let threshText = if large: "3" else: "4.5"
    return @[EmailDiagnostic(
      severity: sevWarning, code: codeA11yContrast,
      message: "<" & node.tag & "> text/background contrast " &
        formatFloat(ratio, ffDecimal, 2) & ":1 is below " & threshText &
        ":1 (R-A11Y-07)",
      origin: node.origin, rules: @["R-A11Y-07"],
    )]
  @[]

proc lintAltLength(node: EmailNode): seq[EmailDiagnostic] =
  ## R-IMG-04's length half (P1 owns presence): alt longer than 60
  ## characters warns — usually text baked into the image.
  if node.kind != enElement or node.tag notin ["mailImage", "img"]:
    return @[]
  let alt = node.attrs.getOrDefault("alt", "")
  if alt.len > 60:
    return @[EmailDiagnostic(
      severity: sevWarning, code: codeA11yAltLong,
      message: "<" & node.tag & "> alt is " & $alt.len &
        " characters (R-IMG-04: alt longer than 60 characters warns)",
      origin: node.origin, rules: @["R-IMG-04"],
    )]
  @[]

proc lintTreeImpl(node: EmailNode; profile: AudienceProfile;
                  expected: openArray[ExpectedDegradation];
                  ancestors: seq[EmailNode]): seq[EmailDiagnostic] =
  ## `lintTree` with the ancestor chain (for contrast backgrounds).
  if node == nil:
    return @[]
  case node.kind
  of enElement:
    let es = elementSlug(node.tag)
    if es.len > 0:
      result.add(checkFeature(es, "<" & node.tag.toLowerAscii() & ">",
        lkElement, node.tag, profile, expected, node.origin))
    for attr, _ in node.attrs.pairs:
      let aus = attributeSlug(attr)
      if aus.len > 0:
        result.add(checkFeature(aus, attr.toLowerAscii() & " attribute",
          lkAttribute, attr, profile, expected, node.origin))
    var decls: seq[(string, string)] = @[]
    for prop, value in node.styles.pairs:
      decls.add((prop, value))
    result.add(lintStyles(node.tag, decls, profile, expected, node.origin))
    result.add(lintLinkText(node))
    result.add(lintContrast(node, ancestors))
    result.add(lintAltLength(node))
  of enHeadStyle:
    result.add(lintHeadCss(node.text, profile, expected, node.origin))
  of enText, enRaw, enMsoIf, enNotMso, enVml:
    discard
  var next = ancestors
  next.add(node)
  for child in node.children:
    result.add(lintTreeImpl(child, profile, expected, next))

const sizeErrorLimit* = 100_000
  ## R-SIZE-01: decoded HTML above this errors — Gmail clips at about
  ## 102 KB, hiding the footer and the unsubscribe link.

proc decodedHtmlSize*(html: string): int =
  ## The R-SIZE-01 measure: bytes of the decoded text/html part.
  html.len

proc checkSize*(html: string; target: EmailTarget;
               breakdown: seq[(string, int)] = @[]): seq[EmailDiagnostic] =
  ## The P10 size budget (R-SIZE-01, R-SIZE-02): silent at or under
  ## `target.sizeBudget`, `W-SIZE-NEAR-CLIP` above it, `E-SIZE-CLIP`
  ## above `sizeErrorLimit`. The message reports the contributor
  ## breakdown (head CSS, inline styles, URLs, preheader padding,
  ## MSO/VML) when the caller passes one.
  let size = decodedHtmlSize(html)
  if size <= target.sizeBudget:
    return @[]
  var rules = @["R-SIZE-01"]
  var message = "decoded HTML is " & $size & " bytes (budget " &
    $target.sizeBudget & "; hard limit " & $sizeErrorLimit & ")"
  if breakdown.len > 0:
    rules.add("R-SIZE-02")
    var parts: seq[string] = @[]
    for (what, bytes) in breakdown:
      parts.add(what & " " & $bytes)
    message.add(": " & parts.join("; "))
  if size > sizeErrorLimit:
    @[EmailDiagnostic(severity: sevError, code: codeSizeClip,
      message: message, rules: rules)]
  else:
    @[EmailDiagnostic(severity: sevWarning, code: codeSizeNearClip,
      message: message, rules: rules)]

proc lintTree*(node: EmailNode; profile: AudienceProfile;
               expected: openArray[ExpectedDegradation] = []): seq[
                   EmailDiagnostic] =
  ## P10 over one tree: element, attribute, property and value checks per
  ## element node, head-CSS checks per `enHeadStyle` block, the a11y
  ## checks (link text, contrast, alt length), recursing through every
  ## node kind (conditional branches are emitted content). Findings keep
  ## tree order; nothing dedupes — each names its origin.
  lintTreeImpl(node, profile, expected, @[])
