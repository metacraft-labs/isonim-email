// tools/capture/providers/linux_desktop.test.ts — the linux-desktop
// provider: real desktop mail clients (Thunderbird, Evolution, Geary,
// KMail with Akonadi, Claws Mail) in a headless sway, end to end.
//
// Everything is real: the capture harness (assessProviders +
// executePlan) with the registered imap and assets services (Dovecot run
// as the user, the loopback asset server and egress guard), the
// provider with sway (wlroots' headless backend, software renderer),
// grim, wtype, a private D-Bus session bus, the clients from the dev
// shell with their own helper daemons (an accessibility bus,
// Evolution's source registry, a keyring daemon, Akonadi on SQLite),
// the stories built by the library's story driver, and the PNGs decoded
// with the capture tools' own PNG codec. No mocks.
//
// The vacuity guard of the capture test reads the PNG itself: OCR
// (tesseract, English only, from the dev shell) must find the story's
// own heading in the cropped body. It reads pixels, so an empty or
// wrong window, a crop of the client's chrome or a capture of the
// wrong message fails it, whatever the client reports about itself.
//
// Four test seams are used, each justified: further origins the
// client may load remote content from (the provider's
// `extraRemoteOrigins`), so a message with an image on a foreign host
// makes Thunderbird request it and the test can see that the request
// ends at the egress guard (the provider itself allows the assets
// service's origin only); clients whose injected copy keeps the story's
// own image origin (the provider's `withholdImagesFrom`), so one client
// cannot load the story image while the others load the very same
// image at once, which is what shows that each capture's image check
// counts only its own requests; and the accessible name KMail's driver
// looks for in the external-references notice (`noticeLink`), so the
// link is never found and the test can show that the capture fails
// rather than passing without its images; and the number of Claws
// Mail's 'Open in new window' requests its driver drops instead of
// sending (`dropOpenRequests`), because Claws Mail itself drops such a
// request only while its message list is busy, which no test can bring
// about on demand, and the driver's answer to a dropped request (make
// it again, and fail naming every attempt when none is taken) must
// still be shown to work. Nothing else is replaced. One test
// reaches into the running Thunderbird instance's Marionette connection
// (a private field) to put a text field in its window and read back
// what wtype typed into it: the session's input path is what is under
// test there, and the client offers no other way to read a keystroke
// back.
// One test records the requests the accessibility client sends to
// Evolution during a real capture (its request method wrapped, each
// request passed on unchanged), because what must be shown is what the
// driver never asks Evolution: the cells of its lists, whose answers
// crash it while a list changes.
//
// Some tests deliver a small hand-written message instead of a story:
// a stale asset hash, a foreign image, a message whose colours follow
// prefers-color-scheme.
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
// ISONIM_EMAIL_DESKTOP_CLIENTS (a comma-separated list of client ids)
// narrows the clients the multi-client tests run; unset, they run every
// registered client. `just test-desktop` sets it (see the Justfile);
// `just test-desktop-all` does not.
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
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createConnection, createServer } from "node:net";
import { hostname } from "node:os";
import { dirname, join, resolve } from "node:path";
import { readPng, type RgbaImage } from "../contact_sheet.ts";
import { AssetsService } from "./assets_service.ts";
import { A11yClient, type A11yNode } from "./desktop_a11y.ts";
import {
  calibrationPath,
  checkCalibration,
  type DesktopClientDriver,
  MARKER_PX,
  readCalibration,
} from "./desktop_clients.ts";
import {
  cropImage,
  DESKTOP_SOCKET_PREFIX,
  DesktopSession,
  SESSION_DEV_ENTRIES,
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
import { ClawsDriver } from "./claws_driver.ts";
import { KMailDriver } from "./kmail_driver.ts";
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
): { ppid: number; start: string; comm: string; state: string } | null {
  try {
    const s = readFileSync(`/proc/${pid}/stat`, "latin1");
    const f = s.slice(s.lastIndexOf(")") + 2).split(" ");
    return {
      state: f[0]!,
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

// Processes whose command line or environment mentions this file's
// scratch directory: every sway, bus, Dovecot and helper this file
// starts names it in its arguments, and every client and helper daemon
// of a session has its home and runtime directory under it.
function scratchProcesses(environOnly = false): string[] {
  const out: string[] = [];
  for (const e of readdirSync("/proc")) {
    if (!/^\d+$/.test(e) || Number(e) === process.pid) continue;
    try {
      const cmd = readFileSync(`/proc/${e}/cmdline`, "latin1");
      let environ = "";
      try {
        environ = readFileSync(`/proc/${e}/environ`, "latin1");
      } catch {
        // another user's process
      }
      const hit = environOnly
        ? !cmd.includes(scratch) && environ.includes(scratch)
        : cmd.includes(scratch) || environ.includes(scratch);
      if (hit) out.push(`${e}: ${cmd.replace(/\0/g, " ")}`);
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
let boxDark: StoryMessage;
before(() => {
  assert.ok(
    existsSync(driver),
    `${driver} missing: run \`just email-shots-build\` first`,
  );
  const out = join(scratch, "stories");
  const r = spawnSync(driver, [out, "receipt", "alert", "boxDark"], {
    encoding: "utf8",
    env: {
      ...process.env,
      ISONIM_CAPTURE_FIXTURES: "1",
      ISONIM_CAPTURE_LAYOUT: "1",
    },
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
  boxDark = load("boxDark");
});

// A one-part base64 HTML message holding the whole document `html`.
function fromHtml(story: string, html: string): StoryMessage {
  const b64 = Buffer.from(html, "utf8")
    .toString("base64")
    .replace(/(.{76})/g, "$1\r\n");
  const mime = Buffer.from(
    [
      "From: IsoNim Shots <shots@example.test>",
      "To: qa@example.test",
      `Subject: [shots] ${story}`,
      "Date: Thu, 01 Jan 2026 12:00:00 +0000",
      `Message-ID: <${story}@example.test>`,
      "MIME-Version: 1.0",
      "Content-Type: text/html; charset=utf-8",
      "Content-Transfer-Encoding: base64",
      "",
      b64,
      "",
    ].join("\r\n"),
  );
  return { story, mime, html };
}

// `html` without its Thunderbird rules (catalogue R-DRK-08): block 6
// and block 3's copies after the query.
function withoutThunderbirdRules(html: string): string {
  const out = html
    .replace(
      '<style>html:has(.moz-text-html){filter:url("#prefers-color-scheme: dark")}</style>',
      "",
    )
    .replace(/\.moz-text-html \.e-[a-z0-9-]+\{[^}]*light-dark\([^}]*\}/g, "")
    .replace(/body:has\(\.moz-text-html\)\{[^}]*\}/g, "");
  assert.ok(!out.includes("light-dark("), "a Thunderbird copy is left");
  assert.ok(!out.includes(":has("), "a Thunderbird rule is left");
  return out;
}

// The share of an image's pixels that are exactly `hex`.
function colourShare(img: RgbaImage, hex: string): number {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  let n = 0;
  for (let i = 0; i < img.data.length; i += 4)
    if (img.data[i] === r && img.data[i + 1] === g && img.data[i + 2] === b)
      n++;
  return n / (img.width * img.height);
}

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
    // The clients to run (default: Thunderbird).
    clients?: string[];
  } = {},
): Promise<{ rows: Row[]; wallMs: number; passwords: string[] }> {
  const run = `ld-${process.pid}-${++runSeq}`;
  const runDir = join(scratch, "runs", run);
  const clients = opts.clients ?? ["thunderbird"];
  const provider = new LinuxDesktopProvider({
    env,
    stateRoot: deskRoot,
    calibrationRoot: calRoot,
    drivers: defaultDrivers().filter((d) => clients.includes(d.clientId)),
    ...opts.provider,
  });
  const spec: MatrixSpec = {
    stories: stories.map((s) => ({
      story: s.story,
      mimeSha256: sha256(s.mime),
    })),
    families: ["thunderbird", "verification"],
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

// The clients the multi-client tests run (see the file header).
const CLIENTS: string[] = (() => {
  const all = defaultDrivers().map((d) => d.clientId);
  const only = (process.env.ISONIM_EMAIL_DESKTOP_CLIENTS ?? "")
    .split(",")
    .filter((c) => c !== "");
  for (const c of only) assert.ok(all.includes(c), `no desktop client ${c}`);
  return only.length > 0 ? all.filter((c) => only.includes(c)) : all;
})();

function driverOf(client: string): DesktopClientDriver {
  const d = defaultDrivers().find((x) => x.clientId === client);
  assert.ok(d !== undefined, client);
  return d;
}

function out(
  cmd: string,
  args: string[],
  extra: Record<string, string> = {},
): string {
  const r = spawnSync(cmd, args, {
    encoding: "utf8",
    env: { ...process.env, ...extra },
  });
  return `${r.stdout ?? ""}${r.stderr ?? ""}`;
}

// The exact client versions, read here independently of the drivers:
// from each client's own binary, or (Evolution, which needs a display
// even for --version) from its own package's pkg-config file.
function clientVersion(client: string): string {
  let v: string | undefined;
  if (client === "thunderbird")
    v = /Thunderbird (\S+)/.exec(out("thunderbird", ["--version"]))?.[1];
  else if (client === "geary")
    v = /geary:?\s+(\d\S*)/.exec(out("geary", ["--version"]))?.[1];
  else if (client === "claws-mail")
    v = /Claws Mail version (\S+)/.exec(out("claws-mail", ["--version"]))?.[1];
  else if (client === "kmail") {
    const m = /kmail2 (\S+) \((\S+)\)/.exec(
      out("isonim-email-kde", ["kmail", "--version"], {
        QT_QPA_PLATFORM: "offscreen",
      }),
    );
    v = m === null ? undefined : `${m[1]}-${m[2]}`;
  } else if (client === "evolution") {
    const bin = execFileSync("sh", ["-c", "command -v evolution"], {
      encoding: "utf8",
    }).trim();
    const pc = join(
      dirname(dirname(realpathSync(bin))),
      "lib",
      "pkgconfig",
      "evolution-shell-3.0.pc",
    );
    v = /^Version:\s*(\S+)/m.exec(readFileSync(pc, "utf8"))?.[1];
  }
  assert.ok(v !== undefined, `cannot read ${client}'s version`);
  return v;
}

function swayVersion(): string {
  const v = /sway version (\S+)/.exec(out("sway", ["--version"]))?.[1];
  assert.ok(v !== undefined);
  return v;
}

// The exact client and compositor versions, read here independently.
function versions(): { thunderbird: string; sway: string } {
  return { thunderbird: clientVersion("thunderbird"), sway: swayVersion() };
}

// A message whose colours follow prefers-color-scheme: a 320 px block,
// white under light and black under dark, so a capture shows whether
// the scheme reached the message.
const SCHEME_PROBE_HTML = [
  "<style>.probe{background:#ffffff;color:#000000;height:320px;margin:0}",
  "@media (prefers-color-scheme: dark){.probe{background:#000000;color:#ffffff}}</style>",
  '<div class="probe"><h1>Scheme probe</h1><p>light or dark</p></div>',
].join("\r\n");

// The share of an image's pixels that are dark (luminance below 50: the
// probe's black, also as a client's own dark adaptation renders it).
function darkShare(img: RgbaImage): number {
  let n = 0;
  for (let i = 0; i < img.data.length; i += 4)
    if (
      0.2126 * img.data[i]! +
        0.7152 * img.data[i + 1]! +
        0.0722 * img.data[i + 2]! <
      50
    )
      n++;
  return n / (img.width * img.height);
}

describe("linux desktop", { skip: process.platform !== "linux" }, () => {
  // The receipt in every desktop client, light and dark; mobile asked
  // for too, to show it is not one a desktop client renders, and dark
  // not-applicable where the client renders light only.
  let main: Awaited<ReturnType<typeof runDesktop>>;
  before(async () => {
    main = await runDesktop([receipt], {
      viewports: [MOBILE, DESKTOP],
      schemes: ["light", "dark"],
      clients: CLIENTS,
    });
  });

  it("e2e linux desktop captures the receipt story in every client", () => {
    assert.ok(CLIENTS.includes("thunderbird"), CLIENTS.join(", "));
    const sway = swayVersion();
    const heading = headingOf(receipt.html);
    assert.equal(heading, "Receipt #1234");
    const accounts = new Set<string>();
    const tokens = new Set<string>();
    const luminance: Record<string, Record<string, number>> = {};
    let done = 0;
    for (const client of CLIENTS) {
      const d = driverOf(client);
      const version = clientVersion(client);
      const mine = main.rows.filter((r) => r.entry.client === client);
      // Mobile: not a viewport a desktop client renders.
      const mobile = mine.filter((r) => r.entry.viewport === "mobile");
      assert.equal(mobile.length, 2, client);
      for (const r of mobile) {
        assert.equal(r.entry.status, "not-applicable");
        // (a scheme the client does not render is named first)
        assert.match(String(r.reason), /renders: desktop|renders: light\)/);
      }
      // A scheme the client does not render: not-applicable.
      for (const r of mine.filter(
        (x) =>
          x.entry.viewport === "desktop" &&
          !d.schemes.includes(x.entry.scheme as Scheme),
      )) {
        assert.equal(r.entry.status, "not-applicable", client);
        assert.match(String(r.reason), /is not a scheme client/);
      }
      const captured = mine.filter(
        (r) =>
          r.entry.viewport === "desktop" &&
          d.schemes.includes(r.entry.scheme as Scheme),
      );
      assert.deepEqual(
        captured.map((r) => r.entry.scheme).sort(),
        [...d.schemes].sort(),
        client,
      );
      for (const { entry, reason, meta, metaText, png } of captured) {
        const id = `${client}-${entry.scheme}`;
        assert.equal(entry.status, "done", `${id}: ${reason}`);
        done++;
        assert.equal(meta.provider, "linux-desktop");
        assert.equal(meta.via, "inject");
        assert.equal(meta.approximation, false);
        assert.equal(meta.family, d.family, id);
        // The client build, read from the client itself, in provenance.
        const c = rec(meta.client);
        assert.equal(c.id, client);
        assert.equal(c.build, `${client}-${version}+sway-${sway}`, id);
        assert.equal(c.version, version, id);
        assert.match(String(c.account), /^c\d+-[0-9a-f]{8}$/);
        accounts.add(String(c.account));
        // The account user, never its password.
        for (const p of main.passwords)
          assert.ok(!metaText.includes(p), `${id}: a password in provenance`);
        assert.doesNotMatch(metaText, /password/i);
        // The requested scheme, as the client applied it.
        assert.equal(
          rec(meta.scheme_applied).dark,
          entry.scheme === "dark",
          id,
        );
        // The image: rewritten to the assets service, served 200, and
        // (where the client can say) loaded by the client.
        // The rewrite carries the capture's own token, and every request
        // in its assets log is under that token.
        const rewrite = rec(meta.asset_rewrite);
        assert.equal(rewrite.count, 1);
        const token = String(rewrite.token);
        assert.match(token, /^[0-9a-f]{16}$/);
        assert.ok(!tokens.has(token), `${id}: token reused`);
        tokens.add(token);
        assert.equal(
          String(rewrite.to),
          `${new URL(String(rewrite.to)).origin}/c/${token}/`,
        );
        assert.match(String(rewrite.to), /^http:\/\/127\.0\.0\.1:\d+\//);
        const images = rec(meta.images);
        assert.deepEqual(images.expected, [LOGO]);
        assert.deepEqual(images.missing, [], id);
        assert.ok(
          (images.served as { path: string; status: number }[]).some(
            (s) => s.path === LOGO && s.status === 200,
          ),
          id,
        );
        if (client === "thunderbird") assert.ok(Array.isArray(images.client));
        const log = meta.assets_log as { token: string | null }[];
        assert.ok(log.length >= 1, id);
        for (const e of log) assert.equal(e.token, token, id);
        assert.deepEqual(rec(meta.network).blocked, []);
        // Cropped to the message body: the PNG is the crop the client's
        // geometry gave, below the client's own header and tool bars,
        // within the output's width.
        const crop = rec(rec(meta.crop).device);
        const img = readPng(png!);
        assert.equal(img.width, Number(crop.width), id);
        assert.equal(img.height, Number(crop.height), id);
        assert.ok(img.width <= DESKTOP.width * DESKTOP.dpr, id);
        assert.ok(img.width >= 700, `${id}: crop ${img.width} px wide`);
        if (client === "thunderbird")
          assert.equal(img.width, DESKTOP.width * DESKTOP.dpr, id);
        assert.ok(Number(crop.y) > 60, `${id}: crop at y=${String(crop.y)}`);
        // The calibration held for this build.
        assert.notEqual(rec(rec(meta.crop).calibration).state, "failed", id);
        // Vacuity guard: the crop shows the story's own heading.
        const text = ocr(png!);
        assert.ok(
          text.includes(heading),
          `${id}: OCR of the crop does not show '${heading}': ${JSON.stringify(text)}`,
        );
        (luminance[client] ??= {})[entry.scheme] = meanLuminance(img);
      }
      // Light is light in the pixels, and so is dark: the receipt has no
      // dark palette (`accommodate`), and every client keeps a message
      // without dark styles as it is, Thunderbird included: the message
      // root tells it the message handles its own colours, so its dark
      // reader leaves it alone (catalogue R-DRK-08; the scheme probe
      // below shows the scheme reaching the message).
      const l = luminance[client]!;
      assert.ok(l.light! > 150, `${client} light: mean luminance ${l.light}`);
      if (client === "thunderbird") {
        assert.ok(l.dark! > 150, `${client} dark: mean luminance ${l.dark}`);
        const dark = captured.find((r) => r.entry.scheme === "dark")!;
        const ev = rec(rec(dark.meta.scheme_applied).evidence);
        assert.equal(ev.root_filter, 'url("#prefers-color-scheme: dark")');
      }
    }
    assert.equal(accounts.size, done, "one account per capture");
    process.stderr.write(
      `linux-desktop: mean luminance ${JSON.stringify(luminance)}\n`,
    );
  });

  it("the dark scheme reaches the message in every client that renders it", async () => {
    // A message whose own styles follow prefers-color-scheme: black
    // under dark, white under light.
    const probe = crafted("schemeProbe", SCHEME_PROBE_HTML);
    const dark = CLIENTS.filter((c) => driverOf(c).schemes.includes("dark"));
    const { rows } = await runDesktop([probe], {
      schemes: ["light", "dark"],
      clients: dark,
    });
    for (const client of dark) {
      const share: Record<string, number> = {};
      for (const r of rows.filter((x) => x.entry.client === client)) {
        assert.equal(
          r.entry.status,
          "done",
          `${client} ${r.entry.scheme}: ${r.reason}`,
        );
        share[r.entry.scheme] = darkShare(readPng(r.png!));
      }
      // Light: dark only in the text; dark: the block is (KMail's crop
      // also holds its header, dark in its dark colour scheme: about a
      // sixth of the crop, under the bound).
      assert.ok(
        share.light! < 0.05,
        `${client} light: dark share ${share.light}`,
      );
      assert.ok(share.dark! > 0.3, `${client} dark: dark share ${share.dark}`);
      process.stderr.write(
        `linux-desktop: scheme probe ${client}: dark share light ${share.light!.toFixed(3)}, dark ${share.dark!.toFixed(3)}\n`,
      );
    }
  });

  it("Thunderbird shows a designed message's dark palette through its copies, and adapts it without them (R-DRK-08)", async () => {
    // The designed box story as the library writes it, and the same
    // message with its Thunderbird rules taken out. Light: the rules
    // change no pixel. Dark: with them, the designed palette, exactly;
    // without them, Thunderbird's own adaptation (its page colour, the
    // card cleared) and none of the palette.
    // Both are delivered the same way (one base64 HTML part), so only
    // the rules differ.
    const full = fromHtml("boxDark", boxDark.html);
    const bare = fromHtml("boxDarkBare", withoutThunderbirdRules(boxDark.html));
    const { rows } = await runDesktop([full, bare], {
      schemes: ["light", "dark"],
    });
    const png = (story: string, scheme: string): RgbaImage => {
      const r = rows.find(
        (x) => x.entry.story === story && x.entry.scheme === scheme,
      );
      assert.ok(
        r !== undefined && r.entry.status === "done",
        `${story} ${scheme}: ${r?.reason}`,
      );
      return readPng(r.png!);
    };
    const evidence = (story: string): Record<string, unknown> =>
      rec(
        rec(
          rows.find(
            (x) => x.entry.story === story && x.entry.scheme === "dark",
          )!.meta.scheme_applied,
        ).evidence,
      );
    const a = png("boxDark", "light");
    const b = png("boxDarkBare", "light");
    assert.equal(a.width, b.width);
    assert.equal(a.height, b.height);
    assert.ok(
      Buffer.from(a.data).equals(Buffer.from(b.data)),
      "light pixels differ",
    );
    const dark = png("boxDark", "dark");
    assert.equal(
      evidence("boxDark").root_filter,
      'url("#prefers-color-scheme: dark")',
    );
    assert.equal(evidence("boxDark").root_color_scheme, "dark");
    // The page below and around the message, the card, the band and the
    // card's dark border: the designed palette's own colours.
    assert.ok(colourShare(dark, "#0f1115") > 0.3, "page");
    assert.ok(colourShare(dark, "#1a1d23") > 0.05, "card");
    assert.ok(colourShare(dark, "#22262e") > 0.05, "band");
    assert.ok(colourShare(dark, "#05070c") > 0, "border");
    const adapted = png("boxDarkBare", "dark");
    assert.equal(evidence("boxDarkBare").root_filter, "none");
    for (const c of ["#0f1115", "#1a1d23", "#22262e", "#05070c"])
      assert.equal(colourShare(adapted, c), 0, c);
    process.stderr.write(
      `linux-desktop: boxDark dark: page ${colourShare(dark, "#0f1115").toFixed(3)}, card ${colourShare(dark, "#1a1d23").toFixed(3)}\n`,
    );
  });

  it("e2e linux desktop warm capture latency is recorded", async () => {
    // Warm: one session per client for the run, two stories in each
    // scheme the client renders. Cold: a fresh session and client per
    // capture (the receipt, light).
    const warm = await runDesktop([receipt, alert], {
      schemes: ["light", "dark"],
      clients: CLIENTS,
    });
    const cold = await runDesktop([receipt], {
      schemes: ["light"],
      cold: true,
      clients: CLIENTS,
    });
    const p50 = (xs: number[]): number => {
      const s = [...xs].sort((a, b) => a - b);
      return s[Math.floor((s.length - 1) / 2)]!;
    };
    // Steps every client records; the drivers add their own (scheme,
    // configure, client start, images).
    const steps = [
      "account",
      "inject",
      "sync",
      "open",
      "settle",
      "capture",
      "total",
    ];
    const totals: Record<string, { warm: number[]; cold: number[] }> = {};
    for (const [mode, run] of [
      ["warm", warm],
      ["cold", cold],
    ] as const) {
      const expected = CLIENTS.reduce(
        (n, c) => n + (mode === "warm" ? 2 * driverOf(c).schemes.length : 1),
        0,
      );
      const rows = run.rows.filter((r) => r.entry.status !== "not-applicable");
      assert.equal(rows.length, expected, mode);
      for (const { entry, reason, meta } of rows) {
        const id = `${mode} ${entry.client} ${entry.story} ${entry.scheme}`;
        assert.equal(entry.status, "done", `${id}: ${reason}`);
        const t = rec(meta.timing_ms);
        for (const s of steps)
          assert.ok(
            typeof t[s] === "number" && (t[s] as number) >= 0,
            `${id} ${s}: ${String(t[s])}`,
          );
        assert.ok(
          (t.total as number) >=
            (t.open as number) + (t.settle as number) + (t.capture as number),
          id,
        );
        const compositor = rec(meta.compositor);
        assert.equal(compositor.warm, mode === "warm", id);
        // Cold captures start a session and a client of their own.
        if (mode === "cold") {
          assert.ok((t.session as number) > 0 && (t.launch as number) > 0, id);
        } else {
          assert.equal(t.session, undefined, id);
        }
        (totals[entry.client] ??= { warm: [], cold: [] })[mode].push(
          t.total as number,
        );
        const start = rec(meta.client_start_ms);
        process.stderr.write(
          `linux-desktop latency: ${id}: ${Object.entries(t)
            .map(([k, v]) => `${k} ${Math.round(Number(v))}`)
            .join(", ")}; client instance start: ${Object.entries(start)
            .map(([k, v]) => `${k} ${Math.round(Number(v))}`)
            .join(", ")}\n`,
        );
      }
    }
    // Recorded, not asserted (targets: 10 s p50 warm, 30 s cold).
    for (const [client, t] of Object.entries(totals))
      process.stderr.write(
        `linux-desktop latency: ${client}: warm p50 ${Math.round(p50(t.warm))} ms over ${t.warm.length} captures (target 10000 ms); cold ${Math.round(p50(t.cold))} ms (target 30000 ms)\n`,
      );
    process.stderr.write(
      `linux-desktop latency: run wall warm ${warm.wallMs} ms, cold ${cold.wallMs} ms (sessions, client starts and calibration checks included)\n`,
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
      drivers: defaultDrivers().filter((d) => CLIENTS.includes(d.clientId)),
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
      for (const client of CLIENTS) {
        const r = await provider.calibrate(client, true);
        assert.equal(r.ok, true, `${client}: ${r.problems.join("; ")}`);
        assert.equal(r.checks.length, driverOf(client).schemes.length, client);
        process.stderr.write(
          `linux-desktop calibration: ${r.build}: ${r.checks
            .map(
              (c) =>
                `${c.scheme} crop ${c.crop.width}x${c.crop.height}+${c.crop.x}+${c.crop.y}`,
            )
            .join(", ")} in ${Math.round(r.timingMs)} ms\n`,
        );
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
              `${client} ${c.scheme}: a crop off by ${JSON.stringify(o)} passed`,
            );
          }
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
    const { rows } = await runDesktop([stale], { clients: CLIENTS });
    assert.equal(rows.length, CLIENTS.length);
    for (const r of rows) {
      assert.equal(r.entry.status, "failed", r.entry.client);
      assert.match(
        String(r.reason),
        /not served 200 by the assets service and loaded by the client: \/0000000000000000\/logo\.png/,
        r.entry.client,
      );
      const images = rec(r.meta.images);
      assert.deepEqual(images.missing, ["/0000000000000000/logo.png"]);
      assert.ok(
        (images.served as { path: string; status: number }[]).some(
          (s) => s.path === "/0000000000000000/logo.png" && s.status === 404,
        ),
        r.entry.client,
      );
    }
  });

  it("attributes image requests to each capture: a client that loads no image fails while the others load the same image at once", async () => {
    // Every client captures the receipt in one warm run (one worker per
    // client, all at once); one of them gets a copy whose image keeps
    // the story's own origin (the provider's test seam), so it cannot
    // load it while the others request the very same path from the
    // assets service. A client that can report its own images
    // (Thunderbird) would fail on that alone, so the client chosen is
    // one that cannot, where the assets service's log is the evidence.
    const target =
      CLIENTS.find((c) => c === "kmail") ??
      CLIENTS.find((c) => c !== "thunderbird") ??
      "thunderbird";
    const { rows } = await runDesktop([receipt], {
      clients: CLIENTS,
      schemes: ["light"],
      provider: { withholdImagesFrom: [target] },
    });
    assert.equal(rows.length, CLIENTS.length);
    const failed = rows.find((r) => r.entry.client === target)!;
    assert.equal(failed.entry.status, "failed", failed.reason ?? "");
    assert.match(
      String(failed.reason),
      new RegExp(
        `^${target}: image\\(s\\) the story contains were not served 200 by the assets service and loaded by the client: ${LOGO.replace(/\./g, "\\.")}$`,
      ),
    );
    assert.equal(failed.meta.asset_rewrite, null);
    assert.deepEqual(rec(failed.meta.images).served, []);
    assert.deepEqual(rec(failed.meta.images).missing, [LOGO]);
    assert.deepEqual(failed.meta.assets_log, []);
    // The others, at the same time, were served the same path.
    for (const r of rows.filter((x) => x.entry.client !== target)) {
      assert.equal(r.entry.status, "done", `${r.entry.client}: ${r.reason}`);
      const token = String(rec(r.meta.asset_rewrite).token);
      const log = r.meta.assets_log as {
        url: string;
        status: number;
        token: string;
      }[];
      assert.ok(
        log.some((e) => e.url === LOGO && e.status === 200),
        `${r.entry.client}: ${JSON.stringify(log)}`,
      );
      for (const e of log) assert.equal(e.token, token, r.entry.client);
    }
  });

  it(
    "KMail fails a capture whose external-references link never shows, rather than capturing without its images",
    { skip: !CLIENTS.includes("kmail") },
    async () => {
      const { rows } = await runDesktop([receipt], {
        clients: ["kmail"],
        provider: {
          drivers: [new KMailDriver({ noticeLink: "no such link" })],
        },
      });
      assert.equal(rows.length, 1);
      const [r] = rows;
      assert.equal(r!.entry.status, "failed", r!.reason ?? "");
      assert.equal(r!.png, null);
      assert.equal(
        r!.reason,
        "kmail: the message has remote images but KMail's notice offered no 'load the external references' link within 60 s",
      );
    },
  );

  it(
    "Evolution is never asked anything about a cell of its lists: every search skips them, and the list is counted and selected as a table",
    { skip: !CLIENTS.includes("evolution") },
    async () => {
      // Every request the accessibility client makes during a real
      // capture (and the calibration before it), recorded on its way
      // out; nothing is changed.
      const asked: Record<string, unknown>[] = [];
      const answered: unknown[] = [];
      const request = A11yClient.prototype.request;
      A11yClient.prototype.request = async function (
        this: A11yClient,
        req: Record<string, unknown>,
      ): Promise<unknown> {
        asked.push(req);
        const r = await request.call(this, req);
        answered.push(r);
        return r;
      };
      let rows: Row[];
      try {
        ({ rows } = await runDesktop([receipt], {
          clients: ["evolution"],
          schemes: ["light", "dark"],
        }));
      } finally {
        A11yClient.prototype.request = request;
      }
      for (const r of rows)
        assert.equal(r.entry.status, "done", r.reason ?? "");
      const finds = asked.filter((q) => q.op === "find");
      assert.ok(finds.length > 0);
      for (const q of finds) {
        assert.ok(
          Array.isArray(q.prune) && q.prune.includes("tree table"),
          `a search that enters Evolution's lists: ${JSON.stringify(q)}`,
        );
        assert.notEqual(q.role, "table cell", JSON.stringify(q));
      }
      // No node any search returned lies inside a list, so no later
      // request (focus, act, set_text) can address one of its cells.
      for (const a of answered)
        if (Array.isArray(a))
          for (const n of a as A11yNode[])
            assert.ok(
              !(n.ancestors ?? []).some((x) => x.role === "tree table"),
              `a node inside a list: ${JSON.stringify(n.path)} ${n.role} ${n.name}`,
            );
      // The message was found and selected through the list itself.
      assert.ok(asked.some((q) => q.op === "table_rows"));
      assert.ok(asked.some((q) => q.op === "select_row"));
      assert.ok(!asked.some((q) => q.op === "focus"));
    },
  );

  it(
    "Claws Mail: an 'Open in new window' request the client does not take is made again, and the provenance counts the requests",
    { skip: !CLIENTS.includes("claws-mail") },
    async () => {
      const { rows } = await runDesktop([receipt], {
        clients: ["claws-mail"],
        provider: { drivers: [new ClawsDriver({ dropOpenRequests: 1 })] },
      });
      assert.equal(rows.length, 1);
      const [r] = rows;
      assert.equal(r!.entry.status, "done", r!.reason ?? "");
      assert.ok(r!.png !== null);
      const open = rec(rec(r!.meta.client).open_requests);
      assert.equal(open.made, 2, JSON.stringify(open));
      const notTaken = open.not_taken as string[];
      assert.equal(notTaken.length, 1, JSON.stringify(open));
      assert.match(notTaken[0]!, /^\+\d+ ms dropped \(no new window\)$/);
    },
  );

  it(
    "Claws Mail: a capture whose every 'Open in new window' request goes untaken fails, naming each request",
    { skip: !CLIENTS.includes("claws-mail") },
    async () => {
      const { rows } = await runDesktop([receipt], {
        clients: ["claws-mail"],
        provider: {
          drivers: [new ClawsDriver({ dropOpenRequests: Infinity })],
        },
      });
      assert.equal(rows.length, 1);
      const [r] = rows;
      assert.equal(r!.entry.status, "failed", r!.reason ?? "");
      assert.equal(r!.png, null);
      const m =
        /^claws-mail: the message window did not open within 30 s: (\d+) 'Open in new window' request\(s\), none taken \((.*)\)$/.exec(
          String(r!.reason),
        );
      assert.ok(m !== null, String(r!.reason));
      const n = Number(m[1]);
      // One request every ~250 ms for 30 s: well over one.
      assert.ok(n >= 2, String(r!.reason));
      const each = m[2]!.split("; ");
      assert.equal(each.length, n, String(r!.reason));
      for (const a of each)
        assert.match(a, /^\+\d+ ms dropped \(no new window\)$/);
    },
  );

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
      // The session's processes are found by their environment too (the
      // leftover check below relies on it): Thunderbird's content
      // processes name no scratch path in their arguments.
      assert.ok(
        scratchProcesses(true).length > 0,
        "no session process found by its environment alone",
      );
    });

    it("resolves names only through its own files: no host nscd, localhost only, no nameserver", async () => {
      // The host's nscd socket is not there inside (it is outside, on a
      // host that runs nscd), and no name but localhost resolves.
      const socket = "/run/nscd/socket";
      const inside = await session.runInside("nscd-socket", [
        "sh",
        "-c",
        `test -e ${socket}`,
      ]);
      if (existsSync(socket))
        assert.notEqual(inside.status, 0, `${socket} is reachable inside`);
      const ls = await session.runInside("nscd-dir", [
        "sh",
        "-c",
        "ls -A /run/nscd 2>/dev/null",
      ]);
      assert.equal(ls.output.trim(), "");
      const ex = await session.runInside("getent-example", [
        "getent",
        "hosts",
        "example.com",
      ]);
      assert.notEqual(
        ex.status,
        0,
        `example.com resolved inside: ${ex.output}`,
      );
      const own = await session.runInside("getent-own", [
        "getent",
        "hosts",
        hostname(),
      ]);
      assert.notEqual(
        own.status,
        0,
        `the machine's own name resolved inside: ${own.output}`,
      );
      // localhost still resolves (the session's own hosts file).
      const lh = await session.runInside("getent-localhost", [
        "getent",
        "hosts",
        "localhost",
      ]);
      assert.equal(lh.status, 0, lh.output);
      assert.match(lh.output, /localhost/);
    });

    it("reaches no host unix socket: no journal, no system bus, no host user bus, nothing under /tmp; its own bus answers", async () => {
      // Each stream socket the host has is connected to from outside (a
      // positive control: it is there and answers) and from inside the
      // session, where it must not exist. One is created under /tmp
      // after the session started, as a client could find there.
      const probeDir = mkdtempSync("/tmp/ie-sock-");
      const probePath = join(probeDir, "probe.sock");
      const probe = createServer((c) => c.end());
      await new Promise<void>((ok) => probe.listen(probePath, ok));
      try {
        const hostUserBus = join(
          process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid!()}`,
          "bus",
        );
        const candidates = [
          "/run/systemd/journal/stdout",
          "/run/dbus/system_bus_socket",
          "/run/systemd/private",
          hostUserBus,
          "/nix/var/nix/daemon-socket/socket",
          probePath,
        ];
        const connectFrom = (path: string): Promise<string> =>
          new Promise((ok) => {
            const c = createConnection(path);
            c.on("connect", () => {
              c.destroy();
              ok("connected");
            });
            c.on("error", (e: NodeJS.ErrnoException) => ok(e.code ?? "error"));
          });
        const reachable: string[] = [];
        for (const p of candidates)
          if ((await connectFrom(p)) === "connected") reachable.push(p);
        // The journal, the system bus and the probe at least are there
        // on a host like this one; the others where the host has them.
        assert.ok(reachable.includes(probePath), reachable.join(", "));
        assert.ok(
          reachable.includes("/run/dbus/system_bus_socket") ||
            !existsSync("/run/dbus/system_bus_socket"),
        );
        const code = [
          "const net = require('node:net');",
          "let left = process.argv.length - 1;",
          "for (const p of process.argv.slice(1)) {",
          "  const c = net.createConnection(p);",
          "  c.on('connect', () => { console.log(p + ' connected'); c.destroy(); if (--left === 0) process.exit(0); });",
          "  c.on('error', (e) => { console.log(p + ' ' + e.code); if (--left === 0) process.exit(0); });",
          "}",
        ].join("\n");
        const inside = await session.runInside("host-sockets", [
          process.execPath,
          "-e",
          code,
          ...reachable,
        ]);
        assert.equal(inside.status, 0, inside.output);
        const lines = inside.output.trim().split("\n").sort();
        assert.deepEqual(
          lines,
          reachable.map((p) => `${p} ENOENT`).sort(),
          inside.output,
        );
        // POSIX shared memory: a host object is not visible inside.
        const shmProbe = `/dev/shm/ie-shm-probe-${process.pid}`;
        writeFileSync(shmProbe, "host");
        try {
          const shm = await session.runInside("shm", [
            "sh",
            "-c",
            `test -e ${shmProbe}`,
          ]);
          assert.notEqual(shm.status, 0, `${shmProbe} is visible inside`);
        } finally {
          rmSync(shmProbe, { force: true });
        }
        // What is under /run inside: nothing of the host's.
        const run = await session.runInside("run-listing", [
          "sh",
          "-c",
          "ls -A /run",
        ]);
        for (const name of run.output.trim().split(/\s+/))
          assert.ok(
            ["user", "mount", "opengl-driver", "current-system"].includes(name),
            `/run/${name} inside: ${run.output}`,
          );
        // The one system program a helper runs by its NixOS path is the
        // dev shell's, nothing else of the host system is there.
        const sys = await session.runInside("system-bin", [
          "sh",
          "-c",
          "ls -A /run/current-system /run/current-system/sw /run/current-system/sw/bin; readlink /run/current-system/sw/bin/dbus-daemon",
        ]);
        assert.equal(sys.status, 0, sys.output);
        assert.match(
          sys.output,
          /^\/run\/current-system:\nsw\n\n\/run\/current-system\/sw:\nbin\n\n\/run\/current-system\/sw\/bin:\ndbus-daemon\n\/nix\/store\/[^\n]*-dbus-[^\n]*\/bin\/dbus-daemon\n$/,
          sys.output,
        );
        // The session's own runtime directory and its bus are there.
        const own = await session.runInside("own-bus", [
          "dbus-send",
          "--session",
          "--print-reply",
          "--dest=org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus.ListNames",
        ]);
        assert.equal(own.status, 0, own.output);
        assert.match(own.output, /org\.freedesktop\.DBus/);
      } finally {
        await new Promise<void>((ok) => probe.close(() => ok()));
        rmSync(probeDir, { recursive: true, force: true });
      }
    });

    it("reaches no host device: /dev holds only the pseudo-devices, and no session process has another device open", async () => {
      // Positive control: the host's /dev has devices a session must
      // not see (on any real host at least its console and kernel log;
      // on a host with a GPU, its render nodes).
      const hostOnly = readdirSync("/dev").filter(
        (e) => !(SESSION_DEV_ENTRIES as readonly string[]).includes(e),
      );
      assert.ok(hostOnly.length > 0, readdirSync("/dev").join(" "));
      const ls = await session.runInside("dev-listing", ["ls", "-A", "/dev"]);
      assert.equal(ls.status, 0, ls.output);
      assert.deepEqual(
        ls.output.trim().split(/\s+/).sort(),
        [...SESSION_DEV_ENTRIES].sort(),
        ls.output,
      );
      // What is there works: the pseudo-devices are the real ones, a
      // pseudo-terminal opens, and /dev/shm takes a file.
      const works = await session.runInside("dev-works", [
        "sh",
        "-c",
        'set -e; echo x >/dev/null; test "$(head -c 16 /dev/urandom | wc -c)" = 16; test "$(head -c 4 /dev/zero | wc -c)" = 4; test -c /dev/pts/ptmx; echo s >/dev/shm/ie-probe; rm /dev/shm/ie-probe',
      ]);
      assert.equal(works.status, 0, works.output);
      // No process of the session (Thunderbird and its helpers, sway,
      // the bus) holds a character or block device open other than the
      // memory devices (major 1), /dev/tty and ptmx (major 5) and its
      // own pseudo-terminals (majors 136-143): no GPU (DRM 226, NVIDIA
      // 195), no input, no sound.
      const held: string[] = [];
      for (const p of tree(session.pid!)) {
        let fds: string[];
        try {
          fds = readdirSync(`/proc/${p.pid}/fd`);
        } catch {
          continue;
        }
        for (const fd of fds) {
          let st;
          try {
            st = statSync(`/proc/${p.pid}/fd/${fd}`);
          } catch {
            continue;
          }
          if (!st.isCharacterDevice() && !st.isBlockDevice()) continue;
          const major = Math.floor(st.rdev / 256) & 0xfff;
          const pseudo =
            st.isCharacterDevice() &&
            (major === 1 || major === 5 || (major >= 136 && major <= 143));
          if (!pseudo)
            held.push(
              `${p.comm} ${p.pid} fd ${fd}: ${readlinkSync(`/proc/${p.pid}/fd/${fd}`)} (major ${major})`,
            );
        }
      }
      assert.deepEqual(held, []);
    });

    it("stopLaunched ends a launched process and its children, and returns once they are gone", async () => {
      session.launch("stop-probe", [
        "sh",
        "-c",
        "sleep 1000 & sleep 1000 & wait",
      ]);
      const pidFile = join(session.stateDir, "stop-probe.pid");
      assert.ok(
        await waitFor(() => existsSync(pidFile), 20000),
        "not launched",
      );
      const inner = Number(readFileSync(pidFile, "utf8").trim());
      let procs: Proc[] = [];
      assert.ok(
        await waitFor(() => {
          procs = tree(outerPid(inner, session.pid!));
          return procs.filter((p) => p.comm === "sleep").length === 2;
        }, 20000),
        JSON.stringify(procs),
      );
      await session.stopLaunched("stop-probe");
      // Gone (or a zombie only its parent has yet to collect) the moment
      // the call returns.
      const left = procs.filter((p) => {
        const st = procStat(p.pid);
        return st !== null && st.start === p.start && st.state !== "Z";
      });
      assert.deepEqual(left, []);
      assert.equal(session.hasLaunched("stop-probe"), false);
    });

    it("stopLaunched ends the rest of a launched process group whose leader has already exited", async () => {
      session.launch("stop-orphans", [
        "sh",
        "-c",
        "sleep 1003 & sleep 1003 & exit 0",
      ]);
      const pidFile = join(session.stateDir, "stop-orphans.pid");
      assert.ok(
        await waitFor(() => existsSync(pidFile), 20000),
        "not launched",
      );
      const inner = readFileSync(pidFile, "utf8").trim();
      // The two sleeps, left in the leader's group once it is gone.
      const orphans = (): Proc[] =>
        tree(session.pid!).filter((p) => {
          if (p.comm !== "sleep") return false;
          try {
            const pgid = /^NSpgid:\s+(.*)$/m
              .exec(readFileSync(`/proc/${p.pid}/status`, "latin1"))?.[1]
              ?.trim()
              .split(/\s+/)
              .at(-1);
            return pgid === inner;
          } catch {
            return false;
          }
        });
      const leaderGone = (): boolean => {
        try {
          outerPid(Number(inner), session.pid!);
          return false;
        } catch {
          return true;
        }
      };
      let procs: Proc[] = [];
      assert.ok(
        await waitFor(() => {
          procs = orphans();
          return procs.length === 2 && leaderGone();
        }, 20000),
        JSON.stringify(procs),
      );
      await session.stopLaunched("stop-orphans");
      const left = procs.filter((p) => {
        const st = procStat(p.pid);
        return st !== null && st.start === p.start && st.state !== "Z";
      });
      assert.deepEqual(left, []);
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

  it("leaves no sway, bus, client, helper daemon or Dovecot process and no state after the runs", () => {
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
      // The real client's own brief, named like its capture.
      assert.match(
        readFileSync(
          join(
            shots,
            "named",
            "receipt",
            "brief-linux-desktop-thunderbird-thunderbird-desktop-light.md",
          ),
          "utf8",
        ),
        /real client of the `thunderbird` audience family/,
      );
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
