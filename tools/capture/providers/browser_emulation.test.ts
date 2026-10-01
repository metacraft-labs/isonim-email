// tools/capture/providers/browser_emulation.test.ts — the local browser
// provider streams: it yields each capture's result as soon as that
// capture finishes, not when its whole batch is done.
//
// No test doubles: the real provider with the dev shell's pinned
// Chromium (run under `nix develop`, which sets PLAYWRIGHT_BROWSERS_PATH).
// One request in the batch is made slow by its own content: an image far
// below the fold with loading="lazy" never starts loading, so the
// provider's image wait runs to its timeout (5 s) and fails that
// capture. The other request is a plain paragraph. Run with:
//   node --test tools/capture/providers/browser_emulation.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BrowserEmulationProvider } from "./browser_emulation.ts";
import type {
  CaptureRequest,
  CaptureResult,
  SessionCtx,
  StoryMessage,
} from "./types.ts";

function message(story: string, html: string): StoryMessage {
  return { story, mime: Buffer.from(`Subject: ${story}\r\n\r\n${html}`), html };
}

function sha(m: StoryMessage): string {
  return createHash("sha256").update(m.mime).digest("hex");
}

function request(m: StoryMessage): CaptureRequest {
  return {
    id: `a-chromium-baseline-chromium-mobile-light-on`,
    story: m.story,
    mimeSha256: sha(m),
    provider: "browser-emulation",
    backend: "a",
    family: "chromium-baseline",
    clientId: "chromium",
    viewport: { name: "mobile", width: 375, dpr: 1 },
    scheme: "light",
    images: "on",
  };
}

describe("browser-emulation streaming", () => {
  it("yields a finished capture while another capture of the same batch is still running", async () => {
    const fast = message("fast", "<p>fast</p>");
    const slow = message(
      "slow",
      '<div style="height:40000px"></div>' +
        '<img loading="lazy" width="10" height="10" alt="" ' +
        'src="https://x.test/0000000000000000/never.png">',
    );
    const batch = [request(slow), request(fast)];
    const messages = new Map([
      [sha(fast), fast],
      [sha(slow), slow],
    ]);
    const dir = mkdtempSync(join(tmpdir(), "browser-emulation-test-"));
    const ctx: SessionCtx = {
      run: "r1",
      session: null,
      runDir: dir,
      planned: batch,
      assert: false,
      cold: false,
      services: {},
    };
    const provider = new BrowserEmulationProvider(process.env);
    try {
      await provider.prepare(ctx);
      const results = provider
        .capture(batch, messages, ctx)
        [Symbol.asyncIterator]();
      const t0 = Date.now();
      const first = await results.next();
      const firstMs = Date.now() - t0;
      assert.equal(first.done, false);
      const r1 = first.value as CaptureResult;
      assert.equal(r1.request.story, "fast");
      assert.equal(r1.status, "done", r1.reason);
      // The slow capture is still running: its result is not ready a
      // second after the first one was handed over.
      const second = results.next();
      const early = await Promise.race([
        second.then(() => true),
        new Promise<false>((r) => setTimeout(() => r(false), 1000).unref()),
      ]);
      assert.equal(
        early,
        false,
        `the second result was ready with the first (first after ${firstMs} ms): the batch was buffered`,
      );
      const r2 = (await second).value as CaptureResult;
      assert.equal(r2.request.story, "slow");
      assert.equal(r2.status, "failed");
      assert.match(r2.reason ?? "", /never finished loading within 5000 ms/);
      assert.equal((await results.next()).done, true);
    } finally {
      await provider.dispose();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
