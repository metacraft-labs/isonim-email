// tools/capture/edge_ink.ts — does anything touch the top edge?
//
// Loads each *.html of a directory in the dev shell's pinned Chromium,
// WebKit and Firefox, raw (a client with head CSS), at each viewport
// (`W` or `W@DPR`, as the capture CLI spells them), screenshots the
// page, and counts the "ink" pixels in its first two device-pixel rows:
// pixels that differ by more than 60 in a channel from the row's most
// common colour, in runs shorter than 150 device pixels (a band that
// starts the message fills a long run of the row; a glyph cut by the
// edge leaves short strokes; a run from a side of the page is the
// canvas beside a centred band). A message whose first line sits flush with the
// top of the reading pane, or reaches above it, has ink there: the tops
// of its letters are cut off.
//
//   node tools/capture/edge_ink.ts <dir> <out.json> --viewports 375@3,800
//
// Output: [{file, engine, viewport, dpr, inkTop}]. Captures never use the
// network: every request is aborted.

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { readPng } from "./contact_sheet.ts";
import { launchOptions } from "./launch.ts";
import { resolveDriver } from "./providers/browser_emulation.ts";

type Playwright = typeof import("playwright-core");

export interface EdgeInk {
  file: string;
  engine: string;
  viewport: number;
  dpr: number;
  inkTop: number;
}

const ENGINES = ["chromium", "webkit", "firefox"] as const;
const ROWS = 2;
const THRESHOLD = 60;
const MAX_RUN = 150;

// Ink pixels in the first ROWS rows of an RGBA image: pixels that
// differ from the row's most common colour, in runs shorter than
// MAX_RUN pixels. A band that starts the message (a coloured header)
// fills a long run of its row; a glyph cut by the edge leaves short
// strokes.
export function topInk(png: Buffer): number {
  const img = readPng(png);
  let ink = 0;
  for (let y = 0; y < Math.min(ROWS, img.height); y++) {
    const counts = new Map<number, number>();
    const at = (x: number): number => {
      const i = (y * img.width + x) * 4;
      return (img.data[i]! << 16) | (img.data[i + 1]! << 8) | img.data[i + 2]!;
    };
    for (let x = 0; x < img.width; x++)
      counts.set(at(x), (counts.get(at(x)) ?? 0) + 1);
    let mode = 0;
    let best = -1;
    for (const [k, n] of counts)
      if (n > best) {
        best = n;
        mode = k;
      }
    const differs = (x: number): boolean => {
      const v = at(x);
      return (
        Math.abs(((v >> 16) & 255) - ((mode >> 16) & 255)) > THRESHOLD ||
        Math.abs(((v >> 8) & 255) - ((mode >> 8) & 255)) > THRESHOLD ||
        Math.abs((v & 255) - (mode & 255)) > THRESHOLD
      );
    };
    // A run that reaches the side of the page is the canvas beside a
    // centred band, never a glyph.
    let run = 0;
    for (let x = 0; x <= img.width; x++) {
      if (x < img.width && differs(x)) {
        run++;
        continue;
      }
      const fromEdge = x - run === 0 || x === img.width;
      if (run > 0 && run < MAX_RUN && !fromEdge) ink += run;
      run = 0;
    }
  }
  return ink;
}

export async function measure(
  dir: string,
  viewports: { width: number; dpr: number }[],
): Promise<EdgeInk[]> {
  const driver = resolveDriver(process.env);
  if ("reason" in driver) throw new Error(driver.reason);
  const pw: Playwright = await import(
    pathToFileURL(join(driver.dir, "index.mjs")).href
  );
  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".html"))
    .sort();
  const out: EdgeInk[] = [];
  for (const engine of ENGINES) {
    const browser = await pw[engine].launch(
      launchOptions(engine, false, process.platform, process.env),
    );
    try {
      for (const file of files) {
        const html = readFileSync(join(dir, file), "utf8");
        for (const vp of viewports) {
          const context = await browser.newContext({
            viewport: { width: vp.width, height: 800 },
            deviceScaleFactor: vp.dpr,
          });
          try {
            const page = await context.newPage();
            await page.route("**/*", (route) => route.abort());
            await page.setContent(html, { waitUntil: "load" });
            await page.evaluate("document.fonts.ready.then(() => true)");
            const png = await page.screenshot();
            out.push({
              file,
              engine,
              viewport: vp.width,
              dpr: vp.dpr,
              inkTop: topInk(png),
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
  const i = args.indexOf("--viewports");
  if (dir === undefined || outFile === undefined || i < 0)
    throw new Error(
      "usage: edge_ink.ts <dir> <out.json> --viewports W[@DPR],…",
    );
  const viewports = args[i + 1]!.split(",").map((v) => {
    const [w, d] = v.split("@");
    return { width: parseInt(w!, 10), dpr: d ? parseFloat(d) : 1 };
  });
  writeFileSync(
    outFile,
    JSON.stringify(await measure(dir, viewports), null, 1) + "\n",
  );
}
