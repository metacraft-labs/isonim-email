# IsoNim Email — Rendering Rules Catalogue

<!-- markdownlint-disable-file MD013 MD038 MD056 MD060 -->
<!-- Line length, code-span spacing, table shape and column style are
     intrinsic to this file: rule rows are machine-read one-per-line by
     tests/t1_rule_traceability.nim, and several code spans carry exact
     bytes (literal selector spacing, attribute padding). -->

> **Status:** Normative. This catalogue is the **exact behaviour** the
> implementation must produce. The rule-traceability test
> (`tests/t1_rule_traceability.nim`) reads it directly.
> **Last Updated:** 2026-10-04

This catalogue turns published HTML-email practice (RFCs, vendor
documentation, caniemail data, framework sources and community write-ups)
and client captures into rules an implementation agent can follow without
re-deriving them. When this file and any other source disagree, this file
wins. A disagreement found in code or in a capture is recorded here, with
its evidence.

## How to use this file

- **Rule IDs are stable.** Each rule has an ID such as `R-OL-07`. An ID is
  never reused; a rule that is withdrawn stays in the table marked ❌
  **withdrawn**, with its reason.
- **Traceability is enforced.** Every rule is implemented in the named
  module, and at least one test carries the rule's ID in a
  `# rule: R-OL-07` comment. The traceability test
  (`tests/t1_rule_traceability.nim`) parses this file and fails on any
  ID that no test names. Rules not yet covered by a test are listed in
  `tests/rules_pending.txt`; the list only shrinks.
- **Status** says how far a rule can be trusted:

  | Mark | Meaning | What the implementer does |
  |---|---|---|
  | ✓ | Verified: a primary source was read (RFC text, vendor docs, caniemail data, MJML/Cerberus source), or a capture proved it | Implement as written |
  | ◐ | Sourced: widely documented community practice, or a secondary source not read in full | Implement as written. The first real-client capture that exercises it (backend B/C/D) must confirm it or reopen it |
  | ☐ | Unverified: from recollection, or the sources disagree | Implement behind the named flag or as written. The rule's owner **must** settle it with backend C/D evidence before it is marked ✓ |

- **Families** use the client-family IDs. `all` means every family.
- **Where** names the pass (`P1`–`P12`) or the lowering module
  (`lower/…`, `mso/…`) that owns the rule.
- **Sources** name the evidence directly: an RFC, a vendor document, a
  caniemail feature file, framework source (MJML, Cerberus, Maizzle), or
  a named community article or bug report. `(read)` means the source was
  read in full; `(via search)` means only a search summary was seen;
  `inference` and `design rule` mark rules derived here rather than
  taken from a source.

A rule's **fix** is part of the rule. Anything that emits the fixed
construct differently violates it, even if the output looks right in one
client.

---

## 1. DOC — Document skeleton

The exact skeleton that `lower/document.nim` emits. `{…}` are values.
Lines marked `⟪mso⟫` are emitted only when `EmailTarget.outlookWord`.

```html
<!doctype html>
<html lang="{lang}" dir="{dir}" xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=yes">
<!--[if !mso]><!--><meta http-equiv="X-UA-Compatible" content="IE=edge"><!--<![endif]-->
<meta name="format-detection" content="telephone=no, date=no, address=no, email=no, url=no">
<meta name="x-apple-disable-message-reformatting">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>{title}</title>
⟪mso⟫<!--[if mso]><noscript><xml><o:OfficeDocumentSettings><o:AllowPNG/><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript><![endif]-->
<style>{block 1: reset}</style>
<style>{block 2: responsive}</style>
<style>{block 3: dark}</style>
<!--[if !mso]><!--><style>{block 4: fonts}</style><!--<![endif]-->
<style>{block 5: decorative}</style>
<style>{block 6: Thunderbird}</style>
⟪mso⟫<!--[if mso]><style>{mso block}</style><![endif]-->
⟪mso⟫<!--[if lte mso 11]><style>.e-mso-group-fix{width:100% !important;}</style><![endif]-->
</head>
<body xml:lang="{lang}" style="margin:0;padding:0;word-spacing:normal;background-color:{bg};">
{preheader — §9}
<div role="article" aria-roledescription="email" aria-label="{title}" lang="{lang}" dir="{dir}" style="background-color:{bg};font-size:medium;font-size:max(16px, 1rem);">
<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="background-color:{bg};table-layout:fixed;">
<tr><td align="center">{sections}</td></tr>
</table>
</div>
</body>
</html>
```

| ID | Rule | Where | Families | Source | Status |
|---|---|---|---|---|---|
| R-DOC-01 | The doctype is exactly `<!doctype html>`. | lower/document | all | MJML skeleton.js; Good Email Code template (read) | ✓ |
| R-DOC-02 | `lang` and `dir` MUST appear on `<html>` **and** on the article wrapper `div`, because clients strip them from `<html>`. `xml:lang` is also on `<body>`. | lower/document, P7 | all | Email Markup Consortium Accessibility Report 2026 (read) | ✓ |
| R-DOC-03 | `<meta charset="utf-8">` is present, and the MIME part also declares `charset=utf-8` (R-MIME-06). | lower/document | all | Good Email Code template (read) | ✓ |
| R-DOC-04 | The viewport meta keeps `user-scalable=yes`. Zoom must never be disabled. | lower/document | apple, gmailApp, samsung | Good Email Code template (read) | ✓ |
| R-DOC-05 | `format-detection` disables telephone, date, address, email and url detection. It is paired with R-TXT-06. | lower/document | apple | Cerberus (read) | ✓ |
| R-DOC-06 | `x-apple-disable-message-reformatting` is always present. The email must therefore be responsive on its own (§4). | lower/document | apple | Good Email Code template (read) | ✓ |
| R-DOC-07 | The `color-scheme` / `supported-color-schemes` metas are emitted only when `darkMode != none`. | lower/document | apple, outlookApp | Good Email Code template; Cerberus (read) | ✓ |
| R-DOC-08 | ⟪mso⟫ `OfficeDocumentSettings` with `AllowPNG` and `PixelsPerInch 96` sits inside `<noscript>` inside `<!--[if mso]>`. The `noscript` wrapper keeps the XML from leaking into non-Outlook clients. | mso/document | outlookWord | MJML skeleton.js (read); noscript rationale ◐ | ✓ |
| R-DOC-09 | The background colour appears in three places: `<body>` style, the article wrapper `div`, and the 100%-width wrapper table. Gmail and Yahoo drop `<body>` styles. The wrapper table's `table-layout:fixed` is R-TBL-17's (the reset's, inline). | lower/document | gmail*, yahoo | Cerberus (read) | ✓ |
| R-DOC-10 | The wrapper has `role="article"`, `aria-roledescription="email"`, and `aria-label` = document title. | lower/document, P7 | all | Good Email Code template; Email Markup Consortium Accessibility Report 2026 (read) | ✓ |
| R-DOC-11 | The wrapper's font size is `font-size:medium; font-size:max(16px, 1rem)`: two declarations, the second overriding where supported. It respects the reader's text size. | lower/document | all | Good Email Code template (read) | ✓ |
| R-DOC-12 | `<style>` elements appear in `<head>` only, in the block order above, and before any element that uses their classes (Outlook requires declaration before use). | P6 | gmail*, outlookWord | caniemail html-style notes 1, 4 (read) | ✓ |
| R-DOC-13 | `<body>` carries `word-spacing:normal`, because MJML found inline-block whitespace artefacts without it. | lower/document | all | MJML skeleton.js ◐ (no second source) | ☐ (to be settled by a real-client capture) |
| R-DOC-14 | `<body>` carries no `class` attribute. Roundcube turns `<body>` into its message wrapper `div.rcmBody` and scopes every head selector under `div.rcmBody`, but copies the message's own body attributes over its own, so a body `class` replaces `rcmBody` and no head rule (responsive, dark, hover) can match. No rule selects the body by class; the reset selects the element, and so does block 3's dark background for the page below the message (R-DRK-02). | lower/document | all | capture: Roundcube 1.6.15 (selfhosted-webmail), the body class removed restores the scoped rules (`tools/capture/emulation/RULES.md`) | ✓ |

## 2. RST — Reset block (head block 1)

This is the exact content of block 1, taken from the Cerberus and MJML
resets. Each line is its own rule, so that a capture can
withdraw one without touching the others. Serialisation is minified by the
CSS serialiser. It is shown expanded here for review.

The block is emitted **verbatim, in the order printed here**: the rule
order and the declaration order inside each rule are both this table's.
R-CSS-16's sorting applies to generated rules only. When two rules of
equal specificity set the same property on the same element, the later
one wins in every client, so the order of a hand-curated reset is part
of its meaning. These lines reproduce the order in which their sources
ship and were checked. A line added later is placed where its source
puts it, and does not go in sorted position.

```css
html,body{margin:0 auto !important;padding:0 !important;height:100% !important;width:100% !important;}
*{-ms-text-size-adjust:100%;-webkit-text-size-adjust:100%;}
div[style*="margin: 16px 0"]{margin:0 !important;}
#MessageViewBody,#MessageWebViewDiv{width:100% !important;}
table,td{mso-table-lspace:0pt !important;mso-table-rspace:0pt !important;}
table{border-spacing:0 !important;border-collapse:collapse !important;table-layout:fixed !important;margin:0 auto !important;}
img{-ms-interpolation-mode:bicubic;border:0;height:auto;line-height:100%;outline:none;text-decoration:none;}
a{text-decoration:none;}
#outlook a{padding:0;}
a[x-apple-data-detectors],.unstyle-auto-detected-links a,.aBn{border-bottom:0 !important;cursor:default !important;color:inherit !important;text-decoration:none !important;font-size:inherit !important;font-family:inherit !important;font-weight:inherit !important;line-height:inherit !important;}
.im{color:inherit !important;}
.a6S{display:none !important;opacity:0.01 !important;}
img.g-img+div{display:none !important;}
```

| ID | Rule | Families | Source | Status |
|---|---|---|---|---|
| R-RST-01 | `html,body` margin/padding/height/width reset | all | Cerberus (read) | ✓ |
| R-RST-02 | `-ms-text-size-adjust` / `-webkit-text-size-adjust:100%` on `*` stops small-text resizing | apple, outlookWord | Cerberus, MJML (read) | ✓ |
| R-RST-03 | `div[style*="margin: 16px 0"]` fix (Android 4.4 centring) | legacy Android | Cerberus (read) | ✓. It stays while the size budget allows; it is the first candidate to drop. |
| R-RST-04 | `#MessageViewBody,#MessageWebViewDiv{width:100%}` | samsung | Cerberus (read) | ✓ |
| R-RST-05 | `mso-table-lspace/rspace:0pt` on `table,td` removes Outlook table gaps | outlookWord | MJML, Cerberus (read) | ✓ |
| R-RST-06 | `table{border-spacing:0;border-collapse:collapse;table-layout:fixed;margin:0 auto}` | all | Cerberus (read) | ✓ |
| R-RST-07 | `img` reset (bicubic, border 0, height auto, line-height 100%) | all | MJML skeleton (read) | ✓ |
| R-RST-08 | `#outlook a{padding:0}` | outlookWeb (legacy) | MJML skeleton (read) | ✓ |
| R-RST-09 | Auto-detected link neutralisation: `a[x-apple-data-detectors]`, `.aBn`, `.unstyle-auto-detected-links a` | apple, gmail* | Cerberus (read) | ✓ |
| R-RST-10 | `.im{color:inherit}` stops Gmail recolouring text in threads | gmail* | Cerberus (read) | ✓ |
| R-RST-11 | `.a6S` and `img.g-img+div` hide Gmail's image download button | gmailWeb | Cerberus (read) | ✓ |
| R-RST-12 | Attribute selectors in block 1 (R-RST-03, -09, -11) are ignored by Gmail but harmless. They MUST NOT be placed in any block whose loss would matter, because Gmail may treat unsupported selectors as a reason to drop the block. | gmail* | Google, Gmail CSS support: "might ignore unsupported CSS properties and selectors" (read) | ◐ to be confirmed on backend B: block 1 survives in Gmail with these selectors present |
| R-RST-13 | `a{text-decoration:none;}`: reset line 8. Link decoration is then set inline per R-TXT-04; the reset removes client defaults in clients that honour head CSS (Cerberus notes that Windows 10 Mail needs it) | all | Cerberus (read) | ✓ |

## 3. CSS — Emitting CSS

| ID | Rule | Where | Families | Source | Status |
|---|---|---|---|---|---|
| R-CSS-01 | **Inline first.** Every declaration that can be expressed on an element is emitted inline in `style=""`. Head CSS is progressive enhancement: the message MUST be correct and readable with every `<style>` removed. | P5 | ganga (no `<style>` at all) | caniemail html-style note 2 (read) | ✓ |
| R-CSS-02 | Only these go to the head: `@media` rules (responsive, dark), pseudo-classes (`:hover`), client-targeting selectors (§2, R-DRK-03, R-LAY-12, R-DRK-08), `@font-face`. Nothing else. | P6 | all | caniemail html-style notes (read); MJML and Maizzle inlining practice | ✓ |
| R-CSS-03 | Head rules that must beat inline styles carry `!important`, always written in **lower case**. An uppercase `!IMPORTANT` makes Gmail drop the whole block. | P6, style/css | gmail* | hteumeuleu/email-bugs #13 | ◐ |
| R-CSS-04 | **No nested at-rules.** `@font-face` and `@import` never appear inside `@media`, and `@media` is never nested. Violating this makes Gmail remove the whole block. | style/css | gmail* | hteumeuleu/email-bugs #21 | ◐ |
| R-CSS-05 | The CSS serialiser only emits syntactically valid CSS: balanced braces, no empty declarations, every property name in the known-property table. Values, selectors and queries never contain `<` (so no `</style>` can close the element early), comment delimiters (`/*`, `*/`), backslashes, or unbalanced quotes or parentheses. A syntax error makes Gmail drop the whole block. | style/css | gmail* | Email on Acid, "12 things you must know when developing for Gmail" (read) | ✓ |
| R-CSS-06 | Colour values have no whitespace-separated syntax (`rgb(0 0 0)` is forbidden; use hex, or `rgba(0,0,0,.5)`). | style/colors | gmail* | hteumeuleu/email-bugs #160 | ◐ |
| R-CSS-07 | Total head CSS stays ≤ `headStyleBudget` (15,000 bytes; Gmail's limit is 16 KB of combined `<style>` content). Blocks are separate `<style>` elements in priority order, so that Gmail's cut loses only the lowest-priority block. When over budget, whole blocks are dropped from the lowest priority up (decorative, fonts, dark), each with a diagnostic. Reset and responsive are never dropped, nor is Thunderbird's one-rule block (R-DRK-08), which counts towards the total. If they alone still exceed the budget, P6 emits `W-CSS-OVER-BUDGET` (an error under `strict`), because Gmail will truncate them. | P6 | gmail* | hteumeuleu/email-bugs #90 (read); older sources (Email on Acid) say 8,192 chars | ✓ for 16 KB; the 8,192-char figure is treated as historical |
| R-CSS-08 | Class names match `[a-z][a-z0-9-]*`: no escapes, no `:` `/` `.` `\`. Tailwind-style names are never emitted. Names are generated (`e-` + base36 hash of the variant and the declaration set, shortest unique prefix ≥ 3 characters) and deterministic. The variant (`sm`, `dark`, `hover`) is part of the hash input, so the same declarations under two variants get two classes and a rule never applies to another variant's element. | style/classes | gmail* | Maizzle safeClassNames transformer docs | ◐ |
| R-CSS-09 | Selectors in head blocks use only class, element and ID selectors, apart from the fixed client-targeting set (R-RST-03/08/09/11, R-DRK-03, R-LAY-12, R-LAY-13). The fixed set is a closed list of literal selectors (`div[style*="margin: 16px 0"]`, `#outlook a`, `a[x-apple-data-detectors]`, `.aBn`, `.unstyle-auto-detected-links a`, `.a6S`, `img.g-img+div`, `[data-ogsc] …`, `[data-ogsb] …`, `.moz-text-html …`, `[owa] …`, and R-DRK-08's `html:has(.moz-text-html)` and `body:has(.moz-text-html)`); the serialiser admits exactly these. Gmail supports "class, element, and ID selectors". | style/css | gmail* | Google, Gmail CSS support (read) | ✓ |
| R-CSS-10 | `@media` queries use only the `screen` type (or `only screen`) and the features `min-width`/`max-width`, plus `prefers-color-scheme` in the dark block. Height, orientation and resolution features are not used. This is the intersection that Gmail (width features only) and Yahoo/AOL (screen + width/height) support. | P6 | gmail*, yahoo | Google, Gmail CSS support; caniemail css-at-media notes 2, 7 (read) | ✓ |
| R-CSS-11 | CSS custom properties (`var()`, `--x`) are never emitted. | P5 | gmail*, outlook*, yahoo | caniemail css-variables (read) | ✓ |
| R-CSS-12 | Colours are 6-digit lower-case hex in both CSS and HTML attributes (`bgcolor`). 3-digit hex and named colours are converted. Some clients reject 3-digit hex in attributes. | style/colors | outlookWord | Maizzle sixHex transformer docs | ◐ |
| R-CSS-13 | Lengths are px for box properties, `font-size` and `line-height`; `%` for widths only. `rem`/`em` are converted with a 16px root. Unitless numbers from the Tailwind extractor get `px` restored from the extractor's unit record. | style/units | outlookWord | Cerberus; caniemail Outlook notes (read) | ✓ |
| R-CSS-14 | Semi-transparent colours: when the family set includes `outlookWord`, the opaque blend against the resolved background colour is emitted first, followed by `rgba()` for the others (`color:#7f7f7f;color:rgba(0,0,0,.5)`); without it, `rgba()` alone. A background blends over what is behind its element, a text or border colour over its element's background. The pair is an R-CSS-19 fallback pair on the HTML element that carries it (a cell's `bgcolor` is the blend); a vocabulary element, whose lowering paints its own markup, and a head declaration (which Word never reads) carry the blend alone. | P5, style/colors | outlookWord | inference (Word ignores rgba) | ☐ (to be settled by a Word-engine Outlook capture) |
| R-CSS-15 | Any rule in the head that exists only to override an inline value (responsive or dark) is paired with a **class** on the element. Selectors never depend on the element's position or on inline style content. | P6 | all | inference, from R-CSS-09 | ✓ (design rule) |
| R-CSS-16 | Declarations inside a generated rule are sorted by property name, and generated rules by selector, both deterministically. A shorthand always precedes its own longhands (`border`, then `border-top` and `border-color`, then `border-top-color`), so sorting never lets a shorthand override a longhand written to refine it. Sorting generated rules is cascade-safe, because each element gets at most one generated class per variant. The reset block (§2) is not generated: it is emitted verbatim in the catalogue's order (§2 explains why). | style/css | — | design rule: byte-identical output for the same input | ✓ (design rule) |
| R-CSS-17 | `!important` is stripped by Gmail when images are off (email-bugs #70). No rule may depend on `!important` for **legibility**; it may only depend on it for layout improvement. | P6 | gmail* | hteumeuleu/email-bugs #70 | ◐ (to be confirmed by a real-client capture) |
| R-CSS-18 | In the "View entire message" window of a clipped email, Gmail removes all `<style>` (email-bugs #56). A clipped message is therefore also style-less, which is one more reason for R-SIZE-01. | — | gmailWeb | hteumeuleu/email-bugs #56 (read) | ✓ |
| R-CSS-19 | **Fallback pairs.** Where a declaration needs a value some clients reject (a CSS function they lack), the inline style carries the property twice, the fallback first: `width:calc(…);width:max(…)`. A client that rejects the second keeps the first; one that understands both takes the second. Both stay at the property's place among the element's declarations, in that order. A style table holds one value per property, so lowering sets the pair with `setStyleWithFallback` and only the serialiser writes the fallback; nothing reorders or deduplicates inline declarations (R-CSS-16 sorts generated head rules only). Used by the document wrapper's font size (R-DOC-11, `font-size:medium;font-size:max(16px, 1rem)`) and the Fab Four width (R-LAY-18). R-CSS-14's colour pair is the same shape. | lower/*, serialize | all | caniemail css-function-max: Fastmail and Outlook.com have no `max()`, Fastmail keeps `calc()` (read); capture of SnappyMail 2.38 and Roundcube 1.6, 2026-10-02 | ✓ |

## 4. LAY — Layout (sections, columns, groups)

This is MJML's algorithm (from `mjml-section`, `mjml-column` and
`mediaQueries.js`, read) with Cerberus's hybrid fallback.

### 4.1 Width computation (P3)

```text
containerWidth W        = EmailTarget.containerWidth (default 600) or mailDocument(width)
section box B           = W − paddingLeft − paddingRight − borderLeft − borderRight
column width, % given   = colPct
column width, px given  = colPx
column width, omitted   = 100 / (number of non-raw siblings) %
column px (Outlook)     = colPx, or round(colPct/100 · B)
column box              = colPct/100 · B (or colPx) − column paddingL/R − borders, truncated (child context)
group                   = like a section inside a column: its B is the group's exact width less its padding
content in a section    = an implicit single column with the default column padding
mailColumns row         = B is the content box the row sits in; its columns' padding defaults to none
gutter g (n columns)    = desktop class width = colPct − (g/B·100)·(n−1)/n  (% columns)
                          desktop class width = colPx − g·(n−1)/n, floored, the remainder to the first columns (px columns)
                          half-gutters: ceil(g/2) on the leading inner side, floor(g/2) on the trailing one, none outside
                          Outlook cell = the full column px (unchanged), the half-gutters as its padding
```

- Rounding follows MJML 5 (`mjml-column` `getWidthAsPixel`): each
  column's px width is rounded on its own, so the px widths of a row may
  sum to `B` ± 1 per column (thirds of 590 are 197 each, 591 in all);
  no remainder is moved onto the last column. Word stretches or shrinks
  the fixed-width ghost row by that pixel.
- Lengths are whole px: padding and border widths truncate, as MJML's
  `parseInt` does. A column's box truncates; a group's box keeps its
  fraction, and its columns take their percentage of that.
- Percentages are read as authored, at full precision (the inline
  `width` is normalised to two decimals later, but the width maths never
  reads it). Class names normalise them to at most 6 decimals, trailing
  zeros stripped (R-LAY-03).
- A section holds either columns or content, never both (`E-STRUCT-NESTING`).
- A section's own columns are a gutterless row, MJML's model (column
  padding `0 24px` by default). A `mailColumns` row sits in content (a
  section's implicit column, a column, a stack) and spaces its columns
  with its gutter (24px by default), MJML 5's `mj-section gutter`
  (`mjml-column` `getDesktopWidth`, `getDesktopPaddingValues`, read):
  the desktop class width loses each column's share of the gutters, a
  px row hands the rounding remainder to its first columns one pixel
  each (`floor` plus `round(n · fraction)` extra pixels), and the
  Outlook cell keeps the full width with the half-gutters as padding.
- These numbers are checked against the pinned MJML's output by
  `just test-conformance`.

### 4.2 Rules

| ID | Rule | Where | Families | Source | Status |
|---|---|---|---|---|---|
| R-LAY-01 | **Mobile-first hybrid column** (`strategy = hybrid`, and a section's own columns). The column is `<div class="e-col-… [e-gutter-…]" style="display:inline-block;width:100%;vertical-align:{va};[padding-top:{g}px;]font-size:16px;text-align:{align};direction:{dir};"><div style="padding:{colPad};[background-color:{bg};][border-radius:{r};]">content</div></div>`. There is no table inside the column (div-first) and no inline `max-width` (MJML's column has none): clients with no `<style>` get stacked full-width columns, which is safe, and the desktop width comes only from the head media query (R-LAY-02). `{align}` is the start of the column's direction. The inner div is omitted when the column carries no padding, background, border, radius or class; a border is drawn by a frame Word does not see, as a section's (R-LAY-08). `padding-top:{g}px` is the stacked gap of a gutter row (R-LAY-14), on every column but the first; a column with a gutter class also has `box-sizing:content-box` after its width, because the class pads it outside its width and a client stylesheet that makes every box `border-box` (Roundcube's) would take the padding out of the width. A row whose columns do not stack (`mailSection(stack = never)`) keeps each column's desktop width inline instead of 100%. | lower/column | all | mjml-column source (read); div-first per goodemailcode.com columns and Blocks Edit, "No more tables for email" (read) | ✓ structure; ◐ div-first inner padding (to be confirmed by a Word-engine Outlook capture) |
| R-LAY-02 | The responsive block opens with one `@media only screen and (min-width: {breakpoint}px){…}` holding, per distinct column class, `.{cls}{max-width:{w};width:{w} !important}` (`{w}` the desktop class width, % or px, after the gutter share of R-LAY-14) and, per gutter class, `.{cls}{padding:{gutter} !important}`. Declarations are sorted (R-CSS-16). The breakpoint defaults to 480. The `max-width` query that follows holds the stacked state: `cellsStacking` cells and gaps (R-LAY-19), the Fab Four gap (R-LAY-18) and the `sm:` variants. | P6 | all except ganga, outlookWord | MJML mediaQueries.js and mjml-core addMediaQuery (read); 480 ◐ | ✓ |
| R-LAY-03 | Column class names are `e-col-{pct}` with `.` replaced by `-` (e.g. `e-col-33-333333`), or `e-colpx-{n}` for px columns, named after the desktop class width (so a gutter row's `e-col-47-826087`). Gutter classes are `e-gutter-{n}-{i}-{per\|px}-{g}` (`n` columns, the `i`th from 1, the gutter in the columns' unit, `-rtl` appended in a right-to-left row; MJML's `mj-column-gutter-…`). The stacked-state helpers are `e-cells-stack`, `e-cells-gutter` and `e-stackpad-{t}-{r}-{b}-{l}` (the padding a cell or a Fab Four gutter `div` takes once stacked). All are deduplicated across the document. | style/classes | — | mjml-column class naming (read) | ✓ |
| R-LAY-04 | The element that contains inline-block columns (the section's inner div, a `mailColumns` row's `div`, a group, a Grid or a Cluster parent) has a zero font size, written `font-size:0.01px`. Each column or item resets `font-size` (16px default) on its own div. Not `0`: WebKitGTK 2.52 (Evolution 3.58, Geary 46) renders no message that holds a box whose font-size is exactly zero (MJML's `font-size:0px` included), and the WebKit build of the capture tooling crashes on one; a hundredth of a pixel lays out the same everywhere captured. Residual risk (P3, not observed): a reader's minimum font size setting (Firefox, Chromium, Thunderbird) exempts `0` but applies to `0.01px`, so such a reader can see a whitespace-sized gap (a strut) between inline-block columns or under images. | lower/section, lower/column | all | Cerberus hybrid template; MJML (read); capture of Evolution and Geary, 2026-10-02 | ✓ |
| R-LAY-05 | **Nothing between inline-block siblings**: no whitespace or text nodes between column `div`s, including across the ⟪mso⟫ conditional comments that separate them. | serialize | all | MJML and Cerberus inline-block practice (read) | ✓ |
| R-LAY-06 | ⟪mso⟫ Section ghost table (div-first): `<!--[if mso]><table role="presentation" align="center" border="0" cellpadding="0" cellspacing="0" width="{W}" style="width:{W}px;"><tr><td bgcolor="{bg}" style="padding:{pad};background-color:{bg};"><![endif]-->` before the section `div`, and `<!--[if mso]></td></tr></table><![endif]-->` after it. The cell carries the section's padding and background (R-TBL-02), its border (`border:{border};` after the background), and, when the section is not left-aligned, `align="{align}"` after `bgcolor` and `text-align:{align};` last (R-TBL-14). Attributes and declarations without a value are omitted (no `bgcolor` without a background). | mso/ghost | outlookWord | goodemailcode.com container (read) | ✓ |
| R-LAY-07 | ⟪mso⟫ Multi-column ghost row, inside the row's container (the section's inner div, the `mailColumns` div, a group): `<!--[if mso]><table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%"><tr><td valign="{va}" width="{colPx}" style="width:{colPx}px;vertical-align:{va};"><![endif]-->` before the first column; `<!--[if mso]></td><td …><![endif]-->` between columns; `<!--[if mso]></td></tr></table><![endif]-->` after the last. The table fills its box (the cells carry the px widths, as MJML's auto-width row does); `dir="rtl"` follows `width` in a right-to-left row, and a group's row carries `bgcolor` before it. The cells carry **no padding**: a cell's `width` does not include its padding in every engine, so a padded fixed-width cell can overflow its row (Cerberus and Foundation pad a table inside the cell for the same reason). What Word must honour of the column (R-TBL-02) goes on single-cell tables inside the cell instead: `<!--[if mso]><table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0"><tr><td style="padding:{pad};"><![endif]-->` … `<!--[if mso]></td></tr></table><![endif]-->` with `{pad}` the half-gutters (R-LAY-14) plus the column's padding; a column with a background or a border puts its padding in a second one inside, `<td bgcolor="{bg}" style="padding:{colPad};background-color:{bg};border:{border};">`, so its background stays out of the gutter. A column aligned `center` or `right` puts `align` and `text-align` on the innermost of them (R-TBL-14). With no row cell padded, Word has no vertical padding to equalise (R-TBL-03). Grids chunk the row into rows of N (`<!--[if mso]></td></tr><tr><td …><![endif]-->`), a cell per slot `width="{w}"` (the item's width plus the gutter it carries); an incomplete last row is padded with sized spacer cells (R-TBL-05), or, when it is centred or stretched, gets a ghost table of its own (`align="center"`, or `width="100%"` with the stretched widths). | mso/ghost | outlookWord | mjml-section and mjml-group source; Foundation block-grid (read) | ✓ |
| R-LAY-08 | Section (non-MSO): `<div style="margin:0 auto;max-width:{W}px;background-color:{bg};"><div align="{align}" style="padding:{pad};font-size:{fs};text-align:{align};direction:{dir};">…</div></div>`. A single-column section has no column scaffolding: column padding merges into the inner div and the MSO cell (section `24px 0` plus column `0 24px` gives `24px`), and `{fs}` is the column's own reset, `16px`; a section that holds inline-block columns has the zero font size, written `font-size:0.01px` (R-LAY-04). Content placed directly in a section is that single column, with the default column padding. `{align}` defaults to the start of the direction (left for `ltr`, right for `rtl`); `{dir}` defaults to the document's and is omitted for `auto`. A radius goes on the outer div (`border-radius:{r};` last) and on the border frame. A border is drawn by a frame `div` between the two that Word does not see: `<!--[if !mso]><!--><div style="border:{border};border-radius:{r};"><!--<![endif]-->` … `<!--[if !mso]><!--></div><!--<![endif]-->` (a plain `div` when `outlookWord` is off); Word draws the border on the ghost cell, and its div borders are unreliable (caniemail css-border note 2). Centring in Word comes from `align="center"` on the ghost table (R-LAY-06), never from `margin:auto` alone. No class is emitted: no rule targets the section. **Content placed directly in a `mailDocument`** (outside any band: a section, a wrapper, a hero, a conditional or `mailRaw`; a stray column or group stays where it is, for its nesting error) is an implicit section with the section defaults: each run of consecutive loose children is wrapped in one, after pattern expansion and before layout. A pattern is classified by the root of its expansion: one that expands to a band stays a top-level band, one that expands to loose content is wrapped. P1 reports a section inside a section, or a wrapper inside a band, as `E-STRUCT-NESTING` (R-LAY-16), also when a pattern element sits between them. Without a band the content sits flush against the reading pane, where a heading whose glyphs reach above its line box loses its tops (WebKit draws a 28px heading at a 36px line height about 2px above its box). | lower/section | all | goodemailcode.com container; caniemail css-margin note 4 (read) | ◐ (to be confirmed by a Word-engine Outlook capture) |
| R-LAY-09 | `full_width` section: an outer `<div style="background-color:{bg};">` plus ⟪mso⟫ `<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0"><tr><td bgcolor="{bg}" style="background-color:{bg};">` around the section (closed like a ghost table). The inner container is unchanged. | lower/section | all | mjml-section full-width; Cerberus full-bleed section (read) | ✓ |
| R-LAY-10 | **Group** (`mailGroup`): columns inside keep their desktop percentage on mobile. Their inline width is the percentage, not 100% (their class rule restates the same width, as MJML's does). The group itself is one inline-block, `width:100%` inline with its own column class for the desktop, `font-size:0.01px` (R-LAY-04), its background, and the `e-mso-group-fix` class (R-DOC, `lte mso 11`); Word gets a ghost row of its own inside the group's ghost cell (R-LAY-07). | lower/column | all | mjml-column getMobileWidth, mjml-group source (read) | ✓ |
| R-LAY-11 | **Mobile reversal** (`reverse_on_mobile`, on a section's own columns or a `mailColumns`): the row runs right to left, so only the desktop order flips — the section's inner div or the row's div gets `dir="rtl"` and `direction:rtl`, its ghost table or cell table `dir="rtl"` — and every column gets `dir="ltr"` and `direction:ltr` back. Authoring order stays the mobile order and the reading order for screen readers and the text part. Allowed only when at most one column holds text (the moved column is an image or decoration) and only in a left-to-right row; otherwise P1 reports `E-LAYOUT-REVERSE-TEXT`. A `cells` row never stacks, so reversing it is `E-VOCAB-BAD-VALUE`. | lower/column, P1 | all | Cerberus `dir="rtl"` reversal; Litmus, "Mobile responsive email stacking" (read) | ◐ (verified on the browser engines, the self-hosted webmails and the desktop clients; Word-engine Outlook to confirm) |
| R-LAY-12 | Thunderbird copy: when `thunderbirdMq`, every rule of R-LAY-02's `min-width` query (column widths and gutters) is duplicated with the selector prefixed by `.moz-text-html `, **outside** the query, after it (before the OWA copies). Thunderbird applies no `@media` rule in a message (caniemail css-at-media: no; a Thunderbird 150 capture stacked a hybrid row at 800 px with the copy inside the query) and is a desktop client, so the copy forces desktop widths; MJML 5 puts it in a `<style media="screen and (min-width:…)">` of its own. Rules of the `max-width` query and `sm:` variants are never copied. | P6 | thunderbird | MJML mediaQueries.js (read); caniemail css-at-media (read); capture of Thunderbird, 2026-10-02 | ✓ |
| R-LAY-13 | OWA copy: when `owaDesktop`, every rule of R-LAY-02's `min-width` query is duplicated with the selector prefixed by `[owa] ` and placed **outside** the media query, after it. OWA ignores the query, so this forces desktop widths. Rules of the `max-width` query and `sm:` variants are never copied: outside the query they would give OWA's desktop the phone layout. | P6 | outlookWeb | MJML mediaQueries.js, forceOWADesktop (read) | ✓ |
| R-LAY-14 | Gutters follow MJML 5's model (`mj-section gutter`), mobile first. Inline, the stacked state: every column but the first has `padding-top:{g}px` (MJML splits it into % halves above and below; the gap is the same). The desktop gutter class (R-LAY-03) under the `min-width` query sets `padding:0 {right} 0 {left} !important`: half a gutter on each inner side, `ceil(g/2)` on the leading side and `floor(g/2)` on the trailing one in px rows (in % of the row box, `g/B·100/2` each, in % rows), none on the row's outer edges, mirrored in a right-to-left row. The desktop class width loses the column's gutter share (§4.1). Word's ghost cells keep the full column width and take the px half-gutters as padding (R-LAY-07). Without CSS the columns stack with their gaps, which is the stacked design. A section's own columns have no gutter; `mailColumns` defaults to 24px. Cell rows put the gutter in a cell of its own (R-LAY-19, R-LAY-20); the Fab Four keeps half-gutters inside each column (R-LAY-18). | lower/column, P3, P6 | all | mjml-column getDesktopWidth, getDesktopPaddingValues, getMobileGutterStyles, getOutlookGutterStyles (read) | ✓ |
| R-LAY-15 | Every layout `<table>` has `role="presentation"`, `border="0"`, `cellpadding="0"`, `cellspacing="0"`, and an HTML `width` attribute alongside CSS width (R-OL-09). | P7, lower/* | all | Email Markup Consortium Accessibility Report 2026; Cerberus (read) | ✓ |
| R-LAY-16 | Max nesting: `mailSection` cannot nest in `mailSection` (use `mailWrapper`); `mailColumn` only in `mailSection`/`mailGroup`/`mailColumns`; `mailGroup` only in `mailSection`. These are compile-time errors. | vocabulary | — | MJML structure (read) | ✓ |
| R-LAY-17 | `mailWrapper` gives several sections one shared background, padding and border. It lowers like a section (R-LAY-06, R-LAY-08: ghost table, outer div, inner div carrying only the padding, the border frame), its inner div holding sections. Its inner sections use `W − wrapper padding − wrapper borders` as their container width, so their own ghost tables are that wide, nested in the wrapper's ghost cell. A wrapper has no default padding. | lower/wrapper | all | MJML mj-wrapper docs | ✓ |
| R-LAY-18 | **Fab Four row** (`strategy = fabFour`): each column is `<div style="display:inline-block;vertical-align:{va};width:calc(({bp}px - 100%) * {bp});width:max({w}, calc(({bp}px - 100%) * {bp}));min-width:{w};max-width:100%;font-size:16px;text-align:{align};direction:{dir};">`, `{w}` its desktop width (% or px). Above `bp` the `calc` is negative and the lower bound wins (side by side); below it, it is huge and `max-width` wins (stacked). The threshold is the row's own width, not the viewport, and no media query is needed, so the row switches even where the head CSS is lost, as long as the client keeps `calc`: Outlook for Windows and Outlook.com do not (caniemail `css-unit-calc`), so there the columns size to their content between `min-width` and 100%. The width is a fallback pair (R-CSS-19): the `max()` form carries the lower bound itself, so a sanitiser that removes `min-width` but keeps `calc()` and `max()` (SnappyMail 2.38) still lays the columns side by side on a wide screen and stacks them on a narrow one; a client without `max()` keeps the bare `calc()` form and its `min-width`. Half-gutters sit in a `div` inside the column, `<div class="e-stackpad-{g}-0-0-0" style="padding:0 {right} 0 {left};">` (`e-stackpad-0-0-0-0` on the first column); under the `max-width` query that class turns them into the top gap. Without CSS they stay, offsetting stacked columns by half a gutter: a declared degradation. Word gets the ghost row (R-LAY-07). | lower/column, P6 | all | Rémi Parmentier, "The Fab Four technique to create responsive emails without media queries" (2016, via search); Mosaico (via search); caniemail css-unit-calc, css-function-max (read); capture of SnappyMail 2.38 (side by side on desktop, stacked on mobile) and Roundcube 1.6 (unchanged), 2026-10-02 | ◐ (verified on the browser engines, the self-hosted webmails and the desktop clients; hosted webmail to confirm) |
| R-LAY-19 | **Stacking cell row** (`strategy = cellsStacking`): `<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="table-layout:fixed;"><tr><td class="e-cells-stack [e-stackpad-…]" [bgcolor] valign="{va}" width="{w}" style="width:{w};padding:{colPad};vertical-align:{va};[background-color;][border;][border-radius;]font-size:16px;text-align:{align};direction:{dir};">…</td>…</tr></table>`, `{w}` the desktop width less the gutter share (§4.1); a column aligned `center` or `right` adds `align` after `width` (R-TBL-14). Cells give equal heights and vertical centring everywhere, Word included. Between two cells the gutter is a cell of its own, `<td class="e-cells-gutter" width="{g%}" aria-hidden="true" style="width:{g%};font-size:0.01px;line-height:0;mso-line-height-rule:exactly;">&nbsp;</td>` (R-TBL-05, with R-LAY-04's non-zero font size), so a background or border stays inside its cell. Under the `max-width` query `.e-cells-stack{display:block !important;width:100% !important}`, `.e-cells-gutter{display:none !important}` and `e-stackpad-…` (the cell's padding plus the gutter on top, every cell but the first) stack the cells. **Without CSS the row stays side by side**, so it is always checked at 320px (R-TBL-11). A row of cells whose vertical paddings differ pads a nested single-cell table per cell (R-TBL-03). `border-collapse:separate !important` on the table when a cell has a radius (R-TBL-16). | lower/column, P6 | all | Foundation for Emails `_media-query.scss` stacking; Litmus, "Mobile responsive email stacking" (read) | ✓ structure; ◐ (verified on the browser engines, the self-hosted webmails and the desktop clients) |
| R-LAY-20 | **Cell row** (`strategy = cells`): R-LAY-19's table without the classes; it never stacks. For short items (stats, icons, key-value pairs, steps); checked at 320px (R-TBL-11). | lower/column | all | goodemailcode.com columns (read) | ✓ |

## 4b. TBL — Table and scaffolding construction

These rules apply to every construct. **Div-first: tables only for MSO
scaffolding, table-layout semantics, and data.**

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-TBL-01 | Outside MSO comments, a layout table is emitted only by these constructs: `mailBox`; `mailColumns(cells\|cellsStacking)`; `mailSidebar(switch_below = 0)`; `mailHero` (its content cell: a height and a vertical alignment, which a `div` cannot have without `display:flex`, R-OL-10; R-VML-06); `mailKeyValue`; steppers, timelines and labelled dividers; a badge's Word wrapper (a one-cell `display:inline-table`, written when Outlook output is on and the badge is not inside a line of text); `mailTable`; the button; the document wrapper. P10 flags any other non-MSO layout table (`W-TBL-UNEXPECTED`): in the authoring tree, every `table` outside a `mailTable` (the constructs emit theirs in lowering), except the tables a stepper, a timeline, a labelled divider or a badge writes in its expansion (layout-patterns.md §4.4, §4.5: their special lowering). | P10 | goodemailcode.com; Blocks Edit, "No more tables for email"; Litmus, "Email design with HTML tables" (read) | ✓ (decision) |
| R-TBL-02 | **Mirroring.** Any padding, background colour, border or width that Word must honour on a div is repeated on the enclosing MSO ghost cell (`padding`, `bgcolor` + `background-color`, `border`, `width` attr + CSS). The div keeps its own copy for everyone else. | mso/ghost | Blocks Edit, "No more tables for email": Outlook ignores div padding and mis-paints div backgrounds (read) | ◐ (to be confirmed by a Word-engine Outlook capture) |
| R-TBL-03 | **One padded cell per row.** Word equalises vertical padding across all cells of a row to the largest value. A row whose cells need different vertical padding gets a nested single-cell table per cell instead. | lower/*, mso/* | caniemail css-padding note (read) | ✓ |
| R-TBL-04 | Gaps are padding on cells or divs, or ⟪mso⟫ spacer rows. Never `gap`, never negative margins, never `margin:auto` alone. | P5 | caniemail css-gap, css-margin (read) | ✓ |
| R-TBL-05 | **Spacer cells are never empty.** They carry explicit `height`/`width` attributes and CSS, `font-size:0;line-height:0;mso-line-height-rule:exactly;` (`font-size:0.01px` outside Outlook conditionals, R-LAY-04), a `&nbsp;`, and `aria-hidden="true"`. Unsized empty cells are dropped by about 25–90% of clients. | mso/ghost, lower/* | Email on Acid empty-cells study (read); Cerberus spacer (read) | ✓ |
| R-TBL-06 | No `rowspan` anywhere. No `colspan` in layout tables; data tables may use `colspan` in header rows. P10 reports either as `W-TBL-SPAN`. | vocabulary, P10 | inference: Email on Acid lists them only as alternatives to empty cells (read); no current source recommends them for layout | ✓ (decision) |
| R-TBL-07 | A cell containing only an image (a `mailImage`, or a link around one), beside a cell containing text, gets `&zwnj;` after the image, so that Word applies `valign` correctly. ⟪mso⟫ The character is written inside an Outlook conditional, `<!--[if mso]>&zwnj;<![endif]-->`: only Word needs it, and in any other engine a character after a block image opens a line of its own under the image. Applies to both sides of a `mailSidebar`, either lowering. | lower/sidebar, mso/ghost | kontent.ai, Outlook vertical alignment in tables (read) | ◐ (markup and its centring verified in the browser engines, with and without head CSS; the Word effect to be confirmed by a Word-engine Outlook capture) |
| R-TBL-08 | Dashed or dotted borders: the bordered cell **and** its parent carry the same background colour (Outlook 2007/2010 paints the parent's colour between dashes). A `mailBox` with a dashed or dotted border and a background gives its table the cell's `bgcolor`, `background-color` and dark class (`mailCoupon`'s box). | lower/box | hteumeuleu/email-bugs #34 (via search) | ◐ (markup verified in the browser engines, the self-hosted webmails and the desktop clients; Outlook 2007/2010's dashes to be confirmed by a Word-engine Outlook capture) |
| R-TBL-09 | `box-shadow` is decoration only and is always paired with a border, because the shadow is missing in Gmail web, Word and Yahoo, and invisible in dark mode: the box's own border, else `1px solid` in its background one step darker. One step is 0.1 of OKLCH lightness, chroma and hue kept (the step that tells two adjacent bands apart); a box without a background of its own is taken to sit on white. Under `darkMode = designed` the derived border also gets a dark colour, one step darker than the box's dark background (else the nearest ancestor's), through its dark class (R-DRK-02); without one it would stay light-derived and turn near-white on the dark box. `shadow = sm` is `0 1px 3px rgba(0,0,0,0.12)`, `md` `0 4px 12px rgba(0,0,0,0.16)`, on the box's cell after its border. | lower/box | caniemail box-shadow (read) | ✓ |
| R-TBL-10 | Equal heights are promised only by table-cell constructs (`cells`, `cellsStacking`, `mailSidebar` that never switches, steppers, timelines). Hybrid and Grid constructs declare "ragged bottoms" as an expected degradation (the review brief lists it wherever their items paint a box), and bordered or background-carrying items in them are flagged with `I-TBL-RAGGED`, once per row (a `hybrid` or `fabFour` `mailColumns`, a section's own columns, a `mailGrid`), so the design is chosen knowingly. An item paints a box when it, or its only child (a `mailBox` in a column), has a background or a border. | P10 | goodemailcode.com columns (read) | ✓ |
| R-TBL-11 | **320px check** for non-stacking and media-query-stacking cell rows (`cells`, `cellsStacking`): each cell's content box at a 320px document — its desktop share of the row's box, which shrinks by exactly what the document loses (paddings and borders stay), less its own padding and borders — must be ≥ its minimum: the column's `min_width`, else the row's `min_column`, else 160px for a column with text and 120px for one without (images, decoration). Short items declare theirs (stats 72). Otherwise `W-LAYOUT-MIN-COLUMN` (an error under `strict`). This applies to `cellsStacking` because it shows the desktop row whenever CSS is lost. | P3 | Cerberus minimums (read) | ✓ |
| R-TBL-12 | Interactive items in a row (links, buttons, rating targets) keep ≥ 8px between hit areas and ≥ 44px hit height. P10 checks the spacing of a `mailCluster` holding two or more links or buttons: a `gap` or `row_gap` below 8px is `W-A11Y-TAP-TARGET`. The 44px height is the button's (R-BTN-06). | P10 | Mailchimp, mobile-friendliness guide (read) | ✓ |
| R-TBL-13 | Tables or cells containing only images get a zero font size and `line-height:0;` on the cell: `font-size:0.01px` outside Outlook conditionals (R-LAY-04: WebKitGTK renders nothing of a message holding a true zero), `font-size:0` inside them, where only Word reads it. This prevents the Outlook 2013–2019 1px line under images. "Containing only images" means images and links around them only; the holder may be a `td` or a `div`. A holder of R-IMG-03's inline form keeps its font size (litehtml lays an inline image out empty in a zero-font line); the image's `vertical-align:middle` closes the gap instead. | lower/image | hteumeuleu/email-bugs #99 (via search); capture of Evolution and Geary, 2026-10-02 (the zero) | ◐ (to be confirmed by a Word-engine Outlook capture) |
| R-TBL-14 | Alignment is emitted as attribute **and** CSS (`align` + `text-align`, `valign` + `vertical-align`). Horizontal centring of a block in Word is `align="center"` on its (ghost) table. | P5 | caniemail css-margin note 4; goodemailcode.com container (read) | ✓ |
| R-TBL-15 | Non-MSO layout-table nesting stays ≤ 3 levels per construct (P10 `W-TBL-DEEP`). Deeper structure lives inside MSO comments, where only Word pays for it. Counted over the lowered document: tables with `role="presentation"` outside Outlook conditionals, below the document's wrapper table; a fourth level warns. | P10 | inference: Blocks Edit byte measurements; Outlook per-level margin quirks | ✓ (design rule) |
| R-TBL-16 | Rounded boxes: `border-radius` on the cell with `border-collapse:separate !important` on its table (radius does not render on collapsed tables, and the reset collapses every table with `!important`, R-RST-06, which only an inline `!important` overrides); without a radius the table is `border-collapse:collapse`. Square in Word. The opt-in 3×3 VML-corner Box (`outlook_rounded`) is not built: asking for it is `E-LOWER-MISSING` and the box lowers square, until a Word-engine capture shows the variant works (☐). General `v:roundrect` containers are never used; they distort and cannot nest. | lower/box | mjml-column renderGutter; kontent.ai (read) | ✓ / ☐ 3×3 variant (to be settled by a Word-engine Outlook capture) |
| R-TBL-17 | **Long words break inside primitives.** The content box of a primitive — a `mailBox` cell, a `mailGrid` item, either side of a `mailSidebar` — carries `word-break:break-word`; a `mailCluster` item carries `overflow-wrap:break-word`, which breaks only a word too long for its line: Word lays a cluster out as one table row it never wraps, and `word-break` would let the row squeeze every label into broken words (seen in the Word approximation), so there a cluster too long for its line overflows instead, as declared (layout-patterns.md §3.5). The reset fixes table layout (R-RST-06) and a grid item is capped at its width, so an unbroken word (a long reference, a URL) would otherwise overflow the box, or, in a table that sizes to its content, push the row past the message width. Where head CSS is stripped (the `ganga` family: Gmail with a non-Google account), the reset is gone with it, and an auto-layout table grows to its longest unbroken word even where its text carries `overflow-wrap:break-word`, which leaves that width alone: a 42-letter word in a plain paragraph widened a 320px message to 371px through the document's wrapper table. So every layout table outside Outlook conditionals that has a width of its own (`role="presentation"`, a `width` attribute or declaration) and no layout of its own carries the reset's `table-layout:fixed` inline: the wrapper table (§1), a box, a sidebar, a cell row, a hero's cell table, a button's width table. A data table keeps its own `auto` (R-TBL-18), and a labelled divider its own (layout-patterns.md §4.5). A `mailCluster` item is also capped at its line (`max-width:100%` with `box-sizing:border-box`, its gap included): an inline-block grows to its longest word, which `overflow-wrap` leaves alone, so a word longer than the line pushed the item past the message's edge. | lower/box, lower/grid, lower/cluster, lower/sidebar, lower/document | capture of the primitives' maximal stories in the browser engines (an unbroken 42-letter word overflowed the box and the grid card at 375 px), 2026-10-02; capture of every story at 320 px under `ganga` (the wrapper table at 371 px and 384 px, a hero's cell table, a cluster item), 2026-10-04 | ◐ (verified in the browser engines; Word's handling to be confirmed by a Word-engine Outlook capture) |
| R-TBL-18 | **Data tables** (`mailTable`). The author's `table` is emitted as the data table: `role="table"`, `border="0" cellpadding="0" cellspacing="0" width="100%"`, `style="width:100%;border-collapse:collapse;table-layout:auto !important;"` (its own collapse: a table inside a rounded box would otherwise inherit the box cell's `separate` where the reset is stripped, R-TBL-16; and its own layout: the reset fixes every table's layout with `!important`, R-RST-06, which would give every column the same width). A `caption` attribute becomes R-A11Y-09's hidden caption, its first child. Every `td` and `th` carries its padding (`space.2` `space.3`, 8px 12px), `vertical-align:top` (with `valign`, R-OL-09), and, in a cell holding a word longer than 20 characters, `word-break:break-word` (a long reference breaks in its cell instead of widening the table past the message, R-TBL-17; on every cell it would let the table squeeze short columns into broken words) and the table's `border` as its own bottom border (default `1px solid` `color.border.subtle`, dark-paired under `darkMode = designed`; `none` draws none); never on the `table`. A `th` is bold and start-aligned (`text-align` and `align`; browsers centre one). `striped` gives every second body row's cells `color.surface.subtle`, as background and `bgcolor`. **Mobile:** `mobile` is `stack` by default for a table wider than 3 columns (the widest row, `colspan` counted), else `keep`. `stack` is mobile-first: the table everyone but Word reads is, inline, a block (`e-tbl-t`) whose body (`e-tbl-g`), rows (`e-tbl-r`) and cells (`e-tbl-c`) are blocks, its header row hidden (`e-tbl-head`, `display:none`), every cell but a row's last without its rule and bottom padding (`e-tbl-in-{w}`), and each body `td` (a body `th` heads its row and is a label already) starting with a label, the text of its column's header cell then `: `, in a bold `span` (`e-tbl-lbl`); from the breakpoint up, rules restore the table (`display:table`, `table-row-group`, `table-row`, `table-cell`, the header row, the rules and padding, the labels hidden), copied with R-LAY-12's `.moz-text-html` prefix for Thunderbird, and a stacked cell's line starts at the start of the line (inline `text-align:inherit`; an amount column's end alignment would leave its lines hanging at the far edge), its own alignment given back with the table (`e-tbl-a-left`, `-right`, `-center`). So a client without head CSS or media queries reads complete "label: value" groups (seen: the GANGA emulation and SnappyMail, where the desktop table did not fit a phone). Word reads none of that CSS: with `outlookWord` it gets the plain table, a second copy inside an `mso` conditional, the mobile-first one inside `!mso`. `scroll` wraps the table in `<div style="overflow-x:auto;">`, inside a one-cell presentation table with `width:100%;table-layout:fixed` (without the reset, the auto-layout tables around it would grow to the data table's narrowest width and widen the message past a phone's screen; seen in the GANGA emulation), and gives the data table, by a class, its desktop width as `min-width` below the breakpoint. `scroll` is an option: a phone draws no scrollbar, so the author says the table scrolls. A `mailTable` holds exactly one `table` (`E-STRUCT-NESTING` otherwise). | lower/data_table, P5, P6 | design rule, from R-A11Y-02 and R-A11Y-09; caniemail css-display, css-overflow (read) | ◐ (stack and scroll verified in the browser engines with and without head CSS, the self-hosted webmails and the desktop clients; hosted webmails and Word to be confirmed) |

## 5. OL — Word-engine Outlook

All ⟪mso⟫ output is created only in `src/isonim_email/mso/`,
and is removed by P9 when `outlookWord = false`.

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-OL-01 | Conditional syntax: Outlook-only `<!--[if mso]>…<![endif]-->`; everyone but Outlook `<!--[if !mso]><!-->…<!--<![endif]-->`. The two are never mixed within one comment. | ir, serialize | Cerberus hybrid template, both forms in use (read); Email on Acid, Word rendering engine article (secondary, not read verbatim ◐) | ✓ |
| R-OL-02 | Version conditions: `mso 12` = 2007, `14` = 2010, `15` = 2013 and every later version; `gte mso 9` = all Word-engine versions; `lte mso 11` = 2000–2003. The library emits only `mso`, `!mso`, `gte mso 9` (VML) and `lte mso 11` (group fix). An author reaches conditions in two ways, and both are checked: `mailIf` takes a boolean (`mso = true` or `false`) and reports any other value as `E-VOCAB-BAD-VALUE`; a conditional comment inside `mailRaw` with any other condition is `E-RAW-MALFORMED` (R-RAW-02). A library construct that asks for another condition is an internal error and raises (`EmailRenderError`), since no author input reaches it. | mso/*, P1 | Email on Acid, Word rendering engine article (◐ version table) | ◐ (the version table to be confirmed by a Word-engine Outlook capture) |
| R-OL-03 | `max-width` is ignored, so every `max-width` container has a ghost table with fixed px width (R-LAY-06/07). | mso/ghost | mjml-section source (read) | ✓ |
| R-OL-04 | `margin`: no negative values, none on `span`/`body`, background bleeds into the margin, `auto` unsupported. Only `p`, `h1`–`h6`, `ul`/`ol` and the text blocks whose defaults carry one (`li`, R-TXT-09; `blockquote`, `pre`, R-TXT-02) may carry vertical margins. All other spacing is padding on a `td`. P5 converts other margins into cell padding, with a warning. | P5 | caniemail css-margin notes 1–4 (read) | ✓ |
| R-OL-05 | Padding is reliable only on `td`. Padding on `a`, `div` and `p` is emitted for other clients, and the ⟪mso⟫ equivalent is carried by the enclosing `td` (`mso-padding-alt` for buttons, R-BTN). | lower/* | Email on Acid, Word rendering engine article (◐); mjml-button source (read) | ✓ |
| R-OL-06 | Every px `line-height` is accompanied by `mso-line-height-rule:exactly`. Without it, Word treats `line-height` as a minimum. | P5 | mjml-section source emits it (read) | ✓ |
| R-OL-07 | Web fonts: when any `@font-face` or `<link>` font is used, the mso block contains `*{font-family:{fallback stack} !important;}`. Otherwise Word falls back to Times New Roman. Additionally, `mso-font-alt:{fallback}` is emitted on elements whose first family is a web font. Web fonts are declared on the target (`EmailTarget.webFonts`); the fallback stack is `font.body` without the web families, and `{fallback}` the first family of the element's own stack that is not a web font. | mso/fonts, P5, P6 | Cerberus (read); caniemail at-font-face notes 4–5 (read) | ✓ (markup; Word's use of it to be confirmed by a Word-engine Outlook capture) |
| R-OL-08 | DPI: besides R-DOC-08, every `img` and fixed-width `table`/`td` carries an HTML `width` attribute (unitless px) as well as CSS. VML sizes are in px. | P5, lower/* | Cerberus comment (read) | ✓ |
| R-OL-09 | Attribute mirroring: `width`, `height` (images), `bgcolor` (cells with a background), `align` and `valign` are emitted as HTML attributes as well as CSS on `table`/`td`/`img`. `valign` mirrors `vertical-align` (`top`, `middle`, `bottom`) on `td`, `th` and `tr`, either way round. A translucent background's `bgcolor` is its opaque blend over what is behind the cell (R-CSS-14) for every target, Word or not: an attribute cannot carry `rgba()`, and a client that reads the attribute (or drops the CSS) needs a colour. | P5 | Maizzle attributeToStyle docs (◐); Cerberus (read) | ✓ |
| R-OL-10 | No `display:flex`/`grid` anywhere. On a layout container it is **harmful** (error); elsewhere it is removed with a warning. | P5, P10 | caniemail css-display-flex (read) | ✓ |
| R-OL-11 | CSS `background-image` is ignored by Word, so any background image gets the VML of R-VML-01, except where that rectangle would rely on the unverified fit of R-VML-03 and the target's `vmlFitToText` is off: then Word gets the image's fallback colour on the ghost cell, as when images are blocked. | mso/vml, lower/section, lower/hero | mjml-section source; Cerberus (read) | ✓ |
| R-OL-12 | `border-radius` is ignored by Word, so corners are square. Accepted as a declared degradation unless the component emits VML (R-BTN-04). | lower/button, P10 | caniemail css-border-radius (◐) | ◐ (to be confirmed by a Word-engine Outlook capture) |
| R-OL-13 | Images: PNG, JPEG and GIF only. No WebP, SVG, `<picture>` or `data:` (R-IMG-08). Animated GIFs show only the first frame in Outlook 2007–2016, so the first frame must carry the message. | P10, lower/image | caniemail image-webp, html-svg, html-picture, image-base64 (read); GIF first-frame behaviour ◐ | ✓ / ◐ GIF |
| R-OL-14 | `mso-hide:all` is emitted on every element that must not render in Word and is not already inside a `NotMso` comment (preheader, dark-swap images, hidden captions), when `outlookWord` is on. | P5, lower/document, lower/image, lower/data_table | Cerberus (read) | ✓ |
| R-OL-15 | **The closed list of `mso-*` properties** the library may emit is: `mso-line-height-rule`, `mso-table-lspace`, `mso-table-rspace`, `mso-padding-alt`, `mso-hide`, `mso-font-alt` (R-OL-07's web-font fallback; caniemail at-font-face notes 4–5, read). Adding one requires a Word-engine Outlook capture that shows its effect, recorded here. (The R-BTN-05 option emits `mso-text-raise` and `mso-font-width`, and is reported for them until they are admitted.) P10 checks the lowered document (inline styles, `style` attributes, MSO payloads, head blocks) and reports any other `mso-*` property, author-written or emitted, as `W-CSS-MSO-UNLISTED`. Candidates awaiting evidence: `mso-text-raise`, `mso-font-width` (R-BTN-05), `mso-generic-font-family`, `mso-special-format` (R-TXT-09), `mso-border-alt`, `mso-color-alt`, `mso-ansi-font-size`. | P5, P10 | community lists of `mso-*` properties; caniemail notes (list flagged "verify") | ☐ per candidate, each settled by a Word-engine Outlook capture |
| R-OL-16 | 120-DPI rendering is part of backend C: classic Outlook is captured at 96 and at 120 DPI for every story that contains images or fixed-width elements. | capture | Cerberus (read) | ✓ (process rule) |

## 6. VML — Background images and shapes

```html
<!--[if gte mso 9]><v:rect xmlns:v="urn:schemas-microsoft-com:vml" fill="true" stroke="false" style="width:{W}px;height:{H}px;"><v:fill type="{frame|tile}" origin="{x}, {y}" position="{x}, {y}" src="{absolute https src}" color="{fallback bg}"{size}{aspect} /><v:textbox inset="0,0,0,0"{fit}><![endif]-->
{content}
<!--[if gte mso 9]></v:textbox></v:rect><![endif]-->
```

`{fit}` is ` style="mso-fit-shape-to-text:true"` when R-VML-03 applies,
and then the rectangle has no `height:{H}px;`. `{size}` and `{aspect}`
are ` size="…"` and ` aspect="…"`, each omitted when it has no value.
The `v:fill` follows MJML 5's `mj-section` (read): `background_size`
`cover`/`contain` is `size="1,1"` with `aspect="atleast"`/`"atmost"`;
one px length is `size="{w}px" aspect="atmost"`, two are
`size="{w}px,{h}px"`; `auto` writes neither and is always a `tile`
placed at `0.5, 0`. A `no-repeat` image is a `frame` and a `repeat`
image a `tile`. `background_position` (one or two of `left`, `center`,
`right`, `top`, `bottom` or whole percentages; one value names one axis
and centres the other) becomes per-axis percentages `p`: a frame is
placed at `(p − 50) / 100`, a tile at `p / 100`, written with up to four
decimals and no trailing zeros (`0`, `-0.5`, `0.3`).

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-VML-01 | Background images (`background_image` on `mailSection`, `mailWrapper` and `mailHero`). **Capable clients:** CSS on the element that carries the band's padding and classes (a section's or wrapper's inner div, R-LAY-08; a hero's background box, R-VML-06), longhands only, in this order: `background-color:{fallback};background-image:url('{src}');background-position:{position};background-size:{size};background-repeat:{repeat};` (defaults `center center`, `cover`, `no-repeat`; a radius goes on that element too when the band has no border frame). Yahoo and AOL drop a `background` shorthand carrying a `/ size`, so none is written. The image covers the band's container (`W` px), never a `full_width` bleed, which shows the fallback colour. The **fallback colour** is the band's `background_color`, else the nearest enclosing background (the document's, white when none is set): it is painted behind the image, on Word's ghost cell (`bgcolor`) and in the `v:fill`. The band's fallback colour keeps one value in both schemes (R-DRK-02's image backdrops), as do the colours of what lies over the image; an explicit `@dark:` of the band's under `darkMode = designed` puts its dark class on the same element as the image, so the dark rule repaints the colour behind it, never over it. **Word:** the rectangle above, inside the ghost cell (which keeps the fallback colour and the border, and loses the padding), holding a one-cell 100% table whose cell carries the padding, the alignment and the direction (`msoBoxOpen`); no element with a background of its own is visible to Word inside the rectangle (Word would paint it over the image): the outer div has no colour, and the inner div's tags are written in `<!--[if !mso]><!-->` conditionals, its content shared. A value outside the vocabulary is `E-VOCAB-BAD-VALUE`, and the default is used. P10 declares the background properties' gaps as degradations (`I-SUPPORT-DEGRADATION`): Word gets VML or the fallback colour (R-OL-11), and a client that drops the size, position or repeat shows the image at its own size or place over the fallback colour. | mso/vml, lower/background, lower/section, lower/wrapper, lower/hero, P10 | mjml-section source (read; the `v:fill` mapping); Cerberus (read); Campaign Monitor, backgrounds.cm (the bulletproof background pattern: no background inside the text box; via search); caniemail css-background note 2 (read) | ✓ (markup; Word's rendering, including the hidden inner div, to be confirmed by a Word-engine Outlook capture) |
| R-VML-02 | VML requires explicit px **width and height**, except a rectangle that grows with its content (R-VML-03), which has a px width only. A `mailHero` with a background image requires `height` or `min_height` (px) when `outlookWord` is on; missing both, or a value that is not px, is `E-LAYOUT-VML-SIZE`, and the hero is lowered without VML. Both at once, or a height that leaves no room inside the vertical padding, is `E-VOCAB-BAD-VALUE`. A hero without an image needs neither. | lower/hero (P4), mso/vml | mjml-section source; Cerberus (read) | ✓ |
| R-VML-03 | `mso-fit-shape-to-text:true` on `v:textbox` lets the rectangle grow with its content. It is used for a section's or a wrapper's rectangle (MJML's `mj-section` form: a px width, no height) and for a `min_height` hero's (its px height the minimum), and only when the target's `vmlFitToText` flag is on; the flag is off by default until a Word-engine capture settles this rule. Without it those bands show Word their fallback colour on the ghost cell (a `min_height` hero at least that tall, through its cell's `height`), as when images are blocked, never a fixed-height rectangle their content could overflow. `mso-fit-shape-to-text` is not on R-OL-15's closed list, so the opt-in reports `W-CSS-MSO-UNLISTED` until it is admitted. A `height` hero never grows: its rectangle has that height and no fit. | mso/vml, lower/section, lower/hero, target | community practice ("widely used; not fetched"); MJML 5 `mj-section` writes it (read) | ☐ (to be settled by a Word-engine Outlook capture; behind `vmlFitToText`) |
| R-VML-04 | VML `src` is always an absolute https URL. VML ignores `cid:` and relative URLs in some versions, so embedded (cid) images are never used for VML backgrounds. P8 resolves a `background_image` that names an asset through the asset store (as images, R-IMG-07) and reports anything else that is not an absolute https URL — `http:`, `cid:`, a relative path, a `data:` URI, or a URL holding a quote, a parenthesis, a backslash or white space, which would end the CSS `url('…')` — as `E-URL-SCHEME`. | mso/vml, P8 | inference | ☐ (to be settled by a Word-engine Outlook capture) |
| R-VML-05 | Decorative VML is `aria-hidden` where the markup allows it. Text inside `v:textbox` is ordinary HTML and remains the accessible content: a background rectangle, which holds the content, is never `aria-hidden`. | P7 | Email Markup Consortium Accessibility Report 2026 | ◐ |
| R-VML-06 | **`mailHero`.** A band laid out like a section (`W` px, centred, the section's padding defaults, its content an implicit single column with the default column padding; columns in a hero are `E-STRUCT-NESTING`) whose content sits in one table cell, which gives it a height and a vertical alignment in every client, Word included: ⟪mso⟫ the ghost table of R-LAY-06 with the fallback colour and no padding (`<td bgcolor="{bg}" style="background-color:{bg};">`), ⟪mso⟫ the rectangle (`{W}` × the hero's `height` or `min_height`, R-VML-02, R-VML-03), `<div style="margin:0 auto;max-width:{W}px;">`, the background box `<div class="{classes}" style="{R-VML-01's CSS}">` (a colour only when there is no image) with its tags in `<!--[if !mso]><!-->` conditionals when `outlookWord` is on, `<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="width:100%;table-layout:fixed;"><tr><td height="{H − vertical padding}" valign="{v}" align="{align}" style="padding:{pad};height:{H − vertical padding}px;box-sizing:content-box;vertical-align:{v};font-size:16px;text-align:{align};direction:{dir};">{content}</td></tr></table>`, and everything closed in reverse. The cell's `height` (attribute and CSS, with `box-sizing:content-box`, all three omitted without a height; Roundcube's stylesheet makes every element `border-box`, which took the padding out of the height) is a minimum everywhere, so `height` and `min_height` look the same outside Word. `vertical_align` is `top` (default), `middle` or `bottom`; the alignment and direction default as a section's. The hero's classes go on the background box, so a dark rule repaints the colour behind the image; a responsive padding rule on a hero therefore pads the box, not the cell. | lower/hero, mso/vml | MJML 5 `mj-hero` (read: a cell with the height, the padding and the alignment); design rule | ◐ (verified in the browser engines, the self-hosted webmails and the desktop clients; Word's rendering to be confirmed by a Word-engine Outlook capture) |
| R-VML-08 | **A fixed-height hero's content fits.** Word's rectangle for a `height` hero never grows (R-VML-03), so when `outlookWord` is on, a `mailHero` with a background image and `height` has its content's height estimated at the text metrics' worst case and compared with its cell (`height` less the vertical padding): each heading, paragraph and `mailText` among its children is wrapped greedily, word by word, at the cell's content width (its width less its horizontal padding) in the widest face of its font stack, bold when its weight is, at its font size with the metrics' safety margin, as drawn: after its `text-transform`, plus its `letter-spacing` after every character (both its own or inherited from an ancestor inside the hero; px, or em of its font size; a negative spacing counts as none) (a word wider than the line takes as many lines as its width needs; a `br` starts a line), and counts its lines times its line height (px; the font's content area when it has none) plus its top and bottom margins; a `mailButton` counts its height (line height, vertical padding, borders), a `mailSpacer` its height, a `mailDivider` its vertical padding and line; margins are summed, never collapsed; any other element (an image, a table, a row) is not measured. An estimate above the cell is `E-LAYOUT-HERO-OVERFLOW` (an error, naming the estimate and the room; the remedy is a taller hero, shorter content, or `min_height`), with `I-LAYOUT-METRICS-APPROX` when a character fell outside the metrics' ranges. The estimate errs on the tall side, as the button's label check (R-BTN-04) errs on the wide side. | lower/hero | design rule; the text metrics (R-BTN-04) | ✓ (decision) |
| R-VML-07 | Text over a background image is checked against the image's fallback colour (R-VML-01), which is what shows when images are blocked: P10's contrast check (R-A11Y-07) takes the nearest enclosing background colour as usual, and when a band with an image lies between the text and that colour, reports `W-A11Y-CONTRAST` naming the fallback colour (and R-VML-01). Light text needs a dark fallback, whatever the image. | P10 | design rule | ✓ (decision) |

## 7. BTN — Buttons

Default (table) button, from MJML `mj-button` (read; "No, VML is not
used"), in its placement cell (a start- or end-aligned button; a centred
one, a full-width one and an item of a `mailCluster` have no placement
cell, and a cluster's has no `align`):

```html
<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="table-layout:fixed;"><tr><td align="{align}" style="text-align:{align};">
<table role="presentation" border="0" cellpadding="0" cellspacing="0" align="{align}" style="border-collapse:separate !important;line-height:100%;">
<tr><td align="center" bgcolor="{bg}" role="presentation" valign="middle" style="border:{border};border-radius:{r}px;cursor:auto;mso-padding-alt:{pv}px {ph}px;background-color:{bg};">
<a href="{href}" target="_blank" style="display:inline-block;background-color:{bg};color:{fg};font-family:{ff};font-size:{fs}px;font-weight:{fw};line-height:{lh}px;mso-line-height-rule:exactly;margin:0;text-decoration:none;text-transform:none;padding:{pv}px {ph}px;mso-padding-alt:0px;border-radius:{r}px;">{label}</a>
</td></tr></table>
</td></tr></table>
```

VML variant (Campaign Monitor pattern), in a block that aligns it for
Word:

```html
<!--[if mso]><div align="{align}"><v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="{href}" style="height:{h}px;v-text-anchor:middle;width:{w}px;" arcsize="{round(r/h*100)}%" strokecolor="{border or bg}"[ strokeweight="{bw}px"] fillcolor="{bg}"><w:anchorlock /><center style="color:{fg};font-family:{ff};font-size:{fs}px;font-weight:{fw};">{label}</center></v:roundrect></div><![endif]-->
<!--[if !mso]><!-->{table button}<!--<![endif]-->
```

An outline button's shape has no fill: `filled="f"` in place of
`fillcolor`.

Word-spacers variant (R-BTN-05, an option), from goodemailcode.com:

```html
<div align="{align}" style="text-align:{align};"><a href="{href}" target="_blank" style="display:inline-block;background-color:{bg};[border:{border};]color:{fg};…;padding:{pv}px {ph}px;mso-padding-alt:0;text-underline-color:{bg};border-radius:{r}px;"><!--[if mso]><i style="mso-font-width:{ph/fs}%;mso-text-raise:{(pt+pb)/fs}%" hidden>&emsp;</i><span style="mso-text-raise:{pb/fs}%;"><![endif]-->{label}<!--[if mso]></span><i style="mso-font-width:{ph/fs}%;" hidden>&emsp;&#8203;</i><![endif]--></a></div>
```

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-BTN-01 | The default button is the table button above: colour on both `td` (`bgcolor` + CSS) and `a`; padding on the `a`, with `mso-padding-alt` on the `td` and `mso-padding-alt:0px` on the `a`. Two additions to MJML's markup, both for the reset (§2): `border-collapse:separate` is `!important`, because the reset collapses every table with `!important` and a collapsed cell draws its border and background square; and a start- or end-aligned button sits in a one-cell 100% placement table, because the reset centres every table with `margin:0 auto !important`, so only the table's `align` (a float) can place it, and a cell contains the float (without one the button hangs out of its box's bottom padding and the text after it flows beside it). | lower/button | mjml-button source (read); captures of the placement in Chromium, WebKit and Firefox, 2026-10-03 | ✓ |
| R-BTN-02 | Declared degradation: in Word only the label text is clickable, and corners are square. The brief generator tells reviewers so. | lower/button, P10 | mjml-button source (read) | ✓ |
| R-BTN-03 | The label may wrap. Button width is content-driven unless `width` is set; a set `width` (px or %) goes on the button's `table` (attribute and CSS), whose width includes the cell's border, and the link becomes a centred block that fills the cell, so the whole width is the link. (MJML puts it on the `td`, whose width excludes its border.) | lower/button | MJML; design rule | ✓ |
| R-BTN-04 | The VML variant is used when `vml = always`, or when `vml = auto` and `border_radius > 0` and `width` is set in px (a % width keeps the fluid table button; with `vml = always` it is taken of the box the button sits in). It requires `width` and `height` in px (`E-LAYOUT-VML-SIZE`); the height is the button's (line height + padding + borders, or its `height`). The label must fit: its width at the text metrics' worst case (the widest face of its font stack, +5%), as drawn (after its `text-transform`, plus its `letter-spacing` after every character; a negative spacing counts as none), must not exceed the width less the horizontal padding and the borders, or the render fails with `E-LAYOUT-LABEL-OVERFLOW`; characters outside the metrics add `I-LAYOUT-METRICS-APPROX`. The label cannot wrap. Word's label (the VML `center`) carries the button's `letter-spacing` and `text-transform` too, so it is the label measured. A `link` button never uses VML. | lower/button, mso/vml | Campaign Monitor buttons.cm pattern (◐; not fetched) | ◐ (to be confirmed by a Word-engine Outlook capture) |
| R-BTN-05 | Candidate: Good Email Code's link button (the third template above), which gives Word its padding with hidden `<i>` spacers: an em space (`&emsp;`, `mso-font-width` = the side padding in % of the font size, at most 500% an em space, more em spaces beyond that) on each side, the first raised by the top and bottom padding together (`mso-text-raise`), the label raised by the bottom padding, a zero-width space (`&#8203;`) after the trailing em space (and in the leading one too, right to left), `mso-padding-alt:0` and `text-underline-color` on the link; the full area is the link without VML. Implemented as an option, `word_padding = spacers`; the default stays R-BTN-01 until a comparison on backends C and D. Local comparison (2026-10-03, backend A with the Word approximation, Roundcube, SnappyMail, Thunderbird, Evolution, Geary, KMail, Claws Mail): no client but Word gains from it, and two lose: Thunderbird's dark adaptation clears the fill (it is on the link), and litehtml places a right-aligned one a padding width past the line's end. Its `mso-font-width` and `mso-text-raise` are not on R-OL-15's list, so a render using it reports `W-CSS-MSO-UNLISTED`. | lower/button | goodemailcode.com, "CTA Link - button", last updated 2023-04-20 (read 2026-10-03) | ☐ (adoption to be settled by backend C and D captures) |
| R-BTN-06 | The button's minimum tap target is 44 px tall: `lh + 2·pv (+ 2·border) ≥ 44`, or its `height`; below it is `W-A11Y-TAP-TARGET`. P10 checks it; the capture's Tier-3 `touch` check holds every target to WCAG 2.5.8's 24px (R-A11Y-11), not to this recommendation. The default (`button.font` 20px line, `button.padding` 12px) is exactly 44; a `font_size` given alone keeps the theme's line-height ratio. | P10 | WCAG-derived target size (◐) | ✓ (design rule) |
| R-BTN-07 | `href` is absolute https (or `mailto:`/`tel:`), and never `#` or empty; a button with no destination is an error (`E-URL-EMPTY`), any other scheme or a relative URL `E-URL-SCHEME`. | P1 | design rule | ✓ |

## 8. IMG — Images

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-IMG-01 | Every **fixed-size** image (rendered narrower than its container, e.g. a logo): `width` attribute (px), `style="display:block;{margin}border:0;outline:none;text-decoration:none;height:auto;width:{w}px;max-width:100%;-ms-interpolation-mode:bicubic;"` plus alt-text styling (R-IMG-03). The width is the px width, capped by `max-width:100%` on narrow screens, never `width:100%` capped by `max-width:{w}px`: Thunderbird marks message images `shrinktofit` and its message stylesheet sets `max-inline-size` with `!important` on them, which replaces an author `max-width`, so a `width:100%` image fills the column. `{margin}` centres the block in standards-only engines, from the image's horizontal alignment (the nearest ancestor's `align` attribute or `text-align`, else the skeleton's centred content cell): centre `margin:0 auto;`, right `margin:0 0 0 auto;`, left nothing. `align`/`text-align` centre inline content only; Chromium, WebKit and Gecko centre a block under `align` through a legacy quirk that litehtml (Claws Mail) does not have. Word ignores the margin and keeps the cell's `align` (R-TBL-14). `height` attribute only when the aspect is fixed and known. The `height` attribute is written when the author gives a height or the image is a published asset whose intrinsic size is known (at the rendered width). An explicit `align` sets the margin and wraps the image in a `div` carrying `align` and `text-align` (what Word reads); a bad value is `E-VOCAB-BAD-VALUE`. A narrow image alone in its holder may take R-IMG-03's inline form. **Fluid** images (rendered at the container width: a percentage `width`, a px width at least as wide as the box the image sits in and wider than a phone's box, 280px; or `fluid_on_mobile`) follow R-IMG-11 instead. | lower/image | all | MJML skeleton.js (read); capture: Thunderbird 150 `img[shrinktofit]` (`messageBody.css`, measured on the live element: computed `max-width` 772px with the attribute, 48px without; `width:48px;max-width:100%` keeps 48px with it); capture: Claws Mail 4.4 (litehtml) shows a block image under `align="center"` at the left edge | ✓ |
| R-IMG-02 | `display:block` is what removes the gap under images. A row of stacked images additionally gets a zero font size and `line-height:0` on its `td` (or the `div` that holds it: any block holding images and links around them only, R-TBL-13), the font size written `0.01px` outside Outlook conditionals (R-LAY-04). | lower/image | widely documented canonical fix for the gap under images; capture of Evolution and Geary, 2026-10-02 (the zero) | ✓ |
| R-IMG-03 | Alt text is styled on the `img` itself (`font-family`, `font-size`, `line-height`, `color`: `font.body`, `type.small`, `color.text.secondary`), so it is readable when images are blocked. Under `darkMode = designed` an image without a colour of its own also carries that colour's dark pair (R-DRK-02's class), so the alt stays legible on a dark surface. The containing cell has a background colour with sufficient contrast against that alt text colour (below 4.5:1 is `W-A11Y-CONTRAST`). The engines draw a blocked image's alt differently, and the lowering follows them (widths estimated from the text-metrics table): **WebKit** draws an alt only when it fits the image's width on one line, from just above the image's box, which otherwise collapses to a few pixels over whatever follows; so an image whose alt fits and whose rendered height is known never to drop below one alt line (its height, at its width and at 280px) gets `min-height:{alt line}px`, and an alt that does not fit is `W-IMG-ALT-FIT` (families: apple; the remedy is visible text beside a narrow icon, a shorter alt or a wider image). **Chromium and Gecko** draw a block image's alt inside its box, clipped at its edge; a fixed image whose longest alt word may not fit (estimated with the metrics' safety margin, plus 6px for the box's border and padding), or that is narrower than 40px (in a box that small Chromium's broken-image icon covers even a one-letter alt: a social icon's "X"), alone in its holder, is written **inline**: no `display` declaration (an explicit `display:inline` makes litehtml lay it out empty), its px width kept as CSS and attribute, no `max-width`, `vertical-align:middle`, `overflow-wrap:normal;word-break:normal` (the alt is laid out as text, which a container breaking long words must not break). Its holder keeps its font size (litehtml draws nothing of an inline image in a zero-font line). | lower/image | Cerberus (read); capture of the primitives' and content leaves' images-off stories in backend A's engines and Claws Mail 4.4, 2026-10-02 (probes of a bare `img` with an emptied `src`) | ✓ |
| R-IMG-04 | `alt` is required. `alt=""` only with `decorative = true`. Alt longer than 60 characters warns (text-in-image heuristic). | P1, P10 | Email Markup Consortium Accessibility Report 2026 (read) | ✓ |
| R-IMG-05 | Retina: `@2x` assets render at intrinsic/2 by default. The `width` attribute is the rendered size, never the intrinsic size. | lower/image, assets | Cerberus hero 1360→680 (read) | ✓ |
| R-IMG-06 | `dark_src`: two `img`s, under `darkMode = designed` only. The dark one follows the light one directly, the same element but for its `src` (`dark_src`) and its class `e-dk-show` (for the light one's `e-dk-hide`; the element's other classes are kept on both), hidden inline: `display:none;` first, `mso-hide:all;` last when `outlookWord` is on (R-OL-14). A fluid image's dark copy is its non-Word image's twin, in its own `NotMso` comment beside it (Word never sees it, so no `mso-hide`). A linked image holds both in its link. Block 3 swaps them: `.e-dk-hide{display:none !important}` and `.e-dk-show{display:block !important}` in the `prefers-color-scheme` query, with `[data-ogsc]` copies of both (R-DRK-03); the dark copy of an image in R-IMG-03's inline form (a social icon) carries `e-dk-show-inline` instead, shown by `.e-dk-show-inline{display:inline !important}`, so with images off its alt is laid out as text as its light image's is, not clipped in a block box (added 2026-10-04). P6 gives the light image `e-dk-hide` only when the dark block survives the head budget, and the lowering writes the dark copy only then: a dropped block, `accommodate` and `none` leave the light image alone. Both images carry the alt text and neither is `aria-hidden` (R-A11Y-05). P8 publishes `dark_src` like `src`. Gmail and the other families that never apply the dark block show the light image, so it must be dark-safe (R-DRK-06). | lower/image, P6, P8 | Litmus, "The ultimate guide to dark mode for email marketers" ◐ | ◐ (verified in the browser engines' dark schemes; Outlook.com and Apple Mail to be confirmed on backends B and C) |
| R-IMG-07 | Hosted asset URLs are content-hashed (`/{sha256[0:16]}/{name}`). The upload hook completes **before** the message is rendered for send or capture, so proxies such as Gmail's never cache a 404 or a stale image. | assets | Litmus, "Gmail adds image caching"; mailtester.com, Gmail image-proxy caching (read) | ✓ |
| R-IMG-08 | `data:` URIs are forbidden (Gmail, Outlook). WebP and SVG are errors under any profile that contains `outlookWord` or `gmail*` (`E-ASSET-FORMAT`, read from the source's extension or a `data:` URI's media type; `ganga` counts as Gmail). | P10 | caniemail image-base64, html-svg, image-webp (read) | ✓ |
| R-IMG-09 | `fluid_on_mobile`: below the breakpoint, `width:100% !important;max-width:100% !important` through a class. The desktop width stays inline. | lower/image, P6 | MJML ◐ | ◐ (to be confirmed by a real-client capture) |
| R-IMG-10 | A linked image wraps the `img` in `<a href target="_blank" style="display:block;color:{alt colour};text-decoration:none;">`, with no whitespace inside the `a` (Word paints a link's content, alt text included, in the link's colour, underlined). | lower/image | community practice | ◐ |
| R-IMG-11 | **Samsung Auto-fit split for fluid images.** Samsung Email lays out the whole email at an image's `width` *attribute*, so a fluid image never carries a px `width` attribute outside MSO. It is emitted twice: ⟪mso⟫ `<!--[if mso]><img src width="{px}" alt style="display:block;…"><![endif]-->` and `<!--[if !mso]><!--><img src width="100%" alt style="display:block;width:100%;max-width:{px}px;height:auto;…"><!--<![endif]-->`. Outlook ≤ 2016 reads a percentage `width` attribute relative to the image, hence the split. A percentage below 100 keeps its percentage as the CSS width; `fluid_on_mobile` keeps R-IMG-01's CSS. Without `outlookWord` only the second image is written, with no conditional. | lower/image, mso/cond | samsung, outlookWord | hteumeuleu.com, "Samsung Auto-fit" (read) | ✓ |
| R-IMG-12 | **Social icons** (`mailSocial`). A `mailCluster` of linked images, one per `mailSocialItem`: each a `mailImage` `icon_size` px square (16–48, default 24) with `alt` the network's name, linked to `href` (R-IMG-10). The built-in icons are monogram plates (a filled circle with the network's initials), PNG at 64×64 (2× the largest size shown at the default density, so `icon_size` up to 32 stays sharp), in two variants: `light`, a dark plate for light backgrounds, and `dark`, a light plate for dark ones. A plate carries its own contrast, so either variant stays legible on any background. `mode = auto` is the pair: under `darkMode = designed`, the `light` plate with the `dark` one as its `dark_src` (R-IMG-06's swap); under `none` and `accommodate`, which write no dark CSS, the `light` plate alone. An application's own icon takes its dark variant from `dark_icon` the same way. An `icon` of the application's own replaces the built-in one (brand artwork is the application's to ship). Items are 12px apart by default (`gap`, R-TBL-12). | lower/cluster, lower/image | MJML mj-social (read); design rule | ◐ (verified in the browser engines, the self-hosted webmails and the desktop clients) |
| R-IMG-13 | **Crops are made before sending** (`crop`). `mailImage(crop = "W:H")` (positive whole numbers) or `crop = circle` (an avatar). P8 crops a PNG it holds the bytes of (a store asset or a compile-time `asset"…"`): the largest centred W:H rectangle, or for `circle` the largest centred square with every pixel outside its inscribed circle transparent (the edge anti-aliased over one pixel), re-encoded as an 8-bit RGBA PNG whose bytes depend only on the source and the crop, published as an asset of its own (`{name}-{W}x{H}.png`, `{name}-circle.png`, content-hashed like any asset, R-IMG-07), and the image's `src` is its URL; the lowering reads the cropped size. A JPEG or GIF is not re-encoded: its size must already have the ratio (within a pixel), else `E-ASSET-CROP`, and a circle needs a PNG (it needs transparency). An image P8 cannot read (no store, an absolute URL) is `E-ASSET-CROP`: a crop asked for is never dropped silently. `object-fit` and `aspect-ratio` are never used: Apple Mail alone supports them. | P8 | caniemail `css-object-fit`, `css-aspect-ratio` (read); design rule | ✓ |

## 9. PRE — Preheader

```html
<div style="display:none;font-size:1px;color:{bg};line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">{preheader text}</div>
<div style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;" aria-hidden="true">{padding}</div>
```

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-PRE-01 | The preheader is the first content in `<body>`, before the article wrapper, as the two `div`s above. | lower/document | Cerberus (read) | ✓ |
| R-PRE-02 | The padding stops clients pulling body text into the inbox preview. Its unit sequence is a **flag** (`preheaderPad`), with default `&#847;&zwnj;&nbsp;` repeated N times. N = clamp(100 − len(preheader), 0, 150), where len counts characters. | lower/document | Cerberus (read); sequence alternatives are unverified community practice | ☐ the sequence and N are to be settled from inbox-list captures on backend B |
| R-PRE-03 | The padding carries `aria-hidden="true"`. | P7 | Good Email Code template; Email Markup Consortium Accessibility Report 2026 | ✓ |
| R-PRE-04 | The preheader text is omitted from the plain-text part. | P12 | design rule | ✓ |
| R-PRE-05 | Preheader bytes count toward R-SIZE-01. At about 12 bytes per unit, 150 units ≈ 1.8 KB. | P10 | arithmetic | ✓ |

## 10. TXT — Text, fonts and links

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-TXT-01 | Text uses real `h1`–`h6`, `p`, `ul`/`ol`/`li`, `strong`/`em` and `a`, never styled `td` text. At least one `h1` per message. | P1, P7 | Email Markup Consortium Accessibility Report 2026 (read) | ✓ |
| R-TXT-02 | Every text element gets inline `margin` (`0 0 {n}px`), `font-family` (full stack), `font-size` (px), `line-height` (px) with `mso-line-height-rule:exactly`, and `color`. Nothing relies on inheritance, because clients reset differently (Roundcube's page stylesheet makes an unstyled `h1` 40px at weight 500 with no top margin; SnappyMail strips the head and leaves the browser's sizes). The defaults, from the theme: `h1`/`h2`/`h3` take `type.h1`…`type.h3` (size, line height, weight) with bottom margins of `space.4`/`space.3`/`space.2`; `h4` takes `type.body`, `h5`/`h6` `type.small`, at weight 700, margin `space.2`; headings use `font.heading`; `p`, `blockquote` and `pre` (in `font.mono`) take `type.body` and `space.4`; `li`, a grouping `div`, `mailText` and a `td`/`th` holding text take `type.body` without a margin of their own (R-TXT-09 for `li`); `code` takes `font.mono`. Family, size and line height are inherited from the nearest ancestor that sets them (a `mailText`, the document's `font_family`), as CSS would; a heading's size and weight are its level's. The last element of its parent, and an item of a primitive that spaces its items itself (`mailStack`, `mailCluster`, `mailGrid`, `mailSidebar`, `mailColumns`), has no bottom margin. An author's declaration always wins; given a `font-size` without a `line-height`, the line height keeps the ratio of the element's type; the `font` shorthand turns the type defaults off. Every text block (lists and `code` aside) also gets `overflow-wrap:break-word`, so a word too long for its line (a reference, a URL) breaks there instead of running past the message's edge (Roundcube does not break it; capture, 2026-10-03). A default line height never falls below the font's content area, 1.2 em (the default stacks' fonts: Arial and Helvetica 1.15, Roboto 1.17, Georgia 1.14), so glyphs stay inside their line box; the theme's scale (28/36, 22/30, 18/26, 16/24, 14/20) is above it everywhere. A text element (`h1`–`h6`, `p`, `li`, a `td`/`th` holding text directly, and a `mailCluster` with a `separator`, whose separators are text) whose author gave no `color` gets, inline, the colour it would have inherited: the resolved light colour of the nearest ancestor that sets `color`, or the theme's `color.text.primary` when none does. Under `darkMode = designed` it also gets the dark colour it would have inherited, through R-DRK-02's class: the nearest ancestor's dark value when that ancestor has one, `darkFor(color.text.primary)` when the default applies, so its dark colour matches what inheritance gave it. Under `none` and `accommodate` it carries the light value only (R-DRK-02 writes no dark CSS there). An author's own `color` always wins. R-DRK-04 checks the result like any other pair. Without the inline colour, a client whose dark scheme or theme supplies a light default text colour paints the text light on the message's own light background: SnappyMail's dark themes, WebKitGTK (Evolution) and every browser engine under `color-scheme: light dark`. | lower/text, P5 | Cerberus; MJML (read); capture: SnappyMail 2.38 (NightShine), Evolution 3.58 and backend A's engines in their dark schemes; capture of the content-leaf stories in Roundcube 1.6, SnappyMail 2.38 and the desktop clients, 2026-10-02 (headings now match the theme) | ✓ |
| R-TXT-03 | Body text is at least 14 px (P10 warns below 14, `W-A11Y-FONT-SMALL`, and errors below 12, `E-A11Y-FONT-TINY`). Default body 16 px. Checked on every element holding text directly, at the font size it renders with: its own, else the nearest ancestor's; text hidden from readers (`aria-hidden`) is not checked. One exception: a `mailFooter`'s legal text is 12px, which is allowed there only (no warning; below 12px is still `E-A11Y-FONT-TINY`). | P10 | Good Email Code template; iOS text-size behaviour (◐) | ✓ (design rule) |
| R-TXT-04 | Every `a` gets inline `color` and `text-decoration` (underline in body copy for accessibility; none on buttons and navigation). This avoids client default blue and purple. A link in body text (whose inherited colour is `color.text.primary`) is `color.link`; a link in text the author coloured (a footer, a caption) keeps that colour, underlined; a link around images only is not underlined. Under `darkMode = designed` the colour's dark pair follows (R-DRK-02). The author's own values win. | lower/text, P5 | Cerberus: "Styles for underlined links should be inline" (read) | ✓ |
| R-TXT-05 | Font stacks always end in a generic family. Default stacks: sans `Helvetica, Arial, sans-serif`; serif `Georgia, 'Times New Roman', serif`; mono `Menlo, Consolas, 'Courier New', monospace`. An author's `font-family` whose last family is not generic (`serif`, `sans-serif`, `monospace`, `cursive`, `fantasy`, `system-ui`) is `E-VOCAB-BAD-VALUE` (P5). | style/tokens, P5 | community practice | ✓ |
| R-TXT-06 | Auto-detected content (dates, phone numbers, addresses) that must not become a link is protected by R-DOC-05 and R-RST-09. Where the author marks a span `nolink = true`, a zero-width joiner (U+200D) is inserted between each digit and the character next to it, so no run of digits a detector reads as a number remains; the text reads and copies the same. | lower/text | community practice ◐ | ◐ (markup verified; the detectors' behaviour to be confirmed by a real-client capture on iOS) |
| R-TXT-07 | Web fonts: `@font-face` or `<link>` only inside the `NotMso` fonts block (block 4), never inside `@media`, and always with R-OL-07. Supported families only: apple, samsung (not Microsoft accounts), thunderbird, outlookApp (older). Others use the fallback stack. Each `EmailTarget.webFonts` entry is one `@font-face` (`font-family`, `src:url(…) format(…)`, `font-weight`, `font-style`); its URL must be absolute `https` (`E-URL-SCHEME`). The lint declares the at-rule an expected degradation (`I-SUPPORT-DEGRADATION`): the fallback stack is the design for every other family. | P6, P10 | caniemail at-font-face (read) | ✓ |
| R-TXT-08 | `-webkit-text-size-adjust:100%` comes from R-RST-02. Nothing else suppresses user text scaling: an author's `text-size-adjust` (any prefix) other than `100%` or `auto` is `E-VOCAB-BAD-VALUE` (P5). | P5 | MJML; Cerberus (read) | ✓ |
| R-TXT-09 | Lists: `ul`/`ol` get `margin:0 0 {n}px;padding:0;` (`space.4`, none as the last block) and `li` gets `margin:0 0 {m}px {indent}px;` (indent on `li`, following Cerberus; `space.2` and `space.5`, 8px and 24px; on the right, `0 {indent}px {m}px 0`, right to left), plus R-TXT-02's type. Outlook 2021/365 honour `ul` padding and doubled the indent of older fixes (Litmus). `mso-special-format:bullet` is not emitted until R-OL-15 admits it. Custom-marker lists (icon bullets) are a presentation table with `role="list"`/`"listitem"` and an `aria-hidden` marker cell. | lower/text | all | Litmus, "The ultimate guide to bulleted lists in HTML email" (read); Outlook 365 change via search | ◐ (to be confirmed by a Word-engine Outlook capture) |
| R-TXT-10 | Headings keep their semantic level. P7 warns on skipped levels (h1 → h3). | P7 | Email Markup Consortium Accessibility Report 2026 | ✓ |
| R-TXT-11 | **Quotations are not `blockquote`s in the output.** Webmails fold a `blockquote` away as quoted mail (SnappyMail hides it behind its quoted-text toggle; Evolution greys it and Geary boxes it), so a template's `blockquote` is lowered to a `div` with R-TXT-02's defaults, `padding:0 0 0 16px` and a `3px solid` start-side border in `color.border.subtle` (mirrored right to left). The semantic tree keeps the `blockquote`. | P4, lower/text | capture of the content-leaf stories in SnappyMail 2.38, Evolution 3.58 and Geary 46, 2026-10-02 | ◐ (verified in the self-hosted webmails and the desktop clients; hosted webmails to be confirmed on backend B) |
| R-TXT-12 | **Navigation links** (`mailNavbar`). A `mailCluster` of links, one per `mailNavLink`, 24px apart by default (`gap`, R-TBL-12), centred by default, with the cluster's `separator`. Each link is `color.link` (dark-paired under `darkMode = designed`), bold (700: a 600 face is missing from common font sets, which then substitute another family), not underlined (R-TXT-04: navigation), `font.body` and `type.body` (a link carries its own family, R-TXT-02), and `display:inline-block;padding:10px 0;`, so its hit area is 44px tall where padding on a link is honoured (not in Word, R-OL-05, a desktop client). Wrapped lines are 8px apart (the cluster's `row_gap`), so hit areas keep R-TBL-12's spacing. A label with a word longer than 20 characters breaks inside its link (`word-break:break-word`, R-TBL-17; on every link Word's one-line row would squeeze labels into pieces), and the separator takes `color.text.secondary` (dark-paired), never a client's default colour (R-TXT-02). A navbar never collapses to a menu: its row wraps (the cluster's); for Word, which never wraps a row, links that do not fit the box on one line (their widths estimated from the text metrics, 16px bold) get a ghost row per line, each after the first with the row gap above its cells. | lower/cluster, P5 | MJML mj-navbar (read); design rule | ◐ (verified in the browser engines, the self-hosted webmails and the desktop clients) |
| R-TXT-13 | **Every link goes somewhere a mail client can open.** The `href` of every `a` of a template (one a pattern writes included, and a `mailMarkdown` link) and of a linked `mailImage` is an absolute https URL, or a `mailto:` or `tel:` one, as R-BTN-07 requires of buttons: none, an empty one or one starting with `#` is `E-URL-EMPTY`; a relative URL, `http:`, `javascript:`, `data:` or any other scheme, or a URL holding white space, a quote or an angle bracket, is `E-URL-SCHEME`. A mail client has no page to resolve a relative URL against, and `#` goes nowhere. A link that a `mailButton`, `mailNavLink` or `mailSocialItem` expands into, carrying that element's own `href` (compared without surrounding white space, as the expansion writes it), is not checked again: R-BTN-07 reports it once, on the element. A correctness check, not a security filter: markup inside `mailRaw` keeps R-RAW-01–R-RAW-03 (an unsupported scheme there is `W-RAW-UNSUPPORTED`). | P1 | design rule | ✓ |

## 11. DRK — Dark mode

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-DRK-01 | Families that honour `prefers-color-scheme`: apple, outlookApp, outlookWeb (limited), samsung, fastmail. Families that do not: gmail*, ganga, yahoo (mangled), outlookWord, proton; hey rewrites it to `(false)`; thunderbird applies no `@media` rule at all (it removes every conditional rule from a message, R-LAY-12) and takes the dark palette from R-DRK-08's copies instead, without the image swap. | target | caniemail css-at-media-prefers-color-scheme (read); capture of Thunderbird 150.0.1, 2026-10-03 (R-DRK-08) | ✓ |
| R-DRK-02 | For every element whose token colour has a different dark value: the element's dark class, R-CSS-08's generated name (`e-` + the hash of the `dark` variant and its declarations; there is no separate `e-dk-` prefix), and, in block 3, `@media (prefers-color-scheme: dark){.e-…{color:{dark} !important;}}` (and `background-color` and the border colours likewise). The dark value comes from the element's own `@dark:` declaration when it has one; otherwise P5 pairs every `color`, `background`/`background-color` and border colour resolved from a `tok"…"` with that token's dark value (token-driven: a designed template needs no `@dark:` of its own; a token whose two values are equal needs no rule; a raw colour has no dark value and warns, `W-DARK-RAW-COLOR`); a text element without a colour of its own gets the pairing it would have inherited (R-TXT-02). The skeleton's surfaces follow the token path: a designed `mailDocument` without a background is painted `color.surface.card` (`#ffffff` in the default theme, so the light bytes are unchanged), and its dark class reaches the article wrapper and the wrapper table; the page below the message, `<body>`, carries no class (R-DOC-14), so block 3 selects the element: `body{background-color:{the document's dark value} !important}` inside the query (no Outlook copy: Outlook.com keeps no body). A shadowed `mailBox` without a border of its own gets the dark colour of its derived border (R-TBL-09: one step darker than the box's dark background, else the nearest ancestor's). **Image backdrops keep one colour.** A band with a background image (R-VML-01), and every element whose backdrop is that image (no element with a background of its own between them), is not paired: the image does not change with the scheme, so neither does its fallback colour nor the text and lines over it (a token that flips would put dark text on a light image, or a dark fallback under the light text of a dark one), and a raw colour there is not `W-DARK-RAW-COLOR`; an element's own `@dark:` still applies. A card with a background of its own inside the band is its own backdrop and is paired as usual. The dark class is named after both values of each declaration (R-CSS-08's hash over `light-dark({light},{dark})`), so two elements that share a dark value but not a light one get two classes and R-DRK-08's copy of each is exact. Only under `darkMode = designed`. `none` and `accommodate` write no dark CSS at all (no block 3, no R-DRK-03 copies, no dark classes); `accommodate` keeps R-DOC-07's metas, R-DRK-08's Thunderbird block and the inversion lint. | P5, P6 | Cerberus (read) | ✓ |
| R-DRK-03 | Outlook.com and the Outlook apps: the same classes (R-DRK-02's generated names) get `[data-ogsc] .e-…{color:{dark} !important;}` and `[data-ogsb] .e-…{background-color:{dark} !important;}` in block 3, **outside** the media query: a `[data-ogsc]` copy carries the `color` declarations only and a `[data-ogsb]` copy the `background-color` ones only (border colours are not copied). R-IMG-06's swap rules get `[data-ogsc]` copies. Outlook adds these attributes itself when it recolours. | P6 | caniemail note (read); Litmus dark-mode guide ◐ | ◐ to be confirmed on backend B (Outlook.com dark toggle) |
| R-DRK-04 | Contrast in every scheme, and inversion simulation. WCAG 2 contrast ≥ 4.5:1 (≥ 3:1 for text ≥ 24 px, or ≥ 18.66 px bold) is required for every text/background pair in light (`W-A11Y-CONTRAST`, R-A11Y-07), in the designed dark scheme (`E-A11Y-CONTRAST`, under `designed` when block 3 survives: each side its dark value where a dark rule paints one) and after two models of a client that recolours the message itself (P10, under `accommodate` and `designed`: `W-A11Y-CONTRAST-INVERTED` for a model marked calibrated, `I-A11Y-CONTRAST-INVERTED`, information only, for one that is not; each model has its own calibrated flag in the lint, `modelCalibrated`, set when its formula is recorded here). The models invert a colour's OKLCH lightness (L → 1 − L, chroma and hue kept). **Partial** (stands for the Gmail app on Android, Outlook.com's automatic dark mode and Outlook 365 for Windows: families gmailApp, outlookWeb, outlookWord): every background with relative luminance > 0.5 is inverted, every text colour with luminance < 0.5 is inverted, the rest kept. **Full** (the Gmail app on iOS: gmailApp): both are inverted. The pairs are the light scheme's, the same text elements and backgrounds the light check reads (a button's label on its fill; text over a band's background image against its fallback colour). Text over a background image is checked twice under each model and the worse holds: on the recoloured fallback colour (images blocked), and recoloured on the fallback colour as it is, which stands for the image: no model recolours an image (measured on Blink's automatic dark mode, which lightens dark text and leaves a background image as it is). One warning per model and pair, at its first element, counting the others; weighted by the profile, and not checked when the model's families have no weight. Neither model is calibrated yet, so both report information: under them the default palette's mid-tone colours (the link, `#0969da`, and the accent button's white label, under full inversion) fall below 4.5:1, and the default palette is checked against the calibrated models when they exist. | P10 | Litmus dark-mode guide (behaviours ◐); the algorithm is our model | ☐ uncalibrated: calibrate both models against Gmail-app (full) and Outlook.com (partial) captures on backends B and C, and record the calibrated formula here |
| R-DRK-05 | The Gmail iOS blend-mode hack is **not** emitted. | — | hteumeuleu.com, "Fixing Gmail's dark mode issues with CSS blend modes" | ✓ (decision) |
| R-DRK-06 | Logos and icons in light mode must be legible on both white and near-black (`#121212`): transparent PNG with a ≥ 2 px contrasting outline or padding plate, checked by the alpha heuristic on the light image of every `dark_src` pair (P10, after P8, under `accommodate` and `designed`): an image with no transparent pixel is its own plate; otherwise its edge (the opaque pixels within 2 px of a transparent one) must, on each background, contrast ≥ 3:1 with it over at least half its pixels, or be a plate (90% within 1.5:1 of its mean colour, holding content that contrasts ≥ 3:1 with it over 5% of the pixels inside). A failure is `W-DARK-LOGO-UNSAFE`, naming the background it fails on and the families that show the light image in dark mode (R-DRK-01's non-honouring families). An image whose bytes the render does not hold (not resolved through the asset store), or that is not a non-interlaced PNG whose chunk CRCs, zlib header and Adler-32 verify, is not checked; one over 4096 × 4096 pixels is not decoded and reports `I-DARK-LOGO-UNCHECKED` (information). | P10, assets | Litmus dark-mode guide (◐) | ◐ (to be confirmed by dark-mode captures) |
| R-DRK-07 | Pure `#000000` on `#ffffff` brand blocks are avoided in `designed` themes. The theme generator nudges them to `#111111` / `#fefefe`, because some inverters treat pure values specially. | style/tokens | inference from the Litmus dark-mode guide | ☐ (to be settled by dark-mode captures) |
| R-DRK-08 | **Thunderbird.** Measured on Thunderbird 150.0.1 (its source, `DarkReader.mjs` and `messageBody.css`, and captures, 2026-10-03). Thunderbird removes every `@media` and `@supports` rule from a message's `<style>` (pref `mail.html_sanitize.drop_conditional_css`, on by default; plain rules stay), so block 3's query never applies (nor R-LAY-02's, R-LAY-12). In its dark theme with dark message mode on (`mail.dark-reader.enabled`, the default), after the message loads it adapts it: the `bgcolor`/`color` attributes go; in every inline style and every top-level `<style>` rule that sets a colour, a background lighter than luminance 200 of 255 (`0.2125R+0.7154G+0.0721B`), or under 3.5:1 by its own ratio with the element's colour, is removed, and a text colour of luminance ≤ 200 then goes too; gradients go; borders and images stay. The message page gets Thunderbird's dark background and white text, and the message root `color-scheme: dark`. It skips all of this when the root element's computed `filter` contains `invert(1)` or `prefers-color-scheme: dark`. **Emission.** When the colour-scheme metas are written (`accommodate`, `designed`), block 6 is one rule, `html:has(.moz-text-html){filter:url("#prefers-color-scheme: dark")}`: Thunderbird reads it as "the message handles its own colours" and leaves it alone; the URL names no element, so no filter applies (pixel-identical in light, measured up to 4,800 px tall, where `invert(1) invert(1)` rasterises a tall message blurred); `.moz-text-html` is Thunderbird's message wrapper, so the rule matches no other client's root, and it is a `<style>` of its own so a client that drops a block over the `:has()` selector loses nothing else. So an `accommodate` message keeps its light design in Thunderbird's dark theme, as in the clients that honour its metas (R-DRK-01). Under `designed`, block 3 also carries, after the query, a copy of each of its rules for Thunderbird: `.moz-text-html .e-…{color:light-dark({light},{dark}) !important;…}` (colour, background colour and border colours, R-DRK-02's light and dark values) and `body:has(.moz-text-html){background-color:light-dark(…) !important}`; the message root's `color-scheme` picks the value (dark in Thunderbird's dark mode, light otherwise, so light renders unchanged). R-IMG-06's swap has no copy (`display` has no scheme-dependent value without a query): Thunderbird shows the light image of a pair, which R-DRK-06's check covers. Under `none` (no metas) nothing is written and Thunderbird adapts the message. | P6 | Thunderbird 150.0.1 source (`chrome://messenger/content/DarkReader.mjs`, `messageBody.css`, the pref default) and captures of probes and the dark, button and background stories, light and dark, 2026-10-03 (`tools/capture/emulation/RULES.md`) | ✓ |

## 12. A11Y — Accessibility

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-A11Y-01 | `lang`/`dir`: R-DOC-02. | P7 | EMC 2026 (read) | ✓ |
| R-A11Y-02 | `role="presentation"` on every layout table; `role="table"` plus a `caption` on data tables (`mailTable`). | P7 | EMC 2026 (read) | ✓ |
| R-A11Y-03 | At least one `h1`; R-TXT-01, R-TXT-10. | P1, P7 | EMC 2026 (read) | ✓ |
| R-A11Y-04 | `alt` on every image: R-IMG-04. | P1 | EMC 2026 (read) | ✓ |
| R-A11Y-05 | `aria-hidden="true"` on spacers, the preheader padding and decorative VML. Dark-swap duplicates (R-IMG-06) carry **no** `aria-hidden`: whichever image of the pair is hidden is `display:none` (inline, or by the dark block), which takes it out of the accessibility tree already, and an `aria-hidden` on the dark copy would stay on it after the swap, when the light one is `display:none`, leaving a reader neither. Both carry the alt text. (Settled 2026-10-03: the rule first listed the hidden duplicate here.) | P7, lower/image | Email Markup Consortium Accessibility Report 2026; Good Email Code template (read) | ✓ |
| R-A11Y-06 | Link text is meaningful out of context: "click here", "here", "read more" and bare URLs as link text warn. | P10 | Email Markup Consortium Accessibility Report 2026 | ✓ (design rule) |
| R-A11Y-07 | Contrast: R-DRK-04 applies to every scheme. | P10 | Email Markup Consortium Accessibility Report 2026 | ✓ |
| R-A11Y-08 | Document order is reading order. No pass reorders children, and visual reordering uses R-LAY-11. | all passes | Email Markup Consortium Accessibility Report 2026 | ✓ |
| R-A11Y-09 | Data tables use `th scope="col"`/`"row"` (P7 backfills a missing `scope`: `col` in a `thead` or a row of header cells only, else `row`). The hidden caption is `mso-hide:all` plus visually-hidden CSS inline (`position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);`) — but `position` is unsupported in several families, so P10 must accept this declared degradation (the caption shows). The caption is written `<caption style="mso-hide:all;position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);">{caption}</caption>` as the data table's first child (R-TBL-18). | lower/data_table | inference | ◐ (the caption hidden in the browser engines, the self-hosted webmails and the desktop clients; families that drop `position` to be confirmed on hosted webmail) |
| R-A11Y-10 | The HTML5 sectioning and interactive elements `nav`, `main`, `article`, `section`, `header`, `footer`, `aside`, `details` and `summary` are **never emitted**. Gmail replaces some with `<u>`, and others strip them. Landmark intent uses `role` on a **table** (Yahoo keeps `role` only on tables): `mailCluster(role = navigation, label)` (a `mailNavLinks`) sits in a one-cell table with `role="navigation"` and `aria-label`. The article wrapper `div` (R-DOC-10) is the one `role` on a div, kept because it is wrapper-level and survives in the clients that matter for it. P10 checks the emitted document too: a sectioning element anywhere in it, whoever produced it, is `E-A11Y-SECTIONING`. | P1, vocabulary, P10 | all | caniemail html-semantics, html-role (read) | ✓ |
| R-A11Y-11 | Target size, the capture's Tier-3 `touch` check: WCAG 2.2 Success Criterion 2.5.8 Target Size (Minimum), level AA. A visible link or button passes when its box is at least 24 × 24 CSS px, or when a 24px-diameter circle centred on its box intersects no other target and no other undersized target's circle (the spacing exception). A link in a sentence or a block of text, an inline element whose block holds text outside any target, is exempt (the inline exception). A target's box is the union of its client rects, so a wrapped inline link is measured by its lines (WebKit reports such a link's bounding box 0px tall; the WebKit builds the capture pins report its line boxes 0px tall too, at the baseline, and the check gives each of an inline element the height of its font's line, at most its line height; a box its CSS makes 0px tall stays 0px tall, and undersized). The 44px of R-BTN-06 (buttons) and R-TBL-12 (links in a row) stays the recommendation, checked by P10 as `W-A11Y-TAP-TARGET`, not by this gate. | capture (`tools/capture/dom_assertions.ts`) | W3C, WCAG 2.2 SC 2.5.8 Target Size (Minimum) (read) | ✓ |

## 12b. RAW — Raw markup and explicit client targeting

`mailRaw` is the escape hatch for markup the vocabulary cannot express,
and `mailIf` the only way to target clients by name. `mailRaw` is for HTML
the author trusts: it is written byte for byte, and it is not a sanitiser
(the library does not try to stop anyone sending a hostile message; that
would only get in the way of legitimate markup). Its checks are authoring
aids: errors for markup that would break the message the library builds
around it, warnings for what clients strip, and the same lint as generated
HTML.

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-RAW-01 | **Read, linted, kept verbatim.** Each `raw` payload inside a `mailRaw` is read, one payload at a time, into a tree of its own (elements with their attributes and their inline `style` declarations, text, and conditional comments as conditionals). The output is the payload, byte for byte. The tree goes through the checks generated HTML goes through: P1's (alt text, R-IMG-04; no sectioning element, R-A11Y-10) and P10's (client support of every property, value, element and attribute; link text, R-A11Y-06; contrast, R-A11Y-07; alt length; image formats, R-IMG-08; layout tables and spans, R-TBL-01, R-TBL-06; the closed `mso-*` list, R-OL-15). | raw, P1, P10 | design rule | ✓ (design rule) |
| R-RAW-02 | **Nothing that breaks the message's structure** (`E-RAW-MALFORMED`). The payload's tags and comments are read as the HTML Standard's tokenizer reads them (a comment ends at its first `-->` or `--!>`, `<!-->` and `<!--->` are whole comments, a quoted `>` ends no tag, the content of `script`, `style`, `textarea`, `title`, `xmp`, `iframe`, `noembed` and `noframes` is text up to its end tag); the tree builder is not modelled, so balance is asked for explicitly. The checks cover plausible authoring mistakes and a fixed corpus of parser probes; what the reader cannot verify is refused rather than modelled, and further exotic parser behaviour is handled as an issue when found. It is an error when it: holds `<noscript>` (its content is text with scripting on and markup with it off, and scripts never run in email); holds `<svg>` or `<math>` (a parser reads parts of inline SVG and MathML as HTML, on HTML tags, in `foreignObject`, `title`, `mi` and the like, and the content of `style` or `script` there is markup, so their structure cannot be checked without modelling foreign content; mail clients largely do not render them, and the template vocabulary refuses `svg` too: use an image); leaves a tag, comment, quoted value or raw-text element open, or holds `<plaintext>` (each would swallow the markup after it), or has `<!--` inside `script` or `style` (in a script it can keep a parser in script text past `</script>`); leaves an element open (void elements aside; `<div/>` is open, as HTML ignores the `/`), closes over an element still open, or has an end tag for no element it opened (it would close the library's markup); has a table part (`td`, `th`, `tr`, `tbody`, `thead`, `tfoot`, `caption`, `col`, `colgroup`) outside a `table` it opens (a parser reads it against the table the payload sits in and closes the host cell); in a text element, has an element that closes a paragraph; in a link, has a link; in a list item, has an `li` outside a `ul` or `ol` it opens (a parser closes the host item through `div` and `p`); sits directly in table structure, a list, `mailSocial` or `mailNavbar`. Conditional comments must be one of R-OL-01's two forms, `[if` and `[endif]` matched without case (as Word matches them), with a condition from R-OL-02's set, closed in the same payload and closing none they did not open. Inside a conditional, and anywhere in a payload inside a `mailIf` (or a `mailTable` or `mailButton`, whose content the library may copy into Word's conditional), there is no comment, no conditional and no `<!--`, `-->`, `--!>` or `<![`, not even in an attribute value: comments do not nest, so any of them would end the conditional early and show Word-only content to every client. A payload with an error is not written (the error blocks sending; the rest of the message stays inspectable). | raw | HTML Standard, tokenization (read); R-OL-01 | ✓ (design rule) |
| R-RAW-03 | **What clients strip is written, with a warning** (`W-RAW-UNSUPPORTED`). The elements the vocabulary refuses in templates (`script`, `iframe`, `object`, `embed`, `form`, `input`, `video`, `audio`, `canvas`; `svg` is refused under R-RAW-02), event-handler (`on*`) attributes, a `javascript:` or `vbscript:` URL in `href`, `src`, `action`, `formaction` or `background` (the scheme read as a URL parser reads it: character references decoded, tabs, newlines and leading controls dropped, case ignored), and a VML or Office element (`v:`, `o:`, `w:`) outside an `mso` conditional. Each is written byte for byte all the same; the warning says that mail clients strip it (VML: that only Word shows it). Nothing else is reported for what it might do. | raw | caniemail html-form, html-object, html-video, html-audio (read); the vocabulary's own refusals (`E-VOCAB-FORBIDDEN-TAG`, `E-VOCAB-EVENT-HANDLER`) and URL policy (`E-URL-SCHEME`); R-VML-01 | ◐ (the stripping of `script`, `iframe`, `embed`, `canvas`, event handlers and `javascript:` URLs to be confirmed in captures of the webmail sanitisers) |
| R-RAW-04 | **Placement and audit.** A raw node outside `mailRaw` is `E-STRUCT-RAW-OUTSIDE` (P1). Every `mailRaw` is reported once as `I-RAW-USED` (information), so an audit counts the escape hatches a template uses. `mailRaw` is lowered to its payloads, with nothing around them. | P1, P4 | design rule | ✓ (design rule) |
| R-RAW-05 | **`mailIf(mso)`.** `mso = true` puts the lowered content inside `<!--[if mso]>…<![endif]-->`, `mso = false` inside `<!--[if !mso]><!-->…<!--<![endif]-->` (R-OL-01); `family = outlookWord` is `mso = true`. Exactly one of `mso` and `family` is given; any other value is `E-VOCAB-BAD-VALUE`. Conditional comments cannot nest (the first `-->` closes the outer comment for every other client), so the content is lowered first and its own conditionals are flattened: inside an `mso` block an inner `mso` conditional is unwrapped (its content is Word's already) and inner `!mso` content is dropped (Word never shows it); inside a `!mso` block the reverse. Raw markup is not flattened: a `mailRaw` payload inside a `mailIf` holds no comment and no comment delimiter at all (R-RAW-02). Without `outlookWord`, `mso = true` content is dropped (P9) and `mso = false` content is written without the conditional. | lower/conditional, mso/cond | R-OL-01; design rule | ✓ (design rule) |
| R-RAW-06 | **`mailIf(family = thunderbird)`.** The content sits in a block hidden inline, `display:none;max-height:0;overflow:hidden;` (a `div`, or a `span` inside text), with the class `e-if-tb` (`e-if-tb-i` for the `span`), shown only in Thunderbird by `.moz-text-html .e-if-tb{display:block !important;max-height:none !important;overflow:visible !important;}` (`display:inline` for the `span`), written in the responsive block outside any media query (R-LAY-12's prefix), whatever `thunderbirdMq` says. The block is inside `!mso` (Word is not Thunderbird) and flattened as R-RAW-05. A family set holding both `outlookWord` and `thunderbird` writes both forms, Word's first. Any other family is `E-VOCAB-BAD-VALUE`: Outlook web's `[owa]` prefix (R-LAY-13) waits for a hosted-webmail capture that shows it. | lower/conditional, P6 | MJML mediaQueries.js (read); capture of Thunderbird | ◐ (verified in Thunderbird and in the other local clients, which hide the block) |

## 13. SIZE — Size and clipping

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-SIZE-01 | The decoded HTML (the text/html part after transfer decoding) must be ≤ `sizeBudget` (90,000 bytes): warning above, error above 100,000. Gmail clips at about 102 KB of raw HTML. Clipping hides the footer and unsubscribe link, and removes `<style>` (R-CSS-18). | P10 | Litmus, "How to keep Gmail from clipping your emails" ◐; hteumeuleu/email-bugs #41 | ◐ the clip threshold is to be measured on backend B with a near-limit story, and recorded here |
| R-SIZE-02 | Size diagnostics report the contributors: head CSS, inline styles, URLs (tracking parameters included), preheader padding, MSO/VML. This lets an author see what to cut. | P10 | design rule | ✓ |
| R-SIZE-03 | The URL-rewrite hook (UTM, tracking) runs **before** the size check. | P8, P10 | inference: URL length counts toward the clip size | ✓ |

## 14. MIME — Message structure and encodings

Every rule in this section was checked against the RFC text on 2026-09-27.

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-MIME-01 | Structure: `multipart/alternative` with `text/plain` **first** and the HTML part **last**. RFC 2046 §5.1.4 orders alternatives by "increasing faithfulness … with the preferred format last". | mime | RFC 2046 §5.1.4 | ✓ |
| R-MIME-02 | With `cid:` images, the HTML part is wrapped in `multipart/related; type="text/html"`. The `type` parameter is mandatory: RFC 2387 §3.1, "The type parameter must be specified". The HTML is the first (root) part. | mime | RFC 2387 §3.1 | ✓ |
| R-MIME-03 | Attachments wrap everything in `multipart/mixed`. | mime | RFC 2046 | ✓ |
| R-MIME-04 | Boundaries are 1–70 characters from the `bcharsnospace` set, never ending in a space, and verified absent from every part body. | mime | RFC 2046 §5.1.1 (`boundary := 0*69<bchars> bcharsnospace`) | ✓ |
| R-MIME-05 | Both text parts use `Content-Transfer-Encoding: quoted-printable`. Encoded lines are ≤ 76 characters (RFC 2045 §6.7 rule 5, "no more than 76"). A soft break is `=` at end of line. `=` is always `=3D`. A space or tab before a line break is encoded (`=20`/`=09`). Bytes ≥ 0x80 become `=XX`. | mime/qp | RFC 2045 §6.7 | ✓ |
| R-MIME-06 | Text parts are `charset=utf-8`. The text part is `format=flowed` (RFC 3676). If `DelSp` is not used, trailing spaces mark soft breaks, and lines starting with space, `>` or "From " are space-stuffed. | mime, text | RFC 3676 | ✓ |
| R-MIME-07 | **No encoded line starts with `.`**. The QP encoder emits a leading `.` as `=2E`. This guards against non-compliant SMTP clients: per RFC 5321 §4.5.2 a compliant client doubles a leading period, and the server deletes the first one, so a buggy client loses it. | mime/qp | RFC 5321 §4.5.2 | ✓ |
| R-MIME-08 | Lines (any part, including headers) are ≤ 998 characters (MUST) and are kept ≤ 78 (SHOULD), excluding CRLF. QP and base64 guarantee this for bodies. The header folder guarantees it for headers. | mime | RFC 5322 §2.1.1 | ✓ |
| R-MIME-09 | Binary parts are base64, in 76-character lines. | mime | RFC 2045 §6.8 | ✓ |
| R-MIME-10 | Non-ASCII in `Subject` and in display names uses RFC 2047 encoded-words (`=?UTF-8?B?…?=`, or `Q` when mostly ASCII). Each encoded-word is ≤ 75 characters ("may not be more than 75 characters long"). Several encoded-words are separated by CRLF SPACE. Encoded-words are never used inside an addr-spec. | mime/headers | RFC 2047 §2, §5 | ✓ |
| R-MIME-11 | `cid:` references use the `Content-ID` value **without** angle brackets. The `Content-ID` header has them: `Content-ID: <logo.a1b2@example.com>` pairs with `src="cid:logo.a1b2@example.com"`. Inline images also carry `Content-Disposition: inline; filename="…"`. | mime | RFC 2392 | ✓ |
| R-MIME-12 | `MIME-Version: 1.0`, `Date` (RFC 5322 date-time, from the time facade), and a `Message-ID` of the form `<{id}@{sender-domain}>`, suppliable for deterministic tests. | mime/headers | RFC 5322 §3.6 | ✓ |
| R-MIME-13 | CRLF line endings throughout the serialised message. | mime | RFC 5322 | ✓ |

## 15. SND — Headers the receiving system acts on

| ID | Rule | Where | Source | Status |
|---|---|---|---|---|
| R-SND-01 | One-click unsubscribe: exactly one `List-Unsubscribe` header containing **one HTTPS URI** (optionally also a `mailto:`), and exactly one `List-Unsubscribe-Post: List-Unsubscribe=One-Click`. | mime/headers | RFC 8058 §3.1 | ✓ |
| R-SND-02 | The unsubscribe URI must identify recipient and list by itself; there are no extra POST arguments. It should contain an opaque, hard-to-forge token. The library's `Unsubscribe` type takes the full URI and refuses one without a query or path token of at least 16 characters (warning). | mime/headers | RFC 8058 §3.1 | ✓ |
| R-SND-03 | Documented for the sender's server, implemented by the library's one-click endpoint half (`checkOneClickRequest`, `oneClickResponse`), and checked by the test suite's one-click unsubscribe server fixture: the POST carries no cookies or auth; the server must not answer with a redirect; the body is `List-Unsubscribe=One-Click` as `multipart/form-data` or `application/x-www-form-urlencoded`. | docs, mime/one_click, tests | RFC 8058 §3.1–§3.2 | ✓ |
| R-SND-04 | Both headers must be covered by a DKIM signature (`h=` tag). DKIM is the ESP's job. `toMessage` records in the message metadata that DKIM must include them, and the Mailgun transport sets no option that would exclude them. | docs, transport | RFC 8058 §4 | ✓ |
| R-SND-05 | Transactional helpers set `Auto-Submitted: auto-generated`. | mime/headers | RFC 3834 | ◐ |
| R-SND-06 | Bulk-sender context, for docs only: Gmail and Yahoo require SPF+DKIM, aligned DMARC, one-click unsubscribe for marketing mail, and a spam rate < 0.3% (from Feb 2024; stricter enforcement from Nov 2025). Microsoft requires SPF/DKIM/DMARC above 5,000/day (from 2025-05-05). | docs | Google sender guidelines (support.google.com/mail/answer/14229414); Microsoft high-volume sender requirements (via search) | ◐ |

## 16. INT — Interactive content (optional)

| ID | Rule | Source | Status |
|---|---|---|---|
| R-INT-01 | Interactive components use the checkbox/radio hack (hidden `input` + `label` + `:checked ~`). Their **unchecked** state is a complete, static presentation of all content. Gmail and Outlook do not support `:checked`. | Email on Acid, Gmail development article (read) | ✓ |
| R-INT-02 | `:hover` is decoration only (block 5). It works in apple, outlookWeb and gmailWeb only. Hover rules carry `!important`, because they must beat inline values (R-CSS-03) | Email on Acid, Gmail development article (read) | ✓ |
| R-INT-03 | No forms, no `details`/`summary` (support unverified), no AMP part. | caniemail html-form; caniemail amp | ✓ (decision) |

---

## 17. BUG — Symptom index

This maps the common rendering bugs to the rules that prevent
them. A reviewer or agent who sees a symptom in a capture starts here.

| Symptom | Clients | Rules |
|---|---|---|
| Gap under images | Outlook, Gmail, Yahoo | R-IMG-01, R-IMG-02 |
| Whole email laid out at 600px in Samsung | Samsung | R-IMG-11 |
| 1px line under images | Outlook 2013–2019 | R-TBL-13 |
| Image cell misaligned beside text | Outlook | R-TBL-07 |
| Squeezed desktop layout on phones | Gmail app (non-Google), Gmail after a dropped block | R-TBL-11 |
| Ragged card bottoms in a row | all non-Word | R-TBL-10 |
| Padding or background missing on div blocks | Outlook | R-TBL-02 |
| Uneven vertical padding in a row | Outlook | R-TBL-03 |
| Colour showing between dashes | Outlook 2007/2010 | R-TBL-08 |
| Bullets double-indented | Outlook 2021/365 | R-TXT-09 |
| Tags turned into underlines (`<u>`) | Gmail | R-A11Y-10 |
| Gap between inline-block columns | all | R-LAY-04, R-LAY-05 |
| 1-px lines or gaps between tables | Outlook | R-RST-05, R-RST-06 |
| Content full-width on desktop | Outlook | R-OL-03, R-LAY-06, R-LAY-07 |
| Margins ignored or background bleeding | Outlook | R-OL-04 |
| Padding on links/divs ignored | Outlook | R-OL-05, R-BTN-01 |
| Uneven line heights | Outlook | R-OL-06 |
| Missing background images | Outlook | R-OL-11, R-VML-01 |
| Square corners | Outlook | R-OL-12, R-BTN-02, R-BTN-04 |
| Times New Roman | Outlook | R-OL-07, R-TXT-07 |
| Images wrong size at 120 DPI | Outlook | R-DOC-08, R-OL-08, R-OL-16 |
| Blue auto-links on dates or phones | iOS, Gmail | R-DOC-05, R-RST-09, R-TXT-06 |
| Gmail iOS right gutter | Gmail iOS | R-RST (candidate `u ~ div .email-container{min-width:…}`; not in the reset until a capture shows the gutter; add as R-RST-14 with evidence) |
| All head styles gone | Gmail | R-CSS-03…R-CSS-07, R-CSS-09, R-CSS-10 |
| Message clipped, footer missing | Gmail | R-SIZE-01…03 |
| Grey text in threads | Gmail | R-RST-10 |
| Download icon over images | Gmail | R-RST-11 |
| Narrow in Samsung | Samsung | R-RST-04 |
| Text auto-resized | iOS | R-RST-02 |
| Email auto-scaled | iOS | R-DOC-06 |
| Logo vanishes in dark | Gmail, Outlook.com, Apple | R-IMG-06, R-DRK-06 |
| Inverted buttons unreadable | Gmail iOS | R-DRK-04 |
| Media queries ignored | Yahoo, AOL | R-CSS-10 |
| Thunderbird ignores responsive rules | Thunderbird | R-LAY-12 |
| CSS or URLs broken at random points | SMTP relays | R-MIME-05, R-MIME-08 |
| First `.` of a line missing | buggy SMTP | R-MIME-07 |
| `=` sequences corrupt URLs | QP decoding | R-MIME-05 |

## 18. INV — Invariants every rendered message satisfies

These are the `t3_*` invariant tests. They run over every story,
with `outlookWord` on and off:

1. Every `table` has `role` (R-LAY-15, R-A11Y-02).
2. Every `img` has `alt`, a `width` attribute and `display:block` (R-IMG-01, R-IMG-04), but for the forms the library writes on purpose: R-IMG-03's inline form (`vertical-align:middle`, no `display`) and R-IMG-06's hidden dark copy (`display:none` until the dark block shows it).
3. Head CSS parses; it is lower-case (`!important`), has no nested
at-rules, uses only allowed selectors and media features, and fits the
budget (R-CSS-03…R-CSS-10).
4. Decoded HTML ≤ budget (R-SIZE-01).
5. No encoded line > 76 characters, and none starts with `.` (R-MIME-05, R-MIME-07).
6. Conditional comments are balanced; there is no MSO or VML output
when `outlookWord = false` (R-OL-01).
7. The text part is non-empty and contains no markup.
8. `lang`/`dir` are on `html` and the wrapper; there is an `h1` (R-DOC-02, R-A11Y-03).
9. No `var(`, `data:`, `javascript:`, `<script`, `on*=`, `data-hk`
or `data-isonim-` anywhere the library generates (R-CSS-11, R-IMG-08);
a `mailRaw` payload is the author's, written as it is (R-RAW-03).
10. No whitespace between inline-block column siblings (R-LAY-05).
11. No `nav`/`main`/`article`/`section`/`header`/`footer`/`aside`/
`details`/`summary` elements (R-A11Y-10).
12. No non-MSO `img` with a px `width` attribute that renders at its
container width (R-IMG-11).
13. No non-MSO layout table outside the R-TBL-01 constructs; no empty
unsized cells (R-TBL-01, R-TBL-05).

## 19. Change log

- 2026-09-27: Initial catalogue, from published HTML-email practice and
  client-capture tooling. MIME and RFC 8058 rules verified against RFC texts.
- 2026-09-27: Div-first adopted after a survey of layout patterns: R-LAY-01, -04,
  -06…-09 and -14 rewritten; §4b TBL added; R-IMG-11 (Samsung split),
  R-A11Y-10 (no sectioning elements) added; R-TXT-09 revised (Outlook 365
  list indent).
- 2026-09-29: Implementation issues resolved: R-RST-13 owns reset
  line 8; R-CSS-09's fixed set lists R-RST-08 and the literal selectors;
  R-LAY-16 admits `mailColumns`. From code review:
  R-CSS-07 gains `W-CSS-OVER-BUDGET`; R-INT-02 hover rules carry `!important`.
- 2026-09-29: Published in this repository as `docs/rendering-rules.md`.
- 2026-09-30: Source and status cells restated to name public sources
  and the capture that settles each open rule.
- 2026-09-30: R-CSS-05 names the characters and shapes the serialiser
  rejects; R-CSS-08 hashes the variant with the declarations; R-CSS-16
  keeps a shorthand before its longhands.
- 2026-10-01: R-CSS-16's sorting covers generated rules only, and §2
  states that the reset is emitted verbatim in catalogue order (equal
  specificity resolves by source order). R-DRK-02 limits dark CSS to
  `darkMode = designed`.
- 2026-10-01: From the first real review loop over the self-hosted
  webmails and the desktop clients: R-DOC-14 (no `class` on
  `<body>`, Roundcube) added and the §1 skeleton changed to match;
  R-IMG-01's fixed-size stack is `width:{w}px;max-width:100%`
  (Thunderbird's `shrinktofit`) with an alignment margin (litehtml);
  R-TXT-02 gives text elements without a colour the colour they
  would have inherited (the nearest coloured ancestor's, else
  `color.text.primary`), dark-paired under `darkMode = designed`.
- 2026-10-02: Div-first scaffolding built and checked against MJML 5's
  Outlook geometry. §4.1 follows MJML's rounding (each column on its
  own; no remainder on the last column), truncates lengths, reads
  percentages at full precision and names the implicit single column.
  R-LAY-08 drops the unused `e-sec` class, gives the inner div the
  merged column's `font-size:16px` and an `align` attribute, defaults
  the alignment to the start of the direction, and moves the div border
  to a frame Word does not see. R-LAY-06 adds the cell's border and
  alignment; R-LAY-09's table carries the R-LAY-15 attributes; R-LAY-17
  lowers a wrapper as a section band. R-TBL-01, R-TBL-06, R-TBL-15 and
  R-OL-15 name what P10 checks and the codes it reports.
- 2026-10-02: Column strategies built and checked against MJML 5's
  Outlook geometry, gutters included. R-LAY-01 drops the inline
  `max-width` (MJML has none; the Fab Four is the strategy that sizes
  without the head CSS) and adds the stacked gap; R-LAY-02, -03, -07,
  -10 and -14 follow MJML 5.4.1's `mjml-column`, `mjml-group` and
  `mediaQueries.js` as read (mobile-first gutters, the gutter share of
  the desktop width, a fill-width ghost row, group columns keeping
  their class); R-LAY-11 names its markup and its restriction;
  R-LAY-12/13 copy the desktop column rules only, never `sm:` rules,
  and put both copies outside the query;
  R-LAY-18 (Fab Four), R-LAY-19 (stacking cells) and R-LAY-20 (cells)
  added; R-TBL-11 measures the content box and names its defaults;
  R-OL-15 names `mso-font-alt`'s rule and source. R-LAY-07's ghost
  cells carry no padding (single-cell tables inside them do). R-LAY-04 (and
  R-TBL-05 outside Outlook conditionals) write the zero font size as
  `0.01px`: Evolution and Geary on WebKitGTK 2.52 rendered nothing of a
  message with a true zero, and rendered it whole with `0.01px`.
- 2026-10-02: R-CSS-19 (fallback pairs) added. R-LAY-18's width is a
  fallback pair, `calc()` then `max({w}, calc())`: SnappyMail 2.38,
  which removes `min-width` but keeps both functions, collapsed a Fab
  Four row on a wide screen and lays it out side by side with the pair
  (Roundcube unchanged). R-TBL-13, R-IMG-02 and R-LAY-08 write the zero
  font size outside Outlook conditionals as `0.01px` (R-LAY-04), and
  R-LAY-04 records the minimum-font-size residual risk.
- 2026-10-02: the layout primitives. R-TBL-07's `&zwnj;` is written
  inside an Outlook conditional (only Word needs it; elsewhere it would
  open a line under a block image). R-TBL-09 defines the border's step
  (0.1 OKLCH lightness) and the two shadows. R-TBL-10 names the rows
  `I-TBL-RAGGED` flags and what paints a box. R-TBL-12's spacing check
  is `W-A11Y-TAP-TARGET` on clusters. R-TBL-16 records that the 3×3
  Outlook corner box is not built until a Word-engine capture backs it
  (`outlook_rounded` is reported, not emitted). R-LAY-07 spells out a
  grid's chunked ghost rows and its last row. R-CSS-19 names R-DOC-11's
  wrapper font size as a user (it is now set as a fallback pair; the
  bytes are unchanged). R-TBL-17 (long words break inside primitives)
  added; R-TBL-16 and R-LAY-19 write `border-collapse:separate
  !important`, since the reset's `!important` collapse beat the plain
  inline value and drew a rounded box's border square.
- 2026-10-02: From the content leaves (text, images, spacer, divider)
  and their capture loop over backend A, the self-hosted webmails and
  the desktop clients: R-TXT-02 lists the text leaves' defaults
  (type, margins, inheritance, no bottom margin for a last block or a
  spacing primitive's item); R-TXT-04 settles the link colour (body
  links `color.link`, links in coloured text keep it); R-TXT-09 gives
  lists a bottom margin and mirrors the indent right to left; R-TXT-11
  (quotations lowered to a `div`) added; R-OL-04 admits the text
  blocks' margins. R-IMG-03 records how the engines draw a blocked
  image's alt and the lowering's answer (the inline form, the
  min-height, `W-IMG-ALT-FIT`); R-IMG-01 the height attribute and the
  explicit `align`; R-IMG-10 the link's colour; R-IMG-11 and R-TBL-13
  which images and holders they cover; R-IMG-08 names
  `E-ASSET-FORMAT`; R-A11Y-09 the `scope` backfill; R-A11Y-10 the check
  of the emitted document.
- 2026-10-03: R-LAY-08 makes content placed directly in a document an
  implicit section (the canary's heading, with no band around it, was
  drawn above the top of the reading pane in WebKit); R-TXT-02 floors
  a default line height at the font's content area and lets an
  overlong word break.
- 2026-10-03: Buttons built. R-BTN-01 adds the placement cell and
  `border-collapse:separate !important` (both for the reset: captured
  in Chromium, WebKit and Firefox, a left-aligned button floated out of
  its box); R-BTN-03 puts a set width on the button's table; R-BTN-04
  states the fit check and its diagnostics, and its VML template the
  aligning block, `strokeweight` and the unfilled outline; R-BTN-05
  records Good Email Code's markup from its source and the local
  comparison, and is implemented as an option; R-BTN-06 counts borders
  and `height`; R-BTN-07 names its codes. R-CSS-14 is emitted as a
  fallback pair (R-CSS-19) on HTML elements, rgba() alone without
  `outlookWord`.
- 2026-10-03: Data tables, social icons, navigation, raw markup and
  client targeting built. R-TBL-18 (data tables, their mobile modes),
  R-IMG-12 (social icons), R-TXT-12 (navigation links) and §12b (raw
  markup and `mailIf`, R-RAW-01…06) added. R-OL-02 names how authors
  reach conditions and what each way reports; R-OL-07 and R-TXT-07 name
  the web-font declaration and its fallbacks; R-OL-09 adds `valign` and
  mirrors a translucent background's blend for every target; R-A11Y-09
  gives the caption's markup; R-TXT-03, -05, -06 and -08 name their
  checks.
- 2026-10-03: §12b's raw markup settled as an authoring aid. `mailRaw`
  is for HTML the author trusts and is not a sanitiser: there is no
  allowlist of elements, attributes, URL schemes or CSS. R-RAW-02 reports
  only what would break the message's structure, its tags and comments
  read as the HTML Standard's tokenizer reads them (`--!>` ends a
  comment, `<!-->` is one, `noscript` is markup), including table parts
  outside the payload's own table, an `li` in a list item outside the
  payload's own list, inline `svg`, `math` and `noscript` (refused: their
  structure cannot be checked without modelling foreign content or
  scripting, and clients largely do not render them or never run
  scripts), `<!--` in a script and any comment in a payload
  inside a `mailIf` (one there ended Word's conditional early and showed
  Word-only content to every client); conditionals are matched without
  case. The checks cover plausible authoring mistakes and a fixed corpus
  of parser probes; constructs the library cannot verify are refused,
  and further exotic parser behaviour is handled as an issue. R-RAW-03
  writes what clients strip as it is, with
  `W-RAW-UNSUPPORTED`. Invariant 9 covers the markup the library
  generates.
- 2026-10-03: Background images and `mailHero` built. §6's template
  gives the full `v:fill` (MJML 5's `mj-section` mapping of size,
  position and repeat). R-VML-01 names the CSS path, its element and
  order, the fallback colour, Word's view (the rectangle in the ghost
  cell, the padding in a cell inside it, no background visible to Word
  inside it) and the declared degradations; R-VML-02 names the hero's
  height and its errors; R-VML-03 puts the growing rectangle of
  sections, wrappers and `min_height` heroes behind the target's
  `vmlFitToText` (off until a Word-engine capture), with the fallback
  colour for Word without it, and R-OL-11 follows; R-VML-04 names
  P8's check. R-VML-06 (the hero), R-VML-07 (contrast against the
  fallback colour) and R-VML-08 (a fixed-height hero's content fits,
  `E-LAYOUT-HERO-OVERFLOW`) added; R-TBL-01 admits the hero's cell.
  P8 and P10 read `background_image` as the lowering does, as a style
  or an attribute.
- 2026-10-03: The dark-mode system. R-DRK-02 is token-driven (a
  designed template's token colours get their dark rules without
  `@dark:`), names R-CSS-08's generated class rather than an `e-dk-`
  prefix, and adds the designed document's surface
  (`color.surface.card`), the `body` rule for the page below the
  message and the shadowed box's dark border; R-DRK-03 follows.
  R-DRK-04 names the three schemes, the inversion models as built and
  their families, and stays ☐: uncalibrated until backends B and C, and
  until then their findings are information (`I-A11Y-CONTRAST-INVERTED`),
  a warning only for a model marked calibrated.
  R-DRK-06 states the alpha heuristic. R-IMG-06 is built (the dark copy,
  its class, its hiding, the swap rules and when the pair is written).
  R-A11Y-05 settled: the dark-swap pair carries no `aria-hidden`.
  R-OL-14 names the lowerings that write it. R-BTN-04 and R-VML-08
  measure text as drawn (`text-transform`, `letter-spacing`), and
  Word's VML button label carries both.
- 2026-10-03: Thunderbird's dark mode, measured on Thunderbird 150.0.1:
  it applies no `@media` rule (R-DRK-01 moves it to the families that do
  not honour `prefers-color-scheme`) and adapts a message itself unless
  the message's root says it handles its own colours. R-DRK-08 added:
  block 6 says so whenever the colour-scheme metas are written, and a
  designed message gets `light-dark()` copies of its dark rules for
  Thunderbird (the §1 skeleton, R-CSS-02, R-CSS-07 and R-CSS-09 follow).
  R-DRK-02: image backdrops keep one colour, and the dark class is named
  after both values. R-DRK-04 models a background image no inverter
  recolours. R-VML-01 follows. R-TXT-02 colours a cluster's separators.
- 2026-10-03: The structure and media patterns: R-IMG-13 (crops made by
  the asset pass, never `object-fit`) added; R-IMG-12's `mode = auto` is
  the light and dark plate pair under `darkMode = designed`; R-TXT-03
  allows a footer's 12px legal text; R-A11Y-10 names the navigation
  table.
- 2026-10-04: The container and data patterns. R-TBL-01 admits the
  tables a stepper and a timeline write in their expansion. R-TXT-03's
  footer exception is the footer's legal line only, never the author's
  content in the footer. The contrast checks (R-A11Y-07, R-DRK-04) read
  text on its own element's background first, and skip a cell or block
  with no visible text (a painted spacer). Captures map Courier New and
  `monospace` to the pinned Liberation Mono, as a desktop's fontconfig
  does.
- 2026-10-04: The actions and inline items. R-TBL-01 admits a badge's
  Word wrapper and lists the labelled divider's table among the
  expansions P10 does not flag. R-TBL-08 is built: a dashed or dotted
  box with a background paints its table too. R-TBL-17: where head CSS
  is stripped, every layout table with a width of its own carries the
  reset's `table-layout:fixed` inline (the §1 wrapper table, R-VML-06's
  hero table, R-LAY-19's cell rows and R-BTN-01's placement table show
  it), and a cluster item is capped at its line. R-DOC-09 names the
  wrapper's fixed layout.
- 2026-10-04: R-A11Y-11 added: the capture's Tier-3 `touch` check is WCAG
  2.2 SC 2.5.8 (24px, or the spacing exception; inline links exempt;
  inline links measured by their client rects); R-BTN-06's 44px and
  R-TBL-12's stay recommendations for P10. R-IMG-06 gains
  `e-dk-show-inline` for an inline-form image's dark copy. §18's image
  invariant names the inline form and the hidden dark copy.
