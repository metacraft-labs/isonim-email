// tools/capture/providers/webmail_signin_guard.test.ts — the one-attempt
// rule and the cool-down of the automated webmail sign-in: a second
// automated attempt within the cool-down is refused, whatever the first
// one's result, including a run that died mid-attempt; an unreadable or
// future-dated record refuses; the operator override passes and says
// so; the record is private (0600) and carries no secret.
//
// Real files in a scratch profile directory; no browser, no network.
// Run with:
//   node --test tools/capture/providers/webmail_signin_guard.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { accountProfile } from "./webmail_profiles.ts";
import {
  attemptPath,
  beginAttempt,
  COOLDOWN_MS,
  finishAttempt,
  guardAttempt,
  markPasswordTyped,
  readAttempt,
} from "./webmail_signin_guard.ts";

const scratch = mkdtempSync(join(tmpdir(), "signin-guard-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

let n = 0;
const fresh = () =>
  accountProfile(
    {
      env: { ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: join(scratch, `p${n++}`) },
      platform: "linux",
    },
    "yahoo",
    "yahoo/qa1.json",
    true,
  );
const T0 = Date.parse("2026-10-27T12:00:00.000Z");
const H = 3600_000;

describe("the sign-in attempt guard", () => {
  it("allows the first attempt, and refuses a second within the cool-down whatever the first one's result", () => {
    for (const result of [
      "signed-in",
      "challenged:captcha",
      "wrong-password",
      "unknown-screen",
    ]) {
      const p = fresh();
      assert.deepEqual(guardAttempt(p, T0, { override: false }), {
        allowed: true,
        overridden: false,
        last: null,
      });
      const r = beginAttempt(p, {
        set: "yahoo",
        accountFile: "yahoo/qa1.json",
        nowMs: T0,
        override: false,
      });
      finishAttempt(p, r, result, T0 + 60_000);
      const v = guardAttempt(p, T0 + 23 * H, { override: false });
      assert.equal(v.allowed, false, result);
      assert.ok(!v.allowed);
      assert.match(
        v.why,
        new RegExp(
          `started 2026-10-27T12:00:00.000Z and ended ${result.replace(/[:]/g, "\\$&")}`,
        ),
      );
      assert.equal(v.until, new Date(T0 + COOLDOWN_MS).toISOString());
      // At the end of the cool-down it is allowed again.
      const later = guardAttempt(p, T0 + COOLDOWN_MS, { override: false });
      assert.equal(later.allowed, true, result);
    }
  });

  it("counts an attempt whose run died before it finished (the record still says started)", () => {
    const p = fresh();
    beginAttempt(p, {
      set: "yahoo",
      accountFile: "yahoo/qa1.json",
      nowMs: T0,
      override: false,
    });
    const v = guardAttempt(p, T0 + H, { override: false });
    assert.ok(!v.allowed);
    assert.match(
      v.why,
      /never finished \(state started: the run stopped mid-attempt\)/,
    );
    const q = fresh();
    const r = beginAttempt(q, {
      set: "yahoo",
      accountFile: "yahoo/qa1.json",
      nowMs: T0,
      override: false,
    });
    markPasswordTyped(q, r);
    const w = guardAttempt(q, T0 + H, { override: false });
    assert.ok(!w.allowed);
    assert.match(w.why, /state password-typed/);
  });

  it("refuses on a record it cannot read, and on one dated in the future", () => {
    const p = fresh();
    writeFileSync(attemptPath(p), "{not json", { mode: 0o600 });
    const v = guardAttempt(p, T0, { override: false });
    assert.ok(!v.allowed);
    assert.match(
      v.why,
      /is not JSON, so an attempt may have been made at any time/,
    );
    writeFileSync(attemptPath(p), JSON.stringify({ schema: "other" }), {
      mode: 0o600,
    });
    const w = guardAttempt(p, T0, { override: false });
    assert.ok(!w.allowed);
    assert.match(w.why, /is not an attempt record/);

    const q = fresh();
    beginAttempt(q, {
      set: "yahoo",
      accountFile: "yahoo/qa1.json",
      nowMs: T0 + 2 * H,
      override: false,
    });
    const f = guardAttempt(q, T0, { override: false });
    assert.ok(!f.allowed);
    assert.match(f.why, /starts in the future: the clock moved back/);
  });

  it("lets the operator's override through, and the attempt it allows says so", () => {
    const p = fresh();
    const r = beginAttempt(p, {
      set: "yahoo",
      accountFile: "yahoo/qa1.json",
      nowMs: T0,
      override: false,
    });
    finishAttempt(p, r, "challenged:captcha", T0);
    const v = guardAttempt(p, T0 + H, { override: true });
    assert.equal(v.allowed, true);
    assert.ok(v.allowed && v.overridden);
    const again = beginAttempt(p, {
      set: "yahoo",
      accountFile: "yahoo/qa1.json",
      nowMs: T0 + H,
      override: true,
    });
    assert.equal(again.override, true);
    const read = readAttempt(p);
    assert.ok(read.kind === "record" && read.record.override === true);
    // An override is not needed, and not reported, outside a cool-down.
    const free = guardAttempt(fresh(), T0, { override: true });
    assert.ok(free.allowed && !free.overridden);
  });

  it("keeps the record private and free of secrets, through every state", () => {
    const p = fresh();
    let r = beginAttempt(p, {
      set: "yahoo",
      accountFile: "yahoo/qa1.json",
      nowMs: T0,
      override: false,
    });
    assert.equal(statSync(attemptPath(p)).mode & 0o777, 0o600);
    assert.equal(
      readAttempt(p).kind === "record" &&
        (readAttempt(p) as { record: { state: string } }).record.state,
      "started",
    );
    r = markPasswordTyped(p, r);
    assert.equal(r.state, "password-typed");
    r = finishAttempt(p, r, "signed-in", T0 + 1000);
    assert.equal(statSync(attemptPath(p)).mode & 0o777, 0o600);
    const rec = JSON.parse(readFileSync(attemptPath(p), "utf8")) as Record<
      string,
      unknown
    >;
    assert.deepEqual(Object.keys(rec).sort(), [
      "account_file",
      "finished_at",
      "host",
      "override",
      "pid",
      "result",
      "schema",
      "set",
      "started_at",
      "state",
    ]);
    assert.equal(rec.state, "finished");
    assert.equal(rec.result, "signed-in");
  });
});
