// tools/web/static_page.test.ts — the invoice summary's billing page,
// rendered in the pinned Chromium by IsoNim's web renderer (the script
// `just example-page-build` builds from examples/invoice_summary_page.nim),
// saved as static HTML, and compared with the invoice email the same
// view renders into (the `invoiceSummary` story, built by the story
// driver): the words a reader gets from the page's view are the email's,
// in the same order. Real browser, real driver, real files.
// Run with:
//   node --test tools/web/static_page.test.ts

import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Browser } from "playwright-core";
import {
  invoicePageOptions,
  launchChromium,
  renderStaticPage,
  wordsOf,
} from "./static_page.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
const driver = join(repoRoot, "build", "capture", "build-stories");

let browser: Browser;
let scratch: string;

before(async () => {
  scratch = mkdtempSync(join(tmpdir(), "isonim-email-static-page-"));
  browser = await launchChromium();
});

after(async () => {
  await browser.close();
  rmSync(scratch, { recursive: true, force: true });
});

/** The invoice email's HTML, from the story driver. */
function invoiceEmailHtml(): string {
  assert.ok(existsSync(driver), `${driver} is built (just email-shots-build)`);
  const out = join(scratch, "stories");
  execFileSync(driver, [out, "invoiceSummary"], {
    env: { ...process.env, ISONIM_CAPTURE_LAYOUT: "1" },
    stdio: ["ignore", "ignore", "inherit"],
  });
  return readFileSync(join(out, "invoiceSummary.html"), "utf8");
}

describe("the billing page renders the invoice email's domain view", () => {
  it("saves the page the web renderer built as static, semantic HTML with the email's text", async () => {
    const o = invoicePageOptions(join(scratch, "page"));
    assert.ok(
      existsSync(o.script),
      `${o.script} is built (just example-page-build)`,
    );
    const saved = await renderStaticPage(browser, o);
    // Static: no script left, the view's semantic HTML in place.
    assert.doesNotMatch(saved.html, /<script/i);
    assert.match(saved.html, /<section aria-label="Invoice INV-2041">/);
    for (const re of [
      /<picture><source media="\(prefers-color-scheme: dark\)" srcset="mark-dark\.png"><img src="mark-outlined\.png" alt="Northwind Studio" width="120" height="40"/,
      /<h1>Invoice INV-2041<\/h1>/,
      /<figure class="leaf-keyvalue"[^>]*><figcaption[^>]*>Invoice details<\/figcaption><dl[^>]*><div[^>]*><dt>Invoice number<\/dt><dd[^>]*>INV-2041<\/dd><\/div>/,
      /<table class="leaf-table"[^>]*><caption[^>]*>Lines of invoice INV-2041<\/caption><thead><tr><th scope="col"/,
      /<a href="https:\/\/example\.com\/invoices\/INV-2041\/pay">View and pay invoice INV-2041<\/a>/,
    ])
      assert.match(saved.html, re);

    // The static copy, opened with no script, shows the view.
    const page = await browser.newPage();
    try {
      await page.goto(pathToFileURL(saved.index).href);
      const web = await wordsOf(page, "#invoice > section");
      assert.ok(web.length > 50, `the view has its text (${web.length} words)`);
      assert.equal(
        await page.evaluate(
          `getComputedStyle(document.querySelector("#invoice td:last-child")).textAlign`,
        ),
        "end",
      );

      // The email, as Chromium shows it (its images not loaded: only
      // the text is compared): the page's words appear in it, in order
      // and unbroken, between the email's own card and footer.
      await page.route("**/*", (route) =>
        route.request().url().startsWith("file:")
          ? route.continue()
          : route.abort(),
      );
      await page.setContent(invoiceEmailHtml());
      const email = await wordsOf(page, "body");
      const at = email.join(" ").indexOf(web.join(" "));
      assert.ok(
        at >= 0,
        `the email holds the page's text:\n  page:  ${web.join(" ")}\n  email: ${email.join(" ")}`,
      );
      assert.ok(email.length > web.length, "the email has its footer besides");
    } finally {
      await page.close();
    }
  });
});
