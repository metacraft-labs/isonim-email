// tools/test/runners.test.ts — the concurrent test runners behind
// `just test` (run-recipes.sh) and `just test-c`/`test-js`
// (run-nim-tests.sh), run for real on throwaway recipes.
//
// No test doubles: each case writes a justfile into a scratch directory
// and runs the real script, the real `just`, real processes and a real
// listening server in it. A recipe that hangs, leaks a server or leaves
// a daemon behind does exactly that; the assertions read the runner's
// output and the host's process table and sockets. Every process a case
// starts carries a token unique to the run in its command line, so the
// "nothing survives" checks see only this test's processes (other tests
// run beside it).
//
// Run with:
//   node --test tools/test/runners.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const runRecipes = resolve(scriptDir, "run-recipes.sh");
const runNimTests = resolve(scriptDir, "run-nim-tests.sh");
const scratch = mkdtempSync(join(tmpdir(), "isonim-email-runners-"));
// In every process this test starts, so it can find them afterwards.
const token = `ie-runners-${process.pid}-${Date.now()}`;
after(() => {
  for (const pid of tokenProcesses())
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // gone
    }
  rmSync(scratch, { recursive: true, force: true });
});

// Live processes whose command line carries this run's token.
function tokenProcesses(): number[] {
  const out: number[] = [];
  if (!existsSync("/proc")) return out;
  for (const d of readdirSync("/proc")) {
    if (!/^\d+$/.test(d) || Number(d) === process.pid) continue;
    let cmd = "";
    try {
      cmd = readFileSync(`/proc/${d}/cmdline`, "utf8");
    } catch {
      continue;
    }
    // A zombie's cmdline is empty: it is dead, only not yet reaped.
    if (cmd.includes(token)) out.push(Number(d));
  }
  return out;
}

// An idle process that shows the token in its command line.
const tokenSleep = (tag: string): string =>
  `${process.execPath} -e 'setInterval(() => {}, 1e6)' ${token}-${tag}`;

// The same, ignoring SIGTERM: only SIGKILL stops it.
const tokenStubborn = (tag: string): string =>
  `${process.execPath} -e 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1e6)' ${token}-${tag}`;

function project(name: string, justfile: string): string {
  const dir = join(scratch, name);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "justfile"), justfile);
  return dir;
}

interface Run {
  status: number;
  stdout: string;
  stderr: string;
  cpuSeconds: number;
  wallSeconds: number;
}

// The runner under bash's `time`, so its own CPU use (and its waited-for
// children's) is measured.
function runIn(
  dir: string,
  recipes: string[],
  env: Record<string, string> = {},
): Run {
  const t0 = Date.now();
  // Not this test's own node:test context: a recipe's `node --test`
  // would take it for a parent and run as its child.
  const childEnv: Record<string, string | undefined> = {
    ...process.env,
    ...env,
  };
  delete childEnv.NODE_TEST_CONTEXT;
  const r = spawnSync(
    "bash",
    ["-c", 'TIMEFORMAT="cpu %U %S"; time "$0" "$@"', runRecipes, ...recipes],
    { cwd: dir, encoding: "utf8", env: childEnv },
  );
  const m = /cpu ([\d.]+) ([\d.]+)\s*$/.exec(r.stderr);
  assert.ok(m !== null, `no timing in:\n${r.stderr}`);
  return {
    status: r.status ?? 1,
    stdout: r.stdout,
    stderr: r.stderr,
    cpuSeconds: Number(m[1]) + Number(m[2]),
    wallSeconds: (Date.now() - t0) / 1000,
  };
}

function listening(port: number): Promise<boolean> {
  return new Promise((res) => {
    const s = connect(port, "127.0.0.1");
    s.once("connect", () => {
      s.destroy();
      res(true);
    });
    s.once("error", () => res(false));
  });
}

// Linux: the checks read /proc (the runner's environment-marker search
// is Linux-only too).
describe("run-recipes.sh", { skip: process.platform !== "linux" }, () => {
  it("passes finished recipes and waits for the rest without spinning", () => {
    const dir = project(
      "idle",
      ["quick:", "    @echo quick done", "slow:", "    @sleep 6", ""].join(
        "\n",
      ),
    );
    const r = runIn(dir, ["quick", "slow"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /^PASS quick \(\d+ s\)/m);
    assert.match(r.stdout, /^PASS slow \(\d+ s\)/m);
    assert.match(r.stdout, /^2 of 2 recipes passed/m);
    assert.ok(r.wallSeconds >= 6, `finished in ${r.wallSeconds} s`);
    // About 6 s of waiting after `quick` ends: a runner that polls a
    // reaped pid burns a core for all of it; one that blocks uses a few
    // tens of milliseconds (process listings included).
    assert.ok(
      r.cpuSeconds < 1.5,
      `the runner used ${r.cpuSeconds} s of CPU over ${r.wallSeconds} s of waiting`,
    );
  });

  it("fails a hanging recipe after the timeout and kills all of its processes", () => {
    const dir = project(
      "hang",
      [
        "hang:",
        // A child in the group, and one that left it: a session of its
        // own, re-parented away from the recipe by a double fork (only
        // the environment marker still finds it); and one that ignores
        // SIGTERM, so only the escalation to SIGKILL stops it.
        `    #!/usr/bin/env bash`,
        `    (setsid ${tokenSleep("escaped")} &)`,
        `    ${tokenSleep("child")} &`,
        `    ${tokenStubborn("stubborn")} &`,
        `    wait`,
        "fine:",
        "    @true",
        "",
      ].join("\n"),
    );
    const r = runIn(dir, ["hang", "fine"], {
      ISONIM_EMAIL_RECIPE_TIMEOUT: "3",
    });
    assert.equal(r.status, 1, r.stdout);
    assert.match(
      r.stdout,
      /^FAIL hang \(timed out after 3 s; every process of it killed\)/m,
    );
    assert.match(r.stdout, /^PASS fine/m);
    assert.match(r.stdout, /^FAILED: hang$/m);
    assert.ok(r.wallSeconds < 60, `took ${r.wallSeconds} s`);
    const log = readFileSync(join(dir, "test-logs", "hang.log"), "utf8");
    assert.match(log, /TIMED OUT after 3 s; killing its \d+ process\(es\)/);
    assert.match(log, new RegExp(`${token}-escaped`));
    assert.deepEqual(tokenProcesses(), []);
  });

  it("fails a node --test recipe held open by a leaked server, and closes the server", async () => {
    const dir = project("server", "");
    const portFile = join(dir, "port");
    // The file's name carries the token into node --test's command line
    // and its per-file child's.
    const testFile = `${token}.test.ts`;
    writeFileSync(
      join(dir, testFile),
      [
        `import { test } from "node:test";`,
        `import { createServer } from "node:http";`,
        `import { writeFileSync } from "node:fs";`,
        `test("starts a server and never closes it", async () => {`,
        `  const s = createServer((_q, a) => a.end("x"));`,
        `  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));`,
        `  const a = s.address();`,
        `  writeFileSync(${JSON.stringify(portFile)}, String(typeof a === "object" && a ? a.port : 0));`,
        `});`,
        "",
      ].join("\n"),
    );
    writeFileSync(
      join(dir, "justfile"),
      ["leak:", `    node --test ${testFile}`, ""].join("\n"),
    );
    const r = runIn(dir, ["leak"], { ISONIM_EMAIL_RECIPE_TIMEOUT: "8" });
    assert.equal(r.status, 1, r.stdout);
    assert.match(r.stdout, /^FAIL leak \(timed out after 8 s/m);
    assert.ok(existsSync(portFile), "the test never started its server");
    const port = Number(readFileSync(portFile, "utf8"));
    assert.ok(port > 0);
    assert.equal(await listening(port), false, `port ${port} still open`);
    assert.deepEqual(tokenProcesses(), []);
  });

  it("fails a recipe that exits leaving a process behind, and kills it", () => {
    const dir = project(
      "left",
      ["left:", `    ${tokenSleep("daemon")} &`, ""].join("\n"),
    );
    const r = runIn(dir, ["left"]);
    assert.equal(r.status, 1, r.stdout);
    assert.match(
      r.stdout,
      /^FAIL left \(\d+ s\) left 1 process\(es\) running \(killed; see the log\)/m,
    );
    const log = readFileSync(join(dir, "test-logs", "left.log"), "utf8");
    assert.match(log, new RegExp(`${token}-daemon`));
    assert.deepEqual(tokenProcesses(), []);
  });

  it("refuses a timeout that is not a positive number of seconds", () => {
    const dir = project("bad-timeout", "ok:\n    @true\n");
    for (const bad of ["0", "abc", "-5"]) {
      const r = spawnSync(runRecipes, ["ok"], {
        cwd: dir,
        encoding: "utf8",
        env: { ...process.env, ISONIM_EMAIL_RECIPE_TIMEOUT: bad },
      });
      assert.equal(r.status, 2, `${bad}: ${r.stdout}${r.stderr}`);
      assert.match(r.stderr, /ISONIM_EMAIL_RECIPE_TIMEOUT must be a positive/);
    }
  });
});

describe("run-nim-tests.sh", () => {
  it("refuses a job count that is not a positive number", () => {
    const dir = project("bad-jobs", "");
    for (const bad of ["0", "x", "-1"]) {
      const r = spawnSync(runNimTests, ["c", "", "tests/none.nim"], {
        cwd: dir,
        encoding: "utf8",
        env: { ...process.env, ISONIM_EMAIL_TEST_JOBS: bad },
      });
      assert.equal(r.status, 2, `${bad}: ${r.stdout}${r.stderr}`);
      assert.match(r.stderr, /ISONIM_EMAIL_TEST_JOBS must be a positive/);
    }
  });
});
