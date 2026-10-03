## isonim_email/lower/image.nim — `mailImage` lowering.
##
## **Fixed-size images** (rendered narrower than their container: a
## logo, an icon, a thumbnail) follow R-IMG-01: an `img` with `src`,
## `alt`, the px `width` attribute (always, for DPI scaling and Word),
## the `height` attribute when the aspect is known (the author's
## `height`, or a published asset's intrinsic size), and the inline
## stack
## `display:block;{margin}border:0;outline:none;text-decoration:none;height:auto;width:{w}px;max-width:100%;-ms-interpolation-mode:bicubic;`
## The width is the px width capped by `max-width:100%`, never
## `width:100%` capped by a px `max-width`: Thunderbird's `shrinktofit`
## message stylesheet replaces an author `max-width` with `!important`,
## which let a `width:100%` image fill the column. `{margin}` places the
## block: the image's own `align`, else the alignment it inherits
## (`inheritedAlign`): `margin:0 auto;` when centred, `margin:0 0 0
## auto;` when right-aligned, nothing when left-aligned, because
## `align`/`text-align` move inline content only and engines without
## the legacy `align` quirk (litehtml) left a centred image at the left
## edge. An explicit `align` also wraps the image in a `div` carrying
## it as `align` and `text-align`, which is what Word reads.
##
## **Fluid images** (a percentage `width`, a px width at least as wide
## as the box the image sits in and wider than a phone's box, 280 px, or
## `fluid_on_mobile`) follow R-IMG-11,
## the Samsung split: Samsung Email lays the whole message out at an
## image's `width` attribute, so outside Outlook a fluid image carries
## `width="100%"`, and Word gets a copy of its own with the px width
## (Outlook 2016 and earlier read a percentage attribute relative to
## the image): `<!--[if mso]><img … width="{px}" …><![endif]-->` then
## `<!--[if !mso]><!--><img … width="100%" style="…width:100%;max-width:{px}px;…"><!--<![endif]-->`.
## A percentage below 100 keeps its percentage as the CSS width.
## `fluid_on_mobile` keeps the fixed image's CSS on desktop, and the
## style pass gives it the class that makes it full width below the
## breakpoint (R-IMG-09).
##
## **Alt text** (R-IMG-03) is styled on the `img` itself: body font,
## small type size and line height, secondary text colour, so it stays
## readable when images are blocked, and it must read on the background
## it sits on (below 4.5:1 is `W-A11Y-CONTRAST`). The engines show it
## differently, and the lowering follows what they do (widths estimated
## with `style/metrics`):
##
## - WebKit draws an image's alt only when it fits the image's width on
##   one line, from the top of a box that collapses to a few pixels,
##   over whatever follows. An image whose alt fits and whose rendered
##   height is known never to drop below one alt line (its height, at
##   its width and at 280 px, the narrowest a phone gives a full-width
##   image) gets `min-height:{alt line}px`, so the alt stays inside its
##   own box. Where the height is unknown the minimum is not written: it
##   would stretch a loaded image thinner than one line (a wordmark). An
##   alt that does not fit is reported (`W-IMG-ALT-FIT`, families:
##   apple): with images off, WebKit shows nothing for that image. Pair
##   a narrow icon with visible text, shorten its alt or widen it.
## - Chromium and Gecko draw a block image's alt inside its box,
##   wrapped at word boundaries and clipped at its edge (or broken
##   mid-word where a container breaks long words). An image whose
##   longest alt word may not fit its width (the estimate with its
##   safety margin, plus the box's border and padding), alone in its
##   holder, is written inline (`display:inline`, its width as the
##   attribute only): an inline broken image is laid out as text, so its
##   whole alt shows, and a loaded one keeps the attribute's width. Alone
##   in its holder, the holder's zero font size (below) leaves no gap
##   under it. WebKit draws the alt of an inline image under the same
##   one-line rule.
##
## **Image-only holders** (R-TBL-13, R-IMG-02): the block an image sits
## in, when it holds nothing but images (or links around them), gets a
## zero font size written `0.01px` (R-LAY-04: WebKitGTK renders nothing
## of a message holding a true zero) and `line-height:0`, which keeps
## any line from opening under the image.
##
## A linked image wraps the `img` (both copies of a fluid one) in
## `<a href target="_blank" style="display:block;color:{alt colour};text-decoration:none;">`
## with nothing between them (R-IMG-10): Word paints a link's content
## in the link's colour, underlined, alt text included.
##
## The width comes from the element (P5-normalised `width` style or a
## plain `width` attribute), else from the published asset's intrinsic
## size, halved for `@2x` assets (R-IMG-05). A width that is still
## unknown is an error (`E-LAYOUT-IMAGE-WIDTH`). `dark_src` (R-IMG-06,
## two images swapped by the dark block) is reported as
## `E-LOWER-MISSING`: the image still lowers, but the error blocks
## sending.
##
## The `img` is P5-final: P5 has already run over the authoring
## element, so the literals written here are what the serialiser
## emits. Author classes (including the ones P6 generated for variant
## declarations) and any other resolved declaration carry over after
## the canonical stack.
##
## Pure tree building: identical on the C and JS targets.

import std/[math, strutils, tables]
import ../renderer
import ../diagnostics
import ../assets
import ../style/tokens
import ../style/units
import ../style/metrics
import ../target
import ../mso/cond
import ../style/colors
from ../passes/lint import contrastRatio
from ./document import contentCellAlign
from ./section import zeroFontSize

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  consumedStyles = ["width", "height", "border_radius", "border-radius"]
    ## Declarations the lowering itself turns into attributes or the
    ## canonical stack; every other resolved declaration carries over.
  narrowestFluidBox* = 280
    ## The narrowest box a full-width image gets on a phone (a 320px
    ## screen less two 20px paddings): the floor of the min-height check.
  webkitAltInset* = 2.0
    ## What WebKit's broken-image box takes from the alt text's width.
  iconAltBelow* = 40
    ## An image narrower than this, alone in its holder, always takes the
    ## inline form: in a box that small Chromium's broken-image icon
    ## covers even a one-letter alt (a social icon's "X").
  chromiumAltInset* = 6.0
    ## What Chromium's takes: a border and a padding on each side, and
    ## room for the last glyph's overhang.
  holderTags = ["div", "td", "th", "p"]
    ## The blocks an image can sit alone in.

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

proc percentNumber(value: string): float =
  ## `50%` → 50.0; 0 when not a positive percentage.
  let s = value.strip()
  if not s.endsWith("%"):
    return 0
  try:
    max(0.0, parseFloat(s[0 ..< ^1].strip()))
  except ValueError:
    0

proc pctText(p: float): string =
  formatNum(p) & "%"

proc declared(node: EmailNode; prop: string): string =
  ## The element's own value for `prop`: the resolved style first,
  ## then a plain attribute (hand-built trees).
  if prop in node.styles:
    return node.styles[prop]
  node.attrs.getOrDefault(prop, "")

proc assetOf(src: string; assets: openArray[AssetRef]): AssetRef =
  ## The published asset `src` names, or an empty record.
  for a in assets:
    if a.url.len > 0 and a.url == src:
      return a

proc intrinsicWidth(a: AssetRef): int =
  ## The rendered width a published asset implies: its intrinsic
  ## width, halved for `@2x` assets (R-IMG-05). 0 when unknown.
  if a.width <= 0:
    return 0
  if "@2x" in a.name: a.width div 2 else: a.width

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

proc isImageContent(n: EmailNode): bool =
  ## An image, or a link holding images only.
  if n.kind != enElement:
    return false
  let tag = n.tag.toLowerAscii()
  if tag in ["img", "mailimage"]:
    return true
  # A link, or an expanded pattern still standing around what it became
  # (a social item around its linked icon), holding images only.
  if tag != "a" and not n.expanded:
    return false
  var any = false
  for c in n.children:
    case c.kind
    of enText:
      if c.text.strip().len > 0:
        return false
    of enElement:
      if not isImageContent(c):
        return false
      any = true
    of enMsoIf, enNotMso:
      any = true
    else: discard
  any

proc imageOnlyHolder*(node: EmailNode): EmailNode =
  ## The block `node` (an image) sits in when that block holds nothing
  ## but images and links around them; nil otherwise. Links between
  ## the image and the block are looked through, and so is an expanded
  ## pattern around an image (a social item, `navigation.nim`).
  var h = node.parent
  while h != nil and h.kind == enElement and (h.tag.toLowerAscii() == "a" or
      h.expanded):
    h = h.parent
  if h == nil or h.kind != enElement or h.tag.toLowerAscii() notin holderTags:
    return nil
  var any = false
  for c in h.children:
    case c.kind
    of enText:
      if c.text.strip().len > 0:
        return nil
    of enElement:
      if not isImageContent(c):
        return nil
      any = true
    of enMsoIf, enNotMso:
      discard
    else: discard
  if any: h else: nil

proc markImageOnlyHolder*(holder: EmailNode) =
  ## R-TBL-13, R-IMG-02: no line opens under the images of a block
  ## that holds nothing else.
  let r = EmailRenderer()
  r.setStyle(holder, "font-size", zeroFontSize)
  r.setStyle(holder, "line-height", "0")

proc backgroundOf(node: EmailNode): string =
  ## The background colour `node` is painted on: the nearest ancestor's
  ## `background-color` style or `bgcolor` attribute, "" for none.
  var p = node.parent
  while p != nil:
    if p.kind == enElement:
      let v = p.styles.getOrDefault("background-color", "")
      if v.len > 0:
        return v
      let a = p.attrs.getOrDefault("bgcolor", "")
      if a.len > 0:
        return a
    p = p.parent
  ""

proc lowerMissing(node: EmailNode; what, rule: string): EmailDiagnostic =
  EmailDiagnostic(severity: sevError, code: codeLowerMissing,
    message: "mailImage " & what & " has no lowering yet (" & rule &
      "); it is reported, never dropped silently",
    origin: node.origin, rules: @[rule])

type AltStyle* = object
  ## The alt text's type (R-IMG-03).
  family*, color*: string
  size*, line*: float

proc altStyle*(theme: EmailTheme): AltStyle =
  let small = theme.lightFor("type.small").split('/')
  result.family = theme.lightFor("font.body")
  result.color = theme.lightFor("color.text.secondary")
  result.size = try: toPx(small[0]) except StyleError: 14.0
  result.line = if small.len > 1:
      (try: toPx(small[1]) except StyleError: round(result.size * 1.4))
    else: round(result.size * 1.4)

proc altFitsOneLine*(alt: string; width: int; st: AltStyle): bool =
  ## WebKit's test: the whole alt on one line inside the image's box. A
  ## best estimate, without the metrics' safety margin: WebKit's box
  ## takes almost nothing from the text.
  textWidth(alt, st.size, margin = false) + webkitAltInset <= float(width)

proc altWordsFit*(alt: string; width: int; st: AltStyle): bool =
  ## Chromium's and Gecko's: every word of the alt inside the box (the
  ## rest wraps). With the safety margin: a word judged to fit that does
  ## not is clipped, or broken mid-word where a container breaks long
  ## words (R-TBL-17).
  longestWordWidth(alt, st.size) + chromiumAltInset <= float(width)

proc baseStack(r: EmailRenderer; img: EmailNode; display, margin: string) =
  # The inline form leaves `display` at the image's own default: an
  # explicit `display:inline` makes litehtml (Claws Mail) lay the image
  # out as an empty inline box.
  if display != "inline":
    r.setStyle(img, "display", display)
  if margin.len > 0:
    r.setStyle(img, "margin", margin)
  r.setStyle(img, "border", "0")
  r.setStyle(img, "outline", "none")
  r.setStyle(img, "text-decoration", "none")
  r.setStyle(img, "height", "auto")

proc altStack(r: EmailRenderer; img: EmailNode; st: AltStyle) =
  r.setStyle(img, "font-family", st.family)
  r.setStyle(img, "font-size", formatPx(st.size))
  r.setStyle(img, "line-height", formatPx(st.line))
  r.setStyle(img, "color", st.color)

proc lowerImage*(node: EmailNode; theme: EmailTheme;
    assets: openArray[AssetRef]; target = defaultTarget()):
    tuple[nodes: seq[EmailNode]; diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one `mailImage` element (see the module comment): `nodes`
  ## replace it. The authoring element is left untouched, except that
  ## an image-only holder above it is marked (R-TBL-13).
  let r = EmailRenderer()
  var diags: seq[EmailDiagnostic] = @[]
  let src = node.attrs.getOrDefault("src", "")
  let alt = node.attrs.getOrDefault("alt", "")
  let asset = assetOf(src, assets)
  let container = if node.layout.container > 0: node.layout.container
    else: target.containerWidth

  var width = 0
  var percent = 0.0
  let given = declared(node, "width")
  if given.len > 0:
    let (ok, px) = pxNumber(given)
    if ok:
      width = int(round(parseFloat(px)))
    elif percentNumber(given) > 0:
      percent = min(100.0, percentNumber(given))
      width = max(1, int(round(float(container) * percent / 100.0)))
    else:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue,
        message: "mailImage width '" & given & "' is not a px length " &
          "or a percentage",
        origin: node.origin, rules: @["R-IMG-01"]))
  if width == 0 and given.len == 0:
    width = intrinsicWidth(asset)
    if width == 0:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeLayoutImageWidth,
        message: "mailImage '" & src & "' has no width and no known " &
          "intrinsic size: give it a px width (R-IMG-01)",
        origin: node.origin, rules: @["R-IMG-01"]))
  var height = 0
  let givenH = declared(node, "height")
  if givenH.len > 0 and givenH.strip().toLowerAscii() != "auto":
    let (ok, px) = pxNumber(givenH)
    if ok:
      height = int(round(parseFloat(px)))
    else:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeVocabBadValue,
        message: "mailImage height '" & givenH & "' is not a px length",
        origin: node.origin, rules: @["R-IMG-01"]))
  elif givenH.len == 0 and width > 0 and asset.width > 0 and
      asset.height > 0:
    # A published asset's aspect is known: its height at this width.
    height = int(round(float(width) * float(asset.height) /
      float(asset.width)))

  if "dark_src" in node.attrs:
    diags.add(lowerMissing(node, "dark_src", "R-IMG-06"))
  let fluidOnMobile =
    node.attrs.getOrDefault("fluid_on_mobile", "").toLowerAscii() == "true"
  # A px image fills its box only when it is wider than a phone's box:
  # a narrower one (an avatar in its fixed cell) never outgrows a phone,
  # so it stays a fixed image with its alt text rules.
  let fullWidth = percent == 0 and width >= container and
    width > narrowestFluidBox
  let fluid = percent > 0 or fullWidth or fluidOnMobile
  let px = if fullWidth: container else: width

  var alignAttr = node.attrs.getOrDefault("align", "").strip().toLowerAscii()
  if alignAttr.len > 0 and alignAttr notin ["left", "center", "right"]:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailImage align '" & alignAttr &
        "' is not left, center or right",
      origin: node.origin, rules: @["R-IMG-01"]))
    alignAttr = ""
  let align = if alignAttr.len > 0: alignAttr else: inheritedAlign(node)
  let margin = case align
    of "center": "0 auto"
    of "right": "0 0 0 auto"
    else: ""

  let st = altStyle(theme)
  let holder = imageOnlyHolder(node)
  if alt.len > 0:
    # R-IMG-03: the alt text must read on the background it sits on.
    let bg = backgroundOf(node)
    try:
      let fg = parseColor(st.color)
      let back = if bg.len > 0: parseColor(bg)
        else: parseColor("#ffffff")
      let ratio = contrastRatio(fg, back)
      if ratio < 4.5:
        diags.add(EmailDiagnostic(severity: sevWarning,
          code: codeA11yContrast,
          message: "with images off, this image's alt text (" & st.color &
            ") is at " & formatFloat(ratio, ffDecimal, 2) & ":1 on its " &
            "background (" & (if bg.len > 0: bg else: "#ffffff") &
            "), below 4.5:1 (R-IMG-03)",
          origin: node.origin, rules: @["R-IMG-03"]))
    except StyleError:
      discard
  var inline = false
  var minHeight = false
  if alt.len > 0 and px > 0 and not fluid:
    let oneLine = altFitsOneLine(alt, px, st)
    if (not altWordsFit(alt, px, st) or px < iconAltBelow) and
        holder != nil:
      inline = true
    # WebKit draws the alt of either form when it fits on one line.
    if not oneLine:
      diags.add(EmailDiagnostic(severity: sevWarning,
        code: codeImgAltFit, families: {cfApple},
        message: "with images off, WebKit shows no alt text for this " &
          $px & "px image: '" & alt & "' does not fit its width on one " &
          "line (R-IMG-03); pair the image with visible text, or " &
          "shorten its alt or widen the image",
        origin: node.origin, rules: @["R-IMG-03"]))
  if alt.len > 0 and px > 0 and not inline and height > 0 and
      altFitsOneLine(alt, px, st) and
      float(height) * min(1.0, float(narrowestFluidBox) / float(px)) >=
        st.line:
    minHeight = true

  proc buildImg(attrWidth, cssWidth, cssMax: string; display: string;
      withClass, withAlt: bool; withHeight = true): EmailNode =
    let img = r.createElement("img")
    img.origin = node.origin
    r.setAttribute(img, "src", src)
    r.setAttribute(img, "alt", alt)
    if attrWidth.len > 0:
      r.setAttribute(img, "width", attrWidth)
    if height > 0 and withHeight:
      r.setAttribute(img, "height", $height)
    if withClass and "class" in node.attrs:
      r.setAttribute(img, "class", node.attrs["class"])
    r.baseStack(img, display, if display == "block": margin else: "")
    if cssWidth.len > 0:
      r.setStyle(img, "width", cssWidth)
    if cssMax.len > 0:
      r.setStyle(img, "max-width", cssMax)
    if minHeight:
      r.setStyle(img, "min-height", formatPx(st.line))
    if display == "inline":
      # On the line's middle, so no descender gap opens under it; and
      # the alt of an inline broken image is laid out as text, which a
      # container that breaks long words (R-TBL-17) must not break.
      r.setStyle(img, "vertical-align", "middle")
      r.setStyle(img, "overflow-wrap", "normal")
      r.setStyle(img, "word-break", "normal")
    r.setStyle(img, "-ms-interpolation-mode", "bicubic")
    if withAlt:
      r.altStack(img, st)
    let radius = block:
      let a = declared(node, "border-radius")
      if a.len > 0: a else: declared(node, "border_radius")
    if radius.len > 0:
      r.setStyle(img, "border-radius", radius)
    for k, v in node.styles.pairs:
      if k notin consumedStyles:
        r.setStyle(img, k, v)
    img

  var images: seq[EmailNode] = @[]
  if not fluid:
    # The inline form keeps the width attribute only: a CSS width would
    # size the box a broken image's alt is laid out in.
    images.add(buildImg(if width > 0: $width else: "",
      if width > 0: $width & "px" else: "", if inline: "" else: "100%",
      if inline: "inline" else: "block", true, true))
  else:
    let cssW = if fluidOnMobile and percent == 0 and not fullWidth:
        $px & "px"
      elif percent > 0: pctText(percent)
      else: "100%"
    let cssMax = if fluidOnMobile and percent == 0 and not fullWidth: "100%"
      else: $px & "px"
    let web = buildImg("100%", cssW, cssMax, "block", true, true,
      withHeight = false)
    if target.outlookWord:
      let word = buildImg($px, $px & "px", "100%", "block", false, true)
      images.add(msoWrap(word))
      images.add(notMsoWrap(web))
    else:
      images.add(web)

  if holder != nil and not inline:
    markImageOnlyHolder(holder)

  var nodes = images
  let href = node.attrs.getOrDefault("href", "")
  if href.len > 0:
    let a = r.createElement("a")
    a.origin = node.origin
    r.setAttribute(a, "href", href)
    r.setAttribute(a, "target", "_blank")
    r.setStyle(a, "display", "block")
    # Word paints a link's content in the link's colour and underlines
    # it: the alt text keeps its own colour, never underlined.
    r.setStyle(a, "color", st.color)
    r.setStyle(a, "text-decoration", "none")
    for n in images:
      r.appendChild(a, n)
    nodes = @[a]
  if alignAttr.len > 0:
    let d = r.createElement("div")
    d.origin = node.origin
    r.setAttribute(d, "align", alignAttr)
    r.setStyle(d, "text-align", alignAttr)
    for n in nodes:
      r.appendChild(d, n)
    nodes = @[d]
  (nodes, diags)
