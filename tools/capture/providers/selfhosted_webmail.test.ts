// tools/capture/providers/selfhosted_webmail.test.ts — the
// selfhosted-webmail provider: real Roundcube and SnappyMail sanitisers
// in the pinned Chromium, end to end.
//
// Everything is real: the capture harness (assessProviders +
// executePlan) with the registered imap and assets services (Dovecot
// run as the user, the loopback asset server and egress guard), the
// provider itself with php-fpm, caddy, Roundcube and SnappyMail from the
// dev shell, the stories built by the library's story driver, and the
// PNGs decoded with the capture tools' own PNG codec. No mocks.
//
// Two test seams of the provider are used, both justified: a locator
// override (to show that a webmail UI the drivers do not recognise
// fails the capture loudly; the webmail is real, only the selector is
// wrong), and SnappyMail's server-side image proxy turned on (to make
// PHP fetch an image, so the egress guard can be seen working; the
// provider itself runs with the proxy off). A third seam belongs to
// the assets service: `bodyDelayMs` makes it send an asset's status and
// headers at once and its body that many milliseconds later, to show
// that the provider waits for a slow image before it crops. It is never
// set outside tests: registeredServices() constructs the service with
// no options, and no environment variable or CLI flag reads it.
//
// Some tests deliver a small hand-written message instead of a story,
// to put a stale asset hash or a foreign image URL in front of the real
// webmails.
//
// Every run uses scratch state roots and a scratch socket base, so the
// sweeps under test see only this file's runs. Linux only (the teardown
// tests read /proc).
//
// The email-shots CLI is also run for real, in a scratch clone of this
// checkout (its capture tools, library sources and story assets copied
// in and committed, so it runs the code under test): after a previous
// run and a non-module edit, an explicit --clients or --backends that
// names the webmails captures them, a bare run does not, and an
// impossible combination fails naming why.
//
// Needs `just email-shots-build` (which `just test`
// runs first) and the dev shell. Run with:
//   node --test tools/capture/providers/selfhosted_webmail.test.ts

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
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { readPng } from "../contact_sheet.ts";
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
import { processAlive } from "./owned_state.ts";
import {
  SelfhostedWebmailProvider,
  type SelfhostedWebmailOptions,
  storyImagePaths,
  subjectOf,
} from "./selfhosted_webmail.ts";
import { AssetsService } from "./assets_service.ts";
import { registeredServices, type ServiceRegistry } from "./services.ts";
import type { Scheme, StoryMessage, ViewportSpec } from "./types.ts";
import { WebmailServers } from "./webmail_servers.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const providersDir = resolve(scriptDir);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const driver = join(repoRoot, "build", "capture", "build-stories");
// Short: the socket base must leave room for the socket paths.
const scratch = mkdtempSync("/tmp/ie-sw-");
const socketBase = join(scratch, "rt");
const mailRoot = join(scratch, "mail");
const webRoot = join(scratch, "web");
mkdirSync(socketBase, { mode: 0o700 });
const env = { ...process.env, XDG_RUNTIME_DIR: socketBase };

const MOBILE: ViewportSpec = { name: "mobile", width: 375, dpr: 3 };
const DESKTOP: ViewportSpec = { name: "desktop", width: 800, dpr: 1 };

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

// --- /proc helpers. -------------------------------------------------

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

interface Proc {
  pid: number;
  start: string | null;
  comm: string;
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
// (every php-fpm, caddy and Dovecot this file starts names it).
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

async function waitFor(cond: () => boolean, ms: number): Promise<boolean> {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) return false;
    await new Promise((r) => setTimeout(r, 50));
  }
  return true;
}

// --- Stories and crafted messages. -----------------------------------

let receipt: StoryMessage;
let probe: StoryMessage;
before(() => {
  assert.ok(
    existsSync(driver),
    `${driver} missing: run \`just email-shots-build\` first`,
  );
  const out = join(scratch, "stories");
  const r = spawnSync(driver, [out, "receipt", "sanitiserProbe"], {
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
  probe = load("sanitiserProbe");
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

const LOGO = "/2494f1185a00ab29/logo.png";

// --- Running the real harness. -------------------------------------

interface Row {
  entry: Finished["entry"];
  reason: string | null;
  meta: Record<string, unknown>;
  png: Buffer | null;
}

let runSeq = 0;
async function runWebmail(
  stories: StoryMessage[],
  opts: {
    clients?: string[];
    viewports?: ViewportSpec[];
    schemes?: Scheme[];
    cold?: boolean;
    provider?: SelfhostedWebmailOptions;
    services?: ServiceRegistry;
  } = {},
): Promise<{ rows: Row[]; wallMs: number }> {
  const run = `sw-${process.pid}-${++runSeq}`;
  const runDir = join(scratch, "runs", run);
  const provider = new SelfhostedWebmailProvider({
    env,
    ...opts.provider,
    servers: { stateRoot: webRoot, env, ...opts.provider?.servers },
  });
  const spec: MatrixSpec = {
    stories: stories.map((s) => ({
      story: s.story,
      mimeSha256: sha256(s.mime),
    })),
    families: ["verification"],
    clients: opts.clients ?? null,
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
      ...opts.services,
    },
  );
  if (availability.get(provider.id)?.state !== "ok") {
    await services.stopAll();
    assert.deepEqual(availability.get(provider.id), { state: "ok" });
  }
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
  const rows = finished.map((f) => ({
    entry: f.entry,
    reason: typeof f.line.reason === "string" ? f.line.reason : null,
    meta: JSON.parse(
      readFileSync(join(runDir, f.entry.meta!), "utf8"),
    ) as Record<string, unknown>,
    png: f.entry.png === null ? null : readFileSync(join(runDir, f.entry.png)),
  }));
  return { rows, wallMs };
}

function rec(v: unknown): Record<string, unknown> {
  assert.ok(typeof v === "object" && v !== null, JSON.stringify(v));
  return v as Record<string, unknown>;
}

// Pixels within `tol` of an RGB colour.
function countColour(
  png: Buffer,
  rgb: [number, number, number],
  tol = 3,
): number {
  const img = readPng(png);
  let n = 0;
  for (let i = 0; i < img.data.length; i += 4)
    if (
      Math.abs(img.data[i]! - rgb[0]) <= tol &&
      Math.abs(img.data[i + 1]! - rgb[1]) <= tol &&
      Math.abs(img.data[i + 2]! - rgb[2]) <= tol
    )
      n++;
  return n;
}

// Pixels of the logo's blue plate (about #213a8b).
function logoPixels(png: Buffer): number {
  const img = readPng(png);
  let n = 0;
  for (let i = 0; i < img.data.length; i += 4) {
    const [r, g, b] = [img.data[i]!, img.data[i + 1]!, img.data[i + 2]!];
    if (b > 110 && r < 70 && g < 90 && b - r > 60) n++;
  }
  return n;
}

function staleScratch(): string[] {
  const left: string[] = [];
  for (const root of [webRoot, mailRoot])
    if (existsSync(root))
      for (const e of readdirSync(root)) left.push(join(root, e));
  for (const e of readdirSync(socketBase)) left.push(join(socketBase, e));
  return left;
}

describe("selfhosted webmail", { skip: process.platform !== "linux" }, () => {
  // The receipt in both webmails, light and dark, desktop and mobile.
  let main: { rows: Row[]; wallMs: number };
  before(async () => {
    main = await runWebmail([receipt], {
      viewports: [MOBILE, DESKTOP],
      schemes: ["light", "dark"],
    });
  });

  it("e2e selfhosted webmail captures a story in Roundcube and SnappyMail", () => {
    const { rows } = main;
    assert.equal(rows.length, 8);
    const seen = new Set<string>();
    const accounts = new Set<string>();
    const tokens = new Set<string>();
    for (const { entry, reason, meta, png } of rows) {
      const id = `${entry.client}-${entry.viewport}-${entry.scheme}`;
      seen.add(id);
      assert.equal(entry.status, "done", `${id}: ${reason}`);
      assert.equal(meta.provider, "selfhosted-webmail");
      assert.equal(meta.via, "inject");
      const client = rec(meta.client);
      assert.equal(client.id, entry.client);
      assert.match(
        String(client.build),
        entry.client === "roundcube"
          ? /^roundcube-1\.6\.\d+\+chromium-\d/
          : /^snappymail-2\.38\.\d+\+chromium-\d/,
      );
      assert.equal(client.webmail, entry.client);
      assert.match(String(client.account), /^c\d+-[0-9a-f]{8}$/);
      accounts.add(String(client.account));
      assert.doesNotMatch(JSON.stringify(meta), /password/i);
      // The colour scheme the webmail applied.
      assert.equal(rec(meta.scheme_applied).dark, entry.scheme === "dark");
      // The injected copy had its one image rewritten, and the image
      // was served 200 by the assets service to this page.
      // Under a token of this capture's own: the service's log for the
      // capture holds only requests under it.
      const rewrite = rec(meta.asset_rewrite);
      assert.equal(rewrite.count, 1);
      const token = String(rewrite.token);
      assert.match(token, /^[0-9a-f]{16}$/);
      assert.ok(!tokens.has(token), `${id}: token reused`);
      tokens.add(token);
      assert.match(
        String(rewrite.to),
        new RegExp(`^http://127\\.0\\.0\\.1:\\d+/c/${token}/$`),
      );
      const log = meta.assets_log as {
        url: string;
        status: number;
        token: string | null;
      }[];
      assert.ok(
        log.some((e) => e.url === LOGO && e.status === 200),
        `${id}: ${JSON.stringify(log)}`,
      );
      for (const e of log) assert.equal(e.token, token, id);
      const images = rec(meta.images);
      assert.deepEqual(images.expected, [LOGO]);
      assert.deepEqual(images.missing, []);
      assert.ok(
        (images.served as { path: string; status: number }[]).some(
          (s) => s.path === LOGO && s.status === 200,
        ),
      );
      assert.deepEqual(rec(meta.network).blocked, []);
      // Cropped to the message body: the PNG is the body element's box
      // at the viewport's DPR, below the webmail's own header, and it
      // shows the logo.
      const crop = rec(meta.crop);
      const vp = entry.viewport === "mobile" ? MOBILE : DESKTOP;
      const img = readPng(png!);
      assert.ok(
        Math.abs(img.width - Number(crop.width) * vp.dpr) <= vp.dpr + 1,
        `${id}: ${img.width} vs ${String(crop.width)}×${vp.dpr}`,
      );
      assert.ok(
        Math.abs(img.height - Number(crop.height) * vp.dpr) <= vp.dpr + 1,
        `${id}: ${img.height} vs ${String(crop.height)}×${vp.dpr}`,
      );
      assert.ok(Number(crop.y) > 40, `${id}: crop at y=${String(crop.y)}`);
      assert.ok(Number(crop.width) <= vp.width, id);
      assert.ok(Number(crop.height) < 400, `${id}: ${String(crop.height)}`);
      assert.ok(logoPixels(png!) > 200 * vp.dpr, `${id}: no logo pixels`);
      // SnappyMail marks message images lazy; the provider makes them
      // eager so the whole body loads.
      assert.equal(
        images.lazy_made_eager,
        entry.client === "snappymail" ? 1 : 0,
        id,
      );
      // The message, not the webmail: its text is in the sanitised body.
      assert.match(String(meta.sanitised_html), /Receipt #1234/);
    }
    assert.equal(seen.size, 8, [...seen].join(", "));
    assert.equal(accounts.size, 8, "one fresh account per capture");
    // Warm: one set of servers for the whole run.
    for (const { meta } of rows) assert.equal(rec(meta.servers).warm, true);
    // Each webmail's desktop body is narrower than the window: the
    // webmail's own navigation is cropped away.
    for (const { entry, meta } of rows)
      if (entry.viewport === "desktop")
        assert.ok(Number(rec(meta.crop).width) < DESKTOP.width - 40);
  });

  it("e2e webmail latency is recorded", () => {
    const totals: Record<string, number[]> = {};
    for (const { entry, meta } of main.rows) {
      const t = rec(meta.timing_ms);
      for (const step of [
        "account",
        "inject",
        "login",
        "open",
        "settle",
        "capture",
        "total",
      ])
        assert.ok(
          typeof t[step] === "number" && (t[step] as number) >= 0,
          `${entry.client} ${step}: ${String(t[step])}`,
        );
      assert.ok((t.total as number) > 0);
      assert.ok(
        (t.total as number) >=
          (t.login as number) + (t.open as number) + (t.capture as number),
      );
      (totals[entry.client] ??= []).push(t.total as number);
    }
    const p50 = (xs: number[]): number => {
      const s = [...xs].sort((a, b) => a - b);
      return s[Math.floor((s.length - 1) / 2)]!;
    };
    // Recorded, not asserted (target: 10 s p50 warm per capture).
    for (const [client, xs] of Object.entries(totals))
      process.stderr.write(
        `selfhosted-webmail latency: ${client} p50 ${Math.round(p50(xs))} ms over ${xs.length} warm captures (target 10000 ms); totals ${xs.map(Math.round).join(", ")}\n`,
      );
    process.stderr.write(
      `selfhosted-webmail latency: run wall ${main.wallMs} ms for ${main.rows.length} captures, servers and browser start included\n`,
    );
    assert.equal(Object.keys(totals).length, 2);
  });

  it("leaves no php-fpm, caddy or Dovecot process and no state after a run", () => {
    assert.deepEqual(scratchProcesses(), []);
    assert.deepEqual(staleScratch(), []);
  });

  it("a locator that matches nothing, or more than one element, fails the capture naming it", async () => {
    const { rows } = await runWebmail([receipt], {
      provider: {
        locators: {
          roundcube: { body: "#messagebody, #messagebody *" },
          snappymail: { subject: "#no-such-subject" },
        },
      },
    });
    const byClient = new Map(rows.map((r) => [r.entry.client, r]));
    const rc = byClient.get("roundcube")!;
    const sm = byClient.get("snappymail")!;
    assert.equal(rc.entry.status, "failed");
    assert.equal(rc.png, null);
    assert.match(
      rc.reason!,
      /^roundcube: locator 'body' \(#messagebody, #messagebody \*\) matched \d+ elements, expected exactly one/,
    );
    assert.equal(sm.entry.status, "failed");
    assert.equal(sm.png, null);
    assert.match(
      sm.reason!,
      /^snappymail: locator 'subject' \(#no-such-subject\) matched no visible element/,
    );
  });

  it("fails a capture when an image the story contains is not served 200 by the assets service", async () => {
    const stale = crafted(
      "stale",
      `<h1>Stale image</h1>\r\n<img src="https://x.test/0000000000000000/logo.png" alt="logo" width="120">`,
    );
    assert.deepEqual(storyImagePaths(stale.html), [
      "/0000000000000000/logo.png",
    ]);
    const { rows } = await runWebmail([stale]);
    assert.equal(rows.length, 2);
    for (const { entry, reason, meta, png } of rows) {
      assert.equal(entry.status, "failed", entry.client);
      assert.equal(png, null);
      assert.match(
        reason!,
        /image\(s\) the story contains were not served 200 by the assets service: \/0000000000000000\/logo\.png/,
      );
      const images = rec(meta.images);
      assert.deepEqual(images.missing, ["/0000000000000000/logo.png"]);
      // The service did answer, with the fixture host's 404.
      assert.ok(
        (meta.assets_log as { url: string; status: number }[]).some(
          (r) => r.url === "/0000000000000000/logo.png" && r.status === 404,
        ),
        JSON.stringify(meta.assets_log),
      );
    }
  });

  it("waits for a slow image before the crop, and the image is in the PNG", async () => {
    // The assets service sends the logo's 200 at once and its bytes
    // SLOW_MS later. A capture that does not wait crops a body without
    // its logo (and before the page has reported the response, so the
    // served-200 check fails it too).
    const SLOW_MS = 2500;
    const { rows } = await runWebmail([receipt], {
      services: { assets: () => new AssetsService({ bodyDelayMs: SLOW_MS }) },
    });
    assert.equal(rows.length, 2);
    for (const { entry, reason, meta, png } of rows) {
      assert.equal(entry.status, "done", `${entry.client}: ${reason}`);
      const images = rec(meta.images);
      assert.deepEqual(images.expected, [LOGO]);
      assert.deepEqual(images.missing, []);
      assert.equal(images.all_complete, true, entry.client);
      // The capture waited for the bytes before the crop. Roundcube
      // opens the message by navigating to it, and that navigation
      // already waits for the page's load event (images included);
      // SnappyMail opens it in place, so only the image settle waits.
      const t = rec(meta.timing_ms);
      const open = t.open as number;
      const settle = t.settle as number;
      assert.ok(
        open + settle >= SLOW_MS - 100,
        `${entry.client}: open ${Math.round(open)} ms + settle ${Math.round(settle)} ms, the image needed ${SLOW_MS}`,
      );
      if (entry.client === "snappymail")
        assert.ok(
          settle >= SLOW_MS / 2,
          `snappymail: settle took ${Math.round(settle)} ms, the image needed ${SLOW_MS}`,
        );
      assert.ok(
        logoPixels(png!) > 200,
        `${entry.client}: no logo pixels in the PNG`,
      );
    }
  });

  it("aborts every page request but the webmail and the assets service, and lists it", async () => {
    const foreign = crafted(
      "foreign",
      `<h1>Foreign image</h1>\r\n<img src="https://x.test${LOGO}" alt="logo" width="120">\r\n<img src="http://192.0.2.7/banner.png" alt="banner" width="60">\r\n<img src="http://192.0.2.7/pixel.gif" alt="" width="1" height="1">`,
    );
    const { rows } = await runWebmail([foreign]);
    assert.equal(rows.length, 2);
    for (const { entry, reason, meta } of rows) {
      assert.equal(entry.status, "done", `${entry.client}: ${reason}`);
      const blocked = rec(meta.network).blocked as {
        url: string;
        reason: string;
      }[];
      // Roundcube asks for the 1×1 image too; SnappyMail hides an
      // image one pixel wide (a tracking pixel) without loading it.
      assert.deepEqual(
        blocked.map((b) => [b.url, b.reason]),
        entry.client === "roundcube"
          ? [
              ["http://192.0.2.7/banner.png", "network"],
              ["http://192.0.2.7/pixel.gif", "network"],
            ]
          : [["http://192.0.2.7/banner.png", "network"]],
        entry.client,
      );
      const html = String(meta.sanitised_html);
      if (entry.client === "snappymail") {
        assert.match(
          html,
          /<img [^>]*data-x-src-hidden="http:\/\/192\.0\.2\.7\/pixel\.gif"[^>]*display: none/,
        );
        // The width attribute becomes a fluid inline width.
        assert.match(
          html,
          /<img alt="logo" [^>]*style="width: 100%; max-width: 120px;"/,
        );
        assert.doesNotMatch(html, /width="120"/);
      } else
        assert.match(html, /<img src="[^"]*logo\.png" alt="logo" width="120">/);
      assert.deepEqual(rec(meta.images).missing, []);
    }
  });

  it("PHP's outbound HTTP reaches only the assets service, through the egress guard", async () => {
    // SnappyMail's image proxy on: PHP fetches each image itself.
    const two = crafted(
      "egress",
      `<h1>Egress</h1>\r\n<img src="https://x.test${LOGO}" alt="logo" width="120">\r\n<img src="https://example.com/remote.png" alt="remote" width="60">`,
    );
    const { rows } = await runWebmail([two], {
      clients: ["snappymail"],
      provider: { servers: { snappymailImageProxy: true } },
    });
    assert.equal(rows.length, 1);
    const log = rows[0]!.meta.assets_log as {
      url: string;
      status: number;
      kind: string;
      via: string;
    }[];
    // The story image, fetched by PHP through the proxy and served.
    assert.ok(
      log.some(
        (r) =>
          r.url === LOGO &&
          r.status === 200 &&
          r.kind === "asset" &&
          r.via === "proxy",
      ),
      JSON.stringify(log),
    );
    // The story image's request carries this capture's token.
    const token = rec(rows[0]!.meta.asset_rewrite).token;
    assert.ok(
      log.every((r) => (r as { token?: string }).token === token),
      JSON.stringify(log),
    );
    // The foreign one, refused at the guard (a CONNECT for https); a
    // refusal carries no token, so it is listed with the refusals.
    const refused = rows[0]!.meta.assets_refused as {
      url: string;
      status: number;
      kind: string;
    }[];
    assert.ok(
      refused.some(
        (r) =>
          r.url === "example.com:443" &&
          r.status === 403 &&
          r.kind === "blocked",
      ),
      JSON.stringify(refused),
    );
    // Nothing reached the service directly: PHP had no other way out.
    assert.ok(!log.some((r) => r.via === "direct"), JSON.stringify(log));
  });

  it("--cold starts fresh servers and a fresh browser context for every capture", async () => {
    const { rows } = await runWebmail([receipt], {
      clients: ["roundcube"],
      schemes: ["light", "dark"],
      cold: true,
    });
    assert.equal(rows.length, 2);
    for (const { entry, reason, meta } of rows) {
      assert.equal(entry.status, "done", reason ?? "");
      assert.equal(rec(meta.servers).warm, false);
      assert.ok(Number(rec(meta.timing_ms).servers) > 0);
    }
    assert.deepEqual(scratchProcesses(), []);
    assert.deepEqual(staleScratch(), []);
  });

  it("records how Roundcube and SnappyMail sanitise head CSS", async () => {
    // The probe has every kind of head block; the control is the same
    // message with the class attribute removed from <body>.
    const n = (s: string, re: RegExp): number => s.match(re)?.length ?? 0;
    const bodyClassQp = '<body class=3D"body" ';
    assert.equal(
      n(Buffer.from(probe.mime).toString("latin1"), /<body class=3D"body" /g),
      1,
    );
    const control: StoryMessage = {
      story: "sanitiserProbeNoBodyClass",
      mime: Buffer.from(
        Buffer.from(probe.mime)
          .toString("latin1")
          .replace(bodyClassQp, "<body "),
        "latin1",
      ),
      html: probe.html.replace('<body class="body" ', "<body "),
    };
    const classes = [
      ...new Set(
        [...probe.html.matchAll(/class="([^"]*)"/g)]
          .flatMap((m) => m[1]!.split(" "))
          .filter((c) => c.startsWith("e-")),
      ),
    ];
    assert.ok(classes.length >= 3, classes.join(" "));
    assert.match(probe.html, /@media \(prefers-color-scheme: dark\)/);
    assert.match(probe.html, /\[data-ogsc\] \.e-/);
    assert.match(probe.html, /<!--\[if lte mso 11\]><style>/);
    const { rows } = await runWebmail([probe, control], { schemes: ["dark"] });
    const get = (story: string, client: string): Row =>
      rows.find((r) => r.entry.story === story && r.entry.client === client)!;
    for (const r of rows)
      assert.equal(
        r.entry.status,
        "done",
        `${r.entry.story} ${r.entry.client}: ${r.reason}`,
      );
    const DARK_BG: [number, number, number] = [0x11, 0x18, 0x27];

    // Roundcube: every <style> block outside a conditional comment is
    // kept, its selectors scoped under the body wrapper and its class
    // names prefixed; media queries, the dark block, the [data-og*]
    // copies and :hover survive; conditional comments are dropped.
    const rc = String(get("sanitiserProbe", "roundcube").meta.sanitised_html);
    assert.equal(n(rc, /<style\b/g), 4);
    for (const css of rc.matchAll(/<style[^>]*>([^<]*)<\/style>/g))
      for (const sel of css[1]!.matchAll(/(?:^|})\s*([^@{}][^{}]*)\{/g))
        for (const one of sel[1]!.split(","))
          assert.match(one.trim(), /^#message-htmlpart1 div\.rcmBody\b/, one);
    for (const c of classes) {
      assert.ok(rc.includes(`.v1${c}`), `.v1${c} in the scoped CSS`);
      assert.match(rc, new RegExp(`class="[^"]*\\bv1${c}\\b`));
      assert.doesNotMatch(rc, new RegExp(`class="[^"]*(?<!v1)\\b${c}\\b`));
    }
    assert.match(
      rc,
      /@media only screen and \(max-width: 479px\)\{#message-htmlpart1 div\.rcmBody \.v1e-/,
    );
    assert.match(
      rc,
      /@media \(prefers-color-scheme: dark\)\{#message-htmlpart1 div\.rcmBody \.v1e-/,
    );
    assert.match(rc, /#message-htmlpart1 div\.rcmBody \[data-ogsc\] \.v1e-/);
    assert.match(rc, /#message-htmlpart1 div\.rcmBody \[data-ogsb\] \.v1e-/);
    assert.match(rc, /:hover\{/);
    assert.match(
      rc,
      /#message-htmlpart1 div\.rcmBody \.v1moz-text-html \.v1e-/,
    );
    assert.doesNotMatch(rc, /\[if /);
    assert.doesNotMatch(rc, /mso-group-fix/);
    // The <body> class replaces the wrapper's rcmBody class, so no
    // element carries it and none of those rules can match: the dark
    // paragraph background never appears.
    assert.match(
      rc,
      /<div class="v1body" id="message-htmlpart1" xml:lang="en" style="margin: 0; padding: 0; word-spacing: normal; background-color: #ffffff">/,
    );
    // Ids are prefixed like classes; inline styles are kept, re-spaced.
    assert.match(rc, /#message-htmlpart1 div\.rcmBody #v1outlook a\{/);
    assert.match(rc, /<h1 class="v1e-[0-9a-z]+" style="color: #111111">/);
    assert.doesNotMatch(rc, /class="[^"]*\brcmBody\b/);
    // (Text pixels in the paragraph's own #111827 colour count a few
    // hundred; its dark background, where applied, tens of thousands.)
    assert.ok(
      countColour(get("sanitiserProbe", "roundcube").png!, DARK_BG) < 1500,
    );
    // The control: without the body class the wrapper keeps rcmBody and
    // the same rules apply.
    const rcControl = get("sanitiserProbeNoBodyClass", "roundcube");
    assert.match(
      String(rcControl.meta.sanitised_html),
      /<div class="rcmBody" id="message-htmlpart1"/,
    );
    assert.ok(countColour(rcControl.png!, DARK_BG) > 5000);
    // Kept: the hidden preheader, the image (on the assets service),
    // lang and dir on the wrapper; removed: role and aria-*.
    assert.match(rc, /Head CSS under a webmail sanitiser\./);
    assert.match(rc, /<div lang="en" dir="ltr" style=/);
    assert.doesNotMatch(rc, /\srole=|\saria-/);
    assert.match(
      rc,
      /<img src="http:\/\/127\.0\.0\.1:\d+\/c\/[0-9a-f]{16}\/2494f1185a00ab29\/logo\.png"/,
    );

    // SnappyMail (default settings): every <style> block and every
    // class name of the message is stripped, conditional comments too,
    // and elements hidden with display:none (the preheader) are
    // removed; the inline styles and the image stay.
    for (const story of ["sanitiserProbe", "sanitiserProbeNoBodyClass"]) {
      const row = get(story, "snappymail");
      const sm = String(row.meta.sanitised_html);
      assert.equal(n(sm, /<style\b/g), 0, story);
      const tokens = new Set(
        [...sm.matchAll(/class="([^"]*)"/g)].flatMap((m) => m[1]!.split(/\s+/)),
      );
      for (const t of tokens)
        assert.ok(
          ["bodyText", "b-text-part", "html", "mail-body"].includes(t),
          t,
        );
      assert.doesNotMatch(sm, /\[if |e-mso-group-fix|data-ogs/);
      assert.doesNotMatch(sm, /Head CSS under a webmail sanitiser\./);
      assert.match(sm, /Sanitiser probe/);
      assert.match(sm, /<div lang="en" dir="ltr" style=/);
      assert.doesNotMatch(sm, /\srole=|\saria-/);
      // Inline styles re-serialised: rgb() colours, no mso-/-ms-.
      assert.match(sm, /color: rgb\(17, 17, 17\)/);
      assert.doesNotMatch(sm, /color: ?#|mso-|-ms-/);
      // The body is SnappyMail's wrapper, with the body's inline style;
      // the only id is SnappyMail's own.
      assert.match(
        sm,
        /<div class="mail-body" style="[^"]*word-spacing: normal;/,
      );
      assert.deepEqual(
        [...sm.matchAll(/\sid="([^"]*)"/g)].map((m) =>
          m[1]!.replace(/[0-9a-f]{32}$/, ""),
        ),
        ["rl-msg-"],
      );
      assert.match(
        sm,
        /src="http:\/\/127\.0\.0\.1:\d+\/c\/[0-9a-f]{16}\/2494f1185a00ab29\/logo\.png"/,
      );
      assert.ok(countColour(row.png!, DARK_BG) < 1500, story);
    }
  });
});

// --- The CLI selects the webmail clients. ----------------------------

describe(
  "email-shots selects the webmail clients on an explicit --clients/--backends",
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

    function playwrightCore(): string {
      for (const p of [
        process.env.PLAYWRIGHT_CORE_PATH ?? "",
        join(repoRoot, "tools", "capture", "node_modules", "playwright-core"),
        join(repoRoot, "..", "isonim", "node_modules", "playwright-core"),
      ])
        if (p !== "" && existsSync(join(p, "index.mjs"))) return p;
      throw new Error("no playwright-core found: run under `nix develop`");
    }

    interface CliRun {
      status: number;
      stderr: string;
      entries: {
        family: string;
        client: string;
        backend: string;
        status: string;
        png: string | null;
      }[];
    }

    // Each run first edits a non-module file, so it always has a
    // change since the previous run (with none, the fallback selects
    // every family, the webmails' included, and the explicit flags
    // would go untested).
    function cli(name: string, args: string[]): CliRun {
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
          env: {
            ...process.env,
            XDG_RUNTIME_DIR: cliRuntime,
            PLAYWRIGHT_CORE_PATH: playwrightCore(),
          },
        },
      );
      const index = join(out, "index.json");
      return {
        status: r.status ?? 1,
        stderr: r.stderr,
        entries: existsSync(index)
          ? (JSON.parse(readFileSync(index, "utf8")) as CliRun["entries"])
          : [],
      };
    }

    const set = (xs: string[]): string[] => [...new Set(xs)].sort();

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
      // A previous run for every later run to diff against.
      const seed = cli("seed", [
        "receipt",
        "--full",
        "--families",
        "chromium-baseline",
      ]);
      assert.equal(seed.status, 0, seed.stderr);
    });

    it("--clients roundcube captures Roundcube after a previous run", () => {
      const r = cli("roundcube", [
        "receipt",
        "--clients",
        "roundcube",
        "--no-cache",
      ]);
      assert.equal(r.status, 0, r.stderr);
      assert.doesNotMatch(r.stderr, /empty request matrix/);
      assert.equal(r.entries.length, 1, JSON.stringify(r.entries));
      const [e] = r.entries;
      assert.equal(e!.client, "roundcube");
      assert.equal(e!.family, "verification");
      assert.equal(e!.backend, "selfhosted-webmail");
      assert.equal(e!.status, "done");
      assert.ok(
        e!.png !== null && existsSync(join(shots, "roundcube", e!.png)),
      );
    });

    it("--clients snappymail and --backends selfhosted-webmail capture the webmails", () => {
      const sm = cli("snappymail", [
        "receipt",
        "--clients",
        "snappymail",
        "--no-cache",
      ]);
      assert.equal(sm.status, 0, sm.stderr);
      assert.deepEqual(
        sm.entries.map((e) => `${e.client}/${e.family}/${e.status}`),
        ["snappymail/verification/done"],
      );
      const b = cli("backend", [
        "receipt",
        "--backends",
        "selfhosted-webmail",
        "--no-cache",
      ]);
      assert.equal(b.status, 0, b.stderr);
      assert.deepEqual(
        b.entries.map((e) => `${e.client}/${e.family}/${e.status}`).sort(),
        ["roundcube/verification/done", "snappymail/verification/done"],
      );
    });

    it("mixed --clients across backends captures each named client", () => {
      const r = cli("mixed", ["receipt", "--clients", "webkit,roundcube"]);
      assert.equal(r.status, 0, r.stderr);
      assert.deepEqual(set(r.entries.map((e) => `${e.client}/${e.family}`)), [
        "roundcube/verification",
        "webkit/apple",
      ]);
      for (const e of r.entries) assert.equal(e.status, "done", e.client);
    });

    it("a bare run after a previous run captures backend A's families only", () => {
      const r = cli("bare", ["receipt"]);
      assert.equal(r.status, 0, r.stderr);
      assert.deepEqual(set(r.entries.map((e) => e.backend)), ["a"]);
      assert.ok(!r.entries.some((e) => e.family === "verification"));
    });

    it("an impossible --clients/--backends combination fails naming why", () => {
      const r = cli("impossible", [
        "receipt",
        "--clients",
        "roundcube",
        "--backends",
        "a",
      ]);
      assert.equal(r.status, 1);
      assert.match(
        r.stderr,
        /empty request matrix: .*client 'roundcube' is served by backend selfhosted-webmail, which --backends leaves out/,
      );
    });

    it("leaves no webmail, php-fpm, caddy or Dovecot process behind", () => {
      assert.deepEqual(scratchProcesses(), []);
      for (const d of [".mail", ".webmail"])
        if (existsSync(join(shots, d)))
          assert.deepEqual(readdirSync(join(shots, d)), [], d);
      assert.deepEqual(readdirSync(cliRuntime), []);
    });
  },
);

// --- Nothing outlives the run. --------------------------------------

const CHILD = `
import { renameSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { assessProviders, candidateProviders, executePlan, messageMap, routeRequests } from "${providersDir}/harness.ts";
import { installSignalTeardown, registeredServices } from "${providersDir}/services.ts";
import { DovecotService } from "${providersDir}/imap_service.ts";
import { SelfhostedWebmailProvider } from "${providersDir}/selfhosted_webmail.ts";
const [run, mailRoot, webRoot, emlPath] = process.argv.slice(2);
installSignalTeardown();
const mime = (await import("node:fs")).readFileSync(emlPath);
const sha = createHash("sha256").update(mime).digest("hex");
// A body locator that never matches holds the capture open (20 s).
const p = new SelfhostedWebmailProvider({ locators: { roundcube: { body: "#held-open" } }, servers: { stateRoot: webRoot } });
const spec = { stories: [{ story: "s", mimeSha256: sha }], families: ["verification"], clients: ["roundcube"], backends: null, viewports: [{ name: "desktop", width: 800, dpr: 1 }], schemes: ["light"], images: ["on"] };
const runDir = webRoot + "/../run-" + run;
const registry = { ...registeredServices(), imap: () => new DovecotService({ stateRoot: mailRoot }) };
const { availability, services } = await assessProviders(candidateProviders([p], spec), { run, runDir }, registry);
await executePlan([p], availability, routeRequests([p], availability, spec), messageMap([{ story: "s", mime, html: "" }]),
  { run, session: null, runDir, library: { commit: "c", dirty: false, tree_hash: "t" }, cacheRoot: runDir + "/.cache", noCache: true, assert: false, cold: false, services }, () => {});
`;

describe(
  "selfhosted webmail teardown",
  { skip: process.platform !== "linux" },
  () => {
    const childScript = join(scratch, "run.ts");
    const eml = join(scratch, "receipt.eml");
    before(() => {
      writeFileSync(childScript, CHILD);
      writeFileSync(eml, receipt.mime);
    });

    interface Up {
      child: ChildProcess;
      exit: Promise<{ code: number | null; signal: string | null }>;
      stateDir: string;
      socketDir: string;
      procs: Proc[];
    }

    let seq = 0;
    async function startRun(): Promise<Up> {
      const run = `swt-${process.pid}-${++seq}`;
      const child = spawn(
        process.execPath,
        [childScript, run, mailRoot, webRoot, eml],
        { env, stdio: ["ignore", "ignore", "pipe"] },
      );
      spawned.push(child.pid!);
      let stderr = "";
      child.stderr!.on("data", (d: Buffer) => (stderr += d.toString()));
      const exit = new Promise<{ code: number | null; signal: string | null }>(
        (ok) => child.once("exit", (code, signal) => ok({ code, signal })),
      );
      const stateDir = join(webRoot, run);
      let owner: { socketDir: string; processes: { pid: number }[] } | null =
        null;
      // Up: both servers recorded, and php-fpm's workers forked.
      const up = await waitFor(() => {
        if (child.exitCode !== null) return true;
        try {
          owner = JSON.parse(
            readFileSync(join(stateDir, "owner.json"), "utf8"),
          );
        } catch {
          return false;
        }
        return (
          owner!.processes.length === 2 &&
          tree(owner!.processes[0]!.pid).length >= 4 &&
          existsSync(join(stateDir, "roundcube", "roundcube.db"))
        );
      }, 60000);
      assert.ok(
        up && child.exitCode === null,
        `the run did not come up: ${stderr}`,
      );
      const o = owner!;
      const procs = o.processes.flatMap((p) => tree(p.pid));
      // php-fpm (namespace launcher, master, workers) and caddy.
      assert.ok(
        procs.some((p) => p.comm === "caddy"),
        JSON.stringify(procs),
      );
      assert.ok(
        procs.filter((p) => p.comm.includes("php-fpm")).length >= 3,
        JSON.stringify(procs),
      );
      return { child, exit, stateDir, socketDir: o.socketDir, procs };
    }

    const alive = (procs: Proc[]): Proc[] =>
      procs.filter((p) => processAlive(p));

    it("SIGTERM: the run exits 143 and leaves no php-fpm, caddy or Dovecot and no state", async () => {
      const { child, exit, stateDir, socketDir, procs } = await startRun();
      const all = tree(child.pid!);
      child.kill("SIGTERM");
      assert.deepEqual(await exit, { code: 143, signal: null });
      assert.ok(
        await waitFor(
          () => alive([...procs, ...all.slice(1)]).length === 0,
          5000,
        ),
        `still running: ${JSON.stringify(alive([...procs, ...all.slice(1)]))}`,
      );
      assert.equal(existsSync(stateDir), false);
      assert.equal(existsSync(socketDir), false);
      assert.deepEqual(staleScratch(), []);
    });

    it("SIGKILL: php-fpm (workers included) and caddy die with the run, and the next start sweeps what it left", async () => {
      const { child, exit, stateDir, socketDir, procs } = await startRun();
      child.kill("SIGKILL");
      assert.equal((await exit).signal, "SIGKILL");
      assert.ok(
        await waitFor(() => alive(procs).length === 0, 5000),
        `survived the run: ${JSON.stringify(alive(procs))}`,
      );
      assert.ok(existsSync(join(stateDir, "owner.json")));
      assert.ok(existsSync(join(socketDir, "owner.json")));
      // (The run's Dovecot died with it too; its state is the imap
      // service's sweep's, tested in imap_teardown.test.ts.)
      const next = new WebmailServers({ stateRoot: webRoot, env });
      const e = await next.start({
        run: `swt-next-${process.pid}`,
        imap: { host: "127.0.0.1", port: 1 },
        proxy: "http://127.0.0.1:1/",
      });
      try {
        assert.ok(e.swept.includes(stateDir), JSON.stringify(e.swept));
        assert.ok(e.swept.includes(socketDir), JSON.stringify(e.swept));
        assert.equal(existsSync(stateDir), false);
        assert.equal(existsSync(socketDir), false);
      } finally {
        await next.stop();
      }
      // The killed run's Dovecot state goes with the next imap start.
      const d = new DovecotService({ stateRoot: mailRoot, env });
      await d.start({ run: `swt-next-${process.pid}`, runDir: scratch });
      await d.stop();
      assert.deepEqual(scratchProcesses(), []);
      assert.deepEqual(staleScratch(), []);
    });
  },
);

describe("selfhosted webmail helpers", () => {
  it("expects the story images a browser renders, not those in conditional comments", () => {
    const html =
      `<img src="https://x.test/aaaaaaaaaaaaaaaa/a.png">` +
      `<!--[if mso]><img src="https://x.test/bbbbbbbbbbbbbbbb/b.png"><![endif]-->` +
      `<!--[if !mso]><!--><img alt="x" SRC='https://x.test/cccccccccccccccc/c.png?v=1'><!--<![endif]-->` +
      `<img src="https:&#x2F;&#x2F;x.test/dddddddddddddddd/d.png">` +
      `<img src="http://elsewhere.test/e.png"><a href="https://x.test/f">f</a>`;
    assert.deepEqual(storyImagePaths(html), [
      "/aaaaaaaaaaaaaaaa/a.png",
      "/cccccccccccccccc/c.png",
      "/dddddddddddddddd/d.png",
    ]);
  });

  it("reads the Subject header, unfolded, and refuses encoded words", () => {
    const m = (h: string): Uint8Array =>
      Buffer.from(`From: a@b\r\n${h}\r\nTo: c@d\r\n\r\nSubject: body\r\n`);
    assert.equal(subjectOf(m("Subject: [shots] receipt")), "[shots] receipt");
    assert.equal(subjectOf(m("Subject: a\r\n  folded")), "a  folded");
    assert.equal(subjectOf(m("Subject: =?utf-8?q?x?=")), null);
    assert.equal(
      subjectOf(Buffer.from("From: a@b\r\n\r\nSubject: x\r\n")),
      null,
    );
  });
});
