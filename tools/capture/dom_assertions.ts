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
// The seventh Tier-3 item, axe-core, is NOT in the snippet: it needs
// the axe source injected into the page, and axe-core is not pinned
// in the dev shell or in isonim's node_modules (see the captureOne
// comment in email-shots.ts, which records the honest axe entry).

export interface DomAssertion {
  check: string;
  pass: boolean;
  detail: string;
}

// The six in-page checks, in snippet order (axe-core rides alongside
// node-side — see email-shots.ts).
export const DOM_ASSERTION_CHECKS = [
  "overflow",
  "touch",
  "bodyfont",
  "contrast",
  "unsubscribe",
  "clipped",
];

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

  // -- touch: every visible link/button is at least 44px on its
  // short side. Hidden elements (offsetParent === null, which also
  // covers display:none ancestors) are skipped, never failed. --
  const taps = document.querySelectorAll("a,button");
  let vis = 0;
  let small = null;
  let smallW = 0;
  let smallH = 0;
  let smallMin = Infinity;
  for (let i = 0; i < taps.length; i++) {
    const el = taps[i];
    if (el.offsetParent === null) continue;
    vis++;
    const r = el.getBoundingClientRect();
    const m = Math.min(r.width, r.height);
    if (m < smallMin) { smallMin = m; small = el; smallW = r.width; smallH = r.height; }
  }
  if (vis === 0) {
    push("touch", true, "no visible links/buttons (vacuous pass)");
  } else if (smallMin >= 44) {
    push("touch", true, vis + " visible link(s)/button(s), smallest min-dimension " + Math.round(smallMin) + "px (>= 44px)");
  } else {
    push("touch", false, "smallest visible target <" + label(small) + "> is " + Math.round(smallW) + "x" + Math.round(smallH) + "px (min-dimension " + Math.round(smallMin) + "px < 44px)");
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
