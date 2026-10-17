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
// Both the guided sign-in (email-webmail-signin.ts) and the provider
// resolve the paths here, so they cannot disagree.
//
// A person signs each profile in, once: the harness never types into a
// sign-in page. The sign-in browser is the shell's pinned Chromium
// started without automation (Google refuses to sign in an
// automation-controlled browser), with Playwright's cookie-store
// switches, so the profile it leaves reads as signed in when Playwright
// opens it afterwards (a profile whose cookies were sealed with the
// desktop keyring would read as signed out).

import {
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  chmodSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { BrowserContext } from "playwright-core";
import { resolveDriver } from "./browser_emulation.ts";
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
  // The host the inbox loaded on when it was checked.
  host: string;
  browser: string;
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

// The pinned Chromium of the dev shell (PLAYWRIGHT_BROWSERS_PATH), the
// build Playwright drives, for starting it without Playwright.
export function pinnedChromium(
  env: Record<string, string | undefined>,
): { path: string } | { reason: string } {
  const driver = resolveDriver(env);
  if ("reason" in driver) return driver;
  const browsers = JSON.parse(
    readFileSync(join(driver.dir, "browsers.json"), "utf8"),
  ) as { browsers: { name: string; revision: string }[] };
  const rev = browsers.browsers.find((b) => b.name === "chromium")?.revision;
  const root = env.PLAYWRIGHT_BROWSERS_PATH;
  if (rev === undefined || root === undefined)
    return { reason: "no pinned Chromium (run under `nix develop`)" };
  for (const sub of ["chrome-linux64/chrome", "chrome-linux/chrome"]) {
    const path = join(root, `chromium-${rev}`, sub);
    if (existsSync(path)) return { path };
  }
  return {
    reason: `no Chromium executable under ${join(root, `chromium-${rev}`)}`,
  };
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
