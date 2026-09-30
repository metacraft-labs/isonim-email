// tools/capture/affected.ts — derive the capture set from the change.
//
// Choosing what to capture in an iteration: capturing every
// story × family × viewport × scheme on every iteration would waste both time
// and reviewer capacity, so `just email-shots --affected` derives the capture
// set from the change. This module is the families/schemes half of that: the
// stories half is an exact MIME-hash comparison done by the Nim driver.

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

// git status --porcelain v1: the path field of every non-empty line,
// including untracked ('??') entries; surrounding quotes stripped.
export function parsePorcelain(out: string): string[] {
  const files: string[] = [];
  for (const line of out.split("\n")) {
    if (line === "") continue;
    let path = line.slice(3);
    if (path.length >= 2 && path.startsWith('"') && path.endsWith('"')) {
      path = path.slice(1, -1);
    }
    files.push(path);
  }
  return files;
}

// Changed files since the previous iteration's tree: the union of
// `git diff --name-only <prevTree> HEAD` and the working-tree status.
// Non-empty trimmed lines, deduped. The command runner is injected so tests
// can stub it.
export function changedFilesSince(
  run: (cmd: string[]) => string,
  prevTree: string,
): string[] {
  const diffOut = run(["git", "diff", "--name-only", prevTree, "HEAD"]);
  const statusOut = run(["git", "status", "--porcelain"]);
  const seen = new Set<string>();
  const files: string[] = [];
  const add = (p: string) => {
    const t = p.trim();
    if (t !== "" && !seen.has(t)) {
      seen.add(t);
      files.push(t);
    }
  };
  for (const line of diffOut.split("\n")) add(line);
  for (const p of parsePorcelain(statusOut)) add(p);
  return files;
}
