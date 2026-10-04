## isonim_email/content/containers.nim — the container patterns
## (layout-patterns.md §4.3): `mailCard`, `mailCallout`,
## `mailCodeBlock`, `codeInline` and `mailQuote`.
##
## Each is defined with `defineMailPattern` and expands only into
## primitives, scaffolding and leaves:
##
## - `mailCard(title, level, image, image_alt, decorative, image_ratio,
##   cta, cta_href, variant)` holding its body: a `mailBox` on the card
##   surface (bordered unless `plain`, a small shadow when `elevated`)
##   holding a `mailStack` of the image, the heading at the level the
##   context needs (`h3` by default), the body and a `mailButton`. Its
##   text part leaves the image out.
## - `mailCallout(tone, title, label, icon)` holding its body: a
##   `mailSidebar` whose 4px side is the accent drawn as a painted cell
##   (never `border-left`) beside a `mailBox` in the tone's background
##   colour; the title line starts with the tone word (`Warning: …`), so
##   the tone is never colour alone, and the text part writes it upper
##   case (`WARNING: …`).
## - `mailCodeBlock` holding the code: a `mailBox` on the subtle surface
##   holding a `pre` that wraps (`pre-wrap`, words broken, never a
##   scrollbar), its leading indentation turned into no-break spaces;
##   the text part is the code indented four spaces. `codeInline`: a
##   `code` on the same surface.
## - `mailQuote(name, role, avatar, avatar_alt, glyph)` holding the
##   quotation: a `mailStack` of the quotation in typographic quotes
##   (or under a large decorative `“`, hidden from screen readers) and
##   the attribution, beside the avatar in a `mailMediaObject` when there
##   is one; the text part is the quotation and `— Name, role`.
##
## A required prop that is missing, or content of the wrong kind, is a
## `PatternError` (`E-VOCAB-BAD-VALUE` at the element). Importing this
## module registers the five.
##
## Pure tree building: identical on the C and JS targets.

{.used.}

import std/[strutils, tables, unicode]
import ../renderer
import ../target
import ../patterns
import ../crop
import ../style/tokens
import ./kit

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  CardProps* = object
    ## `mailCard` (layout-patterns.md §4.3).
    title*: string
    level*: string = "h3"
    image*: string
    image_alt*: string
    decorative*: bool
    image_ratio*: string
    cta*: string
    cta_href*: string
    variant*: string = "bordered"

  CalloutProps* = object
    ## `mailCallout`.
    tone*: string = "info"
    title*: string
    label*: string ## the tone word (default per tone)
    icon*: string

  CodeBlockProps* = object ## `mailCodeBlock` (no props: the code is its content).

  CodeInlineProps* = object ## `codeInline` (no props).

  QuoteProps* = object
    ## `mailQuote`.
    name*: string
    role*: string
    avatar*: string
    avatar_alt*: string
    glyph*: bool

const
  calloutTones* = ["neutral", "primary", "info", "success", "warning",
    "danger"]
    ## A callout's tones (the `Tone` value type).
  calloutAccentPx* = 4
    ## The accent cell's width.
  calloutIconPx* = 24
    ## A callout icon's size.
  codeIndentPx* = 4
    ## Spaces a tab counts for in a code block's indentation.
  quoteAvatarPx* = 48
    ## A quotation's avatar size.
  inlineTags = ["span", "strong", "b", "em", "i", "u", "s", "small", "sup",
    "sub", "a", "code", "br", "codeInline"]
    ## Elements that sit in a line of text.

proc toneWord*(tone: string): string =
  ## The word a callout's title starts with for `tone`.
  case tone
  of "info": "Info"
  of "success": "Success"
  of "warning": "Warning"
  of "danger": "Error"
  else: "Note"

proc calloutColours*(tone: string): tuple[accent, bg: string] =
  ## The theme keys of a tone's accent and background.
  case tone
  of "neutral": ("color.text.secondary", "color.surface.subtle")
  of "primary": ("color.accent.primary", "color.surface.subtle")
  else: ("color.status." & tone, "color.status." & tone & ".bg")

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

proc border(ctx: ExpandCtx; node: EmailNode; width = "1px";
    token = "color.border.subtle") =
  ## A box's solid border in a theme colour (the `border` shorthand the
  ## layout pass reads), dark-paired under `designed`.
  ctx.r.setStyle(node, "border", width & " solid " &
    ctx.theme.lightFor(token))
  if ctx.darkDesigned():
    ctx.r.setStyle(node, "@dark:border-color", "tok:" & token)

# --- mailCard -------------------------------------------------------------------

proc cardExpand(n: EmailNode; p: CardProps; ctx: ExpandCtx): EmailNode =
  let variant = oneOf(n, p.variant, "variant", ["plain", "bordered",
    "elevated"])
  let level = oneOf(n, p.level, "level", ["h2", "h3", "h4"])
  if p.cta.strip().len > 0:
    discard required(n, p.cta_href, "a cta_href", "the CTA's destination")
  if p.image_ratio.len > 0:
    let c = parseCrop(p.image_ratio)
    if not c.ok or c.circle:
      raise newException(PatternError, "mailCard image_ratio = '" &
        p.image_ratio & "' is not W:H")
  result = el(ctx, n, "mailBox",
    attrs = [("shadow", if variant == "elevated": "sm" else: "")],
    styles = [("padding", "tok:space.5"), ("border-radius", "8px")])
  paint(ctx, result, "background-color", "color.surface.card")
  if variant != "plain":
    # A shadow always keeps its border (R-TBL-09).
    border(ctx, result)
  let stack = el(ctx, n, "mailStack", styles = [("gap", "tok:space.3")])
  if p.image.strip().len > 0:
    let img = el(ctx, n, "mailImage", attrs = [("src", p.image.strip()),
      ("crop", p.image_ratio.strip()),
      ("decorative", if p.decorative: "true" else: ""),
      # A card that a stacked row widens on a phone stays filled.
      ("fluid_on_mobile", "true")],
      styles = [("width", "100%")])
    ctx.r.setAttribute(img, "alt", p.image_alt.strip())
    # The image is the HTML's alone: the title says what the card is.
    let h = el(ctx, n, "htmlOnly")
    add(ctx, h, img)
    add(ctx, stack, h)
  if p.title.strip().len > 0:
    add(ctx, stack, el(ctx, n, level, styles = [("margin", "0")],
      text = p.title.strip()))
  let body = slot(n)
  if body.len > 0:
    let d = el(ctx, n, "div")
    moveInto(ctx, d, body)
    add(ctx, stack, d)
  if p.cta.strip().len > 0:
    add(ctx, stack, el(ctx, n, "mailButton", attrs = [("href",
      p.cta_href.strip())], text = p.cta.strip()))
  add(ctx, result, stack)

proc cardExpected(n: EmailNode; p: CardProps; view: BriefView): seq[string] =
  var parts: seq[string] = @[]
  if p.image.len > 0:
    parts.add("an image across its full width" &
      (if p.image_ratio.len > 0: " (" & p.image_ratio & ")" else: ""))
  if p.title.len > 0:
    parts.add("the heading " & quoted(p.title))
  if slot(n).len > 0:
    parts.add("its text " & quoted(textOf(n)))
  if p.cta.len > 0:
    parts.add("a \"" & p.cta.strip() & "\" button")
  let frame = case p.variant
    of "plain": "a padded card with no border"
    of "elevated": "a card with a 1px border and a soft shadow, rounded " &
      "corners"
    else: "a card with a 1px grey border and rounded corners"
  @["Card: " & frame & ", on the card colour, holding one under another: " &
    parts.join("; ") & ". Nothing touches its edges."]

proc cardDegradations(n: EmailNode; p: CardProps;
    view: BriefView): seq[string] =
  if view.word:
    result.add("Word draws the card's corners square" &
      (if p.variant == "elevated": " and no shadow" else: "") &
      " (R-TBL-16, R-TBL-09)")
  elif p.variant == "elevated" and view.client in ["gmailWeb", "ganga",
      "outlookWeb"]:
    result.add("no shadow: this client drops box-shadow; the card's " &
      "border marks its edge (R-TBL-09)")

# --- mailCallout ------------------------------------------------------------------

proc calloutLabel(p: CalloutProps; tone: string): string =
  if p.label.strip().len > 0: p.label.strip() else: toneWord(tone)

proc calloutTitle(p: CalloutProps; tone: string):
    tuple[html, text: string] =
  ## The title line as shown and as the text part writes it.
  let label = calloutLabel(p, tone)
  let title = p.title.strip()
  let up = unicode.toUpper(label)
  if title.len == 0:
    return (label, up)
  if unicode.toLower(title).startsWith(unicode.toLower(label)):
    return (title, up & title[label.len .. ^1])
  (label & ": " & title, up & ": " & title)

proc calloutExpand(n: EmailNode; p: CalloutProps;
    ctx: ExpandCtx): EmailNode =
  let tone = oneOf(n, p.tone, "tone", calloutTones)
  let (accentTok, bgTok) = calloutColours(tone)
  result = el(ctx, n, "mailSidebar", attrs = [("side", "left"),
    ("fixed", $calloutAccentPx & "px"), ("valign", "top"),
    ("switch_below", "0")], styles = [("gap", "0")])
  # The accent: a side with no text, painted, so it paints its whole
  # cell, the height of the row (never a border-left).
  let accent = el(ctx, n, "div", styles = [("font-size", "0.01px"),
    ("line-height", "0")], text = "\u00a0")
  paint(ctx, accent, "background-color", accentTok)
  let box = el(ctx, n, "mailBox", styles = [("padding", "12px 16px")])
  paint(ctx, box, "background-color", bgTok)
  let stack = el(ctx, n, "mailStack", styles = [("gap", "tok:space.2")])
  let (shown, written) = calloutTitle(p, tone)
  let titleP = el(ctx, n, "p", styles = [("margin", "0"),
    ("font-weight", "700")], text = shown)
  add(ctx, stack, htmlAndText(ctx, n, titleP,
    [el(ctx, n, "p", text = written)]))
  let body = slot(n)
  if body.len > 0:
    let d = el(ctx, n, "div")
    moveInto(ctx, d, body)
    add(ctx, stack, d)
  if p.icon.strip().len > 0:
    let inner = el(ctx, n, "mailSidebar", attrs = [("side", "left"),
      ("fixed", $calloutIconPx & "px"), ("valign", "top"),
      ("switch_below", "0")], styles = [("gap", "tok:space.3")])
    let img = el(ctx, n, "mailImage", attrs = [("src", p.icon.strip()),
      ("decorative", "true")], styles = [("width", $calloutIconPx & "px"),
        ("height", $calloutIconPx & "px")])
    # Decorative: the tone word carries the meaning.
    ctx.r.setAttribute(img, "alt", "")
    add(ctx, inner, img, stack)
    add(ctx, box, inner)
  else:
    add(ctx, box, stack)
  add(ctx, result, accent, box)

proc calloutExpected(n: EmailNode; p: CalloutProps;
    view: BriefView): seq[string] =
  let tone = p.tone.strip().toLowerAscii()
  let (shown, _) = calloutTitle(p, if tone in calloutTones: tone else: "info")
  @["Callout (" & tone & "): a 4px coloured bar down its " &
    (if isRtl(n): "right" else: "left") & " edge, the full height of a " &
    "tinted panel holding the bold line \"" & shown & "\"" &
    (if slot(n).len > 0: " above " & quoted(textOf(n)) else: "") &
    (if p.icon.len > 0: ", a 24px icon beside them" else: "") & "."]

proc calloutDegradations(n: EmailNode; p: CalloutProps;
    view: BriefView): seq[string] =
  if p.icon.len > 0 and view.client == "imagesOff":
    result.add("with images off, the decorative icon's 24px box may show " &
      "the client's broken-image mark (it has no alt text: the tone word " &
      "says what the icon would)")

# --- mailCodeBlock / codeInline ------------------------------------------------------

proc codeOf(nodes: seq[EmailNode]): string =
  ## The code as written: text, `br` a line break, tabs four spaces.
  proc walk(x: EmailNode; acc: var string) =
    case x.kind
    of enText:
      acc.add(x.text)
    of enElement:
      if x.tag == "br":
        acc.add('\n')
      else:
        for c in x.children:
          walk(c, acc)
    else:
      discard
  for n in nodes:
    walk(n, result)
  result = result.replace("\t", repeat(' ', codeIndentPx))

proc keepIndentation(node: EmailNode; atStart: var bool) =
  ## Leading indentation, in every line of the code under `node`, as
  ## no-break spaces (a tab four of them): a client that reflows white
  ## space keeps the code's shape.
  case node.kind
  of enText:
    var s = ""
    for ch in node.text:
      if ch == '\n':
        atStart = true
        s.add(ch)
      elif atStart and ch == ' ':
        s.add("\u00a0")
      elif atStart and ch == '\t':
        s.add(repeat("\u00a0", codeIndentPx))
      else:
        atStart = false
        s.add(ch)
    node.text = s
  of enElement:
    if node.tag == "br":
      atStart = true
    for c in node.children:
      keepIndentation(c, atStart)
  else:
    discard

proc codeSlot(n: EmailNode): seq[EmailNode] =
  ## The code: text and inline elements, a leading newline dropped (as
  ## HTML drops the one after `<pre>`).
  for c in n.children:
    if c.kind == enElement and c.tag notin inlineTags:
      raise newException(PatternError, n.tag & " holds text and inline " &
        "elements only (found <" & c.tag & ">)")
    if c.kind notin {enText, enElement}:
      continue
    result.add(c)
  if result.len > 0 and result[0].kind == enText:
    var t = result[0].text
    if t.startsWith("\r\n"): t = t[2 .. ^1]
    elif t.startsWith("\n"): t = t[1 .. ^1]
    result[0].text = t
  if result.len > 0 and result[^1].kind == enText:
    result[^1].text = result[^1].text.strip(leading = false)

proc codeBlockExpand(n: EmailNode; p: CodeBlockProps;
    ctx: ExpandCtx): EmailNode =
  let code = codeSlot(n)
  if code.len == 0 or codeOf(code).strip().len == 0:
    raise newException(PatternError, "mailCodeBlock needs its code")
  # The text part: the code verbatim, indented four spaces.
  var lines: seq[string] = @[]
  for l in codeOf(code).splitLines():
    lines.add(if l.strip().len == 0: "" else: "    " & l)
  let textPre = el(ctx, n, "pre", text = lines.join("\n"))
  let box = el(ctx, n, "mailBox", styles = [("padding", "12px 16px"),
    ("border-radius", "6px")])
  paint(ctx, box, "background-color", "color.surface.subtle")
  # Code reads left to right in any message, at the start of its line.
  let pre = el(ctx, n, "pre", attrs = [("dir", "ltr")],
    styles = [("margin", "0"),
    ("font-family", "tok:font.mono"), ("font-size", "14px"),
    ("line-height", "20px"), ("white-space", "pre-wrap"),
    ("word-break", "break-word"), ("overflow-wrap", "anywhere"),
    ("direction", "ltr"), ("text-align", "left")])
  var atStart = true
  for c in code:
    keepIndentation(c, atStart)
  moveInto(ctx, pre, code)
  add(ctx, box, pre)
  htmlAndText(ctx, n, box, [textPre])

proc codeBlockExpected(n: EmailNode; p: CodeBlockProps;
    view: BriefView): seq[string] =
  let lines = codeOf(slot(n)).strip(chars = {'\n', '\r'}).splitLines().len
  @["Code block: a grey panel with slightly rounded corners holding " &
    $lines & " line" & (if lines == 1: "" else: "s") & " of monospace " &
    "code; indentation kept, a line too long for the panel wrapping " &
    "inside it, never scrolling or running past its edge."]

proc codeInlineExpand(n: EmailNode; p: CodeInlineProps;
    ctx: ExpandCtx): EmailNode =
  # Left to right inside any sentence; a long token (a URL) breaks
  # rather than widen the line.
  result = el(ctx, n, "code", attrs = [("dir", "ltr")],
    styles = [("font-family", "tok:font.mono"),
    ("padding", "0 4px"), ("border-radius", "4px"),
    ("word-break", "break-word"), ("overflow-wrap", "anywhere")])
  paint(ctx, result, "background-color", "color.border.subtle")
  let kids = n.children # Copy: appendChild detaches as it moves.
  moveInto(ctx, result, kids)

proc codeInlineExpected(n: EmailNode; p: CodeInlineProps;
    view: BriefView): seq[string] =
  @["Inline code " & quoted(textOf(n)) & ": monospace, on a light grey " &
    "background, in the line of text around it."]

proc codeInlineDegradations(n: EmailNode; p: CodeInlineProps;
    view: BriefView): seq[string] =
  if view.word:
    result.add("Word draws no padding or rounded corners around inline " &
      "code (caniemail css-padding)")

# --- mailQuote ------------------------------------------------------------------

proc isInlineNode(c: EmailNode): bool =
  c.kind == enText or (c.kind == enElement and c.tag in inlineTags)

proc quoteExpand(n: EmailNode; p: QuoteProps; ctx: ExpandCtx): EmailNode =
  let name = required(n, p.name, "a name", "a quotation says whose it is")
  let content = slot(n)
  if content.len == 0:
    raise newException(PatternError, "mailQuote needs its quotation")
  # The quotation as paragraphs: inline content is one.
  var paras: seq[EmailNode] = @[]
  var allInline = true
  for c in content:
    if not isInlineNode(c):
      allInline = false
  if allInline:
    let para = el(ctx, n, "p")
    moveInto(ctx, para, content)
    paras.add(para)
  else:
    for c in content:
      if c.kind != enElement or c.tag != "p":
        raise newException(PatternError, "mailQuote holds inline content " &
          "or paragraphs (found " & (if c.kind == enElement: "<" & c.tag &
            ">" else: "text") & ")")
      paras.add(c)
  # The text part's copy, inside typographic quotes.
  var textParas: seq[EmailNode] = @[]
  for i, para in paras:
    let t = cloneNode(ctx, para)
    if i == 0:
      ctx.r.insertBefore(t, ctx.r.createTextNode("“"),
        if t.children.len > 0: t.children[0] else: nil)
    if i == paras.high:
      add(ctx, t, ctx.r.createTextNode("”"))
    textParas.add(t)
  for i, para in paras:
    ctx.r.setStyle(para, "font-size", "18px")
    ctx.r.setStyle(para, "line-height", "28px")
    ctx.r.setStyle(para, "margin", if i == paras.high: "0" else: "0 0 12px")
    if not p.glyph:
      if i == 0:
        ctx.r.insertBefore(para, ctx.r.createTextNode("“"),
          if para.children.len > 0: para.children[0] else: nil)
      if i == paras.high:
        add(ctx, para, ctx.r.createTextNode("”"))
  let stack = el(ctx, n, "mailStack", styles = [("gap", "tok:space.3")])
  if p.glyph:
    let g = el(ctx, n, "p", attrs = [("aria-hidden", "true")],
      styles = [("margin", "0"), ("font-family",
        "Georgia, 'Times New Roman', serif"), ("font-size", "56px"),
        # A mark sits in the top third of its em: a line box this short
        # ends just under it, so it stands close above the quotation,
        # and the padding keeps its top inside the paragraph.
        ("line-height", "4px"), ("padding-top", "28px"),
        ("font-weight", "700")], text = "“")
    paint(ctx, g, "color", "color.accent.primary")
    add(ctx, stack, g)
  let quote = el(ctx, n, "div")
  moveInto(ctx, quote, paras)
  add(ctx, stack, quote)
  let who = el(ctx, n, "div")
  add(ctx, who, el(ctx, n, "p", styles = [("margin", "0"),
    ("font-weight", "700")], text = name))
  if p.role.strip().len > 0:
    let r = el(ctx, n, "p", styles = [("margin", "0")],
      text = p.role.strip())
    useType(ctx, r, "type.small")
    paint(ctx, r, "color", "color.text.secondary")
    add(ctx, who, r)
  if p.avatar.strip().len > 0:
    let alt = p.avatar_alt.strip()
    let m = el(ctx, n, "mailMediaObject", attrs = [("image",
      p.avatar.strip()), ("image_width", $quoteAvatarPx),
      ("stack", "never"), ("valign", "middle"),
      ("decorative", if alt.len == 0: "true" else: "")],
      styles = [("gap", "tok:space.3")])
    ctx.r.setAttribute(m, "image_alt", alt)
    add(ctx, m, who)
    add(ctx, stack, m)
  else:
    add(ctx, stack, who)
  var line = "— " & name
  if p.role.strip().len > 0:
    line.add((if isRtl(n): "، " else: ", ") & p.role.strip())
  textParas.add(el(ctx, n, "p", text = line))
  htmlAndText(ctx, n, stack, textParas)

proc quoteExpected(n: EmailNode; p: QuoteProps;
    view: BriefView): seq[string] =
  @["Quotation: " & (if p.glyph: "a large decorative “ above " else: "") &
    "the quotation " & quoted(textOf(n)) & " in larger text" &
    (if p.glyph: "" else: " inside curly quotes") & ", then " &
    (if p.avatar.len > 0: "a 48px avatar beside " else: "") &
    "the name \"" & p.name.strip() & "\" in bold" &
    (if p.role.len > 0: " above the role \"" & p.role.strip() &
      "\" in smaller grey text" else: "") & "."]

# --- Registration -------------------------------------------------------------------

defineMailPattern(mailCard, CardProps, cardExpand, cardExpected,
  cardDegradations)
defineMailPattern(mailCallout, CalloutProps, calloutExpand, calloutExpected,
  calloutDegradations)
proc codeBlockDegradations(n: EmailNode; p: CodeBlockProps;
    view: BriefView): seq[string] =
  result.add("a line too long for the panel wraps to the start of the " &
    "next line, losing its indentation (never a horizontal scroll; " &
    "layout-patterns.md §4.3)")

defineMailPattern(mailCodeBlock, CodeBlockProps, codeBlockExpand,
  codeBlockExpected, codeBlockDegradations)
defineMailPattern(codeInline, CodeInlineProps, codeInlineExpand,
  codeInlineExpected, codeInlineDegradations)
defineMailPattern(mailQuote, QuoteProps, quoteExpand, quoteExpected,
  noLines[QuoteProps])
