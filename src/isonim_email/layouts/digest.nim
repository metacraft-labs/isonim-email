## isonim_email/layouts/digest.nim — `digestLayout`
## (layout-patterns.md §4.8; the digest / newsletter row of §4.6): the
## header, an optional `mailHero` (text over an image), the heading,
## then the repeated items as a `mailGrid` of `mailCard`s or as a
## `mailZigZag` of `mailMediaObject`s, then the footer.
##
## The hero's text sits over an image, which no colour scheme changes:
## its colours are the caller's (`heroColor`, `heroTextColor`), the one
## place a layout writes a colour that is not a theme token (under
## `darkMode = designed` they are reported, `W-DARK-RAW-COLOR`, as for
## any raw colour).
##
## Pure tree building: identical on the C and JS targets.

import ../renderer
import ../target
import ../style/tokens
import ./frame

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const digestContentWidth = 552
  ## The content card's width: the 600px message less its 24px sides.

type
  DigestArrangement* = enum
    ## How the items are laid out.
    daGrid = "grid"       ## cards, `columns` per row (one on a phone)
    daZigZag = "zigzag"   ## media objects, the image side alternating

  DigestHero* = object
    ## The hero: text over an image (or over its colour alone).
    title*: string            ## "" for no hero
    text*: string
    image*: string            ## the background image's Url
    color*: string = "#1b2a4a" ## the colour under it (and with images off)
    textColor*: string = "#ffffff"
    height*: int = 280        ## px (its minimum, and Word's height)
    cta*: string
    href*: string

  DigestItem* = object
    ## One repeated item.
    title*: string            ## required
    body*: string
    image*: string            ## Url; "" for none
    imageAlt*: string         ## "" = decorative
    imageWidth*: int = 200    ## px, in a zig-zag row
    crop*: bool = true        ## crop the image to the layout's `imageRatio`
                              ## (it must be an asset the render holds)
    cta*: string
    href*: string

  DigestLayoutProps* = object
    ## `digestLayout`'s props.
    frame*: LayoutFrame
    hero*: DigestHero
    heading*: string          ## the `h1` (required)
    intro*: string
    arrangement*: DigestArrangement = daGrid
    columns*: int = 2         ## cards per row (2–3)
    items*: seq[DigestItem]
    imageRatio*: string = "3:2" ## the cards' images are cropped to it
    content*: LayoutSlot      ## the caller's content, after the items

proc digestLayout*(r: EmailRenderer; p: DigestLayoutProps): EmailNode =
  ## Header, hero, repeated cards, footer. With a hero, its title is the
  ## message's `h1` and `heading` an `h2`; the items' titles are one
  ## level below `heading`.
  result = r.layoutDocument(p.frame)
  let withHero = p.hero.title.len > 0
  if withHero:
    let h = r.node(result, "mailHero", [("vertical_align", "middle")],
      [("background-color", p.hero.color),
      ("background-image", p.hero.image),
      ("min-height", $p.hero.height & "px")])
    discard r.node(h, "h1", styles = [("color", p.hero.textColor),
      ("margin", "0 0 8px")], text = p.hero.title)
    if p.hero.text.len > 0:
      discard r.node(h, "p", styles = [("color", p.hero.textColor),
        ("margin", "0 0 16px")], text = p.hero.text)
    if p.hero.cta.len > 0:
      discard r.node(h, "mailButton", [("href", p.hero.href)],
        text = p.hero.cta)
  let stack = r.contentCard(result)
  r.heading(stack, p.heading, p.intro, if withHero: "h2" else: "h1")
  let itemLevel = if withHero: "h3" else: "h2"
  case p.arrangement
  of daGrid:
    # Without head CSS (Gmail with other accounts) the items wrap as
    # many as fit; held to their desktop width, a card that wraps keeps
    # it rather than its 160px minimum.
    let gutter = 24
    let item = (digestContentWidth - (p.columns - 1) * gutter) div
      max(p.columns, 1)
    let g = r.node(stack, "mailGrid", [("columns", $p.columns),
      ("mobile_columns", "1"), ("min_item", $item & "px")])
    for it in p.items:
      let c = r.node(g, "mailCard", [("title", it.title), ("level", itemLevel),
        ("image", it.image), ("image_alt", it.imageAlt),
        ("decorative", if it.image.len > 0 and it.imageAlt.len == 0: "true"
          else: ""),
        ("image_ratio", if it.image.len > 0 and it.crop: p.imageRatio
          else: ""),
        ("cta", it.cta), ("cta_href", it.href)])
      if it.body.len > 0:
        discard r.node(c, "p", text = it.body)
  of daZigZag:
    let z = r.node(stack, "mailZigZag")
    for it in p.items:
      let m = r.node(z, "mailMediaObject", [("image", it.image),
        ("image_width", $it.imageWidth), ("image_alt", it.imageAlt),
        ("decorative", if it.imageAlt.len == 0: "true" else: ""),
        ("image_href", it.href),
        ("image_ratio", if it.crop: p.imageRatio else: "")])
      let h = r.node(m, itemLevel, text = it.title)
      r.setStyle(h, "margin", "0 0 8px")
      if it.body.len > 0:
        discard r.node(m, "p", text = it.body)
      if it.cta.len > 0:
        discard r.node(m, "a", [("href", it.href)], text = it.cta)
  r.slotInto(stack, p.content)
  r.layoutFooter(result, p.frame)
