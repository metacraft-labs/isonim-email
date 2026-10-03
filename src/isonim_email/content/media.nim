## isonim_email/content/media.nim — the hero and media patterns
## (layout-patterns.md §4.2): `mailHero`'s review declarations, and
## `mailMediaObject`, `mailZigZag`, `mailGallery` and `mailCountdown`.
##
## - `mailHero` has a lowering of its own (`lower/hero.nim`), so, like
##   the layout primitives, it registers its two review declarations
##   with no expansion.
## - `mailMediaObject(image, image_width, image_alt, decorative,
##   image_href, image_ratio, side, stack, valign, gap)` holding its text:
##   a `mailSidebar` whose fixed side is the image. `stack = never`
##   never switches (the image on `side`); `stack = below` switches below
##   280px (the Cerberus thumbnail ranges) with the image first in the
##   source, so a phone shows it above the text, and `side = right`
##   reverses the desktop order only (`reverse_on_mobile`, R-LAY-11).
##   `image_ratio` crops the image before sending (R-IMG-13).
## - `mailZigZag(gap)` holding `mailMediaObject`s: a `mailStack` of
##   them, each set to `stack = below`, the image on the left on odd rows
##   and on the right on even ones (desktop only; a phone always shows
##   the image first). A right-to-left document refuses the even rows'
##   reversal (`E-LAYOUT-REVERSE-TEXT`, R-LAY-11).
## - `mailGallery(ratio, columns, mobile_columns, gutter)` holding
##   `mailImage`s: a `mailGrid` of them, each full width in its item and
##   cropped to `ratio` (R-IMG-13; never `object-fit`); its text part is
##   each image as `alt (url)`, one per line.
## - `mailCountdown(src, width, height, deadline_text, href, align)`: the
##   server-rendered GIF as a `mailImage` whose alt is the deadline
##   text, which is also its plain-text form; without one it is
##   `E-PATTERN-MISSING-TEXT` (P1, `passes/validate.nim`).
##
## Importing this module registers the five.
##
## Pure tree building: identical on the C and JS targets.

{.used.}

import std/[strutils, tables]
import ../renderer
import ../target
import ../patterns
import ../primitives
import ../crop
import ./kit

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  HeroProps* = object
    ## `mailHero` (layout-patterns.md §4.2), for its declarations.
    background_image*: string
    background_color*: string
    height*: string
    min_height*: string
    vertical_align*: string = "top"

  MediaObjectProps* = object
    ## `mailMediaObject`.
    image*: string
    image_width*: string
    image_alt*: string
    decorative*: bool
    image_href*: string
    image_ratio*: string
    side*: string = "left"
    stack*: string = "never"
    valign*: string = "top"
    gap*: string

  ZigZagProps* = object
    ## `mailZigZag`.
    gap*: string

  GalleryProps* = object
    ## `mailGallery`.
    ratio*: string = "1:1"
    columns*: int = 3
    mobile_columns*: int ## 0: two when `columns` is 2 or 4, else one
    gutter*: string

  CountdownProps* = object
    ## `mailCountdown`.
    src*: string
    width*: string
    height*: string
    deadline_text*: string
    href*: string
    align*: string
    color*: string ## the alt text's colour (on a dark band, a light one)

const
  mediaSwitchBelow* = 280
    ## Where a stacking media object's text side switches under its
    ## image (px of the text side's minimum: the Cerberus ranges).
  mediaSwitchMin* = 160
    ## The narrowest text side a stacking media object keeps beside its
    ## image (a text column's 320px minimum, R-TBL-11).
  mediaColumnPadding* = 24
  mediaSwitchSlack* = 24
    ## How much narrower than the container a reading pane may be and
    ## still show the pair side by side (a webmail's pane is often a
    ## few pixels under 600).
    ## A section's column padding on each side, which the desktop width
    ## a media object sits in loses.
  galleryMinItem* = "120px"
    ## A gallery tile's 320px minimum (an image-only cell, R-TBL-11).

proc textOf(n: EmailNode): string =
  if n.kind == enText:
    return n.text
  for c in n.children:
    result.add(textOf(c))

proc firstWords(n: EmailNode; limit = 40): string =
  var t = splitWhitespace(textOf(n)).join(" ")
  if t.len > limit:
    t = t[0 ..< limit] & "…"
  "\"" & t & "\""

proc noLines[P](n: EmailNode; p: P; view: BriefView): seq[string] = @[]

proc noExpansion[P](n: EmailNode; p: P; ctx: ExpandCtx): EmailNode = nil

# --- mailHero -----------------------------------------------------------------

proc heroExpected(n: EmailNode; p: HeroProps; view: BriefView): seq[string] =
  let valign = case p.vertical_align.strip().toLowerAscii()
    of "middle": "vertically centred"
    of "bottom": "at the bottom"
    else: "at the top"
  var line = "Hero: a band across the message's column"
  if p.height.len > 0:
    line.add(", " & p.height & " tall")
  elif p.min_height.len > 0:
    line.add(", at least " & p.min_height & " tall")
  if p.background_image.len == 0 and p.background_color.len > 0:
    line.add(", in " & p.background_color)
  line.add("; its content sits " & valign & " in it, padded from its " &
    "edges, nothing cut off at any edge")
  @[line & "."]

proc heroDegradations(n: EmailNode; p: HeroProps;
    view: BriefView): seq[string] =
  if p.background_image.len > 0 and p.height.len == 0 and view.word:
    result.add("Word shows the hero's fallback colour instead of its " &
      "image: a rectangle that grows with its content is not drawn by " &
      "default (R-VML-03)")

# --- mailMediaObject ----------------------------------------------------------

proc mediaExpand(n: EmailNode; p: MediaObjectProps;
    ctx: ExpandCtx): EmailNode =
  let src = required(n, p.image, "an image", "a media object is its " &
    "image beside its text")
  let w = pxProp(n, p.image_width, "image_width")
  let side = oneOf(n, p.side, "side", ["left", "right"])
  let stack = oneOf(n, p.stack, "stack", ["never", "below"])
  let valign = oneOf(n, p.valign, "valign", ["top", "middle", "bottom"])
  if p.image_ratio.len > 0:
    let c = parseCrop(p.image_ratio)
    if not c.ok or c.circle:
      raise newException(PatternError, "mailMediaObject image_ratio = '" &
        p.image_ratio & "' is not W:H")
  let img = el(ctx, n, "mailImage", attrs = [("src", src),
    ("href", p.image_href.strip()), ("crop", p.image_ratio.strip()),
    ("decorative", if p.decorative: "true" else: "")],
    styles = [("width", $w & "px")])
  # Always written, empty included: a decorative image has `alt=""`.
  ctx.r.setAttribute(img, "alt", p.image_alt.strip())
  let text = el(ctx, n, "div")
  moveInto(ctx, text, slot(n))
  let gap = if p.gap.len > 0: p.gap else: "tok:space.4"
  if stack == "never":
    result = el(ctx, n, "mailSidebar", attrs = [("side", side),
      ("fixed", $w & "px"), ("valign", valign), ("switch_below", "0")],
      styles = [("gap", gap)])
    if side == "left": add(ctx, result, img, text)
    else: add(ctx, result, text, img)
  else:
    # The image first in the source, so a phone shows it first; the
    # desktop order reversed for a right-hand image (R-LAY-11). The
    # text switches below 280px, or below what a full-width section
    # leaves it beside a wide image, so the pair is side by side on
    # the desktop whatever the image's width.
    var gapPx = 16
    try:
      gapPx = pxProp(n, ctx.resolveProp(gap), "gap")
    except PatternError:
      discard
    let beside = ctx.target.containerWidth - 2 * mediaColumnPadding - w -
      gapPx - mediaSwitchSlack
    let switchAt = clamp(beside, mediaSwitchMin, mediaSwitchBelow)
    result = el(ctx, n, "mailSidebar", attrs = [("side", "left"),
      ("fixed", $w & "px"), ("valign", valign),
      ("switch_below", $switchAt & "px"),
      ("reverse_on_mobile", if side == "right": "true" else: "")],
      styles = [("gap", gap)])
    add(ctx, result, img, text)

proc mediaExpected(n: EmailNode; p0: MediaObjectProps;
    view: BriefView): seq[string] =
  var p = p0
  var zigSide = ""
  if n.parent != nil and n.parent.kind == enElement and
      n.parent.tag == "mailZigZag":
    # A zig-zag sets its rows' stacking and sides at expansion; the
    # brief reads the tree before it.
    p.stack = "below"
    var i = 0
    for c in n.parent.children:
      if c == n:
        break
      if c.kind == enElement:
        inc i
    zigSide = if i mod 2 == 0: "left" else: "right"
    p.side = zigSide
  let what = if p.decorative: "a decorative image"
    else: "the image \"" & p.image_alt.strip() & "\""
  let size = p.image_width.strip() & (if p.image_width.strip().endsWith(
    "px"): "" else: "px") & " wide" &
    (if p.image_ratio.len > 0: ", cropped to " & p.image_ratio.strip()
     else: "")
  let stacked = p.stack == "below" and not view.word and
    ((view.headCss and view.mediaQueries and view.narrow) or
     (not (view.headCss and view.mediaQueries) and view.width < 480))
  if stacked:
    return @["Media object, stacked at this width: " & what & " (" & size &
      ") above its text " & firstWords(n) & ", each the full width."]
  # The image's side, mirrored right to left.
  var left = if p.side == "right": "right" else: "left"
  if isRtl(n):
    left = if left == "left": "right" else: "left"
  @["Media object: " & what & " (" & size & ") on the " & left &
    ", its text " & firstWords(n) & " beside it, " &
    (case p.valign
     of "middle": "vertically centred"
     of "bottom": "aligned to the bottom"
     else: "aligned to the top") & (if p.stack == "never":
       "; side by side at every width" else: "") & "."]

proc mediaDegradations(n: EmailNode; p: MediaObjectProps;
    view: BriefView): seq[string] =
  if p.stack == "below" and not view.word and
      not (view.headCss and view.mediaQueries):
    result.add("without media queries the image and its text wrap " &
      "onto two lines only once the row is too narrow for both, and " &
      "then sit with no gap between them (layout patterns §3.6)")

# --- mailZigZag ---------------------------------------------------------------

proc zigZagExpand(n: EmailNode; p: ZigZagProps; ctx: ExpandCtx): EmailNode =
  let rows = slotOf(n, ["mailMediaObject"], "mailMediaObject rows")
  if rows.len == 0:
    raise newException(PatternError, "mailZigZag needs at least one " &
      "mailMediaObject")
  result = el(ctx, n, "mailStack",
    styles = [("gap", if p.gap.len > 0: p.gap else: "tok:space.6")])
  for i, row in rows:
    ctx.r.setAttribute(row, "stack", "below")
    ctx.r.setAttribute(row, "side", if i mod 2 == 0: "left" else: "right")
    add(ctx, result, row)

proc zigZagExpected(n: EmailNode; p: ZigZagProps;
    view: BriefView): seq[string] =
  let rows = slot(n).len
  let stacked = not view.word and
    ((view.headCss and view.mediaQueries and view.narrow) or
     (not (view.headCss and view.mediaQueries) and view.width < 480))
  if stacked:
    return @["Zig-zag of " & $rows & " rows, stacked at this width: in " &
      "every row the image comes first, above its text."]
  @["Zig-zag of " & $rows & " rows: the image on the left in the first " &
    "row, on the right in the second, alternating, each beside its text."]

# --- mailGallery --------------------------------------------------------------

proc galleryMobile(p: GalleryProps): int =
  if p.mobile_columns > 0: p.mobile_columns
  elif p.columns in [2, 4]: 2
  else: 1

proc galleryExpand(n: EmailNode; p: GalleryProps;
    ctx: ExpandCtx): EmailNode =
  let images = slotOf(n, ["mailImage"], "mailImage images")
  if images.len == 0:
    raise newException(PatternError, "mailGallery needs at least one image")
  let c = parseCrop(p.ratio)
  if not c.ok or c.circle:
    raise newException(PatternError, "mailGallery ratio = '" & p.ratio &
      "' is not W:H")
  result = el(ctx, n, "mailGrid", attrs = [("columns", $p.columns),
    ("mobile_columns", $galleryMobile(p)), ("min_item", galleryMinItem)],
    styles = [("gutter", p.gutter)])
  # The text part: each image as `alt (url)`, one per line (a row of
  # links reads one per line, never as `[n]` references).
  let lines = el(ctx, n, "mailCluster")
  for img in images:
    # One ratio for every tile, made before sending (R-IMG-13); the
    # image fills its item.
    ctx.r.setAttribute(img, "crop", p.ratio.strip())
    ctx.r.setStyle(img, "width", "100%")
    # On a phone the tile is as wide as its widened item (R-IMG-09).
    ctx.r.setAttribute(img, "fluid_on_mobile", "true")
    add(ctx, result, img)
    let alt = img.attrs.getOrDefault("alt", "").strip()
    let href = img.attrs.getOrDefault("href", "").strip()
    if href.len > 0:
      add(ctx, lines, el(ctx, n, "a", attrs = [("href", href)], text = alt))
    elif alt.len > 0:
      add(ctx, lines, el(ctx, n, "span", text = "[" & alt & "]"))
  result = htmlAndText(ctx, n, result, [lines])

proc galleryExpected(n: EmailNode; p: GalleryProps;
    view: BriefView): seq[string] =
  var alts: seq[string] = @[]
  for c in slot(n):
    if c.kind == enElement:
      alts.add("\"" & c.attrs.getOrDefault("alt", "") & "\"")
  var per = p.columns
  if not view.word:
    if view.headCss and view.mediaQueries:
      if view.narrow: per = galleryMobile(p)
    elif galleryMobile(p) == 2 or view.narrow:
      per = galleryMobile(p)
  @["Gallery of " & $alts.len & " images (" & alts.join(", ") & "), " &
    $per & " per row at this width, every tile the same " & p.ratio &
    " shape and filling its cell, a gap between tiles; each image is a " &
    "link."]

proc galleryDegradations(n: EmailNode; p: GalleryProps;
    view: BriefView): seq[string] =
  if not view.word and not (view.headCss and view.mediaQueries):
    result.add("without media queries every tile keeps its desktop size, " &
      "so where its item widens (one or two to a row) the tiles leave a " &
      "wider gap beside them than below (R-IMG-09)")
  if galleryMobile(p) == 1 and not view.word and
      not (view.headCss and view.mediaQueries):
    result.add("without media queries the tiles shrink with the row down " &
      "to their minimum and then wrap, as many per row as fit, so a " &
      "narrow screen may show a short last row (layout patterns §3.4)")

# --- mailCountdown ------------------------------------------------------------

proc countdownExpand(n: EmailNode; p: CountdownProps;
    ctx: ExpandCtx): EmailNode =
  let src = required(n, p.src, "a src", "the server-rendered countdown GIF")
  let w = pxProp(n, p.width, "width")
  let deadline = p.deadline_text.strip()
  var styles = @[("width", $w & "px")]
  if p.height.len > 0:
    styles.add(("height", $pxProp(n, p.height, "height") & "px"))
  let img = el(ctx, n, "mailImage", attrs = [("src", src),
    ("href", p.href.strip()), ("align", p.align.strip()),
    # Without its deadline text the countdown is P1's
    # E-PATTERN-MISSING-TEXT, reported once, not as a missing alt too.
    ("decorative", if deadline.len == 0: "true" else: "")], styles = styles)
  ctx.r.setAttribute(img, "alt", deadline)
  if p.color.strip().len > 0:
    ctx.r.setStyle(img, "color", p.color.strip())
  let line = el(ctx, n, "p")
  if p.href.strip().len > 0:
    add(ctx, line, el(ctx, n, "a", attrs = [("href", p.href.strip())],
      text = deadline))
  elif deadline.len > 0:
    add(ctx, line, ctx.r.createTextNode(deadline))
  htmlAndText(ctx, n, img, [line])

proc countdownExpected(n: EmailNode; p: CountdownProps;
    view: BriefView): seq[string] =
  @["Countdown: an image " & p.width.strip() & " wide showing the time " &
    "left (its first frame carries the message); with images off, its " &
    "alt text reads \"" & p.deadline_text.strip() & "\"."]

proc countdownDegradations(n: EmailNode; p: CountdownProps;
    view: BriefView): seq[string] =
  if view.word:
    result.add("Word shows the GIF's first frame only, not the animation " &
      "(R-OL-13)")

# --- Registration -------------------------------------------------------------

registerPattern(typedPattern[HeroProps]("mailHero", noExpansion[HeroProps],
  heroExpected, heroDegradations))
defineMailPattern(mailMediaObject, MediaObjectProps, mediaExpand,
  mediaExpected, mediaDegradations)
proc zigZagDegradations(n: EmailNode; p: ZigZagProps;
    view: BriefView): seq[string] =
  if not view.word and not (view.headCss and view.mediaQueries):
    result.add("without media queries a row wraps only once it is too " &
      "narrow for its image and text; then the image of an even row sits " &
      "at the far edge (its desktop reversal) and the text directly under " &
      "it, with no gap (layout patterns §3.6)")

defineMailPattern(mailZigZag, ZigZagProps, zigZagExpand, zigZagExpected,
  zigZagDegradations)
defineMailPattern(mailGallery, GalleryProps, galleryExpand, galleryExpected,
  galleryDegradations)
defineMailPattern(mailCountdown, CountdownProps, countdownExpand,
  countdownExpected, countdownDegradations)
