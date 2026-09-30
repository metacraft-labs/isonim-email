// tools/capture/affected.ts — derive the capture set from the change.
//
// Choosing what to capture in an iteration: capturing every
// story × family × viewport × scheme on every iteration would waste both time
// and reviewer capacity, so `just email-shots --affected` derives the capture
// set from the change. This module is the families/schemes half of that: the
// stories half is an exact MIME-hash comparison done by the Nim driver.

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const defaultRepoRoot = resolve(
  dirname(new URL(import.meta.url).pathname),
  "..",
  "..",
);

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

// The library's ClientFamily enum (src/isonim_email/target.nim), by
// family id: the cf-prefixed Nim name with the prefix dropped and the
// first letter lowered.
export const CLIENT_FAMILIES = [
  "apple",
  "gmailWeb",
  "gmailApp",
  "ganga",
  "outlookWord",
  "outlookWeb",
  "outlookApp",
  "yahoo",
  "samsung",
  "thunderbird",
  "proton",
  "fastmail",
  "hey",
];

// Where the per-module declarations live. Each module under it declares
//   const affects*: set[ClientFamily] = <expr>
// with <expr> built from `allFamilies`, set literals of cf-names
// (`{cfOutlookWord}`, `{}`) and `+` / `-`. The client reads the
// declarations; it keeps no table of its own.
export const MODULE_ROOT = "src/isonim_email/";

const DECL_RE =
  /^const\s+affects\*\s*(?::\s*set\[\s*ClientFamily\s*\])?\s*=\s*(.+?)\s*(?:#.*)?$/m;

// Parses one module's declaration. null when the module declares none;
// throws when the expression is outside the grammar above (a
// declaration the client would misread must fail loudly).
export function parseAffects(source: string): string[] | null {
  const m = DECL_RE.exec(source);
  if (m === null) return null;
  const expr = m[1];
  const tokens = expr.match(/allFamilies|\{[^{}]*\}|[+-]|\S+/g) ?? [];
  const term = (tok: string | undefined): Set<string> => {
    if (tok === "allFamilies") return new Set(CLIENT_FAMILIES);
    if (tok !== undefined && tok.startsWith("{") && tok.endsWith("}")) {
      const out = new Set<string>();
      for (const raw of tok.slice(1, -1).split(",")) {
        const name = raw.trim();
        if (name === "") continue;
        const id = /^cf([A-Z]\w*)$/.exec(name);
        const fam = id === null ? "" : id[1][0].toLowerCase() + id[1].slice(1);
        if (!CLIENT_FAMILIES.includes(fam))
          throw new Error(`affects: unknown family '${name}' in '${expr}'`);
        out.add(fam);
      }
      return out;
    }
    throw new Error(`affects: cannot read '${expr}' (at '${tok ?? ""}')`);
  };
  let acc = term(tokens[0]);
  for (let i = 1; i < tokens.length; i += 2) {
    const op = tokens[i];
    const rhs = term(tokens[i + 1]);
    if (op === "+") for (const f of rhs) acc.add(f);
    else if (op === "-") for (const f of rhs) acc.delete(f);
    else throw new Error(`affects: cannot read '${expr}' (at '${op}')`);
  }
  return CLIENT_FAMILIES.filter((f) => acc.has(f));
}

// Client families → backend-A families. Each audience family with a
// backend-A stand-in maps to it (outlookWord's is the wordApprox
// approximation). chromium-baseline and imagesOff render the message as
// a standards engine sees it (imagesOff with images blocked), so they
// follow every family except outlookWord — Word renders none of what a
// standards engine does.
export function backendAFamilies(clientFamilies: string[]): string[] {
  const wanted = new Set<string>();
  for (const f of clientFamilies) {
    if (f === "outlookWord") wanted.add("wordApprox");
    else {
      if (BACKEND_A_FAMILIES.includes(f)) wanted.add(f);
      wanted.add("chromium-baseline");
      wanted.add("imagesOff");
    }
  }
  return BACKEND_A_FAMILIES.filter((f) => wanted.has(f));
}

// The client families one changed path can affect: its own declaration
// for a module under MODULE_ROOT, every family for anything else (the
// umbrella, tests, stories, tools) and for a module that no longer
// exists or declares nothing (the safe side; affected.test.ts requires
// every module to declare).
export function pathAffects(
  path: string,
  repoRoot: string = defaultRepoRoot,
): string[] {
  if (!path.startsWith(MODULE_ROOT) || !path.endsWith(".nim"))
    return [...CLIENT_FAMILIES];
  const file = join(repoRoot, path);
  if (!existsSync(file)) return [...CLIENT_FAMILIES];
  return parseAffects(readFileSync(file, "utf8")) ?? [...CLIENT_FAMILIES];
}

// Union of the declared families over every changed file, as backend-A
// families in BACKEND_A_FAMILIES order.
export function selectFamilies(
  changedFiles: string[],
  repoRoot: string = defaultRepoRoot,
): string[] {
  const clientFamilies = new Set<string>();
  for (const f of changedFiles)
    for (const fam of pathAffects(f, repoRoot)) clientFamilies.add(fam);
  return backendAFamilies([...clientFamilies]);
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
  repoRoot: string = defaultRepoRoot,
): string[] {
  const selected = selectFamilies(changedFiles, repoRoot).filter((f) =>
    all.includes(f),
  );
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
