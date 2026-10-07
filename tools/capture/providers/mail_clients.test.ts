// tools/capture/providers/mail_clients.test.ts — the SMTP submission
// client and the IMAP client against scripted servers that answer the
// way hosted providers do, for the protocol shapes the local servers in
// hosted_delivery.test.ts never produce.
//
// What is proven: an SMTP reply whose last line is the bare code, and
// an EHLO that offers only the old "AUTH=" form with LOGIN, are read
// correctly, and a message with LF line ends reaches the server with
// CRLF line ends and its dot lines stuffed; a server that stops
// answering fails the read after the per-read timeout; IMAP LIST
// responses with quoted names containing spaces and escapes, a name
// sent as a literal (a localized Trash), a NIL delimiter and extended
// data after the name yield the right names and special-use roles; a
// Message-ID is searched quoted with its angle brackets; a FETCH whose
// body is a literal followed by more items returns exactly the body;
// and a password that must go as a literal is sent after the server's
// continuation, even when untagged data comes first.
//
// Test doubles (justification, per the repository's mock policy): the
// servers are scripts, because the replies under test are ones the
// real local servers (Mailpit, Dovecot) do not send; the TLS, the
// certificate verification and the clients are real.
// Run with:
//   node --test tools/capture/providers/mail_clients.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
import type { AddressInfo } from "node:net";
import { createServer, type TLSSocket, type Server } from "node:tls";
import {
  ImapSession,
  parseListResponse,
  specialMailbox,
} from "./imap_client.ts";
import { MailProtocolError } from "./mail_socket.ts";
import { submitMessage } from "./smtp_submit.ts";
import { makeTestPki } from "./test_pki.ts";

const pki = makeTestPki();
const servers: Server[] = [];
const sockets = new Set<TLSSocket>();
after(async () => {
  // A client that failed mid-script leaves its connection open; end it
  // so the servers can close.
  for (const s of sockets) s.destroy();
  for (const s of servers) await new Promise((ok) => s.close(ok));
});

// A TLS server that greets, then hands each received line to the
// script (or, after the script calls `collect`, the raw bytes up to a
// terminator).
interface Script {
  greeting: string;
  onLine(line: string, conn: Conn): void;
}
interface Conn {
  send(text: string): void;
  // Collect raw bytes until `until` is seen, then call `done`.
  collect(until: string, done: (bytes: string) => void): void;
  socket: TLSSocket;
}

async function scripted(script: Script): Promise<number> {
  const server = createServer(
    { cert: pki.certChainPem, key: pki.keyPem },
    (socket) => {
      sockets.add(socket);
      socket.on("close", () => sockets.delete(socket));
      let buf = "";
      let collecting: { until: string; done: (b: string) => void } | null =
        null;
      const conn: Conn = {
        send: (t) => socket.write(t),
        collect: (until, done) => {
          collecting = { until, done };
        },
        socket,
      };
      socket.on("error", () => undefined);
      socket.on("data", (d: Buffer) => {
        buf += d.toString("latin1");
        for (;;) {
          if (collecting !== null) {
            const i = buf.indexOf(collecting.until);
            if (i < 0) return;
            const c = collecting;
            collecting = null;
            const bytes = buf.slice(0, i + c.until.length);
            buf = buf.slice(i + c.until.length);
            c.done(bytes);
            continue;
          }
          const i = buf.indexOf("\r\n");
          if (i < 0) return;
          const line = buf.slice(0, i);
          buf = buf.slice(i + 2);
          script.onLine(line, conn);
        }
      });
      socket.write(script.greeting);
    },
  );
  servers.push(server);
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  return (server.address() as AddressInfo).port;
}

describe("SMTP submission client against provider-shaped replies", () => {
  it("reads a bare-code last reply line and the old AUTH= form, and sends CRLF with dots stuffed", async () => {
    const seen: string[] = [];
    let data = "";
    const port = await scripted({
      greeting: "220-smtp.example ESMTP\r\n220\r\n",
      onLine(line, c) {
        seen.push(line);
        if (line.startsWith("EHLO"))
          c.send(
            "250-smtp.example\r\n250-AUTH=LOGIN\r\n250-8BITMIME\r\n250\r\n",
          );
        else if (line === "AUTH LOGIN") c.send("334 VXNlcm5hbWU6\r\n");
        else if (seen.length === 3) c.send("334 UGFzc3dvcmQ6\r\n");
        else if (seen.length === 4) c.send("235 2.7.0 Accepted\r\n");
        else if (line.startsWith("MAIL FROM")) c.send("250 OK\r\n");
        else if (line.startsWith("RCPT TO")) c.send("250 OK\r\n");
        else if (line === "DATA") {
          c.send("354 go ahead\r\n");
          c.collect("\r\n.\r\n", (b) => {
            data = b;
            c.send("250 2.0.0 OK queued\r\n");
          });
        } else if (line === "QUIT") {
          c.send("221 bye\r\n");
          c.socket.end();
        }
      },
    });
    const r = await submitMessage({
      endpoint: { host: "127.0.0.1", port, security: "tls" },
      trust: { ca: pki.caPem },
      user: "qa@example.test",
      password: "pw-abcdefgh",
      mailFrom: "qa@example.test",
      rcptTo: ["qa@example.test"],
      message: Buffer.from(
        "Subject: s\n\n.one dot\nplain\n..two dots\n",
        "latin1",
      ),
      timeoutMs: 5000,
    });
    assert.match(r.accepted, /^250 2\.0\.0 OK queued$/);
    // LOGIN, the old AUTH= form being all the server offers.
    assert.equal(seen[1], "AUTH LOGIN");
    assert.equal(seen[2], Buffer.from("qa@example.test").toString("base64"));
    assert.equal(
      data,
      "Subject: s\r\n\r\n..one dot\r\nplain\r\n...two dots\r\n.\r\n",
    );
  });

  it("fails a read after the per-read timeout when the server stops answering", async () => {
    const port = await scripted({
      greeting: "220 smtp.example ESMTP\r\n",
      onLine() {
        // silent
      },
    });
    const t0 = Date.now();
    await assert.rejects(
      submitMessage({
        endpoint: { host: "127.0.0.1", port, security: "tls" },
        trust: { ca: pki.caPem },
        user: "qa@example.test",
        password: "pw-abcdefgh",
        mailFrom: "qa@example.test",
        rcptTo: ["qa@example.test"],
        message: Buffer.from("Subject: s\r\n\r\nx\r\n"),
        timeoutMs: 300,
      }),
      (e: unknown) =>
        e instanceof MailProtocolError &&
        e.stage === "EHLO" &&
        /timed out after 300 ms/.test(e.message),
    );
    assert.ok(Date.now() - t0 < 5000);
  });
});

describe("IMAP client against provider-shaped responses", () => {
  it("parses LIST names quoted with spaces and escapes, as literals, and before extended data", () => {
    const boxes = [
      parseListResponse('* LIST (\\HasNoChildren) "/" "INBOX"', []),
      parseListResponse(
        '* LIST (\\All \\HasNoChildren) "/" "[Gmail]/All Mail"',
        [],
      ),
      parseListResponse(
        '* LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"',
        [],
      ),
      parseListResponse('* LIST (\\HasNoChildren \\Trash) "/" \u00000\u0000', [
        Buffer.from("[Gmail]/Corbeille", "utf8"),
      ]),
      parseListResponse(
        '* LIST (\\HasNoChildren \\Junk) "/" "Bulk" ("CHILDINFO" ("SUBSCRIBED"))',
        [],
      ),
      parseListResponse('* LIST (\\Noselect) NIL "a \\"quoted\\" box"', []),
      parseListResponse('* LIST (\\HasNoChildren) "." Archive', []),
    ];
    assert.deepEqual(
      boxes.map((b) => b?.name),
      [
        "INBOX",
        "[Gmail]/All Mail",
        "[Gmail]/Sent Mail",
        "[Gmail]/Corbeille",
        "Bulk",
        'a "quoted" box',
        "Archive",
      ],
    );
    const list = boxes.filter((b) => b !== null);
    assert.equal(specialMailbox(list, "\\All", []), "[Gmail]/All Mail");
    assert.equal(
      specialMailbox(list, "\\Trash", ["[Gmail]/Trash"]),
      "[Gmail]/Corbeille",
    );
    assert.equal(specialMailbox(list, "\\Junk", ["Spam"]), "Bulk");
    assert.equal(specialMailbox(list, "\\Drafts", ["Archive"]), "Archive");
  });

  it("searches a Message-ID quoted with its brackets, fetches a literal body, and sends a password literal after untagged data", async () => {
    const seen: string[] = [];
    const body = "Subject: hi\r\n\r\nline {5}\r\nend\r\n";
    let password = "";
    const port = await scripted({
      greeting: "* OK [CAPABILITY IMAP4rev1] ready\r\n",
      onLine(line, c) {
        seen.push(line);
        const [tag, ...rest] = line.split(" ");
        const cmd = rest.join(" ");
        if (cmd === "CAPABILITY")
          c.send(`* CAPABILITY IMAP4rev1 UIDPLUS MOVE\r\n${tag} OK done\r\n`);
        else if (/^LOGIN "qa@example.test" \{\d+\}$/.test(cmd)) {
          const n = Number(/\{(\d+)\}$/.exec(cmd)![1]);
          // Untagged data before the continuation.
          c.send("* OK [ALERT] hello\r\n+ go\r\n");
          c.collect("\r\n", (b) => {
            password = b.slice(0, n);
            c.send(`${tag} OK logged in\r\n`);
          });
        } else if (cmd.startsWith("EXAMINE"))
          c.send(`* 3 EXISTS\r\n${tag} OK [READ-ONLY] done\r\n`);
        else if (cmd.startsWith("UID SEARCH"))
          c.send(`* SEARCH 42\r\n${tag} OK done\r\n`);
        else if (cmd.startsWith("UID FETCH"))
          c.send(
            `* 3 FETCH (UID 42 BODY[] {${Buffer.byteLength(body)}}\r\n${body} FLAGS (\\Seen))\r\n${tag} OK done\r\n`,
          );
        else if (cmd === "LOGOUT") {
          c.send(`* BYE\r\n${tag} OK bye\r\n`);
          c.socket.end();
        } else c.send(`${tag} BAD unexpected\r\n`);
      },
    });
    const pw = 'app"pw\\x1';
    const s = await ImapSession.open(
      { host: "127.0.0.1", port, security: "tls" },
      { ca: pki.caPem },
      [pw],
      5000,
    );
    await s.login("qa@example.test", pw);
    assert.equal(password, pw);
    assert.equal(await s.open("INBOX", false), 3);
    assert.deepEqual(await s.searchHeader("Message-ID", "<r.1a2b.c@d.test>"), [
      42,
    ]);
    assert.equal(
      seen.find((l) => l.includes("SEARCH")),
      'a5 UID SEARCH HEADER Message-ID "<r.1a2b.c@d.test>"',
    );
    assert.equal((await s.fetchMessage(42)).toString("latin1"), body);
    await s.logout();
  });
});
