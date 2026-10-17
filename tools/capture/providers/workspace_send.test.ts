// tools/capture/providers/workspace_send.test.ts — delivery through a
// Workspace sender (the Gmail API), against local stand-ins for
// Google's token endpoint and the Gmail API.
//
// What is proven: the token request is a JWT bearer grant whose
// assertion, verified with the service account's public key, is RS256
// and carries iss (the service account), sub (the configured subject),
// scope (gmail.send, alone), aud (the token endpoint) and exp (an hour
// after iat); the send goes to users/{subject}/messages/send with that
// token, and its `raw` is exactly the submitted copy, base64url without
// padding, with the sender address as From, the QA account as To, the
// handle's Message-ID and the run token; a recipient outside
// allowed_recipients is refused before any request; a refused grant is
// reported naming the scope and the domain-wide delegation; and no
// error, stack or command output carries the key (a sentinel key id,
// each PEM line), the assertion or the token, even when the endpoints
// echo them. The smoke command sends a given message, announces the
// operator override, sends only to the QA accounts with it, and
// verifies the Sent copy with gmail.metadata.
//
// Test doubles (justification, per the repository's mock policy):
// Google's token endpoint and the Gmail API cannot be reached from a
// test, and a real call would send mail. They are played by one local
// HTTPS server (a per-test authority, test_pki.ts) that implements the
// two calls as documented: it verifies the assertion's signature and
// answers with a token, and it decodes `raw` and answers with an id.
// The clients, TLS verification, the credentials directory and the CLI
// are real.
// Run with:
//   node --test tools/capture/providers/workspace_send.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";
import { createVerify, generateKeyPairSync, type KeyObject } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:https";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  CredentialsUnavailable,
  loadHostedAccount,
} from "./hosted_delivery.ts";
import { CREDENTIALS_SCHEMA, type HostEnv } from "./requirements.ts";
import { makeTestPki } from "./test_pki.ts";
import {
  deliverWorkspace,
  GMAIL_SEND_SCOPE,
  loadWorkspaceSender,
  overrideSender,
  OVERRIDE_ENV,
  type WorkspaceEndpoints,
  WorkspaceSendError,
} from "./workspace_send.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const smokeCli = join(
  repoRoot,
  "tools",
  "capture",
  "email-workspace-send-smoke.ts",
);
const scratch = mkdtempSync(join(tmpdir(), "workspace-send-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

// Never to be printed: the key id, and the token the stub issues.
const KEY_ID = "kid-7c1e0f93-never-print";
const TOKEN = "tok-3a9d52e1-never-print";

const SA_EMAIL = "sender@project.iam.invalid";
const SUBJECT = "qa-sender@tenant.invalid";
const FROM = "tests-alias@tenant.invalid";
const QA = "qa1@receiver.invalid";
const OTHER = "someone-else@receiver.invalid";

const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 });
const PRIVATE_PEM = rsa.privateKey.export({
  type: "pkcs8",
  format: "pem",
}) as string;
const PEM_LINES = PRIVATE_PEM.split("\n").filter(
  (l) => l.length >= 16 && !l.startsWith("-----"),
);

const SA_KEY = {
  type: "service_account",
  project_id: "project",
  private_key_id: KEY_ID,
  private_key: PRIVATE_PEM,
  client_email: SA_EMAIL,
  client_id: "1234567890",
  // Not used: the harness picks the endpoint a signed assertion goes to.
  token_uri: "https://token-uri-from-the-file.invalid/token",
};

// A story-like message whose body base64-encodes to '+' and '/' (">>>"
// is "Pj4+", "???" is "Pz8/"), so base64 and base64url differ on it.
const STORY = Buffer.from(
  [
    'From: "Acme Billing" <billing@acme.invalid>',
    "To: someone@acme.invalid",
    "Cc: other@acme.invalid",
    "Subject: Your receipt",
    "Message-ID: <story@acme.invalid>",
    "Date: Sat, 17 Oct 2026 10:00:00 +0000",
    "MIME-Version: 1.0",
    "Content-Type: text/html; charset=us-ascii",
    "",
    "<p>>>>???</p>",
    ".a line that starts with a dot",
    "",
  ].join("\r\n"),
  "latin1",
);

function secretsIn(text: string): string[] {
  const found: string[] = [];
  if (text.includes(KEY_ID)) found.push("key id");
  if (text.includes(TOKEN)) found.push("token");
  for (const l of PEM_LINES) if (text.includes(l)) found.push("a PEM line");
  if (/eyJ[A-Za-z0-9_-]{10,}\.eyJ/.test(text)) found.push("an assertion");
  return found;
}

// ---------------------------------------------------------------------------
// The stand-in for Google
// ---------------------------------------------------------------------------

interface Recorded {
  path: string;
  method: string;
  headers: Record<string, string | string[] | undefined>;
  body: string;
}

type Mode = "ok" | "refuse-delegation" | "refuse-and-echo" | "send-error-echo";

class FakeGoogle {
  server!: Server;
  requests: Recorded[] = [];
  mode: Mode = "ok";
  claims: Record<string, unknown>[] = [];
  headers: Record<string, unknown>[] = [];
  signatureValid: boolean[] = [];
  sent: { path: string; auth: string; raw: string }[] = [];
  // Message-ID and From of each sent message, by API id.
  byId = new Map<string, { messageId: string; from: string }>();
  readonly pki = makeTestPki("workspace-send test CA");

  private readonly publicKey: KeyObject;
  constructor(publicKey: KeyObject) {
    this.publicKey = publicKey;
  }

  async start(): Promise<WorkspaceEndpoints> {
    this.server = createServer(
      { key: this.pki.keyPem, cert: this.pki.certChainPem },
      (req, res) => {
        const chunks: Buffer[] = [];
        req.on("data", (c: Buffer) => chunks.push(c));
        req.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          this.requests.push({
            path: req.url ?? "",
            method: req.method ?? "",
            headers: req.headers,
            body,
          });
          const reply = (status: number, o: unknown): void => {
            res.writeHead(status, { "content-type": "application/json" });
            res.end(JSON.stringify(o));
          };
          if (req.url === "/token") return this.token(body, reply);
          const m =
            /^\/gmail\/v1\/users\/([^/]+)\/messages(\/send|\/([^/?]+)\?.*)$/.exec(
              req.url ?? "",
            );
          if (m === null) return reply(404, { error: "not found" });
          const auth = String(req.headers.authorization ?? "");
          if (auth !== `Bearer ${TOKEN}`)
            return reply(401, { error: { status: "UNAUTHENTICATED" } });
          if (m[2] === "/send") {
            if (this.mode === "send-error-echo")
              return reply(400, {
                error: {
                  code: 400,
                  status: "INVALID_ARGUMENT",
                  message: `Invalid raw; you sent ${auth} with ${body.slice(0, 40)}`,
                },
              });
            const raw = (JSON.parse(body) as { raw: string }).raw;
            this.sent.push({ path: req.url ?? "", auth, raw });
            const id = `id${this.sent.length}`;
            const text = Buffer.from(raw, "base64url").toString("latin1");
            const h = (n: string): string =>
              new RegExp(`^${n}: (.*)$`, "mi").exec(text)?.[1]?.trim() ?? "";
            this.byId.set(id, { messageId: h("Message-ID"), from: h("From") });
            return reply(200, { id, threadId: `t${id}`, labelIds: ["SENT"] });
          }
          const got = this.byId.get(decodeURIComponent(m[3] ?? ""));
          if (got === undefined)
            return reply(404, { error: { status: "NOT_FOUND" } });
          return reply(200, {
            id: m[3],
            labelIds: ["SENT"],
            payload: {
              headers: [
                { name: "From", value: got.from },
                { name: "Message-ID", value: got.messageId },
              ],
            },
          });
        });
      },
    );
    await new Promise<void>((r) => this.server.listen(0, "127.0.0.1", r));
    const port = (this.server.address() as AddressInfo).port;
    return {
      tokenUrl: `https://localhost:${port}/token`,
      gmailBase: `https://localhost:${port}`,
    };
  }

  private token(body: string, reply: (s: number, o: unknown) => void): void {
    const form = new URLSearchParams(body);
    const assertion = form.get("assertion") ?? "";
    const [h, c, s] = assertion.split(".");
    if (
      form.get("grant_type") !==
        "urn:ietf:params:oauth:grant-type:jwt-bearer" ||
      s === undefined
    )
      return reply(400, { error: "invalid_request" });
    this.headers.push(
      JSON.parse(Buffer.from(h!, "base64url").toString("utf8")),
    );
    this.claims.push(JSON.parse(Buffer.from(c!, "base64url").toString("utf8")));
    this.signatureValid.push(
      createVerify("RSA-SHA256")
        .update(`${h}.${c}`)
        .verify(this.publicKey, Buffer.from(s, "base64url")),
    );
    if (this.mode === "refuse-delegation")
      return reply(401, {
        error: "unauthorized_client",
        error_description:
          "Client is unauthorized to retrieve access tokens using this method, or client not authorized for any of the scopes requested.",
      });
    if (this.mode === "refuse-and-echo")
      return reply(400, {
        error: "invalid_grant",
        error_description: `bad assertion ${assertion} for key ${KEY_ID} ${PEM_LINES[2]}`,
      });
    return reply(200, {
      access_token: TOKEN,
      expires_in: 3599,
      token_type: "Bearer",
    });
  }

  async stop(): Promise<void> {
    await new Promise<void>((r) => this.server.close(() => r()));
  }
}

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

function writePrivate(path: string, body: unknown): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, JSON.stringify(body), { mode: 0o600 });
  chmodSync(path, 0o600);
}

function credentialsDir(
  name: string,
  opts: { sender?: boolean; allowed?: string[] } = {},
): { dir: string; host: HostEnv } {
  const dir = join(scratch, name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  if (opts.sender !== false)
    writePrivate(join(dir, "workspace-sender", "tests.json"), {
      schema: CREDENTIALS_SCHEMA,
      key: SA_KEY,
      subject: SUBJECT,
      from: FROM,
      allowed_recipients: opts.allowed ?? [QA],
    });
  writePrivate(join(dir, "gmail-workspace", "qa1.json"), {
    schema: CREDENTIALS_SCHEMA,
    address: QA,
    password: "acct-password-never-used",
  });
  writePrivate(join(dir, "yahoo", "qa1.json"), {
    schema: CREDENTIALS_SCHEMA,
    address: OTHER,
    password: "acct-password-never-used",
  });
  for (const d of ["workspace-sender", "gmail-workspace", "yahoo"])
    try {
      chmodSync(join(dir, d), 0o700);
    } catch {
      // absent
    }
  return {
    dir,
    host: {
      env: { ISONIM_EMAIL_CREDENTIALS_DIR: dir, HOME: scratch },
      platform: "linux",
    },
  };
}

function headerOf(raw: Buffer, name: string): string[] {
  const t = raw.toString("latin1");
  const head = t.slice(0, t.indexOf("\r\n\r\n")).replace(/\r\n[ \t]/g, " ");
  return head
    .split("\r\n")
    .filter((l) => l.toLowerCase().startsWith(`${name.toLowerCase()}:`))
    .map((l) => l.slice(name.length + 1).trim());
}

interface CliRun {
  status: number;
  out: string;
}

function runCli(args: string[], env: Record<string, string>): Promise<CliRun> {
  return new Promise((r) => {
    const p = spawn(process.execPath, [smokeCli, ...args], {
      env: { ...process.env, ...env },
    });
    let out = "";
    p.stdout.on("data", (c: Buffer) => (out += c.toString()));
    p.stderr.on("data", (c: Buffer) => (out += c.toString()));
    p.on("close", (code) => r({ status: code ?? -1, out }));
  });
}

// ---------------------------------------------------------------------------

describe("Workspace send through the Gmail API", () => {
  const google = new FakeGoogle(rsa.publicKey);
  let endpoints: WorkspaceEndpoints;
  let trust: { ca: string };
  before(async () => {
    endpoints = await google.start();
    trust = { ca: google.pki.caPem };
  });
  after(() => google.stop());

  const options = (run = "run1") => ({ run, endpoints, trust });

  it("mints a delegated token: a JWT bearer grant with iss, sub, scope, aud and exp, signed RS256 with the key", async () => {
    google.mode = "ok";
    const { host } = credentialsDir("claims");
    const sender = loadWorkspaceSender(host);
    const receiver = loadHostedAccount("gmail-workspace", host, {
      needsAppPassword: false,
    });
    const before = Math.floor(Date.now() / 1000);
    await deliverWorkspace(new Uint8Array(STORY), sender, receiver, options());
    const after = Math.floor(Date.now() / 1000);
    assert.equal(google.claims.length, 1);
    const claims = google.claims[0]!;
    assert.deepEqual(google.headers[0], {
      alg: "RS256",
      typ: "JWT",
      kid: KEY_ID,
    });
    assert.equal(google.signatureValid[0], true, "signed with the key");
    assert.equal(claims.iss, SA_EMAIL);
    assert.equal(claims.sub, SUBJECT);
    assert.equal(claims.scope, GMAIL_SEND_SCOPE);
    assert.equal(
      claims.aud,
      endpoints.tokenUrl,
      "not the key file's token_uri",
    );
    const iat = claims.iat as number;
    assert.ok(iat >= before && iat <= after, `iat ${iat}`);
    assert.equal(claims.exp, iat + 3600);
    assert.deepEqual(Object.keys(claims).sort(), [
      "aud",
      "exp",
      "iat",
      "iss",
      "scope",
      "sub",
    ]);
    // The token is reused for the next send.
    await deliverWorkspace(new Uint8Array(STORY), sender, receiver, options());
    assert.equal(google.claims.length, 1, "one grant for two sends");
  });

  it("sends exactly the submitted copy, base64url, to users/{subject}/messages/send", async () => {
    google.mode = "ok";
    google.sent = [];
    const { host } = credentialsDir("raw");
    const sender = loadWorkspaceSender(host);
    const receiver = loadHostedAccount("gmail-workspace", host, {
      needsAppPassword: false,
    });
    const d = await deliverWorkspace(
      new Uint8Array(STORY),
      sender,
      receiver,
      options("run-raw"),
    );
    assert.equal(google.sent.length, 1);
    const sent = google.sent[0]!;
    assert.equal(
      sent.path,
      `/gmail/v1/users/${encodeURIComponent(SUBJECT)}/messages/send`,
    );
    assert.equal(sent.auth, `Bearer ${TOKEN}`);
    assert.match(sent.raw, /^[A-Za-z0-9_-]+$/, "base64url, no padding");
    const raw = Buffer.from(sent.raw, "base64url");
    assert.equal(d.bytes, raw.length);
    const { createHash } = await import("node:crypto");
    assert.equal(
      createHash("sha256").update(raw).digest("hex"),
      d.submittedSha256,
    );
    assert.deepEqual(headerOf(raw, "From"), [`"Acme Billing" <${FROM}>`]);
    assert.deepEqual(headerOf(raw, "To"), [QA]);
    assert.deepEqual(headerOf(raw, "Cc"), []);
    assert.deepEqual(headerOf(raw, "Message-ID"), [d.messageId]);
    assert.match(
      d.messageId,
      /^<run-raw\.[0-9a-f]{8}\.[0-9a-f]{12}@render-test\.tenant\.invalid>$/,
    );
    assert.deepEqual(headerOf(raw, "Subject"), [
      `${d.subjectToken} Your receipt`,
    ]);
    const text = raw.toString("latin1");
    const body = STORY.toString("latin1");
    assert.equal(
      text.slice(text.indexOf("\r\n\r\n")),
      body.slice(body.indexOf("\r\n\r\n")),
      "every body byte kept",
    );
    assert.equal(d.api.id, "id1");
    assert.equal(d.api.threadId, "tid1");
    assert.equal(d.arrival.state, "unverified");
    assert.equal(d.receiverCleanup, "webmail");
    assert.equal(JSON.stringify(d).includes(PEM_LINES[1]!), false);
  });

  it("refuses a recipient outside allowed_recipients before anything connects", async () => {
    google.mode = "ok";
    const n = google.requests.length;
    const { host } = credentialsDir("allow");
    const sender = loadWorkspaceSender(host);
    const outsider = loadHostedAccount("yahoo", host, {
      needsAppPassword: false,
    });
    await assert.rejects(
      deliverWorkspace(new Uint8Array(STORY), sender, outsider, options()),
      (err: Error) => {
        assert.ok(err instanceof WorkspaceSendError);
        assert.match(
          err.message,
          /yahoo\/qa1\.json is not among the allowed recipients of workspace-sender\/tests\.json; nothing was sent/,
        );
        assert.equal(
          err.message.includes(OTHER),
          false,
          "names the file, not the address",
        );
        return true;
      },
    );
    assert.equal(google.requests.length, n, "no request was made");
    // Matching is case-insensitive, so an allowed address in another case is sent to.
    const upper = credentialsDir("allow-case", { allowed: [QA.toUpperCase()] });
    await deliverWorkspace(
      new Uint8Array(STORY),
      loadWorkspaceSender(upper.host),
      loadHostedAccount("gmail-workspace", upper.host, {
        needsAppPassword: false,
      }),
      options(),
    );
    assert.ok(google.requests.length > n);
  });

  it("a refused delegation names the scope and the domain-wide delegation to fix", async () => {
    google.mode = "refuse-delegation";
    const { host } = credentialsDir("refused");
    const sender = loadWorkspaceSender(host);
    const receiver = loadHostedAccount("gmail-workspace", host, {
      needsAppPassword: false,
    });
    await assert.rejects(
      deliverWorkspace(new Uint8Array(STORY), sender, receiver, options()),
      (err: Error) => {
        assert.ok(err instanceof WorkspaceSendError);
        assert.match(err.message, /^token: HTTP 401 unauthorized_client/);
        assert.match(
          err.message,
          /not authorised for https:\/\/www\.googleapis\.com\/auth\/gmail\.send/,
        );
        assert.match(err.message, /Domain-wide delegation/);
        assert.match(err.message, /client id \(in the key\)/);
        return true;
      },
    );
    google.mode = "ok";
  });

  it("never carries the key, the assertion or the token in an error, a stack or the command's output", async () => {
    const { dir, host } = credentialsDir("redact");
    const sender = loadWorkspaceSender(host);
    const receiver = loadHostedAccount("gmail-workspace", host, {
      needsAppPassword: false,
    });
    // Positive control: the sender holds the secrets, and the stand-in
    // echoes them.
    assert.ok(sender.serviceAccount.privateKeyPem.includes(PEM_LINES[2]!));
    assert.equal(
      JSON.stringify(sender).includes(KEY_ID),
      false,
      "the key is not enumerable",
    );
    const errors: Error[] = [];
    google.mode = "refuse-and-echo";
    await deliverWorkspace(
      new Uint8Array(STORY),
      sender,
      receiver,
      options(),
    ).catch((e: Error) => errors.push(e));
    google.mode = "send-error-echo";
    const fresh = loadWorkspaceSender(host);
    await deliverWorkspace(
      new Uint8Array(STORY),
      fresh,
      receiver,
      options(),
    ).catch((e: Error) => errors.push(e));
    assert.equal(errors.length, 2);
    assert.match(
      errors[0]!.message,
      /^token: HTTP 400 invalid_grant \(bad assertion \[redacted\] for key \[redacted\] \[redacted\]\)/,
    );
    assert.match(
      errors[1]!.message,
      /^send: HTTP 400 INVALID_ARGUMENT \(Invalid raw; you sent Bearer \[redacted\]/,
    );
    for (const e of errors) {
      assert.deepEqual(secretsIn(e.message), [], e.message);
      assert.deepEqual(secretsIn(e.stack ?? ""), [], e.stack);
    }
    // The command, with the same stand-in.
    const ep = join(dir, "..", "redact-endpoints.json");
    writeFileSync(ep, JSON.stringify(endpoints));
    const ca = join(dir, "..", "redact-ca.pem");
    writeFileSync(ca, google.pki.caPem);
    const msg = join(dir, "..", "redact-story.eml");
    writeFileSync(msg, STORY);
    for (const mode of ["refuse-and-echo", "send-error-echo"] as const) {
      google.mode = mode;
      const r = await runCli(
        [
          "gmail-workspace",
          "--dir",
          dir,
          "--endpoints",
          ep,
          "--ca",
          ca,
          "--mime",
          msg,
        ],
        {},
      );
      assert.equal(r.status, 1, r.out);
      assert.match(r.out, /\[redacted\]/);
      assert.deepEqual(secretsIn(r.out), [], r.out);
    }
    google.mode = "ok";
  });

  it("the smoke command sends a message, announces the operator override, keeps it to the QA accounts, and verifies the Sent copy", async () => {
    google.mode = "ok";
    const { dir } = credentialsDir("cli");
    const ep = join(scratch, "cli-endpoints.json");
    writeFileSync(ep, JSON.stringify(endpoints));
    const ca = join(scratch, "cli-ca.pem");
    writeFileSync(ca, google.pki.caPem);
    const msg = join(scratch, "cli-story.eml");
    writeFileSync(msg, STORY);
    const common = ["--dir", dir, "--endpoints", ep, "--ca", ca, "--mime", msg];

    const r = await runCli(["gmail-workspace", ...common, "--verify-sent"], {});
    assert.equal(r.status, 0, r.out);
    assert.match(
      r.out,
      /workspace send: workspace-sender\/tests\.json -> gmail-workspace\/qa1\.json \(Gmail\)/,
    );
    assert.match(r.out, /\n  api id id\d+\n/);
    assert.match(
      r.out,
      /Message-ID <smoke-[a-z0-9]+\.[0-9a-f]{8}\.[0-9a-f]{12}@render-test\.tenant\.invalid>/,
    );
    assert.match(
      r.out,
      /sent copy: labels SENT; Message-ID as sent; From the sender address/,
    );
    assert.doesNotMatch(r.out, /OPERATOR OVERRIDE/);
    for (const a of [QA, SUBJECT, SA_EMAIL])
      assert.equal(r.out.includes(a), false, a);

    // The override: announced, used instead of the directory's sender,
    // and limited to the directory's QA accounts (both sets here).
    const keyFile = join(scratch, "override-key.json");
    writeFileSync(keyFile, JSON.stringify(SA_KEY), { mode: 0o600 });
    const env = {
      [OVERRIDE_ENV.key]: keyFile,
      [OVERRIDE_ENV.subject]: "operator@tenant.invalid",
      [OVERRIDE_ENV.from]: FROM,
    };
    const o = await runCli(["yahoo", ...common], env);
    assert.equal(o.status, 0, o.out);
    assert.match(o.out, /^OPERATOR OVERRIDE: /);
    assert.match(
      o.out,
      /workspace send: operator override \(ISONIM_EMAIL_WORKSPACE_SENDER_OVERRIDE_KEY\) -> yahoo\/qa1\.json/,
    );
    assert.equal(google.claims.at(-1)!.sub, "operator@tenant.invalid");
    const over = overrideSender({
      env: { ISONIM_EMAIL_CREDENTIALS_DIR: dir, ...env },
      platform: "linux",
    });
    assert.deepEqual([...over!.allowedRecipients].sort(), [QA, OTHER].sort());
    // Without QA accounts, the override sends nowhere.
    const empty = join(scratch, "empty-dir");
    mkdirSync(empty, { mode: 0o700 });
    const e = await runCli(["yahoo", "--dir", empty, "--mime", msg], env);
    assert.equal(e.status, 3, e.out);
    assert.match(e.out, /PENDING: .*has none/);

    // No sender at all: pending, nothing contacted.
    const n = google.requests.length;
    const none = credentialsDir("cli-none", { sender: false });
    const p = await runCli(
      [
        "gmail-workspace",
        "--dir",
        none.dir,
        "--endpoints",
        ep,
        "--ca",
        ca,
        "--mime",
        msg,
      ],
      {},
    );
    assert.equal(p.status, 3, p.out);
    assert.match(p.out, /PENDING: no sender file for workspace-sender/);
    assert.equal(google.requests.length, n);
  });

  it("refuses an incomplete sender file by name and key, before anything connects", () => {
    const { dir, host } = credentialsDir("bad-sender");
    writePrivate(join(dir, "workspace-sender", "tests.json"), {
      schema: CREDENTIALS_SCHEMA,
      key: { ...SA_KEY, private_key: `${PEM_LINES[3]}` },
      subject: SUBJECT,
      from: FROM,
      allowed_recipients: [QA],
    });
    assert.throws(
      () => loadWorkspaceSender(host),
      (err: Error) => {
        assert.ok(err instanceof CredentialsUnavailable);
        assert.equal(
          err.message,
          "workspace-sender/tests.json: key's private_key is not a PEM private key",
        );
        return true;
      },
    );
    writePrivate(join(dir, "workspace-sender", "tests.json"), {
      schema: CREDENTIALS_SCHEMA,
      key: SA_KEY,
      subject: SUBJECT,
      from: FROM,
      allowed_recipients: [],
    });
    assert.throws(
      () => loadWorkspaceSender(host),
      /allowed_recipients must be a non-empty list of addresses/,
    );
  });
});
