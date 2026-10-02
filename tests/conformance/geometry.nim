## Outlook geometry of an HTML email, as the Word engine lays it out:
## the measure the MJML conformance check compares (`just
## test-conformance`), so that the comparison is about what classic
## Outlook shows and not about markup, which deliberately differs (this
## library is div-first; MJML puts a table inside every column).
##
## The model, and its limits, stated once:
##
## - **The Word view.** What only other clients see
##   (`<!--[if !mso]><!-->…<!--<![endif]-->`) is removed, Outlook
##   conditionals (`<!--[if mso]>`, MJML's `<!--[if mso | IE]>`) are
##   unwrapped, and other comments go. Only `<body>` is laid out.
## - **Boxes come from tables only.** Word ignores width, max-width and
##   padding on `div`s, so a `div` (and every element but `table`, `tr`
##   and `td`) passes its box to its content unchanged.
## - A table is as wide as its px width (the `width` attribute or a CSS
##   px width), its % of the box, or the box when it has neither; a
##   table never grows past an auto-width parent's box (Word fits auto
##   tables to their container). `align="center"` centres it in the box.
## - A row's cells take their px widths (clamped to the table); cells
##   without one share what is left. A cell's content box is its width
##   less its padding and border, never below zero; top and bottom
##   insets add up the cells' vertical padding and borders down to the
##   leaf.
## - A background is a `bgcolor` attribute or a CSS `background-color`
##   (or `background`) on a table or cell. A leaf on the document's own
##   colour has no background of its own: the skeleton paints the page
##   colour on its wrapper table, MJML on the body only.
##
## From that model come three measures: the **leaves** (each marker
## text's left edge, width, vertical insets and background), the
## **ghost-table tree** (every table with a px width, nested, with its
## centring and background), and the **bleed** of each px table: the
## background of an enclosing 100% table outside every px table that
## differs from the document's, which is how a full-bleed band shows in
## Word (a 100% table inside a px box only fills that box).
## The responsive class widths come from the head's
## `@media only screen and (min-width:…)` rules.
##
## The same parser also lists, for MJML's output, the solver facts the
## layout pass is checked against (`widthFactsOfMjml`).
##
## Pure string processing: identical on the C and JS targets.

import std/[algorithm, strutils, tables]
import ./fixtures

type
  WNode* = ref object
    tag*: string                 ## "" for a text node
    attrs*: Table[string, string]
    text*: string
    kids*: seq[WNode]

  Leaf* = object
    marker*: string
    x*, width*: float
    top*, bottom*: int
    background*: string

  Geometry* = object
    leaves*: seq[Leaf]
    ghostTree*: string      ## e.g. `600c#ffffff[560c]`
    bleeds*: seq[string]    ## per px table, in order: bleed colour or "-"
    responsive*: seq[string] ## sorted class widths other than 100%

const pageWidth = 800.0
const voidTags = ["meta", "img", "br", "hr", "input", "link", "col",
  "source", "wbr"]

proc stripBetween(s, open, close: string): string =
  ## Removes every `open … close` span (non-greedy).
  var i = 0
  while true:
    let a = s.find(open, i)
    if a < 0:
      result.add(s[i .. ^1])
      return
    result.add(s[i ..< a])
    let b = s.find(close, a + open.len)
    if b < 0:
      return
    i = b + close.len

proc wordView*(html: string): string =
  ## The body as Word sees it (see the module comment).
  var s = stripBetween(html, "<!--[if !mso]><!-->", "<!--<![endif]-->")
  var res = ""
  var i = 0
  while i < s.len:
    if s.continuesWith("<!--[if", i):
      let e = s.find("]>", i)
      let cond = s[i + 7 ..< e].strip()
      if "mso" in cond and not cond.startsWith("!"):
        i = e + 2
        continue
      # Any other conditional (none expected in a body): dropped whole.
      let close = s.find("<![endif]-->", e)
      i = close + "<![endif]-->".len
      continue
    if s.continuesWith("<![endif]-->", i):
      i += "<![endif]-->".len
      continue
    if s.continuesWith("<!--", i):
      let close = s.find("-->", i + 4)
      i = close + 3
      continue
    res.add(s[i])
    inc i
  let b = res.find("<body")
  if b >= 0: res[b .. ^1] else: res

proc parseAttrs(s: string): Table[string, string] =
  var i = 0
  while i < s.len:
    while i < s.len and s[i] in {' ', '\n', '\t', '\r', '/'}:
      inc i
    var j = i
    while j < s.len and s[j] notin {' ', '=', '\n', '\t', '\r', '/', '>'}:
      inc j
    if j == i:
      break
    let name = s[i ..< j].toLowerAscii()
    i = j
    while i < s.len and s[i] in {' ', '\n', '\t'}:
      inc i
    if i < s.len and s[i] == '=':
      inc i
      while i < s.len and s[i] in {' ', '\n', '\t'}:
        inc i
      if i < s.len and s[i] in {'"', '\''}:
        let q = s[i]
        let e = s.find(q, i + 1)
        result[name] = s[i + 1 ..< e]
        i = e + 1
      else:
        var e = i
        while e < s.len and s[e] notin {' ', '>', '\n', '\t'}:
          inc e
        result[name] = s[i ..< e]
        i = e
    else:
      result[name] = ""

proc parseWord*(view: string): WNode =
  ## A forgiving tree builder over the Word view: void elements close
  ## themselves, and a closing tag pops to its nearest open match.
  result = WNode(tag: "#root")
  var stack = @[result]
  var i = 0
  while i < view.len:
    if view[i] == '<':
      let e = view.find('>', i)
      if e < 0:
        break
      let inner = view[i + 1 ..< e]
      i = e + 1
      if inner.startsWith("/"):
        let name = inner[1 .. ^1].strip().toLowerAscii()
        var k = stack.high
        while k > 0 and stack[k].tag != name:
          dec k
        if k > 0:
          stack.setLen(k)
        continue
      if inner.startsWith("!") or inner.startsWith("?"):
        continue
      var n = 0
      while n < inner.len and inner[n] notin {' ', '\n', '\t', '/', '\r'}:
        inc n
      let node = WNode(tag: inner[0 ..< n].toLowerAscii(),
        attrs: parseAttrs(inner[n .. ^1]))
      stack[^1].kids.add(node)
      if node.tag notin voidTags and not inner.endsWith("/"):
        stack.add(node)
    else:
      var e = view.find('<', i)
      if e < 0:
        e = view.len
      let text = view[i ..< e]
      if text.strip().len > 0:
        stack[^1].kids.add(WNode(tag: "", text: text))
      i = e

proc styleOf(n: WNode): Table[string, string] =
  for decl in n.attrs.getOrDefault("style", "").split(';'):
    let c = decl.find(':')
    if c > 0:
      result[decl[0 ..< c].strip().toLowerAscii()] =
        decl[c + 1 .. ^1].strip()

proc pxOf(v: string): float =
  ## `24px`, `24`, `0` → 24.0; anything else → 0.
  var s = v.strip().toLowerAscii()
  if s.endsWith("px"):
    s = s[0 ..< ^2]
  try: parseFloat(s) except ValueError: 0.0

proc sidesOf(v: string): array[4, float] =
  let p = v.strip().splitWhitespace()
  case p.len
  of 1: [pxOf(p[0]), pxOf(p[0]), pxOf(p[0]), pxOf(p[0])]
  of 2: [pxOf(p[0]), pxOf(p[1]), pxOf(p[0]), pxOf(p[1])]
  of 3: [pxOf(p[0]), pxOf(p[1]), pxOf(p[2]), pxOf(p[1])]
  of 4: [pxOf(p[0]), pxOf(p[1]), pxOf(p[2]), pxOf(p[3])]
  else: [0.0, 0.0, 0.0, 0.0]

proc borderWidth(v: string): float =
  for part in v.splitWhitespace():
    if part.len > 0 and part[0] in {'0' .. '9'}:
      return pxOf(part)
  0.0

proc paddingOf(st: Table[string, string]): array[4, float] =
  if "padding" in st:
    result = sidesOf(st["padding"])
  for i, side in ["top", "right", "bottom", "left"]:
    if ("padding-" & side) in st:
      result[i] = pxOf(st["padding-" & side])

proc bordersOf(st: Table[string, string]): array[4, float] =
  if "border" in st:
    let w = borderWidth(st["border"])
    result = [w, w, w, w]
  for i, side in ["top", "right", "bottom", "left"]:
    if ("border-" & side) in st:
      result[i] = borderWidth(st["border-" & side])

proc backgroundOf(n: WNode): string =
  let st = styleOf(n)
  if "bgcolor" in n.attrs:
    return n.attrs["bgcolor"].toLowerAscii()
  if "background-color" in st:
    return st["background-color"].toLowerAscii()
  if "background" in st and st["background"].startsWith("#"):
    return st["background"].splitWhitespace()[0].toLowerAscii()
  ""

type WidthKind = enum wkNone, wkPx, wkPercent

proc widthOf(n: WNode): tuple[kind: WidthKind; value: float] =
  let st = styleOf(n)
  for v in [n.attrs.getOrDefault("width", ""), st.getOrDefault("width", "")]:
    let s = v.strip().toLowerAscii()
    if s.len == 0 or s == "auto":
      continue
    if s.endsWith("%"):
      return (wkPercent, pxOf(s[0 ..< ^1]))
    let px = pxOf(s)
    if px > 0:
      return (wkPx, px)
  (wkNone, 0.0)

proc textOf(n: WNode): string =
  if n.tag == "":
    return n.text
  for k in n.kids:
    result.add(textOf(k))

proc rowsOf(table: WNode): seq[WNode] =
  for k in table.kids:
    if k.tag == "tr":
      result.add(k)
    elif k.tag in ["tbody", "thead", "tfoot"]:
      for r in k.kids:
        if r.tag == "tr":
          result.add(r)

type Walk = object
  docBg: string
  pxDepth: int
  leaves: seq[Leaf]
  tree: string
  bleeds: seq[string]

proc layoutNode(w: var Walk; n: WNode; x, avail: float; top, bottom: int;
    bg, bleed: string; autoParent: bool)

proc layoutTable(w: var Walk; t: WNode; x, avail: float; top, bottom: int;
    bg, bleed: string; autoParent: bool) =
  let (kind, value) = widthOf(t)
  var width = case kind
    of wkPx: value
    of wkPercent: avail * value / 100.0
    of wkNone: avail
  if autoParent and width > avail:
    width = avail
  let tx = if t.attrs.getOrDefault("align", "") == "center":
      x + (avail - width) / 2.0 else: x
  var tbg = backgroundOf(t)
  let rows = rowsOf(t)
  if tbg.len == 0 and rows.len == 1:
    var cells = 0
    for c in rows[0].kids:
      if c.tag in ["td", "th"]:
        inc cells
    if cells == 1:
      for c in rows[0].kids:
        if c.tag in ["td", "th"]:
          tbg = backgroundOf(c)
  # A full-width band is a 100% table with a background of its own
  # outside every px table; inside a px box a 100% table is just the
  # box's fill (MJML paints its sections that way), never a band.
  var innerBleed = bleed
  if kind == wkPercent and value >= 100.0 and tbg.len > 0 and
      tbg != w.docBg and w.pxDepth == 0:
    innerBleed = tbg
  elif w.pxDepth > 0 or kind == wkPx:
    innerBleed = ""
  if kind == wkPx:
    inc w.pxDepth
    w.tree.add($int(width) &
      (if t.attrs.getOrDefault("align", "") == "center": "c" else: "") &
      tbg & "[")
    w.bleeds.add(if bleed.len > 0: bleed else: "-")
  let ownBg = backgroundOf(t)
  let rowBg = if ownBg.len > 0: ownBg else: bg
  for row in rows:
    var cells: seq[WNode] = @[]
    for c in row.kids:
      if c.tag in ["td", "th"]:
        cells.add(c)
    var fixed = 0.0
    var autos = 0
    for c in cells:
      let (ck, cv) = widthOf(c)
      if ck == wkPx: fixed += min(cv, width)
      elif ck == wkPercent: fixed += width * cv / 100.0
      else: inc autos
    let share = if autos > 0: max(0.0, width - fixed) / float(autos) else: 0.0
    var cx = tx
    for c in cells:
      let (ck, cv) = widthOf(c)
      let cw = case ck
        of wkPx: min(cv, width)
        of wkPercent: width * cv / 100.0
        of wkNone: share
      let st = styleOf(c)
      let pad = paddingOf(st)
      let bor = bordersOf(st)
      let cbg0 = backgroundOf(c)
      let cbg = if cbg0.len > 0: cbg0 else: rowBg
      # A cell narrower than its padding lays its content out in
      # nothing, never in a negative width.
      let inner = max(0.0, cw - pad[1] - pad[3] - bor[1] - bor[3])
      for k in c.kids:
        layoutNode(w, k, cx + pad[3] + bor[3], inner,
          top + int(pad[0] + bor[0]), bottom + int(pad[2] + bor[2]), cbg,
          innerBleed, ck == wkNone and kind == wkNone)
      cx += cw
  if kind == wkPx:
    dec w.pxDepth
    w.tree.add("]")

proc layoutNode(w: var Walk; n: WNode; x, avail: float; top, bottom: int;
    bg, bleed: string; autoParent: bool) =
  if n.tag == "":
    let t = n.text.strip()
    if t.startsWith("MK"):
      # The document's own colour is the page, wherever it is painted:
      # this library's skeleton repeats it on its wrapper table
      # (catalogue §1), MJML only on the body and a div.
      w.leaves.add(Leaf(marker: t, x: x, width: avail, top: top,
        bottom: bottom, background: if bg == w.docBg: "" else: bg))
    return
  if n.tag == "table":
    layoutTable(w, n, x, avail, top, bottom, bg, bleed, autoParent)
    return
  for k in n.kids:
    layoutNode(w, k, x, avail, top, bottom, bg, bleed, autoParent)

proc responsiveWidths(html: string): seq[string] =
  ## Class widths from the `min-width` media rules, `.moz-text-html`
  ## and `[owa]` copies folded in, 100% (a no-op over the inline
  ## 100%) left out; one per class, sorted.
  var byClass = initTable[string, string]()
  var i = 0
  while true:
    let m = html.find("@media only screen and (min-width", i)
    if m < 0:
      break
    let open = html.find('{', m)
    var depth = 1
    var j = open + 1
    while j < html.len and depth > 0:
      if html[j] == '{': inc depth
      elif html[j] == '}': dec depth
      inc j
    let body = html[open + 1 ..< j - 1]
    var k = 0
    while true:
      let ob = body.find('{', k)
      if ob < 0:
        break
      let cb = body.find('}', ob)
      let sel = body[k ..< ob].strip()
      let decls = body[ob + 1 ..< cb]
      var cls = sel.splitWhitespace()[^1]
      cls = cls.strip(chars = {'.'})
      for d in decls.split(';'):
        let c = d.find(':')
        if c > 0 and d[0 ..< c].strip() == "width":
          let v = d[c + 1 .. ^1].replace("!important", "").strip()
          byClass[cls] = v
      k = cb + 1
    i = j
  for _, v in byClass:
    if v != "100%":
      result.add(v)
  result.sort()

proc geometryOf*(html: string; docBg = documentBackground): Geometry =
  ## The Outlook geometry of one rendered document.
  let root = parseWord(wordView(html))
  var w = Walk(docBg: docBg.toLowerAscii())
  for k in root.kids:
    layoutNode(w, k, 0.0, pageWidth, 0, 0, "", "", false)
  result.leaves = w.leaves
  result.ghostTree = w.tree
  result.bleeds = w.bleeds
  result.responsive = responsiveWidths(html)

proc mqWidths(html: string): Table[string, string] =
  ## Every class's width in the `min-width` media rules.
  var i = 0
  while true:
    let m = html.find("@media only screen and (min-width", i)
    if m < 0:
      break
    let open = html.find('{', m)
    var depth = 1
    var j = open + 1
    while j < html.len and depth > 0:
      if html[j] == '{': inc depth
      elif html[j] == '}': dec depth
      inc j
    let body = html[open + 1 ..< j - 1]
    var k = 0
    while true:
      let ob = body.find('{', k)
      if ob < 0:
        break
      let cb = body.find('}', ob)
      let cls = body[k ..< ob].strip().splitWhitespace()[^1].strip(
        chars = {'.'})
      for d in body[ob + 1 ..< cb].split(';'):
        let c = d.find(':')
        if c > 0 and d[0 ..< c].strip() == "width":
          result[cls] = d[c + 1 .. ^1].replace("!important", "").strip()
      k = cb + 1
    i = j

proc factsWalk(n: WNode; mq: Table[string, string]; pending: var int;
    acc: var seq[WidthFact]) =
  if n.tag == "table" and n.attrs.getOrDefault("align", "") == "center" and
      "width" in n.attrs and not n.attrs["width"].endsWith("%"):
    let st = styleOf(n)
    if "width" in st and st["width"].endsWith("px"):
      acc.add(WidthFact(kind: "table", px: pxOf(n.attrs["width"])))
  elif n.tag == "td":
    let st = styleOf(n)
    if "width" in st and st["width"].endsWith("px"):
      acc.add(WidthFact(kind: "cell", px: pxOf(st["width"])))
      pending = acc.high
  elif n.tag == "div" and pending >= 0:
    for cls in n.attrs.getOrDefault("class", "").splitWhitespace():
      if cls.startsWith("mj-column-per-") or cls.startsWith("mj-column-px-"):
        acc[pending].responsive = mq.getOrDefault(cls, "")
        pending = -1
        break
  for k in n.kids:
    factsWalk(k, mq, pending, acc)

proc widthFactsOfMjml*(html: string): seq[WidthFact] =
  ## The ghost-table widths, column and group cell widths and their
  ## class widths in MJML's output, in document order: the facts the
  ## layout pass must reproduce.
  let root = parseWord(wordView(html))
  var pending = -1
  factsWalk(root, mqWidths(html), pending, result)
