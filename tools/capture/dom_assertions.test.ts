// tools/capture/dom_assertions.test.ts — Tier-3 snippet logic.
//
// The snippet runs in-page via page.evaluate, but its inputs are a
// small DOM surface (document.scrollingElement/body/querySelectorAll,
// getComputedStyle, innerWidth), so these tests eval it against a
// fake DOM through `new Function` — no browser needed. The real
// browsers pin the end-to-end direction in
// tests/e2e_dom_assertions.nim.
import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  DOM_ASSERTION_CHECKS,
  domAssertionsScript,
  type DomAssertion,
} from "./dom_assertions.ts";

interface FakeRect {
  width: number;
  height: number;
  right: number;
}

interface FakeStyle {
  fontSize: string;
  color: string;
  backgroundColor: string;
}

interface FakeEl {
  tagName: string;
  id: string;
  className: string;
  offsetParent: object | null;
  textContent: string;
  href: string;
  parentElement: FakeEl | null;
  style: FakeStyle;
  rect: FakeRect;
  innerText?: string;
  getBoundingClientRect(): FakeRect;
  getAttribute(name: string): string | null;
}

function mkEl(
  tag: string,
  opts: {
    rect?: FakeRect;
    hidden?: boolean;
    text?: string;
    href?: string;
    parent?: FakeEl | null;
    style?: Partial<FakeStyle>;
    id?: string;
    cls?: string;
    innerText?: string;
  } = {},
): FakeEl {
  const el: FakeEl = {
    tagName: tag.toUpperCase(),
    id: opts.id ?? "",
    className: opts.cls ?? "",
    // offsetParent === null is the snippet's hidden signal.
    offsetParent: opts.hidden === true ? null : {},
    textContent: opts.text ?? "",
    href: opts.href ?? "",
    parentElement: opts.parent ?? null,
    style: {
      fontSize: "16px",
      color: "rgb(0, 0, 0)",
      backgroundColor: "rgba(0, 0, 0, 0)",
      ...opts.style,
    },
    rect: opts.rect ?? { width: 100, height: 20, right: 100 },
    getBoundingClientRect() {
      return el.rect;
    },
    getAttribute(name: string) {
      return name === "href" ? el.href || null : null;
    },
  };
  if (opts.innerText !== undefined) el.innerText = opts.innerText;
  return el;
}

interface FakeDoc {
  scrollingElement: { scrollWidth: number };
  body: FakeEl;
  all: FakeEl[];
  taps: FakeEl[];
  texts: FakeEl[];
  links: FakeEl[];
  querySelectorAll(sel: string): FakeEl[];
}

// A page that passes all six checks at a 320px viewport: body text
// on the canvas, a black h1, one 100x44 unsubscribe button.
function passingPage(): { doc: FakeDoc; innerWidth: number } {
  const body = mkEl("body", {
    rect: { width: 320, height: 600, right: 320 },
    innerText: "Receipt #1234 Thanks for your order. Unsubscribe",
    style: {
      fontSize: "16px",
      color: "rgb(39, 37, 34)",
      backgroundColor: "rgb(210, 204, 193)",
    },
  });
  const h1 = mkEl("h1", {
    parent: body,
    text: "Receipt #1234",
    style: { color: "rgb(0, 0, 0)" },
  });
  const unsub = mkEl("a", {
    parent: body,
    text: "Unsubscribe",
    href: "https://x.test/unsub?x=1",
    rect: { width: 100, height: 44, right: 100 },
    style: { color: "rgb(0, 0, 238)" },
  });
  return {
    doc: fakeDoc(body, 320, {
      all: [body, h1, unsub],
      taps: [unsub],
      texts: [body, h1, unsub],
      links: [unsub],
    }),
    innerWidth: 320,
  };
}

function fakeDoc(
  body: FakeEl,
  scrollWidth: number,
  sets: { all: FakeEl[]; taps: FakeEl[]; texts: FakeEl[]; links: FakeEl[] },
): FakeDoc {
  return {
    scrollingElement: { scrollWidth },
    body,
    ...sets,
    querySelectorAll(sel: string): FakeEl[] {
      if (sel === "*") return sets.all;
      if (sel === "a,button") return sets.taps;
      if (sel === "body,h1,h2,h3,h4,h5,h6,a") return sets.texts;
      if (sel === "a") return sets.links;
      throw new Error(`fake DOM: unexpected selector '${sel}'`);
    },
  };
}

function run(doc: FakeDoc, innerWidth: number): DomAssertion[] {
  const gcs = (el: FakeEl): FakeStyle => el.style;
  const fn = new Function(
    "document",
    "getComputedStyle",
    "innerWidth",
    `return ${domAssertionsScript()};`,
  ) as (d: FakeDoc, g: typeof gcs, w: number) => DomAssertion[];
  return fn(doc, gcs, innerWidth);
}

function byCheck(results: DomAssertion[]): Map<string, DomAssertion> {
  return new Map(results.map((r) => [r.check, r]));
}

// The one result for `check`, failing the test when it is missing.
function resultOf(results: DomAssertion[], check: string): DomAssertion {
  const r = byCheck(results).get(check);
  assert.ok(r !== undefined, `no ${check} result`);
  return r;
}

describe("Tier-3 DOM assertions snippet", () => {
  it("returns exactly the six Tier-3 checks, in order", () => {
    const { doc, innerWidth } = passingPage();
    const results = run(doc, innerWidth);
    assert.deepEqual(
      results.map((r) => r.check),
      DOM_ASSERTION_CHECKS,
    );
    assert.deepEqual(DOM_ASSERTION_CHECKS, [
      "overflow",
      "touch",
      "bodyfont",
      "contrast",
      "unsubscribe",
      "clipped",
    ]);
    for (const r of results) {
      assert.equal(typeof r.pass, "boolean", r.check);
      assert.ok(r.detail.length > 0, r.check);
    }
  });

  it("a clean page passes all six", () => {
    const { doc, innerWidth } = passingPage();
    for (const r of run(doc, innerWidth))
      assert.equal(r.pass, true, `${r.check}: ${r.detail}`);
  });

  it("a 700px table fails overflow naming the table", () => {
    const { doc, innerWidth } = passingPage();
    doc.scrollingElement.scrollWidth = 700;
    const table = mkEl("table", {
      parent: doc.body,
      cls: "wide",
      rect: { width: 700, height: 100, right: 700 },
    });
    doc.all.push(table);
    const r = resultOf(run(doc, innerWidth), "overflow");
    assert.equal(r.pass, false);
    assert.match(r.detail, /700/);
    assert.match(r.detail, /320/);
    assert.match(r.detail, /table/);
    // Nothing else flips: the width alone fails the page.
    for (const [check, a] of byCheck(run(doc, innerWidth)))
      if (check !== "overflow")
        assert.equal(a.pass, true, `${check}: ${a.detail}`);
  });

  it("a 20px-tall link fails touch; hidden targets are skipped", () => {
    const { doc, innerWidth } = passingPage();
    const small = mkEl("a", {
      parent: doc.body,
      text: "tiny",
      href: "https://x.test/t",
      rect: { width: 100, height: 20, right: 100 },
    });
    const hidden = mkEl("button", {
      parent: doc.body,
      hidden: true,
      text: "x",
      rect: { width: 1, height: 1, right: 1 },
    });
    doc.taps.push(small, hidden);
    doc.all.push(small, hidden);
    const r = resultOf(run(doc, innerWidth), "touch");
    assert.equal(r.pass, false);
    assert.match(r.detail, /100x20/);
    assert.match(r.detail, /44px/);
  });

  it("12px body text fails bodyfont", () => {
    const { doc, innerWidth } = passingPage();
    doc.body.style.fontSize = "12px";
    const r = resultOf(run(doc, innerWidth), "bodyfont");
    assert.equal(r.pass, false);
    assert.match(r.detail, /12px/);
  });

  it("contrast pins the WCAG luminance formula (#777 on white is 4.48:1, a fail)", () => {
    const { doc, innerWidth } = passingPage();
    // #777 on white: ((0.1845…+0.05)/(0+0.05)) — 4.48:1, just under.
    doc.texts.push(
      mkEl("h2", {
        parent: null,
        style: {
          color: "rgb(119, 119, 119)",
          backgroundColor: "rgb(255, 255, 255)",
        },
      }),
    );
    const r = resultOf(run(doc, innerWidth), "contrast");
    assert.equal(r.pass, false);
    assert.match(r.detail, /4\.48:1/);
  });

  it("contrast walks up past transparent backgrounds to white (21:1)", () => {
    const body = mkEl("body", {
      innerText: "hi",
      style: {
        fontSize: "16px",
        color: "rgb(255, 255, 255)",
        backgroundColor: "rgb(0, 0, 0)",
      },
    });
    // Transparent background: the snippet must walk up to the
    // body's opaque black (21:1), not fall through to white (1:1).
    const h1 = mkEl("h1", {
      parent: body,
      text: "hi",
      style: { color: "rgb(255, 255, 255)" },
    });
    const doc = fakeDoc(body, 320, {
      all: [body, h1],
      taps: [],
      texts: [body, h1],
      links: [],
    });
    const r = resultOf(run(doc, 320), "contrast");
    assert.equal(r.pass, true);
    assert.match(r.detail, /21:1/);
  });

  it("no unsubscribe link fails; a hidden one does not count", () => {
    const { doc, innerWidth } = passingPage();
    // In place: querySelectorAll closes over these same arrays.
    doc.links.length = 0;
    doc.taps.length = 0;
    for (let i = doc.texts.length - 1; i >= 0; i--)
      if (doc.texts[i]?.tagName === "A") doc.texts.splice(i, 1);
    // A display:none unsubscribe link is not a visible one.
    doc.links.push(
      mkEl("a", {
        parent: doc.body,
        hidden: true,
        text: "Unsubscribe",
        href: "https://x.test/unsub",
      }),
    );
    const r = resultOf(run(doc, innerWidth), "unsubscribe");
    assert.equal(r.pass, false);
    assert.match(r.detail, /0 visible link/);
  });

  it("unsubscribe matches href or text, case-insensitively", () => {
    const { doc, innerWidth } = passingPage();
    const link = doc.links[0];
    assert.ok(link !== undefined, "the passing page has an unsubscribe link");
    link.href = "https://x.test/preferences";
    link.textContent = "Click here to UNSUBSCRIBE";
    const r = resultOf(run(doc, innerWidth), "unsubscribe");
    assert.equal(r.pass, true);
  });

  it("a '[Message clipped]' marker fails clipped", () => {
    const { doc, innerWidth } = passingPage();
    doc.body.innerText += " [Message clipped] View entire message";
    const r = resultOf(run(doc, innerWidth), "clipped");
    assert.equal(r.pass, false);
    assert.match(r.detail, /Message clipped/);
  });
});
