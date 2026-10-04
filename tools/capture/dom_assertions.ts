// tools/capture/dom_assertions.ts — Tier-3 DOM assertions.
//
// domAssertionsScript() returns ONE self-contained JS snippet (no
// imports: it runs via page.evaluate after the capture settle) that
// returns an array of {check, pass, detail} for the six in-page
// Tier-3 checks: overflow, touch, bodyfont, contrast, unsubscribe,
// clipped. email-shots.ts evaluates it after settle and before the
// screenshot, stores the array in the capture provenance
// (meta.assertions), aggregates per-story assertions.json files, and
// --assert gates captures on it.
//
// The seventh Tier-3 item, axe-core, is not in the snippet: it needs
// the pinned axe source injected into the page, which axe.ts does after
// the screenshot (providers/browser_emulation.ts captureOne).

export interface DomAssertion {
  check: string;
  pass: boolean;
  detail: string;
}

// The six in-page checks, in snippet order (axe-core rides alongside:
// axe.ts).
export const DOM_ASSERTION_CHECKS = [
  "overflow",
  "touch",
  "bodyfont",
  "contrast",
  "unsubscribe",
  "clipped",
];

// Checks that do not apply to a story by design, with the reason: the
// result is recorded as `pass: null` (never a failure, as axe's
// "not run") carrying the reason. Only the canary is listed: it is the
// fixed minimal document of the determinism checks, with no footer.
export const NOT_APPLICABLE: Readonly<
  Record<string, Readonly<Record<string, string>>>
> = {
  canary: {
    unsubscribe:
      "not applicable: the canary is the fixed minimal document of the determinism checks, with no footer by design",
  },
};

// The story's results with its not-applicable checks recorded as such.
export function applyNotApplicable<
  T extends { check: string; pass: boolean | null; detail: string },
>(story: string, results: T[]): T[] {
  const na = NOT_APPLICABLE[story];
  if (na === undefined) return results;
  return results.map((r) =>
    na[r.check] === undefined
      ? r
      : ({ ...r, pass: null, detail: na[r.check] } as T),
  );
}

export function domAssertionsScript(): string {
  // Plain JS only (no TS syntax, no backticks, no ${}): node passes
  // this string to page.evaluate, which runs it in the page.
  return `(() => {
  const out = [];
  const push = (check, pass, detail) => out.push({ check: check, pass: pass, detail: detail });
  const label = (el) => {
    const t = el.tagName ? el.tagName.toLowerCase() : "?";
    const id = el.id ? "#" + el.id : "";
    const cls = (typeof el.className === "string" && el.className.length > 0)
      ? "." + el.className.trim().split(/\\s+/)[0]
      : "";
    return t + id + cls;
  };

  // -- overflow: no horizontal overflow (at 320px; the CLI
  // picks the viewport, the snippet only compares). --
  const se = document.scrollingElement || document.documentElement;
  const sw = se ? se.scrollWidth : 0;
  if (sw <= innerWidth + 1) {
    push("overflow", true, "scrollWidth " + sw + "px <= viewport " + innerWidth + "px (+1px tolerance)");
  } else {
    let worst = null;
    let worstRight = innerWidth + 1;
    const all = document.querySelectorAll("*");
    for (let i = 0; i < all.length; i++) {
      const r = all[i].getBoundingClientRect();
      if (r.right > worstRight) { worstRight = r.right; worst = all[i]; }
    }
    push("overflow", false, "scrollWidth " + sw + "px > viewport " + innerWidth + "px (+1px tolerance)" +
      (worst ? "; widest overhang: <" + label(worst) + "> (right edge at " + Math.round(worstRight) + "px)" : ""));
  }

  // -- touch: WCAG 2.2 SC 2.5.8 Target Size (Minimum), level AA
  // (catalogue R-A11Y-11). A visible link or button passes when its box
  // is at least 24x24 CSS px, or when a 24px-diameter circle centred on
  // its box intersects no other target and no other undersized target's
  // circle (the spacing exception). An inline link in a sentence or
  // block of text (its block holds text outside any target) is exempt
  // (the inline exception). A box is the union of the element's client
  // rects (WebKit reports a wrapped inline's bounding box 0px tall; the
  // builds captured here report its line boxes 0px tall too, at the
  // baseline, and those of an inline element are given the height of its
  // font's line, at most its line height; a box that is 0px tall because
  // its CSS makes it so stays 0px tall and undersized).
  // Hidden elements (offsetParent === null) are skipped, never failed. --
  const TARGET_MIN = 24;
  const lineHeightOf = (el) => {
    const cs = getComputedStyle(el);
    const lh = parseFloat(cs.lineHeight);
    const fs = parseFloat(cs.fontSize);
    const font = fs > 0 ? fs * 1.2 : 0;
    return lh > 0 ? Math.min(lh, font) : font;
  };
  const boxOf = (el) => {
    const list = typeof el.getClientRects === "function" ? el.getClientRects() : [];
    const inlineBox = getComputedStyle(el).display === "inline";
    let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
    for (let i = 0; i < list.length; i++) {
      const c = list[i];
      if (c.width === 0 && c.height === 0) continue;
      let top = c.top, bottom = c.bottom;
      if (c.height === 0 && inlineBox) {
        // The WebKit builds captured here report every line box of an
        // inline 0px tall, at its baseline: the box is its font's line,
        // about four fifths of it above the baseline.
        const lh = lineHeightOf(el);
        top = c.top - lh * 0.8;
        bottom = top + lh;
      }
      l = Math.min(l, c.left); t = Math.min(t, top);
      r = Math.max(r, c.right); b = Math.max(b, bottom);
    }
    if (l === Infinity) {
      const c = el.getBoundingClientRect();
      const right = c.right;
      const left = c.left !== undefined ? c.left : right - c.width;
      const top = c.top !== undefined ? c.top : 0;
      return { left: left, top: top, right: right, bottom: top + c.height };
    }
    return { left: l, top: t, right: r, bottom: b };
  };
  const isTarget = (el) => {
    const tag = el.tagName ? el.tagName.toLowerCase() : "";
    return tag === "a" || tag === "button";
  };
  const textOutsideTargets = (node) => {
    let out = "";
    const kids = node.childNodes || [];
    for (let i = 0; i < kids.length; i++) {
      const k = kids[i];
      if (k.nodeType === 3) out += k.textContent || "";
      else if (k.nodeType === 1 && !isTarget(k)) out += textOutsideTargets(k);
    }
    return out;
  };
  const isInlineInText = (el) => {
    const cs = getComputedStyle(el);
    if (!cs || cs.display !== "inline") return false;
    let block = el.parentElement;
    while (block) {
      const d = getComputedStyle(block).display;
      if (d && d !== "inline" && d !== "contents") break;
      block = block.parentElement;
    }
    return block !== null && textOutsideTargets(block).trim().length > 0;
  };
  const taps = document.querySelectorAll("a,button");
  const targets = [];
  for (let i = 0; i < taps.length; i++) {
    const el = taps[i];
    if (el.offsetParent === null) continue;
    // A target inside another (a button in a link) is that target.
    let p = el.parentElement, nested = false;
    while (p) { if (isTarget(p)) { nested = true; break; } p = p.parentElement; }
    if (nested) continue;
    const box = boxOf(el);
    const w = box.right - box.left, h = box.bottom - box.top;
    targets.push({ el: el, box: box, w: w, h: h,
      cx: (box.left + box.right) / 2, cy: (box.top + box.bottom) / 2,
      small: w < TARGET_MIN || h < TARGET_MIN, inline: isInlineInText(el) });
  }
  const distToBox = (x, y, b) => {
    const dx = Math.max(b.left - x, 0, x - b.right);
    const dy = Math.max(b.top - y, 0, y - b.bottom);
    return Math.sqrt(dx * dx + dy * dy);
  };
  let touchFail = null, exempt = 0, spaced = 0, smallest = null;
  for (let i = 0; i < targets.length; i++)
    if (!targets[i].inline && (smallest === null ||
        Math.min(targets[i].w, targets[i].h) < Math.min(smallest.w, smallest.h)))
      smallest = targets[i];
  for (let i = 0; i < targets.length && touchFail === null; i++) {
    const a = targets[i];
    if (a.inline) { exempt++; continue; }
    if (!a.small) continue;
    for (let j = 0; j < targets.length; j++) {
      if (j === i) continue;
      const b = targets[j];
      const nearBox = distToBox(a.cx, a.cy, b.box) < TARGET_MIN / 2;
      const nearCircle = b.small &&
        Math.hypot(a.cx - b.cx, a.cy - b.cy) < TARGET_MIN;
      if (nearBox || nearCircle) { touchFail = { a: a, b: b }; break; }
    }
    if (touchFail === null) spaced++;
  }
  if (targets.length === 0) {
    push("touch", true, "no visible links/buttons (vacuous pass)");
  } else if (touchFail === null) {
    push("touch", true, targets.length + " visible target(s): " + exempt + " inline in text (exempt), " + spaced + " under 24px but spaced, the rest at least 24x24px" + (smallest === null ? "" : "; smallest measured <" + label(smallest.el) + "> " + Math.round(smallest.w) + "x" + Math.round(smallest.h) + "px") + " (WCAG 2.5.8)");
  } else {
    const a = touchFail.a, b = touchFail.b;
    push("touch", false, "target <" + label(a.el) + "> is " + Math.round(a.w) + "x" + Math.round(a.h) + "px, under 24px, and its 24px circle meets <" + label(b.el) + "> (" + Math.round(b.w) + "x" + Math.round(b.h) + "px) (WCAG 2.5.8)");
  }

  // -- bodyfont: body text is at least 14px. --
  const bodyStyle = getComputedStyle(document.body);
  const fs = parseFloat(bodyStyle.fontSize);
  push("bodyfont", fs >= 14, "body font-size " + bodyStyle.fontSize + (fs >= 14 ? " (>= 14px)" : " (< 14px)"));

  // -- contrast: every visible element that holds text of its own
  // reaches 4.5:1 (3:1 when its text is large: >= 24px, or >= 18.66px
  // and bold, WCAG 2) against the nearest non-transparent background
  // walking up (else white). An element without text of its own (the
  // body of a message whose text all sits in coloured elements) is not
  // a text colour anyone reads, so it is not checked.
  // WCAG relative luminance — the lint formula
  // (src/isonim_email/passes/lint.nim channelLuminance /
  // relativeLuminance / contrastRatio), duplicated here because this
  // snippet runs in-page with no imports. --
  const chan = (c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  };
  const lum = (r, g, b) => 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b);
  const ratio = (l1, l2) => (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  const parse = (s) => {
    const m = /^rgba?\\(\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*,\\s*([\\d.]+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)$/.exec(s);
    if (!m) return null;
    return [parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3]), m[4] === undefined ? 1 : parseFloat(m[4])];
  };
  const bgOf = (el) => {
    let n = el;
    while (n) {
      const c = parse(getComputedStyle(n).backgroundColor);
      if (c && c[3] > 0) return [c[0], c[1], c[2]];
      n = n.parentElement;
    }
    return [255, 255, 255];
  };
  const ownText = (el) => {
    const kids = el.childNodes || [];
    for (let i = 0; i < kids.length; i++)
      if (kids[i].nodeType === 3 && (kids[i].textContent || "").trim().length > 0) return true;
    return false;
  };
  const shown = (el) => {
    if (el !== document.body && el.offsetParent === null) return false;
    const st = getComputedStyle(el);
    if (st.visibility === "hidden" || st.opacity === "0") return false;
    // A box of a pixel or less is the visually hidden pattern (a data
    // table's caption for screen readers): nothing is drawn to read.
    const r = el.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
  };
  const candidates = document.querySelectorAll("*");
  let worstEl = null;
  let worstRatio = Infinity;
  let worstNeed = 4.5;
  let checked = 0;
  for (let i = 0; i < candidates.length; i++) {
    const el = candidates[i];
    if (!ownText(el) || !shown(el)) continue;
    const st = getComputedStyle(el);
    const fg = parse(st.color);
    if (!fg) continue;
    checked++;
    const bg = bgOf(el);
    let fr = fg[0];
    let fgg = fg[1];
    let fb = fg[2];
    if (fg[3] < 1) {
      fr = fg[0] * fg[3] + bg[0] * (1 - fg[3]);
      fgg = fg[1] * fg[3] + bg[1] * (1 - fg[3]);
      fb = fg[2] * fg[3] + bg[2] * (1 - fg[3]);
    }
    const px = parseFloat(st.fontSize) || 16;
    const bold = (parseInt(st.fontWeight, 10) || 400) >= 700;
    const need = px >= 24 || (bold && px >= 18.66) ? 3 : 4.5;
    const q = ratio(lum(fr, fgg, fb), lum(bg[0], bg[1], bg[2]));
    if (worstEl === null || q / need < worstRatio / worstNeed) {
      worstRatio = q;
      worstNeed = need;
      worstEl = el;
    }
  }
  if (worstEl === null) {
    push("contrast", true, "no visible text elements with parseable colors (vacuous pass)");
  } else {
    const shownRatio = Math.round(worstRatio * 100) / 100;
    push("contrast", worstRatio >= worstNeed, "lowest " + shownRatio + ":1 on <" + label(worstEl) + "> (" + checked + " element(s) with text checked, need >= " + worstNeed + ":1)");
  }

  // -- unsubscribe: some visible link carries 'unsub' in href or
  // text (case-insensitive). --
  const links = document.querySelectorAll("a");
  let found = null;
  let visLinks = 0;
  for (let i = 0; i < links.length; i++) {
    const el = links[i];
    if (el.offsetParent === null) continue;
    visLinks++;
    const hay = ((el.getAttribute("href") || "") + " " + (el.textContent || "")).toLowerCase();
    if (hay.indexOf("unsub") !== -1) { found = el; break; }
  }
  if (found) {
    push("unsubscribe", true, "visible unsubscribe link <a href=\\"" + found.getAttribute("href") + "\\">");
  } else {
    push("unsubscribe", false, "no visible link with 'unsub' in href or text (" + visLinks + " visible link(s))");
  }

  // -- clipped: no Gmail "[Message clipped]" marker. --
  const bodyText = document.body ? (document.body.innerText || "") : "";
  push("clipped", bodyText.indexOf("[Message clipped]") === -1,
    bodyText.indexOf("[Message clipped]") === -1
      ? "no '[Message clipped]' marker in body text"
      : "body text contains '[Message clipped]' (Gmail truncation marker)");

  return out;
})()`;
}
