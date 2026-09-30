#!/usr/bin/env node
// tools/capture/email-capture-ci.ts — Tier-1 + Tier-2 regression
// checks over an email-shots run dir, plus Tier-3 from the
// recorded assertions with --assert.
//
// Tier-1 exact-hash canary: every done `canary` capture's PNG bytes
// must sha256-match tests/baselines/canary/<variant>.sha256. Tier-2
// perceptual diff: every done capture's PNG must diffPng-match the
// approved tests/baselines/<story>/<variant>.png with a diff ratio
// at or below TIER2_MAX_DIFF_RATIO. Tier-3 (--assert only): every
// story's assertions.json must record no failed DOM assertion. Any
// failure exits 1 naming the variants; a run with no done captures
// fails rather than passing vacuously. --update-baselines
// regenerates both baseline kinds from the run dir (end-of-session
// approval only).
//
// Usage:
//   node tools/capture/email-capture-ci.ts RUN_DIR [--assert]
//     [--update-baselines] [--baselines DIR]
//   node tools/capture/email-capture-ci.ts --help

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { diffPng } from "./perceptual.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

export const CANARY_STORY = "canary";
export const TIER2_MAX_DIFF_RATIO = 0.001;

interface IndexEntry {
  story: string;
  status: string;
  png: string | null;
}

function variantOf(entry: IndexEntry): string {
  return `${entry.story}/${basename(entry.png as string, ".png")}`;
}

function readIndex(runDir: string): IndexEntry[] {
  const path = join(runDir, "index.json");
  if (!existsSync(path))
    throw new Error(`capture-ci: no index.json in ${runDir}`);
  return JSON.parse(readFileSync(path, "utf8")) as IndexEntry[];
}

function doneEntries(index: IndexEntry[]): IndexEntry[] {
  return index.filter((e) => e.status === "done" && e.png !== null);
}

function readBaselineHash(path: string, variant: string): string {
  if (!existsSync(path))
    throw new Error(
      `capture-ci: no Tier-1 baseline for ${variant} (${path} missing) — regenerate with \`just email-capture-ci --update-baselines\``,
    );
  const hex = readFileSync(path, "utf8").split(/\s/, 1)[0] ?? "";
  if (!/^[0-9a-f]{64}$/.test(hex))
    throw new Error(
      `capture-ci: malformed Tier-1 baseline for ${variant} (${path} holds no sha256) — refusing to pass`,
    );
  return hex;
}

// Tier-1: exact sha256 of each done canary PNG vs the checked-in
// .sha256 files. Returns one message per failing variant (empty =
// pass); throws when the run holds no done canary captures at all.
export function tier1Check(runDir: string, baselinesDir: string): string[] {
  const canaries = doneEntries(readIndex(runDir)).filter(
    (e) => e.story === CANARY_STORY,
  );
  if (canaries.length === 0)
    throw new Error(
      `capture-ci: Tier-1 found no done canary captures in ${runDir} — refusing a vacuous pass`,
    );
  const failures: string[] = [];
  for (const entry of canaries) {
    const variant = variantOf(entry);
    const pngPath = join(runDir, entry.png as string);
    let want: string;
    try {
      want = readBaselineHash(
        join(
          baselinesDir,
          CANARY_STORY,
          `${basename(entry.png as string, ".png")}.sha256`,
        ),
        variant,
      );
    } catch (err) {
      failures.push(err instanceof Error ? err.message : String(err));
      continue;
    }
    const got = createHash("sha256")
      .update(readFileSync(pngPath))
      .digest("hex");
    if (got !== want)
      failures.push(
        `capture-ci: Tier-1 hash mismatch for ${variant} (run ${got.slice(0, 12)}… vs baseline ${want.slice(0, 12)}…)`,
      );
  }
  return failures;
}

// Tier-2: every done capture's PNG vs its approved baseline PNG via
// diffPng; fails when diffRatio > TIER2_MAX_DIFF_RATIO. Returns one
// message per failing variant (empty = pass); throws when the run
// holds no done captures at all.
export function tier2Check(runDir: string, baselinesDir: string): string[] {
  const entries = doneEntries(readIndex(runDir));
  if (entries.length === 0)
    throw new Error(
      `capture-ci: Tier-2 found no done captures in ${runDir} — refusing a vacuous pass`,
    );
  const failures: string[] = [];
  for (const entry of entries) {
    const variant = variantOf(entry);
    const baseline = join(
      baselinesDir,
      entry.story,
      basename(entry.png as string),
    );
    if (!existsSync(baseline)) {
      failures.push(
        `capture-ci: Tier-2 has no approved baseline for ${variant} (${baseline} missing) — regenerate with \`just email-capture-ci --update-baselines\``,
      );
      continue;
    }
    let diff: { diffPixels: number; diffRatio: number };
    try {
      diff = diffPng(
        readFileSync(join(runDir, entry.png as string)),
        readFileSync(baseline),
      );
    } catch (err) {
      failures.push(
        `capture-ci: Tier-2 cannot compare ${variant} (${err instanceof Error ? err.message : String(err)})`,
      );
      continue;
    }
    if (diff.diffRatio > TIER2_MAX_DIFF_RATIO)
      failures.push(
        `capture-ci: Tier-2 diff for ${variant} is ${diff.diffRatio.toExponential(2)} (${diff.diffPixels} px) — over the ${TIER2_MAX_DIFF_RATIO} limit`,
      );
  }
  return failures;
}

// Tier-3 (--assert only): every story's assertions.json (written
// by email-shots for every story in the index, even when its
// captures failed) must record no failed DOM assertion. pass:null
// (axe, unpinned — see email-shots.ts) never fails. Returns one
// message per failing assertion (empty = pass); throws when the run
// holds no stories at all.
export function tier3Check(runDir: string): string[] {
  const index = readIndex(runDir);
  const stories = [...new Set(index.map((e) => e.story))].sort();
  if (stories.length === 0)
    throw new Error(
      `capture-ci: Tier-3 found no stories in ${runDir} — refusing a vacuous pass`,
    );
  const failures: string[] = [];
  for (const story of stories) {
    const path = join(runDir, story, "assertions.json");
    if (!existsSync(path)) {
      failures.push(
        `capture-ci: Tier-3 has no assertions.json for ${story} (${path} missing) — the run predates Tier-3 recording`,
      );
      continue;
    }
    let file: { captures?: any[] };
    try {
      file = JSON.parse(readFileSync(path, "utf8"));
    } catch (err) {
      failures.push(
        `capture-ci: Tier-3 cannot parse ${story}/assertions.json (${err instanceof Error ? err.message : String(err)})`,
      );
      continue;
    }
    for (const cap of file.captures ?? []) {
      for (const a of cap?.assertions ?? []) {
        if (a !== null && a !== undefined && a.pass === false)
          failures.push(
            `capture-ci: Tier-3 ${a.check} failed for ${story}/${cap.capture}: ${a.detail}`,
          );
      }
    }
  }
  return failures;
}

// --update-baselines: copy every done capture's PNG into the
// baselines tree and (re)write the canary .sha256 files from the
// same bytes. Adds and overwrites; never prunes stale variants.
export function updateBaselines(
  runDir: string,
  baselinesDir: string,
): { pngs: number; hashes: number } {
  const entries = doneEntries(readIndex(runDir));
  if (entries.length === 0)
    throw new Error(
      `capture-ci: no done captures in ${runDir} — refusing to write baselines from an empty run`,
    );
  let pngs = 0;
  let hashes = 0;
  for (const entry of entries) {
    const bytes = readFileSync(join(runDir, entry.png as string));
    const storyDir = join(baselinesDir, entry.story);
    mkdirSync(storyDir, { recursive: true });
    const file = basename(entry.png as string);
    writeFileSync(join(storyDir, file), bytes);
    pngs++;
    if (entry.story === CANARY_STORY) {
      const hex = createHash("sha256").update(bytes).digest("hex");
      writeFileSync(
        join(storyDir, `${basename(file, ".png")}.sha256`),
        `${hex}  ${file}\n`,
      );
      hashes++;
    }
  }
  return { pngs, hashes };
}

const USAGE = `usage: email-capture-ci RUN_DIR [--assert] [--update-baselines] [--baselines DIR]

options:
  --assert             also run Tier-3 over the run's assertions.json
                        files (any recorded DOM-assertion failure fails)
  --update-baselines   regenerate tests/baselines/ from RUN_DIR instead of
                        checking (end-of-session approval only)
  --baselines DIR      baseline tree (default: tests/baselines)
  --help               this text
`;

function fail(message: string): never {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function main(): void {
  const argv = process.argv.slice(2);
  let runDir: string | null = null;
  let update = false;
  let gate = false;
  let baselinesDir = join(repoRoot, "tests", "baselines");
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      process.stdout.write(USAGE);
      process.exit(0);
    }
    if (arg === "--assert") {
      gate = true;
      continue;
    }
    if (arg === "--update-baselines") {
      update = true;
      continue;
    }
    if (arg === "--baselines") {
      const value = argv[++i];
      if (value === undefined)
        fail(`capture-ci: flag '--baselines' needs a value\n${USAGE}`);
      baselinesDir = resolve(repoRoot, value);
      continue;
    }
    if (arg.startsWith("--"))
      fail(`capture-ci: unknown flag '${arg}'\n${USAGE}`);
    if (runDir !== null) fail(`capture-ci: want exactly one RUN_DIR\n${USAGE}`);
    runDir = resolve(repoRoot, arg);
  }
  if (runDir === null) fail(`capture-ci: missing RUN_DIR\n${USAGE}`);

  if (update) {
    let result: { pngs: number; hashes: number };
    try {
      result = updateBaselines(runDir, baselinesDir);
    } catch (err) {
      fail(err instanceof Error ? err.message : String(err));
    }
    process.stdout.write(
      `capture-ci: wrote ${result.pngs} baseline PNGs + ${result.hashes} canary hashes to ${baselinesDir} (from ${runDir})\n`,
    );
    return;
  }

  let tier1: string[];
  let tier2: string[];
  let tier3: string[] = [];
  try {
    tier1 = tier1Check(runDir, baselinesDir);
    tier2 = tier2Check(runDir, baselinesDir);
    if (gate) tier3 = tier3Check(runDir);
  } catch (err) {
    fail(err instanceof Error ? err.message : String(err));
  }
  for (const line of [...tier1, ...tier2, ...tier3])
    process.stdout.write(`${line}\n`);
  if (tier1.length > 0 || tier2.length > 0 || tier3.length > 0)
    fail(
      `capture-ci: FAIL — Tier-1 ${tier1.length} failure(s), Tier-2 ${tier2.length} failure(s), Tier-3 ${tier3.length} failure(s) (run at ${runDir})`,
    );
  process.stdout.write(
    `capture-ci: PASS — Tier-1 + Tier-2${gate ? " + Tier-3" : ""} clean (run at ${runDir})\n`,
  );
}

const isMain =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;

if (isMain) main();
