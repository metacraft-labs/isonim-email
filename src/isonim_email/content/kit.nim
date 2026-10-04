## isonim_email/content/kit.nim — what the content patterns' expansions
## share: building elements, reading a pattern's content (its slot),
## px props, the direction an element sits in, and the HTML/text split
## a pattern uses when its plain-text form differs from what its
## expansion would write (`htmlOnly` beside `textOnly`).
##
## Pure tree building: identical on the C and JS targets.

import std/[strutils, tables]
import isonim/dsl/vocabulary
import ../renderer
import ../vocabulary as emailVocabulary
import ../target
import ../patterns
import ../style/shorthand
import ../style/tokens

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

proc el*(ctx: ExpandCtx; n: EmailNode; tag: string;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []; text = ""): EmailNode =
  ## A new element for `n`'s expansion, carrying `n`'s source span.
  result = ctx.r.createElement(tag)
  result.origin = n.origin
  for (k, v) in attrs:
    if v.len > 0:
      ctx.r.setAttribute(result, k, v)
  for (k, v) in styles:
    if v.len > 0:
      ctx.r.setStyle(result, k, v)
  if text.len > 0:
    ctx.r.appendChild(result, ctx.r.createTextNode(text))

proc add*(ctx: ExpandCtx; parent: EmailNode; kids: varargs[EmailNode]) =
  for k in kids:
    if k != nil:
      ctx.r.appendChild(parent, k)

proc slot*(n: EmailNode): seq[EmailNode] =
  ## The content written inside the pattern: its children, blank text
  ## aside.
  for c in n.children:
    if c.kind == enText and c.text.strip().len == 0:
      continue
    result.add(c)

proc slotOf*(n: EmailNode; tags: openArray[string]; what: string):
    seq[EmailNode] =
  ## The pattern's content, every item one of `tags`; anything else is
  ## a `PatternError` naming what the pattern holds.
  for c in slot(n):
    if c.kind != enElement or c.tag notin tags:
      raise newException(PatternError, n.tag & " holds only " & what &
        " (found " & (if c.kind == enElement: "<" & c.tag & ">"
          else: "text") & ")")
    result.add(c)

proc moveInto*(ctx: ExpandCtx; parent: EmailNode; nodes: seq[EmailNode]) =
  for c in nodes:
    ctx.r.appendChild(parent, c)

proc required*(n: EmailNode; value, name, why: string): string =
  ## `value` stripped; a `PatternError` when it is empty.
  result = value.strip()
  if result.len == 0:
    raise newException(PatternError, n.tag & " needs " & name & ": " & why)

proc pxProp*(n: EmailNode; value, name: string): int =
  ## A positive px length (`96` or `96px`); a `PatternError` otherwise.
  var v = value.strip().toLowerAscii()
  if v.endsWith("px"):
    v = v[0 ..< ^2].strip()
  try:
    result = parseInt(v)
  except ValueError:
    raise newException(PatternError, n.tag & " " & name & " = '" & value &
      "' is not a px length")
  if result <= 0:
    raise newException(PatternError, n.tag & " " & name & " = '" & value &
      "' is not a positive px length")

proc oneOf*(n: EmailNode; value, name: string;
    allowed: openArray[string]): string =
  ## `value` lower-cased, one of `allowed`; a `PatternError` otherwise.
  result = value.strip().toLowerAscii()
  if result notin allowed:
    raise newException(PatternError, n.tag & " " & name & " = '" & value &
      "' is not " & allowed.join(", "))

proc isRtl*(n: EmailNode): bool =
  ## True when `n` sits in a right-to-left row: the nearest `direction`
  ## of an ancestor, else the document's `dir`.
  var a = n
  while a != nil:
    if a.kind == enElement:
      let own = (a.attrs.getOrDefault("direction",
        a.styles.getOrDefault("direction", ""))).strip().toLowerAscii()
      if own in ["ltr", "rtl"]:
        return own == "rtl"
      if a.tag == "mailDocument":
        return a.attrs.getOrDefault("dir", "").strip().toLowerAscii() == "rtl"
    a = a.parent
  false

proc startSide*(n: EmailNode): string =
  if isRtl(n): "right" else: "left"

proc endSide*(n: EmailNode): string =
  if isRtl(n): "left" else: "right"

proc darkDesigned*(ctx: ExpandCtx): bool =
  ctx.target.darkMode == dmDesigned

proc paint*(ctx: ExpandCtx; node: EmailNode; prop, token: string) =
  ## A theme colour, dark-paired under `darkMode = designed` (R-DRK-02).
  ctx.r.setStyle(node, prop, "tok:" & token)
  if ctx.darkDesigned():
    ctx.r.setStyle(node, "@dark:" & prop, "tok:" & token)

proc useType*(ctx: ExpandCtx; node: EmailNode; token: string) =
  ## The theme's type size and line height (`type.small`, …).
  for (k, v) in expandTypeSpec(ctx.theme.lightFor(token)):
    ctx.r.setStyle(node, k, v)

proc cloneNode*(ctx: ExpandCtx; n: EmailNode): EmailNode =
  ## A deep copy of `n` (its attributes, styles and content), for the
  ## text part's copy of content the HTML also shows.
  case n.kind
  of enText:
    result = ctx.r.createTextNode(n.text)
  of enElement:
    result = ctx.r.createElement(n.tag)
    for k, v in n.attrs.pairs:
      ctx.r.setAttribute(result, k, v)
    for k, v in n.styles.pairs:
      ctx.r.setStyle(result, k, v)
    for c in n.children:
      let cc = cloneNode(ctx, c)
      if cc != nil:
        ctx.r.appendChild(result, cc)
  else:
    result = nil
  if result != nil:
    result.origin = n.origin

proc htmlAndText*(ctx: ExpandCtx; n: EmailNode; html: EmailNode;
    text: openArray[EmailNode]): EmailNode =
  ## `html` for the HTML part and `text` for the plain-text part: a
  ## `div` holding `htmlOnly(html)` and `textOnly(text…)` (layout
  ## layout-patterns.md §4: the text form a pattern writes when it differs from
  ## what its expansion would).
  result = el(ctx, n, "div")
  let h = el(ctx, n, "htmlOnly")
  ctx.r.appendChild(h, html)
  ctx.r.appendChild(result, h)
  let t = el(ctx, n, "textOnly")
  for x in text:
    if x != nil:
      ctx.r.appendChild(t, x)
  ctx.r.appendChild(result, t)

proc plainText*(n: EmailNode): string =
  ## What `n` says in the text part, on one line: its text, white space
  ## collapsed, a `br` a space, `htmlOnly` content left out and
  ## `textOnly` content kept (a value cell's own text form).
  proc walk(x: EmailNode; acc: var string) =
    case x.kind
    of enText:
      acc.add(x.text)
    of enElement:
      if x.tag == "htmlOnly":
        return
      if x.tag == "br":
        acc.add(' ')
        return
      # A block's text is a word apart from its neighbours'.
      let inline = x.tag in ["span", "strong", "b", "em", "i", "u", "s",
        "small", "sup", "sub", "a", "code", "codeInline"]
      if not inline:
        acc.add(' ')
      for c in x.children:
        walk(c, acc)
      if not inline:
        acc.add(' ')
    else:
      discard
  var s = ""
  walk(n, s)
  splitWhitespace(s).join(" ")

proc linesPara*(ctx: ExpandCtx; n: EmailNode; lines: openArray[string]):
    EmailNode =
  ## One paragraph of `lines`, a `br` between them: the text part writes
  ## them as consecutive lines (`label: value`, `time — event`).
  result = el(ctx, n, "p")
  for i, l in lines:
    if i > 0:
      add(ctx, result, el(ctx, n, "br"))
    add(ctx, result, ctx.r.createTextNode(l))

const visuallyHiddenStyles* = [("mso-hide", "all"), ("position", "absolute"),
  ("width", "1px"), ("height", "1px"), ("margin", "0"),
  ("overflow", "hidden"), ("clip", "rect(0 0 0 0)")]
  ## Text a screen reader reads and a screen does not show: the hidden
  ## caption's styles (catalogue R-A11Y-09). A client that drops
  ## `position` keeps a 1px box with its overflow hidden.

proc visuallyHidden*(ctx: ExpandCtx; n: EmailNode; text: string):
    EmailNode =
  ## A paragraph holding `text`, visually hidden (`visuallyHiddenStyles`).
  el(ctx, n, "p", styles = visuallyHiddenStyles, text = text)

proc itemTagDef*(name, parent: string; P: typedesc): TagDef
    {.compileTime.} =
  ## The static-vocabulary entry of a pattern's item element (a
  ## `mailKeyValueRow`, a `mailLineItem`): one attribute per field of
  ## `P`, allowed only in `parent`.
  result = patternTagDef(name, P)
  result.allowedParents = @[parent]

template defineMailItem*(name: untyped; parent: string; props: typedesc) =
  ## Declares `name`, an item element that only `parent` holds and reads
  ## (with `readProps[props]`) when it expands: the item joins the static
  ## vocabulary, so a template may write it inside its pattern (its
  ## attributes checked), and never reaches the output on its own; one
  ## left anywhere else is `E-LOWER-MISSING`.
  static:
    registerPatternTag(itemTagDef(astToStr(name), parent, props))
