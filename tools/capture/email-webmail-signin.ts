// tools/capture/email-webmail-signin.ts — `just email-webmail-signin`:
// the guided first sign-in of a hosted-webmail QA account's browser
// profile, by a person.
//
// It prints the account's address (never its password), offers to put
// the password on the clipboard without printing it, and opens the
// provider's webmail in the shell's pinned Chromium, started WITHOUT
// automation (no Playwright, no DevTools protocol) on the operator's
// display, in the account's persistent profile
// (providers/webmail_profiles.ts). The person signs in, completes any
// challenge, and presses Enter. The recipe then closes that browser,
// clears the clipboard if it filled it, opens the same profile under
// Playwright (headed, as the capture provider will) and checks that the
// inbox loads signed in. On success it records the sign-in in the
// profile's signin.json.
//
// It never types into a page: a sign-in is a person's. `--check-only`
// skips the sign-in and only checks (and records) an existing profile.

import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { createInterface } from "node:readline/promises";
import { resolveDriver } from "./providers/browser_emulation.ts";
import { launchOptions } from "./launch.ts";
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
  accountProfile,
  checkSignedIn,
  COOKIE_STORE_SWITCHES,
  pinnedChromium,
  PROFILES_ENV,
  WEBMAIL_SIGNIN,
  writeSigninRecord,
} from "./providers/webmail_profiles.ts";

const USAGE = `usage: email-webmail-signin SET [--account NAME] [--check-only]
                            [--dir DIR] [--timeout SECONDS]

The first sign-in of a QA account's browser profile, done by a person on
this machine's display. Sets: ${Object.keys(WEBMAIL_SIGNIN).join(", ")}.

1) Prints the account's address (SET's first account file, or
  SET/NAME.json with --account) and offers to copy its password to the
  clipboard (wl-copy, xclip or xsel), never printing it.
2) Opens the webmail in the pinned Chromium, without automation, in the
  account's profile under $${PROFILES_ENV}
  (default \${XDG_STATE_HOME:-$HOME/.local/state}/isonim-email/webmail-profiles).
3) You sign in and complete any challenge, then press Enter here.
4) It closes that browser, opens the profile under Playwright (headed)
  and checks the inbox is signed in; on success it writes signin.json.

--check-only  skip steps 1-3: only check (and record) the profile
--dir DIR     the credentials directory (default $ISONIM_EMAIL_CREDENTIALS_DIR,
              else \${XDG_CONFIG_HOME:-$HOME/.config}/metacraft/dev-credentials/isonim-email)
--timeout S   how long the check waits for the inbox (default 45)

Exit status: 0 signed in (recorded); 1 not signed in, or failed;
2 usage, or no display; 3 pending (no account file).
`;

function clipboardTool(host: HostEnv): string[] | null {
  if (host.env.WAYLAND_DISPLAY && findExecutable("wl-copy", host) !== null)
    return ["wl-copy"];
  if (host.env.DISPLAY) {
    if (findExecutable("xclip", host) !== null)
      return ["xclip", "-selection", "clipboard"];
    if (findExecutable("xsel", host) !== null)
      return ["xsel", "--clipboard", "--input"];
  }
  return null;
}

function setClipboard(tool: string[], text: string): boolean {
  const r = spawnSync(tool[0]!, tool.slice(1), {
    input: text,
    stdio: ["pipe", "ignore", "ignore"],
    timeout: 5000,
  });
  return r.status === 0;
}

async function stop(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise<void>((r) => child.once("exit", () => r()));
  child.kill("SIGTERM");
  const t = setTimeout(() => child.kill("SIGKILL"), 15_000);
  await exited;
  clearTimeout(t);
}

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
    const rl = createInterface({
      input: process.stdin,
      output: process.stdout,
    });
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
    const tool = clipboardTool(host);
    let copied = false;
    if (tool !== null) {
      const answer = await rl.question(
        `Press c then Enter to copy the password to the clipboard (${tool[0]}), or Enter to skip: `,
      );
      if (answer.trim().toLowerCase() === "c") {
        const pw = (
          JSON.parse(
            readFileSync(join(credentialsDir(host), acct.file), "utf8"),
          ) as {
            password?: unknown;
          }
        ).password;
        copied = typeof pw === "string" && pw !== "" && setClipboard(tool, pw);
        process.stdout.write(
          copied
            ? "Copied. It is cleared from the clipboard when you press Enter below.\n"
            : "Could not copy it; copy it from the file yourself.\n",
        );
      }
    } else {
      process.stdout.write(
        "(No wl-copy, xclip or xsel on PATH: copy the password from the file yourself.)\n",
      );
    }
    const browser = spawn(
      chromium.path,
      [
        `--user-data-dir=${profile.userDataDir}`,
        ...COOKIE_STORE_SWITCHES,
        "--no-sandbox",
        "--no-first-run",
        "--no-default-browser-check",
        w.inboxUrl,
      ],
      { stdio: "ignore" },
    );
    process.stdout.write(
      [
        "",
        `A browser window opened on ${w.inboxUrl}.`,
        "  1. Sign in with the address and password above.",
        '  2. Complete any challenge (a code, a phone prompt, "stay signed in": yes).',
        "  3. Wait until the inbox shows.",
        "",
      ].join("\n") + "\n",
    );
    await rl.question(
      "Then press Enter here (the browser is closed for you): ",
    );
    rl.close();
    await stop(browser);
    if (copied && tool !== null) setClipboard(tool, "");
  }

  process.stdout.write(
    `Checking the profile under Playwright (${w.label}, headed)…\n`,
  );
  const pw: typeof import("playwright-core") = await import(
    pathToFileURL(join(driver.dir, "index.mjs")).href
  );
  const context = await pw.chromium.launchPersistentContext(
    profile.userDataDir,
    {
      ...launchOptions("chromium", false, process.platform, host.env),
      headless: false,
    },
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
  writeSigninRecord(profile, {
    set,
    account_file: acct.file,
    signed_in_at: new Date().toISOString(),
    host: result.host,
    browser: `chromium (playwright-core ${driver.version})`,
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
