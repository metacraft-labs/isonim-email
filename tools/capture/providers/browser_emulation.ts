// tools/capture/providers/browser_emulation.ts — the local browser
// provider (backend A).
//
// Renders a story's HTML part in the dev shell's pinned Chromium, WebKit
// and Firefox through Playwright: raw, or through the gmailWeb, ganga,
// outlookWeb, imagesOff and wordApprox emulations, with images=off
// layered on any of them (transforms.ts). Its clients are the three
// engines; its families are the emulation labels plus the raw engines'
// apple, thunderbird and chromium-baseline. Captures never use the
// network: only the story fixture host and data: URIs load
// (fixture_host.ts).
//
// Determinism: a fixed page clock, animations disabled, the caret
// hidden, fonts and images settled before the screenshot. Anything that
// can change this provider's pixels for the same message bumps
// BROWSER_EMULATION_VERSION or BROWSER_EMULATION_ADAPTER_VERSION.

import { existsSync, readFileSync } from "node:fs";
import { cpus } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Browser, BrowserType } from "playwright-core";
import { applyChain, transformChain, transformVersion } from "../transforms.ts";
import { domAssertionsScript } from "../dom_assertions.ts";
import { launchOptions } from "../launch.ts";
import { installCapturePolicy } from "../fixture_host.ts";
import type { AssertionResult } from "./harness.ts";
import type {
  CaptureProvider,
  CaptureRequest,
  CaptureResult,
  ClientDescriptor,
  Emulation,
  Engine,
  ProviderHealth,
  Requirement,
  Scheme,
  SessionCtx,
  Sha256,
  StoryMessage,
} from "./types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
// Story fixture images, served on the fixture host (fixture_host.ts).
const storyAssetsDir = join(repoRoot, "tests", "stories", "assets");

export const BROWSER_EMULATION_ID = "browser-emulation";
// Bump whenever output can change for reasons no other key field
// captures.
export const BROWSER_EMULATION_VERSION = "1";
// Bump by hand when crop/mask/wait changes. 2: story images are served
// from the local fixture host instead of failing to load.
export const BROWSER_EMULATION_ADAPTER_VERSION = 2;

const FIXED_CLOCK = "2026-01-01T12:00:00Z";
const IMAGE_TIMEOUT_MS = 5000;

type EngineName = "chromium" | "webkit" | "firefox";

interface FamilyDef {
  engine: EngineName;
  approximation: boolean;
}

// The families this provider serves, in matrix order.
export const BROWSER_FAMILIES: Readonly<Record<string, FamilyDef>> = {
  apple: { engine: "webkit", approximation: false },
  thunderbird: { engine: "firefox", approximation: true },
  "chromium-baseline": { engine: "chromium", approximation: true },
  gmailWeb: { engine: "chromium", approximation: true },
  ganga: { engine: "chromium", approximation: true },
  outlookWeb: { engine: "chromium", approximation: true },
  imagesOff: { engine: "chromium", approximation: true },
  wordApprox: { engine: "chromium", approximation: true },
};

const ENGINE_KIND: Record<EngineName, Engine> = {
  chromium: "blink",
  webkit: "webkit",
  firefox: "gecko",
};

// Forced dark exists only for Chromium (WebContentsForceDark); no other
// engine emulates it.
const ENGINE_SCHEMES: Record<EngineName, Scheme[]> = {
  chromium: ["light", "dark", "forced-dark"],
  webkit: ["light", "dark"],
  firefox: ["light", "dark"],
};

// Own keys only: `in` would also accept Object.prototype members.
function familyDef(family: string): FamilyDef {
  const def = Object.hasOwn(BROWSER_FAMILIES, family)
    ? BROWSER_FAMILIES[family]
    : undefined;
  if (def === undefined) throw new Error(`unknown family '${family}'`);
  return def;
}

// ---------------------------------------------------------------------------
// Playwright driver resolution (pinned shell browsers)
// ---------------------------------------------------------------------------

type Playwright = typeof import("playwright-core");

// The browsers.json each playwright-core ships (the parts read here).
interface BrowsersJson {
  browsers: { name: string; revision: string }[];
}

function candidateDriverPaths(
  env: Record<string, string | undefined>,
): string[] {
  const paths: string[] = [];
  if (env.PLAYWRIGHT_CORE_PATH) paths.push(env.PLAYWRIGHT_CORE_PATH);
  paths.push(
    join(repoRoot, "tools", "capture", "node_modules", "playwright-core"),
  );
  paths.push(join(repoRoot, "..", "isonim", "node_modules", "playwright-core"));
  return paths;
}

// The playwright-core directory to load, checked against the pinned
// browser trees; a reason when there is none.
export function resolveDriver(
  env: Record<string, string | undefined>,
): { dir: string; version: string } | { reason: string } {
  for (const dir of candidateDriverPaths(env)) {
    const pkgFile = join(dir, "package.json");
    if (!existsSync(join(dir, "index.mjs")) || !existsSync(pkgFile)) continue;
    const pkg = JSON.parse(readFileSync(pkgFile, "utf8")) as {
      version: string;
    };
    const browsersPath = env.PLAYWRIGHT_BROWSERS_PATH;
    if (!browsersPath || !existsSync(browsersPath))
      return {
        reason:
          "PLAYWRIGHT_BROWSERS_PATH is not set to a readable directory — refusing to download browsers (run under `nix develop` in isonim-email, whose flake pins the shell browsers)",
      };
    const browsersJson = JSON.parse(
      readFileSync(join(dir, "browsers.json"), "utf8"),
    ) as BrowsersJson;
    for (const want of ["chromium", "firefox", "webkit"]) {
      const found = browsersJson.browsers.find((b) => b.name === want);
      if (!found) continue;
      // headless-shell shares the chromium revision; only the full
      // chromium, firefox and webkit trees are checked here.
      if (!existsSync(join(browsersPath, `${want}-${found.revision}`)))
        return {
          reason: `playwright-core ${pkg.version} at ${dir} expects ${want}-${found.revision} but ${browsersPath} has no such tree (driver/browser mismatch — run under \`nix develop\` so PLAYWRIGHT_CORE_PATH matches the pinned browsers)`,
        };
    }
    return { dir, version: pkg.version };
  }
  return {
    reason: `no playwright-core found (tried ${candidateDriverPaths(env).join(", ")}) — run under \`nix develop\` in isonim-email`,
  };
}

function browserType(pw: Playwright, engine: EngineName): BrowserType {
  switch (engine) {
    case "chromium":
      return pw.chromium;
    case "firefox":
      return pw.firefox;
    case "webkit":
      return pw.webkit;
  }
}

// ---------------------------------------------------------------------------
// One capture
// ---------------------------------------------------------------------------

function launchKey(engine: EngineName, scheme: Scheme): string {
  return `${engine}|${scheme === "forced-dark" ? "forced" : "plain"}`;
}

function emulationOf(req: CaptureRequest): Emulation {
  const chain = transformChain(req.family, req.images);
  return {
    transformVersion: transformVersion(chain),
    // The transforms applied, in order: the family's own emulation,
    // then imagesOff for images=off. null for a raw capture with
    // images on.
    detail:
      chain.length === 0
        ? null
        : {
            transform: chain.map((t) => t.name).join("+"),
            chain: chain.map((t) => ({
              transform: t.name,
              version: t.version,
            })),
            version: (chain.length === 1 ? chain[0]?.version : null) ?? null,
          },
  };
}

async function imagesComplete(
  page: import("playwright-core").Page,
  timeoutMs: number,
): Promise<boolean> {
  // Node-side polling: the page clock is fixed, so in-page timers and
  // Date.now() are frozen and the wait must live here.
  const start = Date.now();
  for (;;) {
    const done = await page.evaluate(
      "Array.from(document.images).every((i) => i.complete)",
    );
    if (done) return true;
    if (Date.now() - start >= timeoutMs) return false;
    await new Promise((r) => setTimeout(r, 50));
  }
}

async function captureOne(
  browser: Browser,
  req: CaptureRequest,
  html: string,
  gateAssertions: boolean,
): Promise<CaptureResult> {
  const chain = transformChain(req.family, req.images);
  const t0 = Date.now();
  const timing: Record<string, number> = {};
  const failed = (
    provenance: Record<string, unknown>,
    reason: string,
  ): CaptureResult => ({ request: req, status: "failed", reason, provenance });
  const context = await browser.newContext({
    viewport: { width: req.viewport.width, height: 800 },
    deviceScaleFactor: req.viewport.dpr,
    colorScheme: req.scheme === "light" ? "light" : "dark",
  });
  try {
    // Nothing leaves the machine: story images come from the local
    // fixture host, data: URIs stay inline, every other request is
    // aborted and recorded in the provenance (fixture_host.ts).
    const blocked = await installCapturePolicy(
      context,
      storyAssetsDir,
      req.images,
    );
    const network = (): Record<string, unknown> => ({
      policy: "fixture-host-and-data-only",
      blocked: [...blocked],
    });
    const page = await context.newPage();
    // Emulated families (and images=off) rewrite the HTML before
    // setContent; the provenance records the chain.
    const effective = applyChain(chain, html, req.scheme);
    await page.clock.setFixedTime(FIXED_CLOCK);
    const tSet = Date.now();
    await page.setContent(effective, { waitUntil: "load" });
    timing.setcontent_ms = Date.now() - tSet;
    const tSettle = Date.now();
    await page.evaluate("document.fonts.ready.then(() => true)");
    if (!(await imagesComplete(page, IMAGE_TIMEOUT_MS))) {
      timing.settle_ms = Date.now() - tSettle;
      return failed(
        {
          timing_ms: {
            total: Date.now() - t0,
            capture: 0,
            setcontent: timing.setcontent_ms,
            settle: timing.settle_ms,
          },
          network: network(),
        },
        `an image never finished loading within ${IMAGE_TIMEOUT_MS} ms`,
      );
    }
    timing.settle_ms = Date.now() - tSettle;
    // Tier-3 DOM assertions: evaluated after settle, before the
    // screenshot, recorded in every provenance either way; --assert
    // fails the capture on any failure (no PNG, like every other
    // capture failure).
    const assertions = (await page.evaluate(
      domAssertionsScript(),
    )) as AssertionResult[];
    // axe-core, the seventh Tier-3 item, is NOT run: no axe-core is
    // pinned in the dev shell or in isonim's node_modules, and an
    // unpinned download would silently unpin the audit. Recorded as
    // not-run (pass: null never gates) instead of faked.
    assertions.push({
      check: "axe",
      pass: null,
      detail:
        "axe-core not pinned — follow-up: pin axe-core (a flake.nix package or isonim/node_modules via yarn) and inject + axe.run it in-page here in captureOne, storing the violations count + first 5 rule IDs in the provenance",
    });
    const failedChecks = gateAssertions
      ? assertions.filter((a) => a.pass === false)
      : [];
    if (failedChecks.length > 0)
      return failed(
        {
          timing_ms: {
            total: Date.now() - t0,
            capture: 0,
            setcontent: timing.setcontent_ms,
            settle: timing.settle_ms,
          },
          assertions,
          network: network(),
        },
        `Tier-3 DOM assertion(s) failed (--assert): ` +
          failedChecks.map((a) => `${a.check}: ${a.detail}`).join("; "),
      );
    const tCap = Date.now();
    const png = await page.screenshot({
      fullPage: true,
      animations: "disabled",
      caret: "hide",
    });
    timing.capture_ms = Date.now() - tCap;
    return {
      request: req,
      status: "done",
      png,
      provenance: {
        timing_ms: {
          total: Date.now() - t0,
          capture: timing.capture_ms,
          setcontent: timing.setcontent_ms,
          settle: timing.settle_ms,
        },
        assertions,
        network: network(),
      },
    };
  } catch (err) {
    return failed(
      { timing_ms: { total: Date.now() - t0, capture: 0 } },
      err instanceof Error ? err.message : String(err),
    );
  } finally {
    await context.close();
  }
}

// ---------------------------------------------------------------------------
// The provider
// ---------------------------------------------------------------------------

export class BrowserEmulationProvider implements CaptureProvider {
  readonly id = BROWSER_EMULATION_ID;
  readonly backend = "a";
  readonly version = BROWSER_EMULATION_VERSION;
  readonly adapterVersion = BROWSER_EMULATION_ADAPTER_VERSION;

  private readonly env: Record<string, string | undefined>;
  private pw: Playwright | null = null;
  // One browser per (engine, forced-dark) key.
  private readonly browsers = new Map<string, Browser>();

  constructor(env: Record<string, string | undefined> = process.env) {
    this.env = env;
  }

  clients(): ClientDescriptor[] {
    return Object.entries(BROWSER_FAMILIES).map(([family, def]) => ({
      clientId: def.engine,
      family,
      engine: ENGINE_KIND[def.engine],
      build: async () => this.engineBuild(def.engine),
      viewports: "any",
      schemes: ENGINE_SCHEMES[def.engine],
      imagesOff: true,
      approximation: def.approximation,
    }));
  }

  // The launched engine's version ("" before prepare launched it); the
  // plain and forced-dark browsers of an engine are the same build.
  private engineBuild(engine: EngineName): string {
    const b =
      this.browsers.get(`${engine}|plain`) ??
      this.browsers.get(`${engine}|forced`);
    return b === undefined ? "" : b.version();
  }

  requirements(): Requirement[] {
    return [
      {
        kind: "host-os",
        os: ["linux", "darwin"],
        why: "the pinned Playwright browsers exist for Linux and macOS",
      },
      {
        kind: "env-dir",
        variable: "PLAYWRIGHT_BROWSERS_PATH",
        why: "the dev shell's pinned browser builds; browsers are never downloaded (run under `nix develop`)",
      },
    ];
  }

  async health(): Promise<ProviderHealth> {
    const driver = resolveDriver(this.env);
    return "reason" in driver
      ? { state: "unavailable", reason: driver.reason }
      : { state: "ok" };
  }

  // Loads the driver and launches, sequentially, one browser per
  // (engine, forced-dark) key the planned requests need — never lazily
  // from the capture workers, where a check-then-set races and leaks
  // duplicate browsers whose open pipes keep node alive.
  async prepare(ctx: SessionCtx): Promise<void> {
    if (this.pw === null) {
      const driver = resolveDriver(this.env);
      if ("reason" in driver) throw new Error(driver.reason);
      process.stderr.write(
        `email-shots: playwright-core ${driver.version} from ${driver.dir}\n`,
      );
      // A runtime-resolved specifier types as `any`; the module is the
      // playwright-core whose declarations the type-check reads.
      const pw: Playwright = await import(
        pathToFileURL(join(driver.dir, "index.mjs")).href
      );
      this.pw = pw;
    }
    const pw = this.pw;
    const keys = new Map<string, { engine: EngineName; forced: boolean }>();
    for (const r of ctx.planned) {
      const engine = familyDef(r.family).engine;
      keys.set(launchKey(engine, r.scheme), {
        engine,
        forced: r.scheme === "forced-dark",
      });
    }
    for (const [key, { engine, forced }] of keys) {
      if (this.browsers.has(key)) continue;
      // Launch options per engine and host: launch.ts (Linux keeps
      // Playwright's defaults; macOS daemon sessions need a
      // keychain-free, GPU-free Firefox profile).
      const opts = launchOptions(engine, forced, process.platform, this.env);
      try {
        this.browsers.set(key, await browserType(pw, engine).launch(opts));
      } catch (err) {
        throw new Error(
          `launching ${engine} (${forced ? "forced" : "plain"}) on ${process.platform} failed: ${err instanceof Error ? err.message : String(err)}`,
          { cause: err },
        );
      }
    }
  }

  emulation(req: CaptureRequest): Emulation {
    return emulationOf(req);
  }

  // A pool of min(8, cores) pages over the batch; results are yielded
  // in completion order, each as soon as it lands.
  async *capture(
    batch: CaptureRequest[],
    messages: Map<Sha256, StoryMessage>,
    ctx: SessionCtx,
  ): AsyncIterable<CaptureResult> {
    const ready: CaptureResult[] = [];
    let wake: (() => void) | null = null;
    let running = 0;
    let cursor = 0;
    const worker = async (): Promise<void> => {
      for (;;) {
        const req = batch[cursor++];
        if (req === undefined) return;
        let result: CaptureResult;
        const message = messages.get(req.mimeSha256);
        const browser = this.browsers.get(
          launchKey(familyDef(req.family).engine, req.scheme),
        );
        if (message === undefined)
          result = {
            request: req,
            status: "failed",
            reason: `no message for ${req.story} (${req.mimeSha256})`,
            provenance: {},
          };
        else if (browser === undefined)
          result = {
            request: req,
            status: "failed",
            reason: `no browser launched for ${launchKey(familyDef(req.family).engine, req.scheme)}`,
            provenance: {},
          };
        else
          try {
            result = await captureOne(browser, req, message.html, ctx.assert);
          } catch (err) {
            result = {
              request: req,
              status: "failed",
              reason: err instanceof Error ? err.message : String(err),
              provenance: {},
            };
          }
        ready.push(result);
        wake?.();
      }
    };
    const limit = Math.min(8, cpus().length, batch.length);
    const workers = Array.from({ length: limit }, async () => {
      running++;
      try {
        await worker();
      } finally {
        running--;
        wake?.();
      }
    });
    const all = Promise.all(workers);
    for (;;) {
      const next = ready.shift();
      if (next !== undefined) {
        yield next;
        continue;
      }
      if (running === 0) break;
      await new Promise<void>((r) => {
        wake = r;
      });
      wake = null;
    }
    await all;
  }

  async dispose(): Promise<void> {
    for (const b of this.browsers.values()) await b.close().catch(() => {});
    this.browsers.clear();
  }
}
