// tools/capture/axe.test.ts — axe-core, the seventh Tier-3 check.
//
// No test doubles: the dev shell's pinned axe-core ($ISONIM_EMAIL_AXE)
// in the pinned Chromium, through the real browser-emulation provider
// (run under `nix develop`). A message with an image without alt text
// records axe's `image-alt` violation and is refused under --assert; a
// clean message passes; and the rules switched off for email are off
// (the same page under axe's defaults reports `region`, ours does not).
// Run with:
//   node --test tools/capture/axe.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  AXE_DISABLED,
  AXE_TAGS,
  axeAssertion,
  axeOptions,
  loadAxeSource,
  runAxe,
} from "./axe.ts";
import {
  BrowserEmulationProvider,
  resolveDriver,
} from "./providers/browser_emulation.ts";
import type {
  CaptureRequest,
  CaptureResult,
  SessionCtx,
  StoryMessage,
} from "./providers/types.ts";

const clean =
  '<!doctype html><html lang="en"><head><title>Clean</title></head>' +
  "<body><h1>Clean</h1><p>A paragraph.</p></body></html>";
// Everything the six DOM assertions want (a visible unsubscribe link,
// 44px tall), so under --assert only axe can refuse it.
const missingAlt =
  '<!doctype html><html lang="en"><head><title>Alt</title></head>' +
  '<body><h1>Alt</h1><img src="data:image/gif;base64,' +
  'R0lGODlhAQABAAAAACw=" width="1" height="1">' +
  '<p><a href="https://example.com/unsubscribe" style="display:' +
  'inline-block;padding:12px 4px;line-height:20px">Unsubscribe</a></p>' +
  "</body></html>";

function message(story: string, html: string): StoryMessage {
  return { story, mime: Buffer.from(`Subject: ${story}\r\n\r\n${html}`), html };
}

function sha(m: StoryMessage): string {
  return createHash("sha256").update(m.mime).digest("hex");
}

function request(m: StoryMessage): CaptureRequest {
  return {
    id: `a-chromium-baseline-chromium-desktop-light-on`,
    story: m.story,
    mimeSha256: sha(m),
    provider: "browser-emulation",
    backend: "a",
    family: "chromium-baseline",
    clientId: "chromium",
    viewport: { name: "desktop", width: 800, dpr: 1 },
    scheme: "light",
    images: "on",
  };
}

async function captureAll(
  msgs: StoryMessage[],
  gate: boolean,
): Promise<Map<string, CaptureResult>> {
  const batch = msgs.map(request);
  const dir = mkdtempSync(join(tmpdir(), "axe-test-"));
  const ctx: SessionCtx = {
    run: "r1",
    session: null,
    runDir: dir,
    planned: batch,
    assert: gate,
    cold: false,
    services: {},
  };
  const provider = new BrowserEmulationProvider(process.env);
  const out = new Map<string, CaptureResult>();
  try {
    await provider.prepare(ctx);
    for await (const r of provider.capture(
      batch,
      new Map(msgs.map((m) => [sha(m), m])),
      ctx,
    ))
      out.set(r.request.story, r);
  } finally {
    await provider.dispose();
    rmSync(dir, { recursive: true, force: true });
  }
  return out;
}

function axeOf(r: CaptureResult | undefined): {
  check: string;
  pass: boolean | null;
  detail: string;
} {
  const list = (r?.provenance as { assertions?: unknown[] }).assertions;
  assert.ok(Array.isArray(list), "the capture records its assertions");
  const a = list.find((x) => (x as { check?: string }).check === "axe") as
    | { check: string; pass: boolean | null; detail: string }
    | undefined;
  assert.ok(a !== undefined, "an axe result is recorded");
  return a;
}

describe("axe-core in the captures", () => {
  it("records image-alt for a missing alt, and passes a clean message", async () => {
    const results = await captureAll(
      [message("clean", clean), message("alt", missingAlt)],
      false,
    );
    const ok = axeOf(results.get("clean"));
    assert.equal(ok.pass, true, ok.detail);
    assert.match(ok.detail, /^axe-core 4\.13\.0: no violations/);
    const bad = axeOf(results.get("alt"));
    assert.equal(bad.pass, false);
    assert.match(bad.detail, /image-alt \(critical, 1 node, first: img\)/);
    // The provenance keeps the count and the first rule IDs.
    const prov = results.get("alt")?.provenance as {
      axe?: { version: string; violations: number; rules: string[] };
    };
    assert.equal(prov.axe?.version, "4.13.0");
    assert.ok((prov.axe?.violations ?? 0) >= 1);
    assert.ok(prov.axe?.rules.includes("image-alt"));
  });

  it("refuses a violating capture under --assert, like the other checks", async () => {
    const results = await captureAll([message("alt", missingAlt)], true);
    const r = results.get("alt");
    assert.equal(r?.status, "failed");
    assert.match(
      (r as { reason: string }).reason,
      /Tier-3 DOM assertion\(s\) failed \(--assert\): axe: .*image-alt/,
    );
  });

  it("switches off the rules that judge a web page, and only those", async () => {
    // Control: the same clean page under axe's defaults reports content
    // outside landmarks, which a message never has.
    const driver = resolveDriver(process.env);
    assert.ok(!("reason" in driver), "the pinned playwright-core is found");
    const axe = loadAxeSource();
    assert.ok("source" in axe, "the pinned axe-core is found");
    const pw = (await import(
      pathToFileURL(join(driver.dir, "index.mjs")).href
    )) as typeof import("playwright-core");
    const browser = await pw.chromium.launch();
    try {
      const page = await browser.newPage();
      await page.setContent(clean);
      const ours = await runAxe(page, axe.source);
      assert.deepEqual(ours.violations, []);
      const defaults = (await page.evaluate(async () => {
        const g = globalThis as unknown as {
          axe: { run(d: unknown): Promise<{ violations: { id: string }[] }> };
          document: unknown;
        };
        return (await g.axe.run(g.document)).violations.map((v) => v.id);
      })) as string[];
      assert.ok(defaults.includes("region"), defaults.join(", "));
    } finally {
      await browser.close();
    }
    const opts = axeOptions() as {
      runOnly: { values: string[] };
      rules: Record<string, { enabled: boolean }>;
    };
    assert.deepEqual(opts.runOnly.values, AXE_TAGS);
    assert.deepEqual(
      Object.keys(opts.rules).sort(),
      Object.keys(AXE_DISABLED).sort(),
    );
    for (const id of Object.keys(AXE_DISABLED))
      assert.ok(
        id === "region" || id === "bypass" || id.startsWith("landmark-"),
        id,
      );
  });

  it("summarises at most five violations", () => {
    const many = Array.from({ length: 7 }, (_, i) => ({
      id: `rule-${i}`,
      impact: "serious",
      nodes: i + 1,
      target: `p:nth-child(${i + 1})`,
    }));
    const a = axeAssertion({ version: "4.13.0", violations: many });
    assert.equal(a.pass, false);
    assert.match(a.detail, /7 rules violated: rule-0 \(serious, 1 node,/);
    assert.match(a.detail, /rule-4 .*; and 2 more$/);
    assert.doesNotMatch(a.detail, /rule-5/);
    assert.deepEqual(axeAssertion({ version: "4.13.0", violations: [] }), {
      check: "axe",
      pass: true,
      detail: "axe-core 4.13.0: no violations of the email rules",
    });
  });
});
