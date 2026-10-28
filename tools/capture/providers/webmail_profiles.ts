// tools/capture/providers/webmail_profiles.ts — the persistent browser
// profile of each hosted-webmail QA account, and how to tell whether
// it is signed in.
//
// One profile per account, at
//   $ISONIM_EMAIL_WEBMAIL_PROFILES_DIR/<set>/<account>/
// (default ${XDG_STATE_HOME:-$HOME/.local/state}/isonim-email/webmail-profiles),
// every level 0700: `chromium/` is the Chromium user data directory the
// capture provider opens with launchPersistentContext, and
// `signin.json` the non-secret record of the last verified sign-in.
// Both the sign-in recipe (email-webmail-signin.ts) and the provider
// resolve the paths here, so they cannot disagree.
//
// The sign-in recipe signs each profile in (automated, with OS-level
// input in a private GuiAssert session: webmail_signin.ts); the capture
// provider never types into a sign-in page. Every browser on a profile
// is the dev shell's webmail browser (`webmailBrowser`: Google Chrome,
// or nixpkgs' Chromium where Google Chrome is not packaged), a regular
// release build and not Playwright's Chrome for Testing, which shows an
// "only for automated testing" bar and which the providers' sign-in
// pages may treat as automated. The sign-in starts it without
// automation (Google refuses to sign in an automation-controlled
// browser), with Playwright's cookie-store switches, so the profile it
// leaves reads as signed in when Playwright opens it afterwards (a
// profile whose cookies were sealed with the desktop keyring would read
// as signed out). Playwright opens the profile with `executablePath`
// set to the same executable (headed or headless), so the profile is
// never opened by a build other than the one that wrote it.
//
// Both browsers load the real web, so both keep Chromium's sandbox on:
// the sign-in browser is started without `--no-sandbox`, and Playwright
// (which adds `--no-sandbox` unless told otherwise) with
// `chromiumSandbox: true`. On Linux a store build sandboxes its
// renderers with user and PID namespaces plus seccomp-bpf (its setuid
// helper cannot be setuid in the Nix store), so it needs unprivileged
// user namespaces; where those are refused, Chromium aborts with "No
// usable sandbox!" rather than run unsandboxed, and the sign-in says
// so and stops. `waitSandboxed` checks the running browser: one of its
// renderers must be under a seccomp filter.

import type { ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  statSync,
  chmodSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { BrowserContext } from "playwright-core";
import { launchOptions, type LaunchOptions } from "../launch.ts";
import type { HostEnv } from "./requirements.ts";

export const PROFILES_ENV = "ISONIM_EMAIL_WEBMAIL_PROFILES_DIR";

// The switches Playwright passes Chromium for its cookie store; the
// sign-in browser gets the same ones.
export const COOKIE_STORE_SWITCHES = [
  "--password-store=basic",
  "--use-mock-keychain",
];

export interface WebmailSignin {
  label: string;
  // Where a signed-in profile lands on the mailbox.
  inboxUrl: string;
  // The hosts the inbox stays on when signed in (a signed-out profile
  // is sent to a sign-in or marketing host instead).
  mailHosts: string[];
  // A selector present in the signed-in mailbox UI: its search box.
  // [measure: confirm per provider on the first sign-in]
  marker: string;
}

export const WEBMAIL_SIGNIN: Record<string, WebmailSignin> = {
  "gmail-workspace": {
    label: "Gmail",
    inboxUrl: "https://mail.google.com/mail/u/0/#inbox",
    mailHosts: ["mail.google.com"],
    marker: 'form[role="search"], input[name="q"]',
  },
  yahoo: {
    label: "Yahoo Mail",
    inboxUrl: "https://mail.yahoo.com/",
    mailHosts: ["mail.yahoo.com"],
    marker: '[role="search"], input[type="search"], input[name="p"]',
  },
  aol: {
    label: "AOL Mail",
    inboxUrl: "https://mail.aol.com/",
    mailHosts: ["mail.aol.com"],
    marker: '[role="search"], input[type="search"]',
  },
  "outlook-com": {
    label: "Outlook.com",
    inboxUrl: "https://outlook.live.com/mail/0/",
    mailHosts: ["outlook.live.com"],
    marker: '[role="search"], #topSearchInput, input[type="search"]',
  },
};

export function profilesRoot(host: HostEnv): string {
  const v = host.env[PROFILES_ENV];
  if (v !== undefined && v !== "") return v;
  const home = host.env.HOME ?? homedir();
  const state =
    host.env.XDG_STATE_HOME !== undefined && host.env.XDG_STATE_HOME !== ""
      ? host.env.XDG_STATE_HOME
      : join(home, ".local", "state");
  return join(state, "isonim-email", "webmail-profiles");
}

export interface AccountProfile {
  dir: string;
  // The Chromium user data directory.
  userDataDir: string;
  record: string;
}

// The account's name: its file's name without .json.
export function accountName(accountFile: string): string {
  return accountFile
    .slice(accountFile.lastIndexOf("/") + 1)
    .replace(/\.json$/, "");
}

function privateDir(path: string): void {
  if (!existsSync(path)) mkdirSync(path, { recursive: true, mode: 0o700 });
  if ((statSync(path).mode & 0o777) !== 0o700) chmodSync(path, 0o700);
}

// The account's profile paths; with `create`, the directories exist,
// each 0700 from the root down.
export function accountProfile(
  host: HostEnv,
  set: string,
  accountFile: string,
  create = false,
): AccountProfile {
  const root = profilesRoot(host);
  const dir = join(root, set, accountName(accountFile));
  const p = {
    dir,
    userDataDir: join(dir, "chromium"),
    record: join(dir, "signin.json"),
  };
  if (create)
    for (const d of [root, join(root, set), dir, p.userDataDir]) privateDir(d);
  return p;
}

export interface SigninRecord {
  set: string;
  account_file: string;
  signed_in_at: string;
  // The host the inbox was checked on: the inbox URL's host when the
  // mailbox was read off the screen (`ocr`), the host the page stayed
  // on under Playwright (`ocr+playwright`).
  host: string;
  browser: string;
  // How the sign-in was verified: by OCR of the mailbox in the webmail
  // browser started without automation (always), and with
  // `--playwright-check` also under Playwright. Absent in records
  // written before 2026-10-28 (Playwright only).
  verified_by?: "ocr" | "ocr+playwright";
}

export function writeSigninRecord(p: AccountProfile, r: SigninRecord): void {
  writeFileSync(p.record, `${JSON.stringify(r, null, 2)}\n`, { mode: 0o600 });
  chmodSync(p.record, 0o600);
}

export function readSigninRecord(p: AccountProfile): SigninRecord | null {
  try {
    return JSON.parse(readFileSync(p.record, "utf8")) as SigninRecord;
  } catch {
    return null;
  }
}

// The variables the dev shell sets (flake.nix `webmailBrowser`): the
// webmail browser's executable, and which build it is (for signin.json
// and the captures' build key).
export const BROWSER_ENV = "ISONIM_EMAIL_WEBMAIL_BROWSER";
export const BROWSER_LABEL_ENV = "ISONIM_EMAIL_WEBMAIL_BROWSER_LABEL";

export interface WebmailBrowser {
  path: string;
  /** e.g. "Google Chrome 147.0.7727.137"; the path when unknown. */
  label: string;
}

// The webmail browser: the one executable every browser on a webmail
// profile runs, the sign-in's (started without Playwright) and the
// captures' (Playwright's `executablePath`).
export function webmailBrowser(
  env: Record<string, string | undefined>,
): WebmailBrowser | { reason: string } {
  const path = env[BROWSER_ENV];
  if (path === undefined || path === "")
    return {
      reason: `no webmail browser: ${BROWSER_ENV} is not set (run under \`nix develop\` on Linux)`,
    };
  if (!existsSync(path))
    return { reason: `${BROWSER_ENV}=${path} does not exist` };
  const label = env[BROWSER_LABEL_ENV];
  return { path, label: label === undefined || label === "" ? path : label };
}

export type SignedIn =
  | { signedIn: true; host: string }
  | { signedIn: false; host: string; reason: string };

// Loads the inbox in a context opened on the profile and judges it: the
// page must stay on one of the mail hosts and show the marker, within
// the timeout. Never types anything.
export async function checkSignedIn(
  context: BrowserContext,
  w: WebmailSignin,
  timeoutMs = 30_000,
): Promise<SignedIn> {
  const page = context.pages()[0] ?? (await context.newPage());
  try {
    await page.goto(w.inboxUrl, {
      waitUntil: "domcontentloaded",
      timeout: timeoutMs,
    });
  } catch (err) {
    return {
      signedIn: false,
      host: "",
      reason: `the inbox did not load: ${err instanceof Error ? err.message.split("\n")[0] : String(err)}`,
    };
  }
  const deadline = Date.now() + timeoutMs;
  let host = new URL(page.url()).host;
  for (;;) {
    host = new URL(page.url()).host;
    if (w.mailHosts.includes(host)) {
      const found = await page
        .locator(w.marker)
        .first()
        .isVisible()
        .catch(() => false);
      if (found) return { signedIn: true, host };
    }
    if (Date.now() >= deadline) break;
    await page.waitForTimeout(500);
  }
  return {
    signedIn: false,
    host,
    reason: w.mailHosts.includes(host)
      ? `the inbox loaded on ${host} but the mailbox marker (${w.marker}) did not appear within ${timeoutMs} ms`
      : `the inbox was redirected to ${host}, not ${w.mailHosts.join(" or ")}: the profile is not signed in`,
  };
}

// The profile preferences that turn off the browser's own sign-in (its
// "Allow Chrome sign-in" setting), so Google Chrome never offers to sign
// the browser in ("Make Chrome your own … Continue as …") over a page
// once the web sign-in succeeds. Both keys: Chrome resets
// `signin.allowed` at startup from `signin.allowed_on_next_startup`
// (measured 2026-10-28, Google Chrome 147: with the first alone it was
// true again after a start, with both it stayed false and the profile
// menu offered no "Sign in to Chrome"). A user setting, not an
// automation switch, and invisible to a page.
export const SIGNIN_OFFER_PREFS = {
  allowed: false,
  allowed_on_next_startup: false,
} as const;

// Writes SIGNIN_OFFER_PREFS into the profile's Default/Preferences
// before a browser starts on it (none may run on it then), keeping
// everything else in the file; atomic, 0600. A file that is not a JSON
// object is an error: it is never replaced.
export function suppressBrowserSigninOffer(userDataDir: string): void {
  const dir = join(userDataDir, "Default");
  const path = join(dir, "Preferences");
  let prefs: Record<string, unknown> = {};
  if (existsSync(path)) {
    const v: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (v === null || typeof v !== "object" || Array.isArray(v))
      throw new Error(`${path} is not a JSON object`);
    prefs = v as Record<string, unknown>;
  }
  const signin = prefs.signin;
  prefs.signin = {
    ...(signin !== null && typeof signin === "object" && !Array.isArray(signin)
      ? (signin as Record<string, unknown>)
      : {}),
    ...SIGNIN_OFFER_PREFS,
  };
  privateDir(dir);
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(prefs), { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

// The command line of the sign-in browser: the webmail browser without
// automation, on the account's profile, with Playwright's cookie-store
// switches and the sandbox on. `unsafeNoSandbox` is the operator's
// explicit override for a host without a usable sandbox (`--no-sandbox`:
// the browser then loads the web with renderers that are not confined).
// `extra` goes before the URL (the automated sign-in's own switches,
// webmail_signin.ts `SIGNIN_SESSION_SWITCHES`).
export function signinBrowserArgs(
  userDataDir: string,
  url: string,
  opts: {
    headless?: boolean;
    unsafeNoSandbox?: boolean;
    extra?: string[];
  } = {},
): string[] {
  return [
    `--user-data-dir=${userDataDir}`,
    ...COOKIE_STORE_SWITCHES,
    ...(opts.unsafeNoSandbox === true ? ["--no-sandbox"] : []),
    ...(opts.headless === true ? ["--headless=new"] : []),
    "--no-first-run",
    "--no-default-browser-check",
    ...(opts.extra ?? []),
    url,
  ];
}

// The Playwright launch options that open an account's profile: the
// capture's Chromium options, the webmail browser's executable, and
// the sandbox on (unless the operator overrode it for the sign-in).
export function webmailLaunchOptions(
  env: Record<string, string | undefined>,
  headless: boolean,
  opts: { unsafeNoSandbox?: boolean } = {},
): LaunchOptions & {
  headless: boolean;
  chromiumSandbox: boolean;
  executablePath: string;
} {
  const browser = webmailBrowser(env);
  if ("reason" in browser) throw new Error(browser.reason);
  return {
    ...launchOptions("chromium", false, process.platform, env),
    headless,
    chromiumSandbox: opts.unsafeNoSandbox !== true,
    executablePath: browser.path,
  };
}

function hasArg(cmdline: string, arg: string): boolean {
  for (let i = cmdline.indexOf(arg); i >= 0; i = cmdline.indexOf(arg, i + 1)) {
    const before = i === 0 ? " " : cmdline[i - 1]!;
    const after = cmdline[i + arg.length] ?? " ";
    if (/[\0 ]/.test(before) && /[\0 ]/.test(after)) return true;
  }
  return false;
}

// The renderers of the browser running on `userDataDir`, each with
// whether it is under a seccomp filter (/proc/<pid>/status "Seccomp: 2").
// Linux only: elsewhere there is no /proc and the list is empty.
export function rendererSandboxes(
  userDataDir: string,
): { pid: number; seccomp: boolean }[] {
  const out: { pid: number; seccomp: boolean }[] = [];
  let pids: string[];
  try {
    pids = readdirSync("/proc").filter((d) => /^\d+$/.test(d));
  } catch {
    return out;
  }
  for (const pid of pids) {
    try {
      // A renderer forked by the zygote carries its command line as its
      // process title, space-separated rather than NUL-separated, so an
      // argument ends at a space, a NUL or the end.
      const argv = readFileSync(`/proc/${pid}/cmdline`, "utf8");
      if (
        !hasArg(argv, "--type=renderer") ||
        !hasArg(argv, `--user-data-dir=${userDataDir}`)
      )
        continue;
      const status = readFileSync(`/proc/${pid}/status`, "utf8");
      out.push({
        pid: Number(pid),
        seccomp: /^Seccomp:\s*2\s*$/m.test(status),
      });
    } catch {
      continue; // exited meanwhile, or not ours to read
    }
  }
  return out;
}

// Waits until the browser started on `userDataDir` (as `child`) runs a
// renderer under a seccomp filter. Fails when the browser exits first
// (Chromium's "No usable sandbox!" abort among them: `stderr` is what
// it printed), when one renderer stays unconfined for `unconfinedMs`
// (a renderer is confined moments after it starts, so one still
// unconfined after that runs without the sandbox), or at the timeout.
export async function waitSandboxed(
  child: ChildProcess,
  userDataDir: string,
  stderr: () => string,
  timeoutMs = 90_000,
  unconfinedMs = 10_000,
): Promise<{ ok: true; pid: number } | { ok: false; reason: string }> {
  const firstSeen = new Map<number, number>();
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const now = Date.now();
    for (const r of rendererSandboxes(userDataDir)) {
      if (r.seccomp) return { ok: true, pid: r.pid };
      const seen = firstSeen.get(r.pid) ?? now;
      firstSeen.set(r.pid, seen);
      if (now - seen >= unconfinedMs)
        return {
          ok: false,
          reason: `renderer ${r.pid} has run for ${Math.round((now - seen) / 1000)} s without a seccomp filter: the browser is not sandboxed`,
        };
    }
    if (child.exitCode !== null || child.signalCode !== null) {
      // What it printed last may still be in the pipe.
      const err = child.stderr;
      if (err != null && !err.readableEnded)
        await new Promise<void>((r) => {
          err.once("end", () => r());
          setTimeout(r, 2000).unref();
        });
      const said = stderr()
        .split("\n")
        .filter((l) => /sandbox/i.test(l))
        .slice(-2)
        .join(" | ");
      return {
        ok: false,
        reason: `the browser exited (${child.exitCode ?? child.signalCode}) before running a sandboxed renderer${said === "" ? "" : `: ${said}`}`,
      };
    }
    if (now >= deadline)
      return {
        ok: false,
        reason: `no sandboxed renderer within ${Math.round(timeoutMs / 1000)} s`,
      };
    await new Promise((r) => setTimeout(r, 250));
  }
}

// Stops a browser started without Playwright: SIGINT, SIGKILL after
// 15 s. Not SIGTERM: Chromium exits on SIGTERM without writing the
// cookies of its last ~30 s to the profile (measured, Playwright's Chromium 1217,
// 2026-10-17, headed on Wayland and headless alike: a session cookie
// set a second before SIGTERM was missing from the profile's Cookies
// database, and present after SIGINT or SIGHUP), so a person who
// pressed Enter as soon as the inbox showed would leave a profile that
// reads as signed out.
export const BROWSER_STOP_SIGNAL = "SIGINT";

export async function stopBrowser(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise<void>((r) => child.once("exit", () => r()));
  child.kill(BROWSER_STOP_SIGNAL);
  const t = setTimeout(() => child.kill("SIGKILL"), 15_000);
  await exited;
  clearTimeout(t);
}
