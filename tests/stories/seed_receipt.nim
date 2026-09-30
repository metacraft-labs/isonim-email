## Seed story: a minimal receipt `mailDocument`.
##
## Growth rule: the reference template set subsumes these seeds —
## when it lands, these builders retire (or grow into full reference
## stories); until then the verification tests build on them.
##
## Backend-independent (tree building only).
import isonim_email

proc seedReceipt*(): EmailNode =
  ## A P1-clean receipt: `lang`/`dir`/`title`/`preheader`, an `h1`,
  ## one layout table (its `role` left for P7 to backfill) and a
  ## `mailImage` with `alt`.
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Receipt #1234")
  r.setAttribute(doc, "preheader", "Thanks for your order.")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Receipt #1234")
  r.setStyle(h1, "color", "#111111")
  r.appendChild(doc, h1)
  let table = r.createElement("table")
  let tr = r.createElement("tr")
  let td = r.createElement("td")
  r.setTextContent(td, "Widget: $10.00")
  r.appendChild(tr, td)
  r.appendChild(table, tr)
  r.appendChild(doc, table)
  let img = r.createElement("mailImage")
  r.setAttribute(img, "src", "https://x.test/logo.png")
  r.setAttribute(img, "alt", "Acme logo")
  r.appendChild(doc, img)
  doc
