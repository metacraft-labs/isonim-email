// tools/capture/providers/webmail_browser.test.ts — the one launcher of
// the webmail browser, and its guard against automation.
//
// What is proven: every switch of the automation list is recognised in
// the spellings a launcher would pass; the session switches and the
// profile's own switches carry none, and no colour-scheme switch; a
// start asked to carry one is refused before anything is spawned and
// before the profile is touched; a start without one spawns the webmail
// browser with the profile's switches, the caller's, then the URL,
// having written the profile's preferences (its colour mode among them)
// first; and no module that starts a browser on a webmail profile (the
// captures', the sign-in's, the profiles') imports anything from
// Playwright or calls one of its launchers.
//
// Test double (justification, per the repository's mock policy): the
// spawn seam records the command line instead of starting Chrome, so the
// refusal can be shown to happen before a process exists. The real
// browser started by this launcher is exercised in
// hosted_webmail.test.ts and webmail_signin_session.test.ts.
// Run with:
//   node --test tools/capture/providers/webmail_browser.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  AUTOMATION_SWITCHES,
  AutomationSwitchError,
  assertNoAutomation,
  automationSwitchesIn,
  sessionSwitches,
  startWebmailBrowser,
} from "./webmail_browser.ts";
import { signinBrowserArgs } from "./webmail_profiles.ts";
import { SIGNIN_SESSION_SWITCHES } from "./webmail_signin.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const scratch = mkdtempSync(join(tmpdir(), "webmail-browser-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const AUTOMATED = [
  "--remote-debugging-port=9222",
  "--remote-debugging-pipe",
  "--remote-debugging-address=0.0.0.0",
  "--enable-automation",
  "--headless",
  "--headless=new",
  "--test-type",
  "--test-type=webdriver",
  "--remote-allow-origins=*",
  "--disable-blink-features=AutomationControlled",
  "--load-extension=/tmp/ext",
  "--disable-extensions-except=/tmp/ext",
  "--auto-open-devtools-for-tabs",
  "--user-agent=Mozilla/5.0 (iPhone)",
];

describe("the automation switch list", () => {
  it("recognises every automation switch, and only those", () => {
    for (const a of AUTOMATED)
      assert.deepEqual(automationSwitchesIn([a]), [a], a);
    // Every pattern of the list is exercised by an example above.
    for (const re of AUTOMATION_SWITCHES)
      assert.ok(
        AUTOMATED.some((a) => re.test(a)),
        `no example for ${re}`,
      );
    assert.deepEqual(
      automationSwitchesIn([
        "--force-renderer-accessibility",
        "--lang=en-US",
        "--no-first-run",
        "https://mail.google.com/",
      ]),
      [],
    );
    assert.throws(
      () => assertNoAutomation(["--lang=en-US", "--enable-automation"]),
      (e: unknown) =>
        e instanceof AutomationSwitchError &&
        e.switches.join() === "--enable-automation",
    );
  });

  it("the session and profile switches carry none, and no colour-scheme switch", () => {
    const argv = signinBrowserArgs("/p", "https://x.test/", {
      extra: sessionSwitches(1240, 2400),
    });
    assert.deepEqual(automationSwitchesIn(argv), []);
    // The scheme is the profile's colour mode, never a switch.
    assert.ok(
      !argv.some((a) => /dark|color-?scheme|blink-settings/i.test(a)),
      argv.join(" "),
    );
    assert.ok(argv.includes("--window-size=1240,2400"));
    assert.ok(argv.includes("--force-renderer-accessibility"));
    assert.equal(argv.at(-1), "https://x.test/");
    assert.deepEqual(automationSwitchesIn([...SIGNIN_SESSION_SWITCHES]), []);
    assert.ok(SIGNIN_SESSION_SWITCHES.includes("--window-size=1280,900"));
  });
});

describe("startWebmailBrowser", () => {
  const chrome = { path: "/nonexistent/google-chrome", label: "test" };

  it("refuses an automation switch before spawning or touching the profile", async () => {
    for (const bad of ["--remote-debugging-pipe", "--enable-automation"]) {
      const userDataDir = join(scratch, `refused-${bad.slice(2, 10)}`);
      let spawned = 0;
      await assert.rejects(
        startWebmailBrowser({
          chrome,
          userDataDir,
          url: "https://mail.google.com/",
          env: {},
          extra: [...sessionSwitches(800, 600), bad],
          scheme: "light",
          unsafeNoSandbox: true,
          spawnImpl: () => {
            spawned++;
            throw new Error("must not spawn");
          },
        }),
        (e: unknown) => e instanceof AutomationSwitchError,
      );
      assert.equal(spawned, 0);
      assert.equal(
        existsSync(join(userDataDir, "Default", "Preferences")),
        false,
      );
    }
  });

  it("spawns the webmail browser with the profile's switches, the caller's, then the URL", async () => {
    const userDataDir = join(scratch, "started");
    const seen: { file: string; args: string[]; env: unknown }[] = [];
    const started = await startWebmailBrowser({
      chrome,
      userDataDir,
      url: "https://mail.google.com/mail/u/0/#inbox",
      env: { DISPLAY: ":99" },
      extra: sessionSwitches(1240, 2400),
      scheme: "dark",
      unsafeNoSandbox: true,
      spawnImpl: (file, args, opts) => {
        seen.push({ file, args, env: opts.env });
        return spawn(process.execPath, ["-e", ""], { stdio: "pipe" });
      },
    });
    assert.equal(started.ok, true);
    assert.equal(seen.length, 1);
    assert.equal(seen[0]!.file, chrome.path);
    assert.deepEqual(seen[0]!.env, { DISPLAY: ":99" });
    const args = seen[0]!.args;
    assert.equal(args[0], `--user-data-dir=${userDataDir}`);
    assert.equal(args.at(-1), "https://mail.google.com/mail/u/0/#inbox");
    assert.ok(args.includes("--password-store=basic"));
    assert.ok(args.includes("--window-size=1240,2400"));
    assert.deepEqual(automationSwitchesIn(args), []);
    if (started.ok) assert.deepEqual(started.argv, args);
    // The profile's preferences were written before the start.
    const prefs = JSON.parse(
      readFileSync(join(userDataDir, "Default", "Preferences"), "utf8"),
    );
    assert.equal(prefs.credentials_enable_service, false);
    // The caller's scheme is the profile's colour mode (dark: 2).
    assert.deepEqual(prefs.browser.theme, {
      color_scheme2: 2,
      color_scheme: 2,
    });
  });
});

describe("the webmail-profile modules and Playwright", () => {
  it("import nothing from Playwright and call none of its launchers", () => {
    for (const f of [
      "hosted_webmail.ts",
      "webmail_desktop.ts",
      "webmail_browser.ts",
      "a11y_tree.ts",
      "webmail_adapters.ts",
      "webmail_profiles.ts",
      "webmail_signin.ts",
      "webmail_accounts.ts",
      join("..", "email-webmail-signin.ts"),
    ]) {
      const src = readFileSync(join(scriptDir, f), "utf8");
      assert.doesNotMatch(src, /from\s+["'][^"']*playwright/i, f);
      assert.doesNotMatch(src, /import\(\s*[^)]*playwright/i, f);
      assert.doesNotMatch(
        src,
        /launchPersistentContext|connectOverCDP|chromium\.launch|resolveDriver/,
        f,
      );
    }
  });
});
