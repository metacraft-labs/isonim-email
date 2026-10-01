// tools/capture/providers/linux_desktop.test.ts — the linux-desktop
// provider: real desktop mail clients (Thunderbird) in a headless sway,
// end to end.
//
// Everything is real: the capture harness (assessProviders +
// executePlan) with the registered imap and assets services (Dovecot run
// as the user, the loopback asset server and egress guard), the
// provider with sway (wlroots' headless backend, software renderer),
// grim, wtype, a private D-Bus session bus and Thunderbird from the dev
// shell, the stories built by the library's story driver, and the PNGs
// decoded with the capture tools' own PNG codec. No mocks.
//
// The vacuity guard of the capture test reads the PNG itself: OCR
// (tesseract, English only, from the dev shell) must find the story's
// own heading in the cropped body. It reads pixels, so an empty or
// wrong window, a crop of the client's chrome or a capture of the
// wrong message fails it, whatever the client reports about itself.
//
// One test seam of the provider is used, justified: further origins
// the client may load remote content from (`extraRemoteOrigins`), so a
// message with an image on a foreign host makes Thunderbird request it
// and the test can see that the request ends at the egress guard. The
// provider itself allows the assets service's origin only. One test
// reaches into the running Thunderbird instance's Marionette connection
// (a private field) to put a text field in its window and read back
// what wtype typed into it: the session's input path is what is under
// test there, and the client offers no other way to read a keystroke
// back.
//
// Some tests deliver a small hand-written message instead of a story:
// a stale asset hash, a foreign image.
//
// Every run uses scratch state roots, a scratch calibration root and a
// scratch socket base, so the sweeps under test see only this file's
// runs. Linux only (the provider is, and the teardown tests read
// /proc).
//
// The email-shots CLI is also run for real, in a scratch clone of this
// checkout (its capture tools, library sources and story assets copied
// in and committed, so it runs the code under test): after a previous
// run, `--clients thunderbird` captures the real Thunderbird.
//
// Needs `just email-shots-build` (which `just test-desktop` runs first)
// and the dev shell. Run with:
//   node --test tools/capture/providers/linux_desktop.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import {
  execFileSync,
  spawn,
  spawnSync,
  type ChildProcess,
} from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { readPng, type RgbaImage } from "../contact_sheet.ts";
import { AssetsService } from "./assets_service.ts";
import {
  calibrationPath,
  checkCalibration,
  MARKER_PX,
  readCalibration,
} from "./desktop_clients.ts";
import {
  cropImage,
  DESKTOP_SOCKET_PREFIX,
  DesktopSession,
} from "./desktop_session.ts";
import {
  assessProviders,
  candidateProviders,
  executePlan,
  type Finished,
  type MatrixSpec,
  messageMap,
  routeRequests,
} from "./harness.ts";
import { DovecotService } from "./imap_service.ts";
import {
  defaultDrivers,
  LinuxDesktopProvider,
  type LinuxDesktopOptions,
} from "./linux_desktop.ts";
import type { Marionette } from "./marionette.ts";
import { processAlive } from "./owned_state.ts";
import { registeredServices } from "./services.ts";
import { ThunderbirdDriver } from "./thunderbird_driver.ts";
import type { Scheme, StoryMessage, ViewportSpec } from "./types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const providersDir = resolve(scriptDir);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const driver = join(repoRoot, "build", "capture", "build-stories");
// Short: the socket base must leave room for the socket paths.
const scratch = mkdtempSync("/tmp/ie-ld-");
const socketBase = join(scratch, "rt");
const mailRoot = join(scratch, "mail");
const deskRoot = join(scratch, "desk");
const calRoot = join(scratch, "cal");
mkdirSync(socketBase, { mode: 0o700 });
const env = { ...process.env, XDG_RUNTIME_DIR: socketBase };

const MOBILE: ViewportSpec = { name: "mobile", width: 375, dpr: 3 };
const DESKTOP: ViewportSpec = { name: "desktop", width: 800, dpr: 1 };
const LOGO = "/2494f1185a00ab29/logo.png";

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

function sha256(b: Uint8Array): string {
  return createHash("sha256").update(b).digest("hex");
}

function rec(v: unknown): Record<string, unknown> {
  assert.ok(typeof v === "object" && v !== null, JSON.stringify(v));
  return v as Record<string, unknown>;
}

// --- /proc helpers. -------------------------------------------------

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
    return {
      ppid: Number(f[1]),
      start: f[19]!,
      comm: s.slice(s.indexOf("(") + 1, s.lastIndexOf(")")),
    };
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

// Processes whose command line mentions this file's scratch directory
// (every sway, bus, Thunderbird and Dovecot this file starts names it).
function scratchProcesses(): string[] {
  const out: string[] = [];
  for (const e of readdirSync("/proc")) {
    if (!/^\d+$/.test(e) || Number(e) === process.pid) continue;
    try {
      const cmd = readFileSync(`/proc/${e}/cmdline`, "latin1");
      if (cmd.includes(scratch)) out.push(`${e}: ${cmd.replace(/\0/g, " ")}`);
    } catch {
      // gone
    }
  }
  return out;
}

// The pid, as seen from here, of the process below `root` whose pid in
// its own (innermost) PID namespace is `inner`.
function outerPid(inner: number, root: number): number {
  for (const p of tree(root)) {
    const ns = /^NSpid:\s+(.*)$/m
      .exec(readFileSync(`/proc/${p.pid}/status`, "latin1"))?.[1]
      ?.trim()
      .split(/\s+/);
    if (
      ns !== undefined &&
      Number(ns[ns.length - 1]) === inner &&
      ns.length > 1
    )
      return p.pid;
  }
  throw new Error(`no process below ${root} has inner pid ${inner}`);
}

// The value of the probe field, once it equals `want` (or what it holds
// after five seconds).
async function fieldValue(m: Marionette, want: string): Promise<string> {
  const t0 = Date.now();
  for (;;) {
    const v = (await m.script(
      `return document.getElementById("ie-wtype-probe").value;`,
    )) as string;
    if (v === want || Date.now() - t0 > 5000) return v;
    await new Promise((r) => setTimeout(r, 50));
  }
}

// What a finished run left in the scratch state roots.
function staleScratch(): string[] {
  const out: string[] = [];
  for (const root of [deskRoot, mailRoot])
    if (existsSync(root))
      for (const e of readdirSync(root)) out.push(join(root, e));
  for (const e of readdirSync(socketBase)) out.push(join(socketBase, e));
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

// --- Pixels. ----------------------------------------------------------

function meanLuminance(img: RgbaImage): number {
  let sum = 0;
  for (let i = 0; i < img.data.length; i += 4)
    sum +=
      0.2126 * img.data[i]! +
      0.7152 * img.data[i + 1]! +
      0.0722 * img.data[i + 2]!;
  return sum / (img.width * img.height);
}

let ocrSeq = 0;
function ocr(png: Uint8Array): string {
  const p = join(scratch, `ocr-${++ocrSeq}.png`);
  writeFileSync(p, png);
  const r = spawnSync("tesseract", [p, "-", "-l", "eng"], {
    encoding: "utf8",
  });
  assert.equal(r.status, 0, `tesseract: ${r.stderr}`);
  return r.stdout;
}

function headingOf(html: string): string {
  const m = /<h1\b[^>]*>([\s\S]*?)<\/h1>/i.exec(html);
  assert.ok(m !== null, "the story has no h1");
  return m[1]!
    .replace(/<[^>]*>/g, "")
    .replace(/&#(\d+);/g, (_m, d: string) => String.fromCodePoint(Number(d)))
    .replace(/&amp;/g, "&")
    .trim();
}

// --- Stories and crafted messages. -----------------------------------

let receipt: StoryMessage;
let alert: StoryMessage;
before(() => {
  assert.ok(
    existsSync(driver),
    `${driver} missing: run \`just email-shots-build\` first`,
  );
  const out = join(scratch, "stories");
  const r = spawnSync(driver, [out, "receipt", "alert"], {
    encoding: "utf8",
    env: { ...process.env, ISONIM_CAPTURE_FIXTURES: "1" },
  });
  assert.equal(r.status, 0, r.stderr);
  const manifest = JSON.parse(
    readFileSync(join(out, "manifest.json"), "utf8"),
  ) as { stories: { story: string; eml: string; html: string }[] };
  const load = (name: string): StoryMessage => {
    const m = manifest.stories.find((s) => s.story === name)!;
    return {
      story: m.story,
      mime: readFileSync(join(out, m.eml)),
      html: readFileSync(join(out, m.html), "utf8"),
    };
  };
  receipt = load("receipt");
  alert = load("alert");
});

// A one-part 7bit HTML message with short lines.
function crafted(story: string, body: string): StoryMessage {
  const html = `<!doctype html><html><body>\r\n${body}\r\n</body></html>`;
  const mime = Buffer.from(
    [
      "From: IsoNim Shots <shots@example.test>",
      "To: qa@example.test",
      `Subject: [shots] ${story}`,
      "Date: Thu, 01 Jan 2026 12:00:00 +0000",
      `Message-ID: <${story}@example.test>`,
      "MIME-Version: 1.0",
      "Content-Type: text/html; charset=utf-8",
      "Content-Transfer-Encoding: 7bit",
      "",
      html,
      "",
    ].join("\r\n"),
  );
  return { story, mime, html };
}

// --- Running the real harness. -------------------------------------

interface Row {
  entry: Finished["entry"];
  reason: string | null;
  meta: Record<string, unknown>;
  metaText: string;
  png: Buffer | null;
}

let runSeq = 0;
async function runDesktop(
  stories: StoryMessage[],
  opts: {
    viewports?: ViewportSpec[];
    schemes?: Scheme[];
    cold?: boolean;
    provider?: LinuxDesktopOptions;
  } = {},
): Promise<{ rows: Row[]; wallMs: number; passwords: string[] }> {
  const run = `ld-${process.pid}-${++runSeq}`;
  const runDir = join(scratch, "runs", run);
  const provider = new LinuxDesktopProvider({
    env,
    stateRoot: deskRoot,
    calibrationRoot: calRoot,
    ...opts.provider,
  });
  const spec: MatrixSpec = {
    stories: stories.map((s) => ({
      story: s.story,
      mimeSha256: sha256(s.mime),
    })),
    families: ["thunderbird"],
    clients: provider.clients().map((c) => c.clientId),
    backends: null,
    viewports: opts.viewports ?? [DESKTOP],
    schemes: opts.schemes ?? ["light"],
    images: ["on"],
  };
  const t0 = Date.now();
  const { availability, services } = await assessProviders(
    candidateProviders([provider], spec),
    { run, runDir },
    {
      ...registeredServices(),
      imap: () => new DovecotService({ stateRoot: mailRoot, env }),
    },
  );
  if (availability.get(provider.id)?.state !== "ok") {
    await services.stopAll();
    assert.deepEqual(availability.get(provider.id), { state: "ok" });
  }
  // The per-run IMAP passwords, to show that none reaches a provenance.
  const creds = services.handlesFor(provider).imap?.credentials ?? {};
  const finished: Finished[] = [];
  await executePlan(
    [provider],
    availability,
    routeRequests([provider], availability, spec),
    messageMap(stories),
    {
      run,
      session: null,
      runDir,
      library: { commit: "c", dirty: false, tree_hash: "t" },
      cacheRoot: join(runDir, ".cache"),
      noCache: true,
      assert: false,
      cold: opts.cold ?? false,
      services,
    },
    (f) => finished.push(f),
  );
  const wallMs = Date.now() - t0;
  const rows = finished.map((f) => {
    const metaText = readFileSync(join(runDir, f.entry.meta!), "utf8");
    return {
      entry: f.entry,
      reason: typeof f.line.reason === "string" ? f.line.reason : null,
      meta: JSON.parse(metaText) as Record<string, unknown>,
      metaText,
      png:
        f.entry.png === null ? null : readFileSync(join(runDir, f.entry.png)),
    };
  });
  return { rows, wallMs, passwords: Object.values(creds) };
}

// The exact client and compositor versions, read here independently.
function versions(): { thunderbird: string; sway: string } {
  const tb = /Thunderbird (\S+)/.exec(
    execFileSync("thunderbird", ["--version"], { encoding: "utf8" }),
  )?.[1];
  const sway = /sway version (\S+)/.exec(
    execFileSync("sway", ["--version"], { encoding: "utf8" }),
  )?.[1];
  assert.ok(tb !== undefined && sway !== undefined);
  return { thunderbird: tb, sway };
}

describe("linux desktop", { skip: process.platform !== "linux" }, () => {
  // The receipt in every desktop client, light and dark; mobile asked
  // for too, to show it is not one a desktop client renders.
  let main: Awaited<ReturnType<typeof runDesktop>>;
  before(async () => {
    main = await runDesktop([receipt], {
      viewports: [MOBILE, DESKTOP],
      schemes: ["light", "dark"],
    });
  });

  it("e2e linux desktop captures the receipt story in every client", () => {
    const clients = defaultDrivers().map((d) => d.clientId);
    assert.ok(clients.includes("thunderbird"), clients.join(", "));
    const v = versions();
    const heading = headingOf(receipt.html);
    assert.equal(heading, "Receipt #1234");
    const accounts = new Set<string>();
    const luminance: Record<string, Record<string, number>> = {};
    for (const client of clients) {
      const mine = main.rows.filter((r) => r.entry.client === client);
      // Mobile: not a viewport a desktop client renders.
      const mobile = mine.filter((r) => r.entry.viewport === "mobile");
      assert.equal(mobile.length, 2);
      for (const r of mobile) {
        assert.equal(r.entry.status, "not-applicable");
        assert.match(String(r.reason), /renders: desktop/);
      }
      const done = mine.filter((r) => r.entry.viewport === "desktop");
      assert.deepEqual(done.map((r) => r.entry.scheme).sort(), [
        "dark",
        "light",
      ]);
      for (const { entry, reason, meta, metaText, png } of done) {
        const id = `${client}-${entry.scheme}`;
        assert.equal(entry.status, "done", `${id}: ${reason}`);
        assert.equal(meta.provider, "linux-desktop");
        assert.equal(meta.via, "inject");
        assert.equal(meta.approximation, false);
        // The client build, read from the client itself, in provenance.
        const c = rec(meta.client);
        assert.equal(c.id, client);
        assert.equal(c.build, `thunderbird-${v.thunderbird}+sway-${v.sway}`);
        assert.equal(c.version, v.thunderbird);
        assert.match(String(c.account), /^c\d+-[0-9a-f]{8}$/);
        accounts.add(String(c.account));
        // The account user, never its password.
        for (const p of main.passwords)
          assert.ok(!metaText.includes(p), `${id}: a password in provenance`);
        assert.doesNotMatch(metaText, /password/i);
        // The requested scheme, as the client applied it.
        assert.equal(rec(meta.scheme_applied).dark, entry.scheme === "dark");
        // The image: rewritten to the assets service, served 200, and
        // loaded by the client.
        const rewrite = rec(meta.asset_rewrite);
        assert.equal(rewrite.count, 1);
        assert.match(String(rewrite.to), /^http:\/\/127\.0\.0\.1:\d+\/$/);
        const images = rec(meta.images);
        assert.deepEqual(images.expected, [LOGO]);
        assert.deepEqual(images.missing, []);
        assert.ok(
          (images.served as { path: string; status: number }[]).some(
            (s) => s.path === LOGO && s.status === 200,
          ),
        );
        assert.ok(Array.isArray(meta.assets_log));
        assert.deepEqual(rec(meta.network).blocked, []);
        // Cropped to the message body: the PNG is the crop the client's
        // geometry gave, below the client's header, full width.
        const crop = rec(rec(meta.crop).device);
        const img = readPng(png!);
        assert.equal(img.width, Number(crop.width), id);
        assert.equal(img.height, Number(crop.height), id);
        assert.equal(img.width, DESKTOP.width * DESKTOP.dpr, id);
        assert.ok(Number(crop.y) > 60, `${id}: crop at y=${String(crop.y)}`);
        // Vacuity guard: the crop shows the story's own heading.
        const text = ocr(png!);
        assert.ok(
          text.includes(heading),
          `${id}: OCR of the crop does not show '${heading}': ${JSON.stringify(text)}`,
        );
        (luminance[client] ??= {})[entry.scheme] = meanLuminance(img);
      }
      // Light is light and dark is dark, in the pixels.
      const l = luminance[client]!;
      assert.ok(l.light! > 150, `${client} light: mean luminance ${l.light}`);
      assert.ok(l.dark! < 110, `${client} dark: mean luminance ${l.dark}`);
    }
    assert.equal(accounts.size, 2 * clients.length, "one account per capture");
    process.stderr.write(
      `linux-desktop: mean luminance ${JSON.stringify(luminance)}\n`,
    );
  });

  it("e2e linux desktop warm capture latency is recorded", async () => {
    // Warm: one session for the run, four captures (two stories, two
    // schemes). Cold: a fresh session and client per capture.
    const warm = await runDesktop([receipt, alert], {
      schemes: ["light", "dark"],
    });
    const cold = await runDesktop([receipt], {
      schemes: ["light", "dark"],
      cold: true,
    });
    const p50 = (xs: number[]): number => {
      const s = [...xs].sort((a, b) => a - b);
      return s[Math.floor((s.length - 1) / 2)]!;
    };
    const steps = [
      "account",
      "inject",
      "scheme",
      "configure",
      "sync",
      "open",
      "settle",
      "capture",
      "total",
    ];
    const totals = { warm: [] as number[], cold: [] as number[] };
    for (const [mode, run] of [
      ["warm", warm],
      ["cold", cold],
    ] as const) {
      assert.equal(run.rows.length, mode === "warm" ? 4 : 2);
      const sessions = new Set<string>();
      for (const { entry, reason, meta } of run.rows) {
        assert.equal(entry.status, "done", `${mode}: ${reason}`);
        const t = rec(meta.timing_ms);
        for (const s of steps)
          assert.ok(
            typeof t[s] === "number" && (t[s] as number) >= 0,
            `${mode} ${s}: ${String(t[s])}`,
          );
        assert.ok(
          (t.total as number) >=
            (t.open as number) + (t.settle as number) + (t.capture as number),
        );
        const compositor = rec(meta.compositor);
        assert.equal(compositor.warm, mode === "warm");
        // Cold captures start a session and a client of their own.
        if (mode === "cold") {
          assert.ok((t.session as number) > 0 && (t.launch as number) > 0);
        } else {
          assert.equal(t.session, undefined);
        }
        sessions.add(String(rec(rec(meta.client).window).main_window));
        totals[mode].push(t.total as number);
        process.stderr.write(
          `linux-desktop latency: ${mode} ${entry.story} ${entry.scheme}: ${steps
            .concat(mode === "cold" ? ["session", "launch"] : [])
            .map((s) => `${s} ${Math.round(Number(t[s]))}`)
            .join(", ")}\n`,
        );
      }
    }
    // Recorded, not asserted (targets: 10 s p50 warm, 30 s cold).
    process.stderr.write(
      `linux-desktop latency: warm p50 ${Math.round(p50(totals.warm))} ms over ${totals.warm.length} captures (target 10000 ms); cold p50 ${Math.round(p50(totals.cold))} ms over ${totals.cold.length} (target 30000 ms); run wall warm ${warm.wallMs} ms, cold ${cold.wallMs} ms (session, client start and calibration check included)\n`,
    );
  });

  it("the crop calibration runs for a new client build, is recorded, and is skipped while the build is unchanged", async () => {
    const root = join(scratch, "cal-fresh");
    const once = async (): Promise<Record<string, unknown>> => {
      const { rows } = await runDesktop([receipt], {
        provider: { calibrationRoot: root },
      });
      assert.equal(rows.length, 1);
      assert.equal(rows[0]!.entry.status, "done", rows[0]!.reason ?? "");
      return rec(rec(rows[0]!.meta.crop).calibration);
    };
    // No record: the run calibrates and records the build.
    const first = await once();
    assert.equal(first.state, "calibrated in this run");
    const path = calibrationPath(root, "linux-desktop", "thunderbird");
    const record = readCalibration(root, "linux-desktop", "thunderbird")!;
    assert.ok(record !== null, `no record at ${path}`);
    const v = versions();
    assert.equal(record.build, `thunderbird-${v.thunderbird}+sway-${v.sway}`);
    assert.deepEqual(record.checks.map((c) => c.scheme).sort(), [
      "dark",
      "light",
    ]);
    for (const c of record.checks)
      for (const corner of Object.values(c.corners))
        assert.deepEqual(corner, { h: MARKER_PX, v: MARKER_PX });
    // Same build: no calibration.
    assert.equal((await once()).state, "recorded");
    // Another build recorded (an upgrade since): calibrated again.
    writeFileSync(
      path,
      JSON.stringify({ ...record, build: "thunderbird-0.0+sway-0.0" }),
    );
    assert.equal((await once()).state, "calibrated in this run");
    assert.equal(
      readCalibration(root, "linux-desktop", "thunderbird")!.build,
      record.build,
    );
  });

  it("the calibration check holds the crop to exactly the message body", async () => {
    const provider = new LinuxDesktopProvider({
      env,
      stateRoot: deskRoot,
      calibrationRoot: join(scratch, "cal-check"),
    });
    const run = `ld-${process.pid}-cal`;
    const { availability, services } = await assessProviders(
      [provider],
      { run, runDir: join(scratch, "runs", run) },
      {
        ...registeredServices(),
        imap: () => new DovecotService({ stateRoot: mailRoot, env }),
      },
    );
    try {
      assert.deepEqual(availability.get(provider.id), { state: "ok" });
      await provider.prepare({
        run,
        session: null,
        runDir: join(scratch, "runs", run),
        planned: [],
        assert: false,
        cold: false,
        services: services.handlesFor(provider),
      });
      const r = await provider.calibrate("thunderbird", true);
      assert.equal(r.ok, true, r.problems.join("; "));
      assert.equal(r.checks.length, 2);
      for (const c of r.checks) {
        assert.equal(
          c.check.ok,
          true,
          `${c.scheme}: ${c.check.problems.join("; ")}`,
        );
        // A crop one device pixel off in any direction, or one pixel
        // larger or smaller, is caught.
        const off = [
          { x: 1, y: 0, w: 0, h: 0 },
          { x: -1, y: 0, w: 0, h: 0 },
          { x: 0, y: 1, w: 0, h: 0 },
          { x: 0, y: -1, w: 0, h: 0 },
          { x: 0, y: 0, w: 1, h: 0 },
          { x: 0, y: 0, w: -1, h: 0 },
          { x: 0, y: 0, w: 0, h: 1 },
          { x: 0, y: 0, w: 0, h: -1 },
        ];
        for (const o of off) {
          const shifted = cropImage(c.full, {
            x: c.crop.x + o.x,
            y: c.crop.y + o.y,
            width: c.crop.width + o.w,
            height: c.crop.height + o.h,
          });
          // A crop that runs off the output's edge is clamped (and so
          // is no longer shifted); only the in-bounds variants count.
          if (
            c.crop.x + o.x < 0 ||
            c.crop.x + o.x + c.crop.width + o.w > c.full.width
          )
            continue;
          const check = checkCalibration(shifted, c.viewport.dpr);
          assert.equal(
            check.ok,
            false,
            `${c.scheme}: a crop off by ${JSON.stringify(o)} passed`,
          );
        }
      }
    } finally {
      await provider.dispose();
      await services.stopAll();
    }
  });

  it("fails a capture when an image the story contains is not served 200 by the assets service", async () => {
    const stale = crafted(
      "stale",
      '<h1>Stale</h1><img src="https://x.test/0000000000000000/logo.png" width="80" height="20" alt="">',
    );
    const { rows } = await runDesktop([stale]);
    assert.equal(rows.length, 1);
    const [r] = rows;
    assert.equal(r!.entry.status, "failed");
    assert.match(
      String(r!.reason),
      /not served 200 by the assets service and loaded by the client: \/0000000000000000\/logo\.png/,
    );
    const images = rec(r!.meta.images);
    assert.deepEqual(images.missing, ["/0000000000000000/logo.png"]);
    assert.ok(
      (images.served as { path: string; status: number }[]).some(
        (s) => s.path === "/0000000000000000/logo.png" && s.status === 404,
      ),
    );
  });

  it("a remote image from any other host ends at the egress guard", async () => {
    const foreign = crafted(
      "foreign",
      [
        "<h1>Foreign</h1>",
        '<img src="https://x.test/2494f1185a00ab29/logo.png" width="80" height="20" alt="">',
        '<img src="http://foreign.test/plain.png" width="10" height="10" alt="">',
        '<img src="https://foreign.test/tls.png" width="10" height="10" alt="">',
      ].join("\r\n"),
    );
    const { rows } = await runDesktop([foreign], {
      provider: {
        extraRemoteOrigins: ["http://foreign.test", "https://foreign.test"],
      },
    });
    assert.equal(rows.length, 1);
    const [r] = rows;
    assert.equal(r!.entry.status, "done", r!.reason ?? "");
    const blocked = rec(r!.meta.network).blocked as {
      url: string;
      status: number;
      via: string;
    }[];
    assert.ok(
      blocked.some(
        (b) =>
          b.url === "http://foreign.test/plain.png" &&
          b.status === 403 &&
          b.via === "proxy",
      ),
      JSON.stringify(blocked),
    );
    assert.ok(
      blocked.some((b) => b.url === "foreign.test:443" && b.status === 403),
      JSON.stringify(blocked),
    );
    // The story image is still served, directly (loopback is never
    // proxied).
    const served = rec(r!.meta.images).served as {
      path: string;
      status: number;
      via: string;
    }[];
    assert.ok(
      served.some(
        (s) => s.path === LOGO && s.status === 200 && s.via === "direct",
      ),
      JSON.stringify(served),
    );
  });

  describe("the session", () => {
    let assets: AssetsService;
    let session: DesktopSession;
    let instance: Awaited<ReturnType<ThunderbirdDriver["launch"]>>;
    before(async () => {
      assets = new AssetsService();
      const handle = await assets.start({ run: "s", runDir: scratch });
      session = new DesktopSession({ env, stateRoot: deskRoot });
      const d = new ThunderbirdDriver();
      await session.start({
        run: `ld-${process.pid}-session`,
        instance: "thunderbird",
        output: { width: 800, height: 600, scale: 1 },
        env: d.sessionEnv(),
        forward: [Number(new URL(handle.baseUrl).port)],
      });
      instance = await d.launch(session, {
        assets: handle,
        extraRemoteOrigins: [],
      });
    });
    after(async () => {
      await instance?.quit();
      await session?.stop();
      await assets?.stop();
    });

    it("is isolated: its own HOME and XDG directories, a private session bus, no system bus, loopback-only network, UTC, a fixed locale and the pinned fonts", () => {
      const win = session.windows().find((w) => w.appId === "thunderbird");
      assert.ok(win !== undefined, JSON.stringify(session.windows()));
      // sway reports the pid inside the session's PID namespace.
      const tb = { pid: outerPid(win.pid, session.pid!) };
      const environ = new Map(
        readFileSync(`/proc/${tb.pid}/environ`, "latin1")
          .split("\0")
          .filter((kv) => kv.includes("="))
          .map((kv) => [
            kv.slice(0, kv.indexOf("=")),
            kv.slice(kv.indexOf("=") + 1),
          ]),
      );
      assert.equal(environ.get("HOME"), session.home);
      for (const k of [
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "XDG_CACHE_HOME",
      ])
        assert.ok(
          environ.get(k)?.startsWith(session.home + "/"),
          `${k}=${environ.get(k)}`,
        );
      assert.equal(environ.get("XDG_RUNTIME_DIR"), session.runtimeDir);
      assert.ok(
        environ.get("DBUS_SESSION_BUS_ADDRESS")?.includes(session.runtimeDir),
        environ.get("DBUS_SESSION_BUS_ADDRESS"),
      );
      const system = environ.get("DBUS_SYSTEM_BUS_ADDRESS") ?? "";
      assert.ok(system.startsWith(`unix:path=${session.stateDir}/`), system);
      assert.equal(existsSync(system.slice("unix:path=".length)), false);
      assert.equal(environ.get("TZ"), "UTC");
      assert.equal(environ.get("LANG"), "en_US.UTF-8");
      assert.equal(environ.get("LC_ALL"), "en_US.UTF-8");
      assert.equal(environ.get("FONTCONFIG_FILE"), process.env.FONTCONFIG_FILE);
      for (const p of (environ.get("PATH") ?? "").split(":"))
        assert.ok(p.startsWith("/nix/store/"), `PATH entry ${p}`);
      // In a network namespace of its own whose only interface is
      // loopback: nothing it does can leave the machine.
      assert.notEqual(
        readlinkSync(`/proc/${tb.pid}/ns/net`),
        readlinkSync("/proc/self/ns/net"),
      );
      const ifaces = readFileSync(`/proc/${tb.pid}/net/dev`, "latin1")
        .split("\n")
        .slice(2)
        .map((l) => l.split(":")[0]!.trim())
        .filter((n) => n !== "");
      assert.deepEqual(ifaces, ["lo"]);
      // In a PID namespace of its own (two pids: outer and inner).
      const nspid = /^NSpid:\s+(.*)$/m
        .exec(readFileSync(`/proc/${tb.pid}/status`, "latin1"))?.[1]
        ?.trim()
        .split(/\s+/);
      assert.equal(nspid?.length, 2, `NSpid ${String(nspid)}`);
      // The bus is the session's, configured here, activating nothing.
      const bus = tree(session.pid!).find((p) => p.comm === "dbus-daemon");
      assert.ok(bus !== undefined, JSON.stringify(tree(session.pid!)));
      const cmd = readFileSync(`/proc/${bus.pid}/cmdline`, "latin1");
      assert.ok(cmd.includes(join(session.stateDir, "bus.conf")), cmd);
      assert.doesNotMatch(
        readFileSync(join(session.stateDir, "bus.conf"), "utf8"),
        /servicedir/,
      );
    });

    it("sets the output mode and scale through swaymsg and captures it with grim", () => {
      session.setOutput({ width: 700, height: 500, scale: 2 });
      const out = JSON.parse(session.swaymsg(["-t", "get_outputs", "-r"])) as {
        name: string;
        scale: number;
        rect: { width: number; height: number };
        current_mode: { width: number; height: number };
      }[];
      assert.equal(out.length, 1);
      assert.equal(out[0]!.scale, 2);
      assert.deepEqual(out[0]!.rect.width, 700);
      assert.deepEqual(out[0]!.current_mode, {
        ...out[0]!.current_mode,
        width: 1400,
        height: 1000,
      });
      const shot = session.screenshot();
      assert.equal(shot.width, 1400);
      assert.equal(shot.height, 1000);
      session.setOutput({ width: 800, height: 600, scale: 1 });
      assert.equal(session.screenshot().width, 800);
    });

    it("types into the focused client window through wtype", async () => {
      // The instance's Marionette connection (see the file header).
      const m = (instance as unknown as { m: Marionette }).m;
      await m.script(`
        const input = document.createElementNS("http://www.w3.org/1999/xhtml", "input");
        input.id = "ie-wtype-probe";
        document.documentElement.prepend(input);
        input.focus();
        return document.activeElement === input;`);
      const main = session.windows().find((w) => w.appId === "thunderbird")!;
      session.swaymsg([`[con_id=${main.id}]`, "focus"]);
      session.type("typed by wtype 42");
      assert.equal(
        await fieldValue(m, "typed by wtype 42"),
        "typed by wtype 42",
      );
      // A key with a modifier: select all, then type over it.
      session.key("ctrl", "a");
      session.type("x");
      assert.equal(await fieldValue(m, "x"), "x");
      await m.script(`document.getElementById("ie-wtype-probe").remove();`);
    });
  });

  it("leaves no sway, bus, Thunderbird or Dovecot process and no state after the runs", () => {
    assert.deepEqual(scratchProcesses(), []);
    assert.deepEqual(staleScratch(), []);
  });
});

// --- Nothing outlives the run. --------------------------------------

const CHILD = `
import { DesktopSession } from "${providersDir}/desktop_session.ts";
import { AssetsService } from "${providersDir}/assets_service.ts";
import { ThunderbirdDriver } from "${providersDir}/thunderbird_driver.ts";
import { installSignalTeardown } from "${providersDir}/services.ts";
const [run, deskRoot] = process.argv.slice(2);
installSignalTeardown();
const assets = new AssetsService();
const handle = await assets.start({ run, runDir: deskRoot });
const s = new DesktopSession({ stateRoot: deskRoot });
const d = new ThunderbirdDriver();
await s.start({ run, instance: "thunderbird", output: { width: 800, height: 600, scale: 1 }, env: d.sessionEnv() });
await d.launch(s, { assets: handle, extraRemoteOrigins: [] });
process.stdout.write(JSON.stringify({ pid: s.pid, stateDir: s.stateDir, runtimeDir: s.runtimeDir }) + "\\n");
setInterval(() => {}, 1000);
`;

describe(
  "linux desktop teardown",
  { skip: process.platform !== "linux" },
  () => {
    const childScript = join(scratch, "session.ts");
    before(() => writeFileSync(childScript, CHILD));

    interface Up {
      child: ChildProcess;
      exit: Promise<{ code: number | null; signal: string | null }>;
      stateDir: string;
      runtimeDir: string;
      procs: Proc[];
    }

    let seq = 0;
    async function startRun(): Promise<Up> {
      const run = `ldt-${process.pid}-${++seq}`;
      const child = spawn(process.execPath, [childScript, run, deskRoot], {
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      spawned.push(child.pid!);
      let stdout = "";
      let stderr = "";
      child.stdout!.on("data", (d: Buffer) => (stdout += d.toString()));
      child.stderr!.on("data", (d: Buffer) => (stderr += d.toString()));
      const exit = new Promise<{ code: number | null; signal: string | null }>(
        (ok) => child.once("exit", (code, signal) => ok({ code, signal })),
      );
      const up = await waitFor(
        () => stdout.includes("\n") || child.exitCode !== null,
        90000,
      );
      assert.ok(up && child.exitCode === null, `not up: ${stderr}`);
      const info = JSON.parse(stdout.split("\n")[0]!) as {
        pid: number;
        stateDir: string;
        runtimeDir: string;
      };
      const procs = tree(info.pid);
      for (const comm of ["sway", "dbus-daemon"])
        assert.ok(
          procs.some((p) => p.comm === comm),
          `${comm}: ${JSON.stringify(procs)}`,
        );
      assert.ok(
        procs.some((p) =>
          /thunderbird|firefox|Web Content|Isolated/i.test(p.comm),
        ),
        JSON.stringify(procs),
      );
      return {
        child,
        exit,
        stateDir: info.stateDir,
        runtimeDir: info.runtimeDir,
        procs,
      };
    }

    const alive = (procs: Proc[]): Proc[] =>
      procs.filter((p) => processAlive(p));

    it("SIGTERM: the run exits 143 and leaves no sway, bus or Thunderbird process and no state", async () => {
      const { child, exit, stateDir, runtimeDir, procs } = await startRun();
      child.kill("SIGTERM");
      assert.deepEqual(await exit, { code: 143, signal: null });
      assert.ok(
        await waitFor(() => alive(procs).length === 0, 5000),
        `still running: ${JSON.stringify(alive(procs))}`,
      );
      assert.equal(existsSync(stateDir), false);
      assert.equal(existsSync(runtimeDir), false);
    });

    it("SIGKILL: the whole session dies with the run, and the next start sweeps what it left", async () => {
      const { child, exit, stateDir, runtimeDir, procs } = await startRun();
      child.kill("SIGKILL");
      assert.equal((await exit).signal, "SIGKILL");
      assert.ok(
        await waitFor(() => alive(procs).length === 0, 5000),
        `survived the run: ${JSON.stringify(alive(procs))}`,
      );
      assert.ok(existsSync(join(stateDir, "owner.json")));
      assert.ok(existsSync(join(runtimeDir, "owner.json")));
      assert.ok(runtimeDir.includes(`/${DESKTOP_SOCKET_PREFIX}`));
      const next = new DesktopSession({ env, stateRoot: deskRoot });
      const info = await next.start({
        run: `ldt-next-${process.pid}`,
        instance: "probe",
        output: { width: 640, height: 480, scale: 1 },
      });
      try {
        assert.ok(info.swept.includes(stateDir), JSON.stringify(info.swept));
        assert.ok(info.swept.includes(runtimeDir), JSON.stringify(info.swept));
        assert.equal(existsSync(stateDir), false);
        assert.equal(existsSync(runtimeDir), false);
      } finally {
        await next.stop();
      }
      assert.deepEqual(scratchProcesses(), []);
      assert.deepEqual(staleScratch(), []);
    });
  },
);

// --- The CLI. ------------------------------------------------------------

describe(
  "email-shots captures the real Thunderbird when named",
  { skip: process.platform !== "linux" },
  () => {
    const briefDriver = join(repoRoot, "build", "review", "brief-driver");
    const clone = join(scratch, "clone");
    const cliRuntime = join(scratch, "crt");
    const shots = join(clone, "build", "email-shots");

    const git = (args: string[]): string =>
      execFileSync(
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
        { cwd: clone, encoding: "utf8" },
      );

    function cli(
      name: string,
      args: string[],
    ): {
      status: number;
      stderr: string;
      entries: {
        client: string;
        family: string;
        backend: string;
        status: string;
        png: string | null;
      }[];
    } {
      appendFileSync(join(clone, "docs", "sending.md"), `\nedit ${name}\n`);
      const out = join(shots, name);
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
          out,
          ...args,
        ],
        {
          cwd: clone,
          encoding: "utf8",
          env: { ...process.env, XDG_RUNTIME_DIR: cliRuntime },
        },
      );
      const index = join(out, "index.json");
      return {
        status: r.status ?? 1,
        stderr: r.stderr,
        entries: existsSync(index)
          ? (JSON.parse(readFileSync(index, "utf8")) as ReturnType<
              typeof cli
            >["entries"])
          : [],
      };
    }

    before(() => {
      mkdirSync(cliRuntime, { mode: 0o700 });
      execFileSync("git", [
        "clone",
        "--quiet",
        "--no-hardlinks",
        repoRoot,
        clone,
      ]);
      for (const sub of [
        join("tools", "capture"),
        "src",
        join("tests", "stories", "assets"),
      ]) {
        rmSync(join(clone, sub), { recursive: true, force: true });
        cpSync(join(repoRoot, sub), join(clone, sub), {
          recursive: true,
          filter: (src) => !src.includes("node_modules"),
        });
      }
      git(["add", "-A"]);
      git(["commit", "--quiet", "--allow-empty", "-m", "code under test"]);
      const seed = cli("seed", [
        "receipt",
        "--full",
        "--families",
        "chromium-baseline",
      ]);
      assert.equal(seed.status, 0, seed.stderr);
    });

    it("--clients thunderbird captures the real Thunderbird after a previous run; a bare run does not", () => {
      const named = cli("named", [
        "receipt",
        "--clients",
        "thunderbird",
        "--no-cache",
      ]);
      assert.equal(named.status, 0, named.stderr);
      assert.deepEqual(
        named.entries.map(
          (e) => `${e.backend}/${e.client}/${e.family}/${e.status}`,
        ),
        ["linux-desktop/thunderbird/thunderbird/done"],
      );
      assert.ok(existsSync(join(shots, "named", named.entries[0]!.png!)));
      const bare = cli("bare", ["receipt"]);
      assert.equal(bare.status, 0, bare.stderr);
      assert.ok(bare.entries.length > 0);
      assert.deepEqual([...new Set(bare.entries.map((e) => e.backend))], ["a"]);
      // Nothing of the desktop sessions is left.
      if (existsSync(join(shots, ".desktop")))
        assert.deepEqual(readdirSync(join(shots, ".desktop")), []);
      assert.deepEqual(readdirSync(cliRuntime), []);
      assert.deepEqual(scratchProcesses(), []);
    });
  },
);
