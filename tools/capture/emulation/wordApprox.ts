// tools/capture/emulation/wordApprox.ts — backend-A wordApprox emulation.
//
// WordApprox steps 1–5: a pure HTML→HTML function applied
// before setContent. This is a LINT-GRADE approximation: it makes no
// attempt to imitate Word's text layout. It exists so that structural
// mistakes — a missing ghost table, a layout that depends on
// max-width — are visible in seconds. What Word really does is judged
// only on backends C and D.

// 2: inline styles are re-escaped after rewriting.
// 3: declarations whose value uses calc() are stripped (step 2).
// 4: box-shadow is stripped (step 2).
// 5: a cell's mso-padding-alt is its padding (step 2).
// 6: a shape filled with an image (v:fill src) shows the image (step 4).
export const WORD_APPROX_TRANSFORM_VERSION = 6;

import { joinChunks, splitTopLevel } from "./gmailWeb.ts";
import { stripBackgroundImageFromCss } from "./imagesOff.ts";
import { mapStyleAttributes } from "./style_attr.ts";

const STYLE_BLOCK_RE = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;

// Step 1: reveal <!--[if mso]> and <!--[if gte mso 9]>
// content (unwrap: keep the inner markup, drop the markers), and
// delete <!--[if !mso]><!-->…<!--<![endif]--> content whole. Other
// conditions are left untouched: downlevel-hidden blocks stay hidden
// in Chromium exactly as Word hides them, so touching them would only
// add drift.
const MSO_OPEN_RES = [
  /<!--\[if\s+mso\s*\]>/gi,
  /<!--\[if\s+gte\s+mso\s+9\s*\]>/gi,
];
const MSO_CLOSE_RE = /<!\[endif\]-->/gi;
const NOT_MSO_BLOCK_RE =
  /<!--\[if\s+!mso\s*\]\s*><!-->([\s\S]*?)<!--\s*<!\[endif\]\s*-->/gi;

export function revealMsoConditionals(html: string): string {
  // The !mso branch goes first and whole (content included): Word
  // never renders it.
  const noNotMso = html.replace(NOT_MSO_BLOCK_RE, "");
  // Then unwrap each mso/gte-mso-9 block in turn. Sequential pairs
  // (ghost-table open/close markers are separate pairs, never nested)
  // resolve one at a time; the pass repeats until no pair remains.
  let out = noNotMso;
  for (;;) {
    let changed = false;
    for (const openRe of MSO_OPEN_RES) {
      openRe.lastIndex = 0;
      const open = openRe.exec(out);
      if (!open) continue;
      MSO_CLOSE_RE.lastIndex = open.index + open[0].length;
      const close = MSO_CLOSE_RE.exec(out);
      // Unmatched opener: a truncated document — leave it a comment
      // rather than leak raw markup.
      if (!close) continue;
      out =
        out.slice(0, open.index) +
        out.slice(open.index + open[0].length, close.index) +
        out.slice(close.index + close[0].length);
      changed = true;
      break;
    }
    if (!changed) return out;
  }
}

// Step 2: strip what Word ignores — max-width (R-OL-03),
// display:flex|grid|inline-block, any declaration whose value uses
// calc() (caniemail css-unit-calc: unsupported in Outlook for Windows;
// the Fab Four column width), box-shadow (caniemail box-shadow: no
// support in Outlook for Windows; R-TBL-09), CSS background-image (R-OL-11),
// border-radius (R-OL-12), margin:auto (R-LAY-08: centring in Word
// comes from align="center" on the ghost table, never from
// margin:auto), and padding on anything but td/th (R-OL-05) — from
// style blocks and inline style= alike. Declaration spelling follows
// gmailWeb's stripVarDecls: a declaration must start a declaration
// (after start, ";" or "{") so URLs cannot match as properties.

// Any margin declaration whose value names auto (margin:0 auto,
// margin-left:auto, …). The value class cannot overrun into the next
// declaration (";" never appears inside a margin value unquoted).
const MARGIN_AUTO_RE =
  /(?:^|(?<=[;{]))\s*margin(?:-[a-z-]+)?\s*:[^;{}]*\bauto\b[^;{}]*;?/gi;

// display:flex, display:grid and display:inline-block only — every
// other display value survives.
const BAD_DISPLAY_RE =
  /(?:^|(?<=[;{]))\s*display\s*:\s*(?:flex|grid|inline-block)\b[^;{}]*;?/gi;

const MAX_WIDTH_RE = /(?:^|(?<=[;{]))\s*max-width\s*:[^;{}]*;?/gi;
const CALC_RE = /(?:^|(?<=[;{]))\s*[a-z-]+\s*:[^;{}]*\bcalc\([^;{}]*;?/gi;
const BORDER_RADIUS_RE = /(?:^|(?<=[;{]))\s*border-radius\s*:[^;{}]*;?/gi;
const BOX_SHADOW_RE = /(?:^|(?<=[;{]))\s*box-shadow\s*:[^;{}]*;?/gi;
const PADDING_RE = /(?:^|(?<=[;{]))\s*padding(?:-[a-z-]+)?\s*:[^;{}]*;?/gi;

function stripNonPaddingDecls(css: string): string {
  return stripBackgroundImageFromCss(
    css
      .replace(MAX_WIDTH_RE, "")
      .replace(CALC_RE, "")
      .replace(BAD_DISPLAY_RE, "")
      .replace(BORDER_RADIUS_RE, "")
      .replace(BOX_SHADOW_RE, "")
      .replace(MARGIN_AUTO_RE, ""),
  );
}

// A rule keeps its padding only when a selector in its list names td
// or th as a type selector (R-OL-05: padding is reliable only on
// td). Class/id selectors (.td, #td) and attribute text do not count.
function selectorKeepsPadding(head: string): boolean {
  return /(^|[\s,>+~])(td|th)(?=[\s,>+~.:#[]|$)/i.test(head);
}

function stripPaddingFromCss(css: string): string {
  return joinChunks(
    splitTopLevel(css).map((c) => {
      if (c.body === null) return c;
      if (/^\s*@media\b/i.test(c.head))
        return { head: c.head, body: stripPaddingFromCss(c.body) };
      return {
        head: c.head,
        body: selectorKeepsPadding(c.head)
          ? c.body
          : c.body.replace(PADDING_RE, ""),
      };
    }),
  );
}

function stripStep2FromCss(css: string): string {
  return stripPaddingFromCss(stripNonPaddingDecls(css));
}

function stripStep2Styles(html: string): string {
  return html.replace(STYLE_BLOCK_RE, (match: string, css: string): string => {
    const open = /<style\b[^>]*>/i.exec(match)?.[0] ?? "<style>";
    return `${open}${stripStep2FromCss(css)}</style>`;
  });
}

// Inline style=: td/th keep their padding (and lose the rest); every
// other element loses padding too. A cell's `mso-padding-alt` is the
// padding Word lays it out with, in place of its CSS padding (R-OL-05,
// R-BTN-01: a table button's padding is on its link, which Word
// ignores, and on its cell as mso-padding-alt). Decoded, rewritten and
// re-escaped through mapStyleAttributes.
const MSO_PADDING_ALT_RE =
  /(?:^|(?<=;))\s*mso-padding-alt\s*:\s*([^;{}]*?)\s*(?:;|$)/i;

function stripStep2Inline(html: string): string {
  return mapStyleAttributes(html, (attr: string, tag: string): string => {
    const keepPadding = /^<(td|th)\b/i.test(tag);
    const css = stripNonPaddingDecls(attr);
    if (!keepPadding) return css.replace(PADDING_RE, "");
    const alt = MSO_PADDING_ALT_RE.exec(css);
    if (alt === null) return css;
    const rest = css.replace(PADDING_RE, "").replace(/;?\s*$/, "");
    return `${rest}${rest.length > 0 ? ";" : ""}padding:${alt[1]};`;
  });
}

export function stripWordIgnoredCss(html: string): string {
  return stripStep2Inline(stripStep2Styles(html));
}

// Step 3: strip every @media rule from <style> blocks. Word
// honours no media query (R-LAY-02 excludes outlookWord), so keeping
// any of them would paint a responsive picture Word never shows.
// gmailWeb's splitTopLevel, imported — never reimplemented — per the
// ganga precedent.
function stripMediaFromCss(css: string): string {
  return joinChunks(
    splitTopLevel(css)
      .map((c) => {
        if (c.body === null) return /^\s*@media\b/i.test(c.head) ? null : c;
        if (/^\s*@media\b/i.test(c.head)) return null;
        if (/^\s*@/i.test(c.head))
          return { head: c.head, body: stripMediaFromCss(c.body) };
        return c;
      })
      .filter((c) => c !== null),
  );
}

export function stripMediaQueries(html: string): string {
  return html.replace(STYLE_BLOCK_RE, (match: string, css: string): string => {
    const open = /<style\b[^>]*>/i.exec(match)?.[0] ?? "<style>";
    return `${open}${stripMediaFromCss(css)}</style>`;
  });
}

// Step 4: replace VML shapes (R-VML-01/02) with a flat <div>
// rectangle of their fillcolor/color at their px size, with a dashed
// outline and the label "VML". Chromium renders no VML, so without
// the stand-in a VML-backed hero would screenshot as missing.
//
// Tag-wise, never wholesale: the open and close tags of one shape
// usually sit in separate conditionals with live content between
// them, which Word shows and the emulation must keep. Shape tags
// (v:rect, v:roundrect, v:shape, v:image) become the opening/closing
// div; inner v:fill/v:textbox tags unwrap (tags dropped, content
// kept). A self-closing shape becomes a closed div around the label.
const VML_SHAPES = "rect|roundrect|shape|image";
const VML_SELF_CLOSING_RE = new RegExp(
  `<v:(${VML_SHAPES})\\b([^>]*?)\\/>`,
  "gi",
);
const VML_OPEN_RE = new RegExp(`<v:(${VML_SHAPES})\\b([^>]*)>`, "gi");
const VML_CLOSE_RE = new RegExp(`</v:(${VML_SHAPES})\\s*>`, "gi");
const VML_INNER_RE = /<\/?v:(?:fill|textbox)\b[^>]*>/gi;

function vmlAttr(tag: string, name: string): string | null {
  const m = new RegExp(
    `\\b${name}\\s*=\\s*("[^"]*"|'[^']*'|[^\\s>]+)`,
    "i",
  ).exec(tag);
  const raw = m?.[1];
  if (raw === undefined) return null;
  return raw.startsWith('"') || raw.startsWith("'") ? raw.slice(1, -1) : raw;
}

// A px length from a style fragment or a width/height attribute:
// unitless and px pass through, pt converts at 96/72, anything else
// is unknown (no guess — the div keeps its auto size).
function vmlPx(value: string | null): string | null {
  if (value === null) return null;
  const [, num, unit] = /^\s*([\d.]+)\s*(px|pt)?\s*$/i.exec(value) ?? [];
  if (num === undefined) return null;
  if ((unit ?? "px").toLowerCase() === "pt")
    return `${Math.round((parseFloat(num) * 96) / 72)}px`;
  return `${num}px`;
}

function vmlSize(attrs: string): {
  width: string | null;
  height: string | null;
} {
  const style = vmlAttr(attrs, "style") ?? "";
  const w =
    /(?:^|;)\s*width\s*:\s*([^;]+)/i.exec(style)?.[1] ??
    vmlAttr(attrs, "width");
  const h =
    /(?:^|;)\s*height\s*:\s*([^;]+)/i.exec(style)?.[1] ??
    vmlAttr(attrs, "height");
  return { width: vmlPx(w ?? null), height: vmlPx(h ?? null) };
}

function vmlRectDiv(attrs: string, closed: boolean): string {
  const color =
    vmlAttr(attrs, "fillcolor") ?? vmlAttr(attrs, "color") ?? "#cccccc";
  const { width, height } = vmlSize(attrs);
  const dims =
    (width ? `width:${width};` : "") + (height ? `height:${height};` : "");
  const open = `<div style="${dims}background-color:${color};outline:2px dashed #000">VML`;
  return closed ? `${open}</div>` : open;
}

const VML_FILLED_OPEN_RE = new RegExp(
  `<v:(${VML_SHAPES})\\b([^>]*)>\\s*<v:fill\\b([^>]*?)\\/?>`,
  "gi",
);

// A VML fill fraction (`-0.5`, `0.5`) as a CSS position percentage: a
// frame is placed by its centre, a tile by its corner.
function fillPercent(value: string | undefined, tile: boolean): string {
  const f = parseFloat(value ?? "0");
  const pct = Number.isFinite(f) ? (tile ? f * 100 : 50 + f * 100) : 50;
  return `${Math.round(pct * 100) / 100}%`;
}

function vmlImageDiv(shapeAttrs: string, fillAttrs: string): string | null {
  const src = vmlAttr(fillAttrs, "src");
  if (src === null || src === "") return null;
  const color =
    vmlAttr(fillAttrs, "color") ??
    vmlAttr(shapeAttrs, "fillcolor") ??
    "#cccccc";
  const tile = (vmlAttr(fillAttrs, "type") ?? "").toLowerCase() === "tile";
  const aspect = (vmlAttr(fillAttrs, "aspect") ?? "").toLowerCase();
  const size =
    aspect === "atleast" ? "cover" : aspect === "atmost" ? "contain" : "auto";
  const [px, py] = (vmlAttr(fillAttrs, "position") ?? "0, 0").split(",");
  const { width, height } = vmlSize(shapeAttrs);
  const dims =
    (width ? `width:${width};` : "") + (height ? `height:${height};` : "");
  return (
    `<div style="${dims}background-color:${color};` +
    `background-image:url('${src}');background-size:${size};` +
    `background-position:${fillPercent(px, tile)} ${fillPercent(py, tile)};` +
    `background-repeat:${tile ? "repeat" : "no-repeat"};` +
    `position:relative;outline:2px dashed #000">` +
    `<span style="position:absolute;top:0;left:0;font:10px/12px monospace;` +
    `background:#000;color:#fff">VML</span>`
  );
}

export function replaceVml(html: string): string {
  const filled = html.replace(
    VML_FILLED_OPEN_RE,
    (m: string, _t: string, shape: string, fill: string): string =>
      vmlImageDiv(shape, fill) ?? m,
  );
  const shapesClosed = filled.replace(
    VML_SELF_CLOSING_RE,
    (_m: string, _t: string, attrs: string): string => vmlRectDiv(attrs, true),
  );
  const shapesOpen = shapesClosed.replace(
    VML_OPEN_RE,
    (_m: string, _t: string, attrs: string): string => vmlRectDiv(attrs, false),
  );
  const shapesShut = shapesOpen.replace(VML_CLOSE_RE, "</div>");
  return shapesShut.replace(VML_INNER_RE, "");
}

// Step 5: drop rgba alpha — rgba(r,g,b,a) becomes rgb(r,g,b)
// (R-CSS-14: Word ignores rgba; the library emits the opaque blend
// first, so what remains here is other clients' copy). Style blocks
// and inline style= only, so text content is never touched.
const RGBA_RE =
  /rgba\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*[\d.]+\s*\)/gi;

function dropRgbaFromCss(css: string): string {
  return css.replace(RGBA_RE, "rgb($1,$2,$3)");
}

export function dropRgbaAlpha(html: string): string {
  const inBlocks = html.replace(
    STYLE_BLOCK_RE,
    (match: string, css: string): string => {
      const open = /<style\b[^>]*>/i.exec(match)?.[0] ?? "<style>";
      return `${open}${dropRgbaFromCss(css)}</style>`;
    },
  );
  return mapStyleAttributes(inBlocks, dropRgbaFromCss);
}

// WordApprox: the full five-step pipeline. Pure: the
// output depends only on the input HTML. Order matters: the mso
// unwrap (1) must precede the VML pass (4), whose shapes hide inside
// gte-mso-9 conditionals, and the rgba flattening (5) runs last so it
// sees only surviving declarations.
export function wordApprox(html: string): string {
  return dropRgbaAlpha(
    replaceVml(
      stripMediaQueries(stripWordIgnoredCss(revealMsoConditionals(html))),
    ),
  );
}
