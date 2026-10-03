## isonim_email/lower/background.nim — a band's background image.
##
## Reads the background props of a `mailSection`, `mailWrapper` or
## `mailHero` (`background_image`, `background_color`,
## `background_size`, `background_position`, `background_repeat`) into
## the two paths of catalogue R-VML-01:
##
## - **CSS** for every client but Word: `background-color`,
##   `background-image:url('{src}')`, `background-position`,
##   `background-size` and `background-repeat` on the element that
##   carries the band's own box and classes, longhands only (Yahoo and
##   AOL drop a `background` shorthand with a `/ size`, caniemail
##   css-background note 2);
## - **VML** for Word: the `v:fill` of the `v:rect` (`mso/vml.nim`),
##   whose `type`, `origin`, `position`, `size` and `aspect` follow
##   MJML 5's `mj-section` (read): a position becomes fractions of the
##   box, `cover`/`contain` keep the image's aspect (`atleast`/`atmost`),
##   and a repeating or `auto`-sized image is a tile.
##
## The **fallback colour** is the band's `background_color`, else the
## nearest enclosing background (the document's, white when it sets
## none): it is what shows behind the image, and instead of it when
## images are blocked, so text over the image is checked against it
## (P10, R-VML-01). VML's `src` is an absolute https URL (R-VML-04),
## checked by P8 before lowering.
##
## Values outside the vocabulary (`background_size`: `cover`, `contain`,
## `auto`, one or two px lengths; `background_position`: one or two of
## `left`/`center`/`right`/`top`/`bottom` or whole percentages;
## `background_repeat`: `no-repeat` or `repeat`) are
## `E-VOCAB-BAD-VALUE`.
##
## Pure (no IO): identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/colors
import ../style/units
import ../passes/layout

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const backgroundProps* = ["background-image", "background_image",
  "background-size", "background_size", "background-position",
  "background_position", "background-repeat", "background_repeat"]
  ## The props this module turns into markup; a band never copies them
  ## through as they were authored.

type
  VmlFill* = object
    ## The `v:fill` attributes (R-VML-01), as MJML writes them.
    kind*: string      ## `frame` or `tile`
    origin*: string    ## `x, y` fractions
    position*: string  ## `x, y` fractions
    size*: string      ## `1,1`, `{w}px`, `{w}px,{h}px`, or "" (none)
    aspect*: string    ## `atleast`, `atmost`, or "" (none)

  BandBackground* = object
    ## A band's background image, resolved; `src` is "" when the band
    ## has none.
    src*: string       ## The image URL, as P8 left it
    color*: string     ## The fallback colour, `#rrggbb`
    size*, position*, repeat*: string ## The CSS longhand values
    fill*: VmlFill

proc imageUrl*(value: string): string =
  ## A `background_image` value as a URL: `url(…)` and quotes taken off.
  result = value.strip()
  if result.toLowerAscii().startsWith("url(") and result.endsWith(")"):
    result = result[4 ..< ^1].strip()
  if result.len >= 2 and result[0] in {'\'', '"'} and result[^1] == result[0]:
    result = result[1 ..< ^1]

proc backgroundImageOf*(node: EmailNode): string =
  ## The band's background image URL, "" when it has none.
  imageUrl(rawValue(node, "background-image"))

proc fallbackColour*(node: EmailNode): string =
  ## The band's own background colour, else the nearest enclosing
  ## element's (the document's included), else white.
  var n = node
  while n != nil:
    if n.kind == enElement:
      let v = rawValue(n, "background-color")
      if v.len > 0 and not v.startsWith("tok:"):
        try:
          return normaliseColor(v)
        except StyleError:
          discard
    n = n.parent
  "#ffffff"

proc badValue(node: EmailNode; prop, value, expected: string):
    EmailDiagnostic =
  EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
    message: node.tag & " " & prop & " '" & value & "' is not " & expected &
      " (R-VML-01)", origin: node.origin, rules: @["R-VML-01"])

proc axisPercent(word: string; horizontal: bool): int =
  ## A position keyword or whole percentage along one axis; -1 when it
  ## is neither (or names the other axis).
  case word
  of "left": (if horizontal: 0 else: -1)
  of "right": (if horizontal: 100 else: -1)
  of "top": (if horizontal: -1 else: 0)
  of "bottom": (if horizontal: -1 else: 100)
  of "center": 50
  else:
    if word.endsWith("%"):
      try:
        let v = parseInt(word[0 ..< ^1])
        if v in 0 .. 100: v else: -1
      except ValueError:
        -1
    else:
      -1

proc parsePosition(value: string): tuple[x, y: int; ok: bool] =
  ## `background-position` as (x %, y %), read as MJML reads it: one
  ## value names one axis (`top`/`bottom` the vertical one) and centres
  ## the other; two values are `x y`, or `y x` when the first is
  ## vertical (`top left`).
  let parts = value.toLowerAscii().splitWhitespace()
  if parts.len == 1:
    let v = parts[0]
    if v in ["top", "bottom"]:
      return (50, axisPercent(v, false), true)
    let x = axisPercent(v, true)
    return (x, 50, x >= 0)
  if parts.len == 2:
    var (a, b) = (parts[0], parts[1])
    if a in ["top", "bottom"] or (a == "center" and b in ["left", "right"]):
      swap(a, b)
    let x = axisPercent(a, true)
    let y = axisPercent(b, false)
    return (x, y, x >= 0 and y >= 0)
  (0, 0, false)

proc vmlFraction(v: float): string =
  ## A VML fraction as MJML writes it (`0`, `0.5`, `-0.5`).
  result = formatFloat(v, ffDecimal, 4)
  if '.' in result:
    result = result.strip(leading = false, chars = {'0'})
    result = result.strip(leading = false, chars = {'.'})
  if result == "-0":
    result = "0"

proc readBackground*(node: EmailNode;
    diags: var seq[EmailDiagnostic]): BandBackground =
  ## The band's background, with `E-VOCAB-BAD-VALUE` for a value outside
  ## the vocabulary (the default is used instead).
  result.src = backgroundImageOf(node)
  result.color = fallbackColour(node)
  if result.src.len == 0:
    return
  # Size.
  var size = rawValue(node, "background-size").toLowerAscii()
  if size.len == 0:
    size = "cover"
  var sizePx: seq[string] = @[]
  if size notin ["cover", "contain", "auto"]:
    for part in size.splitWhitespace():
      try:
        if not part.endsWith("px"):
          raise newException(StyleError, "not px")
        sizePx.add(formatPx(toPx(normaliseLength("width", part))))
      except StyleError, ValueError:
        sizePx = @[]
        break
    if sizePx.len notin 1 .. 2:
      diags.add(badValue(node, "background_size", size,
        "cover, contain, auto or one or two px lengths"))
      size = "cover"
      sizePx = @[]
    else:
      size = sizePx.join(" ")
  # Position.
  var position = rawValue(node, "background-position").toLowerAscii()
  if position.len == 0:
    position = "center center"
  var pos = parsePosition(position)
  if not pos.ok:
    diags.add(badValue(node, "background_position", position,
      "one or two of left, center, right, top, bottom or whole percentages"))
    position = "center center"
    pos = (50, 50, true)
  # Repeat.
  var repeat = rawValue(node, "background-repeat").toLowerAscii()
  if repeat.len == 0:
    repeat = "no-repeat"
  if repeat notin ["no-repeat", "repeat"]:
    diags.add(badValue(node, "background_repeat", repeat,
      "no-repeat or repeat"))
    repeat = "no-repeat"
  result.size = size
  result.position = position
  result.repeat = repeat
  # VML, after MJML's `renderWithBackground`: a repeating image is
  # placed by its top-left corner, a framed one by its centre.
  var fill = VmlFill(kind: if repeat == "repeat": "tile" else: "frame")
  var fx, fy: float
  if repeat == "repeat":
    fx = float(pos.x) / 100.0
    fy = float(pos.y) / 100.0
  else:
    fx = float(pos.x - 50) / 100.0
    fy = float(pos.y - 50) / 100.0
  case size
  of "cover", "contain":
    fill.size = "1,1"
    fill.aspect = if size == "cover": "atleast" else: "atmost"
  of "auto":
    # Word cannot place an image at its own size in a frame, so an
    # `auto` image is a tile, placed as MJML places it.
    fill.kind = "tile"
    fx = 0.5
    fy = 0.0
  else:
    if sizePx.len == 1:
      fill.size = sizePx[0]
      fill.aspect = "atmost"
    else:
      fill.size = sizePx.join(",")
  fill.origin = vmlFraction(fx) & ", " & vmlFraction(fy)
  fill.position = fill.origin
  result.fill = fill

proc cssDeclarations*(bg: BandBackground): seq[(string, string)] =
  ## The CSS path (R-VML-01): the colour, then the image's longhands.
  if bg.src.len == 0:
    return
  @[("background-color", bg.color),
    ("background-image", "url('" & bg.src & "')"),
    ("background-position", bg.position),
    ("background-size", bg.size),
    ("background-repeat", bg.repeat)]

proc hasBackgroundProps*(node: EmailNode): bool =
  for k in backgroundProps:
    if k in node.styles or k in node.attrs:
      return true
  false

proc dropBackgroundProps*(node: EmailNode) =
  ## Removes the authored background props (their markup is written by
  ## the lowering), so a carry-over never copies them as authored.
  for k in backgroundProps:
    node.styles.del(k)
    node.attrs.del(k)
