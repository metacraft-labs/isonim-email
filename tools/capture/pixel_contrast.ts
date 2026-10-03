// tools/capture/pixel_contrast.ts — text contrast measured on the
// screenshot.
//
// The in-page contrast check (dom_assertions.ts) reads computed
// colours. Under forced dark that is the wrong evidence: Blink's
// automatic dark mode recolours what it paints, not the computed
// styles, so the computed colours are still the light design's. This
// check measures what was drawn instead, for every visible run of text:
//
// 1. In the page (`textRunsScript`, after the settle, before the
//    screenshot): every non-blank text node's line boxes (a Range's
//    client rects, in document coordinates), cut down to what no
//    ancestor's `overflow` clips away; with its element's font size and
//    weight (the WCAG large-text rule) and a label.
// 2. On the screenshot (`measureTextRuns`): within each box the
//    background is the most frequent colour and the text colour the
//    pixel that contrasts with it most; the WCAG 2 ratio of the two is
//    the run's contrast. Anti-aliasing only lowers a measured ratio, so
//    a pass is never a measurement artefact. A run passes at 4.5:1, or
//    at 3:1 when it is large (≥ 24px, or ≥ 18.66px and bold).
//
// The result is one `contrast` assertion, like the computed one, so
// `--assert` and the Tier-3 checker treat it the same way.

import type { RgbaImage } from "./contact_sheet.ts";

export interface TextRun {
  x: number;
  y: number;
  w: number;
  h: number;
  px: number;
  bold: boolean;
  label: string;
}

export interface RunContrast {
  run: TextRun;
  ratio: number;
  need: number;
  fg: [number, number, number];
  bg: [number, number, number];
}

export function textRunsScript(): string {
  // Plain JS only (no TS syntax, no backticks, no ${}): node passes
  // this string to page.evaluate, which runs it in the page.
  return `(() => {
  const runs = [];
  const label = (el) => {
    const t = el.tagName ? el.tagName.toLowerCase() : "?";
    const cls = (typeof el.className === "string" && el.className.length > 0)
      ? "." + el.className.trim().split(/\\s+/)[0]
      : "";
    return t + cls;
  };
  const clipOf = (el) => {
    let box = { l: -Infinity, t: -Infinity, r: Infinity, b: Infinity };
    for (let a = el; a && a !== document.documentElement; a = a.parentElement) {
      const cs = getComputedStyle(a);
      if (cs.overflowX !== "visible" || cs.overflowY !== "visible") {
        const r = a.getBoundingClientRect();
        box = { l: Math.max(box.l, r.left), t: Math.max(box.t, r.top),
          r: Math.min(box.r, r.right), b: Math.min(box.b, r.bottom) };
      }
    }
    return box;
  };
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n !== null && runs.length < 4000; n = walker.nextNode()) {
    const text = n.textContent || "";
    if (text.trim().length === 0) continue;
    const el = n.parentElement;
    if (!el) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility !== "visible" || parseFloat(cs.opacity) === 0) continue;
    const range = document.createRange();
    range.selectNodeContents(n);
    const clip = clipOf(el);
    const rects = range.getClientRects();
    for (let i = 0; i < rects.length; i++) {
      const r = rects[i];
      const l = Math.max(r.left, clip.l);
      const t = Math.max(r.top, clip.t);
      const rr = Math.min(r.right, clip.r);
      const b = Math.min(r.bottom, clip.b);
      if (rr - l < 3 || b - t < 6) continue;
      const px = parseFloat(cs.fontSize) || 16;
      const bold = (parseInt(cs.fontWeight, 10) || 400) >= 700;
      runs.push({ x: l + scrollX, y: t + scrollY, w: rr - l, h: b - t, px: px, bold: bold,
        label: label(el) + " '" + text.trim().slice(0, 24) + "'" });
    }
  }
  return runs;
})()`;
}

function channel(c: number): number {
  const s = c / 255;
  return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
}

function luminance(r: number, g: number, b: number): number {
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

export function contrastRatio(
  a: [number, number, number],
  b: [number, number, number],
): number {
  const la = luminance(...a);
  const lb = luminance(...b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// WCAG 2: large text is ≥ 24px, or ≥ 18.66px (14pt) and bold.
export function requiredRatio(run: TextRun): number {
  return run.px >= 24 || (run.bold && run.px >= 18.66) ? 3 : 4.5;
}

export function measureTextRuns(
  img: RgbaImage,
  runs: TextRun[],
  dpr: number,
): RunContrast[] {
  const out: RunContrast[] = [];
  for (const run of runs) {
    const x0 = Math.max(0, Math.floor(run.x * dpr));
    const y0 = Math.max(0, Math.floor(run.y * dpr));
    const x1 = Math.min(img.width, Math.ceil((run.x + run.w) * dpr));
    const y1 = Math.min(img.height, Math.ceil((run.y + run.h) * dpr));
    if (x1 - x0 < 2 || y1 - y0 < 2) continue;
    const counts = new Map<number, number>();
    for (let y = y0; y < y1; y++)
      for (let x = x0; x < x1; x++) {
        const i = (y * img.width + x) * 4;
        const k =
          ((img.data[i] ?? 0) << 16) |
          ((img.data[i + 1] ?? 0) << 8) |
          (img.data[i + 2] ?? 0);
        counts.set(k, (counts.get(k) ?? 0) + 1);
      }
    let bgKey = 0;
    let best = -1;
    for (const [k, c] of counts)
      if (c > best || (c === best && k < bgKey)) {
        best = c;
        bgKey = k;
      }
    const bg: [number, number, number] = [
      (bgKey >> 16) & 255,
      (bgKey >> 8) & 255,
      bgKey & 255,
    ];
    let fg = bg;
    let ratio = 1;
    for (const k of counts.keys()) {
      const c: [number, number, number] = [
        (k >> 16) & 255,
        (k >> 8) & 255,
        k & 255,
      ];
      const q = contrastRatio(c, bg);
      if (q > ratio) {
        ratio = q;
        fg = c;
      }
    }
    out.push({ run, ratio, need: requiredRatio(run), fg, bg });
  }
  return out;
}

const hex = (c: [number, number, number]): string =>
  "#" + c.map((v) => v.toString(16).padStart(2, "0")).join("");

// The `contrast` assertion from measured runs: passes when every run
// reaches its ratio; names the worst run (lowest ratio over its need).
export function pixelContrastAssertion(
  measured: RunContrast[],
  scheme: string,
): { check: string; pass: boolean; detail: string } {
  if (measured.length === 0)
    return {
      check: "contrast",
      pass: true,
      detail: `measured on the ${scheme} pixels: no visible text runs (vacuous pass)`,
    };
  let worst = measured[0] as RunContrast;
  for (const m of measured)
    if (m.ratio / m.need < worst.ratio / worst.need) worst = m;
  const failing = measured.filter((m) => m.ratio < m.need).length;
  const shown = Math.round(worst.ratio * 100) / 100;
  return {
    check: "contrast",
    pass: failing === 0,
    detail:
      `measured on the ${scheme} pixels: lowest ${shown}:1 on <${worst.run.label}> ` +
      `(${hex(worst.fg)} on ${hex(worst.bg)}, need >= ${worst.need}:1); ` +
      `${failing} of ${measured.length} text run(s) below their ratio`,
  };
}
