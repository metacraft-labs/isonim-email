## isonim_email/style/units.nim — length normalisation (R-CSS-13).
##
## px everywhere for box properties, `font-size` and `line-height`; `%` for
## widths only; `rem`/`em` converted with a 16px root; unitless numbers get
## px restored from the Tailwind extractor's unit record; unitless `line-height` becomes px
## (Word needs px plus `mso-line-height-rule:exactly` — the MSO addition is
## P5's closed list, not this module).
##
## Pure `std` string work: identical on the C and JS targets. This module
## also defines `StyleError`, the shared style-layer failure: every
## style/* module raises it with a stable code head up front
## (`E-VOCAB-BAD-VALUE`, `E-CSS-INVALID`) so `toDiagnostic` converts it.
## Kept framework-free (no renderer import) like `ThemeError`, so the
## theme generator and the JS target never import the renderer.

import std/[math, strutils, tables]
import ../target
import ./memo

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type StyleError* = object of ValueError
  ## A style-layer failure (units, colours, shorthand, CSS serialiser,
  ## class names). The message carries the stable code head.

const cssRootPx* = 16.0
  ## The root `font-size` `rem`/`em` convert against.

proc formatNum*(n: float): string =
  ## Canonical number: integral values without decimals, otherwise up to
  ## two decimals with trailing zeros stripped. Rounds to 2dp so float
  ## noise (`18.400000000001`) never reaches output.
  let r = round(n * 100.0) / 100.0
  if r == r.int.float:
    $r.int
  else:
    formatFloat(r, ffDecimal, 2).strip(leading = false, trailing = true,
      chars = {'0'})

proc formatPx*(px: float): string =
  ## Canonical px length: `"0"` for zero, else the canonical number plus
  ## `px`. Unitless zero is valid everywhere a length is.
  if px == 0.0:
    "0"
  else:
    formatNum(px) & "px"

proc isWidthProp*(prop: string): bool =
  ## `%` is allowed for widths only (R-CSS-13).
  prop in ["width", "min-width", "max-width"]

proc splitNumberUnit(s: string): tuple[num: string; unit: string] =
  ## Splits `"16px"` into `("16", "px")`, `"-1.5rem"` into
  ## `("-1.5", "rem")`, `"50%"` into `("50", "%")`. Letters and `%` after
  ## the numeric prefix form the unit; anything else is a bad value.
  var i = 0
  if i < s.len and s[i] in {'+', '-'}:
    inc i
  var digits = 0
  while i < s.len and (s[i] in {'0' .. '9'} or s[i] == '.'):
    if s[i] in {'0' .. '9'}:
      inc digits
    inc i
  if digits == 0:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & s & "' is not a length (R-CSS-13: px for " &
      "box properties, font-size and line-height; % for widths only)")
  result = (s[0 ..< i], s[i .. ^1].toLowerAscii())

proc computeToPx(value: string; fontSizePx: float; unit: string): float =
  ## `toPx`, parsed every time.
  let s = value.strip()
  let (numText, rawUnit) = splitNumberUnit(s)
  let effUnit = if rawUnit == "": unit.toLowerAscii() else: rawUnit
  var num: float
  try:
    num = parseFloat(numText)
  except ValueError:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value & "' is not a length (R-CSS-13)")
  case effUnit
  of "", "px":
    num
  of "rem":
    num * cssRootPx
  of "em":
    num * fontSizePx
  of "%":
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value & "' is a percentage, not a px " &
      "length (% is for widths only, R-CSS-13)")
  else:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: unknown length unit '" & effUnit & "' in '" &
      value & "' (R-CSS-13: px, rem, em)")

var toPxMemo {.threadvar.}: Table[string, float]
  ## `toPx` per value with the default font size and unit, as parsed
  ## once on this thread (`memo.nim`).
var widthLengthMemo {.threadvar.}: Table[string, string]
  ## `normaliseLength` per value with the default font size and unit,
  ## for a width property.
var lengthMemo {.threadvar.}: Table[string, string]
  ## The same for any other property.

const unitsMemoCap = 1024
  ## Answers each table of this module keeps before it is emptied.

proc toPx*(value: string; fontSizePx = cssRootPx; unit = ""): float =
  ## Converts a length literal to px: `px` as-is, `rem`/`em` against the
  ## 16px root (`em` against `fontSizePx` when given), unitless via the
  ## Tailwind extractor's unit record (`unit`, empty meaning px). `%` is rejected — percents
  ## are widths, handled by `normaliseLength`, never converted here.
  if fontSizePx == cssRootPx and unit.len == 0:
    memoised(toPxMemo, unitsMemoCap, value,
      computeToPx(value, fontSizePx, unit))
  else:
    computeToPx(value, fontSizePx, unit)

proc normalisePercent(value: string): string =
  ## Canonical percent: `"50%"`, `"12.5%"`.
  let s = value.strip()
  if not s.endsWith("%"):
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value & "' is not a percentage")
  let numText = s[0 ..< ^1].strip()
  var num: float
  try:
    num = parseFloat(numText)
  except ValueError:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value & "' is not a percentage")
  formatNum(num) & "%"

proc computeNormaliseLength(prop, value: string; fontSizePx: float;
                            unit: string): string =
  ## `normaliseLength`, parsed every time.
  let s = value.strip()
  if s.endsWith("%"):
    if not isWidthProp(prop):
      raise newException(StyleError,
        "E-VOCAB-BAD-VALUE: '" & value & "' on '" & prop &
        "' (% is for widths only, R-CSS-13)")
    return normalisePercent(s)
  formatPx(toPx(s, fontSizePx, unit))

proc normaliseLength*(prop, value: string; fontSizePx = cssRootPx;
                      unit = ""): string =
  ## Normalises one declaration value for `prop`: px lengths become
  ## canonical px, `%` survives only on width props, unitless numbers get
  ## px restored (the extractor's unit record arrives via `unit`). Units are
  ## case-insensitive on input, lowercase on output.
  ##
  ## The answer depends on `prop` only through `isWidthProp` (an error's
  ## message names `prop`, and an error is never kept).
  if fontSizePx == cssRootPx and unit.len == 0:
    if isWidthProp(prop):
      memoised(widthLengthMemo, unitsMemoCap, value,
        computeNormaliseLength(prop, value, fontSizePx, unit))
    else:
      memoised(lengthMemo, unitsMemoCap, value,
        computeNormaliseLength(prop, value, fontSizePx, unit))
  else:
    computeNormaliseLength(prop, value, fontSizePx, unit)

proc computeNormaliseLineHeight(value: string; fontSizePx: float): string =
  ## `normaliseLineHeight`, parsed every time.
  let s = value.strip().toLowerAscii()
  if s == "normal":
    return "normal"
  if s.endsWith("%"):
    let pct = s[0 ..< ^1].strip()
    var num: float
    try:
      num = parseFloat(pct)
    except ValueError:
      raise newException(StyleError,
        "E-VOCAB-BAD-VALUE: '" & value & "' is not a line-height (R-CSS-13)")
    return formatPx(num / 100.0 * fontSizePx)
  let (numText, rawUnit) = splitNumberUnit(value.strip())
  if rawUnit == "":
    var mult: float
    try:
      mult = parseFloat(numText)
    except ValueError:
      raise newException(StyleError,
        "E-VOCAB-BAD-VALUE: '" & value & "' is not a line-height (R-CSS-13)")
    if mult == 0.0:
      return "0"
    return formatPx(mult * fontSizePx)
  formatPx(toPx(value.strip(), fontSizePx))

var lineHeightMemo {.threadvar.}: Table[float, Table[string, string]]
  ## `normaliseLineHeight` per font size, then per value, as parsed once
  ## on this thread (`memo.nim`).

proc normaliseLineHeight*(value: string; fontSizePx: float): string =
  ## Unitless `line-height` becomes px against `fontSizePx` (Word needs
  ## px); px/`em`/`rem`/`%` values convert; `normal` passes through.
  when nimvm:
    computeNormaliseLineHeight(value, fontSizePx)
  else:
    if fontSizePx != fontSizePx:
      # A NaN size never equals itself as a key: not kept.
      return computeNormaliseLineHeight(value, fontSizePx)
    if fontSizePx notin lineHeightMemo:
      if lineHeightMemo.len >= unitsMemoCap:
        lineHeightMemo.clear()
      lineHeightMemo[fontSizePx] = initTable[string, string]()
    memoised(lineHeightMemo[fontSizePx], unitsMemoCap, value,
      computeNormaliseLineHeight(value, fontSizePx))
