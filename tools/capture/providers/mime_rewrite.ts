// tools/capture/providers/mime_rewrite.ts — rewriting the story asset
// origin in the copy of a message that is injected into IMAP.
//
// Stories reference their images on the reserved fixture origin
// (https://x.test/…). Backend A answers that origin inside the browser;
// a real mail client cannot, so the copy delivered to its mailbox has
// the origin replaced by the loopback assets service where it loads a
// resource. The canonical MIME (the one the cache key and the canary
// hashes are computed from) is never changed; only the injected copy is.
//
// What is rewritten: in text/html parts only, a URL that starts with
// the origin (ASCII case-insensitively) and
// - is the value of a `src`, `srcset` (each candidate), `background`
//   or `poster` attribute, on any element (so also the VML
//   `<v:fill src="…">` inside MSO conditional comments, which are
//   scanned as markup), or
// - is the argument of a CSS `url(…)`, or the string of an
//   `@import "…"`, in a `style` attribute or a `<style>` block.
// Attribute values are matched as a parser reads them, with their
// character references decoded (the library's serialiser writes `"`
// as `&quot;` and `'` as `&#x27;`, so a quoted url() in a style
// attribute is spelled `url(&quot;https://x.test/a.png&quot;)`); the
// URL is replaced over the characters it is spelled with, and the
// replacement is written escaped the way the serialiser escapes an
// attribute value. `<style>` content is raw text and is matched as is.
// Text nodes, `href` and every other attribute, and text/plain parts
// are left alone: links and visible text are part of what is captured.
//
// The rewrite is done in each part's own transfer encoding, and every
// other byte is kept, so a client still decodes the library's own
// encoding. The part is decoded (quoted-printable per RFC 2045 §6.7),
// the occurrences are found in the decoded HTML and each is replaced in
// the encoded text over the encoded characters it decoded from:
// - quoted-printable: only the lines that got longer are re-split at 76
//   characters, never inside an =XX escape;
// - base64: re-encoded at the original line length;
// - 7bit, 8bit, binary (or none): replaced as is.
// A post-check re-parses the whole result and fails unless every part
// decodes to the original with exactly those occurrences replaced, and
// unless no HTML part still loads a resource from the origin. That last
// test does not reuse the rewrite's scanner: it decodes every attribute
// value's character references and every CSS escape and comment on its
// own, and counts any CSS string or url() starting with the origin, so
// a spelling the rewrite does not handle (a CSS-escaped URL, an
// image-set() string) fails the rewrite instead of slipping through.
// Anything the rewrite cannot handle (an HTML part in another transfer
// encoding or a UTF-16/32 charset, a multipart without a boundary or
// without its closing delimiter) is an error, never a skipped part.

import { Buffer } from "node:buffer";

export interface RewriteResult {
  bytes: Uint8Array;
  // How many occurrences were replaced, over every HTML part.
  count: number;
}

// Byte-preserving string view of the message (one char per octet).
function latin1(b: Uint8Array): string {
  return Buffer.from(b.buffer, b.byteOffset, b.byteLength).toString("latin1");
}

export interface Parsed {
  headers: string; // the header block, including the blank line
  body: string;
  contentType: string; // lower-cased type/subtype
  boundary: string | null;
  encoding: string; // lower-cased transfer encoding, "" when absent
  charset: string; // lower-cased, "" when absent
}

function headerValue(headers: string, name: string): string | null {
  const unfolded = headers.replace(/\r?\n[ \t]+/g, " ");
  const re = new RegExp(`^${name}:[ \\t]*(.*)$`, "im");
  const m = re.exec(unfolded);
  return m === null ? null : (m[1] ?? "").trim();
}

// Splits an entity into its header block and body. The header block
// ends at the first empty line; an entity that starts with an empty
// line (a MIME part whose boundary line is followed directly by a
// blank line) has no headers, and its body starts right after it.
export function parseEntity(entity: string): Parsed {
  let split: number;
  const lead = /^\r?\n/.exec(entity);
  if (lead !== null) split = lead[0].length;
  else {
    const m = /\r?\n\r?\n/.exec(entity);
    split = m === null ? entity.length : m.index + m[0].length;
  }
  const headers = entity.slice(0, split);
  const body = entity.slice(split);
  const ct = headerValue(headers, "content-type") ?? "text/plain";
  const contentType = (ct.split(";")[0] ?? "").trim().toLowerCase();
  const bm = /boundary\s*=\s*(?:"([^"]+)"|([^;\s]+))/i.exec(ct);
  const boundary = bm === null ? null : (bm[1] ?? bm[2] ?? null);
  const cm = /charset\s*=\s*(?:"([^"]+)"|([^;\s]+))/i.exec(ct);
  const charset = (cm === null ? "" : (cm[1] ?? cm[2] ?? "")).toLowerCase();
  const encoding = (
    headerValue(headers, "content-transfer-encoding") ?? ""
  ).toLowerCase();
  return { headers, body, contentType, boundary, encoding, charset };
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// A multipart body cut into its raw stretches (preamble, delimiter
// lines, epilogue: kept byte for byte) and its parts.
type Segment = { part: false; text: string } | { part: true; text: string };

function splitMultipart(body: string, boundary: string): Segment[] {
  const delim = new RegExp(
    `(^|\\r?\\n)--${escapeRe(boundary)}(--)?[ \\t]*(?=\\r?\\n|$)`,
    "g",
  );
  const marks: { start: number; end: number; close: boolean }[] = [];
  for (const m of body.matchAll(delim)) {
    marks.push({
      start: m.index,
      end: m.index + m[0].length,
      close: m[2] === "--",
    });
    if (m[2] === "--") break;
  }
  if (marks.length === 0 || !marks.at(-1)!.close)
    throw new Error(
      `asset rewrite: multipart without its closing delimiter --${boundary}--`,
    );
  const out: Segment[] = [{ part: false, text: body.slice(0, marks[0]!.end) }];
  for (let i = 0; i + 1 < marks.length; i++) {
    const from = marks[i]!.end;
    // The part runs from after the delimiter line's line break to the
    // next delimiter (whose leading line break belongs to it).
    const lb = /^\r?\n/.exec(body.slice(from));
    const partStart = from + (lb === null ? 0 : lb[0].length);
    const next = marks[i + 1]!;
    out.push({ part: false, text: body.slice(from, partStart) });
    out.push({ part: true, text: body.slice(partStart, next.start) });
    out.push({ part: false, text: body.slice(next.start, next.end) });
  }
  out.push({ part: false, text: body.slice(marks.at(-1)!.end) });
  return out;
}

// Every leaf entity of a message, in order (multiparts descended).
function leaves(entity: string): Parsed[] {
  const p = parseEntity(entity);
  if (p.contentType.startsWith("multipart/")) {
    if (p.boundary === null)
      throw new Error(`asset rewrite: ${p.contentType} without a boundary`);
    return splitMultipart(p.body, p.boundary).flatMap((s) =>
      s.part ? leaves(s.text) : [],
    );
  }
  return [p];
}

// ---------------------------------------------------------------------
// HTML character references
// ---------------------------------------------------------------------

// Named references that decode to ASCII (the origin is ASCII, so no
// other named reference can spell part of it; those are kept as they
// are). From the HTML named character reference table.
const NAMED_REFS: Record<string, string> = {
  Tab: "\t",
  NewLine: "\n",
  excl: "!",
  quot: '"',
  QUOT: '"',
  num: "#",
  dollar: "$",
  percnt: "%",
  amp: "&",
  AMP: "&",
  apos: "'",
  lpar: "(",
  rpar: ")",
  ast: "*",
  midast: "*",
  plus: "+",
  comma: ",",
  period: ".",
  sol: "/",
  colon: ":",
  semi: ";",
  lt: "<",
  LT: "<",
  equals: "=",
  gt: ">",
  GT: ">",
  quest: "?",
  commat: "@",
  lsqb: "[",
  lbrack: "[",
  bsol: "\\",
  rsqb: "]",
  rbrack: "]",
  Hat: "^",
  lowbar: "_",
  UnderBar: "_",
  grave: "`",
  DiacriticalGrave: "`",
  lcub: "{",
  lbrace: "{",
  verbar: "|",
  vert: "|",
  VerticalLine: "|",
  rcub: "}",
  rbrace: "}",
};

// The ASCII ones of the legacy references a parser also decodes
// without their ";" (in an attribute value only when the next
// character is neither "=" nor alphanumeric).
const LEGACY_REFS = new Set([
  "amp",
  "AMP",
  "lt",
  "LT",
  "gt",
  "GT",
  "quot",
  "QUOT",
]);

function codePointText(n: number): string {
  if (n === 0 || n > 0x10ffff || (n >= 0xd800 && n <= 0xdfff)) return "�";
  return String.fromCodePoint(n);
}

// One character reference at `i` (where s[i] is "&") inside an
// attribute value ending at `e`: the decoded text and the length of
// the reference, or null when there is none.
function charRefAt(
  s: string,
  i: number,
  e: number,
): { text: string; len: number } | null {
  const rest = s.slice(i, e);
  const num = /^&#(?:[xX]([0-9A-Fa-f]+)|([0-9]+))(;?)/.exec(rest);
  if (num !== null) {
    const digits = num[1] ?? num[2]!;
    const n =
      digits.replace(/^0+/, "").length > 8
        ? 0x110000
        : parseInt(digits, num[1] !== undefined ? 16 : 10);
    return { text: codePointText(n), len: num[0].length };
  }
  const named = /^&([A-Za-z][A-Za-z0-9]*)(;?)/.exec(rest);
  if (named === null) return null;
  const name = named[1]!;
  if (named[2] === ";")
    return name in NAMED_REFS
      ? { text: NAMED_REFS[name]!, len: named[0].length }
      : null;
  const next = rest[named[0].length];
  if (LEGACY_REFS.has(name) && next !== "=")
    return { text: NAMED_REFS[name]!, len: named[0].length };
  return null;
}

// A stretch of the HTML as a parser sees it, and for each of its
// characters the span of HTML characters it came from.
interface View {
  text: string;
  start: number[];
  end: number[];
}

// An attribute value html[s, e) with its character references decoded.
function attrView(html: string, s: number, e: number): View {
  const chars: string[] = [];
  const start: number[] = [];
  const end: number[] = [];
  let i = s;
  while (i < e) {
    const ref = html[i] === "&" ? charRefAt(html, i, e) : null;
    if (ref === null) {
      chars.push(html[i]!);
      start.push(i);
      end.push(i + 1);
      i++;
      continue;
    }
    // Every UTF-16 unit of the decoded text maps to the whole reference.
    for (const unit of ref.text.split("")) {
      chars.push(unit);
      start.push(i);
      end.push(i + ref.len);
    }
    i += ref.len;
  }
  return { text: chars.join(""), start, end };
}

// Raw text (a <style> element's content): no references are decoded.
function rawView(html: string, s: number, e: number): View {
  const start: number[] = [];
  const end: number[] = [];
  for (let i = s; i < e; i++) {
    start.push(i);
    end.push(i + 1);
  }
  return { text: html.slice(s, e), start, end };
}

// The serialiser's attribute escaping: what a replacement written into
// an attribute value is escaped with.
export function escapeAttrValue(s: string): string {
  return s.replace(/["&'<]/g, (c) =>
    c === '"' ? "&quot;" : c === "&" ? "&amp;" : c === "'" ? "&#x27;" : "&lt;",
  );
}

// ---------------------------------------------------------------------
// Resource-loading contexts in HTML
// ---------------------------------------------------------------------

const RESOURCE_ATTRS = new Set(["src", "background", "poster"]);

function isSpace(c: string | undefined): boolean {
  return c === " " || c === "\t" || c === "\n" || c === "\r" || c === "\f";
}

// One resource-loading occurrence of the origin: the span of HTML
// characters it is spelled with, and whether it is in an attribute
// value (where its replacement is written escaped).
export interface Occurrence {
  start: number;
  end: number;
  attr: boolean;
}

// Every occurrence of `from` in `html` that loads a resource: a URL
// starting with `from` (ASCII case-insensitively, as scheme and host
// are) as the value of src, srcset (each candidate), background or
// poster, as a CSS url() argument in a style attribute or a <style>
// block, or as the string of an @import in either. Attribute values are
// matched with their character references decoded, as a parser decodes
// them; <style> content is raw text. Text, href and other attributes do
// not count.
export function resourceOccurrences(html: string, from: string): Occurrence[] {
  const out: Occurrence[] = [];
  const want = from.toLowerCase();
  const urlAt = (v: View, pos: number, attr: boolean): void => {
    if (
      pos + from.length <= v.text.length &&
      v.text.slice(pos, pos + from.length).toLowerCase() === want
    )
      out.push({
        start: v.start[pos]!,
        end: v.end[pos + from.length - 1]!,
        attr,
      });
  };
  const css = (v: View, attr: boolean): void => {
    for (const m of v.text.matchAll(/url\(\s*["']?\s*|@import\s*["']\s*/gi))
      urlAt(v, m.index + m[0].length, attr);
  };
  const srcset = (v: View): void => {
    const t = v.text;
    let q = 0;
    while (q < t.length) {
      while (q < t.length && (isSpace(t[q]) || t[q] === ",")) q++;
      if (q >= t.length) break;
      urlAt(v, q, true);
      while (q < t.length && !isSpace(t[q])) q++;
      if (t[q - 1] === ",") continue; // the URL ended the candidate
      while (q < t.length && t[q] !== ",") q++; // its descriptors
    }
  };
  const tagName = /<([A-Za-z][A-Za-z0-9:_-]*)/y;
  const attrName = /[^\s"'>/=]+/y;
  let i = 0;
  for (;;) {
    const lt = html.indexOf("<", i);
    if (lt === -1) break;
    tagName.lastIndex = lt;
    const tm = tagName.exec(html);
    if (tm === null) {
      // Not a start tag (text, a comment, `</x>`, `<!…`): conditional
      // comments hold markup, so scanning goes on inside them.
      i = lt + 1;
      continue;
    }
    const tag = tm[1]!.toLowerCase();
    let p = lt + tm[0].length;
    while (p < html.length) {
      while (p < html.length && (isSpace(html[p]) || html[p] === "/")) p++;
      if (p >= html.length) break;
      if (html[p] === ">") {
        p++;
        break;
      }
      attrName.lastIndex = p;
      const am = attrName.exec(html);
      if (am === null) {
        p++;
        continue;
      }
      const name = am[0].toLowerCase();
      p += am[0].length;
      while (isSpace(html[p])) p++;
      if (html[p] !== "=") continue;
      p++;
      while (isSpace(html[p])) p++;
      let vs: number;
      let ve: number;
      const q = html[p];
      if (q === '"' || q === "'") {
        vs = p + 1;
        const close = html.indexOf(q, vs);
        ve = close === -1 ? html.length : close;
        p = ve + 1;
      } else {
        vs = p;
        while (p < html.length && !isSpace(html[p]) && html[p] !== ">") p++;
        ve = p;
      }
      if (RESOURCE_ATTRS.has(name)) {
        const v = attrView(html, vs, ve);
        let s = 0;
        while (s < v.text.length && isSpace(v.text[s])) s++;
        urlAt(v, s, true);
      } else if (name === "srcset") srcset(attrView(html, vs, ve));
      else if (name === "style") css(attrView(html, vs, ve), true);
    }
    if (tag === "style") {
      const close = /<\/style\s*>/gi;
      close.lastIndex = p;
      const cm = close.exec(html);
      const end = cm === null ? html.length : cm.index;
      css(rawView(html, p, end), false);
      p = end;
    }
    i = Math.max(p, lt + 1);
  }
  return out;
}

// ---------------------------------------------------------------------
// The independent leftover check
// ---------------------------------------------------------------------

// Decodes every character reference in an attribute value. Written
// apart from attrView (a whole-string replace, no position map), so the
// post-check does not inherit a blind spot of the rewrite's scanner.
export function decodeAttrValue(v: string): string {
  return v.replace(
    /&(?:#[xX]([0-9A-Fa-f]+)(;?)|#([0-9]+)(;?)|([A-Za-z][A-Za-z0-9]*)(;?))(?=([\s\S]?))/g,
    (m, hex, _hs, dec, _ds, name, semi, next) => {
      if (hex !== undefined || dec !== undefined) {
        const digits = (hex ?? dec) as string;
        const n =
          digits.replace(/^0+/, "").length > 8
            ? 0x110000
            : parseInt(digits, hex !== undefined ? 16 : 10);
        return codePointText(n);
      }
      if (semi === ";") return NAMED_REFS[name] ?? m;
      if (LEGACY_REFS.has(name) && next !== "=") return NAMED_REFS[name]!;
      return m;
    },
  );
}

// Whether CSS loads from `from`: any url() argument, and any string
// (an @import, an image-set() candidate, …), that starts with it once
// its escapes are decoded. A small tokenizer: comments are skipped
// outside strings and url() arguments only, as a CSS parser does.
function cssLoadsFrom(css: string, want: string): boolean {
  const n = css.length;
  const starts = (s: string): boolean =>
    s
      .replace(/^[\x00-\x20]+/, "")
      .toLowerCase()
      .startsWith(want);
  // An escape at css[i] === "\\": its decoded text and the index after.
  const escape = (i: number): [string, number] => {
    const hex = /^[0-9A-Fa-f]{1,6}[ \t\n\r\f]?/.exec(css.slice(i + 1, i + 8));
    if (hex !== null)
      return [
        codePointText(parseInt(hex[0].trim(), 16)),
        i + 1 + hex[0].length,
      ];
    if (i + 1 >= n) return ["", n];
    if (css[i + 1] === "\n") return ["", i + 2];
    return [css[i + 1]!, i + 2];
  };
  let i = 0;
  while (i < n) {
    const c = css[i]!;
    if (c === "/" && css[i + 1] === "*") {
      const close = css.indexOf("*/", i + 2);
      i = close === -1 ? n : close + 2;
    } else if (c === '"' || c === "'") {
      let v = "";
      i++;
      while (i < n && css[i] !== c && css[i] !== "\n") {
        if (css[i] === "\\") {
          const [t, next] = escape(i);
          v += t;
          i = next;
        } else v += css[i++];
      }
      i++;
      if (starts(v)) return true;
    } else if (c === "\\") {
      i = escape(i)[1];
    } else if (/^url\(/i.test(css.slice(i, i + 4))) {
      i += 4;
      while (i < n && /[ \t\n\r\f]/.test(css[i]!)) i++;
      if (css[i] === '"' || css[i] === "'") continue; // a string, above
      let v = "";
      while (i < n && css[i] !== ")") {
        if (css[i] === "\\") {
          const [t, next] = escape(i);
          v += t;
          i = next;
        } else v += css[i++];
      }
      if (starts(v)) return true;
    } else i++;
  }
  return false;
}

// Where, after a parser's decoding, `html` still loads a resource from
// `from` (see resourceOccurrences for the contexts); null when nowhere.
export function leftoverResource(html: string, from: string): string | null {
  const want = from.toLowerCase();
  const startsUrl = (v: string): boolean =>
    v
      .replace(/^[ \t\n\r\f]+/, "")
      .toLowerCase()
      .startsWith(want);
  const attr =
    /([^\s"'>/=]+)(?:[ \t\n\r\f]*=[ \t\n\r\f]*(?:"([^"]*)"?|'([^']*)'?|([^\s>]*)))?/y;
  const gap = /[\s/]*/y;
  for (const tm of html.matchAll(/<([A-Za-z][A-Za-z0-9:_-]*)/g)) {
    const tag = tm[1]!.toLowerCase();
    let at = tm.index + tm[0].length;
    for (;;) {
      gap.lastIndex = at;
      at += gap.exec(html)![0].length;
      if (at >= html.length) break;
      if (html[at] === ">") {
        at++;
        break;
      }
      attr.lastIndex = at;
      const am = attr.exec(html);
      if (am === null) {
        at++; // a stray quote or "=": skipped, the tag goes on
        continue;
      }
      at += am[0].length;
      const name = am[1]!.toLowerCase();
      const raw = am[2] ?? am[3] ?? am[4];
      if (raw === undefined) continue;
      const v = decodeAttrValue(raw);
      if (
        (name === "src" || name === "background" || name === "poster") &&
        startsUrl(v)
      )
        return `<${tag} ${name}>`;
      if (name === "srcset" && v.split(",").some(startsUrl))
        return `<${tag} srcset>`;
      if (name === "style" && cssLoadsFrom(v, want)) return `<${tag} style>`;
    }
    const end = at;
    if (tag === "style") {
      const close = /<\/style\s*>/gi;
      close.lastIndex = end;
      const cm = close.exec(html);
      if (
        cssLoadsFrom(
          html.slice(end, cm === null ? html.length : cm.index),
          want,
        )
      )
        return "<style>";
    }
  }
  return null;
}

// ---------------------------------------------------------------------
// Transfer encodings
// ---------------------------------------------------------------------

// Quoted-printable decoded per RFC 2045 §6.7, line by line: trailing
// whitespace (transport padding) is dropped, a final "=" is a soft line
// break, and only then are the line's =XX escapes decoded, so an escape
// is never joined across a soft break (an "=" not followed by two hex
// digits on its own line stays literal). For each decoded character,
// the span of encoded characters it came from.
interface QpDecoded {
  text: string;
  start: number[];
  end: number[];
}

function qpDecodeMapped(body: string): QpDecoded {
  const chars: string[] = [];
  const start: number[] = [];
  const end: number[] = [];
  const hex = /^[0-9A-Fa-f]{2}$/;
  let pos = 0;
  while (pos < body.length) {
    const nl = body.indexOf("\n", pos);
    const lineEnd =
      nl === -1 ? body.length : nl > pos && body[nl - 1] === "\r" ? nl - 1 : nl;
    const next = nl === -1 ? body.length : nl + 1;
    let contentEnd = lineEnd;
    while (
      contentEnd > pos &&
      (body[contentEnd - 1] === " " || body[contentEnd - 1] === "\t")
    )
      contentEnd--;
    const soft = contentEnd > pos && body[contentEnd - 1] === "=";
    if (soft) contentEnd--;
    let k = pos;
    while (k < contentEnd) {
      if (
        body[k] === "=" &&
        k + 3 <= contentEnd &&
        hex.test(body.slice(k + 1, k + 3))
      ) {
        chars.push(String.fromCharCode(parseInt(body.slice(k + 1, k + 3), 16)));
        start.push(k);
        end.push(k + 3);
        k += 3;
      } else {
        chars.push(body[k]!);
        start.push(k);
        end.push(k + 1);
        k += 1;
      }
    }
    if (!soft && nl !== -1)
      for (let j = lineEnd; j < next; j++) {
        chars.push(body[j]!);
        start.push(j);
        end.push(j + 1);
      }
    pos = next;
  }
  return { text: chars.join(""), start, end };
}

export function decodeQuotedPrintable(body: string): string {
  return qpDecodeMapped(body).text;
}

const QP_MAX = 76;

// Splits one encoded line (without its line break) into lines of at
// most 76 characters joined by soft line breaks, never inside an =XX
// escape.
export function splitQpLine(line: string, eol: string): string {
  if (line.length <= QP_MAX) return line;
  const out: string[] = [];
  let rest = line;
  while (rest.length > QP_MAX) {
    let cut = QP_MAX - 1; // room for the "=" of the soft break
    // Do not cut an =XX escape apart.
    const eq = rest.lastIndexOf("=", cut - 1);
    if (eq !== -1 && eq > cut - 3) cut = eq;
    out.push(rest.slice(0, cut) + "=");
    rest = rest.slice(cut);
  }
  out.push(rest);
  return out.join(eol);
}

interface Edit {
  start: number;
  end: number;
  text: string;
}

function replaceAt(s: string, edits: Edit[]): string {
  let out = s;
  for (const ed of [...edits].sort((a, b) => b.start - a.start))
    out = out.slice(0, ed.start) + ed.text + out.slice(ed.end);
  return out;
}

// The edits that replace each occurrence by `to`, escaped like the
// serialiser escapes attribute values when the occurrence is in one.
function editsFor(at: Occurrence[], to: string): Edit[] {
  const inAttr = escapeAttrValue(to);
  return at.map((o) => ({
    start: o.start,
    end: o.end,
    text: o.attr ? inAttr : to,
  }));
}

const HTML_ENCODINGS = new Set([
  "",
  "7bit",
  "8bit",
  "binary",
  "quoted-printable",
  "base64",
]);

function decodeBody(p: Parsed): string {
  if (p.encoding === "quoted-printable") return decodeQuotedPrintable(p.body);
  if (p.encoding === "base64")
    return Buffer.from(p.body.replace(/\s+/g, ""), "base64").toString("latin1");
  return p.body;
}

function checkHtmlPart(p: Parsed): void {
  if (!HTML_ENCODINGS.has(p.encoding))
    throw new Error(
      `asset rewrite: a text/html part in transfer encoding ${p.encoding} cannot be rewritten`,
    );
  if (/^utf-?(16|32)/.test(p.charset))
    throw new Error(
      `asset rewrite: a text/html part in charset ${p.charset} cannot be rewritten`,
    );
}

// Rewrites the resource-loading occurrences in one HTML part's body,
// in its own transfer encoding.
function rewriteHtmlBody(
  p: Parsed,
  from: string,
  to: string,
): { body: string; count: number } {
  checkHtmlPart(p);
  if (p.encoding === "quoted-printable") {
    const d = qpDecodeMapped(p.body);
    const at = resourceOccurrences(d.text, from);
    if (at.length === 0) return { body: p.body, count: 0 };
    // Decoded HTML spans mapped to the encoded characters they came from.
    const edits = editsFor(at, to).map((ed) => ({
      start: d.start[ed.start]!,
      end: d.end[ed.end - 1]!,
      text: ed.text,
    }));
    const replaced = replaceAt(p.body, edits);
    const eol = p.body.includes("\r\n") ? "\r\n" : "\n";
    const texts = [...new Set(edits.map((ed) => ed.text))];
    const fixed = replaced
      .split(eol)
      .map((l) =>
        l.length > QP_MAX && texts.some((t) => l.includes(t))
          ? splitQpLine(l, eol)
          : l,
      );
    return { body: fixed.join(eol), count: at.length };
  }
  if (p.encoding === "base64") {
    const decoded = decodeBody(p);
    const at = resourceOccurrences(decoded, from);
    if (at.length === 0) return { body: p.body, count: 0 };
    const text = replaceAt(decoded, editsFor(at, to));
    const eol = p.body.includes("\r\n") ? "\r\n" : "\n";
    const firstLine = p.body.split(/\r?\n/)[0] ?? "";
    const width = firstLine.length > 0 ? firstLine.length : 76;
    const encoded = Buffer.from(text, "latin1").toString("base64");
    const lines: string[] = [];
    for (let i = 0; i < encoded.length; i += width)
      lines.push(encoded.slice(i, i + width));
    const trailing = /\r?\n$/.test(p.body) ? eol : "";
    return { body: lines.join(eol) + trailing, count: at.length };
  }
  const at = resourceOccurrences(p.body, from);
  return { body: replaceAt(p.body, editsFor(at, to)), count: at.length };
}

function rewriteEntity(
  entity: string,
  from: string,
  to: string,
): { entity: string; count: number } {
  const p = parseEntity(entity);
  if (p.contentType.startsWith("multipart/")) {
    if (p.boundary === null)
      throw new Error(`asset rewrite: ${p.contentType} without a boundary`);
    let out = "";
    let count = 0;
    for (const s of splitMultipart(p.body, p.boundary)) {
      if (!s.part) {
        out += s.text;
        continue;
      }
      const r = rewriteEntity(s.text, from, to);
      out += r.entity;
      count += r.count;
    }
    return { entity: p.headers + out, count };
  }
  if (p.contentType !== "text/html") return { entity, count: 0 };
  const r = rewriteHtmlBody(p, from, to);
  return { entity: p.headers + r.body, count: r.count };
}

// The post-check: re-parses both whole messages and throws unless they
// have the same parts with the same headers, every non-HTML part is
// byte-identical, every HTML part decodes to the original with exactly
// its resource-loading occurrences of `from` replaced by `to`, and no
// such occurrence is left in any HTML part. Returns the number of
// occurrences replaced.
export function checkRewrite(
  original: Uint8Array,
  rewritten: Uint8Array,
  from: string,
  to: string,
): number {
  const before = leaves(latin1(original));
  const after = leaves(latin1(rewritten));
  if (before.length !== after.length)
    throw new Error(
      `asset rewrite: ${after.length} parts after the rewrite, ${before.length} before`,
    );
  let count = 0;
  for (let i = 0; i < before.length; i++) {
    const b = before[i]!;
    const a = after[i]!;
    const where = `part ${i + 1} (${b.contentType}, ${b.encoding || "7bit"})`;
    if (a.headers !== b.headers)
      throw new Error(`asset rewrite: the headers of ${where} changed`);
    if (b.contentType !== "text/html") {
      if (a.body !== b.body)
        throw new Error(
          `asset rewrite: ${where} is not an HTML part but changed`,
        );
      continue;
    }
    checkHtmlPart(b);
    const orig = decodeBody(b);
    const at = resourceOccurrences(orig, from);
    const want = replaceAt(orig, editsFor(at, to));
    const got = decodeBody(a);
    // Independent of the scanner: the whole part decoded the way a
    // parser decodes it, character references included.
    const left = leftoverResource(got, from);
    if (left !== null)
      throw new Error(
        `asset rewrite: a resource URL on ${from} is left in ${where} (${left})`,
      );
    if (got !== want)
      throw new Error(
        `asset rewrite: ${where} does not decode to the original with only its resource URLs on ${from} replaced`,
      );
    count += at.length;
  }
  return count;
}

// Test seam: lets a test change the rewritten bytes before the
// post-check runs, to prove the post-check is what fails a bad rewrite.
export interface RewriteSeam {
  beforeCheck?: (bytes: Uint8Array) => Uint8Array;
}

// Rewrites `from` to `to` where it loads a resource in the message's
// HTML parts. Headers and every other part are never touched.
export function rewriteAssetOrigin(
  mime: Uint8Array,
  from: string,
  to: string,
  seam: RewriteSeam = {},
): RewriteResult {
  if (!/^[\x21-\x3c\x3e-\x7e]+$/.test(to))
    throw new Error(
      `asset rewrite: target ${to} must be printable ASCII without "="`,
    );
  const r = rewriteEntity(latin1(mime), from, to);
  let bytes: Uint8Array = new Uint8Array(Buffer.from(r.entity, "latin1"));
  if (seam.beforeCheck !== undefined) bytes = seam.beforeCheck(bytes);
  const checked = checkRewrite(mime, bytes, from, to);
  if (checked !== r.count)
    throw new Error(
      `asset rewrite: replaced ${r.count} resource URLs, the check counts ${checked}`,
    );
  return { bytes, count: r.count };
}
