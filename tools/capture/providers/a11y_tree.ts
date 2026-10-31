// tools/capture/providers/a11y_tree.ts — what the hosted-webmail
// captures read from the webmail browser's accessibility tree
// (`guiassert tree --pid <browser>`, contract guiassert-desktop/1.1),
// as pure functions over the tree a call returned:
// - accessibility locators (a normalized or platform role, an exact,
//   contained or patterned accessible name) and the nodes they match;
// - the address bar's value (Chrome's "Address and search bar");
// - the story region: where an opened message's body is when the
//   webmail gives it no name of its own, from the story's own text;
// - the UI fingerprint of a reading pane: its roles and depths, the
//   body and the list's rows left out, every name and text ignored;
// - masks painted over a captured region.
// Nothing here talks to GuiAssert or the browser (webmail_desktop.ts
// does), so every rule is tested on synthetic trees.

import { createHash } from "node:crypto";
import { readPng, writePng } from "../contact_sheet.ts";
import type { GaNode, Rect } from "./guiassert.ts";

/** How an adapter names an element: every given field must match. */
export interface A11yLocator {
  /** GuiAssert's normalized role (`row`, `button`, `link`, `list-item`, …). */
  role?: string;
  /** The platform's role (AT-SPI: `heading`, `landmark`, `table row`, …). */
  nativeRole?: string;
  /** The accessible name, exactly. */
  name?: string;
  /** A substring of the accessible name (case-sensitive). */
  nameContains?: string;
  /** A regular expression over the accessible name (case-insensitive). */
  namePattern?: string;
}

/** A node of the tree with where it sits. */
export interface Flat {
  node: GaNode;
  parent: Flat | null;
  depth: number;
  /** Pre-order position: an ancestor always precedes its descendants. */
  order: number;
}

export function flatten(root: GaNode): Flat[] {
  const out: Flat[] = [];
  const walk = (node: GaNode, parent: Flat | null, depth: number): void => {
    const f: Flat = { node, parent, depth, order: out.length };
    out.push(f);
    for (const c of node.children ?? []) walk(c, f, depth + 1);
  };
  walk(root, null, 0);
  return out;
}

export function matches(node: GaNode, loc: A11yLocator): boolean {
  const name = node.name ?? "";
  if (loc.role !== undefined && node.role !== loc.role) return false;
  if (loc.nativeRole !== undefined && node.nativeRole !== loc.nativeRole)
    return false;
  if (loc.name !== undefined && name !== loc.name) return false;
  if (loc.nameContains !== undefined && !name.includes(loc.nameContains))
    return false;
  if (
    loc.namePattern !== undefined &&
    !new RegExp(loc.namePattern, "iu").test(name)
  )
    return false;
  return true;
}

/** Shown on the display: bounds of some size, visible, not off screen. */
export function showing(node: GaNode): node is GaNode & { bounds: Rect } {
  return (
    node.bounds !== null &&
    node.bounds[2] > 0 &&
    node.bounds[3] > 0 &&
    node.states.includes("visible") &&
    !node.states.includes("offscreen")
  );
}

/** Every showing node `loc` matches (within `scope` when given). */
export function findShowing(
  flat: Flat[],
  loc: A11yLocator,
  scope: Flat | null = null,
): Flat[] {
  return flat.filter(
    (f) =>
      matches(f.node, loc) &&
      showing(f.node) &&
      (scope === null || isWithin(f, scope)),
  );
}

export function isWithin(f: Flat, ancestor: Flat): boolean {
  for (let a: Flat | null = f; a !== null; a = a.parent)
    if (a === ancestor) return true;
  return false;
}

/** The nearest ancestor (or `f` itself) that `loc` matches. */
export function closest(f: Flat, loc: A11yLocator): Flat | null {
  for (let a: Flat | null = f; a !== null; a = a.parent)
    if (matches(a.node, loc)) return a;
  return null;
}

/**
 * Where to click a node: the centre of its deepest showing descendant
 * whose name carries `text` (a row's subject), else the node's own
 * bounds. An inline element that wraps (a link over two lines) has a
 * bounding box whose centre may lie between its fragments, on nothing.
 */
export function clickTarget(
  node: GaNode & { bounds: Rect },
  text: string,
): Rect {
  let best: { b: Rect; depth: number } | null = null;
  const walk = (n: GaNode, depth: number): void => {
    for (const c of n.children ?? []) {
      if (showing(c) && (c.name ?? "").includes(text))
        if (best === null || depth + 1 > best.depth)
          best = { b: c.bounds, depth: depth + 1 };
      walk(c, depth + 1);
    }
  };
  walk(node, 0);
  return best === null ? node.bounds : (best as { b: Rect }).b;
}

/** Every node of `f`'s subtree, `f` included. */
export function subtree(flat: Flat[], f: Flat): Flat[] {
  return flat.filter((x) => isWithin(x, f));
}

/** The accessible name of Chrome's address bar (its interface in English). */
export const ADDRESS_BAR = "Address and search bar";

/** The address bar's value; null when there is none or it is empty. */
export function addressBarValue(flat: Flat[]): string | null {
  for (const f of flat) {
    const n = f.node;
    if (n.role !== "text-field" || n.name !== ADDRESS_BAR) continue;
    const v = (n.value ?? n.text ?? "").trim();
    if (v !== "") return v;
  }
  return null;
}

/**
 * The host (with its port) of an address-bar value, which Chrome may
 * show without its scheme ("127.0.0.1:4711/mail/0/inbox",
 * "mail.google.com/mail/u/0/#inbox"); null when it is not an address.
 */
export function locationHost(value: string): string | null {
  const v = value.trim();
  if (v === "" || /\s/.test(v)) return null;
  try {
    return new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(v) ? v : `http://${v}`).host;
  } catch {
    return null;
  }
}

/**
 * Whether the address bar holds `url`: the same host and the same path,
 * query and fragment, whatever scheme Chrome leaves out of its display.
 */
export function sameLocation(value: string | null, url: string): boolean {
  if (value === null) return false;
  const strip = (u: string): string =>
    u
      .trim()
      .replace(/^[a-z][a-z0-9+.-]*:\/\//i, "")
      .replace(/\/(?=[#?]|$)/, "");
  return strip(value) === strip(url);
}

// ---------------------------------------------------------------------------
// The story's own text, and where it is in the tree
// ---------------------------------------------------------------------------

/** Lower case, letters and digits only, one space between words. */
export function normText(text: string): string {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/￼/g, " ")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

const ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  zwnj: "",
  zwj: "",
  shy: "",
  euro: "€",
  pound: "£",
  copy: "©",
  reg: "®",
  trade: "™",
  hellip: "…",
  ndash: "–",
  mdash: "—",
  lsquo: "‘",
  rsquo: "’",
  ldquo: "“",
  rdquo: "”",
  bull: "•",
  middot: "·",
};

function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === "#")
      return String.fromCodePoint(
        e[1] === "x" || e[1] === "X"
          ? Number.parseInt(e.slice(2), 16)
          : Number.parseInt(e.slice(1), 10),
      );
    return ENTITIES[e.toLowerCase()] ?? m;
  });
}

/**
 * The story's visible text as a webmail shows it, one entry per block:
 * the HTML without its head, styles, scripts and hidden elements (the
 * preheader: `display:none`), each image's alt text, then the text of
 * every block, entities decoded; entries without a letter or digit are
 * left out.
 */
export function storyTexts(html: string): string[] {
  let s = html
    .replace(/<head[\s\S]*?<\/head>/gi, " ")
    .replace(/<(style|script|title)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ");
  // A hidden element holding no element of its own kind (the preheader).
  for (let i = 0; i < 8; i++) {
    const next = s.replace(
      /<(div|span|p|td|table)\b[^>]*display\s*:\s*none[^>]*>(?:(?!<\1\b)[\s\S])*?<\/\1>/gi,
      " ",
    );
    if (next === s) break;
    s = next;
  }
  s = s
    .replace(/<img\b[^>]*\balt\s*=\s*(["'])(.*?)\1[^>]*>/gi, "\n$2\n")
    .replace(
      /<\/?(p|div|tr|td|th|table|tbody|thead|h[1-6]|li|ul|ol|br|hr|center|blockquote)\b[^>]*>/gi,
      "\n",
    )
    .replace(/<[^>]+>/g, "");
  const out: string[] = [];
  for (const line of decodeEntities(s).split("\n")) {
    const t = line.replace(/\s+/g, " ").trim();
    if (normText(t) !== "" && !out.includes(t)) out.push(t);
  }
  return out;
}

/** A node's own text: its name and its text content, normalized. */
export function nodeText(n: GaNode): string {
  return normText(`${n.name ?? ""} ${n.text ?? ""}`);
}

/**
 * Whether the node's text is all story text. Its name and text are
 * each tested whole, then word for word: a webmail may give a block of
 * the body a name that joins the text of several of its blocks (a link
 * or a cell named from its content).
 */
function isStoryText(n: GaNode, story: string): boolean {
  const parts = [normText(n.name ?? ""), normText(n.text ?? "")].filter(
    (p) => p !== "",
  );
  return parts.every((p) => ` ${story} `.includes(` ${p} `));
}

export interface StoryRegion {
  /** The body's region, desktop coordinates. */
  rect: Rect;
  /** How many leaves carried the story's text. */
  carriers: number;
  /** Leaves of other text or controls inside the region (none expected). */
  foreignInside: number;
  /** What bounds the region above and below. */
  top: "subject" | "webmail";
  bottom: "story" | "webmail";
}

/**
 * Where the opened message's body is when the webmail gives it no name,
 * from the story's own text. Chrome prunes the generic containers a
 * body sits in (a webmail's `div`s and the story's presentational
 * tables) from its accessibility tree, so the body is a region, not a
 * node (measured 2026-10-31, Google Chrome 147 in a GuiAssert session):
 * - its leaves: every showing node of `scope` below the subject's top
 *   with no children, and every `chrome` node as one (its descendants
 *   left out); a leaf is the story's when its text is story text,
 *   another's when it has other text or is chrome, neutral without
 *   text (an image without alt text);
 * - its column: the subject's block (a heading spans the message
 *   column) and every story leaf below the subject;
 * - above: the lowest other leaf in the column ending before the first
 *   story leaf, else the subject's bottom; below: the highest other
 *   leaf in the column starting after the last story leaf, else the
 *   last story leaf's bottom.
 * Other leaves inside it are counted (`foreignInside`). Null when no
 * leaf below the subject carries the story's text.
 */
export function locateStoryRegion(
  flat: Flat[],
  texts: string[],
  o: { scope: Flat; chrome: A11yLocator[]; subject: Flat },
): StoryRegion | null {
  const story = texts.map(normText).join(" ");
  const hb = o.subject.node.bounds;
  if (hb === null) return null;
  const subjectBottom = hb[1] + hb[3];
  type Leaf = { b: Rect; kind: "story" | "other" };
  const leaves: Leaf[] = [];
  const isChrome = (f: Flat): boolean =>
    o.chrome.some((loc) => matches(f.node, loc));
  const inChrome = (f: Flat): boolean => {
    for (let a = f.parent; a !== null; a = a.parent)
      if (isChrome(a)) return true;
    return false;
  };
  for (const f of subtree(flat, o.scope)) {
    if (!showing(f.node) || isWithin(f, o.subject) || inChrome(f)) continue;
    const b = f.node.bounds;
    if (b[1] < hb[1]) continue;
    if (isChrome(f)) {
      leaves.push({ b, kind: "other" });
      continue;
    }
    if ((f.node.children ?? []).some((c) => showing(c))) continue;
    const t = nodeText(f.node);
    if (t.length < 3) continue;
    leaves.push({ b, kind: isStoryText(f.node, story) ? "story" : "other" });
  }
  const carriers = leaves.filter(
    (l) => l.kind === "story" && l.b[1] >= subjectBottom,
  );
  if (carriers.length === 0) return null;
  const x0 = Math.min(hb[0], ...carriers.map((l) => l.b[0]));
  const x1 = Math.max(hb[0] + hb[2], ...carriers.map((l) => l.b[0] + l.b[2]));
  const first = Math.min(...carriers.map((l) => l.b[1]));
  const last = Math.max(...carriers.map((l) => l.b[1] + l.b[3]));
  const others = leaves.filter(
    (l) => l.kind === "other" && l.b[0] < x1 && l.b[0] + l.b[2] > x0,
  );
  const above = others
    .map((l) => l.b[1] + l.b[3])
    .filter((bottom) => bottom <= first);
  const below = others.map((l) => l.b[1]).filter((top) => top >= last);
  const top = Math.max(subjectBottom, ...above);
  const bottom = below.length > 0 ? Math.min(...below) : last;
  const foreignInside = others.filter(
    (l) => l.b[1] >= top && l.b[1] < bottom && l.b[1] + l.b[3] > top,
  ).length;
  return {
    rect: [x0, top, x1 - x0, bottom - top],
    carriers: carriers.length,
    foreignInside,
    top:
      above.length > 0 && Math.max(...above) > subjectBottom
        ? "webmail"
        : "subject",
    bottom: below.length > 0 ? "webmail" : "story",
  };
}

// ---------------------------------------------------------------------------
// The UI fingerprint
// ---------------------------------------------------------------------------

/** Whether `b` lies wholly inside `r`. */
export const insideRect = (b: Rect | null, r: Rect): boolean =>
  b !== null &&
  b[0] >= r[0] &&
  b[1] >= r[1] &&
  b[0] + b[2] <= r[0] + r[2] &&
  b[1] + b[3] <= r[1] + r[3];

/**
 * A hash of the reading pane's structure: every node's depth, normalized
 * and platform role, in order, leaving out the nodes `skip` names (the
 * body, the message list's rows: they change with the story and the
 * mailbox) with their subtrees; names, text, values, states and bounds
 * are left out, so neither the story nor the account changes it.
 */
export function structureFingerprint(
  flat: Flat[],
  root: Flat,
  skip: (f: Flat) => boolean,
): string {
  const lines: string[] = [];
  const skipped: Flat[] = [];
  for (const f of subtree(flat, root)) {
    if (skipped.some((s) => isWithin(f, s))) continue;
    if (f !== root && skip(f)) {
      skipped.push(f);
      continue;
    }
    lines.push(`${f.depth - root.depth}:${f.node.role}/${f.node.nativeRole}`);
  }
  return createHash("sha256")
    .update(lines.join("\n"))
    .digest("hex")
    .slice(0, 12);
}

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

/** Playwright's mask colour, kept so masked crops look as before. */
export const MASK_RGB = [0xff, 0x00, 0xff] as const;

/**
 * The PNG of a region captured at desktop `origin` with every rect (in
 * desktop coordinates) painted MASK_RGB, clipped to the image; the PNG
 * unchanged when there is nothing to paint.
 */
export function paintMasks(
  png: Uint8Array,
  origin: [number, number],
  rects: Rect[],
): Uint8Array {
  if (rects.length === 0) return png;
  const img = readPng(png);
  const rgb = new Uint8Array(img.width * img.height * 3);
  for (let i = 0, j = 0; i < img.data.length; i += 4, j += 3) {
    rgb[j] = img.data[i]!;
    rgb[j + 1] = img.data[i + 1]!;
    rgb[j + 2] = img.data[i + 2]!;
  }
  for (const [rx, ry, rw, rh] of rects) {
    const x0 = Math.max(0, Math.round(rx - origin[0]));
    const y0 = Math.max(0, Math.round(ry - origin[1]));
    const x1 = Math.min(img.width, Math.round(rx - origin[0] + rw));
    const y1 = Math.min(img.height, Math.round(ry - origin[1] + rh));
    for (let y = y0; y < y1; y++)
      for (let x = x0; x < x1; x++) {
        const k = (y * img.width + x) * 3;
        rgb[k] = MASK_RGB[0];
        rgb[k + 1] = MASK_RGB[1];
        rgb[k + 2] = MASK_RGB[2];
      }
  }
  return writePng({ width: img.width, height: img.height, data: rgb });
}

/** The mean luminance (0-255, Rec. 709) of a PNG: evidence of a scheme. */
export function meanLuminance(png: Uint8Array): number {
  const img = readPng(png);
  let sum = 0;
  const n = img.width * img.height;
  for (let i = 0; i < img.data.length; i += 4)
    sum +=
      0.2126 * img.data[i]! +
      0.7152 * img.data[i + 1]! +
      0.0722 * img.data[i + 2]!;
  return n === 0 ? 0 : sum / n;
}

/** Whether two rects are equal. */
export const sameRect = (a: Rect | null, b: Rect | null): boolean =>
  a !== null && b !== null && a.every((v, i) => v === b[i]);
