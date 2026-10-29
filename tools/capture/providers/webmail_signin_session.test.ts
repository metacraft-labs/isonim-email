// tools/capture/providers/webmail_signin_session.test.ts — the automated
// webmail sign-in end to end, with everything real but the provider:
// GuiAssert's private Xvfb session, the dev shell's webmail browser
// (Google Chrome, the very executable the recipe runs) started normally
// in it (its sandbox checked), OCR of the display through the password
// guard, the accessibility tree, OS-level typing (XTest), then the
// recipe's check (the browser started again on the inbox URL, the
// mailbox read off the screen) and Playwright's signed-in check on the
// profile in the same session (the captures open it under Playwright).
//
// What is proven: Gmail's screen table recognises pages worded as
// Gmail's and rendered by the webmail browser; the address and the
// password reach the page's fields (the page receives them exactly once
// each, the password through a password field it did not focus, so the
// click-and-check path ran); an account-setup screen after the password
// ("Set a home address", its field focused) is declined through its
// "Skip" link and nothing is saved; the page sees no automation
// (navigator.webdriver is false on every page); the browser's command
// line carries no automation switch and no password; the browser's
// window shows no infobar (OCR finds no "automated" or "for testing"
// wording); the profile the sign-in leaves reads as signed in when the
// browser is started again (by OCR, no input) and under Playwright; a
// profile that is not signed in reads as not signed in; a challenge after
// the password stops the attempt, keeps a screenshot in which the
// password is not legible (checked with GuiAssert's own guard), and
// types nothing more; a session asked for VNC serves an owner-only
// socket; with the profile's preferences, written as the recipe writes
// them before every start, Chrome offers no "Save password?" after the
// password form is submitted, saves no login, and keeps every one of
// them (the password manager off, the web sign-in interception off,
// Chrome's sign-in allowed), while the same pages and steps on a profile
// without them get the offer (the positive control); a privacy-consent
// page on a loopback consent host (`consent.localhost`, any port),
// worded in Bulgarian as Yahoo's is, is recognised by the address Chrome's
// address bar holds and answered by rejecting every row and clicking
// its continue control, never its allow choices; the
// typing check (a loopback page comparing a salted SHA-256 of what was
// typed) reports MATCH for passwords of every printable ASCII character
// and of non-ASCII letters typed through GuiAssert into Google Chrome,
// and MISMATCH for a different one.
//
// Test double (justification, per the repository's mock policy): the
// real provider pages cannot be signed in to from a test, so a local
// HTTP server on loopback plays Gmail's sign-in (an address page, a
// password page, a "Set a home address" page, a "Verify it's you" page,
// and a mailbox behind a session cookie), worded as Gmail words them,
// and a privacy-consent page on `consent.localhost` (which Chrome
// resolves to loopback itself) worded as Yahoo's. GuiAssert, the browser,
// tesseract, AT-SPI, Playwright and the profile are real.
// Run (inside `nix develop`, which puts guiassert on PATH) with:
//   node --test tools/capture/providers/webmail_signin_session.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { resolveDriver } from "./browser_emulation.ts";
import {
  type GaSession,
  GuiAssert,
  GuiAssertError,
  Secret,
  sessionEnv,
} from "./guiassert.ts";
import { findExecutable } from "./requirements.ts";
import {
  checkSignedIn,
  signinBrowserArgs,
  secretsAtRest,
  stopBrowser,
  waitSandboxed,
  webmailBrowser,
  webmailLaunchOptions,
  writeWebmailProfilePrefs,
} from "./webmail_profiles.ts";
import {
  AUTOMATION_SWITCHES,
  driveSignin,
  SIGNIN_SCREEN,
  SIGNIN_SESSION_SWITCHES,
  verifySignedIn,
} from "./webmail_signin.ts";
import { GMAIL_SIGNIN, type ProviderSignin } from "./webmail_signin_steps.ts";
import {
  runTypingCheck,
  startTypingCheckServer,
} from "./webmail_typing_check.ts";

const SENTINEL = "Sentinel-pw-7Qx9z";
const ADDRESS = "qa.tester@example.com";
const scratch = mkdtempSync(join(tmpdir(), "webmail-signin-session-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const page = (body: string): string =>
  `<!doctype html><html><head><meta charset="utf-8"><title>Gmail</title>
<style>body{font-family:Roboto,sans-serif;font-size:20px;margin:48px 80px}
h1{font-size:30px;font-weight:400} input{font-size:20px;padding:10px;width:420px;display:block;margin:18px 0}
button{font-size:18px;padding:8px 22px}</style>
<script>fetch('/probe?webdriver=' + String(navigator.webdriver) + '&page=' + encodeURIComponent(location.pathname));</script>
</head><body>${body}</body></html>`;

function readBody(req: IncomingMessage): Promise<URLSearchParams> {
  return new Promise((r) => {
    let b = "";
    req.setEncoding("utf8");
    req.on("data", (d: string) => (b += d));
    req.on("end", () => r(new URLSearchParams(b)));
  });
}

describe("the automated sign-in in a real GuiAssert session", () => {
  let server: Server;
  let port: number;
  let mode: "ok" | "challenge" = "ok";
  const received = {
    identifier: [] as string[],
    password: [] as string[],
    homeAddressSaved: 0,
    consent: [] as string[],
  };
  const probes: { webdriver: string; page: string }[] = [];
  let bin: string;
  let ga: GuiAssert;
  let pw: typeof import("playwright-core");

  before(async () => {
    server = createServer((req, res) => {
      void (async () => {
        const url = new URL(req.url ?? "/", "http://x");
        const html = (b: string) => {
          res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
          res.end(page(b));
        };
        const signedIn = /(?:^|; )session=yes(?:;|$)/.test(
          req.headers.cookie ?? "",
        );
        if (url.pathname === "/probe") {
          probes.push({
            webdriver: url.searchParams.get("webdriver") ?? "",
            page: url.searchParams.get("page") ?? "",
          });
          res.writeHead(204);
          return res.end();
        }
        if (url.pathname === "/mail/") {
          if (!signedIn) {
            res.writeHead(302, { location: "/signin" });
            return res.end();
          }
          return html(
            '<form role="search"><input name="q" aria-label="Search mail"></form><h2>Compose</h2><p>Inbox</p><p>Starred</p>',
          );
        }
        if (url.pathname === "/signin")
          return html(
            '<h1>Sign in</h1><p>to continue to Gmail</p><form method="post" action="/signin/identifier"><input name="identifier" aria-label="Email or phone" placeholder="Email or phone" autofocus autocomplete="off"><p>Forgot email?</p><button>Next</button></form>',
          );
        if (url.pathname === "/signin/identifier" && req.method === "POST") {
          received.identifier.push(
            (await readBody(req)).get("identifier") ?? "",
          );
          res.writeHead(303, { location: "/signin/pwd" });
          return res.end();
        }
        if (url.pathname === "/signin/pwd" && req.method === "GET")
          // The password field is NOT focused: the procedure must click it.
          return html(
            '<h1>Welcome</h1><form method="post" action="/signin/pwd"><p>Enter your password</p><input type="password" name="Passwd" aria-label="Enter your password" autocomplete="off"><p>Forgot password?</p><button>Next</button></form>',
          );
        if (url.pathname === "/signin/pwd" && req.method === "POST") {
          const p = (await readBody(req)).get("Passwd") ?? "";
          received.password.push(p);
          if (mode === "challenge") {
            res.writeHead(303, { location: "/challenge" });
            return res.end();
          }
          // Signed in; then Google's account-setup screen, as measured on
          // 2026-10-28 ("Set a home address", "Skip", "Save").
          res.writeHead(303, {
            "set-cookie": "session=yes; Max-Age=86400; Path=/",
            location: "/homeaddress",
          });
          return res.end();
        }
        if (url.pathname === "/homeaddress" && req.method === "GET")
          return html(
            '<h1>Set a home address</h1><p>Your home and work addresses are used to personalize your experiences across Google products.</p><form method="post" action="/homeaddress"><input name="home" aria-label="Home address" autofocus autocomplete="off"><a href="/mail/">Skip</a> <button>Save</button></form>',
          );
        if (url.pathname === "/homeaddress" && req.method === "POST") {
          received.homeAddressSaved++;
          res.writeHead(303, { location: "/mail/" });
          return res.end();
        }
        if (url.pathname === "/collectConsent" && req.method === "GET") {
          // Yahoo's layout (measured 2026-10-28): rows of a reject/allow
          // pair of radio buttons, none chosen, then a continue button.
          const row = (n: number, what: string) =>
            `<p>${what}</p><label><input type="radio" name="r${n}" value="reject" aria-label="Отхвърляне"> Отхвърляне</label> <label><input type="radio" name="r${n}" value="allow" aria-label="Разрешаване"> Разрешаване</label>`;
          return html(
            `<h1>Актуализирайте настройките си за поверителност</h1><form method="post" action="/collectConsent">${row(1, "Използване на информация от всички имейли")}${row(2, "Персонализирани реклами")}<p><button>Продължаване</button></p></form>`,
          );
        }
        if (url.pathname === "/collectConsent" && req.method === "POST") {
          const b = await readBody(req);
          received.consent.push(`${b.get("r1")},${b.get("r2")}`);
          // On to the sign-in, on the provider's own host.
          res.writeHead(303, { location: `http://127.0.0.1:${port}/signin` });
          return res.end();
        }
        if (url.pathname === "/challenge")
          return html(
            "<h1>Verify it's you</h1><p>To help keep your account safe, Google wants to make sure it's really you trying to sign in.</p><input aria-label=\"Enter code\" autofocus><button>Next</button>",
          );
        res.writeHead(404);
        res.end();
      })();
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    port = (server.address() as AddressInfo).port;
    const found = findExecutable("guiassert", {
      env: process.env,
      platform: process.platform,
    });
    if (found === null)
      throw new Error("no guiassert on PATH: run inside `nix develop`");
    bin = found;
    const state = join(scratch, "ga-state");
    mkdirSync(state, { mode: 0o700 });
    ga = new GuiAssert({
      bin,
      stateDir: state,
      env: process.env,
      timeoutMs: 60_000,
    });
    const driver = resolveDriver(process.env);
    if ("reason" in driver) throw new Error(driver.reason);
    pw = await import(pathToFileURL(join(driver.dir, "index.mjs")).href);
  });
  after(() => new Promise<void>((r) => server.close(() => r())));

  // The webmail browser on `profile` at `url` in the session, sandboxed.
  async function launch(
    env: Record<string, string>,
    profile: string,
    url: string,
    prefs = true,
  ) {
    const browser = webmailBrowser(process.env);
    if ("reason" in browser) throw new Error(browser.reason);
    // As the recipe does before every start (left out only by the
    // password manager's positive control).
    if (prefs) writeWebmailProfilePrefs(profile);
    let said = "";
    const child = spawn(
      browser.path,
      signinBrowserArgs(profile, url, { extra: [...SIGNIN_SESSION_SWITCHES] }),
      { env, stdio: ["ignore", "ignore", "pipe"] },
    );
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (d: string) => (said = (said + d).slice(-8192)));
    const sandboxed = await waitSandboxed(child, profile, () => said);
    if (!sandboxed.ok) await stopBrowser(child);
    assert.ok(sandboxed.ok, JSON.stringify(sandboxed));
    return child;
  }

  // The recipe's check: the browser started again on the inbox URL, the
  // mailbox read off the screen; returns its verdict and every GuiAssert
  // call it made is OCR.
  async function check(a: {
    sga: GuiAssert;
    env: Record<string, string>;
    profile: string;
    frames: string;
  }) {
    const child = await launch(
      a.env,
      a.profile,
      `http://127.0.0.1:${port}/mail/`,
    );
    try {
      return await verifySignedIn({
        ga: a.sga,
        provider: {
          ...GMAIL_SIGNIN,
          startUrl: `http://127.0.0.1:${port}/mail/`,
        },
        password: new Secret(SENTINEL),
        framesDir: a.frames,
        timeoutMs: 60_000,
        settleMs: 3000,
        pollMs: 500,
        log: () => undefined,
      });
    } finally {
      await stopBrowser(child);
    }
  }

  // The stand-in Gmail, from its inbox URL.
  const standInGmail = (): ProviderSignin => ({
    ...GMAIL_SIGNIN,
    startUrl: `http://127.0.0.1:${port}/mail/`,
  });

  async function attempt(
    name: string,
    vncSocket: boolean,
    opts: { provider?: ProviderSignin; prefs?: boolean } = {},
  ) {
    const provider = opts.provider ?? standInGmail();
    const profile = join(scratch, name, "chromium");
    mkdirSync(profile, { recursive: true, mode: 0o700 });
    const frames = join(scratch, name, "frames");
    mkdirSync(frames, { mode: 0o700 });
    const session: GaSession = await ga.sessionStart({
      name: `signin-test-${name}-${process.pid}`,
      width: SIGNIN_SCREEN.width,
      height: SIGNIN_SCREEN.height,
      vncSocket,
    });
    const sga = ga.inSession(session.id);
    const env = sessionEnv(process.env, session);
    let child;
    try {
      child = await launch(env, profile, provider.startUrl, opts.prefs ?? true);
    } catch (err) {
      await ga.sessionStop(session.id);
      throw err;
    }
    const events: string[] = [];
    try {
      // No infobar: nothing on the first screen says the browser is
      // automated or for testing (Chrome for Testing's bar does).
      const first = await sga.ocr(
        join(frames, "first.png"),
        new Secret(SENTINEL),
      );
      rmSync(join(frames, "first.png"), { force: true });
      assert.doesNotMatch(first.text, /automated|for testing|controlled by/i);
      // Chromium rewrites its process title with its arguments joined
      // by spaces (as its zygote's children do), so split on both.
      const cmdline = readFileSync(`/proc/${child.pid}/cmdline`, "utf8").split(
        /[\0 ]/,
      );
      const result = await driveSignin({
        ga: sga,
        provider,
        browserPid: child.pid!,
        address: ADDRESS,
        password: new Secret(SENTINEL),
        framesDir: frames,
        keepPath: join(scratch, name, "kept.png"),
        timings: {
          pollMs: 500,
          unknownMs: 45_000,
          stuckMs: 30_000,
          deadlineMs: 240_000,
          focusSettleMs: 600,
        },
        onFirstInput: () => events.push("first-input"),
        onBeforePassword: () => events.push("before-password"),
        log: (l) => events.push(l),
      });
      return {
        result,
        session,
        sga,
        env,
        profile,
        cmdline,
        events,
        frames,
        child,
      };
    } catch (err) {
      await stopBrowser(child);
      await ga.sessionStop(session.id);
      throw err;
    }
  }

  it("signs in through the stand-in Gmail pages, and the profile reads as signed in under Playwright", async () => {
    mode = "ok";
    const a = await attempt("ok", false);
    try {
      assert.deepEqual(
        a.result.outcome,
        { result: "signed-in", typed: true },
        a.events.join("\n"),
      );
      // The account-setup screen declined through its "Skip" link, as
      // Chrome's accessibility tree names it; nothing saved.
      assert.deepEqual(a.result.steps, [
        "address",
        "password",
        "interstitial:home-address",
      ]);
      assert.equal(received.homeAddressSaved, 0);
      assert.deepEqual(received.identifier, [ADDRESS]);
      assert.deepEqual(received.password, [SENTINEL]);
      assert.deepEqual(
        a.events.filter((e) => !e.startsWith(" ") && !e.startsWith("screen")),
        ["first-input", "before-password"],
      );
      // No automation, as the page and the process table see it.
      assert.ok(probes.length >= 3, JSON.stringify(probes));
      for (const p of probes) assert.equal(p.webdriver, "false", p.page);
      for (const arg of a.cmdline) {
        assert.ok(!AUTOMATION_SWITCHES.some((re) => re.test(arg)), arg);
        assert.ok(!arg.includes(SENTINEL));
      }
      assert.ok(a.cmdline.includes("--force-renderer-accessibility"));
      assert.equal(existsSync(join(scratch, "ok", "kept.png")), false);
    } finally {
      await stopBrowser(a.child);
    }
    try {
      // The recipe's check: the same browser started again, the mailbox
      // read off the screen, nothing typed.
      const typedBefore = received.identifier.length + received.password.length;
      assert.deepEqual(await check(a), { signedIn: true });
      assert.equal(
        received.identifier.length + received.password.length,
        typedBefore,
      );
      for (const p of probes) assert.equal(p.webdriver, "false", p.page);
      // And under Playwright, with the same executable, as the captures
      // open the profile.
      const context = await pw.chromium.launchPersistentContext(a.profile, {
        ...webmailLaunchOptions(process.env, false),
        env: a.env,
      });
      try {
        const r = await checkSignedIn(
          context,
          {
            label: "stand-in Gmail",
            inboxUrl: `http://127.0.0.1:${port}/mail/`,
            mailHosts: [`127.0.0.1:${port}`],
            marker: 'form[role="search"]',
          },
          30_000,
        );
        assert.deepEqual(r, { signedIn: true, host: `127.0.0.1:${port}` });
      } finally {
        await context.close();
      }
    } finally {
      await ga.sessionStop(a.session.id);
    }
  });

  it("stops at a challenge after the password, keeps a screenshot without it, and serves the session on an owner-only VNC socket", async () => {
    mode = "challenge";
    received.identifier.length = 0;
    received.password.length = 0;
    const a = await attempt("challenge", true);
    try {
      assert.deepEqual(
        a.result.outcome,
        {
          result: "challenged",
          challenge: "verify-identity",
          phrase: "verify it's you",
        },
        a.events.join("\n"),
      );
      assert.deepEqual(received.password, [SENTINEL]);
      const kept = a.result.screen;
      assert.ok(kept !== null && existsSync(kept));
      // GuiAssert's own guard over the kept file: the password is not
      // legible in it, and the challenge is.
      const read = await ga.run(
        "ocr",
        ["--image", kept, "--secret-stdin"],
        new Secret(SENTINEL),
      );
      assert.match((read as { text: string }).text, /Verify/);
      // The VNC socket: in the session's private runtime directory.
      assert.ok(a.session.vncSocket !== null);
      const sock = a.session.vncSocket!;
      assert.ok(statSync(sock).isSocket());
      assert.equal(statSync(join(sock, "..")).mode & 0o777, 0o700);
      await stopBrowser(a.child);
      // The challenged profile holds no session: the check, started on
      // the inbox URL, is sent to the sign-in and says so.
      const v = await check(a);
      assert.ok(!v.signedIn);
      assert.match(v.reason, /the address screen of the sign-in/);
    } finally {
      await stopBrowser(a.child);
      await ga.sessionStop(a.session.id);
    }
    // And the guard does refuse a frame that shows the secret.
    await assert.rejects(
      ga.run(
        "ocr",
        ["--image", a.result.screen!, "--secret-stdin"],
        new Secret("Verify it's you"),
      ),
      (e: unknown) =>
        e instanceof GuiAssertError && e.reason === "secret-visible",
    );
  });
  // Chrome's "Save password?" bubble, by its title (OCR of the display).
  const SAVE_OFFER = /save\s+password/i;

  // The challenge flow (address, password, "Verify it's you") on a fresh
  // profile, then the display read for SAVE_OFFER until it shows or
  // `watchMs` passes; the browser is stopped before returning.
  async function passwordOffer(name: string, prefs: boolean) {
    mode = "challenge";
    received.password.length = 0;
    const a = await attempt(name, false, { prefs });
    let offered = false;
    try {
      assert.equal(a.result.outcome.result, "challenged", a.events.join("\n"));
      assert.deepEqual(received.password, [SENTINEL]);
      const watchMs = 15_000;
      for (const t0 = Date.now(); !offered && Date.now() - t0 < watchMs; ) {
        const shot = join(a.frames, "offer.png");
        const seen = await a.sga.ocr(shot, new Secret(SENTINEL));
        rmSync(shot, { force: true });
        offered = SAVE_OFFER.test(seen.text);
        if (!offered) await sleep(1000);
      }
    } finally {
      await stopBrowser(a.child);
      await ga.sessionStop(a.session.id);
    }
    return { offered, profile: a.profile };
  }

  it("keeps Chrome's password manager off: no 'Save password?' after the password, no saved login, and every profile preference kept; without them the same steps get the offer", async () => {
    const off = await passwordOffer("password-manager", true);
    assert.equal(
      off.offered,
      false,
      "a Save password? offer with the preferences",
    );
    assert.deepEqual(secretsAtRest(off.profile), {
      savedLogins: 0,
      accountLogins: 0,
      passwordHashes: 0,
      unreadable: [],
    });
    // Chrome kept every preference the recipe wrote across its start.
    const prefs = JSON.parse(
      readFileSync(join(off.profile, "Default", "Preferences"), "utf8"),
    ) as {
      credentials_enable_service: unknown;
      credentials_enable_autosignin: unknown;
      profile: Record<string, unknown>;
      signin: Record<string, unknown>;
      intl: Record<string, unknown>;
    };
    assert.equal(prefs.credentials_enable_service, false);
    assert.equal(prefs.credentials_enable_autosignin, false);
    assert.equal(prefs.profile.password_manager_enabled, false);
    assert.equal(prefs.profile.password_manager_leak_detection, false);
    assert.equal(prefs.signin.interception_enabled, false);
    assert.equal(prefs.signin.allowed, true);
    assert.equal(prefs.signin.allowed_on_next_startup, true);
    assert.equal(prefs.intl.accept_languages, "en-US,en");
    // The positive control: Chrome's defaults offer to save the password
    // on the same pages after the same steps (nobody answers it).
    const on = await passwordOffer("password-manager-control", false);
    assert.equal(
      on.offered,
      true,
      "no Save password? offer without the preferences",
    );
  });

  it("answers a privacy-consent page on a loopback consent host by its address (any port): every row rejected, then its continue control, then the sign-in", async () => {
    mode = "ok";
    received.identifier.length = 0;
    received.password.length = 0;
    received.consent.length = 0;
    const provider: ProviderSignin = {
      ...standInGmail(),
      startUrl: `http://consent.localhost:${port}/collectConsent?sessionId=x`,
      consent: {
        name: "loopback-consent",
        hosts: ["consent.localhost"],
        paths: ["collectconsent"],
      },
    };
    const a = await attempt("consent", false, { provider });
    try {
      assert.deepEqual(
        a.result.outcome,
        { result: "signed-in", typed: true },
        a.events.join("\n"),
      );
      assert.deepEqual(a.result.steps, [
        "consent:loopback-consent",
        "address",
        "password",
        "interstitial:home-address",
      ]);
      // Both rows rejected, no allow choice, posted once.
      assert.deepEqual(received.consent, ["reject,reject"]);
      assert.deepEqual(received.identifier, [ADDRESS]);
      assert.deepEqual(received.password, [SENTINEL]);
      // The consent page's clicks, by exact name; the first of them was
      // the attempt's first input.
      const chose = a.events.findIndex((e) => /chose "Отхвърляне" on/.test(e));
      const went = a.events.findIndex((e) =>
        /every row rejected \(2\); clicked "Продължаване"/.test(e),
      );
      assert.ok(chose >= 0 && went > chose, a.events.join("\n"));
      assert.equal(a.events.filter((e) => e === "first-input").length, 1);
      assert.ok(a.events.indexOf("first-input") < chose);
    } finally {
      await stopBrowser(a.child);
      await ga.sessionStop(a.session.id);
    }
  });

  it("types passwords of every printable ASCII character and of non-ASCII letters into the check page exactly (MATCH), and tells a different one (MISMATCH)", async () => {
    let ascii = "";
    for (let c = 0x20; c <= 0x7e; c++) ascii += String.fromCharCode(c);
    // "𝄞" is outside the BMP: two UTF-16 units, one code point.
    const nonAscii = "Grüße-Ñandú-Жук-€-éà-𝄞";
    const differs = `${ascii.slice(0, -1)}}`;
    assert.notEqual(differs, ascii);
    const cases: { name: string; expected: string; typed: string }[] = [
      { name: "ascii", expected: ascii, typed: ascii },
      { name: "nonascii", expected: nonAscii, typed: nonAscii },
      { name: "differs", expected: ascii, typed: differs },
    ];
    const session = await ga.sessionStart({
      name: `signin-test-typing-${process.pid}`,
      width: SIGNIN_SCREEN.width,
      height: SIGNIN_SCREEN.height,
      vncSocket: false,
    });
    const sga = ga.inSession(session.id);
    const results: Record<string, unknown> = {};
    try {
      for (const c of cases) {
        const profile = join(scratch, `typing-${c.name}`, "chromium");
        mkdirSync(profile, { recursive: true, mode: 0o700 });
        const frames = join(scratch, `typing-${c.name}`, "frames");
        mkdirSync(frames, { mode: 0o700 });
        const server = await startTypingCheckServer(new Secret(c.expected));
        try {
          const child = await launch(
            sessionEnv(process.env, session),
            profile,
            server.url,
          );
          try {
            results[c.name] = await runTypingCheck({
              ga: sga,
              browserPid: child.pid!,
              timings: { focusSettleMs: 600 },
              server,
              typed: new Secret(c.typed),
              guard: new Secret(c.expected),
              framesDir: frames,
              timeoutMs: 60_000,
              pollMs: 500,
              log: () => undefined,
            });
            // The page never echoes the field: nothing it served or
            // showed carried the password.
            assert.deepEqual(readdirSync(frames), []);
          } finally {
            await stopBrowser(child);
          }
        } finally {
          await server.close();
        }
      }
    } finally {
      await ga.sessionStop(session.id);
    }
    assert.deepEqual(results, {
      ascii: { result: "match", lengthMatch: true },
      nonascii: { result: "match", lengthMatch: true },
      differs: { result: "mismatch", lengthMatch: true },
    });
  });
});
