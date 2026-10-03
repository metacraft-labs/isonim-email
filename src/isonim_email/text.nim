## isonim_email/text.nim — the plain-text alternative (P12).
##
## `renderText` walks the resolved **semantic** tree (after layout and
## asset resolution, before lowering), never the lowered HTML, and
## writes the `text/plain` part:
##
## | Element | Text |
## |---|---|
## | `h1` | its text, then a line of `=` as long as its longest line |
## | `h2`, `h3` | its text, then a line of `-` likewise |
## | `h4`–`h6` | its text, a block of its own |
## | `p`, `mailText`, `div` | paragraphs, one blank line apart, wrapped at 76 columns |
## | inline elements | their text; `br` breaks the line |
## | `a` | `text (url)`; only `url` when the text is the URL; `alt (url)` around an image |
## | `mailButton` | `label: url` on a line of its own |
## | `mailImage` | `[alt]`; nothing when decorative; linked: `alt (url)` |
## | `mailTable` | its caption, then rows of cells joined by ` | `, or `label: value` blocks |
## | `ul`, `ol` | `- ` / `1. ` items with a hanging indent |
## | `blockquote` | its blocks indented by two spaces |
## | `pre` | its lines as written |
## | `mailDivider` | `----` |
## | `mailSpacer`, the preheader, `htmlOnly`, Word- or family-only `mailIf` | nothing |
## | `mailIf(mso = false)`, `textOnly` | their content |
## | bands, columns, primitives, patterns | their content in reading order |
## | a column, group, box, grid or sidebar item of one-line blocks | those lines, consecutive |
## | `mailCluster` (`mailNavbar`) | items joined by the separator, or one per line when they carry URLs |
## | `mailSocial` | `Network: url`, one per line |
## | `mailRaw` | its payload read as HTML and walked like the rest |
##
## Details:
##
## - **Wrapping** breaks only at spaces, at 76 columns counted in code
##   points; a word longer than the line (a URL) is written whole. Text
##   is white-space collapsed as HTML collapses it; a no-break space
##   does not break.
## - **Links**: when the text is the URL (with or without its scheme
##   and a trailing `/`), only the URL; for `mailto:` and `tel:`, the
##   address the text shows. A paragraph with more than three links
##   that need a URL lists them as `[n]` references after its last
##   line, numbered through the whole text.
## - **Tables**: one line per row, the header row first, cells joined
##   by ` | ` (an empty cell is `-`), when every row fits in 76 columns;
##   otherwise one `label: value` block per body row. Nothing is
##   aligned with spaces: most clients show plain text in a
##   proportional face, where space-aligned columns drift.
## - **The preheader** is never written (catalogue R-PRE-04): it is a
##   `mailDocument` attribute, which the walk does not read.
## - **Format** (`format=flowed`, RFC 3676; R-MIME-06): blocks one
##   blank line apart, one final newline. A line the wrapper broke
##   inside a paragraph ends in a soft break, one trailing space, so a
##   flowed reader rejoins the paragraph and reflows it to its window.
##   Every other line ends in a hard break, with no trailing space: a
##   paragraph's last line, `br`, headings and their rule, list items,
##   quotations, `pre`, table rows and blocks, buttons, images and
##   cluster items. The MIME layer keeps the soft breaks
##   (`RenderedEmail.textFlowed`) and space-stuffs the lines.
##
## A walk that writes nothing but white space is `E-TEXT-EMPTY`: an
## empty text part is never sent, so the text is then empty and the
## message goes out as HTML alone.
##
## Pure string work over the tree: identical on the C and JS targets.

import std/[strutils, tables, unicode]
import ./renderer
import ./target
import ./diagnostics
import ./raw
import ./patterns
import ./lower/conditional
import ./lower/table_style

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const
  textWidth* = 76
    ## The column the text part wraps at.
  inlineTags = ["a", "strong", "em", "b", "i", "u", "s", "small", "sup",
    "sub", "span", "code", "br", "font", "abbr", "cite", "q", "mark",
    "time", "label", "del", "ins", "kbd", "samp", "var", "big", "tt",
    "strike", "bdi", "bdo", "img", "wbr"]
    ## Elements whose content flows inside a line.
  wrapperTags = ["mailIf", "textOnly", "htmlOnly"]
    ## Transparent wrappers: inline where they sit inline.
  omittedTags = ["mailSpacer", "htmlOnly", "style", "script", "title",
    "head", "meta", "link", "textarea", "noscript", "template", "xmp",
    "iframe", "object", "embed", "video", "audio", "canvas", "svg",
    "math", "select", "input", "button", "noembed", "noframes"]
    ## Elements that contribute no text (`button` is a raw payload's
    ## form control: a template's button is a `mailButton`).
  space = {' ', '\t', '\n', '\r', '\f'}
  softMark = '\x1F'
    ## Ends a line the wrapper broke inside a paragraph while the text is
    ## built; written as the soft break's trailing space at the end.

type
  RefList = ref object
    ## The `[n]` link references, numbered through the whole text.
    next: int

  Block = seq[string]
    ## One block: its lines, without trailing white space.

  State = object
    ## A walk in progress: the finished blocks, and the inline content
    ## waiting for the next block boundary.
    width: int
    blocks: seq[Block]
    pending: seq[EmailNode]
    refs: RefList
    soft: bool
      ## Paragraphs here reflow: their wrapped lines end in soft breaks.

proc cols(s: string): int =
  ## The width of `s` in columns: code points.
  s.runeLen

proc ifIncluded(node: EmailNode): bool =
  ## A `mailIf` the text part carries: `mso = false` only, what every
  ## client but Word shows. Content for Word or one family is not text.
  ifForm(node) == ifNotMso

proc skipped(node: EmailNode): bool =
  ## True when `node` writes nothing to the text part.
  case node.kind
  of enText, enRaw: false
  of enNotMso: false
  of enMsoIf, enVml, enHeadStyle: true
  of enElement:
    if node.tag in omittedTags:
      return true
    if node.tag == "mailIf":
      return not ifIncluded(node)
    false

proc isInline(node: EmailNode): bool =
  ## True for content that flows inside a line.
  case node.kind
  of enText: true
  of enElement:
    let t = node.tag.toLowerAscii()
    t in inlineTags or (node.tag in wrapperTags and node.children.len > 0 and
      (block:
        var all = true
        for c in node.children:
          if c.kind == enElement and not c.isInline() and not c.skipped():
            all = false
        all))
  else: false

# --- inline text -------------------------------------------------------------

proc collapse(s: string): string =
  ## HTML white-space collapsing: every run of white space is one
  ## space (a no-break space is not white space).
  var inSpace = false
  for ch in s:
    if ch in space:
      if not inSpace:
        result.add(' ')
      inSpace = true
    else:
      result.add(ch)
      inSpace = false

proc urlCore(s: string): string =
  ## A URL or a link text reduced for comparison: no scheme, no
  ## trailing `/`, lower case.
  result = s.strip().toLowerAscii()
  for scheme in ["https://", "http://", "mailto:", "tel:"]:
    if result.startsWith(scheme):
      result = result[scheme.len .. ^1]
      break
  while result.endsWith("/"):
    result.setLen(result.len - 1)

proc plainInline(node: EmailNode): string
proc rawNodes(node: EmailNode): seq[EmailNode]

proc linkNeedsUrl(text, href: string): bool =
  ## False when the link's text already is its URL.
  href.strip().len > 0 and urlCore(text) != urlCore(href)

proc linkText(text, href: string): string =
  ## `text (url)`, or the URL alone when the text is the URL (for
  ## `mailto:` and `tel:`, the address the text shows).
  let h = href.strip()
  let t = text.strip()
  if h.len == 0:
    return t
  if not linkNeedsUrl(t, h):
    let lower = h.toLowerAscii()
    if t.len > 0 and (lower.startsWith("mailto:") or lower.startsWith("tel:")):
      return t
    return h
  if t.len == 0:
    return h
  t & " (" & h & ")"

proc imageAlt(node: EmailNode): string =
  ## An image's alt text, "" for a decorative one.
  if node.attrs.getOrDefault("decorative", "").strip().toLowerAscii() ==
      "true":
    return ""
  if node.attrs.getOrDefault("role", "").strip().toLowerAscii() in
      ["presentation", "none"]:
    return ""
  collapse(node.attrs.getOrDefault("alt", "")).strip()

proc soleImage(node: EmailNode): EmailNode =
  ## The one image a link holds and nothing else, or nil.
  for c in node.children:
    if c.kind == enText and c.text.strip().len == 0:
      continue
    if c.kind == enElement and (c.tag == "mailImage" or
        c.tag.toLowerAscii() == "img") and result == nil:
      result = c
    else:
      return nil

type InlineCtx = object
  ## Rendering one run of inline content: whether its links are
  ## listed as references, and the references it collected.
  useRefs: bool
  refs: RefList
  refLines: seq[string]

proc inlineOf(node: EmailNode; ic: var InlineCtx; s: var string) =
  ## Appends `node`'s inline text to `s`; `\n` marks a hard break.
  if node.skipped():
    return
  case node.kind
  of enText:
    # White space in text is a space; only `br` breaks a line.
    s.add(collapse(node.text))
  of enRaw:
    for n in rawNodes(node):
      inlineOf(n, ic, s)
  of enNotMso:
    for c in node.children:
      inlineOf(c, ic, s)
  of enElement:
    let t = node.tag.toLowerAscii()
    if t == "br":
      s.add('\n')
    elif t == "img" or node.tag == "mailImage":
      let alt = imageAlt(node)
      if alt.len > 0:
        let href = node.attrs.getOrDefault("href", "")
        if href.strip().len > 0: s.add(linkText(alt, href))
        else: s.add("[" & alt & "]")
    elif t == "a":
      var inner = ""
      var sub = InlineCtx(useRefs: false, refs: ic.refs)
      for c in node.children:
        inlineOf(c, sub, inner)
      var text = collapse(inner.replace('\n', ' ')).strip()
      let img = soleImage(node)
      if img != nil:
        # A linked image reads `alt (url)`, as a linked `mailImage` does.
        text = imageAlt(img)
      let href = node.attrs.getOrDefault("href", "")
      if ic.useRefs and linkNeedsUrl(text, href) and text.len > 0:
        inc ic.refs.next
        s.add(text & " [" & $ic.refs.next & "]")
        ic.refLines.add("[" & $ic.refs.next & "] " & href.strip())
      else:
        s.add(linkText(text, href))
    else:
      for c in node.children:
        inlineOf(c, ic, s)
  else:
    discard

proc countUrlLinks(node: EmailNode): int =
  ## The links in `node` whose URL would be written after their text.
  if node.skipped():
    return 0
  if node.kind == enRaw:
    for n in rawNodes(node):
      result += countUrlLinks(n)
    return
  if node.kind == enElement and node.tag.toLowerAscii() == "a":
    var inner = ""
    var ic = InlineCtx()
    for c in node.children:
      inlineOf(c, ic, inner)
    let img = soleImage(node)
    if img != nil:
      inner = imageAlt(img)
    if linkNeedsUrl(collapse(inner).strip(),
        node.attrs.getOrDefault("href", "")):
      return 1
    return 0
  for c in node.children:
    result += countUrlLinks(c)

proc plainInline(node: EmailNode): string =
  ## `node`'s inline text on one line, collapsed (no references).
  var s = ""
  var ic = InlineCtx()
  inlineOf(node, ic, s)
  collapse(s.replace('\n', ' ')).strip()

# --- wrapping ------------------------------------------------------------------

proc wrapLine(line: string; width: int): seq[string] =
  ## Greedy wrapping of one collapsed line at spaces; a word longer
  ## than `width` (a URL) is written whole on a line of its own.
  var cur = ""
  for word in line.split(' '):
    if word.len == 0:
      continue
    if cur.len == 0:
      cur = word
    elif cur.cols + 1 + word.cols <= width:
      cur.add(' ')
      cur.add(word)
    else:
      result.add(cur)
      cur = word
  if cur.len > 0:
    result.add(cur)

proc wrapInline(s: string; width: int; soft: bool): seq[string] =
  ## Wraps inline text whose `\n` are hard breaks; with `soft`, every
  ## line the wrapper broke ends in a soft break (RFC 3676), so a flowed
  ## reader rejoins the paragraph and reflows it to its own width.
  for part in s.split('\n'):
    let line = collapse(part).strip()
    if line.len == 0:
      continue
    let lines = wrapLine(line, width)
    for i, l in lines:
      result.add(if soft and i < lines.high: l & softMark else: l)

proc inlineParts(nodes: openArray[EmailNode]; st: var State;
    soft = true): tuple[lines, refs: seq[string]] =
  ## One paragraph from a run of inline nodes, wrapped, and its link
  ## references when it holds more than three links with URLs.
  var links = 0
  for n in nodes:
    links += countUrlLinks(n)
  var ic = InlineCtx(useRefs: links > 3, refs: st.refs)
  var s = ""
  for n in nodes:
    inlineOf(n, ic, s)
  result.lines = wrapInline(s, st.width, soft and st.soft)
  if result.lines.len > 0:
    result.refs = ic.refLines

proc inlineBlock(nodes: openArray[EmailNode]; st: var State): Block =
  let (lines, refs) = inlineParts(nodes, st)
  lines & refs

# --- blocks --------------------------------------------------------------------

proc emit(st: var State; node: EmailNode)

proc flush(st: var State) =
  if st.pending.len == 0:
    return
  let lines = inlineBlock(st.pending, st)
  st.pending = @[]
  if lines.len > 0:
    st.blocks.add(lines)

proc add(st: var State; b: Block) =
  if b.len > 0:
    st.blocks.add(b)

proc sub(st: State; width: int; soft: bool): State =
  State(width: max(width, 20), refs: st.refs, soft: soft)

proc blocksOf(st: State; nodes: openArray[EmailNode]; width: int;
    soft = false): seq[Block] =
  ## The blocks `nodes` write at `width`; their paragraphs reflow only
  ## with `soft` (never in an indented or one-line context: list items,
  ## quotations, table cells, cluster items).
  var inner = st.sub(width, soft and st.soft)
  for n in nodes:
    inner.emit(n)
  inner.flush()
  inner.blocks

proc joined(blocks: openArray[Block]): Block =
  ## Blocks as one, a blank line between them.
  for i, b in blocks:
    if i > 0:
      result.add("")
    result.add(b)

proc indented(lines: openArray[string]; first, rest: string): Block =
  for i, l in lines:
    if l.len == 0:
      result.add("")
    else:
      result.add((if i == 0: first else: rest) & l)

proc heading(st: var State; node: EmailNode) =
  ## `h1`–`h3` are underlined as wide as their longest line (above
  ## their references); `h4`–`h6` are their text.
  let (lines, refs) = inlineParts(node.children, st, soft = false)
  if lines.len == 0:
    return
  var b = lines
  let t = node.tag.toLowerAscii()
  if t in ["h1", "h2", "h3"]:
    var w = 0
    for l in lines:
      w = max(w, l.cols)
    b.add(repeat(if t == "h1": '=' else: '-', w))
  st.add(b & refs)

proc listBlock(st: var State; node: EmailNode) =
  ## `ul`/`ol`: one item per marker, a hanging indent, no blank line
  ## between items.
  let ordered = node.tag.toLowerAscii() == "ol"
  var n = 1
  if ordered:
    try:
      n = parseInt(node.attrs.getOrDefault("start", "1").strip())
    except ValueError:
      n = 1
  var b: Block
  proc items(x: EmailNode; acc: var seq[EmailNode]) =
    for c in x.children:
      if c.skipped():
        continue
      if c.kind == enElement and c.tag.toLowerAscii() == "li":
        acc.add(c)
      elif c.kind == enElement and c.tag in wrapperTags:
        items(c, acc)
      elif c.kind == enNotMso:
        items(c, acc)
  var lis: seq[EmailNode]
  items(node, lis)
  for li in lis:
    let marker = if ordered: $n & ". " else: "- "
    let lines = joined(st.blocksOf(li.children, st.width - marker.len))
    if lines.len > 0:
      b.add(indented(lines, marker, repeat(' ', marker.len)))
    inc n
  st.add(b)

proc preBlock(st: var State; node: EmailNode) =
  var s = ""
  proc collect(x: EmailNode) =
    if x.skipped():
      return
    if x.kind == enText:
      s.add(x.text)
    elif x.kind == enElement and x.tag.toLowerAscii() == "br":
      s.add('\n')
    else:
      for c in x.children:
        collect(c)
  collect(node)
  if s.startsWith("\n"):
    s = s[1 .. ^1]
  var b: Block
  for line in s.splitLines():
    b.add(line.strip(leading = false, trailing = true))
  while b.len > 0 and b[^1].len == 0:
    b.setLen(b.len - 1)
  st.add(b)

proc cellText(st: State; cell: EmailNode): string =
  ## A cell's content on one line.
  var parts: seq[string]
  for b in st.blocksOf(cell.children, 100_000):
    for l in b:
      if l.strip().len > 0:
        parts.add(l.strip())
  parts.join(" ")

proc captionOf(table, dataTable: EmailNode): string =
  if dataTable != nil:
    let c = collapse(dataTable.attrs.getOrDefault("caption", "")).strip()
    if c.len > 0:
      return c
  for c in table.children:
    if c.kind == enElement and c.tag.toLowerAscii() == "caption":
      return plainInline(c)
  ""

proc dataTableBlocks(st: var State; table, dataTable: EmailNode) =
  ## A data table: its caption, then one line per row (the header row
  ## first, cells joined by ` | `) when every row fits in 76 columns,
  ## else one `label: value` block per body row.
  let caption = captionOf(table, dataTable)
  let frozen = st # The cells read a copy: closures cannot hold `var`.
  let head = headerRow(table)
  let ncols = max(1, columnCount(table))
  type Cell = tuple[text: string; span: int; th: bool]
  proc rowCells(row: EmailNode): seq[Cell] =
    for c in cellsOf(row):
      result.add((frozen.cellText(c), spanOf(c),
        c.tag.toLowerAscii() == "th"))
  let header = if head != nil: rowCells(head) else: @[]
  var body: seq[seq[Cell]]
  for r in bodyRows(table):
    let cells = rowCells(r)
    var any = false
    for c in cells:
      if c.text.len > 0:
        any = true
    if any:
      body.add(cells)
  # One line per row, cells joined by ` | `, the header row first: no
  # column is aligned with spaces, so the table reads the same in a
  # proportional face (most clients show plain text in one). An empty
  # cell is `-`, so the cells keep their places.
  proc line(cells: seq[Cell]): string =
    var parts: seq[string]
    for c in cells:
      parts.add(if c.text.len > 0: c.text else: "-")
    parts.join(" | ")
  var lines: seq[string]
  if header.len > 0:
    lines.add(line(header))
  for r in body:
    lines.add(line(r))
  var fits = true
  for l in lines:
    if l.cols > st.width:
      fits = false
  var blocks: seq[Block]
  if caption.len > 0:
    blocks.add(wrapLine(caption, st.width))
  if fits:
    if blocks.len > 0:
      # The caption sits right above its table.
      blocks[^1].add(lines)
    else:
      blocks.add(lines)
  else:
    var labels = newSeq[string](ncols)
    var col = 0
    for c in header:
      if col < ncols:
        labels[col] = c.text
      col += c.span
    for r in body:
      var b: Block
      var col = 0
      for c in r:
        let label = if col < ncols and not c.th: labels[col] else: ""
        if c.text.len > 0:
          let l = if label.len > 0: label & ": " & c.text else: c.text
          b.add(indented(wrapLine(l, st.width - 2), "", "  "))
        col += c.span
      blocks.add(b)
  for b in blocks:
    st.add(b)

proc layoutTableBlocks(st: var State; table: EmailNode) =
  ## A layout table (outside `mailTable`): each cell's content in
  ## order, as a block container.
  proc cells(st: var State; x: EmailNode) =
    for c in x.children:
      if c.skipped():
        continue
      if c.kind == enElement and c.tag.toLowerAscii() in ["td", "th"]:
        st.flush()
        for k in c.children:
          st.emit(k)
        st.flush()
      elif c.kind == enElement and c.tag.toLowerAscii() == "caption":
        st.flush()
        st.add(wrapLine(plainInline(c), st.width))
      elif c.kind == enElement or c.kind == enNotMso:
        cells(st, c)
  cells(st, table)

proc carriesUrl(node: EmailNode): bool =
  ## True when `node` writes a URL: a link, a button, a linked image.
  if node.skipped():
    return false
  if node.kind == enElement:
    let t = node.tag.toLowerAscii()
    if t in ["mailbutton", "mailsocialitem"]:
      return true
    if t in ["a", "mailimage", "img"] and
        node.attrs.getOrDefault("href", "").strip().len > 0:
      return true
  for c in node.children:
    if carriesUrl(c):
      return true
  false

proc clusterBlock(st: var State; node: EmailNode) =
  ## A row of items: on one line joined by the separator (or `·`) when
  ## no item carries a URL and the line fits; otherwise one item per
  ## line, no blank line between items.
  proc items(st: State; x: EmailNode; acc: var seq[string];
      urls: var bool) =
    for c in x.children:
      if c.skipped():
        continue
      if c.kind == enText and c.text.strip().len == 0:
        continue
      if c.kind == enElement and c.tag == "mailIf":
        items(st, c, acc, urls)
        continue
      var parts: seq[string]
      for blk in st.blocksOf([c], 100_000):
        for l in blk:
          if l.strip().len > 0:
            parts.add(l.strip())
      if parts.len > 0:
        acc.add(parts.join(" "))
        if carriesUrl(c):
          urls = true
  var lines: seq[string]
  var urls = false
  items(st, node, lines, urls)
  if lines.len == 0:
    return
  var sep = collapse(node.attrs.getOrDefault("separator", "")).strip()
  if sep.len == 0:
    sep = "·"
  let joined = lines.join(" " & sep & " ")
  if not urls and joined.cols <= st.width:
    st.add(@[joined])
  else:
    var b: Block
    for l in lines:
      b.add(wrapLine(l, st.width))
    st.add(b)

proc inRaw(node: EmailNode): bool =
  ## True inside a payload `rawNodes` read.
  var a = node.parent
  while a != nil:
    if a.kind == enElement and a.tag == "#raw":
      return true
    a = a.parent
  false

proc item(st: var State; nodes: openArray[EmailNode]) =
  ## A column, a box, or an item of a grid or a sidebar: its blocks,
  ## written as consecutive lines when each is one line (a figure and
  ## its caption, a name and a role), one blank line apart otherwise.
  let blocks = st.blocksOf(nodes, st.width, soft = true)
  var short = true
  for b in blocks:
    if b.len != 1:
      short = false
  if short and blocks.len > 1:
    var b: Block
    for blk in blocks:
      b.add(blk)
    st.add(b)
  else:
    for b in blocks:
      st.add(b)

proc rawNodes(node: EmailNode): seq[EmailNode] =
  ## A `raw` payload read as HTML (`raw.nim`'s reader; its findings
  ## are P1's business, not the text part's).
  readRaw(node.text).nodes

proc emit(st: var State; node: EmailNode) =
  if node == nil or node.skipped():
    return
  if node.isInline():
    st.pending.add(node)
    return
  case node.kind
  of enRaw:
    for n in rawNodes(node):
      st.emit(n)
    return
  of enNotMso:
    for c in node.children:
      st.emit(c)
    return
  of enElement:
    discard
  else:
    return
  let t = node.tag.toLowerAscii()
  if node.tag == "mailSocialItem":
    # A social link reads `Network: url`.
    var name = ""
    for c in node.children:
      if c.kind == enElement and c.tag == "mailImage":
        name = imageAlt(c)
    if name.len == 0:
      name = node.attrs.getOrDefault("network", "").strip()
    let href = node.attrs.getOrDefault("href", "").strip()
    st.flush()
    st.add(wrapLine(if href.len > 0: name & ": " & href else: name,
      st.width))
    return
  if node.tag in wrapperTags or node.tag == "mailRaw" or
      (node.expanded and isPattern(node.tag)) or t == "#raw":
    # Transparent: what it holds sits where it sits.
    for c in node.children:
      st.emit(c)
    return
  st.flush()
  case t
  of "h1", "h2", "h3", "h4", "h5", "h6":
    st.heading(node)
  of "p":
    st.add(inlineBlock(node.children, st))
  of "mailbutton":
    let label = plainInline(node)
    let href = node.attrs.getOrDefault("href", "").strip()
    let line = if label.len == 0: href
      elif href.len == 0: label
      else: label & ": " & href
    st.add(wrapLine(line, st.width))
  of "mailimage":
    var ic = InlineCtx()
    var s = ""
    inlineOf(node, ic, s)
    st.add(wrapLine(collapse(s).strip(), st.width))
  of "maildivider", "hr":
    st.add(@["----"])
  of "ul", "ol":
    st.listBlock(node)
  of "blockquote":
    let inner = joined(st.blocksOf(node.children, st.width - 2))
    st.add(indented(inner, "  ", "  "))
  of "pre":
    st.preBlock(node)
  of "mailtable":
    let table = tableOf(node)
    if table != nil:
      st.dataTableBlocks(table, node)
    else:
      for c in node.children:
        st.emit(c)
  of "table":
    # Outside `mailTable` a table is layout; in a `mailRaw` payload, one
    # with a header row that does not say it is presentational is data.
    if inRaw(node) and headerRow(node) != nil and
        node.attrs.getOrDefault("role", "").strip().toLowerAscii() notin
          ["presentation", "none"]:
      st.dataTableBlocks(node, nil)
    else:
      st.layoutTableBlocks(node)
  of "mailcluster":
    st.clusterBlock(node)
  of "mailcolumn", "mailgroup", "mailbox":
    st.item(node.children)
  of "mailgrid", "mailsidebar":
    for c in node.children:
      if c.kind == enElement and not c.isInline():
        st.item([c])
      else:
        st.emit(c)
  else:
    # Bands, rows, `mailText`, `div`, list items and anything else: a
    # block container.
    for c in node.children:
      st.emit(c)
  st.flush()

proc renderText*(doc: EmailNode): tuple[text: string;
    diagnostics: seq[EmailDiagnostic]] =
  ## P12: the plain-text alternative of the semantic tree `doc` (see
  ## the module comment). An empty result is `E-TEXT-EMPTY`.
  var st = State(width: textWidth, refs: RefList(), soft: true)
  if doc != nil:
    st.emit(doc)
    st.flush()
  var lines: seq[string]
  for b in st.blocks:
    var trimmed: Block
    for l in b:
      # No trailing white space on a hard break; a soft break keeps
      # exactly one space (RFC 3676 §4.2).
      var line = l.strip(leading = false, trailing = true)
      if line.endsWith(softMark):
        line = line[0 ..< ^1].strip(leading = false, trailing = true)
        if line.len > 0:
          line.add(' ')
      trimmed.add(line)
    while trimmed.len > 0 and trimmed[0].len == 0:
      trimmed.delete(0)
    while trimmed.len > 0 and trimmed[^1].len == 0:
      trimmed.setLen(trimmed.len - 1)
    if trimmed.len == 0:
      continue
    if lines.len > 0:
      lines.add("")
    lines.add(trimmed)
  let text = lines.join("\n")
  if text.strip().len == 0:
    result.diagnostics.add(EmailDiagnostic(severity: sevError,
      code: codeTextEmpty, message: "the plain-text part would be empty: " &
        "the message has no text, link, button or image alt text a " &
        "plain-text reader could get (add textOnly content, or give an " &
        "image an alt text)",
      origin: if doc != nil: doc.origin else: SourceSpan()))
    return
  result.text = text & "\n"
