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
## Construction checks (catalogue §4b, §5): a layout `table` outside
## the constructs allowed to emit one (`W-TBL-UNEXPECTED`, R-TBL-01; in
## the authoring tree, any `table` outside a `mailTable`), `rowspan`
## anywhere or `colspan` outside a data table's header row
## (`W-TBL-SPAN`, R-TBL-06), and, over the lowered document, more than
## three levels of layout tables outside Outlook conditionals
## (`W-TBL-DEEP`, R-TBL-15) and any `mso-*` property outside the closed
## list (`W-CSS-MSO-UNLISTED`, R-OL-15). Layout props of the vocabulary
## that are not CSS (a stack's `gap`) are not linted as CSS: the
## lowering turns them into padding and spacer rows.
##
## The a11y lint covers meaningless link text (R-A11Y-06),
## light-scheme text/background contrast (R-A11Y-07), and the
## R-IMG-04 alt-length heuristic. All three are warnings. Text sizes
## (R-TXT-03): text below 14px warns, below 12px is an error.
##
## Raw markup (R-RAW-01): a payload inside `mailRaw` that `raw.nim`
## reads with no error is linted like everything else, in place, its
## tree under the raw node's ancestors; one with an error is P1's to
## report and is not linted.
## `lintDarkContrast` adds R-DRK-04's dark scheme under
## `darkMode = designed`: each pair as the dark head rules paint it,
## an error (`E-A11Y-CONTRAST`). The partial and full inversion
## models are not checked yet.

import std/[math, strutils, tables, unicode]
import ../diagnostics
import ../renderer
import ../style/colors
import ../style/units
import ../style/shorthand
import ../style/ascii
import ../style/memo
import ../support/families
import ../raw
import ../target
import ../assets
import ../imaging
import ./layout

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

proc propertySlugOf(prop: string): string =
  ## `propertySlug` of a lower-case property.
  case prop
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

proc propertySlug*(prop: string): string =
  ## CSS property → caniemail slug.
  if hasUpperAscii(prop): propertySlugOf(prop.toLowerAscii())
  else: propertySlugOf(prop)

proc valueSlug*(prop, value: string): string =
  ## `(property, value keyword)` → caniemail slug.
  if not eqLowerAscii(prop, "display"):
    # Every keyword below is a `display` value.
    return ""
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

proc atRuleSlugOf(name: string): string =
  case name
  of "font-face": "css-at-font-face"
  of "import": "css-at-import"
  of "supports": "css-at-supports"
  of "keyframes": "css-at-keyframes"
  else: ""

proc atRuleSlug*(name: string): string =
  ## At-rule name (without `@`) → caniemail slug.
  if hasUpperAscii(name): atRuleSlugOf(name.toLowerAscii())
  else: atRuleSlugOf(name)

proc elementSlugOf(tag: string): string =
  case tag
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

proc elementSlug*(tag: string): string =
  ## HTML element → caniemail slug.
  if hasUpperAscii(tag): elementSlugOf(tag.toLowerAscii())
  else: elementSlugOf(tag)

proc attributeSlugOf(attr: string): string =
  case attr
  of "align": "html-align"
  of "valign": "html-valign"
  of "cellspacing": "html-cellspacing"
  of "cellpadding": "html-cellpadding"
  else: ""

proc attributeSlug*(attr: string): string =
  ## HTML attribute → caniemail slug.
  if hasUpperAscii(attr): attributeSlugOf(attr.toLowerAscii())
  else: attributeSlugOf(attr)

# ----------------------------------------------------------------------------
# Harmful values (R-OL-10)
# ----------------------------------------------------------------------------

proc isLayoutContainer*(tag: string): bool =
  ## Tags whose box positions other content: the `mail*` structural set,
  ## the document root, and the lowered structural elements. `display:flex`
  ## /`grid` on one of these collapses the layout in Word-engine Outlook
  ## (error); anywhere else it is removed with a warning (R-OL-10).
  tag.inLowerAscii [
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
  eqLowerAscii(prop, "display") and harmfulDisplayValue(value) != ""

# ----------------------------------------------------------------------------
# Severity core
# ----------------------------------------------------------------------------

proc profileWeight*(profile: AudienceProfile;
                    families: set[ClientFamily]): float =
  for f in families:
    result += profile.weights[f]

proc harmfulDisplayDiagnostic*(tag, keyword: string;
                               profile: AudienceProfile;
                               origin: SourceSpan;
                               removed: bool): EmailDiagnostic =
  ## R-OL-10's one severity rule, shared by lint and the inline style
  ## pass (which removes the declaration on every element): an error on a
  ## layout container while the profile gives Word-engine Outlook weight,
  ## where flex/grid collapses the layout; otherwise the removal warning —
  ## off a container nothing collapses, and with no Word-engine weight
  ## nobody opens the mail where it would. `removed` picks the tense of
  ## the warning ("was removed" from the pass, "will be" from lint).
  let fams = {cfOutlookWord}
  let w = profileWeight(profile, fams)
  if isLayoutContainer(tag) and w > 0.0:
    EmailDiagnostic(
      severity: sevError, code: codeCssHarmful,
      message: "display:" & keyword & " on <" & tag &
        "> collapses in Word-engine Outlook; use mailColumns or " &
        "mailStack instead",
      origin: origin, families: fams, weight: w, rules: @["R-OL-10"])
  else:
    EmailDiagnostic(
      severity: sevWarning, code: codeSupportUnsupported,
      message: "display:" & keyword & " on <" & tag &
        "> is not supported in email and " &
        (if removed: "was removed" else: "will be removed") &
        "; restructure to avoid it",
      origin: origin, families: fams, weight: w, rules: @["R-OL-10"])

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
    if e.kind == kind and cmpIgnoreCase(e.name, name) == 0:
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

proc lintDeclBase(tag, variant, base, value: string;
                  profile: AudienceProfile;
                  expected: openArray[ExpectedDegradation];
                  origin: SourceSpan; acc: var seq[EmailDiagnostic]) =
  ## `lintStyles` over one declaration, its property split from its
  ## variant and lower-cased (`base`).
  # Harmful values apply to inline declarations only: Word ignores head
  # rules entirely, so a variant (head-bound) flex cannot collapse it.
  if variant.len == 0 and isHarmfulDeclaration(base, value):
    acc.add(harmfulDisplayDiagnostic(tag, harmfulDisplayValue(value),
      profile, origin, removed = false))
    return
  let vs = valueSlug(base, value)
  if vs.len > 0:
    acc.add(checkFeature(vs, base & ":" & value.strip().toLowerAscii(),
      lkValue, base & "=" & value.strip().toLowerAscii(), profile,
      expected, origin))
  let ps = propertySlug(base)
  # `checkFeature` finds nothing for a feature every family supports;
  # the description is built only for one that some family lacks.
  if ps.len > 0 and unsupportedFamilies(ps) != {}:
    var what = base
    if variant.len > 0:
      what.add(" (@" & variant & " variant)")
    acc.add(checkFeature(ps, what, lkProperty, base, profile,
      expected, origin))

proc lintDecl(tag, rawProp, value: string; profile: AudienceProfile;
              expected: openArray[ExpectedDegradation];
              origin: SourceSpan; acc: var seq[EmailDiagnostic]) =
  ## `lintStyles` over one declaration as the node keeps it: the
  ## variant split off (`splitVariantKey`) and the property lower-cased,
  ## copying only a key that has a variant or a capital.
  if rawProp.startsWith("@") and rawProp.find(':') > 0:
    let (variant, prop) = splitVariantKey(rawProp)
    lintDeclBase(tag, variant, prop.toLowerAscii(), value, profile,
      expected, origin, acc)
  elif hasUpperAscii(rawProp):
    lintDeclBase(tag, "", rawProp.toLowerAscii(), value, profile,
      expected, origin, acc)
  else:
    lintDeclBase(tag, "", rawProp, value, profile, expected, origin, acc)

proc lintStyles*(tag: string;
                 styles: openArray[(string, string)];
                 profile: AudienceProfile;
                 expected: openArray[ExpectedDegradation];
                 origin: SourceSpan): seq[EmailDiagnostic] =
  ## Property and value checks over one node's declarations.
  for (rawProp, value) in styles:
    lintDecl(tag, rawProp, value, profile, expected, origin, result)

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
  if node.kind != enElement or not eqLowerAscii(node.tag, "a"):
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

proc contrastRatio*(a, b: Rgba): float =
  ## WCAG contrast of two opaque colours, 1..21.
  let hi = max(relativeLuminance(a), relativeLuminance(b))
  let lo = min(relativeLuminance(a), relativeLuminance(b))
  (hi + 0.05) / (lo + 0.05)

proc computeFontSizePx(value: string): float =
  ## `fontSizePx`, parsed every time.
  let v = value.strip().toLowerAscii()
  if not v.endsWith("px"):
    return 0.0
  try:
    parseFloat(v[0 ..< ^2].strip())
  except ValueError:
    0.0

var fontSizePxMemo {.threadvar.}: Table[string, float]
  ## `fontSizePx` per value, as parsed once on this thread (`memo.nim`).

proc fontSizePx(value: string): float =
  ## Trailing-`px` sizes in pixels; anything else is 0, which is
  ## never large (unknown sizes take the strict threshold).
  memoised(fontSizePxMemo, 1024, value, computeFontSizePx(value))

proc isBoldWeight(value: string): bool =
  ## `bold`, or a numeric weight of at least 700.
  let v = value.strip().toLowerAscii()
  if v == "bold":
    return true
  try:
    parseFloat(v) >= 700.0
  except ValueError:
    false

const imageBandTags = ["mailSection", "mailWrapper", "mailHero"]
  ## The bands that take a background image (R-VML-01).

proc hasBackgroundImage(node: EmailNode): bool =
  ## A band with a background image, read as the lowering reads it (a
  ## style or an attribute, either spelling: `rawValue`).
  rawValue(node, "background-image").len > 0

type TextPair = object
  ## A text element's light-scheme pair: its colour, the background it
  ## sits on, whether it is large text (the 3:1 threshold), and whether
  ## a band's background image is on the way (the background is then
  ## the image's fallback colour).
  ok: bool
  fg, bg: Rgba
  large, overImage: bool

const contrastTags = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li",
  "span", "a", "td", "mailbutton"]
  ## The elements whose text the contrast checks read.

proc holdsVisibleText(node: EmailNode): bool =
  ## True when some text under `node` holds something a reader sees: not
  ## only white space (a no-break space included) or zero-width
  ## characters, which spacers and painted cells carry to keep a box
  ## from collapsing.
  if node.kind == enText:
    for ch in node.text.runes:
      if not ch.isWhiteSpace() and ch.int notin [0x200B, 0x200C, 0x200D,
          0xFEFF, 0x034F]:
        return true
    return false
  for c in node.children:
    if holdsVisibleText(c):
      return true
  false

proc textPairOf(node: EmailNode; ancestors: seq[EmailNode]): TextPair =
  ## Foreground from the element's own `color` (absent: not ok),
  ## background from the element's own `background-color` (a button's
  ## fill, a step marker, a date tile's month row), else the nearest
  ## ancestor's, else white. Unparseable colours are not ok: P2 owns bad
  ## values, not the contrast checks.
  if node.kind != enElement or "color" notin node.styles or
      not node.tag.inLowerAscii(contrastTags):
    return
  if not holdsVisibleText(node):
    # A spacer or a painted cell: no text to read.
    return
  # Text sits on its own element's background, when it has one.
  var bgValue = node.styles.getOrDefault("background-color", "")
  for i in countdown(ancestors.high, 0):
    if bgValue.len > 0:
      break
    let a = ancestors[i]
    if a == nil:
      continue
    if a.kind == enElement and a.tag in imageBandTags and
        hasBackgroundImage(a):
      # Text over a band's background image (R-VML-01): the image may
      # be blocked, so the pair checked is the text and the fallback
      # colour that shows instead (the band's own, else the nearest
      # enclosing one, as the lowering paints it).
      result.overImage = true
    if "background-color" in a.styles:
      bgValue = a.styles["background-color"]
      break
  let white = Rgba(r: 255, g: 255, b: 255, a: 1.0)
  try:
    result.fg = parseColor(node.styles["color"])
    result.bg = if bgValue.len > 0: parseColor(bgValue) else: white
  except ValueError:
    return
  if result.bg.a < 1.0:
    result.bg = blendOver(result.bg, white)
  if result.fg.a < 1.0:
    result.fg = blendOver(result.fg, result.bg)
  let size = fontSizePx(node.styles.getOrDefault("font-size", ""))
  result.large = size >= 24.0 or
    (size >= 18.66 and isBoldWeight(node.styles.getOrDefault(
      "font-weight", "")))
  result.ok = true

proc lintContrast(node: EmailNode;
                 ancestors: seq[EmailNode]): seq[EmailDiagnostic] =
  ## R-A11Y-07: WCAG contrast below 4.5:1 warns (below 3:1 for large
  ## text: 24px+, or 18.66px+ bold), over `textPairOf`'s pair.
  ##
  ## Light-scheme pairs only: the designed dark scheme is
  ## `lintDarkContrast`'s and the inverted ones `lintInversion`'s
  ## (R-DRK-04).
  let pair = textPairOf(node, ancestors)
  if not pair.ok:
    return @[]
  let threshold = if pair.large: 3.0 else: 4.5
  let ratio = contrastRatio(pair.fg, pair.bg)
  if ratio < threshold:
    let threshText = if pair.large: "3" else: "4.5"
    if pair.overImage:
      return @[EmailDiagnostic(
        severity: sevWarning, code: codeA11yContrast,
        message: "<" & node.tag & "> text over a background image has " &
          "contrast " & formatFloat(ratio, ffDecimal, 2) & ":1 against " &
          "the image's fallback colour, below " & threshText & ":1: the " &
          "fallback shows when images are blocked, so it must carry the " &
          "text (R-VML-01, R-A11Y-07)",
        origin: node.origin, rules: @["R-VML-01", "R-A11Y-07"],
      )]
    return @[EmailDiagnostic(
      severity: sevWarning, code: codeA11yContrast,
      message: "<" & node.tag & "> text/background contrast " &
        formatFloat(ratio, ffDecimal, 2) & ":1 is below " & threshText &
        ":1 (R-A11Y-07)",
      origin: node.origin, rules: @["R-A11Y-07"],
    )]
  @[]

# ----------------------------------------------------------------------------
# Inversion simulation (R-DRK-04, spec: inversion safety)
# ----------------------------------------------------------------------------

type InversionModel* = enum
  ## R-DRK-04's two models of a client that recolours a message itself.
  imPartial ## light backgrounds darkened, dark text lightened
  imFull    ## every colour inverted

const
  partialInverters* = {cfGmailApp, cfOutlookWeb, cfOutlookWord}
    ## The families R-DRK-04's partial model stands for: the Gmail app on
    ## Android, Outlook.com's automatic dark mode and Outlook 365 for
    ## Windows.
  fullInverters* = {cfGmailApp}
    ## The family the full model stands for: the Gmail app on iOS.
  inversionPivot* = 0.5
    ## The relative luminance above which a background, and below which
    ## a text colour, is inverted by the partial model.
  modelCalibrated*: array[InversionModel, bool] = [false, false]
    ## Whether each model has been calibrated against captures of the
    ## clients it stands for (catalogue R-DRK-04). An uncalibrated
    ## model's findings are `I-A11Y-CONTRAST-INVERTED`, information only;
    ## a calibrated one's are `W-A11Y-CONTRAST-INVERTED`. Calibrating a
    ## model records its formula in the catalogue and sets its flag.

proc modelName*(m: InversionModel): string =
  case m
  of imPartial: "partial"
  of imFull: "full"

proc relLuminance*(c: Rgba): float =
  ## WCAG 2 relative luminance of an opaque colour.
  relativeLuminance(c)

proc invertPair*(fg, bg: Rgba; model: InversionModel): tuple[fg, bg: Rgba] =
  ## The pair as R-DRK-04's model recolours it (an uncalibrated model:
  ## OKLCH lightness inverted, chroma and hue kept). Partial: a
  ## background lighter than the pivot and a text colour darker than it
  ## are inverted, the rest kept. Full: both are inverted.
  case model
  of imPartial:
    let f = if relativeLuminance(fg) < inversionPivot: invertLightness(fg)
      else: fg
    let b = if relativeLuminance(bg) > inversionPivot: invertLightness(bg)
      else: bg
    (f, b)
  of imFull:
    (invertLightness(fg), invertLightness(bg))

proc inversionFamilies(model: InversionModel): set[ClientFamily] =
  case model
  of imPartial: partialInverters
  of imFull: fullInverters

proc lintInversion*(root: EmailNode;
                    profile: AudienceProfile): seq[EmailDiagnostic] =
  ## R-DRK-04's inversion simulation (P10): every text/background pair of
  ## the light scheme, recoloured by the partial and the full model, must
  ## keep 4.5:1 (3:1 for large text); below is
  ## `W-A11Y-CONTRAST-INVERTED` for a calibrated model and
  ## `I-A11Y-CONTRAST-INVERTED` for one that is not (`modelCalibrated`),
  ## naming the pair before and after and the
  ## families the model stands for, weighted by `profile`. One warning
  ## per model and pair, at its first element, counting the others: a
  ## palette that inverts into mud does so wherever it is used. A model
  ## whose families have no weight in `profile` is not checked.
  ##
  ## The models are R-DRK-04's own; until one is calibrated against the
  ## clients it stands for, its findings are information and the message
  ## says so.
  type Seen = tuple[model: InversionModel; fg, bg: string; large: bool]
  var seen: seq[Seen] = @[]
  var at: seq[int] = @[]
  var counts: seq[int] = @[]
  var diags: seq[EmailDiagnostic] = @[]
  proc walk(node: EmailNode; ancestors: var seq[EmailNode]) =
    if node == nil or (node.kind == enElement and node.tag == "textOnly"):
      return
    if node.kind == enElement:
      let pair = textPairOf(node, ancestors)
      if pair.ok:
        for model in InversionModel:
          var fams: set[ClientFamily] = {}
          var weight = 0.0
          for f in inversionFamilies(model):
            if profile.weights[f] > 0:
              fams.incl(f)
              weight += profile.weights[f]
          if fams == {}:
            continue
          var (fg2, bg2) = invertPair(pair.fg, pair.bg, model)
          let threshold = if pair.large: 3.0 else: 4.5
          var ratio = contrastRatio(fg2, bg2)
          var onImage = false
          if pair.overImage:
            # Text over a background image: the recoloured fallback is
            # what shows with images blocked; with images on, the text is
            # recoloured and the image is not (no model recolours an
            # image; measured on Blink's automatic dark mode), and the
            # light fallback colour stands for the image. The worse holds.
            let onImg = contrastRatio(fg2, pair.bg)
            if onImg < ratio:
              ratio = onImg
              bg2 = pair.bg
              onImage = true
          if ratio >= threshold:
            continue
          let key: Seen = (model, pair.fg.toHex(), pair.bg.toHex(),
            pair.large)
          let idx = seen.find(key)
          if idx >= 0:
            inc counts[idx]
            continue
          seen.add(key)
          counts.add(1)
          at.add(diags.len)
          let calibrated = modelCalibrated[model]
          diags.add(EmailDiagnostic(
            severity: if calibrated: sevWarning else: sevInfo,
            code: if calibrated: codeA11yContrastInverted
              else: codeA11yContrastInvertedInfo,
            message: "<" & node.tag & "> text " & pair.fg.toHex() &
              " on " & pair.bg.toHex() & " becomes " & fg2.toHex() &
              " on " & bg2.toHex() &
              (if onImage: " (its background image, which no model " &
                "recolours; the fallback colour stands for it)" else: "") &
              " under " & modelName(model) &
              " inversion (" & formatFamilies(fams) & "): contrast " &
              formatFloat(ratio, ffDecimal, 2) & ":1, below " &
              (if pair.large: "3" else: "4.5") & ":1 (R-DRK-04" &
              (if calibrated: ")" else: ", an uncalibrated model: " &
                "for information)"),
            origin: node.origin, families: fams, weight: weight,
            rules: @["R-DRK-04"]))
    ancestors.add(node)
    for c in node.children:
      walk(c, ancestors)
    discard ancestors.pop()
  var ancestors: seq[EmailNode] = @[]
  walk(root, ancestors)
  for i, idx in at:
    if counts[i] > 1:
      diags[idx].message.add("; the same pair on " & $(counts[i] - 1) &
        " more element" & (if counts[i] > 2: "s" else: ""))
  diags

# ----------------------------------------------------------------------------
# A logo with no swap (R-DRK-06, spec: images in dark mode)
# ----------------------------------------------------------------------------

const
  nearBlack* = Rgba(r: 0x12, g: 0x12, b: 0x12, a: 1.0)
    ## The dark surface a logo must read on where no swap happens: a
    ## dark mail client's near-black reading pane (#121212).
  logoEdgePx* = 2
    ## How far in from its transparent surroundings a logo's edge is
    ## read: R-DRK-06's 2px outline or plate.
  noSwapFamilies* = {cfGmailWeb, cfGmailApp, cfGanga, cfYahoo,
    cfOutlookWord, cfProton, cfHey, cfThunderbird}
    ## The families that never apply the dark block's image swap
    ## (R-DRK-01; Thunderbird applies no media query and gets only the
    ## palette, R-DRK-08), so show the light image of a pair in dark mode
    ## too.

type LogoVerdict* = enum
  lvSafe       ## legible on white and on near-black
  lvUnsafe     ## illegible on one of them
  lvUnknown    ## not a PNG this check reads
  lvTooLarge   ## over `maxDecodePixels`: not decoded

proc logoVerdict*(bytes: string): tuple[verdict: LogoVerdict;
    failsOn: string] =
  ## R-DRK-06's alpha heuristic. An image with no transparent pixel
  ## carries its own plate: safe. Otherwise its **edge** is the opaque
  ## pixels within `logoEdgePx` of a transparent one, and on a
  ## background the image is legible when at least half of its edge
  ## contrasts at least 3:1 with that background (WCAG's non-text
  ## threshold: the silhouette shows, as a dark logo's does on white
  ## or a light outline's on black), or its edge is a **plate**: one
  ## colour (90% of it within 1.5:1 of its mean) holding content that
  ## contrasts 3:1 with it (5% of the pixels inside). The image is safe
  ## when it is legible on white and on near-black. `failsOn` names the
  ## background it fails on.
  let px = decodePng(bytes)
  if px.tooLarge:
    return (lvTooLarge, "")
  if not px.ok:
    return (lvUnknown, "")
  let w = px.width
  let h = px.height
  var transparent = newSeq[bool](w * h)
  var anyTransparent, anyOpaque = false
  for i in 0 ..< w * h:
    transparent[i] = px.rgba[i * 4 + 3] < 128
    if transparent[i]: anyTransparent = true
    else: anyOpaque = true
  if not anyTransparent:
    return (lvSafe, "")
  if not anyOpaque:
    return (lvUnknown, "")
  var edge = newSeq[bool](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      if not transparent[y * w + x]:
        continue
      for dy in -logoEdgePx .. logoEdgePx:
        for dx in -logoEdgePx .. logoEdgePx:
          let (xx, yy) = (x + dx, y + dy)
          if xx >= 0 and yy >= 0 and xx < w and yy < h and
              not transparent[yy * w + xx]:
            edge[yy * w + xx] = true
  proc colourAt(i: int; over: Rgba): Rgba =
    let fg = Rgba(r: int(px.rgba[i * 4]), g: int(px.rgba[i * 4 + 1]),
      b: int(px.rgba[i * 4 + 2]), a: float(px.rgba[i * 4 + 3]) / 255.0)
    if fg.a >= 1.0: fg else: blendOver(fg, over)
  proc legibleOn(bg: Rgba): bool =
    var edgeN, visible = 0
    var sr, sg, sb = 0.0
    for i in 0 ..< w * h:
      if edge[i]:
        let c = colourAt(i, bg)
        inc edgeN
        if contrastRatio(c, bg) >= 3.0:
          inc visible
        sr += float(c.r); sg += float(c.g); sb += float(c.b)
    if edgeN == 0:
      return true
    if visible * 2 >= edgeN:
      return true
    # A plate: a uniform edge holding contrasting content.
    let mean = Rgba(r: int(sr / float(edgeN)), g: int(sg / float(edgeN)),
      b: int(sb / float(edgeN)), a: 1.0)
    var near = 0
    for i in 0 ..< w * h:
      if edge[i] and contrastRatio(colourAt(i, bg), mean) < 1.5:
        inc near
    if near * 10 < edgeN * 9:
      return false
    var inner, content = 0
    for i in 0 ..< w * h:
      if not transparent[i] and not edge[i]:
        inc inner
        if contrastRatio(colourAt(i, bg), mean) >= 3.0:
          inc content
    inner > 0 and content * 20 >= inner
  let white = Rgba(r: 255, g: 255, b: 255, a: 1.0)
  if not legibleOn(white):
    return (lvUnsafe, "white")
  if not legibleOn(nearBlack):
    return (lvUnsafe, "near-black")
  (lvSafe, "")

const logoVerdictMemoCap = 256
  ## How many images' verdicts `memoLogoVerdict` keeps per thread before
  ## it starts over (a sender with endless distinct logos stays bounded).

var logoVerdictMemo {.threadvar.}: Table[string, tuple[
  verdict: LogoVerdict; failsOn: string]]
  ## `logoVerdict` per image bytes, as computed on this thread.

proc memoLogoVerdict(bytes: string): tuple[verdict: LogoVerdict;
    failsOn: string] =
  ## `logoVerdict(bytes)`, decoded once per distinct image: the verdict
  ## is a function of the bytes alone, and a sender renders the same
  ## logo into every message.
  logoVerdictMemo.withValue(bytes, known):
    return known[]
  result = logoVerdict(bytes)
  if logoVerdictMemo.len >= logoVerdictMemoCap:
    logoVerdictMemo.clear()
  logoVerdictMemo[bytes] = result

proc lintDarkLogos*(root: EmailNode;
                    assets: openArray[AssetRef]): seq[EmailDiagnostic] =
  ## R-DRK-06 for the light image of every `dark_src` pair (P10, after
  ## P8 resolved the images): Gmail and the other families that never
  ## apply the dark block show it in dark mode too, so it must read on
  ## near-black as well as on white (`logoVerdict`).
  ## `W-DARK-LOGO-UNSAFE` names the background it fails on. An image
  ## whose bytes the render does not have (not resolved through the
  ## asset store, or not a PNG it reads) is not checked; one over
  ## `maxDecodePixels` is not decoded and reports
  ## `I-DARK-LOGO-UNCHECKED`.
  var stack = @[root]
  while stack.len > 0:
    let node = stack.pop()
    if node == nil:
      continue
    if node.kind == enElement and node.tag == "mailImage" and
        node.attrs.getOrDefault("dark_src", "").strip().len > 0:
      let src = node.attrs.getOrDefault("src", "")
      for a in assets:
        if a.url.len > 0 and a.url == src and a.bytes.len > 0:
          let (verdict, failsOn) = memoLogoVerdict(a.bytes)
          if verdict == lvTooLarge:
            result.add(EmailDiagnostic(severity: sevInfo,
              code: codeDarkLogoUnchecked,
              message: "the light image of this dark_src pair ('" &
                a.name & "') is too large to check for dark safety (over " &
                $maxDecodePixels & " pixels); not checked (R-DRK-06)",
              origin: node.origin, rules: @["R-DRK-06"]))
          if verdict == lvUnsafe:
            result.add(EmailDiagnostic(severity: sevWarning,
              code: codeDarkLogoUnsafe,
              message: "the light image of this dark_src pair ('" &
                a.name & "') is not legible on " & failsOn & ": where " &
                "no swap happens (" & formatFamilies(noSwapFamilies) &
                ") it shows in dark mode too; give it a 2px " &
                "contrasting outline or a plate (R-DRK-06)",
              origin: node.origin, families: noSwapFamilies,
              rules: @["R-DRK-06"]))
          break
    for i in countdown(node.children.high, 0):
      stack.add(node.children[i])

type DarkDecl* = tuple[node: EmailNode; prop, value: string]
  ## One dark-scheme declaration as P6 paints it: the element, `color`
  ## or `background-color`, and the dark value. (P5's `HeadDecl` filtered
  ## to the dark variant; lint sits below the styles pass, so it takes
  ## the plain tuple.)

proc darkValueOf(dark: openArray[DarkDecl]; node: EmailNode;
                 prop: string): string =
  ## The element's dark value for `prop` (last one wins), or "".
  for d in dark:
    if d.node == node and d.prop == prop:
      result = d.value

type SchemeBackground = tuple[value: string; darkened, document: bool]
  ## The dark-scheme background of a text element: its value, whether a
  ## dark rule paints it, and whether it is the document's own (no
  ## element on the way sets one).

proc schemeBackground(node: EmailNode;
                      dark: openArray[DarkDecl]): SchemeBackground =
  ## The background a text element sits on in the dark scheme: the
  ## nearest element (itself first) with a dark or inline
  ## `background-color`, the dark value winning; else the document's
  ## own `background_color`; else white. The document shell repeats
  ## that background on three carriers with no dark value of its own.
  var n = node
  while n != nil:
    if n.kind == enElement:
      let d = darkValueOf(dark, n, "background-color")
      if d != "":
        return (d, true, false)
      if "background-color" in n.styles:
        return (n.styles["background-color"], false, n.parent == nil)
      if n.parent == nil:
        for key in ["background_color", "background-color"]:
          if key in n.attrs:
            return (n.attrs[key], false, true)
        if "background_color" in n.styles:
          return (n.styles["background_color"], false, true)
    n = n.parent
  ("#ffffff", false, true)

proc darkContrastAdvice(bg: SchemeBackground): string =
  ## What the author can do about a failing dark pair whose background
  ## no dark rule paints.
  if bg.darkened:
    return ""
  let where =
    if bg.document: "the document background, a raw colour with no dark " &
      "value (give mailDocument a tok\"color.surface.…\" " &
      "background_color, or none: a designed document defaults to " &
      "color.surface.card)"
    else: "a background with no dark value"
  "; the text sits on " & where & ": put it in a container with a " &
    "dark background (a `dark:bg-…` class or `@dark:background-color`), " &
    "or give the text its own colour that reads on " & bg.value

proc lintDarkContrastImpl(node: EmailNode; dark: openArray[DarkDecl];
                          diags: var seq[EmailDiagnostic]) =
  if node == nil or (node.kind == enElement and node.tag == "textOnly"):
    return
  if node.kind == enElement and node.tag.toLowerAscii() in ["h1", "h2",
      "h3", "h4", "h5", "h6", "p", "li", "span", "a", "td", "th"] and
      "color" in node.styles and holdsVisibleText(node):
    var fgValue = darkValueOf(dark, node, "color")
    if fgValue == "":
      fgValue = node.styles["color"]
    let white = Rgba(r: 255, g: 255, b: 255, a: 1.0)
    var fg, bg: Rgba
    var parsed = true
    let under = schemeBackground(node, dark)
    try:
      fg = parseColor(fgValue)
      bg = parseColor(under.value)
    except ValueError:
      parsed = false
    if parsed:
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
        diags.add(EmailDiagnostic(
          severity: sevError, code: codeA11yContrastDark,
          message: "<" & node.tag & "> text/background contrast " &
            formatFloat(ratio, ffDecimal, 2) & ":1 in the dark scheme (" &
            fg.toHex() & " on " & bg.toHex() & ") is below " &
            (if large: "3" else: "4.5") & ":1 (R-DRK-04)" &
            darkContrastAdvice(under),
          origin: node.origin, rules: @["R-DRK-04"],
        ))
  for child in node.children:
    lintDarkContrastImpl(child, dark, diags)

proc lintDarkContrast*(root: EmailNode;
                       dark: openArray[DarkDecl]): seq[EmailDiagnostic] =
  ## R-DRK-04's dark scheme under `darkMode = designed`: every text
  ## element with a resolved `color` (P5 gives text elements one,
  ## R-TXT-02), painted with its dark value when the dark head rules
  ## give it one, over `schemeBackground`. Below 4.5:1 (3:1 for large
  ## text) is `E-A11Y-CONTRAST`. Call it only for designed renders whose
  ## dark block survived the head budget: otherwise no dark rule
  ## exists and the light check (R-A11Y-07) already covers the pairs.
  ## Unparseable colours are skipped, as in the light check.
  lintDarkContrastImpl(root, dark, result)

# ----------------------------------------------------------------------------
# Adjacent bands that merge in dark mode (layout-patterns.md §4.1, mailBand)
# ----------------------------------------------------------------------------

const bandStep* = 0.1
  ## The OKLCH lightness two adjacent bands must differ by to read as
  ## two (layout-patterns.md §4.1).

proc bandOf(node: EmailNode): EmailNode =
  ## The band a document child is: a section, wrapper or hero, or the
  ## band an expanded pattern became; nil for anything else.
  var n = node
  while n != nil and n.kind == enElement:
    if n.tag in ["mailSection", "mailWrapper", "mailHero"]:
      return n
    if not n.expanded:
      return nil
    var next: EmailNode = nil
    for c in n.children:
      if c.kind == enElement:
        next = c
        break
    n = next
  nil

proc lintBandsMerge*(root: EmailNode;
                     dark: seq[DarkDecl] = @[]): seq[EmailDiagnostic] =
  ## `W-DARK-BANDS-MERGE` (P10, layout-patterns.md §4.1): two adjacent
  ## bands of the document whose backgrounds differ by at least
  ## `bandStep` in OKLCH lightness in the light palette, and by less
  ## after R-DRK-04's partial inversion (light backgrounds darkened) or,
  ## when `dark` holds the designed dark scheme, in their dark colours.
  ## A band without a background shows the document's; a band with a
  ## background image is the image's, and is not compared.
  if root == nil or root.kind != enElement or root.tag != "mailDocument":
    return
  let white = Rgba(r: 255, g: 255, b: 255, a: 1.0)
  var docBg = white
  var docDark = ""
  try:
    let v = rawValue(root, "background-color")
    if v.len > 0 and not v.startsWith("tok:"):
      docBg = parseColor(v)
      if docBg.a < 1.0:
        docBg = blendOver(docBg, white)
  except ValueError:
    discard
  docDark = darkValueOf(dark, root, "background-color")
  type Band = tuple[node: EmailNode; light: Rgba; dark: string; ok: bool]
  proc colourOf(band: EmailNode): Band =
    if rawValue(band, "background-image").len > 0:
      return (band, docBg, "", false)
    let v = rawValue(band, "background-color")
    var c = docBg
    if v.len > 0 and not v.startsWith("tok:"):
      try:
        c = parseColor(v)
        if c.a < 1.0:
          c = blendOver(c, docBg)
      except ValueError:
        return (band, docBg, "", false)
    var d = darkValueOf(dark, band, "background-color")
    if d.len == 0 and v.len == 0:
      d = docDark
    (band, c, d, true)
  proc lightness(c: Rgba): float = rgbToOklch(c).l
  proc partial(c: Rgba): Rgba =
    if relativeLuminance(c) > inversionPivot: invertLightness(c) else: c
  var prev: Band
  var havePrev = false
  for child in root.children:
    if child.kind != enElement:
      continue
    let band = bandOf(child)
    if band == nil:
      havePrev = false
      continue
    let cur = colourOf(band)
    if havePrev and prev.ok and cur.ok:
      let dl = abs(lightness(prev.light) - lightness(cur.light))
      if dl >= bandStep:
        let a = partial(prev.light)
        let b = partial(cur.light)
        let di = abs(lightness(a) - lightness(b))
        if di < bandStep:
          result.add(EmailDiagnostic(severity: sevWarning,
            code: codeDarkBandsMerge,
            message: "adjacent bands " & prev.light.toHex() & " and " &
              cur.light.toHex() & " differ by " &
              formatFloat(dl, ffDecimal, 2) & " in OKLCH lightness, but " &
              "after partial inversion (" & formatFamilies(partialInverters) &
              ") they become " & a.toHex() & " and " & b.toHex() & ", " &
              formatFloat(di, ffDecimal, 2) & " apart, and read as one " &
              "band: move them at least " & $bandStep & " apart where both " &
              "stay light, or make one of them dark (layout-patterns.md " &
              "§4.1, R-DRK-04)",
            origin: band.origin, families: partialInverters,
            rules: @["R-DRK-04"]))
        elif prev.dark.len > 0 and cur.dark.len > 0:
          try:
            let da = parseColor(prev.dark)
            let db = parseColor(cur.dark)
            let dd = abs(lightness(da) - lightness(db))
            if dd < bandStep:
              result.add(EmailDiagnostic(severity: sevWarning,
                code: codeDarkBandsMerge,
                message: "adjacent bands " & prev.light.toHex() & " and " &
                  cur.light.toHex() & " differ by " &
                  formatFloat(dl, ffDecimal, 2) & " in OKLCH lightness, but " &
                  "their designed dark colours " & da.toHex() & " and " &
                  db.toHex() & " are " & formatFloat(dd, ffDecimal, 2) &
                  " apart and read as one band in the dark scheme: move " &
                  "them at least " & $bandStep & " apart " &
                  "(layout-patterns.md §4.1)",
                origin: band.origin, rules: @["R-DRK-02"]))
          except ValueError:
            discard
    prev = cur
    havePrev = true

proc lintAltLength(node: EmailNode): seq[EmailDiagnostic] =
  ## R-IMG-04's length half (P1 owns presence): alt longer than 60
  ## characters warns — usually text baked into the image.
  if node.kind != enElement or node.tag notin ["mailImage", "img"]:
    return @[]
  let alt = node.attrs.getOrDefault("alt", "")
  # Characters, not bytes: an Arabic alt is twice as many bytes.
  if alt.runeLen > 60:
    return @[EmailDiagnostic(
      severity: sevWarning, code: codeA11yAltLong,
      message: "<" & node.tag & "> alt is " & $alt.runeLen &
        " characters (R-IMG-04: alt longer than 60 characters warns)",
      origin: node.origin, rules: @["R-IMG-04"],
    )]
  @[]

proc imageFormat*(src: string): string =
  ## The format an image source names by its extension (`webp`, `svg`,
  ## `png`, …; a `data:` URI by its media type), "" when it names none.
  ## Query and fragment are ignored.
  var s = src.strip().toLowerAscii()
  if s.startsWith("data:image/"):
    let e = s.find({';', ','})
    let t = if e > 0: s["data:image/".len ..< e] else: s["data:image/".len .. ^1]
    return if t.startsWith("svg"): "svg" else: t
  for cut in ['?', '#']:
    let i = s.find(cut)
    if i >= 0:
      s = s[0 ..< i]
  let slash = s.rfind('/')
  let dot = s.rfind('.')
  if dot > slash and dot >= 0:
    return s[dot + 1 .. ^1]
  ""

proc lintImageFormat(node: EmailNode;
    profile: AudienceProfile): seq[EmailDiagnostic] =
  ## R-IMG-08, R-OL-13: WebP and SVG images are errors under a profile
  ## that gives Word-engine Outlook or Gmail (web, app, or with another
  ## provider's account) any weight: neither shows them.
  if node.kind != enElement or node.tag notin ["mailImage", "img"]:
    return @[]
  # A pair's dark copy (R-IMG-06) is an image like any other.
  var fmt = imageFormat(node.attrs.getOrDefault("src", ""))
  if fmt notin ["webp", "svg"]:
    fmt = imageFormat(node.attrs.getOrDefault("dark_src", ""))
  if fmt notin ["webp", "svg"]:
    return @[]
  var fams: set[ClientFamily] = {}
  var weight = 0.0
  for f in [cfOutlookWord, cfGmailWeb, cfGmailApp, cfGanga]:
    if profile.weights[f] > 0:
      fams.incl(f)
      weight += profile.weights[f]
  if fams == {}:
    return @[]
  @[EmailDiagnostic(severity: sevError, code: codeAssetFormat,
    message: "<" & node.tag & "> is " & fmt.toUpperAscii() & ", which " &
      "Word-engine Outlook and Gmail do not show (R-IMG-08); use PNG, " &
      "JPEG or GIF",
    origin: node.origin, families: fams, weight: weight,
    rules: @["R-IMG-08", "R-OL-13"])]

# ----------------------------------------------------------------------------
# Construction checks (R-TBL-01, R-TBL-06, R-TBL-15, R-OL-15)
# ----------------------------------------------------------------------------

proc hiddenTextDegradations(node: EmailNode): seq[ExpectedDegradation] =
  ## Visually hidden text (R-A11Y-09's styles: a stepper's status line):
  ## a client that drops `position` or `clip` keeps a 1px box with its
  ## overflow hidden. Declared, so they report as degradations.
  if node.kind != enElement or
      node.styles.getOrDefault("position", "") != "absolute" or
      "clip" notin node.styles:
    return
  for prop in ["position", "clip"]:
    result.add(expectDegradation(lkProperty, prop, allFamilies,
      "where it is dropped, the hidden line is a 1px box with its " &
      "overflow hidden (R-A11Y-09)"))

const msoClosedList* = ["mso-line-height-rule", "mso-table-lspace",
  "mso-table-rspace", "mso-padding-alt", "mso-hide", "mso-font-alt"]
  ## R-OL-15: the only `mso-*` properties the library may emit. A new
  ## one joins only with a Word-engine capture that shows its effect.

proc backgroundDegradations(node: EmailNode): seq[ExpectedDegradation] =
  ## A band's background image is lowered with its fallbacks
  ## (R-VML-01): Word gets VML or the fallback colour (R-OL-11), and a
  ## client that drops the image's size, position or repeat shows it
  ## at its own size or place, over the fallback colour that text is
  ## checked against. Declared, so they report as degradations.
  if node.kind != enElement or node.tag notin imageBandTags:
    return
  if not hasBackgroundImage(node):
    return
  result.add(expectDegradation(lkProperty, "background-image",
    {cfOutlookWord}, "Word gets the image as VML, or its fallback " &
    "colour (R-VML-01, R-OL-11)"))
  for prop in ["background-size", "background-position",
      "background-repeat"]:
    result.add(expectDegradation(lkProperty, prop, allFamilies,
      "the image shows at its own size or place over its fallback " &
      "colour, which the text is checked against (R-VML-01)"))

const nonCssProps = [("mailstack", "gap"), ("mailcluster", "gap"),
  ("mailcluster", "row-gap"), ("mailcluster", "row_gap"),
  ("mailsidebar", "gap"), ("mailbox", "shadow"), ("mailsocial", "gap"),
  ("mailnavbar", "gap")]
  ## Vocabulary props that arrive as style keywords but are lowered to
  ## other markup, never emitted as the CSS property of that name.

const specialLoweringTags* = ["mailStepper", "mailTimeline",
  "mailDividerLabel", "mailBadge"]
  ## Patterns whose expansion writes its own layout table (their special
  ## lowering, layout-patterns.md §4.4 and §4.5: the stepper, the
  ## timeline, the labelled divider and the badge's Word wrapper), which
  ## R-TBL-01 allows.

proc lintTables(node: EmailNode; ancestors: seq[EmailNode]):
    seq[EmailDiagnostic] =
  ## R-TBL-01 and R-TBL-06 over one authoring element.
  let isTable = eqLowerAscii(node.tag, "table")
  let hasRowspan = "rowspan" in node.attrs
  let hasColspan = "colspan" in node.attrs
  if not (isTable or hasRowspan or hasColspan):
    # Nothing below can fire.
    return
  let tag = node.tag.toLowerAscii()
  var inDataTable, inHead, inSpecial = false
  for a in ancestors:
    if a.kind != enElement:
      continue
    if eqLowerAscii(a.tag, "mailtable"): inDataTable = true
    elif eqLowerAscii(a.tag, "thead"): inHead = true
    if a.tag in specialLoweringTags and a.expanded:
      inSpecial = true
  if tag == "table" and not inDataTable and not inSpecial:
    result.add(EmailDiagnostic(severity: sevWarning,
      code: codeTblUnexpected,
      message: "a layout <table> outside the constructs that emit one: " &
        "use mailTable for data, or the layout primitives (R-TBL-01)",
      origin: node.origin, rules: @["R-TBL-01"]))
  if "rowspan" in node.attrs:
    result.add(EmailDiagnostic(severity: sevWarning, code: codeTblSpan,
      message: "<" & tag & "> has rowspan, which no layout uses " &
        "(R-TBL-06)", origin: node.origin, rules: @["R-TBL-06"]))
  if "colspan" in node.attrs and
      not (inDataTable and (inHead or tag == "th")):
    result.add(EmailDiagnostic(severity: sevWarning, code: codeTblSpan,
      message: "<" & tag & "> has colspan outside a data table's " &
        "header row (R-TBL-06)", origin: node.origin,
      rules: @["R-TBL-06"]))

# ----------------------------------------------------------------------------
# Rows whose items do not share a height (R-TBL-10) and tap-target
# spacing in clusters (R-TBL-12)
# ----------------------------------------------------------------------------

proc paintsBox(node: EmailNode): bool =
  ## True when `node` paints a box of its own: a background or a border
  ## (either spelling: P5 may or may not have run).
  if node.kind != enElement:
    return false
  for k, v in node.styles.pairs:
    let key = k.toLowerAscii().replace("_", "-")
    if (key == "background-color" or key.startsWith("border")) and
        not key.startsWith("border-radius") and
        v.strip().toLowerAscii() notin ["", "none", "0", "transparent"]:
      return true
  "bgcolor" in node.attrs or "background_color" in node.attrs

proc isRaggedRow(node: EmailNode): bool =
  ## A row whose items keep their own heights side by side: a `hybrid`
  ## or `fabFour` `mailColumns`, a section's own columns, a grid.
  if node.kind != enElement:
    return false
  case node.tag
  of "mailColumns":
    node.attrs.getOrDefault("strategy", "hybrid") in ["", "hybrid",
      "fabFour"]
  of "mailSection":
    var cols = 0
    for c in node.children:
      if c.kind == enElement and c.tag in ["mailColumn", "mailGroup"]:
        inc cols
    cols >= 2
  of "mailGrid":
    true
  else:
    false

proc lintRagged(node: EmailNode): seq[EmailDiagnostic] =
  ## R-TBL-10: equal heights are promised only by table cells. A bordered
  ## or background-carrying item in a hybrid row or a grid ends where its
  ## content does, so the design is flagged (information) to be chosen
  ## knowingly: once per row, naming how many items paint a box.
  if not isRaggedRow(node):
    return
  var boxedItems = 0
  var items = 0
  for c in node.children:
    if c.kind != enElement:
      continue
    inc items
    var target = c
    # A grid item boxed by a mailBox, or a column whose single child
    # is one, paints the item's box.
    if paintsBox(target) or (target.children.len == 1 and
        paintsBox(target.children[0])):
      inc boxedItems
  if boxedItems > 0 and items > 1:
    result.add(EmailDiagnostic(severity: sevInfo, code: codeTblRagged,
      message: $boxedItems & " of the " & $items & " items of this " &
        node.tag & " paint a background or a border, and the row does " &
        "not give its items one height: their bottoms will be ragged " &
        "where their content differs (a declared degradation). Use a " &
        "cells row, or a shared band background, for a shared bottom " &
        "edge (R-TBL-10)", origin: node.origin, rules: @["R-TBL-10"]))

const interactiveTags = ["a", "mailbutton", "mailnavlink", "mailsocialitem"]

proc holdsInteractive(node: EmailNode): bool =
  if node.kind == enElement and node.tag.inLowerAscii(interactiveTags):
    return true
  for c in node.children:
    if holdsInteractive(c):
      return true
  false

proc pxOf(value: string): float =
  try:
    toPx(value.strip())
  except StyleError, ValueError:
    -1.0

proc lintTapSpacing(node: EmailNode): seq[EmailDiagnostic] =
  ## R-TBL-12: interactive items of a cluster keep at least 8px between
  ## their hit areas, across a line (`gap`) and between wrapped lines
  ## (`row_gap`).
  if node.kind != enElement or node.tag != "mailCluster":
    return
  var interactive = 0
  for c in node.children:
    if holdsInteractive(c):
      inc interactive
  if interactive < 2:
    return
  var gap = node.styles.getOrDefault("gap",
    node.attrs.getOrDefault("gap", ""))
  if gap.len == 0 or gap.startsWith("tok:"):
    gap = "12px" # the default, space.3, resolves to 12px in every theme
  var rowGap = node.styles.getOrDefault("row-gap",
    node.styles.getOrDefault("row_gap", node.attrs.getOrDefault("row_gap",
      "")))
  if rowGap.len == 0 or rowGap.startsWith("tok:"):
    rowGap = gap
  for (what, value) in [("gap", gap), ("row_gap", rowGap)]:
    let px = pxOf(value)
    if px >= 0 and px < 8:
      result.add(EmailDiagnostic(severity: sevWarning,
        code: codeA11yTapTarget,
        message: "mailCluster " & what & " " & value & " leaves less " &
          "than 8px between the hit areas of its " & $interactive &
          " links or buttons: a thumb hits the neighbour (R-TBL-12)",
        origin: node.origin, rules: @["R-TBL-12"]))

proc lintButtonTap(node: EmailNode): seq[EmailDiagnostic] =
  ## R-BTN-06: a button is at least 44px tall: its line height, its
  ## vertical padding and its borders (read after the style pass, which
  ## gave it the theme's defaults).
  if node.kind != enElement or node.tag != "mailButton":
    return
  let st = node.styles
  if "height" notin st and "line-height" notin st and "padding" notin st and
      "padding-top" notin st and "padding-bottom" notin st:
    # Not styled yet: the style pass gives every button its padding and
    # line height, so a tree linted before it has nothing to measure.
    return
  var h = 0.0
  let height = st.getOrDefault("height", "")
  if height.len > 0 and pxOf(height) >= 0:
    h = pxOf(height)
  else:
    var lh = pxOf(st.getOrDefault("line-height", ""))
    if lh < 0:
      let fs = pxOf(st.getOrDefault("font-size", "16px"))
      lh = (if fs > 0: fs else: 16.0) * 1.2
    var sides = [0.0, 0.0, 0.0, 0.0]
    let pad = st.getOrDefault("padding", "")
    if pad.len > 0:
      try:
        let s = expandBox(pad)
        for i in 0 .. 3:
          sides[i] = toPx(s[i])
      except StyleError:
        discard
    for (i, k) in [(0, "padding-top"), (2, "padding-bottom")]:
      if k in st and pxOf(st[k]) >= 0:
        sides[i] = pxOf(st[k])
    var border = 0.0
    if st.getOrDefault("border-style", "none").toLowerAscii() notin
        ["", "none"]:
      border = max(0.0, pxOf(st.getOrDefault("border-width", "0")))
    h = lh + sides[0] + sides[2] + 2 * border
  if h < 44:
    result.add(EmailDiagnostic(severity: sevWarning,
      code: codeA11yTapTarget,
      message: "mailButton is " & formatPx(h) & " tall: a tap target " &
        "needs 44px (line height plus vertical padding and borders; " &
        "R-BTN-06)", origin: node.origin, rules: @["R-BTN-06"]))

proc msoNamesIn*(text: string): seq[string] =
  ## Every `mso-*` property name declared in a CSS or markup fragment
  ## (`mso-hide:all`, `mso-text-raise: 4px`), in order. A name counts
  ## only as a declaration (a `:` follows) and only at a word start, so
  ## class names such as `e-mso-group-fix` and conditions such as
  ## `[if mso]` are not property names.
  var i = text.find("mso-")
  while i >= 0:
    let atStart = i == 0 or text[i - 1] notin
      {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_'}
    var j = i + 4
    while j < text.len and text[j] in {'a' .. 'z', 'A' .. 'Z', '-'}:
      inc j
    var k = j
    while k < text.len and text[k] in {' ', '\t'}:
      inc k
    if atStart and k < text.len and text[k] == ':':
      result.add(text[i ..< j].toLowerAscii())
    i = text.find("mso-", j)

proc msoDiag(name: string; origin: SourceSpan): EmailDiagnostic =
  EmailDiagnostic(severity: sevWarning, code: codeCssMsoUnlisted,
    message: "'" & name & "' is not on the closed list of mso-* " &
      "properties (" & msoClosedList.join(", ") & "): its effect in " &
      "Word is unverified (R-OL-15)",
    origin: origin, families: {cfOutlookWord}, rules: @["R-OL-15"])

proc isMsoKey(k: string): bool =
  ## The property of style key `k` (its variant split off, as
  ## `splitVariantKey` does), lower-cased, starts with `mso-`.
  var at = 0
  if k.startsWith("@"):
    let sep = k.find(':')
    if sep > 0:
      at = sep + 1
  k.len - at >= 4 and toLowerAscii(k[at]) == 'm' and
    toLowerAscii(k[at + 1]) == 's' and toLowerAscii(k[at + 2]) == 'o' and
    k[at + 3] == '-'

proc lintMsoImpl(node: EmailNode; origin: SourceSpan;
    acc: var seq[EmailDiagnostic]) =
  if node == nil:
    return
  template walk(here: SourceSpan) =
    case node.kind
    of enElement, enVml:
      for k in node.styles.keys:
        if isMsoKey(k):
          let (_, base) = splitVariantKey(k)
          let name = base.toLowerAscii()
          if name notin msoClosedList:
            acc.add(msoDiag(name, here))
      if "style" in node.attrs:
        for name in msoNamesIn(node.attrs["style"]):
          if name notin msoClosedList:
            acc.add(msoDiag(name, here))
    of enRaw, enHeadStyle:
      for name in msoNamesIn(node.text):
        if name notin msoClosedList:
          acc.add(msoDiag(name, here))
    of enText, enMsoIf, enNotMso:
      discard
    for c in node.children:
      lintMsoImpl(c, here, acc)
  # The nearest origin, read in place.
  if node.origin.file.len > 0:
    walk(node.origin)
  else:
    walk(origin)

proc lintMsoProperties*(root: EmailNode): seq[EmailDiagnostic] =
  ## R-OL-15, lint side: every `mso-*` property anywhere in a tree (the
  ## styles tables, `style` attributes, raw MSO payloads and head
  ## blocks) must be on the closed list. Runs over the lowered document,
  ## so it sees what the library emits as well as what the author wrote.
  lintMsoImpl(root, SourceSpan(), result)

proc lintDepthImpl(node: EmailNode; depth: int; wrapperSeen: bool;
    acc: var seq[EmailDiagnostic]) =
  if node == nil or node.kind in {enMsoIf, enVml}:
    # What only Word sees is Word's to pay for (R-TBL-15).
    return
  var d = depth
  var seen = wrapperSeen
  if node.kind == enElement and node.tag.toLowerAscii() == "table" and
      node.attrs.getOrDefault("role", "") == "presentation":
    if not seen:
      # The document's wrapper table is the skeleton, not a construct.
      seen = true
    else:
      inc d
      if d == 4:
        acc.add(EmailDiagnostic(severity: sevWarning, code: codeTblDeep,
          message: "layout tables nest " & $d & " levels deep outside " &
            "Outlook conditionals; keep a construct within 3 and move " &
            "deeper structure into its ghost tables (R-TBL-15)",
          origin: node.origin, rules: @["R-TBL-15"]))
  for c in node.children:
    lintDepthImpl(c, d, seen, acc)

const sectioningElements* = ["nav", "main", "article", "section",
  "header", "footer", "aside", "details", "summary"]
  ## R-A11Y-10: never emitted (Gmail rewrites some to `<u>`, others
  ## strip them).

proc lintSectioningImpl(node: EmailNode; acc: var seq[EmailDiagnostic]) =
  if node == nil:
    return
  if node.kind == enElement and
      node.tag.toLowerAscii() in sectioningElements:
    acc.add(EmailDiagnostic(severity: sevError, code: codeA11ySectioning,
      message: "<" & node.tag.toLowerAscii() & "> in the emitted " &
        "document (R-A11Y-10: sectioning elements are never emitted; " &
        "landmarks are a role on a presentation table)",
      origin: node.origin, rules: @["R-A11Y-10"]))
  for c in node.children:
    lintSectioningImpl(c, acc)

proc lintSectioning*(root: EmailNode): seq[EmailDiagnostic] =
  ## R-A11Y-10 over a lowered document: a sectioning element anywhere
  ## in what is emitted, Outlook conditionals included, is an error,
  ## whoever produced it (the template check stops authors; this one
  ## stops a lowering or an expansion).
  lintSectioningImpl(root, result)

proc lintTableDepth*(root: EmailNode): seq[EmailDiagnostic] =
  ## R-TBL-15 over a lowered document: more than three levels of
  ## layout tables (`role="presentation"`) outside Outlook conditionals,
  ## below the document's wrapper table, warn once per too-deep chain.
  lintDepthImpl(root, 0, false, result)

proc stampOrigin(node: EmailNode; origin: SourceSpan) =
  ## A raw payload's tree has no template locations of its own: every
  ## finding in it points at the `mailRaw` that holds it.
  if node == nil:
    return
  if node.origin.file.len == 0:
    node.origin = origin
  for c in node.children:
    stampOrigin(c, origin)

proc holdsDirectText(node: EmailNode): bool =
  ## True when a text child holds something a reader sees: not only
  ## white space (a no-break space included) or zero-width characters,
  ## which spacers and accents carry to keep a box from collapsing.
  for c in node.children:
    if c.kind != enText:
      continue
    for ch in c.text.runes:
      if not ch.isWhiteSpace() and ch.int notin [0x200B, 0x200C, 0x200D,
          0xFEFF, 0x034F]:
        return true
  false

proc isFooterLegal*(node: EmailNode): bool =
  ## True when `node` is the legal text of an expanded `mailFooter` (the
  ## last line of the footer's stack, or of the stack the footer's links
  ## row sits in, which closes the footer's; written from its `legal`
  ## prop): that line only, never the author's content in the footer.
  proc lastElement(x: EmailNode): EmailNode =
    for c in x.children:
      if c.kind == enElement:
        result = c
  var item = node
  var stack = node.parent
  var depth = 0
  while true:
    if stack == nil or stack.kind != enElement or stack.tag != "mailStack" or
        lastElement(stack) != item:
      return false
    let up = stack.parent
    if up != nil and up.kind == enElement and up.tag == "mailFooter":
      break
    inc depth
    if depth > 1:
      return false
    item = stack
    stack = up
  let footer = stack.parent
  if not footer.expanded:
    return false
  rawValue(footer, "legal").strip().len > 0

proc lintFontSize(node: EmailNode; ancestors: seq[EmailNode]):
    seq[EmailDiagnostic] =
  ## R-TXT-03: text a reader sees is at least 14px (a warning below,
  ## an error below 12px), at the size it renders with: the element's
  ## own font size, else the nearest ancestor's (16px, the default
  ## body, when none sets one). Text hidden from readers is skipped.
  if node.kind != enElement or not holdsDirectText(node):
    return
  if node.attrs.getOrDefault("aria-hidden", "") == "true":
    return
  for a in ancestors:
    if a.kind == enElement and a.attrs.getOrDefault("aria-hidden", "") ==
        "true":
      return
  var size = node.styles.getOrDefault("font-size", "")
  var i = ancestors.high
  while size.len == 0 and i >= 0:
    if ancestors[i].kind == enElement:
      size = ancestors[i].styles.getOrDefault("font-size", "")
    dec i
  if size.len == 0 or size.startsWith("tok:"):
    return
  let px = fontSizePx(size)
  if px <= 0:
    return
  if px >= 12 and px < 14 and isFooterLegal(node):
    # R-TXT-03 allows 12px in one place: a footer's legal text.
    return
  if px < 12:
    result.add(EmailDiagnostic(severity: sevError, code: codeA11yFontTiny,
      message: "<" & node.tag & "> text is " & formatPx(px) & ": text " &
        "below 12px is unreadable on a phone (R-TXT-03)",
      origin: node.origin, rules: @["R-TXT-03"]))
  elif px < 14:
    result.add(EmailDiagnostic(severity: sevWarning,
      code: codeA11yFontSmall,
      message: "<" & node.tag & "> text is " & formatPx(px) & ": body " &
        "text is at least 14px (R-TXT-03)",
      origin: node.origin, rules: @["R-TXT-03"]))

const nonCssTags = ["mailstack", "mailcluster", "mailsidebar", "mailbox",
  "mailsocial", "mailnavbar"]
  ## The tags of `nonCssProps`.

proc isNonCssProp(tag, prop: string): bool =
  ## `(tag, prop)`, lower-cased, is in `nonCssProps`.
  for (t, p) in nonCssProps:
    if eqLowerAscii(tag, t) and eqLowerAscii(prop, p):
      return true
  false

proc lintTreeImpl(node: EmailNode; profile: AudienceProfile;
                  expected: openArray[ExpectedDegradation];
                  ancestors: var seq[EmailNode];
                  acc: var seq[EmailDiagnostic]) =
  ## `lintTree` with the ancestor chain (for contrast backgrounds), kept
  ## as one stack the walk pushes and pops, and the findings written to
  ## `acc` in tree order.
  if node == nil:
    return
  if node.kind == enElement and node.tag == "textOnly":
    # Never written to the HTML: nothing in it is drawn.
    return
  case node.kind
  of enElement:
    let es = elementSlug(node.tag)
    if es.len > 0:
      acc.add(checkFeature(es, "<" & node.tag.toLowerAscii() & ">",
        lkElement, node.tag, profile, expected, node.origin))
    for attr in node.attrs.keys:
      let aus = attributeSlug(attr)
      if aus.len > 0:
        acc.add(checkFeature(aus, attr.toLowerAscii() & " attribute",
          lkAttribute, attr, profile, expected, node.origin))
    template lintOwnStyles(exp: openArray[ExpectedDegradation]) =
      if not node.expanded:
        # Every style of an expanded pattern is skipped (its expansion
        # is what is emitted, and is linted), and so is a prop lowered
        # to other markup.
        let mayLower = node.tag.inLowerAscii(nonCssTags)
        # Keys read in place, each value looked up (not a copy of either).
        for prop in node.styles.keys:
          if not (mayLower and isNonCssProp(node.tag, prop)):
            lintDecl(node.tag, prop, node.styles[prop], profile, exp,
              node.origin, acc)
    let own = backgroundDegradations(node) & hiddenTextDegradations(node)
    if own.len > 0:
      lintOwnStyles(@expected & own)
    else:
      lintOwnStyles(expected)
    acc.add(lintTables(node, ancestors))
    acc.add(lintLinkText(node))
    acc.add(lintContrast(node, ancestors))
    acc.add(lintAltLength(node))
    acc.add(lintImageFormat(node, profile))
    acc.add(lintRagged(node))
    acc.add(lintTapSpacing(node))
    acc.add(lintButtonTap(node))
    acc.add(lintFontSize(node, ancestors))
  of enHeadStyle:
    acc.add(lintHeadCss(node.text, profile, expected, node.origin))
  of enRaw:
    var inRaw = false
    var origin = node.origin
    for i in countdown(ancestors.high, 0):
      let a = ancestors[i]
      if origin.file.len == 0 and a.origin.file.len > 0:
        origin = a.origin
      if a.kind == enElement and a.tag == "mailRaw":
        inRaw = true
    if inRaw:
      let read = readRaw(node.text)
      if not read.refused:
        ancestors.add(node)
        for n in read.nodes:
          stampOrigin(n, origin)
          lintTreeImpl(n, profile, expected, ancestors, acc)
        ancestors.setLen(ancestors.len - 1)
  of enText, enMsoIf, enNotMso, enVml:
    discard
  if node.children.len > 0:
    ancestors.add(node)
    for child in node.children:
      lintTreeImpl(child, profile, expected, ancestors, acc)
    ancestors.setLen(ancestors.len - 1)

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
  var ancestors: seq[EmailNode] = @[]
  lintTreeImpl(node, profile, expected, ancestors, result)
