// tools/capture/help.test.ts — `email-shots --help` matches the parser.
//
// Every flag the help names is accepted by the CLI (never "unknown
// flag"), every flag the parser knows (each "--x" literal in
// email-shots.ts) is named in the help, and the help describes the
// axes as they behave now. Runs the real CLI; the story driver path is
// deliberately missing, so each accepted flag stops at "story driver
// not found" before any capture. Run with:
//   node --test tools/capture/help.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
const cli = join(scriptDir, "email-shots.ts");
const missing = join(repoRoot, "build", "no-such-driver");

function run(args: string[]): { status: number; out: string; err: string } {
  const r = spawnSync(process.execPath, [cli, ...args], {
    cwd: repoRoot,
    encoding: "utf8",
  });
  return {
    status: r.status ?? 1,
    out: r.stdout as string,
    err: r.stderr as string,
  };
}

// A valid value for each flag that takes one.
const VALUES: Record<string, string> = {
  "--backends": "a",
  "--families": "apple,wordApprox",
  "--clients": "chromium",
  "--viewports": "mobile,600@2x",
  "--schemes": "light,dark",
  "--images": "on,off",
  "--out": "build/no-such-run",
  "--driver": missing,
  "--brief-driver": missing,
};

// Named by the help as not served yet: refused with a reason.
const REFUSED = new Set(["--async", "--follow", "--via"]);

describe("email-shots --help", () => {
  const help = run(["--help"]);

  it("exits 0 and prints the usage", () => {
    assert.equal(help.status, 0, help.err);
    assert.match(help.out, /^usage: email-shots/);
  });

  it("every flag it names is accepted by the parser", () => {
    const named = [...new Set(help.out.match(/--[a-z][a-z-]*/g) ?? [])];
    assert.ok(named.length >= 15, `only ${named.length} flags named`);
    for (const flag of named) {
      if (flag === "--help") continue;
      const value = Object.hasOwn(VALUES, flag) ? VALUES[flag] : undefined;
      const args = value === undefined ? [flag] : [flag, value];
      const r = run([...args, "--driver", missing]);
      assert.doesNotMatch(r.err, /unknown flag/, `${flag}: ${r.err}`);
      if (REFUSED.has(flag)) {
        assert.equal(r.status, 2, `${flag} should be refused: ${r.err}`);
        assert.match(r.err, /land|lands/, `${flag}: ${r.err}`);
      } else {
        assert.match(r.err, /story driver not found/, `${flag}: ${r.err}`);
      }
    }
  });

  it("every flag the parser knows is in the help", () => {
    const source = readFileSync(cli, "utf8");
    const known = new Set(source.match(/"--[a-z][a-z-]*"/g) ?? []);
    for (const lit of known) {
      const flag = lit.slice(1, -1);
      assert.ok(help.out.includes(flag), `${flag} is parsed but not in --help`);
    }
  });

  it("refuses Object.prototype member names as families and viewports", () => {
    // Validation looks at the CLI's own tables only: an inherited
    // member ("constructor", "toString") is not a family or a named
    // viewport, and is refused before any work starts.
    for (const name of ["constructor", "toString", "__proto__"]) {
      const fam = run(["--families", name, "--driver", missing]);
      assert.equal(fam.status, 2, `--families ${name}: ${fam.err}`);
      assert.match(
        fam.err,
        /is not a family any capture provider serves/,
        fam.err,
      );
      const vp = run(["--viewports", name, "--driver", missing]);
      assert.equal(vp.status, 2, `--viewports ${name}: ${vp.err}`);
      assert.match(vp.err, /bad viewport/, vp.err);
    }
  });

  it("describes the axes as they behave now", () => {
    // --images off is a real axis for every family, not a skip marker.
    assert.match(help.out, /--images on,off/);
    assert.doesNotMatch(help.out, /skip marker/);
    // A bare run is --affected; families come from the declarations.
    assert.match(help.out, /With no STORY and no --full, a run is --affected/);
    assert.match(help.out, /affects declarations/);
    // Captures never use the network.
    assert.match(help.out, /never use the network/);
    // Warm means within one run; --cold asks for a fresh client.
    assert.match(
      help.out,
      /--cold +a fresh client and profile for every capture/,
    );
    assert.match(help.out, /never across\s+runs/);
  });
});
