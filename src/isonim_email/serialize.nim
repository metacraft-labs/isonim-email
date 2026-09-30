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
import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

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

type
  SizeCategory* = enum
    ## The R-SIZE-02 contributors. Every serialised byte lands in
    ## exactly one, so the counts partition the document.
    scHeadCss = "head CSS"
      ## `<style>` elements outside Outlook conditionals, tags included.
    scInlineStyles = "inline styles"
      ## Every ` style="…"` attribute, name and quotes included.
    scUrls = "URLs"
      ## Values of `href`, `src`, `background`, `action` and `poster`,
      ## tracking parameters included (the attribute name and quotes
      ## are markup).
    scPreheaderPadding = "preheader padding"
      ## The hidden padding run after the preheader text (R-PRE-02).
    scMsoVml = "MSO/VML"
      ## Everything inside `<!--[if mso …]>…<![endif]-->` (VML, ghost
      ## tables, their styles and URLs) plus the `<!--[if !mso]>`
      ## markers.
    scMarkup = "markup and text"
      ## Everything else: the doctype, tags, other attributes, text.

  SerialSink = object
    ## Where the serialiser writes: the bytes, plus per-category byte
    ## counts attributed as each piece is written.
    res: string
    counts: array[SizeCategory, int]

const urlAttributes = ["href", "src", "background", "action", "poster"]

proc put(sink: var SerialSink; s: string; cat: SizeCategory;
         context: SizeCategory) {.inline.} =
  ## Appends `s`, attributed to `cat` — or to the context when the
  ## context is an Outlook conditional, which claims everything inside.
  sink.res.add s
  let c = if context == scMsoVml: scMsoVml else: cat
  sink.counts[c] += s.len

proc isPreheaderPadding(node: EmailNode): bool =
  ## The hidden padding div the document shell emits after the
  ## preheader: `aria-hidden` plus the `display:none` hiding stack.
  node.kind == enElement and node.tag == "div" and
    node.attrs.getOrDefault("aria-hidden", "") == "true" and
    "display:none" in node.attrs.getOrDefault("style", "") and
    "mso-hide:all" in node.attrs.getOrDefault("style", "")

proc writeOpenTag(sink: var SerialSink; tag: string; node: EmailNode;
                  context: SizeCategory) =
  sink.put("<", scMarkup, context)
  sink.put(tag, scMarkup, context)
  for k, v in node.attrs.pairs:
    if k == "style":
      sink.put(" " & k & "=\"" & escapeEmailAttr(v) & "\"",
        scInlineStyles, context)
    elif k.toLowerAscii() in urlAttributes:
      sink.put(" " & k & "=\"", scMarkup, context)
      sink.put(escapeEmailAttr(v), scUrls, context)
      sink.put("\"", scMarkup, context)
    else:
      sink.put(" " & k & "=\"" & escapeEmailAttr(v) & "\"", scMarkup,
        context)
  if node.styles.len > 0:
    var style = " style=\""
    for k, v in node.styles.pairs:
      style.add k
      style.add ":"
      style.add escapeEmailAttr(v)
      style.add ";"
    style.add "\""
    sink.put(style, scInlineStyles, context)

proc serializeNode(sink: var SerialSink; node: EmailNode; minify: bool;
                   preDepth: int; context: SizeCategory;
                   padding = false) =
  case node.kind
  of enText:
    # Whitespace-only text between elements is dropped in minify mode,
    # except inside `pre`/`textarea` where it is content.
    if minify and preDepth == 0 and isWhitespaceOnly(node.text):
      discard
    else:
      sink.put(escapeHtml(node.text), scMarkup, context)
  of enRaw:
    sink.put(node.text,
      if padding: scPreheaderPadding else: scMarkup, context)
  of enMsoIf:
    # Verbatim (R-OL-01): emitted exactly, in both plain and minify mode.
    # Children serialise with minify off: Outlook reads conditional
    # content raw, so even whitespace-only text inside is significant.
    sink.put("<!--[if " & node.cond & "]>", scMsoVml, scMsoVml)
    for c in node.children:
      serializeNode(sink, c, false, preDepth, scMsoVml)
    sink.put("<![endif]-->", scMsoVml, scMsoVml)
  of enNotMso:
    # Verbatim like MsoIf: minify never reaches inside.
    sink.put("<!--[if !mso]><!-->", scMsoVml, context)
    for c in node.children:
      serializeNode(sink, c, false, preDepth, context)
    sink.put("<!--<![endif]-->", scMsoVml, context)
  of enVml:
    # Verbatim like conditionals: minify never touches VML.
    writeOpenTag(sink, node.tag, node, scMsoVml)
    if node.children.len == 0:
      # Self-closed with a space (` />`), exactly as the catalogue §6 shows.
      sink.put(" />", scMsoVml, scMsoVml)
    else:
      sink.put(">", scMsoVml, scMsoVml)
      for c in node.children:
        serializeNode(sink, c, minify, preDepth, scMsoVml)
      sink.put("</" & node.tag & ">", scMsoVml, scMsoVml)
  of enHeadStyle:
    sink.put("<style>" & node.text & "</style>", scHeadCss, context)
  of enElement:
    let childPre =
      if node.tag.toLowerAscii() in ["pre", "textarea"]: preDepth + 1
      else: preDepth
    writeOpenTag(sink, node.tag, node, context)
    if isVoidTag(node.tag):
      # Void elements carry no children; anything attached is a loud
      # error citing the element's template span, never a silent drop.
      # Serialised open, HTML5 style: `<meta …>`.
      if node.children.len > 0:
        raise newException(EmailRenderError,
          "void element <" & node.tag & "> cannot have children at " &
          $node.origin &
          " (remove the children or use a non-void element)")
      sink.put(">", scMarkup, context)
    else:
      sink.put(">", scMarkup, context)
      # No inter-element whitespace is ever emitted (R-LAY-05): column
      # siblings — and the conditionals between them — stay contiguous.
      let pad = isPreheaderPadding(node)
      for c in node.children:
        serializeNode(sink, c, minify, childPre, context, pad)
      sink.put("</" & node.tag & ">", scMarkup, context)

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

proc serializeSink(node: EmailNode; minify: bool): SerialSink =
  if node == nil:
    raise newException(EmailRenderError, "cannot serialize a nil node")
  validateIr(node)
  serializeNode(result, node, minify, 0, scMarkup)
  assertConditionalsBalanced(result.res)

proc serialize*(node: EmailNode; minify = false): string =
  ## Serialises `node` deterministically: attribute and style order follow
  ## tree insertion order, so the same tree always yields the same bytes.
  ## Runs `validateIr` first (VML-inside-MsoIf, closed condition set) and
  ## asserts balanced conditionals on the output.
  serializeSink(node, minify).res

const doctype = "<!doctype html>"

proc serializeDocument*(node: EmailNode; minify = false): string =
  ## `serialize` plus the exact `<!doctype html>` prefix (R-DOC-01).
  doctype & serialize(node, minify)

proc serializeDocumentMeasured*(node: EmailNode; minify = false): tuple[
    html: string; breakdown: seq[(string, int)]] =
  ## `serializeDocument` plus the R-SIZE-02 contributor breakdown: the
  ## bytes each `SizeCategory` wrote, in enum order, zero entries
  ## included. The counts are taken while the bytes are written, so
  ## they sum to `html.len` exactly (the doctype is markup).
  let sink = serializeSink(node, minify)
  result.html = doctype & sink.res
  for cat in SizeCategory:
    var n = sink.counts[cat]
    if cat == scMarkup:
      n += doctype.len
    result.breakdown.add(($cat, n))
