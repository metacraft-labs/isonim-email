## Layout reference story: one column of sections and a wrapper.
##
## The div-first scaffolding as a real message would use it: a header
## section with the logo, a wrapper whose grey band holds two white
## sections (the first a stack of heading and paragraphs, the second
## bordered), and a full-width footer band in a dark colour. Every
## block is one column, so each section's column padding merges into
## the section (no column scaffolding). It is iterated on in the capture
## loop like any story, on every provider.
##
## Env-gated: the drivers register it only under
## `ISONIM_CAPTURE_LAYOUT=1`, so bare runs, the capture regression
## matrix and the story-set pins never see it (it has no baselines).
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import fixture_images

proc text(r: EmailRenderer; parent: EmailNode; tag, body: string;
    styles: openArray[(string, string)] = []) =
  let el = r.createElement(tag)
  r.setTextContent(el, body)
  for (k, v) in styles:
    r.setStyle(el, k, v)
  r.appendChild(parent, el)

proc layoutOneColumnDoc*(): EmailNode =
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Your weekly summary")
  r.setAttribute(doc, "preheader", "Three builds, one review, no alerts.")
  r.setStyle(doc, "background-color", "#f4f5f7")

  # Header: the logo, centred on white.
  let header = r.createElement("mailSection")
  r.setStyle(header, "background-color", "#ffffff")
  r.setStyle(header, "padding", "16px 0")
  r.setStyle(header, "text-align", "center")
  let logo = r.createElement("mailImage")
  r.setAttribute(logo, "src", fixtureImageUrl("logo.png"))
  r.setAttribute(logo, "alt", "Acme logo")
  r.setStyle(logo, "width", "120px")
  r.appendChild(header, logo)
  r.appendChild(doc, header)

  # A grey wrapper band around two white sections.
  let wrapper = r.createElement("mailWrapper")
  r.setStyle(wrapper, "background-color", "#e5e7eb")
  r.setStyle(wrapper, "padding", "16px 12px")
  let body = r.createElement("mailSection")
  r.setStyle(body, "background-color", "#ffffff")
  let stack = r.createElement("mailStack")
  r.setStyle(stack, "gap", "8px")
  r.text(stack, "h1", "Your weekly summary")
  r.text(stack, "p", "Three builds finished this week and one review " &
    "is waiting for you.")
  r.text(stack, "p", "No alerts were raised.")
  r.appendChild(body, stack)
  r.appendChild(wrapper, body)
  let note = r.createElement("mailSection")
  r.setStyle(note, "background-color", "#ffffff")
  r.setStyle(note, "padding", "16px 0")
  r.setStyle(note, "border", "1px solid #9ca3af")
  r.text(note, "p", "This section has a border and its own padding.")
  r.appendChild(wrapper, note)
  r.appendChild(doc, wrapper)

  # Footer: a full-width dark band.
  let footer = r.createElement("mailSection")
  r.setAttribute(footer, "full_width", "true")
  r.setStyle(footer, "background-color", "#1f2937")
  r.setStyle(footer, "text-align", "center")
  r.text(footer, "p", "Acme Inc., 1 Example Street, Springfield",
    [("color", "#f9fafb")])
  r.appendChild(doc, footer)
  doc

const layoutOneColumnText* = "Your weekly summary\n\n" &
  "Three builds finished this week and one review is waiting for you.\n\n" &
  "No alerts were raised.\n\n" &
  "This section has a border and its own padding.\n\n" &
  "Acme Inc., 1 Example Street, Springfield\n"
  ## Fixed plain-text alternative (the plain-text generator will
  ## produce these).

proc renderLayoutOneColumn*(): StoryHtml =
  (renderPipeline(layoutOneColumnDoc(), defaultTarget()), layoutOneColumnText)

proc registerLayoutStories*() =
  ## Registers the layout reference stories (env-gated, see above).
  registerStory(Story(name: "layoutOneColumn", group: "layout",
    description: "One column: sections, a wrapper, a stack, a bordered " &
      "and a full-width section.", render: renderLayoutOneColumn))
