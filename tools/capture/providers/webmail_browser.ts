// tools/capture/providers/webmail_browser.ts — the one launcher of the
// webmail browser on a QA account's profile, for the sign-in
// (email-webmail-signin.ts) and the hosted-webmail captures
// (webmail_desktop.ts).
//
// The browser is started as an ordinary process, never under
// Playwright, the DevTools protocol or WebDriver, so a provider's page
// sees a person's browser (`navigator.webdriver` false, no automation
// infobar). Every start:
// - removes the password hashes Chrome keeps in the profile and writes
//   the profile's preferences (webmail_profiles.ts), its colour mode
//   (light or dark, the caller's `scheme`) among them;
// - builds the command line from the profile's switches
//   (`signinBrowserArgs`: the cookie store, no first-run pages) and the
//   caller's session switches (`sessionSwitches`);
// - refuses, BEFORE anything is spawned, a command line carrying any
//   switch of AUTOMATION_SWITCHES (`AutomationSwitchError`): no caller
//   can open a webmail profile in an automated browser by passing one;
// - checks the sandbox (a renderer under seccomp), stopping the browser
//   and saying why when it is not on.

import {
  type ChildProcess,
  spawn,
  type SpawnOptions,
} from "node:child_process";
import {
  scrubPasswordHashes,
  signinBrowserArgs,
  stopBrowser,
  waitSandboxed,
  type WebmailBrowser,
  writeWebmailProfilePrefs,
} from "./webmail_profiles.ts";

/**
 * Switches a browser on a webmail profile must never carry: each makes
 * the browser automated, debuggable from outside, headless, or a test
 * build to the page, or imitates another browser.
 * - the DevTools protocol (a port or a pipe) and the origins it accepts;
 * - `--enable-automation` (the "controlled by automated test software"
 *   bar, and `navigator.webdriver` true);
 * - `--headless` (any mode) and `--test-type`;
 * - `--disable-blink-features=AutomationControlled`: what a stealth
 *   setup passes to hide the above; never needed without them;
 * - an extension loaded from the command line (an extension can drive
 *   pages), and DevTools opened for every tab;
 * - `--user-agent`: a browser claiming to be another (a phone) contradicts
 *   its client hints, `navigator.platform` and touch support.
 */
export const AUTOMATION_SWITCHES: readonly RegExp[] = [
  /^--remote-debugging/,
  /^--enable-automation/,
  /^--headless/,
  /^--test-type/,
  /^--remote-allow-origins/,
  /^--disable-blink-features=AutomationControlled/,
  /^--load-extension/,
  /^--disable-extensions-except/,
  /^--auto-open-devtools-for-tabs/,
  /^--user-agent/,
];

/** The automation switches `argv` carries (empty: none). */
export function automationSwitchesIn(argv: readonly string[]): string[] {
  return argv.filter((a) => AUTOMATION_SWITCHES.some((re) => re.test(a)));
}

export class AutomationSwitchError extends Error {
  readonly switches: string[];
  constructor(switches: string[]) {
    super(
      `refused to start the webmail browser with an automation switch (${switches.join(" ")}): a browser on a webmail profile is always started as a person's browser`,
    );
    this.name = "AutomationSwitchError";
    this.switches = switches;
  }
}

/** Throws when `argv` carries an automation switch. */
export function assertNoAutomation(argv: readonly string[]): void {
  const bad = automationSwitchesIn(argv);
  if (bad.length > 0) throw new AutomationSwitchError(bad);
}

/**
 * The session switches of a browser driven through GuiAssert, the
 * sign-in's and the captures' (none of them is an automation switch,
 * and none puts a bar or a
 * warning in the window, checked on a screenshot of Google Chrome 147
 * in the session, 2026-10-28):
 * - --force-renderer-accessibility: Chromium's accessibility tree on the
 *   session's AT-SPI bus, as it is built for a screen reader; the page's
 *   elements, their bounds and the address bar are read from it. Without
 *   it the browser exposed no page element in the session (probe,
 *   2026-10-28). No web API tells a page whether an assistive technology
 *   is attached.
 * - --force-device-scale-factor=1: Google Chrome otherwise picks a scale
 *   of about 1.047 on the session's Xvfb display and reports its
 *   accessibility extents in its own scaled pixels, which GuiAssert
 *   cannot place (every bound null; recorded as a GuiAssert issue). A
 *   page sees `devicePixelRatio` 1, the common desktop value.
 * - --lang=en-US: the browser's own interface in English (its bubbles,
 *   and the address bar's accessible name).
 * - the window placed on the whole display, so OCR reads all of it and a
 *   region of the display is a region of the page.
 *
 * The colour scheme is not a switch: it is the profile's colour mode
 * (`scheme`, written by webmail_profiles.ts `colorSchemePrefs`, the
 * setting a person picks on Chrome's settings page). An earlier version
 * started a dark browser with `--force-dark-mode` and
 * `--blink-settings=preferredColorScheme=0`; measured 2026-10-31, the
 * first changed nothing (Chrome's toolbar stayed light, pages saw
 * light) and the second made pages dark under a light browser, through
 * a developer switch that sets Blink's internal settings.
 */
export function sessionSwitches(width: number, height: number): string[] {
  return [
    "--force-renderer-accessibility",
    "--force-device-scale-factor=1",
    "--lang=en-US",
    "--window-position=0,0",
    `--window-size=${width},${height}`,
  ];
}

export interface StartBrowser {
  chrome: WebmailBrowser;
  userDataDir: string;
  url: string;
  /** The session's environment (guiassert.ts `sessionEnv`). */
  env: Record<string, string>;
  /** The caller's switches, before the URL (`sessionSwitches`). */
  extra: string[];
  /** The profile's colour mode for this start (the sign-in's: light). */
  scheme: "light" | "dark";
  /** The operator's override for a host without a usable sandbox. */
  unsafeNoSandbox: boolean;
  /** Sees the process as soon as it exists (for the signal cleanup). */
  onChild?: (c: ChildProcess) => void;
  /** Test seam: what spawns the process. */
  spawnImpl?: (
    file: string,
    args: string[],
    opts: SpawnOptions,
  ) => ChildProcess;
}

export type Started =
  | { ok: true; child: ChildProcess; argv: string[] }
  | { ok: false; reason: string };

/**
 * The webmail browser started normally on `userDataDir` at `url`. Throws
 * AutomationSwitchError, having spawned nothing, when the command line
 * would carry an automation switch; otherwise the running browser, or
 * why it cannot run sandboxed (it was then stopped).
 */
export async function startWebmailBrowser(o: StartBrowser): Promise<Started> {
  const argv = signinBrowserArgs(o.userDataDir, o.url, {
    unsafeNoSandbox: o.unsafeNoSandbox,
    extra: o.extra,
  });
  assertNoAutomation(argv);
  // No password hash is loaded into the browser, and its preferences.
  scrubPasswordHashes(o.userDataDir);
  writeWebmailProfilePrefs(o.userDataDir, o.scheme);
  let said = "";
  const child = (o.spawnImpl ?? spawn)(o.chrome.path, argv, {
    env: o.env,
    stdio: ["ignore", "ignore", "pipe"],
  });
  o.onChild?.(child);
  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", (d: string) => {
    said = (said + d).slice(-8192);
  });
  if (o.unsafeNoSandbox) return { ok: true, child, argv };
  const sandboxed = await waitSandboxed(child, o.userDataDir, () => said);
  if (sandboxed.ok) return { ok: true, child, argv };
  await stopBrowser(child);
  return {
    ok: false,
    reason: `Chromium's sandbox is not running (${sandboxed.reason}). It needs unprivileged user namespaces (or a setuid sandbox named by CHROME_DEVEL_SANDBOX)`,
  };
}
