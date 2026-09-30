## Seed story: a minimal RTL alert `mailDocument`.
##
## Growth rule: the reference template set subsumes these seeds —
## when it lands, these builders retire (or grow into full reference
## stories); until then the verification tests build on them.
##
## Backend-independent (tree building only).
import isonim_email
import fixture_images

proc seedAlert*(): EmailNode =
  ## A P1-clean alert: `lang`/`dir`/`title`/`preheader` (RTL, to pin
  ## `dir` propagation past the `ltr` default), an `h1`, one layout
  ## table (its `role` left for P7 to backfill) and a `mailImage`
  ## with `alt` and a px width. Only elements with a lowering: a bare
  ## `img` is not part of the vocabulary, and an element without a
  ## lowering fails the render.
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "ar")
  r.setAttribute(doc, "dir", "rtl")
  r.setAttribute(doc, "title", "Security alert")
  r.setAttribute(doc, "preheader", "New sign-in detected.")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Security alert")
  r.appendChild(doc, h1)
  let table = r.createElement("table")
  let tr = r.createElement("tr")
  let td = r.createElement("td")
  r.setTextContent(td, "Sign-in from a new device.")
  r.appendChild(tr, td)
  r.appendChild(table, tr)
  r.appendChild(doc, table)
  # A 96×96 @2x PNG shown at 48 px (tests/stories/assets/shield.png,
  # served to the capture browsers from the fixture host).
  let img = r.createElement("mailImage")
  r.setAttribute(img, "src", fixtureImageUrl("shield.png"))
  r.setAttribute(img, "alt", "Shield icon")
  r.setStyle(img, "width", "48px")
  r.appendChild(doc, img)
  doc
