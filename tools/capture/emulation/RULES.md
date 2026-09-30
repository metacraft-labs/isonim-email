# Emulation-transform rules

Every correction learned from backends B/C/D is recorded in this file
with its screenshot pair: the backend-A emulation
that was wrong, the real-client capture that showed it, and the rule
change that fixed it. Until backend B lands, the citations below
rest on published behaviour only: the rules in
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

## outlookWeb (`outlookWeb.ts`, version 2)

`x_` prefix plus `rps_xxxx` wrapper (documented Outlook.com behaviour;
the wrapper class is measured against real clients later). Dark
recolours with the R-DRK-04 partial-inversion model — inline text
colours with luminance < 0.5 and inline or `bgcolor` backgrounds with
luminance > 0.5 get OKLCH lightness L → 1 − L, chroma and hue kept —
and marks each recoloured element with `data-ogsc`/`data-ogsb`
(R-DRK-03), so the message's own `[data-ogsc] …` rules apply over it.

## imagesOff (`imagesOff.ts`, version 2)

No catalogue rule; models images blocked by default: empty `img[src]`/`srcset`,
drop CSS `background-image`. `--images off` applies it after any
family's own transform, and blocks image requests to the fixture host.

## wordApprox (`wordApprox.ts`, version 2)

Lint-grade (emulation steps 1–5): reveal mso conditionals; strip
`max-width` (R-OL-03), `display:flex|grid|inline-block`, CSS
`background-image` (R-OL-11), `border-radius` (R-OL-12), `margin:auto`
(R-LAY-08) and non-`td`/`th` padding (R-OL-05, R-TBL-02); strip
`<style>` media queries (R-LAY-02 excludes outlookWord); stand VML
shapes in as flat labelled rectangles (R-VML-01/02); flatten `rgba()`
(R-CSS-14).

## Real-client evidence (once backend B lands)

None yet. Each entry names the transform step, the backend-B/C/D
capture pair that contradicts it, and the rule change made.
