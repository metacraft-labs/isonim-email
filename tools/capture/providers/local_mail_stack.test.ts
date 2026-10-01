// tools/capture/providers/local_mail_stack.test.ts — the shared local
// mail stack real mail clients capture from: Dovecot run as the user
// (the `imap` service) and the story images over loopback HTTP (the
// `assets` service), started by the capture harness.
//
// Everything that is under test is real: the harness lifecycle
// (assessProviders + executePlan with the registered services), a real
// Dovecot from the dev shell, real `doveadm save` injection, the real
// story MIME built by the library's story driver, a real IMAP exchange
// over TCP (a few lines of protocol in this file, not a library), real
// HTTP fetches, and Python's `email` package as the independent MIME
// decoder.
//
// Test double, justified: the provider that declares the services is a
// minimal CaptureProvider written here (MailStackProbe). The providers
// that will use these services (self-hosted webmail, desktop clients)
// do not exist yet, and the harness only starts a service for a
// provider that declares it. The probe does what such a provider does
// with the services (a fresh account per capture, injection, reading
// the message back over IMAP, loading the story images) and records
// what it saw; it returns placeholder PNG bytes.
//
// Needs the story driver (`just email-shots-build`, which `just test`
// runs first) and the dev shell (dovecot, python3). Run with:
//   node --test tools/capture/providers/local_mail_stack.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { connect, type Socket } from "node:net";
import { networkInterfaces, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  assessProviders,
  candidateProviders,
  executePlan,
  type Finished,
  type MatrixSpec,
  messageMap,
  routeRequests,
} from "./harness.ts";
import { assetsHandle } from "./assets_service.ts";
import { imapHandle, MAIL_STATE_ROOT } from "./imap_service.ts";
import { registeredServices } from "./services.ts";
import type {
  AssetsHandle,
  CaptureProvider,
  CaptureRequest,
  CaptureResult,
  ClientDescriptor,
  Delivery,
  Emulation,
  ImapAccount,
  ImapHandle,
  ProviderHealth,
  Requirement,
  SessionCtx,
  Sha256,
  StoryMessage,
} from "./types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const driver = join(repoRoot, "build", "capture", "build-stories");
const assetsDir = join(repoRoot, "tests", "stories", "assets");
const scratch = mkdtempSync(join(tmpdir(), "local-mail-stack-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

function sha256(b: Uint8Array): string {
  return createHash("sha256").update(b).digest("hex");
}

// --- A minimal IMAP client: one connection, tagged commands. -------

class Imap {
  private buf = Buffer.alloc(0);
  private waiters: (() => void)[] = [];
  private tag = 0;
  private readonly sock: Socket;
  private constructor(sock: Socket) {
    this.sock = sock;
    sock.on("data", (d: Buffer) => {
      this.buf = Buffer.concat([this.buf, d]);
      for (const w of this.waiters.splice(0)) w();
    });
  }
  static async open(host: string, port: number): Promise<Imap> {
    const sock = await new Promise<Socket>((ok, fail) => {
      const s = connect({ host, port }, () => ok(s));
      s.once("error", fail);
    });
    const c = new Imap(sock);
    const greeting = await c.until(() => c.buf.indexOf("\r\n"));
    assert.match(greeting, /^\* OK/, "IMAP greeting");
    return c;
  }
  // Waits until find() gives an end offset; returns and consumes the
  // text up to it.
  private async until(find: () => number): Promise<string> {
    const deadline = Date.now() + 10000;
    for (;;) {
      const end = find();
      if (end >= 0) {
        const text = this.buf.subarray(0, end + 2).toString("latin1");
        this.buf = this.buf.subarray(end + 2);
        return text;
      }
      if (Date.now() > deadline) throw new Error("IMAP: no response in 10 s");
      await new Promise<void>((r) => {
        this.waiters.push(r);
        setTimeout(r, 200);
      });
    }
  }
  // Sends one command; resolves with everything up to and including
  // its tagged status line.
  async command(cmd: string): Promise<{ status: string; text: string }> {
    const t = `a${++this.tag}`;
    this.sock.write(`${t} ${cmd}\r\n`);
    const text = await this.until(() => {
      const s = this.buf.toString("latin1");
      const m = new RegExp(`(^|\\r\\n)${t} (OK|NO|BAD)[^\\r]*\\r\\n`).exec(s);
      return m === null ? -1 : m.index + m[0].length - 2;
    });
    const status = new RegExp(`${t} (OK|NO|BAD)`).exec(text)?.[1] ?? "?";
    return { status, text };
  }
  close(): void {
    this.sock.destroy();
  }
}

// Logs in, selects INBOX and fetches every message's full bytes.
async function readMailbox(
  a: ImapAccount,
  password = a.password,
): Promise<{ login: string; exists: number; messages: Buffer[] }> {
  const c = await Imap.open(a.host, a.port);
  try {
    const login = await c.command(`LOGIN "${a.user}" "${password}"`);
    if (login.status !== "OK")
      return { login: login.status, exists: 0, messages: [] };
    const sel = await c.command("SELECT INBOX");
    assert.equal(sel.status, "OK", sel.text);
    const exists = Number(/\* (\d+) EXISTS/.exec(sel.text)?.[1] ?? "-1");
    const messages: Buffer[] = [];
    if (exists > 0) {
      const f = await c.command("FETCH 1:* (BODY.PEEK[])");
      assert.equal(f.status, "OK", f.text.slice(0, 200));
      const raw = Buffer.from(f.text, "latin1");
      const re = /BODY\[\] \{(\d+)\}\r\n/g;
      for (const m of f.text.matchAll(re)) {
        const start = Buffer.byteLength(
          f.text.slice(0, m.index + m[0].length),
          "latin1",
        );
        messages.push(raw.subarray(start, start + Number(m[1])));
      }
    }
    await c.command("LOGOUT");
    return { login: "OK", exists, messages };
  } finally {
    c.close();
  }
}

// Connects to host:port; resolves "open" or the error code.
function connectProbe(host: string, port: number): Promise<string> {
  return new Promise((ok) => {
    const s = connect({ host, port });
    s.setTimeout(2000, () => {
      s.destroy();
      ok("timeout");
    });
    s.once("connect", () => {
      s.destroy();
      ok("open");
    });
    s.once("error", (e: NodeJS.ErrnoException) => ok(e.code ?? "error"));
  });
}

// The decoded text/html part, by Python's email package.
function pythonHtml(mime: Uint8Array): string {
  const r = spawnSync(
    "python3",
    [
      "-c",
      [
        "import sys, email, email.policy",
        "m = email.message_from_bytes(sys.stdin.buffer.read(), policy=email.policy.default)",
        "sys.stdout.write(m.get_body(preferencelist=('html',)).get_content())",
      ].join("\n"),
    ],
    { input: mime, encoding: "utf8" },
  );
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}

// The HTML a client must see in the injected copy: the story HTML with
// the asset origin replaced where it loads a resource (the value of a
// src or background attribute, each srcset candidate, a CSS url()
// argument) and nowhere else, so links and visible text keep the
// fixture origin. Written with regular expressions here, independently
// of the rewriter's own scanner.
function resourcesRewritten(html: string, from: string, to: string): string {
  const o = from.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return html
    .replace(
      new RegExp(`(\\s(?:src|background)\\s*=\\s*["']?\\s*)${o}`, "gi"),
      `$1${to}`,
    )
    .replace(
      /(\ssrcset\s*=\s*)(["'])([^"']*)\2/gi,
      (_m, attr: string, q: string, v: string) =>
        attr +
        q +
        v.replace(new RegExp(`(^|,)(\\s*)${o}`, "g"), `$1$2${to}`) +
        q,
    )
    .replace(new RegExp(`(url\\(\\s*["']?\\s*)${o}`, "gi"), `$1${to}`);
}

// Every href value, in document order.
function hrefs(html: string): string[] {
  return [...html.matchAll(/\shref\s*=\s*"([^"]*)"/gi)].map((m) => m[1]!);
}

// --- The probe provider. ------------------------------------------

interface Seen {
  request: CaptureRequest;
  delivery: Delivery;
  stateDirDuringRun: boolean;
  passwdMode: number;
  mailbox: { login: string; exists: number; messages: Buffer[] };
  // LOGIN with a wrong password, and with the previous capture's user
  // and this capture's password: both must be refused.
  wrongPassword: string;
  otherUser: string | null;
  images: { url: string; status: number; bytes: Buffer }[];
}

class MailStackProbe implements CaptureProvider {
  readonly id = "mail-stack-probe";
  readonly backend = "probe";
  readonly version = "1";
  readonly adapterVersion = 1;
  readonly via = "inject";
  readonly seen: Seen[] = [];
  imap: ImapHandle | null = null;
  assets: AssetsHandle | null = null;
  private readonly useAssets: boolean;
  constructor(useAssets: boolean) {
    this.useAssets = useAssets;
  }
  clients(): ClientDescriptor[] {
    return [
      {
        clientId: "imap-probe",
        family: "verification",
        engine: "unknown",
        build: async () => "1",
        viewports: "any",
        schemes: ["light"],
        imagesOff: true,
        approximation: false,
      },
    ];
  }
  requirements(): Requirement[] {
    return [
      { kind: "service", name: "imap", why: "opens the injected message" },
      { kind: "service", name: "assets", why: "loads the story images" },
    ];
  }
  async health(): Promise<ProviderHealth> {
    return { state: "ok" };
  }
  async prepare(ctx: SessionCtx): Promise<void> {
    this.imap = imapHandle(ctx.services.imap);
    this.assets = assetsHandle(ctx.services.assets);
  }
  emulation(_req: CaptureRequest): Emulation {
    return { transformVersion: "", detail: null };
  }
  async *capture(
    batch: CaptureRequest[],
    messages: Map<Sha256, StoryMessage>,
    _ctx: SessionCtx,
  ): AsyncIterable<CaptureResult> {
    const imap = this.imap!;
    const assets = this.assets!;
    for (const request of batch) {
      const msg = messages.get(request.mimeSha256)!;
      const delivery = await imap.mailboxFor(
        msg.mime,
        this.useAssets ? { assets } : {},
      );
      const stateDir = String(imap.detail.stateDir);
      const mailbox = await readMailbox(delivery.account);
      const wrongPassword = (
        await readMailbox(delivery.account, "not-the-password")
      ).login;
      const previous = this.seen.at(-1)?.delivery.account;
      const otherUser =
        previous === undefined
          ? null
          : (
              await readMailbox(
                { ...delivery.account, user: previous.user },
                // Not carried by the spread (non-enumerable): passed
                // explicitly.
                delivery.account.password,
              )
            ).login;
      const images: Seen["images"] = [];
      for (const m of mailbox.messages)
        for (const [, url] of pythonHtml(m).matchAll(
          /<img [^>]*src="([^"]+)"/g,
        ))
          if (url !== undefined && url.startsWith(assets.baseUrl)) {
            const res = await fetch(url);
            images.push({
              url,
              status: res.status,
              bytes: Buffer.from(await res.arrayBuffer()),
            });
          }
      this.seen.push({
        request,
        delivery,
        stateDirDuringRun: existsSync(join(stateDir, "mail")),
        passwdMode:
          statSync(join(stateDir, "passwd.d", delivery.account.user)).mode &
          0o777,
        mailbox,
        wrongPassword,
        otherUser,
        images,
      });
      yield {
        request,
        status: "done",
        png: Buffer.from(`PNG:${request.id}`),
        provenance: {
          asset_rewrite:
            delivery.assetRewrite === null
              ? null
              : {
                  ...delivery.assetRewrite,
                  injected_sha256: delivery.injectedSha256,
                },
        },
      };
    }
  }
  async dispose(): Promise<void> {}
}

// --- Story MIME from the real driver. ------------------------------

let stories: StoryMessage[] = [];
before(() => {
  assert.ok(
    existsSync(driver),
    `${driver} missing: run \`just email-shots-build\` first`,
  );
  const out = join(scratch, "stories");
  const r = spawnSync(driver, [out, "receipt", "alert"], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  const manifest = JSON.parse(
    readFileSync(join(out, "manifest.json"), "utf8"),
  ) as { stories: { story: string; eml: string; html: string }[] };
  stories = manifest.stories.map((m) => ({
    story: m.story,
    mime: readFileSync(join(out, m.eml)),
    html: readFileSync(join(out, m.html), "utf8"),
  }));
});

async function runProbe(
  probe: MailStackProbe,
  run: string,
): Promise<{ rows: Finished[]; imap: ImapHandle; assets: AssetsHandle }> {
  const messages = messageMap(stories);
  const spec: MatrixSpec = {
    stories: stories.map((s) => ({
      story: s.story,
      mimeSha256: sha256(s.mime),
    })),
    families: ["verification"],
    clients: null,
    backends: null,
    viewports: [{ name: "desktop", width: 800, dpr: 1 }],
    schemes: ["light"],
    images: ["on"],
  };
  const runDir = join(scratch, run);
  const { availability, services } = await assessProviders(
    candidateProviders([probe], spec),
    { run, runDir },
    registeredServices(),
  );
  if (availability.get(probe.id)?.state !== "ok") {
    // Nothing will run the plan, so stop what did start (an open
    // server would keep the test process alive).
    await services.stopAll();
    assert.deepEqual(availability.get(probe.id), { state: "ok" });
  }
  const rows: Finished[] = [];
  await executePlan(
    [probe],
    availability,
    routeRequests([probe], availability, spec),
    messages,
    {
      run,
      session: null,
      runDir,
      library: { commit: "c", dirty: false, tree_hash: "t" },
      cacheRoot: join(runDir, ".cache"),
      noCache: true,
      assert: false,
      cold: false,
      services,
    },
    (f) => rows.push(f),
  );
  return { rows, imap: probe.imap!, assets: probe.assets! };
}

describe("local mail stack", () => {
  it("a harness-started Dovecot accepts an injected story into a fresh per-capture user and serves it over IMAP on loopback, with all state under build/ removed at teardown", async (t) => {
    const run = `t9-${process.pid}-${Date.now()}`;
    const probe = new MailStackProbe(true);
    const { rows, imap } = await runProbe(probe, run);
    const stateDir = join(MAIL_STATE_ROOT, run);
    assert.deepEqual(
      rows.map((r) => r.entry.status),
      ["done", "done"],
      JSON.stringify(rows.map((r) => r.line)),
    );
    assert.equal(probe.seen.length, 2);
    // Started by the harness: loopback, plain IMAP, Dovecot.
    assert.match(imap.endpoint, /^imap:\/\/127\.0\.0\.1:\d+$/);
    assert.equal(imap.host, "127.0.0.1");
    assert.equal(imap.tls, "none");
    assert.match(String(imap.detail.server), /^dovecot 2\.\d+\.\d+$/);
    assert.equal(imap.detail.stateDir, stateDir);
    assert.ok(
      stateDir.startsWith(join(repoRoot, "build") + "/"),
      "state under build/",
    );
    const users = new Set<string>();
    for (const s of probe.seen) {
      // A fresh user per capture, whose INBOX holds exactly the one
      // message, byte for byte what was injected.
      assert.ok(!users.has(s.delivery.account.user));
      users.add(s.delivery.account.user);
      assert.equal(s.mailbox.login, "OK");
      assert.equal(s.mailbox.exists, 1, s.request.story);
      assert.equal(s.mailbox.messages.length, 1);
      assert.equal(sha256(s.mailbox.messages[0]!), s.delivery.injectedSha256);
      assert.equal(s.delivery.account.port, imap.port);
      assert.ok(s.stateDirDuringRun, "mail store under build/ during the run");
      assert.equal(s.passwdMode, 0o600);
      t.diagnostic(
        `${s.request.story}: account ${s.delivery.timingMs.account.toFixed(1)} ms, inject ${s.delivery.timingMs.inject.toFixed(1)} ms`,
      );
    }
    const start = imap.detail.startMs as { configMs: number; listenMs: number };
    t.diagnostic(
      `dovecot start: config ${start.configMs.toFixed(1)} ms, to listening ${start.listenMs.toFixed(1)} ms`,
    );
    // A wrong password is refused, and one user's password does not
    // open another's mailbox.
    for (const s of probe.seen) assert.equal(s.wrongPassword, "NO");
    assert.equal(probe.seen[0]!.otherUser, null);
    assert.equal(probe.seen[1]!.otherUser, "NO");
    // Teardown: the service is gone with all of its state.
    assert.equal(existsSync(stateDir), false, `${stateDir} removed`);
    assert.equal(
      existsSync(String(imap.detail.socketDir)),
      false,
      "socket directory removed",
    );
    assert.notEqual(await connectProbe("127.0.0.1", imap.port), "open");
  });

  it("real clients load the story images from the assets service through the rewritten injected copy", async () => {
    const run = `t9a-${process.pid}-${Date.now()}`;
    const probe = new MailStackProbe(true);
    const { rows, assets } = await runProbe(probe, run);
    assert.deepEqual(
      rows.map((r) => r.entry.status),
      ["done", "done"],
    );
    for (const s of probe.seen) {
      const original = stories.find((m) => m.story === s.request.story)!;
      const rw = s.delivery.assetRewrite;
      assert.ok(rw !== null);
      assert.equal(rw.from, "https://x.test/");
      assert.equal(rw.to, assets.baseUrl);
      assert.ok(rw.count >= 1, `${s.request.story}: ${rw.count} rewrites`);
      // The canonical MIME is untouched (the cache key's mime_sha256);
      // the injected copy differs from it.
      assert.equal(s.request.mimeSha256, sha256(original.mime));
      assert.notEqual(s.delivery.injectedSha256, s.request.mimeSha256);
      // Decoded by an independent MIME implementation, the injected
      // HTML is the story's HTML with the asset origin replaced in its
      // resource-loading contexts only.
      const fetched = s.mailbox.messages[0]!;
      const injected = pythonHtml(fetched);
      const story = pythonHtml(original.mime);
      assert.equal(injected, resourcesRewritten(story, rw.from, rw.to));
      // Links are kept: every href is the story's own, fixture origin
      // included.
      assert.deepEqual(hrefs(injected), hrefs(story));
      // Every story image loads over real HTTP, with the fixture's
      // bytes; none is left on the fixture origin.
      assert.ok(s.images.length >= 1, `${s.request.story} has images`);
      for (const img of s.images) {
        assert.equal(img.status, 200, img.url);
        const name = img.url.slice(img.url.lastIndexOf("/") + 1);
        assert.deepEqual(img.bytes, readFileSync(join(assetsDir, name)));
      }
      assert.equal(
        resourcesRewritten(injected, rw.from, rw.to),
        injected,
        "no resource left on the fixture origin",
      );
      // Recorded in the provenance, with the injected bytes' hash.
      const row = rows.find((r) => r.entry.story === s.request.story)!;
      const meta = JSON.parse(
        readFileSync(join(scratch, run, row.entry.meta!), "utf8"),
      ) as { asset_rewrite: Record<string, unknown>; mime_sha256: string };
      assert.deepEqual(meta.asset_rewrite, {
        ...rw,
        injected_sha256: s.delivery.injectedSha256,
      });
      assert.equal(meta.mime_sha256, s.request.mimeSha256);
    }
    // The service's request log names what was served.
    assert.ok(
      assets.requests().some((r) => r.kind === "asset" && r.status === 200),
    );
  });

  it("delivers the canonical bytes and records no rewrite without the assets service", async () => {
    const run = `t9n-${process.pid}-${Date.now()}`;
    const probe = new MailStackProbe(false);
    await runProbe(probe, run);
    for (const s of probe.seen) {
      assert.equal(s.delivery.assetRewrite, null);
      assert.equal(s.delivery.injectedSha256, s.request.mimeSha256);
      assert.equal(s.images.length, 0);
    }
  });

  it("generates a fresh user and password for every account and every run", async () => {
    const seen: ImapAccount[] = [];
    for (let i = 0; i < 2; i++) {
      const service = registeredServices().imap!();
      const h = imapHandle(
        await service.start({
          run: `t9u-${process.pid}-${Date.now()}-${i}`,
          runDir: scratch,
        }),
      );
      try {
        seen.push(await h.createAccount(), await h.createAccount());
        assert.deepEqual(
          Object.keys(h.credentials ?? {}).sort(),
          seen
            .slice(-2)
            .map((a) => a.user)
            .sort(),
          "the handle's credentials list this run's users",
        );
      } finally {
        await service.stop();
      }
    }
    assert.equal(new Set(seen.map((a) => a.user)).size, 4);
    assert.equal(new Set(seen.map((a) => a.password)).size, 4);
    for (const a of seen) assert.ok(a.password.length >= 20, a.password);
  });

  it("never carries an account's password in a spread or a JSON.stringify of a Delivery", async () => {
    const service = registeredServices().imap!();
    const h = imapHandle(
      await service.start({
        run: `t9p-${process.pid}-${Date.now()}`,
        runDir: scratch,
      }),
    );
    try {
      const d = await h.mailboxFor(stories[0]!.mime);
      const password = d.account.password;
      assert.equal(typeof password, "string");
      assert.ok(password.length >= 20);
      // Spread into provenance the way a provider would.
      const provenance = { delivery: { ...d }, account: { ...d.account } };
      for (const s of [JSON.stringify(d), JSON.stringify(provenance)])
        assert.ok(!s.includes(password), s);
      assert.ok(!Object.keys(d.account).includes("password"));
      // Still the account's password: it logs in.
      assert.equal((await readMailbox(d.account)).login, "OK");
    } finally {
      await service.stop();
    }
  });

  it("the IMAP and asset ports refuse connections on every non-loopback address", async () => {
    const registry = registeredServices();
    const imapService = registry.imap!();
    const assetsService = registry.assets!();
    const run = `t9l-${process.pid}-${Date.now()}`;
    const imap = imapHandle(await imapService.start({ run, runDir: scratch }));
    const assets = assetsHandle(
      await assetsService.start({ run, runDir: scratch }),
    );
    try {
      const assetsPort = Number(new URL(assets.baseUrl).port);
      // Every address of the host that is not loopback (IPv6 link-local
      // ones with their interface as the scope).
      const external: string[] = [];
      for (const [iface, addrs] of Object.entries(networkInterfaces()))
        for (const i of addrs ?? [])
          if (!i.internal)
            external.push(
              i.family === "IPv6" && i.address.startsWith("fe80:")
                ? `${i.address}%${iface}`
                : i.address,
            );
      assert.ok(
        external.length > 0,
        "the host has no non-loopback address, so this control cannot be run",
      );
      // Positive control: both are reachable on loopback.
      assert.equal(await connectProbe("127.0.0.1", imap.port), "open");
      assert.equal(await connectProbe("127.0.0.1", assetsPort), "open");
      const outcomes: string[] = [];
      for (const addr of external)
        for (const port of [imap.port, assetsPort]) {
          const r = await connectProbe(addr, port);
          outcomes.push(r);
          assert.notEqual(
            r,
            "open",
            `${addr}:${port} must not accept connections`,
          );
        }
      // At least one of those addresses is reachable and actively
      // refuses (rather than dropping the probe), so a listener bound
      // there would have been seen.
      assert.ok(outcomes.includes("ECONNREFUSED"), outcomes.join(","));
    } finally {
      await imapService.stop();
      await assetsService.stop();
    }
  });
});
