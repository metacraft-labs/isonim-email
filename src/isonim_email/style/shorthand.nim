## isonim_email/style/shorthand.nim — shorthand expansion.
##
## - `background` splits into `background-color` plus the image-path
##   remainder (lowered by P5 — this module only splits);
## - `border` parses to width/style/colour (`Border`) and expands
##   to longhands where Outlook needs them (`td` keeps the shorthand);
## - `margin` parses with R-OL-04's shape (no negatives, no `auto`, only
##   `p`/`h1`–`h6`/`ul`/`ol` carry it); P5 owns the conversion of other
##   margins to cell padding with `W-LAYOUT-MARGIN-CONVERTED`, so this
##   module claims no rule for margins;
## - `Box` values (1–4 `Len`, CSS shorthand order) expand to 4 px sides;
## - the packed `type.*`/`button.font` theme encodings expand to
##   `font-size`/`line-height`/`font-weight` declarations.
##
## Pure `std` string work: identical on the C and JS targets.

import std/strutils
import ./units
import ./colors
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

export units
export colors

type
  Border* = object
    ## A parsed `border` shorthand (`Border`): px width, a
    ## style Outlook honours, and the colour.
    widthPx*: float
    style*: string
    color*: Rgba

  TypeSpec* = object
    ## A parsed `type.*`/`button.font` literal: px size and
    ## line-height, plus the weight (`""` when the literal has none).
    fontSize*: string
    lineHeight*: string
    weight*: string

proc expandBox*(value: string): array[4, string] =
  ## Expands 1–4 `Len` values in CSS shorthand order to
  ## `[top, right, bottom, left]`, each normalised px (`Box`
  ## canonicalises to 4 px ints; `%` is rejected).
  let parts = value.strip().splitWhitespace()
  if parts.len < 1 or parts.len > 4:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value & "' is not a Box (1-4 lengths)")
  var sides: array[4, string]
  try:
    case parts.len
    of 1:
      let all = normaliseLength("padding", parts[0])
      sides = [all, all, all, all]
    of 2:
      let vert = normaliseLength("padding", parts[0])
      let horiz = normaliseLength("padding", parts[1])
      sides = [vert, horiz, vert, horiz]
    of 3:
      sides = [normaliseLength("padding", parts[0]),
        normaliseLength("padding", parts[1]),
        normaliseLength("padding", parts[2]),
        normaliseLength("padding", parts[1])]
    else:
      sides = [normaliseLength("padding", parts[0]),
        normaliseLength("padding", parts[1]),
        normaliseLength("padding", parts[2]),
        normaliseLength("padding", parts[3])]
  except StyleError as e:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value & "' is not a Box: " & e.msg)
  sides

proc parseBorder*(value: string): Border =
  ## Parses `"1px solid #e5e7eb"` (tokens in any order) to width, style
  ## and colour. Styles outside `{solid, dashed, dotted}` are rejected:
  ## Word honours no others.
  let parts = value.strip().splitWhitespace()
  if parts.len != 3:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value &
      "' is not a Border (width style colour, e.g. '1px solid #e5e7eb')")
  var width = 0.0
  var hasWidth = false
  var style = ""
  var color = Rgba(r: 0, g: 0, b: 0, a: 1.0)
  var hasColor = false
  for part in parts:
    if part.toLowerAscii() in ["solid", "dashed", "dotted"]:
      if style != "":
        raise newException(StyleError,
          "E-VOCAB-BAD-VALUE: '" & value & "' has two border styles")
      style = part.toLowerAscii()
      continue
    var parsedWidth = false
    var w = 0.0
    try:
      w = toPx(part)
      parsedWidth = true
    except StyleError:
      discard
    if parsedWidth:
      if hasWidth:
        raise newException(StyleError,
          "E-VOCAB-BAD-VALUE: '" & value & "' has two border widths")
      if w < 0.0:
        raise newException(StyleError,
          "E-VOCAB-BAD-VALUE: '" & value & "' has a negative border width")
      width = w
      hasWidth = true
      continue
    try:
      color = parseColor(part)
      hasColor = true
    except StyleError:
      raise newException(StyleError,
        "E-VOCAB-BAD-VALUE: '" & part & "' in '" & value &
        "' is neither a width, a border style (solid, dashed, dotted) " &
        "nor a colour")
  if not hasWidth:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value & "' has no border width")
  if style == "":
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value &
      "' has no border style (solid, dashed, dotted)")
  if not hasColor:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value & "' has no border colour")
  Border(widthPx: width, style: style, color: color)

proc expandBorder*(b: Border): array[3, tuple[prop, value: string]] =
  ## Longhands for Outlook (`td` keeps the shorthand).
  [("border-width", formatPx(b.widthPx)), ("border-style", b.style),
    ("border-color", b.color.toHex())]

proc splitBackground*(value: string): tuple[color, rest: string] =
  ## Splits `background` into the colour (`background-color`, `""` when
  ## none) and the remainder (the background-image path, `""` when none).
  let s = value.strip()
  try:
    return (parseColor(s).toHex(), "")
  except StyleError:
    discard
  var rest: seq[string] = @[]
  var color = ""
  for tok in s.splitWhitespace():
    if color == "":
      try:
        color = parseColor(tok).toHex()
        continue
      except StyleError:
        discard
    rest.add(tok)
  (color, rest.join(" "))

proc isBlockTextElement*(tag: string): bool =
  ## The elements that may carry vertical margins (R-OL-04): `p`,
  ## `h1`–`h6`, `ul`/`ol`, and the text blocks whose defaults carry one
  ## (`li`, R-TXT-09; `blockquote`, `pre`, R-TXT-02). P5 converts every
  ## other margin into cell padding with `W-LAYOUT-MARGIN-CONVERTED`.
  tag in ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
    "blockquote", "pre"]

proc parseMargin*(value: string): array[4, string] =
  ## Margin sides with R-OL-04's shape: no negatives, no `auto`
  ## (Word supports neither).
  if "auto" in value.toLowerAscii().splitWhitespace():
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value &
      "' uses margin:auto, which Word does not support (R-OL-04)")
  let sides = expandBox(value)
  for side in sides:
    if side.startsWith("-"):
      raise newException(StyleError,
        "E-VOCAB-BAD-VALUE: '" & value &
        "' uses a negative margin, which Word does not support (R-OL-04)")
  sides

proc parseTypeSpec*(value: string): TypeSpec =
  ## Parses a packed `type.*`/`button.font` literal:
  ## `"size/line"` or `"size/line/weight"`. Size is px (unitless means
  ## px); line is px or a unitless multiplier of the size; weight is
  ## 100–900 or `normal`/`bold`.
  let parts = value.strip().split("/")
  if parts.len < 2 or parts.len > 3:
    raise newException(StyleError,
      "E-VOCAB-BAD-VALUE: '" & value &
      "' is not a type spec ('size/line' or 'size/line/weight')")
  let sizePx =
    try:
      toPx(parts[0].strip())
    except StyleError as e:
      raise newException(StyleError,
        "E-VOCAB-BAD-VALUE: bad font size in '" & value & "': " & e.msg)
  let fontSize = formatPx(sizePx)
  let lineText = parts[1].strip()
  let lineHeight =
    try:
      normaliseLineHeight(lineText, sizePx)
    except StyleError as e:
      raise newException(StyleError,
        "E-VOCAB-BAD-VALUE: bad line-height in '" & value & "': " & e.msg)
  var weight = ""
  if parts.len == 3:
    let w = parts[2].strip().toLowerAscii()
    if w in ["normal", "bold"]:
      weight = w
    else:
      try:
        let n = parseInt(w)
        if n < 100 or n > 900:
          raise newException(StyleError,
            "E-VOCAB-BAD-VALUE: bad font weight in '" & value &
            "' (100-900, or normal/bold)")
        weight = $n
      except ValueError:
        raise newException(StyleError,
          "E-VOCAB-BAD-VALUE: bad font weight in '" & value &
          "' (100-900, or normal/bold)")
  TypeSpec(fontSize: fontSize, lineHeight: lineHeight, weight: weight)

proc expandTypeSpec*(value: string): seq[tuple[prop, value: string]] =
  ## The declarations for a packed type literal: `font-size` and
  ## `line-height`, plus `font-weight` when the literal carries one.
  let spec = parseTypeSpec(value)
  result = @[("font-size", spec.fontSize),
    ("line-height", spec.lineHeight)]
  if spec.weight != "":
    result.add(("font-weight", spec.weight))
