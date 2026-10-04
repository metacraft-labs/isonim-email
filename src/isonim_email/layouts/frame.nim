## isonim_email/layouts/frame.nim — what every layout shares
## (layout-patterns.md §4.8): the document, its header and footer bands,
## the content card, and the props they read (`LayoutFrame`).
##
## A layout is a template, `proc(r: EmailRenderer; p: XProps):
## EmailNode`, returning a whole `mailDocument`: `renderEmail` and
## `story` take it as they take any template. It is built only from
## patterns and primitives, and every colour it writes is a theme
## token, so `darkMode = designed` gives it its dark palette with no
## `@dark:` of its own (R-DRK-02). A required prop left empty is reported
## by the pattern that needs it (a `mailHeader` without its logo, a
## `mailFooter` without its address: `E-VOCAB-BAD-VALUE`; a document
## without a title or a heading: `E-A11Y-TITLE-MISSING`,
## `E-A11Y-NO-H1`), never filled in.
##
## Pure tree building: identical on the C and JS targets.

import std/strutils
import ../renderer
import ../target
import ../style/tokens

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  LayoutLink* = object
    ## A link or a button: its label and where it goes.
    label*, href*: string

  LayoutRow* = object
    ## A key-value row: its label, its value, and whether it is bold.
    label*, value*: string
    emphasis*: bool

  LayoutSocial* = object
    ## A social link of the footer: a network `mailSocial` knows
    ## (`github`, `linkedin`, …) and its URL.
    network*, href*: string

  LayoutFrame* = object
    ## What every layout takes: the document, the brand's header and
    ## footer, the unsubscribe and preferences links.
    lang*: string = "en"       ## BCP 47
    dir*: string = "ltr"       ## `ltr` or `rtl`
    title*: string             ## the document title (required)
    preheader*: string
    brand*: string             ## the brand's name: the logo's alt text (required)
    logo*: string              ## Url (required)
    logoWidth*: int            ## px (required)
    logoDark*: string          ## the dark logo (R-IMG-06)
    homeUrl*: string           ## where the logo links
    links*: seq[LayoutLink]    ## the header's links (3 sit beside the logo)
    viewInBrowser*: string     ## Url of the web copy; "" for none
    viewInBrowserLabel*: string = "View in browser"
    address*: string           ## the sender's postal address (required)
    reason*: string            ## "You're receiving this because …"
    legal*: string
    unsubscribe*: string       ## Url; "" makes the footer transactional
    unsubscribeLabel*: string = "Unsubscribe"
    preferences*: string       ## Url
    preferencesLabel*: string = "Preferences"
    social*: seq[LayoutSocial] ## the footer's social row

  LayoutSlot* = proc(r: EmailRenderer; parent: EmailNode) {.closure.}
    ## Content the caller appends to `parent` (the content card's stack).

proc nodeAt*(r: EmailRenderer; parent: EmailNode; tag: string;
    attrs: openArray[(string, string)]; styles: openArray[(string, string)];
    text: string; at: SourceSpan): EmailNode =
  ## `node`, with the element's source span given (`at`).
  result = r.createElement(tag)
  result.origin = at
  for (k, v) in attrs:
    if v.len > 0:
      r.setAttribute(result, k, v)
  for (k, v) in styles:
    if v.len > 0:
      r.setStyle(result, k, v)
  if text.len > 0:
    r.appendChild(result, r.createTextNode(text))
  if parent != nil:
    r.appendChild(parent, result)

template node*(r: EmailRenderer; parent: EmailNode; tag: string;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []; text = ""): EmailNode =
  ## An element appended to `parent` (when given); an empty value is not
  ## set. The element's source span is the line that calls `node`, so a
  ## diagnostic about it points there, as one about an element of a
  ## `ui(r)` template does.
  nodeAt(r, parent, tag, attrs, styles, text,
    callerSpan(instantiationInfo(-1, fullPaths = true)))

proc layoutDocument*(r: EmailRenderer; f: LayoutFrame): EmailNode =
  ## The document on the canvas, its web-copy link after the preheader,
  ## and its header band (`mailHeader`: the logo, the links beside it).
  result = r.node(nil, "mailDocument", [("lang", f.lang), ("dir", f.dir),
    ("title", f.title), ("preheader", f.preheader)])
  r.setStyle(result, "background-color", tok"color.surface.canvas")
  if f.viewInBrowser.len > 0:
    discard r.node(result, "mailViewInBrowser", [("href", f.viewInBrowser),
      ("label", f.viewInBrowserLabel)])
  let band = r.node(result, "mailSection", styles = [("padding",
    "24px 0 16px")])
  let header = r.node(band, "mailHeader", [("logo", f.logo),
    ("logo_width", if f.logoWidth > 0: $f.logoWidth else: ""),
    ("logo_alt", f.brand), ("logo_dark", f.logoDark), ("href", f.homeUrl)])
  for l in f.links:
    discard r.node(header, "a", [("href", l.href)], text = l.label)

proc contentCard*(r: EmailRenderer; doc: EmailNode;
    padding = "32px 0"): EmailNode =
  ## A content band on the card surface, returning the `mailStack` its
  ## content goes into (24px between blocks).
  let band = r.node(doc, "mailSection", styles = [("padding", padding)])
  r.setStyle(band, "background-color", tok"color.surface.card")
  result = r.node(band, "mailStack")
  r.setStyle(result, "gap", tok"space.5")

proc heading*(r: EmailRenderer; parent: EmailNode; text, intro: string;
    level = "h1") =
  ## The message's heading (its `h1`, unless a hero above holds that)
  ## and its introduction. An empty heading writes none (a message
  ## without its `h1` is then `E-A11Y-NO-H1`, never an empty heading).
  if text.len > 0:
    let h = r.node(parent, level, text = text)
    r.setStyle(h, "margin", "0")
  if intro.len > 0:
    let p = r.node(parent, "p", text = intro)
    r.setStyle(p, "margin", "0")

proc buttonGroup*(r: EmailRenderer; parent: EmailNode;
    actions: openArray[LayoutLink]) =
  ## A `mailButtonGroup` of 1–3 actions (the first the primary one);
  ## stacked at full width on a phone. Nothing when there are none.
  if actions.len == 0:
    return
  let g = r.node(parent, "mailButtonGroup", [("stack_on_mobile", "true")])
  for a in actions:
    discard r.node(g, "mailButton", [("href", a.href)], text = a.label)

proc keyValue*(r: EmailRenderer; parent: EmailNode; caption: string;
    rows: openArray[LayoutRow]; totalRow = false) =
  ## A `mailKeyValue` of `rows`. Nothing when there are none.
  if rows.len == 0:
    return
  let kv = r.node(parent, "mailKeyValue", [("caption", caption),
    ("total_row", if totalRow: "true" else: "")])
  for row in rows:
    discard r.node(kv, "mailKeyValueRow", [("label", row.label),
      ("emphasis", if row.emphasis: "true" else: "")], text = row.value)

proc slotInto*(r: EmailRenderer; parent: EmailNode; slot: LayoutSlot) =
  if slot != nil:
    slot(r, parent)

proc markdownBody*(r: EmailRenderer; parent: EmailNode; src: string) =
  ## A Markdown body under the layout's `h1` (its `#` an `h2`).
  if src.strip().len > 0:
    discard r.node(parent, "mailMarkdown", [("src", src),
      ("heading_offset", "1")])

proc layoutFooter*(r: EmailRenderer; doc: EmailNode; f: LayoutFrame) =
  ## The footer band on the canvas: `mailFooter` (the reason, the
  ## address, the unsubscribe and preferences links, the legal text),
  ## its social row above them. Without an unsubscribe link the footer
  ## is a transactional one.
  let band = r.node(doc, "mailSection", styles = [("padding", "24px 0 32px")])
  let footer = r.node(band, "mailFooter", [("address", f.address),
    ("unsubscribe", f.unsubscribe),
    ("unsubscribe_label", f.unsubscribeLabel),
    ("preferences", f.preferences),
    ("preferences_label", f.preferencesLabel), ("legal", f.legal),
    ("reason", f.reason),
    ("transactional", if f.unsubscribe.len == 0: "true" else: "")])
  if f.social.len > 0:
    let s = r.node(footer, "mailSocial")
    for item in f.social:
      discard r.node(s, "mailSocialItem", [("network", item.network),
        ("href", item.href)])
