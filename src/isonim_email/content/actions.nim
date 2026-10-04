## isonim_email/content/actions.nim — the actions and inline items
## (layout-patterns.md §4.5): `mailButtonGroup`, `mailBadge`,
## `mailAvatarName`, `mailDividerLabel`, `mailCoupon`,
## `mailRatingScale`, `mailSecurityCode` and `mailAppBadges` (the social
## row is `mailSocial`, `navigation.nim`).
##
## Each is defined with `defineMailPattern` and expands only into
## primitives, scaffolding and leaves, except the two special lowerings
## R-TBL-01 admits:
##
## - `mailButtonGroup(gap, align, stack_on_mobile)` holding 1–3
##   `mailButton`s (the first solid, the rest outlined unless they say
##   otherwise): a `mailCluster`, or, `stack_on_mobile`, a `hybrid`
##   `mailColumns` row of full-width buttons; its text part is each
##   `label: url`.
## - `mailBadge(tone)` holding its label: an inline-block `span` in the
##   tone's colours; when Outlook output is on and the badge is not
##   inside a line of text, the **badge Word wrapper**: the expansion
##   writes a one-cell `display:inline-table` table whose cell carries
##   the padding (Word ignores a span's). Its text part is `[label]`.
## - `mailAvatarName(name, role, avatar, avatar_alt, size, crop)`: a
##   `mailSidebar` of the circular avatar (cropped by the asset pass) and
##   the name over the role; text `Name — role`.
## - `mailDividerLabel` holding its label: the **labelled divider**, a
##   three-cell table the expansion writes (rule | label | rule, the
##   rules 1px `bgcolor` cells in nested tables), with its own automatic
##   layout; text `—— label ——`.
## - `mailCoupon(code, title, hint, label)`: a dashed `mailBox` (the box
##   lowering paints its parent table too, R-TBL-08) holding the offer,
##   the code in a monospace face, protected from data detectors
##   (R-TXT-06), and the hint; text `Code: …`.
## - `mailRatingScale(kind, href, low_label, high_label)`: five 44px
##   star links in a `mailCluster`, or an NPS scale of two `cells` rows
##   (0–5, 6–10); every link reads "Rate n out of m"; text one `score:
##   url` line per score.
## - `mailSecurityCode(code, expires, label, expires_label, href, cta)`:
##   a `mailBox` holding the code (monospace, protected from data
##   detectors), its expiry and an optional magic-link button; text
##   `Your code: 123456 (expires at 14:05 UTC)`.
## - `mailAppBadges(height, align, gap)` holding `mailAppBadge(store,
##   href, image, dark_image, width, alt)`s: a `mailCluster` of the
##   linked badge images, 40–48px tall, a quarter of their height apart
##   at least; text `alt: url` lines.
##
## A required prop that is missing, or content of the wrong kind, is a
## `PatternError` (`E-VOCAB-BAD-VALUE` at the element). Importing this
## module registers them.
##
## Pure tree building: identical on the C and JS targets.

{.used.}

import std/[math, strutils, tables, unicode]
import ../renderer
import ../target
import ../patterns
import ../style/tokens
import ./kit
import ./data

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  ButtonGroupProps* = object
    ## `mailButtonGroup` (layout-patterns.md §4.5).
    gap*: string = "12px"
    align*: string
    stack_on_mobile*: bool

  BadgeProps* = object
    ## `mailBadge`: its label is its content.
    tone*: string = "neutral"

  AvatarNameProps* = object
    ## `mailAvatarName`.
    name*: string
    role*: string
    avatar*: string
    avatar_alt*: string
    size*: int = 48
    crop*: string = "circle"

  DividerLabelProps* = object ## `mailDividerLabel`: its label is its content.

  CouponProps* = object
    ## `mailCoupon`.
    code*: string
    title*: string
    hint*: string
    label*: string = "Code"

  RatingScaleProps* = object
    ## `mailRatingScale`.
    kind*: string = "stars"
    href*: string
    low_label*: string
    high_label*: string

  SecurityCodeProps* = object
    ## `mailSecurityCode`.
    code*: string
    expires*: string
    label*: string = "Your code"
    expires_label*: string = "Expires at"
    href*: string
    cta*: string

  AppBadgesProps* = object
    ## `mailAppBadges`.
    height*: int = 40
    align*: string = "center"
    gap*: string

  AppBadgeProps* = object
    ## `mailAppBadge`, an item of `mailAppBadges`.
    store*: string = "other"
    href*: string
    image*: string
    dark_image*: string
    width*: int
    alt*: string

const
  buttonGroupMinGapPx* = 12
    ## A button group's smallest gap.
  buttonGroupMax* = 3
    ## The buttons a group holds.
  badgeTones* = ["neutral", "primary", "info", "success", "warning",
    "danger"]
    ## A badge's tones (the `Tone` value type).
  shortLabelChars* = 20
    ## A badge's or a divider's label this short never wraps.
  avatarMinPx* = 32
  avatarMaxPx* = 96
    ## An avatar's sizes.
  ratingTargetPx* = 44
    ## A rating link's hit size (R-TBL-12).
  ratingGapPx* = 8
    ## Between two rating targets (R-TBL-12).
  ratingStar* = "★"
    ## A star's glyph.
  npsDefaultLow* = "Not likely"
  npsDefaultHigh* = "Very likely"
    ## An NPS scale's end labels.
  appBadgeMinPx* = 40
  appBadgeMaxPx* = 48
    ## An app badge's heights (Apple's marketing guidelines: 40px at
    ## least on screen).
  appBadgeDefaultAlts* = [("apple", "Download on the App Store"),
    ("google", "Get it on Google Play")]
    ## The alt text of a store's badge.
  textTags = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "a", "span",
    "strong", "b", "em", "i", "u", "s", "small", "sup", "sub", "code",
    "blockquote", "pre", "caption", "th", "td", "mailText"]
    ## Elements whose content is a line of text: a badge in one is
    ## inline.
  inlineTags = ["span", "strong", "b", "em", "i", "u", "s", "small", "sup",
    "sub", "a", "code", "br", "codeInline"]

defineMailItem(mailAppBadge, "mailAppBadges", AppBadgeProps)

proc textOf(n: EmailNode): string =
  if n.kind == enText:
    return n.text
  for c in n.children:
    result.add(textOf(c))

proc quoted(s: string; limit = 40): string =
  var t = strutils.splitWhitespace(s).join(" ")
  if t.runeLen > limit:
    t = t.runeSubStr(0, limit) & "…"
  "\"" & t & "\""

proc noLines[P](n: EmailNode; p: P; view: BriefView): seq[string] = @[]

proc alignWordOf(align: string): string =
  case align.strip().toLowerAscii()
  of "left": "at the left"
  of "right": "at the right"
  else: "centred"

proc gapPx(n: EmailNode; ctx: ExpandCtx; value, name: string): int =
  ## A px gap, a `tok"…"` resolved first.
  pxProp(n, resolveProp(ctx, value), name)

proc layoutTable(ctx: ExpandCtx; n: EmailNode;
    styles: openArray[(string, string)] = []): EmailNode =
  ## A presentation table (R-LAY-15), right to left where `n` is.
  result = el(ctx, n, "table", attrs = [("role", "presentation"),
    ("width", "100%"), ("border", "0"), ("cellpadding", "0"),
    ("cellspacing", "0"), ("dir", if isRtl(n): "rtl" else: "")],
    styles = @[("width", "100%")] & @styles)

proc spacerCell(ctx: ExpandCtx; n: EmailNode;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []): EmailNode =
  ## A cell that holds nothing visible (R-TBL-05, R-LAY-04).
  result = el(ctx, n, "td", attrs = @[("aria-hidden", "true")] & @attrs,
    styles = @[("padding", "0"), ("font-size", "0.01px"),
      ("line-height", "0"), ("mso-line-height-rule", "exactly")] & @styles,
    text = "\u00a0")

proc themeBorder(ctx: ExpandCtx; node: EmailNode; width, style,
    token: string) =
  ## A border in a theme colour (the `border` shorthand), dark-paired
  ## under `designed`.
  ctx.r.setStyle(node, "border", width & " " & style & " " &
    ctx.theme.lightFor(token))
  if ctx.darkDesigned():
    ctx.r.setStyle(node, "@dark:border-color", "tok:" & token)

proc inlineSlot(n: EmailNode; what: string): seq[EmailNode] =
  ## The pattern's content as text and inline elements only.
  for c in n.children:
    if c.kind == enElement and c.tag notin inlineTags:
      raise newException(PatternError, n.tag & " holds " & what &
        " (found <" & c.tag & ">)")
    if c.kind in {enText, enElement}:
      result.add(c)

proc nolinkSpan(ctx: ExpandCtx; n: EmailNode; text: string): EmailNode =
  ## Text no data detector turns into a link (R-TXT-06).
  el(ctx, n, "span", attrs = [("nolink", "true")], text = text)

proc lowerFirst(s: string): string =
  ## `s` with its first letter lower-cased (`Expires at` → `expires at`).
  if s.len == 0:
    return s
  let r = s.runeAt(0)
  $unicode.toLower(r) & s[size(r) .. ^1]

# --- mailButtonGroup -----------------------------------------------------------

proc buttonLabel(b: EmailNode): string =
  strutils.splitWhitespace(plainText(b)).join(" ")

proc buttonGroupExpand(n: EmailNode; p: ButtonGroupProps;
    ctx: ExpandCtx): EmailNode =
  let buttons = slotOf(n, ["mailButton"], "mailButton items")
  if buttons.len == 0 or buttons.len > buttonGroupMax:
    raise newException(PatternError, "mailButtonGroup holds 1 to " &
      $buttonGroupMax & " buttons (found " & $buttons.len & ")")
  let gap = gapPx(n, ctx, p.gap, "gap")
  if gap < buttonGroupMinGapPx:
    raise newException(PatternError, "mailButtonGroup gap = '" & p.gap &
      "' is below " & $buttonGroupMinGapPx & "px: buttons in a row keep " &
      "their tap targets apart (R-TBL-12)")
  let align =
    if p.align.strip().len > 0: oneOf(n, p.align, "align", ["left",
      "center", "right"])
    else: startSide(n)
  var lines: seq[string] = @[]
  # A button without a variant of its own is the group's primary action
  # when it is the first, secondary after it (`variantOf`, read by the
  # button's defaults wherever the button sits in the group).
  for b in buttons:
    lines.add(buttonLabel(b) & ": " & b.attrs.getOrDefault("href", "").strip())
  var html: EmailNode
  if p.stack_on_mobile:
    html = el(ctx, n, "mailColumns", attrs = [("strategy", "hybrid"),
      ("gutter", $gap & "px")])
    for b in buttons:
      let col = el(ctx, n, "mailColumn")
      ctx.r.setStyle(b, "width", "100%")
      add(ctx, col, b)
      add(ctx, html, col)
  else:
    html = el(ctx, n, "mailCluster", attrs = [("align", align)],
      styles = [("gap", $gap & "px"), ("row_gap", $gap & "px")])
    moveInto(ctx, html, buttons)
  htmlAndText(ctx, n, html, [linesPara(ctx, n, lines)])

proc buttonGroupExpected(n: EmailNode; p: ButtonGroupProps;
    view: BriefView): seq[string] =
  var names: seq[string] = @[]
  var i = 0
  for c in slot(n):
    if c.kind == enElement:
      let variant = c.attrs.getOrDefault("variant",
        if i == 0: "solid" else: "outline")
      names.add(quoted(textOf(c)) & (case variant
        of "outline": " (outlined)"
        of "link": " (a link)"
        else: " (filled)"))
      inc i
  if p.stack_on_mobile:
    if view.word or (view.headCss and view.mediaQueries and not view.narrow):
      @["Button group: " & $names.len & " buttons side by side, " &
        "sharing the row's width equally (" & names.join(", ") &
        "), 12px or more apart; each label centred in its button."]
    else:
      @["Button group: " & $names.len & " buttons one under another, " &
        "each the full width of the content (" & names.join(", ") &
        "), 12px or more apart."]
  else:
    @["Button group: " & $names.len & " buttons in a row (" &
      names.join(", ") & "), each as wide as its label, 12px or more " &
      "apart" & (if view.word: "" else: "; a button that does not fit " &
        "the line wraps to the next line, never overflowing") & "."]

proc buttonGroupDegradations(n: EmailNode; p: ButtonGroupProps;
    view: BriefView): seq[string] =
  if p.stack_on_mobile and (view.word or (view.headCss and
      view.mediaQueries and not view.narrow)):
    result.add("side by side, buttons whose labels wrap onto different " &
      "numbers of lines have different heights (a hybrid row's columns " &
      "are ragged, layout-patterns.md §3.3)")
  if p.stack_on_mobile and not view.word and not view.headCss:
    result.add("without head CSS the buttons stack, one per line at full " &
      "width, at every width (the hybrid row's safe state)")
  if not p.stack_on_mobile and view.word:
    result.add("Word lays the buttons on one row and never wraps it " &
      "(layout-patterns.md §3.5)")

# --- mailBadge -------------------------------------------------------------------

proc inTextLine(n: EmailNode): bool =
  ## True when the badge sits inside a line of text: a text element
  ## holds it, or text or inline elements stand beside it.
  let parent = n.parent
  if parent == nil or parent.kind != enElement:
    return false
  if parent.tag in textTags:
    return true
  for c in parent.children:
    if c == n:
      continue
    if c.kind == enText and c.text.strip().len > 0:
      return true
    if c.kind == enElement and c.tag in inlineTags:
      return true
  false

proc badgeStyle(ctx: ExpandCtx; node: EmailNode; tone, label: string) =
  let (fg, bg) = statColours(tone)
  # A 1px border in the tone's colour keeps the pill visible where its
  # tint is close to the surface, and where a client darkens the tint
  # with the canvas (an inverting dark mode keeps a border a line).
  let edge = if tone == "neutral": "color.text.secondary" else: fg
  ctx.r.setStyle(node, "border", "1px solid " & ctx.theme.lightFor(edge))
  if ctx.darkDesigned():
    ctx.r.setStyle(node, "@dark:border-color", "tok:" & edge)
  ctx.r.setStyle(node, "padding", "1px 9px")
  ctx.r.setStyle(node, "border-radius", "999px")
  useType(ctx, node, "type.small")
  ctx.r.setStyle(node, "font-weight", "700")
  if label.runeLen <= shortLabelChars:
    ctx.r.setStyle(node, "white-space", "nowrap")
  paint(ctx, node, "background-color", bg)
  # The label is the primary text colour on every tint (at least 11:1 in
  # both palettes): a tone's own colour on its tint is under 4.5:1 for
  # 14px text (primary 4.4:1, info 4.07:1); the tint and the border
  # carry the tone.
  paint(ctx, node, "color", "color.text.primary")

proc badgeExpand(n: EmailNode; p: BadgeProps; ctx: ExpandCtx): EmailNode =
  let tone = oneOf(n, p.tone, "tone", badgeTones)
  let content = inlineSlot(n, "its label (text)")
  let label = strutils.splitWhitespace(plainText(n)).join(" ")
  if label.len == 0:
    raise newException(PatternError, "mailBadge needs its label: the " &
      "text carries the meaning, never the colour alone")
  var html: EmailNode
  if ctx.target.outlookWord and not inTextLine(n):
    # The badge Word wrapper: Word pads a cell, never a span (caniemail
    # css-padding); MJML's mj-social item, an inline table.
    html = el(ctx, n, "table", attrs = [("role", "presentation"),
      ("border", "0"), ("cellpadding", "0"), ("cellspacing", "0")],
      styles = [("display", "inline-table"),
        ("border-collapse", "separate !important"),
        ("vertical-align", "middle")])
    let tr = el(ctx, n, "tr")
    let td = el(ctx, n, "td", attrs = [("align", "center")],
      styles = [("text-align", "center")])
    badgeStyle(ctx, td, tone, label)
    moveInto(ctx, td, content)
    add(ctx, tr, td)
    add(ctx, html, tr)
  else:
    html = el(ctx, n, "span", styles = [("display", "inline-block")])
    badgeStyle(ctx, html, tone, label)
    moveInto(ctx, html, content)
  # Inline: the text part's form follows the HTML in the badge's place
  # (left in the element, it follows the expansion), so a badge inside a
  # sentence stays in it.
  let t = el(ctx, n, "textOnly")
  add(ctx, t, ctx.r.createTextNode("[" & label & "]"))
  ctx.r.appendChild(n, t)
  result = el(ctx, n, "htmlOnly")
  add(ctx, result, html)

proc badgeExpected(n: EmailNode; p: BadgeProps; view: BriefView):
    seq[string] =
  let tone = p.tone.strip().toLowerAscii()
  @["Badge " & quoted(textOf(n)) & ": a small pill with fully rounded " &
    "ends, bold 14px dark text on the " & tone & " tone's light tint" &
    (if tone == "neutral": " (light grey)" else: "") &
    ", a thin border in the same colour, a little padding around the " &
    "label" & (if textOf(n).strip().runeLen <= shortLabelChars:
      ", on one line" else: ", wrapping onto further lines if it must") &
    (if inTextLine(n): ", in the line of text around it" else: "") & "."]

proc badgeDegradations(n: EmailNode; p: BadgeProps; view: BriefView):
    seq[string] =
  if view.word:
    if inTextLine(n):
      result.add("inside a line of text Word draws the badge unpadded " &
        "and square: its colours behind the label only " &
        "(layout-patterns.md §4.5)")
    else:
      result.add("Word draws the badge's corners square (border-radius, " &
        "R-TBL-16)")
  if view.client == "outlookWeb":
    result.add("in Outlook web's dark recolouring the badge's tint turns " &
      "as dark as the canvas: its border keeps the pill visible, and its " &
      "tone's text may be dim (the emulation's partial inversion, to be " &
      "calibrated against Outlook.com)")

# --- mailAvatarName ----------------------------------------------------------------

proc avatarNameLine(p: AvatarNameProps; rtl: bool): string =
  result = p.name.strip()
  if p.role.strip().len > 0:
    result.add(" — " & p.role.strip())
  discard rtl

proc avatarNameExpand(n: EmailNode; p: AvatarNameProps;
    ctx: ExpandCtx): EmailNode =
  let name = required(n, p.name, "a name", "the avatar says whose it is")
  let avatar = required(n, p.avatar, "an avatar", "the image beside the " &
    "name")
  if p.size < avatarMinPx or p.size > avatarMaxPx:
    raise newException(PatternError, "mailAvatarName size = " & $p.size &
      " is not " & $avatarMinPx & " to " & $avatarMaxPx & " px")
  let crop = oneOf(n, p.crop, "crop", ["circle", "none"])
  let side = el(ctx, n, "mailSidebar", attrs = [("side", "left"),
    ("fixed", $p.size & "px"), ("valign", "middle"), ("switch_below", "0")],
    styles = [("gap", "tok:space.3")])
  let alt = p.avatar_alt.strip()
  let img = el(ctx, n, "mailImage", attrs = [("src", avatar),
    ("crop", if crop == "circle": "circle" else: ""),
    ("decorative", if alt.len == 0: "true" else: "")],
    styles = [("width", $p.size & "px"), ("height", $p.size & "px")])
  ctx.r.setAttribute(img, "alt", alt)
  let who = el(ctx, n, "mailStack", styles = [("gap", "0")])
  add(ctx, who, el(ctx, n, "p", styles = [("margin", "0"),
    ("font-weight", "700")], text = name))
  if p.role.strip().len > 0:
    let r = el(ctx, n, "p", styles = [("margin", "0")], text = p.role.strip())
    useType(ctx, r, "type.small")
    paint(ctx, r, "color", "color.text.secondary")
    add(ctx, who, r)
  add(ctx, side, img, who)
  htmlAndText(ctx, n, side, [el(ctx, n, "p",
    text = avatarNameLine(p, isRtl(n)))])

proc avatarNameExpected(n: EmailNode; p: AvatarNameProps;
    view: BriefView): seq[string] =
  @["Avatar and name: a round " & $p.size & "px avatar at the " &
    startSide(n) & ", vertically centred beside the name \"" &
    p.name.strip() & "\" in bold" & (if p.role.strip().len > 0:
      " above the role \"" & p.role.strip() & "\" in smaller grey text"
    else: "") & "; the avatar is a circle in every client (its corners " &
    "transparent), never a square."]

proc avatarNameDegradations(n: EmailNode; p: AvatarNameProps;
    view: BriefView): seq[string] =
  if view.client == "imagesOff":
    if p.avatar_alt.strip().len == 0:
      result.add("with images off the decorative avatar shows nothing, or " &
        "the client's empty image box; the name beside it says who it is")
    else:
      result.add("with images off the avatar's alt text \"" &
        p.avatar_alt.strip() & "\" wraps inside its " & $p.size & "px box, " &
        "breaking a word the box is too narrow for, and may push the " &
        "name aside")

# --- mailDividerLabel ----------------------------------------------------------------

proc ruleCell(ctx: ExpandCtx; n: EmailNode; share: string): EmailNode =
  ## A rule cell: `share` of the row, a 1px line in a table of its own,
  ## vertically centred. The line is an empty cell's top border, never a
  ## painted cell: a client that inverts a message (Outlook web's dark
  ## mode) darkens a background with the canvas and keeps a border a
  ## visible line, as it does `mailDivider`'s.
  result = el(ctx, n, "td", attrs = [("width", share), ("valign", "middle"),
    ("aria-hidden", "true")], styles = [("width", share),
      ("padding", "16px 0"), ("vertical-align", "middle")])
  let t = layoutTable(ctx, n)
  let tr = el(ctx, n, "tr")
  let line = spacerCell(ctx, n)
  # Longhands: the side's own colour property carries the light value
  # Thunderbird's copy of the dark rule pairs with (R-DRK-08).
  ctx.r.setStyle(line, "border-top-width", "1px")
  ctx.r.setStyle(line, "border-top-style", "solid")
  paint(ctx, line, "border-top-color", "color.border.subtle")
  add(ctx, tr, line)
  add(ctx, t, tr)
  add(ctx, result, t)

proc dividerLabelExpand(n: EmailNode; p: DividerLabelProps;
    ctx: ExpandCtx): EmailNode =
  let content = inlineSlot(n, "its label (text)")
  let label = strutils.splitWhitespace(plainText(n)).join(" ")
  if label.len == 0:
    raise newException(PatternError, "mailDividerLabel needs its label")
  # Its own automatic layout: under the reset's fixed layout the label
  # would get a third of the row; automatic, it takes its text's width
  # and the rules share the rest.
  let table = layoutTable(ctx, n, [("table-layout", "auto !important")])
  let tr = el(ctx, n, "tr")
  let mid = el(ctx, n, "td", attrs = [("align", "center"),
    ("valign", "middle")], styles = [("padding", "16px 12px"),
      ("text-align", "center"), ("vertical-align", "middle")])
  let short = label.runeLen <= shortLabelChars
  if short:
    # One line, as wide as its text: the rules share the rest.
    ctx.r.setStyle(mid, "white-space", "nowrap")
  else:
    # A long label wraps in the middle 60%, a word too long for it
    # broken there (an automatic layout would otherwise grow the cell to
    # the word, past the message).
    ctx.r.setAttribute(mid, "width", "60%")
    ctx.r.setStyle(mid, "width", "60%")
    ctx.r.setStyle(mid, "word-break", "break-word")
    ctx.r.setStyle(mid, "overflow-wrap", "break-word")
  let share = if short: "50%" else: "20%"
  useType(ctx, mid, "type.small")
  paint(ctx, mid, "color", "color.text.secondary")
  moveInto(ctx, mid, content)
  add(ctx, tr, ruleCell(ctx, n, share), mid, ruleCell(ctx, n, share))
  add(ctx, table, tr)
  htmlAndText(ctx, n, table, [el(ctx, n, "p", text = "—— " & label & " ——")])

proc dividerLabelExpected(n: EmailNode; p: DividerLabelProps;
    view: BriefView): seq[string] =
  @["Labelled divider: a thin grey line across the content with the " &
    "word " & quoted(textOf(n)) & " in small grey text in its middle; the " &
    "line stops a little before the word on each side and is vertically " &
    "centred on it."]

# --- mailCoupon -------------------------------------------------------------------

proc couponExpand(n: EmailNode; p: CouponProps; ctx: ExpandCtx): EmailNode =
  let code = required(n, p.code, "a code", "the code is the coupon")
  let box = el(ctx, n, "mailBox", styles = [("padding", "16px 24px"),
    ("border-radius", "8px"), ("text-align", "center")])
  paint(ctx, box, "background-color", "color.surface.subtle")
  # Dashed: the box lowering gives its table the cell's background too,
  # so Outlook shows it between the dashes (R-TBL-08).
  themeBorder(ctx, box, "2px", "dashed", "color.accent.primary")
  let stack = el(ctx, n, "mailStack", attrs = [("align", "center")],
    styles = [("gap", "tok:space.2")])
  var lines: seq[string] = @[]
  if p.title.strip().len > 0:
    add(ctx, stack, el(ctx, n, "p", styles = [("margin", "0"),
      ("font-weight", "700"), ("text-align", "center")],
      text = p.title.strip()))
    lines.add(p.title.strip())
  let c = el(ctx, n, "p", styles = [("margin", "0"),
    ("font-family", "tok:font.mono"), ("font-size", "24px"),
    ("line-height", "32px"), ("font-weight", "700"),
    ("letter-spacing", "2px"), ("text-align", "center")])
  add(ctx, c, nolinkSpan(ctx, n, code))
  add(ctx, stack, c)
  lines.add(p.label.strip() & ": " & code)
  if p.hint.strip().len > 0:
    let h = el(ctx, n, "p", styles = [("margin", "0"),
      ("text-align", "center")], text = p.hint.strip())
    useType(ctx, h, "type.small")
    paint(ctx, h, "color", "color.text.secondary")
    add(ctx, stack, h)
    lines.add(p.hint.strip())
  add(ctx, box, stack)
  htmlAndText(ctx, n, box, [linesPara(ctx, n, lines)])

proc couponExpected(n: EmailNode; p: CouponProps; view: BriefView):
    seq[string] =
  @["Coupon: a light grey panel with a 2px dashed blue border and " &
    "rounded corners, its content centred: " & (if p.title.len > 0:
      "the bold line \"" & p.title.strip() & "\", then " else: "") &
    "the code \"" & p.code.strip() & "\" large, bold, monospace and " &
    "letter-spaced, as plain text (never a blue link)" &
    (if p.hint.len > 0: ", then the small grey line \"" & p.hint.strip() &
      "\"" else: "") & "."]

proc couponDegradations(n: EmailNode; p: CouponProps; view: BriefView):
    seq[string] =
  if view.word:
    result.add("Word draws the coupon's corners square (border-radius, " &
      "R-TBL-16)")

# --- mailRatingScale ---------------------------------------------------------------

proc hiddenSpan(ctx: ExpandCtx; n: EmailNode; text: string): EmailNode =
  ## Text a screen reader reads inside a link and a screen does not show
  ## (R-A11Y-09's styles).
  el(ctx, n, "span", styles = visuallyHiddenStyles, text = text)

proc scoreHref(n: EmailNode; href: string; score: int): string =
  href.replace("{score}", $score)

proc ratingExpand(n: EmailNode; p: RatingScaleProps;
    ctx: ExpandCtx): EmailNode =
  let kind = oneOf(n, p.kind, "kind", ["nps", "stars"])
  let href = required(n, p.href, "an href", "the link for a score, with " &
    "{score} where the score goes")
  if "{score}" notin href:
    raise newException(PatternError, "mailRatingScale href = '" & href &
      "' has no {score}: every score needs its own link")
  let (lo, hi, top) = if kind == "nps": (0, 10, 10) else: (1, 5, 5)
  var low = p.low_label.strip()
  var high = p.high_label.strip()
  if kind == "nps":
    if low.len == 0: low = npsDefaultLow
    if high.len == 0: high = npsDefaultHigh
  var lines: seq[string] = @[]
  if low.len > 0 or high.len > 0:
    var ends: seq[string] = @[]
    if low.len > 0: ends.add($lo & " = " & low)
    if high.len > 0: ends.add($hi & " = " & high)
    lines.add(ends.join(if isRtl(n): "، " else: ", "))
  for k in lo .. hi:
    lines.add($k & ": " & scoreHref(n, href, k))
  let stack = el(ctx, n, "mailStack", styles = [("gap", $ratingGapPx & "px")])
  if kind == "stars":
    let row = el(ctx, n, "mailCluster", attrs = [("align", startSide(n))],
      styles = [("gap", $ratingGapPx & "px"),
        ("row_gap", $ratingGapPx & "px")])
    for k in lo .. hi:
      let a = el(ctx, n, "a", attrs = [("href", scoreHref(n, href, k))],
        styles = [("display", "inline-block"),
          ("width", $ratingTargetPx & "px"),
          ("height", $ratingTargetPx & "px"),
          ("line-height", $ratingTargetPx & "px"),
          ("font-size", "28px"), ("text-align", "center"),
          ("text-decoration", "none")])
      paint(ctx, a, "color", "color.accent.primary")
      add(ctx, a, el(ctx, n, "span", attrs = [("aria-hidden", "true")],
        text = ratingStar))
      add(ctx, a, hiddenSpan(ctx, n, "Rate " & $k & " out of " & $top))
      add(ctx, row, a)
    add(ctx, stack, row)
  else:
    for (a0, b0) in [(0, 5), (6, 10)]:
      let row = el(ctx, n, "mailColumns", attrs = [("strategy", "cells"),
        ("gutter", $ratingGapPx & "px"), ("valign", "middle")])
      for k in a0 .. a0 + 5:
        let col = el(ctx, n, "mailColumn", attrs = [("min_width", "40px")])
        if k <= b0:
          paint(ctx, col, "background-color", "color.surface.subtle")
          themeBorder(ctx, col, "1px", "solid", "color.border.subtle")
          ctx.r.setStyle(col, "border-radius", "6px")
          let link = el(ctx, n, "a", attrs = [("href",
            scoreHref(n, href, k))], styles = [("display", "block"),
              ("padding", "12px 0"), ("font-size", "16px"),
              ("line-height", "20px"), ("font-weight", "700"),
              ("text-align", "center"), ("text-decoration", "none")])
          paint(ctx, link, "color", "color.text.primary")
          add(ctx, link, hiddenSpan(ctx, n, "Rate "))
          add(ctx, link, ctx.r.createTextNode($k))
          add(ctx, link, hiddenSpan(ctx, n, " out of " & $top))
          add(ctx, col, link)
        else:
          # The second row's sixth slot: empty, so its cells line up
          # with the first row's.
          add(ctx, col, el(ctx, n, "div", attrs = [("aria-hidden", "true")],
            text = "\u00a0"))
        add(ctx, row, col)
      add(ctx, stack, row)
  if low.len > 0 or high.len > 0:
    let ends = el(ctx, n, "mailColumns", attrs = [("strategy", "cells"),
      ("gutter", $ratingGapPx & "px")])
    for (label, side) in [(low, startSide(n)), (high, endSide(n))]:
      let col = el(ctx, n, "mailColumn", attrs = [("min_width", "100px")])
      let para = el(ctx, n, "p", styles = [("margin", "0"),
        ("text-align", side)], text = (if label.len > 0: label
          else: "\u00a0"))
      useType(ctx, para, "type.small")
      paint(ctx, para, "color", "color.text.secondary")
      add(ctx, col, para)
      add(ctx, ends, col)
    add(ctx, stack, ends)
  htmlAndText(ctx, n, stack, [linesPara(ctx, n, lines)])

proc ratingExpected(n: EmailNode; p: RatingScaleProps; view: BriefView):
    seq[string] =
  let kind = p.kind.strip().toLowerAscii()
  var ends = ""
  let low = if p.low_label.len > 0: p.low_label.strip()
    elif kind == "nps": npsDefaultLow else: ""
  let high = if p.high_label.len > 0: p.high_label.strip()
    elif kind == "nps": npsDefaultHigh else: ""
  if low.len > 0 or high.len > 0:
    ends = "; under it, in small grey text, \"" & low & "\" at the " &
      startSide(n) & " and \"" & high & "\" at the " & endSide(n)
  if kind == "nps":
    @["Rating scale (0 to 10): two rows of light grey rounded boxes with " &
      "a thin border, 0 to 5 in the first and 6 to 10 in the second, " &
      "each holding its number in bold, centred; the two rows' boxes line " &
      "up (the second row's last slot is empty), every box 44px tall, " &
      "8px apart, nothing overflowing at 320px" & ends & "."]
  else:
    @["Rating scale (stars): five blue stars in a row at the " &
      startSide(n) & ", each in its own 44px square (no visible box), " &
      "8px apart" & ends & "."]

# --- mailSecurityCode -------------------------------------------------------------------

proc securityCodeExpand(n: EmailNode; p: SecurityCodeProps;
    ctx: ExpandCtx): EmailNode =
  let code = required(n, p.code, "a code", "the code is the message")
  let expires = required(n, p.expires, "an expiry", "a code says, in " &
    "absolute time, when it stops working")
  if p.href.strip().len > 0:
    discard required(n, p.cta, "a cta", "the magic link's button label")
  let box = el(ctx, n, "mailBox", styles = [("padding", "24px"),
    ("border-radius", "8px"), ("text-align", "center")])
  paint(ctx, box, "background-color", "color.surface.subtle")
  let stack = el(ctx, n, "mailStack", attrs = [("align", "center")],
    styles = [("gap", "tok:space.3")])
  proc small(text: string): EmailNode =
    result = el(ctx, n, "p", styles = [("margin", "0"),
      ("text-align", "center")], text = text)
    useType(ctx, result, "type.small")
    paint(ctx, result, "color", "color.text.secondary")
  add(ctx, stack, small(p.label.strip()))
  let c = el(ctx, n, "p", styles = [("margin", "0"),
    ("font-family", "tok:font.mono"), ("font-size", "32px"),
    ("line-height", "40px"), ("font-weight", "700"),
    ("letter-spacing", "6px"), ("text-align", "center")])
  add(ctx, c, nolinkSpan(ctx, n, code))
  add(ctx, stack, c)
  add(ctx, stack, small(p.expires_label.strip() & " " & expires))
  var text = @[el(ctx, n, "p", text = p.label.strip() & ": " & code & " (" &
    lowerFirst(p.expires_label.strip()) & " " & expires & ")")]
  if p.href.strip().len > 0:
    add(ctx, stack, el(ctx, n, "mailButton", attrs = [("href",
      p.href.strip()), ("align", "center")], text = p.cta.strip()))
    text.add(el(ctx, n, "p", text = p.cta.strip() & ": " & p.href.strip()))
  add(ctx, box, stack)
  htmlAndText(ctx, n, box, text)

proc securityCodeExpected(n: EmailNode; p: SecurityCodeProps;
    view: BriefView): seq[string] =
  @["Security code: a light grey panel with rounded corners, its content " &
    "centred: the small grey label \"" & p.label.strip() & "\", the code \"" &
    p.code.strip() & "\" very large, bold, monospace and letter-spaced, as " &
    "plain text (never a blue link), then the small grey line \"" &
    p.expires_label.strip() & " " & p.expires.strip() & "\"" &
    (if p.href.len > 0: ", then a \"" & p.cta.strip() & "\" button" else: "") &
    "."]

# --- mailAppBadges -----------------------------------------------------------------------

proc appBadgeAlt(n: EmailNode; ip: AppBadgeProps): string =
  if ip.alt.strip().len > 0:
    return ip.alt.strip()
  for (store, alt) in appBadgeDefaultAlts:
    if ip.store.strip().toLowerAscii() == store:
      return alt
  raise newException(PatternError, "mailAppBadge store = '" & ip.store &
    "' needs an alt: what the badge says")

proc appBadgesExpand(n: EmailNode; p: AppBadgesProps;
    ctx: ExpandCtx): EmailNode =
  let items = slotOf(n, ["mailAppBadge"], "mailAppBadge items")
  if items.len == 0:
    raise newException(PatternError, "mailAppBadges needs at least one " &
      "mailAppBadge")
  if p.height < appBadgeMinPx or p.height > appBadgeMaxPx:
    raise newException(PatternError, "mailAppBadges height = " &
      $p.height & " is not " & $appBadgeMinPx & " to " & $appBadgeMaxPx &
      " px (a badge is 40px tall at least)")
  let quarter = int(ceil(float(p.height) / 4.0))
  let gap =
    if p.gap.strip().len > 0: gapPx(n, ctx, p.gap, "gap")
    else: max(buttonGroupMinGapPx, quarter)
  if gap < quarter:
    raise newException(PatternError, "mailAppBadges gap = '" & p.gap &
      "' is below a quarter of the badge height (" & $quarter & "px): " &
      "a badge keeps its clear space")
  let align = oneOf(n, p.align, "align", ["left", "center", "right"])
  let row = el(ctx, n, "mailCluster", attrs = [("align", align)],
    styles = [("gap", $gap & "px"), ("row_gap", $gap & "px")])
  var lines: seq[string] = @[]
  for it in items:
    let ip = readProps[AppBadgeProps](it)
    let store = oneOf(it, ip.store, "store", ["apple", "google", "other"])
    discard store
    let href = required(it, ip.href, "an href", "the badge links to the " &
      "store")
    let image = required(it, ip.image, "an image", "the store's official " &
      "badge artwork")
    if ip.width <= 0:
      raise newException(PatternError, "mailAppBadge needs a width: the " &
        "badge's px width at the row's height")
    let alt = appBadgeAlt(it, ip)
    let img = el(ctx, n, "mailImage", attrs = [("src", image),
      ("href", href)], styles = [("width", $ip.width & "px"),
        ("height", $p.height & "px")])
    ctx.r.setAttribute(img, "alt", alt)
    if ip.dark_image.strip().len > 0 and ctx.darkDesigned():
      ctx.r.setAttribute(img, "dark_src", ip.dark_image.strip())
    add(ctx, row, img)
    lines.add(alt & ": " & href)
  for it in items:
    ctx.r.removeChild(n, it)
  htmlAndText(ctx, n, row, [linesPara(ctx, n, lines)])

proc appBadgesExpected(n: EmailNode; p: AppBadgesProps; view: BriefView):
    seq[string] =
  var alts: seq[string] = @[]
  for c in slot(n):
    if c.kind == enElement:
      let a = c.attrs.getOrDefault("alt", "")
      alts.add(if a.len > 0: "\"" & a & "\"" else:
        "the " & c.attrs.getOrDefault("store", "other") & " store's")
  @["App badges: " & $alts.len & " store badge" &
    (if alts.len == 1: "" else: "s") & " (" & alts.join(", ") & "), each " &
    $p.height & "px tall, side by side and " & alignWordOf(p.align) &
    ", a quarter of their height or more apart; their artwork sharp, " &
    "never stretched."]

proc appBadgesDegradations(n: EmailNode; p: AppBadgesProps;
    view: BriefView): seq[string] =
  if not view.word:
    result.add("a row that wraps keeps its last badge's gap on each " &
      "wrapped line, so a wrapped, centred line sits a few pixels to the " &
      "left of the last one (layout-patterns.md §3.5)")
  if view.client == "imagesOff":
    result.add("with images off each badge shows its alt text in its " &
      "box (\"Download on the App Store\"), the box as large as the badge")

# --- Registration --------------------------------------------------------------------

defineMailPattern(mailButtonGroup, ButtonGroupProps, buttonGroupExpand,
  buttonGroupExpected, buttonGroupDegradations)
defineMailPattern(mailBadge, BadgeProps, badgeExpand, badgeExpected,
  badgeDegradations)
defineMailPattern(mailAvatarName, AvatarNameProps, avatarNameExpand,
  avatarNameExpected, avatarNameDegradations)
defineMailPattern(mailDividerLabel, DividerLabelProps, dividerLabelExpand,
  dividerLabelExpected, noLines[DividerLabelProps])
defineMailPattern(mailCoupon, CouponProps, couponExpand, couponExpected,
  couponDegradations)
defineMailPattern(mailRatingScale, RatingScaleProps, ratingExpand,
  ratingExpected, noLines[RatingScaleProps])
defineMailPattern(mailSecurityCode, SecurityCodeProps, securityCodeExpand,
  securityCodeExpected, noLines[SecurityCodeProps])
defineMailPattern(mailAppBadges, AppBadgesProps, appBadgesExpand,
  appBadgesExpected, appBadgesDegradations)
