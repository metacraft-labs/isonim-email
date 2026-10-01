## isonim_email/passes/a11y.nim — P7: accessibility backfills.
##
## Backfills roles and aria attributes the authoring tree leaves implicit,
## and warns on skipped heading levels (R-TXT-10):
##
## - `role="presentation"` on every `table` lacking `role`, and
##   `role="table"` on every `mailTable` lacking it (R-A11Y-02); a
##   data table without a `caption` child or a non-empty `caption`
##   attribute is an `E-A11Y-TABLE-CAPTION` error instead;
## - `aria-hidden="true"` on the preheader padding div (R-PRE-03), on VML
##   shapes carrying decorative markers, and on empty spacer divs
##   (R-A11Y-05; its dark-swap duplicates are not handled yet, because
##   `mailImage` `dark_src` has no lowering to produce them);
## - `mailDocument` `lang`/`dir` copied onto the article wrapper div when
##   absent (R-A11Y-01).
##
## Backfills only add missing attributes, never overwrite author values,
## and never reorder children. No other checks.

import std/[strutils, tables]
import ../diagnostics
import ../renderer
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

export diagnostics

proc headingLevel(tag: string): int =
  ## 1–6 for `h1`–`h6` (any case), else 0.
  let t = tag.toLowerAscii()
  if t.len == 2 and t[0] == 'h' and t[1] in {'1' .. '6'}:
    ord(t[1]) - ord('0')
  else:
    0

proc isArticleWrapper(node: EmailNode): bool =
  node.kind == enElement and node.tag == "div" and
    node.attrs.getOrDefault("role", "") == "article"

proc isEmptySpacer(node: EmailNode): bool =
  ## A `div` with no text or element children.
  if node.kind != enElement or node.tag != "div":
    return false
  for c in node.children:
    if c.kind in {enElement, enText, enRaw}:
      return false
  true

proc isDecorativeVml(node: EmailNode): bool =
  ## A VML shape is decorative when marked `decorative = true` or when
  ## it carries an explicitly empty `alt`.
  node.attrs.getOrDefault("decorative", "").toLowerAscii() == "true" or
    ("alt" in node.attrs and node.attrs["alt"].len == 0)

proc findFirst(root: EmailNode;
               pred: proc(n: EmailNode): bool): EmailNode =
  ## First node in document order satisfying `pred` (root included).
  if root == nil:
    return nil
  if pred(root):
    return root
  for c in root.children:
    let hit = findFirst(c, pred)
    if hit != nil:
      return hit
  nil

proc preheaderPaddingDiv(root: EmailNode): EmailNode =
  ## The second preheader div: `lower/document.nim` emits `body`
  ## with two hiding-stack divs (`display:none` in their style) ahead of
  ## the article wrapper, and the padding is the second one.
  let body = findFirst(root, proc(n: EmailNode): bool =
    n.kind == enElement and n.tag == "body")
  if body == nil:
    return nil
  var hiding: seq[EmailNode] = @[]
  for c in body.children:
    if c.kind == enElement and c.tag == "div" and
        "display:none" in c.attrs.getOrDefault("style", ""):
      hiding.add(c)
  if hiding.len >= 2:
    hiding[1]
  else:
    nil

proc applyA11y*(root: EmailNode): seq[EmailDiagnostic] =
  ## P7 over the tree. Mutates in place (attribute backfills only) and
  ## collects the caption errors and heading-skip warnings.
  if root == nil:
    return @[]
  var prevHeading = 0
  var stack: seq[EmailNode] = @[root]
  while stack.len > 0:
    let node = stack.pop()
    if node == nil:
      continue
    if node.kind == enElement and node.tag == "table" and
        "role" notin node.attrs:
      node.attrs["role"] = "presentation"
    elif node.kind == enElement and node.tag == "mailTable":
      if "role" notin node.attrs:
        node.attrs["role"] = "table"
      var hasCaption = node.attrs.getOrDefault("caption", "").len > 0
      if not hasCaption:
        for c in node.children:
          if c.kind == enElement and c.tag == "caption":
            hasCaption = true
            break
      if not hasCaption:
        result.add(EmailDiagnostic(
          severity: sevError, code: codeA11yTableCaption,
          message: "mailTable without a caption child or caption " &
            "attribute (R-A11Y-02: data tables carry role=\"table\" " &
            "plus a caption)",
          origin: node.origin, rules: @["R-A11Y-02"],
        ))
    if node.kind == enVml and isDecorativeVml(node) and
        "aria-hidden" notin node.attrs:
      node.attrs["aria-hidden"] = "true"
    if isEmptySpacer(node) and "aria-hidden" notin node.attrs:
      node.attrs["aria-hidden"] = "true"
    let level = if node.kind == enElement: headingLevel(node.tag) else: 0
    if level > 0:
      if level > prevHeading + 1:
        let prevName = if prevHeading == 0: "nothing" else: "h" & $prevHeading
        result.add(EmailDiagnostic(
          severity: sevWarning, code: codeA11yHeadingSkip,
          message: "heading level skipped: " & prevName & " followed by h" &
            $level & " (R-TXT-10)",
          origin: node.origin, rules: @["R-TXT-10"],
        ))
      prevHeading = level
    for i in countdown(node.children.high, 0):
      stack.add(node.children[i])
  let pad = preheaderPaddingDiv(root)
  if pad != nil and "aria-hidden" notin pad.attrs:
    pad.attrs["aria-hidden"] = "true"
  let doc = findFirst(root, proc(n: EmailNode): bool =
    n.kind == enElement and n.tag == "mailDocument")
  let wrap = findFirst(root, proc(n: EmailNode): bool = isArticleWrapper(n))
  if doc != nil and wrap != nil:
    for key in ["lang", "dir"]:
      if key in doc.attrs and key notin wrap.attrs:
        wrap.attrs[key] = doc.attrs[key]
