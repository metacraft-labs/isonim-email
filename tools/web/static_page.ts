// tools/web/static_page.ts — `just example-page`: render an IsoNim web
// page in the pinned Chromium and save what its script built as static
// HTML.
//
// The page is a shell (its HTML, naming its script by file name) and the
// script `nim js` built from it; the files it loads (images) are copied
// beside them. The shell is opened from disk, the script renders into
// it through IsoNim's web renderer, and once the `ready` selector
// matches, the document is saved without its scripts as `index.html`:
// the page as a reader receives it, no JavaScript needed. Screenshots of
// that static copy (desktop and phone widths, light and dark schemes)
// land beside it when asked for.
//
// `wordsOf` reads the text a reader gets under an element (text nodes
// that are not inside `display:none`, split into words); the tests
// compare it with an email's.

import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Browser, Page } from "playwright-core";
import { resolveDriver } from "../capture/providers/browser_emulation.ts";
import { launchOptions } from "../capture/launch.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

export interface StaticPageOptions {
  /** The page's HTML; it loads its script by the script's file name. */
  shell: string;
  /** The script `nim js` built for the page. */
  script: string;
  /** Files the page loads (images), copied beside it. */
  files: string[];
  /** Where the page, its files, `index.html` and the shots go. */
  outDir: string;
  /** A selector that matches once the script has rendered. */
  ready: string;
  /** Also take the four screenshots. */
  shots?: boolean;
}

export interface StaticPage {
  /** The saved static HTML. */
  html: string;
  /** Its path (`<outDir>/index.html`). */
  index: string;
  /** The screenshots taken, `page-<viewport>-<scheme>.png`. */
  shots: string[];
}

export const VIEWPORTS: Record<string, { width: number; height: number }> = {
  desktop: { width: 1024, height: 900 },
  mobile: { width: 390, height: 844 },
};

/** The pinned Chromium (the dev shell's), as the captures launch it. */
export async function launchChromium(): Promise<Browser> {
  const driver = resolveDriver(process.env);
  if ("reason" in driver) throw new Error(driver.reason);
  const pw = (await import(
    pathToFileURL(join(driver.dir, "index.mjs")).href
  )) as typeof import("playwright-core");
  return pw.chromium.launch(launchOptions("chromium", false, process.platform));
}

/** The words of the text a reader gets under `selector`: every text
 *  node outside `display:none`, split at white space (no-break and
 *  invisible spaces included). */
export async function wordsOf(page: Page, selector: string): Promise<string[]> {
  // Plain JS run in the page (this file has no DOM types).
  return (await page.evaluate(`(() => {
    const root = document.querySelector(${JSON.stringify(selector)});
    if (!root) throw new Error("no element matches " + ${JSON.stringify(selector)});
    const shown = (n) => {
      for (let e = n.parentElement; e; e = e.parentElement)
        if (getComputedStyle(e).display === "none") return false;
      return true;
    };
    const words = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (!shown(n)) continue;
      const t = (n.nodeValue || "").replace(/[\\u00a0\\u200b\\u200c\\u034f\\ufeff\\u2007]/g, " ");
      for (const w of t.split(/\\s+/)) if (w !== "") words.push(w);
    }
    return words;
  })()`)) as string[];
}

/** Renders the page and saves it as static HTML (see the header). */
export async function renderStaticPage(
  browser: Browser,
  o: StaticPageOptions,
): Promise<StaticPage> {
  mkdirSync(o.outDir, { recursive: true });
  const shell = join(o.outDir, basename(o.shell));
  copyFileSync(o.shell, shell);
  if (resolve(o.script) !== resolve(join(o.outDir, basename(o.script))))
    copyFileSync(o.script, join(o.outDir, basename(o.script)));
  for (const f of o.files) copyFileSync(f, join(o.outDir, basename(f)));
  const page = await browser.newPage({ viewport: VIEWPORTS.desktop });
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  try {
    await page.goto(pathToFileURL(shell).href);
    await page.waitForSelector(o.ready, { timeout: 10_000 }).catch(() => {
      throw new Error(
        `the page never rendered ${o.ready}${errors.length ? `: ${errors.join("; ")}` : ""}`,
      );
    });
    if (errors.length) throw new Error(`the page failed: ${errors.join("; ")}`);
    const html = (await page.evaluate(`(() => {
      for (const s of Array.from(document.querySelectorAll("script")))
        s.remove();
      return "<!doctype html>\\n" + document.documentElement.outerHTML + "\\n";
    })()`)) as string;
    const index = join(o.outDir, "index.html");
    writeFileSync(index, html);
    const shots: string[] = [];
    if (o.shots) {
      // The static copy, not the scripted page: what is shot is what
      // was saved.
      await page.goto(pathToFileURL(index).href);
      for (const [vp, size] of Object.entries(VIEWPORTS))
        for (const scheme of ["light", "dark"] as const) {
          await page.setViewportSize(size);
          await page.emulateMedia({ colorScheme: scheme });
          await page.evaluate(
            `Promise.all(Array.from(document.images).map((i) => i.decode()))`,
          );
          const out = join(o.outDir, `page-${vp}-${scheme}.png`);
          await page.screenshot({ path: out, fullPage: true });
          shots.push(out);
        }
    }
    return { html, index, shots };
  } finally {
    await page.close();
  }
}

/** The invoice summary's billing page (`examples/invoice_summary_page.*`),
 *  its script built by `just example-page-build`. */
export function invoicePageOptions(outDir: string): StaticPageOptions {
  return {
    shell: join(repoRoot, "examples", "invoice_summary_page.html"),
    script: join(
      repoRoot,
      "build",
      "examples",
      "invoice-summary",
      "invoice_summary_page.js",
    ),
    files: ["mark-outlined.png", "mark-dark.png"].map((f) =>
      join(repoRoot, "examples", "assets", f),
    ),
    outDir,
    ready: "#invoice > section",
  };
}

const USAGE = `usage: static_page [--out DIR] [--no-shots]

Renders the invoice summary's billing page (examples/invoice_summary_page.html
with the script \`just example-page-build\` built) in the pinned Chromium and
saves it as static HTML, DIR/index.html (default
build/examples/invoice-summary), with screenshots at desktop and phone widths
in the light and dark schemes beside it.
`;

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  let outDir = join(repoRoot, "build", "examples", "invoice-summary");
  let shots = true;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--help") {
      process.stdout.write(USAGE);
      return 0;
    }
    if (a === "--out" && args[i + 1] !== undefined) {
      outDir = resolve(args[++i]!);
      continue;
    }
    if (a === "--no-shots") {
      shots = false;
      continue;
    }
    process.stderr.write(`static_page: unknown argument ${a}\n${USAGE}`);
    return 2;
  }
  const o = { ...invoicePageOptions(outDir), shots };
  try {
    readFileSync(o.script);
  } catch {
    process.stderr.write(
      `static_page: ${o.script} is missing (run \`just example-page-build\`)\n`,
    );
    return 1;
  }
  const browser = await launchChromium();
  try {
    const page = await renderStaticPage(browser, o);
    process.stdout.write(`${page.index}\n`);
    for (const s of page.shots) process.stdout.write(`${s}\n`);
  } finally {
    await browser.close();
  }
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href)
  process.exit(await main());
