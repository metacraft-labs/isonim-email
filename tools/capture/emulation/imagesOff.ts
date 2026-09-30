// tools/capture/emulation/imagesOff.ts — backend-A imagesOff emulation.
//
// ImagesOff: replace every `img[src]` with `src=""`, keep
// `alt` and the styling, and remove CSS `background-image`. VML is
// irrelevant in Chromium, so there is no VML handling here.
// A pure HTML→HTML function applied before setContent.

import { mapStyleAttributes } from "./style_attr.ts";

// 2: inline styles are re-escaped after rewriting.
export const IMAGES_OFF_TRANSFORM_VERSION = 2;

// Empty the src of every <img> that has one, keeping alt and all other
// attributes (including dimensions and styling) untouched. The
// lookbehind keeps `data-src` from matching as `src` (outlookWeb's
// spelling). The emulation names `img[src]` only; `srcset` is emptied
// too — leaving it would still load images, defeating the emulation.
function emptyImgSources(html: string): string {
  // Whole-tag match with an inner pass so an <img> carrying both src
  // and srcset gets both emptied (a single flat match ends at the
  // first attribute and never sees the second).
  return html.replace(/<img\b[^>]*>/gi, (tag: string): string =>
    tag.replace(
      /(?<![-\w])(src|srcset)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi,
      `$1=""`,
    ),
  );
}

const STYLE_BLOCK_RE = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;

// Drop every `background-image` declaration from a CSS fragment. The
// declaration must start a declaration (after start, ";" or "{") so a
// URL path cannot match as a property, and the value alternation
// consumes one level of url(...) parens plus quoted strings so
// `url(data:…;base64,…)` is eaten whole instead of stopping at its
// inner semicolon. Only the `background-image` property goes — the
// `background` shorthand is left alone. Exported for
// wordApprox's step 2 (imported — never reimplemented — per the
// ganga precedent).
export function stripBackgroundImageFromCss(css: string): string {
  return css.replace(
    /(?:^|(?<=[;{]))\s*background-image\s*:\s*(?:[^;{}()"']|"[^"]*"|'[^']*'|\([^()]*\))*;?/gi,
    "",
  );
}

function stripBackgroundImages(html: string): string {
  const noBlockBg = html.replace(
    STYLE_BLOCK_RE,
    (match: string, css: string): string => {
      const open = /<style\b[^>]*>/i.exec(match)?.[0] ?? "<style>";
      return `${open}${stripBackgroundImageFromCss(css)}</style>`;
    },
  );
  // Inline style= attributes: decoded, rewritten, re-escaped.
  return mapStyleAttributes(noBlockBg, stripBackgroundImageFromCss);
}

export function imagesOff(html: string): string {
  return stripBackgroundImages(emptyImgSources(html));
}
