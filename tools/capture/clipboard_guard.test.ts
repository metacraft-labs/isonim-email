// tools/capture/clipboard_guard.test.ts — a password put on the
// clipboard for the guided webmail sign-in comes off it again on every
// way out.
//
// What is proven: the guard picks wl-copy/wl-paste on Wayland; it
// empties the clipboard when the caller clears it and, unasked, at its
// deadline; it leaves alone a clipboard the person has since filled
// with something else; and a process holding a copied secret, with the
// sign-in's signal cleanup installed, empties the clipboard when it is
// sent SIGINT, SIGTERM or SIGHUP (exiting 128+N) and when it dies of an
// uncaught exception, never printing the secret.
//
// Test doubles (justification, per the repository's mock policy): a
// test has no desktop session whose clipboard it may overwrite, so
// wl-copy and wl-paste are two-line shell stand-ins on PATH that keep
// "the clipboard" in a file (wl-copy --clear empties it, as the real
// one does). The guard, its deadline and the signal handling are real,
// the signals sent to a real child process.
// Run with:
//   node --test tools/capture/clipboard_guard.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { ClipboardGuard, clipboardTool } from "./clipboard_guard.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const guardModule = pathToFileURL(join(scriptDir, "clipboard_guard.ts")).href;
const scratch = mkdtempSync(join(tmpdir(), "clipboard-guard-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const bin = join(scratch, "bin");
mkdirSync(bin);
writeFileSync(
  join(bin, "wl-copy"),
  '#!/bin/sh\nif [ "$1" = --clear ]; then : > "$FAKE_CLIPBOARD"; else cat > "$FAKE_CLIPBOARD"; fi\n',
  { mode: 0o755 },
);
writeFileSync(
  join(bin, "wl-paste"),
  '#!/bin/sh\n[ -s "$FAKE_CLIPBOARD" ] || exit 1\ncat "$FAKE_CLIPBOARD"\n',
  { mode: 0o755 },
);

let n = 0;
function desktop(): { env: Record<string, string>; board: string } {
  const board = join(scratch, `clipboard-${n++}`);
  writeFileSync(board, "");
  return {
    board,
    env: {
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      WAYLAND_DISPLAY: "wayland-test",
      FAKE_CLIPBOARD: board,
    },
  };
}
const read = (board: string): string => readFileSync(board, "utf8");

describe("the clipboard guard", () => {
  it("clears its secret on request and at its deadline, and leaves a clipboard the person has refilled", async () => {
    const d = desktop();
    const tool = clipboardTool({ env: d.env, platform: "linux" });
    assert.ok(tool !== null);
    assert.deepEqual(tool.copy, ["wl-copy"]);
    assert.deepEqual(tool.paste, ["wl-paste", "--no-newline"]);

    const g = new ClipboardGuard(tool, d.env, 60_000);
    assert.equal(g.fill("pw-one"), true);
    assert.equal(read(d.board), "pw-one");
    assert.equal(g.clear(), true);
    assert.equal(read(d.board), "");

    // The person copied something else meanwhile: theirs stays.
    assert.equal(g.fill("pw-two"), true);
    writeFileSync(d.board, "the person's own text");
    assert.equal(g.clear(), false);
    assert.equal(read(d.board), "the person's own text");

    // Nobody clears it: the deadline does.
    const timed = new ClipboardGuard(tool, d.env, 300);
    assert.equal(timed.fill("pw-three"), true);
    const deadline = Date.now() + 10_000;
    while (read(d.board) !== "" && Date.now() < deadline) await sleep(50);
    assert.equal(read(d.board), "");
    assert.equal(timed.holding, false);
  });

  for (const [how, code] of [
    ["SIGINT", 130],
    ["SIGTERM", 143],
    ["SIGHUP", 129],
    ["an uncaught exception", 1],
  ] as const) {
    it(`clears the clipboard when the process ends by ${how}`, async () => {
      const d = desktop();
      const secret = `s3cret-${how.replace(/\W/g, "")}`;
      const program = `
        import { ClipboardGuard, clipboardTool, installSignalCleanup } from ${JSON.stringify(guardModule)};
        const tool = clipboardTool({ env: process.env, platform: "linux" });
        const g = new ClipboardGuard(tool, process.env);
        if (!g.fill(${JSON.stringify(secret)})) process.exit(9);
        installSignalCleanup(() => { g.clear(); });
        process.stdout.write("ready\\n");
        ${how === "an uncaught exception" ? 'setTimeout(() => { throw new Error("boom"); }, 100);' : "setInterval(() => {}, 1000);"}
      `;
      const child = spawn(
        process.execPath,
        ["--input-type=module", "-e", program],
        {
          env: { ...process.env, ...d.env },
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      let out = "";
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (s: string) => (out += s));
      child.stderr.on("data", (s: string) => (out += s));
      const exited = new Promise<number | null>((r) =>
        child.once("exit", (c) => r(c)),
      );
      const deadline = Date.now() + 60_000;
      while (!out.includes("ready") && Date.now() < deadline) await sleep(50);
      assert.match(out, /ready/);
      assert.equal(read(d.board), secret);
      if (how !== "an uncaught exception") child.kill(how);
      assert.equal(await exited, code, out);
      assert.equal(read(d.board), "");
      assert.ok(!out.includes(secret), "the secret is never printed");
    });
  }
});
