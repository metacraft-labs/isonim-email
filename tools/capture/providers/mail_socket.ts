// tools/capture/providers/mail_socket.ts — the connection under the
// SMTP submission client (smtp_submit.ts) and the IMAP client
// (imap_client.ts): TLS from the first byte or after STARTTLS, a
// verified server certificate, line and literal reads with a deadline,
// and redaction of the secrets the protocols carry.
//
// The server certificate is always verified: against the system roots,
// or against the authority a test passes (`trust.ca`). There is no
// option to skip verification and no cleartext mode: a server reached
// on a submission or IMAP port without TLS is an error.

import { Buffer } from "node:buffer";
import { connect as netConnect, type Socket } from "node:net";
import { connect as tlsConnect, type TLSSocket } from "node:tls";

export interface MailEndpoint {
  host: string;
  port: number;
  // "tls": TLS from the first byte (465, 993); "starttls": a plain
  // greeting, then STARTTLS before anything else is sent (587).
  security: "tls" | "starttls";
}

export interface TlsTrust {
  // PEM roots to verify the server against instead of the system's
  // (tests: a throwaway authority).
  ca?: string;
  // The name the certificate must carry, when it is not the host.
  servername?: string;
}

// An error from a mail server or the connection to it. Its message is
// already redacted: no password, in any encoding the protocols use,
// appears in it.
export class MailProtocolError extends Error {
  readonly stage: string;
  readonly code: number | null;
  constructor(message: string, stage: string, code: number | null = null) {
    super(message);
    this.name = "MailProtocolError";
    this.stage = stage;
    this.code = code;
  }
}

// Replaces every secret, and the encodings SMTP AUTH and IMAP LOGIN put
// them in, with "[redacted]".
export class Redactor {
  private readonly needles: string[] = [];
  add(...secrets: string[]): this {
    for (const s of secrets) {
      if (s === "") continue;
      const forms = [
        s,
        Buffer.from(s, "utf8").toString("base64"),
        JSON.stringify(s).slice(1, -1),
      ];
      for (const f of forms) if (f.length >= 4) this.needles.push(f);
    }
    return this;
  }
  // AUTH PLAIN's whole token, which a server could echo.
  addPlain(user: string, password: string): this {
    this.needles.push(
      Buffer.from(`\0${user}\0${password}`, "utf8").toString("base64"),
    );
    return this;
  }
  redact(text: string): string {
    let out = text;
    // Longest first, so a secret inside a longer token goes with it.
    for (const n of [...this.needles].sort((a, b) => b.length - a.length))
      out = out.split(n).join("[redacted]");
    return out;
  }
}

export class MailSocket {
  private socket: Socket | TLSSocket;
  private buf: Buffer = Buffer.alloc(0);
  private waiter: (() => void) | null = null;
  private failure: Error | null = null;
  private closed = false;
  readonly label: string;
  private readonly redactor: Redactor;
  private readonly timeoutMs: number;

  private constructor(
    socket: Socket | TLSSocket,
    label: string,
    redactor: Redactor,
    timeoutMs: number,
  ) {
    this.socket = socket;
    this.label = label;
    this.redactor = redactor;
    this.timeoutMs = timeoutMs;
    this.attach(socket);
  }

  private attach(socket: Socket | TLSSocket): void {
    socket.on("data", (d: Buffer) => {
      this.buf = Buffer.concat([this.buf, d]);
      this.wake();
    });
    socket.on("error", (e: Error) => {
      this.failure ??= e;
      this.wake();
    });
    socket.on("close", () => {
      this.closed = true;
      this.wake();
    });
  }

  private wake(): void {
    const w = this.waiter;
    this.waiter = null;
    w?.();
  }

  // Connects and, for "tls", completes the handshake with a verified
  // certificate.
  static async open(
    endpoint: MailEndpoint,
    trust: TlsTrust,
    redactor: Redactor,
    timeoutMs: number,
  ): Promise<MailSocket> {
    const label = `${endpoint.host}:${endpoint.port}`;
    const socket =
      endpoint.security === "tls"
        ? await secure(
            tlsConnect({
              host: endpoint.host,
              port: endpoint.port,
              ca: trust.ca,
              servername: tlsName(endpoint.host, trust),
            }),
            label,
            timeoutMs,
          )
        : await plain(
            netConnect({ host: endpoint.host, port: endpoint.port }),
            label,
            timeoutMs,
          );
    return new MailSocket(socket, label, redactor, timeoutMs);
  }

  // Upgrades a plain connection after the server accepted STARTTLS.
  async startTls(endpoint: MailEndpoint, trust: TlsTrust): Promise<void> {
    if (this.buf.length > 0)
      throw this.error(
        "the server sent data after accepting STARTTLS (refused: it could be injected)",
        "starttls",
      );
    const raw = this.socket;
    raw.removeAllListeners("data");
    raw.removeAllListeners("error");
    raw.removeAllListeners("close");
    const upgraded = await secure(
      tlsConnect({
        socket: raw,
        ca: trust.ca,
        servername: tlsName(endpoint.host, trust),
      }),
      this.label,
      this.timeoutMs,
    );
    this.socket = upgraded;
    this.attach(upgraded);
  }

  get encrypted(): boolean {
    return (this.socket as TLSSocket).encrypted === true;
  }

  write(data: string | Uint8Array): void {
    this.socket.write(data);
  }

  error(
    message: string,
    stage: string,
    code: number | null = null,
  ): MailProtocolError {
    return new MailProtocolError(
      this.redactor.redact(`${this.label}: ${message}`),
      stage,
      code,
    );
  }

  private async more(stage: string, deadline: number): Promise<void> {
    if (this.failure !== null)
      throw this.error(
        `connection failed during ${stage}: ${this.failure.message}`,
        stage,
      );
    if (this.closed)
      throw this.error(
        `the server closed the connection during ${stage}`,
        stage,
      );
    const left = deadline - Date.now();
    if (left <= 0)
      throw this.error(
        `timed out after ${this.timeoutMs} ms waiting for ${stage}`,
        stage,
      );
    await new Promise<void>((ok) => {
      const t = setTimeout(ok, left);
      this.waiter = () => {
        clearTimeout(t);
        ok();
      };
    });
  }

  // One line without its CRLF (bytes as latin1).
  async readLine(stage: string): Promise<string> {
    const deadline = Date.now() + this.timeoutMs;
    for (;;) {
      const i = this.buf.indexOf("\r\n");
      if (i >= 0) {
        const line = this.buf.subarray(0, i).toString("latin1");
        this.buf = this.buf.subarray(i + 2);
        return line;
      }
      await this.more(stage, deadline);
    }
  }

  // Exactly n bytes (an IMAP literal).
  async readBytes(n: number, stage: string): Promise<Buffer> {
    const deadline = Date.now() + this.timeoutMs;
    while (this.buf.length < n) await this.more(stage, deadline);
    const out = this.buf.subarray(0, n);
    this.buf = this.buf.subarray(n);
    return Buffer.from(out);
  }

  close(): void {
    this.socket.destroy();
  }

  redact(text: string): string {
    return this.redactor.redact(text);
  }
}

function tlsName(host: string, trust: TlsTrust): string | undefined {
  if (trust.servername !== undefined) return trust.servername;
  // SNI takes names only; an IP literal is checked against the
  // certificate's IP entries without it.
  return /^[\d.]+$|:/.test(host) ? undefined : host;
}

function plain(
  socket: Socket,
  label: string,
  timeoutMs: number,
): Promise<Socket> {
  return new Promise((ok, fail) => {
    const t = setTimeout(() => {
      socket.destroy();
      fail(
        new MailProtocolError(
          `${label}: connect timed out after ${timeoutMs} ms`,
          "connect",
        ),
      );
    }, timeoutMs);
    socket.once("connect", () => {
      clearTimeout(t);
      ok(socket);
    });
    socket.once("error", (e) => {
      clearTimeout(t);
      fail(
        new MailProtocolError(
          `${label}: cannot connect: ${e.message}`,
          "connect",
        ),
      );
    });
  });
}

function secure(
  socket: TLSSocket,
  label: string,
  timeoutMs: number,
): Promise<TLSSocket> {
  return new Promise((ok, fail) => {
    const t = setTimeout(() => {
      socket.destroy();
      fail(
        new MailProtocolError(
          `${label}: TLS handshake timed out after ${timeoutMs} ms`,
          "tls",
        ),
      );
    }, timeoutMs);
    socket.once("secureConnect", () => {
      clearTimeout(t);
      // tls.connect rejects an unverified certificate itself
      // (rejectUnauthorized defaults to true); this is belt and braces.
      if (!socket.authorized) {
        socket.destroy();
        fail(
          new MailProtocolError(
            `${label}: TLS certificate not trusted (${String(socket.authorizationError)})`,
            "tls",
          ),
        );
        return;
      }
      ok(socket);
    });
    socket.once("error", (e) => {
      clearTimeout(t);
      fail(new MailProtocolError(`${label}: TLS failed: ${e.message}`, "tls"));
    });
  });
}
