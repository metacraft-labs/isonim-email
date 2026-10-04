## isonim_email/passes/styles.nim — P5: the inline style pass.
##
## Resolves every declaration to its final inline form: `tok"…"` sentinels
## (stored by the `setStyle` overload) become light literals (R-CSS-01) —
## except under the `@dark:` variant, where they become the token's dark
## literal (`darkFor`), the value the dark head rules exist to carry.
## Under `darkMode = designed` a colour resolved from a token whose dark
## value differs gets that `@dark:` twin itself (R-DRK-02, token-driven;
## an element's own `@dark:` declaration wins), a designed document
## without a background is painted with `color.surface.card`, and a
## shadowed box's derived border gets its dark colour (R-TBL-09) —
## variant keys (`@sm:`/`@dark:`/`@hover:`) move into the head
## list P6 serialises, units/colours/shorthands normalise through
## `style/*`, the closed MSO list applies when `outlookWord`, and
## `width`/`height`/`bgcolor`/`align` mirror between attributes and CSS.
##
## Pass discipline: children are never reordered (the walk only
## touches `styles`/`attrs`, never the `children` seq); unsupported
## properties are kept verbatim for P10, and only three things are ever
## removed — harmful `display:flex`/`grid` (with lint's R-OL-10
## diagnostic: `E-CSS-HARMFUL` on a layout container while Word-engine
## Outlook has weight, the removal warning otherwise), `var()`/`--x`
## (with `E-VOCAB-BAD-VALUE`: R-CSS-11's "never emitted" overrides never-drop, since a custom
## property is unresolvable in email, not merely unsupported), and margins
## that moved to cell padding (with `W-LAYOUT-MARGIN-CONVERTED`). Every
## other failure keeps the raw declaration beside its error diagnostic.
##
## A translucent colour on an HTML element inlines as R-CSS-14's pair:
## with `outlookWord`, the opaque blend against the resolved background
## first, then `rgba()`; the blend rides as the declaration's fallback
## (`EmailNode.fallbacks`, R-CSS-19), which only the serialiser writes.
## Without `outlookWord` it is `rgba()` alone. A vocabulary element's
## translucent colour, and a head declaration's, stay the blend alone
## (their lowering, or Word, needs one opaque colour), and `HeadDecl`
## carries one declaration each (P6 re-pairs where head CSS needs pairs).
##
## An `md:` class arrives as a plain unprefixed inline style — the
## extractor only tags the `--variants` list (Justfile), so an untagged
## `md:` class is indistinguishable from its unprefixed twin by the time
## P5 sees the tree (probed with a scratch template: the md padding class
## yielded flat `padding:24px`, overwritten by the base padding class).
## The Justfile therefore lists `md` too, the variant-preserving Tailwind
## expansion surfaces `@md:` keys, and
## this pass errors on them.

import std/[strutils, tables]
import ../diagnostics
import ../renderer
import ../style/tokens
import ../style/units
import ../style/colors
import ../style/shorthand
import ./lint
import ../style/ascii
import ../style/memo
import ../target
import ../lower/text
import ../lower/button_style
import ../lower/table_style

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  HeadDecl* = object
    ## One variant declaration split out of inline for P6 (`passes/head.nim`
    ## owns serialisation, budgets and validation — this pass only
    ## partitions): the variant, the normalised base declaration, the
    ## element the generated class attaches to, and its origin.
    variant*: string
    prop*: string
    value*: string
    node*: EmailNode
    origin*: SourceSpan
    light*: string
      ## A `dark` declaration's light twin: the element's resolved inline
      ## value of the same property ("" when it has none). Thunderbird's
      ## copy of a dark rule carries both (`light-dark()`, R-DRK-08).

const
  headVariants = ["sm", "dark", "hover"]
    ## The only variants email knows. `md` is tagged by the Tailwind expansion
    ## solely so P5 can reject it; anything else is a config error.

  boxAttrCarriers = ["table", "td", "th", "img"]
    ## Elements whose `width`/`height` attributes mirror CSS.

  bgAttrCarriers = ["body", "table", "tr", "td", "th"]
    ## Elements whose `bgcolor` mirrors `background-color`.

  textColorCarriers = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li",
    "blockquote", "pre"]
    ## Text elements that always carry an inline `color` (R-TXT-02);
    ## `td`/`th`/`div` carry one when they hold text directly.

  linkColorToken = "color.link"
    ## The colour of a link in body text (R-TXT-04).

  defaultTextColorToken = "color.text.primary"
    ## The theme token a text element without a colour of its own gets.

  valignCarriers = ["td", "th", "tr"]
    ## Elements whose `valign` mirrors `vertical-align` (R-OL-09).

  alignCarriers = ["td", "th", "tr", "div", "p", "h1", "h2", "h3", "h4",
    "h5", "h6"]
    ## Elements whose `align` mirrors `text-align`. `table` is excluded:
    ## `align` on a table centers the box, not the text — P4 owns that.

proc splitTokenKey(value: string): string =
  ## The theme key when `value` is a `tok"…"` sentinel, else "".
  if value.startsWith("tok:"):
    value[4 .. ^1]
  else:
    ""

proc containsVarRef(value: string): bool =
  ## Case-insensitive `var(` scan that skips spaces and tabs anywhere
  ## (so `VAR (` and `v a r(` count): the value with its spaces and tabs
  ## removed, lower-cased, contains `var(`. One pass, no copies.
  const pattern = "var("
  var matched = 0
  for c in value:
    if c == ' ' or c == '\t':
      continue
    let lc = toLowerAscii(c)
    if lc == pattern[matched]:
      inc matched
      if matched == pattern.len:
        return true
    elif lc == pattern[0]:
      # `var(` has no proper prefix that is also a suffix, so a mismatch
      # restarts the match at this character.
      matched = 1
    else:
      matched = 0
  false

proc isColorProp(prop: string): bool =
  prop == "color" or prop.endsWith("-color")

proc isLengthProp(prop: string): bool =
  ## The box/font set normalised to px (`%` survives on widths via
  ## `normaliseLength`); every other property keeps its value verbatim.
  case prop
  of "margin-top", "margin-right", "margin-bottom",
      "margin-left", "padding-top", "padding-right", "padding-bottom",
      "padding-left", "width", "min-width", "max-width", "height",
      "min-height", "max-height", "font-size", "border-width",
      "border-top-width", "border-right-width", "border-bottom-width",
      "border-left-width", "letter-spacing", "text-indent", "border-spacing",
      "border-radius", "border-top-left-radius", "border-top-right-radius",
      "border-bottom-right-radius", "border-bottom-left-radius": true
  else: false

const genericFamilies* = ["serif", "sans-serif", "monospace", "cursive",
  "fantasy", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace",
  "math", "emoji", "fangsong"]
  ## The CSS generic families a stack may end in (R-TXT-05).

proc familiesOf*(stack: string): seq[string] =
  ## The families of a `font-family` value, unquoted, in order.
  for part in stack.split(','):
    var f = part.strip()
    if f.len >= 2 and f[0] in {'"', '\''} and f[^1] == f[0]:
      f = f[1 ..< ^1]
    if f.len > 0:
      result.add(f)

proc computeEndsGeneric(stack: string): bool =
  ## `endsGeneric`, read every time.
  let fams = familiesOf(stack)
  if fams.len == 0:
    return true
  if fams.len == 1 and fams[0].toLowerAscii() in ["inherit", "initial",
      "unset", "revert"]:
    return true
  fams[^1].toLowerAscii() in genericFamilies

var endsGenericMemo {.threadvar.}: Table[string, bool]
  ## `endsGeneric` per stack, as read once on this thread (`memo.nim`):
  ## a document repeats its few stacks on every text element.

proc endsGeneric*(stack: string): bool =
  ## True when a `font-family` value ends in a generic family
  ## (R-TXT-05); a CSS-wide keyword (`inherit`, …) has no stack.
  memoised(endsGenericMemo, 1024, stack, computeEndsGeneric(stack))

proc isWebFamily*(family: string; target: EmailTarget): bool =
  for f in target.webFonts:
    if f.family.toLowerAscii() == family.toLowerAscii():
      return true
  false

proc msoFontAlt*(stack: string; target: EmailTarget): string =
  ## R-OL-07: for a stack whose first family is a web font, the family
  ## Word should use instead: the first that is neither a web font nor
  ## generic, else Arial. "" when the first family is not a web font.
  let fams = familiesOf(stack)
  if fams.len == 0 or not isWebFamily(fams[0], target):
    return ""
  for f in fams:
    if not isWebFamily(f, target) and f.toLowerAscii() notin genericFamilies:
      return f
  "Arial"

proc cssSizeToAttr(css: string): string =
  ## `600px` → `600`, `50%` → `50%` (both valid attribute forms).
  let s = css.strip()
  try:
    if s.toLowerAscii().endsWith("px"):
      let num = s[0 ..< ^2].strip()
      discard parseFloat(num)
      num
    elif s.endsWith("%"):
      discard parseFloat(s[0 ..< ^1].strip())
      s
    else:
      discard parseFloat(s)
      s
  except ValueError:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & css & "' is not a mirrorable size")

proc attrSizeToCss(attr: string): string =
  ## `600` → `600px`, `50%` → `50%`.
  let s = attr.strip()
  try:
    if s.endsWith("%"):
      discard parseFloat(s[0 ..< ^1].strip())
      s
    else:
      formatPx(parseFloat(s))
  except ValueError:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & attr & "' is not a mirrorable size")

proc isSideProp(prop, suffix: string): bool =
  ## `border-color` or `border-<side>-color` (and the width/style twins):
  ## `prop` is `border-` + `suffix`, or starts with `border-` and ends
  ## with `-` + `suffix`.
  const head = "border-"
  if not prop.startsWith(head) or not prop.endsWith(suffix):
    return false
  # `border-<suffix>` exactly, or a `-` before the suffix.
  prop.len == head.len + suffix.len or
    (prop.len > suffix.len and prop[prop.len - suffix.len - 1] == '-')

proc compressBox*(sides: array[4, string]): string =
  ## Minimal CSS shorthand for 4 sides (top, right, bottom, left).
  let (t, r, b, l) = (sides[0], sides[1], sides[2], sides[3])
  if t == r and t == b and t == l:
    t
  elif t == b and r == l:
    t & " " & r
  elif r == l:
    t & " " & r & " " & b
  else:
    t & " " & r & " " & b & " " & l

proc addPx(a, b: string): string =
  ## Sums two canonical px lengths (both come from the normalisers).
  formatPx(toPx(a) + toPx(b))

proc paddingSidesOf(styles: OrderedTable[string, string];
                    sides: var array[4, string]): bool =
  ## Reads padding sides out of a style table (shorthand, then longhands
  ## win — an approximation when both are present, where true CSS lets
  ## source order decide). False when any part is unparseable.
  sides = ["0", "0", "0", "0"]
  if "padding" in styles:
    try:
      sides = expandBox(styles["padding"])
    except StyleError:
      return false
  const longs = ["padding-top", "padding-right", "padding-bottom",
    "padding-left"]
  for i, lp in longs:
    if lp in styles:
      try:
        sides[i] = normaliseLength(lp, styles[lp])
      except StyleError:
        return false
  true

proc enclosingCell(node: EmailNode): EmailNode =
  ## The nearest ancestor `td`/`th` above `node`, or nil.
  var n = node.parent
  while n != nil:
    if n.kind == enElement and n.tag.toLowerAscii() in ["td", "th"]:
      return n
    n = n.parent
  nil

proc resolveBg(node: EmailNode; theme: EmailTheme): Rgba =
  ## The nearest opaque background: the node's own `background-color` /
  ## `background` first, then ancestors; white at the root (R-CSS-14's
  ## example blends against white). Image backgrounds are skipped — the
  ## colour behind them is unknowable, so the ancestor colour stands in.
  var n = node
  while n != nil:
    if n.kind == enElement:
      for key in ["background-color", "background"]:
        if key notin n.styles:
          continue
        var lit = n.styles[key]
        let tkey = splitTokenKey(lit)
        if tkey != "":
          try:
            lit = theme.lightFor(tkey)
          except ThemeError:
            continue
        try:
          let c = parseColor(lit)
          if c.a >= 1.0:
            return c
          return blendOver(c, resolveBg(n.parent, theme))
        except StyleError:
          continue
    n = n.parent
  parseColor("#ffffff")

proc colourDecls(node: EmailNode; tag, prop, value: string;
    theme: EmailTheme; target: EmailTarget; inline: bool):
    seq[tuple[prop, value: string]] =
  ## A colour declaration's inline form (R-CSS-14). Opaque: one hex
  ## declaration. Translucent, inline on an HTML element (which reaches
  ## the output as it is): with `outlookWord`, the opaque blend against
  ## the resolved background, then `rgba()` (the caller keeps the blend
  ## as the fallback of the pair, `EmailNode.fallbacks`, R-CSS-19);
  ## without it, `rgba()` alone. A vocabulary element (`mail…`) and a
  ## head declaration get the blend alone: their lowering, or Word,
  ## needs one opaque colour.
  let fg = parseColor(value)
  if fg.a >= 1.0:
    return @[(prop, fg.toHex())]
  # A background blends over what is behind the element; a text or
  # border colour over the element's own background.
  let behind = if prop == "background-color": resolveBg(node.parent, theme)
    else: resolveBg(node, theme)
  let blend = blendOver(fg, behind).toHex()
  if not inline or tag.startsWith("mail"):
    return @[(prop, blend)]
  if target.outlookWord:
    return @[(prop, blend), (prop, fg.toRgba())]
  @[(prop, fg.toRgba())]

proc warnDarkRaw(diags: var seq[EmailDiagnostic]; prop, value: string;
                 origin: SourceSpan) =
  diags.add(EmailDiagnostic(
    severity: sevWarning, code: codeDarkRawColor,
    message: "raw colour '" & value & "' on '" & prop &
      "' under darkMode=designed; use a tok\"color.…\" token so dark " &
      "mode resolves",
    origin: origin, families: {}, weight: 0.0, rules: @[],
  ))

proc convertMarginToCell(cell: EmailNode; sides: array[4, string];
                         tag: string; origin: SourceSpan;
                         diags: var seq[EmailDiagnostic]): bool =
  ## Merges margin sides into the cell's padding (the margin sat between
  ## the child and the cell edge, so the padding grows by it) and warns.
  ## False when the cell's padding is unparseable — the caller then keeps
  ## the margin for P10 rather than destroying the raw value.
  var pad: array[4, string]
  if not paddingSidesOf(cell.styles, pad):
    return false
  var merged: array[4, string]
  for i in 0 .. 3:
    merged[i] = addPx(pad[i], sides[i])
  for k in ["padding", "padding-top", "padding-right", "padding-bottom",
      "padding-left"]:
    cell.styles.del(k)
  cell.styles["padding"] = compressBox(merged)
  diags.add(EmailDiagnostic(
    severity: sevWarning, code: codeLayoutMarginConverted,
    message: "margin on <" & tag & "> became padding on the enclosing <" &
      cell.tag.toLowerAscii() & "> (R-OL-04)",
    origin: origin, families: {}, weight: 0.0, rules: @["R-OL-04"],
  ))
  true

proc resolveToken(node: EmailNode; raw: string; theme: EmailTheme;
                  diags: var seq[EmailDiagnostic];
                  val: var string; fromToken: var bool;
                  tkey: var string; dark = false): bool =
  ## Resolves a `tok:` sentinel to its light literal, or to its dark
  ## literal when `dark` (the `@dark:` variant). False after recording
  ## the `E-THEME-MISSING-TOKEN` diagnostic — the caller keeps the raw
  ## value and moves on.
  tkey = splitTokenKey(raw)
  if tkey == "":
    val = raw
    fromToken = false
    return true
  fromToken = true
  try:
    val = if dark: theme.darkFor(tkey) else: theme.lightFor(tkey)
  except ThemeError as e:
    diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
    return false
  true

proc normaliseDecl(node: EmailNode; tag, prop, val: string; fromToken: bool;
                   tkey: string; theme: EmailTheme; target: EmailTarget;
                   fontSizePx: float; convertMargin: bool;
                   diags: var seq[EmailDiagnostic];
                   acc: var seq[tuple[prop, value: string]]) =
  ## The replacement declarations for one token-resolved declaration,
  ## written to `acc` (which the caller empties and reuses).
  ## Shared by the inline and head paths: variant declarations normalise
  ## identically, except margins never convert (head rules are invisible
  ## to Word, so there is nothing to convert for) and MSO/mirroring stay
  ## inline-only (applied by the caller).
  if prop.startsWith("--"):
    diags.add(EmailDiagnostic(
      severity: sevError, code: codeVocabBadValue,
      message: "custom property '" & prop &
        "' is never emitted in email (R-CSS-11)",
      origin: node.origin, families: {}, weight: 0.0, rules: @["R-CSS-11"],
    ))
    return
  if containsVarRef(val):
    diags.add(EmailDiagnostic(
      severity: sevError, code: codeVocabBadValue,
      message: "'" & val & "' on '" & prop &
        "' carries a CSS custom property reference; email resolves " &
        "every token to a literal at render time (R-CSS-11)",
      origin: node.origin, families: {}, weight: 0.0, rules: @["R-CSS-11"],
    ))
    return
  if fromToken and (tkey.startsWith("type.") or tkey == "button.font"):
    # A packed type literal: the carrier property is dropped and
    # replaced by its longhands — an expansion, not a drop. (Which
    # property authors write the token under is P2's spelling to settle.)
    try:
      acc.add(expandTypeSpec(val))
      return
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      acc.add((prop, val))
      return
  if prop == "margin":
    var sides: array[4, string]
    try:
      sides = parseMargin(val)
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @["R-OL-04"]))
      acc.add((prop, val))
      return
    if sides == ["0", "0", "0", "0"]:
      acc.add((prop, "0"))
      return
    if not convertMargin or isBlockTextElement(tag):
      acc.add((prop, compressBox(sides)))
      return
    let cell = enclosingCell(node)
    if cell == nil:
      # No cell above (an unlowered authoring tree): kept for P10's
      # data-driven css-margin check — the conversion warning fires only
      # when a move actually happened.
      acc.add((prop, compressBox(sides)))
      return
    if convertMarginToCell(cell, sides, tag, node.origin, diags):
      return
    acc.add((prop, compressBox(sides)))
    return
  if prop in ["margin-top", "margin-right", "margin-bottom", "margin-left"]:
    var side: string
    try:
      side = normaliseLength(prop, val)
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @["R-OL-04"]))
      acc.add((prop, val))
      return
    if side.startsWith("-"):
      diags.add(toDiagnostic("E-VOCAB-BAD-VALUE: '" & val &
        "' uses a negative margin, which Word does not support (R-OL-04)",
        node.origin, {}, 0.0, @["R-OL-04"]))
      acc.add((prop, val))
      return
    if side == "0" or not convertMargin or isBlockTextElement(tag):
      acc.add((prop, side))
      return
    var sides = ["0", "0", "0", "0"]
    let idx = case prop
      of "margin-top": 0
      of "margin-right": 1
      of "margin-bottom": 2
      else: 3
    sides[idx] = side
    let cell = enclosingCell(node)
    if cell != nil and convertMarginToCell(cell, sides, tag, node.origin,
        diags):
      return
    acc.add((prop, side))
    return
  if prop == "padding":
    try:
      acc.add((prop, compressBox(expandBox(val))))
      return
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      acc.add((prop, val))
      return
  if prop == "background":
    try:
      let decls = colourDecls(node, tag, "background-color", val, theme,
        target, convertMargin)
      if target.darkMode == dmDesigned and not fromToken:
        warnDarkRaw(diags, "background-color", val, node.origin)
      acc.add(decls)
      return
    except StyleError:
      discard
    try:
      let (color, rest) = splitBackground(val)
      if target.darkMode == dmDesigned and color != "" and not fromToken:
        warnDarkRaw(diags, "background-color", val, node.origin)
      if rest == "":
        acc.add(("background-color", color))
        return
      # `background` first: the shorthand resets the colour, so the
      # colour must follow it. The rest stays `background` for the
      # background-image lowering, which owns it (not built yet).
      if color == "":
        acc.add(("background", rest))
        return
      acc.add(("background", rest))
      acc.add(("background-color", color))
      return
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      acc.add((prop, val))
      return
  if prop == "border":
    var b: Border
    try:
      b = parseBorder(val)
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      acc.add((prop, val))
      return
    let ch = if b.color.a < 1.0:
      blendOver(b.color, resolveBg(node, theme)).toHex()
    else:
      b.color.toHex()
    if target.darkMode == dmDesigned and not fromToken and
        "@dark:border-color" notin node.styles:
      # A border whose colour has its own dark pair resolves in dark
      # mode (a pattern's border: the theme's light value, then the
      # token's dark one).
      warnDarkRaw(diags, "border-color", val, node.origin)
    let width = formatPx(b.widthPx)
    if tag == "td":
      acc.add((prop, width & " " & b.style & " " & ch))
      return
    acc.add(("border-width", width))
    acc.add(("border-style", b.style))
    acc.add(("border-color", ch))
    return
  if isColorProp(prop):
    try:
      let decls = colourDecls(node, tag, prop, val, theme, target,
        convertMargin)
      if target.darkMode == dmDesigned and not fromToken:
        warnDarkRaw(diags, prop, val, node.origin)
      acc.add(decls)
      return
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      acc.add((prop, val))
      return
  if isSideProp(prop, "width"):
    try:
      acc.add((prop, normaliseLength(prop, val)))
      return
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      acc.add((prop, val))
      return
  if isSideProp(prop, "style"):
    acc.add((prop, val.strip().toLowerAscii()))
    return
  if prop == "line-height":
    try:
      acc.add((prop, normaliseLineHeight(val, fontSizePx)))
      return
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      acc.add((prop, val))
      return
  if isLengthProp(prop):
    try:
      acc.add((prop, normaliseLength(prop, val)))
      return
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      acc.add((prop, val))
      return
  # Unknown or unsupported: kept verbatim for P10 (never-drop). The `font`
  # shorthand passes through here too — its expansion is unowned (this
  # pass covers background/border/margin plus the packed type specs).
  acc.add((prop, val.strip()))

proc holdsText(node: EmailNode): bool =
  ## True when `node` has a non-blank text child of its own, or text in
  ## a phrase element that is its child (a cell holding only
  ## `<strong>$20</strong>` holds text: the phrase inherits its colour
  ## and type from the cell).
  for c in node.children:
    if c.kind == enText and c.text.strip().len > 0:
      return true
    if c.kind == enElement and c.tag.toLowerAscii() in ["strong", "em", "b",
        "i", "u", "s", "span", "code", "small", "sup", "sub", "codeinline"] and
        holdsText(c):
      return true
  false

proc darkColorOf(node: EmailNode; head: seq[HeadDecl]): string =
  ## The dark `color` an element's own `@dark:` declaration produced
  ## (the last one wins, as in the head block), or "".
  for d in head:
    if d.node == node and d.variant == "dark" and d.prop == "color":
      result = d.value

proc inheritedTextColor(node: EmailNode; theme: EmailTheme;
                        head: seq[HeadDecl]): tuple[light, dark: string] =
  ## The light and dark colours `node` would inherit (R-TXT-02). Light:
  ## the nearest ancestor's resolved inline `color`, else the theme's
  ## `color.text.primary`. Dark: the nearest ancestor that sets either —
  ## its `@dark:` value, or its inline colour when it has no dark one
  ## (that colour then holds in dark mode too) — else the token's dark
  ## value. Ancestors are final already: the walk is pre-order.
  var lightFound, darkFound = false
  var a = node.parent
  while a != nil and not (lightFound and darkFound):
    if a.kind == enElement:
      let own = a.styles.getOrDefault("color", "")
      if not darkFound:
        let d = darkColorOf(a, head)
        if d != "":
          result.dark = d
          darkFound = true
        elif own != "":
          result.dark = own
          darkFound = true
      if not lightFound and own != "":
        result.light = own
        lightFound = true
    a = a.parent
  try:
    if not lightFound:
      result.light = normaliseColor(theme.lightFor(defaultTextColorToken))
    if not darkFound:
      result.dark = normaliseColor(theme.darkFor(defaultTextColorToken))
  except ThemeError, StyleError:
    discard

proc onlyImages(node: EmailNode): bool =
  ## True when `node` holds images and nothing else (whitespace aside).
  var any = false
  for c in node.children:
    case c.kind
    of enText:
      if c.text.strip().len > 0:
        return false
    of enElement:
      if c.tag notin ["mailImage", "img"]:
        return false
      any = true
    else: discard
  any

proc linkDefaults(node: EmailNode; theme: EmailTheme; target: EmailTarget;
                  head: var seq[HeadDecl];
                  res: var OrderedTable[string, string]) =
  ## R-TXT-04: every link carries its colour and decoration inline, so
  ## no client paints its default blue, purple or underline. A link in
  ## body text is `color.link`, underlined; a link in text the author
  ## coloured (a footer, a caption) keeps that colour, underlined, the
  ## way it would inherit it; a link around images only is not
  ## underlined (the line would show under the image, or under its alt
  ## text). The author's own values win.
  defer:
    if "text-decoration" notin res:
      res["text-decoration"] = if onlyImages(node): "none" else: "underline"
  if "color" in res:
    return
  let (light, dark) = inheritedTextColor(node, theme, head)
  var primary = ""
  try:
    primary = normaliseColor(theme.lightFor(defaultTextColorToken))
  except ThemeError, StyleError:
    discard
  if light.len > 0 and light != primary:
    res["color"] = light
    if target.darkMode == dmDesigned and dark != "" and dark != light:
      head.add(HeadDecl(variant: "dark", prop: "color", value: dark,
        node: node, origin: node.origin))
    return
  try:
    let l = normaliseColor(theme.lightFor(linkColorToken))
    let d = normaliseColor(theme.darkFor(linkColorToken))
    res["color"] = l
    if target.darkMode == dmDesigned and d != l:
      head.add(HeadDecl(variant: "dark", prop: "color", value: d,
        node: node, origin: node.origin))
  except ThemeError, StyleError:
    discard

const designedDocumentSurface* = "color.surface.card"
  ## The surface a `darkMode = designed` document without a background of
  ## its own is painted with: the token whose light value is the
  ## skeleton's `#ffffff` in the default theme, so its dark value comes
  ## with it (R-DRK-02, catalogue §1).

proc pairsDark(prop: string): bool =
  ## The properties R-DRK-02 pairs with a token's dark value: the text
  ## colour, the background (either spelling) and the border colours.
  prop in ["color", "background-color", "background"] or
    isSideProp(prop, "color")

proc tokenDarkPairs(entries: seq[(string, string)];
                    theme: EmailTheme): seq[(string, string)] =
  ## R-DRK-02, token-driven: for every colour declaration resolved from a
  ## `tok"…"` whose dark value differs from its light one, the `@dark:`
  ## twin that carries the dark value, unless the element declares that
  ## variant itself (its own `@dark:` wins). Only under `designed`.
  var explicit: seq[string] = @[]
  for (k, _) in entries:
    let (variant, base) = splitVariantKey(k)
    if variant == "dark":
      explicit.add(base.toLowerAscii())
  for (k, v) in entries:
    let (variant, base) = splitVariantKey(k)
    let prop = base.toLowerAscii()
    if variant != "" or not pairsDark(prop):
      continue
    let tkey = splitTokenKey(v)
    if tkey == "" or prop in explicit or
        (prop == "background" and "background-color" in explicit) or
        (prop == "background-color" and "background" in explicit):
      continue
    try:
      if normaliseColor(theme.darkFor(tkey)) ==
          normaliseColor(theme.lightFor(tkey)):
        continue
    except ThemeError, StyleError:
      # A missing token or a non-colour value: the inline path reports it.
      continue
    explicit.add(prop)
    result.add(("@dark:" & k, v))

proc darkBackgroundOf(node: EmailNode; head: seq[HeadDecl]): string =
  ## The dark `background-color` the dark rules give `node` itself (its
  ## last one), or "".
  for d in head:
    if d.node == node and d.variant == "dark" and
        d.prop == "background-color":
      result = d.value

proc shadowBorderDark(node: EmailNode; head: seq[HeadDecl]): string =
  ## R-TBL-09 under `designed`: the dark colour of the border a shadowed
  ## `mailBox` without a border of its own gets, one step darker than the
  ## background it shows in the dark scheme (its own dark background,
  ## else the nearest ancestor's); "" when no dark rule paints one, and
  ## the light border then stands.
  var n = node
  while n != nil:
    if n.kind == enElement:
      let d = darkBackgroundOf(n, head)
      if d.len > 0:
        try:
          return darkerStep(d)
        except StyleError:
          return ""
    n = n.parent
  ""

proc hasBackgroundImage(n: EmailNode): bool =
  ## True when `n` carries a background image (a style or an attribute,
  ## either spelling, or a `background` shorthand holding a `url(`).
  for k in ["background-image", "background_image"]:
    if n.styles.getOrDefault(k, "").strip().len > 0 or
        n.attrs.getOrDefault(k, "").strip().len > 0:
      return true
  "url(" in n.styles.getOrDefault("background", "").toLowerAscii()

proc paintsBackground(n: EmailNode): bool =
  ## True when `n` paints a background colour of its own.
  for k in ["background-color", "background_color", "background", "bgcolor"]:
    for v in [n.styles.getOrDefault(k, ""), n.attrs.getOrDefault(k, "")]:
      let x = v.strip().toLowerAscii()
      if x.len > 0 and x notin ["transparent", "none"]:
        return true
  false

proc overBackgroundImage*(node: EmailNode): bool =
  ## R-DRK-02, R-VML-01: true when `node` is a band with a background
  ## image, or the backdrop of its colours is one. Walking up from the
  ## element itself, the first element that paints a background decides:
  ## an image means yes, a colour means no (a card with a background of
  ## its own is its own backdrop, even inside an image band).
  var n = node
  while n != nil:
    if n.kind == enElement:
      if hasBackgroundImage(n):
        return true
      if paintsBackground(n):
        return false
    n = n.parent
  false

proc borderShorthandColour(value: string): string =
  ## The colour of a `border` shorthand value, "" when none parses.
  try:
    let b = parseBorder(value)
    result = if b.color.a < 1.0: b.color.toRgba() else: b.color.toHex()
  except StyleError:
    result = ""

proc lightTwin(res: OrderedTable[string, string]; prop: string): string =
  ## The element's resolved inline value of `prop`: the light twin of a
  ## dark declaration of it (R-DRK-08), "" when it has none. A border
  ## colour is read from its own longhand, else its side's or the
  ## element's `border-color` (one value), else the `border` shorthand.
  let p = prop.toLowerAscii()
  if p in res:
    return res[p]
  if p.startsWith("border") and p.endsWith("-color"):
    let side = p[0 ..< p.len - "-color".len]
    if side != "border" and side in res:
      let c = borderShorthandColour(res[side])
      if c.len > 0:
        return c
    let all = res.getOrDefault("border-color", "").strip()
    if all.len > 0 and " " notin all:
      return all
    if "border" in res:
      return borderShorthandColour(res["border"])
  ""

proc styleElementFor(node: EmailNode; theme: EmailTheme; target: EmailTarget;
                     profile: AudienceProfile; head: var seq[HeadDecl];
                     diags: var seq[EmailDiagnostic]) =
  ## `styleElement` under the target it applies to the element.
  let tag = node.tag.toLowerAscii()
  let headStart = head.len
  var entries: seq[(string, string)] = @[]
  template addAll(defaults: seq[tuple[prop, value: string]]) =
    # Each default moved into `entries`, in order.
    var fresh = defaults
    for d in fresh.mitems:
      entries.add((move(d.prop), move(d.value)))
  # The text leaves' defaults (`lower/text.nim`, R-TXT-02, R-TXT-09)
  # come first, so every declaration of the element's own follows and
  # wins; they normalise like any other declaration.
  try:
    addAll(textDefaults(node, theme))
    addAll(leafDefaults(node, target))
    addAll(buttonDefaults(node, theme, target))
    addAll(tableDefaults(node, theme, target))
  except ThemeError as e:
    diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @["R-TXT-02"]))
  except StyleError as e:
    # A `mailTable` border that is neither `none` nor a Border; the
    # table's own declaration reports it.
    discard e
  if tag == "maildocument" and target.darkMode == dmDesigned and
      "background-color" notin node.styles and
      "background" notin node.styles and
      "background_color" notin node.styles and
      "background_color" notin node.attrs and
      "background-color" notin node.attrs:
    # The skeleton's surface under `designed` is a token, so it has a
    # dark value like every other colour of a designed message (R-DRK-02).
    entries.add(("background-color", "tok:" & designedDocumentSurface))
  for k in node.styles.keys:
    entries.add((k, node.styles[k]))
  if target.darkMode == dmDesigned:
    for e in tokenDarkPairs(entries, theme):
      entries.add(e)
  if tag == "mailimage" and
      node.attrs.getOrDefault("fluid_on_mobile", "").toLowerAscii() == "true":
    # R-IMG-09: full width below the breakpoint, through a class; the
    # desktop width stays inline (`lower/image.nim`).
    entries.add(("@sm:width", "100%"))
    entries.add(("@sm:max-width", "100%"))
  # The element's font size, for unitless line-height multipliers; unknown
  # or unparseable sizes fall back to the 16px root.
  var fontSizePx = cssRootPx
  for (k, v) in entries:
    if not eqLowerAscii(k, "font-size"):
      continue
    if splitVariantKey(k).variant != "":
      continue
    var lit = v
    let tk = splitTokenKey(v)
    if tk != "":
      try:
        lit = theme.lightFor(tk)
      except ThemeError:
        continue
    try:
      fontSizePx = toPx(lit)
    except StyleError:
      discard
  var res = initOrderedTable[string, string](entries.len)
  # Usually stays empty: allocated by its first pair only.
  var fallbacks: OrderedTable[string, string]
  # One buffer for every declaration's replacements (`normaliseDecl`).
  var decls: seq[tuple[prop, value: string]] = @[]
  for i in 0 ..< entries.len:
    template key: untyped = entries[i][0]
    template given: untyped = entries[i][1]
    if key.startsWith("@") and key.find(':') > 1:
      # A variant key (`splitVariantKey` gives a non-empty variant).
      let (variant, base) = splitVariantKey(key)
      var val, tkey: string
      var fromToken = false
      if not resolveToken(node, given, theme, diags, val, fromToken, tkey,
          dark = variant == "dark"):
        res[key] = given
        continue
      if variant notin headVariants:
        if variant == "md":
          diags.add(EmailDiagnostic(
            severity: sevError, code: codeVocabBadValue,
            message: "'" & key & "' uses the md: breakpoint: email has " &
              "one breakpoint; use sm: (mobile) semantics",
            origin: node.origin, families: {}, weight: 0.0, rules: @[],
          ))
        else:
          diags.add(EmailDiagnostic(
            severity: sevError, code: codeVocabBadValue,
            message: "'" & key & "' uses unknown variant '" & variant &
              "': email knows sm:, dark: and hover:",
            origin: node.origin, families: {}, weight: 0.0, rules: @[],
          ))
        # The raw @-key stays inline (never-drop) — the error blocks
        # `toMessage`, so the unsplittable key never reaches output.
        res[key] = given
        continue
      # No harmful check here: a head-bound flex cannot collapse Word,
      # which ignores head rules entirely (the lint precedent).
      decls.setLen(0)
      normaliseDecl(node, tag, base.toLowerAscii(), val, fromToken, tkey,
        theme, target, fontSizePx, false, diags, decls)
      for (p, v) in decls:
        head.add(HeadDecl(variant: variant, prop: p, value: v, node: node,
          origin: node.origin))
      continue
    if hasUpperAscii(key):
      # Read below as the lower-cased property; the key itself is not
      # read again.
      key = key.toLowerAscii()
    template prop: untyped = key
    # The value, token-resolved, is read in the entry's own slot: a
    # literal stays where it is; a token's literal is swapped in, and its
    # sentinel kept in `tokenRaw`.
    var tokenRaw, tkey: string
    var fromToken = false
    if given.startsWith("tok:"):
      if not resolveToken(node, given, theme, diags, tokenRaw, fromToken,
          tkey):
        res[prop] = given
        continue
      swap(given, tokenRaw)
    template val: untyped = given
    if tag == "mailtable" and prop == "border":
      # A data table's `border` is its cells' (R-TBL-18): `none` is a
      # value here, and the table's lowering, not CSS, places it.
      try:
        discard tableBorder(node)
      except StyleError as e:
        diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @["R-TBL-18"]))
      res[prop] = if fromToken: tokenRaw else: given
      continue
    if prop == "font-family" and not fromToken and not endsGeneric(val):
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue, message: "font-family '" & val &
          "' does not end in a generic family (serif, sans-serif, " &
          "monospace, …): a client without its fonts falls back to its " &
          "own default (R-TXT-05)", origin: node.origin,
        rules: @["R-TXT-05"]))
    if prop in ["text-size-adjust", "-webkit-text-size-adjust",
        "-ms-text-size-adjust", "-moz-text-size-adjust"] and
        val.strip().toLowerAscii() notin ["100%", "auto"]:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue, message: prop & ":" & val & " stops " &
          "readers from scaling the text; only the reset's 100% is " &
          "written (R-TXT-08)", origin: node.origin, rules: @["R-TXT-08"]))
    if isHarmfulDeclaration(prop, val):
      # P5 is the remover lint warns about: the declaration goes on every
      # element, with lint's R-OL-10 severity — an error on a layout
      # container while the profile gives Word-engine Outlook weight, the
      # removal warning otherwise.
      diags.add(harmfulDisplayDiagnostic(tag, harmfulDisplayValue(val),
        profile, node.origin, removed = true))
      continue
    decls.setLen(0)
    normaliseDecl(node, tag, prop, val, fromToken, tkey, theme, target,
      fontSizePx, true, diags, decls)
    for j in 0 ..< decls.len:
      template p: untyped = decls[j].prop
      var seen = false
      for k in 0 ..< j:
        if decls[k].prop == p:
          seen = true
          break
      if seen:
        # The second of a pair (R-CSS-14): the first becomes its
        # fallback (R-CSS-19).
        fallbacks[p] = res[p]
      elif p in fallbacks:
        fallbacks.del(p)
      res[p] = move(decls[j].value)
  if tag == "a":
    linkDefaults(node, theme, target, head, res)
  elif "color" notin res and (tag in textColorCarriers or
      (tag in ["td", "th", "div", "mailtext"] and holdsText(node)) or
      (tag == "mailcluster" and
        node.attrs.getOrDefault("separator", "").len > 0)):
    # R-TXT-02: a text element never relies on an inherited colour (a
    # cluster's separators are text its lowering writes). A
    # client whose dark scheme or theme supplies a light default text
    # colour (SnappyMail's dark themes, WebKit under `color-scheme:
    # light dark`) would otherwise paint it light on the message's own
    # light background. The inline value is the one inheritance would
    # have given; under `designed` the dark pairing follows it too.
    let (light, dark) = inheritedTextColor(node, theme, head)
    if light != "":
      res["color"] = light
      if target.darkMode == dmDesigned and dark != "" and dark != light:
        head.add(HeadDecl(variant: "dark", prop: "color", value: dark,
          node: node, origin: node.origin))
  if tag == "mailbox" and target.darkMode == dmDesigned and
      "border" notin res and "border-color" notin res and
      (res.getOrDefault("shadow", node.attrs.getOrDefault("shadow",
        "")).strip().toLowerAscii() in ["sm", "md"]):
    # R-TBL-09: the border that marks a shadowed box's edge is derived
    # from its light background; in the dark scheme it follows the dark
    # one, or it turns near-white on the dark box.
    let dark = shadowBorderDark(node, head)
    if dark.len > 0:
      head.add(HeadDecl(variant: "dark", prop: "border-color", value: dark,
        node: node, origin: node.origin,
        light: shadowBorderColour(res.getOrDefault("background-color", ""))))
  if target.outlookWord:
    # The closed MSO list: each addition checks for an
    # author-set value first and never overwrites one. With outlookWord
    # off nothing is added; author-written mso-* stays for P9 to prune
    # (only P9 removes by target).
    if "line-height" in res and
        res["line-height"].strip().toLowerAscii() != "normal" and
        "mso-line-height-rule" notin res:
      res["mso-line-height-rule"] = "exactly"
    if tag == "table":
      if "mso-table-lspace" notin res:
        res["mso-table-lspace"] = "0pt"
      if "mso-table-rspace" notin res:
        res["mso-table-rspace"] = "0pt"
    if tag == "td" and "mso-padding-alt" notin res and
        ("padding" in res or "padding-top" in res or
        "padding-right" in res or "padding-bottom" in res or
        "padding-left" in res):
      # Button cells are `td`s with padding; restating it as
      # mso-padding-alt is what Word reads instead.
      var sides: array[4, string]
      if paddingSidesOf(res, sides):
        res["mso-padding-alt"] = compressBox(sides)
    if res.getOrDefault("display", "").strip().toLowerAscii() == "none" and
        "mso-hide" notin res:
      # Inline `display:none` hides everywhere including desktop, so
      # hiding from Word as well changes nothing (mobile-hide patterns
      # use variant keys, never inline none).
      res["mso-hide"] = "all"
  if tag in boxAttrCarriers:
    # CSS wins: the attribute follows resolved CSS, or seeds it when the
    # CSS side is absent. Unparseable sides leave both untouched.
    for attr in ["width", "height"]:
      if attr in res:
        try:
          node.attrs[attr] = cssSizeToAttr(res[attr])
        except StyleError:
          discard
      elif attr in node.attrs:
        try:
          res[attr] = attrSizeToCss(node.attrs[attr])
        except StyleError:
          discard
  if tag in bgAttrCarriers:
    if "background-color" in fallbacks:
      # A translucent background's attribute is its opaque blend.
      node.attrs["bgcolor"] = fallbacks["background-color"]
    elif "background-color" in res:
      try:
        let c = parseColor(res["background-color"])
        # R-OL-09: an attribute cannot carry rgba(), so a translucent
        # background's `bgcolor` is its blend over what is behind the
        # cell, whatever the target (without Word the inline value is
        # rgba() alone, R-CSS-14).
        node.attrs["bgcolor"] = if c.a < 1.0:
            blendOver(c, resolveBg(node.parent, theme)).toHex()
          else: normaliseColor(res["background-color"])
      except StyleError:
        discard
    elif "bgcolor" in node.attrs:
      try:
        let hex = normaliseColor(node.attrs["bgcolor"])
        node.attrs["bgcolor"] = hex
        res["background-color"] = hex
        if target.darkMode == dmDesigned:
          warnDarkRaw(diags, "background-color", node.attrs["bgcolor"],
            node.origin)
      except StyleError:
        discard
  if tag in alignCarriers:
    const aligns = ["left", "center", "right"]
    if "text-align" in res:
      let v = res["text-align"].strip().toLowerAscii()
      if v in aligns:
        node.attrs["align"] = v
    elif "align" in node.attrs:
      let v = node.attrs["align"].strip().toLowerAscii()
      if v in aligns:
        res["text-align"] = v
  if tag in valignCarriers:
    # R-OL-09: `valign` mirrors `vertical-align`, CSS first.
    const valigns = ["top", "middle", "bottom"]
    if "vertical-align" in res:
      let v = res["vertical-align"].strip().toLowerAscii()
      if v in valigns:
        node.attrs["valign"] = v
    elif "valign" in node.attrs:
      let v = node.attrs["valign"].strip().toLowerAscii()
      if v in valigns:
        res["vertical-align"] = v
  if target.outlookWord and target.webFonts.len > 0 and "font-family" in res:
    # R-OL-07: an element whose first family is a web font names Word's
    # fallback for it.
    let alt = msoFontAlt(res["font-family"], target)
    if alt.len > 0 and "mso-font-alt" notin res:
      res["mso-font-alt"] = alt
  node.styles = move(res)
  # The resolved table now lives on the node; it is read there below.
  node.fallbacks = default(OrderedTable[string, string])
  for k, v in fallbacks.pairs:
    if k in node.styles:
      node.fallbacks[k] = v
  if node.styles.getOrDefault("color", "").startsWith("rgba(") and
      "color" notin node.fallbacks:
    # A colour inherited from an ancestor's translucent pair keeps the
    # ancestor's blend as its fallback.
    var a = node.parent
    while a != nil:
      if a.kind == enElement and "color" in a.styles:
        if a.styles["color"] == node.styles["color"] and
            "color" in a.fallbacks:
          node.fallbacks["color"] = a.fallbacks["color"]
        break
      a = a.parent
  for i in headStart ..< head.len:
    # Each dark declaration's light twin, for Thunderbird's copy of its
    # rule (R-DRK-08).
    if head[i].node == node and head[i].variant == "dark" and
        head[i].light.len == 0:
      head[i].light = lightTwin(node.styles, head[i].prop)

proc styleElement(node: EmailNode; theme: EmailTheme; target: EmailTarget;
                  profile: AudienceProfile; head: var seq[HeadDecl];
                  diags: var seq[EmailDiagnostic]) =
  if target.darkMode == dmDesigned and overBackgroundImage(node):
    # R-DRK-02, R-VML-01: a band with a background image, and what lies
    # over the image, keep one colour in both schemes: the image does
    # not change with the scheme, so neither its fallback colour nor the
    # text on it pairs a token's dark value (an element's own `@dark:`
    # still applies), and a raw colour there is not a defect.
    var t = target
    t.darkMode = dmAccommodate
    styleElementFor(node, theme, t, profile, head, diags)
  else:
    styleElementFor(node, theme, target, profile, head, diags)

proc applyStylesImpl(node: EmailNode; theme: EmailTheme;
                     target: EmailTarget; profile: AudienceProfile;
                     head: var seq[HeadDecl];
                     diags: var seq[EmailDiagnostic]) =
  if node == nil:
    return
  if node.kind == enElement:
    styleElement(node, theme, target, profile, head, diags)
  # Pre-order: parents resolve before children (margin conversion merges
  # into already-final cell padding), and the seq itself is never touched.
  for child in node.children:
    applyStylesImpl(child, theme, target, profile, head, diags)

proc applyStyles*(root: EmailNode; theme: EmailTheme; target: EmailTarget;
                  profile = consumer):
    tuple[head: seq[HeadDecl]; diagnostics: seq[EmailDiagnostic]] =
  ## P5 over one tree: final inline styles plus the variant declarations
  ## split out for P6 and every diagnostic, in tree order. Pure (no IO)
  ## and backend-independent. `profile` weighs only the harmful-display
  ## removal (see `harmfulDisplayDiagnostic`).
  var head: seq[HeadDecl] = @[]
  var diags: seq[EmailDiagnostic] = @[]
  applyStylesImpl(root, theme, target, profile, head, diags)
  (head, diags)
