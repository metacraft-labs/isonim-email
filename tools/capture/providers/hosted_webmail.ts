// tools/capture/providers/hosted_webmail.ts — the hosted-webmail
// capture provider (backend b): the real Gmail, Yahoo Mail and
// Outlook.com, signed in by a person once, captured after real delivery.
//
// A capture, per story and QA account (the procedure is one
// implementation over the adapters' data, webmail_adapters.ts):
//  1. lease the account (webmail_accounts.ts: a lock file per account;
//     any free, signed-in account of the set under its daily budget),
//     check its session (the inbox loads on the mail host with the
//     mailbox marker) and count the delivery against its budget;
//  2. deliver the story by Workspace send (workspace_send.ts): the
//     Workspace sender sends the copy, with a fresh Message-ID and the
//     run token in the subject, to the account through the Gmail API;
//  3. find it in the webmail: Inbox, then Spam/Junk, polled up to a
//     bounded wait, recording where it arrived; not found in time is a
//     delivery failure, never a capture of nothing;
//  4. for an inbox-list client, screenshot its row before it is opened;
//     open it and check that the opened subject carries the run token;
//  5. per requested variant: size the window so the body gets the
//     requested width, set the scheme (Outlook.com: its background
//     toggle), wait for the body, fonts, images and a stable box, lift
//     the body's scroll containers, and screenshot the body, masking
//     the chrome inside it; each result is yielded as it lands;
//  6. delete the message in the UI, then from Trash/Deleted Items, look
//     again in every folder, and record the outcome in
//     <run>/hosted-webmail-cleanup.jsonl; release the lease.
//
// Never a sign-in: a page that leaves the mail hosts is a lost session.
// The account is marked needs-login (out of selection until a person's
// sign-in passes), its requests fail with "session lost:" naming the
// sign-in recipe, and the same line goes to stderr at once. A locator
// that matches nothing or more than one element while the page is on
// the mail host is UI drift: the capture fails naming the locator, and
// the adapter is down for the rest of the run, so no crop is ever made
// from a UI the adapter does not recognise.
//
// Credentials only from the credentials directory: the Workspace
// sender's file and the QA account files (credentials.ts). No secret is
// printed, written or carried in a result: the provenance names the
// account by its file's name, never by its address.
//
// The provider is opt-in: it joins a run only when named (--backends b,
// or one of its --clients), since every capture sends real mail and
// spends an account's budget.

import { createHash } from "node:crypto";
import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import type { BrowserContext, Locator, Page } from "playwright-core";
import { TIER2_MAX_DIFF_RATIO } from "../email-capture-ci.ts";
import { diffPng } from "../perceptual.ts";
import { resolveDriver } from "./browser_emulation.ts";
import { credentialRequirement, WORKSPACE_SENDER_SET } from "./credentials.ts";
import { loadHostedAccount } from "./hosted_delivery.ts";
import type { HostEnv } from "./requirements.ts";
import type {
  CaptureProvider,
  CaptureRequest,
  CaptureResult,
  ClientDescriptor,
  Emulation,
  ProviderHealth,
  Requirement,
  SessionCtx,
  Sha256,
  StoryMessage,
} from "./types.ts";
import {
  budgetState,
  countDelivery,
  dailyBudget,
  type Lease,
  markNeedsLogin,
  type PoolAccount,
  poolAccounts,
  readFingerprint,
  readiness,
  releaseLease,
  signinCommand,
  tryLease,
  writeFingerprint,
} from "./webmail_accounts.ts";
import {
  type AdapterClient,
  type AdapterUi,
  type FolderName,
  folderUrl,
  IPHONE_USER_AGENT,
  WEBMAIL_ADAPTERS,
  type WebmailAdapter,
  type WebmailLocator,
  WINDOW_HEIGHT,
} from "./webmail_adapters.ts";
import { checkSignedIn, webmailLaunchOptions } from "./webmail_profiles.ts";
import {
  deliverWorkspace,
  loadWorkspaceSender,
  type WorkspaceDelivery,
  type WorkspaceOptions,
  type WorkspaceSender,
} from "./workspace_send.ts";

export const HOSTED_WEBMAIL_ID = "hosted-webmail";
// Bump whenever output can change for reasons no other key field
// captures (the UI fingerprint and the browser are in client_build).
export const HOSTED_WEBMAIL_VERSION = "1";
// Bump by hand when crop, mask or wait logic changes.
export const HOSTED_WEBMAIL_ADAPTER_VERSION = 1;

export const HEADLESS_ENV = "ISONIM_EMAIL_WEBMAIL_HEADLESS";

// What a person does to make backend b available: the one recipe that
// lists the steps, in order, and checks each.
export const REMEDY =
  "`just email-webmail-checklist` lists the steps a person runs, in order (unlock the credentials, the Workspace sender, a sign-in per set, a smoke send) and checks each";

export interface HostedWebmailTimings {
  // How long a delivered message may take to show up.
  arrivalTimeoutMs: number;
  // Between arrival polls.
  pollMs: number;
  // How long a folder list may take to show the message's row.
  listSettleMs: number;
  // Every other wait for a locator.
  stepTimeoutMs: number;
  // How long a request waits for a lease another run holds.
  leaseWaitMs: number;
  leasePollMs: number;
  // The signed-in check at lease time.
  signinCheckMs: number;
  // Waiting for the body's images (they may point at a host the
  // webmail's proxy cannot reach: never a failure).
  imageTimeoutMs: number;
  // Layout stability: two equal boxes this far apart.
  stableMs: number;
  // Finding the deleted message in Trash.
  cleanupFindMs: number;
}

export const DEFAULT_TIMINGS: HostedWebmailTimings = {
  arrivalTimeoutMs: 60_000,
  pollMs: 2_000,
  listSettleMs: 4_000,
  stepTimeoutMs: 20_000,
  leaseWaitMs: 600_000,
  leasePollMs: 1_000,
  signinCheckMs: 30_000,
  imageTimeoutMs: 5_000,
  stableMs: 300,
  cleanupFindMs: 15_000,
};

export interface HostedWebmailOptions {
  env?: Record<string, string | undefined>;
  // Test seams (hosted_webmail.test.ts): the adapters (rebased onto a
  // stand-in webmail), the Gmail API endpoints and their trust roots,
  // shorter waits, headless, the clock, where notices go.
  adapters?: WebmailAdapter[];
  workspace?: WorkspaceOptions;
  timings?: Partial<HostedWebmailTimings>;
  headless?: boolean;
  now?: () => number;
  log?: (line: string) => void;
}

type Playwright = typeof import("playwright-core");

// ---------------------------------------------------------------------------
// Failures
// ---------------------------------------------------------------------------

class StepError extends Error {}

// A locator that no longer matches the UI as the adapter describes it.
class DriftError extends Error {}

class SessionLostError extends Error {}

class DeliveryTimeout extends Error {}

// An error as one line: Playwright's carry a call log (with terminal
// colours) after the first line.
function oneLine(err: unknown): string {
  const text = err instanceof Error ? err.message : String(err);
  return (text.split("\n")[0] ?? "").replace(/\u001b\[[0-9;]*m/g, "").trim();
}

// ---------------------------------------------------------------------------
// The fidelity comparison (an injection route against delivery)
// ---------------------------------------------------------------------------

export interface FidelityVerdict {
  match: boolean;
  diffRatio: number | null;
  reason: string;
}

// Whether two captures of the same request agree within the Tier-2
// threshold: what an injection route must show against delivery before
// it may be used. A size difference is a difference, never an error.
export function fidelityVerdict(
  delivered: Uint8Array,
  other: Uint8Array,
  threshold = TIER2_MAX_DIFF_RATIO,
): FidelityVerdict {
  let d: { diffRatio: number; diffPixels: number };
  try {
    d = diffPng(Buffer.from(delivered), Buffer.from(other));
  } catch (err) {
    return {
      match: false,
      diffRatio: null,
      reason: `not comparable: ${oneLine(err)}`,
    };
  }
  return d.diffRatio <= threshold
    ? {
        match: true,
        diffRatio: d.diffRatio,
        reason: `within the threshold (${d.diffPixels} px, ratio ${d.diffRatio.toExponential(2)} <= ${threshold})`,
      }
    : {
        match: false,
        diffRatio: d.diffRatio,
        reason: `different (${d.diffPixels} px, ratio ${d.diffRatio.toExponential(2)} > ${threshold})`,
      };
}

// ---------------------------------------------------------------------------
// In-page helpers (the type-check has no DOM library)
// ---------------------------------------------------------------------------

interface El {
  tagName: string;
  getAttribute(n: string): string | null;
  classList: Iterable<string>;
  children: ArrayLike<El>;
  querySelectorAll(s: string): ArrayLike<El>;
}

interface BodyEl {
  querySelectorAll(
    s: string,
  ): ArrayLike<{ complete: boolean; loading: string }>;
}

interface RelaxEl {
  parentElement: RelaxEl | null;
  getAttribute(n: string): string | null;
  setAttribute(n: string, v: string): void;
  removeAttribute(n: string): void;
  style: { setProperty(n: string, v: string, priority: string): void };
}

interface RelaxGlobal {
  getComputedStyle(e: RelaxEl): {
    overflowX: string;
    overflowY: string;
    maxHeight: string;
  };
  __isonimRelaxed?: { el: RelaxEl; style: string | null }[];
}

// Lifts every ancestor of the body that clips it (a scroll or hidden
// overflow, a max-height), remembering each one's style attribute so
// that restoreScroll puts it back. Runs in the page.
function relaxScroll(el: RelaxEl): number {
  const g = globalThis as unknown as RelaxGlobal;
  const changed: { el: RelaxEl; style: string | null }[] = [];
  for (let a = el.parentElement; a !== null; a = a.parentElement) {
    const s = g.getComputedStyle(a);
    if (
      /(auto|scroll|hidden)/.test(s.overflowY + s.overflowX) ||
      s.maxHeight !== "none"
    ) {
      changed.push({ el: a, style: a.getAttribute("style") });
      a.style.setProperty("max-height", "none", "important");
      a.style.setProperty("overflow", "visible", "important");
      a.style.setProperty("height", "auto", "important");
    }
  }
  g.__isonimRelaxed = changed;
  return changed.length;
}

function restoreScroll(): void {
  const g = globalThis as unknown as RelaxGlobal;
  for (const { el, style } of g.__isonimRelaxed ?? []) {
    if (style === null) el.removeAttribute("style");
    else el.setAttribute("style", style);
  }
  g.__isonimRelaxed = [];
}

// ---------------------------------------------------------------------------
// The provider
// ---------------------------------------------------------------------------

interface Handle {
  delivery: WorkspaceDelivery;
  folder: FolderName;
  arrivalMs: number;
  polls: number;
}

interface StoryJob {
  story: string;
  mimeSha256: Sha256;
  requests: CaptureRequest[];
}

interface Worker {
  account: PoolAccount;
  context: BrowserContext | null;
  page: Page | null;
  mode: "desktop" | "mobile" | null;
  dpr: number;
  sessionChecked: boolean;
}

type Emit = (r: CaptureResult) => void;

export class HostedWebmailProvider implements CaptureProvider {
  readonly id = HOSTED_WEBMAIL_ID;
  readonly backend = "b";
  readonly version = HOSTED_WEBMAIL_VERSION;
  readonly adapterVersion = HOSTED_WEBMAIL_ADAPTER_VERSION;
  readonly via = "submit";
  readonly optIn = true;

  private readonly env: Record<string, string | undefined>;
  private readonly host: HostEnv;
  private readonly adapters: WebmailAdapter[];
  private readonly workspace: WorkspaceOptions;
  private readonly t: HostedWebmailTimings;
  private readonly headlessOpt: boolean | undefined;
  private readonly now: () => number;
  private readonly log: (line: string) => void;
  private pw: Playwright | null = null;
  private sender: WorkspaceSender | null = null;
  private run = "";
  private runDir = "";
  private cold = false;
  // Adapters found drifted in this run, with the diagnostic.
  private readonly down = new Map<string, string>();
  private readonly workers: Worker[] = [];
  private readonly leases = new Set<Lease>();

  constructor(opts: HostedWebmailOptions = {}) {
    this.env = opts.env ?? process.env;
    this.host = { env: this.env, platform: process.platform };
    this.adapters = opts.adapters ?? WEBMAIL_ADAPTERS;
    this.workspace = opts.workspace ?? {};
    this.t = { ...DEFAULT_TIMINGS, ...opts.timings };
    this.headlessOpt = opts.headless;
    this.now = opts.now ?? Date.now;
    this.log = opts.log ?? ((l) => process.stderr.write(`${l}\n`));
  }

  private headless(): boolean {
    return this.headlessOpt ?? this.env[HEADLESS_ENV] === "1";
  }

  private adapter(clientId: string): {
    adapter: WebmailAdapter;
    client: AdapterClient;
  } | null {
    for (const adapter of this.adapters)
      for (const client of adapter.clients)
        if (client.clientId === clientId) return { adapter, client };
    return null;
  }

  clients(): ClientDescriptor[] {
    return this.adapters.flatMap((adapter) =>
      adapter.clients.map((c) => ({
        clientId: c.clientId,
        family: c.family,
        engine: "blink" as const,
        build: async () => this.build(adapter, c.ui),
        viewports: c.viewports,
        schemes: c.schemes,
        imagesOff: false,
        approximation: false,
        // A list row is captured only when --clients names it.
        ...(c.kind === "list" ? { namedOnly: true } : {}),
      })),
    );
  }

  // The last UI fingerprint seen for the adapter's UI (desktop or
  // mobile; a list row is on the desktop UI) and the browser build: both
  // decide the pixels. A capture that sees another fingerprint records
  // it and updates it, so the next run's key differs.
  private build(adapter: WebmailAdapter, ui: "desktop" | "mobile"): string {
    const driver = resolveDriver(this.env);
    if ("reason" in driver) return "";
    let rev = "unknown";
    try {
      const browsers = JSON.parse(
        readFileSync(join(driver.dir, "browsers.json"), "utf8"),
      ) as { browsers: { name: string; revision: string }[] };
      rev =
        browsers.browsers.find((b) => b.name === "chromium")?.revision ?? rev;
    } catch {
      // keep "unknown"
    }
    const fp = readFingerprint(this.host, adapter.set, ui) ?? "none";
    return `ui-fp:${fp}+chromium-${rev}`;
  }

  requirements(): Requirement[] {
    const sender = credentialRequirement(WORKSPACE_SENDER_SET);
    return [
      {
        kind: "host-os",
        os: ["linux", "darwin"],
        why: "the pinned Playwright Chromium runs on Linux and macOS",
      },
      {
        kind: "env-dir",
        variable: "PLAYWRIGHT_BROWSERS_PATH",
        why: "the dev shell's pinned Chromium, the build the webmail profiles were signed in with (run under `nix develop`)",
      },
      { ...sender, why: `${sender.why}; ${REMEDY}` },
    ];
  }

  // Per set: its accounts and why each is not ready.
  private pools(): Map<string, PoolAccount[]> {
    const limit = dailyBudget(this.env);
    const out = new Map<string, PoolAccount[]>();
    for (const a of this.adapters)
      out.set(a.set, poolAccounts(this.host, a.set, limit, this.now()));
    return out;
  }

  // Why a set cannot serve now, with what to run; null when it can.
  private setProblem(set: string, accounts: PoolAccount[]): string | null {
    if (accounts.length === 0)
      return `${set}: no account file (${set}/*.json) in the credentials directory`;
    if (accounts.some((a) => readiness(a).ready)) return null;
    const why = accounts.map((a) => {
      const r = readiness(a);
      return r.ready ? "" : `${r.why} (${r.remedy})`;
    });
    // Every account out of budget: the reason starts with "budget:".
    if (why.every((w) => w.startsWith("budget:")))
      return `budget: ${HOSTED_WEBMAIL_ID} ${set}: no account has budget left today: ${why.join("; ")}`;
    return `${set}: ${why.join("; ")}`;
  }

  async health(): Promise<ProviderHealth> {
    if (
      !this.headless() &&
      !this.env.DISPLAY &&
      !this.env.WAYLAND_DISPLAY &&
      process.platform === "linux"
    )
      return {
        state: "unavailable",
        reason: `the webmails are captured in headed Chromium (the configuration least likely to trip bot heuristics), which needs a display: neither DISPLAY nor WAYLAND_DISPLAY is set (${HEADLESS_ENV}=1 runs headless instead)`,
      };
    try {
      loadWorkspaceSender(this.host);
    } catch (err) {
      return {
        state: "unavailable",
        reason: `the Workspace sender: ${oneLine(err)}; ${REMEDY}`,
      };
    }
    const problems: string[] = [];
    for (const [set, accounts] of this.pools()) {
      const p = this.setProblem(set, accounts);
      if (p !== null) problems.push(p);
    }
    if (problems.length === this.adapters.length)
      return {
        state: "unavailable",
        reason: `no QA account is ready: ${problems.join("; ")}; ${REMEDY}`,
      };
    if (problems.length > 0)
      return {
        state: "degraded",
        reason: `${problems.join("; ")}; their requests fail; ${REMEDY}`,
      };
    return { state: "ok" };
  }

  async prepare(ctx: SessionCtx): Promise<void> {
    this.run = ctx.run;
    this.runDir = ctx.runDir;
    this.cold = ctx.cold;
    this.sender = loadWorkspaceSender(this.host);
    if (this.pw === null) {
      const driver = resolveDriver(this.env);
      if ("reason" in driver) throw new Error(driver.reason);
      this.pw = (await import(
        pathToFileURL(join(driver.dir, "index.mjs")).href
      )) as Playwright;
    }
  }

  emulation(_req: CaptureRequest): Emulation {
    return { transformVersion: "", detail: null };
  }

  async *capture(
    batch: CaptureRequest[],
    messages: Map<Sha256, StoryMessage>,
    _ctx: SessionCtx,
  ): AsyncIterable<CaptureResult> {
    const ready: CaptureResult[] = [];
    let wake: (() => void) | null = null;
    const emit: Emit = (r) => {
      ready.push(r);
      wake?.();
    };
    const fail = (req: CaptureRequest, reason: string): void =>
      emit({ request: req, status: "failed", reason, provenance: {} });

    // Per adapter, its stories in order, each with all its requests.
    const perAdapter = new Map<WebmailAdapter, StoryJob[]>();
    for (const req of batch) {
      const a = this.adapter(req.clientId);
      if (a === null) {
        fail(req, `unknown hosted-webmail client '${req.clientId}'`);
        continue;
      }
      const jobs = perAdapter.get(a.adapter) ?? [];
      perAdapter.set(a.adapter, jobs);
      let job = jobs.find((j) => j.mimeSha256 === req.mimeSha256);
      if (job === undefined) {
        job = { story: req.story, mimeSha256: req.mimeSha256, requests: [] };
        jobs.push(job);
      }
      job.requests.push(req);
    }

    let running = 0;
    const work: Promise<void>[] = [];
    for (const [adapter, jobs] of perAdapter) {
      running++;
      work.push(
        this.runAdapter(adapter, jobs, messages, emit)
          .catch((err: unknown) => {
            for (const j of jobs)
              for (const r of j.requests)
                fail(r, `${adapter.label}: ${oneLine(err)}`);
            jobs.length = 0;
          })
          .finally(() => {
            running--;
            wake?.();
          }),
      );
    }
    for (;;) {
      const next = ready.shift();
      if (next !== undefined) {
        yield next;
        continue;
      }
      if (running === 0) break;
      await new Promise<void>((r) => {
        wake = r;
      });
      wake = null;
    }
    await Promise.all(work);
  }

  // One worker per ready account of the adapter's set, taking stories
  // from one queue; what no worker could take fails with why.
  private async runAdapter(
    adapter: WebmailAdapter,
    jobs: StoryJob[],
    messages: Map<Sha256, StoryMessage>,
    emit: Emit,
  ): Promise<void> {
    const failJob = (job: StoryJob, reason: string): void => {
      for (const r of job.requests)
        emit({ request: r, status: "failed", reason, provenance: {} });
    };
    const limit = dailyBudget(this.env);
    const accounts = poolAccounts(this.host, adapter.set, limit, this.now());
    const problem = this.setProblem(adapter.set, accounts);
    if (problem !== null) {
      const reason = `${problem}; ${REMEDY}`;
      for (const j of jobs.splice(0)) failJob(j, reason);
      return;
    }
    const stopped: string[] = [];
    const queue = [...jobs];
    const runWorker = async (account: PoolAccount): Promise<void> => {
      const w: Worker = {
        account,
        context: null,
        page: null,
        mode: null,
        dpr: 1,
        sessionChecked: false,
      };
      this.workers.push(w);
      try {
        while (queue.length > 0) {
          const drift = this.down.get(adapter.id);
          if (drift !== undefined) {
            for (const j of queue.splice(0)) failJob(j, drift);
            return;
          }
          const stop = await this.serveOne(adapter, w, queue, messages, emit);
          if (stop !== null) {
            stopped.push(stop);
            return;
          }
        }
      } finally {
        await this.closeContext(w);
      }
    };
    await Promise.all(
      accounts.filter((a) => readiness(a).ready).map((a) => runWorker(a)),
    );
    if (queue.length > 0) {
      const reason =
        stopped.length > 0 && stopped.every((r) => r.startsWith("budget:"))
          ? `budget: ${HOSTED_WEBMAIL_ID} ${adapter.set}: no account has budget left today: ${stopped.join("; ")}`
          : `no ${adapter.set} account could take this story: ${stopped.join("; ")}`;
      for (const j of queue.splice(0)) failJob(j, reason);
    }
  }

  // Leases the worker's account and serves the next story with it.
  // Returns why the worker stops (null: it may take another story).
  private async serveOne(
    adapter: WebmailAdapter,
    w: Worker,
    queue: StoryJob[],
    messages: Map<Sha256, StoryMessage>,
    emit: Emit,
  ): Promise<string | null> {
    const a = w.account;
    const tLease = performance.now();
    const lease = await this.acquire(a);
    if (lease === null)
      return `lease: ${a.set}/${a.name} stayed leased by another run for ${Math.round(this.t.leaseWaitMs / 1000)} s`;
    this.leases.add(lease);
    const leaseMs = performance.now() - tLease;
    try {
      const limit = dailyBudget(this.env);
      const budget = budgetState(a.profile, limit, this.now());
      if (budget.exhausted) {
        const r = readiness({ ...a, budget });
        return r.ready ? "budget" : r.why;
      }
      if (!w.sessionChecked) {
        const page = await this.openContext(w, adapter, "desktop", 1);
        const s = await checkSignedIn(
          page.context(),
          adapter.signin,
          this.t.signinCheckMs,
        );
        if (!s.signedIn) {
          // An inbox that did not load at all (no network, the webmail
          // down) says nothing about the session: the account is not
          // marked, and the worker stops for this run.
          if (s.host === "")
            return `${a.set}/${a.name}: ${s.reason} (the session was not judged; the account stays in selection)`;
          this.sessionLost(a, s.reason);
          return this.lostReason(a, s.reason);
        }
        w.sessionChecked = true;
      }
      const job = queue.shift();
      if (job === undefined) return null;
      await this.serveStory(adapter, w, job, messages, emit, {
        leaseMs,
        tookOver: lease.tookOver,
      });
      if (this.cold) await this.closeContext(w);
      return null;
    } catch (err) {
      if (err instanceof SessionLostError) return err.message;
      throw err;
    } finally {
      releaseLease(lease);
      this.leases.delete(lease);
    }
  }

  private async acquire(a: PoolAccount): Promise<Lease | null> {
    const deadline = Date.now() + this.t.leaseWaitMs;
    for (;;) {
      const lease = tryLease(a.profile, this.run);
      if (lease !== null) return lease;
      if (Date.now() >= deadline) return null;
      await new Promise((r) => setTimeout(r, this.t.leasePollMs));
    }
  }

  private lostReason(a: PoolAccount, reason: string): string {
    return `session lost: ${a.set}/${a.name} is not signed in any more (${reason}); the harness never signs in: a person runs \`${signinCommand(a.set, a.name)}\``;
  }

  private sessionLost(a: PoolAccount, reason: string): void {
    markNeedsLogin(a.profile, reason);
    this.log(`email-shots: hosted-webmail: ${this.lostReason(a, reason)}`);
  }

  private async openContext(
    w: Worker,
    adapter: WebmailAdapter,
    mode: "desktop" | "mobile",
    dpr: number,
  ): Promise<Page> {
    if (
      w.context !== null &&
      w.page !== null &&
      w.mode === mode &&
      w.dpr === dpr
    )
      return w.page;
    await this.closeContext(w);
    const ui = mode === "mobile" ? adapter.mobile : adapter.desktop;
    if (ui === null) throw new StepError(`${adapter.label} has no ${mode} UI`);
    const base = webmailLaunchOptions(this.env, this.headless());
    const mobile = mode === "mobile";
    const context = await this.pw!.chromium.launchPersistentContext(
      w.account.profile.userDataDir,
      {
        ...base,
        viewport: {
          width: 800 + ui.windowAllowance,
          height: WINDOW_HEIGHT[mobile ? "mobile" : "desktop"],
        },
        deviceScaleFactor: dpr,
        ...(mobile
          ? { isMobile: true, hasTouch: true, userAgent: IPHONE_USER_AGENT }
          : {}),
        locale: "en-US",
        timezoneId: "UTC",
      },
    );
    // Every action fails at the step timeout, not Playwright's 30 s.
    context.setDefaultTimeout(this.t.stepTimeoutMs);
    w.context = context;
    w.page = context.pages()[0] ?? (await context.newPage());
    w.mode = mode;
    w.dpr = dpr;
    return w.page;
  }

  private async closeContext(w: Worker): Promise<void> {
    const c = w.context;
    w.context = null;
    w.page = null;
    w.mode = null;
    if (c !== null) await c.close().catch(() => {});
  }

  // The page must be on one of the mail hosts; otherwise the session
  // is gone (a sign-in page, a consent wall).
  private assertOnMailHost(
    adapter: WebmailAdapter,
    page: Page,
    a: PoolAccount,
  ): void {
    let host = "";
    try {
      host = new URL(page.url()).host;
    } catch {
      // about:blank and the like: not a mail host
    }
    if (!adapter.signin.mailHosts.includes(host)) {
      const reason = `the page went to ${host === "" ? page.url() : host}, not ${adapter.signin.mailHosts.join(" or ")}`;
      this.sessionLost(a, reason);
      throw new SessionLostError(this.lostReason(a, reason));
    }
  }

  // Waits for `loc` and requires exactly one visible match. A miss on a
  // mail host is UI drift; off the mail hosts it is a lost session.
  private async exactlyOne(
    scope: Page | Locator,
    page: Page,
    adapter: WebmailAdapter,
    a: PoolAccount,
    name: string,
    loc: WebmailLocator,
    state: "visible" | "attached" = "visible",
  ): Promise<Locator> {
    const css = state === "visible" ? `${loc.css} >> visible=true` : loc.css;
    const l = scope.locator(css);
    try {
      await l.first().waitFor({ state, timeout: this.t.stepTimeoutMs });
    } catch {
      this.assertOnMailHost(adapter, page, a);
      throw this.drift(
        adapter,
        name,
        loc,
        `matched no ${state} element within ${this.t.stepTimeoutMs / 1000} s`,
      );
    }
    const n = await l.count();
    if (n !== 1)
      throw this.drift(
        adapter,
        name,
        loc,
        `matched ${n} elements, expected exactly one`,
      );
    return l;
  }

  private drift(
    adapter: WebmailAdapter,
    name: string,
    loc: WebmailLocator,
    what: string,
  ): DriftError {
    const msg = `UI drift: ${adapter.label} adapter locator '${name}' (${loc.css}, ${loc.status}) ${what}; the adapter is down for the rest of this run (fix the locator in webmail_adapters.ts)`;
    if (!this.down.has(adapter.id)) {
      this.down.set(adapter.id, msg);
      this.log(`email-shots: hosted-webmail: ${msg}`);
    }
    return new DriftError(msg);
  }

  // The rows of the current list that carry the token.
  private async tokenRows(
    page: Page,
    ui: AdapterUi,
    token: string,
  ): Promise<Locator> {
    const rows = page
      .locator(`${ui.row.css} >> visible=true`)
      .filter({ hasText: token });
    await rows
      .first()
      .waitFor({ state: "visible", timeout: this.t.listSettleMs })
      .catch(() => {});
    return rows;
  }

  // Looks for the message in `folders`, once each (and their tabs).
  private async lookIn(
    adapter: WebmailAdapter,
    ui: AdapterUi,
    page: Page,
    a: PoolAccount,
    d: { messageId: string; subjectToken: string },
    folders: FolderName[],
  ): Promise<{ folder: FolderName; rows: Locator; count: number } | null> {
    for (const name of folders) {
      const f = ui.folders[name];
      await page.goto(
        folderUrl(f, { messageId: d.messageId, token: d.subjectToken }),
        {
          timeout: this.t.stepTimeoutMs,
        },
      );
      this.assertOnMailHost(adapter, page, a);
      for (const tab of [null, ...f.tabs]) {
        if (tab !== null) {
          const t = page.locator(`${tab.css} >> visible=true`);
          if ((await t.count()) !== 1) continue;
          await t.click();
        }
        const rows = await this.tokenRows(page, ui, d.subjectToken);
        const count = await rows.count();
        if (count > 0) return { folder: name, rows, count };
      }
    }
    return null;
  }

  private async findArrival(
    adapter: WebmailAdapter,
    ui: AdapterUi,
    page: Page,
    a: PoolAccount,
    d: WorkspaceDelivery,
  ): Promise<{ folder: FolderName; row: Locator; ms: number; polls: number }> {
    const t0 = Date.now();
    const deadline = t0 + this.t.arrivalTimeoutMs;
    let polls = 0;
    for (;;) {
      polls++;
      const found = await this.lookIn(adapter, ui, page, a, d, [
        "inbox",
        "spam",
      ]);
      if (found !== null) {
        if (found.count !== 1)
          throw new StepError(
            `${adapter.label}: ${found.count} messages in ${ui.folders[found.folder].label} carry the run token ${d.subjectToken}, expected one`,
          );
        return {
          folder: found.folder,
          row: found.rows.first(),
          ms: Date.now() - t0,
          polls,
        };
      }
      if (Date.now() >= deadline) {
        // An Inbox list in which the row locator matches nothing at all
        // may be a UI the adapter no longer recognises.
        const any = await page
          .locator(`${ui.row.css} >> visible=true`)
          .count()
          .catch(() => 0);
        throw new DeliveryTimeout(
          `delivery failure: ${d.messageId} (sent through the Gmail API as ${d.api.id}) was not found in ${adapter.label}'s ${ui.folders.inbox.label} or ${ui.folders.spam.label} within ${Math.round(this.t.arrivalTimeoutMs / 1000)} s (${polls} looks)${any === 0 ? `; the row locator (${ui.row.css}, ${ui.row.status}) matched no row at all in the last list looked at: if that folder is not empty, the adapter no longer matches the UI` : ""}`,
        );
      }
      await new Promise((r) => setTimeout(r, this.t.pollMs));
    }
  }

  // Delivers one story to the worker's account and captures every
  // request of it there, then removes the message.
  private async serveStory(
    adapter: WebmailAdapter,
    w: Worker,
    job: StoryJob,
    messages: Map<Sha256, StoryMessage>,
    emit: Emit,
    lease: { leaseMs: number; tookOver: { pid: number; run: string } | null },
  ): Promise<void> {
    const a = w.account;
    const message = messages.get(job.mimeSha256);
    const answered = new Set<CaptureRequest>();
    const emitted = emit;
    emit = (r) => {
      answered.add(r.request);
      emitted(r);
    };
    const failAll = (
      reason: string,
      prov: Record<string, unknown> = {},
    ): void => {
      for (const r of job.requests)
        if (!answered.has(r))
          emit({ request: r, status: "failed", reason, provenance: prov });
    };
    if (message === undefined) {
      failAll(`no message for ${job.story} (${job.mimeSha256})`);
      return;
    }
    // List rows first (before the message is opened and marked read),
    // then the desktop bodies, then the mobile ones.
    const order = (r: CaptureRequest): number => {
      const c = this.adapter(r.clientId)!.client;
      return c.kind === "list" ? 0 : c.ui === "desktop" ? 1 : 2;
    };
    const requests = [...job.requests].sort((x, y) => order(x) - order(y));

    const shared: Record<string, unknown> = {
      lease: {
        wait_ms: Math.round(lease.leaseMs),
        took_over_stale:
          lease.tookOver === null
            ? null
            : { pid: lease.tookOver.pid, run: lease.tookOver.run },
      },
    };
    const timing: Record<string, number> = { lease: lease.leaseMs };

    // Deliver: counted first.
    const limit = dailyBudget(this.env);
    const budget = countDelivery(a.profile, limit, this.now());
    shared.budget = { day: budget.day, count: budget.count, limit };
    let delivery: WorkspaceDelivery;
    const tDeliver = performance.now();
    try {
      const receiver = loadHostedAccount(adapter.set, this.host, {
        account: a.name,
        needsAppPassword: false,
      });
      delivery = await deliverWorkspace(message.mime, this.sender!, receiver, {
        ...this.workspace,
        run: this.run,
      });
    } catch (err) {
      failAll(`delivery failed: ${oneLine(err)}`, shared);
      return;
    }
    timing.deliver = performance.now() - tDeliver;
    shared.delivery = {
      route: delivery.route,
      sender: delivery.sender.source,
      message_id: delivery.messageId,
      subject_token: delivery.subjectToken,
      submitted_sha256: delivery.submittedSha256,
      bytes: delivery.bytes,
      api_id: delivery.api.id,
    };
    shared.asset_rewrite = delivery.assetRewrite;
    if (delivery.assetRewrite === null)
      shared.images = {
        note: "no public asset base yet: the copy keeps https://x.test/, so the story's images could not load in the webmail",
      };

    let handle: Handle | null = null;
    let page: Page | null = null;
    try {
      const first = this.adapter(requests[0]!.clientId)!.client;
      page = await this.openContext(
        w,
        adapter,
        first.ui,
        requests[0]!.viewport.dpr,
      );
      const ui0 = first.ui === "mobile" ? adapter.mobile! : adapter.desktop;
      const tArr = performance.now();
      const found = await this.findArrival(adapter, ui0, page, a, delivery);
      timing.arrival = performance.now() - tArr;
      handle = {
        delivery,
        folder: found.folder,
        arrivalMs: found.ms,
        polls: found.polls,
      };
      shared.arrival = {
        folder: found.folder,
        folder_label: ui0.folders[found.folder].label,
        latency_ms: found.ms,
        polls: found.polls,
      };
      let row: Locator | null = found.row;
      let opened: { ui: AdapterUi; mode: string } | null = null;

      for (const req of requests) {
        const { client } = this.adapter(req.clientId)!;
        const ui = client.ui === "mobile" ? adapter.mobile! : adapter.desktop;
        const t0 = performance.now();
        const prov: Record<string, unknown> = {
          ...shared,
          client: {
            account: a.name,
            adapter: adapter.id,
            ui: client.ui,
            device: ui.device,
            locators: adapter.status,
          },
          network: { policy: "live-webmail", blocked: [] },
        };
        const rtiming: Record<string, number> = { ...timing };
        prov.timing_ms = rtiming;
        try {
          if (this.down.has(adapter.id))
            throw new DriftError(this.down.get(adapter.id)!);
          // A move between desktop and mobile reopens the profile, and
          // the message is looked up again where it arrived.
          if (w.mode !== client.ui || w.dpr !== req.viewport.dpr) {
            page = await this.openContext(
              w,
              adapter,
              client.ui,
              req.viewport.dpr,
            );
            const again = await this.lookIn(adapter, ui, page, a, delivery, [
              handle.folder,
            ]);
            if (again === null || again.count !== 1)
              throw new StepError(
                `${adapter.label} (${client.ui}): the delivered message is not in ${ui.folders[handle.folder].label} any more`,
              );
            row = again.rows.first();
            opened = null;
          }
          await page.setViewportSize({
            width: req.viewport.width + ui.windowAllowance,
            height: WINDOW_HEIGHT[client.ui],
          });
          if (client.kind === "list") {
            if (row === null)
              throw new StepError(
                `${adapter.label}: the list row is captured before the message is opened, and it already was`,
              );
            const r = await this.captureRow(adapter, ui, page, a, row);
            rtiming.capture = performance.now() - t0;
            rtiming.total =
              performance.now() -
              t0 +
              (timing.deliver ?? 0) +
              (timing.arrival ?? 0);
            emit({
              request: req,
              status: "done",
              png: r.png,
              provenance: { ...prov, list_row: r.texts },
            });
            continue;
          }
          if (opened === null) {
            const tOpen = performance.now();
            await this.open(adapter, ui, page, a, row!, delivery.subjectToken);
            rtiming.open = performance.now() - tOpen;
            opened = { ui, mode: client.ui };
            row = null;
          }
          const shot = await this.captureBody(
            adapter,
            ui,
            page,
            a,
            req,
            client,
            rtiming,
          );
          Object.assign(prov, shot.provenance);
          rtiming.total =
            performance.now() -
            t0 +
            (timing.deliver ?? 0) +
            (timing.arrival ?? 0);
          emit({
            request: req,
            status: "done",
            png: shot.png,
            provenance: prov,
          });
        } catch (err) {
          rtiming.total = performance.now() - t0;
          rtiming.capture ??= 0;
          emit({
            request: req,
            status: "failed",
            reason: oneLine(err),
            provenance: prov,
          });
          if (err instanceof SessionLostError) throw err;
        }
      }
    } catch (err) {
      if (handle === null) {
        // Nothing was captured: every request fails with the reason.
        failAll(oneLine(err), shared);
        this.cleanupRecord({
          account: a.name,
          set: a.set,
          message_id: delivery.messageId,
          folder: null,
          state: err instanceof DeliveryTimeout ? "not-found" : "failed",
          reason: oneLine(err),
        });
        if (err instanceof SessionLostError) throw err;
        return;
      }
      if (err instanceof SessionLostError) {
        // The account is out: the story's other requests fail with it.
        failAll(err.message, shared);
        throw err;
      }
    }
    if (page !== null && handle !== null)
      await this.remove(adapter, w, page, a, handle);
  }

  private async captureRow(
    adapter: WebmailAdapter,
    ui: AdapterUi,
    page: Page,
    a: PoolAccount,
    row: Locator,
  ): Promise<{ png: Uint8Array; texts: Record<string, string> }> {
    await row.scrollIntoViewIfNeeded();
    const texts: Record<string, string> = {};
    for (const [name, loc] of Object.entries(ui.rowParts)) {
      const part = row.locator(loc.css).first();
      if ((await row.locator(loc.css).count()) === 0)
        throw this.drift(
          adapter,
          `row.${name}`,
          loc,
          "matched nothing inside the message's row",
        );
      texts[name] = ((await part.textContent()) ?? "").trim();
    }
    this.assertOnMailHost(adapter, page, a);
    const png = await row.screenshot({ animations: "disabled", caret: "hide" });
    return { png, texts };
  }

  private async open(
    adapter: WebmailAdapter,
    ui: AdapterUi,
    page: Page,
    a: PoolAccount,
    row: Locator,
    token: string,
    // The removal checks only who the message is: its body need not be
    // recognised to delete it.
    needBody = true,
  ): Promise<void> {
    await row.click();
    if (needBody)
      await this.exactlyOne(
        page,
        page,
        adapter,
        a,
        "opened.body",
        ui.opened.body,
      );
    const subject = await this.exactlyOne(
      page,
      page,
      adapter,
      a,
      "opened.subject",
      ui.opened.subject,
    );
    const shown = ((await subject.textContent()) ?? "").trim();
    if (!shown.includes(token))
      throw new StepError(
        `${adapter.label}: the opened message is not the delivered one (its subject '${shown}' lacks the run token ${token})`,
      );
  }

  // Whether the message open on the page is the delivered one.
  private async openedCarries(
    page: Page,
    ui: AdapterUi,
    token: string,
  ): Promise<boolean> {
    const subject = page.locator(`${ui.opened.subject.css} >> visible=true`);
    if ((await subject.count()) !== 1) return false;
    return ((await subject.textContent()) ?? "").includes(token);
  }

  private async captureBody(
    adapter: WebmailAdapter,
    ui: AdapterUi,
    page: Page,
    a: PoolAccount,
    req: CaptureRequest,
    client: AdapterClient,
    timing: Record<string, number>,
  ): Promise<{ png: Uint8Array; provenance: Record<string, unknown> }> {
    const provenance: Record<string, unknown> = {};
    // The scheme: the app follows the browser's colour scheme; a
    // webmail with a body toggle (Outlook.com) runs its dark theme for
    // both states and the toggle decides the body.
    const toggle = ui.darkToggle;
    await page.emulateMedia({
      colorScheme: toggle !== null || req.scheme === "dark" ? "dark" : "light",
    });
    const body = await this.exactlyOne(
      page,
      page,
      adapter,
      a,
      "opened.body",
      ui.opened.body,
    );
    if (ui.opened.bodyReady !== null)
      await this.exactlyOne(
        body,
        page,
        adapter,
        a,
        "opened.bodyReady",
        ui.opened.bodyReady,
        "attached",
      );
    if (toggle !== null && client.schemes.includes("dark")) {
      const button = await this.exactlyOne(
        page,
        page,
        adapter,
        a,
        "darkToggle",
        toggle,
      );
      const wantLight = req.scheme !== "dark";
      const pressed = async (): Promise<boolean> =>
        (await button.getAttribute("aria-pressed")) === "true";
      if ((await pressed()) !== wantLight) await button.click();
      if ((await pressed()) !== wantLight)
        throw new StepError(
          `${adapter.label}: the background toggle did not switch the body to ${wantLight ? "light" : "dark"}`,
        );
      provenance.scheme_applied = {
        scheme: req.scheme,
        evidence: `background toggle aria-pressed=${wantLight}`,
        recoloured_elements: await body
          .locator("[data-ogsc], [data-ogsb]")
          .count(),
      };
    } else
      provenance.scheme_applied = {
        scheme: req.scheme,
        evidence: "the webmail does not recolour the body",
      };

    // Settle: fonts, the body's images (bounded, never a failure: with
    // no public asset base they cannot load), a stable box.
    const tSettle = performance.now();
    await page.evaluate("document.fonts.ready.then(() => true)");
    const tImg = Date.now();
    let imagesComplete = false;
    for (;;) {
      imagesComplete = (await body.evaluate((el: BodyEl) =>
        Array.from(el.querySelectorAll("img")).every((i) => i.complete),
      )) as boolean;
      if (imagesComplete || Date.now() - tImg >= this.t.imageTimeoutMs) break;
      await new Promise((r) => setTimeout(r, 100));
    }
    let box = await body.boundingBox();
    for (let i = 0; i < 20; i++) {
      await new Promise((r) => setTimeout(r, this.t.stableMs));
      const next = await body.boundingBox();
      if (
        box !== null &&
        next !== null &&
        next.width === box.width &&
        next.height === box.height &&
        next.x === box.x &&
        next.y === box.y
      )
        break;
      box = next;
    }
    timing.settle = performance.now() - tSettle;
    provenance.images_complete = imagesComplete;

    // UI fingerprint of the reading pane, the body left out.
    const root = await this.exactlyOne(
      page,
      page,
      adapter,
      a,
      "fingerprintRoot",
      ui.fingerprintRoot,
      "attached",
    );
    const structure = (await root.evaluate((el: El, skip: string) => {
      const skipped = new Set(Array.from(el.querySelectorAll(skip)));
      const out: string[] = [];
      const walk = (e: El, depth: number): void => {
        if (skipped.has(e)) {
          out.push(`${depth}:BODY`);
          return;
        }
        const classes = Array.from(e.classList).sort().join(".");
        out.push(
          `${depth}:${e.tagName.toLowerCase()}[${e.getAttribute("role") ?? ""}].${classes}`,
        );
        for (const c of Array.from(e.children)) walk(c, depth + 1);
      };
      walk(el, 0);
      return out.join("\n");
    }, ui.opened.body.css)) as string;
    const fp = createHash("sha256")
      .update(structure)
      .digest("hex")
      .slice(0, 12);
    const previous = readFingerprint(this.host, adapter.set, client.ui);
    if (previous !== fp)
      writeFingerprint(this.host, adapter.set, client.ui, fp);
    provenance.ui_fingerprint = {
      value: fp,
      previous,
      changed: previous !== null && previous !== fp,
    };

    // The crop: lift the body's clipping ancestors, grow the window to
    // hold it, screenshot it with the chrome inside it masked.
    const tCap = performance.now();
    await body.scrollIntoViewIfNeeded();
    const relaxed = (await body.evaluate(relaxScroll)) as number;
    try {
      box = await body.boundingBox();
      if (box === null)
        throw new StepError(`${adapter.label}: the message body has no box`);
      const height = WINDOW_HEIGHT[client.ui];
      const need = Math.ceil(box.y + box.height + 16);
      const windowWidth = req.viewport.width + ui.windowAllowance;
      if (need > height) {
        await page.setViewportSize({ width: windowWidth, height: need });
        box = (await body.boundingBox()) ?? box;
      }
      const masks = ui.opened.masks.map((m) => body.locator(m.css));
      const png = await body.screenshot({
        animations: "disabled",
        caret: "hide",
        mask: masks,
      });
      timing.capture = performance.now() - tCap;
      provenance.crop = {
        selector: ui.opened.body.css,
        x: box.x,
        y: box.y,
        width: box.width,
        height: box.height,
        window: { width: windowWidth, height: Math.max(height, need) },
        relaxed_ancestors: relaxed,
        masks: ui.opened.masks.map((m) => m.css),
      };
      // [calibrate] the body is meant to get the requested width.
      provenance.width_check = {
        requested: req.viewport.width,
        measured: Math.round(box.width),
        delta: Math.round(box.width) - req.viewport.width,
      };
      return { png, provenance };
    } finally {
      await page.evaluate(restoreScroll).catch(() => {});
    }
  }

  // Deletes the message in the UI (then from Trash), looks for it
  // again everywhere, and records the outcome.
  private async remove(
    adapter: WebmailAdapter,
    w: Worker,
    page: Page,
    a: PoolAccount,
    handle: Handle,
  ): Promise<void> {
    const d = handle.delivery;
    const ui = w.mode === "mobile" ? adapter.mobile! : adapter.desktop;
    const record = {
      account: a.name,
      set: a.set,
      message_id: d.messageId,
      folder: handle.folder,
    };
    try {
      // Delete only the delivered message: the open one when its subject
      // carries the run token, otherwise its row is found where it
      // arrived and opened with the identity check (a message that
      // cannot be shown to be the delivered one is never deleted).
      let del = page.locator(`${ui.remove.del.css} >> visible=true`);
      if (
        (await del.count()) !== 1 ||
        !(await this.openedCarries(page, ui, d.subjectToken))
      ) {
        const where = await this.lookIn(adapter, ui, page, a, d, [
          handle.folder,
        ]);
        if (where === null)
          throw new StepError(
            `the message is no longer in ${ui.folders[handle.folder].label}`,
          );
        await this.open(
          adapter,
          ui,
          page,
          a,
          where.rows.first(),
          d.subjectToken,
          false,
        );
        del = await this.exactlyOne(
          page,
          page,
          adapter,
          a,
          "remove.delete",
          ui.remove.del,
        );
      }
      await del.click();
      await this.closed(page, ui, "the delete");
      // From Trash / Deleted Items, for good.
      const deadline = Date.now() + this.t.cleanupFindMs;
      let inTrash: { rows: Locator; count: number } | null = null;
      while (inTrash === null && Date.now() < deadline) {
        inTrash = await this.lookIn(adapter, ui, page, a, d, ["trash"]);
        if (inTrash === null)
          await new Promise((r) => setTimeout(r, this.t.pollMs));
      }
      if (inTrash === null)
        throw new StepError(
          `the deleted message did not show up in ${ui.folders.trash.label} within ${Math.round(this.t.cleanupFindMs / 1000)} s`,
        );
      await this.open(
        adapter,
        ui,
        page,
        a,
        inTrash.rows.first(),
        d.subjectToken,
        false,
      );
      const forever = await this.exactlyOne(
        page,
        page,
        adapter,
        a,
        "remove.deleteForever",
        ui.remove.deleteForever,
      );
      await forever.click();
      if (ui.remove.confirm !== null)
        await (
          await this.exactlyOne(
            page,
            page,
            adapter,
            a,
            "remove.confirm",
            ui.remove.confirm,
          )
        ).click();
      await this.closed(page, ui, "the permanent delete");
      // Gone from every folder?
      const left = await this.lookIn(adapter, ui, page, a, d, [
        "inbox",
        "spam",
        "trash",
      ]);
      if (left !== null)
        throw new StepError(
          `still in ${ui.folders[left.folder].label} after the delete`,
        );
      this.cleanupRecord({ ...record, state: "removed", reason: null });
    } catch (err) {
      const reason = oneLine(err);
      this.cleanupRecord({ ...record, state: "failed", reason });
      this.log(
        `email-shots: hosted-webmail: cleanup FAILED for ${d.messageId} in ${a.set}/${a.name}: ${reason}`,
      );
      if (err instanceof SessionLostError) throw err;
    }
  }

  // A delete has taken effect once the opened message is gone from the
  // page (the webmail went back to a list).
  private async closed(page: Page, ui: AdapterUi, what: string): Promise<void> {
    try {
      await page
        .locator(ui.opened.body.css)
        .first()
        .waitFor({ state: "hidden", timeout: this.t.stepTimeoutMs });
    } catch {
      throw new StepError(
        `${what} did not close the message within ${this.t.stepTimeoutMs / 1000} s`,
      );
    }
  }

  private cleanupRecord(r: Record<string, unknown>): void {
    if (this.runDir === "") return;
    appendFileSync(
      join(this.runDir, "hosted-webmail-cleanup.jsonl"),
      `${JSON.stringify({ at: new Date(this.now()).toISOString(), ...r })}\n`,
    );
  }

  async dispose(): Promise<void> {
    for (const w of this.workers.splice(0)) await this.closeContext(w);
    for (const l of this.leases) releaseLease(l);
    this.leases.clear();
  }
}
