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
//   signed-out profile exits 1 with no input and no attempt;
// - an account-setup interstitial after the password (Gmail's "Set a
//   home address") is dismissed by one click on its skip control and
//   nothing else: no keystroke into its field, never "Save"; without a
//   skip control the attempt stops (`field-not-found`), and one that
//   stays after its dismissal is `stuck`; the check reports one on the
//   inbox URL as not the mailbox, with no input;
// - a privacy-consent page (Yahoo's, in Bulgarian, recognised by the
//   address the browser reports) is answered by clicking every row's
//   reject choice (scrolling to the ones off the screen) and then its
//   continue control, or its reject-all control; an allow or accept
//   control is never clicked; a choice it cannot name, a check box or
//   switch, or a page that stays, ends the attempt `consent-required`
//   with no further input;
// - Google's password re-verification is answered once, as the attempt's
//   input, and asked again after the password it is a challenge; the
//   check reports it, and a consent page, as not signed in with no input;
// - Chrome's own sign-in bubble is closed once through its "Use Chrome
//   without an account" button, which is not an input to the provider;
// - the check keeps its screen (check-screen.png, 0600) when it finds no
//   mailbox and names the screen, and removes an older one when it does;
// - the kept screenshot is 0600 whatever the umask;
// - the command line writes the profile's preferences (the password
//   manager and the sign-in interception off, Chrome's sign-in on, the
//   rest of the file kept) before every browser start; a profile holding
//   a saved password fails the run (exit 8) whatever its result; a
//   consent page it cannot answer exits 5; a run that ends before any
//   input records no attempt and says so; a wrong password names the
//   re-sealing runbook step;
//   `--typing-check` types the password into a loopback page (a stand-in
//   browser that answers as the real page does) and prints only MATCH or
//   MISMATCH, with no attempt, no lease and a throw-away profile.
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
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { inspect } from "node:util";
import { GuiAssert, Secret } from "./guiassert.ts";
import type { StandinLogEntry, StandinScenario } from "./guiassert_standin.ts";
import { CREDENTIALS_SCHEMA } from "./requirements.ts";
import { DatabaseSync } from "node:sqlite";
import {
  accountProfile,
  readSigninRecord,
  WEBMAIL_PROFILE_PREFS,
  WEBMAIL_SIGNIN,
} from "./webmail_profiles.ts";
import {
  AUTOMATION_SWITCHES,
  CONSENT_MAX_PROCEED,
  consentChoice,
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
  YAHOO_SIGNIN,
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

  // Gmail's account-setup screen after the password, as measured on
  // 2026-10-28: a focused "Home address" field, "Skip" (a link) and
  // "Save".
  const homeAddress = (
    buttons: { name: string; role?: string; next: string }[],
  ): StandinScenario["screens"][string] => ({
    text: "Google\nSet a home address\nYour home and work addresses are used to personalize your experiences across Google products\nHome address\nSkip\nSave",
    fields: [{ name: "Home address", bounds: ADDRESS_FIELD }],
    focus: "Home address",
    buttons: buttons.map((b, i) => ({
      ...b,
      bounds: [300 + 200 * i, 600, 80, 30] as [number, number, number, number],
    })),
  });
  const afterPassword = (
    h: Harness,
  ): { inputs: StandinLogEntry[]; clicks: string[] } => {
    const log = h.log();
    const at = log.findIndex((e) => e.screen === "homeaddress");
    const inputs = log
      .slice(at)
      .filter((e) => ["type", "key", "click"].includes(e.verb));
    return {
      inputs,
      clicks: inputs
        .filter((e) => e.verb === "click")
        .map((e) => e.argv[e.argv.indexOf("--at") + 1]!),
    };
  };
  const withInterstitial = (
    buttons: { name: string; role?: string; next: string }[],
  ): StandinScenario => {
    const s = gmailScenario({ homeaddress: homeAddress(buttons) });
    (s.screens.password!.submit as { then: string }).then = "homeaddress";
    return s;
  };

  it("dismisses an account-setup screen after the password with its skip control only, then reaches the mailbox", async () => {
    const h = harness(
      withInterstitial([
        { name: "Skip", role: "link", next: "inbox" },
        { name: "Save", next: "inbox" },
      ]),
    );
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, { result: "signed-in", typed: true });
    assert.deepEqual(r.steps, [
      "address",
      "password",
      "interstitial:home-address",
    ]);
    // One click, on "Skip" (300+40, 600+15); no keystroke into the
    // focused "Home address" field, no "Save".
    assert.deepEqual(
      afterPassword(h).inputs.map((e) => e.verb),
      ["click"],
    );
    assert.deepEqual(afterPassword(h).clicks, ["340,615"]);
    assert.equal(r.screen, null);
    assertSecretOnlyOnItsPipes(h.log());
  });

  it("prefers the first skip control in its order, and never clicks anything else", async () => {
    const h = harness(
      withInterstitial([
        { name: "Cancel", next: "inbox" },
        { name: "Not now", next: "inbox" },
        { name: "Continue", next: "inbox" },
      ]),
    );
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.equal(r.outcome.result, "signed-in");
    assert.deepEqual(afterPassword(h).clicks, ["540,615"]);
  });

  it("counts the click on an account-setup screen as the attempt's first input", async () => {
    const s = withInterstitial([{ name: "Skip", role: "link", next: "inbox" }]);
    s.start = "homeaddress";
    const h = harness(s);
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.equal(r.outcome.result, "signed-in");
    assert.deepEqual(r.steps, ["interstitial:home-address"]);
    assert.deepEqual(h.calls, ["first-input after 0 keystroke calls"]);
  });

  it("stops at an account-setup screen it cannot decline, with no input on it", async () => {
    const h = harness(
      withInterstitial([
        { name: "Save", next: "inbox" },
        { name: "Next", next: "inbox" },
      ]),
    );
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, {
      result: "field-not-found",
      step: "interstitial:home-address",
    });
    assert.deepEqual(afterPassword(h).inputs, []);
    assert.ok(r.screen !== null);
  });

  it("ends as stuck when an account-setup screen stays after its dismissal, clicking once", async () => {
    const h = harness(
      withInterstitial([{ name: "Skip", role: "link", next: "homeaddress" }]),
    );
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, {
      result: "stuck",
      step: "interstitial:home-address",
    });
    assert.deepEqual(afterPassword(h).clicks, ["340,615"]);
  });

  // Yahoo's privacy-consent page as measured on 2026-10-28 (in
  // Bulgarian): three rows of Reject/Allow radio buttons, the third off
  // the screen until the page is scrolled, a "Продължаване" (Continue)
  // button, and a decoy accept-all button.
  const CONSENT_URL =
    "consent.yahoo.com/mailbox/collectConsent?sessionId=3_cc-session_x";
  const R = (
    row: number,
    choice: "reject" | "allow",
    over: Partial<{
      name: string | null;
      below: number;
      checked: boolean;
    }> = {},
  ) => ({
    name: choice === "reject" ? "Отхвърляне" : "Разрешаване",
    group: `row${row}`,
    bounds: [choice === "reject" ? 840 : 940, 300 + row * 120, 20, 20] as [
      number,
      number,
      number,
      number,
    ],
    ...over,
  });
  const consentScenario = (
    over: Partial<StandinScenario["screens"][string]> = {},
  ): StandinScenario => ({
    start: "consent",
    screens: {
      consent: {
        text: `Welcome to Mail!\n${CONSENT_URL}\nyahoo!\nАктуализирайте настройките си за поверителност\nОтхвърляне Разрешаване\nПродължаване`,
        location: CONSENT_URL,
        radios: [
          R(0, "reject"),
          R(0, "allow", { checked: true }),
          R(1, "reject"),
          R(1, "allow"),
          R(2, "reject", { below: 1 }),
          R(2, "allow", { below: 1 }),
        ],
        buttons: [
          { name: "Продължаване", bounds: [560, 790, 200, 40], next: "inbox" },
          {
            name: "Приемане на всички",
            bounds: [100, 790, 200, 40],
            next: "accepted",
          },
        ],
        ...over,
      },
      inbox: { text: "Yahoo Mail\nCompose\nInbox\nUnread" },
      accepted: { text: "ACCEPTED: the decoy was clicked" },
    },
  });
  const inputs = (h: Harness) =>
    h
      .log()
      .filter((e) => ["type", "key", "click", "scroll"].includes(e.verb))
      .map((e) =>
        e.verb === "click"
          ? `click ${e.argv[e.argv.indexOf("--at") + 1]}`
          : e.verb,
      );

  it("names a consent row's choice only by a listed name, exactly or followed by words that do not name the other", () => {
    assert.equal(consentChoice("Отхвърляне"), "reject");
    assert.equal(consentChoice("Reject"), "reject");
    assert.equal(consentChoice("Allow"), "allow");
    assert.equal(consentChoice("Разрешаване"), "allow");
    assert.equal(consentChoice("Reject personalised ads"), "reject");
    assert.equal(consentChoice("Reject or Allow"), null);
    assert.equal(consentChoice("Decline"), null);
    assert.equal(consentChoice("Rejected"), null);
    assert.equal(consentChoice(null), null);
  });

  it("answers Yahoo's consent page in Bulgarian by rejecting every row (scrolling to the last), then 'Продължаване', never an allow or accept control", async () => {
    const h = harness(consentScenario());
    const r = await driveSignin(h.ctx(YAHOO_SIGNIN));
    assert.deepEqual(r.outcome, { result: "signed-in", typed: true });
    assert.deepEqual(r.steps, ["consent:yahoo-consent"]);
    // The two reject choices on the screen, the wheel, the third, then
    // the continue control: no allow choice (940,…), no accept-all.
    assert.deepEqual(inputs(h), [
      "click 850,310",
      "click 850,430",
      "scroll",
      "click 850,550",
      "click 660,810",
    ]);
    // The first click was announced as the attempt's first input.
    assert.deepEqual(h.calls, ["first-input after 0 keystroke calls"]);
    // The page's address was read from the browser's address bar.
    assert.ok(
      h
        .log()
        .some(
          (e) => e.verb === "find" && e.argv.includes("Address and search bar"),
        ),
    );
    assertSecretOnlyOnItsPipes(h.log());
  });

  it("prefers a reject-all control when the page has one, and clicks nothing else", async () => {
    const h = harness(
      consentScenario({
        radios: [],
        buttons: [
          {
            name: "Приемане на всички",
            bounds: [100, 790, 200, 40],
            next: "accepted",
          },
          {
            name: "Отхвърляне на всички",
            bounds: [400, 790, 200, 40],
            next: "inbox",
          },
        ],
      }),
    );
    const r = await driveSignin(h.ctx(YAHOO_SIGNIN));
    assert.deepEqual(r.outcome, { result: "signed-in", typed: true });
    assert.deepEqual(inputs(h), ["click 500,810"]);
  });

  it("stops consent-required, with no input, at a choice it cannot name, and at unequal pairs", async () => {
    for (const radios of [
      [R(0, "reject", { name: "Decline" }), R(0, "allow")],
      [R(0, "reject"), R(0, "allow"), R(1, "reject")],
      [],
    ]) {
      const h = harness(
        consentScenario({
          radios,
          buttons: [
            {
              name: "Продължаване",
              bounds: [560, 790, 200, 40],
              next: "inbox",
            },
          ],
        }),
      );
      const r = await driveSignin(h.ctx(YAHOO_SIGNIN));
      assert.equal(
        r.outcome.result,
        "consent-required",
        JSON.stringify(radios),
      );
      assert.ok(r.outcome.result === "consent-required");
      assert.equal(r.outcome.consent, "yahoo-consent");
      assert.deepEqual(inputs(h), [], JSON.stringify(radios));
      assert.deepEqual(h.calls, []);
      assert.ok(r.screen !== null);
    }
  });

  it("stops consent-required, with no input, at a check box or switch on the consent page, whatever its name", async () => {
    for (const name of ["Отхвърляне", "Personalised ads"]) {
      const s = consentScenario();
      s.screens.consent!.buttons!.push({
        role: "checkbox",
        name,
        bounds: [840, 700, 20, 20],
        next: "consent",
      });
      const h = harness(s);
      const r = await driveSignin(h.ctx(YAHOO_SIGNIN));
      assert.equal(r.outcome.result, "consent-required", name);
      assert.ok(r.outcome.result === "consent-required");
      assert.match(r.outcome.why, /a check box or switch named/);
      assert.deepEqual(inputs(h), [], name);
      assert.deepEqual(h.calls, []);
    }
  });

  it("gives up consent-required when the page stays after its continue control, clicking it a bounded number of times", async () => {
    const s = consentScenario();
    s.screens.consent!.buttons![0]!.next = "consent";
    const h = harness(s);
    const r = await driveSignin(h.ctx(YAHOO_SIGNIN));
    assert.equal(r.outcome.result, "consent-required");
    assert.ok(r.outcome.result === "consent-required");
    assert.match(r.outcome.why, /after "Продължаване" 3 times/);
    assert.equal(
      inputs(h).filter((x) => x === "click 660,810").length,
      CONSENT_MAX_PROCEED,
    );
    assert.ok(!inputs(h).includes("click 200,810"));
  });

  it("does not take a page for the consent page when the browser's address says otherwise", async () => {
    const h = harness(
      consentScenario({ location: "mail.yahoo.com/d/folders/1" }),
    );
    const r = await driveSignin(h.ctx(YAHOO_SIGNIN));
    assert.deepEqual(r.outcome, { result: "unknown-screen" });
    assert.deepEqual(inputs(h), []);
  });

  it("answers Google's password re-verification once, as the attempt's input, and reaches the mailbox", async () => {
    const s = gmailScenario({
      reauth: {
        text: "Google\nVerify it's you\nqa.tester@example.com\nEnter your password\nTry another way\nNext",
        fields: [
          {
            name: "Enter your password",
            protected: true,
            bounds: PASSWORD_FIELD,
          },
        ],
        focus: "Enter your password",
        submit: {
          field: "Enter your password",
          equals: SENTINEL,
          then: "inbox",
          else: "wrong",
        },
      },
    });
    s.start = "reauth";
    const h = harness(s);
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, { result: "signed-in", typed: true });
    assert.deepEqual(r.steps, ["reauth-password"]);
    assert.equal(typed(h.log()).filter((t) => t.secret).length, 1);
    assert.deepEqual(h.calls, [
      "first-input after 0 keystroke calls",
      "before-password after 0 password calls",
    ]);
    assertSecretOnlyOnItsPipes(h.log());
  });

  it("treats a re-verification after the password was typed as a challenge, typing the password once", async () => {
    const s = gmailScenario({
      reauth: {
        text: "Google\nVerify it's you\nEnter your password\nNext",
        fields: [
          {
            name: "Enter your password",
            protected: true,
            bounds: PASSWORD_FIELD,
          },
        ],
        focus: "Enter your password",
        submit: "inbox",
      },
    });
    (s.screens.password!.submit as { then: string }).then = "reauth";
    const h = harness(s);
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, {
      result: "challenged",
      challenge: "verify-identity",
      phrase: "verify it's you",
    });
    assert.equal(typed(h.log()).filter((t) => t.secret).length, 1);
  });

  it("closes Chrome's own sign-in bubble once through its button, not counting it as an input to the provider", async () => {
    const s = gmailScenario();
    s.start = "bubble";
    s.screens.bubble = {
      text: "Gmail\nCompose\nMake Chrome your own\nContinue as QA\nUse Chrome without an account",
      buttons: [
        {
          name: "Continue as QA",
          bounds: [900, 300, 200, 30],
          next: "accepted",
        },
        {
          name: "Use Chrome without an account",
          bounds: [900, 350, 200, 30],
          next: "inbox",
        },
      ],
    };
    s.screens.accepted = { text: "ACCEPTED" };
    const h = harness(s);
    const r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    assert.deepEqual(r.outcome, { result: "signed-in", typed: false });
    assert.deepEqual(inputs(h), ["click 1000,365"]);
    assert.deepEqual(h.calls, []);
  });

  it("keeps its screenshot owner-only whatever the umask", async () => {
    const challenge = { text: "Google\nVerify it's you\nTry another way" };
    const s = gmailScenario({ challenge });
    (s.screens.password!.submit as { then: string }).then = "challenge";
    const h = harness(s);
    // GuiAssert (here its stand-in) inherits the umask and writes the
    // file with it.
    const old = process.umask(0o000);
    let r;
    try {
      r = await driveSignin(h.ctx(GMAIL_SIGNIN));
    } finally {
      process.umask(old);
    }
    assert.equal(r.outcome.result, "challenged");
    assert.ok(r.screen !== null);
    assert.equal(statSync(r.screen).mode & 0o777, 0o600);
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
    assert.match(
      r2.reason,
      /^the mailbox did not show within 0 s \(the screen: unrecognised\)$/,
    );
    assert.equal(r2.seen, "unrecognised");
    noInput(h2.log());
  });

  it("reports an account-setup screen on the inbox URL as not the mailbox, and dismisses nothing", async () => {
    const s = gmailScenario({
      homeaddress: {
        text: "Google\nSet a home address\nHome address\nSkip\nSave",
        buttons: [
          {
            name: "Skip",
            role: "link",
            bounds: [300, 600, 80, 30],
            next: "inbox",
          },
        ],
      },
    });
    s.start = "homeaddress";
    const h = harness(s);
    const r = await verifySignedIn(verifyCtx(h));
    assert.ok(!r.signedIn);
    assert.match(
      r.reason,
      /^the inbox URL showed an account-setup screen \(home-address: "set a home address"\), not the mailbox: .*the check dismisses nothing/,
    );
    noInput(h.log());
  });

  it("reports a consent page and Google's re-verification on the inbox URL as not signed in, answering nothing", async () => {
    const c = consentScenario();
    const h1 = harness(c);
    const r1 = await verifySignedIn(
      verifyCtx(h1, { provider: YAHOO_SIGNIN, browserPid: 4242 }),
    );
    assert.ok(!r1.signedIn);
    assert.match(
      r1.reason,
      /^the inbox URL showed a privacy-consent page \(yahoo-consent\), not the mailbox: .*the check answers nothing/,
    );
    noInput(h1.log());
    const s = gmailScenario({
      reauth: {
        text: "Google\nVerify it's you\nEnter your password\nNext",
        fields: [
          {
            name: "Enter your password",
            protected: true,
            bounds: PASSWORD_FIELD,
          },
        ],
        focus: "Enter your password",
      },
    });
    s.start = "reauth";
    const h2 = harness(s);
    const r2 = await verifySignedIn(verifyCtx(h2));
    assert.ok(!r2.signedIn);
    assert.match(
      r2.reason,
      /^the inbox URL showed Google's password re-verification of the session .*the check never types$/,
    );
    noInput(h2.log());
  });

  it("keeps the screen it saw when it finds no mailbox (guarded, 0600), and removes an older one when it does", async () => {
    const s = gmailScenario({
      verify: { text: "Google\nVerify it's you\nTry another way" },
    });
    s.start = "verify";
    const h = harness(s);
    const keep = join(h.dir, "check-screen.png");
    const old = process.umask(0o000);
    let r;
    try {
      r = await verifySignedIn(verifyCtx(h, { keepPath: keep }));
    } finally {
      process.umask(old);
    }
    assert.ok(!r.signedIn);
    assert.equal(r.screen, keep);
    assert.equal(r.seen, 'a challenge (verify-identity: "verify it\'s you")');
    assert.match(readFileSync(keep, "utf8"), /Verify it's you/);
    assert.equal(statSync(keep).mode & 0o777, 0o600);
    // Every frame, the kept one too, through the guard.
    assertSecretOnlyOnItsPipes(h.log());
    noInput(h.log());
    // Signed in: the older screenshot is gone.
    const s2 = gmailScenario();
    s2.start = "inbox";
    const h2 = harness(s2);
    writeFileSync(join(h2.dir, "check-screen.png"), "old");
    assert.deepEqual(
      await verifySignedIn(
        verifyCtx(h2, { keepPath: join(h2.dir, "check-screen.png") }),
      ),
      { signedIn: true },
    );
    assert.ok(!existsSync(join(h2.dir, "check-screen.png")));
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
    `#!/bin/sh\nprintf '%s\\n' "$@" > "${browserLog}/args.$$"\nenv > "${browserLog}/env.$$"\nfor a in "$@"; do case "$a" in --user-data-dir=*) d="\${a#--user-data-dir=}";; esac; done\n[ -f "$d/Default/Preferences" ] && cp "$d/Default/Preferences" "${browserLog}/prefs.$$"\nexec sleep 600\n`,
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

  it("writes the profile's preferences before every browser start, keeping the rest of them", () => {
    rmSync(attemptPath(profile()), { force: true });
    const prefsPath = join(profile().userDataDir, "Default", "Preferences");
    mkdirSync(dirname(prefsPath), { recursive: true });
    // As the first follow-up left a profile: Chrome's sign-in off.
    writeFileSync(
      prefsPath,
      JSON.stringify({
        keep: { me: 1 },
        signin: { other: true, allowed: false, allowed_on_next_startup: false },
      }),
    );
    const c = cliEnv(gmailScenario());
    resetDesktop(c.state);
    const before = new Set(readdirSync(browserLog));
    const r = run(c.env, "--unsafe-no-sandbox", "--timeout", "10");
    assert.equal(r.status, 0, r.stdout + r.stderr);
    // Two starts (the sign-in, the check); each found the preferences
    // already written when it started.
    const seen = readdirSync(browserLog).filter(
      (f) => !before.has(f) && f.startsWith("prefs."),
    );
    assert.equal(seen.length, 2);
    for (const f of seen) {
      const p = JSON.parse(readFileSync(join(browserLog, f), "utf8")) as {
        keep: unknown;
        signin: Record<string, unknown>;
        credentials_enable_service: unknown;
        profile: Record<string, unknown>;
      };
      assert.deepEqual(p.keep, { me: 1 });
      assert.deepEqual(p.signin, {
        other: true,
        ...WEBMAIL_PROFILE_PREFS.signin,
      });
      assert.equal(p.credentials_enable_service, false);
      assert.deepEqual(p.profile, WEBMAIL_PROFILE_PREFS.profile);
    }
    assert.equal(statSync(prefsPath).mode & 0o777, 0o600);
  });

  // Chrome's saved-password database with one saved login (the columns
  // the count reads), as a profile would hold one had a person answered
  // "Save" to Chrome's bubble.
  const plantSavedLogin = (): string => {
    const path = join(profile().userDataDir, "Default", "Login Data");
    mkdirSync(dirname(path), { recursive: true });
    rmSync(path, { force: true });
    const db = new DatabaseSync(path);
    db.exec(
      "CREATE TABLE logins (origin_url TEXT, password_value BLOB, blacklisted_by_user INTEGER)",
    );
    db.prepare(
      "INSERT INTO logins (origin_url, password_value, blacklisted_by_user) VALUES (?, ?, 0)",
    ).run("https://accounts.google.com/", "x");
    db.close();
    return path;
  };

  it("fails a run whose profile holds a saved password (exit 8), whatever the sign-in's result, counting it without reading it", () => {
    rmSync(attemptPath(profile()), { force: true });
    const planted = plantSavedLogin();
    try {
      const s = gmailScenario();
      s.start = "inbox";
      const c = cliEnv(s);
      resetDesktop(c.state);
      const r = run(
        c.env,
        "--check-only",
        "--unsafe-no-sandbox",
        "--timeout",
        "10",
      );
      assert.equal(r.status, 8, r.stdout + r.stderr);
      // The check itself passed; the profile still fails the run.
      assert.match(r.stdout, /SIGNED IN: gmail-workspace\/qa1/);
      assert.match(
        r.stdout,
        /SECRET AT REST: gmail-workspace\/qa1: the browser profile holds 1 saved login\(s\) in Login Data, 0 in Login Data For Account and 0 password hash\(es\)/,
      );
      assert.match(r.stdout, /"No saved password at rest"/);
      const runbook = readFileSync(
        join(repoRoot, "docs", "webmail-signin.md"),
        "utf8",
      );
      assert.match(runbook, /^## No saved password at rest$/m);
      // Without it, the same run passes.
      rmSync(planted);
      resetDesktop(c.state);
      const ok = run(
        c.env,
        "--check-only",
        "--unsafe-no-sandbox",
        "--timeout",
        "10",
      );
      assert.equal(ok.status, 0, ok.stdout + ok.stderr);
      assert.doesNotMatch(ok.stdout, /SECRET AT REST/);
    } finally {
      rmSync(planted, { force: true });
    }
  });

  it("stops at a consent page it cannot answer (exit 5, consent-required) with no input on it", () => {
    rmSync(attemptPath(profile()), { force: true });
    const c = cliEnv({
      start: "consent",
      screens: {
        consent: {
          text: "consent.google.com/ml?continue=x\nBefore you continue to Google\nAccept all\nMore options",
          location: "consent.google.com/ml?continue=x",
          buttons: [
            { name: "Accept all", bounds: [100, 700, 200, 40], next: "x" },
          ],
        },
        x: { text: "ACCEPTED" },
      },
    });
    resetDesktop(c.state);
    const r = run(c.env, "--unsafe-no-sandbox");
    assert.equal(r.status, 5, r.stdout + r.stderr);
    assert.match(
      r.stdout,
      /CONSENT REQUIRED \(google-consent\): gmail-workspace\/qa1: a privacy-consent page it cannot answer \(no reject-all control and no reject choices\) after \d+ s; a person answers it once \(--takeover, or --manual\)/,
    );
    assert.deepEqual(
      readLog(c.state).filter((e) =>
        ["type", "key", "click", "scroll"].includes(e.verb),
      ),
      [],
    );
    assert.match(
      readFileSync(join(profile().dir, "signin-screen.png"), "utf8"),
      /Before you continue/,
    );
  });

  it("keeps the screen a --check-only saw when the profile is not signed in, and names it", () => {
    rmSync(attemptPath(profile()), { force: true });
    const keep = join(profile().dir, "check-screen.png");
    rmSync(keep, { force: true });
    const s = gmailScenario({
      verify: { text: "Google\nVerify it's you\nTry another way" },
    });
    s.start = "verify";
    const c = cliEnv(s);
    resetDesktop(c.state);
    const r = run(
      c.env,
      "--check-only",
      "--unsafe-no-sandbox",
      "--timeout",
      "20",
    );
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.match(
      r.stdout,
      /gmail-workspace\/qa1: the check saw: a challenge \(verify-identity: "verify it's you"\); screenshot: .*check-screen\.png\./,
    );
    assert.equal(statSync(keep).mode & 0o777, 0o600);
    assert.match(readFileSync(keep, "utf8"), /Verify it's you/);
    assert.ok(!readFileSync(keep, "utf8").includes(SENTINEL));
    assert.equal(readAttempt(profile()).kind, "none");
  });

  it("records no attempt for a run that ended before any input, says so, and keeps its screenshot 0600 under umask 000", () => {
    rmSync(attemptPath(profile()), { force: true });
    rmSync(join(profile().dir, "signin-screen.png"), { force: true });
    // The first screen is already a challenge: nothing is typed.
    const c = cliEnv({
      start: "captcha",
      screens: {
        captcha: {
          text: "Google\nConfirm you're not a robot\nType the text you hear or see",
        },
      },
    });
    resetDesktop(c.state);
    const r = spawnSync(
      "/bin/sh",
      [
        "-c",
        'umask 000; exec "$0" "$@"',
        process.execPath,
        signinCli,
        "gmail-workspace",
        "--unsafe-no-sandbox",
      ],
      { env: c.env, encoding: "utf8", timeout: 120_000 },
    );
    assert.equal(r.status, 5, r.stdout + r.stderr);
    assert.match(
      r.stdout,
      /gmail-workspace\/qa1: no input reached the provider: no attempt recorded, so no cool-down\./,
    );
    assert.doesNotMatch(r.stdout, /next automated attempt is allowed/);
    assert.equal(readAttempt(profile()).kind, "none");
    assert.deepEqual(
      readLog(c.state).filter((e) => ["type", "key", "click"].includes(e.verb)),
      [],
    );
    const kept = join(profile().dir, "signin-screen.png");
    assert.equal(statSync(kept).mode & 0o777, 0o600);
    // And a second run is not held back by a cool-down.
    resetDesktop(c.state);
    const again = run(c.env, "--unsafe-no-sandbox");
    assert.equal(again.status, 5, again.stdout);
  });

  it("names the re-sealing runbook step and the typing check on a wrong password", () => {
    rmSync(attemptPath(profile()), { force: true });
    const s = gmailScenario();
    (s.screens.password!.submit as { equals: string }).equals =
      "not the stored password";
    const c = cliEnv(s);
    resetDesktop(c.state);
    const r = run(c.env, "--unsafe-no-sandbox");
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.match(r.stdout, /FAILED \(wrong-password\): gmail-workspace\/qa1/);
    assert.match(
      r.stdout,
      /the provider refused the account file's password\. Do not run the sign-in again until the credential is corrected: re-seal it at its source \(runbook docs\/webmail-signin\.md, "Re-sealing a QA password"\), then confirm it with --typing-check\./,
    );
    assert.ok(!r.stdout.includes(SENTINEL));
    const runbook = readFileSync(
      join(repoRoot, "docs", "webmail-signin.md"),
      "utf8",
    );
    assert.match(runbook, /^## Re-sealing a QA password$/m);
  });

  describe("--typing-check", () => {
    // A stand-in for the browser on the check page: it loads the page
    // and its expectation as the real page does, waits until the stand-in
    // desktop's field was typed into and submitted, and posts the
    // verdict the real page computes (SHA-256 of salt and the typed
    // text). STANDIN_DROP_LAST makes it lose the last character typed.
    const pageBrowser = join(scratch, "page-browser.mjs");
    writeFileSync(
      pageBrowser,
      `import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
const url = process.argv.at(-1);
writeFileSync(join(${JSON.stringify(browserLog)}, "args." + process.pid), process.argv.slice(2).join("\\n"));
const page = await (await fetch(url)).text();
if (!page.includes('type="password"')) process.exit(3);
const exp = await (await fetch(url + "expect")).json();
const state = join(process.env.ISONIM_EMAIL_WEBMAIL_PROFILES_DIR, ".guiassert-state", "standin-state.json");
let typed = null;
while (typed === null) {
  try {
    const s = JSON.parse(readFileSync(state, "utf8"));
    if (s.screen === "done") typed = s.values["check/Typing check password"] ?? "";
  } catch {}
  await sleep(50);
}
if (process.env.STANDIN_DROP_LAST) typed = [...typed].slice(0, -1).join("");
const digest = createHash("sha256").update(Buffer.from(exp.salt, "hex")).update(typed, "utf8").digest("hex");
await fetch(url + "result", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ match: digest === exp.digest, lengthMatch: [...typed].length === exp.length }) });
await sleep(600000);
`,
    );
    const pageBrowserExe = join(scratch, "page-browser");
    writeFileSync(
      pageBrowserExe,
      `#!/bin/sh\nexec "${process.execPath}" "${pageBrowser}" "$@"\n`,
      { mode: 0o755 },
    );
    const checkScenario = (): StandinScenario => ({
      start: "check",
      screens: {
        check: {
          text: "Typing check\nNo provider is contacted.\nReady",
          fields: [
            {
              name: "Typing check password",
              protected: true,
              bounds: PASSWORD_FIELD,
            },
          ],
          submit: "done",
        },
        done: { text: "Typing check\nDone" },
      },
    });

    for (const variant of ["match", "mismatch"] as const)
      it(`types the password into the loopback page only, and prints ${variant === "match" ? "MATCH" : "MISMATCH"} and nothing about the password`, () => {
        rmSync(attemptPath(profile()), { force: true });
        const c = cliEnv(checkScenario());
        resetDesktop(c.state);
        const before = new Set(readdirSync(browserLog));
        const env = {
          ...c.env,
          ISONIM_EMAIL_WEBMAIL_BROWSER: pageBrowserExe,
          ...(variant === "mismatch" ? { STANDIN_DROP_LAST: "1" } : {}),
        };
        const r = run(
          env,
          "qa1",
          "--typing-check",
          "--unsafe-no-sandbox",
          "--timeout",
          "30",
        );
        if (variant === "match") {
          assert.equal(r.status, 0, r.stdout + r.stderr);
          assert.match(
            r.stdout,
            /^TYPING CHECK MATCH: gmail-workspace\/qa1 \(length match: yes\)$/m,
          );
        } else {
          assert.equal(r.status, 1, r.stdout + r.stderr);
          assert.match(
            r.stdout,
            /^TYPING CHECK MISMATCH: gmail-workspace\/qa1 \(length match: no\)/m,
          );
        }
        for (const out of [r.stdout, r.stderr]) {
          assert.ok(!out.includes(SENTINEL));
          assert.doesNotMatch(out, /[0-9a-f]{32}/, "no digest, salt or token");
        }
        // The password went only into the page's protected field, once,
        // and to the guard of the one read afterwards.
        const log = readLog(c.state);
        assertSecretOnlyOnItsPipes(log);
        assert.deepEqual(typed(log), [
          {
            screen: "check",
            focused: "Typing check password",
            secret: true,
            text: "",
          },
        ]);
        // After the typing, one read of the display through the guard.
        const typedAt = log.findIndex((e) => e.verb === "type");
        assert.deepEqual(
          log.slice(typedAt).filter((e) => e.verb === "ocr").length,
          1,
        );
        // No attempt, and not the account's profile: a throw-away one,
        // removed afterwards, at a loopback page.
        assert.equal(readAttempt(profile()).kind, "none");
        const launches = readdirSync(browserLog)
          .filter((f) => !before.has(f) && f.startsWith("args."))
          .map((f) => readFileSync(join(browserLog, f), "utf8").split("\n"));
        assert.equal(launches.length, 1);
        const argv = launches[0]!;
        assert.match(
          argv.at(-1)!,
          /^http:\/\/127\.0\.0\.1:\d+\/[0-9a-f]{32}\/$/,
        );
        const udd = argv.find((a) => a.startsWith("--user-data-dir="))!;
        assert.ok(!udd.includes(profile().userDataDir), udd);
        assert.match(udd, /\/\.typing-check-[^/]+\/chromium$/);
        assert.ok(!existsSync(udd.slice("--user-data-dir=".length)));
        for (const a of argv) {
          assert.ok(!AUTOMATION_SWITCHES.some((re) => re.test(a)), a);
          assert.ok(!a.includes(SENTINEL));
        }
        assert.ok(!existsSync(join(profile().dir, "lease.json")));
      });

    it("stops (exit 7) when the password is legible on the screen after the typing", () => {
      const sc = checkScenario();
      // A page that showed what was typed in clear.
      sc.screens.done!.text = `Typing check\nYou typed: ${SENTINEL}`;
      const c = cliEnv(sc);
      resetDesktop(c.state);
      const r = run(
        { ...c.env, ISONIM_EMAIL_WEBMAIL_BROWSER: pageBrowserExe },
        "qa1",
        "--typing-check",
        "--unsafe-no-sandbox",
        "--timeout",
        "30",
      );
      assert.equal(r.status, 7, r.stdout + r.stderr);
      assert.match(
        r.stdout,
        /^STOPPED \(secret-visible\): gmail-workspace\/qa1/m,
      );
      assert.ok(!r.stdout.includes(SENTINEL) && !r.stderr.includes(SENTINEL));
    });

    it("refuses to mix with the sign-in's own modes", () => {
      const c = cliEnv(checkScenario());
      for (const extra of [
        "--manual",
        "--check-only",
        "--takeover",
        "--override-cooldown",
        "--playwright-check",
      ]) {
        const r = run(c.env, "--typing-check", extra);
        assert.equal(r.status, 2, extra);
      }
    });
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
