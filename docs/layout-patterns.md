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
> (§4, §5), and the structure, media, container and data patterns
> (§4.1–§4.4), and the actions and inline items (§4.5). An element
> without a lowering is reported (`E-LOWER-MISSING`), never emitted
> raw.
> **Last Updated:** 2026-10-04

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

|           |                                                                                                                                                                                                                                              |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Props     | `gap: Len = tok"space.4"`; `align: Align` = the start of the direction (left, or right in a right-to-left document or section)                                                                                                               |
| Lowering  | each child wrapped in `<div>`; followers get `padding-top:{gap}` plus the ⟪mso⟫ spacer row (§2.2)                                                                                                                                            |
| NoCSS     | ✓ (all inline)                                                                                                                                                                                                                               |
| Word      | ✓ (spacer rows)                                                                                                                                                                                                                              |
| Text part | children in order, separated by a blank line; in a column, a box, or an item of a grid or a sidebar whose children each write one line, those lines follow each other without blank lines (a figure and its caption, a number and its label) |

`mailColumn`, `mailBox` and every pattern slot are implicitly a Stack with
`gap = 0`.

### 3.2 `mailBox`: padding, background, border

|                   |                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Props             | `padding: Box = tok"space.5"`; `background_color`; `border: Border`; `border_radius: Len`; `shadow: none\|sm\|md = none`; `outlook_rounded: bool = false`                                                                                                                                                                                                                                                                                        |
| Lowering          | **a single-cell table**, the one primitive that is a table by default (Blocks Edit; goodemailcode.com container): `<table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="border-collapse:{separate if radius else collapse};table-layout:fixed;"><tr><td bgcolor="{bg}" style="padding;background-color;border;border-radius;box-shadow">`. Everyone, Word included, sees the cell: no ghost table is needed |
| Shadow            | `box-shadow` is decoration only. Unsupported in Gmail web, Word and Yahoo (caniemail `box-shadow`), so a `shadow` Box **always also has a border**: its own, else a 1px border one step (0.1 OKLCH lightness) darker than its background (R-TBL-09)                                                                                                                                                                                              |
| `outlook_rounded` | ☐ opt-in: the 3×3 table with VML corner arcs (kontent.ai, "Outlook containers with rounded corners"). Requires `padding ≥ border_radius`; never nest VML inside it. Shipped only once a Word-engine capture shows it works (R-TBL-16): until then it is not built, and asking for it is `E-LOWER-MISSING` (the box lowers square)                                                                                                                |
| NoCSS             | ✓                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Word              | ✓, with square corners and no shadow                                                                                                                                                                                                                                                                                                                                                                                                             |
| Text part         | content, as a Stack's (§3.1); the Box itself contributes nothing                                                                                                                                                                                                                                                                                                                                                                                 |

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
| Props          | `gap: Len = tok"space.3"`; `row_gap: Len = gap`; `align: Align = left`; `separator: string = ""` (e.g. `"·"`, rendered `aria-hidden`); `role: navigation` and `label` (a landmark: the cluster sits in a one-cell table with `role="navigation"` and `aria-label="{label}"`, R-A11Y-10)                                                                                                                                                                                                                            |
| Lowering       | parent `div` with a zero font size and `text-align:{align}`. Each item is wrapped in a `display:inline-block;vertical-align:middle` div with `padding:0 {gap} {row_gap} 0` (the trailing side in the line's direction) and `font-size` reset; the item itself keeps its own padding and background inside it, so the wrapper never needs MJML's `inline-table`. ⟪mso⟫: a single-row ghost table with one `td` per item and the gap as the cell's padding; the cells carry no width (MJML `mj-social`, `mj-navbar`) |
| Edge alignment | the last item has no trailing gap, whatever the alignment, so a one-line cluster is flush with its edges (and exactly centred). The row-wrap position is unknown at render time, so a wrapped line keeps its last item's gap, and every line its row gap below it: declared degradations                                                                                                                                                                                                                           |
| NoCSS          | ✓ wraps                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Word           | one row, never wraps (items that do not fit run past the box: keep Word-visible clusters short), except where every item's width can be estimated (text, by the text metrics at 16px bold; an image's own width): items that do not fit the box on one line then get a ghost row per line. Acceptable, because Word is desktop-only                                                                                                                                                                                |
| Tap targets    | interactive items keep ≥ 8px between hit areas: a cluster of links or buttons whose `gap` or `row_gap` is below 8px is `W-A11Y-TAP-TARGET` (R-TBL-12)                                                                                                                                                                                                                                                                                                                                                              |
| Text part      | items on one line joined by `separator` or `·` when none carries a URL and the line fits 76 columns; otherwise one item per line (links as `label (url)`, buttons as `label: url`)                                                                                                                                                                                                                                                                                                                                 |

### 3.6 `mailSidebar`: fixed plus fluid

|                               |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Props                         | `side: left\|right = left` (which of its two children is the fixed side: the first or the second; source order is the visual order, mirrored right to left); `fixed: Len` (px, required); `valign: VAlign = middle`; `gap: Len = tok"space.4"`; `switch_below: Len = 0` (0 = never switch); `reverse_on_mobile: bool = false` (switching pairs only, as R-LAY-11); the fluid side's own `min_width` replaces its 320px minimum (R-TBL-11), as a column's does (a cluster of short links that wraps)                                                      |
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
  their ratio before sending: `mailImage(crop = "4:3")`, or `crop =
circle` for an avatar, made by the asset pass (R-IMG-13). `mailHero`
  covers text over an image.

---

## 4. Content patterns

Each pattern is a vocabulary element defined with `defineMailPattern`. It
expands **only** into primitives, scaffolding and leaves, never into raw
HTML, except where "Special" says otherwise. Every pattern ships the
**story set** in §5.

Props are scalars (a string, a bool, a number or an enum: §5), so what a
pattern holds several of (links, images, items) is its **content**: the
elements written inside it, its slot. A required prop that is missing, or
content of the wrong kind, is `E-VOCAB-BAD-VALUE` at the element.

The notation is compact:

- _Built from:_ the expansion.
- _Special:_ anything that is not a pure composition, with its rule
  references.
- _Text:_ the plain-text rendering. Where it differs from what the
  expansion would write, the expansion carries it in `textOnly`, beside
  the HTML in `htmlOnly`.
- _A11y / Dark:_ obligations beyond the global rules.

### 4.1 Structure patterns

**`mailHeader`** (logo + optional links)

- _Props:_ `logo: Url` (required), `logo_width` (px, required),
  `logo_alt` (required), `logo_dark: Url` (the dark logo, R-IMG-06),
  `href`, `align` (`left`, `center`, `right`: where the logo sits when it
  is alone or above its links; default the start of the direction).
- _Content:_ the links, `a` elements: up to 3 sit beside the logo.
- _Built from:_ `mailSidebar(side = left, fixed = logo_width,
valign = middle, gap = space.4)`, logo image | `mailCluster(align = end,
gap = space.4)` of links, whose side is held to 120px at 320px (short
  links wrap; R-TBL-11). With more than 3 links: a `mailStack` of the logo
  above a centred Cluster. Without links: the logo alone.
- _Dark:_ logo per R-IMG-06 / R-DRK-06.
- _Text:_ the brand name (`logo_alt`) on a line, then the links as
  `label (url)`, one per line.

**`mailViewInBrowser`**

- _Props:_ `href` (required), `label = "View in browser"`, `align`
  (default the end of the direction).
- _Built from:_ a paragraph holding the link, `type.small`, the secondary
  text colour (dark-paired under `darkMode = designed`), no margin. As a
  child of the document it is a `mailSection` of its own with
  `padding = 12px 0 0` (a full section's padding would push the message
  down); anywhere else, the paragraph.
- _Special:_ placed **after** the preheader (R-PRE-01; Cerberus): the
  preheader is a document attribute written first in `<body>`, so a
  `mailViewInBrowser` that is the document's first child follows it.
- _Text:_ `View in browser: url` (the label, a colon, the URL).

**`mailBand`** (full-bleed coloured band)

- _Props:_ `background_color` (required), `padding` (the section's),
  `text_align`.
- _Built from:_ `mailSection(full_width = true)` (Cerberus full-bleed
  section; MJML `full-width`), carrying the band's props and styles,
  dark values included.
- _Dark:_ adjacent bands must differ by ≥ 0.1 in OKLCH L in both light and
  dark palettes. P10 warns (`W-DARK-BANDS-MERGE`) when two adjacent bands
  of the document that differ by ≥ 0.1 in the light palette differ by
  less after R-DRK-04's partial inversion, or, under `darkMode =
designed`, in their designed dark colours (a band without a background
  shows the document's).

**`mailFooter`**

- _Props:_ `address` (required), `unsubscribe: Url` (required unless
  `transactional = true`), `unsubscribe_label = "Unsubscribe"`,
  `preferences: Url`, `preferences_label = "Preferences"`,
  `legal: string`, `reason: string` ("You're receiving this because…"),
  `transactional: bool = false`, `align = center`, `color` (the text
  colour, default `color.text.primary`: on a dark band, a light one).
- _Content:_ what sits above the address, typically a `mailSocial` row.
- _Built from:_ a `mailStack(gap = space.3)` aligned per `align`: the
  content, the reason and the address (`type.small`), a
  `mailCluster(separator = "·")` of the links (`type.small`), and the
  legal text (12px). The links sit in a row, so each is a 44px hit area
  (R-TBL-12): `display:inline-block;padding:12px 0` around its 20px
  line. That padding is the space around the row: the address, the
  row and the legal text are a `mailStack(gap = 0)` inside the
  footer's, so the links' text sits 12px from the lines above and below
  it, as the stack's gap set it before, and the footer is no taller.
- _Special:_ text ≥ 12px (R-TXT-03 allows 12 only here: the legal text
  is not `W-A11Y-FONT-SMALL`); contrast ≥ 4.5:1 in all four palettes
  (light, designed dark, partial and full inversion; _design rule_): the
  text is `color.text.primary`, dark-paired under `designed`, unless
  `color` says otherwise (the contrast checks hold it to the same
  thresholds). Not the secondary grey: the default theme's reads at
  4.4:1 under either inversion model.
- _Text:_ the content (social links as `Network: url`), the reason, the
  address, then the links one per line as `label (url)`, then the legal
  text.

**`mailNavLinks`**

- _Props:_ `align = center`, `separator`, `gap`, `label` (the
  navigation's accessible name, default `Navigation`).
- _Content:_ the links, `a` elements.
- _Built from:_ a `mailNavbar` (a `mailCluster`) of up to 5 links, each a
  `mailNavLink`.
- More than 5 is `W-PATTERN-NAV-LONG`, which suggests reducing the links.
  A collapsible menu is not offered (MJML's `mj-navbar` hamburger and
  Foundation's menu need media queries most clients drop).
- _A11y:_ the Cluster sits in a one-cell table with `role="navigation"`
  and `aria-label`, never a `<nav>` element (R-A11Y-10: landmark roles go
  on tables).
- _Text:_ one link per line, `label (url)`.

### 4.2 Hero and media patterns

**`mailHero`**

- _Props:_ `background_image`, `background_color` (the fallback colour),
  `background_size` (`cover`), `background_position` (`center center`),
  `background_repeat` (`no-repeat`), `height` or `min_height` (px),
  `padding` (the section's), `vertical_align` (`top`).
- A band whose content sits in one table cell, so it has a height and a
  vertical alignment everywhere, Word included (catalogue R-VML-06).
  Content in a hero is its implicit single column, as in a section; a
  row of columns goes in a `mailColumns` inside it. It has a lowering of
  its own (`lower/hero.nim`) and carries the review declarations like
  the layout primitives.
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

- _Props:_ `image: Url` (required), `image_width` (px, required),
  `image_alt` (required unless `decorative`), `decorative: bool`,
  `image_href`, `image_ratio` (`W:H`: the image cropped to it before
  sending, R-IMG-13), `side: left|right = left` (where the image sits on
  the desktop, mirrored right to left), `stack: never|below = never`,
  `valign = top`, `gap = space.4`.
- _Content:_ the text side.
- _Built from:_
  - `mailSidebar(switch_below = 0)` when `stack = never`;
  - `mailSidebar(switch_below = 280px)` when `stack = below`, following the
    Cerberus thumbnail ranges (less beside a wide image: what a full-width
    section leaves the text, at least 160px, so the pair is side by side on
    the desktop). The image comes first in the source, so a
    phone shows it above the text; `side = right` reverses the desktop
    order only (`reverse_on_mobile`, R-LAY-11), which a right-to-left row
    refuses (`E-LAYOUT-REVERSE-TEXT`).
- _Text:_ the text content (the image alt only if not decorative).

**`mailZigZag`**

- _Props:_ `gap = space.6` (between rows).
- _Content:_ `mailMediaObject`s, one per row.
- A repeated `mailMediaObject(stack = below)`. The image side alternates on
  **desktop only**, and source order is image-then-text in every row, so on
  mobile the image always comes first (Cerberus `dir="rtl"`; Litmus).
  The rows are a `mailStack`; the zig-zag sets each row's `stack` and
  `side` (left on odd rows, right on even ones).
- _Special:_ R-LAY-11 reversal on even rows; forbidden in right-to-left
  documents (the even rows are `E-LAYOUT-REVERSE-TEXT`), so it has no
  `rtl` story (§5).
- _Text:_ each item in order.

**`mailGallery`**

- _Props:_ `ratio` (`W:H`, default `1:1`), `columns = 3`,
  `mobile_columns` (2 when `columns` is 2 or 4, else 1), `gutter`.
- _Content:_ the images, `mailImage`s (each with its `alt` and usually an
  `href`).
- A `mailGrid` of linked images, each full width in its item (a fluid
  image, R-IMG-11, and `fluid_on_mobile`, R-IMG-09, so a phone's wider
  item is filled), `min_item = 120px`.
- _Special:_ every image is cropped to one ratio before sending
  (`crop = ratio` on each image, R-IMG-13). `object-fit` is not used
  (caniemail `css-object-fit`).
- _Text:_ each image as `alt (url)`, one per line.

**`mailCountdown`**

- _Props:_ `src: Url` (the server-rendered GIF, required), `width` (px,
  required), `height`, `deadline_text` (required, absolute terms: "Offer
  ends 30 September 2026, 23:59 UTC"), `href`, `align`, `color` (the alt
  text's colour with images off: on a dark band, a light one).
- _Built from:_ a `mailImage` whose alt is the deadline text.
- _Special:_ frame 1 must carry the message (R-OL-13). A missing or empty
  `deadline_text` is `E-PATTERN-MISSING-TEXT`.
- _Text:_ the deadline text on a line, followed by its URL in brackets
  when linked.

### 4.3 Containers

**`mailCard`**

- _Props:_ `title`, `level` (`h2`, `h3` or `h4`, default `h3`: the
  heading level the card's context needs), `image: Url` (on top),
  `image_alt` (required with an image unless `decorative`),
  `decorative: bool`, `image_ratio` (`W:H`: the image cropped to it
  before sending, R-IMG-13), `cta` (the button's label), `cta_href`
  (required with a `cta`), `variant: plain|bordered|elevated =
bordered`.
- _Content:_ the body.
- _Built from:_ `mailBox(padding = space.5, border_radius = 8px)` on
  `color.surface.card`, with a 1px `color.border.subtle` border when
  `bordered` or `elevated` and `shadow = sm` when `elevated` (a shadow
  always keeps its border, R-TBL-09), holding a `mailStack(gap =
space.3)` of the image (fluid, the box's full width, R-IMG-11, and
  `fluid_on_mobile`, R-IMG-09: a card a stacked row widens stays
  filled), the
  heading (no margin of its own), the body and a `mailButton` for the
  CTA. Colours are theme tokens, dark-paired under `darkMode =
designed`.
- _Special:_ the heading level comes from the context (`level`).
- _Text:_ the title underlined, the body, the CTA as `label: url`. The
  image is the HTML's alone: the title says what the card is.

**`mailCallout`**

- _Props:_ `tone: Tone = info`, `title`, `label` (the tone word; by
  default `Note` for `neutral` and `primary`, `Info`, `Success`,
  `Warning`, `Error` for the others), `icon: Url` (24px, decorative: the
  tone word carries the meaning).
- _Content:_ the body.
- _Built from:_ a two-cell table, `mailSidebar(fixed = 4px, gap = 0,
switch_below = 0)`. The first cell is the **accent drawn as a cell**: a
  side holding no text, painted the tone's colour (`color.status.*`;
  `color.accent.primary` for `primary`, `color.text.secondary` for
  `neutral`) with a zero font size, so it paints its whole cell, the
  height of the row (§3.6), never a `border-left`. The second is a
  `mailBox(padding = 12px 16px)` on the tone's `.bg` colour
  (`color.surface.subtle` for `neutral` and `primary`) holding a
  `mailStack(gap = space.2)` of the title line (bold) and the body; with
  an `icon`, the stack sits beside it in a `mailSidebar(fixed = 24px,
gap = space.3, valign = top, switch_below = 0)` (Foundation for Emails
  callout).
- _A11y:_ the tone is never conveyed by colour alone. The title line
  starts with the tone word (`Warning: title`) unless `title` already
  does; without a title it is the tone word alone.
- _Text:_ `WARNING: title` (the tone word upper-cased), then the body.

**`mailCodeBlock`** / **`codeInline`**

- _Content:_ the code: text, with inline elements (`span`, `strong`,
  `b`, `em`, `i`, `u`, `br`) for highlighting.
- _Built from:_ `mailBox(padding = 12px 16px, border_radius = 6px)` on
  `color.surface.subtle` (dark-paired) holding a `pre` (`font.mono`,
  14px/20px, no margin). `codeInline` is a `code` element on
  `color.border.subtle` (the subtle surface barely shows on white),
  `padding:0 4px` and a 4px radius, in `font.mono` at the size of the
  text around it, breaking a long token rather than widening its line.
  Both read left to right (`dir="ltr"`), the block at the start of its
  line, in a right-to-left message too.
- _Special:_
  - `white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere`,
    with no horizontal scroll (caniemail `css-overflow`);
  - leading indentation (spaces; a tab counts four) converted to
    no-break spaces;
  - highlighting as inline `span` colours only, which the contrast
    checks hold to the same thresholds as any text, in the light and
    designed dark palettes and under both inversion models (R-DRK-04);
  - the font stack ends in `'Courier New', monospace` (`font.mono`,
    R-TXT-05).
- _Text:_ the block: the code verbatim, indented 4 spaces. Inline: its
  text.

**`mailQuote`** (testimonial)

- _Props:_ `name` (required), `role`, `avatar: Url`, `avatar_alt`
  (default empty: the avatar is decorative, the name follows it),
  `glyph: bool = false` (a large decorative quotation mark above the
  quotation).
- _Content:_ the quotation: inline content (one paragraph) or `p`s.
- _Built from:_ a `mailStack(gap = space.3)` of the glyph (when
  `glyph`: `“`, 40px, `color.accent.primary`, `aria-hidden`), the
  quotation as `p`s (18px/28px) inside typographic quotes (`“…”`, which
  the glyph replaces when it is drawn), and the attribution: the name
  (bold) above the role (`type.small`, `color.text.secondary`), beside
  the avatar (square, or a pre-cropped circular PNG as in
  `mailAvatarName`) in a `mailMediaObject(image_width = 48, stack =
never, valign = middle)` when there is one. Not a
  `blockquote`: webmails fold one away as quoted mail (R-TXT-11).
- _A11y:_ decorative quote glyphs are `aria-hidden`.
- _Text:_ the quotation inside typographic quotes, then `— Name, role`.

### 4.4 Data patterns

**`mailKeyValue`** (summary and totals)

- _Props:_ `caption` (the data table's caption, required as for any
  `mailTable`: `E-A11Y-TABLE-CAPTION`), `total_row: bool = false` (the
  last row is the total).
- _Content:_ `mailKeyValueRow(label, emphasis: bool)` items, each
  holding its value.
- _Built from:_ a `mailTable(caption, mobile = keep, border = none)`,
  one row per item: the label a `th scope="row"` (start-aligned, regular
  weight unless `emphasis`, `nowrap` when it is 20 characters or fewer,
  so a wide value never squeezes it), the value a `td` aligned to the
  end, with
  `white-space:nowrap` when it is short (20 characters or fewer: an
  amount; a longer value wraps rather than widen the row past a phone),
  each cell padded `6px 0`. The total row is bold, with a 1px top border
  in `color.border.subtle` (dark-paired) and 12px above its text.
- _Special:_ never stacks: two cells fit at 320px. The keys use `th
scope="row"` in a real table (non-presentation): it reads better in
  screen readers than a presentation table and costs nothing.
- _Text:_ `label: value` lines (no dot leaders or column alignment: most
  clients show plain text in a proportional face, where they drift),
  written by the pattern (`textOnly`): the table walk would write
  `label | value`.

**`mailLineItems`** (invoice)

- _Props:_ `caption` (required, as for any `mailTable`), `mobile:
auto|cards = auto`, `item_label = "Item"`, `qty_label = "Qty"`,
  `amount_label = "Amount"`, `thumb_width = 48`.
- _Content:_ `mailLineItem(description, detail, qty, amount, thumb,
thumb_alt)` items: `description` and `amount` are required; `detail`
  is the second line (SKU, unit price); `thumb` a thumbnail (decorative
  unless `thumb_alt`).
- _Built from:_ a `mailTable(caption, mobile = keep)` of **at most 3
  columns**: a header row (`Item | Qty | Amount`, the last two
  end-aligned) and one row per item. The description cell holds the
  description and, under it, the detail (`type.small`,
  `color.text.secondary`); with a thumbnail, both sit beside it in a
  nested `mailSidebar(fixed = thumb_width, valign = top, gap = space.3,
switch_below = 0)`, never a 4th column. Quantity and amount are
  end-aligned and `nowrap`; without any quantity there is no quantity
  column. A nested sidebar's fixed layout claims no width for its words,
  so with thumbnails the sidebar sits in a box whose `min-width` is the
  thumbnail, its gap and the descriptions' longest word (16px; a
  detail's at 14px) by the text metrics' worst case, whenever that fits
  a band's content width at 320px (288px) beside the quantity and
  amount columns (their widest text and padding): the word then never
  breaks on a phone. When it does not fit, there is no minimum and such
  a word breaks inside the column (a declared degradation; prefer the
  `cards` form for long words beside thumbnails). The table's outer
  cells have no padding on its outer edges, so its text lines up with
  the text around it.
- _Special:_
  - The desktop design is **readable at 320px**: SKU and unit price are
    the description's second line, so no stacking is needed (and none
    happens without CSS).
  - `mobile = cards`: a `mailStack(gap = space.3)` of bordered
    `mailBox`es, one per item, each holding a `mailKeyValue` (its caption
    the description) of `Item`, `Qty` and `Amount` (emphasised), beside
    the thumbnail in a `mailSidebar` when there is one. This is
    the only stacking data design, and it works without CSS because it
    is every client's rendering, not a media-query switch. `auto` is the
    table: the design never has more than 3 columns.
- _Text:_ as a `mailTable`: the caption, then one line per row with
  cells joined by `|` (the description cell reads `description
(detail)`), or `label: value` blocks; cards: each card's `label: value`
  lines.

**`mailStatTiles`**

- _Content:_ `mailStat(value, label, tone = neutral)` items, 2–4 (a
  `value` and a `label` each; another count is `E-VOCAB-BAD-VALUE`).
- _Built from:_ 2–3 items use `mailColumns(strategy = cells, gutter =
space.3, valign = middle)`, each tile its column's cell painted as a
  box (background, 8px radius, padding `16px 4px`), so the tiles share a
  height, with `min_width = 72px` (a short stat, R-TBL-11); 4 items use
  `mailGrid(columns = 4, mobile_columns = 2, gutter = space.3,
min_item = 72px)` of `mailBox`es (ragged when their labels wrap
  differently, R-TBL-10). Each tile holds the value (a `p`, 28px/34px
  bold, 24px/30px when three tiles share a phone's width, centred, in the
  tone's colour) above the label (a `p`,
  `type.small`, centred, `color.text.secondary`). Tones: `neutral` is
  `color.text.primary` on `color.surface.subtle`, `primary` the accent on
  it; the status tones are their colour on their `.bg`.
- _A11y:_ the number and its unit share one text node (the `value`).
- _Text:_ `label: value` lines.

**`mailStepper`** (order status, 3–5 steps: horizontal, or vertical when its labels cannot fit a phone)

- _Props:_ `current: int` (the current step, from 1), `status` (the
  visually hidden line, default `Current step: {label} ({n} of {m})`),
  `text` (the plain-text line, default `Step {n} of {m}: {label}. Next:
{next label}.`, with no `Next` at the last step).
- _Content:_ `mailStep`s, each holding its label.
- _Special lowering (bespoke geometry):_ a fixed, non-stacking table of
  two rows (_design rule_; no framework ships one). The expansion writes
  the table itself, which R-TBL-01 allows for steppers, rather than a
  primitive, with `table-layout:fixed` inline, so no label can widen it
  past its box. One column per step, `100/m`% wide unless a label needs
  more (below):
  - Row 1 (`aria-hidden`): each step's marker, a 28px circle
    (`border-radius:50%`, square in Word) holding the step's number, or
    a check glyph once the step is done, between the halves of its
    connectors: lines drawn as 2px-high `bgcolor` cells, so each
    connector runs from marker to marker (none before the first step or
    after the last). Done and current markers are `color.accent.primary`
    with `color.accent.primaryText`; later ones a 2px
    `color.border.subtle` ring around a `color.text.secondary` number. A
    connector is the accent up to the current step, `color.border.subtle`
    after it.
  - Row 2: the labels (`type.small`, 14px, ≥ 12px), each centred under
    its marker, the current one bold.
  - **A label word never breaks inside its step.** The expansion
    measures each label's longest word, bold at 14px, with the text
    metrics' worst case (`style/metrics`, the estimate that errs wide),
    plus 4px, against a band's content width at 320px (288px: the
    phone's width less the 16px gutters), where 5 steps get about 58px
    each. A step whose word does not fit its equal share is widened to
    it, and the others share the rest equally (each still at least its
    own word): the column widths are those percentages at every width,
    so the markers stay centred over their labels and the connectors run
    marker to marker. Where head CSS is stripped nothing changes, since
    nothing here depends on it.
  - **Vertical form.** When the steps' words cannot all fit 288px
    together, the stepper is drawn vertically at every width, still one
    fixed table: one row per step, its marker (as above) in a 28px track
    beside its label (padded 12px on the start side, vertically
    centred), and between two steps a 16px row whose track is a
    three-cell line (13px, 2px, 13px: the connector, in the colours
    above). A word longer than the label cell itself (an unbroken
    reference) still breaks there (R-TBL-17).
  - Inside a box narrower than a band (a card, a column) a word that
    fits 288px may still break: a declared degradation; keep the labels
    of a nested stepper short. More than 5 steps is
    `E-PATTERN-STEPPER-LONG`, which points to `mailTimeline`; fewer than
    3 is `E-VOCAB-BAD-VALUE`.
- _A11y:_ a visually hidden **and** text-part line `Current step: Shipped
(2 of 4)` is mandatory: a `current` that names no step, or a current
  step without a label, is `E-PATTERN-MISSING-TEXT`. The line is hidden
  with R-A11Y-09's styles; markers are `aria-hidden`.
- _Text:_ `Step 2 of 4: Shipped. Next: Out for delivery.`

**`mailTimeline`** (vertical, any length)

- _Content:_ `mailTimelineEvent(time)` items (`time` required), each
  holding the event's text.
- _Special lowering:_ one table of two rows per event (the expansion
  writes it, as R-TBL-01 allows for timelines), five columns: a 16px
  track of three cells (7px, 2px, 7px), a 12px gap and the fluid text
  cell. The table's layout is fixed inline (`table-layout:fixed`), so
  where head CSS is stripped an unbroken word breaks in the text cell
  instead of widening the table past a phone and squeezing the track.
  - The event's first row: the three track cells painted
    `color.accent.primary`, the outer two rounded, a 16px dot (square
    in Word), beside the time (14px/16px, bold, `nowrap`);
  - its second row: the middle track cell is the line, a `width:2px`
    `bgcolor` cell in `color.border.subtle`, continuous because a row's
    cells share its height and the next row starts with the next dot,
    beside the event's text, padded 16px below. The last event draws
    no line.

  It never stacks and works in Word.

- _Text:_ `time — event` lines.

**`mailEvent`** (date tile + details)

- _Props:_ `month` (required, short: `OCT`), `day` (required),
  `date_text` (the full date and time in text, "Tuesday, 14 October
  2026, 18:00–20:00 CEST"), `location`, `google`, `outlook`, `ics`
  (the calendar links), `google_label = "Google Calendar"`,
  `outlook_label = "Outlook"`, `ics_label = "Apple Calendar (.ics)"`.
- _Content:_ the details (a heading, a description).
- _Built from:_ `mailSidebar(fixed = 64px, valign = top, gap = space.4,
switch_below = 0)` with a date tile (`aria-hidden`: a `mailBox` with a
  1px `color.border.subtle` border and an 8px radius, the month in a
  12px bold row on `color.accent.primary` above the day at 28px/40px
  bold), then a `mailStack(gap = space.2)` of the details, the date line
  (bold), the location and a `mailCluster(gap = space.4)` of the "Add to
  calendar" links (Google, Outlook, .ics).
- _A11y:_ the full date and time in text is mandatory (_design rule_):
  without `date_text`, `E-PATTERN-MISSING-TEXT`.
- _Text:_ the details, the full date line, the location, then the links
  one per line.

### 4.5 Actions and inline items

**`mailButtonGroup`**

- _Props:_ `gap: Len = 12px` (at least 12px: below it is
  `E-VOCAB-BAD-VALUE`), `align: Align` (the start of the direction),
  `stack_on_mobile: bool = false`.
- _Content:_ 1–3 `mailButton`s. A button without a `variant` of its own
  is `solid` when it is the first (the primary action) and `outline`
  after it (secondary): the button's defaults read its place in the
  group.
- _Built from:_ a `mailCluster(gap, row_gap = gap, align)` of the
  buttons: side by side, wrapping where they do not fit, which is
  correct without CSS too (Foundation for Emails; Cerberus). Word lays
  them on one row.
  `stack_on_mobile = true`: a `mailColumns(strategy = hybrid, gutter =
gap)` of one column per button, each button `width = 100%` of its
  column: side by side with equal widths from the breakpoint up, one
  per line at full width on a phone, and stacked wherever head CSS is
  lost (the hybrid row's safe state); Word gets one row (Foundation for
  Emails `small-expand`). Side by side, buttons whose labels wrap onto
  different numbers of lines have different heights (the hybrid row is
  ragged, §3.3).
- _A11y:_ every button is a 44px target (R-BTN-06), 12px or more from
  the next (R-TBL-12).
- _Text:_ each `label: url`, one per line.

**`mailBadge`**

- _Props:_ `tone: Tone = neutral`.
- _Content:_ the label (text).
- _Built from:_ an inline `span`: `display:inline-block`, padding
  `1px 9px`, radius 999px, `type.small` bold, `white-space:nowrap` when
  the label has 20 characters or fewer; the label in
  `color.text.primary` on the tone's tint (`color.surface.subtle` for
  `neutral` and `primary`, a status tone's `.bg`) inside a 1px border in
  the tone's colour (`color.text.secondary` for `neutral`, the accent
  for `primary`), all dark-paired under `designed`. The label is never
  the tone's colour: on its tint that is under 4.5:1 for 14px text
  (primary 4.4:1, info 4.07:1 in the default theme). The border keeps the
  pill visible where its tint is close to the surface (a neutral or
  primary badge on a white card) and where a client darkens the tint
  with the canvas (Outlook web's dark recolouring keeps a border a
  line).
- _Special (the badge Word wrapper):_ Word ignores a span's padding
  (caniemail `css-padding`). When Outlook output is on and the badge
  sits on a line of its own or in a cluster (not inside a line of
  text), the expansion writes it as a single-cell table,
  `display:inline-table`, whose cell carries the padding, the
  background, the radius and the type, following MJML's `mj-social`
  item pattern (R-TBL-01 admits it); every client reads that table, so
  the badge looks the same everywhere and Word pads it. Inside a line
  of text (a paragraph, a heading, a list item, a link) a table cannot
  sit, so the badge stays the span: Word draws it unpadded and square,
  a declared degradation. Groups of badges are a `mailCluster`.
- _A11y:_ the text carries the meaning, never the colour alone.
- _Text:_ `[label]`.

**`mailAvatarName`**

- _Props:_ `name` (required), `role`, `avatar: Url` (required),
  `avatar_alt` (default empty: decorative, the name beside it says who
  it is), `size = 48` (32–96 px), `crop: circle|none = circle`.
- _Built from:_ `mailSidebar(fixed = size, valign = middle, gap =
space.3, switch_below = 0)` of the avatar (a `mailImage` `size` px
  square) and a `mailStack(gap = 0)` of the name (bold) and the role
  (`type.small`, `color.text.secondary`).
- _Special:_ avatars are **circular PNGs**: `crop = circle` has the
  asset pass cut one from a PNG the store holds (R-IMG-13); a hosted
  avatar (an absolute URL) must already be one, `crop = none`
  (otherwise `E-ASSET-CROP`). `border-radius:50%` alone is square in
  Word. Overlapping avatar stacks are not offered (they need negative
  margins; caniemail `css-margin`).
- _Text:_ `Name — role` (the name alone without a role).

**`mailDividerLabel`** ("or")

- _Content:_ the label (text).
- _Special lowering:_ the expansion writes a three-cell table (R-TBL-01
  admits labelled dividers): rule cell | label cell (`type.small`,
  `color.text.secondary`, padding `16px 12px`) | rule cell. The rules
  are the 1px top borders (`color.border.subtle`) of empty cells inside
  nested tables, all `valign = middle`, the rule cells padded `16px 0`
  (Parcel `x-hr`). A border, not a painted cell: a client that inverts
  a message (Outlook web's dark recolouring) darkens a background with
  the canvas, so a painted hairline vanishes, and keeps a border a
  visible line, as it does `mailDivider`'s.
  The table keeps an automatic layout (`table-layout:auto !important`
  inline: the reset fixes every table's layout, which would give the
  label a third of the row). A label of 20 characters or fewer is
  `white-space:nowrap` beside rule cells 50% wide, so its cell takes its
  text's width and the rules share the rest; a longer one wraps in a
  cell 60% wide beside rules of 20%, breaking a word too long for it
  (`word-break:break-word`), so it never widens the row. The rule cells
  are `aria-hidden`; the label is real text.
- _Text:_ `—— or ——`.

**`mailCoupon`**

- _Props:_ `code` (required), `title` (the offer, above the code),
  `hint` (a copy hint, under it), `label = "Code"` (the text part's
  word for the code).
- _Built from:_ `mailBox(border = "2px dashed color.accent.primary",
background = color.surface.subtle, radius 8px, padding 16px 24px)`
  holding a centred `mailStack(gap = space.2)` of the title (bold), the
  code (`font.mono`, 24px/32px bold, `letter-spacing:2px`) and the hint
  (`type.small`, `color.text.secondary`).
- _Special:_ the same background colour on the cell **and** its parent
  (Outlook shows the parent colour between dashes, R-TBL-08; hteumeuleu
  email-bugs #34): the box lowering does this for any dashed or dotted
  box with a background. The code is a `span nolink = true` (R-TXT-06),
  so no data detector turns its digits into a link. The code is text,
  never an image.
- _Text:_ the title, then `Code: ABC-123`, then the hint.

**`mailRatingScale`** (NPS 0–10, stars 1–5)

- _Props:_ `kind: nps|stars = stars`, `href` (required: the link for a
  score, with `{score}` where the score goes; without it
  `E-VOCAB-BAD-VALUE`), `low_label`, `high_label` (the scale's end
  labels; an NPS scale's default `Not likely` and `Very likely`).
- _Built from:_
  - stars: a `mailCluster(gap = 8px)` of 5 linked 44px items, each a
    `★` (28px, `color.accent.primary`) in a 44px square link box;
  - NPS: two fixed rows (0–5 and 6–10), `cells` rows of six 44px-tall
    painted cells (`color.surface.subtle`, a 1px `color.border.subtle`
    border, 6px radius, `min_width = 40px`, gutter 8px) in a
    `mailStack(gap = 8px)`, the second row's sixth cell empty, so the
    wrap point is deterministic, the two rows' cells line up, and every
    target stays 44px tall; each cell's link fills it (`display:block`,
    the number bold, centred);
  - the end labels (`type.small`, `color.text.secondary`) under the
    scale, a `cells` row of two, the high one end-aligned.
- _A11y:_ each link has text: a visually hidden "Rate" before the
  number and "out of 10" ("out of 5") after it, so it reads "Rate 4
  out of 10"; a star's glyph is `aria-hidden` beside its hidden text
  "Rate 4 out of 5". The end labels are real text. Every target is 44px
  tall and 8px from the next (R-TBL-12).
- _Text:_ the end labels (`0 = Not likely, 10 = Very likely`) when
  there are any, then `0: url` … one line per score.

**`mailSecurityCode`** (OTP / magic link)

- _Props:_ `code` (required), `expires` (required: the expiry in
  absolute time, `14:05 UTC`), `label = "Your code"`, `expires_label =
"Expires at"`, `href` and `cta` (the magic link's button).
- _Built from:_ a centred `mailBox` (`color.surface.subtle`, radius 8px,
  padding 24px) holding a `mailStack(gap = space.3)` of the label
  (`type.small`, `color.text.secondary`), the code (`font.mono`,
  32px/40px bold, `letter-spacing:6px`), the expiry line (`type.small`,
  `color.text.secondary`: `Expires at 14:05 UTC`) and an optional
  `mailButton` for the magic link.
- _Special:_ the code is a `span nolink = true` (R-TXT-06: no detector
  links its digits) and is never an image.
- _Text:_ `Your code: 123456 (expires at 14:05 UTC)`, then the button's
  `label: url`.

**`mailSocial`** (the social row) / **`mailAppBadges`**

- _Built from:_ `mailCluster` of icon images.
  - Social icons are the `mailSocial` element (catalogue R-IMG-12):
    24–32px @2x, with light/dark variants swapped (R-IMG-06); alt = the
    network's name (MJML `mj-social`).
  - App badges: `mailAppBadges(height = 40, align = center, gap)`
    holding `mailAppBadge(store: apple|google|other, href, image,
dark_image, width, alt)` items: the application's official artwork
    (`image`, required, with `width` its px width at the row's height),
    40–48px tall (another `height` is `E-VOCAB-BAD-VALUE`), the gap at
    least a quarter of the badge height (default the larger of 12px and
    that; less is `E-VOCAB-BAD-VALUE`) (Apple's App Store marketing
    guidelines); `dark_image` its dark variant, swapped under
    `designed` (R-IMG-06). The alt defaults to `Download on the App
Store` and `Get it on Google Play`; `other` needs one.
- _Text:_ `Network: url` lines; a badge's `alt: url`.

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

Each row is built from exactly these patterns, with no raw markup and no
error, by `test_common_email_types_are_buildable`; the layouts that wrap
them (`receiptLayout`, …) and the reference emails come with the
templates.

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

A story is named after its element without the `mail` prefix, first
letter lower-cased, and the kind (`cardMinimal`, `codeInlineRtl`). Two
exceptions are made, and `test_pattern_story_set_complete` holds every
registered primitive and pattern to the rule with exactly these:

- **Item elements are covered by their parent's stories.** An item
  (`mailStep`, `mailSocialItem`, `mailNavLink`) is a registered pattern
  only its parent places, and it never appears on its own: its six
  stories are its parent's, which show every item kind it has. Items a
  parent reads and consumes (`mailKeyValueRow`, `mailLineItem`,
  `mailStat`, `mailTimelineEvent`, `mailAppBadge`) are not registered
  patterns at all.
- **No `rtl` story where right to left is refused**: `mailZigZag`
  (R-LAY-11).

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
| Images               | exported at 2×; cropped to ratio before sending; no text in images | R-IMG-13, R-IMG-04 |

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
