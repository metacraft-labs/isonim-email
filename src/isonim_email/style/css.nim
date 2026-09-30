## isonim_email/style/css.nim — the validating CSS serialiser.
##
## Head CSS is progressive enhancement: Gmail drops a whole `<style>`
## block on one syntax error, an uppercase `!IMPORTANT`, or a nested
## at-rule, so every block goes through this serialiser and a block
## that fails validation is an error (`E-CSS-INVALID`), never a
## warning:
##
## - `!important` is always written in lower case (R-CSS-03);
##   declaration values carrying a raw `!` marker are rejected, so the
##   flag is the only source and uppercase can never reach output;
## - at-rules never nest: `@media` holds style rules only, `@font-face`
##   sits at the top level (R-CSS-04);
## - only syntactically valid CSS is emitted: balanced braces by
##   construction, no empty declarations, every property name in the
##   known-property table, no brace- or semicolon-bearing values
##   (R-CSS-05);
## - selectors are class, element or ID selectors, apart from the
##   fixed client-targeting set (R-CSS-09);
## - declarations sort by property name, rules by selector, both
##   deterministically (R-CSS-16). The declaration sort is stable, so
##   R-CSS-14's blend-then-`rgba()` declaration pairs keep their
##   order.
##
## Media-query contents are enforced here (`checkQuery`, R-CSS-10);
## block *membership* (R-CSS-02) and budget enforcement (R-CSS-07)
## stay P6's (`passes/head.nim`).
##
## P6's generated-class spellings `.<safe>:hover` (decorative) and
## `[owa] .<safe>` (responsive OWA copy) stay P6-only extensions in
## `passes/head.nim` — R-CSS-09 admits neither here, and that split
## is final.
##
## Pure `std` string work: identical on the C and JS targets.

import std/[algorithm, strutils]
import ./units

export units

type
  Declaration* = object
    ## One `prop: value` pair; `important` renders as lower-case
    ## `!important` (R-CSS-03).
    prop*: string
    value*: string
    important*: bool

  RuleKind* = enum
    rkStyle, rkMedia, rkFontFace

  Rule* = object
    ## A head-CSS rule. `rkMedia.rules` may hold style rules only and
    ## `rkFontFace` may sit at the top level only — anything else is
    ## `E-CSS-INVALID` (R-CSS-04).
    case kind*: RuleKind
    of rkStyle:
      selector*: string
      decls*: seq[Declaration]
    of rkMedia:
      query*: string
      rules*: seq[Rule]
    of rkFontFace:
      faceDecls*: seq[Declaration]

proc invalidCss*(what: string): ref StyleError =
  ## Builds the `E-CSS-INVALID` failure (R-CSS-05).
  newException(StyleError, "E-CSS-INVALID: " & what)

const knownCssProperties* = [
  "background-color", "background-image", "background-position",
  "background-repeat", "background-size", "border", "border-bottom",
  "border-bottom-color", "border-bottom-style", "border-bottom-width",
  "border-collapse", "border-color", "border-left", "border-left-color",
  "border-left-style", "border-left-width", "border-radius",
  "border-bottom-left-radius", "border-bottom-right-radius",
  "border-top-left-radius", "border-top-right-radius", "border-right",
  "border-right-color", "border-right-style", "border-right-width",
  "border-spacing", "border-style", "border-top", "border-top-color",
  "border-top-style", "border-top-width", "border-width", "box-sizing",
  "caption-side", "clear", "color", "cursor", "direction", "display",
  "empty-cells", "float", "font-family", "font-size", "font-style",
  "font-weight", "height", "max-height", "max-width", "min-height",
  "min-width", "letter-spacing", "line-height", "list-style",
  "list-style-image", "list-style-position", "list-style-type",
  "margin", "margin-bottom", "margin-left", "margin-right", "margin-top",
  "mso-font-alt", "mso-generic-font-family", "mso-hide",
  "mso-line-height-rule", "mso-padding-alt", "mso-table-lspace",
  "mso-table-rspace", "opacity", "overflow", "overflow-wrap", "padding",
  "padding-bottom", "padding-left", "padding-right", "padding-top",
  "src", "font-display", "unicode-range", "table-layout", "text-align",
  "text-decoration", "text-size-adjust", "text-transform",
  "unicode-bidi", "vertical-align", "visibility", "white-space",
  "width", "word-break", "word-spacing", "word-wrap",
  "-ms-text-size-adjust", "-webkit-text-size-adjust",
  "-ms-interpolation-mode", # R-RST-07 (MJML img reset, catalogue §2 line 7)
  "outline",                # R-RST-07 (MJML img reset, catalogue §2 line 7)
]
  ## Every property the serialiser emits (R-CSS-05). Shorthands P5
  ## expands (`background`, `font`) are absent by design, as are
  ## unverified `mso-*` properties: each is admitted only with
  ## backend-C evidence, in the change that needs it.

proc knownProperty*(prop: string): bool =
  ## Whether `prop` (case-insensitive) is in the known-property table.
  prop.toLowerAscii() in knownCssProperties

const clientTargetingSelectors* = [
  "div[style*=\"margin: 16px 0\"]",
  "#outlook a",
  "a[x-apple-data-detectors]",
  ".unstyle-auto-detected-links a",
  "img.g-img+div",
  ".aBn", # R-RST-09 (Gmail auto-detected-link class; the uppercase B
          # needs the literal — R-CSS-08 keeps validClassName lowercase)
  ".a6S", # R-RST-11 (Gmail download-button class; same uppercase reason)
]
  ## The fixed literal client-targeting set (R-CSS-09): R-RST-03, -09,
  ## -11 verbatim, plus R-RST-08's `#outlook a` and the R-RST-09/11
  ## uppercase classes. (`#outlook a` is not in R-CSS-09's
  ## parenthetical, but R-RST-08 normatively emits it in block 1, so
  ## the serialiser must accept it.) Together with the `*`, element,
  ## `.class`, `#id` and group arms of `validSelectorPart`, this is
  ## exactly the catalogue §2 reset selector set — nothing admits `u+.body`,
  ## which no catalogue rule covers. R-DRK-03 and R-LAY-12 are
  ## patterns over generated class names, matched in
  ## `validSelectorPart`, not listed here.

proc isNameChar(c: char): bool =
  c in {'a' .. 'z', '0' .. '9', '-', '_'}

proc validClassName*(name: string): bool =
  ## `[a-z][a-z0-9-]*` (R-CSS-08's shape, without the `e-` prefix the
  ## generator adds; fixed hook classes like `im` match too).
  if name.len == 0 or name[0] notin {'a' .. 'z'}:
    return false
  for c in name[1 .. ^1]:
    if c notin {'a' .. 'z', '0' .. '9', '-'}:
      return false
  true

proc validElementName(name: string): bool =
  if name.len == 0 or name[0] notin {'a' .. 'z'}:
    return false
  for c in name[1 .. ^1]:
    if not isNameChar(c):
      return false
  true

proc validIdName(name: string): bool =
  if name.len == 0 or name[0] notin {'A' .. 'Z', 'a' .. 'z', '_'}:
    return false
  for c in name[1 .. ^1]:
    if not isNameChar(c) and c notin {'A' .. 'Z'}:
      return false
  true

proc validSelectorPart*(part: string): bool =
  ## One comma-separated selector: `*`, an element, `.class`, `#id`, a
  ## fixed client-targeting literal, an R-DRK-03 `[data-ogsc]` /
  ## `[data-ogsb]` pattern, or an R-LAY-12 `.moz-text-html` copy
  ## (R-CSS-09).
  let s = part.strip()
  if s == "*":
    return true
  if s in clientTargetingSelectors:
    return true
  if s.startsWith("[data-ogsc] .") or s.startsWith("[data-ogsb] ."):
    return validClassName(s[13 .. ^1])
  if s.startsWith(".moz-text-html "):
    return validSelectorPart(s[14 .. ^1])
  if s.startsWith("."):
    return validClassName(s[1 .. ^1])
  if s.startsWith("#"):
    return validIdName(s[1 .. ^1])
  validElementName(s)

proc validSelector*(selector: string): bool =
  ## A selector group: every comma-separated part must be valid
  ## (R-CSS-09). Empty groups are invalid.
  let s = selector.strip()
  if s == "":
    return false
  for part in s.split(","):
    if not validSelectorPart(part):
      return false
  true

proc checkDeclaration*(d: Declaration) =
  ## Rejects unknown properties, empty values, and values that would
  ## break the block: braces, semicolons, or a raw `!` marker
  ## (R-CSS-03/05).
  if not knownProperty(d.prop):
    raise invalidCss("unknown property '" & d.prop &
      "' (R-CSS-05: every property name is in the known-property table)")
  let v = d.value.strip()
  if v == "":
    raise invalidCss("empty value for property '" & d.prop &
      "' (R-CSS-05: no empty declarations)")
  for c in v:
    if c in {'{', '}', ';'}:
      raise invalidCss("value '" & d.value & "' for property '" & d.prop &
        "' contains '" & $c & "' (R-CSS-05: balanced braces)")
    if c == '!':
      raise invalidCss("value '" & d.value & "' for property '" & d.prop &
        "' carries a raw '!' marker; importance comes only from the " &
        "declaration flag, which serialises lower-case (R-CSS-03)")

proc serializeDecls*(decls: openArray[Declaration]): string =
  ## `prop:value` pairs joined by `;`, sorted by property name with a
  ## stable tiebreak (R-CSS-16), `!important` lower-case (R-CSS-03).
  ## Property names canonicalise to lowercase.
  var indexed: seq[tuple[prop, value: string; important: bool; idx: int]] = @[]
  for i, d in decls:
    checkDeclaration(d)
    indexed.add((d.prop.toLowerAscii(), d.value.strip(), d.important, i))
  indexed.sort(proc(x, y: tuple[prop, value: string; important: bool;
      idx: int]): int =
    let c = cmp(x.prop, y.prop)
    if c != 0: c else: cmp(x.idx, y.idx))
  var parts: seq[string] = @[]
  for (prop, value, important, _) in indexed:
    parts.add(prop & ":" & value &
      (if important: " !important" else: ""))
  parts.join(";")

const allowedQueryFeatures = ["min-width", "max-width",
  "prefers-color-scheme"]

proc checkQueryAlternative(orig, alt: string) =
  ## One comma-separated alternative: `screen`-type words outside
  ## parens, allowed features only inside (R-CSS-10).
  var depth = 0
  var parenStart = 0
  var word = ""
  var sawWord = false
  var sawFeature = false
  proc flushWord() =
    if word.len == 0:
      return
    if word.toLowerAscii() notin ["only", "and", "screen"]:
      raise invalidCss("@media query '" & orig & "' names '" & word &
        "' (R-CSS-10: only the screen type)")
    sawWord = true
    word = ""
  for i, c in alt:
    if c == '(':
      flushWord()
      if depth == 0:
        parenStart = i
      inc depth
    elif c == ')':
      if depth == 0:
        raise invalidCss("@media query '" & orig &
          "' has unbalanced parens (R-CSS-10)")
      dec depth
      if depth == 0:
        let feat = alt[parenStart + 1 ..< i].split(':')[0].strip()
          .toLowerAscii()
        if feat notin allowedQueryFeatures:
          raise invalidCss("@media query '" & orig & "' uses feature '" &
            feat & "' (R-CSS-10: min-width/max-width/" &
            "prefers-color-scheme only)")
        sawFeature = true
    elif depth == 0:
      if c.isAlphaAscii():
        word.add(c)
      elif c.isSpaceAscii():
        flushWord()
      else:
        raise invalidCss("@media query '" & orig & "' contains '" & $c &
          "' outside a feature (R-CSS-10: only the screen type)")
  flushWord()
  if depth > 0:
    raise invalidCss("@media query '" & orig &
      "' has unbalanced parens (R-CSS-10)")
  if not sawWord and not sawFeature:
    raise invalidCss("@media query '" & orig &
      "' has an empty alternative (R-CSS-10)")

proc checkQuery*(query: string) =
  ## The query shape (non-empty, brace-free, R-CSS-05) plus the
  ## R-CSS-10 vocabulary: only the `screen` type (or `only screen`)
  ## and the features `min-width`/`max-width`/`prefers-color-scheme`.
  ## Height, orientation and resolution features — and any other
  ## media type — are `E-CSS-INVALID`. P6 emits conforming queries
  ## by construction; this is the enforcing choke point.
  let q = query.strip()
  if q == "":
    raise invalidCss("empty @media query (R-CSS-05)")
  for c in q:
    if c in {'{', '}', '@'}:
      raise invalidCss("@media query '" & query & "' contains '" & $c &
        "' (R-CSS-05: no nested at-rules)")
  for alt in q.split(','):
    checkQueryAlternative(query, alt)

proc serializeStyleRule*(selector: string;
    decls: openArray[Declaration]): string =
  if not validSelector(selector):
    raise invalidCss("selector '" & selector &
      "' is not a class, element or ID selector from the fixed " &
      "client-targeting set (R-CSS-09)")
  if decls.len == 0:
    raise invalidCss("selector '" & selector &
      "' has no declarations (R-CSS-05: no empty declarations)")
  selector.strip() & "{" & serializeDecls(decls) & "}"

proc serializeMediaRule*(query: string; rules: openArray[Rule]): string =
  checkQuery(query)
  if rules.len == 0:
    raise invalidCss("@media '" & query &
      "' has no rules (R-CSS-05: no empty declarations)")
  var parts: seq[string] = @[]
  for r in rules:
    if r.kind != rkStyle:
      raise invalidCss("an at-rule inside @media '" & query &
        "' (R-CSS-04: no nested at-rules; @font-face and @media never nest)")
    parts.add(serializeStyleRule(r.selector, r.decls))
  parts.sort()
  "@media " & query.strip() & "{" & parts.join("") & "}"

proc serializeFontFaceRule*(decls: openArray[Declaration]): string =
  if decls.len == 0:
    raise invalidCss("@font-face has no declarations (R-CSS-05)")
  "@font-face{" & serializeDecls(decls) & "}"

proc ruleSortKey*(r: Rule): tuple[rank: int; key: string] =
  ## Deterministic block order (R-CSS-16): style rules by selector,
  ## then `@media` by query, then `@font-face` by body.
  case r.kind
  of rkStyle:
    (0, r.selector.strip())
  of rkMedia:
    (1, r.query.strip())
  of rkFontFace:
    (2, serializeDecls(r.faceDecls))

proc serializeBlock*(rules: openArray[Rule]): string =
  ## One `<style>` element's content: every rule validated and the
  ## block deterministically ordered (R-CSS-16). `@font-face` nested
  ## anywhere but the top level is rejected (R-CSS-04) — the AST can
  ## only nest it inside `@media`, which `serializeMediaRule` refuses.
  var indexed: seq[tuple[rank: int; key: string; idx: int]] = @[]
  for i, r in rules:
    let (rank, key) = r.ruleSortKey()
    indexed.add((rank, key, i))
  indexed.sort(proc(x, y: tuple[rank: int; key: string;
      idx: int]): int =
    let c = cmp(x.rank, y.rank)
    if c != 0:
      return c
    let k = cmp(x.key, y.key)
    if k != 0: k else: cmp(x.idx, y.idx))
  var parts: seq[string] = @[]
  for (rank, _, i) in indexed:
    case rank
    of 0:
      parts.add(serializeStyleRule(rules[i].selector, rules[i].decls))
    of 1:
      parts.add(serializeMediaRule(rules[i].query, rules[i].rules))
    else:
      parts.add(serializeFontFaceRule(rules[i].faceDecls))
  parts.join("")
