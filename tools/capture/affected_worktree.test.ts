// tools/capture/affected_worktree.test.ts — --affected over a real,
// dirtied working tree, in a scratch clone.
//
// The clone is made in the OS temp dir (honours TMPDIR) and removed
// afterwards. It carries this checkout's capture tools as a commit of
// its own, so it runs exactly the code under test, and it is then
// dirtied and reverted for real. It never skips: a clean tree here is
// the starting state, not a reason to stop.
//
// Two halves:
// - workingTreeHash, on real git: an uncommitted edit and an untracked
//   file each change the hash, a revert returns to the original hash,
//   the real index is never touched, and the tree diff between two
//   hashes names exactly the edited file.
// - The CLI, bare runs in the clone: after an edit and after its
//   revert, the run selects the families the edited module declares
//   (never "empty request matrix"), and with no file changed at all
//   it falls back to every family.
//
// One simulated input, justified: a story's MIME is made to "change"
// by rewriting the previous run's recorded mime_sha256 for the canary.
// A real MIME change needs the story driver rebuilt from the edited
// clone (minutes of Nim compiles per edit); the drivers here are this
// checkout's prebuilt ones (`just email-shots-build`), so the rendered
// MIME never changes by itself. The rewrite stands in for exactly the
// case under test — the MIME differs from the previous run's — and
// everything downstream of it (tree hashing, the diff, family
// selection, the captures) is real.
//
// Run with:
//   node --test tools/capture/affected_worktree.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  appendFileSync,
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  BACKEND_A_FAMILIES,
  changedFilesSince,
  workingTreeHash,
} from "./affected.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
const driver = join(repoRoot, "build", "capture", "build-stories");
const briefDriver = join(repoRoot, "build", "review", "brief-driver");
const edited = "src/isonim_email/mso/cond.nim";

let clone = "";

function git(args: string[], cwd = clone): string {
  return execFileSync(
    "git",
    [
      "-c",
      "user.name=capture test",
      "-c",
      "user.email=capture-test@example.invalid",
      "-c",
      "commit.gpgsign=false",
      ...args,
    ],
    { cwd, encoding: "utf8" },
  );
}

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

// A bare run of the clone's CLI with this checkout's drivers.
function bareRun(name: string): {
  status: number;
  stdout: string;
  stderr: string;
  dir: string;
} {
  const dir = join(clone, "build", "email-shots", name);
  const r = spawnSync(
    process.execPath,
    [
      join(clone, "tools", "capture", "email-shots.ts"),
      "--driver",
      driver,
      "--brief-driver",
      briefDriver,
      "--viewports",
      "desktop",
      "--out",
      dir,
    ],
    {
      cwd: clone,
      encoding: "utf8",
      env: { ...process.env, PLAYWRIGHT_CORE_PATH: playwrightCore() },
    },
  );
  return {
    status: r.status ?? 1,
    stdout: r.stdout as string,
    stderr: r.stderr as string,
    dir,
  };
}

function readJson(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
}

// The simulated MIME change (see the header): the canary's recorded
// MIME in the previous run no longer matches.
function forgetCanaryMime(runDir: string): void {
  const path = join(runDir, "manifest.json");
  const manifest = readJson(path);
  let hit = 0;
  for (const s of manifest.stories)
    if (s.story === "canary") {
      s.mime_sha256 = "0".repeat(64);
      hit++;
    }
  assert.equal(hit, 1, "no canary in the previous run's manifest");
  writeFileSync(path, JSON.stringify(manifest, null, 2) + "\n");
}

function families(runDir: string): string[] {
  return [
    ...new Set(
      readJson(join(runDir, "index.json")).map((e: any) => e.family as string),
    ),
  ].sort();
}

describe("--affected over a dirtied working tree (scratch clone)", () => {
  before(() => {
    for (const f of [driver, briefDriver])
      if (!existsSync(f))
        throw new Error(`${f} missing — run \`just email-shots-build\` first`);
    clone = mkdtempSync(join(tmpdir(), "email-shots-worktree-"));
    git(["clone", "--quiet", "--no-hardlinks", repoRoot, clone], repoRoot);
    // The code under test is this checkout's, committed or not.
    rmSync(join(clone, "tools", "capture"), { recursive: true, force: true });
    cpSync(
      join(repoRoot, "tools", "capture"),
      join(clone, "tools", "capture"),
      {
        recursive: true,
        filter: (src) => !src.includes("node_modules"),
      },
    );
    // The story fixture images the prebuilt drivers reference.
    rmSync(join(clone, "tests", "stories", "assets"), {
      recursive: true,
      force: true,
    });
    cpSync(
      join(repoRoot, "tests", "stories", "assets"),
      join(clone, "tests", "stories", "assets"),
      { recursive: true },
    );
    git(["add", "-A"]);
    git([
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "capture tools under test",
    ]);
    assert.equal(git(["status", "--porcelain"]).trim(), "");
  });

  after(() => {
    if (clone !== "") rmSync(clone, { recursive: true, force: true });
  });

  it("hashes the working tree: edits and untracked files count, reverts return", () => {
    const indexBefore = readFileSync(join(clone, ".git", "index"));
    const clean = workingTreeHash(clone);
    assert.equal(clean, git(["rev-parse", "HEAD^{tree}"]).trim());
    const original = readFileSync(join(clone, edited));
    appendFileSync(join(clone, edited), "# scratch edit\n");
    const dirty = workingTreeHash(clone);
    assert.notEqual(dirty, clean);
    // The tree diff names exactly the edited file, both ways.
    const run = (cmd: string[]): string =>
      execFileSync(cmd[0], cmd.slice(1), { cwd: clone, encoding: "utf8" });
    assert.deepEqual(changedFilesSince(run, clean, dirty), [edited]);
    assert.deepEqual(changedFilesSince(run, dirty, clean), [edited]);
    // An untracked file counts too.
    writeFileSync(join(clone, "src", "scratch_untracked.nim"), "discard\n");
    const untracked = workingTreeHash(clone);
    assert.notEqual(untracked, dirty);
    rmSync(join(clone, "src", "scratch_untracked.nim"));
    writeFileSync(join(clone, edited), original);
    assert.equal(workingTreeHash(clone), clean);
    // The real index is untouched throughout.
    assert.deepEqual(readFileSync(join(clone, ".git", "index")), indexBefore);
    assert.equal(git(["status", "--porcelain"]).trim(), "");
  });

  it("bare runs after an edit and after its revert select the edited module's families", () => {
    // Seed: a full run, so the next bare run has a previous run.
    const seed = spawnSync(
      process.execPath,
      [
        join(clone, "tools", "capture", "email-shots.ts"),
        "--full",
        "--driver",
        driver,
        "--brief-driver",
        briefDriver,
        "--families",
        "chromium-baseline",
        "--viewports",
        "desktop",
        "--out",
        join(clone, "build", "email-shots", "run1"),
      ],
      {
        cwd: clone,
        encoding: "utf8",
        env: { ...process.env, PLAYWRIGHT_CORE_PATH: playwrightCore() },
      },
    );
    assert.equal(seed.status, 0, `seed run failed:\n${seed.stderr}`);
    const run1 = join(clone, "build", "email-shots", "run1");
    const cleanTree = readJson(join(run1, "run.json")).tree_hash;

    // Edit: the tree differs, and the Word-only module selects Word.
    const original = readFileSync(join(clone, edited));
    appendFileSync(join(clone, edited), "# scratch edit\n");
    forgetCanaryMime(run1);
    const r2 = bareRun("run2");
    assert.equal(r2.status, 0, `edit run failed:\n${r2.stderr}`);
    const editedTree = readJson(join(r2.dir, "run.json")).tree_hash;
    assert.notEqual(editedTree, cleanTree);
    assert.deepEqual(families(r2.dir), ["wordApprox"]);

    // Revert: the working tree is clean again (HEAD is unchanged
    // throughout), yet the run sees the reverted file.
    writeFileSync(join(clone, edited), original);
    assert.equal(git(["status", "--porcelain"]).trim(), "");
    forgetCanaryMime(r2.dir);
    const r3 = bareRun("run3");
    assert.equal(r3.status, 0, `revert run failed:\n${r3.stderr}`);
    assert.doesNotMatch(r3.stderr, /empty request matrix/);
    assert.equal(readJson(join(r3.dir, "run.json")).tree_hash, cleanTree);
    assert.deepEqual(families(r3.dir), ["wordApprox"]);
    for (const e of readJson(join(r3.dir, "index.json")))
      assert.equal(e.status, "done", JSON.stringify(e));
  });

  it("a MIME change with no changed file selects every family", () => {
    const prev = join(clone, "build", "email-shots", "run3");
    assert.ok(existsSync(prev), "needs the previous test's revert run");
    forgetCanaryMime(prev);
    const r4 = bareRun("run4");
    assert.equal(r4.status, 0, `fallback run failed:\n${r4.stderr}`);
    assert.doesNotMatch(r4.stderr, /empty request matrix/);
    assert.deepEqual(families(r4.dir), [...BACKEND_A_FAMILIES].sort());
    const stories = new Set(
      readJson(join(r4.dir, "index.json")).map((e: any) => e.story),
    );
    assert.deepEqual([...stories], ["canary"]);
  });
});
