## isonim_email/serialize.nim — deterministic HTML serialiser.
##
## Rules implemented here: HTML5 doctype, insertion-ordered attributes
## and styles, email `escapeAttr` variant (also escaping `'` and `<`),
## UTF-8 passthrough (no entity encoding of non-ASCII), no whitespace
## between inline-block siblings (R-LAY-05), verbatim balanced conditional
## comments (R-OL-01), and optional minification that never touches
## conditionals or VML.

import std/[strutils, tables]
import isonim/ssr/escape
import ./ir

export ir

const emailVoidElements = [
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
  "meta", "param", "source", "track", "wbr",
]

proc isVoidTag(tag: string): bool =
  tag.toLowerAscii() in emailVoidElements

proc escapeEmailAttr*(s: string): string =
  ## Email attribute escaping: the `escapeAttr` behaviour (`"`
  ## and `&`) plus `'` and `<`, which the Word engine and webmail sanitisers
  ## mistreat inside attribute values. Non-ASCII passes through as UTF-8.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '"': result.add "&quot;"
    of '&': result.add "&amp;"
    of '\'': result.add "&#x27;"
    of '<': result.add "&lt;"
    else: result.add c

proc isWhitespaceOnly(s: string): bool =
  for c in s:
    if c notin {' ', '\t', '\n', '\r', '\f', '\v'}:
      return false
  true

proc writeOpenTag(res: var string; tag: string; node: EmailNode) =
  res.add "<"
  res.add tag
  for k, v in node.attrs.pairs:
    res.add " "
    res.add k
    res.add "=\""
    res.add escapeEmailAttr(v)
    res.add "\""
  if node.styles.len > 0:
    res.add " style=\""
    for k, v in node.styles.pairs:
      res.add k
      res.add ":"
      res.add escapeEmailAttr(v)
      res.add ";"
    res.add "\""

proc serializeNode(res: var string; node: EmailNode; minify: bool;
                   preDepth: int) =
  case node.kind
  of enText:
    # Whitespace-only text between elements is dropped in minify mode,
    # except inside `pre`/`textarea` where it is content.
    if minify and preDepth == 0 and isWhitespaceOnly(node.text):
      discard
    else:
      res.add escapeHtml(node.text)
  of enRaw:
    res.add node.text
  of enMsoIf:
    # Verbatim (R-OL-01): emitted exactly, in both plain and minify mode.
    # Children serialise with minify off: Outlook reads conditional
    # content raw, so even whitespace-only text inside is significant.
    res.add "<!--[if "
    res.add node.cond
    res.add "]>"
    for c in node.children:
      serializeNode(res, c, false, preDepth)
    res.add "<![endif]-->"
  of enNotMso:
    # Verbatim like MsoIf: minify never reaches inside.
    res.add "<!--[if !mso]><!-->"
    for c in node.children:
      serializeNode(res, c, false, preDepth)
    res.add "<!--<![endif]-->"
  of enVml:
    # Verbatim like conditionals: minify never touches VML.
    writeOpenTag(res, node.tag, node)
    if node.children.len == 0:
      # Self-closed with a space (` />`), exactly as the catalogue §6 shows.
      res.add " />"
    else:
      res.add ">"
      for c in node.children:
        serializeNode(res, c, minify, preDepth)
      res.add "</"
      res.add node.tag
      res.add ">"
  of enHeadStyle:
    res.add "<style>"
    res.add node.text
    res.add "</style>"
  of enElement:
    let childPre =
      if node.tag.toLowerAscii() in ["pre", "textarea"]: preDepth + 1
      else: preDepth
    writeOpenTag(res, node.tag, node)
    if isVoidTag(node.tag):
      # Void elements carry no children; anything attached is a loud
      # error citing the element's template span, never a silent drop.
      # Serialised open, HTML5 style: `<meta …>`.
      if node.children.len > 0:
        raise newException(EmailRenderError,
          "void element <" & node.tag & "> cannot have children at " &
          $node.origin &
          " (remove the children or use a non-void element)")
      res.add ">"
    else:
      res.add ">"
      # No inter-element whitespace is ever emitted (R-LAY-05): column
      # siblings — and the conditionals between them — stay contiguous.
      for c in node.children:
        serializeNode(res, c, minify, childPre)
      res.add "</"
      res.add node.tag
      res.add ">"

proc countOccurrences(haystack, needle: string): int =
  var i = 0
  while true:
    let j = haystack.find(needle, i)
    if j < 0:
      break
    inc result
    i = j + needle.len

proc assertConditionalsBalanced(html: string) =
  ## The serialiser asserts balanced conditionals: every
  ## `<!--[if` opener needs its `<![endif]-->`. Both MsoIf and NotMso
  ## closers contain `<![endif]-->`; a stray closer smuggled in through a
  ## raw node trips this.
  let opens = countOccurrences(html, "<!--[if")
  let closes = countOccurrences(html, "<![endif]-->")
  if opens != closes:
    raise newException(EmailRenderError,
      "unbalanced conditional comments: " & $opens & " opener(s), " &
      $closes & " closer(s)")

proc serialize*(node: EmailNode; minify = false): string =
  ## Serialises `node` deterministically: attribute and style order follow
  ## tree insertion order, so the same tree always yields the same bytes.
  ## Runs `validateIr` first (VML-inside-MsoIf, closed condition set) and
  ## asserts balanced conditionals on the output.
  if node == nil:
    raise newException(EmailRenderError, "cannot serialize a nil node")
  validateIr(node)
  serializeNode(result, node, minify, 0)
  assertConditionalsBalanced(result)

proc serializeDocument*(node: EmailNode; minify = false): string =
  ## `serialize` plus the exact `<!doctype html>` prefix (R-DOC-01).
  "<!doctype html>" & serialize(node, minify)
