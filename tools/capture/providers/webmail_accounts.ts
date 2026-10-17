// tools/capture/providers/webmail_accounts.ts — the state the
// hosted-webmail provider keeps per QA account, on the machine that runs
// the captures: whether a person has signed the account's profile in,
// whether its session was lost since, today's delivery count against
// its daily budget, and its lease.
//
// All of it lives in the account's profile directory
// (webmail_profiles.ts, every level 0700), next to the Chromium profile
// it describes, and none of it is a secret:
// - signin.json: written by the guided sign-in when it verified the
//   profile (webmail_profiles.ts);
// - needs-login.json: written when a capture found the session gone;
//   the account is out of selection until a person's sign-in passes
//   again (the sign-in removes it);
// - budget.json: {day, count}, the UTC day and the deliveries made to
//   the account that day; at 90% of the daily budget the account drops
//   out until the next day;
// - lease.json: who is using the account now (pid, run, since),
//   created exclusively and deleted by its holder; one whose holder no
//   longer runs is stale and taken over.
// And per set, beside the accounts: ui-fingerprint.json, the last UI
// fingerprint an adapter saw per UI (desktop, mobile: two different
// pages), the client build's ui-fp part.

import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { hostname } from "node:os";
import { dirname, join } from "node:path";
import { credentialSet } from "./credentials.ts";
import {
  entryMatches,
  type HostEnv,
  inspectCredentialsDir,
} from "./requirements.ts";
import {
  accountName,
  accountProfile,
  type AccountProfile,
  profilesRoot,
  readSigninRecord,
  type SigninRecord,
} from "./webmail_profiles.ts";

export const BUDGET_ENV = "ISONIM_EMAIL_WEBMAIL_DAILY_BUDGET";
export const DEFAULT_DAILY_BUDGET = 300;
// The share of the budget at which an account drops out.
export const BUDGET_CUTOFF = 0.9;

function readJson<T>(path: string): T | null {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null;
  }
}

function writePrivate(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

// ---------------------------------------------------------------------------
// Budget
// ---------------------------------------------------------------------------

export function dailyBudget(env: Record<string, string | undefined>): number {
  const v = env[BUDGET_ENV];
  if (v === undefined || v === "") return DEFAULT_DAILY_BUDGET;
  const n = Number(v);
  if (!Number.isInteger(n) || n <= 0)
    throw new Error(`${BUDGET_ENV}=${v} is not a positive whole number`);
  return n;
}

export const utcDay = (ms: number): string =>
  new Date(ms).toISOString().slice(0, 10);

export interface BudgetState {
  day: string;
  count: number;
  limit: number;
  // The count at which the account drops out (90% of the limit).
  cutoff: number;
  exhausted: boolean;
}

const budgetPath = (p: AccountProfile): string => join(p.dir, "budget.json");

export function budgetState(
  p: AccountProfile,
  limit: number,
  nowMs: number,
): BudgetState {
  const day = utcDay(nowMs);
  const rec = readJson<{ day?: unknown; count?: unknown }>(budgetPath(p));
  const count =
    rec !== null && rec.day === day && typeof rec.count === "number"
      ? rec.count
      : 0;
  const cutoff = Math.ceil(limit * BUDGET_CUTOFF);
  return { day, count, limit, cutoff, exhausted: count >= cutoff };
}

// Counts one delivery (before it is attempted: the provider sees the
// attempt whether or not it succeeds).
export function countDelivery(
  p: AccountProfile,
  limit: number,
  nowMs: number,
): BudgetState {
  const s = budgetState(p, limit, nowMs);
  writePrivate(budgetPath(p), { day: s.day, count: s.count + 1 });
  return budgetState(p, limit, nowMs);
}

// ---------------------------------------------------------------------------
// Session loss
// ---------------------------------------------------------------------------

export interface NeedsLogin {
  at: string;
  reason: string;
}

const needsLoginPath = (p: AccountProfile): string =>
  join(p.dir, "needs-login.json");

export function readNeedsLogin(p: AccountProfile): NeedsLogin | null {
  return readJson<NeedsLogin>(needsLoginPath(p));
}

export function markNeedsLogin(p: AccountProfile, reason: string): void {
  writePrivate(needsLoginPath(p), { at: new Date().toISOString(), reason });
}

export function clearNeedsLogin(p: AccountProfile): void {
  rmSync(needsLoginPath(p), { force: true });
}

// ---------------------------------------------------------------------------
// Leases
// ---------------------------------------------------------------------------

export interface LeaseRecord {
  pid: number;
  host: string;
  run: string;
  since: string;
}

export interface Lease {
  path: string;
  record: LeaseRecord;
  // The stale lease this one replaced (its holder had exited), if any.
  tookOver: LeaseRecord | null;
}

const leasePath = (p: AccountProfile): string => join(p.dir, "lease.json");

function running(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM: it runs, as another user.
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

export function readLease(p: AccountProfile): LeaseRecord | null {
  return readJson<LeaseRecord>(leasePath(p));
}

// The lease, or null when another running process holds it. A lease
// left by a process that no longer runs (on this host) is removed and
// taken over.
export function tryLease(p: AccountProfile, run: string): Lease | null {
  const path = leasePath(p);
  let tookOver: LeaseRecord | null = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    const record: LeaseRecord = {
      pid: process.pid,
      host: hostname(),
      run,
      since: new Date().toISOString(),
    };
    let fd: number;
    try {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      fd = openSync(path, "wx", 0o600);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      const held = readLease(p);
      if (
        held !== null &&
        held.host === hostname() &&
        typeof held.pid === "number" &&
        !running(held.pid)
      ) {
        tookOver = held;
        rmSync(path, { force: true });
        continue;
      }
      return null;
    }
    try {
      writeSync(fd, `${JSON.stringify(record)}\n`);
    } finally {
      closeSync(fd);
    }
    return { path, record, tookOver };
  }
  return null;
}

// Deletes the lease file if it is still this lease.
export function releaseLease(lease: Lease): void {
  const held = readJson<LeaseRecord>(lease.path);
  if (
    held !== null &&
    held.pid === lease.record.pid &&
    held.run === lease.record.run &&
    held.since === lease.record.since
  )
    rmSync(lease.path, { force: true });
}

// ---------------------------------------------------------------------------
// UI fingerprints
// ---------------------------------------------------------------------------

const fingerprintPath = (host: HostEnv, set: string): string =>
  join(profilesRoot(host), set, "ui-fingerprint.json");

// Per UI ("desktop", "mobile"): the desktop and mobile web UIs are
// different pages, so each keeps its own last fingerprint (one value
// for both would flip at every run that captures both).
type FingerprintFile = { fingerprints?: Record<string, unknown> };

export function readFingerprint(
  host: HostEnv,
  set: string,
  ui: string,
): string | null {
  const v = readJson<FingerprintFile>(fingerprintPath(host, set))
    ?.fingerprints?.[ui];
  return typeof v === "string" ? v : null;
}

export function writeFingerprint(
  host: HostEnv,
  set: string,
  ui: string,
  fingerprint: string,
): void {
  const path = fingerprintPath(host, set);
  const prev = readJson<FingerprintFile>(path)?.fingerprints ?? {};
  writePrivate(path, {
    fingerprints: { ...prev, [ui]: fingerprint },
    seen_at: new Date().toISOString(),
  });
}

// ---------------------------------------------------------------------------
// The pool
// ---------------------------------------------------------------------------

export interface PoolAccount {
  set: string;
  // The account file, relative to the credentials directory.
  file: string;
  name: string;
  profile: AccountProfile;
  signin: SigninRecord | null;
  needsLogin: NeedsLogin | null;
  budget: BudgetState;
  lease: LeaseRecord | null;
}

export type Readiness =
  | { ready: true }
  | { ready: false; why: string; remedy: string };

export function signinCommand(set: string, name: string): string {
  return `just email-webmail-signin ${set} --account ${name}`;
}

export function readiness(a: PoolAccount): Readiness {
  if (a.signin === null || !existsSync(a.profile.userDataDir))
    return {
      ready: false,
      why: `${a.set}/${a.name} has never been signed in`,
      remedy: signinCommand(a.set, a.name),
    };
  if (a.needsLogin !== null)
    return {
      ready: false,
      why: `${a.set}/${a.name} lost its session (${a.needsLogin.at}: ${a.needsLogin.reason})`,
      remedy: signinCommand(a.set, a.name),
    };
  if (a.budget.exhausted)
    return {
      ready: false,
      why: `budget: ${a.set}/${a.name} made ${a.budget.count} deliveries today (${a.budget.day} UTC), at or over ${Math.round(BUDGET_CUTOFF * 100)}% of its daily budget of ${a.budget.limit}`,
      remedy: `wait for the next UTC day, or raise ${BUDGET_ENV}`,
    };
  return { ready: true };
}

// The set's account files (sorted) with their state; [] when the
// directory has none (or is unusable: the requirement check reports
// that).
export function poolAccounts(
  host: HostEnv,
  set: string,
  limit: number,
  nowMs: number,
): PoolAccount[] {
  const state = inspectCredentialsDir(host);
  if (state.problem !== null) return [];
  return entryMatches(credentialSet(set).entry, state)
    .sort()
    .map((file) => {
      const profile = accountProfile(host, set, file);
      return {
        set,
        file,
        name: accountName(file),
        profile,
        signin: readSigninRecord(profile),
        needsLogin: readNeedsLogin(profile),
        budget: budgetState(profile, limit, nowMs),
        lease: readLease(profile),
      };
    });
}
