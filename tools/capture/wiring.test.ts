// tools/capture/wiring.test.ts — selection + cache wiring (runs the real CLI).
//
// Hermeticity: previous-run discovery is anchored at
// build/email-shots/ (not configurable), so run1 seeds it with --out
// under a build/email-shots/__wiring__-<pid>-runN dir, removed
// afterwards (flat: discovery only scans direct children).
// The shared result cache (build/email-shots/.cache) is wiped first:
// it is disposable by design, and run1 asserts miss-everywhere, which
// needs a cold cache. The flag-bare run2 needs a dirty tree (a clean
// tree selects no families); it skips itself when the tree is clean.
// The explicit --families hit-path rerun needs no dirt (explicit
// filters bypass affected-selection), so cache-hit wiring is covered
// on clean trees too.
import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

import {
  BACKEND_A_FAMILIES,
  darkNeeded,
  changedFilesSince,
  familiesForChange,
  selectFamilies,
} from "./affected.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
const cli = join(repoRoot, "tools", "capture", "email-shots.ts");
const shotsRoot = join(repoRoot, "build", "email-shots");
const cacheRoot = join(shotsRoot, ".cache");
// Flat dirs directly under shotsRoot: discovery only scans direct
// children, so a nested prefix would be invisible to it.
const runDir = (n: number): string =>
  join(shotsRoot, `__wiring__-${process.pid}-run${n}`);

function runCli(args: string[]): {
  status: number;
  stdout: string;
  stderr: string;
} {
  const r = spawnSync(process.execPath, [cli, ...args], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  return {
    status: r.status ?? 1,
    stdout: r.stdout as string,
    stderr: r.stderr as string,
  };
}

function readJson(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
}

function gitIsDirty(): boolean {
  const out = execFileSync("git", ["status", "--porcelain"], {
    cwd: repoRoot,
    encoding: "utf8",
  }) as string;
  return out.trim().length > 0;
}

// Mirror of the CLI's previous-run discovery: newest run.json under
// build/email-shots/, excluding the given run dir.
function discoverPrev(excludeDir: string): string | null {
  if (!existsSync(shotsRoot)) return null;
  const resolvedEx = resolve(excludeDir);
  const cands: { dir: string; mtime: number }[] = [];
  for (const e of readdirSync(shotsRoot, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const dir = join(shotsRoot, e.name);
    if (resolve(dir) === resolvedEx) continue;
    if (!existsSync(join(dir, "manifest.json"))) continue;
    if (!existsSync(join(dir, "run.json"))) continue;
    cands.push({ dir, mtime: statSync(join(dir, "run.json")).mtimeMs });
  }
  cands.sort((a, b) => b.mtime - a.mtime);
  return cands.length === 0 ? null : cands[0].dir;
}

describe("selection + cache wiring", () => {
  before(() => {
    for (const n of [1, 2, 3, 4, 5, 6])
      rmSync(runDir(n), { recursive: true, force: true });
    rmSync(cacheRoot, { recursive: true, force: true });
    mkdirSync(shotsRoot, { recursive: true });
  });

  after(() => {
    for (const n of [1, 2, 3, 4, 5, 6])
      rmSync(runDir(n), { recursive: true, force: true });
  });

  it("run1 --full captures the canary matrix, all misses", () => {
    const out = runDir(1);
    const r = runCli([
      "canary",
      "--full",
      "--schemes",
      "light,dark",
      "--out",
      relative(repoRoot, runDir(1)),
    ]);
    assert.equal(r.status, 0, `run1 failed:\n${r.stderr}`);
    // --out is repoRoot-anchored; the CLI resolves it the same way.
    assert.ok(existsSync(out), "run1 dir missing");
    const manifest = readJson(join(out, "manifest.json"));
    assert.equal(manifest.stories.length, 1);
    assert.match(manifest.stories[0].mime_sha256, /^[0-9a-f]{64}$/);
    const runJson = readJson(join(out, "run.json"));
    for (const k of ["tree_hash", "commit", "dirty", "date"])
      assert.ok(k in runJson, `run.json missing ${k}`);
    const index = readJson(join(out, "index.json"));
    assert.ok(index.length > 0, "empty run1 index");
    for (const e of index) {
      assert.equal(e.status, "done", JSON.stringify(e));
      const meta = readJson(join(out, e.meta));
      assert.equal(meta.cache, "miss", e.meta);
      assert.ok(existsSync(join(out, e.png)), `missing png for ${e.meta}`);
    }
  });

  it("explicit --families rerun is all hits (runs on clean trees)", () => {
    // Hit-path wiring without dirt: explicit filters bypass
    // affected-selection, so unlike the bare run2 below this never
    // skips. The filter is read back from run1's own index, so the
    // requested captures are exactly the ones run1 just cached
    // (same story, same MIME, same defaults).
    const first = readJson(join(runDir(1), "index.json"))[0];
    const out = runDir(6);
    const r = runCli([
      "canary",
      "--families",
      first.family,
      "--viewports",
      first.viewport,
      "--schemes",
      first.scheme,
      "--out",
      relative(repoRoot, out),
    ]);
    assert.equal(r.status, 0, `hit-path rerun failed:\n${r.stderr}`);
    const index = readJson(join(out, "index.json"));
    assert.ok(index.length > 0, "empty hit-path index");
    for (const e of index) {
      assert.equal(e.status, "done", JSON.stringify(e));
      const meta = readJson(join(out, e.meta));
      assert.equal(meta.cache, "hit", e.meta);
    }
  });

  it("run2 bare re-captures from cache: every entry a hit", (t) => {
    if (!gitIsDirty()) {
      t.skip("clean tree selects no families; run2 needs dirt");
      return;
    }
    const out = runDir(2);
    const r = runCli(["canary", "--out", relative(repoRoot, runDir(2))]);
    assert.equal(r.status, 0, `run2 failed:\n${r.stderr}`);
    const index = readJson(join(out, "index.json"));
    assert.ok(index.length > 0, "empty run2 index");
    // Whatever the affected set selected, every request was captured
    // by run1's full matrix, so every entry must be a cache hit.
    for (const e of index) {
      assert.equal(e.status, "done", JSON.stringify(e));
      const meta = readJson(join(out, e.meta));
      assert.equal(meta.cache, "hit", e.meta);
    }
    // And the selected families/schemes match the affected module's
    // answer for the real change set against the discovered run.
    const prevDir = discoverPrev(out);
    assert.ok(prevDir !== null, "no previous run discovered");
    const prevTree = readJson(join(prevDir as string, "run.json")).tree_hash;
    const curTree = readJson(join(out, "run.json")).tree_hash;
    const run = (cmd: string[]): string =>
      execFileSync(cmd[0], cmd.slice(1), {
        cwd: repoRoot,
        encoding: "utf8",
      }) as string;
    const changed = changedFilesSince(run, prevTree, curTree);
    const wantFamilies = new Set(
      familiesForChange(changed, BACKEND_A_FAMILIES),
    );
    const wantSchemes = new Set(
      darkNeeded(changed) ? ["light", "dark"] : ["light"],
    );
    const gotFamilies = new Set(index.map((e: any) => e.family));
    const gotSchemes = new Set(index.map((e: any) => e.scheme));
    assert.deepEqual(gotFamilies, wantFamilies);
    assert.deepEqual(gotSchemes, wantSchemes);
  });

  it("mso-only change selects wordApprox; --families smoke", () => {
    assert.deepEqual(selectFamilies(["src/isonim_email/mso/cond.nim"]), [
      "wordApprox",
    ]);
    const out = runDir(3);
    const r = runCli([
      "canary",
      "--families",
      "wordApprox",
      "--viewports",
      "desktop",
      "--schemes",
      "light",
      "--no-cache",
      "--out",
      relative(repoRoot, runDir(3)),
    ]);
    assert.equal(r.status, 0, `run3 failed:\n${r.stderr}`);
    const index = readJson(join(out, "index.json"));
    assert.equal(index.length, 1);
    assert.equal(index[0].status, "done");
    assert.equal(index[0].family, "wordApprox");
    const meta = readJson(join(out, index[0].meta));
    assert.equal(meta.cache, "uncached");
  });

  it("bare rerun with unchanged MIME exits 0 printing 'nothing to capture'", () => {
    // Seed: a bare --full run (all stories, default matrix), so the
    // rerun's MIME-diff sees every story unchanged and selects zero
    // stories: a clean no-op, not a failure (exit 1 stays for explicit
    // filters that empty the matrix).
    const seed = runDir(4);
    const s = runCli(["--full", "--out", relative(repoRoot, seed)]);
    assert.equal(s.status, 0, `seed failed:\n${s.stderr}`);
    const out = runDir(5);
    const r = runCli(["--out", relative(repoRoot, out)]);
    assert.equal(r.status, 0, `rerun failed:\n${r.stderr}`);
    assert.match(r.stdout, /nothing to capture/);
  });
});
