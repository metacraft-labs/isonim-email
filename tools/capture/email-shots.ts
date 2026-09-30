#!/usr/bin/env node
// tools/capture/email-shots.ts — backend-A email captures.
//
// Backend A only: renders stories through the library in
// the working tree (via the build-stories driver), captures each
// story × family × viewport × scheme × images request in a pinned
// shell browser (raw except the gmailWeb/ganga/outlookWeb/imagesOff/wordApprox emulations),
// streams one JSON line per finished capture to stdout, and maintains
// index.json atomically. Exits non-zero when any non-async capture
// failed.
//
// Usage:
//   node tools/capture/email-shots.ts [STORY…] [--backends a]
//     [--families apple,thunderbird,chromium-baseline]
//     [--clients chromium,webkit,firefox]
//     [--viewports mobile,desktop] [--schemes light] [--images on]
//     [--out DIR] [--driver PATH]
//   node tools/capture/email-shots.ts --help
//
// Serves backend A only. --backends b/c/d fail naming the later backends.
// --affected/--full selection and the result cache:
// with no stories and no --full, only stories whose MIME changed
// since the previous run are captured (changed-only is the default).
// Records Tier-3 DOM assertions per capture (meta.assertions +
// per-story assertions.json); --assert gates captures on them.

import { spawnSync, execSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { cpus } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { GMAIL_WEB_TRANSFORM_VERSION, gmailWeb } from "./emulation/gmailWeb.ts";
import { GANGA_TRANSFORM_VERSION, ganga } from "./emulation/ganga.ts";
import {
  OUTLOOK_WEB_TRANSFORM_VERSION,
  outlookWeb,
} from "./emulation/outlookWeb.ts";
import {
  IMAGES_OFF_TRANSFORM_VERSION,
  imagesOff,
} from "./emulation/imagesOff.ts";
import {
  WORD_APPROX_TRANSFORM_VERSION,
  wordApprox,
} from "./emulation/wordApprox.ts";
import { ADAPTER_VERSION, cacheKey, readCache, writeCache } from "./cache.ts";
import { composeStorySheets } from "./contact_sheet.ts";
import { domAssertionsScript } from "./dom_assertions.ts";
import { changedFilesSince, darkNeeded, selectFamilies } from "./affected.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

// ---------------------------------------------------------------------------
// Matrix definition (the backend-A slice)
// ---------------------------------------------------------------------------

const FIXED_CLOCK = "2026-01-01T12:00:00Z";
const IMAGE_TIMEOUT_MS = 5000;

interface FamilyDef {
  engine: string;
  approximation: boolean;
}

const FAMILIES: Record<string, FamilyDef> = {
  apple: { engine: "webkit", approximation: false },
  thunderbird: { engine: "firefox", approximation: true },
  "chromium-baseline": { engine: "chromium", approximation: true },
  gmailWeb: { engine: "chromium", approximation: true },
  ganga: { engine: "chromium", approximation: true },
  outlookWeb: { engine: "chromium", approximation: true },
  imagesOff: { engine: "chromium", approximation: true },
  wordApprox: { engine: "chromium", approximation: true },
};

const ENGINES = new Set(["chromium", "webkit", "firefox"]);
const SCHEMES = new Set(["light", "dark", "forced-dark"]);

interface Viewport {
  name: string;
  width: number;
  dpr: number;
}

const NAMED_VIEWPORTS: Record<string, Viewport> = {
  mobile: { name: "mobile", width: 375, dpr: 3 },
  desktop: { name: "desktop", width: 800, dpr: 1 },
};

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

const USAGE = `usage: email-shots [STORY…] [options]

options:
  --backends a[,…]       serves backend A only (b/c/d land later)
  --families F,…         default: apple,thunderbird,chromium-baseline
  --clients C,…          filter by engine: chromium,webkit,firefox
  --viewports V,…        mobile,desktop (defaults) or W / W@DPR, e.g. 600,600@2x
  --schemes S,…          light (default),dark,forced-dark
  --images on|off        default: on (off is a skip marker outside imagesOff)
  --out DIR              run directory (default: build/email-shots/<run>)
  --driver PATH          build-stories binary (default: build/capture/build-stories)
  --brief-driver PATH    brief-driver binary (default: build/review/brief-driver)
  --affected             capture only what changed since the previous run
                        (stories by MIME hash, families/schemes by git diff;
                        this is also what a bare run does)
  --full                 capture the full matrix (cache reads still on)
  --no-cache             bypass the result cache (no reads, no writes)
  --assert               fail captures whose Tier-3 DOM assertions fail
                        (without it assertions are recorded, never gated)
  --help                 this text
`;

function failUsage(message: string): never {
  process.stderr.write(`email-shots: ${message}\n${USAGE}`);
  process.exit(2);
}

function fail(message: string): never {
  process.stderr.write(`email-shots: ${message}\n`);
  process.exit(1);
}

interface Options {
  stories: string[];
  backends: string[];
  families: string[];
  familiesExplicit: boolean;
  clients: string[] | null;
  viewports: Viewport[];
  schemes: string[];
  schemesExplicit: boolean;
  images: string[];
  outDir: string | null;
  driver: string;
  briefDriver: string;
  affected: boolean;
  full: boolean;
  noCache: boolean;
  assert: boolean;
}

function splitList(value: string): string[] {
  return value
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function parseViewport(token: string): Viewport {
  if (token in NAMED_VIEWPORTS) return NAMED_VIEWPORTS[token];
  const m = /^(\d+)@([\d.]+)x?$/.exec(token) ?? /^(\d+)$/.exec(token);
  if (!m)
    failUsage(`bad viewport '${token}' (want mobile, desktop, W or W@DPR)`);
  const width = parseInt(m[1], 10);
  const dpr = m[2] === undefined ? 1 : parseFloat(m[2]);
  if (!(width > 0) || !(dpr > 0))
    failUsage(`bad viewport '${token}' (width and DPR must be positive)`);
  return { name: `${width}@${m[2] === undefined ? "1" : m[2]}x`, width, dpr };
}

function parseArgs(argv: string[]): Options {
  const stories: string[] = [];
  const opt: Options = {
    stories,
    backends: ["a"],
    families: Object.keys(FAMILIES),
    familiesExplicit: false,
    clients: null,
    viewports: [NAMED_VIEWPORTS.mobile, NAMED_VIEWPORTS.desktop],
    schemes: ["light"],
    schemesExplicit: false,
    images: ["on"],
    outDir: null,
    driver: join(repoRoot, "build", "capture", "build-stories"),
    briefDriver: join(repoRoot, "build", "review", "brief-driver"),
    affected: false,
    full: false,
    noCache: false,
    assert: false,
  };
  const takesValue = new Set([
    "--backends",
    "--families",
    "--clients",
    "--viewports",
    "--schemes",
    "--images",
    "--out",
    "--driver",
    "--brief-driver",
  ]);
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      process.stdout.write(USAGE);
      process.exit(0);
    }
    if (
      arg === "--affected" ||
      arg === "--full" ||
      arg === "--no-cache" ||
      arg === "--assert"
    ) {
      if (arg === "--affected") opt.affected = true;
      else if (arg === "--full") opt.full = true;
      else if (arg === "--no-cache") opt.noCache = true;
      else opt.assert = true;
      continue;
    }
    if (arg === "--async" || arg === "--follow")
      failUsage(`${arg} is for backend-D async requests, which land later`);
    if (arg === "--via")
      failUsage(`--via (inject/smtp delivery choice) lands with backend B`);
    if (!arg.startsWith("--")) {
      stories.push(arg);
      continue;
    }
    if (!takesValue.has(arg)) failUsage(`unknown flag '${arg}'`);
    const value = argv[++i];
    if (value === undefined) failUsage(`flag '${arg}' needs a value`);
    switch (arg) {
      case "--backends":
        opt.backends = splitList(value);
        break;
      case "--families":
        opt.families = splitList(value);
        opt.familiesExplicit = true;
        break;
      case "--clients":
        opt.clients = splitList(value);
        break;
      case "--viewports":
        opt.viewports = splitList(value).map(parseViewport);
        break;
      case "--schemes":
        opt.schemes = splitList(value);
        opt.schemesExplicit = true;
        break;
      case "--images":
        opt.images = splitList(value);
        break;
      case "--out":
        opt.outDir = value;
        break;
      case "--driver":
        opt.driver = resolve(repoRoot, value);
        break;
      case "--brief-driver":
        opt.briefDriver = resolve(repoRoot, value);
        break;
    }
  }

  if (opt.affected && opt.full)
    failUsage(
      "--affected and --full conflict (affected = changed-only, full = everything)",
    );
  for (const b of opt.backends) {
    if (b === "a") continue;
    if (b === "b")
      failUsage(
        "backend B (webmail) lands later; this CLI serves backend A only",
      );
    if (b === "c")
      failUsage(
        "backend C (native clients) lands later; this CLI serves backend A only",
      );
    if (b === "d")
      failUsage(
        "backend D (Mailgun Inspect) lands later; this CLI serves backend A only",
      );
    failUsage(`unknown backend '${b}' (want a, b, c or d)`);
  }
  for (const f of opt.families) {
    if (f in FAMILIES) continue;
    failUsage(
      `family '${f}' is not a backend-A family (backend-A families: ${Object.keys(FAMILIES).join(", ")}; other families arrive with backends B/C/D later)`,
    );
  }
  if (opt.clients !== null)
    for (const c of opt.clients)
      if (!ENGINES.has(c))
        failUsage(
          `unknown client '${c}' (backend-A clients are engine names: chromium, webkit, firefox)`,
        );
  for (const s of opt.schemes)
    if (!SCHEMES.has(s))
      failUsage(`unknown scheme '${s}' (want light, dark or forced-dark)`);
  for (const g of opt.images)
    if (g !== "on" && g !== "off")
      failUsage(`unknown --images '${g}' (want on or off)`);
  if (opt.viewports.length === 0)
    failUsage("--viewports needs at least one viewport");
  return opt;
}

// ---------------------------------------------------------------------------
// Playwright driver resolution (pinned shell browsers)
// ---------------------------------------------------------------------------

function candidateDriverPaths(): string[] {
  const paths: string[] = [];
  if (process.env.PLAYWRIGHT_CORE_PATH)
    paths.push(process.env.PLAYWRIGHT_CORE_PATH);
  paths.push(
    join(repoRoot, "tools", "capture", "node_modules", "playwright-core"),
  );
  paths.push(join(repoRoot, "..", "isonim", "node_modules", "playwright-core"));
  return paths;
}

async function loadPlaywright(): Promise<any> {
  for (const dir of candidateDriverPaths()) {
    const entry = join(dir, "index.mjs");
    const pkgFile = join(dir, "package.json");
    if (!existsSync(entry) || !existsSync(pkgFile)) continue;
    const pkg = JSON.parse(readFileSync(pkgFile, "utf8"));
    const browsersPath = process.env.PLAYWRIGHT_BROWSERS_PATH;
    if (!browsersPath || !existsSync(browsersPath))
      fail(
        `PLAYWRIGHT_BROWSERS_PATH is not set to a readable directory — refusing to download browsers (run under \`nix develop\` in isonim-email, whose flake pins the shell browsers)`,
      );
    const browsersJson = JSON.parse(
      readFileSync(join(dir, "browsers.json"), "utf8"),
    );
    for (const want of ["chromium", "firefox", "webkit"]) {
      const found = (browsersJson.browsers as any[]).find(
        (b) => b.name === want,
      );
      if (!found) continue;
      // Note: headless-shell shares the chromium revision; only the
      // full chromium, firefox and webkit trees are checked here.
      if (!existsSync(join(browsersPath, `${want}-${found.revision}`)))
        fail(
          `playwright-core ${pkg.version} at ${dir} expects ${want}-${found.revision} but ${browsersPath} has no such tree (driver/browser mismatch — run under \`nix develop\` so PLAYWRIGHT_CORE_PATH matches the pinned browsers)`,
        );
    }
    process.stderr.write(
      `email-shots: playwright-core ${pkg.version} from ${dir}\n`,
    );
    return await import(pathToFileURL(entry).href);
  }
  fail(
    `no playwright-core found (tried ${candidateDriverPaths().join(", ")}) — run under \`nix develop\` in isonim-email`,
  );
}

// ---------------------------------------------------------------------------
// Provenance helpers (adapted for backend A)
// ---------------------------------------------------------------------------

interface LibraryInfo {
  commit: string;
  dirty: boolean;
  tree_hash: string;
}

function libraryInfo(): LibraryInfo {
  try {
    const commit = execSync("git rev-parse HEAD", { cwd: repoRoot })
      .toString()
      .trim();
    const tree = execSync("git rev-parse HEAD^{tree}", { cwd: repoRoot })
      .toString()
      .trim();
    const status = execSync("git status --porcelain", { cwd: repoRoot })
      .toString()
      .trim();
    return { commit, dirty: status.length > 0, tree_hash: tree };
  } catch {
    return { commit: "unknown", dirty: true, tree_hash: "unknown" };
  }
}

function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

// ---------------------------------------------------------------------------
// Capture (raw)
// ---------------------------------------------------------------------------

interface Request {
  story: string;
  family: string;
  engine: string;
  client: string;
  viewport: Viewport;
  scheme: string;
  images: string;
  htmlPath: string;
  emlPath: string;
  baseName: string;
}

interface Entry {
  story: string;
  backend: string;
  family: string;
  client: string;
  viewport: string;
  scheme: string;
  images: string;
  png: string | null;
  meta: string | null;
  status: string;
}

// One recorded Tier-3 assertion. pass: null is "not run" (the axe
// entry until axe-core is pinned) — it never gates, with or without
// --assert.
interface AssertionResult {
  check: string;
  pass: boolean | null;
  detail: string;
}

async function imagesComplete(page: any, timeoutMs: number): Promise<boolean> {
  // Node-side polling: the page clock is fixed, so in-page
  // timers and Date.now() are frozen and the wait must live here.
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
  pw: any,
  browsers: Map<string, any>,
  req: Request,
  runDir: string,
  run: string,
  lib: LibraryInfo,
  session: string | null,
  cacheRoot: string,
  noCache: boolean,
  gateAssertions: boolean,
  browserBuilds: Map<string, string>,
): Promise<{ entry: Entry; line: Record<string, unknown> }> {
  const storyDir = join(runDir, req.story);
  const pngRel =
    req.images === "on" || req.family === "imagesOff"
      ? join(req.story, `${req.baseName}.png`)
      : null;
  const metaRel = join(req.story, `${req.baseName}.json`);

  const finish = (
    status: string,
    png: string | null,
    meta: Record<string, unknown>,
    reason?: string,
  ): { entry: Entry; line: Record<string, unknown> } => {
    mkdirSync(storyDir, { recursive: true });
    writeFileSync(join(runDir, metaRel), JSON.stringify(meta, null, 2) + "\n");
    const entry: Entry = {
      story: req.story,
      backend: "a",
      family: req.family,
      client: req.client,
      viewport: req.viewport.name,
      scheme: req.scheme,
      images: req.images,
      png,
      meta: metaRel,
      status,
    };
    const line: Record<string, unknown> = { ...entry };
    if (reason !== undefined) line.reason = reason;
    return { entry, line };
  };

  const baseMeta = (): Record<string, unknown> => ({
    story: req.story,
    run,
    session,
    library: lib,
    mime_sha256: sha256File(req.emlPath),
    backend: "a",
    family: req.family,
    client: { id: req.client, build: "" },
    viewport: { width: req.viewport.width, height: 0, dpr: req.viewport.dpr },
    scheme: req.scheme,
    images: req.images,
    via: "local",
    adapter_version: ADAPTER_VERSION,
    // Skipped / not-applicable variants keep these trivial zeroes;
    // real and failed captures overwrite them below (every
    // provenance carries at least total + capture).
    timing_ms: { total: 0, capture: 0 },
    captured_at: new Date().toISOString(),
    cache: "uncached",
    approximation: FAMILIES[req.family].approximation,
    emulation:
      req.family === "gmailWeb"
        ? { transform: "gmailWeb", version: GMAIL_WEB_TRANSFORM_VERSION }
        : req.family === "ganga"
          ? { transform: "ganga", version: GANGA_TRANSFORM_VERSION }
          : req.family === "outlookWeb"
            ? {
                transform: "outlookWeb",
                version: OUTLOOK_WEB_TRANSFORM_VERSION,
              }
            : req.family === "imagesOff"
              ? {
                  transform: "imagesOff",
                  version: IMAGES_OFF_TRANSFORM_VERSION,
                }
              : req.family === "wordApprox"
                ? {
                    transform: "wordApprox",
                    version: WORD_APPROX_TRANSFORM_VERSION,
                  }
                : null,
    status: "",
  });

  // images=off is a skip marker outside imagesOff: only that
  // family's HTML→HTML transform exists, and network-blocking the
  // images would render broken-image icons instead — a different,
  // misleading picture. The variant is recorded honestly, with no PNG.
  // Composition: --images off (request axis) and the imagesOff family
  // (transform axis) are independent — the skip lifts only where the
  // transform exists, so imagesOff captures under either/both while
  // other families stay skipped under --images off.
  if (req.images === "off" && req.family !== "imagesOff") {
    const meta = baseMeta();
    meta.status = "skipped";
    meta.skip_reason =
      "images=off outside the imagesOff family is a skip marker; the per-request images=off variant lands later";
    return finish("skipped", null, meta, meta.skip_reason as string);
  }

  // Forced-dark exists only for Chromium (WebContentsForceDark).
  if (req.scheme === "forced-dark" && req.engine !== "chromium") {
    const meta = baseMeta();
    meta.status = "not-applicable";
    meta.skip_reason =
      "forced-dark is Chromium-only (WebContentsForceDark); no other engine emulates it";
    return finish("not-applicable", null, meta, meta.skip_reason as string);
  }

  const forced = req.scheme === "forced-dark";
  const key = `${req.engine}|${forced ? "forced" : "plain"}`;
  // Browsers launch up front in main(): a lazy per-worker launch
  // races (duplicate browsers, leaked handles, node never exits).
  const browser = browsers.get(key);
  if (!browser) throw new Error(`no browser launched for ${key}`);

  // Result cache: the key covers the capture inputs, so a
  // client update changes the key and stale results are never served.
  // Skip/not-applicable paths above never touch the cache.
  const mimeSha = sha256File(req.emlPath);
  const ckey = noCache
    ? null
    : cacheKey({
        mimeSha,
        backend: "a",
        family: req.family,
        clientId: req.client,
        clientBuild: browserBuilds.get(key) ?? browser.version(),
        viewport: req.viewport.name,
        dpr: req.viewport.dpr,
        scheme: req.scheme,
        images: req.images,
        adapterVersion: ADAPTER_VERSION,
      });
  if (ckey !== null) {
    const hit = readCache(cacheRoot, ckey);
    if (hit !== null) {
      // --assert gates cache hits on their RECORDED assertions: the
      // key covers the capture inputs, so the DOM — and hence the
      // assertion outcomes — is identical to a fresh capture.
      // Entries written before Tier-3 carry no assertions and cannot
      // gate; they pass through as done.
      if (
        gateAssertions &&
        Array.isArray((hit.meta as any).assertions) &&
        ((hit.meta as any).assertions as AssertionResult[]).some(
          (a) => a !== null && a.pass === false,
        )
      ) {
        const fails = ((hit.meta as any).assertions as AssertionResult[])
          .filter((a) => a !== null && a.pass === false)
          .map((a) => `${a.check}: ${a.detail}`)
          .join("; ");
        const meta = {
          ...hit.meta,
          run,
          session,
          cache: "hit",
          captured_at: new Date().toISOString(),
          status: "failed",
          fail_reason: `Tier-3 assertion(s) failed (--assert, replayed from cache): ${fails}`,
        };
        return finish("failed", null, meta, meta.fail_reason as string);
      }
      mkdirSync(storyDir, { recursive: true });
      writeFileSync(join(runDir, pngRel as string), hit.png);
      const meta = {
        ...hit.meta,
        run,
        session,
        cache: "hit",
        captured_at: new Date().toISOString(),
      };
      return finish("done", pngRel, meta);
    }
  }

  const t0 = Date.now();
  const timing: Record<string, number> = {};
  const context = await browser.newContext({
    viewport: { width: req.viewport.width, height: 800 },
    deviceScaleFactor: req.viewport.dpr,
    colorScheme: req.scheme === "light" ? "light" : "dark",
  });
  try {
    const page = await context.newPage();
    const html = readFileSync(req.htmlPath, "utf8");
    // Emulated families rewrite the HTML before setContent; the
    // provenance above records which transform.
    const effective =
      req.family === "gmailWeb"
        ? gmailWeb(html)
        : req.family === "ganga"
          ? ganga(html)
          : req.family === "outlookWeb"
            ? outlookWeb(html, req.scheme)
            : req.family === "imagesOff"
              ? imagesOff(html)
              : req.family === "wordApprox"
                ? wordApprox(html)
                : html;
    await page.clock.setFixedTime(FIXED_CLOCK);
    const tSet = Date.now();
    await page.setContent(effective, { waitUntil: "load" });
    timing.setcontent_ms = Date.now() - tSet;
    const tSettle = Date.now();
    await page.evaluate("document.fonts.ready.then(() => true)");
    if (!(await imagesComplete(page, IMAGE_TIMEOUT_MS))) {
      timing.settle_ms = Date.now() - tSettle;
      timing.total_ms = Date.now() - t0;
      const meta = baseMeta();
      (meta.client as Record<string, string>).build = browser.version();
      meta.timing_ms = { ...timing, capture_ms: 0 };
      meta.status = "failed";
      meta.fail_reason = `an image never finished loading within ${IMAGE_TIMEOUT_MS} ms`;
      return finish("failed", null, meta, meta.fail_reason as string);
    }
    timing.settle_ms = Date.now() - tSettle;
    // Tier-3 DOM assertions: evaluated after settle,
    // before the screenshot, recorded in every provenance either
    // way; --assert fails the capture on any failure (no PNG, like
    // every other capture failure).
    const assertions = (await page.evaluate(
      domAssertionsScript(),
    )) as AssertionResult[];
    // axe-core, the seventh Tier-3 item, is NOT run: no axe-core is
    // pinned in the dev shell (flake.nix: such tools "arrive with
    // the work that uses them") or in isonim's node_modules, and
    // an unpinned download would silently unpin the audit. Recorded
    // honestly as not-run (pass: null never gates) instead of faked.
    assertions.push({
      check: "axe",
      pass: null,
      detail:
        "axe-core not pinned — follow-up: pin axe-core (a flake.nix package or isonim/node_modules via yarn) and inject + axe.run it in-page here in captureOne, storing the violations count + first 5 rule IDs in the provenance",
    });
    const failedChecks = gateAssertions
      ? assertions.filter((a) => a.pass === false)
      : [];
    if (failedChecks.length > 0) {
      timing.total_ms = Date.now() - t0;
      const meta = baseMeta();
      (meta.client as Record<string, string>).build = browser.version();
      meta.timing_ms = {
        total: timing.total_ms,
        capture: 0,
        setcontent: timing.setcontent_ms,
        settle: timing.settle_ms,
      };
      meta.assertions = assertions;
      meta.status = "failed";
      meta.fail_reason =
        `Tier-3 DOM assertion(s) failed (--assert): ` +
        failedChecks.map((a) => `${a.check}: ${a.detail}`).join("; ");
      return finish("failed", null, meta, meta.fail_reason as string);
    }
    const pngAbs = join(runDir, pngRel as string);
    const tCap = Date.now();
    await page.screenshot({
      path: pngAbs,
      fullPage: true,
      animations: "disabled",
      caret: "hide",
    });
    timing.capture_ms = Date.now() - tCap;
    timing.total_ms = Date.now() - t0;
    const meta = baseMeta();
    (meta.client as Record<string, string>).build = browser.version();
    meta.timing_ms = {
      total: timing.total_ms,
      capture: timing.capture_ms,
      setcontent: timing.setcontent_ms,
      settle: timing.settle_ms,
    };
    meta.assertions = assertions;
    meta.status = "done";
    if (ckey !== null) {
      meta.cache = "miss";
      writeCache(cacheRoot, ckey, readFileSync(pngAbs), meta);
    }
    return finish("done", pngRel, meta);
  } catch (err) {
    timing.total_ms = Date.now() - t0;
    const meta = baseMeta();
    try {
      (meta.client as Record<string, string>).build = browser.version();
    } catch {
      /* browser died; build stays empty */
    }
    meta.timing_ms = { total: timing.total_ms, capture: 0 };
    meta.status = "failed";
    meta.fail_reason = err instanceof Error ? err.message : String(err);
    return finish("failed", null, meta, meta.fail_reason as string);
  } finally {
    await context.close();
  }
}

// ---------------------------------------------------------------------------
// Previous-run discovery (affected selection)
// ---------------------------------------------------------------------------

interface StoryManifest {
  stories: { story: string; eml: string; html: string; mime_sha256?: string }[];
}

interface RunJson {
  tree_hash: string;
  commit: string;
  dirty: boolean;
  date: string;
}

// Latest completed run under build/email-shots/, excluding this runDir:
// the dir (other than runDir) holding both manifest.json and run.json
// whose run.json is newest. Any error → null (full selection).
function discoverPreviousRun(
  shotsRoot: string,
  runDir: string,
): { dir: string; manifest: StoryManifest; runJson: RunJson } | null {
  try {
    const resolvedRun = resolve(runDir);
    const cands: { dir: string; mtime: number }[] = [];
    for (const e of readdirSync(shotsRoot, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      const dir = join(shotsRoot, e.name);
      if (resolve(dir) === resolvedRun) continue;
      const manifestPath = join(dir, "manifest.json");
      const runPath = join(dir, "run.json");
      if (!existsSync(manifestPath) || !existsSync(runPath)) continue;
      let mtime = 0;
      try {
        mtime = statSync(runPath).mtimeMs;
      } catch {
        continue;
      }
      cands.push({ dir, mtime });
    }
    cands.sort((a, b) => b.mtime - a.mtime);
    if (cands.length === 0) return null;
    const manifest = JSON.parse(
      readFileSync(join(cands[0].dir, "manifest.json"), "utf8"),
    ) as StoryManifest;
    const runJson = JSON.parse(
      readFileSync(join(cands[0].dir, "run.json"), "utf8"),
    ) as RunJson;
    return { dir: cands[0].dir, manifest, runJson };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const opt = parseArgs(process.argv.slice(2));

  if (!existsSync(opt.driver))
    fail(
      `story driver not found at ${opt.driver} — run \`just email-shots-build\` first`,
    );
  if (!existsSync(opt.briefDriver))
    fail(
      `brief driver not found at ${opt.briefDriver} — run \`just email-shots-build\` first`,
    );

  const run =
    "a1-" +
    new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "") +
    "Z";
  const runDir = opt.outDir
    ? resolve(repoRoot, opt.outDir)
    : join(repoRoot, "build", "email-shots", run);
  mkdirSync(runDir, { recursive: true });

  // Step 1: build the stories with the working-tree library.
  const built = spawnSync(opt.driver, [runDir, ...opt.stories], {
    cwd: repoRoot,
    stdio: ["ignore", "inherit", "inherit"],
  });
  if (built.status !== 0)
    fail(`story driver exited with status ${built.status}`);
  const manifest = JSON.parse(
    readFileSync(join(runDir, "manifest.json"), "utf8"),
  ) as StoryManifest;

  // Affected selection: explicit CLI stories win; --full or no
  // previous run captures everything; otherwise stories whose MIME
  // changed (missing previous entry = changed), families/schemes
  // from the git change set.
  let fullSelection = opt.full;
  let changed: string[] = [];
  const prev = opt.full
    ? null
    : discoverPreviousRun(join(repoRoot, "build", "email-shots"), runDir);
  if (prev === null) {
    fullSelection = true;
  } else {
    try {
      const run = (cmd: string[]): string => {
        const r = spawnSync(cmd[0], cmd.slice(1), {
          cwd: repoRoot,
          encoding: "utf8",
        });
        if (r.status !== 0)
          throw new Error(`${cmd.join(" ")} exited with status ${r.status}`);
        return r.stdout as string;
      };
      changed = changedFilesSince(run, prev.runJson.tree_hash);
    } catch (err) {
      process.stderr.write(
        `email-shots: cannot diff against previous run at ${prev.dir} (${err instanceof Error ? err.message : String(err)}); capturing everything\n`,
      );
      fullSelection = true;
    }
  }
  let storySet: Set<string> | null = null;
  if (opt.stories.length > 0) storySet = new Set(opt.stories);
  else if (!fullSelection && prev !== null) {
    const prevShas = new Map(
      prev.manifest.stories.map((s) => [s.story, s.mime_sha256]),
    );
    storySet = new Set(
      manifest.stories
        .filter((m) => prevShas.get(m.story) !== m.mime_sha256)
        .map((m) => m.story),
    );
  }
  const families =
    opt.familiesExplicit || fullSelection
      ? opt.families
      : selectFamilies(changed);
  const schemes =
    opt.schemesExplicit || fullSelection
      ? opt.schemes
      : darkNeeded(changed)
        ? ["light", "dark"]
        : ["light"];

  // Step 1b: review briefs for the selected
  // matrix — brief-<family>-<viewport>-<scheme>.md per story dir,
  // written before any capture so reviewers start with the briefs.
  const viewportNames = opt.viewports.map((v) => v.name).join(",");
  for (const m of manifest.stories) {
    if (storySet !== null && !storySet.has(m.story)) continue;
    const briefed = spawnSync(
      opt.briefDriver,
      [
        m.story,
        join(runDir, m.story),
        families.join(","),
        viewportNames,
        schemes.join(","),
      ],
      { cwd: repoRoot, stdio: ["ignore", "inherit", "inherit"] },
    );
    if (briefed.status !== 0)
      fail(
        `brief driver exited with status ${briefed.status} (story ${m.story})`,
      );
  }

  const pw = await loadPlaywright();
  const lib = libraryInfo();
  const session = process.env.EMAIL_SHOTS_SESSION ?? null;

  // The request matrix.
  const requests: Request[] = [];
  for (const m of manifest.stories) {
    if (storySet !== null && !storySet.has(m.story)) continue;
    for (const family of families) {
      const engine = FAMILIES[family].engine;
      if (opt.clients !== null && !opt.clients.includes(engine)) continue;
      for (const viewport of opt.viewports) {
        for (const scheme of schemes) {
          for (const images of opt.images) {
            requests.push({
              story: m.story,
              family,
              engine,
              client: engine,
              viewport,
              scheme,
              images,
              htmlPath: join(runDir, m.html),
              emlPath: join(runDir, m.eml),
              baseName: `a-${family}-${engine}-${viewport.name}-${scheme}-${images}`,
            });
          }
        }
      }
    }
  }
  if (requests.length === 0) {
    // Zero stories after MIME-diff selection is a clean no-op
    // (nothing changed since the previous run), not a
    // failure; exit 1 stays for real failures and for explicit
    // filters that remove every family.
    if (storySet !== null && storySet.size === 0) {
      process.stdout.write("email-shots: nothing to capture\n");
      process.exit(0);
    }
    fail("empty request matrix (a --clients filter removed every family?)");
  }

  // Steps 2+4: pool of min(8, cores) pages; one JSON line per
  // finished capture on stdout; index.json rewritten atomically.
  //
  // One browser per (engine, forced) key, launched sequentially up
  // front — never lazily from the workers, where the check-then-set
  // races and leaks duplicate browsers (whose open pipes keep node
  // alive after the last capture).
  const browsers = new Map<string, any>();
  const keys = new Set<string>();
  for (const r of requests) {
    // Mirror the skip gates in captureOne: only requests that never
    // reach setContent are excluded from the launch set.
    if (r.images !== "on" && r.family !== "imagesOff") continue;
    if (r.scheme === "forced-dark" && r.engine !== "chromium") continue;
    keys.add(`${r.engine}|${r.scheme === "forced-dark" ? "forced" : "plain"}`);
  }
  for (const key of keys) {
    const [engine, mode] = key.split("|");
    browsers.set(
      key,
      await pw[engine].launch(
        mode === "forced"
          ? { args: ["--enable-features=WebContentsForceDark"] }
          : {},
      ),
    );
  }
  // Client builds for the result-cache key, read once per browser.
  const browserBuilds = new Map<string, string>();
  for (const [key, b] of browsers) browserBuilds.set(key, b.version());
  const cacheRoot = join(repoRoot, "build", "email-shots", ".cache");
  const index: Entry[] = [];
  const indexPath = join(runDir, "index.json");
  const writeIndex = (): void => {
    const tmp = `${indexPath}.tmp`;
    writeFileSync(tmp, JSON.stringify(index, null, 2) + "\n");
    renameSync(tmp, indexPath);
  };
  writeIndex();
  let chain: Promise<void> = Promise.resolve();
  const record = (entry: Entry, line: Record<string, unknown>): void => {
    chain = chain.then(() => {
      index.push(entry);
      writeIndex();
      process.stdout.write(JSON.stringify(line) + "\n");
    });
  };

  const limit = Math.min(8, cpus().length);
  let failed = 0;
  let cursor = 0;
  const worker = async (): Promise<void> => {
    for (;;) {
      const i = cursor++;
      if (i >= requests.length) return;
      const { entry, line } = await captureOne(
        pw,
        browsers,
        requests[i],
        runDir,
        run,
        lib,
        session,
        cacheRoot,
        opt.noCache,
        opt.assert,
        browserBuilds,
      );
      if (entry.status === "failed") failed++;
      record(entry, line);
    }
  };
  try {
    await Promise.all(
      Array.from({ length: Math.min(limit, requests.length) }, () => worker()),
    );
    await chain;
  } finally {
    for (const b of browsers.values()) await b.close();
  }

  // Per-story assertions.json (Tier-3) — one file
  // per story aggregating its captures' recorded assertions, so the
  // checker and reviewers read Tier-3 without opening every
  // provenance. Written even when captures failed (a gated run's
  // evidence is the failures); captures sorted by name — index.json
  // follows worker completion order, which legitimately differs
  // between runs.
  for (const story of new Set(index.map((e) => e.story))) {
    const captures = index
      .filter((e) => e.story === story)
      .map((e) => {
        let assertions: unknown = null;
        if (e.meta !== null) {
          try {
            const m = JSON.parse(readFileSync(join(runDir, e.meta), "utf8"));
            assertions = Array.isArray(m.assertions) ? m.assertions : null;
          } catch {
            assertions = null;
          }
        }
        return {
          capture: e.meta !== null ? basename(e.meta, ".json") : null,
          family: e.family,
          client: e.client,
          viewport: e.viewport,
          scheme: e.scheme,
          images: e.images,
          status: e.status,
          assertions,
        };
      })
      .sort((a, b) =>
        (a.capture ?? "") < (b.capture ?? "")
          ? -1
          : (a.capture ?? "") > (b.capture ?? "")
            ? 1
            : 0,
      );
    const storyDir = join(runDir, story);
    mkdirSync(storyDir, { recursive: true });
    writeFileSync(
      join(storyDir, "assertions.json"),
      JSON.stringify({ story, run, captures }, null, 2) + "\n",
    );
    process.stderr.write(`email-shots: assertions ${story}/assertions.json\n`);
  }

  // Contact sheets after each story's captures complete — sheets are required run artifacts, so a compose failure fails the run.
  for (const story of new Set(requests.map((r) => r.story))) {
    for (const rel of composeStorySheets(runDir, story))
      process.stderr.write(`email-shots: contact sheet ${rel}\n`);
  }

  // run.json anchors the next --affected run's change set;
  // always written, from the library state read before capturing.
  writeFileSync(
    join(runDir, "run.json"),
    JSON.stringify(
      {
        tree_hash: lib.tree_hash,
        commit: lib.commit,
        dirty: lib.dirty,
        date: new Date().toISOString(),
      },
      null,
      2,
    ) + "\n",
  );

  const counts: Record<string, number> = {};
  for (const e of index) counts[e.status] = (counts[e.status] ?? 0) + 1;
  process.stderr.write(
    `email-shots: run ${runDir} — ${index.length} captures ` +
      Object.entries(counts)
        .map(([k, v]) => `${v} ${k}`)
        .join(", ") +
      "\n",
  );
  if (failed > 0) fail(`${failed} capture(s) failed (see ${indexPath})`);
}

main().catch((err) => {
  process.stderr.write(`email-shots: ${err?.stack ?? err}\n`);
  process.exit(1);
});
