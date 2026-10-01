## isonim_email/lower/image.nim — `mailImage` lowering.
##
## Emits the catalogue's fixed-size image (R-IMG-01): an `img` with
## `src`, `alt`, the px `width` attribute (always, for DPI scaling and
## Word), the `height` attribute only when the author gave one, and
## the inline stack
## `display:block;{margin}border:0;outline:none;text-decoration:none;height:auto;width:{w}px;max-width:100%;-ms-interpolation-mode:bicubic;`
## The width is the px width capped by `max-width:100%`, never
## `width:100%` capped by a px `max-width`: Thunderbird's `shrinktofit`
## message stylesheet replaces an author `max-width` with `!important`,
## which let a `width:100%` image fill the column. `{margin}` places the
## block by the alignment it inherits (`inheritedAlign`): `margin:0
## auto;` when centred, `margin:0 0 0 auto;` when right-aligned,
## nothing when left-aligned, because `align`/`text-align` move inline
## content only and engines without the legacy `align` quirk
## (litehtml) left a centred image at the left edge.
## The stack is
## followed by the alt-text styling of R-IMG-03 (body font, small type
## size and line height, secondary text colour from the theme), so the
## alt stays readable when images are blocked. `display:block` is what
## removes the gap under the image (R-IMG-02). A linked image wraps the
## `img` in `<a href target="_blank" style="display:block;">` with
## nothing between them (R-IMG-10).
##
## The width comes from the element (P5-normalised `width` style or a
## plain `width` attribute), else from the published asset's intrinsic
## size, halved for `@2x` assets (R-IMG-05). A width that is still
## unknown is an error (`E-LAYOUT-IMAGE-WIDTH`): a fixed-size image
## without a px width attribute is exactly what R-IMG-01 forbids.
##
## Props whose lowering does not exist yet — `dark_src` (R-IMG-06, two
## images swapped by the dark block), `fluid_on_mobile` and
## percentage widths (R-IMG-09, R-IMG-11: the fluid split) and an
## explicit `align` — are reported as `E-LOWER-MISSING` rather than
## dropped: the image still lowers, but the error blocks sending.
##
## The `img` is P5-final: P5 has already run over the authoring
## element, so the literals written here are what the serialiser
## emits. Author classes (including the ones P6 generated for variant
## declarations) and any other resolved declaration carry over after
## the canonical stack.
##
## Pure tree building: identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
import ../diagnostics
import ../assets
import ../style/tokens
import ../style/units
import ../target
from ./document import contentCellAlign

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const consumedStyles = ["width", "height", "border_radius",
  "border-radius"]
  ## Declarations the lowering itself turns into attributes or the
  ## canonical stack; every other resolved declaration carries over.

proc pxNumber(value: string): tuple[ok: bool; px: string] =
  ## `120px` / `120` → (true, "120"); anything else (a percentage,
  ## an unparseable size, empty) → (false, "").
  let s = value.strip().toLowerAscii()
  if s.len == 0 or s.endsWith("%"):
    return (false, "")
  let num = if s.endsWith("px"): s[0 ..< ^2].strip() else: s
  try:
    let f = parseFloat(num)
    if f <= 0:
      return (false, "")
    (true, formatNum(f))
  except ValueError:
    (false, "")

proc declared(node: EmailNode; prop: string): string =
  ## The element's own value for `prop`: the resolved style first,
  ## then a plain attribute (hand-built trees).
  if prop in node.styles:
    return node.styles[prop]
  node.attrs.getOrDefault(prop, "")

proc intrinsicWidth(src: string; assets: openArray[AssetRef]): int =
  ## The rendered width a published asset implies: its intrinsic
  ## width, halved for `@2x` assets (R-IMG-05). 0 when `src` is not a
  ## published asset or its size is unknown.
  for a in assets:
    if a.url.len > 0 and a.url == src and a.width > 0:
      if "@2x" in a.name:
        return a.width div 2
      return a.width
  0

proc inheritedAlign*(node: EmailNode): string =
  ## The horizontal alignment `node` inherits: the nearest ancestor's
  ## `text-align` style or `align` attribute (`left`, `center` or
  ## `right`; a `table`'s `align` places the table, not its content, so
  ## it is skipped), else the skeleton's content cell (`center`).
  const aligns = ["left", "center", "right"]
  var p = if node == nil: nil else: node.parent
  while p != nil:
    if p.kind == enElement:
      let ta = p.styles.getOrDefault("text-align", "").strip().toLowerAscii()
      if ta in aligns:
        return ta
      if p.tag.toLowerAscii() notin ["table", "img"]:
        let a = p.attrs.getOrDefault("align", "").strip().toLowerAscii()
        if a in aligns:
          return a
    p = p.parent
  contentCellAlign

proc lowerMissing(node: EmailNode; what, rule: string): EmailDiagnostic =
  EmailDiagnostic(severity: sevError, code: codeLowerMissing,
    message: "mailImage " & what & " has no lowering yet (" & rule &
      "); it is reported, never dropped silently",
    origin: node.origin, rules: @[rule])

proc lowerImage*(node: EmailNode; theme: EmailTheme;
    assets: openArray[AssetRef]):
    tuple[node: EmailNode; diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one `mailImage` element to `img` (or `a > img` when it
  ## has an `href`). The authoring element is left untouched; the
  ## caller swaps the returned node into the lowered tree.
  let r = EmailRenderer()
  var diags: seq[EmailDiagnostic] = @[]
  let src = node.attrs.getOrDefault("src", "")

  var width = ""
  let given = declared(node, "width")
  if given.len > 0:
    let (ok, px) = pxNumber(given)
    if ok:
      width = px
    elif given.strip().endsWith("%"):
      diags.add(lowerMissing(node, "percentage width '" & given & "'",
        "R-IMG-11"))
    else:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue,
        message: "mailImage width '" & given & "' is not a px length",
        origin: node.origin, rules: @["R-IMG-01"]))
  if width.len == 0 and given.len == 0:
    let w = intrinsicWidth(src, assets)
    if w > 0:
      width = $w
    else:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeLayoutImageWidth,
        message: "mailImage '" & src & "' has no width and no known " &
          "intrinsic size: give it a px width (R-IMG-01)",
        origin: node.origin, rules: @["R-IMG-01"]))
  var height = ""
  let givenH = declared(node, "height")
  if givenH.len > 0 and givenH.strip().toLowerAscii() != "auto":
    let (ok, px) = pxNumber(givenH)
    if ok:
      height = px
    else:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue,
        message: "mailImage height '" & givenH & "' is not a px length",
        origin: node.origin, rules: @["R-IMG-01"]))

  if "dark_src" in node.attrs:
    diags.add(lowerMissing(node, "dark_src", "R-IMG-06"))
  if node.attrs.getOrDefault("fluid_on_mobile", "").toLowerAscii() == "true":
    diags.add(lowerMissing(node, "fluid_on_mobile", "R-IMG-09"))
  if "align" in node.attrs:
    diags.add(lowerMissing(node, "align", "R-IMG-01"))

  let img = r.createElement("img")
  img.origin = node.origin
  r.setAttribute(img, "src", src)
  r.setAttribute(img, "alt", node.attrs.getOrDefault("alt", ""))
  if width.len > 0:
    r.setAttribute(img, "width", width)
  if height.len > 0:
    r.setAttribute(img, "height", height)
  if "class" in node.attrs:
    r.setAttribute(img, "class", node.attrs["class"])
  r.setStyle(img, "display", "block")
  case inheritedAlign(node)
  of "center": r.setStyle(img, "margin", "0 auto")
  of "right": r.setStyle(img, "margin", "0 0 0 auto")
  else: discard
  r.setStyle(img, "border", "0")
  r.setStyle(img, "outline", "none")
  r.setStyle(img, "text-decoration", "none")
  r.setStyle(img, "height", "auto")
  if width.len > 0:
    r.setStyle(img, "width", width & "px")
    r.setStyle(img, "max-width", "100%")
  else:
    # No known width: an error was collected above; the image still
    # lowers, at most as wide as its container.
    r.setStyle(img, "max-width", "100%")
  r.setStyle(img, "-ms-interpolation-mode", "bicubic")
  # R-IMG-03: the alt text is styled on the img itself.
  let small = theme.lightFor("type.small").split('/')
  r.setStyle(img, "font-family", theme.lightFor("font.body"))
  r.setStyle(img, "font-size", small[0])
  if small.len > 1:
    r.setStyle(img, "line-height", small[1])
  r.setStyle(img, "color", theme.lightFor("color.text.secondary"))
  let radius = block:
    let a = declared(node, "border-radius")
    if a.len > 0: a else: declared(node, "border_radius")
  if radius.len > 0:
    r.setStyle(img, "border-radius", radius)
  for k, v in node.styles.pairs:
    if k notin consumedStyles:
      r.setStyle(img, k, v)

  let href = node.attrs.getOrDefault("href", "")
  if href.len == 0:
    return (img, diags)
  let a = r.createElement("a")
  a.origin = node.origin
  r.setAttribute(a, "href", href)
  r.setAttribute(a, "target", "_blank")
  r.setStyle(a, "display", "block")
  r.appendChild(a, img)
  (a, diags)
