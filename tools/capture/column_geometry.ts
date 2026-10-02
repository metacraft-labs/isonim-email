// tools/capture/column_geometry.ts — where a row's columns land.
//
// Loads each *.html of a directory in the dev shell's pinned Chromium,
// through backend A's emulation transforms (transforms.ts: none for
// chromium-baseline, ganga, wordApprox, …), at each viewport width, and
// reports the box of every column. A column is found by its background
// colour: the caller paints each column of a fixture a colour of its
// own and names the colours, and a column's box is the largest element
// painted that colour (a column's box, its Word-only box and its cell
// all share it). The test that drives this asserts what the strategies
// promise: which rows stack, which keep equal heights, and that nothing
// overflows.
//
//   node tools/capture/column_geometry.ts <dir> <out.json>
//     --colours #rrggbb,…  --families F,…  --viewports W,…
//
// Output: [{file, family, viewport, scrollWidth, columns: [{colour, x,
// y, width, height} | null]}], in file × family × viewport order.
// Captures never use the network: every request is aborted.

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { applyChain, transformChain } from "./transforms.ts";
import { launchOptions } from "./launch.ts";
import { resolveDriver } from "./providers/browser_emulation.ts";

type Playwright = typeof import("playwright-core");

export interface ColumnBox {
  colour: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface Measured {
  file: string;
  family: string;
  viewport: number;
  scrollWidth: number;
  columns: (ColumnBox | null)[];
}

// In-page: the largest element whose computed background is each
// colour. Plain JS (it runs through page.evaluate).
function measureScript(colours: string[]): string {
  return `(() => {
  const want = ${JSON.stringify(colours)};
  const hex = (c) => {
    const m = /^rgba?\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)$/.exec(c);
    if (!m || (m[4] !== undefined && parseFloat(m[4]) === 0)) return "";
    return "#" + [m[1], m[2], m[3]].map((v) => parseInt(v, 10).toString(16).padStart(2, "0")).join("");
  };
  const best = want.map(() => null);
  const all = document.querySelectorAll("body *");
  for (let i = 0; i < all.length; i++) {
    const c = hex(getComputedStyle(all[i]).backgroundColor);
    const k = want.indexOf(c);
    if (k < 0) continue;
    const r = all[i].getBoundingClientRect();
    if (best[k] === null || r.width * r.height > best[k].width * best[k].height)
      best[k] = { colour: c, x: r.x, y: r.y, width: r.width, height: r.height };
  }
  const se = document.scrollingElement || document.documentElement;
  return { scrollWidth: se ? se.scrollWidth : 0, columns: best };
})()`;
}

function option(args: string[], name: string): string {
  const i = args.indexOf(name);
  const v = i >= 0 ? args[i + 1] : undefined;
  if (v === undefined) throw new Error(`column_geometry: ${name} is required`);
  return v;
}

export async function measure(
  dir: string,
  colours: string[],
  families: string[],
  viewports: number[],
): Promise<Measured[]> {
  const driver = resolveDriver(process.env);
  if ("reason" in driver) throw new Error(driver.reason);
  const pw: Playwright = await import(
    pathToFileURL(join(driver.dir, "index.mjs")).href
  );
  const browser = await pw.chromium.launch(
    launchOptions("chromium", false, process.platform, process.env),
  );
  const out: Measured[] = [];
  try {
    const files = readdirSync(dir)
      .filter((f) => f.endsWith(".html"))
      .sort();
    for (const file of files) {
      const html = readFileSync(join(dir, file), "utf8");
      for (const family of families) {
        const shown = applyChain(transformChain(family, "on"), html, "light");
        for (const width of viewports) {
          const context = await browser.newContext({
            viewport: { width, height: 900 },
            deviceScaleFactor: 1,
          });
          try {
            const page = await context.newPage();
            await page.route("**/*", (route) => route.abort());
            await page.setContent(shown, { waitUntil: "load" });
            const got = (await page.evaluate(measureScript(colours))) as {
              scrollWidth: number;
              columns: (ColumnBox | null)[];
            };
            out.push({ file, family, viewport: width, ...got });
          } finally {
            await context.close();
          }
        }
      }
    }
  } finally {
    await browser.close();
  }
  return out;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const args = process.argv.slice(2);
  const [dir, outFile] = args;
  if (dir === undefined || outFile === undefined)
    throw new Error(
      "usage: column_geometry.ts <dir> <out.json> --colours … --families … --viewports …",
    );
  const result = await measure(
    dir,
    option(args, "--colours").split(","),
    option(args, "--families").split(","),
    option(args, "--viewports")
      .split(",")
      .map((v) => parseInt(v, 10)),
  );
  writeFileSync(outFile, JSON.stringify(result, null, 1) + "\n");
}
