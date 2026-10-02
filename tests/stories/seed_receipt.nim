## Seed story: a minimal receipt `mailDocument`.
##
## Growth rule: the reference template set subsumes these seeds —
## when it lands, these builders retire (or grow into full reference
## stories); until then the verification tests build on them.
##
## Backend-independent (tree building only).
import isonim_email
import fixture_images

proc seedReceipt*(): EmailNode =
  ## A P1-clean receipt: `lang`/`dir`/`title`/`preheader`, and one
  ## centred `mailSection` holding an `h1`, one layout table (its
  ## `role` left for P7 to backfill) and a `mailImage` with `alt` and a
  ## px width. Only elements with a lowering: an element without one
  ## fails the render.
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Receipt #1234")
  r.setAttribute(doc, "preheader", "Thanks for your order.")
  # One centred section (div-first scaffolding): the content keeps
  # the centring the skeleton's content cell gave it before.
  let section = r.createElement("mailSection")
  r.setStyle(section, "text-align", "center")
  r.appendChild(doc, section)
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Receipt #1234")
  r.setStyle(h1, "color", "#111111")
  r.appendChild(section, h1)
  let table = r.createElement("table")
  # Centred like the section's text: a table is a block, which only its
  # own `align` centres everywhere (text alignment moves inline content).
  r.setAttribute(table, "align", "center")
  let tr = r.createElement("tr")
  let td = r.createElement("td")
  r.setTextContent(td, "Widget: $10.00")
  r.appendChild(tr, td)
  r.appendChild(table, tr)
  r.appendChild(section, table)
  let img = r.createElement("mailImage")
  r.setAttribute(img, "src", fixtureImageUrl("logo.png"))
  r.setAttribute(img, "alt", "Acme logo")
  # A 240×80 @2x PNG shown at 120 px (tests/stories/assets/logo.png,
  # served to the capture browsers from the fixture host).
  r.setStyle(img, "width", "120px")
  r.appendChild(section, img)
  doc
