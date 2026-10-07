// tools/capture/providers/imap_client.ts — a minimal IMAP4rev1 client
// for finding and removing delivered messages: LOGIN, LIST with
// special-use attributes (RFC 6154), SELECT/EXAMINE, UID SEARCH HEADER,
// UID FETCH of a whole message, UID MOVE (RFC 6851; COPY + delete
// without it), UID STORE \Deleted with UID EXPUNGE (RFC 4315; EXPUNGE
// without it), LOGOUT.
//
// Always over TLS (993, or STARTTLS on 143) with a verified certificate
// (mail_socket.ts). Errors carry the server's text redacted of the
// password. No library: the dev shell provides none and nothing is
// installed from npm.

import { Buffer } from "node:buffer";
import {
  MailSocket,
  Redactor,
  type MailEndpoint,
  type TlsTrust,
} from "./mail_socket.ts";

export type SpecialUse =
  | "\\Sent"
  | "\\Junk"
  | "\\All"
  | "\\Trash"
  | "\\Drafts"
  | "\\Archive"
  | "\\Flagged";

export interface MailboxInfo {
  // The name as the server spells it (modified UTF-7), to send back.
  name: string;
  attributes: string[];
}

interface Response {
  // Untagged lines, each with its literals inlined as placeholders.
  untagged: { text: string; literals: Buffer[] }[];
  status: "OK" | "NO" | "BAD";
  text: string;
}

const LITERAL = /\{(\d+)\+?\}$/;

// One command argument: an IMAP quoted string, or a literal (a Buffer)
// when the value cannot be quoted.
function astring(v: string): string | Buffer {
  return /^[\x20-\x7e]*$/.test(v) && !/["\\]/.test(v)
    ? `"${v}"`
    : Buffer.from(v, "utf8");
}

function unquote(s: string): string {
  return s.slice(1, -1).replace(/\\(["\\])/g, "$1");
}

export class ImapSession {
  private tagSeq = 0;
  capabilities = new Set<string>();
  private readonly s: MailSocket;
  private constructor(s: MailSocket) {
    this.s = s;
  }

  static async open(
    endpoint: MailEndpoint,
    trust: TlsTrust = {},
    secrets: string[] = [],
    timeoutMs = 30_000,
  ): Promise<ImapSession> {
    const redactor = new Redactor().add(...secrets);
    const s = await MailSocket.open(endpoint, trust, redactor, timeoutMs);
    const session = new ImapSession(s);
    try {
      const greeting = await s.readLine("greeting");
      if (!/^\* (OK|PREAUTH)\b/i.test(greeting))
        throw s.error(`unexpected greeting: ${greeting}`, "greeting");
      if (endpoint.security === "starttls") {
        await session.command("STARTTLS");
        await s.startTls(endpoint, trust);
      }
      if (!s.encrypted) throw s.error("not encrypted", "tls");
      await session.refreshCapabilities();
      return session;
    } catch (err) {
      s.close();
      throw err;
    }
  }

  private async readResponseLine(
    stage: string,
  ): Promise<{ text: string; literals: Buffer[] }> {
    let text = await this.s.readLine(stage);
    const literals: Buffer[] = [];
    for (let m = LITERAL.exec(text); m !== null; m = LITERAL.exec(text)) {
      const lit = await this.s.readBytes(Number(m[1]), stage);
      text = `${text.slice(0, m.index)}\u0000${literals.length}\u0000${await this.s.readLine(stage)}`;
      literals.push(lit);
    }
    return { text, literals };
  }

  // Sends one command, its pieces joined by spaces: a string is sent
  // as it is, a Buffer as a literal (after the server's continuation).
  // Reads to the tagged reply; a NO or BAD throws, unless `allowNo`.
  async command(
    pieces: string | (string | Buffer)[],
    opts: { allowNo?: boolean } = {},
  ): Promise<Response> {
    const list = typeof pieces === "string" ? [pieces] : pieces;
    const tag = `a${++this.tagSeq}`;
    const first = list[0];
    const stage =
      typeof first === "string"
        ? first.split(" ").slice(0, 2).join(" ")
        : "command";
    let line = tag;
    for (const p of list) {
      if (typeof p === "string") {
        line += ` ${p}`;
        continue;
      }
      this.s.write(`${line} {${p.length}}\r\n`);
      // Untagged data may come before the continuation (RFC 3501
      // section 7.5); it is not this command's answer.
      let cont = (await this.readResponseLine(stage)).text;
      while (cont.startsWith("* "))
        cont = (await this.readResponseLine(stage)).text;
      if (!cont.startsWith("+"))
        throw this.s.error(
          `${stage}: the server refused a literal: ${cont}`,
          stage,
        );
      this.s.write(p);
      line = "";
    }
    this.s.write(`${line}\r\n`);
    const untagged: Response["untagged"] = [];
    for (;;) {
      const r = await this.readResponseLine(stage);
      if (r.text.startsWith(`${tag} `)) {
        const m = /^\S+ (OK|NO|BAD)\b ?(.*)$/i.exec(r.text);
        if (m === null)
          throw this.s.error(`${stage}: malformed reply: ${r.text}`, stage);
        const status = m[1]!.toUpperCase() as Response["status"];
        const resp = { untagged, status, text: m[2]! };
        if (status === "BAD" || (status === "NO" && opts.allowNo !== true))
          throw this.s.error(`${stage} refused: ${status} ${resp.text}`, stage);
        return resp;
      }
      if (r.text.startsWith("+")) continue;
      untagged.push(r);
    }
  }

  private async refreshCapabilities(): Promise<void> {
    const r = await this.command("CAPABILITY");
    for (const u of r.untagged) {
      const m = /^\* CAPABILITY (.*)$/i.exec(u.text);
      if (m !== null)
        this.capabilities = new Set(m[1]!.toUpperCase().split(/\s+/));
    }
  }

  async login(user: string, password: string): Promise<void> {
    if (this.capabilities.has("LOGINDISABLED"))
      throw this.s.error("the server disables LOGIN", "LOGIN");
    await this.command(["LOGIN", astring(user), astring(password)]);
    await this.refreshCapabilities();
  }

  async list(): Promise<MailboxInfo[]> {
    const extended =
      this.capabilities.has("SPECIAL-USE") &&
      this.capabilities.has("LIST-EXTENDED");
    const r = await this.command(
      extended ? 'LIST "" "*" RETURN (SPECIAL-USE)' : 'LIST "" "*"',
    );
    const out: MailboxInfo[] = [];
    for (const u of r.untagged) {
      const box = parseListResponse(u.text, u.literals);
      if (box !== null) out.push(box);
    }
    return out;
  }

  // EXAMINE (read-only) or SELECT; returns the message count.
  async open(mailbox: string, write: boolean): Promise<number> {
    const r = await this.command([
      write ? "SELECT" : "EXAMINE",
      astring(mailbox),
    ]);
    for (const u of r.untagged) {
      const m = /^\* (\d+) EXISTS$/i.exec(u.text);
      if (m !== null) return Number(m[1]);
    }
    return 0;
  }

  async searchHeader(field: string, value: string): Promise<number[]> {
    const r = await this.command([
      `UID SEARCH HEADER ${field}`,
      astring(value),
    ]);
    const uids: number[] = [];
    for (const u of r.untagged) {
      const m = /^\* SEARCH(.*)$/i.exec(u.text);
      if (m !== null)
        for (const t of m[1]!.trim().split(/\s+/))
          if (t !== "") uids.push(Number(t));
    }
    return uids;
  }

  async fetchMessage(uid: number): Promise<Buffer> {
    const r = await this.command(`UID FETCH ${uid} BODY.PEEK[]`);
    for (const u of r.untagged)
      if (/FETCH/i.test(u.text) && u.literals.length > 0) return u.literals[0]!;
    throw this.s.error(`UID ${uid}: no message body returned`, "UID FETCH");
  }

  // Moves the messages to `dest` (the mailbox must be selected
  // read-write).
  async move(uids: number[], dest: string): Promise<void> {
    if (uids.length === 0) return;
    const set = uids.join(",");
    if (this.capabilities.has("MOVE")) {
      await this.command([`UID MOVE ${set}`, astring(dest)]);
      return;
    }
    await this.command([`UID COPY ${set}`, astring(dest)]);
    await this.expungeUids(uids);
  }

  // Flags the messages \Deleted and expunges them (only them, with
  // UIDPLUS; otherwise every \Deleted message in the mailbox).
  async expungeUids(uids: number[]): Promise<void> {
    if (uids.length === 0) return;
    await this.command(`UID STORE ${uids.join(",")} +FLAGS.SILENT (\\Deleted)`);
    await this.command(
      this.capabilities.has("UIDPLUS")
        ? `UID EXPUNGE ${uids.join(",")}`
        : "EXPUNGE",
    );
  }

  async logout(): Promise<void> {
    try {
      await this.command("LOGOUT");
    } catch {
      // The session ends either way.
    } finally {
      this.s.close();
    }
  }

  close(): void {
    this.s.close();
  }
}

// One untagged LIST response (its literals inlined as placeholders, as
// the session reads them): the attributes and the mailbox name, which
// is a quoted string, a literal or an atom, possibly followed by
// extended data (RFC 5258) that is not part of the name.
export function parseListResponse(
  text: string,
  literals: Buffer[],
): MailboxInfo | null {
  const m = /^\* LIST \(([^)]*)\) (?:NIL|"(?:[^"\\]|\\.)*") (.*)$/i.exec(text);
  if (m === null) return null;
  const rest = m[2]!;
  let name: string;
  const quoted = /^"((?:[^"\\]|\\.)*)"/.exec(rest);
  const lit = /^\u0000(\d+)\u0000/.exec(rest);
  if (quoted !== null) name = unquote(quoted[0]);
  else if (lit !== null) {
    const bytes = literals[Number(lit[1])];
    if (bytes === undefined) return null;
    name = bytes.toString("utf8");
  } else name = /^[^\s()]+/.exec(rest)?.[0] ?? "";
  if (name === "") return null;
  return {
    name,
    attributes: m[1]!.split(/\s+/).filter((a) => a !== ""),
  };
}

// The mailbox with a special-use attribute, else the first of the
// fallback names present (a server without RFC 6154).
export function specialMailbox(
  boxes: MailboxInfo[],
  use: SpecialUse,
  fallbacks: string[],
): string | null {
  const byAttr = boxes.find((b) =>
    b.attributes.some((a) => a.toLowerCase() === use.toLowerCase()),
  );
  if (byAttr !== undefined) return byAttr.name;
  for (const f of fallbacks) if (boxes.some((b) => b.name === f)) return f;
  return null;
}
