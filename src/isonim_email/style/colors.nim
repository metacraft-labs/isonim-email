## isonim_email/style/colors.nim — colour normalisation.
##
## Colours are 6-digit lowercase hex in output (R-CSS-12); `#rgb`, `#rgba`,
## `#rrggbbaa`, comma-form `rgb()`/`rgba()`/`hsl()`/`hsla()`, `oklch()`
## and named colours are converted. Whitespace-separated functional syntax
## (`rgb(0 0 0)`) is rejected — Gmail drops it, so authors write hex or
## comma-form `rgba()` instead (R-CSS-06). `oklch()` keeps its standard
## space-separated input form (it has no comma form) and is always
## converted to hex, never emitted.
##
## Alpha becomes an opaque blend against the resolved background emitted
## first, followed by `rgba()` for the clients that support it
## (`color:#7f7f7f;color:rgba(0,0,0,.5)`, R-CSS-14).
##
## Pure `std` string work: identical on the C and JS targets.

import std/[math, strutils]
import ./units
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

export units

type Rgba* = object
  ## A parsed colour: 8-bit channels plus alpha 0..1 (1 = opaque).
  r*, g*, b*: int
  a*: float

const cssNamedColors* = [
  ("aliceblue", "#f0f8ff"), ("antiquewhite", "#faebd7"),
  ("aqua", "#00ffff"), ("aquamarine", "#7fffd4"), ("azure", "#f0ffff"),
  ("beige", "#f5f5dc"), ("bisque", "#ffe4c4"), ("black", "#000000"),
  ("blanchedalmond", "#ffebcd"), ("blue", "#0000ff"),
  ("blueviolet", "#8a2be2"), ("brown", "#a52a2a"),
  ("burlywood", "#deb887"), ("cadetblue", "#5f9ea0"),
  ("chartreuse", "#7fff00"), ("chocolate", "#d2691e"),
  ("coral", "#ff7f50"), ("cornflowerblue", "#6495ed"),
  ("cornsilk", "#fff8dc"), ("crimson", "#dc143c"), ("cyan", "#00ffff"),
  ("darkblue", "#00008b"), ("darkcyan", "#008b8b"),
  ("darkgoldenrod", "#b8860b"), ("darkgray", "#a9a9a9"),
  ("darkgreen", "#006400"), ("darkgrey", "#a9a9a9"),
  ("darkkhaki", "#bdb76b"), ("darkmagenta", "#8b008b"),
  ("darkolivegreen", "#556b2f"), ("darkorange", "#ff8c00"),
  ("darkorchid", "#9932cc"), ("darkred", "#8b0000"),
  ("darksalmon", "#e9967a"), ("darkseagreen", "#8fbc8f"),
  ("darkslateblue", "#483d8b"), ("darkslategray", "#2f4f4f"),
  ("darkslategrey", "#2f4f4f"), ("darkturquoise", "#00ced1"),
  ("darkviolet", "#9400d3"), ("deeppink", "#ff1493"),
  ("deepskyblue", "#00bfff"), ("dimgray", "#696969"),
  ("dimgrey", "#696969"), ("dodgerblue", "#1e90ff"),
  ("firebrick", "#b22222"), ("floralwhite", "#fffaf0"),
  ("forestgreen", "#228b22"), ("fuchsia", "#ff00ff"),
  ("gainsboro", "#dcdcdc"), ("ghostwhite", "#f8f8ff"),
  ("gold", "#ffd700"), ("goldenrod", "#daa520"), ("gray", "#808080"),
  ("green", "#008000"), ("greenyellow", "#adff2f"),
  ("grey", "#808080"), ("honeydew", "#f0fff0"),
  ("hotpink", "#ff69b4"), ("indianred", "#cd5c5c"),
  ("indigo", "#4b0082"), ("ivory", "#fffff0"), ("khaki", "#f0e68c"),
  ("lavender", "#e6e6fa"), ("lavenderblush", "#fff0f5"),
  ("lawngreen", "#7cfc00"), ("lemonchiffon", "#fffacd"),
  ("lightblue", "#add8e6"), ("lightcoral", "#f08080"),
  ("lightcyan", "#e0ffff"), ("lightgoldenrodyellow", "#fafad2"),
  ("lightgray", "#d3d3d3"), ("lightgreen", "#90ee90"),
  ("lightgrey", "#d3d3d3"), ("lightpink", "#ffb6c1"),
  ("lightsalmon", "#ffa07a"), ("lightseagreen", "#20b2aa"),
  ("lightskyblue", "#87cefa"), ("lightslategray", "#778899"),
  ("lightslategrey", "#778899"), ("lightsteelblue", "#b0c4de"),
  ("lightyellow", "#ffffe0"), ("lime", "#00ff00"),
  ("limegreen", "#32cd32"), ("linen", "#faf0e6"),
  ("magenta", "#ff00ff"), ("maroon", "#800000"),
  ("mediumaquamarine", "#66cdaa"), ("mediumblue", "#0000cd"),
  ("mediumorchid", "#ba55d3"), ("mediumpurple", "#9370db"),
  ("mediumseagreen", "#3cb371"), ("mediumslateblue", "#7b68ee"),
  ("mediumspringgreen", "#00fa9a"), ("mediumturquoise", "#48d1cc"),
  ("mediumvioletred", "#c71585"), ("midnightblue", "#191970"),
  ("mintcream", "#f5fffa"), ("mistyrose", "#ffe4e1"),
  ("moccasin", "#ffe4b5"), ("navajowhite", "#ffdead"),
  ("navy", "#000080"), ("oldlace", "#fdf5e6"), ("olive", "#808000"),
  ("olivedrab", "#6b8e23"), ("orange", "#ffa500"),
  ("orangered", "#ff4500"), ("orchid", "#da70d6"),
  ("palegoldenrod", "#eee8aa"), ("palegreen", "#98fb98"),
  ("paleturquoise", "#afeeee"), ("palevioletred", "#db7093"),
  ("papayawhip", "#ffefd5"), ("peachpuff", "#ffdab9"),
  ("peru", "#cd853f"), ("pink", "#ffc0cb"), ("plum", "#dda0dd"),
  ("powderblue", "#b0e0e6"), ("purple", "#800080"),
  ("rebeccapurple", "#663399"), ("red", "#ff0000"),
  ("rosybrown", "#bc8f8f"), ("royalblue", "#4169e1"),
  ("saddlebrown", "#8b4513"), ("salmon", "#fa8072"),
  ("sandybrown", "#f4a460"), ("seagreen", "#2e8b57"),
  ("seashell", "#fff5ee"), ("sienna", "#a0522d"),
  ("silver", "#c0c0c0"), ("skyblue", "#87ceeb"),
  ("slateblue", "#6a5acd"), ("slategray", "#708090"),
  ("slategrey", "#708090"), ("snow", "#fffafa"),
  ("springgreen", "#00ff7f"), ("steelblue", "#4682b4"),
  ("tan", "#d2b48c"), ("teal", "#008080"), ("thistle", "#d8bfd8"),
  ("tomato", "#ff6347"), ("turquoise", "#40e0d0"),
  ("violet", "#ee82ee"), ("wheat", "#f5deb3"), ("white", "#ffffff"),
  ("whitesmoke", "#f5f5f5"), ("yellow", "#ffff00"),
  ("yellowgreen", "#9acd32"),
]
  ## The CSS named colours (CSS Color 4, `transparent` excluded — it
  ## carries alpha and is handled as a special case).

proc badColor(value, why: string): ref StyleError =
  newException(StyleError,
    "E-VOCAB-BAD-VALUE: '" & value & "' is not a colour: " & why)

proc lookupNamed(name: string): string =
  ## The hex for a named colour, or `""` when unknown.
  let lower = name.toLowerAscii()
  if lower == "transparent":
    return "transparent"
  for (n, hex) in cssNamedColors:
    if n == lower:
      return hex
  ""

proc hexDigit(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'f': ord(c) - ord('a') + 10
  of 'A' .. 'F': ord(c) - ord('A') + 10
  else: -1

proc parseHexColor(value: string): Rgba =
  ## `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` (case-insensitive).
  let h = value[1 .. ^1]
  var digits: seq[int] = @[]
  for c in h:
    let d = hexDigit(c)
    if d < 0:
      raise badColor(value, "bad hex digit '" & $c & "'")
    digits.add(d)
  case digits.len
  of 3:
    Rgba(r: digits[0] * 17, g: digits[1] * 17, b: digits[2] * 17, a: 1.0)
  of 4:
    Rgba(r: digits[0] * 17, g: digits[1] * 17, b: digits[2] * 17,
      a: digits[3] * 17 / 255)
  of 6:
    Rgba(r: digits[0] * 16 + digits[1], g: digits[2] * 16 + digits[3],
      b: digits[4] * 16 + digits[5], a: 1.0)
  of 8:
    Rgba(r: digits[0] * 16 + digits[1], g: digits[2] * 16 + digits[3],
      b: digits[4] * 16 + digits[5],
      a: (digits[6] * 16 + digits[7]) / 255)
  else:
    raise badColor(value, "hex colours are #rgb, #rgba, #rrggbb or #rrggbbaa")

proc parseChannel(text, value: string): int =
  ## One `rgb()` channel: `0`–`255` or `0%`–`100%`.
  let t = text.strip()
  try:
    if t.endsWith("%"):
      let pct = parseFloat(t[0 ..< ^1].strip())
      if pct < 0.0 or pct > 100.0:
        raise badColor(value, "channel '" & text & "' out of range")
      result = round(pct / 100.0 * 255.0).int
    else:
      let n = parseFloat(t)
      if n < 0.0 or n > 255.0:
        raise badColor(value, "channel '" & text & "' out of range")
      result = round(n).int
  except ValueError:
    raise badColor(value, "channel '" & text & "' is not a number")

proc parseAlpha(text, value: string): float =
  ## One alpha: `0`–`1` or `0%`–`100%`, clamped into range.
  let t = text.strip()
  try:
    result = if t.endsWith("%"):
      parseFloat(t[0 ..< ^1].strip()) / 100.0
    else:
      parseFloat(t)
  except ValueError:
    raise badColor(value, "alpha '" & text & "' is not a number")
  if result < 0.0 or result > 1.0:
    raise badColor(value, "alpha '" & text & "' out of range")

proc splitArgs(inner, value: string): seq[string] =
  ## Splits a comma-separated function body. A body without commas is
  ## the whitespace-separated syntax Gmail drops (R-CSS-06).
  if "," notin inner:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value &
      "' uses whitespace-separated colour syntax, which Gmail drops " &
      "(R-CSS-06); use hex, or comma-form rgba(0,0,0,.5)")
  inner.split(",")

proc hslToRgb(h, s, l: float): tuple[r, g, b: int] =
  ## Standard HSL→sRGB conversion; `h` in degrees, `s`/`l` in 0..1.
  let hh = floorMod(h, 360.0) / 60.0
  let c = (1.0 - abs(2.0 * l - 1.0)) * s
  let x = c * (1.0 - abs(floorMod(hh, 2.0) - 1.0))
  var r1, g1, b1: float
  if hh < 1.0: (r1, g1, b1) = (c, x, 0.0)
  elif hh < 2.0: (r1, g1, b1) = (x, c, 0.0)
  elif hh < 3.0: (r1, g1, b1) = (0.0, c, x)
  elif hh < 4.0: (r1, g1, b1) = (0.0, x, c)
  elif hh < 5.0: (r1, g1, b1) = (x, 0.0, c)
  else: (r1, g1, b1) = (c, 0.0, x)
  let m = l - c / 2.0
  (round((r1 + m) * 255.0).int, round((g1 + m) * 255.0).int,
    round((b1 + m) * 255.0).int)

proc parseHsl(inner, value: string; withAlpha: bool): Rgba =
  let args = splitArgs(inner, value)
  if args.len != (if withAlpha: 4 else: 3):
    raise badColor(value, "hsl() takes 3 comma-separated components" &
      (if withAlpha: " plus alpha" else: ""))
  var h: float
  try:
    h = parseFloat(args[0].strip())
  except ValueError:
    raise badColor(value, "hue '" & args[0].strip() & "' is not a number")
  for pair in [(1, "saturation"), (2, "lightness")]:
    let (i, name) = pair
    if not args[i].strip().endsWith("%"):
      raise badColor(value, name & " '" & args[i].strip() &
        "' must be a percentage")
  var s, l: float
  try:
    s = parseFloat(args[1].strip()[0 ..< ^1].strip()) / 100.0
    l = parseFloat(args[2].strip()[0 ..< ^1].strip()) / 100.0
  except ValueError:
    raise badColor(value, "saturation/lightness is not a percentage")
  if s < 0.0 or s > 1.0 or l < 0.0 or l > 1.0:
    raise badColor(value, "saturation/lightness out of range")
  let (r, g, b) = hslToRgb(h, s, l)
  let a = if withAlpha: parseAlpha(args[3], value) else: 1.0
  Rgba(r: r, g: g, b: b, a: a)

proc oklchToRgb(l, c, hDeg: float): tuple[r, g, b: int] =
  ## OKLCH→sRGB (Björn Ottosson's OKLab matrices); out-of-gamut
  ## channels clamp. `l` in 0..1, `c` ≥ 0, hue in degrees.
  let hRad = floorMod(hDeg, 360.0) * PI / 180.0
  let a = c * cos(hRad)
  let b = c * sin(hRad)
  let lCone = l + 0.3963377774 * a + 0.2158037573 * b
  let mCone = l - 0.1055613458 * a - 0.0638541728 * b
  let sCone = l - 0.0894841775 * a - 1.2914855480 * b
  let l2 = lCone * lCone * lCone
  let m2 = mCone * mCone * mCone
  let s2 = sCone * sCone * sCone
  let rLin = 4.0767416621 * l2 - 3.3077115913 * m2 + 0.2309699292 * s2
  let gLin = -1.2684380046 * l2 + 2.6097574011 * m2 - 0.3413193965 * s2
  let bLin = -0.0041960863 * l2 - 0.7034186147 * m2 + 1.7076147010 * s2
  proc gamma(u: float): int =
    let v = if u <= 0.0031308: 12.92 * u
      else: 1.055 * pow(max(u, 0.0), 1.0 / 2.4) - 0.055
    round(clamp(v, 0.0, 1.0) * 255.0).int
  (gamma(rLin), gamma(gLin), gamma(bLin))

proc parseOklch(inner, value: string): Rgba =
  ## `oklch(l c h [/ alpha])`: the standard space-separated form (it has
  ## no comma form), always converted to sRGB, never emitted (R-CSS-06
  ## governs emitted values, which are hex or comma-form `rgba()`).
  var body = inner.strip()
  var alpha = 1.0
  let slash = body.rfind('/')
  if slash >= 0:
    alpha = parseAlpha(body[slash + 1 .. ^1], value)
    body = body[0 ..< slash].strip()
  if "," in body:
    raise badColor(value, "oklch() is space-separated: oklch(l c h / alpha)")
  let parts = body.splitWhitespace()
  if parts.len != 3:
    raise badColor(value, "oklch() takes lightness, chroma and hue")
  var l: float
  try:
    if parts[0].endsWith("%"):
      l = parseFloat(parts[0][0 ..< ^1].strip()) / 100.0
    else:
      l = parseFloat(parts[0])
  except ValueError:
    raise badColor(value, "lightness '" & parts[0] & "' is not a number")
  var c, h: float
  try:
    c = parseFloat(parts[1])
    let hText = parts[2].strip()
    h = parseFloat(if hText.endsWith("deg"): hText[0 ..< ^3].strip()
      else: hText)
  except ValueError:
    raise badColor(value, "chroma/hue is not a number")
  if l < 0.0 or l > 1.0 or c < 0.0:
    raise badColor(value, "lightness/chroma out of range")
  let (r, g, b) = oklchToRgb(l, c, h)
  Rgba(r: r, g: g, b: b, a: alpha)

proc parseColor*(value: string): Rgba =
  ## Parses any accepted colour (`Color`): `#rgb`, `#rgba`,
  ## `#rrggbb`, `#rrggbbaa`, comma-form `rgb()`/`rgba()`/`hsl()`/`hsla()`,
  ## `oklch()`, named colours and `transparent`. Anything else —
  ## including whitespace-separated `rgb()` (R-CSS-06) and `var()` —
  ## is `E-VOCAB-BAD-VALUE`.
  let s = value.strip()
  if s.len == 0:
    raise badColor(value, "empty value")
  if s[0] == '#':
    return parseHexColor(s)
  let lower = s.toLowerAscii()
  if lower == "transparent":
    return Rgba(r: 0, g: 0, b: 0, a: 0.0)
  for fn in ["rgba(", "rgb(", "hsla(", "hsl(", "oklch("]:
    if lower.startsWith(fn) and s.endsWith(")"):
      let inner = s[fn.len ..< ^1]
      case fn
      of "rgba(", "rgb(":
        let args = splitArgs(inner, value)
        let want = if fn == "rgba(": 4 else: 3
        if args.len != want:
          raise badColor(value, fn[0 ..< ^1] & "() takes " & $want &
            " comma-separated components")
        let a = if fn == "rgba(": parseAlpha(args[3], value) else: 1.0
        return Rgba(r: parseChannel(args[0], value),
          g: parseChannel(args[1], value), b: parseChannel(args[2], value),
          a: a)
      of "hsla(", "hsl(":
        return parseHsl(inner, value, fn == "hsla(")
      else:
        return parseOklch(inner, value)
  let named = lookupNamed(s)
  if named == "transparent":
    return Rgba(r: 0, g: 0, b: 0, a: 0.0)
  if named != "":
    return parseHexColor(named)
  if lower.startsWith("var("):
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value &
      "' is a CSS custom property reference; email resolves every " &
      "token to a literal at render time (R-CSS-11)")
  raise badColor(value, "expected #hex, rgb()/rgba(), hsl()/hsla(), " &
    "oklch() or a named colour")

proc toHex*(c: Rgba): string =
  ## 6-digit lowercase hex (R-CSS-12). Translucent colours have no hex
  ## form — blend them over the background first (R-CSS-14).
  if c.a < 1.0:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: a translucent colour has no hex form; blend " &
      "it against the resolved background and emit blend-then-rgba " &
      "(R-CSS-14)")
  "#" & toHex(c.r, 2).toLowerAscii() & toHex(c.g, 2).toLowerAscii() &
    toHex(c.b, 2).toLowerAscii()

proc normaliseColor*(value: string): string =
  ## Opaque colours become 6-digit lowercase hex (R-CSS-12).
  ## Translucent ones raise — see `emitColorDecls`.
  parseColor(value).toHex()

proc blendOver*(fg, bg: Rgba): Rgba =
  ## Alpha-composites `fg` over an opaque `bg`. Channels truncate, which
  ## matches R-CSS-14's example (`rgba(0,0,0,.5)` over white is
  ## `#7f7f7f`, not `#808080`).
  if bg.a < 1.0:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: cannot blend over a translucent background")
  let t = fg.a
  Rgba(r: clamp((fg.r.float * t + bg.r.float * (1.0 - t)).int, 0, 255),
    g: clamp((fg.g.float * t + bg.g.float * (1.0 - t)).int, 0, 255),
    b: clamp((fg.b.float * t + bg.b.float * (1.0 - t)).int, 0, 255),
    a: 1.0)

proc formatAlpha*(a: float): string =
  ## Canonical alpha for `rgba()`: `"0"`, `"1"`, else the fraction
  ## without the leading zero (`".5"`, as R-CSS-14 writes it).
  if a <= 0.0:
    "0"
  elif a >= 1.0:
    "1"
  else:
    var t = formatNum(a)
    if t.startsWith("0."):
      t = t[1 .. ^1]
    t

proc toRgba*(c: Rgba): string =
  ## Comma-form `rgba()` (R-CSS-06): `rgba(0,0,0,.5)`.
  "rgba(" & $c.r & "," & $c.g & "," & $c.b & "," & formatAlpha(c.a) & ")"

proc emitColorDecls*(prop, value, background: string):
    seq[tuple[prop, value: string]] =
  ## The declarations for a colour-valued property: opaque colours emit
  ## one hex declaration; translucent ones emit the opaque blend against
  ## the resolved `background` first, then `rgba()` (R-CSS-14). The two
  ## share one property name, so the serialiser's sort must be stable.
  let fg = parseColor(value)
  if fg.a >= 1.0:
    return @[(prop, fg.toHex())]
  let bg = parseColor(background)
  @[(prop, fg.blendOver(bg).toHex()), (prop, fg.toRgba())]

proc rgbToOklch*(c: Rgba): tuple[l, c, h: float] =
  ## sRGB→OKLCH (Björn Ottosson's OKLab matrices, the inverse of the
  ## `oklch()` parser's conversion): lightness 0..1, chroma, hue in
  ## degrees. Alpha is ignored.
  proc linear(v: int): float =
    let u = float(v) / 255.0
    if u <= 0.04045: u / 12.92 else: pow((u + 0.055) / 1.055, 2.4)
  let r = linear(c.r)
  let g = linear(c.g)
  let b = linear(c.b)
  let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  let lab = (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
  let chroma = sqrt(lab[1] * lab[1] + lab[2] * lab[2])
  var hue = arctan2(lab[2], lab[1]) * 180.0 / PI
  if hue < 0.0:
    hue += 360.0
  (lab[0], chroma, hue)

const colourStep* = 0.1
  ## One step of lightness, in OKLCH L: the same 0.1 that tells two
  ## adjacent bands apart.

proc darkerStep*(value: string; step = colourStep): string =
  ## `value` one step darker (OKLCH lightness less `step`, chroma and hue
  ## kept), as 6-digit hex: the border a shadowed box gets (R-TBL-09).
  let (l, ch, h) = rgbToOklch(parseColor(value))
  let (r, g, b) = oklchToRgb(max(0.0, l - step), ch, h)
  Rgba(r: r, g: g, b: b, a: 1.0).toHex()

const shadowSurface* = "#ffffff"
  ## The surface a shadowed box without a background of its own is taken
  ## to sit on, for its border (the default theme's surface, R-TBL-09).

proc shadowBorderColour*(background: string): string =
  ## R-TBL-09: the colour of the border a shadowed box without one of
  ## its own gets, one step darker than its background (`shadowSurface`
  ## when it has none).
  darkerStep(if background.len > 0: background else: shadowSurface)

proc invertLightness*(c: Rgba): Rgba =
  ## `c` with its OKLCH lightness inverted (L → 1 − L), chroma and hue
  ## kept, opaque: R-DRK-04's model of how a client that recolours a
  ## message turns a colour around.
  let (l, ch, h) = rgbToOklch(c)
  let (r, g, b) = oklchToRgb(clamp(1.0 - l, 0.0, 1.0), ch, h)
  Rgba(r: r, g: g, b: b, a: 1.0)
