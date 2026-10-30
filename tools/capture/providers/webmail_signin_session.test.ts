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
// its continue control, never its allow choices; Yahoo's second consent
// page as measured on 2026-10-29 (reached through the first page's
// "Отхвърляне на всички"), a dialog that scrolls, shown scrolled to its
// end, whose radio buttons are named "<purpose>, <choice>", is answered
// by rejecting every purpose (the wheel turned up to the one above the
// visible part, whose Allow was selected), then its "Запазване на избора"
// once, and a choice named otherwise stops it consent-required with no
// input on the dialog and nothing posted; the
// typing check (a loopback page comparing a salted SHA-256 of what was
// typed) reports MATCH for passwords of every printable ASCII character
// and of non-ASCII letters typed through GuiAssert into Google Chrome,
// and MISMATCH for a different one; Chrome writes a hash of a password
// submitted on Google's sign-in page into the profile's preferences even
// with the recipe's preferences (the reason for the scrub), the scrub
// removes it with the browser stopped, and the next start does not bring
// it back, while the same page off Google's origin gets no hash; the
// sign-in-again page changing in place after its "Next" (the address on
// the password page at once, the old wording on the screen for a few
// seconds) is waited through with no input, then the password is typed
// once; with the profile's preferences Chrome offers no translation of a
// page in Bulgarian (no Translate bubble, so no "Always translate" check
// box in the browser's tree for the consent round to stop on), while the
// same preferences with page translation on show the bubble (the
// positive control).
//
// Test double (justification, per the repository's mock policy): the
// real provider pages cannot be signed in to from a test, so a local
// HTTP server on loopback plays Gmail's sign-in (an address page, a
// password page, a "Set a home address" page, a "Verify it's you" page,
// and a mailbox behind a session cookie), worded as Gmail words them,
// and a privacy-consent page on `consent.localhost` (which Chrome
// resolves to loopback itself) worded as Yahoo's. For the password hash,
// Chrome is told the loopback server is Google's sign-in origin with its
// own `--gaia-url` switch (a test-only switch the recipe never passes; it
// sets the origin Chromium's `IsGaiaCredentialPage` compares a form's
// realm with). GuiAssert, the browser, tesseract, AT-SPI, Playwright and
// the profile are real.
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
  writeFileSync,
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
  scrubPasswordHashes,
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
  focusField,
  isPasswordField,
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

// Google's password page after the sign-in-again page (live 2026-10-29
// 21:12Z, the kept screenshot): "Welcome", the account, the field, "Show
// password", "Forgot password?", "Next". Its field is not focused.
const PASSWORD_FORM = `<h1>Welcome</h1><p>${ADDRESS}</p><form method="post" action="/signin/pwd"><p>Enter your password</p><input type="password" name="Passwd" aria-label="Enter your password" autocomplete="off"><p>Show password</p><p>Forgot password?</p><button>Next</button></form>`;
// How long the in-place page keeps its old content after "Next".
const INPLACE_MS = 8000;

describe("the automated sign-in in a real GuiAssert session", () => {
  let server: Server;
  let port: number;
  let mode: "ok" | "challenge" = "ok";
  const received = {
    identifier: [] as string[],
    password: [] as string[],
    homeAddressSaved: 0,
    consent: [] as string[],
    purposes: [] as string[],
    gaia: [] as string[],
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
        // A page in Bulgarian, as Yahoo's consent pages are, that says
        // so (`lang`, Content-Language): Chrome then decides to offer a
        // translation from the declared language, whether or not its
        // language-detection model is in the profile yet (a fresh
        // profile's is not; measured 2026-10-30, Chrome 147: the consent
        // pages without `lang` got no offer in 60 s, this one the
        // Translate bubble within about 11 s).
        if (url.pathname === "/bg") {
          res.writeHead(200, {
            "content-type": "text/html; charset=utf-8",
            "content-language": "bg",
          });
          return res.end(
            `<!doctype html><html lang="bg"><head><meta charset="utf-8"><title>Поверителност</title></head><body><h1>Yahoo е част от семейството на Yahoo</h1>${"<p>Ние и нашите партньори използваме бисквитки и подобни технологии, за да съхраняваме и да имаме достъп до информация на Вашето устройство, да подобряваме услугите си и да Ви показваме подходящо съдържание и реклами.</p>".repeat(6)}</body></html>`,
          );
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
        // Yahoo's two mail consent pages as measured on 2026-10-29: a
        // page with "Отхвърляне на всички" / "Приемане на всички", then a
        // dialog that scrolls, shown scrolled to its end, whose radio
        // buttons are named "<purpose>, <choice>": the smart-features
        // purpose above the visible part (Allow selected), ads (Reject
        // selected), statistics (nothing selected), and "Запазване на
        // избора" at its end. `sessionId=odd` names one choice otherwise.
        if (url.pathname === "/v2/collectConsent" && req.method === "GET")
          return html(
            `<h1>Yahoo е част от семейството на Yahoo</h1><p>Ние и нашите партньори използваме бисквитки.</p><form method="post" action="/v2/collectConsent?sessionId=${url.searchParams.get("sessionId") ?? ""}"><button name="r" value="reject">Отхвърляне на всички</button> <button name="r" value="accept">Приемане на всички</button></form>`,
          );
        if (url.pathname === "/v2/collectConsent" && req.method === "POST") {
          received.purposes.push(`first:${(await readBody(req)).get("r")}`);
          res.writeHead(303, {
            location: `/mailbox/collectConsent?sessionId=${url.searchParams.get("sessionId") ?? ""}`,
          });
          return res.end();
        }
        if (
          url.pathname === "/mailbox/collectConsent" &&
          req.method === "GET"
        ) {
          const odd = url.searchParams.get("sessionId") === "odd";
          const filler = (n: number) =>
            "<p>Използваме информацията, за да подобряваме услугите си и да Ви показваме подходящо съдържание.</p>".repeat(
              n,
            );
          const purpose = (
            id: string,
            title: string,
            on: "reject" | "allow" | null,
            reject = "Отхвърляне",
          ) =>
            `<div class="row"><p class="t"><b>${title}</b> въз основа на нашето предположение за Вашите интереси.</p><span class="c"><input type="radio" name="${id}" value="reject" aria-label="${title}, ${reject}"${on === "reject" ? " checked" : ""}></span><span class="c"><input type="radio" name="${id}" value="allow" aria-label="${title}, Разрешаване"${on === "allow" ? " checked" : ""}></span></div>`;
          res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
          return res.end(`<!doctype html><html><head><meta charset="utf-8"><title>Welcome to Mail!</title>
<style>body{margin:0;background:#777;font-family:Roboto,sans-serif;font-size:18px}
.dlg{position:fixed;top:100px;left:260px;width:712px;height:600px;overflow-y:auto;background:#fff;border-radius:8px;padding:0 24px}
.row{display:flex;align-items:flex-start;margin:20px 0}.t{width:480px;margin:0}
.c{width:100px;text-align:center}.h{display:flex;justify-content:flex-end}
input[type=radio]{width:22px;height:22px;margin:4px}button{font-size:18px;padding:10px 28px;margin:20px 0 40px}</style>
</head><body><div class="dlg"><form method="post" action="/mailbox/collectConsent">
<h2>yahoo!</h2>${filler(3)}
${purpose("smart", "За предоставяне на интелигентни функции", "allow", odd ? "Може би" : "Отхвърляне")}
<h3>Използване на информация само от търговски имейли</h3>${filler(4)}
<div class="h"><span class="c">Отхвърляне</span><span class="c">Разрешаване</span></div>
${purpose("ads", "За да Ви показваме персонализирани реклами и съдържание", "reject")}
${purpose("stats", "За създаване и споделяне на обобщени статистики", null)}
<p>Вижте нашия Център за поверителност за повече подробности.</p>
<button>Запазване на избора</button></form></div>
<script>const d = document.querySelector('.dlg'); d.scrollTop = d.scrollHeight;</script>
</body></html>`);
        }
        if (
          url.pathname === "/mailbox/collectConsent" &&
          req.method === "POST"
        ) {
          const b = await readBody(req);
          received.purposes.push(
            `second:${b.get("smart")},${b.get("ads")},${b.get("stats")}`,
          );
          res.writeHead(303, { location: `http://127.0.0.1:${port}/signin` });
          return res.end();
        }
        // The same page changing in place, as a single-page application
        // does: "Next" moves the address to the password page's at once
        // (history.pushState) and replaces the content INPLACE_MS later,
        // so the old wording stays on the screen, and in the tree, under
        // the new address for a few rounds (measured 2026-10-30 in this
        // session's Chrome: two rounds of "Verify it's you … Please sign
        // in again" with /challenge/pwd before and after the frame).
        if (
          url.pathname === "/v3/signin/confirmidentifier" &&
          url.searchParams.get("inplace") === "1"
        )
          return html(
            `<div id="view"><h1>Verify it’s you</h1><p>${ADDRESS}</p><p>To help keep your account secure, Google needs to verify it’s you. Please sign in again to continue to Gmail.</p><button id="next">Next</button></div><script>document.getElementById('next').addEventListener('click', function () { history.pushState({}, '', '/v3/signin/challenge/pwd?TL=x'); setTimeout(function () { document.getElementById('view').innerHTML = ${JSON.stringify(PASSWORD_FORM)}; }, ${INPLACE_MS}); });</script>`,
          );
        if (url.pathname === "/v3/signin/challenge/pwd")
          return html(PASSWORD_FORM);
        // Google's sign-in-again page as measured on 2026-10-29: the
        // account, the wording, one "Next", nothing to fill.
        if (url.pathname === "/v3/signin/confirmidentifier")
          return html(
            `<h1>Verify it’s you</h1><p>${ADDRESS}</p><p>To help keep your account secure, Google needs to verify it’s you. Please sign in again to continue to Gmail.</p><form method="get" action="/signin/pwd"><button>Next</button></form>`,
          );
        // One form with the account and the password, as a password
        // manager sees Google's two pages; then a page without it.
        if (url.pathname === "/gaia/signin" && req.method === "GET")
          return html(
            '<h1>Sign in</h1><form method="post" action="/gaia/signin"><input type="email" name="identifier" aria-label="Email or phone" autocomplete="username"><input type="password" name="Passwd" aria-label="Enter your password" autocomplete="current-password"><button>Next</button></form>',
          );
        if (url.pathname === "/gaia/signin" && req.method === "POST") {
          received.gaia.push((await readBody(req)).get("identifier") ?? "");
          res.writeHead(303, { location: "/gaia/welcome" });
          return res.end();
        }
        if (url.pathname === "/gaia/welcome")
          return html("<h1>Welcome</h1><p>Compose</p><p>Inbox</p>");
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
    extra: string[] = [],
  ) {
    const browser = webmailBrowser(process.env);
    if ("reason" in browser) throw new Error(browser.reason);
    // As the recipe does before every start (left out only by the
    // password manager's positive control).
    if (prefs) writeWebmailProfilePrefs(profile);
    let said = "";
    const child = spawn(
      browser.path,
      signinBrowserArgs(profile, url, {
        extra: [...SIGNIN_SESSION_SWITCHES, ...extra],
      }),
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
      translate: Record<string, unknown>;
    };
    assert.equal(prefs.credentials_enable_service, false);
    assert.equal(prefs.credentials_enable_autosignin, false);
    assert.equal(prefs.profile.password_manager_enabled, false);
    assert.equal(prefs.profile.password_manager_leak_detection, false);
    assert.equal(prefs.signin.interception_enabled, false);
    assert.equal(prefs.signin.allowed, true);
    assert.equal(prefs.signin.allowed_on_next_startup, true);
    assert.equal(prefs.intl.accept_languages, "en-US,en");
    assert.equal(prefs.translate.enabled, false);
    // The positive control: Chrome's defaults offer to save the password
    // on the same pages after the same steps (nobody answers it).
    const on = await passwordOffer("password-manager-control", false);
    assert.equal(
      on.offered,
      true,
      "no Save password? offer without the preferences",
    );
  });

  // The webmail browser with the recipe's preferences on a fresh profile,
  // at the loopback sign-in form; the account and the password typed
  // through GuiAssert as the sign-in types them, then Return; the browser
  // stopped once the form was posted, the session left for the caller to
  // stop. `gaia`: Chrome is told the server is Google's sign-in origin.
  async function submitGaiaForm(name: string, gaia: boolean) {
    const profile = join(scratch, name, "chromium");
    mkdirSync(profile, { recursive: true, mode: 0o700 });
    const session = await ga.sessionStart({
      name: `signin-test-${name}-${process.pid}`,
      width: SIGNIN_SCREEN.width,
      height: SIGNIN_SCREEN.height,
      vncSocket: false,
    });
    const sga = ga.inSession(session.id);
    const env = sessionEnv(process.env, session);
    const origin = `http://127.0.0.1:${port}/`;
    const stop = () => ga.sessionStop(session.id);
    try {
      const child = await launch(
        env,
        profile,
        `${origin}gaia/signin`,
        true,
        gaia ? [`--gaia-url=${origin}`] : [],
      );
      try {
        const posted = received.gaia.length;
        const ctx = {
          ga: sga,
          browserPid: child.pid!,
          timings: { focusSettleMs: 600 },
        };
        let ok = false;
        for (const t0 = Date.now(); !ok && Date.now() - t0 < 60_000; ) {
          ok = await focusField(
            ctx,
            (e) =>
              e.role === "text-field" &&
              !e.states.includes("protected") &&
              e.name === "Email or phone",
          );
          if (!ok) await sleep(1000);
        }
        assert.ok(ok, "the account field");
        await sga.type(ADDRESS);
        assert.ok(await focusField(ctx, isPasswordField), "the password field");
        await sga.type(new Secret(SENTINEL));
        await sga.key("Return");
        for (let i = 0; i < 60 && received.gaia.length === posted; i++)
          await sleep(500);
        assert.deepEqual(received.gaia.slice(posted), [ADDRESS]);
        // The welcome page rendered: the login counts as successful.
        await sleep(5000);
      } finally {
        await stopBrowser(child);
      }
      return { profile, env, stop };
    } catch (err) {
      await stop();
      throw err;
    }
  }

  it("Chrome writes a hash of a password submitted on Google's sign-in origin despite the recipe's preferences; the scrub removes it and the next start does not bring it back; off that origin no hash", async () => {
    const g = await submitGaiaForm("gaia-hash", true);
    try {
      // Measured on the browser this test runs (Google Chrome 147 in the dev
      // shell): the password manager off does not stop it.
      const prefs = JSON.parse(
        readFileSync(join(g.profile, "Default", "Preferences"), "utf8"),
      ) as {
        credentials_enable_service: unknown;
        profile: { password_hash_data_list?: unknown[] };
      };
      assert.equal(prefs.credentials_enable_service, false);
      assert.equal(prefs.profile.password_hash_data_list?.length, 1);
      assert.deepEqual(secretsAtRest(g.profile), {
        savedLogins: 0,
        accountLogins: 0,
        passwordHashes: 1,
        unreadable: [],
      });
      // The hash is derived, never the password itself.
      assert.ok(
        !readFileSync(
          join(g.profile, "Default", "Preferences"),
          "utf8",
        ).includes(SENTINEL),
      );
      assert.equal(scrubPasswordHashes(g.profile).removed, 1);
      assert.equal(secretsAtRest(g.profile).passwordHashes, 0);
      // Chrome started again on the scrubbed profile and stopped: still none.
      const again = await launch(
        g.env,
        g.profile,
        `http://127.0.0.1:${port}/gaia/welcome`,
      );
      await sleep(3000);
      await stopBrowser(again);
      assert.deepEqual(secretsAtRest(g.profile), {
        savedLogins: 0,
        accountLogins: 0,
        passwordHashes: 0,
        unreadable: [],
      });
    } finally {
      await g.stop();
    }
    // The control: the same page and steps on an origin that is not
    // Google's sign-in get no hash (the hash above came from the Gaia
    // origin, not from the form).
    const off = await submitGaiaForm("gaia-hash-control", false);
    await off.stop();
    assert.equal(secretsAtRest(off.profile).passwordHashes, 0);
  });

  it("answers the sign-in-again page, recognised by its address and wording in Chrome, with its one 'Next' (the address bar not taken for a field), then the password once", async () => {
    mode = "ok";
    received.password.length = 0;
    const provider: ProviderSignin = {
      ...standInGmail(),
      startUrl: `http://127.0.0.1:${port}/v3/signin/confirmidentifier?continue=x&flowName=GlifWebSignIn`,
      signInAgain: {
        ...GMAIL_SIGNIN.signInAgain!,
        address: { hosts: ["127.0.0.1"], paths: ["/signin/confirmidentifier"] },
      },
    };
    const a = await attempt("sign-in-again", false, { provider });
    try {
      assert.deepEqual(
        a.result.outcome,
        { result: "signed-in", typed: true },
        a.events.join("\n"),
      );
      assert.deepEqual(a.result.steps, [
        "sign-in-again",
        "password",
        "interstitial:home-address",
      ]);
      assert.deepEqual(received.password, [SENTINEL]);
      const clicked = a.events.indexOf(
        '  Google asks to sign in again: clicked "Next"',
      );
      assert.ok(clicked > a.events.indexOf("first-input"), a.events.join("\n"));
      assert.ok(a.events.indexOf("first-input") >= 0);
    } finally {
      await stopBrowser(a.child);
      await ga.sessionStop(a.session.id);
    }
  });

  it("waits through the sign-in-again page changing in place after its 'Next' (its wording under the password page's address for several seconds), then types the password once", async () => {
    mode = "ok";
    received.password.length = 0;
    const provider: ProviderSignin = {
      ...standInGmail(),
      startUrl: `http://127.0.0.1:${port}/v3/signin/confirmidentifier?inplace=1&flowName=GlifWebSignIn`,
      signInAgain: {
        ...GMAIL_SIGNIN.signInAgain!,
        address: { hosts: ["127.0.0.1"], paths: ["/signin/confirmidentifier"] },
      },
    };
    const a = await attempt("sign-in-again-inplace", false, { provider });
    try {
      assert.deepEqual(
        a.result.outcome,
        { result: "signed-in", typed: true },
        a.events.join("\n"),
      );
      assert.deepEqual(a.result.steps, [
        "sign-in-again",
        "password",
        "interstitial:home-address",
      ]);
      assert.deepEqual(received.password, [SENTINEL]);
      // The race was met: a frame of the old wording under the new
      // address, read again with no input.
      const clicked = a.events.indexOf(
        '  Google asks to sign in again: clicked "Next"',
      );
      const waited = a.events.findIndex((e) =>
        /^screen: the sign-in-again page moving on \(its wording, the address (?:https?:\/\/)?127\.0\.0\.1:\d+\/v3\/signin\/challenge\/pwd\?TL=x\); read again$/.test(
          e,
        ),
      );
      assert.ok(clicked >= 0 && waited > clicked, a.events.join("\n"));
      assert.ok(
        a.events.indexOf("before-password") > waited,
        a.events.join("\n"),
      );
    } finally {
      await stopBrowser(a.child);
      await ga.sessionStop(a.session.id);
    }
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

  const purposeProvider = (sessionId: string): ProviderSignin => ({
    ...standInGmail(),
    startUrl: `http://consent.localhost:${port}/v2/collectConsent?sessionId=${sessionId}`,
    consent: {
      name: "loopback-consent",
      hosts: ["consent.localhost"],
      paths: ["collectconsent"],
    },
  });

  it("answers Yahoo's per-purpose consent dialog after its reject-all page in real Chrome: the off-screen purpose reached by the wheel, every purpose rejected, saved once, then the sign-in", async () => {
    mode = "ok";
    received.identifier.length = 0;
    received.password.length = 0;
    received.purposes.length = 0;
    const a = await attempt("purposes", false, {
      provider: purposeProvider("y"),
    });
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
      // Reject all on the first page; every purpose rejected on the
      // second (the smart features' Allow was selected), posted once.
      assert.deepEqual(
        received.purposes,
        ["first:reject", "second:reject,reject,reject"],
        a.events.join("\n"),
      );
      assert.deepEqual(received.password, [SENTINEL]);
      const up = a.events.findIndex((e) =>
        /scrolled up to the next reject choices/.test(e),
      );
      const smart = a.events.findIndex((e) =>
        /chose "За предоставяне на интелигентни функции, Отхвърляне" on/.test(
          e,
        ),
      );
      const saved = a.events.filter((e) =>
        /every row rejected \(3\); clicked "Запазване на избора"/.test(e),
      );
      assert.ok(up >= 0 && smart > up, a.events.join("\n"));
      assert.equal(saved.length, 1, a.events.join("\n"));
      assert.ok(a.events.indexOf(saved[0]!) > smart);
      assert.equal(a.events.filter((e) => e === "first-input").length, 1);
    } finally {
      await stopBrowser(a.child);
      await ga.sessionStop(a.session.id);
    }
  });

  it("stops consent-required on the dialog in real Chrome when a purpose's choice is named otherwise, with no input on it and nothing posted", async () => {
    mode = "ok";
    received.identifier.length = 0;
    received.password.length = 0;
    received.purposes.length = 0;
    const a = await attempt("purposes-odd", false, {
      provider: purposeProvider("odd"),
    });
    try {
      assert.equal(
        a.result.outcome.result,
        "consent-required",
        a.events.join("\n"),
      );
      assert.ok(a.result.outcome.result === "consent-required");
      assert.match(
        a.result.outcome.why,
        /a choice named "За предоставяне на интелигентни функции, Може би"/,
      );
      // Only the first page's reject-all was posted; the dialog got no
      // input (nothing scrolled or chosen) and was never saved.
      assert.deepEqual(received.purposes, ["first:reject"]);
      assert.ok(
        !a.events.some((e) => /scrolled|chose|Запазване/.test(e)),
        a.events.join("\n"),
      );
      assert.deepEqual(received.identifier, []);
      assert.deepEqual(received.password, []);
    } finally {
      await stopBrowser(a.child);
      await ga.sessionStop(a.session.id);
    }
  });

  // The webmail browser on a fresh profile with the recipe's preferences
  // (`translate`, when not null, overrides Chrome's page translation in
  // them), at the Bulgarian page; no input. Returns the name of the first
  // check box the browser's tree showed within the watch (what the
  // consent round looks for, by the browser's process: Chrome's Translate
  // bubble has "Always translate"), or null.
  async function translateOffer(name: string, translate: boolean | null) {
    const profile = join(scratch, name, "chromium");
    mkdirSync(profile, { recursive: true, mode: 0o700 });
    writeWebmailProfilePrefs(profile);
    if (translate !== null) {
      const path = join(profile, "Default", "Preferences");
      const p = JSON.parse(readFileSync(path, "utf8")) as Record<
        string,
        unknown
      >;
      p.translate = { enabled: translate };
      writeFileSync(path, JSON.stringify(p), { mode: 0o600 });
    }
    const session = await ga.sessionStart({
      name: `signin-test-${name}-${process.pid}`,
      width: SIGNIN_SCREEN.width,
      height: SIGNIN_SCREEN.height,
      vncSocket: false,
    });
    const sga = ga.inSession(session.id);
    try {
      const child = await launch(
        sessionEnv(process.env, session),
        profile,
        `http://consent.localhost:${port}/bg`,
        false,
      );
      let box: string | null = null;
      try {
        const watchMs = 30_000;
        const t0 = Date.now();
        while (box === null && Date.now() - t0 < watchMs) {
          const boxes = await sga.find({ pid: child.pid!, role: "checkbox" });
          if (boxes.length > 0) box = boxes[0]!.name ?? "";
          else await sleep(1000);
        }
      } finally {
        await stopBrowser(child);
      }
      return { box, profile };
    } finally {
      await ga.sessionStop(session.id);
    }
  }

  it("keeps Chrome's Translate bubble (its 'Always translate' check box) off a page in Bulgarian with the profile's preferences; with page translation on, the bubble shows", async () => {
    const off = await translateOffer("translate-off", null);
    assert.equal(
      off.box,
      null,
      "a check box in the browser with the preferences",
    );
    // Chrome kept the preference across its start (it writes its
    // preferences back on exit).
    const prefs = JSON.parse(
      readFileSync(join(off.profile, "Default", "Preferences"), "utf8"),
    ) as { translate: Record<string, unknown> };
    assert.equal(prefs.translate.enabled, false);
    // The positive control: the same preferences with page translation
    // on (Chrome's default) show the bubble on the same page.
    const on = await translateOffer("translate-control", true);
    assert.match(
      on.box ?? "",
      /translate/i,
      "no Translate bubble with translation on",
    );
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
