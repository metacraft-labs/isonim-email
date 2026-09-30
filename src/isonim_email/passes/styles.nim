## isonim_email/passes/styles.nim — P5: the inline style pass.
##
## Resolves every declaration to its final inline form: `tok"…"` sentinels
## (stored by the `setStyle` overload) become light literals (R-CSS-01) —
## except under the `@dark:` variant, where they become the token's dark
## literal (`darkFor`), the value the dark head rules exist to carry —
## variant keys (`@sm:`/`@dark:`/`@hover:`) move into the head
## list P6 serialises, units/colours/shorthands normalise through
## `style/*`, the closed MSO list applies when `outlookWord`, and
## `width`/`height`/`bgcolor`/`align` mirror between attributes and CSS.
##
## Pass discipline: children are never reordered (the walk only
## touches `styles`/`attrs`, never the `children` seq); unsupported
## properties are kept verbatim for P10, and only three things are ever
## removed — harmful `display:flex`/`grid` (with `E-CSS-HARMFUL`, the same
## code as lint's R-OL-10), `var()`/`--x` (with `E-VOCAB-BAD-VALUE`:
## R-CSS-11's "never emitted" overrides never-drop, since a custom
## property is unresolvable in email, not merely unsupported), and margins
## that moved to cell padding (with `W-LAYOUT-MARGIN-CONVERTED`). Every
## other failure keeps the raw declaration beside its error diagnostic.
##
## Two single-value consequences of `styles` being an `OrderedTable`:
## translucent colours inline as the opaque blend alone (R-CSS-14's
## blend-then-`rgba()` pair needs two declarations under one property
## name, which the table cannot hold — the blend is Word-safe and correct
## everywhere, just not translucent); and `HeadDecl` carries one
## declaration each (P6 re-pairs where head CSS needs pairs).
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
import ../target

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

const
  headVariants = ["sm", "dark", "hover"]
    ## The only variants email knows. `md` is tagged by the Tailwind expansion
    ## solely so P5 can reject it; anything else is a config error.

  boxAttrCarriers = ["table", "td", "th", "img"]
    ## Elements whose `width`/`height` attributes mirror CSS.

  bgAttrCarriers = ["body", "table", "tr", "td", "th"]
    ## Elements whose `bgcolor` mirrors `background-color`.

  alignCarriers = ["td", "th", "tr", "div", "p", "h1", "h2", "h3", "h4",
    "h5", "h6"]
    ## Elements whose `align` mirrors `text-align`. `table` is excluded:
    ## `align` on a table centers the box, not the text — P4 owns that.

  lengthProps = ["margin-top", "margin-right", "margin-bottom",
    "margin-left", "padding-top", "padding-right", "padding-bottom",
    "padding-left", "width", "min-width", "max-width", "height",
    "min-height", "max-height", "font-size", "border-width",
    "border-top-width", "border-right-width", "border-bottom-width",
    "border-left-width", "letter-spacing", "text-indent", "border-spacing",
    "border-radius", "border-top-left-radius", "border-top-right-radius",
    "border-bottom-right-radius", "border-bottom-left-radius"]
    ## The box/font set normalised to px (`%` survives on widths via
    ## `normaliseLength`); every other property keeps its value verbatim.

proc splitTokenKey(value: string): string =
  ## The theme key when `value` is a `tok"…"` sentinel, else "".
  if value.startsWith("tok:"):
    value[4 .. ^1]
  else:
    ""

proc containsVarRef(value: string): bool =
  ## Case-insensitive `var(` scan, tolerating space before the paren.
  "var(" in value.toLowerAscii().replace(" ", "").replace("\t", "")

proc isColorProp(prop: string): bool =
  prop == "color" or prop.endsWith("-color")

proc isLengthProp(prop: string): bool =
  prop in lengthProps

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
  ## `border-color` or `border-<side>-color` (and the width/style twins).
  prop == "border-" & suffix or
    (prop.startsWith("border-") and prop.endsWith("-" & suffix))

proc compressBox(sides: array[4, string]): string =
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

proc opaqueHex(node: EmailNode; theme: EmailTheme; value: string): string =
  ## 6-digit hex for a colour value; translucent blends over the resolved
  ## background (see the header note on why inline carries no `rgba()`).
  let fg = parseColor(value)
  if fg.a >= 1.0:
    fg.toHex()
  else:
    blendOver(fg, resolveBg(node, theme)).toHex()

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
                   diags: var seq[EmailDiagnostic]): seq[
                     tuple[prop, value: string]] =
  ## The replacement declarations for one token-resolved declaration.
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
    return @[]
  if containsVarRef(val):
    diags.add(EmailDiagnostic(
      severity: sevError, code: codeVocabBadValue,
      message: "'" & val & "' on '" & prop &
        "' carries a CSS custom property reference; email resolves " &
        "every token to a literal at render time (R-CSS-11)",
      origin: node.origin, families: {}, weight: 0.0, rules: @["R-CSS-11"],
    ))
    return @[]
  if fromToken and (tkey.startsWith("type.") or tkey == "button.font"):
    # A packed type literal: the carrier property is dropped and
    # replaced by its longhands — an expansion, not a drop. (Which
    # property authors write the token under is P2's spelling to settle.)
    try:
      return expandTypeSpec(val)
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      return @[(prop, val)]
  if prop == "margin":
    var sides: array[4, string]
    try:
      sides = parseMargin(val)
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @["R-OL-04"]))
      return @[(prop, val)]
    if sides == ["0", "0", "0", "0"]:
      return @[(prop, "0")]
    if not convertMargin or isBlockTextElement(tag):
      return @[(prop, compressBox(sides))]
    let cell = enclosingCell(node)
    if cell == nil:
      # No cell above (an unlowered authoring tree): kept for P10's
      # data-driven css-margin check — the conversion warning fires only
      # when a move actually happened.
      return @[(prop, compressBox(sides))]
    if convertMarginToCell(cell, sides, tag, node.origin, diags):
      return @[]
    return @[(prop, compressBox(sides))]
  if prop in ["margin-top", "margin-right", "margin-bottom", "margin-left"]:
    var side: string
    try:
      side = normaliseLength(prop, val)
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @["R-OL-04"]))
      return @[(prop, val)]
    if side.startsWith("-"):
      diags.add(toDiagnostic("E-VOCAB-BAD-VALUE: '" & val &
        "' uses a negative margin, which Word does not support (R-OL-04)",
        node.origin, {}, 0.0, @["R-OL-04"]))
      return @[(prop, val)]
    if side == "0" or not convertMargin or isBlockTextElement(tag):
      return @[(prop, side)]
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
      return @[]
    return @[(prop, side)]
  if prop == "padding":
    try:
      return @[(prop, compressBox(expandBox(val)))]
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      return @[(prop, val)]
  if prop == "background":
    try:
      let hex = opaqueHex(node, theme, val)
      if target.darkMode == dmDesigned and not fromToken:
        warnDarkRaw(diags, "background-color", val, node.origin)
      return @[("background-color", hex)]
    except StyleError:
      discard
    try:
      let (color, rest) = splitBackground(val)
      if target.darkMode == dmDesigned and color != "" and not fromToken:
        warnDarkRaw(diags, "background-color", val, node.origin)
      if rest == "":
        return @[("background-color", color)]
      # `background` first: the shorthand resets the colour, so the
      # colour must follow it. The rest stays `background` for the
      # background-image lowering, which owns it (not built yet).
      if color == "":
        return @[("background", rest)]
      return @[("background", rest), ("background-color", color)]
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      return @[(prop, val)]
  if prop == "border":
    var b: Border
    try:
      b = parseBorder(val)
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      return @[(prop, val)]
    let ch = if b.color.a < 1.0:
      blendOver(b.color, resolveBg(node, theme)).toHex()
    else:
      b.color.toHex()
    if target.darkMode == dmDesigned and not fromToken:
      warnDarkRaw(diags, "border-color", val, node.origin)
    let width = formatPx(b.widthPx)
    if tag == "td":
      return @[(prop, width & " " & b.style & " " & ch)]
    return @[("border-width", width), ("border-style", b.style),
      ("border-color", ch)]
  if isColorProp(prop):
    try:
      let hex = opaqueHex(node, theme, val)
      if target.darkMode == dmDesigned and not fromToken:
        warnDarkRaw(diags, prop, val, node.origin)
      return @[(prop, hex)]
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      return @[(prop, val)]
  if isSideProp(prop, "width"):
    try:
      return @[(prop, normaliseLength(prop, val))]
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      return @[(prop, val)]
  if isSideProp(prop, "style"):
    return @[(prop, val.strip().toLowerAscii())]
  if prop == "line-height":
    try:
      return @[(prop, normaliseLineHeight(val, fontSizePx))]
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      return @[(prop, val)]
  if isLengthProp(prop):
    try:
      return @[(prop, normaliseLength(prop, val))]
    except StyleError as e:
      diags.add(toDiagnostic(e.msg, node.origin, {}, 0.0, @[]))
      return @[(prop, val)]
  # Unknown or unsupported: kept verbatim for P10 (never-drop). The `font`
  # shorthand passes through here too — its expansion is unowned (this
  # pass covers background/border/margin plus the packed type specs).
  @[(prop, val.strip())]

proc styleElement(node: EmailNode; theme: EmailTheme; target: EmailTarget;
                  head: var seq[HeadDecl];
                  diags: var seq[EmailDiagnostic]) =
  let tag = node.tag.toLowerAscii()
  var entries: seq[(string, string)] = @[]
  for k, v in node.styles.pairs:
    entries.add((k, v))
  # The element's font size, for unitless line-height multipliers; unknown
  # or unparseable sizes fall back to the 16px root.
  var fontSizePx = cssRootPx
  for (k, v) in entries:
    if k.toLowerAscii() != "font-size":
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
  var res = initOrderedTable[string, string]()
  for (key, raw) in entries:
    let (variant, base) = splitVariantKey(key)
    if variant != "":
      var val, tkey: string
      var fromToken = false
      if not resolveToken(node, raw, theme, diags, val, fromToken, tkey,
          dark = variant == "dark"):
        res[key] = raw
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
        res[key] = raw
        continue
      # No harmful check here: a head-bound flex cannot collapse Word,
      # which ignores head rules entirely (the lint precedent).
      for (p, v) in normaliseDecl(node, tag, base.toLowerAscii(), val,
          fromToken, tkey, theme, target, fontSizePx, false, diags):
        head.add(HeadDecl(variant: variant, prop: p, value: v, node: node,
          origin: node.origin))
      continue
    let prop = key.toLowerAscii()
    var val, tkey: string
    var fromToken = false
    if not resolveToken(node, raw, theme, diags, val, fromToken, tkey):
      res[prop] = raw
      continue
    if isHarmfulDeclaration(prop, val):
      # P5 is the remover lint warns about: the declaration goes, with an
      # error, on every element — not just layout containers.
      let keyword = harmfulDisplayValue(val)
      let w = if isLayoutContainer(node.tag):
        "display:" & keyword & " on <" & tag &
          "> collapses in Word-engine Outlook; use mailColumns or " &
          "mailStack instead"
      else:
        "display:" & keyword & " on <" & tag &
          "> is not supported in email and was removed; restructure to " &
          "avoid it"
      diags.add(EmailDiagnostic(
        severity: sevError, code: codeCssHarmful, message: w,
        origin: node.origin, families: {cfOutlookWord}, weight: 0.0,
        rules: @["R-OL-10"],
      ))
      continue
    for (p, v) in normaliseDecl(node, tag, prop, val, fromToken, tkey,
        theme, target, fontSizePx, true, diags):
      res[p] = v
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
    if "background-color" in res:
      try:
        node.attrs["bgcolor"] = normaliseColor(res["background-color"])
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
  node.styles = res

proc applyStylesImpl(node: EmailNode; theme: EmailTheme;
                     target: EmailTarget; head: var seq[HeadDecl];
                     diags: var seq[EmailDiagnostic]) =
  if node == nil:
    return
  if node.kind == enElement:
    styleElement(node, theme, target, head, diags)
  # Pre-order: parents resolve before children (margin conversion merges
  # into already-final cell padding), and the seq itself is never touched.
  for child in node.children:
    applyStylesImpl(child, theme, target, head, diags)

proc applyStyles*(root: EmailNode; theme: EmailTheme; target: EmailTarget):
    tuple[head: seq[HeadDecl]; diagnostics: seq[EmailDiagnostic]] =
  ## P5 over one tree: final inline styles plus the variant declarations
  ## split out for P6 and every diagnostic, in tree order. Pure (no IO)
  ## and backend-independent.
  var head: seq[HeadDecl] = @[]
  var diags: seq[EmailDiagnostic] = @[]
  applyStylesImpl(root, theme, target, head, diags)
  (head, diags)
