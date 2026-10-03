# IsoNim Email — Layout Primitives and Content Patterns

<!-- markdownlint-disable-file MD013 MD060 -->
<!-- Line length and table column style are intrinsic to this file:
     the primitive and pattern tables carry long cells. -->

> **Status:** Normative for the layout layer of this library. The exact
> markup every construct must produce, and the client behaviour behind
> it, are in the [rendering rules catalogue](./rendering-rules.md)
> (rule IDs such as `R-LAY-01` and `R-TBL-03` below point there).
> Built so far: the scaffolding (§2), every layout primitive (§3:
> `mailStack`, `mailBox`, `mailColumns` with its four strategies,
> `mailGrid`, `mailCluster`, `mailSidebar`) and `defineMailPattern`
> (§4, §5). The content patterns are specified here and not yet
> implemented; an element without a lowering is reported
> (`E-LOWER-MISSING`), never emitted raw.
> **Last Updated:** 2026-10-02

Email has settled ways of building things. How tables nest, where widths
and padding go, and how gaps, cards, grids, fixed+fluid rows and
equal-height columns are made are all known problems with known answers
and known trade-offs. This document encodes them as three layers above
the document mechanics (`mailDocument`, `mailSection`, the leaves):

```text
templates                         transactional, receipt, …
content patterns (§4)             mailCard, mailCallout, mailMediaObject, mailStepper, mailKeyValue, …
layout primitives (§3)            mailStack, mailBox, mailColumns, mailGrid, mailCluster, mailSidebar
scaffolding (§2)                  mailDocument, mailSection (band + centred container), leaves
```

**Authors write templates from patterns and primitives.** Direct use of
scaffolding internals is for pattern authors. Every primitive and pattern
is a vocabulary element defined with `defineMailPattern`, so applications
extend the set the same way the library does.

Sources are named where a construct is taken from published practice:
MJML 5 (`mjml-section`, `mjml-column`, `mjml-group`, `mjml-core`), the
Cerberus templates (`cerberus-hybrid.html`), Foundation for Emails,
goodemailcode.com, Blocks Edit ("No more tables for email"), Litmus,
Parcel, kontent.ai, the caniemail support data and the hteumeuleu
email-bugs tracker. A construct with no source is marked _design rule_.

---

## 1. Construction stance: div-first, tables where tables are the point

Output is **div-first with Outlook-only ghost tables**:

- Non-Outlook clients get `div`s.
- Classic Outlook (the Word engine) gets tables inside `<!--[if mso]>`,
  which carry the widths, padding and backgrounds that Word ignores on
  divs.

Real tables appear outside MSO comments only where **table layout is the
point** (catalogue R-TBL-01):

1. **Equal-height or vertically centred cells:** `mailSidebar`, `mailBox`,
   `mailColumns(strategy = cells|cellsStacking)`, steppers, timelines,
   labelled dividers.
2. **Rows that must never wrap:** avatar + name, key-value rows, steppers.
3. **Data tables:** `mailTable`, line items.

Why:

- Only the Word engine needs tables. It ignores `width`/`max-width` on
  divs, and honours padding only on table cells (caniemail `css-width`,
  `css-max-width`, `css-padding`; Blocks Edit).
- Div-first output is roughly half the bytes of table-first (Blocks Edit),
  and Gmail clips at about 102 KB (R-SIZE-01).
- With `role="presentation"` on every layout table (R-LAY-15), tables no
  longer hurt screen readers. The remaining costs of tables are bytes,
  nesting quirks and a CSS model unlike the web's.
- This is the position of Litmus, goodemailcode.com, Blocks Edit and
  Parcel.

**What this changes relative to MJML.** MJML puts a table inside every
column `div`; this library does not. The MJML conformance check
(`just test-conformance`) therefore compares only **Outlook geometry**:
the ghost-table structure, the boxes Word lays text into, and the
responsive class widths. It does not compare the non-MSO markup.

**The one hard rule of div-first:** any padding, background or width that
Outlook must honour is **mirrored into the MSO ghost table** (R-TBL-02). A
div's padding on its own renders nowhere in Outlook.

---

## 2. Scaffolding

### 2.1 `mailSection`: band plus centred container

```html
⟪mso⟫<!--[if mso]><table role="presentation" align="center" border="0" cellpadding="0" cellspacing="0" width="{W}" style="width:{W}px;"><tr><td bgcolor="{bg}" style="padding:{pad};background-color:{bg};"><![endif]-->
<div style="margin:0 auto;max-width:{W}px;background-color:{bg};">
  <div
    align="{align}"
    style="padding:{pad};font-size:16px;text-align:{align};direction:{dir};"
  >
    {content}
  </div>
</div>
⟪mso⟫<!--[if mso]></td></tr></table><![endif]-->
```

(`⟪mso⟫` marks output that exists only when Outlook output is on.) The
exact markup is catalogue R-LAY-06 and R-LAY-08.

- `full_width`: an outer `<div style="background-color:{bg}">` plus
  ⟪mso⟫ `<table width="100%"><tr><td bgcolor>` around the whole thing
  (R-LAY-09).
- **Single-column sections have no column scaffolding.** Column padding is
  merged into the section's inner div, and into the MSO cell's padding. For
  example, section `24px 0` plus column `0 24px` gives MSO `24px 24px`.
- Content directly in a section is that single column, with the default
  column padding.
- Borders on a section go on the MSO cell and, for everyone else, on a
  frame `div` around the inner div that Word does not see
  (`<!--[if !mso]><!-->` around its tags): Word renders div borders
  unreliably and would draw the border twice. Radius goes on the outer div
  and the frame, and renders square in Word (R-OL-12).
- `mailWrapper` gives several sections one band (R-LAY-17).

### 2.2 Stacking, spacing and gaps

These are the rules every primitive shares (R-TBL-03…06):

- Vertical gaps are `padding-top` on the following child's wrapper `div`,
  mirrored as an ⟪mso⟫ spacer row:
  `<!--[if mso]><table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0"><tr><td height="{g}" aria-hidden="true" style="height:{g}px;font-size:0;line-height:0;mso-line-height-rule:exactly;">&nbsp;</td></tr></table><![endif]-->`
  (R-LAY-15's table attributes, R-TBL-05's hidden, sized, never-empty
  cell).
- `gap`, negative margins and flex `gap` are never used. They are
  unsupported in Gmail, Outlook.com, Yahoo or Word (caniemail `css-gap`,
  `css-margin`).
- Text elements (`p`, `h*`, `ul`) keep their own bottom margins
  (R-TXT-02). A Stack's gap is **added** to them, never collapsed with
  them. The author picks gap = 0 to rely on text margins alone.
- A box that lays out no text of its own (the container of inline-block
  columns, a gutter cell) has a zero font size written `0.01px`, never `0`
  (R-LAY-04): WebKitGTK 2.52 (Evolution, Geary) renders nothing of a
  message holding a box whose font size is exactly zero.

---

## 3. Layout primitives

Each primitive's table covers:

- **Props:** typed attributes;
- **Lowering:** the output construction;
- **NoCSS:** behaviour with all `<style>` removed (the Gmail app with a
  non-Google account, or Gmail dropping a block);
- **Word:** behaviour in classic Outlook;
- **Equal height**, where it applies;
- **Text part:** how the plain-text alternative renders it.

The names follow Every Layout's primitives where the concept matches. The
email lowerings are this library's own: no published framework maps them
(Every Layout, MJML, Parcel and Stripo were surveyed).

### 3.1 `mailStack`: vertical rhythm

|           |                                                                                                                                |
| --------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Props     | `gap: Len = tok"space.4"`; `align: Align` = the start of the direction (left, or right in a right-to-left document or section) |
| Lowering  | each child wrapped in `<div>`; followers get `padding-top:{gap}` plus the ⟪mso⟫ spacer row (§2.2)                              |
| NoCSS     | ✓ (all inline)                                                                                                                 |
| Word      | ✓ (spacer rows)                                                                                                                |
| Text part | children in order, separated by a blank line                                                                                   |

`mailColumn`, `mailBox` and every pattern slot are implicitly a Stack with
`gap = 0`.

### 3.2 `mailBox`: padding, background, border

|                   |                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Props             | `padding: Box = tok"space.5"`; `background_color`; `border: Border`; `border_radius: Len`; `shadow: none\|sm\|md = none`; `outlook_rounded: bool = false`                                                                                                                                                                                                                                                                     |
| Lowering          | **a single-cell table**, the one primitive that is a table by default (Blocks Edit; goodemailcode.com container): `<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="border-collapse:{separate if radius else collapse};"><tr><td bgcolor="{bg}" style="padding;background-color;border;border-radius;box-shadow">`. Everyone, Word included, sees the cell: no ghost table is needed |
| Shadow            | `box-shadow` is decoration only. Unsupported in Gmail web, Word and Yahoo (caniemail `box-shadow`), so a `shadow` Box **always also has a border**: its own, else a 1px border one step (0.1 OKLCH lightness) darker than its background (R-TBL-09)                                                                                                                                                                           |
| `outlook_rounded` | ☐ opt-in: the 3×3 table with VML corner arcs (kontent.ai, "Outlook containers with rounded corners"). Requires `padding ≥ border_radius`; never nest VML inside it. Shipped only once a Word-engine capture shows it works (R-TBL-16): until then it is not built, and asking for it is `E-LOWER-MISSING` (the box lowers square)                                                                                             |
| NoCSS             | ✓                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Word              | ✓, with square corners and no shadow                                                                                                                                                                                                                                                                                                                                                                                          |
| Text part         | content; the Box itself contributes nothing                                                                                                                                                                                                                                                                                                                                                                                   |

### 3.3 `mailColumns` / `mailColumn`: rows with an explicit strategy

**No single column technique gives stacking, equal heights and NoCSS
safety all at once** (goodemailcode.com, "Columns"). The strategy is
therefore an explicit, typed choice, never a hidden default:

| `strategy`         | Lowering                                                                                                                                                                                       | Stacks on mobile                    | NoCSS (Gmail app on another account, dropped block) | Equal heights | Vertical centring | Use for                                        |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- | --------------------------------------------------- | ------------- | ----------------- | ---------------------------------------------- |
| `hybrid` (default) | inline-block divs at `width:100%` inline, the desktop width from a `min-width` class (mobile first, MJML's model), and an MSO ghost row (R-LAY-01…07)                                          | ✓                                   | ✓ stacks at every width                             | ✗ (ragged)    | ✗                 | text columns, anything that must stack         |
| `fabFour`          | inline-block divs with `width:calc(({bp}px - 100%) * {bp});width:max({w}, calc(…));min-width:{w};max-width:100%`, plus the MSO ghost row (R-LAY-18; Rémi Parmentier, "The Fab Four technique") | ✓ at a container-relative threshold | ✓ switches by width (inline `calc`) ◐               | ✗             | ✗                 | when the switch must survive a lost head block |
| `cellsStacking`    | a table row of cells, stacked by a media query (`display:block;width:100%`) (R-LAY-19)                                                                                                         | ✓ (media query)                     | ✗ **stays side by side**                            | ✓             | ✓                 | only when the desktop row is readable at 320px |
| `cells`            | a table row of cells, never stacking (R-LAY-20)                                                                                                                                                | ✗                                   | ✓                                                   | ✓             | ✓                 | short items: stats, icons, key-value, steps    |

What the strategies do in the clients measured so far (browser engines
with and without head CSS and with Word's ghost tables, Roundcube,
SnappyMail, Thunderbird, Evolution, Geary, KMail, Claws Mail):

- `hybrid` stacks wherever the head CSS is lost and in every client that
  applies no media query (Claws Mail's litehtml); Thunderbird applies no
  media query in a message either, and gets the desktop widths from a
  copy of the rules outside the query (R-LAY-12).
- `fabFour` needs `calc()`: Outlook.com, Yahoo, AOL and Outlook for
  Windows have none (caniemail `css-unit-calc`), and there the columns
  size to their content between `min-width` and 100%. The width is
  written twice, `calc()` and then `max({w}, calc())` (a fallback pair,
  R-CSS-19), so a sanitiser that removes `min-width` but keeps both
  functions (SnappyMail 2.38) still lays the columns side by side on a
  wide screen and stacks them on a narrow one. Without CSS its stacked
  columns keep their half-gutters as side offsets.
- `cellsStacking` keeps the desktop row wherever the head CSS is lost:
  it is always checked at 320px (below).

A section's own `mailColumn` (and `mailGroup`) children are a `hybrid` row
with no gutter: MJML's `mj-section` model, column padding `0 24px` by
default. `mailSection(stack = never)` keeps them side by side, like a
group's.

**Props:**

- on `mailColumns`: `strategy`, `gutter: Len = tok"space.5"` (px),
  `valign: VAlign = top`, `reverse_on_mobile: bool = false`,
  `min_column: Len`;
- on `mailColumn`: `width` (% or px), `min_width`, `vertical_align`,
  `background_color`, `border`, `border_radius`, and `padding`, which
  defaults to none inside `mailColumns` (the gutter spaces the columns)
  and sits inside the gutter, as MJML 5's column padding does.

A `mailColumns` row sits wherever content goes: in a section's implicit
column (so the row is the section's width less the column padding), in a
column, in a stack. Its box is the content box it sits in.

**The 320px check (R-TBL-11).** For `cells` and `cellsStacking`, the
layout pass computes each cell's content box at a 320px document (its
desktop share of the row, which shrinks by exactly what the document
loses, less its padding and borders). Below the column's `min_width`, else
the row's `min_column`, else 160px for a column with text and 120px for one
without, the result is `W-LAYOUT-MIN-COLUMN`, an error under `strict`.
Short items declare theirs (stats 72px). The check exists because
`cellsStacking` fails to the squeezed desktop layout without CSS.

**Gutters** follow MJML 5's `mj-section gutter` (`mjml-column`
`getDesktopWidth`, `getDesktopPaddingValues`, `getMobileGutterStyles`;
R-LAY-14):

- Each column's desktop class width loses its share of the gutters,
  `(n − 1) / n` of one gutter; a px row hands the rounding remainder to its
  first columns, one pixel each.
- Its desktop padding is half a gutter on each inner side and none on the
  row's outer edges, from a desktop class; Word gets the half-gutters on a
  single-cell table inside each ghost cell, which keeps the full column
  width.
- Mobile first: inline, every column but the first has
  `padding-top:{gutter}`, the stacked gap; the desktop class replaces it.
  Without CSS the columns stack with their gaps, which is the stacked
  design.
- Cell rows put the gutter in a cell of its own, so a cell's background
  stays inside the cell; the Fab Four keeps half-gutters inside each
  column.

**Reverse on mobile** (R-LAY-11):

- Source order is the mobile order and the reading order. Reversal applies
  on **desktop only**.
- It is implemented with `dir="rtl"` on the row and `dir="ltr"` restored on
  each column (Cerberus; Litmus, "Mobile responsive email stacking"), and
  is allowed only when at most one column holds text (the moved column is
  an image or decoration).
- It is an error (`E-LAYOUT-REVERSE-TEXT`) when more than one column holds
  text, or in a right-to-left row; reversing a `cells` row, which never
  stacks, is `E-VOCAB-BAD-VALUE`.

**Equal heights come from cells.** A flex enhancement over hybrid
columns (`display:flex;flex-wrap:wrap` on the row) is not offered:
`display:flex` is unsupported in Word and harmful on a layout container
(R-OL-10), and the cell strategies already give equal heights everywhere,
Word included.

### 3.4 `mailGrid`: n-up items that wrap

|                      |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Props                | `columns: 2..4`; `mobile_columns: 1\|2 = 1`; `gutter: Len`; `min_item: Len = 160px`; `align: Align = left`; `last_row: stretch\|left\|center = left`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Lowering             | a row of N inline-block items in a zero-font-size container. Each item is `width:100%` capped at `(B − (N−1)·gutter)/N` px (whole px, the remainder to the first items of a row), plus the gutter as trailing padding on every item that does not end its desktop row and as top padding on every item after the first row: the inline state is the desktop grid. Below the breakpoint a class makes every item full width with the gutter on top. The **MSO ghost table is chunked into rows of N** (`</tr><tr>`), because Outlook tables never wrap (Foundation for Emails `block-grid`); its cells carry the slot widths, never padding (R-LAY-07). Item count not divisible by N: the last MSO row is padded with sized spacer cells (R-TBL-05); `last_row = center` or `stretch` gives that row a ghost table of its own. `align` aligns each item's content. `gutter` defaults to `tok"space.5"` |
| `mobile_columns = 2` | nested 2×2, built by expanding the grid before layout. N = 4 becomes, per desktop row, an outer 2-column `hybrid` `mailColumns` of 2-item `cells` rows, so it goes 4-up → 2-up and never 1-up; N = 2 is a `cells` row per pair. Rows are a `mailStack` with the gutter as gap; `min_item` is the cells' 320px minimum (R-TBL-11); an incomplete last pair keeps an empty slot (`last_row` does not apply). N = 3 with `mobile_columns = 2` is an error (`E-PATTERN-GRID-ORPHAN`)                                                                                                                                                                                                                                                                                                                                                                                                                       |
| NoCSS                | wraps as many as fit, which may give 3+1 or 2+2. Declared as an expected degradation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Word                 | N per row                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Equal height         | ✗. Grid items that need a shared bottom edge use a shared band background, or the Box-per-item design declares ragged bottoms acceptable (R-TBL-10)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Text part            | items in order                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |

### 3.5 `mailCluster`: inline items that wrap

It is used by navigation, social icons, badges, button pairs, app badges,
rating scales, calendar links and footer links.

|                |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Props          | `gap: Len = tok"space.3"`; `row_gap: Len = gap`; `align: Align = left`; `separator: string = ""` (e.g. `"·"`, rendered `aria-hidden`)                                                                                                                                                                                                                                                                                                                                                                              |
| Lowering       | parent `div` with a zero font size and `text-align:{align}`. Each item is wrapped in a `display:inline-block;vertical-align:middle` div with `padding:0 {gap} {row_gap} 0` (the trailing side in the line's direction) and `font-size` reset; the item itself keeps its own padding and background inside it, so the wrapper never needs MJML's `inline-table`. ⟪mso⟫: a single-row ghost table with one `td` per item and the gap as the cell's padding; the cells carry no width (MJML `mj-social`, `mj-navbar`) |
| Edge alignment | the last item has no trailing gap, whatever the alignment, so a one-line cluster is flush with its edges (and exactly centred). The row-wrap position is unknown at render time, so a wrapped line keeps its last item's gap, and every line its row gap below it: declared degradations                                                                                                                                                                                                                           |
| NoCSS          | ✓ wraps                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Word           | one row, never wraps (items that do not fit run past the box: keep Word-visible clusters short), except where every item's width can be estimated (text, by the text metrics at 16px bold; an image's own width): items that do not fit the box on one line then get a ghost row per line. Acceptable, because Word is desktop-only                                                                                                                                                                                |
| Tap targets    | interactive items keep ≥ 8px between hit areas: a cluster of links or buttons whose `gap` or `row_gap` is below 8px is `W-A11Y-TAP-TARGET` (R-TBL-12)                                                                                                                                                                                                                                                                                                                                                              |
| Text part      | items on one line joined by `separator` or `·`; links as `label (url)`, one per line when there are more than 3                                                                                                                                                                                                                                                                                                                                                                                                    |

### 3.6 `mailSidebar`: fixed plus fluid

|                               |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Props                         | `side: left\|right = left` (which of its two children is the fixed side: the first or the second; source order is the visual order, mirrored right to left); `fixed: Len` (px, required); `valign: VAlign = middle`; `gap: Len = tok"space.4"`; `switch_below: Len = 0` (0 = never switch); `reverse_on_mobile: bool = false` (switching pairs only, as R-LAY-11)                                                                                                                                                                                        |
| Lowering (`switch_below = 0`) | a **two-cell table**: `<td width="{fixed}" style="width:{fixed}px" valign>` and `<td valign style="padding-left:{gap}">` with no width (the gap on the side facing the fixed cell). The fluid cell absorbs the rest everywhere, including Word. It never stacks, needs no CSS, and gives equal heights and vertical centring (_design rule_); its fluid side is checked at 320px (R-TBL-11)                                                                                                                                                              |
| Lowering (`switch_below > 0`) | the hybrid pair (Cerberus thumbnail layout). The fixed side is `inline-block;width:{fixed}px`; the fluid side is `inline-block;min-width:{switch_below};max-width:{B−fixed−gap};width:100%`, plus the MSO ghost row. The gap is trailing padding inside the first side, invisible once the sides wrap. It wraps without CSS below `fixed + gap + switch_below` (with no gap between the sides: a declared degradation); below the breakpoint a class gives each side the full width and the second the gap on top. Heights stop being equal once wrapped |
| Decoration sides              | in the table (`switch_below = 0`), a side that holds no text and paints a background (an accent bar, a colour tile) paints its whole cell, so it runs the height of the row                                                                                                                                                                                                                                                                                                                                                                              |
| Image cells                   | a side holding only an image, beside a side holding text, gets `&zwnj;` after the image, inside an Outlook conditional (only Word needs it). Otherwise Word misaligns it against multi-line text (R-TBL-07; kontent.ai, "Outlook vertical alignment in tables")                                                                                                                                                                                                                                                                                          |
| Text part                     | fluid content; the fixed side only if it has text or alt                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

### 3.7 Not provided

- **Reel** (horizontal scroller): `overflow` scrolling is unusable in email
  (caniemail `css-overflow`). Use `mailGrid` with a "View all" link.
- **Frame** (aspect-ratio box): `aspect-ratio`/`object-fit` are Apple-only
  (caniemail `css-aspect-ratio`, `css-object-fit`). Images are cropped to
  their ratio before sending. `mailHero` covers text over an image.

---

## 4. Content patterns

Each pattern is a vocabulary element defined with `defineMailPattern`. It
expands **only** into primitives, scaffolding and leaves, never into raw
HTML, except where "Special" says otherwise. Every pattern ships the
**story set** in §5.

The notation is compact:

- _Built from:_ the expansion.
- _Special:_ anything that is not a pure composition, with its rule
  references.
- _Text:_ the plain-text rendering.
- _A11y / Dark:_ obligations beyond the global rules.

### 4.1 Structure patterns

**`mailHeader`** (logo + optional links)

- _Props:_ `logo: Url`, `logo_width`, `logo_alt` (required), `href`,
  `links: seq[(label, Url)]` (≤ 3 inline), `align`.
- _Built from:_ `mailSidebar(side = left, fixed = logo_width,
valign = middle)`, logo image | `mailCluster(align = right)` of links.
  With more than 3 links: a Stack of the logo above a centred Cluster.
- _Dark:_ logo per R-IMG-06 / R-DRK-06.
- _Text:_ brand name line, links as `label (url)`.

**`mailViewInBrowser`**

- _Props:_ `href`, `label = "View in browser"`.
- _Built from:_ a right-aligned small link row.
- _Special:_ placed **after** the preheader (R-PRE-01; Cerberus).
- _Text:_ `View in browser: url`.

**`mailBand`** (full-bleed coloured band)

- _Built from:_ `mailSection(full_width = true)` (Cerberus full-bleed
  section; MJML `full-width`).
- _Dark:_ adjacent bands must differ by ≥ 0.1 in OKLCH L in both light and
  dark palettes. P10 warns when they would merge after partial inversion.

**`mailFooter`**

- _Props:_ `address` (required), `unsubscribe: Url` (required for
  non-transactional mail), `preferences: Url`, `legal: string`,
  `social: seq[SocialItem]`, `reason: string` ("You're receiving this
  because…").
- _Built from:_ a centred Stack of `mailCluster` (social), small text,
  `mailCluster(separator = "·")` of the links, and legal text.
- _Special:_ text ≥ 12px (R-TXT-03 allows 12 only here); contrast ≥ 4.5:1
  in all four palettes (_design rule_).
- _Text:_ the address, then links one per line.

**`mailNavLinks`**

- A `mailCluster` of up to 5 links.
- More than 5 is `W-PATTERN-NAV-LONG`, which suggests reducing the links.
  A collapsible menu is not offered (MJML's `mj-navbar` hamburger and
  Foundation's menu need media queries most clients drop).
- _A11y:_ the Cluster gets `role="navigation"` on a presentation table, never
  a `<nav>` element (R-A11Y-10).

### 4.2 Hero and media patterns

**`mailHero`**

- _Props:_ `background_image`, `background_color` (the fallback colour),
  `background_size` (`cover`), `background_position` (`center center`),
  `background_repeat` (`no-repeat`), `height` or `min_height` (px),
  `padding` (the section's), `vertical_align` (`top`).
- A band whose content sits in one table cell, so it has a height and a
  vertical alignment everywhere, Word included (catalogue R-VML-06).
  Content in a hero is its implicit single column, as in a section; a
  row of columns goes in a `mailColumns` inside it.
- _Background:_ CSS for every client but Word and a VML rectangle for
  Word (catalogue §6, R-VML-01). With an image and Outlook output on,
  it needs `height` or `min_height` (R-VML-02). A `min_height` hero's
  rectangle grows with its content only through
  `mso-fit-shape-to-text`, which is unverified, so it is drawn only with
  the target's `vmlFitToText`; without it Word shows the fallback colour
  (R-VML-03). A `height` hero's content must fit its cell at the text
  metrics' worst case (R-VML-08, `E-LAYOUT-HERO-OVERFLOW`). Live text only; light text needs a dark fallback colour,
  which the contrast check enforces (R-VML-07; MJML `mj-hero`;
  caniemail `css-background-image`).
- _Image first:_ a hero with no background image is the same band
  holding whatever it is given: a fluid full-width `mailImage`, then
  text and a CTA, is the hero of an image-led design (R-IMG-11, the
  Samsung split, for the image).
- _Text:_ headline, text, `CTA: url`.

**`mailMediaObject`** (thumbnail + text)

- _Props:_ `image`, `image_width` (px), `side`, `stack: never|below`,
  `valign`.
- _Built from:_
  - `mailSidebar(switch_below = 0)` when `stack = never`;
  - `mailSidebar(switch_below = 280px)` when `stack = below`, following the
    Cerberus thumbnail ranges.
- _Text:_ the text content (the image alt only if not decorative).

**`mailZigZag`**

- A repeated `mailMediaObject(stack = below)`. The image side alternates on
  **desktop only**, and source order is image-then-text in every row, so on
  mobile the image always comes first (Cerberus `dir="rtl"`; Litmus).
- _Special:_ R-LAY-11 reversal on even rows; forbidden in right-to-left
  documents.
- _Text:_ each item in order.

**`mailGallery`**

- A `mailGrid` of linked images.
- _Special:_ every image is cropped to one ratio before sending.
  `object-fit` is not used (caniemail `css-object-fit`).

**`mailCountdown`**

- A server-rendered GIF (`Url`) plus a mandatory `deadline_text` in
  absolute terms.
- _Special:_ frame 1 must carry the message (R-OL-13). The alt is the
  deadline text.

### 4.3 Containers

**`mailCard`**

- _Props:_ `image` (optional, top), `title`, a body slot, `cta`,
  `variant: plain|bordered|elevated`.
- _Built from:_ `mailBox(border for bordered/elevated,
shadow = sm for elevated)` holding a Stack of image, heading, body and
  CTA.
- _Special:_ the heading level comes from the context (`level` prop, default
  `h3`).
- _Text:_ title underlined, body, CTA.

**`mailCallout`**

- _Props:_ `tone: Tone`, `title`, a body slot, `icon` (optional).
- _Built from:_ a two-cell table (`mailSidebar(fixed = 4px)`). The first
  cell is the **accent drawn as a cell** (`bgcolor`, a zero font size),
  not `border-left`. The second is a `mailBox` with the tone's `.bg`
  colour (Foundation for Emails callout).
- _A11y:_ the tone is never conveyed by colour alone. The title starts with
  the tone word (e.g. "Warning:") unless `title` already carries it.
- _Text:_ `WARNING: title`, then the body.

**`mailCodeBlock`** / **`codeInline`**

- _Built from:_ `mailBox(background = tok"color.surface.subtle")` holding a
  `pre`.
- _Special:_
  - `white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere`,
    with no horizontal scroll (caniemail `css-overflow`);
  - leading indentation converted to `&nbsp;`;
  - highlighting as inline `span` colours only, with a palette that passes
    R-DRK-04 in both inversion modes;
  - font stack ends in `'Courier New', monospace`.
- _Text:_ the code verbatim, indented 4 spaces.

**`mailQuote`** (testimonial)

- _Built from:_ a `mailStack` of a `blockquote style="margin:0"` or `p`
  with typographic quotes, plus a `mailMediaObject(stack = never)` for the
  avatar, name and role.
- _A11y:_ decorative quote glyphs are `aria-hidden`.

### 4.4 Data patterns

**`mailKeyValue`** (summary and totals)

- _Props:_ `rows: seq[(label, value, emphasis)]`, `total_row: bool`.
- _Built from:_ `mailColumns(strategy = cells)` per row. Values are
  right-aligned with `white-space:nowrap`, and the total row has a top
  border.
- _Special:_ never stacks. The keys use `th scope="row"` in a real table
  (non-presentation): it reads better in screen readers than a
  presentation table and costs nothing.
- _Text:_ `label ....... value`, aligned to 76 columns.

**`mailLineItems`** (invoice)

- _Props:_ `items: seq[LineItem]` (description, sub-line, qty, amount,
  optional thumb), `caption`, `mobile: auto|cards`.
- _Special:_
  - The desktop design is **readable at 320px**: at most 3 columns
    (description | qty | amount). SKU and unit price are a second line in
    the description cell. Amounts are right-aligned and `nowrap`. A
    thumbnail is a nested `mailSidebar` inside the description cell, not a
    4th column.
  - `mobile = cards` (or `auto` with more than 3 columns): each row becomes a
    `mailKeyValue` card. This is the only stacking data design, and it
    works without CSS because it is the default rendering, not a media-query
    switch.
- _Text:_ aligned table, or `label: value` blocks.

**`mailStatTiles`**

- _Props:_ `stats: seq[(value, label, tone)]`, 2–4 items.
- _Built from:_ 2–3 items use `mailColumns(strategy = cells)`; 4 items use
  `mailGrid(columns = 4, mobile_columns = 2)`. Each tile is a `mailBox` with
  `valign = middle`, `align = center`, a large number `p` and a label `p`.
- _A11y:_ the number and unit share one text node.
- _Text:_ `label: value` lines.

**`mailStepper`** (horizontal order status, 3–5 steps)

- _Special lowering (bespoke geometry):_ a fixed, non-stacking two-row
  table (_design rule_; no framework ships one).
  - Row 1: step marker cells (≥ 28px, number or check glyph,
    `border-radius:50%`, which is square in Word) alternating with connector
    cells (`height:2px` `bgcolor`).
  - Row 2: labels (≥ 12px).
  - Fits 320px at 5 steps. More than 5 steps is an error that points to
    `mailTimeline`.
- _A11y:_ a visually hidden **and** text-part line `Current step: Shipped
(2 of 4)` is mandatory; markers are `aria-hidden`.
- _Text:_ `Step 2 of 4: Shipped. Next: Out for delivery.`

**`mailTimeline`** (vertical, any length)

- _Special lowering:_ a two-column table per event:
  - a fixed left cell with the dot and the connector line, drawn as a
    `width:2px` `bgcolor` cell, continuous because the cells are
    equal-height;
  - a fluid right cell with the time and the text.

  It never stacks and works in Word.

- _Text:_ `time — event` lines.

**`mailEvent`** (date tile + details)

- _Built from:_ `mailSidebar(fixed = 64px)` with a date tile (month row plus
  big day, `aria-hidden`), then details, then a `mailCluster` of "Add to
  calendar" links (Google, Outlook, .ics).
- _A11y:_ the full date and time in text is mandatory (_design rule_).
- _Text:_ the full date line, location, links.

### 4.5 Actions and inline items

**`mailButtonGroup`**

- _Built from:_ a `mailCluster(gap ≥ 12px)` of `mailButton`s (primary plus
  secondary `variant = outline`). `stack_on_mobile = true` adds a
  full-width-on-mobile class. NoCSS wraps, which is correct (Foundation for
  Emails `small-expand`; Cerberus).
- _Text:_ each `label: url`.

**`mailBadge`**

- An inline `span` (`inline-block`, padding, radius 999px, tone background).
- _Special:_ Word ignores span padding (caniemail `css-padding`). When
  Outlook output is on, the badge is wrapped in a single-cell
  `inline-table`, following MJML's `mj-social` item pattern. Groups of
  badges are a `mailCluster`.
- _A11y:_ the text carries the meaning, never the colour alone.
- _Text:_ `[label]`.

**`mailAvatarName`**

- _Built from:_ `mailSidebar(fixed = size, valign = middle)` of an avatar and
  a name/role Stack.
- _Special:_ avatars are **pre-cropped circular PNGs**. `border-radius:50%`
  alone is square in Word. Overlapping avatar stacks are not offered
  (they need negative margins; caniemail `css-margin`).
- _Text:_ `Name — role`.

**`mailDividerLabel`** ("or")

- _Special lowering:_ a three-cell table: rule cell | label cell (nowrap,
  padding 0 12px) | rule cell. The rules are 1px `bgcolor` cells inside
  nested tables, all `valign = middle` (Parcel `x-hr`).
- _Text:_ `—— or ——`.

**`mailCoupon`**

- _Built from:_ `mailBox(border = "2px dashed …")` holding a centred
  monospace code with `letter-spacing` and an optional copy-hint text.
- _Special:_ the same background colour on the cell **and** its parent
  (Outlook shows the parent colour between dashes, R-TBL-08; hteumeuleu
  email-bugs #34); the code wrapped against data detectors (R-TXT-06).
- _Text:_ `Code: ABC-123`.

**`mailRatingScale`** (NPS 0–10, stars 1–5)

- _Props:_ `kind: nps|stars`, `href: proc(score): Url`, `low_label`,
  `high_label`.
- _Built from:_
  - stars: a `mailCluster` of 5 linked 44px items;
  - NPS: two fixed rows (0–5 and 6–10), `cells` rows in a Stack, so the
    wrap point is deterministic and every target stays 44px.
- _A11y:_ each link has text ("Rate 4 out of 5"); the end labels are real
  text.
- _Text:_ `0: url` … one line per score.

**`mailSecurityCode`** (OTP / magic link)

- _Built from:_ a `mailBox` holding a large monospace code with
  letter-spacing, the expiry line in absolute time, and an optional
  `mailButton` for the magic link.
- _Special:_ data-detector protection; the code is never an image.
- _Text:_ `Your code: 123456 (expires 14:05 UTC)`.

**`mailSocialRow`** / **`mailAppBadges`**

- _Built from:_ `mailCluster` of icon images.
  - Social icons: 24–32px @2x, with light/dark variants swapped (R-IMG-06);
    alt = network name (MJML `mj-social`).
  - App badges: official artwork, 40–48px tall, gap ≥ ¼ of the badge
    height (Apple's App Store marketing guidelines).
- _Text:_ `Network: url` lines.

### 4.6 Pattern coverage of common email types

| Email                                 | Patterns                                                               |
| ------------------------------------- | ---------------------------------------------------------------------- |
| Receipt / invoice                     | Header, KeyValue, LineItems, ButtonGroup, Footer                       |
| Password reset / magic link / OTP     | Header, SecurityCode, Callout(warning: "didn't request this?"), Footer |
| Shipping / order status               | Header, Stepper or Timeline, MediaObject (items), Footer               |
| Alert / incident (developer products) | Header, Callout(danger), KeyValue, CodeBlock, ButtonGroup, Footer      |
| Digest / newsletter                   | Header, Hero, Grid of Cards or ZigZag, Footer                          |
| Event invitation                      | Header, Hero, Event, ButtonGroup, Footer                               |
| Survey                                | Header, RatingScale, Footer                                            |

---

## 5. Required story set per primitive and pattern

Every primitive and pattern ships these stories, and is iterated in the
capture loop until no reviewer finding of severity P1 or P2 is open in any
client it is captured in:

1. `minimal`: required props only.
2. `maximal`: every prop, the longest realistic content, and long unbroken
   words.
3. `rtl`: `dir = rtl` with Arabic or Hebrew content, where the pattern allows
   it.
4. `imagesOff`: captured with images blocked.
5. `dark`: the `designed` dark theme.
6. `inContext`: the pattern between two different neighbours in a band
   (spacing and colour-bleed checks between adjacent modules; Litmus and
   Parcel on module QA).

The review brief generator reads each pattern's `expectedElements` and
`degradations` declarations, which `defineMailPattern` requires: both
receive the element, its typed props and the client the brief is for
(its family, whether its head CSS and media queries apply, whether it
is Word, the viewport width), so a line can say what that client shows
("3 items per row", "all on one line", "no drop shadow"). The layout
primitives carry the same two declarations.

```nim
template defineMailPattern*(name: untyped; props: typedesc;
    expand, expectedElements, degradations: typed)
  ## expand: proc(n: EmailNode; p: props; ctx: ExpandCtx): EmailNode
  ##   the tree the element stands for, built only from vocabulary
  ##   elements and HTML leaves (n.children is the content to place);
  ## expectedElements, degradations:
  ##   proc(n: EmailNode; p: props; view: BriefView): seq[string]
```

A pattern defined this way joins the static vocabulary at compile time
(its props are its attributes, so a template that misspells one does
not compile) and the render's registry at run time; it expands before
validation, so its expansion goes through every pass.

---

## 6. Design rules of thumb (enforced where they can be)

| Rule                 | Value                                                              | Enforced by        |
| -------------------- | ------------------------------------------------------------------ | ------------------ |
| Container width      | 600 default; 640/680 allowed; > 700 warns                          | layout pass        |
| Mobile side gutter   | 16px                                                               | theme              |
| Section padding      | 32–48 desktop, 16–24 mobile (responsive class)                     | theme              |
| Column minimum       | text 160px; image-only 120px                                       | R-TBL-11 check     |
| Max columns at 320px | 2 text, or 3–4 icon/image/short-stat cells                         | R-TBL-11 check     |
| Tap targets          | ≥ 44px tall; ≥ 8px apart                                           | R-BTN-06, R-TBL-12 |
| Fonts                | body 16; secondary 14; legal ≥ 12; line-height 1.4–1.6             | R-TXT-03           |
| Images               | exported at 2×; cropped to ratio before sending; no text in images | assets, R-IMG-04   |

Sources: Mailchimp's template width and mobile-friendliness guides,
Cerberus's column minimums, goodemailcode.com's templates and Foundation
for Emails' gutters; the thresholds themselves are design rules.

### Decisions

| Decision                                               | Taken                                                                                                                                           |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Output construction                                    | Div-first with MSO ghost tables. Tables only where table layout is the point, or for data (§1)                                                  |
| Key-value summaries: data table or presentation table? | A real table with `th scope="row"` keys. Both are defensible; this reads better in screen readers and costs nothing                             |
| `cellsStacking` allowed without a 320px check?         | No. It is always checked (R-TBL-11), because it fails to the squeezed desktop layout without CSS                                                |
| Equal heights by flex over hybrid columns?             | No: `display:flex` is unsupported in Word and harmful on a layout container (R-OL-10); the cell strategies give equal heights everywhere (§3.3) |
