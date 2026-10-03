## isonim_email/navigation.nim — `mailSocial` and `mailNavbar`: rows of
## links built on `mailCluster`.
##
## Both are compositions, registered as patterns: they expand, before
## validation, into a `mailCluster` (the div-first wrapping row with
## Word's single-row ghost table, `lower/cluster.nim`), so every later
## pass sees ordinary vocabulary.
##
## - `mailSocial(align = center, icon_size = 24, mode = auto, gap =
##   space.3)` holds `mailSocialItem(network, href, icon)`s. Each item
##   expands into a linked `mailImage` `icon_size` px square whose `alt`
##   is the network's name (catalogue R-IMG-12). The built-in icons are
##   monogram plates, PNG at 64×64 (`tools/social-icons/generate.py`),
##   embedded at compile time and published like any compile-time asset:
##   `light` (a dark plate for light backgrounds) and `dark` (a light
##   plate for dark ones). `mode = auto` is `light` until the dark-image
##   swap exists (R-IMG-06): a plate carries its own contrast, so it
##   stays legible on a dark band. An `icon` of the application's own
##   replaces the built-in one; a network without a built-in icon needs
##   one.
## - `mailNavbar(align = center, separator, gap = space.5)` holds
##   `mailNavLink(href)`s, each expanding into a link: `color.link`
##   (dark-paired under `darkMode = designed`), bold, not
##   underlined, `type.body`, `display:inline-block;padding:10px 0` for
##   a 44px hit area (R-TXT-12), wrapped lines 8px apart (R-TBL-12).
##   There is no collapsing menu: the row wraps.
##
## The items stay in the tree as expanded patterns around what they
## became, so P1 checks their destinations (R-BTN-07) and the brief
## reads their props. Importing this module registers the four (like
## `primitives.nim`).
##
## Pure tree building: identical on the C and JS targets.

{.used.}

import std/[strutils, tables]
import ./renderer
import ./target
import ./assets
import ./patterns
import ./passes/layout
import ./style/tokens
import ./style/shorthand
from ./lower/table_style import hasLongWord
from ./lower/image import altFitsOneLine, altStyle

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const socialNetworks* = [
  ("facebook", "Facebook"), ("x", "X"), ("linkedin", "LinkedIn"),
  ("instagram", "Instagram"), ("youtube", "YouTube"),
  ("github", "GitHub"), ("mastodon", "Mastodon"), ("bluesky", "Bluesky"),
  ("email", "Email"), ("website", "Website")]
  ## The networks with a built-in icon, and their names (the alt text).

const socialIconFiles = [
  ("social-facebook-light.png",
    staticRead("assets/social/social-facebook-light.png")),
  ("social-facebook-dark.png",
    staticRead("assets/social/social-facebook-dark.png")),
  ("social-x-light.png", staticRead("assets/social/social-x-light.png")),
  ("social-x-dark.png", staticRead("assets/social/social-x-dark.png")),
  ("social-linkedin-light.png",
    staticRead("assets/social/social-linkedin-light.png")),
  ("social-linkedin-dark.png",
    staticRead("assets/social/social-linkedin-dark.png")),
  ("social-instagram-light.png",
    staticRead("assets/social/social-instagram-light.png")),
  ("social-instagram-dark.png",
    staticRead("assets/social/social-instagram-dark.png")),
  ("social-youtube-light.png",
    staticRead("assets/social/social-youtube-light.png")),
  ("social-youtube-dark.png",
    staticRead("assets/social/social-youtube-dark.png")),
  ("social-github-light.png",
    staticRead("assets/social/social-github-light.png")),
  ("social-github-dark.png",
    staticRead("assets/social/social-github-dark.png")),
  ("social-mastodon-light.png",
    staticRead("assets/social/social-mastodon-light.png")),
  ("social-mastodon-dark.png",
    staticRead("assets/social/social-mastodon-dark.png")),
  ("social-bluesky-light.png",
    staticRead("assets/social/social-bluesky-light.png")),
  ("social-bluesky-dark.png",
    staticRead("assets/social/social-bluesky-dark.png")),
  ("social-email-light.png",
    staticRead("assets/social/social-email-light.png")),
  ("social-email-dark.png", staticRead("assets/social/social-email-dark.png")),
  ("social-website-light.png",
    staticRead("assets/social/social-website-light.png")),
  ("social-website-dark.png",
    staticRead("assets/social/social-website-dark.png")),
]
  ## The built-in icons' bytes (`src/isonim_email/assets/social/`).

var socialIconPaths = initTable[string, string]()
  ## Icon file name → its content-hashed path, filled at start-up.

proc registerSocialIcons() =
  for (name, bytes) in socialIconFiles:
    let a = loadAsset(name, bytes)
    discard registerCompiledAsset(a)
    socialIconPaths[name] = hostedPath(a)

registerSocialIcons()

proc socialName*(network: string): string =
  ## A built-in network's name, "" for any other.
  for (id, name) in socialNetworks:
    if id == network.strip().toLowerAscii():
      return name
  ""

proc socialIcon*(network, variant: string): string =
  ## The content-hashed path of a built-in icon (`light` or `dark`),
  ## "" when the network has none.
  socialIconPaths.getOrDefault("social-" & network.strip().toLowerAscii() &
    "-" & variant & ".png", "")

type
  SocialProps* = object
    ## `mailSocial`.
    align*: string = "center"
    icon_size*: string = "24"
    mode*: string = "auto"
    gap*: string

  SocialItemProps* = object
    ## `mailSocialItem`.
    network*: string
    href*: string
    icon*: string

  NavbarProps* = object
    ## `mailNavbar`.
    align*: string = "center"
    separator*: string
    gap*: string

  NavLinkProps* = object
    ## `mailNavLink`.
    href*: string

proc iconPx*(p: SocialProps): int =
  ## `icon_size` in whole px; raises `PatternError` outside 16–48.
  var v = p.icon_size.strip().toLowerAscii()
  if v.endsWith("px"):
    v = v[0 ..< ^2].strip()
  try:
    result = parseInt(v)
  except ValueError:
    raise newException(PatternError, "mailSocial icon_size '" &
      p.icon_size & "' is not a px length")
  if result < 16 or result > 48:
    raise newException(PatternError, "mailSocial icon_size " & $result &
      "px is outside 16–48 px (R-IMG-12)")

proc variantOf(p: SocialProps): string =
  case p.mode.strip().toLowerAscii()
  of "dark": "dark"
  of "light", "auto", "": "light"
  else:
    raise newException(PatternError, "mailSocial mode '" & p.mode &
      "' is not light, dark or auto")

proc socialOf(n: EmailNode): EmailNode =
  ## The `mailSocial` around an item, or nil.
  var a = n.parent
  while a != nil:
    if a.kind == enElement and a.tag == "mailSocial":
      return a
    a = a.parent
  nil

proc el(ctx: ExpandCtx; n: EmailNode; tag: string): EmailNode =
  result = ctx.r.createElement(tag)
  result.origin = n.origin

# --- mailSocial ---------------------------------------------------------------

proc socialExpand(n: EmailNode; p: SocialProps; ctx: ExpandCtx): EmailNode =
  discard iconPx(p)
  discard variantOf(p)
  result = el(ctx, n, "mailCluster")
  ctx.r.setAttribute(result, "align", p.align)
  ctx.r.setStyle(result, "gap",
    if p.gap.len > 0: p.gap else: "tok:space.3")
  let kids = n.children
  for c in kids:
    if c.kind == enText and c.text.strip().len == 0:
      continue
    if c.kind != enElement or c.tag notin ["mailSocialItem", "mailIf"]:
      raise newException(PatternError, "mailSocial holds only " &
        "mailSocialItem children (found " &
        (if c.kind == enElement: "<" & c.tag & ">" else: "text") & ")")
    ctx.r.appendChild(result, c)

proc socialItemExpand(n: EmailNode; p: SocialItemProps;
    ctx: ExpandCtx): EmailNode =
  let social = socialOf(n)
  let sp = if social != nil: readProps[SocialProps](social)
    else: SocialProps()
  let size = iconPx(sp)
  let network = p.network.strip()
  if network.len == 0:
    raise newException(PatternError, "mailSocialItem needs a network")
  var src = p.icon.strip()
  if src.len == 0:
    src = socialIcon(network, variantOf(sp))
    if src.len == 0:
      raise newException(PatternError, "mailSocialItem network '" &
        network & "' has no built-in icon: give it an icon (R-IMG-12)")
  let name = socialName(network)
  result = el(ctx, n, "mailImage")
  ctx.r.setAttribute(result, "src", src)
  ctx.r.setAttribute(result, "alt", if name.len > 0: name else: network)
  ctx.r.setStyle(result, "width", $size & "px")
  ctx.r.setStyle(result, "height", $size & "px")
  ctx.r.setAttribute(result, "href", p.href)
  if variantOf(sp) == "dark":
    # The light plates sit on a dark band: with images off, their alt
    # text is drawn light (R-IMG-03's contrast, on the band).
    ctx.r.setStyle(result, "color", ctx.theme.lightFor("color.text.inverse"))

proc names(n: EmailNode): seq[string] =
  for c in n.children:
    if c.kind == enElement and c.tag == "mailSocialItem":
      let net = c.attrs.getOrDefault("network", "")
      let name = socialName(net)
      result.add(if name.len > 0: name else: net)

proc socialExpected(n: EmailNode; p: SocialProps;
    view: BriefView): seq[string] =
  let nets = names(n)
  var size = p.icon_size.strip()
  if not size.endsWith("px"):
    size &= "px"
  let gap = if p.gap.len > 0 and not p.gap.startsWith("tok:"): p.gap
    else: "12px"
  if view.client == "imagesOff":
    return @["Social links: the " & $nets.len & " icons are blocked, so " &
      "each shows its alt text, the network's name (" & nets.join(", ") &
      "), side by side; nothing is missing or overlapping."]
  let plate = if variantOf(p) == "dark":
      "light grey circles with near-black initials"
    else: "dark grey circles with white initials"
  var line = "Social links: " & $nets.len & " round icons, " & size &
    " each (" & nets.join(", ") & "), " & plate &
    (if "YouTube" in nets: " (YouTube's is a play triangle)" else: "") &
    ", " & gap & " apart, " &
    (case p.align.toLowerAscii()
     of "left": "left-aligned"
     of "right": "right-aligned"
     else: "centred") & ", each a link"
  if view.word:
    line.add("; all on one line")
  @[line & "."]


const wordPhoneNote = "at a phone's width the Word approximation is no " &
  "real client (Word runs on desktops): a one-line row that runs past " &
  "that screen's edge there is the approximation's, not a defect"

proc socialDegradations(n: EmailNode; p: SocialProps;
    view: BriefView): seq[string] =
  if view.audience and view.family == cfApple:
    # R-IMG-03: WebKit draws a blocked image's alt only when it fits the
    # box on one line (W-IMG-ALT-FIT).
    var size = 24
    try:
      size = iconPx(p)
    except PatternError:
      discard
    var dropped: seq[string] = @[]
    for name in names(n):
      if not altFitsOneLine(name, size, altStyle(defaultTheme())):
        dropped.add("\"" & name & "\"")
    if dropped.len > 0:
      result.add("with images off, WebKit shows no alt text for the " &
        $size & "px icons " & dropped.join(", ") & " (it draws an alt " &
        "only when it fits the icon's width on one line, R-IMG-03)")
  if view.word:
    result.add("the icons stay on one line however narrow (Word never " &
      "wraps a table row)")
    if view.narrow:
      result.add(wordPhoneNote)

proc noLines[P](n: EmailNode; p: P; view: BriefView): seq[string] = @[]

# --- mailNavbar ---------------------------------------------------------------

proc navbarExpand(n: EmailNode; p: NavbarProps; ctx: ExpandCtx): EmailNode =
  result = el(ctx, n, "mailCluster")
  ctx.r.setAttribute(result, "align", p.align)
  ctx.r.setStyle(result, "gap",
    if p.gap.len > 0: p.gap else: "tok:space.5")
  # The links' own 10px padding spaces wrapped lines; 8px more keeps
  # their hit areas apart (R-TBL-12).
  ctx.r.setStyle(result, "row-gap", "8px")
  if p.separator.len > 0:
    ctx.r.setAttribute(result, "separator", p.separator)
    # The separators' colour (R-TXT-02: never a client's default).
    ctx.r.setStyle(result, "color", "tok:color.text.secondary")
    if ctx.target.darkMode == dmDesigned:
      ctx.r.setStyle(result, "@dark:color", "tok:color.text.secondary")
  let kids = n.children
  for c in kids:
    if c.kind == enText and c.text.strip().len == 0:
      continue
    if c.kind != enElement or c.tag notin ["mailNavLink", "mailIf"]:
      raise newException(PatternError, "mailNavbar holds only " &
        "mailNavLink children (found " &
        (if c.kind == enElement: "<" & c.tag & ">" else: "text") & ")")
    ctx.r.appendChild(result, c)

proc navLinkExpand(n: EmailNode; p: NavLinkProps;
    ctx: ExpandCtx): EmailNode =
  result = el(ctx, n, "a")
  ctx.r.setAttribute(result, "href", p.href)
  ctx.r.setStyle(result, "color", "tok:color.link")
  if ctx.target.darkMode == dmDesigned:
    ctx.r.setStyle(result, "@dark:color", "tok:color.link")
  ctx.r.setStyle(result, "text-decoration", "none")
  ctx.r.setStyle(result, "font-weight", "700")
  # The body's family: a link sets its own (R-TXT-02), or a client's
  # default face replaces it.
  ctx.r.setStyle(result, "font-family", "tok:font.body")
  for (k, v) in expandTypeSpec(ctx.theme.lightFor("type.body")):
    ctx.r.setStyle(result, k, v)
  ctx.r.setStyle(result, "display", "inline-block")
  ctx.r.setStyle(result, "padding", "10px 0")
  if hasLongWord(n):
    # A label too long for the line breaks inside the link (an inline
    # block sizes to its longest word otherwise; R-TBL-17); only there,
    # so Word's one-line row never squeezes short labels into pieces.
    ctx.r.setStyle(result, "word-break", "break-word")
  let kids = n.children
  for c in kids:
    ctx.r.appendChild(result, c)

proc linkTexts(n: EmailNode): seq[string] =
  proc textOf(x: EmailNode): string =
    if x.kind == enText:
      return x.text
    for c in x.children:
      result.add(textOf(c))
  for c in n.children:
    if c.kind == enElement and c.tag == "mailNavLink":
      result.add("\"" & splitWhitespace(textOf(c)).join(" ") & "\"")

proc navbarExpected(n: EmailNode; p: NavbarProps;
    view: BriefView): seq[string] =
  let links = linkTexts(n)
  let gap = if p.gap.len > 0 and not p.gap.startsWith("tok:"): p.gap
    else: "24px"
  var line = "Navigation: " & $links.len & " links (" & links.join(", ") &
    ") in a row, " &
    (case p.align.toLowerAscii()
     of "left": "left-aligned"
     of "right": "right-aligned"
     else: "centred") & ", " & gap & " apart" &
    (if p.separator.len > 0: ", separated by \"" & p.separator & "\""
     else: "") &
    ", in the link colour, bold, not underlined"
  if view.word:
    line.add("; Word lays out as many as fit the message's width on a " &
      "line and starts another line for the rest")
  else:
    line.add("; the row wraps onto further lines when it is full, never " &
      "overflowing and never collapsing into a menu")
  @[line & "."]

proc navbarDegradations(n: EmailNode; p: NavbarProps;
    view: BriefView): seq[string] =
  if view.word:
    if view.narrow:
      result.add(wordPhoneNote)
  else:
    result.add("a wrapped line ends with its last link's gap" &
      (if p.separator.len > 0: " and separator" else: "") &
      ", so a wrapped row is not flush with its edge (layout-patterns.md " &
      "§3.5)")

# --- Registration -------------------------------------------------------------

proc registerNavigation() =
  registerPattern(typedPattern[SocialProps]("mailSocial", socialExpand,
    socialExpected, socialDegradations))
  registerPattern(typedPattern[SocialItemProps]("mailSocialItem",
    socialItemExpand, noLines[SocialItemProps], noLines[SocialItemProps]))
  registerPattern(typedPattern[NavbarProps]("mailNavbar", navbarExpand,
    navbarExpected, navbarDegradations))
  registerPattern(typedPattern[NavLinkProps]("mailNavLink", navLinkExpand,
    noLines[NavLinkProps], noLines[NavLinkProps]))

registerNavigation()
