## isonim_email/lower/document.nim — `mailDocument` lowering.
##
## Reads the `mailDocument` node (`lang`/`dir`/`title`/`preheader`/
## `background_color`) and emits the catalogue §1 skeleton exactly:
## `html` + `head` (metas, title, `OfficeDocumentSettings`, the five
## head blocks plus the conditional mso block and group fix) + `body`
## (preheader, article wrapper, wrapper table). The doctype comes from
## the serialiser (`serializeDocument`, R-DOC-01), not from here.
##
## R-DOC-13's `word-spacing:normal` is emitted per the skeleton; its
## backend-effect confirmation rides with later capture evidence.
##
## Missing attributes fall back to rendering defaults (`lang "en"` per
## the Cerberus precedent, default `dir "ltr"`, empty title and
## preheader, `#ffffff` background): P1 validates the required ones,
## but lowering itself never fails on an incomplete tree.
##
## The shell is P5-final: it is built after P5 runs. The preheader's
## hiding stacks are `style`-attribute literals, so the catalogue §9
## style-before-`aria-hidden` order holds. The wrapper's R-DOC-11
## doubled `font-size` is a fallback pair set with
## `setStyleWithFallback` (R-CSS-19), which only the serialiser
## writes. The one `bg` value is stamped in all four places, so the
## triple background stays coherent whatever its spelling;
## colour normalisation is P5's uniform tree-wide job (P2 spelling
## pending, pre-existing). The `style`-attribute nodes keep empty
## styles tables (a second style source would serialise two `style`
## attributes), and the future P4→P5 integration must leave the
## shell's table values unmirrored: `bgcolor` on body/table or
## `text-align` on the wrapper cell would break the catalogue §1 bytes.
##
## No IR constructor calls here: conditionals come from
## `mso/cond` (`msoWrap`/`notMsoWrap`) and `mso/document`, and the
## head blocks arrive as `enHeadStyle` nodes from P6's `assembleHead`.
##
## Pure tree building: identical on the C and JS targets.

import std/[algorithm, strutils, tables, unicode]
import ../renderer
import ../target
import ../mso/cond
import ../mso/document
import ../passes/head

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const contentCellAlign* = "center"
  ## The horizontal alignment of the skeleton's content cell
  ## (`<td align="center">`, catalogue §1): what content inherits when
  ## no container of its own sets one (the image lowering reads it).

proc preheaderPaddingUnits*(preheader: string): int =
  ## R-PRE-02: N = clamp(100 − len(preheader), 0, 150), where len
  ## counts characters. The rule stays pending (the unit sequence and
  ## N settle from inbox-list captures); this pins the formula. The
  ## unit itself is the `preheaderPad` target flag.
  max(0, min(150, 100 - preheader.runeLen))

proc docAttr(doc: EmailNode; key, default: string): string =
  if doc != nil and key in doc.attrs:
    return doc.attrs[key]
  default

proc docBackground(doc: EmailNode): string =
  ## `background_color` lives in `styles` on real templates (the
  ## vocabulary routes it as a style keyword) and in `attrs` on
  ## hand-built trees; P5-normalised trees carry `background-color`.
  if doc == nil:
    return "#ffffff"
  if "background_color" in doc.attrs:
    return doc.attrs["background_color"]
  if "background_color" in doc.styles:
    return doc.styles["background_color"]
  if "background-color" in doc.styles:
    return doc.styles["background-color"]
  "#ffffff"

proc hasWidth(t: EmailNode): bool =
  "width" in t.attrs or "width" in t.styles

proc fixLayoutTables*(n: EmailNode) =
  ## The reset's `table-layout:fixed` (R-RST-06), inline on every layout
  ## table outside Outlook conditionals that has a width of its own and
  ## no layout of its own (catalogue R-TBL-17): where head CSS is
  ## stripped (Gmail with a non-Google account), an auto-layout table
  ## grows to its longest unbroken word, so a long reference in a plain
  ## paragraph would widen the whole message past a phone. A data table
  ## keeps its own `auto` (R-TBL-18); Word reads only its ghost tables.
  if n == nil or n.kind == enMsoIf:
    return
  if n.kind == enElement and n.tag == "table" and
      n.attrs.getOrDefault("role", "") == "presentation" and hasWidth(n) and
      "table-layout" notin n.styles:
    n.styles["table-layout"] = "fixed"
  for c in n.children:
    fixLayoutTables(c)

proc lowerDocument*(doc: EmailNode; sections: EmailNode;
    head: seq[EmailNode]; target: EmailTarget): EmailNode =
  ## Lowers `mailDocument` to the catalogue §1 skeleton. `sections`
  ## (nil for an empty document) lands in the wrapper cell; `head`
  ## holds P6's `enHeadStyle` blocks, placed as separate `<style>`
  ## elements in priority order (R-DOC-12, R-CSS-07): the fonts block
  ## inside `NotMso`, the mso block inside `MsoIf` only when
  ## `target.outlookWord`, plus the `lte mso 11` group fix.
  let r = EmailRenderer()
  let lang = docAttr(doc, "lang", "en")
  let dir = docAttr(doc, "dir", "ltr")
  let title = docAttr(doc, "title", "")
  let preheader = docAttr(doc, "preheader", "")
  let bg = docBackground(doc)

  proc meta(attrs: openArray[(string, string)]): EmailNode =
    let m = r.createElement("meta")
    for (k, v) in attrs:
      r.setAttribute(m, k, v)
    m

  let html = r.createElement("html")
  r.setAttribute(html, "lang", lang)
  r.setAttribute(html, "dir", dir)
  r.setAttribute(html, "xmlns", "http://www.w3.org/1999/xhtml")
  r.setAttribute(html, "xmlns:v", "urn:schemas-microsoft-com:vml")
  r.setAttribute(html, "xmlns:o",
    "urn:schemas-microsoft-com:office:office")

  let headEl = r.createElement("head")
  r.appendChild(html, headEl)
  r.appendChild(headEl, meta([("charset", "utf-8")]))
  r.appendChild(headEl, meta([("name", "viewport"), ("content",
    "width=device-width, initial-scale=1, user-scalable=yes")]))
  r.appendChild(headEl, notMsoWrap(meta([("http-equiv",
    "X-UA-Compatible"), ("content", "IE=edge")])))
  r.appendChild(headEl, meta([("name", "format-detection"), ("content",
    "telephone=no, date=no, address=no, email=no, url=no")]))
  r.appendChild(headEl,
    meta([("name", "x-apple-disable-message-reformatting")]))
  if target.darkMode != dmNone:
    # R-DOC-07 refines the skeleton sketch: the pair is emitted only
    # when dark mode is accommodated or designed.
    r.appendChild(headEl, meta([("name", "color-scheme"),
      ("content", "light dark")]))
    r.appendChild(headEl, meta([("name", "supported-color-schemes"),
      ("content", "light dark")]))
  let titleEl = r.createElement("title")
  r.setTextContent(titleEl, title)
  r.appendChild(headEl, titleEl)
  if target.outlookWord:
    r.appendChild(headEl, officeDocumentSettings())

  # Head blocks in priority order (R-DOC-12), mso last; the sort is
  # indexed so equal priorities keep their input order.
  var plain: seq[tuple[rank, idx: int; node: EmailNode]] = @[]
  var mso: seq[EmailNode] = @[]
  for i, b in head:
    if b == nil:
      continue
    if b.kind == enHeadStyle and b.priority == msoPriority:
      mso.add(b)
    else:
      plain.add((b.priority, i, b))
  plain.sort(proc(x, y: tuple[rank, idx: int; node: EmailNode]): int =
    let c = cmp(x.rank, y.rank)
    if c != 0: c else: cmp(x.idx, y.idx))
  for (_, _, b) in plain:
    if b.kind == enHeadStyle and b.priority == fontsPriority:
      r.appendChild(headEl, notMsoWrap(b))
    else:
      r.appendChild(headEl, b)
  if target.outlookWord:
    for b in mso:
      r.appendChild(headEl, msoWrap(b))
    r.appendChild(headEl, msoGroupFix())

  # R-DOC-14: no `class` on <body> (Roundcube copies it over the
  # `rcmBody` class its scoped head rules select).
  let body = r.createElement("body")
  r.setAttribute(body, "xml:lang", lang)
  r.setStyle(body, "margin", "0")
  r.setStyle(body, "padding", "0")
  r.setStyle(body, "word-spacing", "normal")
  r.setStyle(body, "background-color", bg)
  r.appendChild(html, body)

  # The preheader divs carry `style` as a plain attribute rather than
  # through `setStyle`: the serialiser emits attributes before the
  # style table, and catalogue §9 orders the padding div's `style`
  # before its `aria-hidden`.
  let pre1 = r.createElement("div")
  r.setAttribute(pre1, "style", "display:none;font-size:1px;color:" &
    bg & ";line-height:1px;max-height:0;max-width:0;opacity:0;" &
    "overflow:hidden;mso-hide:all;")
  r.setTextContent(pre1, preheader)
  r.appendChild(body, pre1)
  let pre2 = r.createElement("div")
  r.setAttribute(pre2, "style", "display:none;font-size:1px;" &
    "line-height:1px;max-height:0;max-width:0;opacity:0;" &
    "overflow:hidden;mso-hide:all;")
  r.setAttribute(pre2, "aria-hidden", "true")
  r.appendChild(pre2,
    raw(target.preheaderPad.repeat(preheaderPaddingUnits(preheader))))
  r.appendChild(body, pre2)

  # The wrapper's doubled `font-size` (R-DOC-11) is a fallback pair
  # (R-CSS-19): `medium` for a client without `max()`, then
  # `max(16px, 1rem)`. The serialiser writes the styles table after the
  # attributes, where the `style` attribute stood.
  let wrap = r.createElement("div")
  r.setAttribute(wrap, "role", "article")
  r.setAttribute(wrap, "aria-roledescription", "email")
  r.setAttribute(wrap, "aria-label", title)
  r.setAttribute(wrap, "lang", lang)
  r.setAttribute(wrap, "dir", dir)
  r.setStyle(wrap, "background-color", bg)
  r.setStyleWithFallback(wrap, "font-size", "medium", "max(16px, 1rem)")
  # The document's own head rules (its `@dark:` background) reach the
  # wrapper and its table, which paint the canvas.
  let docClass = if doc != nil: doc.attrs.getOrDefault("class", "") else: ""
  if docClass.len > 0:
    r.setAttribute(wrap, "class", docClass)
  r.appendChild(body, wrap)
  let table = r.createElement("table")
  r.setAttribute(table, "role", "presentation")
  r.setAttribute(table, "width", "100%")
  r.setAttribute(table, "border", "0")
  r.setAttribute(table, "cellpadding", "0")
  r.setAttribute(table, "cellspacing", "0")
  r.setStyle(table, "background-color", bg)
  if docClass.len > 0:
    r.setAttribute(table, "class", docClass)
  r.appendChild(wrap, table)
  let tr = r.createElement("tr")
  r.appendChild(table, tr)
  let td = r.createElement("td")
  r.setAttribute(td, "align", "center")
  if sections != nil:
    r.appendChild(td, sections)
  r.appendChild(tr, td)
  fixLayoutTables(body)
  html
