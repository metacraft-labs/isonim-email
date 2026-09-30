// tools/capture/network_policy.test.ts — captures never use the network.
//
// Three layers:
// - routeDecision, pure: the fixture host is served, data: URIs stay
//   inline, everything else is blocked; with images off, fixture-host
//   images are blocked too.
// - installCapturePolicy in each pinned engine (Chromium, Firefox,
//   WebKit): a page referencing a real local HTTP server, the fixture
//   host and a data: URI. The server must see no request at all, the
//   blocked list must name its URL, and the fixture and data: images
//   must load.
// - The CLI: a capture of a message pointing at that server reports the
//   blocked URL on its stdout line, in the run summary and in the
//   provenance's network.blocked.
//
// Test double, justified: the CLI layer runs with a stand-in story
// driver (a node script writing one message with an external image)
// and a stand-in brief driver (exits 0). No registered story points at
// the network — that is the point of the fixture host — and building
// one into the real drivers would add a story to every run. Everything
// under test (the CLI, the policy, the browser, the provenance) is
// real. Run with:
//   node --test tools/capture/network_policy.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  FIXTURE_HOST,
  installCapturePolicy,
  routeDecision,
} from "./fixture_host.ts";
import { launchOptions } from "./launch.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
const assetsDir = join(repoRoot, "tests", "stories", "assets");

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

function fixtureUrl(name: string): string {
  const sha = createHash("sha256")
    .update(readFileSync(join(assetsDir, name)))
    .digest("hex");
  return `${FIXTURE_HOST}/${sha.slice(0, 16)}/${name}`;
}

// A 1×1 PNG as a data: URI.
const DATA_PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

let server: Server;
let hits: string[] = [];
let external = "";

before(async () => {
  server = createServer((req, res) => {
    hits.push(req.url ?? "");
    res.writeHead(200, { "content-type": "image/png" });
    res.end(readFileSync(join(assetsDir, "logo.png")));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;
  external = `http://127.0.0.1:${port}/tracker.png`;
});

after(async () => {
  await new Promise<void>((r) => server.close(() => r()));
});

describe("routeDecision", () => {
  it("serves the fixture host, keeps data: inline, blocks the rest", () => {
    assert.deepEqual(routeDecision(fixtureUrl("logo.png"), "image", "on"), {
      action: "fixture",
    });
    assert.deepEqual(routeDecision(DATA_PNG, "image", "on"), {
      action: "allow",
    });
    for (const url of [
      "https://example.com/a.png",
      "http://127.0.0.1:8080/x",
      "https://x.test.example.com/a.png",
      "https://fonts.googleapis.com/css?family=Roboto",
    ])
      assert.deepEqual(routeDecision(url, "image", "on"), {
        action: "block",
        reason: "network",
      });
  });

  it("with images off, blocks fixture-host images but not other fixture requests", () => {
    assert.deepEqual(routeDecision(fixtureUrl("logo.png"), "image", "off"), {
      action: "block",
      reason: "images-off",
    });
    assert.deepEqual(
      routeDecision(fixtureUrl("logo.png"), "stylesheet", "off"),
      { action: "fixture" },
    );
  });
});

describe("installCapturePolicy in every pinned engine", () => {
  for (const engine of ["chromium", "firefox", "webkit"]) {
    it(`${engine}: the external server sees nothing, and the block is recorded`, async () => {
      const pw = await import(
        pathToFileURL(join(playwrightCore(), "index.mjs")).href
      );
      const browser = await pw[engine].launch(
        launchOptions(engine, false, process.platform, process.env),
      );
      try {
        const context = await browser.newContext();
        const blocked = await installCapturePolicy(context, assetsDir, "on");
        const page = await context.newPage();
        hits = [];
        await page.setContent(
          `<img id="ext" src="${external}">` +
            `<img id="fix" src="${fixtureUrl("logo.png")}">` +
            `<img id="data" src="${DATA_PNG}">`,
          { waitUntil: "load" },
        );
        const loaded = await page.evaluate(
          "Object.fromEntries([...document.images].map((i) => [i.id, i.complete && i.naturalWidth > 0]))",
        );
        assert.deepEqual(loaded, { ext: false, fix: true, data: true });
        assert.deepEqual(hits, [], "a request reached the external server");
        assert.deepEqual(blocked, [{ url: external, reason: "network" }]);
        await context.close();
      } finally {
        await browser.close();
      }
    });
  }
});

describe("the CLI reports blocked requests", () => {
  let work = "";
  before(() => {
    work = mkdtempSync(join(tmpdir(), "email-shots-network-"));
  });
  after(() => {
    if (work !== "") rmSync(work, { recursive: true, force: true });
  });

  it("names the blocked URL on the capture line, in the summary and in the provenance", async () => {
    const html =
      `<!DOCTYPE html><html><head></head><body>` +
      `<p style="font-size:16px">hello</p><img alt="tracker" src="${external}" width="1" height="1">` +
      `</body></html>`;
    const driver = join(work, "story-driver.mjs");
    writeFileSync(
      driver,
      `#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
const runDir = process.argv[2];
mkdirSync(runDir, { recursive: true });
const html = ${JSON.stringify(html)};
const eml = "Content-Type: text/html\\r\\n\\r\\n" + html;
writeFileSync(join(runDir, "netprobe.html"), html);
writeFileSync(join(runDir, "netprobe.eml"), eml);
writeFileSync(join(runDir, "manifest.json"), JSON.stringify({ stories: [{
  story: "netprobe", eml: "netprobe.eml", html: "netprobe.html",
  mime_sha256: createHash("sha256").update(eml).digest("hex") }] }));
`,
    );
    const briefDriver = join(work, "brief-driver.sh");
    writeFileSync(briefDriver, "#!/bin/sh\nexit 0\n");
    chmodSync(driver, 0o755);
    chmodSync(briefDriver, 0o755);
    const out = join(work, "run");
    hits = [];
    // Asynchronous, so this process's server keeps answering while the
    // CLI runs: a request that got through would be counted.
    const child = spawn(
      process.execPath,
      [
        join(scriptDir, "email-shots.ts"),
        "netprobe",
        "--driver",
        driver,
        "--brief-driver",
        briefDriver,
        "--families",
        "chromium-baseline",
        "--viewports",
        "desktop",
        "--schemes",
        "light",
        "--no-cache",
        "--out",
        out,
      ],
      {
        cwd: repoRoot,
        env: { ...process.env, PLAYWRIGHT_CORE_PATH: playwrightCore() },
      },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    const status = await new Promise<number>((r) =>
      child.on("close", (code) => r(code ?? 1)),
    );
    const r = { status, stdout, stderr };
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(hits, [], "a request reached the external server");
    const lines = (r.stdout as string)
      .split("\n")
      .filter((l) => l.startsWith("{"))
      .map((l) => JSON.parse(l));
    assert.equal(lines.length, 1, r.stdout as string);
    assert.equal(lines[0].status, "done");
    assert.deepEqual(lines[0].blocked, [external]);
    assert.match(
      r.stderr as string,
      new RegExp(
        `blocked 1 request\\(s\\) outside the fixture host.*${external.replace(/[.]/g, "\\.")}`,
      ),
    );
    const meta = JSON.parse(readFileSync(join(out, lines[0].meta), "utf8"));
    assert.deepEqual(meta.network.blocked, [
      { url: external, reason: "network" },
    ]);
  });
});
