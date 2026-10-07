// tools/capture/providers/hosted_delivery.test.ts — delivery to hosted
// webmail by sending, against local servers.
//
// What is proven: an account's message, submitted through a real SMTP
// server (Mailpit) over TLS from the first byte and over STARTTLS with
// AUTH, and filed by the "provider" into real IMAP mailboxes (Dovecot
// behind TLS), is found by its Message-ID with the latency reported,
// carrying the account's From, the receiver's To, a fresh Message-ID
// and the run-token subject with every body byte unchanged; removal
// leaves no copy in INBOX, Sent, Junk, All Mail or Trash and leaves
// other messages alone; a refused login fails with a clear error and
// the password appears in no error, stack or output; a message that
// never arrives fails after the bounded wait, and one filed as junk is
// found in Junk; a receiver without IMAP gets a cross-send from the
// configured sender, confirmed by the sender's Sent copy, with its own
// copy left to the webmail; an account file without an app password is
// refused before anything connects, and the smoke command says it is
// pending; a server certificate the trusted roots do not vouch for is
// refused before any credential is sent.
//
// Test doubles (justification, per the repository's mock policy): the
// hosted provider's internal delivery between its submission server
// and its mailboxes is played by the test (hosted_delivery_fixtures.ts):
// each message the real SMTP server accepted is filed into the real
// IMAP server's mailboxes, as a provider does. Both servers, TLS,
// authentication, the clients and the CLI are real.
// Run with:
//   node --test tools/capture/providers/hosted_delivery.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
  chmodSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  CredentialsUnavailable,
  DeliveryError,
  deliverHosted,
  type MailboxProfile,
  removeHosted,
  resolveRoute,
} from "./hosted_delivery.ts";
import { LocalProvider, type TestAccount } from "./hosted_delivery_fixtures.ts";
import { ImapSession } from "./imap_client.ts";
import { MailProtocolError } from "./mail_socket.ts";
import { CREDENTIALS_SCHEMA, type HostEnv } from "./requirements.ts";
import { makeTestPki } from "./test_pki.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const smokeCli = join(repoRoot, "tools", "capture", "email-selfsend-smoke.ts");
const scratch = mkdtempSync(join(tmpdir(), "hosted-delivery-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

// Never to be printed: the account password (never used over SMTP or
// IMAP) and a wrong app password.
const ACCOUNT_PW = "acctpw-5e7a91c3-never-print";
const WRONG_APP_PW = "wrongapp-0b2d6f48-never-print";

// A story-like message: multipart, a line that starts with a dot (it
// must survive SMTP's dot-stuffing), a Cc and Bcc to drop.
const STORY = Buffer.from(
  [
    'From: "Acme Billing" <billing@acme.invalid>',
    "To: someone@acme.invalid",
    "Cc: other@acme.invalid",
    "Bcc: hidden@acme.invalid",
    "Subject: Your invoice is ready",
    "Message-ID: <story@acme.invalid>",
    "Date: Wed, 07 Oct 2026 10:00:00 +0000",
    "MIME-Version: 1.0",
    'Content-Type: multipart/alternative; boundary="b1"',
    "",
    "--b1",
    "Content-Type: text/plain; charset=us-ascii",
    "",
    "Line one",
    ".a line that starts with a dot",
    "..and one with two",
    "--b1",
    "Content-Type: text/html; charset=us-ascii",
    "",
    "<p>Invoice</p>",
    "--b1--",
    "",
  ].join("\r\n"),
  "latin1",
);

function bodyOf(raw: Uint8Array): string {
  const t = Buffer.from(raw).toString("latin1");
  return t.slice(t.indexOf("\r\n\r\n") + 4);
}

function headerOf(raw: Uint8Array, name: string): string[] {
  const t = Buffer.from(raw).toString("latin1");
  const head = t.slice(0, t.indexOf("\r\n\r\n")).replace(/\r\n[ \t]/g, " ");
  return head
    .split("\r\n")
    .filter((l) => l.toLowerCase().startsWith(`${name.toLowerCase()}:`))
    .map((l) => l.slice(name.length + 1).trim());
}

function credentialsDir(
  name: string,
  files: Record<string, Record<string, string>>,
): HostEnv {
  const dir = join(scratch, name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  for (const [rel, body] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, rel)), { recursive: true, mode: 0o700 });
    writeFileSync(
      join(dir, rel),
      JSON.stringify({ schema: CREDENTIALS_SCHEMA, ...body }),
      { mode: 0o600 },
    );
  }
  return {
    env: { ISONIM_EMAIL_CREDENTIALS_DIR: dir, HOME: scratch },
    platform: "linux",
  };
}

function accountFile(
  a: TestAccount,
  appPassword: string | null = a.appPassword,
): Record<string, string> {
  return appPassword === null
    ? { address: a.address, password: ACCOUNT_PW }
    : { address: a.address, password: ACCOUNT_PW, app_password: appPassword };
}

// Every message with the Message-ID, per mailbox, as the account sees it.
async function copies(
  p: LocalProvider,
  a: TestAccount,
  messageId: string,
): Promise<Record<string, number>> {
  const s = await ImapSession.open(
    { host: "127.0.0.1", port: p.profile("x").imap!.port, security: "tls" },
    { ca: p.caPem },
    [a.appPassword],
  );
  await s.login(a.address, a.appPassword);
  const out: Record<string, number> = {};
  for (const box of ["INBOX", "Sent", "Junk", "All Mail", "Trash"]) {
    await s.open(box, false);
    out[box] = (await s.searchHeader("Message-ID", messageId)).length;
  }
  await s.logout();
  return out;
}

async function fetchCopy(
  p: LocalProvider,
  a: TestAccount,
  mailbox: string,
  messageId: string,
): Promise<Buffer> {
  const s = await ImapSession.open(
    { host: "127.0.0.1", port: p.profile("x").imap!.port, security: "tls" },
    { ca: p.caPem },
    [a.appPassword],
  );
  await s.login(a.address, a.appPassword);
  await s.open(mailbox, false);
  const [uid] = await s.searchHeader("Message-ID", messageId);
  assert.ok(uid !== undefined, `no copy in ${mailbox}`);
  const raw = await s.fetchMessage(uid);
  await s.logout();
  return raw;
}

// The smoke command as a person runs it. Asynchronous: the servers it
// talks to (and the connection counter) run in this process.
function runSmoke(
  args: string[],
  credentials: string,
): Promise<{ status: number | null; stdout: string; stderr: string }> {
  return new Promise((ok) => {
    const child = spawn(process.execPath, [smokeCli, ...args], {
      env: { ...process.env, ISONIM_EMAIL_CREDENTIALS_DIR: credentials },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
    child.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
    child.on("close", (status) => ok({ status, stdout, stderr }));
  });
}

function leakFree(text: string, ...secrets: string[]): void {
  for (const s of secrets) {
    for (const form of [s, Buffer.from(s).toString("base64")])
      assert.equal(
        text.includes(form),
        false,
        `leaked ${form.slice(0, 6)}… in: ${text}`,
      );
    assert.equal(
      text.includes(s.slice(0, 12)),
      false,
      `leaked a prefix in: ${text}`,
    );
  }
}

for (const security of ["tls", "starttls"] as const) {
  describe(`hosted delivery by self-send (${security === "tls" ? "TLS from the first byte" : "STARTTLS"})`, () => {
    const p = new LocalProvider(security);
    let gmail: TestAccount;
    let outlook: TestAccount;
    let profiles: Record<string, MailboxProfile>;
    before(async () => {
      await p.start(`hd-${security}-${process.pid}`);
      gmail = await p.addAccount(`gmailapp${security}0a1b`);
      outlook = await p.addAccount(`outlookapp${security}2c3d`);
      profiles = {
        "gmail-workspace": p.profile("gmail-workspace"),
        "outlook-com": p.profile("outlook-com", {
          canSend: false,
          crossSendFrom: "gmail-workspace",
        }),
      };
    });
    after(async () => {
      await p.stop();
    });
    const opts = (): {
      run: string;
      trust: { ca: string };
      arrivalTimeoutMs: number;
      pollMs: number;
    } => ({
      run: `t-${security}`,
      trust: { ca: p.caPem },
      arrivalTimeoutMs: 20_000,
      pollMs: 100,
    });

    it(`self-send delivers to the account itself and finds the message by Message-ID, over implicit TLS and over STARTTLS`, async () => {
      const host = credentialsDir(`self-${security}`, {
        "gmail-workspace/qa1.json": accountFile(gmail),
      });
      const route = resolveRoute("gmail-workspace", host, { profiles });
      assert.equal(route.kind, "self");
      const d = await deliverHosted(STORY, route, opts());
      assert.equal(d.arrival.state, "arrived");
      assert.ok(d.arrival.state === "arrived");
      assert.equal(d.arrival.role, "inbox");
      assert.equal(d.arrival.mailbox, "INBOX");
      assert.ok(
        d.latencyMs >= 0 && d.latencyMs < 20_000,
        `latency ${d.latencyMs}`,
      );
      assert.match(
        d.messageId,
        /^<t-[a-z]+\.[0-9a-f]{8}\.[0-9a-f]{12}@render-test\.example\.test>$/,
      );
      assert.match(d.subjectToken, /^\[es:t-[a-z]+:[0-9a-f]{8}\]$/);
      assert.equal(d.receiverCleanup, "imap");
      // Serialising the delivery carries no secret.
      leakFree(JSON.stringify(d), gmail.appPassword, ACCOUNT_PW);

      const got = await fetchCopy(p, gmail, "INBOX", d.messageId);
      assert.deepEqual(headerOf(got, "From"), [
        `"Acme Billing" <${gmail.address}>`,
      ]);
      assert.deepEqual(headerOf(got, "To"), [gmail.address]);
      assert.deepEqual(headerOf(got, "Message-ID"), [d.messageId]);
      assert.deepEqual(headerOf(got, "Subject"), [
        `${d.subjectToken} Your invoice is ready`,
      ]);
      assert.deepEqual(headerOf(got, "Cc"), []);
      assert.deepEqual(headerOf(got, "Bcc"), []);
      assert.deepEqual(headerOf(got, "Date"), [
        "Wed, 07 Oct 2026 10:00:00 +0000",
      ]);
      // Every body byte as rendered, the dot lines included.
      assert.equal(bodyOf(got), bodyOf(STORY));
      // The provider kept the sender's copy too.
      const c = await copies(p, gmail, d.messageId);
      assert.equal(c.INBOX, 1);
      assert.equal(c.Sent, 1);
      await removeHosted(d, opts());
    });

    it("removal deletes every copy: INBOX, Sent, Junk and All Mail through Trash", async () => {
      const host = credentialsDir(`remove-${security}`, {
        "gmail-workspace/qa1.json": accountFile(gmail),
      });
      const route = resolveRoute("gmail-workspace", host, { profiles });
      const d = await deliverHosted(STORY, route, opts());
      // A stray copy in Junk, and an unrelated message that must stay.
      const t = Buffer.from(STORY).toString("latin1");
      await p.file(
        gmail,
        Buffer.from(
          t.replace(
            "Message-ID: <story@acme.invalid>",
            `Message-ID: ${d.messageId}`,
          ),
          "latin1",
        ),
        "Junk",
      );
      await p.file(gmail, STORY, "INBOX");
      const before = await copies(p, gmail, d.messageId);
      assert.deepEqual(before, {
        INBOX: 1,
        Sent: 1,
        Junk: 1,
        "All Mail": 1,
        Trash: 0,
      });

      const r = await removeHosted(d, opts());
      assert.equal(r.left, null);
      const counts = Object.fromEntries(
        r.removed.map((x) => [x.mailbox, x.count]),
      );
      assert.deepEqual(counts, {
        INBOX: 1,
        Sent: 1,
        Junk: 1,
        "All Mail": 1,
        Trash: 4,
      });
      assert.deepEqual(await copies(p, gmail, d.messageId), {
        INBOX: 0,
        Sent: 0,
        Junk: 0,
        "All Mail": 0,
        Trash: 0,
      });
      // The other message is still there.
      assert.equal((await copies(p, gmail, "<story@acme.invalid>")).INBOX, 1);
    });

    it("a refused login reports a clear error and the password appears nowhere", async () => {
      const host = credentialsDir(`refused-${security}`, {
        "gmail-workspace/qa1.json": accountFile(gmail, WRONG_APP_PW),
      });
      const route = resolveRoute("gmail-workspace", host, { profiles });
      let err: unknown;
      try {
        await deliverHosted(STORY, route, opts());
      } catch (e) {
        err = e;
      }
      assert.ok(err instanceof MailProtocolError, String(err));
      assert.match(err.message, /^127\.0\.0\.1:\d+: AUTH PLAIN refused: 535\b/);
      leakFree(`${err.message}\n${err.stack ?? ""}`, WRONG_APP_PW, ACCOUNT_PW);

      // IMAP refuses it too, as clearly and as quietly.
      const s = await ImapSession.open(
        profiles["gmail-workspace"]!.imap!,
        { ca: p.caPem },
        [WRONG_APP_PW],
      );
      let imapErr: unknown;
      try {
        await s.login(gmail.address, WRONG_APP_PW);
      } catch (e) {
        imapErr = e;
      } finally {
        s.close();
      }
      assert.ok(imapErr instanceof MailProtocolError, String(imapErr));
      assert.match(imapErr.message, /LOGIN refused: NO/);
      leakFree(`${imapErr.message}\n${imapErr.stack ?? ""}`, WRONG_APP_PW);

      // The smoke command, as a person runs it: exit 1, the refusal on
      // stderr, no secret on either stream.
      const endpoints = join(scratch, `endpoints-${security}.json`);
      writeFileSync(endpoints, JSON.stringify(p.endpoints("gmail-workspace")));
      const ca = join(scratch, `ca-${security}.pem`);
      writeFileSync(ca, p.caPem);
      const cli = await runSmoke(
        [
          "gmail-workspace",
          "--endpoints",
          endpoints,
          "--ca",
          ca,
          "--timeout",
          "5",
        ],
        host.env.ISONIM_EMAIL_CREDENTIALS_DIR!,
      );
      assert.equal(cli.status, 1, cli.stdout + cli.stderr);
      assert.match(cli.stderr, /AUTH PLAIN refused: 535/);
      leakFree(cli.stdout + cli.stderr, WRONG_APP_PW, ACCOUNT_PW);
    });

    it("refuses a server whose certificate the trusted roots do not vouch for, before authenticating", async () => {
      const host = credentialsDir(`untrusted-${security}`, {
        "gmail-workspace/qa1.json": accountFile(gmail),
      });
      const route = resolveRoute("gmail-workspace", host, { profiles });
      const foreign = makeTestPki("another authority");
      // Refused by the submission server's handshake (TLS from the first
      // byte, or the STARTTLS upgrade), before anything is submitted.
      const smtp = profiles["gmail-workspace"]!.smtp!;
      const fromSubmission = `127.0.0.1:${smtp.port}: `;
      const acceptedBefore = (await p.accepted()).length;
      await assert.rejects(
        deliverHosted(STORY, route, {
          ...opts(),
          trust: { ca: foreign.caPem },
        }),
        (e: unknown) =>
          e instanceof MailProtocolError &&
          e.stage === "tls" &&
          e.message.startsWith(fromSubmission) &&
          /TLS failed: .*certificate/i.test(e.message),
      );
      // And with no test root at all (the system's roots only).
      await assert.rejects(
        deliverHosted(STORY, route, { ...opts(), trust: {} }),
        (e: unknown) =>
          e instanceof MailProtocolError &&
          e.stage === "tls" &&
          e.message.startsWith(fromSubmission),
      );
      assert.equal((await p.accepted()).length, acceptedBefore);
    });

    it("a message that never arrives fails after the bounded timeout, and one filed as junk is found in Junk", async () => {
      const host = credentialsDir(`timeout-${security}`, {
        "gmail-workspace/qa1.json": accountFile(gmail),
      });
      const route = resolveRoute("gmail-workspace", host, { profiles });
      p.filing.set(gmail.address, "withhold");
      const t0 = Date.now();
      await assert.rejects(
        deliverHosted(STORY, route, { ...opts(), arrivalTimeoutMs: 1500 }),
        (e: unknown) =>
          e instanceof DeliveryError &&
          /^no message with Message-ID <[^>]+> in INBOX or Junk of gmail-workspace\/qa1\.json within 1500 ms$/.test(
            e.message,
          ),
      );
      const waited = Date.now() - t0;
      assert.ok(waited >= 1500 && waited < 15_000, `waited ${waited} ms`);

      p.filing.set(gmail.address, "junk");
      const d = await deliverHosted(STORY, route, opts());
      p.filing.delete(gmail.address);
      assert.ok(d.arrival.state === "arrived");
      assert.equal(d.arrival.role, "junk");
      assert.equal(d.arrival.mailbox, "Junk");
      await removeHosted(d, opts());
      assert.deepEqual(await copies(p, gmail, d.messageId), {
        INBOX: 0,
        Sent: 0,
        Junk: 0,
        "All Mail": 0,
        Trash: 0,
      });
    });

    it("cross-send submits from the configured sender and leaves arrival to the webmail", async () => {
      const host = credentialsDir(`cross-${security}`, {
        "gmail-workspace/qa1.json": accountFile(gmail),
        // Outlook.com: no app password; it only receives.
        "outlook-com/qa1.json": accountFile(outlook, null),
      });
      const route = resolveRoute("outlook-com", host, { profiles });
      assert.equal(route.kind, "cross");
      assert.equal(route.sender.set, "gmail-workspace");
      assert.equal(route.receiver.set, "outlook-com");
      const d = await deliverHosted(STORY, route, opts());
      assert.equal(d.arrival.state, "unverified");
      assert.equal(d.receiverCleanup, "webmail");
      assert.equal(d.senderCopy?.role, "sent");
      // Submitted to the receiver's address, from the sender's.
      const got = await fetchCopy(p, outlook, "INBOX", d.messageId);
      assert.deepEqual(headerOf(got, "To"), [outlook.address]);
      assert.deepEqual(headerOf(got, "From"), [
        `"Acme Billing" <${gmail.address}>`,
      ]);

      const r = await removeHosted(d, opts());
      assert.match(r.left ?? "", /left for the webmail adapter/);
      assert.deepEqual(await copies(p, gmail, d.messageId), {
        INBOX: 0,
        Sent: 0,
        Junk: 0,
        "All Mail": 0,
        Trash: 0,
      });
      // The receiver's copy is the webmail's to delete.
      assert.equal((await copies(p, outlook, d.messageId)).INBOX, 1);

      // An explicit sender set overrides the default.
      assert.throws(
        () =>
          resolveRoute("outlook-com", host, {
            profiles,
            senderSet: "outlook-com",
          }),
        /outlook-com cannot send/,
      );
    });

    it("the delivery reads only app passwords and stops before connecting without one", async () => {
      const host = credentialsDir(`noapp-${security}`, {
        "gmail-workspace/qa1.json": accountFile(gmail, null),
      });
      const before = p.connections;
      assert.throws(
        () => resolveRoute("gmail-workspace", host, { profiles }),
        (e: unknown) =>
          e instanceof CredentialsUnavailable &&
          /^gmail-workspace\/qa1\.json has no app_password: /.test(e.message),
      );
      const endpoints = join(scratch, `endpoints-noapp-${security}.json`);
      writeFileSync(endpoints, JSON.stringify(p.endpoints("gmail-workspace")));
      const cli = await runSmoke(
        ["gmail-workspace", "--endpoints", endpoints],
        host.env.ISONIM_EMAIL_CREDENTIALS_DIR!,
      );
      assert.equal(cli.status, 3, cli.stdout + cli.stderr);
      assert.match(
        cli.stdout,
        /^PENDING: gmail-workspace\/qa1\.json has no app_password/,
      );
      assert.match(
        cli.stdout,
        /Nothing was sent and no server was contacted\./,
      );
      leakFree(cli.stdout + cli.stderr, ACCOUNT_PW);
      assert.equal(
        p.connections,
        before,
        "no connection to the submission server",
      );
    });
  });
}
