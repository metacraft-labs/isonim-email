// tools/capture/emulation/gmailWeb.ts — backend-A gmailWeb emulation.
//
// GmailWeb steps 1–6: a pure HTML→HTML function applied
// before setContent. Every step cites its rendering-catalogue rule.
// Targeted regex/string passes only — no CSS parser here.

import { mapStyleAttributes } from "./style_attr.ts";

// 2: inline styles are re-escaped after rewriting (a decoded &quot;
// no longer ends the attribute), and the clip keeps text up to the
// byte limit instead of backing up to the last tag.
export const GMAIL_WEB_TRANSFORM_VERSION = 2;

// Byte budget for kept head <style> blocks (R-CSS-07) and the clip
// threshold for the whole document (R-SIZE-01).
const HEAD_CSS_BUDGET = 16384;
const CLIP_THRESHOLD = 102400;

// FNV-1a (32-bit) over the HTML, first 6 hex digits. Gmail rewrites
// every class to m_<hash><name>; the hash is per-message, so it is
// taken over the transform input.
export function gmailHash(html: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < html.length; i++) {
    h ^= html.charCodeAt(i) & 0xff;
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0").slice(0, 6);
}

function byteLen(s: string): number {
  return Buffer.byteLength(s, "utf8");
}

const STYLE_BLOCK_RE = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;
const STYLE_OPEN_RE = /<style\b[^>]*>/gi;

// Step 1: remove <style> outside <head>. Gmail drops them;
// only head styles participate in step 2. A document with no head
// keeps no style blocks at all.
export function stripNonHeadStyles(html: string): string {
  const headOpen = /<head\b[^>]*>/i.exec(html);
  const headClose = /<\/head\s*>/i.exec(html);
  if (!headOpen || !headClose || headClose.index < headOpen.index)
    return html.replace(STYLE_BLOCK_RE, "").replace(STYLE_OPEN_RE, "");
  // (String.replace with a /g regex always scans from 0, so the
  // shared patterns need no lastIndex resets here.)
  const headStart = headOpen.index + headOpen[0].length;
  const headEnd = headClose.index;
  const before = html
    .slice(0, headStart)
    .replace(STYLE_BLOCK_RE, "")
    .replace(STYLE_OPEN_RE, "");
  const after = html
    .slice(headEnd)
    .replace(STYLE_BLOCK_RE, "")
    .replace(STYLE_OPEN_RE, "");
  return before + html.slice(headStart, headEnd) + after;
}

// Step 2: per head <style> in document order, drop the whole
// block on any poison, else keep while the running byte total of kept
// blocks stays ≤ 16,384. The block that crosses the budget is dropped
// together with everything after it (R-CSS-07).
function hasUppercaseImportant(css: string): boolean {
  // R-CSS-03: Gmail drops a block containing uppercase !IMPORTANT.
  return css.includes("!IMPORTANT");
}

function stripCssComments(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//g, "");
}

function hasNestedAtRule(css: string): boolean {
  // R-CSS-04: an at-rule opened inside another rule's braces poisons
  // the block. Single scan tracking brace depth, skipping quoted
  // strings so content:"{" cannot unbalance it.
  const text = stripCssComments(css);
  let depth = 0;
  let quote = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      if (c === quote && text[i - 1] !== "\\") quote = "";
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      continue;
    }
    if (c === "{") {
      depth++;
      continue;
    }
    if (c === "}") {
      if (depth > 0) depth--;
      continue;
    }
    if (c === "@" && depth > 0 && /[a-zA-Z]/.test(text[i + 1] ?? ""))
      return true;
  }
  return false;
}

function hasCssParseError(css: string): boolean {
  // R-CSS-05: unbalanced braces stand in for a CSS parse error —
  // enough to emulate Gmail discarding the block.
  const text = stripCssComments(css);
  let depth = 0;
  let quote = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      if (c === quote && text[i - 1] !== "\\") quote = "";
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      continue;
    }
    if (c === "{") depth++;
    else if (c === "}") {
      if (depth === 0) return true;
      depth--;
    }
  }
  return depth !== 0;
}

function dropWholeBlock(css: string): boolean {
  return (
    hasUppercaseImportant(css) || hasNestedAtRule(css) || hasCssParseError(css)
  );
}

export function filterHeadStyles(html: string): string {
  const headOpen = /<head\b[^>]*>/i.exec(html);
  const headClose = /<\/head\s*>/i.exec(html);
  if (!headOpen || !headClose || headClose.index < headOpen.index) return html;
  const headStart = headOpen.index + headOpen[0].length;
  const headEnd = headClose.index;
  const inner = html.slice(headStart, headEnd);
  let total = 0;
  let overBudget = false;
  const filtered = inner.replace(
    STYLE_BLOCK_RE,
    (match: string, css: string): string => {
      if (overBudget) return "";
      if (dropWholeBlock(css)) return "";
      // R-CSS-07: the running total counts kept blocks only; the
      // block that would cross 16,384 bytes is dropped, and so is
      // everything after it.
      const size = byteLen(css);
      if (total + size > HEAD_CSS_BUDGET) {
        overBudget = true;
        return "";
      }
      total += size;
      return match;
    },
  );
  return html.slice(0, headStart) + filtered + html.slice(headEnd);
}

// Step 3: inside kept blocks, remove rules with attribute
// selectors (R-CSS-09), media queries on features other than width
// (R-CSS-10), plus @font-face and @import.
function stripAtImports(css: string): string {
  return css.replace(/@import[^;]*;/gi, "");
}

function stripFontFace(css: string): string {
  // @font-face bodies never nest, so a flat match suffices.
  return css.replace(/@font-face\s*\{[^{}]*\}/gi, "");
}

function isWidthOnlyQuery(query: string): boolean {
  // R-CSS-10: keep only queries whose every feature is width,
  // min-width or max-width. A query with no features (e.g. "screen")
  // is kept.
  const features = query.match(/\(([a-zA-Z-]+)\s*(?::[^()]*)?\)/g) ?? [];
  return features.every((f) =>
    /^\((?:min-|max-)?width\s*(?::[^()]*)?\)$/.test(f.trim()),
  );
}

// Split top-level CSS into (header, body|null) chunks: "selector" +
// "{…}" pairs plus bare at-statements. Bodies are matched with brace
// counting; quoted strings are skipped.
// Exported for outlookWeb's selector rewriting (imported — never
// reimplemented — per the ganga precedent).
export function splitTopLevel(
  css: string,
): { head: string; body: string | null }[] {
  const chunks: { head: string; body: string | null }[] = [];
  let i = 0;
  let head = "";
  let quote = "";
  while (i < css.length) {
    const c = css[i];
    if (quote) {
      head += c;
      if (c === quote && css[i - 1] !== "\\") quote = "";
      i++;
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      head += c;
      i++;
      continue;
    }
    if (c === "{") {
      let depth = 1;
      let j = i + 1;
      let q2 = "";
      while (j < css.length && depth > 0) {
        const d = css[j];
        if (q2) {
          if (d === q2 && css[j - 1] !== "\\") q2 = "";
        } else if (d === '"' || d === "'") q2 = d;
        else if (d === "{") depth++;
        else if (d === "}") depth--;
        j++;
      }
      chunks.push({ head, body: css.slice(i + 1, j - 1) });
      head = "";
      i = j;
      continue;
    }
    if (c === ";") {
      chunks.push({ head: head + ";", body: null });
      head = "";
      i++;
      continue;
    }
    head += c;
    i++;
  }
  if (head.trim() !== "") chunks.push({ head, body: null });
  return chunks;
}

export function joinChunks(
  chunks: { head: string; body: string | null }[],
): string {
  return chunks
    .map((c) => (c.body === null ? c.head : `${c.head}{${c.body}}`))
    .join("");
}

function stripAttributeRules(css: string): string {
  // R-CSS-09: drop any rule whose selector uses an attribute
  // selector. Runs on plain rule lists (never on @media headers).
  return joinChunks(
    splitTopLevel(css).filter((c) => c.body === null || !c.head.includes("[")),
  );
}

function stripNonWidthMedia(css: string): string {
  // R-CSS-10: drop @media blocks whose query names any feature
  // other than width; attribute-selector rules are filtered out of
  // the queries that survive.
  return joinChunks(
    splitTopLevel(css)
      .map((c) => {
        const m = /^\s*@media\b([\s\S]*)$/i.exec(c.head);
        if (m === null || c.body === null) return c;
        if (!isWidthOnlyQuery(m[1])) return null;
        return { head: c.head, body: stripAttributeRules(c.body) };
      })
      .filter((c) => c !== null),
  );
}

export function filterKeptCss(css: string): string {
  return stripNonWidthMedia(
    stripAttributeRules(stripFontFace(stripAtImports(css))),
  );
}

export function filterKeptStyles(html: string): string {
  const headOpen = /<head\b[^>]*>/i.exec(html);
  const headClose = /<\/head\s*>/i.exec(html);
  if (!headOpen || !headClose || headClose.index < headOpen.index) return html;
  const headStart = headOpen.index + headOpen[0].length;
  const headEnd = headClose.index;
  const filtered = html
    .slice(headStart, headEnd)
    .replace(STYLE_BLOCK_RE, (match: string, css: string): string => {
      const open = /<style\b[^>]*>/i.exec(match)?.[0] ?? "<style>";
      return `${open}${filterKeptCss(css)}</style>`;
    });
  return html.slice(0, headStart) + filtered + html.slice(headEnd);
}

// Step 4: remove var() declarations (R-CSS-11), data: images
// (R-IMG-08) and <link> elements. Named exports so ganga (which strips
// every <style>/<link> first, then applies gmailWeb steps 4–5) reuses
// them.
function stripVarDeclsFromCss(css: string): string {
  // R-CSS-11: drop any declaration whose value uses var(). The
  // property name must start a declaration (after start, ";" or
  // "{") so url(http://…) cannot match as a "property", and [^;{}]
  // cannot overrun into the next declaration (";" never appears
  // inside var(...) unquoted).
  return css.replace(
    /(?:^|(?<=[;{]))\s*[a-zA-Z-][a-zA-Z0-9-]*\s*:[^;{}]*?var\([^;{}]*\)[^;{}]*;?/g,
    "",
  );
}

export function stripVarDecls(html: string): string {
  const noBlockVars = html.replace(
    STYLE_BLOCK_RE,
    (match: string, css: string): string => {
      const open = /<style\b[^>]*>/i.exec(match)?.[0] ?? "<style>";
      return `${open}${stripVarDeclsFromCss(css)}</style>`;
    },
  );
  return mapStyleAttributes(noBlockVars, stripVarDeclsFromCss);
}

export function stripDataImages(html: string): string {
  // R-IMG-08: Gmail does not render data: images, so the emulation
  // drops every <img> whose src is a data: URI.
  return html.replace(
    /<img\b[^>]*?\bsrc\s*=\s*("data:.*?"|'data:.*?'|data:[^\s>]+)[^>]*>/gi,
    "",
  );
}

export function stripLinks(html: string): string {
  return html.replace(/<link\b[^>]*>/gi, "");
}

// Step 5: prefix every class with m_<hash> in markup and CSS,
// then wrap the body in Gmail's <div class="a3s">. Prefixing runs
// first so the wrapper's own class is not rewritten.
function prefixMarkupClasses(html: string, prefix: string): string {
  return html.replace(
    /\bclass\s*=\s*(["'])(.*?)\1/gi,
    (_m: string, q: string, list: string): string =>
      `class=${q}${prefixClasses(list, prefix)}${q}`,
  );
}

function prefixClasses(list: string, prefix: string): string {
  return list
    .split(/\s+/)
    .filter((c) => c.length > 0)
    .map((c) => (c.startsWith(prefix) ? c : prefix + c))
    .join(" ");
}

// Rewrite .class selectors in selector text only (depth-0 runs
// outside rule bodies), so url(foo.png) and string content inside
// declarations are never touched.
function prefixCssClasses(css: string, prefix: string): string {
  const chunks = splitTopLevel(css);
  return joinChunks(
    chunks.map((c) => {
      const head = c.head.replace(
        /\.([a-zA-Z_-][a-zA-Z0-9_-]*)/g,
        (_m: string, name: string): string =>
          name.startsWith(prefix) ? `.${name}` : `.${prefix}${name}`,
      );
      if (c.body === null) return { head, body: null };
      const m = /^\s*@media\b/i.exec(c.head);
      return {
        head,
        body: m ? prefixCssClasses(c.body, prefix) : c.body,
      };
    }),
  );
}

export function prefixClassesWithHash(html: string, hash: string): string {
  const prefix = `m_${hash}`;
  const inMarkup = prefixMarkupClasses(html, prefix);
  return inMarkup.replace(
    STYLE_BLOCK_RE,
    (match: string, css: string): string => {
      const open = /<style\b[^>]*>/i.exec(match)?.[0] ?? "<style>";
      return `${open}${prefixCssClasses(css, prefix)}</style>`;
    },
  );
}

export function wrapA3s(html: string): string {
  const bodyOpen = /<body\b[^>]*>/i.exec(html);
  if (!bodyOpen) return `<div class="a3s">${html}</div>`;
  const insertAt = bodyOpen.index + bodyOpen[0].length;
  const bodyClose = /<\/body\s*>/i.exec(html);
  if (!bodyClose)
    return (
      html.slice(0, insertAt) +
      `<div class="a3s">` +
      html.slice(insertAt) +
      `</div>`
    );
  return (
    html.slice(0, insertAt) +
    `<div class="a3s">` +
    html.slice(insertAt, bodyClose.index) +
    `</div>` +
    html.slice(bodyClose.index)
  );
}

// Step 6 (clip): if the HTML exceeds 102,400 bytes, cut it at that
// byte offset and append Gmail's "[Message clipped]  View entire
// message" marker (R-SIZE-01). Tag-aware: a cut that lands inside a
// tag, a comment or a character reference moves back to its start, and
// a cut inside a multi-byte character moves back to that character.
// Text is never lost to the cut beyond the limit itself — a long
// paragraph is clipped mid-text, as Gmail clips it, instead of backing
// up to the last tag before it. Real-client captures will pin the
// exact threshold.
export function clipLongHtml(html: string): string {
  const bytes = Buffer.from(html, "utf8");
  if (bytes.length <= CLIP_THRESHOLD) return html;
  let end = CLIP_THRESHOLD;
  // A UTF-8 continuation byte (10xxxxxx) at the cut means the cut
  // splits a character: back up to its lead byte.
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
  let cut = bytes.subarray(0, end).toString("utf8");
  const lastComment = cut.lastIndexOf("<!--");
  const lastLt = cut.lastIndexOf("<");
  if (lastComment >= 0 && cut.indexOf("-->", lastComment + 4) < 0)
    cut = cut.slice(0, lastComment);
  else if (
    lastLt >= 0 &&
    // The last tag is complete only if it closes outside quotes (a
    // quoted value may itself hold a ">").
    !/^<(?:[^"'<>]|"[^"]*"|'[^']*')*>/.test(cut.slice(lastLt))
  )
    cut = cut.slice(0, lastLt);
  const amp = /&#?[a-zA-Z0-9]*$/.exec(cut);
  if (amp !== null) cut = cut.slice(0, amp.index);
  return cut + `\n<div>[Message clipped]  View entire message</div>`;
}

// GmailWeb: the full six-step pipeline. Pure: the output
// depends only on the input HTML.
export function gmailWeb(html: string): string {
  const hash = gmailHash(html);
  const step1 = stripNonHeadStyles(html);
  const step2 = filterHeadStyles(step1);
  const step3 = filterKeptStyles(step2);
  const step4 = stripLinks(stripDataImages(stripVarDecls(step3)));
  const step5 = wrapA3s(prefixClassesWithHash(step4, hash));
  return clipLongHtml(step5);
}
