// tools/capture/providers/webmail_signin.test.ts — the automated webmail
// sign-in's procedure and its command line, over a scripted desktop.
//
// What is proven:
// - the step sequence per provider (Gmail: address, password; Outlook.com:
//   address, "Use your password", password, "Stay signed in?"), with a
//   field the page did not focus clicked into first;
// - the address is typed only into the address field and the password
//   only into a focused protected field, once; a password screen whose
//   field is not protected gets no password (`field-not-found`);
// - a challenge, an error, a screen that never moves on (`stuck`), an
//   unknown screen and the deadline each stop the attempt with no input
//   after it, and keep a screenshot that does not show the password; a
//   password legible on the screen stops it at once and keeps no frame;
// - an already signed-in profile gets no input and records no attempt;
// - the check afterwards reads the mailbox off the screen with no input
//   at all: the mailbox is signed in; a sign-in step or a challenge on
//   the inbox URL, or no mailbox by the timeout, is not;
// - the attempt is recorded before the first keystroke and marked before
//   the password is typed;
// - the password (a sentinel) never appears in any argument or
//   environment of any process the sign-in starts (every GuiAssert call,
//   the browser), nor in stdout, stderr, the attempt record or a kept
//   screenshot: it reaches only the standard input of `type` into the
//   protected field and of the `--secret-stdin` guard;
// - the command line: a challenge exits 5 and is not retried; a second
//   run inside the cool-down is refused (exit 6) before a session or a
//   browser starts, also after a run killed mid-attempt;
//   `--override-cooldown` lets it through; SIGTERM mid-attempt stops the
//   browser and the session and closes the record as interrupted; the
//   browser's command line carries no automation switch; a sign-in that
//   reaches the mailbox is checked in the same (stand-in) webmail browser
//   started again on the inbox URL, without Playwright (which cannot run
//   there), and recorded as verified by OCR (exit 0); `--check-only` on a
//   signed-out profile exits 1 with no input and no attempt.
//
// Test doubles (justification, per the repository's mock policy): the
// providers' sign-in pages and challenges cannot be reached from a test
// (a test must never sign in to a real account), so a stand-in
// `guiassert` (guiassert_standin.ts) plays the desktop: same
// command-line contract, scripted screens, and a log of every call. The
// real GuiAssert, the real Chromium and OCR are exercised in
// webmail_signin_session.test.ts. For the command-line tests the browser
// is a stand-in too (a script named by ISONIM_EMAIL_WEBMAIL_BROWSER that
// records its arguments and environment and waits), because the
// stand-in desktop has no display for a real one; the browser sandbox
// check is skipped there with the recipe's own --unsafe-no-sandbox.
// Run with:
//   node --test tools/capture/providers/webmail_signin.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
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
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { inspect } from "node:util";
import { GuiAssert, Secret } from "./guiassert.ts";
import type { StandinLogEntry, StandinScenario } from "./guiassert_standin.ts";
import { CREDENTIALS_SCHEMA } from "./requirements.ts";
import {
  accountProfile,
  readSigninRecord,
  WEBMAIL_SIGNIN,
} from "./webmail_profiles.ts";
import {
  AUTOMATION_SWITCHES,
  driveSignin,
  type SigninContext,
  type VerifyContext,
  verifySignedIn,
} from "./webmail_signin.ts";
import { attemptPath, readAttempt } from "./webmail_signin_guard.ts";
import {
  GMAIL_SIGNIN,
  OUTLOOK_SIGNIN,
  type ProviderSignin,
} from "./webmail_signin_steps.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const signinCli = join(repoRoot, "tools", "capture", "email-webmail-signin.ts");
const standin = join(scriptDir, "guiassert_standin.ts");
const scratch = mkdtempSync(join(tmpdir(), "webmail-signin-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

// The QA account's password in these tests: it must never show up
// anywhere but on the two pipes it is meant for.
const SENTINEL = "Sentinel-pw-7Qx!9z";
const ADDRESS = "qa.tester@example.com";

// A `guiassert` on PATH that is the stand-in.
const binDir = join(scratch, "bin");
mkdirSync(binDir);
const gaBin = join(binDir, "guiassert");
writeFileSync(
  gaBin,
  `#!/bin/sh\nexec "${process.execPath}" "${standin}" "$@"\n`,
  { mode: 0o755 },
);

const ADDRESS_FIELD: [number, number, number, number] = [100, 200, 400, 40];
const PASSWORD_FIELD: [number, number, number, number] = [100, 260, 400, 40];

function gmailScenario(
  after: Record<string, StandinScenario["screens"][string]> = {},
  opts: {
    passwordFocused?: boolean;
    addressFocused?: boolean;
    passwordProtected?: boolean;
  } = {},
): StandinScenario {
  return {
    start: "address",
    screens: {
      address: {
        text: "Google\nSign in\nto continue to Gmail\nEmail or phone\nForgot email?\nNext",
        fields: [{ name: "Email or phone", bounds: ADDRESS_FIELD }],
        ...(opts.addressFocused === false ? {} : { focus: "Email or phone" }),
        submit: "password",
      },
      password: {
        text: "Google\nWelcome\nEnter your password\nShow password\nForgot password?\nNext",
        fields: [
          {
            name: "Enter your password",
            protected: opts.passwordProtected ?? true,
            bounds: PASSWORD_FIELD,
          },
        ],
        ...(opts.passwordFocused === true
          ? { focus: "Enter your password" }
          : {}),
        submit: {
          field: "Enter your password",
          equals: SENTINEL,
          then: "inbox",
          else: "wrong",
        },
      },
      inbox: { text: "Gmail\nCompose\nInbox 2\nStarred\nSent" },
      wrong: {
        text: "Google\nWelcome\nEnter your password\nWrong password. Try again or click Forgot password to reset it.",
        fields: [
          {
            name: "Enter your password",
            protected: true,
            bounds: PASSWORD_FIELD,
          },
        ],
      },
      ...after,
    },
  };
}

function outlookScenario(): StandinScenario {
  return {
    start: "address",
    screens: {
      address: {
        text: "Microsoft\nSign in\nEmail, phone, or Skype\nNo account? Create one!\nNext",
        fields: [{ name: "Email, phone, or Skype", bounds: ADDRESS_FIELD }],
        focus: "Email, phone, or Skype",
        submit: "code-first",
      },
      "code-first": {
        text: "Microsoft\nGet a code to sign in\nWe'll send a code to qa\nSend code\nOther ways to sign in\nUse your password",
        buttons: [
          {
            name: "Use your password",
            role: "link",
            bounds: [100, 400, 200, 30],
            next: "password",
          },
        ],
      },
      password: {
        text: "Microsoft\nEnter password\nForgot your password?\nSign in",
        fields: [{ name: "Password", protected: true, bounds: PASSWORD_FIELD }],
        focus: "Password",
        submit: {
          field: "Password",
          equals: SENTINEL,
          then: "stay",
          else: "address",
        },
      },
      stay: {
        text: "Microsoft\nStay signed in?\nDon't show this again\nNo\nYes",
        buttons: [
          { name: "No", bounds: [100, 500, 100, 30], next: "inbox" },
          { name: "Yes", bounds: [300, 500, 100, 30], next: "inbox" },
        ],
      },
      inbox: { text: "Outlook\nNew mail\nInbox\nFocused\nOther" },
    },
  };
}

let runs = 0;
interface Harness {
  dir: string;
  ga: GuiAssert;
  log: () => StandinLogEntry[];
  calls: string[];
  ctx: (p: ProviderSignin, over?: Partial<SigninContext>) => SigninContext;
}

function harness(scenario: StandinScenario): Harness {
  const dir = join(scratch, `run${runs++}`);
  const state = join(dir, "state");
  mkdirSync(join(dir, "frames"), { recursive: true });
  mkdirSync(state);
  writeFileSync(join(dir, "scenario.json"), JSON.stringify(scenario));
  const ga = new GuiAssert({
    bin: gaBin,
    stateDir: state,
    env: {
      ...process.env,
      GUIASSERT_STANDIN_SCENARIO: join(dir, "scenario.json"),
    },
    session: "s1",
  });
  const calls: string[] = [];
  const log = (): StandinLogEntry[] => {
    const f = join(state, "standin-log.jsonl");
    return existsSync(f)
      ? readFileSync(f, "utf8")
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((l) => JSON.parse(l) as StandinLogEntry)
      : [];
  };
  return {
    dir,
    ga,
    log,
    calls,
    ctx: (p, over = {}) => ({
      ga,
      provider: p,
      browserPid: 4242,
      address: ADDRESS,
      password: new Secret(SENTINEL),
      framesDir: join(dir, "frames"),
      keepPath: join(dir, "kept.png"),
      timings: {
        pollMs: 5,
        unknownMs: 400,
        stuckMs: 400,
        deadlineMs: 180_000,
        focusSettleMs: 0,
      },
      onFirstInput: () => {
        calls.push(
          `first-input after ${log().filter((e) => e.verb === "type" || e.verb === "key").length} keystroke calls`,
        );
      },
      onBeforePassword: () => {
        calls.push(
          `before-password after ${log().filter((e) => e.verb === "type" && e.stdin === SENTINEL).length} password calls`,
        );
      },
      log: () => undefined,
      ...over,
    }),
  };
}

/** Every place the sentinel went, as "verb:where". */
function sentinelPlaces(entries: StandinLogEntry[]): string[] {
  const out: string[] = [];
  for (const e of entries) {
    if (e.argv.some((a) => a.includes(SENTINEL))) out.push(`${e.verb}:argv`);
    if (Object.values(e.env).some((v) => v.includes(SENTINEL)))
      out.push(`${e.verb}:env`);
    if (e.stdin !== null && e.stdin.includes(SENTINEL))
      out.push(`${e.verb}:stdin`);
  }
  return out;
}

function assertSecretOnlyOnItsPipes(entries: StandinLogEntry[]): void {
  for (const e of entries) {
    assert.ok(!e.argv.some((a) => a.includes(SENTINEL)), `${e.verb} argv`);
    assert.ok(
      !Object.values(e.env).some((v) => v.includes(SENTINEL)),
      `${e.verb} env`,
    );
    if (e.stdin !== null && e.stdin.includes(SENTINEL)) {
      if (e.verb === "type") {
        assert.equal(e.stdin, SENTINEL);
        assert.ok(e.argv.includes("--stdin"));
      } else {
        assert.ok(["ocr", "screenshot"].includes(e.verb), e.verb);
        assert.ok(
          e.argv.includes("--secret-stdin"),
          `${e.verb} without its guard`,
        );
      }
    }
  }
  // Every OCR read and every screenshot is guarded.
  for (const e of entries.filter(
    (x) => x.verb === "ocr" || x.verb === "screenshot",
  ))
    assert.equal(
      e.stdin,
      SENTINEL,
      `${e.verb} without the password on its guard`,
    );
}

const typed = (entries: StandinLogEntry[]) =>
  entries
    .filter((e) => e.verb === "type")
    .map((e) => ({
      screen: e.screen,
      focused: e.focused,
      secret: e.stdin === SENTINEL,
      text: e.stdin === SENTINEL ? "" : e.stdin,
    }));

describe("a Secret", () => {
  it("prints as [secret] however it is formatted by accident, and gives its value only when asked", () => {
    const s = new Secret(SENTINEL);
    assert.equal(String(s), "[secret]");
    assert.equal(`${s}`, "[secret]");
    assert.equal(JSON.stringify({ s }), '{"s":"[secret]"}');
    assert.equal(inspect(s), "[secret]");
    assert.equal(inspect({ s }), "{ s: [secret] }");
    assert.equal(s.reveal(), SENTINEL);
    assert.equal(s.length, SENTINEL.length);
  });
});

describe("the automated sign-in procedure", () => {
  it("signs in to Gmail: the address into its field, the password once into the protected field it clicked into", async () => {
    const h = harness(gmailScenario());
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, { result: "signed-in", typed: true });
    assert.deepEqual(r.steps, ["address", "password"]);
    assert.equal(r.screen, null);
    const log = h.log();
    assert.deepEqual(typed(log), [
      {
        screen: "address",
        focused: "Email or phone",
        secret: false,
        text: ADDRESS,
      },
      {
        screen: "password",
        focused: "Enter your password",
        secret: true,
        text: "",
      },
    ]);
    // The password field had no focus: one click into it, at its centre.
    const clicks = log.filter((e) => e.verb === "click");
    assert.equal(clicks.length, 1);
    assert.ok(clicks[0]!.argv.includes("300,280"), clicks[0]!.argv.join(" "));
    assertSecretOnlyOnItsPipes(log);
    // Recorded before the first keystroke, marked before the password.
    assert.deepEqual(h.calls, [
      "first-input after 0 keystroke calls",
      "before-password after 0 password calls",
    ]);
    // No frame is left behind.
    assert.deepEqual(readdirSync(join(h.dir, "frames")), []);
  });

  it("clicks into an address field the page did not focus before typing", async () => {
    const h = harness(
      gmailScenario({}, { addressFocused: false, passwordFocused: true }),
    );
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.equal(r.outcome.result, "signed-in");
    const log = h.log();
    const firstType = log.findIndex((e) => e.verb === "type");
    const click = log.findIndex((e) => e.verb === "click");
    assert.ok(click >= 0 && click < firstType);
    assert.equal(typed(log)[0]!.focused, "Email or phone");
  });

  it("never types into the browser's own address bar, even when it has the focus", async () => {
    const s = gmailScenario();
    s.screens.address!.fields = [
      { name: "Address and search bar", bounds: [0, 20, 1280, 30] },
      { name: "Email or phone", bounds: ADDRESS_FIELD },
    ];
    s.screens.address!.focus = "Address and search bar";
    const h = harness(s);
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.equal(r.outcome.result, "signed-in");
    const t = typed(h.log());
    assert.deepEqual(
      t.map((x) => x.focused),
      ["Email or phone", "Enter your password"],
    );
  });

  it("signs in to Outlook.com through 'Use your password' and 'Stay signed in?'", async () => {
    const h = harness(outlookScenario());
    const r = await driveSignin(h.ctx(OUTLOOK_SIGNIN));
    assert.deepEqual(r.outcome, { result: "signed-in", typed: true });
    assert.deepEqual(r.steps, [
      "address",
      "choose-password",
      "password",
      "stay-signed-in",
    ]);
    const log = h.log();
    assert.equal(typed(log).filter((t) => t.secret).length, 1);
    // "Yes", not "No".
    const lastClick = log.filter((e) => e.verb === "click").pop()!;
    assert.ok(lastClick.argv.includes("350,515"), lastClick.argv.join(" "));
    assertSecretOnlyOnItsPipes(log);
  });

  it("types nothing into a profile that is still signed in, and records no attempt", async () => {
    const h = harness({
      start: "inbox",
      screens: { inbox: { text: "Compose\nInbox" } },
    });
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, { result: "signed-in", typed: false });
    assert.deepEqual(h.calls, []);
    assert.deepEqual(
      h.log().filter((e) => ["type", "key", "click"].includes(e.verb)),
      [],
    );
  });

  it("never types the password into a field that is not protected", async () => {
    const h = harness(
      gmailScenario({}, { passwordProtected: false, passwordFocused: true }),
    );
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, {
      result: "field-not-found",
      step: "password",
    });
    assert.equal(typed(h.log()).filter((t) => t.secret).length, 0);
    assert.deepEqual(h.calls, ["first-input after 0 keystroke calls"]);
  });

  it("stops at a challenge with no input after it, keeping a screenshot without the password", async () => {
    const challenge = {
      text: "Google\nVerify it's you\nTo help keep your account safe, Google wants to make sure it's really you\nTry another way",
      fields: [
        {
          name: "Enter code",
          bounds: [100, 300, 200, 40] as [number, number, number, number],
        },
      ],
      focus: "Enter code",
    };
    const s = gmailScenario({ challenge });
    (s.screens.password!.submit as { then: string }).then = "challenge";
    const h = harness(s);
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, {
      result: "challenged",
      challenge: "verify-identity",
      phrase: "verify it's you",
    });
    assert.equal(r.screen, join(h.dir, "kept.png"));
    const kept = readFileSync(r.screen!, "utf8");
    assert.match(kept, /Verify it's you/);
    assert.ok(!kept.includes(SENTINEL));
    const log = h.log();
    const atChallenge = log.findIndex((e) => e.screen === "challenge");
    assert.deepEqual(
      log
        .slice(atChallenge)
        .filter((e) => ["type", "key", "click"].includes(e.verb)),
      [],
      "no input once the challenge showed",
    );
    assertSecretOnlyOnItsPipes(log);
  });

  it("stops at a wrong password without typing it again", async () => {
    const h = harness(gmailScenario());
    const r = await driveSignin({
      ...h.ctx(GMAIL_SIGNIN),
      password: new Secret(`${SENTINEL}-x`),
    });
    assert.deepEqual(r.outcome, {
      result: "wrong-password",
      phrase: "wrong password",
    });
    assert.equal(
      h.log().filter((e) => e.verb === "type" && e.screen === "password")
        .length,
      1,
    );
    assert.ok(r.screen !== null);
  });

  it("ends as stuck when the password screen stays after its step, typing the password once", async () => {
    const s = gmailScenario();
    s.screens.password!.submit = "password";
    const h = harness(s);
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, { result: "stuck", step: "password" });
    assert.equal(typed(h.log()).filter((t) => t.secret).length, 1);
  });

  it("does not guess at an unknown screen, and gives up on it without input", async () => {
    const h = harness({
      start: "x",
      screens: { x: { text: "Something else entirely" } },
    });
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, { result: "unknown-screen" });
    assert.deepEqual(
      h.log().filter((e) => ["type", "key", "click"].includes(e.verb)),
      [],
    );
    assert.ok(r.screen !== null);
  });

  it("stops at the deadline", async () => {
    // A screen that alternates would never be unknown or stuck for long.
    const h = harness({ start: "x", screens: { x: { text: "Loading" } } });
    const r = await driveSignin({
      ...h.ctx(GMAIL_SIGNIN),
      timings: {
        pollMs: 5,
        unknownMs: 60_000,
        stuckMs: 60_000,
        deadlineMs: 300,
        focusSettleMs: 0,
      },
    });
    assert.deepEqual(r.outcome, { result: "deadline" });
  });

  it("stops at once, keeping no frame, when the password is legible on the screen", async () => {
    const s = gmailScenario();
    s.screens.password!.revealPassword = true;
    s.screens.password!.submit = "password";
    const h = harness(s);
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, { result: "secret-visible" });
    assert.equal(r.screen, null);
    assert.ok(!existsSync(join(h.dir, "kept.png")));
    assert.deepEqual(readdirSync(join(h.dir, "frames")), []);
    // Nothing was typed after the read that saw it.
    const log = h.log();
    const lastOcr = log.map((e) => e.verb).lastIndexOf("ocr");
    assert.deepEqual(
      log
        .slice(lastOcr + 1)
        .filter((e) => ["type", "key", "click"].includes(e.verb)),
      [],
    );
  });

  // The check after a sign-in: the mailbox read off the screen, nothing
  // typed, clicked or pressed.
  const verifyCtx = (h: Harness, over: Partial<VerifyContext> = {}) => ({
    ga: h.ga,
    provider: GMAIL_SIGNIN,
    password: new Secret(SENTINEL),
    framesDir: join(h.dir, "frames"),
    timeoutMs: 5000,
    settleMs: 100,
    pollMs: 5,
    log: () => undefined,
    ...over,
  });
  const noInput = (log: StandinLogEntry[]) =>
    assert.deepEqual(
      log.filter((e) => ["type", "key", "click"].includes(e.verb)),
      [],
    );

  it("checks a signed-in profile by its mailbox on the screen, with no input, every frame guarded", async () => {
    const s = gmailScenario();
    s.start = "inbox";
    const h = harness(s);
    assert.deepEqual(await verifySignedIn(verifyCtx(h)), { signedIn: true });
    const log = h.log();
    noInput(log);
    assert.ok(log.some((e) => e.verb === "ocr"));
    assertSecretOnlyOnItsPipes(log);
    assert.deepEqual(readdirSync(join(h.dir, "frames")), []);
  });

  it("reports a profile sent to the sign-in as not signed in, naming the screen, and types nothing into it", async () => {
    const h = harness(gmailScenario());
    const r = await verifySignedIn(verifyCtx(h));
    assert.equal(r.signedIn, false);
    assert.ok(!r.signedIn);
    assert.match(
      r.reason,
      /^the inbox URL showed the address screen of the sign-in, not the mailbox: the profile is not signed in$/,
    );
    // It waited for the screen to settle (more than one read).
    const log = h.log();
    assert.ok(log.filter((e) => e.verb === "ocr").length > 1);
    noInput(log);
  });

  it("reports a challenge on the inbox URL, and a screen that never becomes the mailbox, as not signed in", async () => {
    const s = gmailScenario({
      verify: { text: "Google\nVerify it's you\nTry another way" },
    });
    s.start = "verify";
    const h1 = harness(s);
    const r1 = await verifySignedIn(verifyCtx(h1));
    assert.ok(!r1.signedIn);
    assert.match(
      r1.reason,
      /a challenge \(verify-identity: "verify it's you"\)/,
    );
    noInput(h1.log());
    const s2 = gmailScenario({ loading: { text: "Loading" } });
    s2.start = "loading";
    const h2 = harness(s2);
    const r2 = await verifySignedIn(verifyCtx(h2, { timeoutMs: 200 }));
    assert.ok(!r2.signedIn);
    assert.match(r2.reason, /^the mailbox did not show within 0 s$/);
    noInput(h2.log());
  });

  it("keeps the sentinel off every argv and environment across all of the above", () => {
    // A cross-check over every log written by the tests above.
    for (const d of readdirSync(scratch).filter((x) => x.startsWith("run"))) {
      const f = join(scratch, d, "state", "standin-log.jsonl");
      if (!existsSync(f)) continue;
      const entries = readFileSync(f, "utf8")
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l) as StandinLogEntry);
      for (const p of sentinelPlaces(entries))
        assert.ok(p.endsWith(":stdin"), `${d}: ${p}`);
    }
  });
});

// ---------------------------------------------------------------------------
// The command line
// ---------------------------------------------------------------------------

describe("email-webmail-signin (the command line)", () => {
  // A stand-in webmail browser where the dev shell names the real one
  // (ISONIM_EMAIL_WEBMAIL_BROWSER): it records its arguments and
  // environment and waits to be stopped.
  const browserLog = join(scratch, "browser-log");
  mkdirSync(browserLog);
  const browserExe = join(scratch, "webmail-browser");
  writeFileSync(
    browserExe,
    `#!/bin/sh\nprintf '%s\\n' "$@" > "${browserLog}/args.$$"\nenv > "${browserLog}/env.$$"\nexec sleep 600\n`,
    { mode: 0o755 },
  );

  const creds = join(scratch, "creds");
  mkdirSync(join(creds, "gmail-workspace"), { recursive: true, mode: 0o700 });
  chmodSync(creds, 0o700);
  writeFileSync(
    join(creds, "gmail-workspace", "qa1.json"),
    JSON.stringify({
      schema: CREDENTIALS_SCHEMA,
      address: ADDRESS,
      password: SENTINEL,
    }),
    { mode: 0o600 },
  );

  let cliRuns = 0;
  function cliEnv(scenario: StandinScenario): {
    env: NodeJS.ProcessEnv;
    profiles: string;
    state: string;
  } {
    const dir = join(scratch, `cli${cliRuns++}`);
    mkdirSync(dir);
    writeFileSync(join(dir, "scenario.json"), JSON.stringify(scenario));
    const profiles = join(scratch, "cli-profiles");
    return {
      env: {
        ...process.env,
        PATH: `${binDir}:${process.env.PATH ?? ""}`,
        ISONIM_EMAIL_WEBMAIL_BROWSER: browserExe,
        ISONIM_EMAIL_WEBMAIL_BROWSER_LABEL: "Stand-in Browser 1.0",
        ISONIM_EMAIL_CREDENTIALS_DIR: creds,
        ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: profiles,
        GUIASSERT_STANDIN_SCENARIO: join(dir, "scenario.json"),
      },
      profiles,
      state: join(profiles, ".guiassert-state"),
    };
  }
  const profile = () =>
    accountProfile(
      {
        env: {
          ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: join(scratch, "cli-profiles"),
        },
        platform: "linux",
      },
      "gmail-workspace",
      "gmail-workspace/qa1.json",
    );
  const readLog = (state: string): StandinLogEntry[] =>
    readFileSync(join(state, "standin-log.jsonl"), "utf8")
      .trim()
      .split("\n")
      .map((l) => JSON.parse(l) as StandinLogEntry);
  const resetDesktop = (state: string): void => {
    rmSync(join(state, "standin-state.json"), { force: true });
    rmSync(join(state, "standin-log.jsonl"), { force: true });
  };
  const browserArgs = (): string[][] =>
    readdirSync(browserLog)
      .filter((f) => f.startsWith("args."))
      .map((f) => readFileSync(join(browserLog, f), "utf8").trim().split("\n"));
  const browserEnvs = (): string[] =>
    readdirSync(browserLog)
      .filter((f) => f.startsWith("env."))
      .map((f) => readFileSync(join(browserLog, f), "utf8"));
  const run = (env: NodeJS.ProcessEnv, ...args: string[]) =>
    spawnSync(process.execPath, [signinCli, "gmail-workspace", ...args], {
      env,
      encoding: "utf8",
      timeout: 120_000,
    });

  const challengeScenario = (): StandinScenario => {
    const s = gmailScenario({
      captcha: {
        text: "Google\nConfirm you're not a robot\nType the text you hear or see",
      },
    });
    (s.screens.password!.submit as { then: string }).then = "captcha";
    return s;
  };

  it("stops at a challenge (exit 5), never retries it, and refuses a second attempt in the cool-down before starting anything", () => {
    const c = cliEnv(challengeScenario());
    const first = run(c.env, "--unsafe-no-sandbox");
    assert.equal(first.status, 5, first.stdout + first.stderr);
    assert.match(
      first.stdout,
      /CHALLENGED \(captcha\): gmail-workspace\/qa1: "not a robot" .* Not retried\./,
    );
    assert.match(
      first.stdout,
      /the next automated attempt is allowed from \d{4}-/,
    );
    for (const out of [first.stdout, first.stderr]) {
      assert.ok(!out.includes(SENTINEL), "the password in the output");
      assert.ok(!out.includes(ADDRESS), "the address in the output");
    }
    const log = readLog(c.state);
    assertSecretOnlyOnItsPipes(log);
    assert.equal(
      log.filter((e) => e.verb === "type" && e.stdin === SENTINEL).length,
      1,
    );
    assert.deepEqual(
      log.map((e) => e.verb).filter((v) => v.startsWith("session")),
      ["session-start", "session-stop"],
    );
    // The record: finished, the challenge named, no secret.
    const rec = readFileSync(attemptPath(profile()), "utf8");
    assert.ok(!rec.includes(SENTINEL));
    const a = readAttempt(profile());
    assert.ok(a.kind === "record");
    assert.equal(a.record.state, "finished");
    assert.equal(a.record.result, "challenged:captcha");
    // The kept screenshot shows the challenge, not the password.
    const kept = join(profile().dir, "signin-screen.png");
    assert.match(readFileSync(kept, "utf8"), /not a robot/);
    assert.ok(!readFileSync(kept, "utf8").includes(SENTINEL));
    // The browser: the profile, the session's display, accessibility, no
    // automation switch, no secret.
    const args = browserArgs();
    assert.equal(args.length, 1);
    const argv = args[0]!;
    assert.ok(argv.includes(`--user-data-dir=${profile().userDataDir}`));
    assert.ok(argv.includes("--force-renderer-accessibility"));
    assert.equal(argv.at(-1), GMAIL_SIGNIN.startUrl);
    for (const a2 of argv) {
      assert.ok(!AUTOMATION_SWITCHES.some((re) => re.test(a2)), a2);
      assert.ok(!a2.includes(SENTINEL));
    }
    const env = browserEnvs()[0]!;
    assert.match(env, /^DISPLAY=:standin$/m);
    assert.ok(!env.includes(SENTINEL));

    // Again, at once: refused before a session or a browser starts.
    resetDesktop(c.state);
    const second = run(c.env, "--unsafe-no-sandbox");
    assert.equal(second.status, 6, second.stdout + second.stderr);
    assert.match(
      second.stdout,
      /REFUSED: gmail-workspace\/qa1: the last automated attempt started .* and ended challenged:captcha; one attempt per 24 h\. The next automated attempt is allowed from /,
    );
    assert.ok(
      !existsSync(join(c.state, "standin-log.jsonl")),
      "no GuiAssert call at all",
    );
    assert.equal(browserArgs().length, 1, "no second browser");
  });

  it("lets the operator's --override-cooldown through, and records that it did", () => {
    const c = cliEnv(challengeScenario());
    resetDesktop(c.state);
    const r = run(c.env, "--unsafe-no-sandbox", "--override-cooldown");
    assert.equal(r.status, 5, r.stdout + r.stderr);
    assert.match(
      r.stdout,
      /WARNING: gmail-workspace\/qa1: --override-cooldown: attempting within the cool-down/,
    );
    const a = readAttempt(profile());
    assert.ok(a.kind === "record" && a.record.override === true);
    assert.equal(browserArgs().length, 2);
  });

  it("on SIGTERM mid-attempt stops the browser and the session and closes the record; a run killed outright still counts", async () => {
    // After the address, a page that never resolves: the run waits.
    const s = gmailScenario({ loading: { text: "Loading" } });
    s.screens.address!.submit = "loading";
    for (const how of ["SIGTERM", "SIGKILL"] as const) {
      rmSync(attemptPath(profile()), { force: true });
      const c = cliEnv(s);
      resetDesktop(c.state);
      const before = new Set(readdirSync(browserLog));
      const child = spawn(
        process.execPath,
        [signinCli, "gmail-workspace", "--unsafe-no-sandbox"],
        {
          env: c.env,
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      let out = "";
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (d: string) => (out += d));
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (d: string) => (out += d));
      const deadline = Date.now() + 60_000;
      while (!/typed the address/.test(out) && Date.now() < deadline)
        await sleep(100);
      assert.match(out, /typed the address/);
      const exited = new Promise<number | null>((r) =>
        child.on("exit", (code) => r(code)),
      );
      child.kill(how);
      const code = await exited;
      const pid = [...readdirSync(browserLog)]
        .find((f) => !before.has(f) && f.startsWith("args."))!
        .slice(5);
      const a = readAttempt(profile());
      assert.ok(a.kind === "record");
      if (how === "SIGTERM") {
        assert.equal(code, 143);
        assert.equal(a.record.state, "finished");
        assert.equal(a.record.result, "interrupted");
        assert.ok(readLog(c.state).some((e) => e.verb === "session-stop"));
        // The browser was stopped.
        await sleep(500);
        assert.throws(() => process.kill(Number(pid), 0));
      } else {
        // Nothing could run: the record says the attempt started.
        assert.equal(a.record.state, "started");
        try {
          process.kill(Number(pid), "SIGKILL");
        } catch {
          /* gone already */
        }
        resetDesktop(c.state);
        const next = run(c.env, "--unsafe-no-sandbox");
        assert.equal(next.status, 6, next.stdout);
        assert.match(
          next.stdout,
          /never finished \(state started: the run stopped mid-attempt\)/,
        );
      }
      assert.ok(!out.includes(SENTINEL));
    }
  });

  it("signs in, then checks the mailbox in the same browser started again (no Playwright, no input), and records it; --check-only types nothing", () => {
    rmSync(attemptPath(profile()), { force: true });
    rmSync(profile().record, { force: true });
    const c = cliEnv(gmailScenario());
    resetDesktop(c.state);
    // Playwright cannot run (no browser trees for its driver): the check
    // must not need it.
    const env = {
      ...c.env,
      PLAYWRIGHT_BROWSERS_PATH: join(scratch, "no-playwright-browsers"),
    };
    const before = browserArgs().length;
    const r = run(env, "--unsafe-no-sandbox", "--timeout", "10");
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /check: the mailbox shows/);
    assert.match(
      r.stdout,
      /SIGNED IN: gmail-workspace\/qa1 on mail\.google\.com/,
    );
    for (const out of [r.stdout, r.stderr]) assert.ok(!out.includes(SENTINEL));
    // Two browsers, both the webmail browser without automation: the
    // sign-in's at the start URL, then the check's at the inbox URL.
    const launches = browserArgs().slice(before);
    assert.equal(launches.length, 2);
    assert.equal(launches[0]!.at(-1), GMAIL_SIGNIN.startUrl);
    assert.equal(
      launches[1]!.at(-1),
      WEBMAIL_SIGNIN["gmail-workspace"]!.inboxUrl,
    );
    for (const argv of launches)
      for (const a2 of argv) {
        assert.ok(!AUTOMATION_SWITCHES.some((re) => re.test(a2)), a2);
        assert.ok(!a2.includes(SENTINEL));
      }
    const log = readLog(c.state);
    assertSecretOnlyOnItsPipes(log);
    assert.equal(
      log.filter((e) => e.verb === "type" && e.stdin === SENTINEL).length,
      1,
    );
    const rec = readSigninRecord(profile());
    assert.ok(rec !== null);
    assert.equal(rec.verified_by, "ocr");
    assert.equal(rec.host, "mail.google.com");
    assert.match(rec.browser, /^Stand-in Browser 1\.0 \(/);
    assert.ok(!readFileSync(profile().record, "utf8").includes(SENTINEL));
    const a = readAttempt(profile());
    assert.ok(a.kind === "record");
    assert.equal(a.record.result, "signed-in");

    // --check-only on a profile the provider sends to its sign-in: not
    // signed in (exit 1), with no input of any kind and no attempt.
    rmSync(attemptPath(profile()), { force: true });
    const c2 = cliEnv(gmailScenario());
    resetDesktop(c2.state);
    const chk = run(
      c2.env,
      "--check-only",
      "--unsafe-no-sandbox",
      "--timeout",
      "20",
    );
    assert.equal(chk.status, 1, chk.stdout + chk.stderr);
    assert.match(
      chk.stdout,
      /NOT SIGNED IN: gmail-workspace\/qa1: the inbox URL showed the address screen of the sign-in/,
    );
    assert.deepEqual(
      readLog(c2.state).filter((e) =>
        ["type", "key", "click"].includes(e.verb),
      ),
      [],
    );
    assert.equal(readAttempt(profile()).kind, "none");
  });

  it("says what is missing: no GuiAssert (4), no account file (3), a bad invocation (2)", () => {
    const c = cliEnv(challengeScenario());
    const noGa = spawnSync(process.execPath, [signinCli, "gmail-workspace"], {
      env: { ...c.env, PATH: dirname(process.execPath) },
      encoding: "utf8",
    });
    assert.equal(noGa.status, 4, noGa.stdout + noGa.stderr);
    assert.match(noGa.stdout, /no guiassert on PATH/);
    const pending = spawnSync(process.execPath, [signinCli, "yahoo"], {
      env: c.env,
      encoding: "utf8",
    });
    assert.equal(pending.status, 3, pending.stdout + pending.stderr);
    assert.match(pending.stdout, /PENDING: no account file for yahoo/);
    for (const bad of [
      ["nope"],
      ["gmail-workspace", "--manual", "--check-only"],
      ["gmail-workspace", "--check-only", "--override-cooldown"],
      ["gmail-workspace", "--bogus"],
    ]) {
      const r = spawnSync(process.execPath, [signinCli, ...bad], {
        env: c.env,
        encoding: "utf8",
      });
      assert.equal(r.status, 2, bad.join(" "));
    }
  });
});
