// tools/capture/touch_target.test.ts — the Tier-3 `touch` check as
// WCAG 2.2 SC 2.5.8 Target Size (Minimum), level AA (catalogue
// R-A11Y-11), in the pinned browsers: the snippet of dom_assertions.ts
// evaluated on real pages.
//
// - a link in a sentence is exempt (the inline exception), in Chromium
//   and in WebKit, which reports a wrapped inline link's bounding box
//   0px tall: the check reads its client rects, and gives an inline's
//   0px-tall line box its font's height (never a block's 0px box);
// - a 24x24 icon link passes on its size;
// - a 19px-tall header link passes by the spacing exception beside its
//   neighbour on a line (16px away or touching: their centres stay more
//   than 24px apart), and fails stacked under another 20px away;
// - two 16px targets 6px apart fail (their circles meet), 8px apart
//   pass; two side by side fail, and so does one beside a 44px
//   button (the circle meets the button's box).
// Run with:
//   node --test tools/capture/touch_target.test.ts

import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import type { Browser } from "playwright-core";
import { domAssertionsScript, type DomAssertion } from "./dom_assertions.ts";
import { resolveDriver } from "./providers/browser_emulation.ts";

const browsers: Record<string, Browser> = {};

before(async () => {
  const driver = resolveDriver(process.env);
  assert.ok(!("reason" in driver), "the pinned playwright-core is found");
  const pw = (await import(
    pathToFileURL(join(driver.dir, "index.mjs")).href
  )) as typeof import("playwright-core");
  browsers.chromium = await pw.chromium.launch();
  browsers.webkit = await pw.webkit.launch();
});

after(async () => {
  for (const b of Object.values(browsers)) await b.close();
});

async function touchOf(engine: string, body: string): Promise<DomAssertion> {
  const browser = browsers[engine];
  assert.ok(browser !== undefined, engine);
  const page = await browser.newPage({ viewport: { width: 375, height: 600 } });
  try {
    await page.setContent(
      `<!doctype html><html><body style="margin:0;font-family:Arial, sans-serif;font-size:16px;line-height:20px">${body}</body></html>`,
    );
    const all = (await page.evaluate(domAssertionsScript())) as DomAssertion[];
    const touch = all.find((a) => a.check === "touch");
    assert.ok(touch !== undefined, "a touch result");
    return touch;
  } finally {
    await page.close();
  }
}

const sentence =
  '<p style="width:200px;margin:0">Read the <a href="https://x.test/a">terms of the service we provide</a> before you sign up, and keep a copy.</p>';

// Two text links in a row, as a header's cluster places them: each in
// an inline-block item of its own, `gap` apart.
function row(gap: number): string {
  return `<div style="padding:40px 0"><div style="display:inline-block;padding-right:${gap}px"><a href="https://x.test/o">Orders</a></div><div style="display:inline-block"><a href="https://x.test/h">Help</a></div></div>`;
}

describe("Tier-3 touch: WCAG 2.5.8 target size", () => {
  for (const engine of ["chromium", "webkit"])
    it(`exempts a link inside a sentence (${engine})`, async () => {
      const t = await touchOf(engine, sentence);
      assert.equal(t.pass, true, t.detail);
      assert.match(t.detail, /1 inline in text \(exempt\)/);
    });

  for (const engine of ["chromium", "webkit"])
    it(`exempts links stacked line on line inside a block of text (${engine})`, async () => {
      // Measured, their 24px circles would meet (centres 20px apart).
      const t = await touchOf(
        engine,
        '<p style="margin:0;padding:40px 0"><a href="https://x.test/1">one</a><br><a href="https://x.test/2">two</a> are the links in this sentence.</p>',
      );
      assert.equal(t.pass, true, t.detail);
      assert.match(t.detail, /2 inline in text \(exempt\)/);
    });

  it("measures an inline link by its client rects in WebKit", async () => {
    // A link alone in its block is not exempt; WebKit's bounding box
    // of it is 0px tall, its line box 19-20px.
    const t = await touchOf(
      "webkit",
      '<p style="margin:0;padding:40px 0"><a href="https://x.test/v">View in browser</a></p>',
    );
    assert.equal(t.pass, true, t.detail);
    assert.match(t.detail, /smallest measured <a> \d+x(19|20|21)px/);
  });

  for (const engine of ["chromium", "webkit"])
    it(`does not give a 0px-tall block link a line's height (${engine})`, async () => {
      // Its CSS makes it 0px tall: it is undersized, and two of them on
      // top of each other fail, whatever the line height around them.
      const t = await touchOf(
        engine,
        '<div style="padding:40px 0;line-height:40px"><a href="https://x.test/1" style="display:block;height:0;overflow:hidden;width:200px">one</a><a href="https://x.test/2" style="display:block;height:0;overflow:hidden;width:200px">two</a></div>',
      );
      assert.equal(t.pass, false, t.detail);
      assert.match(t.detail, /200x0px, under 24px/);
    });

  it("measures an inline link in WebKit by its font, not a taller line", async () => {
    // 10px text on 40px lines: the link is its text's height, as
    // Chromium measures it, not the 40px line it sits on.
    const t = await touchOf(
      "webkit",
      '<p style="margin:0;padding:40px 0;line-height:40px"><a href="https://x.test/v" style="font-size:10px">View in browser</a></p>',
    );
    assert.equal(t.pass, true, t.detail);
    assert.match(t.detail, /1 under 24px but spaced/);
    assert.match(t.detail, /smallest measured <a> \d+x12px/);
  });

  it("passes a 24x24 icon link on its size", async () => {
    const t = await touchOf(
      "chromium",
      '<a href="https://x.test/g" style="display:inline-block;width:24px;height:24px;background:#333"></a><a href="https://x.test/l" style="display:inline-block;width:24px;height:24px;background:#333;margin-left:12px"></a>',
    );
    assert.equal(t.pass, true, t.detail);
    assert.match(t.detail, /0 under 24px but spaced/);
  });

  it("passes a 19px-tall header link spaced 16px from the next", async () => {
    const t = await touchOf("chromium", row(16));
    assert.equal(t.pass, true, t.detail);
    assert.match(t.detail, /2 under 24px but spaced/);
  });

  it("passes them side by side with no gap too: their centres are 24px apart and more", async () => {
    // "Orders" is about 48px wide: a 24px circle on its centre stops
    // 12px short of "Help" however close the two sit on a line.
    const t = await touchOf("chromium", row(0));
    assert.equal(t.pass, true, t.detail);
  });

  it("fails 19px-tall links stacked one under the other", async () => {
    // Line after line, 20px apart: the circles on their centres meet.
    const t = await touchOf(
      "chromium",
      '<div style="padding:40px 0"><div><a href="https://x.test/o">Orders</a></div><div><a href="https://x.test/h">Help</a></div></div>',
    );
    assert.equal(t.pass, false, t.detail);
    assert.match(t.detail, /under 24px, and its 24px circle meets/);
  });

  it("fails a 16px target 2px beside a 44px button", async () => {
    // Only the circle-to-box test sees it: the button is not undersized.
    const t = await touchOf(
      "chromium",
      '<div style="padding:40px"><a href="https://x.test/1" style="display:inline-block;width:16px;height:16px;background:#333;vertical-align:top"></a><a href="https://x.test/2" style="display:inline-block;width:120px;height:44px;background:#333;margin-left:2px;vertical-align:top"></a></div>',
    );
    assert.equal(t.pass, false, t.detail);
    assert.match(
      t.detail,
      /16x16px, under 24px, and its 24px circle meets <a> \(120x44px\)/,
    );
  });

  it("fails two cramped 16px targets", async () => {
    const t = await touchOf(
      "chromium",
      '<div style="padding:40px"><a href="https://x.test/1" style="display:inline-block;width:16px;height:16px;background:#333"></a><a href="https://x.test/2" style="display:inline-block;width:16px;height:16px;background:#333;margin-left:2px"></a></div>',
    );
    assert.equal(t.pass, false, t.detail);
    assert.match(t.detail, /16x16px/);
  });

  it("fails two 16px targets 6px apart: only their circles meet", async () => {
    // Each circle stops 2px short of the other's box (centre 14px from
    // it), but the centres are 22px apart: the circles intersect.
    const cell = (n: number, ml: number) =>
      `<a href="https://x.test/${n}" style="display:inline-block;width:16px;height:16px;background:#333;vertical-align:top;margin-left:${ml}px"></a>`;
    const t = await touchOf(
      "chromium",
      `<div style="padding:40px;font-size:0">${cell(1, 0)}${cell(2, 6)}</div>`,
    );
    assert.equal(t.pass, false, t.detail);
    assert.match(
      t.detail,
      /16x16px, under 24px, and its 24px circle meets <a> \(16x16px\)/,
    );
    // 8px apart, the centres are 24px apart: the circles touch, no more.
    const spaced = await touchOf(
      "chromium",
      `<div style="padding:40px;font-size:0">${cell(1, 0)}${cell(2, 8)}</div>`,
    );
    assert.equal(spaced.pass, true, spaced.detail);
  });
});
