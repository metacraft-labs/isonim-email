## isonim_email/content/kit.nim — what the content patterns' expansions
## share: building elements, reading a pattern's content (its slot),
## px props, the direction an element sits in, and the HTML/text split
## a pattern uses when its plain-text form differs from what its
## expansion would write (`htmlOnly` beside `textOnly`).
##
## Pure tree building: identical on the C and JS targets.

import std/[strutils, tables]
import ../renderer
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
  ## patterns §4: the text form a pattern writes when it differs from
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
