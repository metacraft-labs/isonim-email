// tools/capture/email-webmail-signin.ts — `just email-webmail-signin`:
// the guided first sign-in of a hosted-webmail QA account's browser
// profile, by a person.
//
// It prints the account's address (never its password), opens the
// provider's webmail in the shell's pinned Chromium, started WITHOUT
// automation (no Playwright, no DevTools protocol) and WITH Chromium's
// sandbox on the operator's display, in the account's persistent
// profile (providers/webmail_profiles.ts), and offers to put the
// password on the clipboard without printing it. The person signs in,
// completes any challenge, and presses Enter. The recipe then closes
// that browser, opens the same profile under Playwright (headed, as
// the capture provider will, same executable, sandbox on) and checks
// that the inbox loads signed in. On success it records the sign-in in
// the profile's signin.json.
//
// The sandbox is checked, not assumed: a renderer of the sign-in
// browser must run under a seccomp filter, or the recipe stops the
// browser and exits 4 (`--unsafe-no-sandbox` is the operator's explicit
// override). A password it put on the clipboard is taken off again
// (only while the clipboard still holds it) on Enter, after 60 s, on
// SIGINT, SIGTERM or SIGHUP, and at any exit (clipboard_guard.ts).
//
// It never types into a page: a sign-in is a person's. `--check-only`
// skips the sign-in and only checks (and records) an existing profile.

import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { createInterface } from "node:readline/promises";
import { resolveDriver } from "./providers/browser_emulation.ts";
import {
  CLIPBOARD_CLEAR_MS,
  ClipboardGuard,
  clipboardTool,
  installSignalCleanup,
} from "./clipboard_guard.ts";
import {
  CredentialsUnavailable,
  loadHostedAccount,
} from "./providers/hosted_delivery.ts";
import {
  credentialsDir,
  currentHost,
  type HostEnv,
} from "./providers/requirements.ts";
import {
  accountProfile,
  BROWSER_STOP_SIGNAL,
  checkSignedIn,
  pinnedChromium,
  PROFILES_ENV,
  signinBrowserArgs,
  stopBrowser,
  waitSandboxed,
  WEBMAIL_SIGNIN,
  webmailLaunchOptions,
  writeSigninRecord,
} from "./providers/webmail_profiles.ts";
import { clearNeedsLogin } from "./providers/webmail_accounts.ts";

const USAGE = `usage: email-webmail-signin SET [--account NAME] [--check-only]
                            [--dir DIR] [--timeout SECONDS]
                            [--unsafe-no-sandbox]

The first sign-in of a QA account's browser profile, done by a person on
this machine's display. Sets: ${Object.keys(WEBMAIL_SIGNIN).join(", ")}.

1) Prints the account's address (SET's first account file, or
  SET/NAME.json with --account).
2) Opens the webmail in the pinned Chromium, without automation and
  with its sandbox (checked: it stops if the sandbox is not running),
  in the account's profile under $${PROFILES_ENV}
  (default \${XDG_STATE_HOME:-$HOME/.local/state}/isonim-email/webmail-profiles),
  and offers to copy the password to the clipboard (wl-copy, xclip or
  xsel), never printing it. It is taken off the clipboard when you
  press Enter, after ${CLIPBOARD_CLEAR_MS / 1000} s, or when the recipe is interrupted.
3) You sign in and complete any challenge, then press Enter here.
4) It closes that browser, opens the profile under Playwright (headed,
  same Chromium, sandboxed) and checks the inbox is signed in; on
  success it writes signin.json.

--check-only  skip steps 1-3: only check (and record) the profile
--dir DIR     the credentials directory (default $ISONIM_EMAIL_CREDENTIALS_DIR,
              else \${XDG_CONFIG_HOME:-$HOME/.config}/metacraft/dev-credentials/isonim-email)
--timeout S   how long the check waits for the inbox (default 45)
--unsafe-no-sandbox
              UNSAFE: run both browsers with Chromium's sandbox off, on a
              host where it cannot run (no unprivileged user namespaces).
              You then browse the real web with unconfined renderers;
              prefer enabling user namespaces (or a setuid sandbox via
              CHROME_DEVEL_SANDBOX) instead.

Exit status: 0 signed in (recorded); 1 not signed in, or failed;
2 usage, or no display; 3 pending (no account file); 4 the browser
sandbox is not available (see --unsafe-no-sandbox); 128+N signal N.
`;

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
    process.stdout.write(USAGE);
    return args.length === 0 ? 2 : 0;
  }
  let set: string | undefined;
  let account: string | undefined;
  let checkOnly = false;
  let dir: string | null = null;
  let timeoutS = 45;
  let unsafeNoSandbox = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    const value = (): string => {
      const v = args[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === "--account") account = value();
    else if (a === "--check-only") checkOnly = true;
    else if (a === "--dir") dir = resolve(value());
    else if (a === "--timeout") timeoutS = Number(value());
    else if (a === "--unsafe-no-sandbox") unsafeNoSandbox = true;
    else if (a.startsWith("-")) {
      process.stderr.write(
        `email-webmail-signin: unknown option ${a}\n${USAGE}`,
      );
      return 2;
    } else if (set === undefined) set = a;
    else {
      process.stderr.write(`email-webmail-signin: one SET only\n${USAGE}`);
      return 2;
    }
  }
  const w = set === undefined ? undefined : WEBMAIL_SIGNIN[set];
  if (set === undefined || w === undefined || !(timeoutS > 0)) {
    process.stderr.write(
      `email-webmail-signin: unknown set or bad timeout\n${USAGE}`,
    );
    return 2;
  }
  const base = currentHost();
  const host: HostEnv =
    dir === null
      ? base
      : { ...base, env: { ...base.env, ISONIM_EMAIL_CREDENTIALS_DIR: dir } };
  if (!host.env.DISPLAY && !host.env.WAYLAND_DISPLAY) {
    process.stderr.write(
      "email-webmail-signin: needs the operator's display (DISPLAY or WAYLAND_DISPLAY): the webmail opens in a visible browser\n",
    );
    return 2;
  }
  let acct;
  try {
    acct = loadHostedAccount(set, host, { account, needsAppPassword: false });
  } catch (err) {
    if (err instanceof CredentialsUnavailable) {
      process.stdout.write(`PENDING: ${err.message}\n`);
      return 3;
    }
    throw err;
  }
  const profile = accountProfile(host, set, acct.file, true);
  const driver = resolveDriver(host.env);
  if ("reason" in driver) throw new Error(driver.reason);

  if (!checkOnly) {
    const chromium = pinnedChromium(host.env);
    if ("reason" in chromium) throw new Error(chromium.reason);
    let browser: ChildProcess | null = null;
    let clipboard: ClipboardGuard | null = null;
    // Ctrl-C, a closed terminal or a kill: the password off the
    // clipboard and the browser stopped, then exit 128+N.
    const removeCleanup = installSignalCleanup(() => {
      clipboard?.clear();
      if (browser !== null && browser.exitCode === null)
        browser.kill(BROWSER_STOP_SIGNAL);
    });
    const rl = createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    // readline takes Ctrl-C from a terminal itself: hand it on.
    rl.on("SIGINT", () => process.kill(process.pid, "SIGINT"));
    process.stdout.write(
      [
        `Sign in to ${w.label} as the QA account ${acct.file}:`,
        "",
        `    address:  ${acct.address}`,
        `    password: the "password" of ${join(credentialsDir(host), acct.file)} (not shown)`,
        `    profile:  ${profile.dir}`,
        "",
      ].join("\n") + "\n",
    );
    if (unsafeNoSandbox)
      process.stdout.write(
        "WARNING: --unsafe-no-sandbox: the browser runs WITHOUT Chromium's sandbox while you browse the web.\n",
      );
    let said = "";
    const child = spawn(
      chromium.path,
      signinBrowserArgs(profile.userDataDir, w.inboxUrl, { unsafeNoSandbox }),
      { stdio: ["ignore", "ignore", "pipe"] },
    );
    browser = child;
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (d: string) => {
      said = (said + d).slice(-8192);
    });
    if (!unsafeNoSandbox) {
      const sandboxed = await waitSandboxed(
        child,
        profile.userDataDir,
        () => said,
      );
      if (!sandboxed.ok) {
        await stopBrowser(child);
        rl.close();
        process.stderr.write(
          `email-webmail-signin: REFUSED: Chromium's sandbox is not running (${sandboxed.reason}). ` +
            "It needs unprivileged user namespaces (or a setuid sandbox named by CHROME_DEVEL_SANDBOX). " +
            "--unsafe-no-sandbox runs without it, unsafely.\n",
        );
        return 4;
      }
    }
    process.stdout.write(
      [
        `A browser window opened on ${w.inboxUrl}${unsafeNoSandbox ? " (NOT sandboxed)" : " (sandboxed)"}.`,
        "  1. Sign in with the address and password above.",
        '  2. Complete any challenge (a code, a phone prompt, "stay signed in": yes).',
        "  3. Wait until the inbox shows.",
        "",
      ].join("\n") + "\n",
    );
    const tool = clipboardTool(host);
    if (tool !== null) {
      clipboard = new ClipboardGuard(tool, host.env);
      const answer = await rl.question(
        `Press c then Enter to copy the password to the clipboard (${clipboard.name}), or Enter to skip: `,
      );
      if (answer.trim().toLowerCase() === "c") {
        const pw = (
          JSON.parse(
            readFileSync(join(credentialsDir(host), acct.file), "utf8"),
          ) as {
            password?: unknown;
          }
        ).password;
        const copied = typeof pw === "string" && clipboard.fill(pw);
        process.stdout.write(
          copied
            ? `Copied. It is taken off the clipboard when you press Enter below, after ${CLIPBOARD_CLEAR_MS / 1000} s, or if this recipe is interrupted.\n`
            : "Could not copy it; copy it from the file yourself.\n",
        );
      }
    } else {
      process.stdout.write(
        "(No wl-copy, xclip or xsel on PATH: copy the password from the file yourself.)\n",
      );
    }
    await rl.question(
      "Then press Enter here (the browser is closed for you): ",
    );
    rl.close();
    clipboard?.clear();
    await stopBrowser(child);
    removeCleanup();
  }

  process.stdout.write(
    `Checking the profile under Playwright (${w.label}, headed)…\n`,
  );
  const pw: typeof import("playwright-core") = await import(
    pathToFileURL(join(driver.dir, "index.mjs")).href
  );
  const options = webmailLaunchOptions(host.env, false, { unsafeNoSandbox });
  if (options.executablePath !== pw.chromium.executablePath())
    throw new Error(
      `the sign-in Chromium (${options.executablePath}) is not the one Playwright drives (${pw.chromium.executablePath()})`,
    );
  const context = await pw.chromium.launchPersistentContext(
    profile.userDataDir,
    options,
  );
  let result;
  try {
    result = await checkSignedIn(context, w, timeoutS * 1000);
  } finally {
    await context.close();
  }
  if (!result.signedIn) {
    process.stdout.write(`NOT SIGNED IN: ${result.reason}\n`);
    return 1;
  }
  // A lost session's marker goes: the account is back in selection.
  clearNeedsLogin(profile);
  writeSigninRecord(profile, {
    set,
    account_file: acct.file,
    signed_in_at: new Date().toISOString(),
    host: result.host,
    browser: `chromium ${options.executablePath} (playwright-core ${driver.version})`,
  });
  process.stdout.write(
    `SIGNED IN: ${set}/${acct.file.split("/").pop()} on ${result.host}; recorded in ${profile.record}\n`,
  );
  return 0;
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
