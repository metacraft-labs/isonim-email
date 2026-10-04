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
## here catches trees built by hand. A row's `reverse_on_mobile` is
## checked here too (R-LAY-11): only a non-text column may move, and
## never in a right-to-left row. Other nesting and vocabulary rules
## belong to the static vocabulary check, contrast and sizes to P10.
## A `mailButton`, a `mailNavLink` and a `mailSocialItem` must have a
## real destination (R-BTN-07), and so must every `a` and every linked
## image (R-TXT-13). A `mailIf` names exactly one of `mso`
## (a boolean) and `family` (from the families with a selector; R-OL-02,
## R-RAW-05, R-RAW-06), and a `mailTable` holds exactly one `table`
## (R-TBL-18). The content patterns' own checks are here too: a
## `mailNavLinks` of more than five links (`W-PATTERN-NAV-LONG`), a
## `mailStepper` of more than five steps (`E-PATTERN-STEPPER-LONG`), and
## a mandatory text alternative that is missing (`E-PATTERN-MISSING-TEXT`):
## a `mailCountdown`'s deadline text, a `mailStepper`'s status (its
## `current` step and that step's label) and a `mailEvent`'s date line.
##
## `mailRaw` (R-RAW-01…04): every use is reported once as `I-RAW-USED`,
## and each of its payloads is read by `raw.nim`: markup that would
## break the message's structure is `E-RAW-MALFORMED`, markup mail
## clients strip `W-RAW-UNSUPPORTED` (written all the same), and a
## payload with no error gets this pass's own checks on what it holds
## (alt text, sectioning elements), as authored markup does.

import std/[strutils, tables, unicode]
import ../diagnostics
import ../renderer
import ../raw
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

proc holdsText(node: EmailNode): bool =
  ## True when `node` or a descendant holds non-blank text (an image's
  ## alt text is not text on the page).
  if node.kind == enText:
    return node.text.strip().len > 0
  for c in node.children:
    if holdsText(c):
      return true
  false

proc rowRtl(node: EmailNode): bool =
  ## True when the row runs right to left before any reversal: its own
  ## `direction`, else the nearest section's, else the document's.
  var n = node
  while n != nil:
    if n.kind == enElement:
      let own = n.attrs.getOrDefault("direction",
        n.styles.getOrDefault("direction", "")).toLowerAscii()
      if own in ["ltr", "rtl"]:
        return own == "rtl"
      if n.tag == "mailDocument":
        return n.attrs.getOrDefault("dir", "").toLowerAscii() == "rtl"
    n = n.parent
  false

proc checkReversal(node: EmailNode; diags: var seq[EmailDiagnostic]) =
  ## R-LAY-11: `reverse_on_mobile` flips the desktop order of a row whose
  ## moved columns carry no text (an image beside text), and only in a
  ## left-to-right row; a `cells` row never stacks, so it has no mobile
  ## order to keep.
  if node.attrs.getOrDefault("reverse_on_mobile", "").toLowerAscii() !=
      "true":
    return
  let switchBelow = node.attrs.getOrDefault("switch_below", "").strip()
  if (node.tag == "mailColumns" and
      node.attrs.getOrDefault("strategy", "") == "cells") or
      (node.tag == "mailSidebar" and switchBelow in ["", "0", "0px"]):
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "reverse_on_mobile on a " & (if node.tag == "mailSidebar":
        "mailSidebar that never switches" else: "cells row") &
        ", which never stacks: order its " & (if node.tag == "mailSidebar":
        "sides" else: "columns") & " as they should show (R-LAY-11)",
      origin: node.origin, rules: @["R-LAY-11"]))
    return
  var textual = 0
  for c in node.children:
    if c.kind == enElement and (node.tag == "mailSidebar" or
        c.tag in ["mailColumn", "mailGroup"]) and holdsText(c):
      inc textual
  if textual > 1:
    diags.add(EmailDiagnostic(severity: sevError,
      code: codeLayoutReverseText,
      message: "reverse_on_mobile on a row where " & $textual &
        " columns hold text: reversal moves only a non-text column " &
        "(an image beside text), so the reading order and the visual " &
        "order never disagree for text (R-LAY-11)",
      origin: node.origin, rules: @["R-LAY-11"]))
  if rowRtl(node):
    diags.add(EmailDiagnostic(severity: sevError,
      code: codeLayoutReverseText,
      message: "reverse_on_mobile in a right-to-left row: the reversal " &
        "is itself a right-to-left row and cannot be expressed in one " &
        "(R-LAY-11)", origin: node.origin, rules: @["R-LAY-11"]))

proc checkGrid(node: EmailNode; diags: var seq[EmailDiagnostic]) =
  ## A grid lays out 2, 3 or 4 items per row, and one or two per row on
  ## a phone; three with two on a phone leaves an orphan item every
  ## second row (layout-patterns.md §3.4).
  let cols = node.attrs.getOrDefault("columns", "2").strip()
  let mobile = node.attrs.getOrDefault("mobile_columns", "1").strip()
  if cols notin ["2", "3", "4"]:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailGrid columns '" & cols & "' is not 2, 3 or 4",
      origin: node.origin))
  if mobile notin ["1", "2"]:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailGrid mobile_columns '" & mobile & "' is not 1 or 2",
      origin: node.origin))
  if cols == "3" and mobile == "2":
    diags.add(EmailDiagnostic(severity: sevError,
      code: codePatternGridOrphan,
      message: "mailGrid with 3 columns and 2 on a phone leaves an " &
        "orphan item in every second row: use 2 or 4 columns, or one " &
        "per row on a phone (layout-patterns.md §3.4)",
      origin: node.origin))

proc checkBandNesting(node: EmailNode; acc: var seq[EmailDiagnostic]) =
  ## A band sits in the document, a section also in a wrapper (R-LAY-16,
  ## R-LAY-17): a section inside a section, or a wrapper inside any
  ## band, is `E-STRUCT-NESTING`. The template check stops it when the
  ## author writes it; a pattern whose expansion is a band, placed in a
  ## band, reaches here only (the pattern element hides the nesting).
  var a = node.parent
  var through = ""
  while a != nil:
    if a.kind == enElement:
      if a.tag in ["mailSection", "mailHero"] or
          (a.tag == "mailWrapper" and node.tag == "mailWrapper"):
        acc.add(EmailDiagnostic(severity: sevError,
          code: codeStructNesting,
          message: "<" & node.tag & "> inside <" & a.tag & ">" &
            (if through.len > 0: " (through the pattern <" & through &
              ">, whose expansion is a band)" else: "") &
            ": bands sit in the document, sections also in a wrapper",
          origin: node.origin, rules: @["R-LAY-16"]))
        return
      if a.tag == "mailDocument":
        return
      if a.expanded and through.len == 0:
        through = a.tag
    a = a.parent

proc countTag(node: EmailNode; tag: string): int =
  for c in node.children:
    if c.kind == enElement:
      if c.tag == tag:
        inc result
      result += countTag(c, tag)

const navLinksMax = 5
  ## Links in a `mailNavLinks` before `W-PATTERN-NAV-LONG`.
const stepperMax = 5
  ## Steps in a `mailStepper` before `E-PATTERN-STEPPER-LONG`.

proc stepTexts(node: EmailNode; acc: var seq[string]) =
  ## The labels of the `mailStep`s under `node`, in order (the steps
  ## stay in a stepper's expansion around their labels).
  for c in node.children:
    if c.kind != enElement:
      continue
    if c.tag == "mailStep":
      var t = ""
      proc collect(x: EmailNode) =
        if x.kind == enText:
          t.add(x.text)
        for y in x.children:
          collect(y)
      collect(c)
      acc.add(t.strip())
    else:
      stepTexts(c, acc)

proc checkContentPatterns(node: EmailNode; diags: var seq[EmailDiagnostic]) =
  ## The content patterns' own diagnostics (layout-patterns.md §4): a
  ## navigation of more than five links (`W-PATTERN-NAV-LONG`), a stepper
  ## of more than five steps (`E-PATTERN-STEPPER-LONG`), and a countdown
  ## without its deadline in text, a stepper whose status cannot be
  ## written or an event without its date line (`E-PATTERN-MISSING-TEXT`).
  ## Read from the pattern element, whose props stay on it, and from
  ## its expansion (the links are `mailNavLink`s there).
  case node.tag
  of "mailNavLinks":
    var links = countTag(node, "mailNavLink")
    if not node.expanded:
      for c in node.children:
        if c.kind == enElement and c.tag == "a":
          inc links
    if links > navLinksMax:
      diags.add(EmailDiagnostic(severity: sevWarning,
        code: codePatternNavLong,
        message: "mailNavLinks with " & $links & " links: more than " &
          $navLinksMax & " wrap into a block a reader skims past, and no " &
          "collapsing menu is offered (most clients drop the media " &
          "queries one needs): keep the five that matter, and put the " &
          "rest in the footer (layout-patterns.md §4.1)",
        origin: node.origin))
  of "mailStepper":
    var labels: seq[string] = @[]
    stepTexts(node, labels)
    if labels.len > stepperMax:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codePatternStepperLong,
        message: "mailStepper with " & $labels.len & " steps: a stepper " &
          "holds at most " & $stepperMax & " (more do not fit a phone's " &
          "width in one row); use mailTimeline, which lists any number " &
          "of events (layout-patterns.md §4.4)",
        origin: node.origin))
    let raw = node.attrs.getOrDefault("current",
      node.styles.getOrDefault("current", "")).strip()
    var current = 0
    try:
      current = parseInt(raw)
    except ValueError:
      discard
    if current < 1 or current > labels.len or
        labels[current - 1].len == 0:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codePatternMissingText,
        message: "mailStepper " & (if raw.len == 0: "without current" else:
          "current = " & raw & (if current >= 1 and
            current <= labels.len: ", a step without a label" else:
            ", which names none of its " & $labels.len & " steps")) &
          ": the status line (\"Current step: Shipped (2 of 4)\", " &
          "visually hidden, and the text part's \"Step 2 of 4: …\") is " &
          "the stepper's meaning for a screen reader and a plain-text " &
          "reader, and cannot be written; set current to the step the " &
          "order is at (layout-patterns.md §4.4)",
        origin: node.origin))
  of "mailEvent":
    let dateText = node.attrs.getOrDefault("date_text",
      node.styles.getOrDefault("date_text", "")).strip()
    if dateText.len == 0:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codePatternMissingText,
        message: "mailEvent without date_text: the date tile is " &
          "decoration, hidden from screen readers and the text part, so " &
          "the full date and time must be written out (\"Tuesday, 14 " &
          "October 2026, 18:00–20:00 CEST\") (layout-patterns.md §4.4)",
        origin: node.origin))
  of "mailCountdown":
    let deadline = node.attrs.getOrDefault("deadline_text",
      node.styles.getOrDefault("deadline_text", "")).strip()
    if deadline.len == 0:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codePatternMissingText,
        message: "mailCountdown without deadline_text: the image's " &
          "count is stale when the message is reopened, Word shows its " &
          "first frame only (R-OL-13), and with images off nothing says " &
          "when the offer ends; give the deadline in absolute terms " &
          "(\"Offer ends 30 September 2026, 23:59 UTC\"), which is its " &
          "alt text and its plain-text line (layout-patterns.md §4.2)",
        origin: node.origin, rules: @["R-OL-13"]))
  else:
    discard

proc checkHref(node: EmailNode; diags: var seq[EmailDiagnostic]) =
  ## R-BTN-07 and R-TXT-13: a button, a navigation link, a social item,
  ## a plain link and a linked image go somewhere a mail client can
  ## open: an absolute https URL, or a `mailto:` or `tel:` one; never
  ## nothing or `#`. A plain `a` with no `href` at all is the empty
  ## case. This is a correctness check (a relative URL has no page to
  ## resolve against in a mail client), not a filter: markup inside
  ## `mailRaw` is read by `raw.nim` and keeps its own rules.
  let isLink = node.tag in ["a", "mailImage"]
  let rule = if isLink: "R-TXT-13" else: "R-BTN-07"
  let what = if node.tag == "a": "link" else: node.tag
  let href = node.attrs.getOrDefault("href", "").strip()
  if href.len == 0 or href.startsWith("#"):
    diags.add(EmailDiagnostic(severity: sevError, code: codeUrlEmpty,
      message: what & " without a destination (href '" & href &
        "'): it must link to an absolute https URL, mailto: or " &
        "tel: (" & rule & ")", origin: node.origin, rules: @[rule]))
    return
  let lower = href.toLowerAscii()
  let ok = (lower.startsWith("https://") and href.len > "https://".len and
    href["https://".len] notin {'/', '?', '#'}) or
    (lower.startsWith("mailto:") and href.len > "mailto:".len) or
    (lower.startsWith("tel:") and href.len > "tel:".len)
  if not ok or href.contains({' ', '\t', '\r', '\n', '"', '<', '>'}):
    diags.add(EmailDiagnostic(severity: sevError, code: codeUrlScheme,
      message: what & " href '" & href & "' is not an absolute " &
        "https URL, mailto: or tel: (" & rule & ")", origin: node.origin,
      rules: @[rule]))

const buttonHrefTags = ["mailButton", "mailNavLink", "mailSocialItem"]
  ## The elements whose `href` R-BTN-07 checks on the element itself.

proc hrefCheckedAbove(node: EmailNode): bool =
  ## True when an ancestor is a button-style element (R-BTN-07) holding
  ## the same `href` (compared stripped, as the expansion writes it):
  ## the link is that element's own pattern expansion
  ## (a `mailNavLink`'s `a`, a `mailSocialItem`'s linked image), whose
  ## destination was checked, and reported, on the element.
  let href = node.attrs.getOrDefault("href", "").strip()
  var p = node.parent
  while p != nil:
    if p.kind == enElement and p.tag in buttonHrefTags and
        p.attrs.getOrDefault("href", "").strip() == href:
      return true
    p = p.parent
  false

const ifFamilies* = ["outlookWord", "thunderbird"]
  ## The families `mailIf(family = …)` can target: Word through its
  ## conditional (R-RAW-05), Thunderbird through `.moz-text-html`
  ## (R-RAW-06). Any other needs a capture that backs its selector.

proc ifFamiliesOf*(node: EmailNode): tuple[families: seq[string];
    bad: seq[string]] =
  ## The families a `mailIf(family = …)` names, from its comma- or
  ## space-separated list, matched without case; `bad` holds the
  ## names outside `ifFamilies`.
  for part in node.attrs.getOrDefault("family", "").split({',', ' '}):
    let p = part.strip()
    if p.len == 0:
      continue
    var hit = ""
    for f in ifFamilies:
      if f.toLowerAscii() == p.toLowerAscii():
        hit = f
    if hit.len == 0:
      result.bad.add(p)
    elif hit notin result.families:
      result.families.add(hit)

proc checkIf(node: EmailNode; diags: var seq[EmailDiagnostic]) =
  ## R-OL-02, R-RAW-05, R-RAW-06: `mailIf` is the authors' way to a
  ## conditional, so its values are checked here, where the template's
  ## location is known: exactly one of `mso` (true or false) and
  ## `family` (from `ifFamilies`).
  let hasMso = "mso" in node.attrs
  let hasFamily = "family" in node.attrs
  template bad(text: string; ruleIds: seq[string]) =
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: text, origin: node.origin, rules: ruleIds))
  if hasMso == hasFamily:
    bad("mailIf needs exactly one of mso (true or false) and family " &
      "(R-RAW-05)", @["R-RAW-05"])
    return
  if hasMso:
    let v = node.attrs["mso"].strip().toLowerAscii()
    if v notin ["true", "false"]:
      bad("mailIf mso = '" & node.attrs["mso"] & "': the only conditions " &
        "an author can ask for are mso = true and mso = false; version " &
        "conditions are not offered (R-OL-02)", @["R-OL-02"])
    return
  let (families, unknown) = ifFamiliesOf(node)
  if unknown.len > 0 or families.len == 0:
    bad("mailIf family '" & node.attrs["family"] & "': the families " &
      "with a selector are " & ifFamilies.join(" and ") &
      (if unknown.len > 0: " (not " & unknown.join(", ") & ")" else: "") &
      " (R-RAW-06)", @["R-RAW-06"])

proc checkTable(node: EmailNode; diags: var seq[EmailDiagnostic]) =
  ## R-TBL-18: a data table is one `table`; anything else beside it
  ## (another table, loose content) has nowhere to go.
  var tables, other = 0
  for c in node.children:
    if c.kind == enElement and c.tag == "table":
      inc tables
    elif c.kind == enElement or c.kind == enRaw or
        (c.kind == enText and c.text.strip().len > 0):
      inc other
  if tables != 1 or other > 0:
    diags.add(EmailDiagnostic(severity: sevError, code: codeStructNesting,
      message: "mailTable holds " & $tables & " table" &
        (if tables == 1: "" else: "s") &
        (if other > 0: " and " & $other & " other node" &
          (if other == 1: "" else: "s") else: "") &
        ": a data table is exactly one table (R-TBL-18)",
      origin: node.origin, rules: @["R-TBL-18"]))

proc checkRawTree(node: EmailNode; origin: SourceSpan;
    diags: var seq[EmailDiagnostic]) =
  ## This pass's checks on what a raw payload holds (R-RAW-01): an image
  ## carries `alt` (empty for a decorative one, as HTML says; R-IMG-04),
  ## and no sectioning element appears (R-A11Y-10).
  if node == nil:
    return
  if node.kind == enElement:
    if node.tag == "img" and "alt" notin node.attrs:
      diags.add(EmailDiagnostic(severity: sevError, code: codeA11yAltMissing,
        message: "<img> without alt in mailRaw (R-IMG-04: alt is " &
          "required; alt=\"\" marks a decorative image)", origin: origin,
        rules: @["R-A11Y-04", "R-RAW-01"]))
    if node.tag in sectioningTags:
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeA11ySectioning,
        message: "<" & node.tag & "> in mailRaw is never emitted (email " &
          "clients rewrite or strip sectioning elements)", origin: origin,
        rules: @["R-A11Y-10", "R-RAW-01"]))
  for c in node.children:
    checkRawTree(c, origin, diags)

proc checkRawPayload(node: EmailNode; diags: var seq[EmailDiagnostic]) =
  ## Reads one payload inside `mailRaw` in the place it sits (R-RAW-02,
  ## R-RAW-03) and, when it has no error, checks what it holds
  ## (R-RAW-01).
  let origin = nearestOrigin(node)
  let read = readRaw(node.text, rawContextOf(node))
  for p in read.problems:
    diags.add(EmailDiagnostic(
      severity: if p.warning: sevWarning else: sevError,
      code: if p.warning: codeRawUnsupported else: codeRawMalformed,
      message: "mailRaw: " & p.message, origin: origin, rules: p.rules))
  if not read.refused:
    for n in read.nodes:
      checkRawTree(n, origin, diags)

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
    if node.kind == enElement and node.tag in ["mailSection", "mailColumns",
        "mailSidebar"]:
      checkReversal(node, result)
    if node.kind == enElement and node.tag == "mailGrid":
      checkGrid(node, result)
    if node.kind == enElement and node.tag in buttonHrefTags:
      checkHref(node, result)
    if node.kind == enElement and (node.tag == "a" or
        (node.tag == "mailImage" and "href" in node.attrs)) and
        not hrefCheckedAbove(node):
      checkHref(node, result)
    if node.kind == enElement and node.tag in ["mailNavLinks",
        "mailCountdown", "mailStepper", "mailEvent"]:
      checkContentPatterns(node, result)
    if node.kind == enElement and node.tag == "mailIf":
      checkIf(node, result)
    if node.kind == enElement and node.tag == "mailTable":
      checkTable(node, result)
    if node.kind == enElement and node.tag == "mailRaw":
      result.add(EmailDiagnostic(severity: sevInfo, code: codeRawUsed,
        message: "mailRaw used: its markup is linted but not generated " &
          "(R-RAW-04)", origin: node.origin, rules: @["R-RAW-04"]))
    if node.kind == enRaw and insideMailRaw(node):
      checkRawPayload(node, result)
    if node.kind == enElement and node.tag in ["mailSection", "mailWrapper",
        "mailHero"]:
      checkBandNesting(node, result)
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
