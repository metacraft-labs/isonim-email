# Emulation-transform rules

Every correction learned from backends B/C/D is recorded in this file
with its screenshot pair: the backend-A emulation
that was wrong, the real-client capture that showed it, and the rule
change that fixed it. Real webmail sanitisers run locally
(Roundcube and SnappyMail, last section) are recorded as evidence
too. Until backend B lands, the citations below rest on published
behaviour only: the rules in
`docs/rendering-rules.md`, and — for the steps no rule covers — the
publicly documented client rewrites (Gmail's `m_` class prefix and `a3s`
body wrapper, Outlook.com's `x_` prefix and `rps_` wrapper, images-off
rendering).

Every transform that rewrites inline `style=` attributes decodes their
quote entities first and escapes the result again for the attribute's
quote (`style_attr.ts`), so a font stack such as
`font-family:&quot;Open Sans&quot;` never ends the attribute early.
Each transform's version enters the result-cache key, so changing a
transform never serves a capture made by the old one.

## gmailWeb (`gmailWeb.ts`, version 2)

Emulation steps 1–6. Step 2 cites R-CSS-03 (uppercase
`!IMPORTANT`), R-CSS-04 (nested at-rules), R-CSS-05 (parse errors) and
R-CSS-07 (16,384-byte head budget); step 3 cites R-CSS-09 (attribute
selectors) and R-CSS-10 (non-width media features); step 4 cites
R-CSS-11 (`var()` declarations) and R-IMG-08 (`data:` images); step 6
cites R-SIZE-01 (102,400-byte clip): the cut is at that byte offset,
moved back only out of a tag, comment, character reference or
multi-byte character, so a long paragraph is clipped mid-text.
Steps 1 (non-head styles) and 5 (`m_<hash>` prefix, `a3s` wrapper) cite
documented Gmail behaviour only (caniemail html-style note 1; Gmail's
class prefixing).

## ganga (`ganga.ts`, version 2)

Strip every `<style>` and `<link>`, then gmailWeb steps
4–5 (R-CSS-11, R-IMG-08). The strip itself cites caniemail html-style
note 2 (no `<style>` for non-Google accounts).

## outlookWeb (`outlookWeb.ts`, version 3)

`x_` prefix plus `rps_xxxx` wrapper (documented Outlook.com behaviour;
the wrapper class is measured against real clients later). Every
declaration whose value uses `calc()` or `max()` is dropped, inline and
in `<style>` blocks (caniemail `css-unit-calc` and `css-function-max`:
Outlook.com supports neither; R-LAY-18, R-CSS-19), so a Fab Four column
keeps only its `min-width`/`max-width` and the wrapper's
`font-size:medium` fallback holds. Dark
recolours with the R-DRK-04 partial-inversion model — inline text
colours with luminance < 0.5 and inline or `bgcolor` backgrounds with
luminance > 0.5 get OKLCH lightness L → 1 − L, chroma and hue kept —
and marks each recoloured element with `data-ogsc`/`data-ogsb`
(R-DRK-03), so the message's own `[data-ogsc] …` rules apply over it.

## imagesOff (`imagesOff.ts`, version 2)

No catalogue rule; models images blocked by default: empty `img[src]`/`srcset`,
drop CSS `background-image`. `--images off` applies it after any
family's own transform, and blocks image requests to the fixture host.

## wordApprox (`wordApprox.ts`, version 4)

Lint-grade (emulation steps 1–5): reveal mso conditionals; strip
`max-width` (R-OL-03), `display:flex|grid|inline-block`, declarations
using `calc()` (caniemail `css-unit-calc`: no support in Outlook for
Windows; the Fab Four width, R-LAY-18), `box-shadow` (caniemail
`box-shadow`: no support in Outlook for Windows; R-TBL-09), CSS
`background-image` (R-OL-11), `border-radius` (R-OL-12), `margin:auto`
(R-LAY-08) and non-`td`/`th` padding (R-OL-05, R-TBL-02); strip
`<style>` media queries (R-LAY-02 excludes outlookWord); stand VML
shapes in as flat labelled rectangles (R-VML-01/02); flatten `rgba()`
(R-CSS-14).

## Real-sanitiser evidence: self-hosted webmail

Roundcube 1.6.15 (Elastic skin) and SnappyMail 2.38.2 (default user
settings), captured by the `selfhosted-webmail` provider in the pinned
Chromium. They are verification clients, not audience families: each
is a real, independently written sanitiser, so they show how head CSS
and scoped classes fare outside a browser engine, and they calibrate
the two kinds of webmail behaviour the transforms above model
(prefix-and-scope like gmailWeb and outlookWeb, strip-everything like
ganga). Measured 2026-10-01 on the `sanitiserProbe` capture fixture
(a `darkMode = designed` render whose head has the reset, the
responsive block — a column width rule with its `.moz-text-html` copy
and a mobile rule — the dark
block with its `[data-ogsc]`/`[data-ogsb]` copies, a `:hover` rule and
the `lte mso 11` conditional block) and on the receipt story, light
and dark, desktop and mobile. Each claim below is asserted by
`tools/capture/providers/selfhosted_webmail.test.ts` ("records how
Roundcube and SnappyMail sanitise head CSS", and "aborts every page
request but the webmail and the assets service, and lists it" for the
images), which captures the sanitised message-body DOM it inspects
(provenance `sanitised_html`).

<!-- markdownlint-disable MD013 -->
<!-- A table row cannot wrap. -->

| What                                          | Roundcube 1.6.15 (`washtml`)                                                                                                                                                        | SnappyMail 2.38.2 (in-browser cleaner)                                                                                                                                                                                                     |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `<style>` blocks                              | Kept, each as its own `<style>` (all four outside conditional comments)                                                                                                             | All removed                                                                                                                                                                                                                                |
| Selectors                                     | Every selector scoped under the body wrapper: `#message-htmlpart1 div.rcmBody …`; `html`/`body` become the wrapper                                                                  | Gone with the blocks                                                                                                                                                                                                                       |
| Class names, ids                              | Prefixed `v1` in the attributes and in the CSS alike (`e-3sg` → `v1e-3sg`, `#outlook` → `#v1outlook`, `.moz-text-html` → `.v1moz-text-html`)                                        | Every `class` and `id` of the message removed; only the webmail's own wrappers (`b-text-part`, `mail-body`) carry classes                                                                                                                  |
| Media queries                                 | Kept, scoped selectors inside: `@media only screen and (max-width: 479px){#message-htmlpart1 div.rcmBody .v1e-…}`                                                                   | Gone                                                                                                                                                                                                                                       |
| Dark rules                                    | `@media (prefers-color-scheme: dark)` kept and scoped. The webmail's dark mode (Elastic follows the browser's scheme) does not recolour the message: it stays on its own background | Gone. Dark is a theme (no automatic dark mode); the message keeps its backgrounds                                                                                                                                                          |
| `[data-ogsc]`/`[data-ogsb]` copies (R-DRK-03) | Kept but scoped under the wrapper, so they can only match inside the message: inert, harmless                                                                                       | Gone                                                                                                                                                                                                                                       |
| `:hover`                                      | Kept, scoped                                                                                                                                                                        | Gone                                                                                                                                                                                                                                       |
| Conditional comments                          | Removed with their content (the `lte mso 11` block is gone); the content of `<!--[if !mso]><!-->` blocks stays                                                                      | Removed, as above                                                                                                                                                                                                                          |
| `role`, `aria-*`                              | Removed (R-DOC-10's wrapper roles, R-PRE-03's `aria-hidden`); `lang`/`dir` on the wrapper kept (R-DOC-02)                                                                           | Removed; `lang`/`dir` kept                                                                                                                                                                                                                 |
| `<body>`                                      | Becomes `div.rcmBody#message-htmlpart1` with the body's inline style (R-DOC-09, R-DOC-13 kept). **A `class` attribute on `<body>` replaces `rcmBody`** (see below)                  | Becomes `div.mail-body` with the body's inline style                                                                                                                                                                                       |
| Hidden elements                               | Kept (the preheader, R-PRE-01)                                                                                                                                                      | Elements hidden inline (`display:none`: the preheader and its padding) removed                                                                                                                                                             |
| Inline styles                                 | Kept, re-spaced (`a:b;` → `a: b`)                                                                                                                                                   | Re-serialised: colours as `rgb()`, `mso-*` and `-ms-*` declarations dropped                                                                                                                                                                |
| Images                                        | `src` kept and loaded (remote images allowed); `width` attribute kept; a 1×1 image is loaded                                                                                        | `src` kept and loaded (`view_images = always`); the `width` attribute becomes inline `width: 100%; max-width: {w}px`; `loading="lazy"` added; an image one pixel wide is hidden (`display: none`, `data-x-src-hidden`) and never requested |

<!-- markdownlint-enable MD013 -->

**The body class disables all head CSS in Roundcube.** The document
skeleton (catalogue §1) puts `class="body"` on `<body>`. Roundcube
turns `<body>` into its wrapper `div` with the class `rcmBody` and
scopes every head selector under `div.rcmBody`, but copies the
message's own `class` attribute over its own, so the wrapper is
`div.v1body` and no element matches `div.rcmBody`: none of the
scoped rules (responsive, dark, hover) can apply. Measured on the
probe in dark mode: the dark paragraph background (`#111827`) is not
painted; the same message with the class removed from `<body>` keeps
`div.rcmBody` and paints it (the test's control). Recorded as a
library issue rather than worked around here.

Since the skeleton dropped the body class (catalogue R-DOC-14), the
wrapper keeps `rcmBody` and the scoped rules apply; the test now
checks that directly and keeps the old failure as its control (the
same message with a body class added).

**SnappyMail's dark themes and uncoloured text.** In the dark theme,
text with no inline colour inherits the theme's light text colour
while the message keeps its white background: the receipt's
`Widget: $10.00` cell and the alert's heading and cell (no inline
colour) computed to `#ffffff` on the message's `#ffffff` and vanished
from the dark captures, while the inline-coloured receipt heading
stayed legible. This is what R-TXT-02 (inline `color` on every text
element) guards against; since every text element without a colour
gets inline the colour it would have inherited (the nearest coloured
ancestor's, else the theme's primary text colour), the dark captures
show the text (first review loop, rounds 1 and 2).

**With styles allowed.** SnappyMail has a per-user "allow styles"
setting (off by default, with no administrator default in 2.38.2);
its source namespaces kept selectors as `#rl-msg-{hash} .mail-body …`
and prefixes class names with `msg-`. Not captured here: the provider
renders the default.

**What this means for the transforms.** Roundcube confirms the
prefix-and-scope model (gmailWeb step 5, outlookWeb), with one
difference no transform models: scoping under a wrapper class that a
message's body class can remove. SnappyMail behaves like ganga (no
`<style>` at all) and additionally drops every class, so classes can
never carry layout there either: consistent with R-CSS-01 (correct
with every `<style>` removed). No transform step is changed by this
evidence.

## Real-client evidence: desktop clients

The `linux-desktop` provider's clients (Thunderbird 150, Evolution
3.58, Geary 46, KMail 6.7, Claws Mail 4.4) are real engines, so they
show what no backend-A transform models. Recorded from the first real
review loop over the seed stories (2026-10-01); each changed a library
rule, not a transform:

- **Thunderbird's `shrinktofit`.** Thunderbird marks message images
  `shrinktofit`, and its message stylesheet
  (`chrome://messagebody/skin/messageBody.css`) gives them
  `max-inline-size: … !important`. Measured on the live element over
  Marionette: the alert's 48 px image (`width:100%;max-width:48px`) had
  a computed `max-width` of 772px and rendered 772 px wide; with the
  attribute removed, 48px; with `width:48px;max-width:100%`, 48 px
  with the attribute in place. Backend A's `thunderbird` family is
  plain Firefox, which has no such stylesheet, so it showed 48 px
  throughout. Rule change: catalogue R-IMG-01 (a fixed-size image is
  `width:{w}px;max-width:100%`). No transform models the override yet;
  a fluid image (R-IMG-11, `width:100%;max-width:{w}px`) would meet it
  too.
- **litehtml (Claws Mail) has no `align` quirk and no bidi.** A block
  image under `align="center"` sat at the left edge, because the
  browser engines centre it only through a legacy mapping of `align`;
  rule change: catalogue R-IMG-01's alignment margin. Right-to-left
  words are laid out left to right (no bidirectional reordering);
  declared in Claws Mail's review brief, nothing the message can do.
- **WebKitGTK under a dark GTK theme (Evolution).** The message sees
  `prefers-color-scheme: dark`; with `color-scheme: light dark` the
  engine's default text colour turns light while the message's inline
  backgrounds stay white, so uncoloured text vanished. Rule change:
  catalogue R-TXT-02's default text colour.

## Real-client evidence (once backend B lands)

None yet. Each entry names the transform step, the backend-B/C/D
capture pair that contradicts it, and the rule change made.
