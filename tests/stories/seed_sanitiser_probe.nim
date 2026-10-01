## Capture fixture: head CSS under a webmail sanitiser.
##
## A small document rendered with `darkMode = designed`, so its head
## carries every kind of block a real message can: the reset, a
## responsive `@media` rule with its Thunderbird copy, the dark block
## (`prefers-color-scheme` rules and their `[data-ogsc]`/`[data-ogsb]`
## copies), a `:hover` rule and the MSO-only conditional block, plus the
## generated `e-` classes those rules target and one hosted image. The
## self-hosted webmail capture test delivers it to real webmail
## sanitisers and checks what survives, what is rewritten and what is
## stripped (recorded in tools/capture/emulation/RULES.md).
##
## Env-gated like the overflow twins: the drivers register it only
## under `ISONIM_CAPTURE_FIXTURES=1`, so bare runs, CI matrices and the
## t7 story-set pins never see it.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import fixture_images

proc sanitiserProbeDoc*(): EmailNode =
  ## h1 and p with dark-mode colours, a p with a phone-width padding,
  ## a link with a hover rule, and the logo.
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Sanitiser probe")
  r.setAttribute(doc, "preheader", "Head CSS under a webmail sanitiser.")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Sanitiser probe")
  r.setStyle(h1, "color", "#111111")
  r.setStyle(h1, "@dark:color", "#f9fafb")
  r.appendChild(doc, h1)
  let p = r.createElement("p")
  r.setTextContent(p, "Dark-designed paragraph.")
  r.setStyle(p, "color", "#111827")
  r.setStyle(p, "background-color", "#ffffff")
  r.setStyle(p, "@dark:color", "#e5e7eb")
  r.setStyle(p, "@dark:background-color", "#111827")
  r.setStyle(p, "@sm:padding", "8")
  r.appendChild(doc, p)
  let a = r.createElement("a")
  r.setAttribute(a, "href", "https://x.test/link")
  r.setTextContent(a, "A link")
  r.setStyle(a, "color", "#1d4ed8")
  r.setStyle(a, "@hover:text-decoration", "underline")
  r.appendChild(doc, a)
  let img = r.createElement("mailImage")
  r.setAttribute(img, "src", fixtureImageUrl("logo.png"))
  r.setAttribute(img, "alt", "Acme logo")
  r.setStyle(img, "width", "120px")
  r.appendChild(doc, img)
  doc

const sanitiserProbeText* = "Sanitiser probe\n\n" &
  "Head CSS under a webmail sanitiser.\n"
  ## Fixed plain-text alternative (the plain-text generator will
  ## produce these).

proc sanitiserProbeTarget(): EmailTarget =
  result = defaultTarget()
  result.darkMode = dmDesigned

proc renderSanitiserProbe*(): StoryHtml =
  ## The probe through the current pipeline, dark mode designed.
  (renderPipeline(sanitiserProbeDoc(), sanitiserProbeTarget()),
    sanitiserProbeText)
