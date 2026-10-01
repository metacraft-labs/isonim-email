#!/usr/bin/env node
// tools/capture/email-shots.ts — backend-A email captures.
//
// Backend A only: renders stories through the library in
// the working tree (via the build-stories driver), captures each
// story × family × viewport × scheme × images request in a pinned
// shell browser (raw, or through the gmailWeb/ganga/outlookWeb/
// imagesOff/wordApprox emulations, with images=off layered on any of
// them — transforms.ts), streams one JSON line per finished capture
// to stdout, and maintains index.json atomically. Exits non-zero when
// any capture failed. Captures never use the network: only the story
// fixture host and data: URIs load (fixture_host.ts).
//
// Usage: `node tools/capture/email-shots.ts --help` (the USAGE text
// below is the one reference; keep it in step with parseArgs).

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
import type { Browser, BrowserType, Page } from "playwright-core";
import { applyChain, transformChain, transformVersion } from "./transforms.ts";
import {
  ADAPTER_VERSION,
  cacheKey,
  PROVIDER_ID,
  PROVIDER_VERSION,
  readCache,
  writeCache,
} from "./cache.ts";
import { composeStorySheets } from "./contact_sheet.ts";
import { domAssertionsScript } from "./dom_assertions.ts";
import {
  changedFilesSince,
  type CommandRunner,
  darkNeeded,
  familiesForChange,
  workingTreeHash,
} from "./affected.ts";
import { launchOptions } from "./launch.ts";
import { installCapturePolicy, type BlockedRequest } from "./fixture_host.ts";
import {
  appendHistory,
  latencyVerdict,
  MIN_SAMPLES,
  readHistory,
  selectionKey,
  type HistoryEntry,
} from "./latency.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
// Story fixture images, served on the fixture host (fixture_host.ts).
const storyAssetsDir = join(repoRoot, "tests", "stories", "assets");

// ---------------------------------------------------------------------------
// Matrix definition (the backend-A slice)
// ---------------------------------------------------------------------------

const FIXED_CLOCK = "2026-01-01T12:00:00Z";
const IMAGE_TIMEOUT_MS = 5000;

interface FamilyDef {
  engine: string;
  approximation: boolean;
}

const FAMILIES: Readonly<Record<string, FamilyDef>> = {
  apple: { engine: "webkit", approximation: false },
  thunderbird: { engine: "firefox", approximation: true },
  "chromium-baseline": { engine: "chromium", approximation: true },
  gmailWeb: { engine: "chromium", approximation: true },
  ganga: { engine: "chromium", approximation: true },
  outlookWeb: { engine: "chromium", approximation: true },
  imagesOff: { engine: "chromium", approximation: true },
  wordApprox: { engine: "chromium", approximation: true },
};

// Own keys only: `in` would also accept Object.prototype members
// ("toString", "constructor") as family names.
function familyDef(family: string): FamilyDef | undefined {
  return Object.hasOwn(FAMILIES, family) ? FAMILIES[family] : undefined;
}

// A family already validated by parseArgs.
function knownFamily(family: string): FamilyDef {
  const def = familyDef(family);
  if (def === undefined) throw new Error(`unknown family '${family}'`);
  return def;
}

const ENGINES = new Set(["chromium", "webkit", "firefox"]);
const SCHEMES = new Set(["light", "dark", "forced-dark"]);

interface Viewport {
  name: string;
  width: number;
  dpr: number;
}

const MOBILE: Viewport = { name: "mobile", width: 375, dpr: 3 };
const DESKTOP: Viewport = { name: "desktop", width: 800, dpr: 1 };
const NAMED_VIEWPORTS = new Map<string, Viewport>([
  ["mobile", MOBILE],
  ["desktop", DESKTOP],
]);

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

const USAGE = `usage: email-shots [STORY…] [options]

With no STORY and no --full, a run is --affected: only the stories whose
MIME changed since the previous run, the families the changed modules
declare, and dark added when a colour, token or image changed.

options:
  --backends a           backend A (local engines) is the only one served;
                        b, c and d are refused naming the later backends
  --families F,…         apple,thunderbird,chromium-baseline,gmailWeb,ganga,
                        outlookWeb,imagesOff,wordApprox (default: all, or
                        the affected ones on an --affected run)
  --clients C,…          filter by engine: chromium,webkit,firefox
  --viewports V,…        mobile,desktop (default) or W / W@DPR, e.g. 600,600@2x
  --schemes S,…          light,dark,forced-dark (default: light, plus dark
                        on an --affected run whose change needs it;
                        forced-dark is Chromium-only)
  --images on,off        default: on; off captures every family with its
                        images blocked (the imagesOff transform after the
                        family's own); on,off captures both
  --out DIR              run directory (default: build/email-shots/<run>)
  --driver PATH          build-stories binary (default: build/capture/build-stories)
  --brief-driver PATH    brief-driver binary (default: build/review/brief-driver)
  --affected             capture only what changed since the previous run
                        (stories by MIME hash; families from the per-module
                        affects declarations of the files that changed in
                        the working tree; this is also what a bare run does)
  --full                 capture the full matrix (cache reads still on)
  --no-cache             bypass the result cache (no reads, no writes)
  --assert               fail captures whose Tier-3 DOM assertions fail
                        (without it assertions are recorded, never gated)
  --help                 this text

not yet served (refused with a reason): --async, --follow, --via.
Captures never use the network: requests other than the story fixture
host and data: URIs are blocked and listed in the run summary and in
each capture's provenance (network.blocked).
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
  const named = NAMED_VIEWPORTS.get(token);
  if (named !== undefined) return named;
  const [, widthText, dprText] =
    /^(\d+)@([\d.]+)x?$/.exec(token) ?? /^(\d+)$/.exec(token) ?? [];
  if (widthText === undefined)
    failUsage(`bad viewport '${token}' (want mobile, desktop, W or W@DPR)`);
  const width = parseInt(widthText, 10);
  const dpr = dprText === undefined ? 1 : parseFloat(dprText);
  if (!(width > 0) || !(dpr > 0))
    failUsage(`bad viewport '${token}' (width and DPR must be positive)`);
  return { name: `${width}@${dprText ?? "1"}x`, width, dpr };
}

function parseArgs(argv: string[]): Options {
  const stories: string[] = [];
  const opt: Options = {
    stories,
    backends: ["a"],
    families: Object.keys(FAMILIES),
    familiesExplicit: false,
    clients: null,
    viewports: [MOBILE, DESKTOP],
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
  // One iterator: a flag's value is the element after it.
  const args = argv.values();
  for (const arg of args) {
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
    const value = args.next().value;
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
    if (familyDef(f) !== undefined) continue;
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

// The playwright-core module's API, as its own declarations describe it.
type Playwright = typeof import("playwright-core");

// The browsers.json each playwright-core ships (the parts read here).
interface BrowsersJson {
  browsers: { name: string; revision: string }[];
}

function browserType(pw: Playwright, engine: string): BrowserType {
  switch (engine) {
    case "chromium":
      return pw.chromium;
    case "firefox":
      return pw.firefox;
    case "webkit":
      return pw.webkit;
  }
  throw new Error(`unknown engine '${engine}'`);
}

async function loadPlaywright(): Promise<Playwright> {
  for (const dir of candidateDriverPaths()) {
    const entry = join(dir, "index.mjs");
    const pkgFile = join(dir, "package.json");
    if (!existsSync(entry) || !existsSync(pkgFile)) continue;
    const pkg = JSON.parse(readFileSync(pkgFile, "utf8")) as {
      version: string;
    };
    const browsersPath = process.env.PLAYWRIGHT_BROWSERS_PATH;
    if (!browsersPath || !existsSync(browsersPath))
      fail(
        `PLAYWRIGHT_BROWSERS_PATH is not set to a readable directory — refusing to download browsers (run under \`nix develop\` in isonim-email, whose flake pins the shell browsers)`,
      );
    const browsersJson = JSON.parse(
      readFileSync(join(dir, "browsers.json"), "utf8"),
    ) as BrowsersJson;
    for (const want of ["chromium", "firefox", "webkit"]) {
      const found = browsersJson.browsers.find((b) => b.name === want);
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
    // A runtime-resolved specifier types as `any`; the module is the
    // playwright-core whose declarations the type-check reads.
    const pw: Playwright = await import(pathToFileURL(entry).href);
    return pw;
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

// tree_hash is the WORKING tree's hash, uncommitted and untracked
// changes included (affected.ts workingTreeHash), so the next run's
// --affected diff sees edits and reverts that never reach a commit.
function libraryInfo(): LibraryInfo {
  try {
    const commit = execSync("git rev-parse HEAD", { cwd: repoRoot })
      .toString()
      .trim();
    const tree = workingTreeHash(repoRoot);
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

// One index.json row.
export interface Entry {
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
export interface AssertionResult {
  check: string;
  pass: boolean | null;
  detail: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// A capture's provenance JSON (<story>/<baseName>.json), as far as
// readers of a finished run rely on it; baseMeta() below writes it.
export interface Provenance {
  story: string;
  status: string;
  cache: string;
  transform_version: string;
  emulation: {
    transform: string;
    chain: { transform: string; version: number }[];
    version: number | null;
  } | null;
  network?: { policy: string; blocked: BlockedRequest[] };
  assertions?: AssertionResult[];
  fail_reason?: string;
}

// URLs the network policy refused for a capture (from its provenance).
function blockedUrls(meta: Record<string, unknown>): string[] {
  const network = meta.network;
  const blocked = isRecord(network) ? network.blocked : undefined;
  if (!Array.isArray(blocked)) return [];
  const urls: string[] = [];
  for (const b of blocked as unknown[])
    if (isRecord(b) && b.reason === "network") urls.push(String(b.url));
  return urls;
}

// The Tier-3 assertions a provenance recorded; [] when it has none.
function recordedAssertions(meta: Record<string, unknown>): AssertionResult[] {
  const recorded = meta.assertions;
  if (!Array.isArray(recorded)) return [];
  const out: AssertionResult[] = [];
  for (const a of recorded as unknown[])
    if (isRecord(a))
      out.push({
        check: String(a.check),
        pass: typeof a.pass === "boolean" ? a.pass : null,
        detail: String(a.detail),
      });
  return out;
}

async function imagesComplete(page: Page, timeoutMs: number): Promise<boolean> {
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
  browsers: Map<string, Browser>,
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
  const pngRel = join(req.story, `${req.baseName}.png`);
  const chain = transformChain(req.family, req.images);
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
    // Requests the network policy refused, on the capture's own line
    // (images-off aborts are the axis working, not news).
    const refused = blockedUrls(meta);
    if (refused.length > 0) line.blocked = refused;
    return { entry, line };
  };

  const baseMeta = (): Record<string, unknown> => ({
    story: req.story,
    run,
    session,
    library: lib,
    mime_sha256: sha256File(req.emlPath),
    backend: "a",
    provider: PROVIDER_ID,
    provider_version: PROVIDER_VERSION,
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
    approximation: knownFamily(req.family).approximation,
    // The transforms applied, in order: the family's own emulation,
    // then imagesOff for images=off (transforms.ts). null for a raw
    // capture with images on.
    emulation:
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
    transform_version: transformVersion(chain),
    status: "",
  });

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
        provider: PROVIDER_ID,
        providerVersion: PROVIDER_VERSION,
        backend: "a",
        family: req.family,
        clientId: req.client,
        clientBuild: browserBuilds.get(key) ?? browser.version(),
        viewport: req.viewport.name,
        dpr: req.viewport.dpr,
        scheme: req.scheme,
        images: req.images,
        adapterVersion: ADAPTER_VERSION,
        transformVersion: transformVersion(chain),
      });
  if (ckey !== null) {
    const hit = readCache(cacheRoot, ckey);
    if (hit !== null) {
      // --assert gates cache hits on their RECORDED assertions: the
      // key covers the capture inputs, so the DOM — and hence the
      // assertion outcomes — is identical to a fresh capture.
      // Entries written before Tier-3 carry no assertions and cannot
      // gate; they pass through as done.
      const recordedFailures = recordedAssertions(hit.meta).filter(
        (a) => a.pass === false,
      );
      if (gateAssertions && recordedFailures.length > 0) {
        const fails = recordedFailures
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
      writeFileSync(join(runDir, pngRel), hit.png);
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
    const html = readFileSync(req.htmlPath, "utf8");
    // Emulated families (and images=off) rewrite the HTML before
    // setContent; the provenance above records the chain.
    const effective = applyChain(chain, html, req.scheme);
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
      meta.timing_ms = {
        total: timing.total_ms,
        capture: 0,
        setcontent: timing.setcontent_ms,
        settle: timing.settle_ms,
      };
      meta.network = network();
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
      meta.network = network();
      meta.status = "failed";
      meta.fail_reason =
        `Tier-3 DOM assertion(s) failed (--assert): ` +
        failedChecks.map((a) => `${a.check}: ${a.detail}`).join("; ");
      return finish("failed", null, meta, meta.fail_reason as string);
    }
    const pngAbs = join(runDir, pngRel);
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
    meta.network = network();
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

export interface StoryManifest {
  stories: { story: string; eml: string; html: string; mime_sha256?: string }[];
}

export interface RunJson {
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
    const newest = cands[0];
    if (newest === undefined) return null;
    const manifest = JSON.parse(
      readFileSync(join(newest.dir, "manifest.json"), "utf8"),
    ) as StoryManifest;
    const runJson = JSON.parse(
      readFileSync(join(newest.dir, "run.json"), "utf8"),
    ) as RunJson;
    return { dir: newest.dir, manifest, runJson };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const tMain = Date.now();
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

  // Per-step wall times for run.json (recorded, never asserted).
  const steps: Record<string, number> = {};

  // Step 1: build the stories with the working-tree library.
  const tBuild = Date.now();
  const built = spawnSync(opt.driver, [runDir, ...opt.stories], {
    cwd: repoRoot,
    stdio: ["ignore", "inherit", "inherit"],
  });
  if (built.status !== 0)
    fail(`story driver exited with status ${built.status}`);
  steps.build_stories = Date.now() - tBuild;
  const manifest = JSON.parse(
    readFileSync(join(runDir, "manifest.json"), "utf8"),
  ) as StoryManifest;

  // Affected selection: explicit CLI stories win; --full or no
  // previous run captures everything; otherwise stories whose MIME
  // changed (missing previous entry = changed), families/schemes
  // from the git change set.
  const lib = libraryInfo();
  let fullSelection = opt.full;
  let changed: string[] = [];
  const prev = opt.full
    ? null
    : discoverPreviousRun(join(repoRoot, "build", "email-shots"), runDir);
  if (prev === null) {
    fullSelection = true;
  } else {
    try {
      const run: CommandRunner = (cmd) => {
        const r = spawnSync(cmd[0], cmd.slice(1), {
          cwd: repoRoot,
          encoding: "utf8",
        });
        if (r.status !== 0)
          throw new Error(`${cmd.join(" ")} exited with status ${r.status}`);
        return r.stdout as string;
      };
      changed = changedFilesSince(run, prev.runJson.tree_hash, lib.tree_hash);
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
  // Every selected story's MIME changed, so the matrix is never empty:
  // no changed file in this repository (the change came from
  // ../isonim or the Tailwind map) selects every family.
  const families =
    opt.familiesExplicit || fullSelection
      ? opt.families
      : familiesForChange(changed, opt.families);
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
  const tBriefs = Date.now();
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

  steps.briefs = Date.now() - tBriefs;

  const pw = await loadPlaywright();
  const session = process.env.EMAIL_SHOTS_SESSION ?? null;

  // The request matrix.
  const requests: Request[] = [];
  for (const m of manifest.stories) {
    if (storySet !== null && !storySet.has(m.story)) continue;
    for (const family of families) {
      const engine = knownFamily(family).engine;
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
  const browsers = new Map<string, Browser>();
  const keys = new Map<string, { engine: string; forced: boolean }>();
  for (const r of requests) {
    // Mirror the skip gate in captureOne: only requests that never
    // reach setContent are excluded from the launch set.
    if (r.scheme === "forced-dark" && r.engine !== "chromium") continue;
    const forced = r.scheme === "forced-dark";
    keys.set(`${r.engine}|${forced ? "forced" : "plain"}`, {
      engine: r.engine,
      forced,
    });
  }
  // Launch options per engine and host: tools/capture/launch.ts
  // (Linux keeps Playwright's defaults; macOS daemon sessions need a
  // keychain-free, GPU-free Firefox profile).
  const tLaunch = Date.now();
  for (const [key, { engine, forced }] of keys) {
    const mode = forced ? "forced" : "plain";
    const launchOpts = launchOptions(
      engine,
      forced,
      process.platform,
      process.env,
    );
    try {
      browsers.set(key, await browserType(pw, engine).launch(launchOpts));
    } catch (err) {
      for (const b of browsers.values()) await b.close().catch(() => {});
      fail(
        `launching ${engine} (${mode}) on ${process.platform} failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }
  steps.launch = Date.now() - tLaunch;
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
  const blockedTotal = new Set<string>();
  const record = (entry: Entry, line: Record<string, unknown>): void => {
    if (Array.isArray(line.blocked))
      for (const u of line.blocked as string[]) blockedTotal.add(u);
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
      const req = requests[cursor++];
      if (req === undefined) return;
      const { entry, line } = await captureOne(
        browsers,
        req,
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
  const tCaptures = Date.now();
  try {
    await Promise.all(
      Array.from({ length: Math.min(limit, requests.length) }, () => worker()),
    );
    await chain;
  } finally {
    for (const b of browsers.values()) await b.close();
  }
  steps.captures = Date.now() - tCaptures;

  // Per-story assertions.json (Tier-3) — one file
  // per story aggregating its captures' recorded assertions, so the
  // checker and reviewers read Tier-3 without opening every
  // provenance. Written even when captures failed (a gated run's
  // evidence is the failures); captures sorted by name — index.json
  // follows worker completion order, which legitimately differs
  // between runs.
  const tAssertions = Date.now();
  for (const story of new Set(index.map((e) => e.story))) {
    const captures = index
      .filter((e) => e.story === story)
      .map((e) => {
        let assertions: unknown = null;
        if (e.meta !== null) {
          try {
            const m: unknown = JSON.parse(
              readFileSync(join(runDir, e.meta), "utf8"),
            );
            assertions =
              isRecord(m) && Array.isArray(m.assertions) ? m.assertions : null;
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

  steps.assertions = Date.now() - tAssertions;

  // Contact sheets after each story's captures complete — sheets are required run artifacts, so a compose failure fails the run.
  const tSheets = Date.now();
  for (const story of new Set(requests.map((r) => r.story))) {
    for (const rel of composeStorySheets(runDir, story))
      process.stderr.write(`email-shots: contact sheet ${rel}\n`);
  }
  steps.sheets = Date.now() - tSheets;

  const counts: Record<string, number> = {};
  for (const e of index) counts[e.status] = (counts[e.status] ?? 0) + 1;

  // Latency: recorded, never asserted. The provider slice covers
  // backend A's captures; per-capture timings stay in each provenance.
  const totalMs = Date.now() - tMain;
  const historyPath = join(
    repoRoot,
    "build",
    "email-shots",
    "latency-history.jsonl",
  );
  const key = selectionKey({
    stories: [...new Set(requests.map((r) => r.story))],
    families,
    viewports: opt.viewports.map((v) => v.name),
    schemes,
    images: opt.images,
    cache: !opt.noCache,
  });
  const verdict = latencyVerdict(readHistory(historyPath), key, totalMs);

  // run.json anchors the next --affected run's change set;
  // always written, from the library state read before capturing.
  writeFileSync(
    join(runDir, "run.json"),
    JSON.stringify(
      {
        run,
        tree_hash: lib.tree_hash,
        commit: lib.commit,
        dirty: lib.dirty,
        date: new Date().toISOString(),
        timing_ms: { total: totalMs, steps },
        providers: {
          a: {
            via: "local",
            requests: requests.length,
            statuses: counts,
            wall_ms: steps.launch + steps.captures,
          },
        },
        latency: {
          key,
          history: relative(repoRoot, historyPath),
          ...verdict,
          recorded: failed === 0,
        },
      },
      null,
      2,
    ) + "\n",
  );

  // Only clean runs feed the median (a failing run's time is not a
  // latency sample).
  if (failed === 0) {
    const entry: HistoryEntry = {
      run,
      date: new Date().toISOString(),
      commit: lib.commit,
      dirty: lib.dirty,
      key,
      requests: requests.length,
      total_ms: totalMs,
      captures_ms: steps.captures,
    };
    try {
      appendHistory(historyPath, entry);
    } catch (err) {
      process.stderr.write(
        `email-shots: could not record latency history at ${historyPath} (${err instanceof Error ? err.message : String(err)})\n`,
      );
    }
  }

  process.stderr.write(
    `email-shots: run ${runDir} — ${index.length} captures ` +
      Object.entries(counts)
        .map(([k, v]) => `${v} ${k}`)
        .join(", ") +
      ` in ${totalMs} ms` +
      (verdict.median_ms !== null
        ? ` (rolling median ${verdict.median_ms} ms over ${verdict.samples} run(s))`
        : ` (${verdict.samples} earlier run(s) of this selection; the median needs ${MIN_SAMPLES})`) +
      "\n",
  );
  if (verdict.warning !== null)
    process.stderr.write(`email-shots: ${verdict.warning}\n`);
  if (blockedTotal.size > 0)
    process.stderr.write(
      `email-shots: blocked ${blockedTotal.size} request(s) outside the fixture host (captures never use the network; see each provenance's network.blocked): ${[...blockedTotal].sort().join(", ")}\n`,
    );
  if (failed > 0) fail(`${failed} capture(s) failed (see ${indexPath})`);
}

main().catch((err) => {
  process.stderr.write(`email-shots: ${err?.stack ?? err}\n`);
  process.exit(1);
});
