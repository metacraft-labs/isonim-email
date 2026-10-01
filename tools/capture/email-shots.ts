#!/usr/bin/env node
// tools/capture/email-shots.ts — email captures through the capture
// providers.
//
// Renders stories through the library in the working tree (via the
// build-stories driver), routes each story × family × viewport ×
// scheme × images request to the capture providers that serve it
// (providers/registry.ts; today the local browser provider, backend A:
// pinned shell browsers, raw or through the gmailWeb/ganga/outlookWeb/
// imagesOff/wordApprox emulations), runs the providers concurrently,
// streams one JSON line per finished capture to stdout, and maintains
// index.json atomically. A provider that is unavailable is named in
// the run summary with its reason; a request no available provider
// can serve fails with that reason. Exits non-zero when any capture
// failed. Captures never use the network: only the story fixture host
// and data: URIs load (fixture_host.ts).
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
import { basename, dirname, join, relative, resolve } from "node:path";
import { composeStorySheets } from "./contact_sheet.ts";
import {
  changedFilesSince,
  type CommandRunner,
  darkNeeded,
  emptyMatrixReason,
  selectRunFamilies,
  type ServedClient,
  workingTreeHash,
} from "./affected.ts";
import {
  appendHistory,
  latencyVerdict,
  MIN_SAMPLES,
  readHistory,
  selectionKey,
  type HistoryEntry,
} from "./latency.ts";
import {
  assessProviders,
  candidateProviders,
  type Entry,
  executePlan,
  type LibraryInfo,
  type MatrixSpec,
  messageMap,
  providerSummaryLines,
  routeRequests,
  servedBackends,
  servedClients,
  servedFamilies,
} from "./providers/harness.ts";
import { BROWSER_FAMILIES } from "./providers/browser_emulation.ts";
import { registeredProviders } from "./providers/registry.ts";
import { installSignalTeardown } from "./providers/services.ts";
import type { Scheme, StoryMessage, ViewportSpec } from "./providers/types.ts";

// The shapes a finished run's readers rely on.
export type {
  AssertionResult,
  Entry,
  Provenance,
} from "./providers/harness.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

// The registered providers, in routing order. Their clients() are
// static, so the CLI validates families and clients against them
// before any provider is asked whether it is available.
const PROVIDERS = registeredProviders();
const FAMILIES = servedFamilies(PROVIDERS);
const CLIENTS = servedClients(PROVIDERS);
const BACKENDS = servedBackends(PROVIDERS);
const SERVED: ServedClient[] = PROVIDERS.flatMap((p) =>
  p.clients().map((c) => ({
    backend: p.backend,
    clientId: c.clientId,
    family: c.family,
  })),
);

const SCHEMES = new Set(["light", "dark", "forced-dark"]);

type Viewport = ViewportSpec;

const MOBILE: Viewport = { name: "mobile", width: 375, dpr: 3 };
const DESKTOP: Viewport = { name: "desktop", width: 800, dpr: 1 };
const NAMED_VIEWPORTS = new Map<string, Viewport>([
  ["mobile", MOBILE],
  ["desktop", DESKTOP],
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isScheme(s: string): s is Scheme {
  return SCHEMES.has(s);
}

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

const USAGE = `usage: email-shots [STORY…] [options]

With no STORY and no --full, a run is --affected: only the stories whose
MIME changed since the previous run, the families the changed modules
declare, and dark added when a colour, token or image changed.

options:
  --backends L,…         the capture providers to route to, by backend label
                        (default: every registered provider): a, the local
                        browser engines with the client emulations, and
                        selfhosted-webmail, Roundcube and SnappyMail on a
                        local mail stack; b, c and d are refused naming
                        the later backends
  --families F,…         apple,thunderbird,chromium-baseline,gmailWeb,ganga,
                        outlookWeb,imagesOff,wordApprox, and verification
                        (the real verification clients: roundcube,
                        snappymail) (default: all, or the affected ones on
                        an --affected run)
  --clients C,…          filter by client id; backend A's clients are its
                        engines: chromium,webkit,firefox; the webmail
                        clients are roundcube,snappymail. On an --affected
                        run a named client whose families the change did
                        not select gets all of them (so --clients
                        roundcube captures Roundcube after any change);
                        an explicit --backends does the same for its
                        clients
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
  --cold                 a fresh client and profile for every capture;
                        without it providers keep their clients warm
                        between the captures of this run (never across
                        runs). Backend a starts a fresh browser context per
                        capture either way, so it renders the same
  --help                 this text

not yet served (refused with a reason): --async, --follow, --via.
Each request goes to every available provider that serves its family.
A provider that is unavailable (a missing tool, an unsupported host) is
named in the run summary with its reason; a request no available
provider serves fails with that reason.
Captures never use the network: requests other than the story fixture
host and data: URIs (for a webmail: its own loopback origin and the
local assets service) are blocked and listed in the run summary and in
each capture's provenance (network.blocked).
Review briefs are written for the backend-a families only.
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
  backendsExplicit: boolean;
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
  cold: boolean;
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
    backends: [...BACKENDS],
    backendsExplicit: false,
    families: [...FAMILIES],
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
    cold: false,
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
      arg === "--assert" ||
      arg === "--cold"
    ) {
      if (arg === "--affected") opt.affected = true;
      else if (arg === "--full") opt.full = true;
      else if (arg === "--no-cache") opt.noCache = true;
      else if (arg === "--cold") opt.cold = true;
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
        opt.backendsExplicit = true;
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
  const served = `served today: ${BACKENDS.join(", ")}`;
  for (const b of opt.backends) {
    if (BACKENDS.includes(b)) continue;
    if (b === "b") failUsage(`backend B (webmail) lands later (${served})`);
    if (b === "c")
      failUsage(`backend C (native clients) lands later (${served})`);
    if (b === "d")
      failUsage(`backend D (Mailgun Inspect) lands later (${served})`);
    failUsage(`unknown backend '${b}' (${served}; b, c and d land later)`);
  }
  // Array membership, not `in`: an Object.prototype member name
  // ("constructor", "toString") is no family or client.
  for (const f of opt.families) {
    if (FAMILIES.includes(f)) continue;
    failUsage(
      `family '${f}' is not a family any capture provider serves (served: ${FAMILIES.join(", ")})`,
    );
  }
  if (opt.clients !== null)
    for (const c of opt.clients)
      if (!CLIENTS.includes(c))
        failUsage(
          `unknown client '${c}' (no capture provider serves it; served: ${CLIENTS.join(", ")})`,
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
// Provenance helpers (adapted for backend A)
// ---------------------------------------------------------------------------

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
  // ../isonim or the Tailwind map) selects every family. An explicit
  // --clients/--backends adds the families the change cannot select
  // (the verification clients'), see selectRunFamilies.
  const { families, source: familySource } = selectRunFamilies({
    served: SERVED,
    families: opt.families,
    familiesExplicit: opt.familiesExplicit,
    full: fullSelection,
    changedFiles: changed,
    clients: opt.clients,
    backends: opt.backendsExplicit ? opt.backends : null,
  });
  const schemes =
    opt.schemesExplicit || fullSelection
      ? opt.schemes
      : darkNeeded(changed)
        ? ["light", "dark"]
        : ["light"];

  // Step 1b: review briefs for the selected
  // matrix — brief-<family>-<viewport>-<scheme>.md per story dir,
  // written before any capture so reviewers start with the briefs.
  // Briefs describe what backend a's families are expected to show;
  // the real clients of the other providers get none (yet).
  const viewportNames = opt.viewports.map((v) => v.name).join(",");
  const briefFamilies = families.filter((f) =>
    Object.hasOwn(BROWSER_FAMILIES, f),
  );
  const tBriefs = Date.now();
  for (const m of manifest.stories) {
    if (storySet !== null && !storySet.has(m.story)) continue;
    if (briefFamilies.length === 0) break;
    const briefed = spawnSync(
      opt.briefDriver,
      [
        m.story,
        join(runDir, m.story),
        briefFamilies.join(","),
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

  const session = process.env.EMAIL_SHOTS_SESSION ?? null;

  // The selected stories' messages: the MIME bytes and the rendered HTML
  // part, read once and handed to every provider.
  const selected = manifest.stories.filter(
    (m) => storySet === null || storySet.has(m.story),
  );
  if (selected.length === 0) {
    // Zero stories after MIME-diff selection is a clean no-op (nothing
    // changed since the previous run), not a failure.
    process.stdout.write("email-shots: nothing to capture\n");
    process.exit(0);
  }
  const storyMessages: StoryMessage[] = selected.map((m) => ({
    story: m.story,
    mime: readFileSync(join(runDir, m.eml)),
    html: readFileSync(join(runDir, m.html), "utf8"),
  }));
  const messages = messageMap(storyMessages);
  const spec: MatrixSpec = {
    stories: selected.map((m) => ({
      story: m.story,
      mimeSha256: sha256File(join(runDir, m.eml)),
    })),
    families,
    clients: opt.clients,
    backends: opt.backends,
    viewports: opt.viewports,
    schemes: schemes.filter(isScheme),
    images: opt.images.filter((g) => g === "on" || g === "off"),
  };

  // Availability of every provider the matrix could route to, checked
  // concurrently (requirements first, then health), then the shared
  // services the available ones declare, started once each. An
  // unavailable provider is named at once, and again in the run summary.
  const candidates = candidateProviders(PROVIDERS, spec);
  // From here on, SIGINT/SIGTERM stop the shared services before exiting.
  installSignalTeardown();
  const { availability, services } = await assessProviders(candidates, {
    run,
    runDir,
  });
  for (const p of candidates) {
    const h = availability.get(p.id);
    if (h !== undefined && h.state !== "ok")
      process.stderr.write(
        `email-shots: provider ${p.id} (backend ${p.backend}) ${h.state === "unavailable" ? "UNAVAILABLE" : "DEGRADED"}: ${h.reason}\n`,
      );
  }

  const plan = routeRequests(PROVIDERS, availability, spec);
  if (plan.items.length === 0) {
    await services.stopAll();
    fail(
      emptyMatrixReason(
        SERVED,
        families,
        familySource,
        opt.backends,
        opt.clients,
      ),
    );
  }

  // Steps 2+4: every provider runs at once, in-process; one JSON line
  // per finished capture on stdout; index.json rewritten atomically.
  const cacheRoot = join(repoRoot, "build", "email-shots", ".cache");
  const index: Entry[] = [];
  const indexPath = join(runDir, "index.json");
  const writeIndex = (): void => {
    const tmp = `${indexPath}.tmp`;
    writeFileSync(tmp, JSON.stringify(index, null, 2) + "\n");
    renameSync(tmp, indexPath);
  };
  writeIndex();
  const blockedTotal = new Set<string>();
  let failed = 0;
  const tCaptures = Date.now();
  const reports = await executePlan(
    PROVIDERS,
    availability,
    plan,
    messages,
    {
      run,
      session,
      runDir,
      library: lib,
      cacheRoot,
      noCache: opt.noCache,
      assert: opt.assert,
      cold: opt.cold,
      services,
    },
    ({ entry, line }) => {
      if (entry.status === "failed") failed++;
      if (Array.isArray(line.blocked))
        for (const u of line.blocked as string[]) blockedTotal.add(u);
      index.push(entry);
      writeIndex();
      process.stdout.write(JSON.stringify(line) + "\n");
    },
  );
  const providersWall = Date.now() - tCaptures;
  // Provider warm-up (browser launches) and the captures themselves:
  // providers run concurrently, so warm-up is the longest prepare.
  steps.launch = Math.max(0, ...reports.map((r) => r.prepare_ms));
  steps.captures = Math.max(0, providersWall - steps.launch);
  const requests = plan.items.map((i) => i.request);

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
    cold: opt.cold,
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
        providers: Object.fromEntries(
          reports.map((r) => [
            r.id,
            {
              backend: r.backend,
              version: r.version,
              via: r.via,
              cold: r.cold,
              health: r.health,
              reason: r.reason,
              requests: r.requests,
              served_elsewhere: r.served_elsewhere,
              statuses: r.statuses,
              prepare_ms: r.prepare_ms,
              wall_ms: r.wall_ms,
            },
          ]),
        ),
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
  // The providers: each one's outcome, and every unavailable one with
  // its reason — never a silent skip.
  for (const l of providerSummaryLines(reports))
    process.stderr.write(`email-shots: ${l}\n`);
  if (failed > 0) fail(`${failed} capture(s) failed (see ${indexPath})`);
}

main().catch((err) => {
  process.stderr.write(`email-shots: ${err?.stack ?? err}\n`);
  process.exit(1);
});
