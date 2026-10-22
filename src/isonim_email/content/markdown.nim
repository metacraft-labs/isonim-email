## isonim_email/content/markdown.nim — `mailMarkdown`: a Markdown body
## (layout-patterns.md §4.7), expanded into the library's leaves.
##
## The Markdown is read by isonim-docs's pipeline (`core/markdown_vm`:
## `parseMarkdownBlocks` and `parseInlineSpans`), through its AST, never
## through HTML. That AST is the docs site's dialect: headings,
## paragraphs, flat lists, fenced code, pipe tables, `:::` admonitions
## and the site's own blocks, and inline text, code, links and images.
## Over the same AST this module adds the constructs a notification
## needs that the AST leaves as text:
##
## - first, `src` is read as written (not stripped, as other props are)
##   less a string literal's edges and indentation (`markdownSource`):
##   leading blank lines and trailing white space dropped, the
##   indentation every non-blank line shares removed, so indentation
##   relative to the rest is kept;
## - before the AST is built, the source's lines are read once for
##   block quotes (`>` lines, lazy continuation included: each run is
##   read as Markdown again, inside a `blockquote`), thematic breaks
##   (`---`, `***`, `___`, spaces allowed: a `mailDivider`), setext
##   headings (a line of `=` or `-` under a paragraph's lines) and hard
##   line breaks (a paragraph line ending in two spaces or a backslash);
##   fenced code and `:::` blocks are left as they are; as in
##   CommonMark, a list interrupts a paragraph only when it is a bullet
##   list or an ordered list from 1 whose first item is not empty, and a
##   line indented four or more spaces opens no block (indented code is
##   not read: the line is paragraph text);
## - in the AST's text spans: emphasis and strong emphasis (`*`, `_`,
##   CommonMark's delimiter-run rules), `~~strikethrough~~`, autolinks
##   (`<https://…>`, `<mailto:…>`), backslash escapes of ASCII
##   punctuation and character references (`&amp;`, `&#169;`).
##
## The body is a `mailStack` (16px between blocks); each node becomes
## the element
## layout-patterns.md §4.7's table names:
## a heading `h1`–`h6` (its level plus `heading_offset`, at most 6), a
## paragraph `p`, emphasis `em`/`strong`/`s`, code `codeInline`, a link
## `a`, an image a `mailImage` block of its own (text around it becomes
## the paragraphs before and after it), a list `ul`/`ol`, fenced code a
## `mailCodeBlock`, a quote a `blockquote`, a break a `mailDivider`, a
## table a `mailTable` (its hidden caption the header labels), an
## admonition a `mailCallout` in its tone, a `:::button` a
## `mailButton`.
##
## Never read as markup: raw HTML and footnotes are written as the text
## the author typed (the serialiser escapes it) and reported
## (`W-MARKDOWN-UNSUPPORTED`): the one way to write markup is
## `mailRaw`. The docs site's blocks with no email form (tabs, card
## grids, heroes, FAQs, videos, forms, component tags) are left out and
## reported as errors (`E-MARKDOWN-UNSUPPORTED`).
##
## The text part follows from the elements (P12), like any template's.
##
## Pure tree building and string work: identical on the C and JS
## targets.

{.used.}

import std/[strutils, tables, unicode]
import core/markdown_vm as mdvm
import ../renderer
import ../target
import ../patterns
import ../diagnostics
import ./kit

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  MarkdownProps* = object
    ## `mailMarkdown` (layout-patterns.md §4.7).
    src* {.asWritten.}: string
      ## As written: `markdownSource` drops its edges and indentation.
    heading_offset*: int
    image_width*: string ## px; "" = each image's intrinsic size

const
  maxHeadingOffset* = 5
    ## `heading_offset` runs 0–5.
  hardBreak = "\u2028"
    ## Marks a hard line break through the AST: a paragraph's lines are
    ## joined with spaces and stripped, and this character (a Unicode
    ## line separator, never ASCII white space) survives both.

proc admonitionTone(k: AdmonitionKind): tuple[tone, word: string] =
  ## An admonition's callout tone and its word.
  case k
  of akNote: ("info", "Note")
  of akTip: ("success", "Tip")
  of akImportant: ("primary", "Important")
  of akWarning: ("warning", "Warning")
  of akCaution: ("danger", "Caution")
  of akDanger: ("danger", "Danger")

# --- Reporting -------------------------------------------------------------------

type MdCtx = object
  ctx: ExpandCtx
  n: EmailNode
  p: MarkdownProps
  warned: seq[string] ## the kinds already reported for this element
  inItem: int ## > 0 while a list item's content is read

proc warn(m: var MdCtx; kind, example: string) =
  ## One `W-MARKDOWN-UNSUPPORTED` per kind of construct and element.
  if kind in m.warned:
    return
  m.warned.add(kind)
  m.ctx.report(EmailDiagnostic(severity: sevWarning,
    code: codeMarkdownUnsupportedText,
    message: "mailMarkdown " & kind & " (" & example & ") is not read " &
      "as Markdown: it is written as the text you typed. Markup has one " &
      "way into a message, mailRaw (layout-patterns.md §4.7)",
    origin: m.n.origin))

proc refuse(m: var MdCtx; what: string) =
  m.ctx.report(EmailDiagnostic(severity: sevError,
    code: codeMarkdownUnsupported,
    message: "mailMarkdown " & what & " has no email form: it is left " &
      "out of the message. Write it with the library's patterns instead " &
      "(layout-patterns.md §4.7)",
    origin: m.n.origin))

# --- Source pass: quotes, breaks, setext headings, hard breaks ---------------------

type
  SegKind = enum skText, skQuote, skBreak, skList, skTable
  Segment = object
    kind: SegKind
    lines: seq[string]
      ## skText, skQuote: the run's lines; skTable: the table's rows,
      ## its delimiter row included
    items: seq[seq[string]]
      ## skList: each item's content lines, at its content column
    ordered: bool ## skList
    start: int ## skList: an ordered list's first number
    loose: bool ## skList
    aligns: seq[string]
      ## skTable: each column's alignment ("left", "center", "right",
      ## "" for none), from the delimiter row

proc leadingSpaces(line: string): int =
  while result < line.len and line[result] == ' ':
    inc result

proc isBreakLine(s: string): bool =
  ## A thematic break: three or more of one of `-`, `*`, `_`, with
  ## spaces between them allowed, and nothing else.
  let t = s.strip()
  if t.len < 3 or t[0] notin {'-', '*', '_'}:
    return false
  var count = 0
  for ch in t:
    if ch == t[0]:
      inc count
    elif ch != ' ':
      return false
  count >= 3

proc isSetextLine(s: string): char =
  ## '=' or '-' when `s` is a setext underline, '\0' otherwise.
  let t = s.strip()
  if t.len == 0:
    return '\0'
  for ch in t:
    if ch != t[0]:
      return '\0'
  if t[0] in {'=', '-'}: t[0] else: '\0'

proc isQuoteLine(s: string): bool =
  leadingSpaces(s) <= 3 and s.strip(trailing = false).startsWith(">")

proc unquote(s: string): string =
  var t = s.strip(trailing = false)
  t = t[1 .. ^1]
  if t.startsWith(" "):
    t = t[1 .. ^1]
  t

proc orderedMarkerEnd(t: string): int =
  ## The position of the delimiter of the ordered list marker `t`
  ## starts with (one to nine digits, then `.` or `)`, then a space),
  ## or 0.
  var j = 0
  while j < t.len and j < 10 and t[j] in Digits:
    inc j
  if j in 1 .. 9 and j + 1 < t.len and t[j] in {'.', ')'} and t[j + 1] == ' ':
    j
  else:
    0

proc startsBlock(s: string): bool =
  ## A line that starts a block of its own (so it is not a paragraph's
  ## next line).
  let t = s.strip()
  t.startsWith("```") or t.startsWith(":::") or t.startsWith("#") or
    t.startsWith("|") or t.startsWith(">") or
    (t.len >= 2 and t[0] in {'-', '*', '+'} and t[1] == ' ') or
    orderedMarkerEnd(t) > 0 or
    isBreakLine(t) or (t.len >= 2 and t[0] == '<' and t[1] in {'A'..'Z'})

proc isParagraphLine(s: string): bool =
  s.strip().len > 0 and not startsBlock(s)

proc markHardBreak(line: string; continues: bool): string =
  ## A paragraph line ending in two spaces or a backslash, followed by
  ## another line of the paragraph (`continues`), ends in a hard break.
  if not continues:
    return line
  if line.endsWith("  "):
    return line.strip(leading = false) & hardBreak
  if line.endsWith("\\") and not line.endsWith("\\\\"):
    return line[0 ..< ^1] & hardBreak
  line

# --- Source pass: lists ------------------------------------------------------------

type ListMarker = object
  ok: bool
  indent: int ## spaces before the marker
  ordered: bool
  ch: char ## the bullet, or an ordered marker's `.` or `)`
  number: int
  content: int ## the item's content column
  text: string ## the item's first line, from its content column

proc listMarker(line: string): ListMarker =
  ## The list item marker `line` starts with (CommonMark's): a bullet
  ## `-`, `*`, `+`, or one to nine digits and `.` or `)`, then a space
  ## or the line's end, indented at most three spaces (four is an
  ## indented line, never a marker). A thematic break is no item.
  let ind = leadingSpaces(line)
  if ind >= line.len or ind >= 4 or isBreakLine(line):
    return
  var j = ind
  var r = ListMarker(indent: ind)
  if line[j] in {'-', '*', '+'}:
    r.ch = line[j]
    inc j
  elif line[j] in Digits:
    while j < line.len and line[j] in Digits and j - ind < 9:
      inc j
    if j >= line.len or line[j] notin {'.', ')'} or j - ind > 9:
      return
    r.ordered = true
    r.number = parseInt(line[ind ..< j])
    r.ch = line[j]
    inc j
  else:
    return
  if j < line.len and line[j] != ' ':
    return
  var sp = 0
  while j + sp < line.len and line[j + sp] == ' ':
    inc sp
  if j + sp >= line.len:
    r.content = j + 1 # an empty first line
    r.text = ""
  elif sp > 4:
    r.content = j + 1 # indented code in the item: one space is the gap
    r.text = line[j + 1 .. ^1]
  else:
    r.content = j + sp
    r.text = line[j + sp .. ^1]
  r.ok = true
  r

proc sameList(a, b: ListMarker): bool =
  ## Whether `b` continues the list `a` started: the same kind of
  ## marker (the same bullet, or the same ordered delimiter).
  a.ordered == b.ordered and a.ch == b.ch

proc isBlank(s: string): bool = s.strip().len == 0

proc canInterrupt(mk: ListMarker): bool =
  ## Whether the list item `mk` starts may start a list on a
  ## paragraph's next line (CommonMark): a bullet item, or an ordered
  ## one numbered 1, whose first line is not empty.
  mk.text.strip().len > 0 and (not mk.ordered or mk.number == 1)

proc continuesParagraph(next: string): bool =
  ## Whether `next`, after a paragraph's line, is the paragraph's next
  ## line: paragraph text, an indented line, or a list marker that may
  ## not interrupt a paragraph.
  let mk = listMarker(next)
  isParagraphLine(next) or not isBlank(next) and leadingSpaces(next) >= 4 or
    mk.ok and not canInterrupt(mk)

proc asText(line: string): string =
  ## `line`, without its indentation, as the first line of a paragraph:
  ## a first character that would start a block here or in the AST (a
  ## list marker, a heading, a quote, a table row, a fence, a `:::`
  ## block, a break, a component tag) is written as its character
  ## reference, which the inline pass reads back as the character.
  let t = line.strip(trailing = false)
  if startsBlock(t): "&#" & $ord(t[0]) & ";" & t[1 .. ^1] else: t

proc joinLine(prev, line: string): string =
  ## `line`, a paragraph's next line that would start a block here or
  ## in the AST, joined to the paragraph's line `prev` (ending in its
  ## hard break, if any): not at a line's start, it starts none, and it
  ## stays as typed (a character reference in its place would be read
  ## as typed inside a code span the line above opens).
  markHardBreak(prev, true).strip(leading = false) & " " &
    line.strip(trailing = false)

proc fenceAt(lines: seq[string]; i: int): int
proc listAt(lines: seq[string]; i: int; seg: var Segment): int

proc hasLooseBlocks(lines: seq[string]): bool =
  ## Whether a blank line separates two blocks of an item's content
  ## (read at its top level: a nested list's and a fence's own blank
  ## lines are theirs).
  var i = 0
  var seen = false # a block before the current position
  var gap = false # a blank line since that block
  while i < lines.len:
    if isBlank(lines[i]):
      gap = seen
      inc i
      continue
    if gap:
      return true
    seen = true
    var sub = Segment()
    if lines[i].strip().startsWith("```"):
      i = fenceAt(lines, i)
    elif listMarker(lines[i]).ok:
      i = listAt(lines, i, sub)
    else:
      inc i
  false

proc fenceAt(lines: seq[string]; i: int): int =
  ## The line after the fence opening at `i` closes.
  var k = i + 1
  while k < lines.len and not lines[k].strip().startsWith("```"):
    inc k
  min(k + 1, lines.len)

proc listAt(lines: seq[string]; i: int; seg: var Segment): int =
  ## Reads the list starting at `lines[i]` (a list item marker) into
  ## `seg`; the line after it. Blank lines after its last item are not
  ## its own.
  let first = listMarker(lines[i])
  seg = Segment(kind: skList, ordered: first.ordered,
    start: (if first.ordered: first.number else: 1))
  var k = i
  var blankBetween = false
  while k < lines.len:
    let mk = listMarker(lines[k])
    if not mk.ok or not sameList(first, mk):
      break
    var item = @[mk.text]
    inc k
    var inFence = mk.text.strip().startsWith("```")
    while k < lines.len:
      let l = lines[k]
      if isBlank(l):
        item.add("")
        inc k
        continue
      if leadingSpaces(l) >= mk.content:
        let d = l[mk.content .. ^1]
        if d.strip().startsWith("```"):
          inFence = not inFence
        item.add(d)
        inc k
        continue
      # Not indented to the item: a lazy continuation of its paragraph
      # (the item's last line is paragraph text, this line too, or a
      # line indented four spaces, which opens no block), or the item's
      # end. A setext underline is never lazy, and an empty item (`-`
      # alone) is the next item.
      let last = item[^1]
      let lastMk = listMarker(last)
      if not inFence and (leadingSpaces(l) >= 4 or isParagraphLine(l) and
          isSetextLine(l) == '\0' and not listMarker(l).ok) and
          (isParagraphLine(last) or
          lastMk.ok and isParagraphLine(lastMk.text)):
        if startsBlock(l):
          item[^1] = joinLine(item[^1], l)
        else:
          item.add(l.strip(trailing = false))
        inc k
        continue
      break
    var trailing = 0
    while item.len > 1 and isBlank(item[^1]):
      item.setLen(item.len - 1)
      inc trailing
    if hasLooseBlocks(item):
      seg.loose = true
    seg.items.add(item)
    if k < lines.len and trailing > 0:
      let next = listMarker(lines[k])
      if next.ok and sameList(first, next):
        blankBetween = true
      else:
        # The blank lines end the list: they are not its own.
        k -= trailing
        break
  if blankBetween:
    seg.loose = true
  k

# --- Source pass: table alignment ----------------------------------------------------

proc isTableSeparator(line: string): bool =
  ## The docs dialect's delimiter row: `|` first, then only `|`, `-`,
  ## `:` and spaces.
  let t = line.strip()
  if not t.startsWith("|"):
    return false
  for ch in t:
    if ch notin {'|', '-', ':', ' '}:
      return false
  true

proc columnAligns(separator: string): seq[string] =
  ## Each column's alignment in a delimiter row (GFM): `:---` left,
  ## `:---:` center, `---:` right, `---` none ("").
  var t = separator.strip()
  if t.startsWith("|"):
    t = t[1 .. ^1]
  if t.endsWith("|"):
    t = t[0 ..< ^1]
  for cell in t.split('|'):
    let c = cell.strip()
    let l = c.startsWith(":")
    let r = c.len > 0 and c.endsWith(":") and (c.len > 1 or not l)
    result.add(if l and r and c.len > 1: "center" elif r: "right"
      elif l: "left" else: "")

proc segments(src: string): seq[Segment] =
  ## Splits the source into Markdown runs, block quotes and thematic
  ## breaks, rewriting setext headings to ATX and marking hard breaks.
  let lines = src.replace("\r\n", "\n").replace('\r', '\n').split('\n')
  var cur: seq[string] = @[]
  template flush() =
    if cur.len > 0:
      result.add(Segment(kind: skText, lines: cur))
      cur = @[]
  var i = 0
  var inFence = false
  var inDirective = false
  while i < lines.len:
    let line = lines[i]
    let t = line.strip()
    if inFence:
      cur.add(line)
      if t.startsWith("```"):
        inFence = false
      inc i
      continue
    if inDirective:
      cur.add(line)
      if t == ":::":
        inDirective = false
      inc i
      continue
    let paraOpen = cur.len > 0 and isParagraphLine(cur[^1])
    if t.len > 0 and leadingSpaces(line) >= 4:
      # An indented line opens no block (indented code is not read, and
      # its marker is no list's). Under a paragraph's line it is the
      # paragraph's next line; otherwise its run is a paragraph of its
      # own, its lines kept as hard breaks.
      if paraOpen:
        let next = if i + 1 < lines.len: lines[i + 1] else: ""
        cur[^1] = markHardBreak(joinLine(cur[^1], line),
          continuesParagraph(next))
        inc i
        continue
      var run: seq[string] = @[]
      while i < lines.len and lines[i].strip().len > 0 and
          leadingSpaces(lines[i]) >= 4:
        # One line for the AST: only the first can start a block there.
        run.add(lines[i].strip())
        inc i
      run[0] = asText(run[0])
      if cur.len > 0 and not isBlank(cur[^1]):
        cur.add("")
      cur.add(run.join(hardBreak))
      cur.add("")
      continue
    if t.startsWith("```"):
      inFence = true
      cur.add(line)
      inc i
      continue
    if t.startsWith(":::") and t.len > 3 and
        not t[3 .. ^1].strip().startsWith("video"):
      inDirective = true
      cur.add(line)
      inc i
      continue
    if isQuoteLine(line):
      flush()
      var q: seq[string] = @[]
      while i < lines.len:
        if isQuoteLine(lines[i]):
          q.add(unquote(lines[i]))
        elif q.len > 0 and q[^1].strip().len > 0 and
            isParagraphLine(lines[i]):
          q.add(lines[i]) # lazy continuation of the quoted paragraph
        else:
          break
        inc i
      result.add(Segment(kind: skQuote, lines: q))
      continue
    let underline = isSetextLine(line)
    if underline != '\0' and cur.len > 0 and isParagraphLine(cur[^1]):
      # The paragraph's lines above become the heading.
      var start = cur.len - 1
      while start > 0 and isParagraphLine(cur[start - 1]):
        dec start
      var words: seq[string] = @[]
      for k in start ..< cur.len:
        words.add(cur[k].strip().replace(hardBreak, " "))
      cur.setLen(start)
      cur.add((if underline == '=': "# " else: "## ") & words.join(" "))
      cur.add("")
      inc i
      continue
    if isBreakLine(line):
      flush()
      result.add(Segment(kind: skBreak))
      inc i
      continue
    if paraOpen:
      let mk = listMarker(line)
      if mk.ok and not canInterrupt(mk):
        # A list that may not interrupt a paragraph: the paragraph's
        # next line (`… in` / `2026. That year …` is one paragraph).
        let next = if i + 1 < lines.len: lines[i + 1] else: ""
        cur[^1] = markHardBreak(joinLine(cur[^1], line),
          continuesParagraph(next))
        inc i
        continue
    if listMarker(line).ok:
      # A list, read here: the docs AST's lists are flat.
      flush()
      var seg = Segment()
      i = listAt(lines, i, seg)
      result.add(seg)
      continue
    if t.startsWith("|") and i + 1 < lines.len and
        isTableSeparator(lines[i + 1]):
      # A table on its own, so its delimiter row's alignment goes with
      # the AST's table (the AST has none).
      flush()
      var seg = Segment(kind: skTable, aligns: columnAligns(lines[i + 1]))
      while i < lines.len and lines[i].strip().startsWith("|"):
        seg.lines.add(lines[i])
        inc i
      result.add(seg)
      continue
    let next = if i + 1 < lines.len: lines[i + 1] else: ""
    cur.add(if isParagraphLine(line): markHardBreak(line,
      continuesParagraph(next)) else: line)
    inc i
  flush()

# --- Inline: emphasis, escapes, autolinks, references --------------------------------

type
  ItemKind = enum ikNode, ikDelim
  Item = object
    case kind: ItemKind
    of ikNode:
      node: EmailNode
    of ikDelim:
      ch: char
      count: int
      origCount: int
      canOpen, canClose: bool

const asciiPunct = {'!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+',
  ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^',
  '_', '`', '{', '|', '}', '~'}

const namedRefs = {"amp": "&", "lt": "<", "gt": ">", "quot": "\"",
  "apos": "'", "nbsp": "\u00a0", "copy": "©", "reg": "®", "trade": "™",
  "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»",
  "euro": "€", "pound": "£", "yen": "¥", "middot": "·"}.toTable
  ## The character references read (anything else stays as typed).

proc charRef(s: string; i: int): tuple[text: string; len: int] =
  ## The character reference at `s[i]` (`&name;`, `&#n;`, `&#xh;`), or
  ## a zero length when there is none.
  let semi = s.find(';', i + 1)
  if semi < 0 or semi - i > 12:
    return ("", 0)
  let body = s[i + 1 ..< semi]
  if body.startsWith("#x") or body.startsWith("#X"):
    try:
      let v = parseHexInt(body[2 .. ^1])
      if v > 0 and v <= 0x10FFFF:
        return ($Rune(v), semi - i + 1)
    except ValueError: discard
  elif body.startsWith("#"):
    try:
      let v = parseInt(body[1 .. ^1])
      if v > 0 and v <= 0x10FFFF:
        return ($Rune(v), semi - i + 1)
    except ValueError: discard
  elif body in namedRefs:
    return (namedRefs[body], semi - i + 1)
  ("", 0)

proc isTagAt(s: string; i: int): int =
  ## The length of the raw HTML at `s[i]` (`<tag …>`, `</tag>`,
  ## `<!-- … -->`), 0 when there is none.
  if i + 3 < s.len and s.continuesWith("<!--", i):
    let e = s.find("-->", i + 4)
    return (if e < 0: s.len - i else: e + 3 - i)
  var j = i + 1
  if j < s.len and s[j] == '/':
    inc j
  if j >= s.len or s[j] notin Letters:
    return 0
  while j < s.len and s[j] in Letters + Digits + {'-'}:
    inc j
  if j >= s.len or s[j] notin Whitespace + {'/', '>'}:
    return 0
  let e = s.find('>', j)
  if e < 0: 0 else: e + 1 - i

proc autolinkAt(s: string; i: int): tuple[href: string; len: int] =
  ## `<https://…>`, `<http://…>`, `<mailto:…>`, `<tel:…>` at `s[i]`.
  let e = s.find('>', i + 1)
  if e < 0:
    return ("", 0)
  let inner = s[i + 1 ..< e]
  let lower = inner.toLowerAscii()
  if (lower.startsWith("https://") or lower.startsWith("http://") or
      lower.startsWith("mailto:") or lower.startsWith("tel:")) and
      not inner.contains(' ') and not inner.contains('<'):
    return (inner, e + 1 - i)
  ("", 0)

proc isPunct(r: Rune): bool =
  let c = int(r)
  if c < 128:
    return char(c) in asciiPunct
  # General punctuation and symbols outside ASCII.
  c in 0x2000 .. 0x206F or c in 0x3000 .. 0x303F or c in 0xFF00 .. 0xFF0F

proc isSpace(r: Rune): bool =
  int(r) < 128 and char(int(r)) in Whitespace or unicode.isWhiteSpace(r)

proc appendText(ctx: ExpandCtx; parent: EmailNode; text: string) =
  ctx.r.appendChild(parent, ctx.r.createTextNode(text))

proc lastRuneLen(s: string): int =
  var i = s.len - 1
  while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
    dec i
  s.len - i

proc lastRune(s: string): Rune =
  if s.len == 0: Rune(' ') else: s.runeAt(s.len - s.lastRuneLen)

type Tok = object
  ## One piece of an inline run: literal text, a delimiter run (`*`,
  ## `_`, `~`), or an element already made (code, a link, a break).
  text: string
  delim: char
  count: int
  node: EmailNode

proc textTokens(m: var MdCtx; s: string; toks: var seq[Tok]) =
  ## Tokenises one text span: escapes, references, autolinks, delimiter
  ## runs; raw HTML and footnotes stay text and are reported.
  var lit = ""
  template flushLit() =
    if lit.len > 0:
      toks.add(Tok(text: lit))
      lit = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\\' and i + 1 < s.len and s[i + 1] in asciiPunct:
      lit.add(s[i + 1])
      i += 2
    elif s.continuesWith(hardBreak, i):
      flushLit()
      toks.add(Tok(node: m.ctx.r.createElement("br")))
      i += hardBreak.len
      while i < s.len and s[i] == ' ':
        inc i
    elif c == '&':
      let (t, l) = charRef(s, i)
      if l > 0:
        lit.add(t)
        i += l
      else:
        lit.add(c)
        inc i
    elif c == '<':
      let (href, l) = autolinkAt(s, i)
      if l > 0:
        flushLit()
        let a = el(m.ctx, m.n, "a", attrs = [("href", href)])
        let shown = if href.toLowerAscii().startsWith("mailto:"): href[7 .. ^1]
          else: href
        appendText(m.ctx, a, shown)
        toks.add(Tok(node: a))
        i += l
        continue
      let h = isTagAt(s, i)
      if h > 0:
        m.warn("raw HTML", s[i ..< min(s.len, i + min(h, 40))])
        lit.add(s[i ..< i + h])
        i += h
      else:
        lit.add(c)
        inc i
    elif c == '[' and i + 1 < s.len and s[i + 1] == '^' and
        s.find(']', i + 2) > i + 2:
      let e = s.find(']', i + 2)
      m.warn("footnote", s[i .. e])
      lit.add(s[i .. e])
      i = e + 1
    elif c in {'*', '_', '~'}:
      var j = i
      while j < s.len and s[j] == c:
        inc j
      flushLit()
      toks.add(Tok(delim: c, count: j - i))
      i = j
    else:
      lit.add(c)
      inc i
  flushLit()

proc flank(toks: seq[Tok]; k: int): tuple[left, right: bool;
    before, after: Rune] =
  ## CommonMark's left- and right-flanking tests for the delimiter run
  ## at `k` (an element beside it counts as a letter).
  var before = Rune(' ')
  if k > 0:
    let p = toks[k - 1]
    before = if p.node != nil: Rune('a')
      elif p.delim != '\0': Rune(ord(p.delim))
      else: lastRune(p.text)
  var after = Rune(' ')
  if k + 1 < toks.len:
    let q = toks[k + 1]
    after = if q.node != nil: Rune('a')
      elif q.delim != '\0': Rune(ord(q.delim))
      else: q.text.runeAt(0)
  let left = not after.isSpace and (not after.isPunct or before.isSpace or
    before.isPunct)
  let right = not before.isSpace and (not before.isPunct or after.isSpace or
    after.isPunct)
  (left, right, before, after)

proc emphasise(m: var MdCtx; toks: seq[Tok]): seq[EmailNode] =
  ## CommonMark's "process emphasis" over the tokens, then the items as
  ## nodes, unmatched delimiters as text.
  var items: seq[Item] = @[]
  for k, t in toks:
    if t.node != nil:
      items.add(Item(kind: ikNode, node: t.node))
    elif t.delim != '\0':
      let (left, right, before, after) = flank(toks, k)
      var canOpen, canClose: bool
      case t.delim
      of '_':
        canOpen = left and (not right or before.isPunct)
        canClose = right and (not left or after.isPunct)
      of '~':
        canOpen = left and t.count == 2
        canClose = right and t.count == 2
      else:
        canOpen = left
        canClose = right
      items.add(Item(kind: ikDelim, ch: t.delim, count: t.count,
        origCount: t.count, canOpen: canOpen, canClose: canClose))
    else:
      items.add(Item(kind: ikNode, node: m.ctx.r.createTextNode(t.text)))
  var j = 0
  while j < items.len:
    if items[j].kind != ikDelim or not items[j].canClose or
        items[j].count == 0:
      inc j
      continue
    var o = j - 1
    var found = -1
    while o >= 0:
      let it = items[o]
      if it.kind == ikDelim and it.ch == items[j].ch and it.canOpen and
          it.count > 0:
        let oddMatch = (it.canClose or items[j].canOpen) and
          (it.origCount + items[j].origCount) mod 3 == 0 and
          not (it.origCount mod 3 == 0 and items[j].origCount mod 3 == 0)
        if not oddMatch:
          found = o
          break
      dec o
    if found < 0:
      inc j
      continue
    let use =
      if items[j].ch == '~': 2
      elif items[found].count >= 2 and items[j].count >= 2: 2
      else: 1
    let tag = if items[j].ch == '~': "s" elif use == 2: "strong" else: "em"
    let e = m.ctx.r.createElement(tag)
    e.origin = m.n.origin
    for k in found + 1 ..< j:
      let it = items[k]
      if it.kind == ikNode:
        m.ctx.r.appendChild(e, it.node)
      elif it.count > 0:
        m.ctx.r.appendChild(e, m.ctx.r.createTextNode(repeat(it.ch, it.count)))
    items[found].count -= use
    items[j].count -= use
    var rebuilt = items[0 .. found]
    rebuilt.add(Item(kind: ikNode, node: e))
    let closerAt = rebuilt.len
    rebuilt.add(items[j .. ^1])
    items = rebuilt
    j = closerAt
  var lit = ""
  template flushLit() =
    if lit.len > 0:
      result.add(m.ctx.r.createTextNode(lit))
      lit = ""
  for it in items:
    if it.kind == ikDelim:
      lit.add(repeat(it.ch, it.count))
    elif it.node.kind == enText:
      lit.add(it.node.text)
    else:
      flushLit()
      result.add(it.node)
  flushLit()

proc inlineNodes(m: var MdCtx; spans: seq[InlineSpan]): seq[EmailNode] =
  ## The elements of a run of inline spans. An image here (a heading, a
  ## list item, a table cell) is written as its alt text and reported:
  ## images are blocks of their own (`blockNodes`).
  var toks: seq[Tok] = @[]
  for s in spans:
    case s.kind
    of ikText:
      if s.escaped: toks.add(Tok(text: s.text))
      else: m.textTokens(s.text, toks)
    of ikCode, ikSymRef:
      let code = el(m.ctx, m.n, "codeInline", text = s.text)
      toks.add(Tok(node: code))
    of ikLink:
      # The link's target is checked by P1 like every `a` (catalogue
      # R-TXT-13): the docs dialect resolves a relative target against
      # the docs site, which no mail client can follow.
      let a = el(m.ctx, m.n, "a", attrs = [("href", s.href), ("title", s.title)])
      var inner: seq[Tok] = @[]
      case s.linkOrigin
      of loExplicit:
        # Only the parser knows which punctuation was escaped in the authored
        # label. Preserve that source for email's own emphasis dialect.
        m.textTokens(s.labelSource, inner)
      of loAngleAutolink, loBareAutolink:
        let label = if s.linkOrigin == loAngleAutolink and
            s.text.toLowerAscii().startsWith("mailto:"): s.text[7 .. ^1] else: s.text
        inner.add Tok(text: label)
      of loUnspecified:
        m.textTokens(s.text, inner)
      for c in m.emphasise(inner):
        m.ctx.r.appendChild(a, c)
      toks.add(Tok(node: a))
    of ikImage:
      m.warn("image inside a heading, a list item or a table cell",
        "![" & s.text & "]")
      toks.add(Tok(text: s.text))
    of ikStrike:
      let node = el(m.ctx, m.n, "s")
      for child in m.inlineNodes(s.children): m.ctx.r.appendChild(node, child)
      toks.add(Tok(node: node))
    of ikFootnoteRef:
      m.textTokens("[^" & s.text & "]", toks)
  m.emphasise(toks)

proc trimBreaks(nodes: seq[EmailNode]): seq[EmailNode] =
  ## A line break at either end of a block is no break.
  result = nodes
  while result.len > 0 and result[^1].kind == enElement and
      result[^1].tag == "br":
    result.setLen(result.len - 1)
  while result.len > 0 and result[0].kind == enElement and
      result[0].tag == "br":
    result.delete(0)

proc hasText(nodes: seq[EmailNode]): bool =
  for x in nodes:
    if x.kind == enText:
      if x.text.strip().len > 0:
        return true
    else:
      return true
  false

# --- Blocks ------------------------------------------------------------------------

proc image(m: var MdCtx; s: InlineSpan): EmailNode =
  result = el(m.ctx, m.n, "mailImage", attrs = [("src", s.href),
    ("alt", s.text), ("title", s.title), ("fluid_on_mobile", "true")])
  if s.text.strip().len == 0:
    # No alt text: a decorative image (`alt=""`, R-IMG-04).
    m.ctx.r.setAttribute(result, "alt", "")
    m.ctx.r.setAttribute(result, "decorative", "true")
  if m.p.image_width.strip().len > 0:
    m.ctx.r.setStyle(result, "width",
      $pxProp(m.n, m.p.image_width, "image_width") & "px")

proc paragraph(m: var MdCtx; spans: seq[InlineSpan]): seq[EmailNode] =
  ## A paragraph; an image in it is a block of its own between the
  ## paragraphs its text makes.
  var run: seq[InlineSpan] = @[]
  template flushRun() =
    if run.len > 0:
      let kids = trimBreaks(m.inlineNodes(run))
      # The text beside an image ends and starts its paragraphs.
      if kids.len > 0 and kids[0].kind == enText:
        kids[0].text = kids[0].text.strip(trailing = false)
      if kids.len > 0 and kids[^1].kind == enText:
        kids[^1].text = kids[^1].text.strip(leading = false)
      if hasText(kids):
        let p = el(m.ctx, m.n, "p")
        for k in kids:
          m.ctx.r.appendChild(p, k)
        result.add(p)
      run = @[]
  for s in spans:
    if s.kind == ikImage and m.inItem == 0:
      # In a list item an image stays inline: `inlineNodes` writes its
      # alt text and reports it.
      flushRun()
      result.add(m.image(s))
    else:
      run.add(s)
  flushRun()

proc captionSeparator(n: EmailNode): string =
  ## Between a table's header labels in its caption: the Arabic comma in
  ## Arabic script languages, a comma elsewhere.
  var a = n
  while a != nil and not (a.kind == enElement and a.tag == "mailDocument"):
    a = a.parent
  let lang = if a == nil: "" else: a.attrs.getOrDefault("lang", "")
  for prefix in ["ar", "fa", "ur"]:
    if lang == prefix or lang.startsWith(prefix & "-"):
      return "\u060c "
  ", "

proc withKids(m: MdCtx; tag: string; kids: seq[EmailNode]): EmailNode =
  result = el(m.ctx, m.n, tag)
  for k in kids:
    m.ctx.r.appendChild(result, k)

proc blockNodes(m: var MdCtx; src: string): seq[EmailNode]

proc aligned(m: MdCtx; cell: EmailNode; aligns: seq[string];
    col: int): EmailNode =
  ## `cell` with its column's alignment (the delimiter row's), as its
  ## `text-align`: the style pass writes it as `align` and `text-align`
  ## (catalogue R-TBL-14).
  if col < aligns.len and aligns[col].len > 0:
    m.ctx.r.setStyle(cell, "text-align", aligns[col])
  cell

proc mapBlock(m: var MdCtx; b: Block; aligns: seq[string] = @[]):
    seq[EmailNode] =
  case b.kind
  of bkHeading:
    let level = min(6, b.level + m.p.heading_offset)
    let kids = trimBreaks(m.inlineNodes(parseInlineSpans(b.headingText)))
    result.add(m.withKids("h" & $level, kids))
  of bkParagraph:
    result.add(m.paragraph(b.spans))
  of bkList:
    # Not reached: the source pass reads every list (`listAt`), so the
    # AST's flat lists never form. Mapped as a one-level list anyway.
    let list = el(m.ctx, m.n, if b.listKind == lkOrdered: "ol" else: "ul")
    for item in b.items:
      m.ctx.r.appendChild(list, m.withKids("li",
        trimBreaks(m.inlineNodes(item))))
    result.add(list)
  of bkCodeFence:
    let code = el(m.ctx, m.n, "mailCodeBlock")
    m.ctx.r.appendChild(code, m.ctx.r.createTextNode(b.code))
    result.add(code)
  of bkTable:
    var labels: seq[string] = @[]
    for h in b.headers:
      labels.add(spansText(parseInlineSpans(h)).strip())
    let t = el(m.ctx, m.n, "mailTable", attrs = [("caption",
      labels.join(captionSeparator(m.n)))])
    let table = el(m.ctx, m.n, "table")
    let head = el(m.ctx, m.n, "thead")
    let hr = el(m.ctx, m.n, "tr")
    for col, h in b.headers:
      m.ctx.r.appendChild(hr, m.aligned(m.withKids("th",
        m.inlineNodes(parseInlineSpans(h))), aligns, col))
    m.ctx.r.appendChild(head, hr)
    m.ctx.r.appendChild(table, head)
    let body = el(m.ctx, m.n, "tbody")
    for row in b.rows:
      let tr = el(m.ctx, m.n, "tr")
      for col, cell in row:
        m.ctx.r.appendChild(tr, m.aligned(m.withKids("td",
          m.inlineNodes(parseInlineSpans(cell))), aligns, col))
      m.ctx.r.appendChild(body, tr)
    m.ctx.r.appendChild(table, body)
    m.ctx.r.appendChild(t, table)
    result.add(t)
  of bkAdmonition:
    let (tone, word) = admonitionTone(b.admonitionKind)
    let c = el(m.ctx, m.n, "mailCallout", attrs = [("tone", tone),
      ("label", word)])
    for para in b.bodyParagraphs:
      for x in m.paragraph(para):
        m.ctx.r.appendChild(c, x)
    result.add(c)
  of bkButton:
    let href = b.button.href.strip()
    let variant = if b.button.variant == "secondary": "outline" else: "solid"
    let btn = el(m.ctx, m.n, "mailButton", attrs = [("href", href),
      ("variant", variant)])
    var toks: seq[Tok] = @[]
    m.textTokens(b.button.label, toks)
    for k in m.emphasise(toks):
      m.ctx.r.appendChild(btn, k)
    result.add(btn)
  of bkBlockquote:
    let quote = el(m.ctx, m.n, "blockquote")
    for child in b.quoteBlocks:
      for node in m.mapBlock(child): m.ctx.r.appendChild(quote, node)
    result.add quote
  of bkFigure:
    result.add m.image(b.figureImage)
    result.add m.paragraph(b.caption)
  of bkFootnotes: m.refuse("footnotes")
  of bkExcerptBreak: discard
  of bkTabs: m.refuse("tabs (:::tabs)")
  of bkCardGrid: m.refuse("card grid (:::cards)")
  of bkHero: m.refuse("hero (:::hero)")
  of bkFaq: m.refuse("FAQ (:::faq)")
  of bkVideo: m.refuse("video (:::video)")
  of bkForm: m.refuse("form (:::form)")
  of bkComponent: m.refuse("component tag <" & b.componentName & ">")

proc list(m: var MdCtx; seg: Segment): EmailNode =
  ## A list the source pass read: each item's content read as Markdown
  ## again (a sub-list is a list inside the item). A tight list's items
  ## hold their paragraphs' content directly, a loose one's the `p`s.
  result = el(m.ctx, m.n, if seg.ordered: "ol" else: "ul")
  if seg.ordered and seg.start != 1:
    m.ctx.r.setAttribute(result, "start", $seg.start)
  for item in seg.items:
    inc m.inItem
    let kids = m.blockNodes(item.join("\n"))
    dec m.inItem
    let li = el(m.ctx, m.n, "li")
    var afterText = false # the last child is a paragraph's content
    for k in kids:
      if not seg.loose and k.kind == enElement and k.tag == "p":
        if afterText:
          m.ctx.r.appendChild(li, m.ctx.r.createElement("br"))
        let inner = k.children
        for c in inner:
          m.ctx.r.appendChild(li, c)
        afterText = true
      else:
        m.ctx.r.appendChild(li, k)
        afterText = false
    m.ctx.r.appendChild(result, li)

proc blockNodes(m: var MdCtx; src: string): seq[EmailNode] =
  for seg in segments(src):
    case seg.kind
    of skBreak:
      result.add(el(m.ctx, m.n, "mailDivider"))
    of skQuote:
      let inner = m.blockNodes(seg.lines.join("\n"))
      if inner.len > 0:
        result.add(m.withKids("blockquote", inner))
    of skText:
      for b in parseMarkdownBlocks(seg.lines.join("\n"), footnotes = false):
        result.add(m.mapBlock(b))
    of skTable:
      for b in parseMarkdownBlocks(seg.lines.join("\n"), footnotes = false):
        result.add(m.mapBlock(b, seg.aligns))
    of skList:
      result.add(m.list(seg))

# --- The pattern -------------------------------------------------------------------

proc markdownSource*(src: string): string =
  ## The Markdown `src` holds, as written less a string literal's edges
  ## and indentation: leading blank lines (white space only) and
  ## trailing white space dropped, and the indentation every other
  ## non-blank line shares removed from each line (the longest run of
  ## spaces and tabs they all start with, compared character by
  ## character); a line of white space only is an empty line.
  ## Indentation relative to the rest is kept: a line indented past the
  ## others keeps the difference.
  let lines = src.replace("\r\n", "\n").replace('\r', '\n').split('\n')
  var first = 0
  while first < lines.len and isBlank(lines[first]):
    inc first
  var last = lines.len - 1
  while last >= first and isBlank(lines[last]):
    dec last
  if first > last:
    return ""
  var common = ""
  var seen = false
  for i in first .. last:
    let line = lines[i]
    if isBlank(line):
      continue
    var w = 0
    while w < line.len and line[w] in {' ', '\t'}:
      inc w
    if not seen:
      common = line[0 ..< w]
      seen = true
    else:
      var k = 0
      while k < common.len and k < w and line[k] == common[k]:
        inc k
      common.setLen(k)
  for i in first .. last:
    if isBlank(lines[i]):
      result.add("")
    else:
      result.add(lines[i][common.len .. ^1])
    if i < last:
      result.add('\n')
  result = result.strip(leading = false)

proc markdownNodes*(ctx: ExpandCtx; n: EmailNode; p: MarkdownProps):
    seq[EmailNode] =
  ## The elements `p.src` reads as, for `n`'s expansion.
  var m = MdCtx(ctx: ctx, n: n, p: p)
  if p.heading_offset < 0 or p.heading_offset > maxHeadingOffset:
    raise newException(PatternError, "mailMarkdown heading_offset = " &
      $p.heading_offset & " is not 0–" & $maxHeadingOffset)
  m.blockNodes(markdownSource(p.src))

proc markdownExpand(n: EmailNode; p: MarkdownProps;
    ctx: ExpandCtx): EmailNode =
  discard required(n, p.src, "src", "the Markdown it renders")
  if slot(n).len > 0:
    raise newException(PatternError, "mailMarkdown holds no content: its " &
      "Markdown is its src")
  # A stack, 16px between blocks: a code block, a table, a callout and
  # a quote have no margins of their own, so the stack spaces them (and,
  # as for any stack, its items' own margins give way to its gap).
  result = el(ctx, n, "mailStack", styles = [("gap", "tok:space.4")])
  for x in markdownNodes(ctx, n, p):
    ctx.r.appendChild(result, x)

proc countTags(nodes: seq[EmailNode]; acc: var CountTable[string]) =
  for x in nodes:
    if x.kind == enElement:
      acc.inc(x.tag)
      countTags(x.children, acc)

proc nestedLists(nodes: seq[EmailNode]; inItem = false): int =
  ## The lists inside a list item.
  for x in nodes:
    if x.kind == enElement:
      if inItem and x.tag in ["ul", "ol"]:
        inc result
      result += nestedLists(x.children, inItem or x.tag == "li")

proc markdownExpected(n: EmailNode; p: MarkdownProps;
    view: BriefView): seq[string] =
  ## What the body shows, counted from its own expansion.
  var nodes: seq[EmailNode] = @[]
  try:
    let ctx = ExpandCtx(r: EmailRenderer(), target: defaultTarget())
    nodes = markdownNodes(ctx, n, p)
  except PatternError:
    return @["Markdown body: refused (see the render's diagnostics)."]
  var c = initCountTable[string]()
  countTags(nodes, c)
  var parts: seq[string] = @[]
  var headings = 0
  for h in ["h1", "h2", "h3", "h4", "h5", "h6"]:
    headings += c.getOrDefault(h)
  proc say(k: int; one, many: string) =
    if k == 1: parts.add(one)
    elif k > 1: parts.add($k & " " & many)
  say(headings, "a heading", "headings")
  var paragraphs = 0 # the body's own, not those of a quote or a callout
  for x in nodes:
    if x.kind == enElement and x.tag == "p":
      inc paragraphs
  say(paragraphs, "a paragraph", "paragraphs")
  say(c.getOrDefault("strong") + c.getOrDefault("em"),
    "a bold or italic phrase", "bold or italic phrases")
  say(c.getOrDefault("s"), "a struck-through phrase", "struck-through phrases")
  say(c.getOrDefault("a"), "a link", "links")
  let nested = nestedLists(nodes)
  say(c.getOrDefault("ul") + c.getOrDefault("ol") - nested,
    "a list (bullets or numbers, each item on its own line)", "lists")
  say(nested, "a nested list, indented under its item", "nested lists, " &
    "each indented under its item")
  say(c.getOrDefault("codeInline"), "an inline code span in a monospace " &
    "face on a grey tint", "inline code spans")
  say(c.getOrDefault("mailCodeBlock"), "a code block (monospace, on a " &
    "grey panel, its lines wrapped, never scrolled)", "code blocks")
  say(c.getOrDefault("blockquote"), "a quotation set in from the " &
    startSide(n) & " edge behind a grey bar", "quotations")
  say(c.getOrDefault("mailDivider"), "a thin divider line", "divider lines")
  say(c.getOrDefault("mailTable"), "a table with a bold header row",
    "tables")
  say(c.getOrDefault("mailCallout"), "a callout (a tinted panel with a " &
    "coloured bar at its " & startSide(n) & " edge)", "callouts")
  say(c.getOrDefault("mailImage"), "an image on its own line", "images")
  say(c.getOrDefault("mailButton"), "a button", "buttons")
  @["Markdown body, read as email text: " & parts.join(", ") &
    "; no Markdown syntax characters (#, *, _, `, >, |) left visible " &
    "except where the text says them."]

proc markdownDegradations(n: EmailNode; p: MarkdownProps;
    view: BriefView): seq[string] =
  if p.src.contains("![") and view.client == "imagesOff":
    result.add("with images off, each image shows its alt text in its box")

defineMailPattern(mailMarkdown, MarkdownProps, markdownExpand,
  markdownExpected, markdownDegradations)
