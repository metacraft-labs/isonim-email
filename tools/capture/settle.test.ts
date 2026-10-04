// tools/capture/settle.test.ts — a backend-A capture is settled only
// when its images are loaded, those CSS draws included: a band's or a
// hero's `background-image` is not in document.images, and the `load`
// event does not reliably wait for it, so a slower host could
// screenshot a hero before its image is painted (a 17% Tier-2
// difference in the hermetic VM: the hero's fallback colour where its
// landscape should be). `imagesComplete` loads each CSS image once
// more, waits for it, decodes every image and lets two frames pass. The pinned Chromium and WebKit, a slow image route.
// Run with:
//   node --test tools/capture/settle.test.ts

import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Browser } from "playwright-core";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import {
  imagesComplete,
  resolveDriver,
} from "./providers/browser_emulation.ts";
import { FIXTURE_HOST, installCapturePolicy } from "./fixture_host.ts";

// A 1x1 PNG.
const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

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

describe("a capture settles on its CSS images", () => {
  for (const engine of ["chromium", "webkit"])
    it(`waits for a slow background image (${engine})`, async () => {
      const page = await browsers[engine]!.newPage();
      try {
        let served = 0;
        let releaseAt = 0;
        await page.route("https://slow.test/**", async (route) => {
          // Held well past `load`: the page has nothing else to wait on.
          await new Promise((r) => setTimeout(r, 900));
          served = Date.now();
          await route.fulfill({
            status: 200,
            contentType: "image/png",
            body: PNG,
          });
        });
        await page.setContent(
          '<div style="width:100px;height:100px;background-image:url(https://slow.test/bg.png)">hero</div>',
          { waitUntil: "load" },
        );
        const t0 = Date.now();
        assert.equal(await imagesComplete(page, 5000), true);
        releaseAt = Date.now();
        // Settled only once the image was served.
        assert.ok(served > 0, "the image was requested and served");
        assert.ok(releaseAt >= served, "settled after the image arrived");
        assert.ok(releaseAt - t0 >= 0);
      } finally {
        await page.close();
      }
    });

  it("times out on a background image that never arrives", async () => {
    const page = await browsers.chromium!.newPage();
    try {
      await page.route("https://never.test/**", () => {
        /* never answered */
      });
      // `domcontentloaded`: `load` itself would wait for the image.
      await page.setContent(
        '<div style="background-image:url(https://never.test/bg.png)">x</div>',
        { waitUntil: "domcontentloaded" },
      );
      assert.equal(await imagesComplete(page, 600), false);
    } finally {
      await page.close();
    }
  });
});

// The countdown fixture animates (two frames, a second each). Served
// through the capture policy it is its first frame, so a screenshot
// taken well after the frame would have advanced shows the same pixels
// as one taken at once.
describe("an animated GIF does not advance during a capture", () => {
  const assetsDir = resolve(
    dirname(new URL(import.meta.url).pathname),
    "..",
    "..",
    "tests",
    "stories",
    "assets",
  );
  const bytes = readFileSync(join(assetsDir, "countdown.gif"));
  const sha = createHash("sha256").update(bytes).digest("hex");
  const html =
    `<body style="margin:0"><img src="${FIXTURE_HOST}/${sha.slice(0, 16)}/countdown.gif" ` +
    'width="560" height="140" style="display:block"></body>';
  for (const engine of ["chromium", "webkit"])
    it(`shows the first frame however long the capture takes (${engine})`, async () => {
      const context = await browsers[engine]!.newContext({
        viewport: { width: 560, height: 140 },
      });
      try {
        await installCapturePolicy(context, assetsDir, "on");
        const page = await context.newPage();
        await page.setContent(html, { waitUntil: "load" });
        assert.equal(await imagesComplete(page, 5000), true);
        const early = await page.screenshot({ animations: "disabled" });
        // Past the first frame's one-second delay.
        await new Promise((r) => setTimeout(r, 1600));
        const late = await page.screenshot({ animations: "disabled" });
        assert.ok(early.equals(late), "the frame did not advance");
      } finally {
        await context.close();
      }
    });
});
