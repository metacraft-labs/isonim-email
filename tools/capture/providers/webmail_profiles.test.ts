// tools/capture/providers/webmail_profiles.test.ts — the hosted-webmail
// browser profiles: where they live, and the signed-in check the guided
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
// mailbox marker is not signed in either; the guided sign-in refuses to
// run without a display and stops, pending, without an account file.
//
// Test doubles (justification, per the repository's mock policy): the
// hosted webmails cannot be signed in from a test (a sign-in is a
// person's, and automated sign-in is refused). A local HTTP server
// plays one: its inbox on 127.0.0.1 shows a search form to a browser
// holding its session cookie and redirects any other browser to a
// "sign-in" page on another host (localhost), which has a search box of
// its own. Chromium, Playwright, the
// persistent profile and the check are real.
// Run with:
//   node --test tools/capture/providers/webmail_profiles.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { resolveDriver } from "./browser_emulation.ts";
import { launchOptions } from "../launch.ts";
import { CREDENTIALS_SCHEMA } from "./requirements.ts";
import {
  accountProfile,
  checkSignedIn,
  profilesRoot,
  readSigninRecord,
  type WebmailSignin,
  writeSigninRecord,
} from "./webmail_profiles.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const signinCli = join(repoRoot, "tools", "capture", "email-webmail-signin.ts");
const scratch = mkdtempSync(join(tmpdir(), "webmail-profiles-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const mode = (p: string): number => statSync(p).mode & 0o777;

describe("hosted-webmail browser profiles", () => {
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

  describe("the signed-in check", () => {
    let server: Server;
    let port: number;
    let pw: typeof import("playwright-core");
    before(async () => {
      server = createServer((req, res) => {
        const signedIn = /(?:^|; )session=yes(?:;|$)/.test(
          req.headers.cookie ?? "",
        );
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
  });

  it("the guided sign-in needs a display and an account file, and says so", () => {
    const dir = join(scratch, "creds");
    mkdirSync(dir, { mode: 0o700 });
    chmodSync(dir, 0o700);
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      ISONIM_EMAIL_CREDENTIALS_DIR: dir,
      ISONIM_EMAIL_WEBMAIL_PROFILES_DIR: join(scratch, "cli"),
    };
    delete env.DISPLAY;
    delete env.WAYLAND_DISPLAY;
    const noDisplay = spawnSync(process.execPath, [signinCli, "yahoo"], {
      env,
      encoding: "utf8",
    });
    assert.equal(noDisplay.status, 2, noDisplay.stderr);
    assert.match(noDisplay.stderr, /needs the operator's display/);
    const pending = spawnSync(
      process.execPath,
      [signinCli, "yahoo", "--check-only"],
      {
        env: { ...env, DISPLAY: ":99" },
        encoding: "utf8",
      },
    );
    assert.equal(pending.status, 3, pending.stdout + pending.stderr);
    assert.match(pending.stdout, /PENDING: no account file for yahoo/);
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
      env: { ...env, DISPLAY: ":99" },
      encoding: "utf8",
    });
    assert.equal(unknown.status, 2);
  });
});
