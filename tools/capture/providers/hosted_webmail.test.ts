// tools/capture/providers/hosted_webmail.test.ts — the hosted-webmail
// provider (backend b) end to end, against local stand-ins.
//
// What is proven, each over the real procedure in real Chromium under
// Playwright, on persistent profiles signed in beforehand (by the test
// playing the person):
// - routing: backend b joins a run only when named, and its list rows
//   only when --clients names them;
// - a story is delivered once by Workspace send (the fake Gmail API
//   receives exactly the submitted copy for the QA address), found in
//   Inbox by its Message-ID, its list row captured before it is opened
//   (sender, subject with the run token, the preheader as the preview),
//   opened, its body cropped, and then removed from every folder (Trash
//   included), the cleanup record saying so; the provenance names the
//   account by its file's name, never its address;
// - a message filed as Spam is found there and the provenance says so;
//   one that never arrives fails as a delivery failure after the bounded
//   wait, never a capture of nothing;
// - a lost session (at lease time, or mid-capture) marks the account
//   needs-login, fails its requests with "session lost:" naming the
//   sign-in recipe, says so on the log at once, and nothing is ever
//   typed into the sign-in page; mid-capture it is a lost session, not
//   UI drift; an inbox that does not load at all is not a lost session;
// - a message that cannot be shown to be the delivered one (its opened
//   subject lacks the run token) is neither captured nor deleted;
// - a removal that leaves the message in a folder is a failed cleanup;
// - UI drift: a body locator that matches nothing fails loudly naming
//   the adapter, the locator and its selector, and takes the adapter
//   down for the rest of the run (its next story is not even delivered);
// - leases: two stories for Gmail with two accounts are captured at the
//   same time on different accounts; an account leased by a running
//   process is left to it; a stale lease is taken over and recorded;
// - budgets: an account at 90% of its daily budget drops out, and a set
//   with none left fails with "budget:";
// - Outlook.com: a message in the Other tab is found; light is the
//   background toggle on, dark the body recoloured (data-ogsc) and
//   darker; the mobile-web variant reopens the profile as a phone;
// - the fidelity comparison: the same MIME delivered twice matches, a
//   MIME differing in one colour does not;
// - through the harness: once the first capture has learnt the UI
//   fingerprint (part of the client build), a repeat run is a cache hit
//   and delivers nothing;
// - the CLI: `email-shots --backends b` without credentials fails
//   cleanly with the remedy, and the checklist says what is pending.
//
// Test doubles (justification, per the repository's mock policy): the
// hosted webmails need a real account signed in and the Gmail API sends
// real mail, so neither can be used from a test. webmail_standin.ts plays
// each webmail with the adapter's DOM contract on loopback, and Google's
// token endpoint and Gmail send over TLS with a throwaway authority.
// Chromium, Playwright, the persistent profiles, the provider, the
// Workspace delivery code, the leases, budgets and the harness are real.
// Run with:
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
  writeFileSync,
} from "node:fs";
import { hostname, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { readPng } from "../contact_sheet.ts";
import { resolveDriver } from "./browser_emulation.ts";
import { executePlan, routeRequests, type MatrixSpec } from "./harness.ts";
import {
  fidelityVerdict,
  HostedWebmailProvider,
  type HostedWebmailTimings,
} from "./hosted_webmail.ts";
import { registeredProviders } from "./registry.ts";
import { CREDENTIALS_SCHEMA } from "./requirements.ts";
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
  accountProfile,
  webmailLaunchOptions,
  writeSigninRecord,
} from "./webmail_profiles.ts";
import { FakeGmailApi, StandinWebmail, type Skin } from "./webmail_standin.ts";

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

const FAST: Partial<HostedWebmailTimings> = {
  arrivalTimeoutMs: 6_000,
  pollMs: 200,
  listSettleMs: 700,
  stepTimeoutMs: 4_000,
  leaseWaitMs: 1_500,
  leasePollMs: 100,
  signinCheckMs: 8_000,
  imageTimeoutMs: 300,
  stableMs: 50,
  cleanupFindMs: 4_000,
};

const DESKTOP: ViewportSpec = { name: "desktop", width: 800, dpr: 1 };
const MOBILE: ViewportSpec = { name: "mobile", width: 375, dpr: 3 };

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

const sha = (b: Uint8Array): string =>
  createHash("sha256").update(b).digest("hex");

function message(story: string, bytes: Uint8Array): StoryMessage {
  return { story, mime: bytes, html: "" };
}

const FAMILY: Record<string, string> = {
  "gmail-web": "gmailWeb",
  "gmail-mobile-web": "gmailWeb",
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
  provider(extra?: {
    env?: Record<string, string>;
    timings?: Partial<HostedWebmailTimings>;
  }): HostedWebmailProvider;
  stop(): Promise<void>;
}

let pw: typeof import("playwright-core") | null = null;
async function playwright(): Promise<typeof import("playwright-core")> {
  if (pw !== null) return pw;
  const driver = resolveDriver(process.env);
  if ("reason" in driver) throw new Error(driver.reason);
  pw = (await import(
    pathToFileURL(join(driver.dir, "index.mjs")).href
  )) as typeof import("playwright-core");
  return pw;
}

// A credentials directory, signed-in profiles and the stand-ins.
async function world(
  name: string,
  opts: { accounts?: Partial<Record<SetId, number>>; signIn?: boolean } = {},
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
    const p = await playwright();
    for (const set of Object.keys(QA) as SetId[])
      for (let i = 0; i < accounts[set]; i++) {
        const file = `${set}/qa${i + 1}.json`;
        const prof = accountProfile(host, set, file, true);
        const ctx = await p.chromium.launchPersistentContext(
          prof.userDataDir,
          webmailLaunchOptions(env, true),
        );
        const pg = ctx.pages()[0] ?? (await ctx.newPage());
        await pg.goto(`${webmails[set].origin}/login?account=qa${i + 1}`);
        await ctx.close();
        writeSigninRecord(prof, {
          set,
          account_file: file,
          signed_in_at: new Date().toISOString(),
          host: new URL(webmails[set].origin).host,
          browser: "chromium (test)",
        });
      }
  }
  const origins = Object.fromEntries(
    (Object.keys(QA) as SetId[]).map((s) => [
      HOSTS[SKIN[s]],
      webmails[s].origin,
    ]),
  );
  const adapters = WEBMAIL_ADAPTERS.map((a) => rebaseAdapter(a, origins));
  const logs: string[] = [];
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
    provider: (extra = {}) =>
      new HostedWebmailProvider({
        env: { ...env, ...extra.env },
        adapters,
        workspace: { endpoints, trust: { ca: api.pki.caPem } },
        timings: { ...FAST, ...extra.timings },
        headless: true,
        log: (l) => logs.push(l),
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
  return out;
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

  it("routes backend b only when named, and its list rows only when --clients names them", () => {
    assert.deepEqual(clientsOf(spec({})), []);
    assert.deepEqual(clientsOf(spec({ backends: ["a", "b"] })), [
      "gmail-mobile-web",
      "gmail-web",
      "outlook-mobile-web",
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
    const w = await world("e2e");
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
      assert.equal(prov(body).width_check.requested, 800);
      assert.match(prov(body).ui_fingerprint.value, /^[0-9a-f]{12}$/);
      // The row, before opening: sender, subject with the token, the
      // preheader as the preview.
      assert.equal(prov(row).list_row.sender, "Acme Billing");
      assert.ok(prov(row).list_row.subject.startsWith(d.subject_token));
      assert.match(prov(row).list_row.preview, /Preheader words for e2e/);
      assert.ok(readPng(row.png!).height < img.height);
      // Removed: nothing left in any folder, and the record says so.
      assert.deepEqual(w.webmails["gmail-workspace"].messages, []);
      assert.deepEqual(
        cleanup(w).map((c) => [c.state, c.folder, c.account]),
        [["removed", "inbox", "qa1"]],
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
    const w = await world("spam");
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
        /^delivery failure: <.*> \(sent through the Gmail API as api\d\) was not found in Gmail's Inbox or Spam within 6 s/,
      );
      assert.equal(rb.png, undefined);
      const states = cleanup(w)
        .map((c) => c.state)
        .sort();
      assert.deepEqual(states, ["not-found", "removed"]);
      assert.deepEqual(gm.messages, []);
    } finally {
      await w.stop();
    }
  });
});

describe("hosted-webmail session loss and UI drift", () => {
  it("a session lost before delivery marks the account needs-login, names the sign-in, and types nothing", async () => {
    const w = await world("lost");
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
    const w = await world("lost-mid");
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
    const w = await world("unreachable");
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
        /yahoo\/qa1: the inbox did not load: .*the session was not judged/,
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
    const w = await world("identity");
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
        /the opened message is not the delivered one \(its subject 'Another message' lacks the run token/,
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
    const w = await world("kept");
    try {
      const gm = w.webmails["gmail-workspace"];
      gm.keepDestroyed = true;
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
    const w = await world("drift");
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
          /UI drift: Yahoo Mail adapter locator 'opened\.body' \(\[data-test-id="message-view-body-content"\], unverified-live\) matched no visible element/,
        );
      }
      // The second story was not delivered: the adapter was down.
      assert.equal(w.api.sent.length, 1);
      assert.equal(w.logs.filter((l) => /UI drift/.test(l)).length, 1);
    } finally {
      await w.stop();
    }
  });
});

describe("hosted-webmail leases and budgets", () => {
  it("two stories for Gmail with two accounts are captured at once on different accounts", async () => {
    const w = await world("concurrent", { accounts: { "gmail-workspace": 2 } });
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
    const w = await world("leases", { accounts: { "gmail-workspace": 2 } });
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
    const w = await world("budget", { accounts: { "gmail-workspace": 2 } });
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
  it("Outlook.com: found in the Other tab; light is the background toggle on, dark the body recoloured", async () => {
    const w = await world("outlook");
    try {
      w.webmails["outlook-com"].filing = () => "other";
      const m = mime("outlook");
      const results = await captureAll(
        w.provider(),
        w,
        [
          req("s", m, "outlook-web", DESKTOP, "light"),
          req("s", m, "outlook-web", DESKTOP, "dark"),
        ],
        [message("s", m)],
      );
      const light = results.find((r) => r.request.scheme === "light")!;
      const dark = results.find((r) => r.request.scheme === "dark")!;
      assert.equal(light.status, "done", light.reason);
      assert.equal(dark.status, "done", dark.reason);
      assert.equal(w.api.sent.length, 1);
      assert.equal(prov(light).arrival.folder, "inbox");
      assert.equal(
        prov(light).scheme_applied.evidence,
        "background toggle aria-pressed=true",
      );
      assert.equal(
        prov(dark).scheme_applied.evidence,
        "background toggle aria-pressed=false",
      );
      assert.equal(prov(light).scheme_applied.recoloured_elements, 0);
      assert.ok(prov(dark).scheme_applied.recoloured_elements > 0);
      assert.ok(
        luminance(dark.png!) + 40 < luminance(light.png!),
        `dark ${luminance(dark.png!)} vs light ${luminance(light.png!)}`,
      );
      assert.deepEqual(
        w.webmails["outlook-com"].messages,
        [],
        JSON.stringify(cleanup(w)),
      );
    } finally {
      await w.stop();
    }
  });

  it("the mobile-web variant reopens the profile as a phone, on the same delivery", async () => {
    const w = await world("mobile");
    try {
      const m = mime("mobile");
      const results = await captureAll(
        w.provider(),
        w,
        [req("s", m, "gmail-mobile-web", MOBILE), req("s", m, "gmail-web")],
        [message("s", m)],
      );
      for (const r of results) assert.equal(r.status, "done", r.reason);
      assert.equal(w.api.sent.length, 1);
      const mob = results.find(
        (r) => r.request.clientId === "gmail-mobile-web",
      )!;
      assert.equal(prov(mob).client.ui, "mobile");
      assert.equal(prov(mob).client.device, "iphone");
      assert.equal(prov(mob).width_check.requested, 375);
      assert.ok(
        w.webmails["gmail-workspace"].userAgents.some((u) => /iPhone/.test(u)),
      );
      // DPR 3: the PNG is three times the CSS box.
      assert.ok(
        Math.abs(readPng(mob.png!).width - prov(mob).crop.width * 3) <= 3,
      );
      // The desktop and mobile UIs keep a fingerprint each: neither
      // capture reads the other's as a change.
      const desk = results.find((r) => r.request.clientId === "gmail-web")!;
      assert.notEqual(
        prov(mob).ui_fingerprint.value,
        prov(desk).ui_fingerprint.value,
      );
      assert.equal(prov(mob).ui_fingerprint.changed, false);
      assert.equal(prov(desk).ui_fingerprint.changed, false);
    } finally {
      await w.stop();
    }
  });

  it("fidelity: the same MIME delivered twice matches, a MIME differing in one colour does not", async () => {
    const w = await world("fidelity");
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
    const w = await world("cache");
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
    const w = await world("checklist");
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
