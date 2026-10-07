// tools/capture/email-selfsend-smoke.ts — `just email-selfsend-smoke`:
// one live delivery for a credential set, end to end: the account sends
// a small message to itself through its provider's submission server,
// finds it over IMAP by Message-ID, prints the timings and where it
// arrived, and removes every copy. With --to, the set sends to another
// set instead (a cross-send; Outlook.com always receives one).
//
// It reads the credentials directory (providers/requirements.ts) and
// uses only app passwords: an account file without `app_password`
// stops the run before anything connects (exit 3), because the
// providers refuse the account password over SMTP and IMAP and repeated
// refusals can lock the account. It prints set and file names, timings
// and mailbox names, never an address or a secret.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  CredentialsUnavailable,
  deliverHosted,
  HOSTED_PROFILES,
  type MailboxProfile,
  removeHosted,
  resolveRoute,
} from "./providers/hosted_delivery.ts";
import type { MailEndpoint } from "./providers/mail_socket.ts";
import { currentHost, type HostEnv } from "./providers/requirements.ts";

const USAGE = `usage: email-selfsend-smoke SET [--to SET] [--account NAME] [--to-account NAME]
                            [--timeout SECONDS] [--dir DIR]
                            [--endpoints FILE] [--ca FILE]

Sends one small message from the account of SET (its first account
file, or --account NAME for SET/NAME.json) to itself, or to the account
of --to SET, finds it by Message-ID, prints the timings, and removes
every copy. Sets: ${Object.keys(HOSTED_PROFILES).join(", ")}.
A set whose provider accepts no app password (outlook-com) can only
receive: it is sent to from its default sender, or from SET with --to.

The credentials directory is $ISONIM_EMAIL_CREDENTIALS_DIR, defaulting
to \${XDG_CONFIG_HOME:-$HOME/.config}/metacraft/dev-credentials/isonim-email;
--dir overrides both. Only app passwords are used; without one the run
stops before connecting.

--endpoints FILE  JSON {"<set>": {"smtp": {host, port, security}, "imap": {…}}}
                  replacing the providers' servers (local test servers)
--ca FILE         PEM roots to verify the servers with instead of the system's

Exit status: 0 delivered and removed; 1 failed; 2 usage; 3 pending (an
account file has no app_password).
`;

function smokeMessage(): Uint8Array {
  const crlf = (s: string): string => s.replace(/\n/g, "\r\n");
  return new Uint8Array(
    Buffer.from(
      crlf(`From: isonim-email delivery smoke <smoke@invalid>
To: smoke@invalid
Subject: isonim-email delivery smoke
Date: ${new Date().toUTCString().replace("GMT", "+0000")}
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="smoke-boundary"

--smoke-boundary
Content-Type: text/plain; charset=us-ascii

A delivery smoke message. It is removed right after it arrives.
--smoke-boundary
Content-Type: text/html; charset=us-ascii

<!doctype html><html><body><p>A delivery smoke message. It is removed right after it arrives.</p></body></html>
--smoke-boundary--
`),
      "latin1",
    ),
  );
}

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
    process.stdout.write(USAGE);
    return args.length === 0 ? 2 : 0;
  }
  let set: string | undefined;
  let to: string | undefined;
  let account: string | undefined;
  let toAccount: string | undefined;
  let timeoutS = 60;
  let dir: string | null = null;
  let endpoints: string | null = null;
  let ca: string | null = null;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    const value = (): string => {
      const v = args[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === "--to") to = value();
    else if (a === "--account") account = value();
    else if (a === "--to-account") toAccount = value();
    else if (a === "--timeout") timeoutS = Number(value());
    else if (a === "--dir") dir = resolve(value());
    else if (a === "--endpoints") endpoints = resolve(value());
    else if (a === "--ca") ca = resolve(value());
    else if (a.startsWith("-")) {
      process.stderr.write(
        `email-selfsend-smoke: unknown option ${a}\n${USAGE}`,
      );
      return 2;
    } else if (set === undefined) set = a;
    else {
      process.stderr.write(`email-selfsend-smoke: one SET only\n${USAGE}`);
      return 2;
    }
  }
  if (
    set === undefined ||
    !(set in HOSTED_PROFILES) ||
    (to !== undefined && !(to in HOSTED_PROFILES)) ||
    !(timeoutS > 0)
  ) {
    process.stderr.write(
      `email-selfsend-smoke: unknown set or bad timeout\n${USAGE}`,
    );
    return 2;
  }
  const base = currentHost();
  const host: HostEnv =
    dir === null
      ? base
      : { ...base, env: { ...base.env, ISONIM_EMAIL_CREDENTIALS_DIR: dir } };
  const profiles: Record<string, MailboxProfile> = { ...HOSTED_PROFILES };
  if (endpoints !== null) {
    const o = JSON.parse(readFileSync(endpoints, "utf8")) as Record<
      string,
      { smtp: MailEndpoint; imap: MailEndpoint }
    >;
    for (const [k, v] of Object.entries(o))
      if (profiles[k] !== undefined)
        profiles[k] = { ...profiles[k]!, smtp: v.smtp, imap: v.imap };
  }
  const trust = ca === null ? {} : { ca: readFileSync(ca, "utf8") };

  // With --to, SET sends and --to receives; otherwise SET receives (from
  // itself, or from its cross-send sender).
  const receiver = to ?? set;
  const sender = to === undefined ? undefined : set;
  let route;
  try {
    route = resolveRoute(receiver, host, {
      senderSet: sender,
      // --account names SET's account: the sender's with --to or when
      // SET sends to itself, the receiver's otherwise.
      senderAccount:
        to !== undefined || profiles[set]!.smtp !== null ? account : undefined,
      receiverAccount: to === undefined ? account : toAccount,
      profiles,
    });
  } catch (err) {
    if (err instanceof CredentialsUnavailable) {
      process.stdout.write(
        `PENDING: ${err.message}\nNothing was sent and no server was contacted.\n`,
      );
      return 3;
    }
    throw err;
  }
  process.stdout.write(
    `${route.kind === "self" ? "self-send" : "cross-send"}: ${route.sender.file} -> ${route.receiver.file}\n`,
  );
  const opts = {
    run: `smoke-${Date.now().toString(36)}`,
    trust,
    arrivalTimeoutMs: timeoutS * 1000,
  };
  const d = await deliverHosted(smokeMessage(), route, opts);
  process.stdout.write(`  Message-ID ${d.messageId}\n`);
  process.stdout.write(`  submitted in ${Math.round(d.timingMs.submit)} ms\n`);
  if (d.arrival.state === "arrived")
    process.stdout.write(
      `  arrived in ${d.arrival.mailbox} (${d.arrival.role}) after ${Math.round(d.latencyMs)} ms\n`,
    );
  else
    process.stdout.write(
      `  submission confirmed by the sender's ${d.senderCopy?.mailbox ?? "Sent"} copy after ${Math.round(d.latencyMs)} ms; arrival unverified: ${d.arrival.reason}\n`,
    );
  const r = await removeHosted(d, opts);
  for (const x of r.removed)
    process.stdout.write(`  removed ${x.count} from ${x.set}:${x.mailbox}\n`);
  if (r.left !== null) process.stdout.write(`  left: ${r.left}\n`);
  return 0;
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err: unknown) => {
    // Errors from the mail servers are redacted where they are raised.
    process.stderr.write(
      `email-selfsend-smoke: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    process.exitCode = 1;
  },
);
