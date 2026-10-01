// tools/capture/providers/imap_teardown.test.ts — nothing the `imap`
// service starts outlives the capture run, however the run ends.
//
// Each test spawns a real run in a child node process: the real harness
// (assessProviders + executePlan) with the registered services and the
// signal teardown the email-shots process installs, a real Dovecot from
// the dev shell, a real injected message. The run holds its capture
// open; the test then signals it (SIGTERM, SIGINT, SIGKILL) and looks
// at the real process table (/proc) and the real directories.
//
// Test double, justified: the provider that declares the services is a
// minimal CaptureProvider written into the child script (it delivers
// one message, reports where things are, and waits). The providers that
// will use these services do not exist yet, and the harness only starts
// a service for a provider that declares it.
//
// Each run uses a state root and a socket base of its own (scratch
// directories), so the sweep under test sees only this file's runs and
// test files running in parallel cannot sweep them first. Linux only
// (/proc and the parent-death signal). Run with:
//   node --test tools/capture/providers/imap_teardown.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { connect } from "node:net";
import { dirname, join, resolve } from "node:path";
import {
  DovecotService,
  imapHandle,
  processAlive,
  sweepDeadRuns,
} from "./imap_service.ts";
import { directChildOf } from "./owned_state.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const providersDir = resolve(scriptDir);
// Short: the socket base must leave room for Dovecot's socket paths.
const scratch = mkdtempSync("/tmp/ie-td-");
const stateRoot = join(scratch, "mail");
const socketBase = join(scratch, "rt");
mkdirSync(stateRoot);
mkdirSync(socketBase, { mode: 0o700 });
const env = { ...process.env, XDG_RUNTIME_DIR: socketBase };

const CHILD = `
import { createHash } from "node:crypto";
import { renameSync, writeFileSync } from "node:fs";
import { assessProviders, candidateProviders, executePlan, messageMap, routeRequests } from "${providersDir}/harness.ts";
import { installSignalTeardown, registeredServices } from "${providersDir}/services.ts";
import { assetsHandle } from "${providersDir}/assets_service.ts";
import { DovecotService, imapHandle } from "${providersDir}/imap_service.ts";
const [ready, run, stateRoot, pdeath] = process.argv.slice(2);
installSignalTeardown();
const registry = {
  ...registeredServices(),
  imap: () => new DovecotService({ stateRoot, parentDeathSignal: pdeath === "pdeathsig" }),
};
const mime = Buffer.from("From: a@example.test\\r\\nTo: b@example.test\\r\\nSubject: t\\r\\nMIME-Version: 1.0\\r\\nContent-Type: text/html\\r\\n\\r\\n<img src=\\"https://x.test/0000000000000000/a.png\\">\\r\\n");
const sha = createHash("sha256").update(mime).digest("hex");
const p = {
  id: "teardown-probe", backend: "probe", version: "1", adapterVersion: 1, via: "inject",
  clients: () => [{ clientId: "c", family: "verification", engine: "unknown", build: async () => "1", viewports: "any", schemes: ["light"], imagesOff: true, approximation: false }],
  requirements: () => [{ kind: "service", name: "imap", why: "x" }, { kind: "service", name: "assets", why: "y" }],
  health: async () => ({ state: "ok" }),
  prepare: async (ctx) => { p.imap = imapHandle(ctx.services.imap); p.assets = assetsHandle(ctx.services.assets); },
  emulation: () => ({ transformVersion: "", detail: null }),
  async *capture() {
    await p.imap.mailboxFor(mime, { assets: p.assets });
    const d = p.imap.detail;
    writeFileSync(ready + ".tmp", JSON.stringify({ pid: process.pid, dovecot: d.pid, stateDir: d.stateDir, socketDir: d.socketDir, port: p.imap.port }));
    renameSync(ready + ".tmp", ready);
    setInterval(() => {}, 1000);
    await new Promise(() => {});
  },
  dispose: async () => {},
};
const spec = { stories: [{ story: "s", mimeSha256: sha }], families: ["verification"], clients: null, backends: null, viewports: [{ name: "desktop", width: 800, dpr: 1 }], schemes: ["light"], images: ["on"] };
const runDir = stateRoot + "/../run-" + run;
const { availability, services } = await assessProviders(candidateProviders([p], spec), { run, runDir }, registry);
await executePlan([p], availability, routeRequests([p], availability, spec), messageMap([{ story: "s", mime, html: "" }]),
  { run, session: null, runDir, library: { commit: "c", dirty: false, tree_hash: "t" }, cacheRoot: runDir + "/.cache", noCache: true, assert: false, cold: false, services }, () => {});
`;
const childScript = join(scratch, "run.ts");
writeFileSync(childScript, CHILD);

// Whatever a failing test leaves running is killed; the scratch goes.
const spawned: number[] = [];
after(() => {
  for (const pid of spawned)
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // gone
    }
  rmSync(scratch, { recursive: true, force: true });
});

interface RunInfo {
  pid: number;
  dovecot: number;
  stateDir: string;
  socketDir: string;
  port: number;
}

interface Proc {
  pid: number;
  start: string | null;
  comm: string;
}

function procStat(
  pid: number,
): { ppid: number; start: string; comm: string } | null {
  try {
    const s = readFileSync(`/proc/${pid}/stat`, "latin1");
    const f = s.slice(s.lastIndexOf(")") + 2).split(" ");
    const comm = s.slice(s.indexOf("(") + 1, s.lastIndexOf(")"));
    return { ppid: Number(f[1]), start: f[19]!, comm };
  } catch {
    return null;
  }
}

// The process and every descendant of it, as it is now.
function tree(root: number): Proc[] {
  const children = new Map<number, number[]>();
  for (const e of readdirSync("/proc")) {
    if (!/^\d+$/.test(e)) continue;
    const st = procStat(Number(e));
    if (st === null) continue;
    const list = children.get(st.ppid) ?? [];
    list.push(Number(e));
    children.set(st.ppid, list);
  }
  const out: Proc[] = [];
  const queue = [root];
  while (queue.length > 0) {
    const pid = queue.shift()!;
    const st = procStat(pid);
    if (st === null) continue;
    out.push({ pid, start: st.start, comm: st.comm });
    queue.push(...(children.get(pid) ?? []));
  }
  return out;
}

async function waitFor(cond: () => boolean, ms: number): Promise<boolean> {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) return false;
    await new Promise((r) => setTimeout(r, 50));
  }
  return true;
}

let seq = 0;
async function startRun(pdeath: "pdeathsig" | "no-pdeathsig"): Promise<{
  child: ChildProcess;
  info: RunInfo;
  exit: Promise<{ code: number | null; signal: string | null }>;
}> {
  const run = `td-${process.pid}-${++seq}`;
  const ready = join(scratch, `${run}.json`);
  const child = spawn(
    process.execPath,
    [childScript, ready, run, stateRoot, pdeath],
    { env, stdio: ["ignore", "ignore", "pipe"] },
  );
  spawned.push(child.pid!);
  let stderr = "";
  child.stderr!.on("data", (d: Buffer) => (stderr += d.toString()));
  const exit = new Promise<{ code: number | null; signal: string | null }>(
    (ok) => child.once("exit", (code, signal) => ok({ code, signal })),
  );
  const up = await waitFor(
    () => existsSync(ready) || child.exitCode !== null,
    60000,
  );
  assert.ok(up && existsSync(ready), `the run did not come up: ${stderr}`);
  const info = JSON.parse(readFileSync(ready, "utf8")) as RunInfo;
  assert.equal(info.pid, child.pid);
  // Dovecot is a child of the run, and has children of its own.
  assert.equal(procStat(info.dovecot)?.ppid, child.pid);
  return { child, info, exit };
}

function alive(procs: Proc[]): Proc[] {
  return procs.filter((p) => processAlive(p));
}

function greets(port: number): Promise<boolean> {
  return new Promise((ok) => {
    const c = connect({ host: "127.0.0.1", port });
    c.setTimeout(2000, () => (c.destroy(), ok(false)));
    c.once("data", (d) => (c.destroy(), ok(d.toString().startsWith("* OK"))));
    c.once("error", () => ok(false));
  });
}

describe(
  "imap service teardown",
  { skip: process.platform !== "linux" },
  () => {
    for (const [signal, code] of [
      ["SIGTERM", 143],
      ["SIGINT", 130],
    ] as const)
      it(`${signal}: the run stops its services, exits ${code}, and leaves no Dovecot and no state`, async () => {
        const { child, info, exit } = await startRun("pdeathsig");
        const procs = tree(info.dovecot);
        assert.ok(
          procs.length >= 2,
          `Dovecot and its children: ${JSON.stringify(procs)}`,
        );
        assert.ok(existsSync(info.stateDir) && existsSync(info.socketDir));
        child.kill(signal);
        assert.deepEqual(await exit, { code, signal: null });
        assert.ok(
          await waitFor(() => alive(procs).length === 0, 5000),
          `still running: ${JSON.stringify(alive(procs))}`,
        );
        assert.equal(
          existsSync(info.stateDir),
          false,
          "state directory removed",
        );
        assert.equal(
          existsSync(info.socketDir),
          false,
          "socket directory removed",
        );
      });

    it("SIGKILL: Dovecot dies with the run, and the next start sweeps the state the run left", async () => {
      const { child, info, exit } = await startRun("pdeathsig");
      const procs = tree(info.dovecot);
      child.kill("SIGKILL");
      assert.equal((await exit).signal, "SIGKILL");
      assert.ok(
        await waitFor(() => alive(procs).length === 0, 5000),
        `survived the run: ${JSON.stringify(alive(procs))}`,
      );
      // A SIGKILLed run cannot remove its directories.
      assert.ok(existsSync(join(info.stateDir, "owner.json")));
      assert.ok(existsSync(join(info.socketDir, "owner.json")));
      const next = new DovecotService({ stateRoot, env });
      const h = imapHandle(
        await next.start({ run: `td-next-${process.pid}`, runDir: scratch }),
      );
      try {
        const swept = h.detail.swept as string[];
        assert.ok(swept.includes(info.stateDir), JSON.stringify(swept));
        assert.ok(swept.includes(info.socketDir), JSON.stringify(swept));
        assert.equal(existsSync(info.stateDir), false);
        assert.equal(existsSync(info.socketDir), false);
      } finally {
        await next.stop();
      }
    });

    it("without the parent-death signal a SIGKILLed run's Dovecot survives, and the next start kills it and removes its state", async () => {
      const { child, info, exit } = await startRun("no-pdeathsig");
      const procs = tree(info.dovecot);
      const master = procs[0]!;
      child.kill("SIGKILL");
      await exit;
      // The control: this is what the parent-death signal prevents.
      await new Promise((r) => setTimeout(r, 1000));
      assert.ok(processAlive(master), "the orphaned Dovecot is still running");
      spawned.push(master.pid);
      const next = new DovecotService({ stateRoot, env });
      const h = imapHandle(
        await next.start({ run: `td-orphan-${process.pid}`, runDir: scratch }),
      );
      try {
        assert.equal(processAlive(master), false, "the orphan was killed");
        assert.ok(
          await waitFor(() => alive(procs).length === 0, 5000),
          `left running: ${JSON.stringify(alive(procs))}`,
        );
        const swept = h.detail.swept as string[];
        assert.ok(
          swept.includes(info.stateDir) && swept.includes(info.socketDir),
        );
        assert.ok(
          await waitFor(
            () => !existsSync(info.stateDir) && !existsSync(info.socketDir),
            1000,
          ),
        );
      } finally {
        await next.stop();
      }
    });

    it("a start never touches the state of a live run, nor state without an owner record", async () => {
      const { child, info, exit } = await startRun("pdeathsig");
      const unowned = join(stateRoot, "no-owner");
      mkdirSync(unowned);
      const procs = tree(info.dovecot);
      const next = new DovecotService({ stateRoot, env });
      try {
        const h = imapHandle(
          await next.start({ run: `td-live-${process.pid}`, runDir: scratch }),
        );
        assert.deepEqual(h.detail.swept, []);
        assert.ok(existsSync(join(info.stateDir, "mail")));
        assert.ok(existsSync(join(info.socketDir, "d")));
        assert.ok(existsSync(unowned));
        assert.equal(
          alive(procs).length,
          procs.length,
          "the live run's Dovecot runs on",
        );
        assert.ok(await greets(info.port), "and still answers");
      } finally {
        await next.stop();
        rmSync(unowned, { recursive: true, force: true });
        child.kill("SIGTERM");
        await exit;
      }
    });

    for (const withXdg of [true, false])
      it(`keeps Dovecot's sockets under a private 0700 directory (${withXdg ? "$XDG_RUNTIME_DIR" : "no $XDG_RUNTIME_DIR: /tmp"})`, async () => {
        const e = {
          ...process.env,
          XDG_RUNTIME_DIR: withXdg ? socketBase : undefined,
        };
        const s = new DovecotService({ stateRoot, env: e });
        const h = imapHandle(
          await s.start({
            run: `td-perm-${process.pid}-${withXdg}`,
            runDir: scratch,
          }),
        );
        try {
          const dir = String(h.detail.socketDir);
          assert.equal(dirname(dir), withXdg ? socketBase : "/tmp");
          assert.equal(statSync(dir).mode & 0o777, 0o700);
          // base_dir is inside it; Dovecot made base_dir itself 0755 and
          // some sockets 0666, which is why the parent must be private.
          const baseDir = join(dir, "d");
          assert.ok(existsSync(join(baseDir, "master.pid")));
          const open = readdirSync(baseDir).filter(
            (n) =>
              statSync(join(baseDir, n)).isSocket() &&
              (statSync(join(baseDir, n)).mode & 0o006) !== 0,
          );
          assert.ok(
            open.length > 0,
            "world-writable sockets exist under base_dir",
          );
          assert.equal(statSync(dir).uid, process.getuid!());
        } finally {
          await s.stop();
        }
      });
  },
);

// The sweep's trust in owner.json, on fabricated records (no Dovecot):
// a live pid with another start time is a reused pid, and the paths a
// record names are removed only where they resolve to the shapes the
// service creates. Each test has a state root and socket base of its
// own, so nothing else is swept.
describe(
  "imap service sweep: owner records are not trusted blindly",
  { skip: process.platform !== "linux" },
  () => {
    function sweepScratch(): { root: string; state: string; base: string } {
      const root = mkdtempSync(join(scratch, "sw-"));
      const state = join(root, "a", "mail");
      const base = join(root, "rt");
      mkdirSync(state, { recursive: true });
      mkdirSync(base);
      return { root, state, base };
    }

    function record(dir: string, o: object): void {
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "owner.json"), JSON.stringify(o));
    }

    // A pid that was just used and has exited.
    function deadPid(): number {
      const r = spawnSync("true");
      return r.pid!;
    }

    it("treats a live pid with another start time as dead, and never kills the unrelated process holding it", async () => {
      const { state, base } = sweepScratch();
      const other = spawn("sleep", ["60"], { stdio: "ignore" });
      spawned.push(other.pid!);
      try {
        await waitFor(() => procStat(other.pid!) !== null, 5000);
        const real = procStat(other.pid!)!.start;
        const reused = { pid: other.pid!, start: String(Number(real) + 1) };
        assert.equal(processAlive({ pid: other.pid!, start: real }), true);
        assert.equal(processAlive(reused), false);
        // The owner's pid is now someone else's; so is Dovecot's.
        const a = join(state, "run-a");
        record(a, {
          owner: reused,
          run: "a",
          stateDir: a,
          socketDir: join(base, "ie-imap-a"),
          dovecot: reused,
        });
        record(join(base, "ie-imap-a"), {
          owner: reused,
          run: "a",
          stateDir: a,
          socketDir: join(base, "ie-imap-a"),
          dovecot: reused,
        });
        // A dead owner whose recorded Dovecot pid was reused.
        const b = join(state, "run-b");
        record(b, {
          owner: { pid: deadPid(), start: "1" },
          run: "b",
          stateDir: b,
          socketDir: join(base, "ie-imap-b"),
          dovecot: reused,
        });
        const removed = await sweepDeadRuns(state, [base]);
        assert.deepEqual(
          [...removed].sort(),
          [a, b, join(base, "ie-imap-a")].sort(),
        );
        assert.equal(
          procStat(other.pid!)?.start,
          real,
          "the unrelated process lives",
        );
        assert.equal(other.exitCode, null);
        assert.equal(other.signalCode, null);
      } finally {
        other.kill("SIGKILL");
      }
    });

    it("removes only what resolves to a direct child of the state root or of a socket base", async () => {
      const { root, state, base } = sweepScratch();
      const dead = { pid: deadPid(), start: "1" };
      // Things a forged or corrupted record points at.
      const sentinel = join(root, "a", "sentinel");
      writeFileSync(sentinel, "keep");
      const outside = join(root, "victim", "ie-imap-v");
      mkdirSync(outside, { recursive: true });
      const linked = join(root, "victim2");
      mkdirSync(linked);
      symlinkSync(linked, join(base, "ie-imap-link"));
      mkdirSync(join(base, "ie-imap-up"));
      const run = join(state, "run-x");
      record(run, {
        owner: dead,
        run: "x",
        stateDir: `${state}/..`,
        socketDir: `${base}/ie-imap-up/../../victim/ie-imap-v`,
        dovecot: null,
      });
      const run2 = join(state, "run-y");
      record(run2, {
        owner: dead,
        run: "y",
        stateDir: `${state}/run-y/../../mail/../mail`,
        socketDir: join(base, "ie-imap-link"),
        dovecot: null,
      });
      const removed = await sweepDeadRuns(state, [base]);
      assert.deepEqual([...removed].sort(), [run, run2].sort());
      assert.ok(existsSync(sentinel), "the state root's parent is kept");
      assert.ok(existsSync(state), "the state root is kept");
      assert.ok(
        existsSync(outside),
        "a prefixed directory outside the bases is kept",
      );
      assert.ok(existsSync(linked), "a symlink's target is kept");
      assert.ok(existsSync(join(base, "ie-imap-link")), "and the symlink");
      assert.ok(
        existsSync(join(base, "ie-imap-up")),
        "an unowned socket directory is kept",
      );
    });

    it("never removes a directory a dead record names unless that directory's own record names the same dead run", async () => {
      const { state, base } = sweepScratch();
      const dead = { pid: deadPid(), start: "1" };
      const live = { pid: process.pid, start: procStat(process.pid)!.start };
      // A live run's state directory, an ownerless socket directory,
      // and the socket directory of another live run.
      const liveDir = join(state, "run-live");
      record(liveDir, {
        owner: live,
        run: "live",
        stateDir: liveDir,
        socketDir: join(base, "ie-imap-live"),
        dovecot: null,
      });
      const unowned = join(base, "ie-imap-unowned");
      mkdirSync(unowned);
      const otherRun = join(base, "ie-imap-other");
      record(otherRun, {
        owner: { pid: process.pid, start: live.start },
        run: "other",
        stateDir: join(state, "run-other"),
        socketDir: otherRun,
        dovecot: null,
      });
      // Dead records naming them as their partners.
      const d1 = join(state, "run-d1");
      record(d1, {
        owner: dead,
        run: "d1",
        stateDir: d1,
        socketDir: unowned,
        dovecot: null,
      });
      const d2 = join(base, "ie-imap-d2");
      record(d2, {
        owner: dead,
        run: "d2",
        stateDir: liveDir,
        socketDir: d2,
        dovecot: null,
      });
      const d3 = join(state, "run-d3");
      record(d3, {
        owner: dead,
        run: "d3",
        stateDir: d3,
        socketDir: otherRun,
        dovecot: null,
      });
      // The control: a partner whose own record names the same dead
      // owner and run goes with it.
      const d4 = join(state, "run-d4");
      const d4s = join(base, "ie-imap-d4");
      for (const dir of [d4, d4s])
        record(dir, {
          owner: dead,
          run: "d4",
          stateDir: d4,
          socketDir: d4s,
          dovecot: null,
        });
      const removed = await sweepDeadRuns(state, [base]);
      assert.deepEqual([...removed].sort(), [d1, d2, d3, d4, d4s].sort());
      assert.ok(
        existsSync(join(liveDir, "owner.json")),
        "the live run's directory is kept",
      );
      assert.ok(existsSync(unowned), "the ownerless directory is kept");
      assert.ok(
        existsSync(join(otherRun, "owner.json")),
        "another live run's socket directory is kept",
      );
    });

    it("a dead record whose owner pid was reused never takes the directory of the live run now holding that pid", async () => {
      const { state, base } = sweepScratch();
      const other = spawn("sleep", ["60"], { stdio: "ignore" });
      spawned.push(other.pid!);
      try {
        await waitFor(() => procStat(other.pid!) !== null, 5000);
        const real = procStat(other.pid!)!.start;
        const holder = { pid: other.pid!, start: real };
        const reused = { pid: other.pid!, start: String(Number(real) + 1) };
        assert.equal(processAlive(holder), true);
        assert.equal(processAlive(reused), false);
        // The live run holding the pid now, with the same run name the
        // dead record carries: only the start time tells them apart.
        const liveSock = join(base, "ie-imap-holder");
        const liveState = join(state, "run-holder");
        for (const dir of [liveState, liveSock])
          record(dir, {
            owner: holder,
            run: "r",
            stateDir: liveState,
            socketDir: liveSock,
            dovecot: null,
          });
        // The dead run: its pid is alive again (as `holder`), with
        // another start time, so it is dead; it names the live run's
        // directories as its partners.
        const deadState = join(state, "run-reused");
        const deadSock = join(base, "ie-imap-reused");
        record(deadState, {
          owner: reused,
          run: "r",
          stateDir: deadState,
          socketDir: liveSock,
          dovecot: null,
        });
        record(deadSock, {
          owner: reused,
          run: "r",
          stateDir: liveState,
          socketDir: deadSock,
          dovecot: null,
        });
        const removed = await sweepDeadRuns(state, [base]);
        assert.deepEqual([...removed].sort(), [deadSock, deadState].sort());
        assert.ok(
          existsSync(join(liveState, "owner.json")),
          "the live run's state directory is kept",
        );
        assert.ok(
          existsSync(join(liveSock, "owner.json")),
          "the live run's socket directory is kept",
        );
        assert.equal(other.exitCode, null);
        assert.equal(procStat(other.pid!)?.start, real);
      } finally {
        other.kill("SIGKILL");
      }
    });

    it("refuses a symlink even when its target is a direct child of the root", () => {
      const { state, base } = sweepScratch();
      const uid = process.getuid!();
      const target = join(state, "real");
      mkdirSync(target);
      symlinkSync(target, join(state, "link"));
      symlinkSync(join(base, "ie-imap-t"), join(base, "ie-imap-l"));
      mkdirSync(join(base, "ie-imap-t"));
      assert.equal(directChildOf(target, [state], uid), target);
      assert.equal(directChildOf(join(state, "link"), [state], uid), null);
      assert.equal(
        directChildOf(join(base, "ie-imap-t"), [base], uid),
        join(base, "ie-imap-t"),
      );
      assert.equal(directChildOf(join(base, "ie-imap-l"), [base], uid), null);
    });
  },
);
