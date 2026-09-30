## isonim_email/passes/validate.nim — P1: validate.
##
## The authoring-tree gate: exactly one `mailDocument` with `lang` and
## `title`, at least one `h1` (R-A11Y-03), `alt` on every image
## (R-A11Y-04: `alt=""` only when `decorative` is true), valid UTF-8 in
## every text node, raw nodes only inside `mailRaw`, no sectioning
## elements (R-A11Y-10), and no reactive residue. Pure collection:
## the tree is never mutated, and every finding carries the offending
## node's origin.
##
## Raw placement is checked here rather than statically: `raw` is not an
## element, so the static vocabulary never sees it, and a raw node built
## by one proc may be appended inside `mailRaw` by another. Sectioning
## elements are rejected at compile time in `ui(r)` templates; the check
## here catches trees built by hand. Other nesting and vocabulary rules
## belong to the static vocabulary check, contrast and sizes to P10.

import std/[strutils, tables, unicode]
import ../diagnostics
import ../renderer
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

export diagnostics

proc isMailDocument(node: EmailNode): bool =
  node != nil and node.kind == enElement and node.tag == "mailDocument"

proc isImage(node: EmailNode): bool =
  node.kind == enElement and node.tag in ["mailImage", "img"]

proc isDecorative(node: EmailNode): bool =
  ## The `decorative` bool attr, stored as its Nim spelling (`"true"`).
  node.attrs.getOrDefault("decorative", "").toLowerAscii() == "true"

const sectioningTags = ["nav", "main", "article", "section", "header",
  "footer", "aside", "details", "summary"]
  ## R-A11Y-10: never emitted; clients rewrite or strip them.

proc isH1(node: EmailNode): bool =
  node.kind == enElement and node.tag.toLowerAscii() == "h1"

proc insideMailRaw(node: EmailNode): bool =
  ## True when any ancestor of `node` is a `mailRaw` element.
  var p = node.parent
  while p != nil:
    if p.kind == enElement and p.tag == "mailRaw":
      return true
    p = p.parent
  false

proc nearestOrigin(node: EmailNode): SourceSpan =
  ## `node`'s origin, else the closest ancestor's that has one.
  var n = node
  while n != nil:
    if n.origin.file.len > 0:
      return n.origin
    n = n.parent
  SourceSpan()

proc validate*(root: EmailNode): seq[EmailDiagnostic] =
  ## P1 over the authoring tree. Collects every finding; an empty
  ## result means the tree is structurally valid.
  if root == nil:
    return @[EmailDiagnostic(
      severity: sevError, code: codeStructNoDocument,
      message: "expected exactly one mailDocument, found no tree",
      origin: SourceSpan(), rules: @[],
    )]
  var docs: seq[EmailNode] = @[]
  var hasH1 = false
  var stack: seq[EmailNode] = @[root]
  while stack.len > 0:
    let node = stack.pop()
    if node == nil:
      continue
    if isMailDocument(node):
      docs.add(node)
    if isH1(node):
      hasH1 = true
    if isImage(node):
      if "alt" notin node.attrs:
        result.add(EmailDiagnostic(
          severity: sevError, code: codeA11yAltMissing,
          message: "<" & node.tag & "> without alt (R-IMG-04: alt is " &
            "required; alt=\"\" only with decorative = true)",
          origin: node.origin, rules: @["R-A11Y-04"],
        ))
      elif node.attrs["alt"].len == 0 and not isDecorative(node):
        result.add(EmailDiagnostic(
          severity: sevError, code: codeA11yAltMissing,
          message: "<" & node.tag & "> with empty alt and no " &
            "decorative = true (R-IMG-04: alt=\"\" only when decorative)",
          origin: node.origin, rules: @["R-A11Y-04"],
        ))
    if node.kind == enElement and node.tag.toLowerAscii() in sectioningTags:
      result.add(EmailDiagnostic(
        severity: sevError, code: codeA11ySectioning,
        message: "<" & node.tag & "> is never emitted (email clients " &
          "rewrite or strip sectioning elements): use layout primitives " &
          "and content patterns, which add landmark roles themselves",
        origin: node.origin, rules: @["R-A11Y-10"],
      ))
    if node.kind == enRaw and not insideMailRaw(node):
      let within =
        if node.parent != nil and node.parent.kind == enElement:
          " (inside <" & node.parent.tag & ">)"
        else: ""
      result.add(EmailDiagnostic(
        severity: sevError, code: codeStructRawOutside,
        message: "raw HTML outside mailRaw" & within &
          ": wrap it in mailRaw, the audited escape hatch",
        origin: nearestOrigin(node), rules: @[],
      ))
    if node.kind == enText and validateUtf8(node.text) != -1:
      result.add(EmailDiagnostic(
        severity: sevError, code: codeStructInvalidUtf8,
        message: "text node is not valid UTF-8",
        origin: node.origin, rules: @[],
      ))
    for i in countdown(node.children.high, 0):
      stack.add(node.children[i])
  if docs.len != 1:
    result.add(EmailDiagnostic(
      severity: sevError, code: codeStructNoDocument,
      message: "expected exactly one mailDocument, found " & $docs.len,
      origin: root.origin, rules: @[],
    ))
  else:
    let doc = docs[0]
    if doc.attrs.getOrDefault("lang", "").len == 0:
      result.add(EmailDiagnostic(
        severity: sevError, code: codeA11yLangMissing,
        message: "mailDocument without lang (R-DOC-02)",
        origin: doc.origin, rules: @["R-DOC-02"],
      ))
    if doc.attrs.getOrDefault("title", "").len == 0:
      result.add(EmailDiagnostic(
        severity: sevError, code: codeA11yTitleMissing,
        message: "mailDocument without title (R-DOC-10)",
        origin: doc.origin, rules: @["R-DOC-10"],
      ))
  if not hasH1:
    result.add(EmailDiagnostic(
      severity: sevError, code: codeA11yNoH1,
      message: "no h1 in the tree (R-A11Y-03: at least one h1)",
      origin: root.origin, rules: @["R-A11Y-03"],
    ))
  try:
    assertNoReactiveResidue(root)
  except EmailRenderError as e:
    result.add(toDiagnostic(e.msg, origin = root.origin))
