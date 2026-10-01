// tools/capture/providers/owned_state.test.ts — removing a run's
// directory while a process that was just killed may still write into
// it (removeRunDirSync).
//
// No mocks: a real directory on the real filesystem, and a real process
// that keeps creating files in it while it is removed, as a dying
// php-fpm worker writes its log while a run's teardown removes its state
// directory.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { removeRunDirSync } from "./owned_state.ts";

// A directory with many files (so a removal takes a while) and a
// process that creates further files in it, without pause, for `ms`.
async function busyDir(
  ms: number,
): Promise<{ root: string; dir: string; writer: ChildProcess }> {
  const root = mkdtempSync(join(tmpdir(), "ie-owned-"));
  const dir = join(root, "run");
  mkdirSync(join(dir, "logs"), { recursive: true });
  for (let i = 0; i < 2000; i++) writeFileSync(join(dir, `f${i}`), "x");
  const writer = spawn(
    process.execPath,
    [
      "-e",
      [
        "const { writeFileSync } = require('node:fs');",
        "const [dir, ms] = [process.argv[1], Number(process.argv[2])];",
        "const end = Date.now() + ms;",
        "for (let i = 0; Date.now() < end; i++)",
        "  for (const f of [dir + '/w' + i, dir + '/logs/w' + i])",
        "    try { writeFileSync(f, ''); } catch {}",
      ].join("\n"),
      dir,
      String(ms),
    ],
    { stdio: "ignore" },
  );
  // Writing before the removal starts.
  for (const t0 = Date.now(); !existsSync(join(dir, "w0")); ) {
    assert.ok(Date.now() - t0 < 5000, "the writer did not start");
    await new Promise((r) => setTimeout(r, 5));
  }
  return { root, dir, writer };
}

const exited = (c: ChildProcess): Promise<void> =>
  new Promise((ok) =>
    c.exitCode !== null || c.signalCode !== null
      ? ok()
      : c.once("exit", () => ok()),
  );

describe("removeRunDirSync", () => {
  it("removes a run directory a process is still writing into once the writes stop", async () => {
    const { root, dir, writer } = await busyDir(400);
    try {
      removeRunDirSync(dir);
      assert.equal(existsSync(dir), false);
    } finally {
      writer.kill("SIGKILL");
      await exited(writer);
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("throws the last error, never swallows it, when the writes do not stop within the bound", async () => {
    const { root, dir, writer } = await busyDir(3000);
    try {
      const t0 = Date.now();
      assert.throws(
        () => removeRunDirSync(dir, 300),
        (e: NodeJS.ErrnoException) => e.code === "ENOTEMPTY",
      );
      assert.ok(Date.now() - t0 >= 300, `${Date.now() - t0} ms`);
      assert.equal(existsSync(dir), true);
    } finally {
      writer.kill("SIGKILL");
      await exited(writer);
      rmSync(root, { recursive: true, force: true });
    }
  });
});
