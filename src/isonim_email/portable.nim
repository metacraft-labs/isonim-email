## isonim_email/portable.nim — the portable leaf set: text, heading,
## link, image, key-value and data table, plus the root a view is built
## in.
##
## A domain view written only against these leaves,
## `proc renderX*[R, E](r: R; data: X): E`, compiles for every renderer
## and renders the same content in an email and on a web page. Each leaf
## is generic over the renderer and has two implementations, chosen at
## compile time by the renderer type:
##
## | Leaf | `EmailRenderer` | Any other renderer (web: semantic HTML) |
## |---|---|---|
## | `leafView` | `mailStack` (gap `space.5`) | `<section aria-label>` |
## | `leafText` | `p` (the text defaults) | `<p>` |
## | `leafHeading` | `h1`-`h6` | `<h1>`-`<h6>` |
## | `leafLink` | `p` holding `a href` | `<p>` holding `<a href>` |
## | `leafImage` | `mailImage(src, alt or decorative, width, height, dark_src)` | `<img>`, in a `<picture>` with a dark-scheme `<source>` when `darkSrc` is set |
## | `leafKeyValue` | `mailKeyValue` of `mailKeyValueRow`s | `<figure>`: a visually hidden `<figcaption>`, then a `<dl>` of `<div><dt><dd></div>` rows |
## | `leafTable` | `mailTable` holding `table > thead/tbody` | `<table>`: a visually hidden `<caption>`, `<thead>` of `<th scope="col">`, `<tbody>` of `<td>` |
##
## The two sides write the same text in the same order (a caption is
## text on both, visually hidden on both). The web half uses only the
## renderer surface every IsoNim renderer provides (`createElement`,
## `createTextNode`, `appendChild`, `setAttribute`, `setStyle`), so it
## runs on the browser renderer, on `MockRenderer` and on any other.
##
## A view is called with its renderer types given, as IsoNim's generic
## views are: `renderInvoiceSummary[EmailRenderer, EmailNode](r, inv)`.
## The choice is a compile-time branch rather than overloads: an
## explicitly instantiated generic view would bind a generic overload
## and write web HTML into an email.
##
## Pure tree building: identical on the C and JS targets.

import std/strutils
import ./renderer
import ./target
import ./style/tokens

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  LeafImage* = object
    ## An image leaf.
    src*: string     ## Url (on email: an asset name or an `asset"…"` path, as for `mailImage`)
    alt*: string     ## "" = decorative
    width*: int      ## display width, px (required)
    height*: int     ## display height, px; 0 = from the image's ratio
    darkSrc*: string ## the image for a dark scheme; "" = none

  LeafRow* = object
    ## A key-value row.
    label*, value*: string
    emphasis*: bool

  LeafColumn* = object
    ## A data-table column.
    header*: string
    numeric*: bool ## aligned to the end of the line, never wrapped

  LeafTable* = object
    ## A data table.
    caption*: string        ## its accessible name (visually hidden)
    columns*: seq[LeafColumn]
    rows*: seq[seq[string]] ## one cell per column
    rtl*: bool              ## runs right to left (where "end" is)

# --- EmailRenderer ----------------------------------------------------------------

proc mailEl(r: EmailRenderer; parent: EmailNode; tag: string;
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  ## An element appended to `parent`; an empty attribute is not set.
  result = r.createElement(tag)
  for (k, v) in attrs:
    if v.len > 0:
      r.setAttribute(result, k, v)
  if text.len > 0:
    r.appendChild(result, r.createTextNode(text))
  if parent != nil:
    r.appendChild(parent, result)

proc emailView(r: EmailRenderer): EmailNode =
  result = r.createElement("mailStack")
  r.setStyle(result, "gap", tok"space.5")

proc emailImage(r: EmailRenderer; parent: EmailNode;
    img: LeafImage): EmailNode =
  r.mailEl(parent, "mailImage", [("src", img.src), ("alt", img.alt),
    ("decorative", if img.alt.len == 0: "true" else: ""),
    ("width", if img.width > 0: $img.width & "px" else: ""),
    ("height", if img.height > 0: $img.height & "px" else: ""),
    ("dark_src", img.darkSrc)])

proc emailKeyValue(r: EmailRenderer; parent: EmailNode; caption: string;
    rows: openArray[LeafRow]; totalRow: bool): EmailNode =
  result = r.mailEl(parent, "mailKeyValue", [("caption", caption),
    ("total_row", if totalRow: "true" else: "")])
  for row in rows:
    discard r.mailEl(result, "mailKeyValueRow", [("label", row.label),
      ("emphasis", if row.emphasis: "true" else: "")], text = row.value)

proc emailTable(r: EmailRenderer; parent: EmailNode;
    t: LeafTable): EmailNode =
  result = r.mailEl(parent, "mailTable", [("caption", t.caption)])
  let table = r.mailEl(result, "table")
  let (startSide, endSide) =
    if t.rtl: ("right", "left") else: ("left", "right")
  proc cell(row: EmailNode; tag: string; i, last: int; text: string) =
    let c = r.mailEl(row, tag, text = text)
    # The table's text lines up with the leaves around it: no inset at
    # its outer edges (the cells keep their padding between columns).
    if i == 0:
      r.setStyle(c, "padding-" & startSide, "0")
    if i == last:
      r.setStyle(c, "padding-" & endSide, "0")
    if i < t.columns.len and t.columns[i].numeric:
      # An amount sits at the end of its line and never breaks.
      r.setStyle(c, "text-align", endSide)
      r.setStyle(c, "white-space", "nowrap")
  let head = r.mailEl(r.mailEl(table, "thead"), "tr")
  for i, col in t.columns:
    cell(head, "th", i, t.columns.high, col.header)
  let body = r.mailEl(table, "tbody")
  for row in t.rows:
    let tr = r.mailEl(body, "tr")
    for i, v in row:
      cell(tr, "td", i, row.high, v)

# --- Web (any other renderer): semantic HTML ----------------------------------------

proc webEl[R, E](r: R; parent: E; tag: string; text = ""): E =
  ## An element appended to `parent`, holding `text` when given.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  result = r.createElement(tag)
  if text.len > 0:
    r.appendChild(result, r.createTextNode(text))
  r.appendChild(parent, result)

proc visuallyHidden[R, E](r: R; node: E) =
  ## Read by screen readers and part of the text, not drawn.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  r.setStyle(node, "position", "absolute")
  r.setStyle(node, "width", "1px")
  r.setStyle(node, "height", "1px")
  r.setStyle(node, "margin", "-1px")
  r.setStyle(node, "padding", "0")
  r.setStyle(node, "overflow", "hidden")
  r.setStyle(node, "clip", "rect(0 0 0 0)")
  r.setStyle(node, "white-space", "nowrap")
  r.setStyle(node, "border", "0")

proc webImage[R, E](r: R; parent: E; img: LeafImage): E =
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  let holder =
    if img.darkSrc.len > 0:
      let picture = webEl[R, E](r, parent, "picture")
      let source = webEl[R, E](r, picture, "source")
      r.setAttribute(source, "media", "(prefers-color-scheme: dark)")
      r.setAttribute(source, "srcset", img.darkSrc)
      picture
    else:
      parent
  result = webEl[R, E](r, holder, "img")
  r.setAttribute(result, "src", img.src)
  r.setAttribute(result, "alt", img.alt)
  if img.width > 0:
    r.setAttribute(result, "width", $img.width)
  if img.height > 0:
    r.setAttribute(result, "height", $img.height)
  r.setStyle(result, "display", "block")
  r.setStyle(result, "max-width", "100%")
  r.setStyle(result, "height", "auto")

proc webKeyValue[R, E](r: R; parent: E; caption: string;
    rows: openArray[LeafRow]; totalRow: bool): E =
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  result = webEl[R, E](r, parent, "figure")
  r.setAttribute(result, "class", "leaf-keyvalue")
  r.setStyle(result, "margin", "0")
  if caption.strip().len > 0:
    visuallyHidden[R, E](r, webEl[R, E](r, result, "figcaption",
      caption.strip()))
  let dl = webEl[R, E](r, result, "dl")
  r.setStyle(dl, "margin", "0")
  for i, row in rows:
    let total = totalRow and i == rows.high
    let group = webEl[R, E](r, dl, "div")
    r.setStyle(group, "display", "flex")
    r.setStyle(group, "justify-content", "space-between")
    r.setStyle(group, "gap", "16px")
    r.setStyle(group, "padding", if total: "12px 0 6px" else: "6px 0")
    if row.emphasis or total:
      r.setStyle(group, "font-weight", "700")
    if total:
      r.setStyle(group, "border-top", "1px solid")
    discard webEl[R, E](r, group, "dt", row.label)
    let dd = webEl[R, E](r, group, "dd", row.value)
    r.setStyle(dd, "margin", "0")
    r.setStyle(dd, "text-align", "end")

proc webTable[R, E](r: R; parent: E; t: LeafTable): E =
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  result = webEl[R, E](r, parent, "table")
  r.setAttribute(result, "class", "leaf-table")
  r.setStyle(result, "width", "100%")
  r.setStyle(result, "border-collapse", "collapse")
  if t.caption.strip().len > 0:
    visuallyHidden[R, E](r, webEl[R, E](r, result, "caption",
      t.caption.strip()))
  proc cell(row: E; tag: string; i: int; text: string) =
    let c = webEl[R, E](r, row, tag, text)
    if tag == "th":
      r.setAttribute(c, "scope", "col")
    r.setStyle(c, "text-align",
      if i < t.columns.len and t.columns[i].numeric: "end" else: "start")
    if i < t.columns.len and t.columns[i].numeric:
      r.setStyle(c, "white-space", "nowrap")
  let head = webEl[R, E](r, webEl[R, E](r, result, "thead"), "tr")
  for i, col in t.columns:
    cell(head, "th", i, col.header)
  let body = webEl[R, E](r, result, "tbody")
  for row in t.rows:
    let tr = webEl[R, E](r, body, "tr")
    for i, v in row:
      cell(tr, "td", i, v)

# --- The leaves ---------------------------------------------------------------------

proc leafView*[R, E](r: R; label: string): E =
  ## The root of a domain view, which the caller places: on email a
  ## `mailStack` (24px between its leaves), on the web a `<section>`
  ## named `label`.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  when R is EmailRenderer:
    emailView(r)
  else:
    result = r.createElement("section")
    if label.len > 0:
      r.setAttribute(result, "aria-label", label)

proc leafText*[R, E](r: R; parent: E; text: string): E {.discardable.} =
  ## A paragraph.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  when R is EmailRenderer:
    r.mailEl(parent, "p", text = text)
  else:
    webEl[R, E](r, parent, "p", text)

proc leafHeading*[R, E](r: R; parent: E; text: string;
    level: range[1 .. 6] = 2): E {.discardable.} =
  ## A heading of `level`.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  when R is EmailRenderer:
    r.mailEl(parent, "h" & $level, text = text)
  else:
    webEl[R, E](r, parent, "h" & $level, text)

proc leafLink*[R, E](r: R; parent: E; label, href: string): E {.discardable.} =
  ## A link on a line of its own; returns the paragraph holding it.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  when R is EmailRenderer:
    result = r.mailEl(parent, "p")
    discard r.mailEl(result, "a", [("href", href)], text = label)
  else:
    result = webEl[R, E](r, parent, "p")
    let a = webEl[R, E](r, result, "a", label)
    r.setAttribute(a, "href", href)

proc leafImage*[R, E](r: R; parent: E; image: LeafImage): E {.discardable.} =
  ## An image (`alt` empty: decorative), with its dark-scheme copy when
  ## `darkSrc` is set; returns the image element.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  when R is EmailRenderer:
    emailImage(r, parent, image)
  else:
    webImage[R, E](r, parent, image)

proc leafKeyValue*[R, E](r: R; parent: E; caption: string;
    rows: openArray[LeafRow]; totalRow = false): E {.discardable.} =
  ## Labels and their values; with `totalRow` the last row is a total,
  ## bold under a rule.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  when R is EmailRenderer:
    emailKeyValue(r, parent, caption, rows, totalRow)
  else:
    webKeyValue[R, E](r, parent, caption, rows, totalRow)

proc leafTable*[R, E](r: R; parent: E; table: LeafTable): E {.discardable.} =
  ## A data table: a header row, then the body rows.
  mixin createElement, createTextNode, appendChild, setAttribute, setStyle
  when R is EmailRenderer:
    emailTable(r, parent, table)
  else:
    webTable[R, E](r, parent, table)
