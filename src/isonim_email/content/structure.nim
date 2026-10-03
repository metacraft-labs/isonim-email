## isonim_email/content/structure.nim — the structure patterns
## (layout-patterns.md §4.1): `mailHeader`, `mailViewInBrowser`,
## `mailBand`, `mailFooter` and `mailNavLinks`.
##
## Each is defined with `defineMailPattern` and expands only into
## primitives, scaffolding and leaves:
##
## - `mailHeader(logo, logo_width, logo_alt, logo_dark, href, align)`
##   holding up to three `a` links: a `mailSidebar` (the logo fixed at
##   its width, vertically centred) beside a `mailCluster` of the links
##   at the end of the line; more than three links stack under the
##   centred logo in a centred cluster; no links, the logo alone. Its
##   text part is the brand name (`logo_alt`) and the links.
## - `mailViewInBrowser(href, label, align)`: a small paragraph with the
##   link, in a section of its own (12px from the top) when it is the
##   document's child, which puts it right after the preheader (R-PRE-01);
##   its text part is `View in browser: url`.
## - `mailBand(background_color, padding, text_align)`: a full-width
##   `mailSection` carrying the band's props and styles (dark values
##   included). Adjacent bands that merge in dark mode are P10's
##   `W-DARK-BANDS-MERGE` (`passes/lint.lintBandsMerge`).
## - `mailFooter(address, unsubscribe, preferences, legal, reason,
##   transactional, …)`: a `mailStack` of its content (a `mailSocial`
##   row, typically), the reason, the address, a `·`-separated cluster of
##   the links and the 12px legal text (R-TXT-03 allows 12px here only),
##   all in `color.text.primary`, dark-paired under `designed` (the
##   secondary grey falls to 4.4:1 under either inversion model, below
##   the 4.5:1 the footer keeps in every palette).
## - `mailNavLinks(align, separator, gap, label)` holding `a` links: a
##   `mailNavbar` whose cluster is a navigation landmark (a one-cell
##   table with `role="navigation"`, R-A11Y-10); more than five links is
##   `W-PATTERN-NAV-LONG` (P1, `passes/validate.nim`).
##
## A required prop that is missing, or content of the wrong kind, is a
## `PatternError` (`E-VOCAB-BAD-VALUE` at the element). Importing this
## module registers the five.
##
## Pure tree building: identical on the C and JS targets.

{.used.}

import std/[strutils, tables]
import ../renderer
import ../target
import ../patterns
import ../primitives
import ../navigation
import ./kit

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  HeaderProps* = object
    ## `mailHeader` (layout-patterns.md §4.1).
    logo*: string
    logo_width*: string
    logo_alt*: string
    logo_dark*: string
    href*: string
    align*: string

  ViewInBrowserProps* = object
    ## `mailViewInBrowser`.
    href*: string
    label*: string = "View in browser"
    align*: string

  BandProps* = object
    ## `mailBand`.
    background_color*: string
    padding*: string
    text_align*: string

  FooterProps* = object
    ## `mailFooter`.
    address*: string
    unsubscribe*: string
    unsubscribe_label*: string = "Unsubscribe"
    preferences*: string
    preferences_label*: string = "Preferences"
    legal*: string
    reason*: string
    transactional*: bool
    align*: string = "center"
    color*: string ## the text colour (default `color.text.primary`)

  NavLinksProps* = object
    ## `mailNavLinks`.
    align*: string = "center"
    separator*: string
    gap*: string
    label*: string = "Navigation"

const
  headerInlineLinks* = 3
    ## Links beside the logo; more stack under it.
  headerLinksMin* = 120
    ## The links' side's minimum at a 320px document (R-TBL-11).
  navLinksMax* = 5
    ## Links in a `mailNavLinks` before `W-PATTERN-NAV-LONG`.
  footerLegalPx* = 12
    ## The footer's legal text size (R-TXT-03 allows it here only).

proc textOf(n: EmailNode): string =
  if n.kind == enText:
    return n.text
  for c in n.children:
    result.add(textOf(c))

proc labelsOf(links: seq[EmailNode]): string =
  var parts: seq[string] = @[]
  for l in links:
    parts.add("\"" & splitWhitespace(textOf(l)).join(" ") & "\"")
  parts.join(", ")

proc alignWord(a: string): string =
  case a
  of "center": "centred"
  of "right": "at the right"
  else: "at the left"

# --- mailHeader ---------------------------------------------------------------

proc headerLinks(n: EmailNode): seq[EmailNode] =
  slotOf(n, ["a"], "a links")

proc headerExpand(n: EmailNode; p: HeaderProps; ctx: ExpandCtx): EmailNode =
  let src = required(n, p.logo, "a logo", "the brand's logo image")
  let w = pxProp(n, p.logo_width, "logo_width")
  let links = headerLinks(n)
  let align = if p.align.len > 0:
      oneOf(n, p.align, "align", ["left", "center", "right"])
    else: startSide(n)
  let logo = el(ctx, n, "mailImage", attrs = [("src", src),
    ("alt", p.logo_alt.strip()), ("href", p.href.strip()),
    ("dark_src", p.logo_dark.strip())], styles = [("width", $w & "px")])
  var layout: EmailNode
  if links.len == 0:
    ctx.r.setAttribute(logo, "align", align)
    layout = logo
  elif links.len <= headerInlineLinks:
    layout = el(ctx, n, "mailSidebar", attrs = [("side", "left"),
      ("fixed", $w & "px"), ("valign", "middle")],
      styles = [("gap", "tok:space.4")])
    # Short links wrap inside their side: it is held to 120px at 320px
    # (R-TBL-11), not a text column's 160px.
    # A small row gap: a cluster keeps it below every line, which would
    # lift one line of links off the logo's middle.
    let row = el(ctx, n, "mailCluster", attrs = [("align", endSide(n)),
      ("min_width", $headerLinksMin & "px")],
      styles = [("gap", "tok:space.4"), ("row-gap", "4px")])
    moveInto(ctx, row, links)
    add(ctx, layout, logo, row)
  else:
    ctx.r.setAttribute(logo, "align", "center")
    layout = el(ctx, n, "mailStack", attrs = [("align", "center")],
      styles = [("gap", "tok:space.3")])
    let row = el(ctx, n, "mailCluster", attrs = [("align", "center")],
      styles = [("gap", "tok:space.4")])
    moveInto(ctx, row, links)
    add(ctx, layout, logo, row)
  # The text part: the brand name on a line, then the links.
  var text = @[el(ctx, n, "p", text = p.logo_alt.strip())]
  if links.len > 0:
    let copy = el(ctx, n, "mailCluster")
    for l in links:
      add(ctx, copy, cloneNode(ctx, l))
    text.add(copy)
  htmlAndText(ctx, n, layout, text)

proc headerExpected(n: EmailNode; p: HeaderProps;
    view: BriefView): seq[string] =
  let links = slot(n)
  var w = p.logo_width.strip()
  if not w.endsWith("px"):
    w.add("px")
  let logo = "the logo \"" & p.logo_alt & "\" (" & w & " wide" & (if p.href.len > 0: ", a link" else: "") & ")"
  if links.len == 0:
    return @["Header: " & logo & ", alone, " &
      alignWord(if p.align.len > 0: p.align else: "left") & "."]
  if links.len <= headerInlineLinks:
    @["Header: " & logo & " at the start of the line, vertically " &
      "centred against " & $links.len & " link" &
      (if links.len > 1: "s" else: "") & " (" & labelsOf(links) &
      ") at the other end of the same line, which stay side by side at " &
      "every width."]
  else:
    @["Header: " & logo & " centred, with its " & $links.len & " links (" &
      labelsOf(links) & ") centred in a row under it, which wraps when " &
      "it is full."]

proc headerDegradations(n: EmailNode; p: HeaderProps;
    view: BriefView): seq[string] =
  if p.logo_dark.len > 0:
    result.add("in a dark scheme, a client that applies no dark CSS " &
      "(Gmail, Yahoo, Thunderbird, Word) shows the light logo, which " &
      "must stay legible on its dark reading pane (R-DRK-06)")
  if slot(n).len > headerInlineLinks and view.word:
    result.add("Word lays the links out on one line, never wrapping " &
      "(a table row)")

# --- mailViewInBrowser --------------------------------------------------------

proc viewInBrowserExpand(n: EmailNode; p: ViewInBrowserProps;
    ctx: ExpandCtx): EmailNode =
  let href = required(n, p.href, "an href",
    "the hosted copy of the message")
  let label = if p.label.strip().len > 0: p.label.strip()
    else: "View in browser"
  let align = if p.align.len > 0:
      oneOf(n, p.align, "align", ["left", "center", "right"])
    else: endSide(n)
  let para = el(ctx, n, "p", styles = [("margin", "0"),
    ("text-align", align)])
  useType(ctx, para, "type.small")
  paint(ctx, para, "color", "color.text.secondary")
  let link = el(ctx, n, "a", attrs = [("href", href)], text = label)
  paint(ctx, link, "color", "color.text.secondary")
  add(ctx, para, link)
  # Text: `View in browser: url`.
  let line = el(ctx, n, "p", text = label & ": " & href)
  result = htmlAndText(ctx, n, para, [line])
  if n.parent != nil and n.parent.kind == enElement and
      n.parent.tag == "mailDocument":
    # A band of its own: a full section's padding would push the message
    # down for one small line.
    let band = el(ctx, n, "mailSection", styles = [("padding", "12px 0 0")])
    add(ctx, band, result)
    result = band

proc viewInBrowserExpected(n: EmailNode; p: ViewInBrowserProps;
    view: BriefView): seq[string] =
  let label = if p.label.len > 0: p.label else: "View in browser"
  @["A small \"" & label & "\" link (14px, grey) on a line of its own, " &
    alignWord(if p.align.len > 0: p.align else: endSide(n)) &
    ", above the rest of the message."]

proc noLines[P](n: EmailNode; p: P; view: BriefView): seq[string] = @[]

# --- mailBand -----------------------------------------------------------------

proc bandExpand(n: EmailNode; p: BandProps; ctx: ExpandCtx): EmailNode =
  discard required(n, p.background_color, "a background_color",
    "a band is its colour")
  result = el(ctx, n, "mailSection", attrs = [("full_width", "true")])
  # The band's props and styles, dark values included, are the
  # section's.
  for k, v in n.attrs.pairs:
    if k notin ["full_width"]:
      ctx.r.setAttribute(result, k, v)
  for k, v in n.styles.pairs:
    ctx.r.setStyle(result, k, v)
  moveInto(ctx, result, slot(n))

proc bandExpected(n: EmailNode; p: BandProps; view: BriefView): seq[string] =
  @["Band: a full-width " & p.background_color & " band from edge to edge " &
    "of the message, its content centred in the message's column."]

# --- mailFooter ---------------------------------------------------------------

proc footerExpand(n: EmailNode; p: FooterProps; ctx: ExpandCtx): EmailNode =
  let address = required(n, p.address, "an address",
    "a commercial message carries the sender's postal address")
  if p.unsubscribe.strip().len == 0 and not p.transactional:
    raise newException(PatternError, "mailFooter needs an unsubscribe " &
      "link unless transactional = true: a visible unsubscribe link " &
      "goes with every message a reader did not ask for")
  let align = oneOf(n, p.align, "align", ["left", "center", "right"])
  result = el(ctx, n, "mailStack", attrs = [("align", align)],
    styles = [("gap", "tok:space.3")])
  moveInto(ctx, result, slot(n))
  proc colour(node: EmailNode) =
    if p.color.strip().len > 0:
      ctx.r.setStyle(node, "color", p.color.strip())
    else:
      # Not the secondary grey: it reads at 4.4:1 once a client inverts
      # the message, below the footer's 4.5:1 in every palette.
      paint(ctx, node, "color", "color.text.primary")
  proc small(tag: string): EmailNode =
    result = el(ctx, n, tag, styles = [("margin", "0"),
      ("text-align", align)])
    useType(ctx, result, "type.small")
    colour(result)
  if p.reason.strip().len > 0:
    let r = small("p")
    add(ctx, r, ctx.r.createTextNode(p.reason.strip()))
    add(ctx, result, r)
  let adr = small("p")
  let lines = address.splitLines()
  for i, line in lines:
    if i > 0:
      add(ctx, adr, el(ctx, n, "br"))
    add(ctx, adr, ctx.r.createTextNode(line.strip()))
  add(ctx, result, adr)
  var links: seq[EmailNode] = @[]
  for (href, label) in [(p.unsubscribe, p.unsubscribe_label),
      (p.preferences, p.preferences_label)]:
    if href.strip().len > 0:
      let a = el(ctx, n, "a", attrs = [("href", href.strip())],
        text = label.strip())
      useType(ctx, a, "type.small")
      colour(a)
      links.add(a)
  if links.len > 0:
    let row = el(ctx, n, "mailCluster", attrs = [("align", align),
      ("separator", "·")], styles = [("gap", "tok:space.3")])
    colour(row)
    moveInto(ctx, row, links)
    add(ctx, result, row)
  if p.legal.strip().len > 0:
    let legal = small("p")
    ctx.r.setStyle(legal, "font-size", $footerLegalPx & "px")
    ctx.r.setStyle(legal, "line-height", "18px")
    add(ctx, legal, ctx.r.createTextNode(p.legal.strip()))
    add(ctx, result, legal)

proc footerExpected(n: EmailNode; p: FooterProps;
    view: BriefView): seq[string] =
  var parts: seq[string] = @[]
  if slot(n).len > 0:
    parts.add("its content (below)")
  if p.reason.len > 0:
    parts.add("the line \"" & p.reason.strip() & "\"")
  parts.add("the address \"" & p.address.strip().splitLines().join(", ") &
    "\"")
  var links: seq[string] = @[]
  if p.unsubscribe.len > 0:
    links.add("\"" & p.unsubscribe_label & "\"")
  if p.preferences.len > 0:
    links.add("\"" & p.preferences_label & "\"")
  if links.len > 0:
    parts.add("the links " & links.join(" · ") & " separated by a dot")
  if p.legal.len > 0:
    parts.add("the legal text in smaller (12px) type")
  @["Footer, " & alignWord(p.align) & ", in small (14px) text, one line " &
    "under another: " & parts.join("; ") & ". Every line readable on " &
    "the footer's background."]

# --- mailNavLinks -------------------------------------------------------------

proc navLinksExpand(n: EmailNode; p: NavLinksProps;
    ctx: ExpandCtx): EmailNode =
  let links = slotOf(n, ["a"], "a links")
  if links.len == 0:
    raise newException(PatternError, "mailNavLinks needs at least one link")
  result = el(ctx, n, "mailNavbar", attrs = [("align", p.align),
    ("separator", p.separator), ("role", "navigation"),
    ("label", if p.label.strip().len > 0: p.label.strip() else: "Navigation")],
    styles = [("gap", p.gap)])
  for a in links:
    let nl = el(ctx, n, "mailNavLink",
      attrs = [("href", a.attrs.getOrDefault("href", ""))])
    nl.origin = a.origin
    let kids = a.children # Copy: appendChild detaches as it moves.
    moveInto(ctx, nl, kids)
    add(ctx, result, nl)
    # The link became the navigation link: nothing of it follows.
    ctx.r.removeChild(n, a)

proc navLinksExpected(n: EmailNode; p: NavLinksProps;
    view: BriefView): seq[string] =
  let links = slot(n)
  var line = "Navigation: " & $links.len & " links (" & labelsOf(links) &
    ") in a row, " & alignWord(p.align) &
    (if p.separator.len > 0: ", separated by \"" & p.separator & "\""
     else: "") & ", in the link colour, bold, not underlined"
  if view.word:
    line.add("; Word lays out as many as fit the message's width on a " &
      "line and starts another line for the rest")
  else:
    line.add("; the row wraps onto further lines when it is full, never " &
      "overflowing and never collapsing into a menu")
  @[line & "."]

proc navLinksDegradations(n: EmailNode; p: NavLinksProps;
    view: BriefView): seq[string] =
  if not view.word:
    result.add("a wrapped line ends with its last link's gap" &
      (if p.separator.len > 0: " and separator" else: "") &
      ", so a wrapped row is not flush with its edge (layout-patterns.md " &
      "§3.5)")

# --- Registration -------------------------------------------------------------

defineMailPattern(mailHeader, HeaderProps, headerExpand, headerExpected,
  headerDegradations)
defineMailPattern(mailViewInBrowser, ViewInBrowserProps,
  viewInBrowserExpand, viewInBrowserExpected, noLines[ViewInBrowserProps])
defineMailPattern(mailBand, BandProps, bandExpand, bandExpected,
  noLines[BandProps])
proc footerDegradations(n: EmailNode; p: FooterProps;
    view: BriefView): seq[string] =
  if not view.word:
    result.add("where the links' row wraps, its first line ends with " &
      "the \"·\" separator (a cluster cannot know where it wraps; " &
      "layout-patterns.md §3.5)")

defineMailPattern(mailFooter, FooterProps, footerExpand, footerExpected,
  footerDegradations)
defineMailPattern(mailNavLinks, NavLinksProps, navLinksExpand,
  navLinksExpected, navLinksDegradations)
