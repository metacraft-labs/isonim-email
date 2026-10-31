// tools/capture/providers/hosted_webmail.ts — the hosted-webmail
// capture provider (backend b): the real Gmail, Yahoo Mail and
// Outlook.com, in profiles the sign-in recipe signed in, captured after
// real delivery, in the webmail browser driven the way a person drives
// it (webmail_desktop.ts): started normally by the sign-in's launcher
// (no Playwright, no DevTools, no automation switch: the launcher
// refuses one), in a private GuiAssert session, the page read from its
// accessibility tree and OCR, input through OS-level clicks and the
// address bar, pixels from a region of the display.
//
// A capture, per story and QA account (the procedure is one
// implementation over the adapters' data, webmail_adapters.ts):
//  1. lease the account (webmail_accounts.ts: a lock file per account;
//     any free, signed-in account of the set under its daily budget),
//     start its browser on the inbox URL and check its session (the
//     mailbox read off the screen, the address bar on a mail host), and
//     count the delivery against its budget;
//  2. deliver the story by Workspace send (workspace_send.ts): the
//     Workspace sender sends the copy, with a fresh Message-ID and the
//     run token in the subject, to the account through the Gmail API;
//  3. find it in the webmail: Inbox, then Spam/Junk (each by its URLs
//     in turn, a row carrying the run token by the row locators in
//     turn), polled up to a bounded wait, recording where it arrived and
//     every look (what was navigated to, what rows were seen); not found
//     in time is a delivery failure, never a capture of nothing;
//  4. for an inbox-list client, capture its row before it is opened;
//     open it and check that a heading carries the run token;
//  5. per requested variant (light ones first): the browser in the
//     request's scheme (the profile's colour mode; a browser in the
//     other one is restarted and the message found and opened again),
//     the theme checked where the webmail recolours (Outlook.com: its
//     subject heading's luminance; in dark its background toggle, if
//     shown, unchecked), locate the body (its own name, or the story
//     region), wait until its pixels and bounds hold still, and capture
//     its region, masking the chrome inside it; each result is yielded
//     as it lands;
//  6. delete the message in the UI, check it left the folder, delete it
//     from Trash/Deleted Items (or take the delete as permanent where
//     the adapter allows), look again in every folder, and record the
//     outcome in <run>/hosted-webmail-cleanup.jsonl; release the lease.
//
// On any failure with the browser running, the last display frame and
// the accessibility-tree summary of the failing step are kept under
// <run>/hosted-webmail-failures/ (0600; unguarded, since a capture never
// holds a password) and named in the provenance (`failure`).
//
// Never a sign-in: a page that leaves the mail hosts is a lost session.
// The account is marked needs-login (out of selection until a sign-in
// passes), its requests fail with "session lost:" naming the sign-in
// recipe, and the same line goes to stderr at once. A locator that
// matches nothing or more than one element while the page is on the
// mail host is UI drift: the capture fails naming the locator, and the
// adapter is down for the rest of the run, so no crop is ever made from
// a UI the adapter does not recognise.
//
// Credentials only from the credentials directory: the Workspace
// sender's file and the QA account files (credentials.ts). No secret is
// printed, written or carried in a result: the provenance names the
// account by its file's name, never by its address. A capture never
// reads an account's password.
//
// The provider is opt-in: it joins a run only when named (--backends b,
// or one of its --clients), since every capture sends real mail and
// spends an account's budget.

import { appendFileSync, chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import {
  carriesToken,
  clickTarget,
  clipText,
  closest,
  type Flat,
  findShowing,
  insideRect,
  isWithin,
  locateStoryRegion,
  locationHost,
  matches,
  meanLuminance,
  paintMasks,
  rowText,
  sameLocation,
  sameRect,
  storyTexts,
  structureFingerprint,
  tokenNodes,
  tokenRows,
  treeSummary,
} from "./a11y_tree.ts";
import { TIER2_MAX_DIFF_RATIO } from "../email-capture-ci.ts";
import { diffPng } from "../perceptual.ts";
import { credentialRequirement, WORKSPACE_SENDER_SET } from "./credentials.ts";
import { GuiAssert, type Rect } from "./guiassert.ts";
import { loadHostedAccount } from "./hosted_delivery.ts";
import { findExecutable, type HostEnv } from "./requirements.ts";
import type {
  CaptureProvider,
  CaptureRequest,
  CaptureResult,
  ClientDescriptor,
  Emulation,
  ProviderHealth,
  Requirement,
  Scheme,
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
  CAPTURE_WINDOW_HEIGHT,
  describeLocator,
  DESKTOP_VIEWPORT,
  type FolderName,
  folderUrls,
  WEBMAIL_ADAPTERS,
  WEBMAIL_CHROME,
  type WebmailAdapter,
  type WebmailLocator,
} from "./webmail_adapters.ts";
import {
  DesktopUnavailable,
  type Snapshot,
  WebmailDesktop,
} from "./webmail_desktop.ts";
import { profilesRoot, webmailBrowser } from "./webmail_profiles.ts";
import {
  classifyScreen,
  normalize,
  PROVIDER_SIGNIN,
} from "./webmail_signin_steps.ts";
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
// 2: the captures moved from Playwright to the webmail browser driven
// through GuiAssert (a region of the display, the visual settle).
export const HOSTED_WEBMAIL_VERSION = "2";
// Bump by hand when crop, mask or wait logic changes.
export const HOSTED_WEBMAIL_ADAPTER_VERSION = 2;

// An operator's choice: every capture session serves an owner-only VNC
// socket, named on the log, so a capture can be watched (never driven:
// the provider types nothing a person would need to).
export const VNC_ENV = "ISONIM_EMAIL_WEBMAIL_VNC";

// What a person does to make backend b available: the one recipe that
// lists the steps, in order, and checks each.
export const REMEDY =
  "`just email-webmail-checklist` lists the steps a person runs, in order (unlock the credentials, the Workspace sender, a sign-in per set, a smoke send) and checks each";

/**
 * Phrases of the browser's own error page (normalized as the sign-in's
 * OCR text is): the inbox did not load at all, which says nothing about
 * the session.
 */
export const BROWSER_ERROR_PHRASES = [
  "this site cant be reached",
  "this page isnt working",
  "no internet",
  "err connection",
  "err name not resolved",
  "err internet disconnected",
  "err timed out",
];

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
  // How long a page off the mail hosts must stay to be a lost session.
  offHostMs: number;
  // The visual settle's bound (fonts and images: never a failure).
  imageTimeoutMs: number;
  // The visual settle: two equal frames this far apart.
  stableMs: number;
  // Finding the deleted message in Trash, and its leaving the folder.
  cleanupFindMs: number;
  // How long a dark capture waits for the optional background toggle.
  toggleWaitMs: number;
}

export const DEFAULT_TIMINGS: HostedWebmailTimings = {
  arrivalTimeoutMs: 60_000,
  pollMs: 2_000,
  listSettleMs: 4_000,
  stepTimeoutMs: 20_000,
  leaseWaitMs: 600_000,
  leasePollMs: 1_000,
  signinCheckMs: 45_000,
  offHostMs: 3_000,
  imageTimeoutMs: 5_000,
  stableMs: 300,
  cleanupFindMs: 15_000,
  toggleWaitMs: 2_000,
};

export interface HostedWebmailOptions {
  env?: Record<string, string | undefined>;
  // Test seams (hosted_webmail.test.ts): the adapters (rebased onto a
  // stand-in webmail), the Gmail API endpoints and their trust roots,
  // shorter waits, the window's height, the clock, where notices go,
  // and what sees each capture browser once it runs.
  adapters?: WebmailAdapter[];
  workspace?: WorkspaceOptions;
  timings?: Partial<HostedWebmailTimings>;
  windowHeight?: number;
  now?: () => number;
  log?: (line: string) => void;
  onDesktop?: (d: WebmailDesktop, account: PoolAccount) => void;
}

// ---------------------------------------------------------------------------
// Failures
// ---------------------------------------------------------------------------

class StepError extends Error {}

// A locator that no longer matches the UI as the adapter describes it.
class DriftError extends Error {}

class SessionLostError extends Error {}

class DeliveryTimeout extends Error {}

// An error as one line.
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
  desk: WebmailDesktop | null;
  // The colour mode the running browser was started in.
  scheme: Scheme;
  sessionChecked: boolean;
  // The account's address, once read for a delivery: replaced in every
  // kept tree summary and search record.
  redact: string[];
}

/** One look of a search: what it navigated to, and what it saw. */
export interface Look {
  folder: FolderName;
  url: string;
  how: "typed" | "reload" | "typed-reload" | "tab";
  location: string | null;
  location_matched: boolean;
  rows: string[];
  row_locator: string | null;
  token_rows: number;
  token_nodes: string[];
}

/** A failure's kept evidence: the last frame and the tree summary. */
export interface FailureEvidence {
  step: string;
  frame: string | null;
  tree: string | null;
  location: string | null;
  frame_error?: string;
  tree_error?: string;
}

const LOOK_ROWS = 8;

// Where a failure's evidence is kept, under the run directory.
export const FAILURES_DIR = "hosted-webmail-failures";

type Emit = (r: CaptureResult) => void;

const DOCUMENT = { nativeRole: "document web" };

// A webmail's theme is dark when its subject heading's mean luminance
// (the page's background around the heading's text) is below this.
export const THEME_DARK_BELOW = 128;

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
  private readonly windowHeight: number;
  private readonly now: () => number;
  private readonly log: (line: string) => void;
  private readonly onDesktop:
    | ((d: WebmailDesktop, account: PoolAccount) => void)
    | undefined;
  private ga: GuiAssert | null = null;
  private sender: WorkspaceSender | null = null;
  private run = "";
  private runDir = "";
  private cold = false;
  private desks = 0;
  private failureCount = 0;
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
    this.windowHeight = opts.windowHeight ?? CAPTURE_WINDOW_HEIGHT;
    this.now = opts.now ?? Date.now;
    this.log = opts.log ?? ((l) => process.stderr.write(`${l}\n`));
    this.onDesktop = opts.onDesktop;
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

  // The last UI fingerprint seen for the adapter's UI and the browser
  // build: both decide the pixels. A capture that sees another
  // fingerprint records it and updates it, so the next run's key differs.
  private build(adapter: WebmailAdapter, ui: "desktop"): string {
    const browser = webmailBrowser(this.env);
    // "Google Chrome 147.0.7727.137" -> "google-chrome-147.0.7727.137"
    const name =
      "reason" in browser
        ? "unknown"
        : browser.label
            .toLowerCase()
            .replace(/[^a-z0-9.]+/g, "-")
            .replace(/^-|-$/g, "");
    const fp = readFingerprint(this.host, adapter.set, ui) ?? "none";
    return `ui-fp:${fp}+${name}`;
  }

  requirements(): Requirement[] {
    const sender = credentialRequirement(WORKSPACE_SENDER_SET);
    return [
      {
        kind: "host-os",
        os: ["linux"],
        why: "the webmail browser runs in a private GuiAssert session on an Xvfb display (linux-xvfb)",
      },
      {
        kind: "binary",
        name: "guiassert",
        why: "GuiAssert drives the webmail browser: its session, accessibility tree, OCR, screenshots and OS-level input (run under `nix develop`)",
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
    const browser = webmailBrowser(this.env);
    if ("reason" in browser)
      return { state: "unavailable", reason: browser.reason };
    if (findExecutable("guiassert", this.host) === null)
      return {
        state: "unavailable",
        reason:
          "no guiassert on PATH: the webmails are captured in the webmail browser driven through GuiAssert (run inside `nix develop`, which provides it)",
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
    if (this.ga === null) {
      const bin = findExecutable("guiassert", this.host);
      if (bin === null)
        throw new Error("no guiassert on PATH (run inside `nix develop`)");
      // The sign-in's state directory: sessions of both are recorded
      // in one place, under the profiles' root.
      const stateDir = join(profilesRoot(this.host), ".guiassert-state");
      mkdirSync(stateDir, { recursive: true, mode: 0o700 });
      this.ga = new GuiAssert({
        bin,
        stateDir,
        env: this.env,
        timeoutMs: 60_000,
      });
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
        desk: null,
        scheme: "light",
        sessionChecked: false,
        redact: [],
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
        await this.closeDesktop(w);
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
        let desk: WebmailDesktop;
        try {
          desk = await this.openDesktop(w, adapter);
        } catch (err) {
          if (err instanceof DesktopUnavailable)
            return `${a.set}/${a.name}: the capture browser cannot run: ${err.message}`;
          throw err;
        }
        const s = await this.checkSession(desk, adapter);
        if (!s.signedIn) {
          // An inbox that did not load at all (no network, the webmail
          // down) says nothing about the session: the account is not
          // marked, and the worker stops for this run.
          if (!s.judged)
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
      if (this.cold) {
        await this.closeDesktop(w);
        w.sessionChecked = false;
      }
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
      await sleep(this.t.leasePollMs);
    }
  }

  private lostReason(a: PoolAccount, reason: string): string {
    return `session lost: ${a.set}/${a.name} is not signed in any more (${reason}); a capture never signs in: sign it in again with \`${signinCommand(a.set, a.name)}\``;
  }

  private sessionLost(a: PoolAccount, reason: string): void {
    markNeedsLogin(a.profile, reason);
    this.log(`email-shots: hosted-webmail: ${this.lostReason(a, reason)}`);
  }

  // The worker's browser, started (with its session) on first use, in
  // `scheme` (the profile's colour mode); a browser running in the other
  // one is stopped first.
  private async openDesktop(
    w: Worker,
    adapter: WebmailAdapter,
    scheme: Scheme = "light",
  ): Promise<WebmailDesktop> {
    if (w.desk !== null && w.scheme === scheme) return w.desk;
    if (w.desk !== null) await this.closeDesktop(w);
    const browser = webmailBrowser(this.env);
    if ("reason" in browser) throw new DesktopUnavailable(browser.reason);
    const desk = await WebmailDesktop.open({
      ga: this.ga!,
      chrome: browser,
      userDataDir: w.account.profile.userDataDir,
      env: this.env,
      width: DESKTOP_VIEWPORT.width + adapter.desktop.windowAllowance,
      height: this.windowHeight,
      scheme,
      startUrl: adapter.signin.inboxUrl,
      name: `capture-${adapter.set}-${w.account.name}-${process.pid}-${++this.desks}`,
      vnc: this.env[VNC_ENV] === "1",
    });
    w.desk = desk;
    w.scheme = scheme;
    if (desk.session.vncSocket !== null)
      this.log(
        `email-shots: hosted-webmail: ${adapter.set}/${w.account.name}: watch over VNC: the session is served on ${desk.session.vncSocket} (only this user can connect; from another machine: ssh -L 5901:${desk.session.vncSocket} <user>@<host>, then a VNC viewer on localhost:5901)`,
      );
    this.onDesktop?.(desk, w.account);
    return desk;
  }

  private async closeDesktop(w: Worker): Promise<void> {
    const d = w.desk;
    w.desk = null;
    if (d !== null) await d.close().catch(() => undefined);
  }

  // The session check: the browser was started on the inbox URL; the
  // mailbox must show (OCR, the sign-in's mailbox phrases) while the
  // address bar is on a mail host. Off the mail hosts for offHostMs is
  // signed out; the browser's own error page is a load failure, which
  // judges nothing. Types, clicks and presses nothing.
  private async checkSession(
    desk: WebmailDesktop,
    adapter: WebmailAdapter,
  ): Promise<
    { signedIn: true } | { signedIn: false; judged: boolean; reason: string }
  > {
    const provider = PROVIDER_SIGNIN[adapter.set];
    const deadline = Date.now() + this.t.signinCheckMs;
    let offSince: number | null = null;
    let host: string | null = null;
    for (;;) {
      const snap = await desk.snapshot();
      host = snap.location === null ? null : locationHost(snap.location);
      const onMail = host !== null && adapter.signin.mailHosts.includes(host);
      const text = await desk.ocrText();
      const norm = normalize(text);
      if (BROWSER_ERROR_PHRASES.some((p) => norm.includes(` ${p} `)))
        return {
          signedIn: false,
          judged: false,
          reason: `the inbox did not load (the browser's error page on ${host ?? "an unknown address"})`,
        };
      if (
        onMail &&
        provider !== undefined &&
        classifyScreen(provider, text, undefined).kind === "done"
      )
        return { signedIn: true };
      const now = Date.now();
      if (host !== null && !onMail) {
        offSince ??= now;
        if (now - offSince >= this.t.offHostMs)
          return {
            signedIn: false,
            judged: true,
            reason: `the inbox was redirected to ${host}, not ${adapter.signin.mailHosts.join(" or ")}: the profile is not signed in`,
          };
      } else offSince = null;
      if (now >= deadline)
        return onMail
          ? {
              signedIn: false,
              judged: true,
              reason: `the inbox loaded on ${host} but the mailbox did not show within ${Math.round(this.t.signinCheckMs / 1000)} s`,
            }
          : {
              signedIn: false,
              judged: false,
              reason: `the inbox did not load within ${Math.round(this.t.signinCheckMs / 1000)} s (the address bar: ${host ?? "unread"})`,
            };
      await sleep(500);
    }
  }

  // The page must be on one of the mail hosts; otherwise the session
  // is gone (a sign-in page, a consent wall).
  private assertOnMailHost(
    adapter: WebmailAdapter,
    snap: Snapshot,
    a: PoolAccount,
  ): void {
    if (snap.location === null)
      throw new StepError(
        `${adapter.label}: the browser's address bar could not be read from its accessibility tree`,
      );
    const host = locationHost(snap.location);
    if (host === null || !adapter.signin.mailHosts.includes(host)) {
      const reason = `the page went to ${host ?? snap.location}, not ${adapter.signin.mailHosts.join(" or ")}`;
      this.sessionLost(a, reason);
      throw new SessionLostError(this.lostReason(a, reason));
    }
  }

  private drift(
    adapter: WebmailAdapter,
    name: string,
    loc: WebmailLocator | null,
    what: string,
  ): DriftError {
    const how =
      loc === null
        ? "the story region"
        : `${describeLocator(loc)}, ${loc.status}`;
    const msg = `UI drift: ${adapter.label} adapter locator '${name}' (${how}) ${what}; the adapter is down for the rest of this run (fix the locator in webmail_adapters.ts)`;
    if (!this.down.has(adapter.id)) {
      this.down.set(adapter.id, msg);
      this.log(`email-shots: hosted-webmail: ${msg}`);
    }
    return new DriftError(msg);
  }

  // Waits for `loc` and requires exactly one showing match. A miss on a
  // mail host is UI drift; off the mail hosts it is a lost session.
  private async exactlyOne(
    desk: WebmailDesktop,
    adapter: WebmailAdapter,
    a: PoolAccount,
    name: string,
    loc: WebmailLocator,
  ): Promise<{ snap: Snapshot; node: Flat }> {
    const r = await desk.waitFor(
      (s) => findShowing(s.flat, loc).length > 0,
      this.t.stepTimeoutMs,
    );
    if (!r.ok) {
      this.assertOnMailHost(adapter, r.snap, a);
      throw this.drift(
        adapter,
        name,
        loc,
        `matched no showing element within ${this.t.stepTimeoutMs / 1000} s`,
      );
    }
    const found = findShowing(r.snap.flat, loc);
    if (found.length !== 1)
      throw this.drift(
        adapter,
        name,
        loc,
        `matched ${found.length} elements, expected exactly one`,
      );
    return { snap: r.snap, node: found[0]! };
  }

  // The page: the browser's largest showing document (rows are never
  // matched in the browser's own address bar or popups, and a small
  // document of Chrome's own interface is not the page); the whole tree
  // when no document is read.
  private page(snap: Snapshot): Flat | null {
    let best: Flat | null = null;
    let area = -1;
    for (const f of findShowing(snap.flat, DOCUMENT)) {
      const b = f.node.bounds!;
      if (b[2] * b[3] > area) {
        area = b[2] * b[3];
        best = f;
      }
    }
    return best;
  }

  // The rows of the current list that carry the token, by the first row
  // locator that finds any (a11y_tree.ts `tokenRows`).
  private rowsOf(
    snap: Snapshot,
    ui: AdapterUi,
    token: string,
  ): { rows: Flat[]; locator: number | null; seen: Flat[] } {
    return tokenRows(snap.flat, ui.rows, token, this.page(snap));
  }

  private tokenRows(snap: Snapshot, ui: AdapterUi, token: string): Flat[] {
    return this.rowsOf(snap, ui, token).rows;
  }

  // The headings (the opened subject) that carry the token.
  private tokenHeadings(snap: Snapshot, ui: AdapterUi, token: string): Flat[] {
    return findShowing(snap.flat, ui.opened.subject).filter((f) =>
      (f.node.name ?? "").includes(token),
    );
  }

  // What one look saw (the search record).
  private look(
    ui: AdapterUi,
    folder: FolderName,
    url: string,
    how: Look["how"],
    snap: Snapshot,
    token: string,
    redact: string[],
  ): Look {
    const r = this.rowsOf(snap, ui, token);
    const label = (f: Flat): string => {
      const own = f.node.name ?? "";
      return clipText(own !== "" ? own : rowText(f.node), 120, redact);
    };
    return {
      folder,
      url: clipText(url, 400, redact),
      how,
      location:
        snap.location === null ? null : clipText(snap.location, 400, redact),
      location_matched: sameLocation(snap.location, url),
      rows: r.seen.slice(0, LOOK_ROWS).map(label),
      row_locator:
        r.locator === null ? null : describeLocator(ui.rows[r.locator]!),
      token_rows: r.rows.length,
      token_nodes: tokenNodes(snap.flat, token)
        .slice(0, LOOK_ROWS)
        .map(
          (f) =>
            `${f.node.role}/${f.node.nativeRole} ${clipText(f.node.name || f.node.text || "", 120, redact)}`,
        ),
    };
  }

  // Looks for the message in `folders`, once each: each of a folder's
  // URLs in turn, and its tabs. Every look is appended to `looks`.
  private async lookIn(
    adapter: WebmailAdapter,
    desk: WebmailDesktop,
    w: Worker,
    d: { messageId: string; subjectToken: string },
    folders: FolderName[],
    looks: Look[],
  ): Promise<{ folder: FolderName; rows: Flat[] } | null> {
    const a = w.account;
    const ui = adapter.desktop;
    const token = d.subjectToken;
    const has = (s: Snapshot): boolean =>
      this.tokenRows(s, ui, token).length > 0;
    // A typed URL changes the address at once, but a webmail routed by
    // its fragment (Gmail) swaps the list a moment later: when the page
    // already shows a row carrying the token, the typed URL is reloaded,
    // so that the row read is the new page's.
    for (const name of folders) {
      const f = ui.folders[name];
      const urls = folderUrls(f, { messageId: d.messageId, token });
      for (const url of urls) {
        const r = await desk.navigate(url, has, this.t.listSettleMs, {
          reloadWhen: has,
        });
        looks.push(this.look(ui, name, url, r.how, r.snap, token, w.redact));
        this.assertOnMailHost(adapter, r.snap, a);
        if (r.ok)
          return { folder: name, rows: this.tokenRows(r.snap, ui, token) };
        for (const tab of f.tabs) {
          const t = findShowing(r.snap.flat, tab);
          if (t.length !== 1) continue;
          await desk.click(t[0]!.node.bounds!);
          const r2 = await desk.waitFor(has, this.t.listSettleMs);
          looks.push(
            this.look(
              ui,
              name,
              `${url} (tab ${tab.name ?? describeLocator(tab)})`,
              "tab",
              r2.snap,
              token,
              w.redact,
            ),
          );
          // The look's URL names the tab: the location is the folder's.
          looks[looks.length - 1]!.location_matched = sameLocation(
            r2.snap.location,
            url,
          );
          this.assertOnMailHost(adapter, r2.snap, a);
          if (r2.ok)
            return { folder: name, rows: this.tokenRows(r2.snap, ui, token) };
        }
      }
    }
    return null;
  }

  private async findArrival(
    adapter: WebmailAdapter,
    desk: WebmailDesktop,
    w: Worker,
    d: WorkspaceDelivery,
    polls: Look[][],
  ): Promise<{
    folder: FolderName;
    row: Flat;
    ms: number;
    polls: number;
  }> {
    const ui = adapter.desktop;
    const t0 = Date.now();
    const deadline = t0 + this.t.arrivalTimeoutMs;
    for (;;) {
      const looks: Look[] = [];
      polls.push(looks);
      const found = await this.lookIn(
        adapter,
        desk,
        w,
        d,
        ["inbox", "spam"],
        looks,
      );
      if (found !== null) {
        if (found.rows.length !== 1)
          throw new StepError(
            `${adapter.label}: ${found.rows.length} messages in ${ui.folders[found.folder].label} carry the run token ${d.subjectToken}, expected one`,
          );
        return {
          folder: found.folder,
          row: found.rows[0]!,
          ms: Date.now() - t0,
          polls: polls.length,
        };
      }
      if (Date.now() >= deadline) {
        // A list in which no row locator matches anything at all may be
        // a UI the adapter no longer recognises.
        const last = looks[looks.length - 1];
        const any = last === undefined ? 0 : last.rows.length;
        const where = looks.filter((l) => l.token_nodes.length > 0);
        throw new DeliveryTimeout(
          `delivery failure: ${d.messageId} (sent through the Gmail API as ${d.api.id}) was not found in ${adapter.label}'s ${ui.folders.inbox.label} or ${ui.folders.spam.label} within ${Math.round(this.t.arrivalTimeoutMs / 1000)} s (${polls.length} looks)${any === 0 ? `; the row locators (${ui.rows.map((r) => `${describeLocator(r)}, ${r.status}`).join("; ")}) matched no row at all in the last list looked at: if that folder is not empty, the adapter no longer matches the UI` : ""}${where.length > 0 ? `; the run token was on the page outside any row (${where[0]!.token_nodes[0]}): the row locators do not recognise the list` : ""}; the provenance's search record and failure frame show what was seen`,
        );
      }
      await sleep(this.t.pollMs);
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
    const ui = adapter.desktop;
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
    // then the light bodies, then the dark ones (one browser restart at
    // most where the webmail recolours).
    const order = (r: CaptureRequest): number =>
      this.adapter(r.clientId)!.client.kind === "list"
        ? 0
        : r.scheme === "dark"
          ? 2
          : 1;
    const requests = [...job.requests].sort((x, y) => order(x) - order(y));
    const texts = storyTexts(message.html);

    const shared: Record<string, unknown> = {
      lease: {
        wait_ms: Math.round(lease.leaseMs),
        took_over_stale:
          lease.tookOver === null
            ? null
            : { pid: lease.tookOver.pid, run: lease.tookOver.run },
      },
      browser: {
        driver: "guiassert",
        automation: "none",
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
      w.redact = [receiver.address];
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
    // What the current step is, for a failure's evidence.
    let step = "open-browser";
    // The evidence of the failure that took the adapter down (later
    // requests fail with it without a new frame).
    let downEvidence: FailureEvidence | null = null;
    const polls: Look[][] = [];
    try {
      // The browser in the first request's scheme (list rows, then light
      // bodies, then dark ones): a worker whose browser was left dark by
      // the previous story is restarted light here, before the search,
      // so that the list rows and light bodies never run in a dark
      // browser and the story pays at most one restart.
      const first = requests[0];
      let desk = await this.openDesktop(
        w,
        adapter,
        ui.dark === null || first === undefined ? "light" : first.scheme,
      );
      step = "arrival";
      const tArr = performance.now();
      const found = await this.findArrival(adapter, desk, w, delivery, polls);
      timing.arrival = performance.now() - tArr;
      handle = {
        delivery,
        folder: found.folder,
        arrivalMs: found.ms,
        polls: found.polls,
      };
      const lastPoll = polls[polls.length - 1] ?? [];
      shared.arrival = {
        folder: found.folder,
        folder_label: ui.folders[found.folder].label,
        latency_ms: found.ms,
        polls: found.polls,
        row_locator:
          [...lastPoll].reverse().find((l) => l.row_locator !== null)
            ?.row_locator ?? null,
        looks: lastPoll,
      };
      let row: Flat | null = found.row;
      let opened = false;

      for (const req of requests) {
        const { client } = this.adapter(req.clientId)!;
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
          if (req.viewport.width !== DESKTOP_VIEWPORT.width)
            throw new StepError(
              `${adapter.label}: the window is sized for a ${DESKTOP_VIEWPORT.width} px body when the browser starts; ${req.viewport.width} px is not captured`,
            );
          if (client.kind === "list") {
            step = "list-row";
            if (ui.dark !== null && w.scheme !== req.scheme)
              throw new StepError(
                `${adapter.label}: the list row is captured in the browser it was found in, which runs ${w.scheme}; a ${req.scheme} row is not captured there`,
              );
            if (row === null)
              throw new StepError(
                `${adapter.label}: the list row is captured before the message is opened, and it already was`,
              );
            const r = await this.captureRow(
              adapter,
              desk,
              a,
              delivery.subjectToken,
            );
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
          // The browser in the request's scheme, where the webmail
          // recolours: a browser in the other one is restarted, and the
          // message found again where it arrived and opened again.
          const scheme: Scheme = ui.dark === null ? "light" : req.scheme;
          if (w.scheme !== scheme || w.desk === null) {
            step = `restart-${scheme}`;
            const tRestart = performance.now();
            desk = await this.openDesktop(w, adapter, scheme);
            const looks: Look[] = [];
            const again = await this.lookIn(
              adapter,
              desk,
              w,
              delivery,
              [found.folder],
              looks,
            );
            prov.restart = { scheme, looks };
            if (again === null || again.rows.length !== 1)
              throw new StepError(
                `${adapter.label}: after the browser restarted in ${scheme}, ${again === null ? "the message was not found" : `${again.rows.length} messages carry the run token`} in ${ui.folders[found.folder].label}`,
              );
            row = again.rows[0]!;
            opened = false;
            rtiming.restart = performance.now() - tRestart;
          }
          if (!opened) {
            step = "open";
            const tOpen = performance.now();
            await this.open(adapter, desk, a, row!, delivery.subjectToken);
            rtiming.open = performance.now() - tOpen;
            opened = true;
            row = null;
          }
          step = `body-${req.scheme}`;
          const shot = await this.captureBody(
            adapter,
            desk,
            a,
            req,
            client,
            texts,
            delivery.subjectToken,
            w.scheme,
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
          const wasDown: boolean =
            downEvidence !== null && err instanceof DriftError;
          const evidence: FailureEvidence | null = wasDown
            ? downEvidence
            : await this.keepFailure(w, adapter, step);
          if (evidence !== null) prov.failure = evidence;
          if (err instanceof DriftError && downEvidence === null)
            downEvidence = evidence;
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
        const reason =
          err instanceof DesktopUnavailable
            ? `the capture browser cannot run: ${err.message}`
            : oneLine(err);
        const failure = await this.keepFailure(w, adapter, step);
        const search = polls.slice(-2).flat();
        failAll(reason, {
          ...shared,
          ...(search.length > 0 ? { search } : {}),
          ...(failure !== null ? { failure } : {}),
        });
        this.cleanupRecord({
          account: a.name,
          set: a.set,
          message_id: delivery.messageId,
          folder: null,
          state: err instanceof DeliveryTimeout ? "not-found" : "failed",
          reason,
          ...(failure !== null ? { failure } : {}),
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
    if (w.desk !== null && handle !== null)
      await this.remove(adapter, w.desk, w, handle);
  }

  // The last display frame and the accessibility-tree summary of a
  // failing step, kept 0600 under <run>/hosted-webmail-failures/; null
  // when there is no browser or run dir.
  // Unguarded: a capture never holds a password, so there is no secret
  // to guard against (its OCR is unguarded for the same reason).
  private async keepFailure(
    w: Worker,
    adapter: WebmailAdapter,
    step: string,
  ): Promise<FailureEvidence | null> {
    const desk = w.desk;
    if (desk === null || this.runDir === "") return null;
    const dir = join(this.runDir, FAILURES_DIR);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
    const base = `${adapter.id}-${w.account.name}-${step.replace(/[^A-Za-z0-9_-]+/g, "-")}-${++this.failureCount}`;
    const ev: FailureEvidence = {
      step,
      frame: null,
      tree: null,
      location: null,
    };
    const keep = (name: string, bytes: Uint8Array | string): string => {
      const path = join(dir, name);
      writeFileSync(path, bytes, { mode: 0o600 });
      chmodSync(path, 0o600);
      return `${FAILURES_DIR}/${name}`;
    };
    try {
      ev.frame = keep(`${base}.png`, await desk.displayFrame());
    } catch (err) {
      ev.frame_error = oneLine(err);
    }
    try {
      const snap = await desk.snapshot();
      const summary = treeSummary(snap, w.redact);
      ev.location = summary.location;
      ev.tree = keep(
        `${base}.tree.json`,
        `${JSON.stringify({ step, ...summary }, null, 1)}\n`,
      );
    } catch (err) {
      ev.tree_error = oneLine(err);
    }
    return ev;
  }

  private async captureRow(
    adapter: WebmailAdapter,
    desk: WebmailDesktop,
    a: PoolAccount,
    token: string,
  ): Promise<{ png: Uint8Array; texts: Record<string, string> }> {
    const snap = await desk.snapshot();
    this.assertOnMailHost(adapter, snap, a);
    // The row read again: it must still be shown, and be the only one.
    const again = this.tokenRows(snap, adapter.desktop, token);
    if (again.length !== 1)
      throw new StepError(
        `${adapter.label}: the message's row is no longer shown in the list (${again.length} rows carry the run token)`,
      );
    const f = again[0]!;
    // Its name when that carries the token, else its whole text (a row
    // named after its sender alone).
    const own = f.node.name ?? "";
    const name = carriesToken(own, token) ? own : rowText(f.node);
    const b = f.node.bounds!;
    const png = await desk.capture(b);
    const ocr = (await desk.ocrRegion(b)).replace(/\s+/g, " ").trim();
    return { png, texts: { name, ocr } };
  }

  // Opens the row's message: a heading must then carry the token. With
  // `needBody` its body must be found too (the removal checks only who
  // the message is: its body need not be recognised to delete it).
  private async open(
    adapter: WebmailAdapter,
    desk: WebmailDesktop,
    a: PoolAccount,
    row: Flat,
    token: string,
    needBody = true,
  ): Promise<void> {
    const ui = adapter.desktop;
    await desk.click(
      clickTarget(row.node as typeof row.node & { bounds: Rect }, token),
    );
    const r = await desk.waitFor(
      (s) =>
        this.tokenHeadings(s, ui, token).length > 0 ||
        (findShowing(s.flat, ui.opened.subject).length > 0 &&
          this.tokenRows(s, ui, token).length === 0),
      this.t.stepTimeoutMs,
    );
    const carrying = this.tokenHeadings(r.snap, ui, token);
    if (carrying.length === 1) return;
    this.assertOnMailHost(adapter, r.snap, a);
    if (carrying.length > 1)
      throw this.drift(
        adapter,
        "opened.subject",
        ui.opened.subject,
        `matched ${carrying.length} headings carrying the run token, expected exactly one`,
      );
    const shown = findShowing(r.snap.flat, ui.opened.subject);
    if (!r.ok || shown.length === 0)
      throw this.drift(
        adapter,
        "opened.subject",
        ui.opened.subject,
        `matched no showing element carrying the run token within ${this.t.stepTimeoutMs / 1000} s`,
      );
    throw new StepError(
      `${adapter.label}: the opened message is not the delivered one (no heading carries the run token ${token}; shown: ${shown.map((f) => `'${f.node.name ?? ""}'`).join(", ")})`,
    );
  }

  // The opened message's body: the node its own locator names, or the
  // story region (a11y_tree.ts `locateStoryRegion`).
  private locateBody(
    adapter: WebmailAdapter,
    snap: Snapshot,
    texts: string[],
    token: string,
  ): {
    rect: Rect;
    node: Flat | null;
    subject: Flat;
    how: Record<string, unknown>;
  } {
    const ui = adapter.desktop;
    const headings = this.tokenHeadings(snap, ui, token);
    if (headings.length !== 1)
      throw new StepError(
        `${adapter.label}: the opened message's subject is not shown any more (${headings.length} headings carry the run token)`,
      );
    const subject = headings[0]!;
    if (ui.opened.body !== null) {
      const found = findShowing(snap.flat, ui.opened.body);
      if (found.length !== 1)
        throw this.drift(
          adapter,
          "opened.body",
          ui.opened.body,
          found.length === 0
            ? "matched no showing element"
            : `matched ${found.length} elements, expected exactly one`,
        );
      return {
        rect: found[0]!.node.bounds!,
        node: found[0]!,
        subject,
        how: { locator: describeLocator(ui.opened.body) },
      };
    }
    const scope = closest(subject, DOCUMENT) ?? snap.flat[0]!;
    const region = locateStoryRegion(snap.flat, texts, {
      scope,
      chrome: WEBMAIL_CHROME,
      subject,
    });
    if (region === null)
      throw this.drift(
        adapter,
        "opened.body",
        null,
        "found no showing node below the subject carrying the story's text",
      );
    return {
      rect: region.rect,
      node: null,
      subject,
      how: {
        locator: "story region",
        carriers: region.carriers,
        foreign_inside: region.foreignInside,
        bounded: { top: region.top, bottom: region.bottom },
      },
    };
  }

  private async captureBody(
    adapter: WebmailAdapter,
    desk: WebmailDesktop,
    a: PoolAccount,
    req: CaptureRequest,
    client: AdapterClient,
    texts: string[],
    token: string,
    browserScheme: Scheme,
    timing: Record<string, number>,
  ): Promise<{ png: Uint8Array; provenance: Record<string, unknown> }> {
    const ui = adapter.desktop;
    const provenance: Record<string, unknown> = {};
    let snap = await desk.snapshot();
    this.assertOnMailHost(adapter, snap, a);
    let at = this.locateBody(adapter, snap, texts, token);

    // The scheme: the browser's colour mode, the request's. A webmail
    // that recolours (Outlook.com) must show its theme in it, checked by
    // its subject heading's luminance; in dark its background toggle, if
    // one is shown, must be unchecked (the body in its dark state). A
    // light capture never looks for the toggle.
    const dark = ui.dark;
    if (dark === null)
      provenance.scheme_applied = {
        scheme: req.scheme,
        browser: browserScheme,
        evidence: "the webmail does not recolour the body",
      };
    else {
      const wantDark = req.scheme === "dark";
      const theme = Math.round(
        meanLuminance(await desk.capture(at.subject.node.bounds!)),
      );
      if (browserScheme !== req.scheme || theme < THEME_DARK_BELOW !== wantDark)
        throw new StepError(
          `${adapter.label}: the page is ${theme < THEME_DARK_BELOW ? "dark" : "light"} (its subject heading's mean luminance ${theme}) in a ${browserScheme} browser, for a ${req.scheme} capture: the webmail's theme does not follow the browser's colour mode (set its Appearance to follow the system while signing in); nothing is captured in the other scheme`,
        );
      let toggle: "untouched" | "absent" | "unchecked" | "switched" =
        "untouched";
      if (wantDark) {
        const shown = (s: Snapshot): Flat[] => findShowing(s.flat, dark.toggle);
        const r = await desk.waitFor(
          (s) => shown(s).length > 0,
          this.t.toggleWaitMs,
        );
        snap = r.snap;
        const t = shown(snap);
        if (t.length > 1)
          throw this.drift(
            adapter,
            "dark.toggle",
            dark.toggle,
            `matched ${t.length} elements, expected at most one`,
          );
        if (t.length === 0) toggle = "absent";
        else if (!t[0]!.node.states.includes("checked")) toggle = "unchecked";
        else {
          await desk.click(t[0]!.node.bounds!);
          const r2 = await desk.waitFor((s) => {
            const x = shown(s);
            return x.length === 1 && !x[0]!.node.states.includes("checked");
          }, this.t.stepTimeoutMs);
          if (!r2.ok)
            throw new StepError(
              `${adapter.label}: the background toggle did not switch the body back to its dark state`,
            );
          snap = r2.snap;
          toggle = "switched";
        }
        at = this.locateBody(adapter, snap, texts, token);
      }
      provenance.scheme_applied = {
        scheme: req.scheme,
        browser: browserScheme,
        evidence:
          toggle === "untouched"
            ? "a light browser; the webmail's theme light; the background toggle not touched"
            : toggle === "absent"
              ? "a dark browser; the webmail's theme dark; no background toggle shown (the body in its dark state by default)"
              : `a dark browser; the webmail's theme dark; the background toggle ${toggle === "switched" ? "switched off" : "off"}`,
        theme_luminance: theme,
        toggle,
      };
    }

    // The visual settle: the body's region captured until two frames
    // stableMs apart are identical and its bounds did not move (fonts
    // and images loading change both), bounded; never a failure.
    const tSettle = performance.now();
    const bound = Date.now() + this.t.imageTimeoutMs;
    let png: Uint8Array | null = null;
    let rect: Rect = at.rect;
    let settled = false;
    let frames = 0;
    for (;;) {
      const next = await desk.capture(rect);
      frames++;
      if (
        png !== null &&
        Buffer.compare(Buffer.from(png), Buffer.from(next)) === 0
      ) {
        snap = await desk.snapshot();
        at = this.locateBody(adapter, snap, texts, token);
        if (sameRect(at.rect, rect)) {
          settled = true;
          png = next;
          break;
        }
        rect = at.rect;
        png = null;
        continue;
      }
      png = next;
      if (Date.now() >= bound) break;
      await sleep(this.t.stableMs);
      snap = await desk.snapshot();
      at = this.locateBody(adapter, snap, texts, token);
      if (!sameRect(at.rect, rect)) {
        rect = at.rect;
        png = null;
      }
    }
    if (png === null) png = await desk.capture(rect);
    timing.settle = performance.now() - tSettle;
    provenance.settle = { settled, frames };
    this.assertOnMailHost(adapter, snap, a);

    // A body taller than the window's visible part is not captured
    // rather than cut (scroll-and-stitch is later).
    const doc = closest(at.subject, DOCUMENT);
    const visibleBottom = Math.min(
      this.windowHeight,
      doc?.node.bounds === null || doc === null
        ? this.windowHeight
        : doc.node.bounds[1] + doc.node.bounds[3],
    );
    if (rect[1] + rect[3] > visibleBottom || rect[1] < 0)
      throw new StepError(
        `${adapter.label}: the message body is ${rect[3]} px tall and reaches y=${rect[1] + rect[3]}, past the window's visible part (y=${visibleBottom}); it is not captured rather than cut (bodies taller than the window are not supported yet)`,
      );

    // UI fingerprint of the page the message is on, the body and the
    // list's rows left out.
    const root = doc ?? snap.flat[0]!;
    const body = at.node;
    const fp = structureFingerprint(
      snap.flat,
      root,
      (f) =>
        (body !== null && isWithin(f, body)) ||
        insideRect(f.node.bounds, rect) ||
        ui.rows.some((r) => matches(f.node, r)),
    );
    const previous = readFingerprint(this.host, adapter.set, client.ui);
    if (previous !== fp)
      writeFingerprint(this.host, adapter.set, client.ui, fp);
    provenance.ui_fingerprint = {
      value: fp,
      previous,
      changed: previous !== null && previous !== fp,
      basis:
        "accessibility roles of the page, the body and the list's rows left out",
    };

    // Masks: the chrome inside the body's box, painted over the crop.
    const tCap = performance.now();
    const masks = ui.opened.masks.flatMap((m) =>
      findShowing(snap.flat, m, at.node)
        .filter((f) => at.node !== null || insideRect(f.node.bounds, rect))
        .map((f) => f.node.bounds!),
    );
    png = paintMasks(png, [rect[0], rect[1]], masks);
    timing.capture = performance.now() - tCap;
    const windowWidth = DESKTOP_VIEWPORT.width + ui.windowAllowance;
    provenance.crop = {
      ...at.how,
      x: rect[0],
      y: rect[1],
      width: rect[2],
      height: rect[3],
      window: { width: windowWidth, height: this.windowHeight },
      masks: ui.opened.masks.map((m) => describeLocator(m)),
      masked: masks.length,
    };
    provenance.tree = {
      nodes: snap.nodes,
      read_ms: Math.round(snap.ms),
      truncated: snap.truncated,
    };
    if (dark !== null)
      (provenance.scheme_applied as Record<string, unknown>).luminance =
        Math.round(meanLuminance(png));
    // [calibrate] the body is meant to get the requested width.
    provenance.width_check = {
      requested: req.viewport.width,
      measured: rect[2],
      delta: rect[2] - req.viewport.width,
    };
    return { png, provenance };
  }

  // Deletes the message in the UI (then from Trash; or for good at once
  // in a folder of `remove.permanentIn`, Gmail's Spam; or, where the
  // adapter allows, a delete that was permanent itself), looks for it
  // again everywhere, and records the outcome.
  private async remove(
    adapter: WebmailAdapter,
    desk: WebmailDesktop,
    w: Worker,
    handle: Handle,
  ): Promise<void> {
    const a = w.account;
    const d = handle.delivery;
    const ui = adapter.desktop;
    const record = {
      account: a.name,
      set: a.set,
      message_id: d.messageId,
      folder: handle.folder,
    };
    const permanent = ui.remove.permanentIn.includes(handle.folder);
    const delLoc = permanent ? ui.remove.deleteForever : ui.remove.del;
    const looks: Look[] = [];
    let step = "cleanup-delete";
    try {
      // Delete only the delivered message: the open one when a heading
      // carries the run token, otherwise its row is found where it
      // arrived and opened with the identity check (a message that
      // cannot be shown to be the delivered one is never deleted).
      const snap = await desk.snapshot();
      let del = findShowing(snap.flat, delLoc);
      if (
        del.length !== 1 ||
        this.tokenHeadings(snap, ui, d.subjectToken).length !== 1
      ) {
        const where = await this.lookIn(
          adapter,
          desk,
          w,
          d,
          [handle.folder],
          looks,
        );
        if (where === null)
          throw new StepError(
            `the message is no longer in ${ui.folders[handle.folder].label}`,
          );
        await this.open(
          adapter,
          desk,
          a,
          where.rows[0]!,
          d.subjectToken,
          false,
        );
        del = [
          (
            await this.exactlyOne(
              desk,
              adapter,
              a,
              permanent ? "remove.deleteForever" : "remove.delete",
              delLoc,
            )
          ).node,
        ];
      }
      await desk.click(del[0]!.node.bounds!);
      let via: string;
      if (permanent) {
        await this.finishPermanent(desk, adapter, a, d);
        via = "delete-forever";
      } else {
        const r = await this.afterDelete(
          desk,
          adapter,
          w,
          handle,
          looks,
          (s) => {
            step = s;
          },
        );
        via = r;
      }
      // Gone from every folder?
      step = "cleanup-check";
      const left = await this.lookIn(
        adapter,
        desk,
        w,
        d,
        ["inbox", "spam", "trash"],
        looks,
      );
      if (left !== null)
        throw new StepError(
          `still in ${ui.folders[left.folder].label} after the delete`,
        );
      this.cleanupRecord({
        ...record,
        state: "removed",
        via,
        reason: null,
      });
    } catch (err) {
      const reason = oneLine(err);
      const failure = await this.keepFailure(w, adapter, step);
      this.cleanupRecord({
        ...record,
        state: "failed",
        reason,
        search: looks.slice(-8),
        ...(failure !== null ? { failure } : {}),
      });
      this.log(
        `email-shots: hosted-webmail: cleanup FAILED for ${d.messageId} in ${a.set}/${a.name}: ${reason}${failure?.frame ? ` (the screen kept at ${join(this.runDir, failure.frame)})` : ""}`,
      );
      if (err instanceof SessionLostError) throw err;
    }
  }

  // After a click on the delete in the opened message: the message must
  // leave the folder it was in; then it is found in Trash / Deleted
  // Items and deleted from there for good ("trash"), or, never showing
  // up there, taken as deleted for good already where the adapter allows
  // it ("permanent"; `remove.mayBePermanentIn`).
  private async afterDelete(
    desk: WebmailDesktop,
    adapter: WebmailAdapter,
    w: Worker,
    handle: Handle,
    looks: Look[],
    at: (step: string) => void,
  ): Promise<"trash" | "permanent"> {
    const a = w.account;
    const d = handle.delivery;
    const ui = adapter.desktop;
    const from = ui.folders[handle.folder].label;
    const secs = Math.round(this.t.cleanupFindMs / 1000);
    await this.closed(desk, ui, d.subjectToken, "the delete");
    // Out of the folder it was deleted in.
    at("cleanup-left-folder");
    const goneBy = Date.now() + this.t.cleanupFindMs;
    for (;;) {
      const still = await this.lookIn(
        adapter,
        desk,
        w,
        d,
        [handle.folder],
        looks,
      );
      if (still === null) break;
      if (Date.now() >= goneBy)
        throw new StepError(
          `the delete left the message in ${from} (still there after ${secs} s)`,
        );
      await sleep(this.t.pollMs);
    }
    // In Trash / Deleted Items, then deleted for good from there.
    at("cleanup-trash");
    const deadline = Date.now() + this.t.cleanupFindMs;
    let inTrash: { rows: Flat[] } | null = null;
    while (inTrash === null) {
      inTrash = await this.lookIn(adapter, desk, w, d, ["trash"], looks);
      if (inTrash !== null || Date.now() >= deadline) break;
      await sleep(this.t.pollMs);
    }
    if (inTrash === null) {
      if (ui.remove.mayBePermanentIn.includes(handle.folder))
        return "permanent";
      throw new StepError(
        `the deleted message left ${from} but did not show up in ${ui.folders.trash.label} within ${secs} s`,
      );
    }
    at("cleanup-delete-forever");
    await this.open(adapter, desk, a, inTrash.rows[0]!, d.subjectToken, false);
    const forever = await this.exactlyOne(
      desk,
      adapter,
      a,
      "remove.deleteForever",
      ui.remove.deleteForever,
    );
    await desk.click(forever.node.node.bounds!);
    await this.finishPermanent(desk, adapter, a, d);
    return "trash";
  }

  // After a click on the permanent delete: its confirmation, if the
  // webmail asks one, then the message closed.
  private async finishPermanent(
    desk: WebmailDesktop,
    adapter: WebmailAdapter,
    a: PoolAccount,
    d: WorkspaceDelivery,
  ): Promise<void> {
    const ui = adapter.desktop;
    if (ui.remove.confirm !== null) {
      const ok = await this.exactlyOne(
        desk,
        adapter,
        a,
        "remove.confirm",
        ui.remove.confirm,
      );
      await desk.click(ok.node.node.bounds!);
    }
    await this.closed(desk, ui, d.subjectToken, "the permanent delete");
  }

  // A delete has taken effect once no heading carries the run token any
  // more (the webmail went back to a list).
  private async closed(
    desk: WebmailDesktop,
    ui: AdapterUi,
    token: string,
    what: string,
  ): Promise<void> {
    const r = await desk.waitFor(
      (s) => this.tokenHeadings(s, ui, token).length === 0,
      this.t.stepTimeoutMs,
    );
    if (!r.ok)
      throw new StepError(
        `${what} did not close the message within ${this.t.stepTimeoutMs / 1000} s`,
      );
  }

  private cleanupRecord(r: Record<string, unknown>): void {
    if (this.runDir === "") return;
    appendFileSync(
      join(this.runDir, "hosted-webmail-cleanup.jsonl"),
      `${JSON.stringify({ at: new Date(this.now()).toISOString(), ...r })}\n`,
    );
  }

  async dispose(): Promise<void> {
    for (const w of this.workers.splice(0)) await this.closeDesktop(w);
    for (const l of this.leases) releaseLease(l);
    this.leases.clear();
  }
}
