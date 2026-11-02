// tools/capture/providers/webmail_profiles.ts — the persistent browser
// profile of each hosted-webmail QA account, and how to tell whether
// it is signed in.
//
// One profile per account, at
//   $ISONIM_EMAIL_WEBMAIL_PROFILES_DIR/<set>/<account>/
// (default ${XDG_STATE_HOME:-$HOME/.local/state}/isonim-email/webmail-profiles),
// every level 0700: `chromium/` is the Chromium user data directory the
// sign-in and the capture provider start the webmail browser on
// (webmail_browser.ts), and `signin.json` the non-secret record of the
// last verified sign-in.
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
// pages may treat as automated. The sign-in and the captures start it
// the same way, through one launcher (webmail_browser.ts), never under
// Playwright, the DevTools protocol or WebDriver (Google refuses to sign
// in an automation-controlled browser), always with the same
// cookie-store switches (`COOKIE_STORE_SWITCHES`): a profile's cookies
// are sealed with the store that wrote them, so a browser started with
// another (the desktop keyring) would read the profile as signed out.
//
// Every browser on a profile loads the real web, so each keeps
// Chromium's sandbox on: it is started without `--no-sandbox` (unless
// the operator overrides it for the sign-in). On Linux a store build sandboxes its
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
  readlinkSync,
  renameSync,
  statSync,
  chmodSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { HostEnv } from "./requirements.ts";

export const PROFILES_ENV = "ISONIM_EMAIL_WEBMAIL_PROFILES_DIR";

// The cookie-store switches every browser on a webmail profile gets
// (the ones Playwright passes Chromium, which the first profiles were
// written with; kept so those profiles still read as signed in).
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
}

export const WEBMAIL_SIGNIN: Record<string, WebmailSignin> = {
  "gmail-workspace": {
    label: "Gmail",
    inboxUrl: "https://mail.google.com/mail/u/0/#inbox",
    mailHosts: ["mail.google.com"],
  },
  yahoo: {
    label: "Yahoo Mail",
    inboxUrl: "https://mail.yahoo.com/",
    mailHosts: ["mail.yahoo.com"],
  },
  aol: {
    label: "AOL Mail",
    inboxUrl: "https://mail.aol.com/",
    mailHosts: ["mail.aol.com"],
  },
  "outlook-com": {
    label: "Outlook.com",
    inboxUrl: "https://outlook.live.com/mail/0/",
    mailHosts: ["outlook.live.com"],
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
  // The host the inbox was checked on: the inbox URL's host, the
  // mailbox read off the screen.
  host: string;
  browser: string;
  // How the sign-in was verified: by OCR of the mailbox in the webmail
  // browser started without automation (its phrases), or by the
  // mailbox's structure on its address (`structure`: a mailbox shown in
  // another language). Records written before
  // 2026-10-28 have none (Playwright only), and records of the removed
  // `--playwright-check` say `ocr+playwright`; both are only read.
  verified_by?: "ocr" | "structure" | "ocr+playwright";
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
// profile runs, the sign-in's and the captures' (webmail_browser.ts).
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

// The preferences every browser of the sign-in recipe starts with on a
// webmail profile, merged into its Default/Preferences (capture spec's
// "webmail profile's preferences"). Each is a user setting of Chrome's
// settings page, or the preference an enterprise policy sets; none is an
// automation switch, and no web API reports one to a page.
// - The password manager off: Chrome never offers to save the QA
//   password, and never saves it ("Offer to save passwords",
//   `PasswordManagerEnabled`; `profile.password_manager_enabled` is the
//   older name of the same setting), never signs in with a saved one,
//   and never sends a hash prefix of a submitted password to Google's
//   leak check. Measured 2026-10-28: Yahoo's sign-in left Chrome's "Save
//   password?" bubble over the next page.
// - The web sign-in interception off (`SigninInterceptionEnabled`): no
//   "Make Chrome your own / Continue as …" bubble over the provider's
//   page after a Google web sign-in. Chrome's own sign-in stays allowed
//   (`signin.allowed` and `allowed_on_next_startup` true, Chrome's
//   default, restoring profiles an earlier recipe set to false): turning
//   it off disables Chrome's account consistency with Google, so Google
//   stops receiving the request header the session was signed in with,
//   a plausible cause of the "verify it's you" a Gmail profile met on its
//   first launch with it off (2026-10-28).
// - The pages' languages: en-US, en (Chrome's default for an en-US
//   interface, written so it does not depend on the host's locale).
// - Page translation off (Settings, "Use Google Translate";
//   `translate.enabled`, the `TranslateEnabled` policy's preference):
//   Chrome offers no translation of a page in another language than its
//   interface's, so no Translate bubble ("Always translate", a check box
//   of the browser, not of the page) shows over a consent page in the
//   host region's language. Measured 2026-10-30: that bubble over a
//   Bulgarian consent page stopped an attempt consent-required.
// - Site notifications blocked (Settings, Site settings, Notifications,
//   "Don't allow sites to send notifications";
//   `profile.default_content_setting_values.notifications` 2, the
//   `DefaultNotificationsSetting` policy's preference): every page reads
//   `Notification.permission` "denied", so a page offers no prompt of
//   its own (Gmail's "Enable desktop notifications" toast asks only
//   while it is undecided) and Chrome shows no permission bubble.
//   Measured 2026-10-31: Gmail's toast lay over the live capture's
//   frames.
export const WEBMAIL_PROFILE_PREFS = {
  credentials_enable_service: false,
  credentials_enable_autosignin: false,
  profile: {
    password_manager_enabled: false,
    password_manager_leak_detection: false,
    default_content_setting_values: { notifications: 2 },
  },
  signin: {
    interception_enabled: false,
    allowed: true,
    allowed_on_next_startup: true,
  },
  intl: { accept_languages: "en-US,en" },
  translate: { enabled: false },
} as const;

type Json = Record<string, unknown>;
const isObject = (v: unknown): v is Json =>
  v !== null && typeof v === "object" && !Array.isArray(v);

// `over` merged into `base`, objects key by key (`over` wins elsewhere).
function mergePrefs(base: Json, over: Json): Json {
  const out: Json = { ...base };
  for (const [k, v] of Object.entries(over))
    out[k] = isObject(v) && isObject(out[k]) ? mergePrefs(out[k], v) : v;
  return out;
}

// A preferences file read as a JSON object; {} when there is none. A file
// that is not a JSON object is an error (it is never replaced).
function readPrefsObject(path: string): Json {
  if (!existsSync(path)) return {};
  const v: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (!isObject(v)) throw new Error(`${path} is not a JSON object`);
  return v;
}

// Writes a preferences file atomically (a temporary file renamed over
// it), 0600, its directory 0700.
function writePrefsObject(path: string, prefs: Json): void {
  privateDir(join(path, ".."));
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(prefs), { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

// The browser's colour mode, as a person sets it on Chrome's settings
// page (Appearance, Mode: Light / Dark; `browser.theme.color_scheme2`,
// 1 light, 2 dark, 0 the device's). It decides both Chrome's own
// appearance and the `prefers-color-scheme` every page sees. The older
// `browser.theme.color_scheme` is written to the same value: Chrome
// migrates it over `color_scheme2` at start, so a stale dark one would
// otherwise win. The mode is written explicitly for light as well, so
// neither an earlier dark capture's value nor a dark desktop theme
// inherited from the host (GTK_THEME) carries over. Measured 2026-10-31
// (Google Chrome 147.0.7727.137 in a GuiAssert Xvfb session, throwaway
// profiles, a loopback page reporting the media query and the CSS
// system colours): 2 made Chrome's toolbar dark and every page dark
// (`prefers-color-scheme: dark`, `Canvas` rgb(18,18,18)) on the first
// load, a typed navigation and a reload; 1 kept every page light under
// GTK_THEME=Adwaita:dark; a stale `color_scheme: 2` beside
// `color_scheme2: 1` came out dark.
export function colorSchemePrefs(scheme: "light" | "dark"): Json {
  const v = scheme === "dark" ? 2 : 1;
  return { browser: { theme: { color_scheme2: v, color_scheme: v } } };
}

// Writes WEBMAIL_PROFILE_PREFS and the colour mode (`colorSchemePrefs`)
// into the profile's Default/Preferences before a browser starts on it
// (none may run on it then), keeping everything else in the file;
// atomic, 0600. A file that is not a JSON object is an error: it is
// never replaced.
export function writeWebmailProfilePrefs(
  userDataDir: string,
  scheme: "light" | "dark" = "light",
): void {
  const path = join(userDataDir, "Default", "Preferences");
  writePrefsObject(
    path,
    mergePrefs(
      mergePrefs(
        readPrefsObject(path),
        WEBMAIL_PROFILE_PREFS as unknown as Json,
      ),
      colorSchemePrefs(scheme),
    ),
  );
}

// Where Chrome keeps the hashes of a password it protects against reuse
// (read in Chromium 147.0.7727.137, hash_password_manager.cc: the Google
// account password's in the profile's preferences, kPasswordHashDataList;
// an enterprise password's in the browser's Local State,
// kLocalPasswordHashDataList). Each entry is a salted hash of the
// password with its length and the account name: not the password, but
// derived from it, and enough to test a guess offline, so it is a secret
// at rest. Chrome writes the profile's one when a password is submitted
// on Google's sign-in page and the login succeeds, whatever the password
// manager's settings: no profile preference prevents it (only an
// off-the-record window does), measured with Google Chrome
// 147.0.7727.137 (webmail_signin_session.test.ts).
export const PASSWORD_HASH_LOCATIONS: readonly {
  /** The file, relative to the user data directory. */
  file: string;
  /** The key, as a path of object keys. */
  key: readonly [string, string];
}[] = [
  {
    file: join("Default", "Preferences"),
    key: ["profile", "password_hash_data_list"],
  },
  { file: "Local State", key: ["local", "password_hash_data_list"] },
];

export interface PasswordHashScrub {
  /** Entries removed, over every location. */
  removed: number;
  /** The files rewritten (relative to the user data directory). */
  rewritten: string[];
}

// Removes every PASSWORD_HASH_LOCATIONS key from its file, keeping
// everything else (each rewritten file merge-written atomically, 0600;
// a file without the key is not touched). Run only with no browser on
// the profile: a running browser writes its preferences back on exit.
// A file that is not a JSON object is an error and is never replaced.
export function scrubPasswordHashes(userDataDir: string): PasswordHashScrub {
  const out: PasswordHashScrub = { removed: 0, rewritten: [] };
  for (const loc of PASSWORD_HASH_LOCATIONS) {
    const path = join(userDataDir, loc.file);
    if (!existsSync(path)) continue;
    const prefs = readPrefsObject(path);
    const [outer, inner] = loc.key;
    const parent = prefs[outer];
    if (!isObject(parent) || !(inner in parent)) continue;
    const list = parent[inner];
    out.removed += Array.isArray(list) ? list.length : 1;
    const { [inner]: _gone, ...rest } = parent;
    writePrefsObject(path, { ...prefs, [outer]: rest });
    out.rewritten.push(loc.file);
  }
  return out;
}

// The processes running a browser on `userDataDir`: every process whose
// command line carries `--user-data-dir=<it>` (the browser and its
// helpers), and the process Chrome's SingletonLock names on this host
// (`<host>-<pid>`) while it lives. Linux only (/proc); elsewhere the lock
// alone.
export function browsersOn(userDataDir: string): number[] {
  const pids = new Set<number>();
  let entries: string[] = [];
  try {
    entries = readdirSync("/proc").filter((d) => /^\d+$/.test(d));
  } catch {
    // no /proc
  }
  for (const pid of entries) {
    if (Number(pid) === process.pid) continue;
    try {
      const argv = readFileSync(`/proc/${pid}/cmdline`, "utf8");
      if (hasArg(argv, `--user-data-dir=${userDataDir}`)) pids.add(Number(pid));
    } catch {
      continue;
    }
  }
  try {
    const m = /^(.*)-(\d+)$/.exec(
      readlinkSync(join(userDataDir, "SingletonLock")),
    );
    if (m !== null && m[1] === hostname()) {
      const pid = Number(m[2]);
      try {
        process.kill(pid, 0);
        pids.add(pid);
      } catch (err) {
        // EPERM: it lives, as another user's process.
        if ((err as NodeJS.ErrnoException).code === "EPERM") pids.add(pid);
      }
    }
  } catch {
    // no lock: no browser
  }
  return [...pids].sort((a, b) => a - b);
}

// What the browser keeps of a password in a profile, counted, never read:
// saved logins in Login Data and Login Data For Account (rows that are not
// "never save" entries), and the entries of every PASSWORD_HASH_LOCATIONS
// list (salted hashes of a password, kept for Chrome's password-reuse
// warning). `unreadable` names what could not be counted (a database that
// is locked or malformed, a preferences file that is not JSON): that is a
// failure too, since it proves nothing.
export interface SecretsAtRest {
  savedLogins: number;
  accountLogins: number;
  passwordHashes: number;
  unreadable: string[];
}

export const LOGIN_DATABASES = ["Login Data", "Login Data For Account"];

function countLogins(path: string): number {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    try {
      const row = db
        .prepare(
          "SELECT count(*) AS n FROM logins WHERE blacklisted_by_user = 0",
        )
        .get() as { n: number };
      return Number(row.n);
    } catch {
      // A schema without the column: every row counts.
      const row = db.prepare("SELECT count(*) AS n FROM logins").get() as {
        n: number;
      };
      return Number(row.n);
    }
  } finally {
    db.close();
  }
}

// Counts the profile's saved passwords (run with no browser on it).
export function secretsAtRest(userDataDir: string): SecretsAtRest {
  const out: SecretsAtRest = {
    savedLogins: 0,
    accountLogins: 0,
    passwordHashes: 0,
    unreadable: [],
  };
  const def = join(userDataDir, "Default");
  for (const name of LOGIN_DATABASES) {
    const path = join(def, name);
    if (!existsSync(path)) continue;
    try {
      const n = countLogins(path);
      if (name === "Login Data") out.savedLogins = n;
      else out.accountLogins = n;
    } catch (err) {
      out.unreadable.push(
        `${name} (${err instanceof Error ? err.message.split("\n")[0] : String(err)})`,
      );
    }
  }
  for (const loc of PASSWORD_HASH_LOCATIONS) {
    const path = join(userDataDir, loc.file);
    if (!existsSync(path)) continue;
    const name = loc.file.slice(loc.file.lastIndexOf("/") + 1);
    try {
      const v: unknown = JSON.parse(readFileSync(path, "utf8"));
      if (!isObject(v)) throw new Error("not an object");
      const [outer, inner] = loc.key;
      const parent = v[outer];
      const list = isObject(parent) ? parent[inner] : undefined;
      // Anything but an empty list under the key counts.
      out.passwordHashes += Array.isArray(list)
        ? list.length
        : list === undefined
          ? 0
          : 1;
    } catch {
      out.unreadable.push(`${name} (not a JSON object)`);
    }
  }
  return out;
}

export function holdsSecrets(s: SecretsAtRest): boolean {
  return (
    s.savedLogins + s.accountLogins + s.passwordHashes > 0 ||
    s.unreadable.length > 0
  );
}

// The command line of the sign-in browser: the webmail browser without
// automation, on the account's profile, with the cookie-store
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
