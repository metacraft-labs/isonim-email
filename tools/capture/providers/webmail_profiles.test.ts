// tools/capture/providers/webmail_profiles.test.ts — the hosted-webmail
// browser profiles: where they live, and the signed-in check the
// sign-in and the capture provider share.
//
// What is proven: a profile's directory is resolved from
// ISONIM_EMAIL_WEBMAIL_PROFILES_DIR, else XDG_STATE_HOME, else HOME,
// and created 0700 at every level (a looser existing level is
// tightened); the signed-in check, run in a Playwright persistent
// context on the profile, reports a profile that the "webmail" sends to
// another host as not signed in, naming that host, and a profile whose
// session cookie was stored (as a person's sign-in leaves it) as signed
// in after the browser is closed and the profile reopened, which needs
// the cookie store to persist in the profile; a mail host without the
// mailbox marker is not signed in either; the sign-in recipe needs no
// display of the operator's and stops, pending, without an account file.
// The sign-in browser (the dev shell's webmail browser, Google Chrome,
// started without Playwright, with the sign-in's own command line,
// headless here) runs its renderers under a seccomp filter, and a
// session it was given by the site is read back as signed in by
// Playwright opening the same profile with the same executable (as the
// hosted-webmail captures do), sandboxed too; a browser without the
// sandbox, or one that aborts for want of one, is refused, naming why.
// The profile's preferences (the password manager and the sign-in
// interception off, Chrome's own sign-in on, the pages' languages) are
// merged key by key into Default/Preferences, 0600, never replacing a
// file that is not a JSON object; the saved passwords a profile holds
// are counted (saved logins, not "never save" entries; password hashes
// in Preferences and in Local State) and a database or a preferences file
// that cannot be read counts as a failure; the password hashes are
// scrubbed from both files, every other key kept, atomically and 0600, a
// file without them left untouched and one that is not a JSON object never
// replaced; a process running on a profile is found by its
// --user-data-dir argument and by the live process Chrome's SingletonLock
// names (not by a stale lock or another host's).
//
// Test doubles (justification, per the repository's mock policy): the
// hosted webmails cannot be signed in from a test (a test never signs in
// to a real account). A local HTTP server
// plays one: its inbox on 127.0.0.1 shows a search form to a browser
// holding its session cookie and redirects any other browser to a
// "sign-in" page on another host (localhost), which has a search box of
// its own; its /login sets the session cookie, as a sign-in does.
// Chromium, Playwright, the persistent profile, the sandbox and the
// check are real. One double more: a stand-in Chromium executable that
// aborts as Chromium does without a usable sandbox (a host without
// user namespaces cannot be made from inside a test). And Chrome's
// `Login Data` databases are written by the test with the `logins`
// table reduced to the columns the count reads (Chrome writes them only
// when it saves a password, which the real-browser session test proves
// it no longer does), and the password-hash entries with the keys Chrome
// 147 writes and no real value (the session test has Chrome write a real
// one).
// Run with:
//   node --test tools/capture/providers/webmail_profiles.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { DatabaseSync } from "node:sqlite";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { hostname, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { resolveDriver } from "./browser_emulation.ts";
import { launchOptions } from "../launch.ts";
import { CREDENTIALS_SCHEMA } from "./requirements.ts";
import {
  accountProfile,
  browsersOn,
  checkSignedIn,
  PASSWORD_HASH_LOCATIONS,
  scrubPasswordHashes,
  webmailBrowser,
  profilesRoot,
  readSigninRecord,
  rendererSandboxes,
  signinBrowserArgs,
  stopBrowser,
  holdsSecrets,
  secretsAtRest,
  waitSandboxed,
  type WebmailSignin,
  WEBMAIL_PROFILE_PREFS,
  webmailLaunchOptions,
  writeSigninRecord,
  writeWebmailProfilePrefs,
} from "./webmail_profiles.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const signinCli = join(repoRoot, "tools", "capture", "email-webmail-signin.ts");
const scratch = mkdtempSync(join(tmpdir(), "webmail-profiles-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const mode = (p: string): number => statSync(p).mode & 0o777;

describe("hosted-webmail browser profiles", () => {
  it("never replaces a Preferences file that is not a JSON object when it writes the profile's preferences", () => {
    for (const body of ["[]", "null", "not json {"]) {
      const dir = mkdtempSync(join(scratch, "prefs-"));
      const prefs = join(dir, "Default", "Preferences");
      mkdirSync(dirname(prefs));
      writeFileSync(prefs, body);
      assert.throws(() => writeWebmailProfilePrefs(dir), body);
      assert.equal(readFileSync(prefs, "utf8"), body);
    }
  });

  it("turns the password manager, the sign-in interception and page translation off, and Chrome's own sign-in back on, merging key by key", () => {
    // The values themselves (capture spec): a change here is a change of
    // what Chrome is told, and must be deliberate.
    assert.deepEqual(WEBMAIL_PROFILE_PREFS, {
      credentials_enable_service: false,
      credentials_enable_autosignin: false,
      profile: {
        password_manager_enabled: false,
        password_manager_leak_detection: false,
      },
      signin: {
        interception_enabled: false,
        allowed: true,
        allowed_on_next_startup: true,
      },
      intl: { accept_languages: "en-US,en" },
      translate: { enabled: false },
    });
    const dir = mkdtempSync(join(scratch, "prefs-"));
    const prefs = join(dir, "Default", "Preferences");
    mkdirSync(dirname(prefs));
    // A profile the first follow-up left with Chrome's sign-in off, and
    // keys of Chrome's own beside the ones written.
    writeFileSync(
      prefs,
      JSON.stringify({
        keep: { me: 1 },
        credentials_enable_service: true,
        profile: { name: "Person 1", password_manager_enabled: true },
        signin: { allowed: false, allowed_on_next_startup: false, other: 2 },
        translate: { enabled: true, other: 3 },
      }),
      { mode: 0o644 },
    );
    writeWebmailProfilePrefs(dir);
    assert.deepEqual(JSON.parse(readFileSync(prefs, "utf8")), {
      keep: { me: 1 },
      credentials_enable_service: false,
      credentials_enable_autosignin: false,
      profile: {
        name: "Person 1",
        password_manager_enabled: false,
        password_manager_leak_detection: false,
      },
      signin: {
        allowed: true,
        allowed_on_next_startup: true,
        other: 2,
        interception_enabled: false,
      },
      intl: { accept_languages: "en-US,en" },
      translate: { enabled: false, other: 3 },
    });
    assert.equal(mode(prefs), 0o600);
    // A fresh profile gets them all.
    const fresh = mkdtempSync(join(scratch, "prefs-"));
    writeWebmailProfilePrefs(fresh);
    assert.deepEqual(
      JSON.parse(readFileSync(join(fresh, "Default", "Preferences"), "utf8")),
      WEBMAIL_PROFILE_PREFS,
    );
  });

  it("counts the saved passwords a profile holds, without reading one, and fails on a database it cannot read", () => {
    const dir = mkdtempSync(join(scratch, "rest-"));
    const def = join(dir, "Default");
    mkdirSync(def);
    // No databases at all: nothing at rest.
    assert.deepEqual(secretsAtRest(dir), {
      savedLogins: 0,
      accountLogins: 0,
      passwordHashes: 0,
      unreadable: [],
    });
    // Chrome's `logins` table, reduced to the columns the count needs:
    // two saved logins and one "never save" entry; the account store one.
    const make = (name: string, rows: number[]) => {
      const db = new DatabaseSync(join(def, name));
      db.exec(
        "CREATE TABLE logins (origin_url TEXT, password_value BLOB, blacklisted_by_user INTEGER)",
      );
      const ins = db.prepare(
        "INSERT INTO logins (origin_url, password_value, blacklisted_by_user) VALUES (?, ?, ?)",
      );
      for (const b of rows) ins.run("https://example.test/", "x", b);
      db.close();
    };
    make("Login Data", [0, 0, 1]);
    make("Login Data For Account", [0]);
    writeFileSync(
      join(def, "Preferences"),
      JSON.stringify({ profile: { password_hash_data_list: [{}, {}] } }),
    );
    const s = secretsAtRest(dir);
    assert.deepEqual(s, {
      savedLogins: 2,
      accountLogins: 1,
      passwordHashes: 2,
      unreadable: [],
    });
    assert.equal(holdsSecrets(s), true);
    // Only "never save" entries: nothing at rest.
    rmSync(join(def, "Login Data"));
    rmSync(join(def, "Login Data For Account"));
    make("Login Data", [1]);
    writeFileSync(join(def, "Preferences"), "{}");
    assert.equal(holdsSecrets(secretsAtRest(dir)), false);
    // A database that is not one proves nothing: a failure.
    writeFileSync(join(def, "Login Data For Account"), "not a database");
    const bad = secretsAtRest(dir);
    assert.equal(bad.unreadable.length, 1);
    assert.match(bad.unreadable[0]!, /^Login Data For Account \(/);
    assert.equal(holdsSecrets(bad), true);
  });

  it("counts the password hashes in Local State too, and a hash file that is not a JSON object as unreadable", () => {
    const dir = mkdtempSync(join(scratch, "rest-"));
    mkdirSync(join(dir, "Default"));
    writeFileSync(
      join(dir, "Local State"),
      JSON.stringify({ local: { password_hash_data_list: [{}] } }),
    );
    writeFileSync(
      join(dir, "Default", "Preferences"),
      JSON.stringify({ profile: { password_hash_data_list: [{}, {}] } }),
    );
    assert.equal(secretsAtRest(dir).passwordHashes, 3);
    writeFileSync(join(dir, "Local State"), "[]");
    const bad = secretsAtRest(dir);
    assert.deepEqual(bad.unreadable, ["Local State (not a JSON object)"]);
    assert.equal(holdsSecrets(bad), true);
  });

  it("scrubs the password hashes from Preferences and Local State, keeping every other key, atomically and 0600", () => {
    // Where Chromium 147 keeps them (hash_password_manager.cc).
    assert.deepEqual(
      PASSWORD_HASH_LOCATIONS.map((l) => [l.file, ...l.key]),
      [
        ["Default/Preferences", "profile", "password_hash_data_list"],
        ["Local State", "local", "password_hash_data_list"],
      ],
    );
    const dir = mkdtempSync(join(scratch, "scrub-"));
    mkdirSync(join(dir, "Default"));
    const prefs = join(dir, "Default", "Preferences");
    const local = join(dir, "Local State");
    // As Chrome 147 writes an entry (no value is read by the scrub).
    const entry = {
      hash: "1",
      is_gaia: "x",
      last_signin: 1,
      salt_length: "y",
      username: "z",
    };
    writeFileSync(
      prefs,
      JSON.stringify({
        keep: [1, 2],
        profile: { name: "Person 1", password_hash_data_list: [entry, entry] },
      }),
      { mode: 0o644 },
    );
    writeFileSync(
      local,
      JSON.stringify({
        local: { password_hash_data_list: [entry], other: true },
        browser: { x: 1 },
      }),
      { mode: 0o644 },
    );
    assert.equal(secretsAtRest(dir).passwordHashes, 3);
    assert.deepEqual(scrubPasswordHashes(dir), {
      removed: 3,
      rewritten: ["Default/Preferences", "Local State"],
    });
    assert.deepEqual(JSON.parse(readFileSync(prefs, "utf8")), {
      keep: [1, 2],
      profile: { name: "Person 1" },
    });
    assert.deepEqual(JSON.parse(readFileSync(local, "utf8")), {
      local: { other: true },
      browser: { x: 1 },
    });
    assert.equal(mode(prefs), 0o600);
    assert.equal(mode(local), 0o600);
    assert.equal(holdsSecrets(secretsAtRest(dir)), false);
    // No temporary file left beside them.
    for (const d of [dir, join(dir, "Default")])
      assert.deepEqual(
        readdirSync(d).filter((f) => f.endsWith(".tmp")),
        [],
        d,
      );
    // Nothing to remove: no file is rewritten.
    const before = statSync(prefs).mtimeMs;
    assert.deepEqual(scrubPasswordHashes(dir), { removed: 0, rewritten: [] });
    assert.equal(statSync(prefs).mtimeMs, before);
    // An empty profile: nothing to do.
    assert.deepEqual(
      scrubPasswordHashes(mkdtempSync(join(scratch, "scrub-"))),
      {
        removed: 0,
        rewritten: [],
      },
    );
  });

  it("never replaces a hash file that is not a JSON object when it scrubs", () => {
    for (const body of ["[]", "null", "not json {"]) {
      const dir = mkdtempSync(join(scratch, "scrub-"));
      mkdirSync(join(dir, "Default"));
      writeFileSync(join(dir, "Default", "Preferences"), body);
      assert.throws(() => scrubPasswordHashes(dir), body);
      assert.equal(
        readFileSync(join(dir, "Default", "Preferences"), "utf8"),
        body,
      );
    }
  });

  it("finds a process running on a profile by its --user-data-dir, and by Chrome's SingletonLock while its process lives", async () => {
    const dir = mkdtempSync(join(scratch, "running-"));
    assert.deepEqual(browsersOn(dir), []);
    const child = spawn(process.execPath, [
      "-e",
      "setTimeout(() => {}, 60000)",
      "--",
      `--user-data-dir=${dir}`,
    ]);
    try {
      await sleep(300);
      assert.deepEqual(browsersOn(dir), [child.pid]);
      // Another directory whose name starts the same is not this one.
      assert.deepEqual(browsersOn(dir.slice(0, -1)), []);
    } finally {
      child.kill("SIGKILL");
      await new Promise((r) => child.once("exit", r));
    }
    assert.deepEqual(browsersOn(dir), []);
    // The lock Chrome leaves: <host>-<pid>.
    const lockHolder = spawn(process.execPath, [
      "-e",
      "setTimeout(() => {}, 60000)",
    ]);
    try {
      await sleep(100);
      symlinkSync(
        `${hostname()}-${lockHolder.pid}`,
        join(dir, "SingletonLock"),
      );
      assert.deepEqual(browsersOn(dir), [lockHolder.pid]);
    } finally {
      lockHolder.kill("SIGKILL");
      await new Promise((r) => lockHolder.once("exit", r));
    }
    // A stale lock (its process gone) or another host's: no browser.
    assert.deepEqual(browsersOn(dir), []);
    rmSync(join(dir, "SingletonLock"));
    symlinkSync(`another-host-${process.pid}`, join(dir, "SingletonLock"));
    assert.deepEqual(browsersOn(dir), []);
  });

  it("resolves the profile directory from the variable, XDG_STATE_HOME or HOME, and creates it 0700 at every level", () => {
    const linux = (env: Record<string, string>) => ({ env, platform: "linux" });
    assert.equal(
      profilesRoot(
        linux({
          ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: "/p",
          XDG_STATE_HOME: "/s",
          HOME: "/h",
        }),
      ),
      "/p",
    );
    assert.equal(
      profilesRoot(linux({ XDG_STATE_HOME: "/s", HOME: "/h" })),
      "/s/isonim-email/webmail-profiles",
    );
    assert.equal(
      profilesRoot(linux({ HOME: "/h" })),
      "/h/.local/state/isonim-email/webmail-profiles",
    );

    const root = join(scratch, "profiles");
    const host = linux({ ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: root });
    mkdirSync(join(root, "yahoo"), { recursive: true, mode: 0o755 });
    chmodSync(join(root, "yahoo"), 0o755);
    const p = accountProfile(host, "yahoo", "yahoo/qa1.json", true);
    assert.equal(p.dir, join(root, "yahoo", "qa1"));
    assert.equal(p.userDataDir, join(root, "yahoo", "qa1", "chromium"));
    for (const d of [root, join(root, "yahoo"), p.dir, p.userDataDir])
      assert.equal(mode(d), 0o700, d);
    writeSigninRecord(p, {
      set: "yahoo",
      account_file: "yahoo/qa1.json",
      signed_in_at: "2026-10-17T00:00:00.000Z",
      host: "mail.yahoo.com",
      browser: "chromium",
    });
    assert.equal(mode(p.record), 0o600);
    assert.equal(readSigninRecord(p)?.host, "mail.yahoo.com");
  });

  it("finds the webmail browser through the dev shell's variables, and says what is missing", () => {
    const exe = join(scratch, "webmail-browser");
    writeFileSync(exe, "#!/bin/sh\n", { mode: 0o755 });
    assert.deepEqual(
      webmailBrowser({
        ISONIM_EMAIL_WEBMAIL_BROWSER: exe,
        ISONIM_EMAIL_WEBMAIL_BROWSER_LABEL: "Google Chrome 147.0.7727.137",
      }),
      { path: exe, label: "Google Chrome 147.0.7727.137" },
    );
    assert.deepEqual(webmailBrowser({ ISONIM_EMAIL_WEBMAIL_BROWSER: exe }), {
      path: exe,
      label: exe,
    });
    const unset = webmailBrowser({});
    assert.ok("reason" in unset);
    assert.match(unset.reason, /ISONIM_EMAIL_WEBMAIL_BROWSER is not set/);
    const gone = webmailBrowser({
      ISONIM_EMAIL_WEBMAIL_BROWSER: join(scratch, "no-such-browser"),
    });
    assert.ok("reason" in gone);
    assert.match(gone.reason, /no-such-browser does not exist/);
    // The captures open a profile with that same executable.
    assert.equal(
      webmailLaunchOptions(
        { ...process.env, ISONIM_EMAIL_WEBMAIL_BROWSER: exe },
        true,
      ).executablePath,
      exe,
    );
  });

  describe("the signed-in check", () => {
    let server: Server;
    let port: number;
    let pw: typeof import("playwright-core");
    // Requests for the inbox that carried the session cookie.
    let signedInVisits = 0;
    before(async () => {
      server = createServer((req, res) => {
        const signedIn = /(?:^|; )session=yes(?:;|$)/.test(
          req.headers.cookie ?? "",
        );
        if (req.url === "/login") {
          // A sign-in: the site sets a persistent session cookie.
          res.writeHead(302, {
            "set-cookie": "session=yes; Max-Age=86400; Path=/",
            location: "/mail/",
          });
          return res.end();
        }
        if (req.url === "/mail/" && signedIn) signedInVisits++;
        if (req.url === "/mail/") {
          if (!signedIn) {
            res.writeHead(302, { location: `http://localhost:${port}/signin` });
            return res.end();
          }
          res.writeHead(200, { "content-type": "text/html" });
          return res.end(
            '<!doctype html><form role="search"><input name="q"></form><p>Inbox</p>',
          );
        }
        if (req.url === "/nomarker/") {
          res.writeHead(200, { "content-type": "text/html" });
          return res.end("<!doctype html><p>Loading…</p>");
        }
        res.writeHead(200, { "content-type": "text/html" });
        // A sign-in or marketing page can have a search box too: only
        // the host tells it from the mailbox.
        res.end(
          '<!doctype html><form role="search"><input name="q"></form><p>Sign in</p><input type=password>',
        );
      });
      await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
      port = (server.address() as AddressInfo).port;
      const driver = resolveDriver(process.env);
      if ("reason" in driver) throw new Error(driver.reason);
      pw = await import(pathToFileURL(join(driver.dir, "index.mjs")).href);
    });
    after(() => new Promise<void>((r) => server.close(() => r())));

    const webmail = (path = "/mail/"): WebmailSignin => ({
      label: "Test webmail",
      inboxUrl: `http://127.0.0.1:${port}${path}`,
      mailHosts: [`127.0.0.1:${port}`],
      marker: 'form[role="search"], input[name="q"]',
    });
    const open = (dir: string) =>
      pw.chromium.launchPersistentContext(dir, {
        ...launchOptions("chromium", false, process.platform, process.env),
        headless: true,
      });

    it("reports a redirected profile as not signed in, and a profile holding its session as signed in after it is reopened", async () => {
      const host = {
        env: { ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: join(scratch, "check") },
        platform: "linux",
      };
      const p = accountProfile(
        host,
        "gmail-workspace",
        "gmail-workspace/qa1.json",
        true,
      );

      const first = await open(p.userDataDir);
      try {
        const r = await checkSignedIn(first, webmail(), 3000);
        assert.equal(r.signedIn, false);
        assert.ok(!r.signedIn);
        assert.equal(r.host, `localhost:${port}`);
        assert.match(
          r.reason,
          new RegExp(
            `redirected to localhost:${port}, not 127\\.0\\.0\\.1:${port}: the profile is not signed in`,
          ),
        );
        // What a person's sign-in leaves in the profile: a persistent
        // session cookie.
        await first.addCookies([
          {
            name: "session",
            value: "yes",
            domain: "127.0.0.1",
            path: "/",
            expires: Math.floor(Date.now() / 1000) + 86400,
          },
        ]);
      } finally {
        await first.close();
      }

      const second = await open(p.userDataDir);
      try {
        const r = await checkSignedIn(second, webmail(), 10_000);
        assert.deepEqual(r, { signedIn: true, host: `127.0.0.1:${port}` });
        // The mail host without the mailbox marker is not signed in.
        const n = await checkSignedIn(second, webmail("/nomarker/"), 1500);
        assert.equal(n.signedIn, false);
        assert.ok(!n.signedIn);
        assert.match(
          n.reason,
          /loaded on 127\.0\.0\.1:\d+ but the mailbox marker .* did not appear/,
        );
      } finally {
        await second.close();
      }
    });

    it("reads a profile signed in by the sandboxed sign-in browser back as signed in under Playwright, with the same executable", async () => {
      const chromium = webmailBrowser(process.env);
      if ("reason" in chromium) throw new Error(chromium.reason);
      // A regular release build, not Playwright's Chrome for Testing;
      // Playwright opens the profile with that same executable.
      assert.notEqual(chromium.path, pw.chromium.executablePath());
      assert.match(chromium.label, /^(Google Chrome|Chromium) \d+\./);
      const options = webmailLaunchOptions(process.env, true);
      assert.equal(options.executablePath, chromium.path);
      assert.equal(options.chromiumSandbox, true);

      const host = {
        env: { ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: join(scratch, "signin") },
        platform: "linux",
      };
      const p = accountProfile(host, "yahoo", "yahoo/qa1.json", true);
      const before = signedInVisits;
      let said = "";
      const child = spawn(
        chromium.path,
        signinBrowserArgs(p.userDataDir, `http://127.0.0.1:${port}/login`, {
          headless: true,
        }),
        { stdio: ["ignore", "ignore", "pipe"] },
      );
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (d: string) => {
        said = (said + d).slice(-8192);
      });
      try {
        const sandboxed = await waitSandboxed(child, p.userDataDir, () => said);
        assert.ok(sandboxed.ok, JSON.stringify(sandboxed));
        const deadline = Date.now() + 60_000;
        while (signedInVisits === before && Date.now() < deadline)
          await sleep(250);
        assert.ok(
          signedInVisits > before,
          "the sign-in browser reached the inbox signed in",
        );
      } finally {
        await stopBrowser(child);
      }

      const context = await pw.chromium.launchPersistentContext(
        p.userDataDir,
        options,
      );
      try {
        const r = await checkSignedIn(context, webmail(), 10_000);
        assert.deepEqual(r, { signedIn: true, host: `127.0.0.1:${port}` });
        // Playwright's browser on the profile is sandboxed as well.
        assert.ok(
          rendererSandboxes(p.userDataDir).some((x) => x.seccomp),
          JSON.stringify(rendererSandboxes(p.userDataDir)),
        );
      } finally {
        await context.close();
      }
    });

    it("refuses a sign-in browser without the sandbox, and one that aborts for want of it, naming why", async () => {
      const chromium = webmailBrowser(process.env);
      if ("reason" in chromium) throw new Error(chromium.reason);
      const dir = join(scratch, "unsandboxed", "chromium");
      mkdirSync(dir, { recursive: true });
      const child = spawn(
        chromium.path,
        signinBrowserArgs(dir, `http://127.0.0.1:${port}/nomarker/`, {
          headless: true,
          unsafeNoSandbox: true,
        }),
        { stdio: "ignore" },
      );
      try {
        const r = await waitSandboxed(child, dir, () => "", 90_000, 3000);
        assert.equal(r.ok, false);
        assert.ok(!r.ok);
        assert.match(
          r.reason,
          /without a seccomp filter: the browser is not sandboxed/,
        );
      } finally {
        await stopBrowser(child);
      }

      // What Chromium does on a host without unprivileged user
      // namespaces and without a setuid sandbox.
      const fake = join(scratch, "no-usable-sandbox");
      writeFileSync(
        fake,
        "#!/bin/sh\necho '[1:1:FATAL:content/browser/zygote_host/zygote_host_impl_linux.cc:128] No usable sandbox! You are probably running on a system that does not have unprivileged user namespaces.' >&2\nexit 133\n",
        { mode: 0o755 },
      );
      let said = "";
      const aborts = spawn(fake, signinBrowserArgs(dir, "about:blank"), {
        stdio: ["ignore", "ignore", "pipe"],
      });
      aborts.stderr.setEncoding("utf8");
      aborts.stderr.on("data", (d: string) => {
        said += d;
      });
      const r = await waitSandboxed(aborts, dir, () => said, 30_000);
      assert.equal(r.ok, false);
      assert.ok(!r.ok);
      assert.match(
        r.reason,
        /the browser exited \(133\) before running a sandboxed renderer: .*No usable sandbox!/,
      );
    });
  });

  it("the sign-in recipe needs no display of the operator's, and stops, pending, without an account file", () => {
    const dir = join(scratch, "creds");
    mkdirSync(dir, { mode: 0o700 });
    chmodSync(dir, 0o700);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      ISONIM_EMAIL_CREDENTIALS_DIR: dir,
      ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: join(scratch, "cli"),
    };
    // It runs in a private session of its own: no DISPLAY needed.
    delete env.DISPLAY;
    delete env.WAYLAND_DISPLAY;
    for (const args of [["yahoo"], ["yahoo", "--check-only"]]) {
      const pending = spawnSync(process.execPath, [signinCli, ...args], {
        env,
        encoding: "utf8",
      });
      assert.equal(pending.status, 3, pending.stdout + pending.stderr);
      assert.match(pending.stdout, /PENDING: no account file for yahoo/);
    }
    // A filled account file but an unknown set is a usage error.
    mkdirSync(join(dir, "yahoo"), { mode: 0o700 });
    writeFileSync(
      join(dir, "yahoo", "qa1.json"),
      JSON.stringify({
        schema: CREDENTIALS_SCHEMA,
        address: "a@b.invalid",
        password: "p",
      }),
      { mode: 0o600 },
    );
    const unknown = spawnSync(process.execPath, [signinCli, "nope"], {
      env,
      encoding: "utf8",
    });
    assert.equal(unknown.status, 2);
  });
});
