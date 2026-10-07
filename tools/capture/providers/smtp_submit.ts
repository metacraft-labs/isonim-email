// tools/capture/providers/smtp_submit.ts — a minimal SMTP submission
// client (RFC 6409): one message, one authenticated session.
//
// What it does, in order: connect (TLS from the first byte on 465, or
// a plain greeting and STARTTLS on 587, refusing a server that does not
// offer it), EHLO, AUTH PLAIN (LOGIN when that is all the server
// offers), MAIL FROM (with BODY=8BITMIME when the message has 8-bit
// bytes, refused when the server lacks 8BITMIME), RCPT TO per
// recipient, DATA with CRLF line ends and dot-stuffing, QUIT. Every
// reply that is not the expected class fails the submission with the
// server's text, redacted of the password in every encoding AUTH sends
// it in.
//
// No library: the dev shell provides none and nothing is installed from
// npm, and a submission needs only this much of SMTP.

import { Buffer } from "node:buffer";
import {
  MailProtocolError,
  MailSocket,
  Redactor,
  type MailEndpoint,
  type TlsTrust,
} from "./mail_socket.ts";

export interface SubmitOptions {
  endpoint: MailEndpoint;
  trust?: TlsTrust;
  user: string;
  password: string;
  mailFrom: string;
  rcptTo: string[];
  message: Uint8Array;
  // Per network wait (default 30 s).
  timeoutMs?: number;
  // The EHLO name (default "localhost").
  clientName?: string;
}

export interface SubmitResult {
  // The server's reply to the end of DATA (redacted), e.g. its queue id.
  accepted: string;
  timingMs: { connect: number; auth: number; data: number; total: number };
}

interface Reply {
  code: number;
  lines: string[];
}

async function readReply(s: MailSocket, stage: string): Promise<Reply> {
  const lines: string[] = [];
  for (;;) {
    const line = await s.readLine(stage);
    // The last line may be the bare code: Reply-code [ SP textstring ]
    // (RFC 5321 section 4.2).
    const m = /^(\d{3})(?:([ -])(.*))?$/.exec(line);
    if (m === null)
      throw s.error(`malformed reply during ${stage}: ${line}`, stage);
    lines.push(m[3] ?? "");
    if (m[2] !== "-") return { code: Number(m[1]), lines };
  }
}

async function expect(
  s: MailSocket,
  stage: string,
  ok: (code: number) => boolean,
): Promise<Reply> {
  const r = await readReply(s, stage);
  if (!ok(r.code))
    throw s.error(
      `${stage} refused: ${r.code} ${r.lines.join(" / ")}`,
      stage,
      r.code,
    );
  return r;
}

const is2xx = (c: number): boolean => c >= 200 && c < 300;

async function ehlo(s: MailSocket, name: string): Promise<Set<string>> {
  s.write(`EHLO ${name}\r\n`);
  const r = await expect(s, "EHLO", is2xx);
  return new Set(r.lines.slice(1).map((l) => l.toUpperCase()));
}

function authMechanisms(caps: Set<string>): Set<string> {
  const out = new Set<string>();
  for (const c of caps) {
    const m = /^AUTH[ =](.*)$/.exec(c);
    if (m !== null) for (const mech of m[1]!.split(/\s+/)) out.add(mech);
  }
  return out;
}

// CRLF line ends and dot-stuffing; the terminating "." line appended.
export function dataBody(message: Uint8Array): Buffer {
  const text = Buffer.from(message)
    .toString("latin1")
    .replace(/\r?\n/g, "\r\n");
  const lines = text.split("\r\n");
  if (lines[lines.length - 1] === "") lines.pop();
  const stuffed = lines.map((l) => (l.startsWith(".") ? `.${l}` : l));
  return Buffer.from(`${stuffed.join("\r\n")}\r\n.\r\n`, "latin1");
}

function address(a: string): string {
  if (!/^[^\s<>@]+@[^\s<>@]+$/.test(a) || /[^\x21-\x7e]/.test(a))
    throw new MailProtocolError(
      `not a plain ASCII address: ${JSON.stringify(a)}`,
      "envelope",
    );
  return `<${a}>`;
}

export async function submitMessage(o: SubmitOptions): Promise<SubmitResult> {
  const timeoutMs = o.timeoutMs ?? 30_000;
  const trust = o.trust ?? {};
  const redactor = new Redactor().add(o.password).addPlain(o.user, o.password);
  const name = o.clientName ?? "localhost";
  const from = address(o.mailFrom);
  if (o.rcptTo.length === 0)
    throw new MailProtocolError("no recipient", "envelope");
  const rcpts = o.rcptTo.map(address);
  const eightBit = Buffer.from(o.message).some((b) => b > 0x7f);

  const t0 = performance.now();
  const s = await MailSocket.open(o.endpoint, trust, redactor, timeoutMs);
  try {
    await expect(s, "greeting", (c) => c === 220);
    let caps = await ehlo(s, name);
    if (o.endpoint.security === "starttls") {
      if (!caps.has("STARTTLS"))
        throw s.error(
          "the server does not offer STARTTLS; refusing to authenticate in the clear",
          "starttls",
        );
      s.write("STARTTLS\r\n");
      await expect(s, "STARTTLS", (c) => c === 220);
      await s.startTls(o.endpoint, trust);
      caps = await ehlo(s, name);
    }
    if (!s.encrypted)
      throw s.error("not encrypted; refusing to authenticate", "auth");
    const tConnect = performance.now();

    const mechs = authMechanisms(caps);
    if (mechs.has("PLAIN")) {
      const token = Buffer.from(`\0${o.user}\0${o.password}`, "utf8").toString(
        "base64",
      );
      s.write(`AUTH PLAIN ${token}\r\n`);
      await expect(s, "AUTH PLAIN", (c) => c === 235);
    } else if (mechs.has("LOGIN")) {
      s.write("AUTH LOGIN\r\n");
      await expect(s, "AUTH LOGIN", (c) => c === 334);
      s.write(`${Buffer.from(o.user, "utf8").toString("base64")}\r\n`);
      await expect(s, "AUTH LOGIN (user)", (c) => c === 334);
      s.write(`${Buffer.from(o.password, "utf8").toString("base64")}\r\n`);
      await expect(s, "AUTH LOGIN (password)", (c) => c === 235);
    } else {
      throw s.error(
        `the server offers neither AUTH PLAIN nor AUTH LOGIN (offers: ${[...mechs].join(" ") || "none"})`,
        "auth",
      );
    }
    const tAuth = performance.now();

    if (eightBit && !caps.has("8BITMIME"))
      throw s.error(
        "the message has 8-bit bytes and the server lacks 8BITMIME",
        "envelope",
      );
    s.write(`MAIL FROM:${from}${eightBit ? " BODY=8BITMIME" : ""}\r\n`);
    await expect(s, "MAIL FROM", is2xx);
    for (const r of rcpts) {
      s.write(`RCPT TO:${r}\r\n`);
      await expect(s, `RCPT TO ${r}`, is2xx);
    }
    s.write("DATA\r\n");
    await expect(s, "DATA", (c) => c === 354);
    s.write(dataBody(o.message));
    const done = await expect(s, "end of DATA", is2xx);
    const tData = performance.now();
    s.write("QUIT\r\n");
    // The reply to QUIT is a courtesy; the message is already accepted.
    await readReply(s, "QUIT").catch(() => undefined);
    return {
      accepted: s.redact(`${done.code} ${done.lines.join(" / ")}`),
      timingMs: {
        connect: tConnect - t0,
        auth: tAuth - tConnect,
        data: tData - tAuth,
        total: performance.now() - t0,
      },
    };
  } finally {
    s.close();
  }
}
