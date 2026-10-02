// tools/capture/alt_geometry.ts — what each engine shows of an image's
// alt text when images are blocked.
//
// Loads each *.html of a directory in the dev shell's pinned Chromium,
// WebKit and Firefox through backend A's imagesOff transform (every
// image's source emptied, as the capture CLI does for `--images off`),
// at each viewport width, and reports, for every image with an alt:
//
// - its box (`getBoundingClientRect`);
// - the width of its alt text and of the alt's longest word, measured
//   in the image's own computed font (a canvas `measureText`);
// - whether the engine draws the alt: the region around the image is
//   screenshotted, the image's text colour made transparent (which
//   hides the alt text and nothing else: the broken-image frame and
//   icon keep their own colours), and the region screenshotted again;
//   differing pixels mean the alt was drawn;
// - the page's horizontal scroll width;
// - whether the document's background colours survive (the computed
//   background colour of every element, collected once per page).
//
//   node tools/capture/alt_geometry.ts <dir> <out.json> --viewports W,…
//
// Output: [{file, engine, viewport, scrollWidth, backgrounds: [hex…],
// images: [{alt, x, y, width, height, textWidth, wordWidth, drawn}]}].
// Captures never use the network: every request is aborted.

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { applyChain, transformChain } from "./transforms.ts";
import { launchOptions } from "./launch.ts";
import { resolveDriver } from "./providers/browser_emulation.ts";

type Playwright = typeof import("playwright-core");

export interface AltBox {
  alt: string;
  x: number;
  y: number;
  width: number;
  height: number;
  textWidth: number;
  wordWidth: number;
  drawn: boolean;
}

export interface AltPage {
  file: string;
  engine: string;
  viewport: number;
  scrollWidth: number;
  backgrounds: string[];
  images: AltBox[];
}

const ENGINES = ["chromium", "webkit", "firefox"] as const;

// In-page: every image with an alt, its box and the alt's widths in its
// own font; the page's scroll width and background colours. Plain JS.
const MEASURE = `(() => {
  const hex = (c) => {
    const m = /^rgba?\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)$/.exec(c);
    if (!m || (m[4] !== undefined && parseFloat(m[4]) === 0)) return "";
    return "#" + [m[1], m[2], m[3]].map((v) => parseInt(v, 10).toString(16).padStart(2, "0")).join("");
  };
  const ctx = document.createElement("canvas").getContext("2d");
  const images = [];
  document.querySelectorAll("img").forEach((img, i) => {
    const alt = img.getAttribute("alt") || "";
    if (alt.length === 0) return;
    const cs = getComputedStyle(img);
    if (cs.display === "none") return;
    ctx.font = cs.fontStyle + " " + cs.fontWeight + " " + cs.fontSize + " " + cs.fontFamily;
    const words = alt.split(/\\s+/);
    let word = 0;
    for (const w of words) word = Math.max(word, ctx.measureText(w).width);
    const r = img.getBoundingClientRect();
    img.setAttribute("data-alt-index", String(i));
    images.push({ index: i, alt, x: r.x, y: r.y, width: r.width, height: r.height,
      textWidth: ctx.measureText(alt).width, wordWidth: word });
  });
  const bgs = new Set();
  document.querySelectorAll("body *").forEach((el) => {
    const c = hex(getComputedStyle(el).backgroundColor);
    if (c) bgs.add(c);
  });
  const se = document.scrollingElement || document.documentElement;
  return { scrollWidth: se ? se.scrollWidth : 0, backgrounds: [...bgs].sort(), images };
})()`;

function option(args: string[], name: string): string {
  const i = args.indexOf(name);
  const v = i >= 0 ? args[i + 1] : undefined;
  if (v === undefined) throw new Error(`alt_geometry: ${name} is required`);
  return v;
}

export async function measure(
  dir: string,
  viewports: number[],
): Promise<AltPage[]> {
  const driver = resolveDriver(process.env);
  if ("reason" in driver) throw new Error(driver.reason);
  const pw: Playwright = await import(
    pathToFileURL(join(driver.dir, "index.mjs")).href
  );
  const out: AltPage[] = [];
  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".html"))
    .sort();
  for (const engine of ENGINES) {
    const browser = await pw[engine].launch(
      launchOptions(engine, false, process.platform, process.env),
    );
    try {
      for (const file of files) {
        const html = readFileSync(join(dir, file), "utf8");
        const shown = applyChain(
          transformChain("imagesOff", "off"),
          html,
          "light",
        );
        for (const width of viewports) {
          const context = await browser.newContext({
            viewport: { width, height: 900 },
            deviceScaleFactor: 1,
          });
          try {
            const page = await context.newPage();
            await page.route("**/*", (route) => route.abort());
            await page.setContent(shown, { waitUntil: "load" });
            await page.evaluate("document.fonts.ready.then(() => true)");
            const got = (await page.evaluate(MEASURE)) as {
              scrollWidth: number;
              backgrounds: string[];
              images: (Omit<AltBox, "drawn"> & { index: number })[];
            };
            const images: AltBox[] = [];
            for (const m of got.images) {
              // The region the alt can be drawn in: the box, a line above
              // it (WebKit draws from just above the box) and to its right.
              const clip = {
                x: Math.max(0, m.x - 4),
                y: Math.max(0, m.y - 24),
                width: Math.max(1, m.width + 8),
                height: Math.max(1, m.height + 28),
              };
              const sel = `img[data-alt-index="${m.index}"]`;
              const before = await page.screenshot({ clip, fullPage: true });
              await page.evaluate(
                `document.querySelector('${sel}').style.setProperty("color", "transparent", "important")`,
              );
              const after = await page.screenshot({ clip, fullPage: true });
              await page.evaluate(
                `document.querySelector('${sel}').style.removeProperty("color")`,
              );
              const { index: _index, ...box } = m;
              images.push({ ...box, drawn: !before.equals(after) });
            }
            out.push({
              file,
              engine,
              viewport: width,
              scrollWidth: got.scrollWidth,
              backgrounds: got.backgrounds,
              images,
            });
          } finally {
            await context.close();
          }
        }
      }
    } finally {
      await browser.close();
    }
  }
  return out;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const args = process.argv.slice(2);
  const [dir, outFile] = args;
  if (dir === undefined || outFile === undefined)
    throw new Error("usage: alt_geometry.ts <dir> <out.json> --viewports …");
  const result = await measure(
    dir,
    option(args, "--viewports")
      .split(",")
      .map((v) => parseInt(v, 10)),
  );
  writeFileSync(outFile, JSON.stringify(result, null, 1) + "\n");
}
