// tools/capture/providers/unavailable_cli.test.ts — the real capture CLI
// with its real provider made unavailable, and the same run with it
// available (warm, and with --cold reaching the provider's session and
// the latency history's selection key).
//
// No test doubles: the local browser provider is made unavailable the
// way a developer's machine would be, by running the CLI without the dev
// shell's PLAYWRIGHT_BROWSERS_PATH. Needs the story and brief drivers
// (`just email-shots-build`, which `just test` runs first). Run with:
//   node --test tools/capture/providers/unavailable_cli.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import type { Entry, Provenance } from "./harness.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const cli = join(repoRoot, "tools", "capture", "email-shots.ts");
const scratch = mkdtempSync(join(tmpdir(), "capture-unavailable-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

function runCli(
  out: string,
  env: Record<string, string | undefined>,
  extra: string[] = [],
): { status: number; stderr: string } {
  const r = spawnSync(
    process.execPath,
    [
      cli,
      "canary",
      "--families",
      "apple,gmailWeb",
      "--viewports",
      "mobile",
      "--schemes",
      "light",
      "--no-cache",
      "--out",
      out,
      ...extra,
    ],
    { cwd: repoRoot, encoding: "utf8", env },
  );
  return { status: r.status ?? 1, stderr: r.stderr as string };
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

describe("email-shots with an unavailable provider", () => {
  it("names the unavailable provider and its reason in the run summary and fails its requests", () => {
    const out = join(scratch, "unavailable");
    const env = { ...process.env };
    delete env.PLAYWRIGHT_BROWSERS_PATH;
    const r = runCli(out, env);
    assert.equal(r.status, 1, r.stderr);
    assert.match(
      r.stderr,
      /email-shots: provider browser-emulation \(backend a, v4\) UNAVAILABLE: PLAYWRIGHT_BROWSERS_PATH is not set/,
    );
    assert.match(r.stderr, /2 capture\(s\) failed/);
    // Each failed capture is named in the run summary with its provider,
    // client and reason, not only counted.
    for (const [family, client] of [
      ["apple", "webkit"],
      ["gmailWeb", "chromium"],
    ])
      assert.match(
        r.stderr,
        new RegExp(
          `email-shots: FAILED canary ${family} mobile/light images on, provider browser-emulation, client ${client}: no available provider serves ${family}: browser-emulation is unavailable: PLAYWRIGHT_BROWSERS_PATH is not set`,
        ),
      );
    const index = readJson<Entry[]>(join(out, "index.json"));
    assert.equal(index.length, 2);
    for (const e of index) {
      assert.equal(e.status, "failed");
      assert.equal(e.png, null);
      assert.ok(e.meta !== null);
      const meta = readJson<Provenance>(join(out, e.meta));
      assert.match(
        meta.fail_reason ?? "",
        /no available provider serves .*browser-emulation is unavailable: PLAYWRIGHT_BROWSERS_PATH is not set/,
      );
    }
    const runJson = readJson<{
      providers: Record<string, { health: string; reason: string | null }>;
    }>(join(out, "run.json"));
    assert.equal(runJson.providers["browser-emulation"]?.health, "unavailable");
    assert.match(
      runJson.providers["browser-emulation"]?.reason ?? "",
      /PLAYWRIGHT_BROWSERS_PATH/,
    );
  });

  it("with the provider available, the run summary lists no unavailability", () => {
    const out = join(scratch, "available");
    const r = runCli(out, { ...process.env });
    assert.equal(r.status, 0, r.stderr);
    assert.doesNotMatch(r.stderr, /UNAVAILABLE|DEGRADED/);
    assert.match(
      r.stderr,
      /email-shots: provider browser-emulation \(backend a, v4\): 2 request\(s\), 2 done/,
    );
    const runJson = readJson<{
      providers: Record<
        string,
        { health: string; reason: string | null; via: string; cold: boolean }
      >;
    }>(join(out, "run.json"));
    assert.equal(runJson.providers["browser-emulation"]?.health, "ok");
    assert.equal(runJson.providers["browser-emulation"]?.reason, null);
    assert.equal(runJson.providers["browser-emulation"]?.via, "local");
    assert.equal(runJson.providers["browser-emulation"]?.cold, false);
  });

  it("--cold reaches the provider's session", () => {
    const out = join(scratch, "cold");
    const r = runCli(out, { ...process.env }, ["--cold"]);
    assert.equal(r.status, 0, r.stderr);
    // run.json records the cold flag of the session the harness handed
    // the provider.
    const runJson = readJson<{
      providers: Record<string, { cold: boolean | null }>;
      latency: { key: string };
    }>(join(out, "run.json"));
    assert.equal(runJson.providers["browser-emulation"]?.cold, true);
    // A cold run never shares a rolling median with a warm run of the
    // same selection (the warm run is the previous test's).
    const warm = readJson<{ latency: { key: string } }>(
      join(scratch, "available", "run.json"),
    );
    assert.match(runJson.latency.key, /^[0-9a-f]{16}$/);
    assert.notEqual(runJson.latency.key, warm.latency.key);
  });
});
