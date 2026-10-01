// tools/capture/emulation/outlookWeb.ts — backend-A outlookWeb emulation.
//
// OutlookWeb: prefix every class and id with `x_` in
// markup and CSS; keep attribute selectors; wrap the body in
// `<div class="rps_xxxx">`. For scheme=dark, recolour inline colours
// with the partial-inversion model (R-DRK-04) and mark the recoloured
// elements with `data-ogsc`/`data-ogsb` (R-DRK-03's inverse). A pure
// HTML→HTML function applied before setContent.

import { joinChunks, splitTopLevel } from "./gmailWeb.ts";
import {
  decodeQuoteEntities,
  escapeForQuote,
  START_TAG_RE,
} from "./style_attr.ts";

// 2: dark recolours (partial inversion) instead of only marking.
export const OUTLOOK_WEB_TRANSFORM_VERSION = 2;

const STYLE_BLOCK_RE = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;

// Prefix every class and id with x_ in markup. The lookbehind keeps
// `data-class` / `data-id` attributes (and any `-id` suffix) from
// matching as `class` / `id`. Already-prefixed names are kept as-is,
// so the transform is idempotent.
function prefixMarkupNames(html: string): string {
  const classes = html.replace(
    /(?<![-\w])class\s*=\s*(["'])(.*?)\1/gi,
    (_m: string, q: string, list: string): string =>
      `class=${q}${prefixList(list)}${q}`,
  );
  return classes.replace(
    /(?<![-\w])id\s*=\s*(["'])(.*?)\1/gi,
    (_m: string, q: string, name: string): string =>
      `id=${q}${name.startsWith("x_") ? name : `x_${name}`}${q}`,
  );
}

function prefixList(list: string): string {
  return list
    .split(/\s+/)
    .filter((c) => c.length > 0)
    .map((c) => (c.startsWith("x_") ? c : `x_${c}`))
    .join(" ");
}

// Rewrite .class and #id selectors in selector text only: splitTopLevel
// (gmailWeb's, imported — never reimplemented) keeps declaration bodies
// untouched, so url(...) and hex colours are never rewritten, and the
// quote tracking below keeps quoted attribute values (e.g.
// [href="#sec"]) intact. Attribute-selector rules themselves are kept:
// Outlook honours them.
function prefixCssHead(head: string): string {
  let out = "";
  let quote = "";
  let i = 0;
  const identStart = /[a-zA-Z_-]/;
  const identRest = /[a-zA-Z0-9_-]/;
  while (i < head.length) {
    const c = head[i];
    if (quote) {
      out += c;
      if (c === quote && head[i - 1] !== "\\") quote = "";
      i++;
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      out += c;
      i++;
      continue;
    }
    if ((c === "." || c === "#") && identStart.test(head[i + 1] ?? "")) {
      let j = i + 1;
      while (j < head.length && identRest.test(head[j] ?? "")) j++;
      const name = head.slice(i + 1, j);
      out += name.startsWith("x_") ? c + name : `${c}x_${name}`;
      i = j;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

function prefixCssNames(css: string): string {
  return joinChunks(
    splitTopLevel(css).map((c) => {
      const head = prefixCssHead(c.head);
      if (c.body === null) return { head, body: null };
      const m = /^\s*@media\b/i.exec(c.head);
      return { head, body: m ? prefixCssNames(c.body) : c.body };
    }),
  );
}

function prefixStyles(html: string): string {
  return html.replace(STYLE_BLOCK_RE, (match: string, css: string): string => {
    const open = /<style\b[^>]*>/i.exec(match)?.[0] ?? "<style>";
    return `${open}${prefixCssNames(css)}</style>`;
  });
}

// Wrap the body in Outlook's reader container. Real-client captures
// will pin the wrapper class. Prefixing runs first so the wrapper's
// own class is not rewritten.
function wrapRps(html: string): string {
  const bodyOpen = /<body\b[^>]*>/i.exec(html);
  if (!bodyOpen) return `<div class="rps_xxxx">${html}</div>`;
  const insertAt = bodyOpen.index + bodyOpen[0].length;
  const bodyClose = /<\/body\s*>/i.exec(html);
  if (!bodyClose)
    return (
      html.slice(0, insertAt) +
      `<div class="rps_xxxx">` +
      html.slice(insertAt) +
      `</div>`
    );
  return (
    html.slice(0, insertAt) +
    `<div class="rps_xxxx">` +
    html.slice(insertAt, bodyClose.index) +
    `</div>` +
    html.slice(bodyClose.index)
  );
}

// Partial-inversion membership (R-DRK-04): backgrounds with relative
// luminance > 0.5 and text colours with luminance < 0.5 are the
// recoloured set. Luminance is the WCAG 2 relative luminance, a TS
// port of relativeLuminance in src/isonim_email/passes/lint.nim — TS
// cannot import Nim, so the formula is duplicated here and cited.
// Inline `color` / `background-color` hex values and `bgcolor`
// attributes participate; named colours, rgb() and shorthand
// `background` never match.
function channelLuminance(c: number): number {
  const s = c / 255;
  return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
}

function relativeLuminance(r: number, g: number, b: number): number {
  return (
    0.2126 * channelLuminance(r) +
    0.7152 * channelLuminance(g) +
    0.0722 * channelLuminance(b)
  );
}

function hexToRgb(hex: string): [number, number, number] | null {
  const digits = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(
    hex
      .trim()
      .replace(/\s*!important\s*$/i, "")
      .trim(),
  )?.[1];
  if (digits === undefined) return null;
  const h =
    digits.length === 3
      ? digits
          .split("")
          .map((c) => c + c)
          .join("")
      : digits;
  return [
    parseInt(h.slice(0, 2), 16),
    parseInt(h.slice(2, 4), 16),
    parseInt(h.slice(4, 6), 16),
  ];
}

// sRGB hex ↔ OKLab (Björn Ottosson's matrices, the same ones the
// library's OKLCH parser uses in src/isonim_email/style/colors.nim).
function srgbToLinear(c: number): number {
  const s = c / 255;
  return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
}

function linearToSrgb(u: number): number {
  const s =
    u <= 0.0031308
      ? 12.92 * u
      : 1.055 * Math.pow(Math.max(u, 0), 1 / 2.4) - 0.055;
  return Math.round(Math.min(1, Math.max(0, s)) * 255);
}

function rgbToOklab(r: number, g: number, b: number): [number, number, number] {
  const lr = srgbToLinear(r);
  const lg = srgbToLinear(g);
  const lb = srgbToLinear(b);
  const l = Math.cbrt(
    0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb,
  );
  const m = Math.cbrt(
    0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb,
  );
  const s = Math.cbrt(
    0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb,
  );
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

function oklabToRgb(L: number, a: number, b: number): [number, number, number] {
  const l = Math.pow(L + 0.3963377774 * a + 0.2158037573 * b, 3);
  const m = Math.pow(L - 0.1055613458 * a - 0.0638541728 * b, 3);
  const s = Math.pow(L - 0.0894841775 * a - 1.291485548 * b, 3);
  return [
    linearToSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  ];
}

// R-DRK-04's inversion of one colour: OKLCH lightness L → 1 − L with
// chroma and hue kept (in OKLab terms: a and b unchanged). Channels
// that leave the sRGB gamut are clamped.
export function invertLightness(hex: string): string | null {
  const rgb = hexToRgb(hex);
  if (!rgb) return null;
  const [L, a, b] = rgbToOklab(rgb[0], rgb[1], rgb[2]);
  const [r, g, bl] = oklabToRgb(1 - L, a, b);
  return "#" + [r, g, bl].map((c) => c.toString(16).padStart(2, "0")).join("");
}

// Partial inversion of one inline declaration list: the text colour
// inverts when its luminance is < 0.5, the background when > 0.5.
// Returns the rewritten list and which of the two were recoloured.
function recolourDecls(css: string): {
  css: string;
  text: boolean;
  bg: boolean;
} {
  let text = false;
  let bg = false;
  const out = css
    .split(";")
    .map((decl) => {
      const colon = decl.indexOf(":");
      if (colon < 0) return decl;
      const prop = decl.slice(0, colon).trim().toLowerCase();
      if (prop !== "color" && prop !== "background-color") return decl;
      const value = decl.slice(colon + 1);
      const rgb = hexToRgb(value);
      // hexToRgb accepted the value, so it is one 3/6-digit hex colour
      // (plus an optional !important) and this match always succeeds.
      // Were it ever to fail, the declaration is left as written and
      // not counted as recoloured — the same as any value hexToRgb
      // rejects.
      const hex = /#[0-9a-f]{3,6}/i.exec(value)?.[0];
      if (!rgb || hex === undefined) return decl;
      const lum = relativeLuminance(rgb[0], rgb[1], rgb[2]);
      const inverts = prop === "color" ? lum < 0.5 : lum > 0.5;
      if (!inverts) return decl;
      if (prop === "color") text = true;
      else bg = true;
      const important = /!\s*important\s*$/i.test(value) ? " !important" : "";
      return `${decl.slice(0, colon + 1)}${invertLightness(hex)}${important}`;
    })
    .join(";");
  return { css: out, text, bg };
}

// R-DRK-03's inverse plus the recolouring itself, dark scheme only.
// Outlook on the web recolours in dark mode with the partial-inversion
// model (R-DRK-04) — inline text colours with luminance < 0.5 and
// inline backgrounds (background-color or bgcolor) with luminance >
// 0.5 are lightness-inverted — and marks what it recoloured with
// data-ogsc (text) / data-ogsb (background). The message's own
// `[data-ogsc] …` / `[data-ogsb] …` head rules then apply over the
// recoloured values, exactly as they do in the client. Bare
// attributes: the selectors match any value. Only 3/6-digit hex takes
// part (the library emits 6-digit hex, R-CSS-12); named colours and
// rgb() are left as they are.
function recolourDark(html: string): string {
  return html.replace(START_TAG_RE, (tag: string): string => {
    let text = false;
    let bg = false;
    let out = tag.replace(
      /(?<![-\w])style\s*=\s*(?:"([^"]*)"|'([^']*)')/i,
      (_m: string, dq: string | undefined, sq: string | undefined): string => {
        const quote = dq !== undefined ? '"' : "'";
        const r = recolourDecls(decodeQuoteEntities(dq ?? sq ?? ""));
        text ||= r.text;
        bg ||= r.bg;
        return `style=${quote}${escapeForQuote(r.css, quote)}${quote}`;
      },
    );
    out = out.replace(
      /(?<![-\w])bgcolor\s*=\s*(["']?)(#[0-9a-f]{3}(?:[0-9a-f]{3})?)\1/i,
      (m: string, q: string, hex: string): string => {
        // The pattern admits only 3/6-digit hex, which hexToRgb reads.
        const rgb = hexToRgb(hex);
        if (rgb === null || relativeLuminance(...rgb) <= 0.5) return m;
        bg = true;
        return `bgcolor=${q}${invertLightness(hex)}${q}`;
      },
    );
    let attrs = "";
    if (text && !/\sdata-ogsc(?:\s|=|>|\/)/i.test(out)) attrs += " data-ogsc";
    if (bg && !/\sdata-ogsb(?:\s|=|>|\/)/i.test(out)) attrs += " data-ogsb";
    if (!attrs) return out;
    return out.replace(/^(<[a-zA-Z][a-zA-Z0-9:-]*)/, `$1${attrs}`);
  });
}

// OutlookWeb: the full pipeline. Pure: the output
// depends only on the input HTML and the scheme. forced-dark adds no
// attributes: that inversion is left to Chromium's WebContentsForceDark.
export function outlookWeb(html: string, scheme: string): string {
  const wrapped = wrapRps(prefixStyles(prefixMarkupNames(html)));
  return scheme === "dark" ? recolourDark(wrapped) : wrapped;
}
