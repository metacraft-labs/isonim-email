// tools/capture/providers/hosted_webmail.test.ts — the hosted-webmail
// provider (backend b) end to end, against local stand-ins, in the real
// webmail browser driven through GuiAssert.
//
// What is proven, each over the real procedure in Google Chrome (the dev
// shell's webmail browser, started by the sign-in's launcher) in a real
// GuiAssert session (Xvfb, AT-SPI, XTest, tesseract), on persistent
// profiles signed in beforehand by the test playing the person (the same
// browser started normally on a /login page, stopped with SIGINT):
// - no automation, in every test: every browser the provider starts
//   carries no automation switch, and every page it loads sees
//   navigator.webdriver false and a user agent that is not headless;
// - routing: backend b joins a run only when named, its list rows only
//   when --clients names them, and it has no mobile-web clients;
// - a story is delivered once by Workspace send (the fake Gmail API
//   receives exactly the submitted copy for the QA address), found in
//   Inbox by its Message-ID, its list row captured before it is opened
//   (its accessible name and OCR text: sender, the run token, the
//   preheader as the preview), opened, its body cropped as the story
//   region to exactly the requested width, and then removed from every
//   folder (Trash included), the cleanup record saying so; the
//   provenance names the account by its file's name, never its address;
// - a message filed as Spam is found there and the provenance says so;
//   one that never arrives fails as a delivery failure after the bounded
//   wait, never a capture of nothing;
// - a lost session (at lease time, or mid-capture) marks the account
//   needs-login, fails its requests with "session lost:" naming the
//   sign-in recipe, says so on the log at once, and nothing is ever
//   typed into the sign-in page; mid-capture it is a lost session, not
//   UI drift; an inbox that does not load at all (the browser's error
//   page) is not a lost session;
// - a message that cannot be shown to be the delivered one (no heading
//   carries the run token) is neither captured nor deleted;
// - a removal that leaves the message in a folder is a failed cleanup;
// - UI drift: a body hidden from the accessibility tree fails loudly
//   naming the adapter and the locator, and takes the adapter down for
//   the rest of the run (its next story is not even delivered);
// - leases: two stories for Gmail with two accounts are captured at the
//   same time on different accounts (two sessions, two browsers); an
//   account leased by a running process is left to it; a stale lease is
//   taken over and recorded;
// - budgets: an account at 90% of its daily budget drops out, and a set
//   with none left fails with "budget:";
// - Outlook.com: a message in the Other tab is found; light is
//   captured in a light browser (its pages see prefers-color-scheme
//   light, Gmail's always), dark in a dark one, the body darker;
// - the fidelity comparison: the same MIME delivered twice matches, a
//   MIME differing in one colour does not;
// - through the harness: once the first capture has learnt the UI
//   fingerprint (part of the client build), a repeat run is a cache hit
//   and delivers nothing;
// - the CLI: `email-shots --backends b` without credentials fails
//   cleanly with the remedy, and the checklist says what is pending;
// - failure evidence: a message that never arrives, UI drift and a
//   failed cleanup each keep the last display frame (a PNG of the
//   session's display) and the accessibility-tree summary, 0600 in a
//   0700 directory under the run directory, named in the provenance or
//   the cleanup record, and the search record says what each look
//   navigated to and saw;
// - Gmail's search: a message whose Message-ID Gmail rewrote is found
//   by the run token's search, its row named after the sender alone is
//   recognised by its cells' text, and a suggestions list echoing the
//   token query is not taken for a row;
// - Outlook.com: a light capture in a light browser never touches the
//   background toggle; a dark one restarts the browser dark and switches
//   a pressed toggle off once; without a toggle the dark theme is the
//   evidence; a theme that does not follow the browser fails the
//   capture in that scheme, never a capture in the other; a delete in
//   Junk Email that is permanent is recorded `via: "permanent"`.
// - Outlook.com's lists drawn as placeholders for a while (not in the
//   tree): a look waits for the list to settle and records it; the
//   Inbox shown at the bare /mail/0/ is the Inbox (`location_matched`);
//   a folder whose list never settles is never read as "not there", and
//   the delivery failure says so;
// - Gmail: the body is the story's own article (its role="article"
//   wrapper), its box exactly, never the Reply links below; content
//   reaching past it fails the capture as clipped; the profile blocks
//   notifications (every page reads the permission denied, so Gmail's
//   toast does not show), and a toast shown anyway is dismissed with
//   "No thanks", never "OK"; the permanent delete in Trash is the open
//   message's "Delete" (or "Delete forever" where that is offered), only
//   behind the Trash guard: without the Trash chip nothing is clicked
//   and the cleanup fails.
// - Yahoo in Bulgarian (no English mailbox phrase on its pages): the
//   session check recognises the mailbox by its structure, a folder
//   whose old URL sends elsewhere is opened by its link named in the
//   locale table, and the delete and its confirmation are found by their
//   Bulgarian names.
//
// Test doubles (justification, per the repository's mock policy): the
// hosted webmails need a real account signed in and the Gmail API sends
// real mail, so neither can be used from a test. webmail_standin.ts plays
// each webmail with the adapter's accessibility contract on loopback, and
// Google's token endpoint and Gmail send over TLS with a throwaway
// authority. Google Chrome, GuiAssert, the persistent profiles, the
// provider, the Workspace delivery code, the leases, budgets and the
// harness are real.
// Run (inside `nix develop`, which puts guiassert and the webmail browser
// on PATH) with `just test-hosted` (part of `just test`), or:
//   node --test tools/capture/providers/hosted_webmail.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { hostname, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { readPng } from "../contact_sheet.ts";
import { GuiAssert, sessionEnv } from "./guiassert.ts";
import { executePlan, routeRequests, type MatrixSpec } from "./harness.ts";
import {
  FAILURES_DIR,
  fidelityVerdict,
  HostedWebmailProvider,
  type HostedWebmailTimings,
} from "./hosted_webmail.ts";
import { registeredProviders } from "./registry.ts";
import { CREDENTIALS_SCHEMA, findExecutable } from "./requirements.ts";
import type {
  CaptureRequest,
  CaptureResult,
  ProviderHealth,
  SessionCtx,
  StoryMessage,
  ViewportSpec,
} from "./types.ts";
import { utcDay } from "./webmail_accounts.ts";
import { rebaseAdapter, WEBMAIL_ADAPTERS } from "./webmail_adapters.ts";
import {
  automationSwitchesIn,
  sessionSwitches,
  startWebmailBrowser,
} from "./webmail_browser.ts";
import {
  accountProfile,
  stopBrowser,
  webmailBrowser,
  writeSigninRecord,
} from "./webmail_profiles.ts";
import {
  FakeGmailApi,
  htmlOf,
  StandinWebmail,
  type Skin,
} from "./webmail_standin.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const scratch = mkdtempSync(join(tmpdir(), "hosted-webmail-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const QA = {
  "gmail-workspace": [
    "qa-gmail-1@receiver.invalid",
    "qa-gmail-2@receiver.invalid",
  ],
  yahoo: ["qa-yahoo-1@receiver.invalid"],
  "outlook-com": ["qa-outlook-1@receiver.invalid"],
} as const;
type SetId = keyof typeof QA;
const SKIN: Record<SetId, Skin> = {
  "gmail-workspace": "gmail",
  yahoo: "yahoo",
  "outlook-com": "outlook-com",
};
const HOSTS: Record<Skin, string> = {
  gmail: "mail.google.com",
  yahoo: "mail.yahoo.com",
  "outlook-com": "outlook.live.com",
};

const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 });
const SA_KEY = {
  type: "service_account",
  private_key_id: "kid-hosted-webmail-test",
  private_key: rsa.privateKey.export({
    type: "pkcs8",
    format: "pem",
  }) as string,
  client_email: "sender@project.iam.invalid",
};

// Shorter than the live bounds, long enough for a loaded host: every
// step is a GuiAssert call (a process) and a tree read, and the full
// suite runs many browsers at once (an 8 s step bound was measured too
// short there: a Yahoo page opened by a click took longer to show).
const FAST: Partial<HostedWebmailTimings> = {
  arrivalTimeoutMs: 8_000,
  pollMs: 300,
  listSettleMs: 2_500,
  listLoadMs: 8_000,
  stepTimeoutMs: 15_000,
  leaseWaitMs: 1_500,
  leasePollMs: 100,
  signinCheckMs: 30_000,
  offHostMs: 1_500,
  imageTimeoutMs: 3_000,
  stableMs: 150,
  cleanupFindMs: 8_000,
};
// The stand-ins lay their reading pane out to give the body 800 px; a
// lower window keeps the session's display small.
const WINDOW_HEIGHT = 1000;

const DESKTOP: ViewportSpec = { name: "desktop", width: 800, dpr: 1 };
const MOBILE: ViewportSpec = { name: "mobile", width: 375, dpr: 3 };

const GA_BIN = findExecutable("guiassert", {
  env: process.env,
  platform: process.platform,
});

function mime(name: string, colour = "#336699"): Uint8Array {
  return new Uint8Array(
    Buffer.from(
      [
        'From: "Acme Billing" <billing@acme.invalid>',
        "To: someone@acme.invalid",
        `Subject: Your receipt ${name}`,
        `Message-ID: <${name}@acme.invalid>`,
        "Date: Sat, 17 Oct 2026 10:00:00 +0000",
        "MIME-Version: 1.0",
        'Content-Type: multipart/alternative; boundary="b1"',
        "",
        "--b1",
        "Content-Type: text/plain; charset=utf-8",
        "",
        "Your receipt",
        "--b1",
        "Content-Type: text/html; charset=utf-8",
        "",
        `<html><body><div style="display:none">Preheader words for ${name}</div><div style="background:${colour};color:#ffffff;width:320px;height:140px;padding:12px;font:16px sans-serif">Receipt ${name}</div><p style="color:#222222">Thank you.</p></body></html>`,
        "--b1--",
        "",
      ].join("\r\n"),
      "latin1",
    ),
  );
}

// A story as the library writes it: its body inside its own
// role="article" wrapper, named by its aria-label, 340 px tall (a 300 px
// colour block and a 40 px line that says "Reply", as Gmail's own Reply
// link below it does); `wide`: a table reaching 200 px past it.
function mimeArticle(name: string, wide = false): Uint8Array {
  return new Uint8Array(
    Buffer.from(
      [
        'From: "Acme Billing" <billing@acme.invalid>',
        "To: someone@acme.invalid",
        `Subject: Your receipt ${name}`,
        `Message-ID: <${name}@acme.invalid>`,
        "Date: Sat, 17 Oct 2026 10:00:00 +0000",
        "MIME-Version: 1.0",
        'Content-Type: multipart/alternative; boundary="b1"',
        "",
        "--b1",
        "Content-Type: text/plain; charset=utf-8",
        "",
        "Your receipt",
        "--b1",
        "Content-Type: text/html; charset=utf-8",
        "",
        `<html><body><div style="display:none">Preheader words for ${name}</div><div role="article" aria-roledescription="email" aria-label="Your receipt ${name}" lang="en" style="background:#eeeeee;margin:0;padding:0"><div style="background:#336699;color:#ffffff;height:300px;box-sizing:border-box;padding:12px;font:16px sans-serif">Receipt ${name}</div><p style="margin:0;height:40px;color:#222222;font:16px sans-serif">Questions? Reply to this email.</p>${wide ? '<table style="width:1000px;border-collapse:collapse"><tr><td style="font:16px sans-serif">Wide column</td></tr></table>' : ""}</div></body></html>`,
        "--b1--",
        "",
      ].join("\r\n"),
      "latin1",
    ),
  );
}

const sha = (b: Uint8Array): string =>
  createHash("sha256").update(b).digest("hex");

// The story's HTML part, as the harness hands it to a provider: the
// story region is found from its text.
function message(story: string, bytes: Uint8Array): StoryMessage {
  return {
    story,
    mime: bytes,
    html: htmlOf(Buffer.from(bytes).toString("latin1")).html,
  };
}

const FAMILY: Record<string, string> = {
  "gmail-web": "gmailWeb",
  "gmail-list": "gmailWeb",
  "yahoo-web": "yahoo",
  "outlook-web": "outlookWeb",
};

function req(
  story: string,
  bytes: Uint8Array,
  clientId: string,
  viewport = DESKTOP,
  scheme: "light" | "dark" = "light",
): CaptureRequest {
  const family = FAMILY[clientId]!;
  return {
    id: `b-${family}-${clientId}-${viewport.name}-${scheme}-on`,
    story,
    mimeSha256: sha(bytes),
    provider: "hosted-webmail",
    backend: "b",
    family,
    clientId,
    viewport,
    scheme,
    images: "on",
  };
}

function writePrivate(path: string, body: unknown): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  writeFileSync(path, JSON.stringify(body), { mode: 0o600 });
  chmodSync(path, 0o600);
}

interface World {
  name: string;
  dir: string;
  creds: string;
  profiles: string;
  runDir: string;
  env: Record<string, string | undefined>;
  webmails: Record<SetId, StandinWebmail>;
  api: FakeGmailApi;
  logs: string[];
  // The command line of every browser the provider started.
  argvs: string[][];
  provider(extra?: {
    env?: Record<string, string>;
    timings?: Partial<HostedWebmailTimings>;
  }): HostedWebmailProvider;
  stop(): Promise<void>;
}

// The person's sign-in, played by the test: the webmail browser started
// normally on the account's profile at the stand-in's /login page, which
// sets the session cookie and redirects to the mailbox; once the mailbox
// was requested with it, the browser is stopped with SIGINT so that it
// writes the cookie.
async function signInAsAPerson(
  env: Record<string, string | undefined>,
  stateDir: string,
  accounts: { userDataDir: string; webmail: StandinWebmail; account: string }[],
): Promise<void> {
  if (accounts.length === 0) return;
  const chrome = webmailBrowser(env);
  if ("reason" in chrome) throw new Error(chrome.reason);
  if (GA_BIN === null) throw new Error("no guiassert on PATH");
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const ga = new GuiAssert({ bin: GA_BIN, stateDir, env, timeoutMs: 60_000 });
  const session = await ga.sessionStart({
    name: `person-${process.pid}-${Date.now()}`,
    width: 1280,
    height: 900,
    vncSocket: false,
  });
  try {
    for (const a of accounts) {
      const seen = a.webmail.userAgents.length;
      const started = await startWebmailBrowser({
        chrome,
        userDataDir: a.userDataDir,
        url: `${a.webmail.origin}/login?account=${a.account}`,
        env: sessionEnv(env, session),
        extra: sessionSwitches(1280, 900),
        scheme: "light",
        unsafeNoSandbox: false,
      });
      if (!started.ok) throw new Error(started.reason);
      try {
        const deadline = Date.now() + 60_000;
        while (a.webmail.userAgents.length === seen) {
          if (Date.now() > deadline)
            throw new Error(
              `the person's sign-in to ${a.webmail.skin} did not reach the mailbox`,
            );
          await new Promise((r) => setTimeout(r, 200));
        }
        await new Promise((r) => setTimeout(r, 1000));
      } finally {
        await stopBrowser(started.child);
      }
    }
  } finally {
    await ga.sessionStop(session.id).catch(() => undefined);
  }
}

// A credentials directory, signed-in profiles and the stand-ins.
async function world(
  name: string,
  opts: {
    accounts?: Partial<Record<SetId, number>>;
    signIn?: boolean;
    // The sets whose profiles a person signs in (default every set):
    // a test that uses one webmail spends no browser start on the rest.
    only?: SetId[];
  } = {},
): Promise<World> {
  const dir = join(scratch, name);
  const creds = join(dir, "creds");
  const profiles = join(dir, "profiles");
  const runDir = join(dir, "run");
  mkdirSync(creds, { recursive: true, mode: 0o700 });
  chmodSync(creds, 0o700);
  mkdirSync(runDir, { recursive: true });
  const accounts: Record<SetId, number> = {
    "gmail-workspace": 1,
    yahoo: 1,
    "outlook-com": 1,
    ...opts.accounts,
  };
  const webmails = {
    "gmail-workspace": new StandinWebmail("gmail"),
    yahoo: new StandinWebmail("yahoo"),
    "outlook-com": new StandinWebmail("outlook-com"),
  } as Record<SetId, StandinWebmail>;
  for (const w of Object.values(webmails)) await w.start();
  const route = new Map<string, { webmail: StandinWebmail; account: string }>();
  const allowed: string[] = [];
  for (const set of Object.keys(QA) as SetId[])
    for (let i = 0; i < accounts[set]; i++) {
      const address = QA[set][i]!;
      allowed.push(address);
      route.set(address, { webmail: webmails[set], account: `qa${i + 1}` });
      writePrivate(join(creds, set, `qa${i + 1}.json`), {
        schema: CREDENTIALS_SCHEMA,
        address,
        password: "the-person-types-this-never-the-harness",
      });
    }
  writePrivate(join(creds, "workspace-sender", "tests.json"), {
    schema: CREDENTIALS_SCHEMA,
    key: SA_KEY,
    subject: "qa-sender@tenant.invalid",
    from: "tests-alias@tenant.invalid",
    allowed_recipients: allowed,
  });
  const api = new FakeGmailApi((to) => route.get(to) ?? null);
  const endpoints = await api.start();
  const env: Record<string, string | undefined> = {
    ...process.env,
    ISONIM_EMAIL_CREDENTIALS_DIR: creds,
    ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: profiles,
  };
  delete env.ISONIM_EMAIL_WEBMAIL_DAILY_BUDGET;
  const host = { env, platform: process.platform };
  // The sign-in, played by the test: a session cookie in each account's
  // profile, then the record the sign-in recipe writes.
  if (opts.signIn !== false) {
    const people: {
      userDataDir: string;
      webmail: StandinWebmail;
      account: string;
    }[] = [];
    for (const set of Object.keys(QA) as SetId[])
      for (let i = 0; i < accounts[set]; i++) {
        const file = `${set}/qa${i + 1}.json`;
        const prof = accountProfile(host, set, file, true);
        if ((opts.only ?? [set]).includes(set))
          people.push({
            userDataDir: prof.userDataDir,
            webmail: webmails[set],
            account: `qa${i + 1}`,
          });
        writeSigninRecord(prof, {
          set,
          account_file: file,
          signed_in_at: new Date().toISOString(),
          host: new URL(webmails[set].origin).host,
          browser: "google-chrome (test)",
        });
      }
    await signInAsAPerson(env, join(dir, "person-ga"), people);
    // What the person's browser saw is not the provider's.
    for (const wm of Object.values(webmails)) wm.probes = [];
  }
  const origins = Object.fromEntries(
    (Object.keys(QA) as SetId[]).map((s) => [
      HOSTS[SKIN[s]],
      webmails[s].origin,
    ]),
  );
  const adapters = WEBMAIL_ADAPTERS.map((a) => rebaseAdapter(a, origins));
  const logs: string[] = [];
  const argvs: string[][] = [];
  return {
    name,
    dir,
    creds,
    profiles,
    runDir,
    env,
    webmails,
    api,
    logs,
    argvs,
    provider: (extra = {}) =>
      new HostedWebmailProvider({
        env: { ...env, ...extra.env },
        adapters,
        workspace: { endpoints, trust: { ca: api.pki.caPem } },
        timings: { ...FAST, ...extra.timings },
        windowHeight: WINDOW_HEIGHT,
        log: (l) => logs.push(l),
        onDesktop: (d) => argvs.push(d.argv),
      }),
    stop: async () => {
      for (const w of Object.values(webmails)) await w.stop();
      await api.stop();
    },
  };
}

function ctxFor(w: World, run = "t1"): SessionCtx {
  return {
    run,
    session: null,
    runDir: w.runDir,
    planned: [],
    assert: false,
    cold: false,
    services: {},
  };
}

async function captureAll(
  p: HostedWebmailProvider,
  w: World,
  batch: CaptureRequest[],
  msgs: StoryMessage[],
  run = "t1",
): Promise<CaptureResult[]> {
  const ctx = ctxFor(w, run);
  const out: CaptureResult[] = [];
  await p.prepare(ctx);
  try {
    const map = new Map(msgs.map((m) => [sha(m.mime), m]));
    for await (const r of p.capture(batch, map, ctx)) out.push(r);
  } finally {
    await p.dispose();
  }
  noAutomation(w);
  return out;
}

// Every browser the provider started carried no automation switch, and
// every page it loaded saw no automation.
function noAutomation(w: World): void {
  for (const argv of w.argvs) {
    assert.deepEqual(automationSwitchesIn(argv), [], argv.join(" "));
    assert.ok(!argv.some((a) => /remote-debugging|automation/i.test(a)));
  }
  for (const wm of Object.values(w.webmails))
    for (const p of wm.probes) {
      assert.equal(p.webdriver, "false", `${wm.skin} ${p.page}`);
      assert.doesNotMatch(p.ua, /HeadlessChrome/);
    }
}

function cleanup(w: World): Record<string, unknown>[] {
  const path = join(w.runDir, "hosted-webmail-cleanup.jsonl");
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .filter((l) => l !== "")
    .map((l) => JSON.parse(l) as Record<string, unknown>);
}

const prov = (r: CaptureResult): Record<string, any> =>
  r.provenance as Record<string, any>;

// A failure's kept evidence: the frame a PNG of the session's display
// and the tree summary JSON, both 0600 in a 0700 directory under the
// run directory; returns the summary.
function evidence(w: World, f: Record<string, any> | undefined) {
  assert.ok(f !== undefined && f !== null, "a failure's evidence is named");
  assert.equal(statSync(join(w.runDir, FAILURES_DIR)).mode & 0o777, 0o700);
  const frame = join(w.runDir, f.frame);
  const tree = join(w.runDir, f.tree);
  for (const p of [frame, tree])
    assert.equal(statSync(p).mode & 0o777, 0o600, p);
  const img = readPng(new Uint8Array(readFileSync(frame)));
  assert.ok(
    img.width >= 800 && img.height === WINDOW_HEIGHT,
    `${img.width}x${img.height}`,
  );
  const summary = JSON.parse(readFileSync(tree, "utf8"));
  assert.equal(summary.schema, "isonim-email/a11y-summary/1");
  assert.equal(summary.step, f.step);
  assert.ok(summary.showing.length > 0);
  assert.equal(summary.location, f.location);
  assert.doesNotMatch(JSON.stringify(summary), /@receiver\.invalid/);
  return summary;
}

function luminance(png: Uint8Array): number {
  const img = readPng(png);
  let sum = 0;
  for (let i = 0; i < img.data.length; i += 4)
    sum +=
      0.2126 * img.data[i]! +
      0.7152 * img.data[i + 1]! +
      0.0722 * img.data[i + 2]!;
  return sum / (img.data.length / 4);
}

describe("hosted-webmail routing", () => {
  const providers = registeredProviders();
  const ok = new Map<string, ProviderHealth>(
    providers.map((p) => [p.id, { state: "ok" } as ProviderHealth]),
  );
  const spec = (over: Partial<MatrixSpec>): MatrixSpec => ({
    stories: [{ story: "s", mimeSha256: "0".repeat(64) }],
    families: ["gmailWeb", "outlookWeb", "yahoo"],
    clients: null,
    backends: null,
    viewports: [DESKTOP, MOBILE],
    schemes: ["light"],
    images: ["on"],
    ...over,
  });
  const clientsOf = (s: MatrixSpec): string[] =>
    [
      ...new Set(
        routeRequests(providers, ok, s)
          .items.filter(
            (i) => i.kind === "capture" && i.request.backend === "b",
          )
          .map((i) => i.request.clientId),
      ),
    ].sort();

  it("routes backend b only when named, and its list rows only when --clients names them; it has no mobile-web clients", () => {
    assert.deepEqual(clientsOf(spec({})), []);
    // No mobile-web client: a phone is not imitated without DevTools.
    assert.deepEqual(clientsOf(spec({ backends: ["a", "b"] })), [
      "gmail-web",
      "outlook-web",
      "yahoo-web",
    ]);
    assert.deepEqual(clientsOf(spec({ clients: ["gmail-list"] })), [
      "gmail-list",
    ]);
    assert.deepEqual(clientsOf(spec({ clients: ["gmail-web", "chromium"] })), [
      "gmail-web",
    ]);
  });
});

describe("the hosted-webmail capture procedure", () => {
  it("delivers once, finds the message in Inbox, captures its list row and body, then removes it from every folder", async () => {
    const w = await world("e2e", { only: ["gmail-workspace"] });
    try {
      const m = mime("e2e");
      const p = w.provider();
      assert.deepEqual(await p.health(), { state: "ok" });
      const results = await captureAll(
        p,
        w,
        [req("s1", m, "gmail-web"), req("s1", m, "gmail-list")],
        [message("s1", m)],
      );
      assert.equal(results.length, 2);
      for (const r of results) assert.equal(r.status, "done", r.reason);
      // One delivery for both requests, to the QA address, the exact copy.
      assert.equal(w.api.sent.length, 1);
      const sent = w.api.sent[0]!;
      assert.equal(sent.to, QA["gmail-workspace"][0]);
      const body = results.find((r) => r.request.clientId === "gmail-web")!;
      const row = results.find((r) => r.request.clientId === "gmail-list")!;
      const d = prov(body).delivery;
      assert.ok(sent.raw.includes(`Message-ID: ${d.message_id}`));
      assert.equal(
        createHash("sha256")
          .update(Buffer.from(sent.raw, "latin1"))
          .digest("hex"),
        d.submitted_sha256,
      );
      assert.equal(prov(body).arrival.folder, "inbox");
      // The search record: the Message-ID search typed, the address bar
      // holding it, the row found by the first row locator.
      const look = prov(body).arrival.looks.at(-1);
      assert.match(look.url, /#search\/rfc822msgid%3A/);
      assert.equal(look.how, "typed");
      assert.equal(look.location_matched, true);
      assert.equal(look.token_rows, 1);
      assert.equal(look.row_locator, "role=row");
      assert.equal(prov(body).arrival.row_locator, "role=row");
      assert.ok(look.rows.some((r: string) => r.includes(d.subject_token)));
      assert.equal(prov(body).failure, undefined);
      assert.equal(existsSync(join(w.runDir, FAILURES_DIR)), false);
      assert.equal(prov(body).client.account, "qa1");
      assert.equal(prov(body).client.locators, "unverified-live");
      // Cropped to the body: the PNG is the body's box.
      const img = readPng(body.png!);
      assert.ok(
        Math.abs(img.width - prov(body).crop.width) <= 1,
        `${img.width} vs ${prov(body).crop.width}`,
      );
      assert.ok(
        Math.abs(img.height - prov(body).crop.height) <= 1,
        `${img.height} vs ${prov(body).crop.height}`,
      );
      // The story region is the body's whole box, at the requested width.
      assert.equal(prov(body).crop.locator, "story region");
      assert.deepEqual(prov(body).width_check, {
        requested: 800,
        measured: 800,
        delta: 0,
      });
      assert.equal(img.width, 800);
      assert.equal(prov(body).settle.settled, true);
      assert.match(prov(body).ui_fingerprint.value, /^[0-9a-f]{12}$/);
      assert.equal(prov(body).browser.automation, "none");
      // The story's own colour block is in the crop.
      const px = (x: number, y: number) =>
        Array.from(
          img.data.slice((y * img.width + x) * 4, (y * img.width + x) * 4 + 3),
        );
      // The story's colour block starts the crop (away from its text),
      // and the crop holds the story's last line, not the page beside.
      assert.deepEqual(px(4, 100), [0x33, 0x66, 0x99]);
      assert.deepEqual(px(600, 100), [0xff, 0xff, 0xff]);
      assert.ok(img.height >= 180 && img.height < 260, String(img.height));
      // The row, before opening: its accessible name carries the sender,
      // the run token and the preheader as the preview; OCR reads it.
      assert.match(prov(row).list_row.name, /Acme Billing/);
      assert.ok(prov(row).list_row.name.includes(d.subject_token));
      assert.match(prov(row).list_row.name, /Preheader words for e2e/);
      // OCR reads the row as shown (its reading order is the engine's).
      for (const word of ["Acme", "Billing", "Preheader words"])
        assert.ok(
          prov(row).list_row.ocr.includes(word),
          prov(row).list_row.ocr,
        );
      assert.ok(readPng(row.png!).height < img.height);
      // Removed: nothing left in any folder, and the record says so.
      assert.deepEqual(w.webmails["gmail-workspace"].messages, []);
      assert.deepEqual(
        cleanup(w).map((c) => [c.state, c.folder, c.account, c.via]),
        [["removed", "inbox", "qa1", "trash"]],
      );
      // Named by file, never by address; the lease is released.
      for (const r of results)
        assert.doesNotMatch(JSON.stringify(r.provenance), /@receiver\.invalid/);
      assert.equal(
        existsSync(join(w.profiles, "gmail-workspace", "qa1", "lease.json")),
        false,
      );
      const budget = JSON.parse(
        readFileSync(
          join(w.profiles, "gmail-workspace", "qa1", "budget.json"),
          "utf8",
        ),
      );
      assert.deepEqual(budget, { day: utcDay(Date.now()), count: 1 });
    } finally {
      await w.stop();
    }
  });

  it("finds a message filed as Spam there and says so; one that never arrives is a delivery failure", async () => {
    const w = await world("spam", { only: ["gmail-workspace"] });
    try {
      const gm = w.webmails["gmail-workspace"];
      gm.filing = ({ subject }) =>
        subject.includes("never") ? "withhold" : "spam";
      gm.deliveryDelayMs = 400;
      const a = mime("spammed");
      const b = mime("never");
      const results = await captureAll(
        w.provider(),
        w,
        [req("a", a, "gmail-web"), req("b", b, "gmail-web")],
        [message("a", a), message("b", b)],
      );
      const ra = results.find((r) => r.request.story === "a")!;
      const rb = results.find((r) => r.request.story === "b")!;
      assert.equal(ra.status, "done", ra.reason);
      assert.equal(prov(ra).arrival.folder, "spam");
      assert.equal(prov(ra).arrival.folder_label, "Spam");
      assert.equal(rb.status, "failed");
      assert.match(
        rb.reason!,
        /^delivery failure: <.*> \(sent through the Gmail API as api\d\) was not found in Gmail's Inbox or Spam within 8 s/,
      );
      assert.equal(rb.png, undefined);
      // What was looked at, and the screen when it gave up.
      const search = prov(rb).search as Record<string, any>[];
      assert.ok(search.length >= 2, JSON.stringify(search));
      assert.deepEqual([...new Set(search.map((l) => l.folder))].sort(), [
        "inbox",
        "spam",
      ]);
      for (const l of search) {
        assert.equal(l.location_matched, true, JSON.stringify(l));
        assert.equal(l.token_rows, 0);
      }
      assert.ok(search.some((l) => /%22%5Bes%3At1%3A/.test(l.url)));
      const sum = evidence(w, prov(rb).failure);
      assert.equal(prov(rb).failure.step, "arrival");
      assert.ok(sum.showing.some((x: any) => x.name === "Search mail"));
      const notFound = cleanup(w).find((c) => c.state === "not-found")!;
      assert.deepEqual(notFound.failure, prov(rb).failure);
      const states = cleanup(w)
        .map((c) => c.state)
        .sort();
      assert.deepEqual(states, ["not-found", "removed"]);
      // Gmail's Spam offers only the permanent delete: no Trash step.
      const removed = cleanup(w).find((c) => c.state === "removed")!;
      assert.equal(removed.folder, "spam");
      assert.equal(removed.via, "delete-forever");
      assert.equal(gm.destroyed.length, 1);
      assert.deepEqual(gm.messages, []);
    } finally {
      await w.stop();
    }
  });
});

describe("hosted-webmail session loss and UI drift", () => {
  it("a session lost before delivery marks the account needs-login, names the sign-in, and types nothing", async () => {
    const w = await world("lost", { only: ["yahoo"] });
    try {
      const y = w.webmails.yahoo;
      y.expire("qa1");
      const loginsBefore = y.logins.length;
      const m = mime("lost");
      const results = await captureAll(
        w.provider(),
        w,
        [req("s", m, "yahoo-web")],
        [message("s", m)],
      );
      assert.equal(results.length, 1);
      assert.equal(results[0]!.status, "failed");
      assert.match(
        results[0]!.reason!,
        /session lost: yahoo\/qa1 is not signed in any more \(.*\); a capture never signs in: sign it in again with `just email-webmail-signin yahoo --account qa1`/,
      );
      assert.ok(
        w.logs.some((l) => /hosted-webmail: session lost: yahoo\/qa1/.test(l)),
      );
      assert.ok(
        existsSync(join(w.profiles, "yahoo", "qa1", "needs-login.json")),
      );
      // Nothing was sent to the account, nothing typed, no sign-in made.
      assert.equal(w.api.sent.filter((s) => s.to === QA.yahoo[0]).length, 0);
      assert.equal(y.signinTyped, 0);
      assert.ok(y.signinVisits > 0, "the redirect did reach the sign-in page");
      assert.equal(y.logins.length, loginsBefore);
      // Out of selection now: health says so, with the remedy.
      const h = await w.provider().health();
      assert.equal(h.state, "degraded");
      assert.match(
        (h as { reason: string }).reason,
        /yahoo\/qa1 lost its session .*just email-webmail-signin yahoo --account qa1/,
      );
    } finally {
      await w.stop();
    }
  });

  it("a session lost mid-capture is a lost session, not UI drift", async () => {
    const w = await world("lost-mid", { only: ["gmail-workspace"] });
    try {
      const gm = w.webmails["gmail-workspace"];
      gm.expireOnOpen = true;
      const m = mime("mid");
      const results = await captureAll(
        w.provider(),
        w,
        [req("s", m, "gmail-web")],
        [message("s", m)],
      );
      assert.equal(results[0]!.status, "failed");
      assert.match(results[0]!.reason!, /^session lost: gmail-workspace\/qa1/);
      assert.doesNotMatch(results[0]!.reason!, /UI drift/);
      assert.ok(
        existsSync(
          join(w.profiles, "gmail-workspace", "qa1", "needs-login.json"),
        ),
      );
      assert.equal(gm.signinTyped, 0);
    } finally {
      await w.stop();
    }
  });

  it("an inbox that does not load is not a lost session: the account is not marked", async () => {
    const w = await world("unreachable", { only: ["yahoo"] });
    try {
      await w.webmails.yahoo.stop();
      const m = mime("unreachable");
      const results = await captureAll(
        w.provider(),
        w,
        [req("s", m, "yahoo-web")],
        [message("s", m)],
      );
      assert.equal(results[0]!.status, "failed");
      assert.match(
        results[0]!.reason!,
        /yahoo\/qa1: the inbox did not load \(the browser's error page on 127\.0\.0\.1:\d+\) \(the session was not judged/,
      );
      assert.doesNotMatch(results[0]!.reason!, /session lost/);
      assert.equal(
        existsSync(join(w.profiles, "yahoo", "qa1", "needs-login.json")),
        false,
      );
      assert.equal(w.api.sent.length, 0);
    } finally {
      await w.stop();
    }
  });

  it("a message that cannot be shown to be the delivered one is never captured or deleted", async () => {
    const w = await world("identity", { only: ["gmail-workspace"] });
    try {
      const gm = w.webmails["gmail-workspace"];
      gm.openedSubject = "Another message";
      const m = mime("identity");
      const results = await captureAll(
        w.provider(),
        w,
        [req("s", m, "gmail-web")],
        [message("s", m)],
      );
      assert.equal(results[0]!.status, "failed");
      assert.equal(results[0]!.png, undefined);
      assert.match(
        results[0]!.reason!,
        /the opened message is not the delivered one \(no heading carries the run token \[es:t1:[0-9a-f]{8}\]; shown: 'Another message'\)/,
      );
      // Nothing deleted: the delivered message is still in the Inbox,
      // and the cleanup record says the removal failed.
      assert.deepEqual(
        gm.messages.map((x) => x.folder),
        ["inbox"],
      );
      assert.deepEqual(gm.destroyed, []);
      assert.deepEqual(
        cleanup(w).map((c) => c.state),
        ["failed"],
      );
    } finally {
      await w.stop();
    }
  });

  it("a removal that leaves the message in a folder is a failed cleanup, said on the log", async () => {
    const w = await world("kept", { only: ["gmail-workspace"] });
    try {
      const gm = w.webmails["gmail-workspace"];
      gm.keepDestroyed = true;
      // Gmail's lists swap late: the Trash list still showing under the
      // Inbox's address is not the message "still in Inbox".
      gm.viewDelayMs = 1_000;
      const m = mime("kept");
      const results = await captureAll(
        w.provider(),
        w,
        [req("s", m, "gmail-web")],
        [message("s", m)],
      );
      // The capture stands; the cleanup does not.
      assert.equal(results[0]!.status, "done", results[0]!.reason);
      assert.equal(gm.destroyed.length, 1);
      const rec = cleanup(w);
      assert.deepEqual(
        rec.map((c) => c.state),
        ["failed"],
      );
      assert.match(String(rec[0]!.reason), /still in Trash after the delete/);
      // The screen and the looks that saw it still there.
      evidence(w, rec[0]!.failure as Record<string, any>);
      assert.equal((rec[0]!.failure as any).step, "cleanup-check");
      const looks = rec[0]!.search as Record<string, any>[];
      assert.ok(looks.some((l) => l.folder === "trash" && l.token_rows === 1));
      // The final check's first look left a page showing the message:
      // its typed URL was reloaded, and the Inbox read empty.
      assert.ok(
        looks.some(
          (l) =>
            l.folder === "inbox" &&
            l.how === "typed-reload" &&
            l.token_rows === 0,
        ),
        JSON.stringify(looks.map((l) => [l.folder, l.how, l.token_rows])),
      );
      assert.ok(w.logs.some((l) => /the screen kept at .*\.png\)$/.test(l)));

      // A delete that leaves the message in its folder is a failed
      // cleanup saying so, before Trash is ever looked in.
      gm.keepDestroyed = false;
      gm.viewDelayMs = 0;
      gm.deleteIgnored = true;
      const m2 = mime("kept-2");
      const again = await captureAll(
        w.provider(),
        w,
        [req("s2", m2, "gmail-web")],
        [message("s2", m2)],
        "t2",
      );
      assert.equal(again[0]!.status, "done", again[0]!.reason);
      const rec2 = cleanup(w).at(-1)!;
      assert.equal(rec2.state, "failed");
      assert.match(
        String(rec2.reason),
        /^the delete left the message in Inbox \(still there after 8 s\)$/,
      );
      assert.equal((rec2.failure as any).step, "cleanup-left-folder");
      assert.ok(
        !(rec2.search as any[]).some((l) => l.folder === "trash"),
        "Trash not looked in",
      );
      assert.ok(
        w.logs.some((l) =>
          /cleanup FAILED for <.*> in gmail-workspace\/qa1: still in Trash/.test(
            l,
          ),
        ),
      );
    } finally {
      await w.stop();
    }
  });

  it("UI drift fails loudly naming the locator and takes the adapter down for the run", async () => {
    const w = await world("drift", { only: ["yahoo"] });
    try {
      const y = w.webmails.yahoo;
      y.drift = true;
      const a = mime("drift-a");
      const b = mime("drift-b");
      const results = await captureAll(
        w.provider(),
        w,
        [req("a", a, "yahoo-web"), req("b", b, "yahoo-web")],
        [message("a", a), message("b", b)],
      );
      assert.equal(results.length, 2);
      for (const r of results) {
        assert.equal(r.status, "failed");
        assert.equal(r.png, undefined);
        assert.match(
          r.reason!,
          /UI drift: Yahoo Mail adapter locator 'opened\.body' \(the story region\) found no showing node below the subject carrying the story's text/,
        );
      }
      // The second story was not delivered: the adapter was down.
      assert.equal(w.api.sent.length, 1);
      // One frame and one tree, for the failure that took it down.
      const withEvidence = results.filter((r) => prov(r).failure);
      assert.equal(withEvidence.length, 1);
      evidence(w, prov(withEvidence[0]!).failure);
      assert.equal(prov(withEvidence[0]!).failure.step, "body-light");
      assert.equal(readdirSync(join(w.runDir, FAILURES_DIR)).length, 2);
      assert.equal(w.logs.filter((l) => /UI drift/.test(l)).length, 1);
    } finally {
      await w.stop();
    }
  });
});

describe("hosted-webmail leases and budgets", () => {
  it("two stories for Gmail with two accounts are captured at once on different accounts", async () => {
    const w = await world("concurrent", {
      accounts: { "gmail-workspace": 2 },
      only: ["gmail-workspace"],
    });
    try {
      w.webmails["gmail-workspace"].deliveryDelayMs = 800;
      const a = mime("con-a");
      const b = mime("con-b");
      const results = await captureAll(
        w.provider(),
        w,
        [req("a", a, "gmail-web"), req("b", b, "gmail-web")],
        [message("a", a), message("b", b)],
      );
      for (const r of results) assert.equal(r.status, "done", r.reason);
      assert.deepEqual(results.map((r) => prov(r).client.account).sort(), [
        "qa1",
        "qa2",
      ]);
      // Both were sent before either was removed: at the same time.
      const sends = w.api.sent.map((s) => s.at).sort((x, y) => x - y);
      const firstRemoved = Math.min(
        ...w.webmails["gmail-workspace"].destroyed.map((d) => d.at),
      );
      assert.equal(sends.length, 2);
      assert.ok(
        sends[1]! < firstRemoved,
        `second send ${sends[1]} after first removal ${firstRemoved}`,
      );
    } finally {
      await w.stop();
    }
  });

  it("leaves an account leased by a running process to it, and takes over a stale lease", async () => {
    const w = await world("leases", {
      accounts: { "gmail-workspace": 2 },
      only: ["gmail-workspace"],
    });
    const holder = spawn(
      process.execPath,
      ["-e", "setTimeout(() => {}, 60000)"],
      { stdio: "ignore" },
    );
    try {
      const lease = (pid: number) => ({
        pid,
        host: hostname(),
        run: "other-run",
        since: new Date().toISOString(),
      });
      writePrivate(
        join(w.profiles, "gmail-workspace", "qa1", "lease.json"),
        lease(holder.pid!),
      );
      const dead = spawnSync(process.execPath, ["-e", "process.exit(0)"]).pid;
      writePrivate(
        join(w.profiles, "gmail-workspace", "qa2", "lease.json"),
        lease(dead),
      );
      const a = mime("lease-a");
      const b = mime("lease-b");
      const results = await captureAll(
        w.provider(),
        w,
        [req("a", a, "gmail-web"), req("b", b, "gmail-web")],
        [message("a", a), message("b", b)],
      );
      for (const r of results) assert.equal(r.status, "done", r.reason);
      assert.deepEqual(
        results.map((r) => prov(r).client.account),
        ["qa2", "qa2"],
      );
      assert.deepEqual(prov(results[0]!).lease.took_over_stale, {
        pid: dead,
        run: "other-run",
      });
      assert.equal(prov(results[1]!).lease.took_over_stale, null);
      // The running holder's lease is untouched.
      const held = JSON.parse(
        readFileSync(
          join(w.profiles, "gmail-workspace", "qa1", "lease.json"),
          "utf8",
        ),
      );
      assert.equal(held.pid, holder.pid);
    } finally {
      holder.kill();
      await w.stop();
    }
  });

  it("drops an account at 90% of its daily budget, and fails a set with none left with budget", async () => {
    const w = await world("budget", {
      accounts: { "gmail-workspace": 2 },
      only: ["gmail-workspace"],
    });
    try {
      const day = utcDay(Date.now());
      writePrivate(join(w.profiles, "gmail-workspace", "qa1", "budget.json"), {
        day,
        count: 9,
      });
      writePrivate(join(w.profiles, "gmail-workspace", "qa2", "budget.json"), {
        day,
        count: 7,
      });
      const env = { ISONIM_EMAIL_WEBMAIL_DAILY_BUDGET: "10" };
      const a = mime("budget-a");
      const b = mime("budget-b");
      const c = mime("budget-c");
      const results = await captureAll(
        w.provider({ env }),
        w,
        [
          req("a", a, "gmail-web"),
          req("b", b, "gmail-web"),
          req("c", c, "gmail-web"),
        ],
        [message("a", a), message("b", b), message("c", c)],
      );
      const by = new Map(results.map((r) => [r.request.story, r]));
      // qa1 (9 of 10: at the cutoff) is out; qa2 takes a (8) and b (9),
      // then it is out too, and c fails with budget.
      assert.equal(by.get("a")!.status, "done", by.get("a")!.reason);
      assert.equal(prov(by.get("a")!).client.account, "qa2");
      assert.equal(by.get("b")!.status, "done", by.get("b")!.reason);
      assert.equal(by.get("c")!.status, "failed");
      assert.match(by.get("c")!.reason!, /^budget: /);
      assert.match(
        by.get("c")!.reason!,
        /gmail-workspace\/qa2 made 9 deliveries today/,
      );
      assert.equal(w.api.sent.length, 2);
      // A set with every account out fails at once.
      const again = await captureAll(
        w.provider({ env }),
        w,
        [req("d", a, "gmail-web")],
        [message("d", a)],
      );
      assert.match(
        again[0]!.reason!,
        /^budget: hosted-webmail gmail-workspace/,
      );
      assert.equal(w.api.sent.length, 2);
    } finally {
      await w.stop();
    }
  });
});

describe("hosted-webmail variants", () => {
  it("Outlook.com: found in the Other tab; light in a light browser, the toggle never touched; dark in a dark browser, a pressed toggle switched off once", async () => {
    const w = await world("outlook", { only: ["outlook-com"] });
    try {
      const ol = w.webmails["outlook-com"];
      ol.filing = () => "other";
      ol.togglePressed = true;
      const m = mime("outlook");
      const results = await captureAll(
        w.provider(),
        w,
        [
          req("s", m, "outlook-web", DESKTOP, "dark"),
          req("s", m, "outlook-web", DESKTOP, "light"),
        ],
        [message("s", m)],
      );
      const light = results.find((r) => r.request.scheme === "light")!;
      const dark = results.find((r) => r.request.scheme === "dark")!;
      assert.equal(light.status, "done", light.reason);
      assert.equal(dark.status, "done", dark.reason);
      assert.equal(w.api.sent.length, 1);
      assert.equal(prov(light).arrival.folder, "inbox");
      assert.ok(
        prov(light).arrival.looks.some((l: any) => l.how === "tab"),
        "found in a tab",
      );
      // Light: a light browser, the theme light, the toggle untouched.
      assert.equal(prov(light).scheme_applied.browser, "light");
      assert.equal(prov(light).scheme_applied.toggle, "untouched");
      assert.ok(prov(light).scheme_applied.theme_luminance >= 128);
      assert.equal(prov(light).restart, undefined);
      // Dark: the browser restarted dark, the message found and opened
      // again, the pressed toggle switched off by one click.
      assert.equal(prov(dark).scheme_applied.browser, "dark");
      assert.equal(prov(dark).scheme_applied.toggle, "switched");
      assert.ok(prov(dark).scheme_applied.theme_luminance < 128);
      assert.equal(prov(dark).restart.scheme, "dark");
      assert.deepEqual(ol.events, ["toggle"]);
      assert.equal(prov(light).crop.locator, 'name="Message body"');
      assert.equal(prov(light).width_check.measured, 800);
      // Light pages first (the light capture ran first although asked
      // second), then dark ones, never light again.
      const seen = ol.probes.map((p) => p.dark);
      assert.equal(seen[0], false, JSON.stringify(ol.probes));
      assert.equal(seen.at(-1), true);
      assert.ok(seen.indexOf(true) > 0);
      assert.ok(!seen.slice(seen.indexOf(true)).includes(false));
      assert.ok(
        prov(dark).scheme_applied.luminance + 40 <
          prov(light).scheme_applied.luminance,
      );
      assert.ok(
        luminance(dark.png!) + 40 < luminance(light.png!),
        `dark ${luminance(dark.png!)} vs light ${luminance(light.png!)}`,
      );
      assert.deepEqual(ol.messages, [], JSON.stringify(cleanup(w)));
      assert.deepEqual(
        cleanup(w).map((c) => [c.state, c.via]),
        [["removed", "trash"]],
      );
    } finally {
      await w.stop();
    }
  });

  it("Outlook.com: dark without a toggle is the dark theme's evidence; a delete in Junk Email that is permanent is removed; a theme that ignores the browser fails that scheme only", async () => {
    const w = await world("outlook2", { only: ["outlook-com"] });
    try {
      const ol = w.webmails["outlook-com"];
      ol.noToggle = true;
      ol.filing = () => "spam";
      ol.junkDeletePermanent = true;
      const a = mime("outlook-junk");
      // A second story on the same worker after the dark one: its list
      // row is captured in a light browser, not the one left dark.
      const c = mime("outlook-after-dark");
      const firstRun = await captureAll(
        w.provider(),
        w,
        [
          req("a", a, "outlook-web", DESKTOP, "dark"),
          req("c", c, "outlook-list", DESKTOP, "light"),
        ],
        [message("a", a), message("c", c)],
      );
      const r = firstRun.find((x) => x.request.clientId === "outlook-web");
      const listRow = firstRun.find(
        (x) => x.request.clientId === "outlook-list",
      )!;
      assert.equal(listRow.status, "done", listRow.reason);
      // (The session check's start page is light; then the dark story,
      // then the second story's pages, all light.)
      const seen = ol.probes.map((p) => p.dark);
      const lastDark = seen.lastIndexOf(true);
      assert.ok(lastDark > 0, JSON.stringify(seen));
      assert.ok(lastDark < seen.length - 1, JSON.stringify(seen));
      assert.ok(seen.slice(lastDark + 1).every((d) => d === false));
      assert.ok(
        ol.probes
          .slice(lastDark + 1)
          .some((p) => p.page.includes("/junkemail")),
        "the second story's list read light",
      );
      assert.equal(r!.status, "done", r!.reason);
      assert.equal(prov(r!).arrival.folder_label, "Junk Email");
      assert.equal(prov(r!).scheme_applied.toggle, "absent");
      assert.match(
        prov(r!).scheme_applied.evidence,
        /no background toggle shown/,
      );
      assert.deepEqual(
        cleanup(w).map((c) => [c.state, c.folder, c.via]),
        [
          ["removed", "spam", "permanent"],
          ["removed", "spam", "permanent"],
        ],
      );
      assert.deepEqual(ol.messages, []);

      // A theme that stays light in a dark browser: the dark capture
      // fails naming why, with the screen kept; the light one stands.
      ol.ignoresDark = true;
      ol.filing = () => "inbox";
      const b = mime("outlook-ignores");
      const results = await captureAll(
        w.provider(),
        w,
        [
          req("b", b, "outlook-web", DESKTOP, "light"),
          req("b", b, "outlook-web", DESKTOP, "dark"),
        ],
        [message("b", b)],
        "t2",
      );
      const light = results.find((x) => x.request.scheme === "light")!;
      const dark = results.find((x) => x.request.scheme === "dark")!;
      assert.equal(light.status, "done", light.reason);
      assert.equal(dark.status, "failed");
      assert.equal(dark.png, undefined);
      assert.match(
        dark.reason!,
        /the page is light \(its subject heading's mean luminance \d+\) in a dark browser, for a dark capture: the webmail's theme does not follow the browser's colour mode/,
      );
      evidence(w, prov(dark).failure);
      assert.equal(prov(dark).failure.step, "body-dark");
      assert.deepEqual(
        cleanup(w).map((c) => c.state),
        ["removed", "removed", "removed"],
      );
    } finally {
      await w.stop();
    }
  });

  it("Gmail: a rewritten Message-ID is found by the run token; a row named after its sender is recognised by its cells; a suggestions list echoing the query is not a row", async () => {
    const w = await world("gmail-search", { only: ["gmail-workspace"] });
    try {
      const gm = w.webmails["gmail-workspace"];
      gm.rewriteMessageId = true;
      gm.rowNamedBySender = true;
      gm.suggestions = true;
      // The open message in Trash offering "Delete forever" (the
      // permanent delete's second alternative).
      gm.trashForever = true;
      const m = mime("search");
      const results = await captureAll(
        w.provider(),
        w,
        [req("s", m, "gmail-web"), req("s", m, "gmail-list")],
        [message("s", m)],
      );
      for (const r of results) assert.equal(r.status, "done", r.reason);
      const body = results.find((r) => r.request.clientId === "gmail-web")!;
      const row = results.find((r) => r.request.clientId === "gmail-list")!;
      const token = prov(body).delivery.subject_token;
      const looks = prov(body).arrival.looks as Record<string, any>[];
      // The Message-ID search finds nothing, the token search the row.
      assert.match(looks[0]!.url, /#search\/rfc822msgid%3A/);
      assert.equal(looks[0]!.token_rows, 0);
      assert.equal(looks[0]!.location_matched, true);
      const hit = looks.at(-1)!;
      assert.match(hit.url, /#search\/%22%5Bes%3At1%3A[0-9a-f]{8}%5D%22$/);
      assert.equal(hit.token_rows, 1);
      // The row's own name is the sender only; the token is in its text.
      assert.ok(hit.rows.includes("Acme Billing"), JSON.stringify(hit.rows));
      // The suggestion carries the token but is no row.
      assert.ok(
        hit.token_nodes.some((n: string) => n.startsWith("list-item/")),
        JSON.stringify(hit.token_nodes),
      );
      assert.ok(prov(row).list_row.name.includes(token));
      assert.match(prov(row).list_row.name, /Preheader words for search/);
      assert.deepEqual(
        cleanup(w).map((c) => [c.state, c.via]),
        [["removed", "trash"]],
      );
      assert.deepEqual(gm.messages, []);
    } finally {
      await w.stop();
    }
  });

  it("Gmail: the body is the story's article, its box exactly; content past it fails as clipped; notifications blocked, a toast dismissed with No thanks; the Trash delete only behind the Trash guard", async () => {
    const w = await world("gmail-article", { only: ["gmail-workspace"] });
    try {
      const gm = w.webmails["gmail-workspace"];
      gm.toastAlways = true;
      gm.noTrashChipFor = "nochip";
      const a = mimeArticle("article");
      const b = mimeArticle("wide", true);
      const c = mimeArticle("nochip");
      const results = await captureAll(
        w.provider(),
        w,
        [
          req("a", a, "gmail-web"),
          req("b", b, "gmail-web"),
          req("c", c, "gmail-web"),
        ],
        [message("a", a), message("b", b), message("c", c)],
      );
      const ra = results.find((r) => r.request.story === "a")!;
      const rb = results.find((r) => r.request.story === "b")!;
      const rc = results.find((r) => r.request.story === "c")!;
      assert.equal(ra.status, "done", ra.reason);
      assert.equal(rc.status, "done", rc.reason);
      // The story's article: its whole box, nothing of Gmail's below.
      assert.equal(prov(ra).crop.locator, "story article");
      const img = readPng(ra.png!);
      assert.equal(img.width, 800);
      // Its box exactly (Chrome's bounds may round a pixel up).
      assert.ok(Math.abs(img.height - 340) <= 1, String(img.height));
      assert.equal(prov(ra).crop.height, img.height);
      assert.deepEqual(prov(ra).width_check, {
        requested: 800,
        measured: 800,
        delta: 0,
      });
      const px = (x: number, y: number) =>
        Array.from(
          img.data.slice((y * img.width + x) * 4, (y * img.width + x) * 4 + 3),
        );
      assert.deepEqual(px(2, 2), [0x33, 0x66, 0x99]);
      assert.deepEqual(px(790, 330), [0xee, 0xee, 0xee]);
      assert.deepEqual(px(2, 338), [0xee, 0xee, 0xee]);
      // Content reaching past the body's box is clipped: not captured.
      assert.equal(rb.status, "failed");
      assert.match(
        rb.reason!,
        /^Gmail: inside the message body \[.*\], a .* node reaches \[.*\], past the body's box: the webmail clips or scrolls the body/,
      );
      assert.equal(rb.png, undefined);
      evidence(w, prov(rb).failure);
      // Notifications are blocked in the profile: every page read the
      // permission denied. The toast shown anyway was dismissed with
      // "No thanks", never "OK".
      assert.ok(gm.probes.length > 0);
      for (const p of gm.probes) assert.equal(p.notif, "denied", p.page);
      assert.ok(gm.events.includes("toast-no"), JSON.stringify(gm.events));
      assert.ok(!gm.events.includes("toast-ok"), JSON.stringify(gm.events));
      assert.ok(
        results.some((r) =>
          (prov(r).notices_dismissed ?? []).includes(
            "name~/^Enable desktop notifications/i",
          ),
        ),
      );
      // The permanent delete in Trash: the open message's "Delete"
      // behind the guard; without the Trash chip nothing is clicked.
      const recs = cleanup(w);
      const byMid = (r: CaptureResult) =>
        recs.find((x) => x.message_id === prov(r).delivery.message_id)!;
      assert.equal(byMid(ra).state, "removed");
      assert.equal(byMid(ra).via, "trash");
      assert.equal(byMid(rb).state, "removed");
      const failed = byMid(rc);
      assert.equal(failed.state, "failed");
      assert.match(
        String(failed.reason),
        /^Gmail: the opened message is not shown in Trash \(the Trash guard: .*role=button name="Search for all messages with label Trash" shown/,
      );
      assert.equal((failed.failure as any).step, "cleanup-delete-forever");
      assert.equal(gm.destroyed.length, 2);
      assert.deepEqual(
        gm.messages.map((m) => [m.folder, m.subject.includes("nochip")]),
        [["trash", true]],
      );
    } finally {
      await w.stop();
    }
  });

  it("Outlook.com: a list drawn as placeholders is waited for, never read as empty; the bare /mail/0/ is the Inbox; a list that never settles is no 'not there'", async () => {
    const w = await world("outlook-loading", { only: ["outlook-com"] });
    try {
      const ol = w.webmails["outlook-com"];
      ol.filing = ({ subject }) =>
        subject.includes("lost") ? "withhold" : "spam";
      // Longer than a look's first wait for the row (listSettleMs).
      ol.listLoadingMs = 4_500;
      const m = mime("loading");
      const results = await captureAll(
        w.provider({ timings: { arrivalTimeoutMs: 60_000 } }),
        w,
        [req("s", m, "outlook-web")],
        [message("s", m)],
      );
      const r = results[0]!;
      assert.equal(r.status, "done", r.reason);
      assert.equal(prov(r).arrival.folder, "spam");
      const looks = prov(r).arrival.looks as Record<string, any>[];
      const inbox = looks.filter((l) => l.folder === "inbox");
      assert.ok(inbox.length >= 1, JSON.stringify(looks));
      for (const l of inbox) {
        // The Inbox shown at /mail/0/ is the Inbox.
        assert.doesNotMatch(l.location, /inbox/, JSON.stringify(l));
        assert.equal(l.location_matched, true, JSON.stringify(l));
        // Read empty only once its list settled: it waited for it.
        assert.equal(l.list.state, "empty", JSON.stringify(l));
        assert.equal(l.list.settled, true);
        assert.equal(l.list.scope, "list");
        assert.ok(l.list.readings >= 2);
        // Placeholders for 4.5 s, the first wait 2.5 s: it read on.
        assert.ok(l.list.waited_ms >= 1_000, JSON.stringify(l));
      }
      // The browser started on the Inbox, shown at /mail/0/: the
      // address bar already held the folder, so it was reloaded.
      assert.equal(inbox[0]!.how, "reload");
      const hit = looks.at(-1)!;
      assert.equal(hit.folder, "spam");
      assert.equal(hit.token_rows, 1);
      assert.equal(hit.list.state, "rows");
      assert.equal(hit.list.settled, true);
      assert.deepEqual(
        cleanup(w).map((c) => [c.state, c.via]),
        [["removed", "trash"]],
      );
      assert.deepEqual(ol.messages, []);

      // A Junk Email list that never stops loading: never "not there",
      // and never waited on past the arrival budget, however long a list
      // may take to settle (listLoadMs ten minutes here).
      ol.neverLoads = ["spam"];
      const lost = mime("lost");
      const t0 = Date.now();
      const again = await captureAll(
        w.provider({
          timings: { arrivalTimeoutMs: 20_000, listLoadMs: 600_000 },
        }),
        w,
        [req("l", lost, "outlook-web")],
        [message("l", lost)],
        "t2",
      );
      const f = again[0]!;
      assert.equal(f.status, "failed");
      assert.match(
        f.reason!,
        /^delivery failure: .* was not found in Outlook\.com's Inbox or Junk Email within 20 s \(1 looks\); Junk Email never settled \(still loading, or read differently each time, for \d+ s after the folder showed\) in the last look: those lists were never read as "not there"/,
      );
      // The whole capture, browser start and cleanup included, well short
      // of the ten minutes one look could otherwise wait.
      assert.ok(Date.now() - t0 < 180_000, `${Date.now() - t0} ms`);
      const junk = (prov(f).search as Record<string, any>[]).filter(
        (l) => l.folder === "spam",
      );
      assert.ok(junk.length >= 1);
      assert.deepEqual(
        [junk.at(-1)!.list.state, junk.at(-1)!.list.settled],
        ["loading", false],
      );
      assert.ok(junk.at(-1)!.list.waited_ms >= 1_000);
      assert.ok(junk.at(-1)!.list.waited_ms <= 20_000);
    } finally {
      await w.stop();
    }
  });

  it("Yahoo in Bulgarian: the session recognised by its structure, the message found in Spam by its folder link when the old URL sends elsewhere, deleted with its Bulgarian controls", async () => {
    const w = await world("yahoo-bg", { only: ["yahoo"] });
    try {
      const y = w.webmails.yahoo;
      y.lang = "bg";
      y.addresses = { qa1: QA.yahoo[0]! };
      y.oldFolderUrlsGone = true;
      y.filing = () => "spam";
      const m = mime("bulgarian");
      const results = await captureAll(
        w.provider(),
        w,
        [req("s", m, "yahoo-web")],
        [message("s", m)],
      );
      const r = results[0]!;
      assert.equal(r.status, "done", r.reason);
      assert.equal(prov(r).arrival.folder, "spam");
      const looks = prov(r).arrival.looks as Record<string, any>[];
      // The Spam URL left the address bar on the Inbox; its link opened it.
      const away = looks.find((l) => l.folder === "spam" && l.how === "typed")!;
      assert.equal(away.list.state, "elsewhere", JSON.stringify(looks));
      const hit = looks.at(-1)!;
      assert.equal(hit.how, "link");
      assert.match(hit.url, /\(link Спам\)$/);
      assert.equal(hit.token_rows, 1);
      // Deleted with "Изтриване", then for good from Trash (its link
      // too) with "Изтриване" and "Добре".
      assert.deepEqual(
        cleanup(w).map((c) => [c.state, c.via]),
        [["removed", "trash"]],
      );
      assert.equal(y.destroyed.length, 1);
      assert.deepEqual(y.messages, []);
      // The account's address, in the title, is in no record.
      assert.doesNotMatch(JSON.stringify(prov(r)), /@receiver\.invalid/);
      assert.doesNotMatch(JSON.stringify(cleanup(w)), /@receiver\.invalid/);
    } finally {
      await w.stop();
    }
  });

  it("fidelity: the same MIME delivered twice matches, a MIME differing in one colour does not", async () => {
    const w = await world("fidelity", { only: ["gmail-workspace"] });
    try {
      const a = mime("fid");
      const b = mime("fid", "#993366");
      const first = await captureAll(
        w.provider(),
        w,
        [req("s", a, "gmail-web")],
        [message("s", a)],
        "f1",
      );
      const second = await captureAll(
        w.provider(),
        w,
        [req("s", a, "gmail-web")],
        [message("s", a)],
        "f2",
      );
      const other = await captureAll(
        w.provider(),
        w,
        [req("s", b, "gmail-web")],
        [message("s", b)],
        "f3",
      );
      for (const r of [...first, ...second, ...other])
        assert.equal(r.status, "done", r.reason);
      // Gmail's browser runs light.
      assert.ok(w.webmails["gmail-workspace"].probes.every((p) => !p.dark));
      const same = fidelityVerdict(first[0]!.png!, second[0]!.png!);
      assert.equal(same.match, true, same.reason);
      const diff = fidelityVerdict(first[0]!.png!, other[0]!.png!);
      assert.equal(diff.match, false, diff.reason);
      assert.match(diff.reason, /^different/);
      const size = fidelityVerdict(
        first[0]!.png!,
        readFileSync(
          join(repoRoot, "tests", "baselines", "canary", readdirFirstPng()),
        ),
      );
      assert.equal(size.match, false);
    } finally {
      await w.stop();
    }
  });

  it("a repeat run through the harness, once the UI fingerprint is known, is a cache hit and delivers nothing", async () => {
    const w = await world("cache", { only: ["gmail-workspace"] });
    try {
      const m = mime("cache");
      const spec: MatrixSpec = {
        stories: [{ story: "s", mimeSha256: sha(m) }],
        families: ["gmailWeb"],
        clients: ["gmail-web"],
        backends: ["b"],
        viewports: [DESKTOP],
        schemes: ["light"],
        images: ["on"],
      };
      const run = async (name: string) => {
        const ps = [w.provider()];
        const availability = new Map<string, ProviderHealth>([
          ["hosted-webmail", { state: "ok" }],
        ]);
        const plan = routeRequests(ps, availability, spec);
        const rows: string[] = [];
        const runDir = join(w.dir, name);
        mkdirSync(runDir, { recursive: true });
        await executePlan(
          ps,
          availability,
          plan,
          new Map([[sha(m), message("s", m)]]),
          {
            run: name,
            session: null,
            runDir,
            library: { commit: "test", dirty: true, tree_hash: "test" },
            cacheRoot: join(w.dir, "cache"),
            noCache: false,
            assert: false,
            cold: false,
          },
          ({ entry }) => rows.push(entry.status),
        );
        return {
          rows,
          meta: JSON.parse(
            readFileSync(
              join(runDir, "s", "b-gmailWeb-gmail-web-desktop-light-on.json"),
              "utf8",
            ),
          ),
        };
      };
      // The client build carries the last UI fingerprint seen, which
      // the first capture learns: so the first run is keyed on none,
      // the second on the fingerprint, and the third hits.
      const one = await run("c1");
      assert.deepEqual(one.rows, ["done"]);
      assert.equal(one.meta.cache, "miss");
      assert.match(
        one.meta.client.build,
        /^ui-fp:none\+(google-chrome|chromium)-\d/,
      );
      const two = await run("c2");
      assert.equal(two.meta.cache, "miss");
      assert.match(
        two.meta.client.build,
        /^ui-fp:[0-9a-f]{12}\+(google-chrome|chromium)-\d/,
      );
      assert.equal(w.api.sent.length, 2);
      const three = await run("c3");
      assert.deepEqual(three.rows, ["done"]);
      assert.equal(three.meta.cache, "hit");
      assert.equal(three.meta.client.build, two.meta.client.build);
      assert.equal(w.api.sent.length, 2, "the hit delivered nothing");
    } finally {
      await w.stop();
    }
  });
});

function readdirFirstPng(): string {
  return readdirSync(join(repoRoot, "tests", "baselines", "canary")).find((n) =>
    n.endsWith(".png"),
  )!;
}

describe("the backend-b command line", () => {
  const cli = join(repoRoot, "tools", "capture", "email-shots.ts");
  const checklist = join(
    repoRoot,
    "tools",
    "capture",
    "email-webmail-checklist.ts",
  );

  it("email-shots --backends b without credentials fails cleanly with the remedy", () => {
    const creds = join(scratch, "cli-empty");
    mkdirSync(creds, { recursive: true, mode: 0o700 });
    chmodSync(creds, 0o700);
    const out = join(scratch, "cli-run");
    const r = spawnSync(
      process.execPath,
      [
        cli,
        "canary",
        "--backends",
        "b",
        "--clients",
        "gmail-web",
        "--viewports",
        "desktop",
        "--no-cache",
        "--out",
        out,
      ],
      {
        cwd: repoRoot,
        encoding: "utf8",
        env: {
          ...process.env,
          ISONIM_EMAIL_CREDENTIALS_DIR: creds,
          ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: join(scratch, "cli-profiles"),
        },
      },
    );
    assert.equal(r.status, 1, r.stderr);
    assert.match(
      r.stderr,
      /provider hosted-webmail \(backend b\) UNAVAILABLE: .*no account file matches workspace-sender\/\*\.json/,
    );
    assert.match(
      r.stderr,
      /`just email-webmail-checklist` lists the steps a person runs, in order/,
    );
    assert.match(
      r.stderr,
      /FAILED canary gmailWeb desktop\/light images on, provider hosted-webmail, client gmail-web/,
    );
    assert.doesNotMatch(r.stderr, /TypeError|ReferenceError|\n\s+at /);
  });

  it("the checklist names the steps in order, and what is pending or ready", async () => {
    const empty = join(scratch, "checklist-empty");
    mkdirSync(empty, { recursive: true, mode: 0o700 });
    chmodSync(empty, 0o700);
    const run = (env: Record<string, string>) =>
      spawnSync(process.execPath, [checklist], {
        cwd: repoRoot,
        encoding: "utf8",
        env: { ...process.env, ...env },
      });
    const pending = run({
      ISONIM_EMAIL_CREDENTIALS_DIR: empty,
      ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: join(scratch, "checklist-profiles"),
    });
    assert.equal(pending.status, 3, pending.stderr);
    const steps = [...pending.stdout.matchAll(/ (\d)\. /g)].map((m) => m[1]);
    assert.deepEqual(steps, ["1", "2", "3", "4", "5"]);
    assert.match(
      pending.stdout,
      /\[PENDING\] 2\. the Workspace sender: no sender file/,
    );
    assert.match(
      pending.stdout,
      /just email-workspace-send-smoke gmail-workspace/,
    );
    assert.match(
      pending.stdout,
      /just email-shots receiptTypical --backends b --clients gmail-web --no-cache/,
    );
    assert.match(pending.stdout, /^PENDING: /m);
    const w = await world("checklist", { only: [] });
    try {
      const ready = run({
        ISONIM_EMAIL_CREDENTIALS_DIR: w.creds,
        ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: w.profiles,
      });
      assert.equal(ready.status, 0, ready.stdout);
      assert.match(
        ready.stdout,
        /\[  ok  \] 2\. the Workspace sender \(workspace-sender\/tests\.json/,
      );
      assert.match(
        ready.stdout,
        /\[  ok  \]    Gmail gmail-workspace\/qa1: signed in/,
      );
      assert.match(ready.stdout, /^ready: 3 of 3 webmails can capture/m);
      assert.doesNotMatch(
        ready.stdout,
        /@receiver\.invalid|@tenant\.invalid|never-the-harness/,
      );
    } finally {
      await w.stop();
    }
  });
});
