// tools/capture/providers/webmail_desktop.test.ts — the captures'
// driver of the webmail browser, through the GuiAssert stand-in.
//
// What is proven: a desktop is a private headless Xvfb session at the
// window's size (no VNC socket unless asked) with the browser started by
// the launcher in it, with the session's environment and the session
// switches (dark only when asked); navigation clicks the browser's
// address bar, selects it, types the URL on standard input (never on
// argv), deletes an inline completion and presses Return, and presses
// F5 instead when the address bar already holds the URL; a snapshot
// reads the address bar from the tree; a region capture is a PNG of the
// region's size whose frame is not kept; a session that cannot start is
// DesktopUnavailable and starts no browser; closing stops the browser
// with SIGINT and the session.
//
// Test double (justification, per the repository's mock policy): the
// GuiAssert stand-in (guiassert_standin.ts) plays the desktop and
// records every invocation, and the launcher seam starts a sleeping
// process instead of Chrome, so the driver's own calls can be checked
// one by one. The real session, browser and tree are exercised in
// hosted_webmail.test.ts.
// Run with:
//   node --test tools/capture/providers/webmail_desktop.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { readPng } from "../contact_sheet.ts";
import { GuiAssert } from "./guiassert.ts";
import type { StandinLogEntry, StandinScenario } from "./guiassert_standin.ts";
import type { StartBrowser, Started } from "./webmail_browser.ts";
import { DesktopUnavailable, WebmailDesktop } from "./webmail_desktop.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const standin = join(scriptDir, "guiassert_standin.ts");
const scratch = mkdtempSync(join(tmpdir(), "webmail-desktop-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));
const binDir = join(scratch, "bin");
mkdirSync(binDir);
const gaBin = join(binDir, "guiassert");
writeFileSync(
  gaBin,
  `#!/bin/sh\nexec "${process.execPath}" "${standin}" "$@"\n`,
  { mode: 0o755 },
);

let runs = 0;
function harness(scenario: StandinScenario, env: Record<string, string> = {}) {
  const dir = join(scratch, `run${runs++}`);
  const state = join(dir, "state");
  mkdirSync(state, { recursive: true });
  writeFileSync(join(dir, "scenario.json"), JSON.stringify(scenario));
  const ga = new GuiAssert({
    bin: gaBin,
    stateDir: state,
    env: {
      ...process.env,
      GUIASSERT_STANDIN_SCENARIO: join(dir, "scenario.json"),
      ...env,
    },
  });
  const log = (): StandinLogEntry[] => {
    const f = join(state, "standin-log.jsonl");
    return existsSync(f)
      ? readFileSync(f, "utf8")
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((l) => JSON.parse(l) as StandinLogEntry)
      : [];
  };
  const starts: StartBrowser[] = [];
  const children: ReturnType<typeof spawn>[] = [];
  const startBrowser = async (o: StartBrowser): Promise<Started> => {
    starts.push(o);
    const child = spawn("sleep", ["60"], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    children.push(child);
    o.onChild?.(child);
    return { ok: true, child, argv: ["--recorded"] };
  };
  return { dir, ga, log, starts, children, startBrowser };
}

const URL_NOW = "127.0.0.1:4711/mail/u/0/#inbox";
const SCENARIO: StandinScenario = {
  start: "mail",
  screens: {
    mail: { text: "Inbox Compose", location: URL_NOW, fill: [10, 20, 30] },
  },
};

async function openDesk(h: ReturnType<typeof harness>, over = {}) {
  return WebmailDesktop.open({
    ga: h.ga,
    chrome: { path: "/nonexistent/chrome", label: "test" },
    userDataDir: join(h.dir, "profile"),
    env: { HOME: "/home/test", WAYLAND_DISPLAY: "wayland-1" },
    width: 1240,
    height: 2400,
    scheme: "light",
    startUrl: "http://127.0.0.1:4711/mail/u/0/#inbox",
    name: "capture-test-1",
    startBrowser: h.startBrowser,
    ...over,
  });
}

describe("WebmailDesktop", () => {
  it("starts a private headless session at the window's size and the browser in it", async () => {
    const h = harness(SCENARIO);
    const d = await openDesk(h);
    try {
      const start = h.log().find((e) => e.verb === "session-start")!;
      const args = start.argv.join(" ");
      assert.match(args, /--kind headless --session-backend linux-xvfb/);
      assert.match(args, /--width 1240 --height 2400/);
      assert.match(args, /--name capture-test-1/);
      assert.doesNotMatch(args, /--vnc/);
      assert.equal(h.starts.length, 1);
      const s = h.starts[0]!;
      assert.equal(s.env.DISPLAY, ":standin");
      assert.equal(s.env.WAYLAND_DISPLAY, undefined);
      assert.equal(s.unsafeNoSandbox, false);
      assert.ok(s.extra.includes("--window-size=1240,2400"));
      assert.equal(s.scheme, "light");
      assert.ok(!s.extra.some((a) => /dark|blink-settings/.test(a)));
      assert.equal(s.url, "http://127.0.0.1:4711/mail/u/0/#inbox");
      assert.equal(d.pid, h.children[0]!.pid);
    } finally {
      await d.close();
    }
    const dark = harness(SCENARIO);
    const dd = await openDesk(dark, { scheme: "dark", vnc: true });
    await dd.close();
    assert.equal(dark.starts[0]!.scheme, "dark");
    assert.ok(
      !dark.starts[0]!.extra.some((a) => /dark|blink-settings/.test(a)),
    );
    assert.match(
      dark
        .log()
        .find((e) => e.verb === "session-start")!
        .argv.join(" "),
      /--vnc-socket/,
    );
  });

  it("navigates through the address bar, the URL on standard input; F5 when it already holds it", async () => {
    const h = harness(SCENARIO);
    const d = await openDesk(h);
    try {
      const target = "http://127.0.0.1:4711/mail/u/0/#search/rfc822msgid%3Ax";
      const r = await d.navigate(target, () => true, 300);
      // The stand-in's address never changes: the wait times out.
      assert.equal(r.ok, false);
      const input = h
        .log()
        .filter((e) => ["click", "key", "type"].includes(e.verb))
        .map((e) =>
          e.verb === "type"
            ? `type:${e.stdin}:${e.argv.includes(target)}`
            : `${e.verb}:${e.argv.at(-1)}`,
        );
      // The bar's bounds are [140, 50, 900, 26]: its centre.
      assert.deepEqual(input.slice(0, 5), [
        "click:590,63",
        "key:ctrl+a",
        `type:${target}:false`,
        "key:Delete",
        "key:Return",
      ]);
      const before = h.log().length;
      const same = await d.navigate(`http://${URL_NOW}`, () => true, 300);
      assert.equal(same.ok, true);
      const after = h
        .log()
        .slice(before)
        .filter((e) => ["click", "key", "type"].includes(e.verb))
        .map((e) => `${e.verb}:${e.argv.at(-1)}`);
      assert.deepEqual(after, ["key:F5"]);
      assert.equal((await d.snapshot()).location, URL_NOW);
    } finally {
      await d.close();
    }
  });

  it("captures a region as a PNG of its size and keeps no frame; close stops the browser and the session", async () => {
    const h = harness(SCENARIO);
    const d = await openDesk(h);
    const png = await d.capture([220, 300, 800, 412]);
    const img = readPng(png);
    assert.equal(img.width, 800);
    assert.equal(img.height, 412);
    assert.deepEqual(Array.from(img.data.slice(0, 3)), [10, 20, 30]);
    const shot = h.log().find((e) => e.verb === "screenshot")!;
    assert.match(shot.argv.join(" "), /--region 220,300,800,412/);
    assert.deepEqual(readdirSync(d.framesDir), []);
    const child = h.children[0]!;
    const exited = new Promise<NodeJS.Signals | null>((r) =>
      child.once("exit", (_c, sig) => r(sig)),
    );
    await d.close();
    assert.equal(await exited, "SIGINT");
    assert.ok(h.log().some((e) => e.verb === "session-stop"));
  });

  it("a session that cannot start is DesktopUnavailable and starts no browser", async () => {
    const h = harness(SCENARIO, {
      GUIASSERT_STANDIN_FAIL: "session-start:5:session-failed",
    });
    await assert.rejects(
      openDesk(h),
      (e: unknown) =>
        e instanceof DesktopUnavailable &&
        /no private display session/.test(e.message),
    );
    assert.equal(h.starts.length, 0);
  });
});
