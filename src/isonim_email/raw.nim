## isonim_email/raw.nim — the reader behind `mailRaw`.
##
## `mailRaw` is the escape hatch for HTML the author trusts. Its
## payloads are written byte for byte: this module is not a sanitiser
## and never changes or refuses markup for what it might do. It reads
## each payload into a tree of its own (elements with their attributes
## and inline `style` declarations, text, and conditional comments as
## conditionals) so that the validation pass (P1) and the lint (P10)
## check raw markup as they check generated HTML (catalogue R-RAW-01).
##
## What it does report is markup that would break the message built
## around the payload (R-RAW-02, `E-RAW-MALFORMED`). Its tokenizer
## follows the HTML Standard's tokenizer where a balance check depends
## on it: tags and their attributes (a quoted `>` ends no tag),
## comments (a comment ends at its first `-->` or `--!>`; `<!-->` and
## `<!--->` are whole comments), bogus comments (`<!…>`, `<?…>`, `</ …>`
## end at the first `>`), and the raw-text elements (`script`, `style`,
## `textarea`, `title`, `xmp`, `iframe`, `noembed`, `noframes`), whose
## content is text up to their end tag. It does not model the tree
## builder: no implied end tags, no foster parenting, no adoption
## agency, no foreign content. So it asks for explicit balance, which
## is stricter than a parser, and it refuses `<svg>` and `<math>`
## outright: a parser reads parts of foreign content as HTML (on HTML
## tags, inside `foreignObject`, `title`, `mi` and the like, and the
## content of `style` or `script` there is markup), so their structure
## cannot be checked without that algorithm, and mail clients largely
## do not render them (the template vocabulary refuses `svg` too; an
## image does the job). `<noscript>` is refused as well: its content is
## text with scripting on and markup with it off, and scripts never run
## in email. These checks cover plausible authoring mistakes and a
## fixed corpus of parser probes (`tests/t5_raw.nim`); constructs the
## reader cannot verify are refused rather than modelled, and further
## exotic parser behaviour is handled as an issue when found. It
## reports:
##
## - a tag, comment or quoted value left open, or a raw-text element
##   never closed, which would swallow the markup after the payload;
##   `<plaintext>`, which swallows all of it; `<!--` inside `script` or
##   `style` (in a script it can keep a parser in script text past
##   `</script>`);
## - an element the payload opens and does not close (void elements
##   aside), an end tag that closes no element the payload opened (it
##   would close the library's markup around it), and misnested tags;
## - a table part (`td`, `th`, `tr`, `tbody`, `thead`, `tfoot`,
##   `caption`, `col`, `colgroup`) outside a `table` the payload opens:
##   an HTML parser reads it against the table the payload sits in and
##   closes the host cell;
## - in a text element, an element that closes a paragraph; in a link,
##   a link; in a list item, an `li` outside a list the payload opens
##   (`RawContext`);
## - conditional comments: one of R-OL-01's two forms, `[if` and
##   `[endif]` matched without case as Word matches them, a condition
##   from R-OL-02's set, closed in the same payload and closing nothing
##   it did not open. Inside a conditional, and anywhere in a payload
##   that sits in one (a `mailIf`, or content the library may copy into
##   Word's conditional), there is no comment, no conditional and no
##   `<!--`, `-->`, `--!>` or `<![` at all, not even in an attribute
##   value: comments do not nest, so any of them would end the
##   conditional early and show Word-only content to every client.
##
## Separately, as warnings (R-RAW-03, `W-RAW-UNSUPPORTED`), it names
## what mail clients strip: the elements the vocabulary refuses in
## templates (`rawUnsupportedElements`), event-handler attributes,
## `javascript:` and `vbscript:` URLs, and VML outside Word's
## conditional. The payload is written as it is all the same.
##
## Reading continues past a problem where it can, so one pass reports
## every problem it can see; the tree is linted only when the payload
## has no error.
##
## Pure string work: identical on the C and JS targets.

import std/[strutils, tables, unicode]
import ./renderer
import ./mso/cond
import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  RawProblem* = object
    ## One finding on a payload: an error (R-RAW-02, `E-RAW-MALFORMED`:
    ## the payload would break the message's structure, and is not
    ## written) or, with `warning`, a compatibility note (R-RAW-03,
    ## `W-RAW-UNSUPPORTED`: clients strip it; written anyway).
    warning*: bool
    message*: string
    rules*: seq[string]

  RawContext* = object
    ## Where a payload sits; `rawContextOf` computes it.
    inConditional*: bool  ## In a conditional comment the library writes
    phrasing*: bool       ## In a text element
    inLink*: bool         ## In a link
    inListItem*: bool     ## In a list item (`li`)
    refused*: string      ## Non-empty: no raw markup may sit here (why)

  RawRead* = object
    ## A payload read: its top-level nodes and every finding.
    nodes*: seq[EmailNode]
    problems*: seq[RawProblem]

const
  voidElements = ["area", "base", "basefont", "bgsound", "br", "col",
    "embed", "frame", "hr", "image", "img", "input", "keygen", "link",
    "meta", "param", "source", "track", "wbr"]
    ## Elements an HTML parser never leaves open (`image` reads as `img`).
  rawTextElements = ["script", "style", "xmp", "iframe", "noembed",
    "noframes", "textarea", "title"]
    ## Elements whose content is text up to their end tag (`noscript`,
    ## text or markup depending on scripting, is refused).
  tableParts* = ["caption", "col", "colgroup", "tbody", "td", "tfoot",
    "th", "thead", "tr"]
    ## Valid only inside a table the payload opens.
  closesParagraph = ["address", "article", "aside", "blockquote",
    "center", "details", "dialog", "dir", "div", "dl", "fieldset",
    "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
    "h5", "h6", "header", "hgroup", "hr", "li", "dd", "dt", "listing",
    "main", "menu", "nav", "ol", "p", "pre", "search", "section",
    "summary", "table", "ul", "xmp"]
    ## Start tags that close an open paragraph (or heading).
  rawConditions* = ["mso", "gte mso 9", "lte mso 11"]
    ## R-OL-02's set besides `!mso`, as a payload's conditional may
    ## name it (compared without case, white space collapsed).
  rawUnsupportedElements* = ["script", "iframe", "object", "embed",
    "form", "input", "video", "audio", "canvas"]
    ## Elements mail clients strip (the vocabulary refuses them in
    ## templates): `W-RAW-UNSUPPORTED`.
  space = {' ', '\t', '\n', '\r', '\f'}

proc refused*(r: RawRead): bool =
  ## True when the payload has an error (not just warnings): it would
  ## break the message, so it is not written and not linted.
  for p in r.problems:
    if not p.warning:
      return true
  false

proc malformed(r: var RawRead; msg: string; rules = @["R-RAW-02"]) =
  r.problems.add(RawProblem(message: msg, rules: rules))

proc unsupported(r: var RawRead; msg: string) =
  r.problems.add(RawProblem(warning: true, message: msg,
    rules: @["R-RAW-03"]))

# --- values -------------------------------------------------------------------

proc decodeRefs*(s: string): string =
  ## `s` with its numeric character references and the common named ones
  ## (`amp`, `lt`, `gt`, `quot`, `apos`, `nbsp`) decoded; anything else
  ## is kept as written. For the checks only: the output is the payload.
  var i = 0
  let n = s.len
  while i < n:
    if s[i] != '&':
      result.add(s[i])
      inc i
      continue
    var j = i + 1
    if j < n and s[j] == '#':
      inc j
      let hex = j < n and s[j] in {'x', 'X'}
      if hex:
        inc j
      let start = j
      var code = 0
      while j < n and (s[j] in Digits or (hex and s[j] in HexDigits)):
        let d = if s[j] in Digits: ord(s[j]) - ord('0')
          else: (ord(s[j]) or 0x20) - ord('a') + 10
        code = min(code * (if hex: 16 else: 10) + d, 0x110000)
        inc j
      if j == start:
        result.add(s[i ..< j])
        i = j
        continue
      if j < n and s[j] == ';':
        inc j
      if code == 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF):
        code = 0xFFFD
      result.add($Rune(code))
      i = j
      continue
    var hit = false
    for (name, value) in [("amp;", "&"), ("lt;", "<"), ("gt;", ">"),
        ("quot;", "\""), ("apos;", "'"), ("nbsp;", " ")]:
      if s.continuesWith(name, j):
        result.add(value)
        i = j + name.len
        hit = true
        break
    if not hit:
      result.add('&')
      inc i

proc urlScheme*(value: string): string =
  ## The scheme a URL parser reads from a decoded attribute value, in
  ## lower case (leading C0 controls and spaces dropped, tabs and
  ## newlines removed anywhere); "" for none.
  var v = ""
  for c in value:
    if c notin {'\t', '\n', '\r'}:
      v.add(c)
  var a = 0
  while a < v.len and ord(v[a]) <= 0x20:
    inc a
  if a >= v.len or v[a] notin {'a' .. 'z', 'A' .. 'Z'}:
    return ""
  var k = a + 1
  while k < v.len and v[k] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '+',
      '-', '.'}:
    inc k
  if k < v.len and v[k] == ':':
    return v[a ..< k].toLowerAscii()
  ""

proc parseStyle(css: string; node: EmailNode) =
  ## The declarations of an inline `style`, into `node.styles` for the
  ## passes: split on `;` outside quotes and brackets.
  var depth = 0
  var quote = '\0'
  var start = 0
  for k in 0 .. css.len:
    if k == css.len or (css[k] == ';' and depth == 0 and quote == '\0'):
      let decl = css[start ..< k]
      let colon = decl.find(':')
      if colon > 0:
        let prop = decl[0 ..< colon].strip().toLowerAscii()
        let value = decl[colon + 1 .. ^1].strip()
        if prop.len > 0 and value.len > 0:
          node.styles[prop] = value
      start = k + 1
    elif quote != '\0':
      if css[k] == quote:
        quote = '\0'
    elif css[k] in {'"', '\''}:
      quote = css[k]
    elif css[k] == '(':
      inc depth
    elif css[k] == ')' and depth > 0:
      dec depth

proc readTagRest(src: string; j: var int; attrs: var seq[(string, string)];
    selfClosing: var bool): string =
  ## The HTML Standard's attribute states, from after a tag's name to
  ## its `>`: fills `attrs` (names in lower case, the first of a repeated
  ## name kept, values as written) and returns "" , or why the tag never
  ## ends.
  let n = src.len
  while true:
    while j < n and src[j] in space:
      inc j
    if j >= n:
      return "the tag is never closed"
    if src[j] == '>':
      inc j
      return ""
    if src[j] == '/':
      inc j
      if j < n and src[j] == '>':
        selfClosing = true
        inc j
        return ""
      continue
    let a = j
    inc j
    while j < n and src[j] notin space + {'/', '>', '='}:
      inc j
    let name = src[a ..< j].toLowerAscii()
    while j < n and src[j] in space:
      inc j
    var value = ""
    if j < n and src[j] == '=':
      inc j
      while j < n and src[j] in space:
        inc j
      if j >= n:
        return "the tag is never closed"
      if src[j] in {'"', '\''}:
        let e = src.find(src[j], j + 1)
        if e < 0:
          return "the quoted value of " & name & " is never closed"
        value = src[j + 1 ..< e]
        j = e + 1
      elif src[j] != '>':
        let v = j
        while j < n and src[j] notin space + {'>'}:
          inc j
        value = src[v ..< j]
    var seen = false
    for (x, _) in attrs:
      if x == name:
        seen = true
    if not seen:
      attrs.add((name, value))

proc looksConditional(data: string): bool =
  let l = data.toLowerAscii()
  "[if" in l or "[endif" in l

# --- the reader ---------------------------------------------------------------

type
  Frame = object
    ## One open element or conditional while reading.
    node: EmailNode
    tag: string           ## "" for the payload's top and for conditionals
    cond: bool            ## A conditional comment
    revealed: bool        ## Its `<!--[if …]><!-->` form
    msoOnly: bool         ## Content only Word reads
    contentStart: int     ## Where a conditional's content starts
    selfClosed: bool      ## Written `<x/>` (HTML keeps it open)

proc readRaw*(payload: string; ctx = RawContext()): RawRead =
  ## Reads one `raw` payload (see the module comment) placed in `ctx`.
  ## The nodes are a tree of their own, for the checks only: the output
  ## is always the payload as written.
  var r: RawRead
  if ctx.refused.len > 0:
    r.malformed(ctx.refused)
    return r
  if validateUtf8(payload) != -1:
    r.malformed("the payload is not valid UTF-8")
    return r
  let src = payload
  let n = src.len
  let er = EmailRenderer()
  let root = er.createElement("#raw")
  var stack: seq[Frame] = @[Frame(node: root)]
  var regions: seq[(int, int)] = @[]  # The content of each conditional

  proc inMso(): bool =
    for f in stack:
      if f.msoOnly:
        return true
    false
  proc inTable(): bool =
    for k in countdown(stack.high, 1):
      if stack[k].tag == "table":
        return true
    false
  proc inList(): bool =
    for k in countdown(stack.high, 1):
      if stack[k].tag in ["ul", "ol", "menu"]:
        return true
    false
  proc inLink(): bool =
    for f in stack:
      if f.tag == "a":
        return true
    false

  var text = ""
  proc flushText() =
    if text.len > 0:
      er.appendChild(stack[^1].node, er.createTextNode(decodeRefs(text)))
      text = ""

  proc bogus(i: var int; start: int): bool =
    ## A bogus comment (`<!…>`, `<?…>`, `</ …>`) from `start` to its
    ## first `>`; false when it never ends.
    let close = src.find('>', start)
    if close < 0:
      r.malformed("'" & src[i ..< min(n, i + 12)] & "…' starts a comment " &
        "that never ends: it would swallow the rest of the message")
      return false
    if looksConditional(src[i ..< close]):
      r.malformed("'" & src[i .. close] & "' looks like a conditional " &
        "comment but is not one of the two forms (Word reads it as one)",
        @["R-RAW-02", "R-OL-01"])
    i = close + 1
    true

  var i = 0
  while i < n:
    if src[i] != '<':
      text.add(src[i])
      inc i
      continue
    let head = src[i ..< min(n, i + 16)].toLowerAscii()
    # --- the end of a conditional ---
    if head.startsWith("<![endif]-->") or head.startsWith("<!--<![endif]-->"):
      flushText()
      let revealedClose = head.startsWith("<!--")
      let token = src[i ..< i + (if revealedClose: 16 else: 12)]
      var k = stack.high
      while k >= 1 and not stack[k].cond:
        dec k
      if k < 1:
        r.malformed(token & " closes no conditional comment this payload " &
          "opened: it would close one around the payload",
          @["R-RAW-02", "R-OL-01"])
      else:
        if stack[k].revealed != revealedClose:
          r.malformed(token & " closes a conditional written in the other " &
            "form: <!--[if mso]> ends with <![endif]-->, <!--[if !mso]><!--> " &
            "with <!--<![endif]-->", @["R-RAW-02", "R-OL-01"])
        if k != stack.high:
          r.malformed(token & " ends the conditional while <" &
            stack[^1].tag & ">, opened inside it, is still open")
        regions.add((stack[k].contentStart, i))
        stack.setLen(k)
      i += token.len
      continue
    # --- the start of a conditional ---
    if head.startsWith("<!--[if"):
      flushText()
      let close = src.find("]>", i)
      let commentEnd = src.find("-->", i + 4)
      if close < 0 or (commentEnd >= 0 and commentEnd < close):
        r.malformed("'" & src[i ..< min(n, i + 20)] & "…' is not a " &
          "conditional comment (no ']>')", @["R-RAW-02", "R-OL-01"])
        if commentEnd < 0:
          break
        i = commentEnd + 3
        continue
      let cond = strutils.splitWhitespace(src[i + 7 ..< close]).join(" ").toLowerAscii()
      var after = close + 2
      let revealed = src.continuesWith("<!-->", after)
      if revealed:
        after += "<!-->".len
      if cond == "!mso":
        if not revealed:
          r.malformed("<!--[if !mso]> must be followed by <!-->: otherwise " &
            "its content is a comment to every client but Word, and Word " &
            "skips it (R-OL-01)", @["R-RAW-02", "R-OL-01"])
      else:
        if cond notin rawConditions:
          r.malformed("conditional '" & cond & "' is outside the set the " &
            "library uses (mso, !mso, gte mso 9, lte mso 11)",
            @["R-RAW-02", "R-OL-02"])
        if revealed:
          r.malformed("<!--[if " & cond & "]><!--> shows its content to " &
            "every client, not only Word: Word's form is <!--[if " & cond &
            "]>…<![endif]-->", @["R-RAW-02", "R-OL-01"])
      let node =
        if cond == "!mso": notMsoWrap()
        elif cond in rawConditions: msoCond(cond)
        else: msoCond("mso")
      er.appendChild(stack[^1].node, node)
      stack.add(Frame(node: node, cond: true, revealed: revealed,
        msoOnly: cond != "!mso", contentStart: after))
      i = after
      continue
    # --- comments ---
    if src.continuesWith("<!--", i):
      flushText()
      let j = i + 4
      var dataEnd, stop: int
      if j < n and src[j] == '>':
        dataEnd = j
        stop = j + 1      # <!--> : an empty comment
      elif src.continuesWith("->", j):
        dataEnd = j
        stop = j + 2      # <!---> : an empty comment
      else:
        let e1 = src.find("-->", j)
        let e2 = src.find("--!>", j)
        if e1 < 0 and e2 < 0:
          r.malformed("a comment that is never closed: it would swallow " &
            "the rest of the message")
          break
        if e2 >= 0 and (e1 < 0 or e2 < e1):
          dataEnd = e2
          stop = e2 + 4
        else:
          dataEnd = e1
          stop = e1 + 3
      if looksConditional(src[j ..< dataEnd]):
        r.malformed("a comment that looks like a conditional comment but " &
          "is not one of the two forms (Word reads it as one)",
          @["R-RAW-02", "R-OL-01"])
      i = stop
      continue
    if src.continuesWith("<!", i) or src.continuesWith("<?", i):
      flushText()
      if not bogus(i, i + 2):
        break
      continue
    # --- end tags ---
    if src.continuesWith("</", i):
      flushText()
      if i + 2 < n and src[i + 2] == '>':
        i += 3 # `</>` is dropped.
        continue
      if i + 2 >= n or src[i + 2] notin {'a' .. 'z', 'A' .. 'Z'}:
        if not bogus(i, i + 2):
          break
        continue
      var j = i + 2
      while j < n and src[j] notin space + {'/', '>'}:
        inc j
      let name = src[i + 2 ..< j].toLowerAscii()
      var attrs: seq[(string, string)] = @[]
      var selfClosing = false
      let why = readTagRest(src, j, attrs, selfClosing)
      if why.len > 0:
        r.malformed("</" & name & ">: " & why & ": it would swallow the " &
          "markup after the payload")
        break
      i = j
      var k = stack.high
      var found = -1
      while k >= 1 and not stack[k].cond:
        if stack[k].tag == name:
          found = k
          break
        dec k
      if found < 0:
        if name notin voidElements:
          r.malformed("</" & name & "> closes no element this payload " &
            "opened" & (if stack[^1].cond or k >= 1:
              " inside its conditional comment" else: "") &
            ": it would close the markup around the payload")
        continue
      if found != stack.high:
        r.malformed("</" & name & "> closes over <" & stack[^1].tag &
          ">, which is still open (misnested or unclosed tags)")
      stack.setLen(found)
      continue
    # --- start tags ---
    if i + 1 < n and src[i + 1] in {'a' .. 'z', 'A' .. 'Z'}:
      flushText()
      var j = i + 1
      while j < n and src[j] notin space + {'/', '>'}:
        inc j
      let name = src[i + 1 ..< j].toLowerAscii()
      var attrs: seq[(string, string)] = @[]
      var selfClosing = false
      let why = readTagRest(src, j, attrs, selfClosing)
      if why.len > 0:
        r.malformed("<" & name & ">: " & why & ": it would swallow the " &
          "markup after the payload")
        break
      i = j
      if name in ["svg", "math"]:
        r.malformed("<" & name & ">: inline " & (if name == "svg": "SVG"
          else: "MathML") & " cannot be checked (a parser reads parts of " &
          "it as HTML, by rules this reader does not follow), and mail " &
          "clients largely do not render it; use an image instead")
      if name == "noscript":
        r.malformed("<noscript>: its structure cannot be checked (a " &
          "parser reads its content as text with scripting on and as " &
          "markup with it off), and scripts never run in email, so it has " &
          "no use there; leave it out")
      if name == "li" and ctx.inListItem and not inList():
        r.malformed("<li> in a list item, outside a list this payload " &
          "opens: an HTML parser closes the list item around the payload " &
          "first (open a <ul> or <ol> in the payload around it)")
      let colon = name.find(':')
      let vml = colon > 0 and name[0 ..< colon] in ["v", "o", "w"]
      if name == "plaintext":
        r.malformed("<plaintext> makes the rest of the message plain " &
          "text")
        break
      if name in tableParts and not inTable():
        r.malformed("<" & name & "> outside a table this payload " &
          "opens: an HTML parser reads it against the table the payload " &
          "sits in and closes the cell around it")
      if ctx.phrasing and name in closesParagraph:
        r.malformed("<" & name & "> in a text element: an HTML parser " &
          "closes the paragraph or heading around the payload first")
      if name == "a" and (ctx.inLink or inLink()):
        r.malformed("a link inside a link: an HTML parser closes the " &
          "outer one first")
      # What clients strip (written all the same).
      if name in rawUnsupportedElements:
        r.unsupported("<" & name & ">: mail clients strip it (written " &
          "as it is)")
      if vml and not inMso() and not ctx.inConditional:
        r.unsupported("<" & name & "> outside an mso conditional: VML is " &
          "Word's; other clients show none of it")
      let node = er.createElement(name)
      for (attr, value) in attrs:
        let decoded = decodeRefs(value)
        if attr.len > 2 and attr.startsWith("on"):
          r.unsupported("<" & name & "> " & attr & ": mail clients strip " &
            "event handlers (they never run)")
        if attr in ["href", "src", "action", "formaction", "background"]:
          let scheme = urlScheme(decoded)
          if scheme in ["javascript", "vbscript"]:
            r.unsupported("<" & name & "> " & attr & " is a " & scheme &
              ": URL: mail clients remove it (the link does nothing)")
        if attr == "style":
          parseStyle(decoded, node)
        else:
          node.attrs[attr] = decoded
      er.appendChild(stack[^1].node, node)
      if name in rawTextElements:
        # Text, not markup, up to the end tag, whatever `/>` says.
        let lower = src.toLowerAscii()
        var p = i
        var close = -1
        while true:
          let at = lower.find("</" & name, p)
          if at < 0:
            break
          let after = at + 2 + name.len
          if after >= n or src[after] in space + {'/', '>'}:
            close = at
            break
          p = at + 1
        if close < 0:
          r.malformed("<" & name & "> is never closed" & (if selfClosing:
            " (HTML ignores the '/' of <" & name & "/>)" else: "") &
            ": its text would run to the end of the message")
          break
        if name in ["script", "style"] and "<!--" in src[i ..< close]:
          r.malformed("'<!--' inside <" & name & ">: in a script it can " &
            "keep a parser reading script text past </script>, to the end " &
            "of the message")
        if close > i and name in ["textarea", "title"]:
          er.appendChild(node, er.createTextNode(decodeRefs(src[i ..< close])))
        var q = close + 2 + name.len
        var endAttrs: seq[(string, string)] = @[]
        var endSelf = false
        if readTagRest(src, q, endAttrs, endSelf).len > 0:
          r.malformed("</" & name & ">: the tag is never closed: it would " &
            "swallow the markup after the payload")
          break
        i = q
        continue
      if name in voidElements or (selfClosing and vml):
        continue
      stack.add(Frame(node: node, tag: name, selfClosed: selfClosing))
      continue
    # A `<` that starts nothing is text.
    text.add('<')
    inc i
  flushText()
  for k in countdown(stack.high, 1):
    if stack[k].cond:
      r.malformed("a conditional comment is not closed in this payload: " &
        "it would hide the rest of the message", @["R-RAW-02", "R-OL-01"])
    else:
      r.malformed("<" & stack[k].tag & "> is never closed in this payload" &
        (if stack[k].selfClosed: " (HTML ignores the '/' of <" &
          stack[k].tag & "/>)" else: "") &
        ": it would take in the markup that follows it")
  # Comment delimiters inside a conditional: comments do not nest.
  if ctx.inConditional:
    regions = @[(0, n)]
  for (a, b) in regions:
    let lower = src[a ..< b].toLowerAscii()
    for pat in ["<!--", "-->", "--!>", "<!["]:
      if pat in lower:
        r.malformed("'" & pat & "' " & (if ctx.inConditional:
          "in a payload inside a mailIf (or other content the library " &
          "may put in a conditional comment)" else:
          "inside a conditional comment") & ": comments do not nest, so " &
          "a comment, a conditional or a stray comment delimiter, even in " &
          "an attribute value, would end the conditional early and show " &
          "its content to every client", @["R-RAW-02", "R-OL-01"])
  for c in root.children:
    c.parent = nil
    r.nodes.add(c)
  r

proc rawContextOf*(node: EmailNode): RawContext =
  ## Where a `raw` node (or a `mailRaw`) sits in the authoring tree: in
  ## a `mailIf`, or a `mailTable` or `mailButton` (whose content the
  ## library may copy into Word's conditional), it is in a conditional;
  ## in a text element it is in phrasing content; in a link (or a
  ## button or navigation link) it is in a link; in an `li` it is in a
  ## list item; directly in table
  ## structure, a list, a `mailSocial` or a `mailNavbar` it is refused.
  ## `mailIf`, `textOnly`, `htmlOnly` and `mailRaw` itself are
  ## transparent.
  var p = if node == nil: nil else: node.parent
  var nearest = ""
  while p != nil:
    if p.kind == enElement:
      let t = p.tag
      if t in ["mailIf", "mailTable", "mailButton"]:
        result.inConditional = true
      if t in ["a", "mailButton", "mailNavLink", "mailSocialItem"]:
        result.inLink = true
      if t.toLowerAscii() == "li":
        result.inListItem = true
      if nearest.len == 0 and t notin ["mailIf", "textOnly", "htmlOnly",
          "mailRaw"]:
        nearest = t
    elif p.kind in {enMsoIf, enNotMso}:
      result.inConditional = true
    p = p.parent
  let t = nearest.toLowerAscii()
  if nearest in ["mailTable", "mailSocial", "mailNavbar"] or
      t in ["table", "thead", "tbody", "tfoot", "tr", "ul", "ol"]:
    result.refused = "mailRaw directly inside <" & nearest & ">: raw " &
      "markup there would sit between rows or items, where an HTML " &
      "parser moves it out (put it in a cell or an item)"
  elif nearest in ["mailButton", "mailNavLink", "mailSocialItem"] or
      t in ["p", "h1", "h2", "h3", "h4", "h5", "h6", "span", "strong", "em",
      "b", "i", "u", "s", "small", "sup", "sub", "code", "pre", "a"]:
    result.phrasing = true
