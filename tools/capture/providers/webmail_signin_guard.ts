// tools/capture/providers/webmail_signin_guard.ts — the one-attempt
// rule and the cool-down of the automated webmail sign-in.
//
// A provider that sees repeated password sign-ins from a new browser
// answers with challenges and then locks the account; a QA account
// that is locked needs a person and days. So an automated attempt is
// rare by construction:
// - the attempt record, signin-attempt.json in the account's profile
//   directory (webmail_profiles.ts; 0600; no secret), is written
//   BEFORE the first keystroke reaches the provider, updated before the
//   password is typed, and closed with the result;
// - a second automated attempt for the account within COOLDOWN_MS of
//   the last one's start is refused before any browser starts, whatever
//   that attempt's result was: a challenge, a failure, a success, or a
//   run that died mid-attempt (its record still says `started`);
// - a record that cannot be read, or that starts in the future (a
//   clock that moved back), refuses too: an unknown answer means "an
//   attempt may be recent", never "none";
// - only the operator's explicit override (`--override-cooldown`)
//   passes a refusal, and the attempt it allows is recorded like any
//   other.
// A sign-in that typed nothing (the profile was still signed in, or a
// person signed in over VNC with --manual) is not an attempt and
// writes no record.

import {
  chmodSync,
  existsSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { hostname } from "node:os";
import { join } from "node:path";
import type { AccountProfile } from "./webmail_profiles.ts";

export const ATTEMPT_SCHEMA = "isonim-email/signin-attempt/1";

/** The cool-down after an automated attempt's start. */
export const COOLDOWN_MS = 24 * 3600 * 1000;

export type AttemptState = "started" | "password-typed" | "finished";

export interface AttemptRecord {
  schema: typeof ATTEMPT_SCHEMA;
  set: string;
  account_file: string;
  started_at: string;
  pid: number;
  host: string;
  state: AttemptState;
  /** The result (webmail_signin.ts `SigninOutcome.result`), once finished. */
  result: string | null;
  finished_at: string | null;
  /** The override that allowed it inside a cool-down, if one did. */
  override: boolean;
}

export const attemptPath = (p: AccountProfile): string =>
  join(p.dir, "signin-attempt.json");

export type AttemptRead =
  | { kind: "none" }
  | { kind: "record"; record: AttemptRecord }
  | { kind: "unreadable"; why: string };

export function readAttempt(p: AccountProfile): AttemptRead {
  const path = attemptPath(p);
  if (!existsSync(path)) return { kind: "none" };
  let v: unknown;
  try {
    v = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return { kind: "unreadable", why: `${path} is not JSON` };
  }
  const r = v as Partial<AttemptRecord>;
  if (
    r === null ||
    typeof r !== "object" ||
    r.schema !== ATTEMPT_SCHEMA ||
    typeof r.started_at !== "string" ||
    Number.isNaN(Date.parse(r.started_at))
  )
    return { kind: "unreadable", why: `${path} is not an attempt record` };
  return { kind: "record", record: r as AttemptRecord };
}

export type GuardVerdict =
  | { allowed: true; overridden: boolean; last: AttemptRecord | null }
  | { allowed: false; why: string; until: string | null };

/** Whether an automated attempt may start now (nothing is written). */
export function guardAttempt(
  p: AccountProfile,
  nowMs: number,
  opts: { override: boolean; cooldownMs?: number },
): GuardVerdict {
  const cooldown = opts.cooldownMs ?? COOLDOWN_MS;
  const read = readAttempt(p);
  if (read.kind === "none")
    return { allowed: true, overridden: false, last: null };
  const refuse = (why: string, until: string | null): GuardVerdict =>
    opts.override
      ? {
          allowed: true,
          overridden: true,
          last: read.kind === "record" ? read.record : null,
        }
      : { allowed: false, why, until };
  if (read.kind === "unreadable")
    return refuse(
      `${read.why}, so an attempt may have been made at any time`,
      null,
    );
  const r = read.record;
  const started = Date.parse(r.started_at);
  if (started > nowMs)
    return refuse(
      `the last attempt (${r.started_at}) starts in the future: the clock moved back`,
      null,
    );
  const until = started + cooldown;
  if (nowMs < until) {
    const what =
      r.state === "finished"
        ? `ended ${r.result ?? "without a result"}`
        : `never finished (state ${r.state}: the run stopped mid-attempt)`;
    return refuse(
      `the last automated attempt started ${r.started_at} and ${what}; one attempt per ${Math.round(cooldown / 3600_000)} h`,
      new Date(until).toISOString(),
    );
  }
  return { allowed: true, overridden: false, last: r };
}

function writeRecord(p: AccountProfile, r: AttemptRecord): void {
  const path = attemptPath(p);
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(r, null, 2)}\n`, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

/** Records an attempt as started: call before the first keystroke. */
export function beginAttempt(
  p: AccountProfile,
  o: { set: string; accountFile: string; nowMs: number; override: boolean },
): AttemptRecord {
  const r: AttemptRecord = {
    schema: ATTEMPT_SCHEMA,
    set: o.set,
    account_file: o.accountFile,
    started_at: new Date(o.nowMs).toISOString(),
    pid: process.pid,
    host: hostname(),
    state: "started",
    result: null,
    finished_at: null,
    override: o.override,
  };
  writeRecord(p, r);
  return r;
}

/** Call before the password is typed. */
export function markPasswordTyped(
  p: AccountProfile,
  r: AttemptRecord,
): AttemptRecord {
  const next: AttemptRecord = { ...r, state: "password-typed" };
  writeRecord(p, next);
  return next;
}

export function finishAttempt(
  p: AccountProfile,
  r: AttemptRecord,
  result: string,
  nowMs: number,
): AttemptRecord {
  const next: AttemptRecord = {
    ...r,
    state: "finished",
    result,
    finished_at: new Date(nowMs).toISOString(),
  };
  writeRecord(p, next);
  return next;
}
