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
// Approval state: a story whose baselines are known to be out of
// date and not yet re-approved carries a PENDING-REVIEW file in its
// baseline directory, holding the reason. Tier-2 does not compare
// such a story (its baselines no longer describe an approved state),
// and every run says so: one "awaiting re-approval" line per pending
// story plus the count in the verdict. It is never a silent pass:
// --require-approved turns any pending story into a failure (for
// release gates), --update-baselines leaves pending stories alone,
// and only --approve STORY[,STORY] — after a real review of the
// captures — writes their baselines and removes the marker. The
// canary can never be pending: Tier-1 hashes it on every run.
//
// Exclusions: a variant listed in TIER2_EXCLUDED, with its reason, is
// captured but not compared and has no committed baseline; every run
// names it with the reason and counts it in the verdict.
//
// Usage:
//   node tools/capture/email-capture-ci.ts RUN_DIR [--assert]
//     [--require-approved] [--update-baselines [--approve S,…]]
//     [--baselines DIR]
//   node tools/capture/email-capture-ci.ts --help

import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { diffPng } from "./perceptual.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

export const CANARY_STORY = "canary";
// The stories Tier-1 exact-hashes, every variant of each: a run must
// hold done captures of every one, their baselines carry a .sha256 per
// PNG, and none can await re-approval. Widened only together with
// their approved baselines (tests/baselines/README.md).
export const TIER1_STORIES: readonly string[] = [
  CANARY_STORY,
  // The reference emails that stand for the rest: a receipt left to
  // right, an alert right to left (Arabic) and a login code in CJK
  // (Japanese).
  "receiptTypical",
  "alertArabic",
  "securityCodeJapanese",
];
export const TIER2_MAX_DIFF_RATIO = 0.001;

// Variants Tier-2 does not compare, each with its reason: their
// captures are still made (and reviewed in-session), but no baseline
// is committed for them. Never silent: every run names each excluded
// variant it holds, with the reason, and counts them in the verdict;
// --update-baselines does not write them; a baseline committed for one
// anyway is a failure (it would go stale unchecked). A Tier-1 story
// cannot be excluded.
export const OVER_FILE_LIMIT = "baseline over the repository's 1 MB file limit";
export const TIER2_EXCLUDED: Readonly<Record<string, string>> = {
  // A message near the 90 KB budget is a very long page on a phone:
  // these three full-page captures are 1.5-2.2 MB. Its desktop
  // variants are compared, and its size is checked by the reference
  // set's invariants.
  "digestNearBudget/a-thunderbird-firefox-mobile-light-on": OVER_FILE_LIMIT,
  "digestNearBudget/a-apple-webkit-mobile-light-on": OVER_FILE_LIMIT,
  "digestNearBudget/a-chromium-baseline-chromium-mobile-light-on":
    OVER_FILE_LIMIT,
};
export const PENDING_MARKER = "PENDING-REVIEW";

// Stories whose baselines await re-approval, with the recorded
// reason: every <baselinesDir>/<story>/PENDING-REVIEW. An empty
// marker, or a marker on a Tier-1 story, is refused (throws): a pending
// state must say why, and Tier-1 cannot be suspended.
export function readPendingReview(
  baselinesDir: string,
  tier1: readonly string[] = TIER1_STORIES,
): Map<string, string> {
  const pending = new Map<string, string>();
  if (!existsSync(baselinesDir)) return pending;
  for (const e of readdirSync(baselinesDir, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const marker = join(baselinesDir, e.name, PENDING_MARKER);
    if (!existsSync(marker)) continue;
    const reason = readFileSync(marker, "utf8").trim();
    if (reason.length === 0)
      throw new Error(
        `capture-ci: ${marker} is empty — a pending review must record why the baselines are out of date`,
      );
    if (tier1.includes(e.name))
      throw new Error(
        `capture-ci: ${marker} — ${e.name === CANARY_STORY ? "the canary" : e.name} is Tier-1 and can never await re-approval`,
      );
    pending.set(e.name, reason);
  }
  return pending;
}

// One line per pending story present in the run: how many of its
// done captures Tier-2 did not compare, and why.
export function tier2Pending(runDir: string, baselinesDir: string): string[] {
  const pending = readPendingReview(baselinesDir);
  const counts = new Map<string, number>();
  for (const e of doneEntries(readIndex(runDir)))
    if (pending.has(e.story))
      counts.set(e.story, (counts.get(e.story) ?? 0) + 1);
  return [...counts.keys()]
    .sort()
    .map(
      (story) =>
        `capture-ci: Tier-2 ${story} awaiting re-approval — ${counts.get(story)} capture(s) not compared (${pending.get(story)})`,
    );
}

// Refuses an exclusion of a Tier-1 variant (Tier-1 hashes every one).
function checkExclusions(
  excluded: Readonly<Record<string, string>>,
  tier1: readonly string[],
): void {
  for (const [variant, reason] of Object.entries(excluded)) {
    const story = variant.slice(0, variant.indexOf("/"));
    if (tier1.includes(story))
      throw new Error(
        `capture-ci: ${variant} is Tier-1 and cannot be excluded from the baselines`,
      );
    if (reason.trim().length === 0)
      throw new Error(
        `capture-ci: the exclusion of ${variant} gives no reason`,
      );
  }
}

// One line per excluded variant the run holds: not compared, and why.
export function tier2Excluded(
  runDir: string,
  excluded: Readonly<Record<string, string>> = TIER2_EXCLUDED,
): string[] {
  checkExclusions(excluded, TIER1_STORIES);
  return doneEntries(readIndex(runDir))
    .map(variantOf)
    .filter((v) => excluded[v] !== undefined)
    .sort()
    .map(
      (v) => `capture-ci: Tier-2 excludes ${v} — not compared (${excluded[v]})`,
    );
}

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

// Tier-1: exact sha256 of each done PNG of the Tier-1 stories vs the
// checked-in .sha256 files. Returns one message per failing variant
// (empty = pass); throws when the run holds no done capture of one of
// the stories (a vacuous pass).
export function tier1Check(
  runDir: string,
  baselinesDir: string,
  stories: readonly string[] = TIER1_STORIES,
): string[] {
  const done = doneEntries(readIndex(runDir));
  for (const story of stories)
    if (!done.some((e) => e.story === story))
      throw new Error(
        `capture-ci: Tier-1 found no done ${story === CANARY_STORY ? "canary" : story} captures in ${runDir} — refusing a vacuous pass`,
      );
  const hashed = done.filter((e) => stories.includes(e.story));
  const failures: string[] = [];
  for (const entry of hashed) {
    const variant = variantOf(entry);
    const pngPath = join(runDir, entry.png as string);
    let want: string;
    try {
      want = readBaselineHash(
        join(
          baselinesDir,
          entry.story,
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
// Stories awaiting re-approval (PENDING-REVIEW) are not compared;
// tier2Pending reports them.
export function tier2Check(
  runDir: string,
  baselinesDir: string,
  excluded: Readonly<Record<string, string>> = TIER2_EXCLUDED,
): string[] {
  checkExclusions(excluded, TIER1_STORIES);
  const entries = doneEntries(readIndex(runDir));
  if (entries.length === 0)
    throw new Error(
      `capture-ci: Tier-2 found no done captures in ${runDir} — refusing a vacuous pass`,
    );
  const pending = readPendingReview(baselinesDir);
  const failures: string[] = [];
  for (const entry of entries) {
    if (pending.has(entry.story)) continue;
    const variant = variantOf(entry);
    const baseline = join(
      baselinesDir,
      entry.story,
      basename(entry.png as string),
    );
    if (excluded[variant] !== undefined) {
      if (existsSync(baseline))
        failures.push(
          `capture-ci: Tier-2 excludes ${variant} (${excluded[variant]}) but ${baseline} exists — delete it or drop the exclusion`,
        );
      continue;
    }
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// A capture's recorded assertions. Absent or null means none were
// recorded (the run predates Tier-3 for it, or the capture failed
// before the checks — email-shots writes null then) and yields [];
// any other non-array value is not a list of results, and yields null
// so the caller reports it instead of passing it as empty.
function recordedAssertions(cap: Record<string, unknown>): unknown[] | null {
  const value = cap.assertions;
  if (value === undefined || value === null) return [];
  return Array.isArray(value) ? value : null;
}

// Tier-3 (--assert only): every story's assertions.json (written
// by email-shots for every story in the index, even when its
// captures failed) must record no failed DOM assertion, axe-core's
// included (axe.ts). pass:null (a check recorded as not run) never
// fails. Returns one
// message per failing assertion or unreadable record (empty = pass);
// throws when the run holds no stories at all.
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
    let file: unknown;
    try {
      file = JSON.parse(readFileSync(path, "utf8"));
    } catch (err) {
      failures.push(
        `capture-ci: Tier-3 cannot parse ${story}/assertions.json (${err instanceof Error ? err.message : String(err)})`,
      );
      continue;
    }
    if (!isRecord(file) || !Array.isArray(file.captures)) {
      failures.push(
        `capture-ci: Tier-3 ${story}/assertions.json has no captures array — nothing was recorded to check`,
      );
      continue;
    }
    // email-shots records one entry per capture of the story in the
    // index, so a story in the index always has at least one: an
    // empty list checked nothing and is not a pass.
    if (file.captures.length === 0) {
      failures.push(
        `capture-ci: Tier-3 ${story}/assertions.json records no captures — nothing was recorded to check`,
      );
      continue;
    }
    for (const [i, cap] of (file.captures as unknown[]).entries()) {
      // A captures entry that is not an object records nothing
      // checkable: a named failure, never read as "none recorded".
      if (!isRecord(cap)) {
        failures.push(
          `capture-ci: Tier-3 ${story}/assertions.json captures[${i}] is not a capture record — its results cannot be checked`,
        );
        continue;
      }
      const capture = String(cap.capture);
      const assertions = recordedAssertions(cap);
      if (assertions === null) {
        failures.push(
          `capture-ci: Tier-3 ${story}/assertions.json capture ${capture} has an assertions field that is not a list — its results cannot be checked`,
        );
        continue;
      }
      for (const [j, a] of assertions.entries()) {
        // A result is an object whose pass is true, false or null
        // (null: recorded as not run); anything else is not
        // a result, and is reported rather than skipped as a pass.
        if (
          !isRecord(a) ||
          (a.pass !== true && a.pass !== false && a.pass !== null)
        ) {
          failures.push(
            `capture-ci: Tier-3 ${story}/assertions.json capture ${capture} assertions[${j}] is not a result with a pass of true, false or null — it cannot be checked`,
          );
          continue;
        }
        if (a.pass === false)
          failures.push(
            `capture-ci: Tier-3 ${String(a.check)} failed for ${story}/${capture}: ${String(a.detail)}`,
          );
      }
    }
  }
  return failures;
}

// --update-baselines: copy every done capture's PNG into the
// baselines tree and (re)write the Tier-1 stories' .sha256 files from
// the same bytes. Adds and overwrites; never prunes stale variants.
// Excluded variants (TIER2_EXCLUDED) are never written.
// Stories awaiting re-approval are skipped unless named in
// `approve`: approving writes their baselines and removes the
// PENDING-REVIEW marker. Naming a story that is not pending is
// refused, so an approval list cannot go stale silently.
export function updateBaselines(
  runDir: string,
  baselinesDir: string,
  approve: string[] = [],
  tier1: readonly string[] = TIER1_STORIES,
  excluded: Readonly<Record<string, string>> = TIER2_EXCLUDED,
): {
  pngs: number;
  hashes: number;
  skipped: string[];
  approved: string[];
  excluded: string[];
} {
  checkExclusions(excluded, tier1);
  const entries = doneEntries(readIndex(runDir));
  if (entries.length === 0)
    throw new Error(
      `capture-ci: no done captures in ${runDir} — refusing to write baselines from an empty run`,
    );
  const pending = readPendingReview(baselinesDir, tier1);
  const inRun = new Set(entries.map((e) => e.story));
  for (const story of approve) {
    if (!pending.has(story))
      throw new Error(
        `capture-ci: --approve ${story}: that story is not awaiting re-approval`,
      );
    if (!inRun.has(story))
      throw new Error(
        `capture-ci: --approve ${story}: the run holds no done captures of it`,
      );
  }
  const approved = new Set<string>();
  const skipped = new Set<string>();
  const notWritten: string[] = [];
  let pngs = 0;
  let hashes = 0;
  for (const entry of entries) {
    if (excluded[variantOf(entry)] !== undefined) {
      notWritten.push(variantOf(entry));
      continue;
    }
    if (pending.has(entry.story) && !approve.includes(entry.story)) {
      skipped.add(entry.story);
      continue;
    }
    if (pending.has(entry.story)) approved.add(entry.story);
    const bytes = readFileSync(join(runDir, entry.png as string));
    const storyDir = join(baselinesDir, entry.story);
    mkdirSync(storyDir, { recursive: true });
    const file = basename(entry.png as string);
    writeFileSync(join(storyDir, file), bytes);
    pngs++;
    if (tier1.includes(entry.story)) {
      const hex = createHash("sha256").update(bytes).digest("hex");
      writeFileSync(
        join(storyDir, `${basename(file, ".png")}.sha256`),
        `${hex}  ${file}\n`,
      );
      hashes++;
    }
  }
  for (const story of approved)
    rmSync(join(baselinesDir, story, PENDING_MARKER));
  return {
    pngs,
    hashes,
    skipped: [...skipped].sort(),
    approved: [...approved].sort(),
    excluded: notWritten.sort(),
  };
}

const USAGE = `usage: email-capture-ci RUN_DIR [--assert] [--require-approved]
                      [--update-baselines [--approve S,…]] [--baselines DIR]

options:
  --assert             also run Tier-3 over the run's assertions.json
                        files (any recorded DOM-assertion failure fails)
  --require-approved   fail when any story awaits re-approval
                        (a PENDING-REVIEW marker in its baseline dir)
  --update-baselines   regenerate tests/baselines/ from RUN_DIR instead of
                        checking (end-of-session approval only); stories
                        awaiting re-approval are left alone
  --approve S,…        with --update-baselines: also write these pending
                        stories' baselines and clear their markers (only
                        after a real review of the captures)
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
  let requireApproved = false;
  let approve: string[] = [];
  let baselinesDir = join(repoRoot, "tests", "baselines");
  // One iterator: a flag's value is the element after it.
  const args = argv.values();
  for (const arg of args) {
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
    if (arg === "--require-approved") {
      requireApproved = true;
      continue;
    }
    if (arg === "--approve") {
      const value = args.next().value;
      if (value === undefined)
        fail(`capture-ci: flag '--approve' needs a value\n${USAGE}`);
      approve = value.split(",").filter((v) => v.length > 0);
      continue;
    }
    if (arg === "--baselines") {
      const value = args.next().value;
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
  if (approve.length > 0 && !update)
    fail(`capture-ci: --approve only works with --update-baselines\n${USAGE}`);

  if (update) {
    let result: ReturnType<typeof updateBaselines>;
    try {
      result = updateBaselines(runDir, baselinesDir, approve);
    } catch (err) {
      fail(err instanceof Error ? err.message : String(err));
    }
    for (const variant of result.excluded)
      process.stdout.write(
        `capture-ci: did not write ${variant} — excluded from the baselines (${TIER2_EXCLUDED[variant]})\n`,
      );
    for (const story of result.skipped)
      process.stdout.write(
        `capture-ci: left ${story} alone — it awaits re-approval (review its captures, then pass --approve ${story})\n`,
      );
    process.stdout.write(
      `capture-ci: wrote ${result.pngs} baseline PNGs + ${result.hashes} Tier-1 hashes to ${baselinesDir} (from ${runDir})${result.approved.length > 0 ? `; approved ${result.approved.join(", ")}` : ""}\n`,
    );
    return;
  }

  let tier1: string[];
  let tier2: string[];
  let pending: string[];
  let excludedLines: string[];
  let tier3: string[] = [];
  try {
    tier1 = tier1Check(runDir, baselinesDir);
    tier2 = tier2Check(runDir, baselinesDir);
    pending = tier2Pending(runDir, baselinesDir);
    excludedLines = tier2Excluded(runDir);
    if (gate) tier3 = tier3Check(runDir);
  } catch (err) {
    fail(err instanceof Error ? err.message : String(err));
  }
  for (const line of [
    ...tier1,
    ...tier2,
    ...pending,
    ...excludedLines,
    ...tier3,
  ])
    process.stdout.write(`${line}\n`);
  const pendingNote =
    pending.length > 0
      ? `; ${pending.length} story(ies) awaiting re-approval, not compared`
      : "";
  const excludedNote =
    excludedLines.length > 0
      ? `; ${excludedLines.length} variant(s) excluded from Tier-2, not compared`
      : "";
  const pendingFail = requireApproved ? pending.length : 0;
  if (
    tier1.length > 0 ||
    tier2.length > 0 ||
    tier3.length > 0 ||
    pendingFail > 0
  )
    fail(
      `capture-ci: FAIL — Tier-1 ${tier1.length} failure(s), Tier-2 ${tier2.length} failure(s), Tier-3 ${tier3.length} failure(s)${requireApproved ? `, ${pendingFail} story(ies) awaiting re-approval (--require-approved)` : pendingNote}${excludedNote} (run at ${runDir})`,
    );
  process.stdout.write(
    `capture-ci: PASS — Tier-1 + Tier-2${gate ? " + Tier-3" : ""} clean${pendingNote}${excludedNote} (run at ${runDir})\n`,
  );
}

const isMain =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;

if (isMain) main();
