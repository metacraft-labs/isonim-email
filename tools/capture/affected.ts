// tools/capture/affected.ts — derive the capture set from the change.
//
// Choosing what to capture in an iteration: capturing every
// story × family × viewport × scheme on every iteration would waste both time
// and reviewer capacity, so `just email-shots --affected` derives the capture
// set from the change. This module is the families/schemes half of that: the
// stories half is an exact MIME-hash comparison done by the Nim driver.

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type AffectSet = "OUTLOOK_WORD" | "HEAD" | "ALL";

// Single-table form of the per-module affects, same semantics.
// Matched by longest prefix; anything matching no row selects ALL.
export const MODULE_AFFECTS: [prefix: string, set: AffectSet][] = [
  ["src/isonim_email/mso/", "OUTLOOK_WORD"],
  ["src/isonim_email/passes/head.nim", "HEAD"],
  ["src/isonim_email/style/css.nim", "HEAD"],
  ["src/isonim_email/style/classes.nim", "HEAD"],
  ["src/", "ALL"],
];

export const BACKEND_A_FAMILIES = [
  "apple",
  "thunderbird",
  "chromium-baseline",
  "gmailWeb",
  "ganga",
  "outlookWeb",
  "imagesOff",
  "wordApprox",
];

export function mapAffectSet(s: AffectSet): string[] {
  switch (s) {
    // "A change under `src/isonim_email/mso/` affects only `outlookWord`."
    // (wordApprox is backend A's approximation family for Word.)
    case "OUTLOOK_WORD":
      return ["wordApprox"];
    // "A head-CSS change affects every family that honours head CSS, and
    // `ganga` is affected by inline changes only."
    case "HEAD":
      return BACKEND_A_FAMILIES.filter((f) => f !== "ganga");
    // "Changes to shared passes select all families."
    case "ALL":
      return [...BACKEND_A_FAMILIES];
  }
}

function matchSet(path: string): AffectSet {
  let best: AffectSet | null = null;
  let bestLen = -1;
  for (const [prefix, set] of MODULE_AFFECTS) {
    if (path.startsWith(prefix) && prefix.length > bestLen) {
      best = set;
      bestLen = prefix.length;
    }
  }
  return best ?? "ALL";
}

// Union of the mapped families over every changed file; unmatched paths
// select ALL. Returned in BACKEND_A_FAMILIES order.
export function selectFamilies(changedFiles: string[]): string[] {
  const wanted = new Set<string>();
  for (const f of changedFiles) {
    for (const fam of mapAffectSet(matchSet(f))) wanted.add(fam);
  }
  return BACKEND_A_FAMILIES.filter((f) => wanted.has(f));
}

// "Dark is added when a colour, token or image changed."
export function darkNeeded(changedFiles: string[]): boolean {
  return changedFiles.some((p) => /style\/|tokens|assets|image/.test(p));
}

// The families for a run whose selected stories' MIME changed. A MIME
// change never produces an empty matrix: when no file of this
// repository changed (the change came from ../isonim or the Tailwind
// map), every family in `all` is selected.
export function familiesForChange(
  changedFiles: string[],
  all: string[],
): string[] {
  const selected = selectFamilies(changedFiles);
  return selected.length > 0 ? selected : [...all];
}

// Hash of the working tree INCLUDING uncommitted and untracked changes
// (ignored files excluded): `git add -A` into a temporary index seeded
// from HEAD, then `git write-tree`. The real index is never touched.
// Two runs over the same bytes record the same hash, so a revert
// returns to the earlier hash, and the diff between two recorded
// hashes names exactly the files that changed between the runs.
export function workingTreeHash(repoDir: string): string {
  const dir = mkdtempSync(join(tmpdir(), "email-shots-index-"));
  try {
    const env = { ...process.env, GIT_INDEX_FILE: join(dir, "index") };
    const git = (args: string[]): string =>
      execFileSync("git", args, { cwd: repoDir, env, encoding: "utf8" });
    try {
      git(["read-tree", "HEAD"]);
    } catch {
      // No HEAD yet (an empty repository): start from an empty index.
    }
    git(["add", "-A"]);
    return git(["write-tree"]).trim();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Changed files between two recorded tree hashes (the previous run's
// and this run's), non-empty trimmed lines. The command runner is
// injected so tests can stub it.
export function changedFilesSince(
  run: (cmd: string[]) => string,
  prevTree: string,
  curTree: string,
): string[] {
  const out = run(["git", "diff", "--name-only", prevTree, curTree]);
  const files: string[] = [];
  for (const line of out.split("\n")) {
    const t = line.trim();
    if (t !== "" && !files.includes(t)) files.push(t);
  }
  return files;
}
