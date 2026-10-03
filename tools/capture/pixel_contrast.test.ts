// tools/capture/pixel_contrast.test.ts — text contrast measured on the
// screenshot (pixel_contrast.ts), and the forced-dark mode it exists for.
//
// The measurement is checked twice: on images built here pixel by pixel
// (known colours, so the ratios are exact), and end to end in the pinned
// Chromium, where the text runs come from a real layout and the pixels
// from a real screenshot, light and under forced dark. No test doubles.
// Run with:
//   node --test tools/capture/pixel_contrast.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Browser } from "playwright-core";
import { readPng, type RgbaImage } from "./contact_sheet.ts";
import { launchOptions } from "./launch.ts";
import {
  contrastRatio,
  measureTextRuns,
  pixelContrastAssertion,
  requiredRatio,
  textRunsScript,
  type TextRun,
} from "./pixel_contrast.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

function playwrightCore(): string {
  for (const p of [
    process.env.PLAYWRIGHT_CORE_PATH ?? "",
    join(repoRoot, "tools", "capture", "node_modules", "playwright-core"),
    join(repoRoot, "..", "isonim", "node_modules", "playwright-core"),
  ])
    if (p !== "" && existsSync(join(p, "index.mjs"))) return p;
  throw new Error(
    "no playwright-core found — run under `nix develop` next to ../isonim",
  );
}

// A w×h image filled with `bg`, with `fg` painted over the rectangles.
function image(
  w: number,
  h: number,
  bg: [number, number, number],
  fg: [number, number, number],
  rects: [number, number, number, number][],
): RgbaImage {
  const data = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const inFg = rects.some(
        ([rx, ry, rw, rh]) => x >= rx && x < rx + rw && y >= ry && y < ry + rh,
      );
      const c = inFg ? fg : bg;
      data.set([c[0], c[1], c[2], 255], (y * w + x) * 4);
    }
  return { width: w, height: h, data };
}

const run = (over: Partial<TextRun> = {}): TextRun => ({
  x: 0,
  y: 0,
  w: 40,
  h: 20,
  px: 16,
  bold: false,
  label: "p 'x'",
  ...over,
});

describe("pixel contrast: the measurement", () => {
  it("pins WCAG 2's ratio and the large-text rule", () => {
    assert.equal(
      Math.round(contrastRatio([119, 119, 119], [255, 255, 255]) * 100) / 100,
      4.48,
    );
    assert.equal(contrastRatio([0, 0, 0], [255, 255, 255]), 21);
    assert.equal(requiredRatio(run({ px: 16 })), 4.5);
    assert.equal(requiredRatio(run({ px: 24 })), 3);
    assert.equal(requiredRatio(run({ px: 19, bold: true })), 3);
    assert.equal(requiredRatio(run({ px: 19, bold: false })), 4.5);
  });

  it("takes the most frequent colour as the background and the most contrasting as the text", () => {
    // Glyph strokes (#777) cover a minority of the box on white.
    const img = image(
      40,
      20,
      [255, 255, 255],
      [119, 119, 119],
      [
        [4, 4, 3, 12],
        [12, 4, 3, 12],
      ],
    );
    const [m] = measureTextRuns(img, [run()], 1);
    assert.ok(m !== undefined);
    assert.deepEqual(m.bg, [255, 255, 255]);
    assert.deepEqual(m.fg, [119, 119, 119]);
    const a = pixelContrastAssertion([m], "forced-dark");
    assert.equal(a.pass, false);
    assert.match(a.detail, /4\.48:1/);
    assert.match(a.detail, /#777777 on #ffffff/);
    // The same strokes at 24px pass (3:1).
    const [big] = measureTextRuns(img, [run({ px: 24 })], 1);
    assert.equal(pixelContrastAssertion([big!], "forced-dark").pass, true);
  });

  it("reads the box at the device pixel ratio", () => {
    // A 2x screenshot: the run's CSS box covers 80×40 device pixels.
    const img = image(80, 40, [0, 0, 0], [255, 255, 255], [[8, 8, 6, 24]]);
    const [m] = measureTextRuns(img, [run()], 2);
    assert.equal(m?.ratio, 21);
    // Read at 1x the same run sees only its top-left quarter, where
    // the stroke starts: still found, still 21:1.
    const [q] = measureTextRuns(img, [run()], 1);
    assert.equal(q?.ratio, 21);
  });

  it("a box with no text in it measures 1:1 and fails; no runs is a vacuous pass", () => {
    const img = image(40, 20, [30, 30, 30], [30, 30, 30], []);
    const [m] = measureTextRuns(img, [run()], 1);
    assert.equal(m?.ratio, 1);
    assert.equal(pixelContrastAssertion([m!], "forced-dark").pass, false);
    const none = pixelContrastAssertion([], "forced-dark");
    assert.equal(none.pass, true);
    assert.match(none.detail, /vacuous/);
  });
});

describe("pixel contrast: in the pinned Chromium", () => {
  let browser: Browser;
  let forced: Browser;
  before(async () => {
    const pw = (await import(
      pathToFileURL(join(playwrightCore(), "index.mjs")).href
    )) as typeof import("playwright-core");
    browser = await pw.chromium.launch(
      launchOptions("chromium", false, process.platform),
    );
    forced = await pw.chromium.launch(
      launchOptions("chromium", true, process.platform),
    );
  });
  after(async () => {
    await browser?.close();
    await forced?.close();
  });

  async function measure(
    b: Browser,
    html: string,
  ): Promise<{
    runs: TextRun[];
    result: ReturnType<typeof pixelContrastAssertion>;
    img: RgbaImage;
  }> {
    const ctx = await b.newContext({
      viewport: { width: 400, height: 300 },
      colorScheme: "light",
    });
    try {
      const page = await ctx.newPage();
      await page.setContent(html, { waitUntil: "load" });
      const runs = (await page.evaluate(textRunsScript())) as TextRun[];
      const img = readPng(await page.screenshot({ fullPage: true }));
      return {
        runs,
        result: pixelContrastAssertion(
          measureTextRuns(img, runs, 1),
          "forced-dark",
        ),
        img,
      };
    } finally {
      await ctx.close();
    }
  }

  const page = (body: string): string =>
    `<!doctype html><html><head><meta name="color-scheme" content="light dark"></head>` +
    `<body style="margin:0;background-color:#ffffff;font:16px/24px Arial,sans-serif">${body}</body></html>`;

  it("finds the visible text runs and skips clipped and hidden ones", async () => {
    const { runs } = await measure(
      browser,
      page(
        `<p style="margin:8px;color:#111111">Visible</p>` +
          `<div style="max-height:0;overflow:hidden"><p style="margin:0">Clipped</p></div>` +
          `<p style="display:none">Hidden</p>` +
          `<p style="visibility:hidden">Invisible</p>` +
          `<p style="margin:8px;color:#222222">Second line</p>`,
      ),
    );
    assert.deepEqual(
      runs.map((r) => r.label),
      ["p 'Visible'", "p 'Second line'"],
    );
  });

  it("measures dark text on white as legible and grey text as not", async () => {
    const good = await measure(
      browser,
      page(`<p style="margin:8px;color:#111111">Readable text</p>`),
    );
    assert.equal(good.result.pass, true, good.result.detail);
    const bad = await measure(
      browser,
      page(`<p style="margin:8px;color:#bbbbbb">Faint text</p>`),
    );
    assert.equal(bad.result.pass, false, bad.result.detail);
    assert.match(bad.result.detail, /on #ffffff/);
  });

  it("forced dark darkens a message that declares color-scheme: light dark", async () => {
    // The light design, darkened by Blink whatever the message declares:
    // the white page turns dark and its dark text light, and the text
    // still reads.
    const html = page(`<p style="margin:8px;color:#111111">Readable text</p>`);
    const plain = await measure(browser, html);
    const dark = await measure(forced, html);
    const at = (img: RgbaImage): number[] =>
      Array.from(img.data.subarray(0, 3));
    assert.deepEqual(at(plain.img), [255, 255, 255]);
    const [r, g, b] = at(dark.img) as [number, number, number];
    assert.ok(r < 40 && g < 40 && b < 40, `canvas ${r},${g},${b}`);
    assert.equal(dark.result.pass, true, dark.result.detail);
  });

  it("under forced dark, dark text over a light background image fails: the text is lightened, the image is not", async () => {
    // A light 2×2 PNG (#fde9d0 and #fff4e6) as the band's background image.
    const light =
      "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4+/LC/y/PGCAUAE4DCx9wMdvNAAAAAElFTkSuQmCC";
    const html = page(
      `<div style="padding:16px;background-color:#fde9d0;background-image:url('${light}');background-size:cover">` +
        `<p style="margin:0;color:#3f3a33">Text over a light image</p></div>`,
    );
    const plain = await measure(browser, html);
    assert.equal(plain.result.pass, true, plain.result.detail);
    const dark = await measure(forced, html);
    assert.equal(dark.result.pass, false, dark.result.detail);
  });
});
