// tools/capture/email-webmail-signin.ts — `just email-webmail-signin`:
// signs a hosted-webmail QA account's browser profile in, by itself,
// with the account file's address and password, and checks it.
//
// For each account (SET's every account file, or the one named):
// 1. The guard (providers/webmail_signin_guard.ts): one automated
//    attempt per account, then a 24 h cool-down; a refused attempt
//    starts no browser. The account's lease (webmail_accounts.ts) keeps
//    a capture run off the profile meanwhile.
// 2. A private off-screen GuiAssert session (linux-xvfb), with an
//    owner-only VNC socket when asked (--vnc, --takeover, --manual).
// 3. The dev shell's webmail browser (Google Chrome; webmail_profiles.ts
//    `webmailBrowser`) started normally in that session (no Playwright,
//    no DevTools protocol, no automation switch), on the account's
//    profile, its sandbox checked, with the profile's preferences written
//    first (`writeWebmailProfilePrefs`: the password manager off, Chrome's
//    sign-in interception off, the pages' languages), so Chrome never
//    offers to save the password or to sign itself in over the
//    provider's page.
// 4. The sign-in (providers/webmail_signin.ts): OCR of the display read
//    through the password guard, the provider's screens and challenges
//    (providers/webmail_signin_steps.ts), OS-level input; a challenge or
//    an error stops it and is never retried; a privacy-consent page is
//    answered rejecting every optional use, or left to a person
//    (`consent-required`).
// 5. The browser closed (SIGINT, so its cookies are written), then the
//    check: the same browser started again in the same session, without
//    automation, on the inbox URL, and the mailbox read off the screen by
//    OCR (providers/webmail_signin.ts `verifySignedIn`; not signed in, the
//    screen is kept as check-screen.png); signin.json is written.
//    `--playwright-check` adds the earlier check under Playwright, which a
//    provider can see as automation, so it is off by default.
// 6. Once every browser on the profile has stopped, the saved passwords
//    it holds are counted (webmail_profiles.ts `secretsAtRest`, no value
//    read): any is a failure (exit 8), whatever the sign-in's result.
//
// `--typing-check` contacts no provider: the same session and browser,
// on a throw-away profile, at a loopback page that compares a salted
// SHA-256 of what was typed with the account file's password
// (providers/webmail_typing_check.ts). Not an attempt: no record, no
// cool-down, no lease, the account's profile untouched.
//
// The password is read from the account file into memory and leaves it
// only on a pipe to `guiassert` (`type --stdin`, `--secret-stdin`):
// never on a command line, in an environment, on stdout or stderr, in a
// record, or in a kept screenshot (each one passes GuiAssert's guard).

import { spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { hostname, userInfo } from "node:os";
import { join, resolve } from "node:path";
import { createInterface, type Interface } from "node:readline/promises";
import { pathToFileURL } from "node:url";
import { resolveDriver } from "./providers/browser_emulation.ts";
import {
  type GaSession,
  GuiAssert,
  GuiAssertError,
  Secret,
  sessionEnv,
} from "./providers/guiassert.ts";
import {
  CredentialsUnavailable,
  loadHostedAccount,
} from "./providers/hosted_delivery.ts";
import {
  credentialsDir,
  currentHost,
  findExecutable,
  type HostEnv,
} from "./providers/requirements.ts";
import {
  clearNeedsLogin,
  dailyBudget,
  poolAccounts,
  releaseLease,
  tryLease,
} from "./providers/webmail_accounts.ts";
import {
  DEFAULT_TIMINGS,
  driveSignin,
  outcomeName,
  SIGNIN_SCREEN,
  SIGNIN_SESSION_SWITCHES,
  type SigninContext,
  type SigninOutcome,
  typePasswordIntoField,
  verifySignedIn,
} from "./providers/webmail_signin.ts";
import {
  type AttemptRecord,
  beginAttempt,
  COOLDOWN_MS,
  finishAttempt,
  guardAttempt,
  markPasswordTyped,
} from "./providers/webmail_signin_guard.ts";
import { PROVIDER_SIGNIN } from "./providers/webmail_signin_steps.ts";
import {
  accountName,
  accountProfile,
  checkSignedIn,
  holdsSecrets,
  PROFILES_ENV,
  profilesRoot,
  secretsAtRest,
  signinBrowserArgs,
  stopBrowser,
  waitSandboxed,
  type WebmailBrowser,
  WEBMAIL_SIGNIN,
  webmailBrowser,
  webmailLaunchOptions,
  writeSigninRecord,
  writeWebmailProfilePrefs,
} from "./providers/webmail_profiles.ts";
import {
  runTypingCheck,
  startTypingCheckServer,
} from "./providers/webmail_typing_check.ts";
import { installSignalCleanup } from "./signal_cleanup.ts";

const SETS = Object.keys(PROVIDER_SIGNIN).filter((s) => s in WEBMAIL_SIGNIN);

const USAGE = `usage: email-webmail-signin SET [ACCOUNT] [--account NAME]
                            [--vnc] [--takeover] [--manual] [--check-only]
                            [--typing-check] [--override-cooldown] [--dir DIR]
                            [--timeout SECONDS] [--playwright-check]
                            [--unsafe-no-sandbox]

Signs a hosted-webmail QA account's browser profile in, by itself, with
the account file's address and password. Sets: ${SETS.join(", ")}.
Every account of SET (SET/*.json), or only ACCOUNT (SET/ACCOUNT.json).

Per account: refuses within ${COOLDOWN_MS / 3600_000} h of its last automated attempt
(whatever that attempt's result); starts a private off-screen session
(GuiAssert, Xvfb); starts the webmail browser (Google Chrome) normally
in it (no automation; its sandbox checked) on the account's profile under
$${PROFILES_ENV} (default \${XDG_STATE_HOME:-$HOME/.local/state}/isonim-email/webmail-profiles);
reads each screen by OCR (never answering a frame that shows the
password) and types the address and the password through OS-level input,
each only into the field meant for it; stops at any challenge (captcha,
a code, a phone, a passkey, "verify it's you", ...) and never retries;
then closes the browser, starts it again on the inbox URL and reads the
mailbox off the screen (no input, no automation), and on success writes
signin.json.

--vnc               serve the session on an owner-only VNC socket, to
                    watch it (prints the ssh -L line)
--takeover          (implies --vnc) on a challenge, a consent page it
                    cannot answer or an unrecognised screen, leave the
                    browser open for a person over VNC; press Enter here
                    when done, and it is checked
--manual            (implies --vnc) a person signs in over VNC; the
                    recipe types nothing, except the password into the
                    focused password field on request (p, then Enter);
                    not an automated attempt
--check-only        only check (and record) an existing profile; types
                    nothing; not signed in, keeps check-screen.png
--typing-check      contacts no provider: types the account's password
                    the way the sign-in does into a loopback page, which
                    compares a salted SHA-256 of what arrived with the
                    account file's; prints MATCH or MISMATCH (and whether
                    the lengths match), nothing else; not an attempt
--playwright-check  also check the profile under Playwright (RISK: the
                    provider sees an automated browser on the account's
                    session: navigator.webdriver, --enable-automation)
--override-cooldown OPERATOR OVERRIDE: attempt even within the cool-down
                    (each password sign-in a provider challenges raises
                    the chance it locks the account)
--dir DIR           the credentials directory (default $ISONIM_EMAIL_CREDENTIALS_DIR,
                    else \${XDG_CONFIG_HOME:-$HOME/.config}/metacraft/dev-credentials/isonim-email)
--timeout S         how long the check waits for the mailbox (default 45)
--unsafe-no-sandbox UNSAFE: run the browsers with Chromium's sandbox off,
                    on a host where it cannot run

Exit status: 0 signed in (recorded), or the typing check matched; 1 not
signed in, or failed (wrong password, unknown account, an unrecognised
screen, a typing-check mismatch, ...); 2 usage; 3
pending (no account file); 4 this host cannot run it (no usable sandbox,
no GuiAssert session, no webmail browser); 5 challenged, or a consent
page it cannot answer (a person must finish it); 6 refused (cool-down, or
the account in use); 7 stopped: the password was legible on the screen;
8 the profile holds a saved password (a secret at rest), whatever the
sign-in's result; 128+N signal N. With several accounts, the first
account's non-zero status.
`;

interface Options {
  set: string;
  account: string | undefined;
  checkOnly: boolean;
  typingCheck: boolean;
  vnc: boolean;
  takeover: boolean;
  manual: boolean;
  overrideCooldown: boolean;
  timeoutS: number;
  playwrightCheck: boolean;
  unsafeNoSandbox: boolean;
}

const EXIT = {
  signedIn: 0,
  failed: 1,
  usage: 2,
  pending: 3,
  hostCannot: 4,
  challenged: 5,
  refused: 6,
  secretVisible: 7,
  secretAtRest: 8,
} as const;

function exitFor(o: SigninOutcome): number {
  switch (o.result) {
    case "signed-in":
      return EXIT.signedIn;
    case "challenged":
    case "consent-required":
      return EXIT.challenged;
    case "secret-visible":
      return EXIT.secretVisible;
    default:
      return EXIT.failed;
  }
}

/** The outcomes a person can finish over VNC (--takeover). */
const TAKEOVER_OUTCOMES = new Set([
  "challenged",
  "consent-required",
  "unknown-screen",
  "stuck",
  "field-not-found",
  "deadline",
]);

function say(line: string): void {
  process.stdout.write(`${line}\n`);
}

function readPassword(host: HostEnv, file: string): Secret {
  let obj: { password?: unknown };
  try {
    obj = JSON.parse(
      readFileSync(join(credentialsDir(host), file), "utf8"),
    ) as {
      password?: unknown;
    };
  } catch {
    throw new CredentialsUnavailable(`${file} cannot be read as JSON`);
  }
  if (typeof obj.password !== "string" || obj.password === "")
    throw new CredentialsUnavailable(`${file} has no password`);
  return new Secret(obj.password);
}

function vncHint(s: GaSession): string[] {
  const user = userInfo().username;
  return [
    `VNC: the session is served on ${s.vncSocket} (only ${user} can connect).`,
    `  From another machine:  ssh -L 5901:${s.vncSocket} ${user}@${hostname()}`,
    "  then a VNC viewer on   localhost:5901",
    "  (ssh stream-local forwarding, OpenSSH 6.7+; on this machine a viewer can open the socket directly)",
  ];
}

async function ask(rl: Interface | null, prompt: string): Promise<string> {
  if (rl === null) return "";
  try {
    return await rl.question(prompt);
  } catch {
    return ""; // stdin closed
  }
}

/**
 * The webmail browser started normally in the session (`env`) on
 * `userDataDir` at `url`, the browser's own sign-in turned off in the
 * profile first, its sandbox checked; `onChild` sees the process as soon
 * as it exists (for the signal cleanup). Null, said why, when it cannot
 * run sandboxed.
 */
async function launchWebmailBrowser(a: {
  chrome: WebmailBrowser;
  userDataDir: string;
  url: string;
  env: Record<string, string>;
  unsafeNoSandbox: boolean;
  label: string;
  onChild: (c: ChildProcess) => void;
}): Promise<ChildProcess | null> {
  writeWebmailProfilePrefs(a.userDataDir);
  let said = "";
  const child = spawn(
    a.chrome.path,
    signinBrowserArgs(a.userDataDir, a.url, {
      unsafeNoSandbox: a.unsafeNoSandbox,
      extra: [...SIGNIN_SESSION_SWITCHES],
    }),
    { env: a.env, stdio: ["ignore", "ignore", "pipe"] },
  );
  a.onChild(child);
  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", (d: string) => {
    said = (said + d).slice(-8192);
  });
  if (a.unsafeNoSandbox) {
    say(
      `WARNING: ${a.label}: --unsafe-no-sandbox: the browser runs WITHOUT Chromium's sandbox.`,
    );
    return child;
  }
  const sandboxed = await waitSandboxed(child, a.userDataDir, () => said);
  if (sandboxed.ok) return child;
  await stopBrowser(child);
  say(
    `CANNOT RUN: ${a.label}: Chromium's sandbox is not running (${sandboxed.reason}). ` +
      "It needs unprivileged user namespaces (or a setuid sandbox named by CHROME_DEVEL_SANDBOX); --unsafe-no-sandbox runs without it, unsafely.",
  );
  return null;
}

/**
 * `--typing-check`: the account's password typed the way the sign-in
 * types it into a loopback page that compares digests. No provider, no
 * attempt record, no lease, and the account's profile is not opened.
 */
async function typingCheckAccount(
  o: Options,
  host: HostEnv,
  label: string,
  password: Secret,
  bin: string,
): Promise<number> {
  const chrome = webmailBrowser(host.env);
  if ("reason" in chrome) throw new Error(chrome.reason);
  const root = profilesRoot(host);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const work = mkdtempSync(join(root, ".typing-check-"));
  const userDataDir = join(work, "chromium");
  const framesDir = join(work, "frames");
  mkdirSync(userDataDir, { mode: 0o700 });
  mkdirSync(framesDir, { mode: 0o700 });
  const stateDir = join(root, ".guiassert-state");
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const ga = new GuiAssert({ bin, stateDir, env: host.env, timeoutMs: 60_000 });
  const server = await startTypingCheckServer(password);
  let session: GaSession | null = null;
  let browser: ChildProcess | null = null;
  const cleanup = (): void => {
    if (
      browser !== null &&
      browser.exitCode === null &&
      browser.signalCode === null
    )
      browser.kill("SIGINT");
    if (session !== null) ga.sessionStopSync(session.id);
    session = null;
    rmSync(work, { recursive: true, force: true });
  };
  const removeCleanup = installSignalCleanup(cleanup);
  try {
    try {
      session = await ga.sessionStart({
        name: `typing-check-${o.set}-${process.pid}`,
        width: SIGNIN_SCREEN.width,
        height: SIGNIN_SCREEN.height,
        vncSocket: o.vnc,
      });
    } catch (err) {
      if (err instanceof GuiAssertError) {
        say(`CANNOT RUN: ${label}: no private display session: ${err.message}`);
        return EXIT.hostCannot;
      }
      throw err;
    }
    if (o.vnc) for (const l of vncHint(session)) say(l);
    say(
      `${label}: typing check: ${chrome.label} on a throw-away profile at a loopback page; no provider is contacted`,
    );
    const child = await launchWebmailBrowser({
      chrome,
      userDataDir,
      url: server.url,
      env: sessionEnv(host.env, session),
      unsafeNoSandbox: o.unsafeNoSandbox,
      label,
      onChild: (c) => (browser = c),
    });
    if (child === null) return EXIT.hostCannot;
    if (child.pid === undefined) throw new Error("the browser did not start");
    let r;
    try {
      r = await runTypingCheck({
        ga: ga.inSession(session.id),
        browserPid: child.pid,
        timings: { focusSettleMs: DEFAULT_TIMINGS.focusSettleMs },
        server,
        typed: password,
        guard: password,
        framesDir,
        timeoutMs: o.timeoutS * 1000,
        pollMs: 1000,
        log: (l) => say(`${label}: ${l}`),
      });
    } finally {
      await stopBrowser(child);
    }
    switch (r.result) {
      case "match":
        say(`TYPING CHECK MATCH: ${label} (length match: yes)`);
        return EXIT.signedIn;
      case "mismatch":
        say(
          `TYPING CHECK MISMATCH: ${label} (length match: ${r.lengthMatch ? "yes" : "no"}): what reached the page is not the account file's password.`,
        );
        return EXIT.failed;
      case "secret-visible":
        say(
          `STOPPED (secret-visible): ${label}: the password was legible on the check page's screen; no frame kept.`,
        );
        return EXIT.secretVisible;
      case "failed":
        say(`TYPING CHECK FAILED: ${label}: ${r.reason}`);
        return EXIT.failed;
    }
  } finally {
    cleanup();
    removeCleanup();
    await server.close();
  }
}

/**
 * The account's sign-in, then (once its browsers have stopped) the count
 * of saved passwords in its profile: any, or a database that cannot be
 * read, is exit 8 whatever the sign-in's result. Not after a run that
 * never opened the profile (pending, refused, the typing check).
 */
async function signInAccount(
  o: Options,
  host: HostEnv,
  file: string,
  bin: string,
  rl: Interface | null,
): Promise<number> {
  const label = `${o.set}/${accountName(file)}`;
  const opened = { profile: null as string | null };
  const code = await signInAccountOnce(o, host, file, bin, rl, opened);
  if (opened.profile === null) return code;
  let s = secretsAtRest(opened.profile);
  // A browser stopped a moment ago may still hold a database's lock.
  if (s.unreadable.length > 0) {
    await new Promise((r) => setTimeout(r, 3000));
    s = secretsAtRest(opened.profile);
  }
  if (!holdsSecrets(s)) return code;
  say(
    `SECRET AT REST: ${label}: the browser profile holds ${s.savedLogins} saved login(s) in Login Data, ${s.accountLogins} in Login Data For Account and ${s.passwordHashes} password hash(es)` +
      (s.unreadable.length > 0
        ? `; could not count: ${s.unreadable.join(", ")}`
        : "") +
      ` (${opened.profile}). The password must never be persisted by the browser: remove it (Chrome's password manager in a --manual session, or delete the two Login Data files with no browser running; a password hash: delete profile.password_hash_data_list from Default/Preferences with no browser running), then rotate the password if the profile was copied anywhere (runbook docs/webmail-signin.md, "No saved password at rest").`,
  );
  return EXIT.secretAtRest;
}

async function signInAccountOnce(
  o: Options,
  host: HostEnv,
  file: string,
  bin: string,
  rl: Interface | null,
  opened: { profile: string | null },
): Promise<number> {
  const label = `${o.set}/${accountName(file)}`;
  const automated = !o.checkOnly && !o.manual;
  const provider = PROVIDER_SIGNIN[o.set]!;
  const w = WEBMAIL_SIGNIN[o.set]!;
  let acct;
  let password: Secret;
  try {
    acct = loadHostedAccount(o.set, host, {
      account: accountName(file),
      needsAppPassword: false,
    });
    password = readPassword(host, acct.file);
  } catch (err) {
    if (err instanceof CredentialsUnavailable) {
      say(`PENDING: ${label}: ${err.message}`);
      return EXIT.pending;
    }
    throw err;
  }
  if (o.typingCheck) return typingCheckAccount(o, host, label, password, bin);
  const profile = accountProfile(host, o.set, acct.file, true);

  // 1. The guard, before anything starts.
  let overridden = false;
  if (automated) {
    const v = guardAttempt(profile, Date.now(), {
      override: o.overrideCooldown,
    });
    if (!v.allowed) {
      say(
        `REFUSED: ${label}: ${v.why}.${v.until === null ? "" : ` The next automated attempt is allowed from ${v.until}.`} ` +
          "Check the profile with --check-only, sign in over VNC with --manual, or (operator) --override-cooldown.",
      );
      return EXIT.refused;
    }
    overridden = v.overridden;
    if (overridden)
      say(
        `WARNING: ${label}: --override-cooldown: attempting within the cool-down (the last attempt is in ${join(profile.dir, "signin-attempt.json")}).`,
      );
  }
  const lease = tryLease(profile, `signin-${process.pid}`);
  if (lease === null) {
    say(
      `REFUSED: ${label}: another run holds the account's lease (${join(profile.dir, "lease.json")}).`,
    );
    return EXIT.refused;
  }

  const stateDir = join(profilesRoot(host), ".guiassert-state");
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const ga = new GuiAssert({ bin, stateDir, env: host.env, timeoutMs: 60_000 });
  const framesDir = join(profile.dir, "signin-frames");
  let session: GaSession | null = null;
  let browser: ChildProcess | null = null;
  let attempt: AttemptRecord | null = null;
  let finished = false;
  const finish = (result: string): void => {
    if (attempt !== null && !finished) {
      attempt = finishAttempt(profile, attempt, result, Date.now());
      finished = true;
    }
  };
  // Ctrl-C, a closed terminal, a kill, an exception: the browser stopped
  // (SIGINT, so it writes its cookies), the session stopped, the attempt
  // closed as interrupted, the lease released.
  const cleanup = (): void => {
    if (
      browser !== null &&
      browser.exitCode === null &&
      browser.signalCode === null
    )
      browser.kill("SIGINT");
    if (session !== null) ga.sessionStopSync(session.id);
    session = null;
    finish("interrupted");
    rmSync(framesDir, { recursive: true, force: true });
    releaseLease(lease);
  };
  const removeCleanup = installSignalCleanup(cleanup);
  try {
    const vnc = o.vnc || o.takeover || o.manual;
    try {
      session = await ga.sessionStart({
        name: `signin-${o.set}-${accountName(file)}-${process.pid}`,
        width: SIGNIN_SCREEN.width,
        height: SIGNIN_SCREEN.height,
        vncSocket: vnc,
      });
    } catch (err) {
      if (err instanceof GuiAssertError) {
        say(`CANNOT RUN: ${label}: no private display session: ${err.message}`);
        return EXIT.hostCannot;
      }
      throw err;
    }
    const sga = ga.inSession(session.id);
    const env = sessionEnv(host.env, session);
    if (vnc) for (const l of vncHint(session)) say(l);
    // From here a browser may open the profile.
    opened.profile = profile.userDataDir;

    const chrome = webmailBrowser(host.env);
    if ("reason" in chrome) throw new Error(chrome.reason);
    // The webmail browser on the account's profile, started normally in
    // the session at `url`, its sandbox checked; null (said why) when it
    // cannot run sandboxed.
    const startBrowser = (url: string): Promise<ChildProcess | null> =>
      launchWebmailBrowser({
        chrome,
        userDataDir: profile.userDataDir,
        url,
        env,
        unsafeNoSandbox: o.unsafeNoSandbox,
        label,
        onChild: (c) => (browser = c),
      });
    mkdirSync(framesDir, { recursive: true, mode: 0o700 });

    let outcome: SigninOutcome | null = null;
    let screen: string | null = null;
    if (!o.checkOnly) {
      const child = await startBrowser(provider.startUrl);
      if (child === null) return EXIT.hostCannot;
      if (child.pid === undefined) throw new Error("the browser did not start");
      const ctx: SigninContext = {
        ga: sga,
        provider,
        browserPid: child.pid,
        address: acct.address,
        password,
        framesDir,
        keepPath: join(profile.dir, "signin-screen.png"),
        timings: DEFAULT_TIMINGS,
        onFirstInput: () => {
          attempt = beginAttempt(profile, {
            set: o.set,
            accountFile: acct.file,
            nowMs: Date.now(),
            override: overridden,
          });
        },
        onBeforePassword: () => {
          if (attempt !== null) attempt = markPasswordTyped(profile, attempt);
        },
        log: (l) => say(`${label}: ${l}`),
      };

      if (o.manual) {
        say(
          `${label}: --manual: sign in over VNC. Here: p then Enter types the password into the focused password field (once); Enter alone when the inbox shows.`,
        );
        let typed = false;
        for (;;) {
          const a = (await ask(rl, "> ")).trim().toLowerCase();
          if (a !== "p") break;
          if (typed) {
            say(
              `${label}: the password was typed once already; type it over VNC if it is needed again.`,
            );
            continue;
          }
          const ok = await typePasswordIntoField(ctx);
          typed = ok;
          say(
            ok
              ? `${label}: typed the password into the focused protected field.`
              : `${label}: no password field has the focus (click into it over VNC first).`,
          );
        }
      } else {
        say(`${label}: signing in to ${provider.label} (${provider.startUrl})`);
        let r;
        try {
          r = await driveSignin(ctx);
        } catch (err) {
          finish(
            `error: ${err instanceof Error ? err.message.split("\n")[0] : String(err)}`,
          );
          throw err;
        }
        outcome = r.outcome;
        screen = r.screen;
        const took = `${Math.round(r.elapsedMs / 1000)} s`;
        if (outcome.result === "signed-in" && !outcome.typed)
          say(
            `${label}: the profile was still signed in; nothing typed (${took}).`,
          );
        else if (outcome.result !== "signed-in") {
          const shot =
            screen === null ? "no screenshot kept" : `screenshot: ${screen}`;
          const what =
            outcome.result === "challenged"
              ? `CHALLENGED (${outcome.challenge}): ${label}: "${outcome.phrase}" after ${took}; a person must finish it; ${shot}. Not retried.`
              : outcome.result === "consent-required"
                ? `CONSENT REQUIRED (${outcome.consent}): ${label}: a privacy-consent page it cannot answer (${outcome.why}) after ${took}; a person answers it once (--takeover, or --manual), rejecting every optional use; ${shot}. Not retried.`
                : outcome.result === "secret-visible"
                  ? `STOPPED (secret-visible): ${label}: the password was legible on the screen after ${took}; no frame kept. Not retried.`
                  : `FAILED (${outcomeName(outcome)}): ${label}: after ${took}; ${shot}. Not retried.`;
          say(what);
          if (outcome.result === "wrong-password")
            say(
              `${label}: the provider refused the account file's password. Do not run the sign-in again until the credential is corrected: re-seal it at its source (runbook docs/webmail-signin.md, "Re-sealing a QA password"), then confirm it with --typing-check.`,
            );
          if (o.takeover && TAKEOVER_OUTCOMES.has(outcome.result)) {
            say(
              `${label}: --takeover: the browser stays open; finish the sign-in over VNC, then press Enter here.`,
            );
            await ask(rl, "Enter when the inbox shows: ");
          } else {
            finish(outcomeName(outcome));
            await stopBrowser(child);
            say(
              attempt !== null
                ? `${label}: the next automated attempt is allowed from ${new Date(Date.parse((attempt as AttemptRecord).started_at) + COOLDOWN_MS).toISOString()}.`
                : `${label}: no input reached the provider: no attempt recorded, so no cool-down.`,
            );
            return exitFor(outcome);
          }
        }
      }
      await stopBrowser(child);
    }

    // 5. The check, in the same session: the browser started again on
    // the inbox URL, the mailbox read off the screen; nothing typed.
    say(
      `${label}: checking the profile: ${chrome.label} started again on ${w.inboxUrl}, the mailbox read off the screen…`,
    );
    const checker = await startBrowser(w.inboxUrl);
    if (checker === null) return EXIT.hostCannot;
    let verified;
    try {
      verified = await verifySignedIn({
        ga: sga,
        provider,
        ...(checker.pid === undefined ? {} : { browserPid: checker.pid }),
        keepPath: join(profile.dir, "check-screen.png"),
        password,
        framesDir,
        timeoutMs: o.timeoutS * 1000,
        settleMs: 5000,
        pollMs: 1000,
        log: (l) => say(`${label}: ${l}`),
      });
    } finally {
      await stopBrowser(checker);
    }
    let checked:
      | { signedIn: true; host: string }
      | {
          signedIn: false;
          reason: string;
        } = verified.signedIn
      ? { signedIn: true, host: new URL(w.inboxUrl).host }
      : verified;

    // Opt-in only: Playwright's launch is visible to the provider as an
    // automated browser on the account's session (navigator.webdriver,
    // --enable-automation), which risks the session the check is for.
    if (checked.signedIn && o.playwrightCheck) {
      say(
        `WARNING: ${label}: --playwright-check: opening the profile under Playwright; the provider can see it as automation.`,
      );
      const driver = resolveDriver(host.env);
      if ("reason" in driver) throw new Error(driver.reason);
      const pw: typeof import("playwright-core") = await import(
        pathToFileURL(join(driver.dir, "index.mjs")).href
      );
      const context = await pw.chromium.launchPersistentContext(
        profile.userDataDir,
        {
          ...webmailLaunchOptions(host.env, false, {
            unsafeNoSandbox: o.unsafeNoSandbox,
          }),
          env,
        },
      );
      try {
        checked = await checkSignedIn(context, w, o.timeoutS * 1000);
      } finally {
        await context.close();
      }
    }
    const prefix =
      outcome === null || outcome.result === "signed-in"
        ? ""
        : `${outcomeName(outcome)}, taken over; `;
    if (!checked.signedIn) {
      finish(`${prefix}not-signed-in`);
      say(`NOT SIGNED IN: ${label}: ${checked.reason}`);
      if (!verified.signedIn)
        say(
          `${label}: the check saw: ${verified.seen ?? "unrecognised"}; ${verified.screen === undefined || verified.screen === null ? "no screenshot kept" : `screenshot: ${verified.screen}`}.`,
        );
      return outcome !== null && outcome.result !== "signed-in"
        ? exitFor(outcome)
        : EXIT.failed;
    }
    finish(`${prefix}signed-in`);
    clearNeedsLogin(profile);
    writeSigninRecord(profile, {
      set: o.set,
      account_file: acct.file,
      signed_in_at: new Date().toISOString(),
      host: checked.host,
      browser: `${chrome.label} (${chrome.path})`,
      verified_by: o.playwrightCheck ? "ocr+playwright" : "ocr",
    });
    say(
      `SIGNED IN: ${label} on ${checked.host}; recorded in ${profile.record}`,
    );
    return EXIT.signedIn;
  } finally {
    cleanup();
    removeCleanup();
  }
}

function parseArgs(args: string[]): Options | string {
  let set: string | undefined;
  let account: string | undefined;
  const o = {
    checkOnly: false,
    typingCheck: false,
    vnc: false,
    takeover: false,
    manual: false,
    overrideCooldown: false,
    timeoutS: 45,
    playwrightCheck: false,
    unsafeNoSandbox: false,
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    const value = (): string => {
      const v = args[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === "--account") account = value();
    else if (a === "--check-only") o.checkOnly = true;
    else if (a === "--typing-check") o.typingCheck = true;
    else if (a === "--vnc") o.vnc = true;
    else if (a === "--takeover") o.takeover = true;
    else if (a === "--manual") o.manual = true;
    else if (a === "--override-cooldown") o.overrideCooldown = true;
    else if (a === "--dir")
      process.env.ISONIM_EMAIL_CREDENTIALS_DIR = resolve(value());
    else if (a === "--timeout") o.timeoutS = Number(value());
    else if (a === "--playwright-check") o.playwrightCheck = true;
    else if (a === "--unsafe-no-sandbox") o.unsafeNoSandbox = true;
    else if (a.startsWith("-")) return `unknown option ${a}`;
    else if (set === undefined) set = a;
    else if (account === undefined) account = a;
    else return "one SET and at most one ACCOUNT";
  }
  if (set === undefined || !SETS.includes(set)) return "unknown set";
  if (!(o.timeoutS > 0)) return "bad timeout";
  if (o.manual && o.checkOnly)
    return "--manual and --check-only exclude each other";
  if (o.manual && o.takeover)
    return "--manual and --takeover exclude each other";
  if (o.overrideCooldown && (o.manual || o.checkOnly))
    return "--override-cooldown applies to an automated attempt only";
  if (
    o.typingCheck &&
    (o.manual ||
      o.checkOnly ||
      o.takeover ||
      o.overrideCooldown ||
      o.playwrightCheck)
  )
    return "--typing-check takes only --vnc, --dir, --timeout and --unsafe-no-sandbox";
  return { set, account, ...o };
}

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
    process.stdout.write(USAGE);
    return args.length === 0 ? EXIT.usage : 0;
  }
  const o = parseArgs(args);
  if (typeof o === "string") {
    process.stderr.write(`email-webmail-signin: ${o}\n${USAGE}`);
    return EXIT.usage;
  }
  const host = currentHost();
  if (host.platform !== "linux") {
    say("CANNOT RUN: the sign-in's private display session is Linux only.");
    return EXIT.hostCannot;
  }
  const bin = findExecutable("guiassert", host);
  if (bin === null) {
    say(
      "CANNOT RUN: no guiassert on PATH (run inside `nix develop`, which provides it).",
    );
    return EXIT.hostCannot;
  }
  const chrome = webmailBrowser(host.env);
  if ("reason" in chrome) {
    say(`CANNOT RUN: ${chrome.reason}.`);
    return EXIT.hostCannot;
  }
  const files =
    o.account !== undefined
      ? [`${o.set}/${o.account}.json`]
      : poolAccounts(host, o.set, dailyBudget(host.env), Date.now()).map(
          (a) => a.file,
        );
  // No account file: loadHostedAccount says precisely what is missing.
  if (files.length === 0) return pendingFor(o.set, host);
  const rl =
    o.takeover || o.manual
      ? createInterface({
          input: process.stdin,
          output: process.stdout,
          terminal: false,
        })
      : null;
  let code = 0;
  try {
    // One attempt per account per run: each file once.
    for (const f of [...new Set(files)]) {
      const c = await signInAccount(o, host, f, bin, rl);
      if (code === 0) code = c;
    }
  } finally {
    rl?.close();
  }
  return code;
}

function pendingFor(set: string, host: HostEnv): number {
  try {
    loadHostedAccount(set, host, { needsAppPassword: false });
  } catch (err) {
    if (err instanceof CredentialsUnavailable) {
      say(`PENDING: ${err.message}`);
      return EXIT.pending;
    }
    throw err;
  }
  say(`PENDING: no account file for ${set}`);
  return EXIT.pending;
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err: unknown) => {
    process.stderr.write(
      `email-webmail-signin: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    process.exitCode = 1;
  },
);
