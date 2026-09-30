// tools/capture/emulation/outlookWeb.ts — backend-A outlookWeb emulation.
//
// OutlookWeb: prefix every class and id with `x_` in
// markup and CSS; keep attribute selectors; wrap the body in
// `<div class="rps_xxxx">`. For scheme=dark, add `data-ogsc`/
// `data-ogsb` attributes to recoloured elements (R-DRK-03's inverse,
// using the partial-inversion model R-DRK-04). A pure HTML→HTML
// function applied before setContent.

import { joinChunks, splitTopLevel } from "./gmailWeb.ts";

export const OUTLOOK_WEB_TRANSFORM_VERSION = 1;

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
      while (j < head.length && identRest.test(head[j])) j++;
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
// Only inline `color` / `background-color` hex values participate;
// named colours, rgb() and shorthand `background` never match.
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
  const m = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(
    hex
      .trim()
      .replace(/\s*!important\s*$/i, "")
      .trim(),
  );
  if (!m) return null;
  const h =
    m[1].length === 3
      ? m[1]
          .split("")
          .map((c) => c + c)
          .join("")
      : m[1];
  return [
    parseInt(h.slice(0, 2), 16),
    parseInt(h.slice(2, 4), 16),
    parseInt(h.slice(4, 6), 16),
  ];
}

// R-DRK-03's inverse, dark scheme only: Outlook adds data-ogsc/
// data-ogsb itself when it recolours, so the emulation adds them to
// the elements the partial-inversion model selects — data-ogsc where
// the inline text colour inverts (luminance < 0.5), data-ogsb where
// the inline background inverts (luminance > 0.5). Bare attributes:
// the [data-ogsc] / [data-ogsb] selectors match any value.
function addDarkAttributes(html: string): string {
  return html.replace(
    /<[a-zA-Z][a-zA-Z0-9-]*(?:\s[^<>]*?)?>/g,
    (tag: string): string => {
      const style = /(?<![-\w])style\s*=\s*(["'])(.*?)\1/i.exec(tag)?.[2];
      if (style === undefined) return tag;
      let text = false;
      let bg = false;
      for (const decl of style.split(";")) {
        const colon = decl.indexOf(":");
        if (colon < 0) continue;
        const prop = decl.slice(0, colon).trim().toLowerCase();
        if (prop !== "color" && prop !== "background-color") continue;
        const rgb = hexToRgb(decl.slice(colon + 1));
        if (!rgb) continue;
        const lum = relativeLuminance(rgb[0], rgb[1], rgb[2]);
        if (prop === "color" && lum < 0.5) text = true;
        if (prop === "background-color" && lum > 0.5) bg = true;
      }
      let attrs = "";
      if (text && !/\sdata-ogsc(?:\s|=|>|\/)/i.test(tag)) attrs += " data-ogsc";
      if (bg && !/\sdata-ogsb(?:\s|=|>|\/)/i.test(tag)) attrs += " data-ogsb";
      if (!attrs) return tag;
      return tag.replace(/^(<[a-zA-Z][a-zA-Z0-9-]*)/, `$1${attrs}`);
    },
  );
}

// OutlookWeb: the full pipeline. Pure: the output
// depends only on the input HTML and the scheme. forced-dark adds no
// attributes: that inversion is left to Chromium's WebContentsForceDark.
export function outlookWeb(html: string, scheme: string): string {
  const wrapped = wrapRps(prefixStyles(prefixMarkupNames(html)));
  return scheme === "dark" ? addDarkAttributes(wrapped) : wrapped;
}
