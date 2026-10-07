// tools/capture/providers/hosted_delivery_fixtures.ts — local stand-ins
// for a hosted mail provider, for the delivery tests
// (hosted_delivery.test.ts): real servers on loopback, over real TLS.
//
// - Submission: Mailpit (in the dev shell), with TLS from the first
//   byte (465-style) or STARTTLS required (587-style), and AUTH checked
//   against a password file holding the test accounts' app passwords.
// - Mailboxes: the user-mode Dovecot of the imap service, with logins
//   by address and the special-use mailboxes a provider has (Sent,
//   Junk, All Mail, Trash), behind a TLS front.
// - Delivery: what the provider does between the two, played by the
//   test: each message Mailpit accepts is filed into the sender's Sent
//   (and All Mail) and into each local recipient's INBOX (or Junk, and
//   All Mail), or withheld. Nothing reaches the network: every server
//   listens on 127.0.0.1.
// - Certificates: a throwaway authority (test_pki.ts) the clients are
//   given as their only root.

import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import {
  createConnection,
  createServer as createNetServer,
  type AddressInfo,
  type Server as NetServer,
  type Socket,
} from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createServer as createTlsServer,
  type Server as TlsServer,
} from "node:tls";
import { DovecotService } from "./imap_service.ts";
import type { MailboxProfile } from "./hosted_delivery.ts";
import type { MailEndpoint } from "./mail_socket.ts";
import { makeTestPki, type TestPki } from "./test_pki.ts";
import type { ImapAccount, ImapHandle } from "./types.ts";

export function freePort(): Promise<number> {
  return new Promise((ok, fail) => {
    const s = createNetServer();
    s.once("error", fail);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address() as AddressInfo;
      s.close(() => ok(port));
    });
  });
}

// Dovecot as a provider's IMAP: logins by address (the domain is
// dropped), and the special-use mailboxes created for every user.
const PROVIDER_MAILBOXES = `
auth_username_format = %{user | username}
namespace inbox {
  inbox = yes
  separator = /
  mailbox Sent {
    special_use = \\Sent
    auto = create
  }
  mailbox Junk {
    special_use = \\Junk
    auto = create
  }
  mailbox "All Mail" {
    special_use = \\All
    auto = create
  }
  mailbox Trash {
    special_use = \\Trash
    auto = create
  }
}
`;

export const TEST_DOMAIN = "example.test";

export interface TestAccount {
  address: string;
  appPassword: string;
  imap: ImapAccount;
}

// A TLS front for a plain loopback server: each connection is
// terminated with the test authority's certificate and piped through.
async function tlsFront(
  pki: TestPki,
  targetPort: number,
): Promise<{ server: TlsServer; port: number }> {
  const server = createTlsServer(
    { cert: pki.certChainPem, key: pki.keyPem },
    (client) => {
      const upstream: Socket = createConnection({
        host: "127.0.0.1",
        port: targetPort,
      });
      client.pipe(upstream).pipe(client);
      const end = (): void => {
        client.destroy();
        upstream.destroy();
      };
      client.on("error", end);
      upstream.on("error", end);
      client.on("close", end);
      upstream.on("close", end);
    },
  );
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  return { server, port: (server.address() as AddressInfo).port };
}

interface MailpitSummary {
  ID: string;
  From: { Address: string } | null;
  To: { Address: string }[] | null;
  Cc: { Address: string }[] | null;
  Bcc: { Address: string }[] | null;
}

export type Filing = "inbox" | "junk" | "withhold";

export class LocalProvider {
  readonly pki: TestPki = makeTestPki();
  private dovecot: DovecotService | null = null;
  private imap: ImapHandle | null = null;
  private front: { server: TlsServer; port: number } | null = null;
  private mailpit: ChildProcess | null = null;
  private mailpitLog = "";
  private smtpPort = 0;
  private apiPort = 0;
  private readonly dir: string;
  private readonly accounts = new Map<string, TestAccount>();
  private pump: NodeJS.Timeout | null = null;
  private pumping = false;
  private readonly done = new Set<string>();
  // How the "provider" files mail to each recipient (default inbox).
  readonly filing = new Map<string, Filing>();
  // Gmail-like: a copy in All Mail beside INBOX and Sent.
  allMail = true;
  security: "tls" | "starttls";
  // Connections the SMTP and IMAP fronts accepted.
  connections = 0;
  private counter: NetServer | null = null;
  private smtpFrontPort = 0;

  constructor(security: "tls" | "starttls") {
    this.security = security;
    this.dir = mkdtempSync(join(tmpdir(), "hosted-delivery-"));
  }

  async start(run: string): Promise<void> {
    this.dovecot = new DovecotService({ extraConfig: PROVIDER_MAILBOXES });
    this.imap = (await this.dovecot.start({
      run,
      runDir: this.dir,
    })) as ImapHandle;
    this.front = await tlsFront(this.pki, this.imap.port);
    writeFileSync(join(this.dir, "cert.pem"), this.pki.certChainPem, {
      mode: 0o600,
    });
    writeFileSync(join(this.dir, "key.pem"), this.pki.keyPem, { mode: 0o600 });
    // Mailpit starts with the first account (it reads its password
    // file only at start).
    // Counts every connection to the submission server, through a
    // plain pass-through in front of it (TLS stays end to end).
    this.counter = createNetServer((c) => {
      this.connections += 1;
      const up = createConnection({ host: "127.0.0.1", port: this.smtpPort });
      c.pipe(up).pipe(c);
      c.on("error", () => up.destroy());
      up.on("error", () => c.destroy());
      c.on("close", () => up.destroy());
      up.on("close", () => c.destroy());
    });
    await new Promise<void>((ok) => this.counter!.listen(0, "127.0.0.1", ok));
    this.smtpFrontPort = (this.counter.address() as AddressInfo).port;
    this.pump = setInterval(() => void this.deliverPending(), 100);
  }

  private async startMailpit(): Promise<void> {
    if (this.mailpit !== null) {
      const old = this.mailpit;
      const gone = new Promise((r) => old.once("exit", r));
      old.kill("SIGTERM");
      await gone;
    }
    this.smtpPort = await freePort();
    this.apiPort = await freePort();
    const lines = [...this.accounts.values()].map(
      (a) => `${a.address}:${a.appPassword}`,
    );
    writeFileSync(join(this.dir, "auth"), `${lines.join("\n")}\n`, {
      mode: 0o600,
    });
    const args = [
      "--smtp",
      `127.0.0.1:${this.smtpPort}`,
      "--listen",
      `127.0.0.1:${this.apiPort}`,
      "--database",
      join(this.dir, `mailpit-${this.smtpPort}.db`),
      "--smtp-tls-cert",
      join(this.dir, "cert.pem"),
      "--smtp-tls-key",
      join(this.dir, "key.pem"),
      "--smtp-auth-file",
      join(this.dir, "auth"),
      this.security === "tls"
        ? "--smtp-require-tls"
        : "--smtp-require-starttls",
      "--disable-version-check",
      "--smtp-disable-rdns",
    ];
    const child = spawn("mailpit", args, { stdio: ["ignore", "pipe", "pipe"] });
    child.stdout?.on("data", (d: Buffer) => (this.mailpitLog += d.toString()));
    child.stderr?.on("data", (d: Buffer) => (this.mailpitLog += d.toString()));
    this.mailpit = child;
    const t0 = Date.now();
    while (Date.now() - t0 < 15_000) {
      try {
        const r = await fetch(`http://127.0.0.1:${this.apiPort}/api/v1/info`);
        if (r.ok) return;
      } catch {
        // not up yet
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new Error(`mailpit did not start: ${this.mailpitLog.slice(-500)}`);
  }

  // A mailbox account and its app password, known to both servers.
  async addAccount(appPassword: string): Promise<TestAccount> {
    const imap = await this.imap!.createAccount();
    const address = `${imap.user}@${TEST_DOMAIN}`;
    const a = { address, appPassword, imap };
    this.accounts.set(address, a);
    // Dovecot's password is the app password too.
    await this.setImapPassword(imap, appPassword);
    // Mailpit reads its password file at start.
    await this.startMailpit();
    return a;
  }

  private async setImapPassword(
    account: ImapAccount,
    password: string,
  ): Promise<void> {
    const stateDir = String(this.imap!.detail.stateDir);
    const file = join(stateDir, "passwd.d", account.user);
    writeFileSync(`${file}.tmp`, `${account.user}:{PLAIN}${password}::::::\n`, {
      mode: 0o600,
    });
    const { renameSync } = await import("node:fs");
    renameSync(`${file}.tmp`, file);
  }

  // The profile of a provider served by these servers.
  profile(
    set: string,
    opts: { canSend: boolean; crossSendFrom?: string } = { canSend: true },
  ): MailboxProfile {
    const smtp: MailEndpoint = {
      host: "127.0.0.1",
      port: this.smtpFrontPort,
      security: this.security,
    };
    const imap: MailEndpoint = {
      host: "127.0.0.1",
      port: this.front!.port,
      security: "tls",
    };
    return {
      set,
      label: `local ${set}`,
      smtp: opts.canSend ? smtp : null,
      imap: opts.canSend ? imap : null,
      fallbacks: { sent: [], junk: [], all: [], trash: [] },
      crossSendFrom: opts.crossSendFrom,
    };
  }

  // Files a message straight into a mailbox (bypassing submission).
  async file(
    account: TestAccount,
    mime: Uint8Array,
    mailbox: string,
  ): Promise<void> {
    // deliver() checks the account's password against the service's
    // own record, which still holds the generated one.
    await this.imap!.deliver(account.imap, mime, { mailbox });
  }

  private async deliverPending(): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    try {
      const r = await fetch(`http://127.0.0.1:${this.apiPort}/api/v1/messages`);
      if (!r.ok) return;
      const list = (await r.json()) as { messages: MailpitSummary[] };
      for (const m of list.messages) {
        if (this.done.has(m.ID)) continue;
        this.done.add(m.ID);
        const raw = new Uint8Array(
          await (
            await fetch(
              `http://127.0.0.1:${this.apiPort}/api/v1/message/${m.ID}/raw`,
            )
          ).arrayBuffer(),
        );
        const sender =
          m.From === null ? undefined : this.accounts.get(m.From.Address);
        if (sender !== undefined) {
          await this.file(sender, raw, "Sent");
          if (this.allMail) await this.file(sender, raw, "All Mail");
        }
        const rcpts = [...(m.To ?? []), ...(m.Cc ?? []), ...(m.Bcc ?? [])].map(
          (x) => x.Address,
        );
        for (const addr of new Set(rcpts)) {
          const rcpt = this.accounts.get(addr);
          const how = this.filing.get(addr) ?? "inbox";
          if (rcpt === undefined || how === "withhold") continue;
          await this.file(rcpt, raw, how === "junk" ? "Junk" : "INBOX");
          if (this.allMail && rcpt !== sender)
            await this.file(rcpt, raw, "All Mail");
        }
      }
    } catch {
      // Mailpit restarting; the next tick retries.
    } finally {
      this.pumping = false;
    }
  }

  // Raw messages Mailpit accepted (for byte comparisons).
  async accepted(): Promise<Uint8Array[]> {
    const r = await fetch(`http://127.0.0.1:${this.apiPort}/api/v1/messages`);
    const list = (await r.json()) as { messages: MailpitSummary[] };
    return Promise.all(
      list.messages.map(
        async (m) =>
          new Uint8Array(
            await (
              await fetch(
                `http://127.0.0.1:${this.apiPort}/api/v1/message/${m.ID}/raw`,
              )
            ).arrayBuffer(),
          ),
      ),
    );
  }

  get caPem(): string {
    return this.pki.caPem;
  }

  // The endpoints as the smoke CLI's --endpoints file takes them.
  endpoints(
    set: string,
  ): Record<string, { smtp: MailEndpoint; imap: MailEndpoint }> {
    const p = this.profile(set);
    return { [set]: { smtp: p.smtp!, imap: p.imap! } };
  }

  async stop(): Promise<void> {
    if (this.pump !== null) clearInterval(this.pump);
    while (this.pumping) await new Promise((r) => setTimeout(r, 20));
    if (this.mailpit !== null) {
      const m = this.mailpit;
      const gone = new Promise((r) => m.once("exit", r));
      m.kill("SIGTERM");
      await gone;
    }
    await new Promise<void>((ok) =>
      this.counter === null ? ok() : this.counter.close(() => ok()),
    );
    await new Promise<void>((ok) =>
      this.front === null ? ok() : this.front.server.close(() => ok()),
    );
    await this.dovecot?.stop();
    rmSync(this.dir, { recursive: true, force: true });
  }
}
