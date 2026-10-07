// tools/capture/providers/hosted_delivery.ts — putting a rendered
// message in front of a hosted webmail by sending it.
//
// The QA account submits the message to its own address through the
// provider's own SMTP submission server, authenticated with an app
// password (smtp_submit.ts), then finds the delivered copy over the
// provider's IMAP with the same app password (imap_client.ts): by its
// Message-ID, in INBOX and then the Junk mailbox, polling until a
// bounded timeout, and reports the latency. That is real delivery: the
// webmail then shows what any recipient's mailbox shows. After the
// capture, every copy (INBOX, Sent, Junk, All Mail) is moved to Trash
// and expunged there; for Gmail that is what deletes a message, since
// removing it from INBOX only drops a label.
//
// A receiver whose provider accepts no password over SMTP or IMAP
// (Outlook.com) is sent to from another account (a cross-send): the
// submission is confirmed by the sender's Sent copy, arrival is left to
// the webmail adapter (which looks in Inbox and Junk), and so is the
// removal of the receiver's copy; the sender's copies are removed here.
//
// Credentials come from the credentials directory (requirements.ts):
// the account files of the set. Only `app_password` is used over SMTP
// and IMAP; an account file without one is refused before any
// connection, because these providers refuse the account password there
// and repeated refusals can lock the account. No credential is printed,
// written anywhere or carried in an error (mail_socket.ts redacts
// server replies), and a HostedAccount or HostedDelivery serialises
// without its secrets.

import { Buffer } from "node:buffer";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { captureToken, tokenPrefix } from "./assets_service.ts";
import { credentialRequirement, credentialSet } from "./credentials.ts";
import {
  ImapSession,
  specialMailbox,
  type MailboxInfo,
} from "./imap_client.ts";
import type { MailEndpoint, TlsTrust } from "./mail_socket.ts";
import { rewriteAssetOrigin } from "./mime_rewrite.ts";
import {
  checkRequirement,
  credentialsDir,
  entryMatches,
  type HostEnv,
  inspectCredentialsDir,
} from "./requirements.ts";
import { submitMessage } from "./smtp_submit.ts";

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

export interface MailboxProfile {
  // The credential set (credentials.ts) holding the accounts.
  set: string;
  label: string;
  // null: the provider accepts no app password there (the account can
  // neither submit nor be read; it only receives cross-sends).
  smtp: MailEndpoint | null;
  imap: MailEndpoint | null;
  // Names to use when the server marks no special-use mailbox
  // (RFC 6154), in order of preference.
  fallbacks: { sent: string[]; junk: string[]; all: string[]; trash: string[] };
  // The set that sends to this one when it cannot send to itself.
  crossSendFrom?: string;
}

const tls = (host: string, port: number): MailEndpoint => ({
  host,
  port,
  security: "tls",
});

export const HOSTED_PROFILES: Record<string, MailboxProfile> = {
  "gmail-workspace": {
    set: "gmail-workspace",
    label: "Gmail",
    smtp: tls("smtp.gmail.com", 465),
    imap: tls("imap.gmail.com", 993),
    fallbacks: {
      sent: ["[Gmail]/Sent Mail"],
      junk: ["[Gmail]/Spam"],
      all: ["[Gmail]/All Mail"],
      trash: ["[Gmail]/Trash", "[Gmail]/Bin"],
    },
  },
  yahoo: {
    set: "yahoo",
    label: "Yahoo Mail",
    smtp: tls("smtp.mail.yahoo.com", 465),
    imap: tls("imap.mail.yahoo.com", 993),
    fallbacks: {
      sent: ["Sent"],
      junk: ["Bulk", "Bulk Mail", "Spam"],
      all: [],
      trash: ["Trash"],
    },
  },
  aol: {
    set: "aol",
    label: "AOL Mail",
    smtp: tls("smtp.aol.com", 465),
    imap: tls("imap.aol.com", 993),
    fallbacks: {
      sent: ["Sent"],
      junk: ["Bulk", "Bulk Mail", "Spam"],
      all: [],
      trash: ["Trash"],
    },
  },
  "outlook-com": {
    set: "outlook-com",
    label: "Outlook.com",
    // Microsoft accepts no password (or app password) over SMTP or IMAP
    // for consumer accounts since 2024.
    smtp: null,
    imap: null,
    fallbacks: { sent: [], junk: [], all: [], trash: [] },
    crossSendFrom: "gmail-workspace",
  },
};

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

export class CredentialsUnavailable extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CredentialsUnavailable";
  }
}

export interface HostedAccount {
  set: string;
  // The account file, relative to the credentials directory.
  file: string;
  address: string;
  profile: MailboxProfile;
  // Non-enumerable: readable, never carried by a spread or JSON.
  readonly appPassword: string | null;
}

// The first account file of a set (sorted), or the named one.
function accountFile(set: string, host: HostEnv, account?: string): string {
  const state = inspectCredentialsDir(host);
  if (state.problem !== null) throw new CredentialsUnavailable(state.problem);
  const files = entryMatches(credentialSet(set).entry, state).sort();
  const want =
    account === undefined
      ? files[0]
      : files.find((f) => f === `${set}/${account}.json`);
  if (want === undefined)
    throw new CredentialsUnavailable(
      account === undefined
        ? `no account file for ${set} in ${credentialsDir(host)}`
        : `no account file ${set}/${account}.json in ${credentialsDir(host)}`,
    );
  return want;
}

// Loads one account of a set. With `needsAppPassword`, an account file
// without `app_password` is refused here, before anything connects.
// Errors name the file and the key, never a value.
export function loadHostedAccount(
  set: string,
  host: HostEnv,
  opts: {
    account?: string;
    needsAppPassword: boolean;
    profile?: MailboxProfile;
  },
): HostedAccount {
  const profile = opts.profile ?? HOSTED_PROFILES[set];
  if (profile === undefined)
    throw new Error(
      `no hosted mailbox profile for ${set} (known: ${Object.keys(HOSTED_PROFILES).join(", ")})`,
    );
  const status = checkRequirement(credentialRequirement(set), host);
  const file = accountFile(set, host, opts.account);
  let obj: Record<string, unknown>;
  try {
    obj = JSON.parse(
      readFileSync(join(credentialsDir(host), file), "utf8"),
    ) as Record<string, unknown>;
  } catch {
    // Not the parser's message: it quotes the text it failed on.
    throw new CredentialsUnavailable(`${file} cannot be read as JSON`);
  }
  const address = obj.address;
  if (typeof address !== "string" || address === "")
    throw new CredentialsUnavailable(`${file} has no address`);
  const app = obj.app_password;
  const appPassword =
    typeof app === "string" && app !== "" ? app.replace(/\s+/g, "") : null;
  if (opts.needsAppPassword && appPassword === null)
    throw new CredentialsUnavailable(
      `${file} has no app_password: delivery over SMTP and IMAP uses only an app password (the account password is never tried there); create one for the account and add it to the file`,
    );
  if (!status.met) throw new CredentialsUnavailable(`${set}: ${status.detail}`);
  const account = { set, file, address, profile } as HostedAccount;
  Object.defineProperty(account, "appPassword", {
    value: appPassword,
    enumerable: false,
  });
  return account;
}

export interface Route {
  kind: "self" | "cross";
  sender: HostedAccount;
  receiver: HostedAccount;
}

// Who sends to `receiverSet`: the receiving account itself when its
// provider accepts an app password for SMTP, otherwise `senderSet` (or
// the profile's cross-send default).
export function resolveRoute(
  receiverSet: string,
  host: HostEnv,
  opts: {
    senderSet?: string;
    receiverAccount?: string;
    senderAccount?: string;
    profiles?: Record<string, MailboxProfile>;
  } = {},
): Route {
  const profiles = opts.profiles ?? HOSTED_PROFILES;
  const rp = profiles[receiverSet];
  if (rp === undefined)
    throw new Error(`no hosted mailbox profile for ${receiverSet}`);
  const senderSet =
    opts.senderSet ?? (rp.smtp === null ? rp.crossSendFrom : receiverSet);
  if (senderSet === undefined)
    throw new Error(
      `${receiverSet} cannot send to itself and has no cross-send sender configured`,
    );
  const sp = profiles[senderSet];
  if (sp === undefined)
    throw new Error(`no hosted mailbox profile for ${senderSet}`);
  if (sp.smtp === null || sp.imap === null)
    throw new Error(
      `${senderSet} cannot send (its provider accepts no app password over SMTP/IMAP)`,
    );
  const sender = loadHostedAccount(senderSet, host, {
    account: opts.senderAccount,
    needsAppPassword: true,
    profile: sp,
  });
  if (senderSet === receiverSet && opts.receiverAccount === opts.senderAccount)
    return { kind: "self", sender, receiver: sender };
  const receiver = loadHostedAccount(receiverSet, host, {
    account: opts.receiverAccount,
    needsAppPassword: rp.imap !== null,
    profile: rp,
  });
  return { kind: "cross", sender, receiver };
}

// ---------------------------------------------------------------------------
// The submitted copy
// ---------------------------------------------------------------------------

interface HeaderField {
  name: string;
  // The whole field as written, folded lines and CRLF included.
  raw: string;
}

function splitMessage(text: string): {
  fields: HeaderField[];
  eol: string;
  body: string;
} {
  const m = /\r?\n\r?\n/.exec(text);
  if (m === null) throw new Error("the message has no header/body separator");
  const eol = m[0].startsWith("\r\n") ? "\r\n" : "\n";
  const head = text.slice(0, m.index + eol.length);
  const body = text.slice(m.index + m[0].length);
  const fields: HeaderField[] = [];
  for (const line of head.split(/(?<=\n)/)) {
    if (line === "") continue;
    if (/^[ \t]/.test(line) && fields.length > 0) {
      fields[fields.length - 1]!.raw += line;
      continue;
    }
    const n = /^([!-9;-~]+):/.exec(line);
    if (n === null)
      throw new Error(`malformed header line: ${line.slice(0, 40)}`);
    fields.push({ name: n[1]!.toLowerCase(), raw: line });
  }
  return { fields, eol, body };
}

function fieldValue(f: HeaderField): string {
  return f.raw
    .slice(f.raw.indexOf(":") + 1)
    .replace(/\r?\n[ \t]/g, " ")
    .trim();
}

export interface SubmissionHeaders {
  fromAddress: string;
  to: string;
  messageId: string;
  subjectPrefix: string;
}

// The rendered MIME with only its top-level header block changed: From
// becomes the account's address (the display name kept), To the
// receiver, Cc and Bcc go, Message-ID is replaced, Subject gets the
// prefix. Every other byte is kept.
export function prepareSubmission(
  mime: Uint8Array,
  h: SubmissionHeaders,
): Uint8Array {
  const text = Buffer.from(mime).toString("latin1");
  const { fields, eol, body } = splitMessage(text);
  const fromField = fields.find((f) => f.name === "from");
  let display = "";
  if (fromField !== undefined) {
    const m = /^(.*?)\s*<[^<>]*>\s*$/.exec(fieldValue(fromField));
    if (m !== null) display = m[1]!.trim();
  }
  const subjectField = fields.find((f) => f.name === "subject");
  const subject = subjectField === undefined ? "" : fieldValue(subjectField);
  const replacements: Record<string, string> = {
    from: `From: ${display === "" ? h.fromAddress : `${display} <${h.fromAddress}>`}${eol}`,
    to: `To: ${h.to}${eol}`,
    "message-id": `Message-ID: ${h.messageId}${eol}`,
    subject: `Subject: ${h.subjectPrefix}${subject === "" ? "" : ` ${subject}`}${eol}`,
  };
  const dropped = new Set([
    "cc",
    "bcc",
    "sender",
    "return-path",
    "delivered-to",
  ]);
  const out: string[] = [];
  const placed = new Set<string>();
  for (const f of fields) {
    if (dropped.has(f.name)) continue;
    const r = replacements[f.name];
    if (r === undefined) {
      out.push(f.raw);
      continue;
    }
    if (placed.has(f.name)) continue; // a duplicate field goes
    out.push(r);
    placed.add(f.name);
  }
  const missing = Object.keys(replacements)
    .filter((k) => !placed.has(k))
    .map((k) => replacements[k]!);
  if (!fields.some((f) => f.name === "date"))
    missing.push(
      `Date: ${new Date().toUTCString().replace("GMT", "+0000")}${eol}`,
    );
  return new Uint8Array(
    Buffer.from(missing.join("") + out.join("") + eol + body, "latin1"),
  );
}

// A Message-ID unique to one delivery, in the run-token form the
// adapters open: <{run}.{story-hash8}.{nonce}@render-test.{domain}>.
export function deliveryMessageId(
  run: string,
  storyHash8: string,
  senderAddress: string,
): string {
  const domain = senderAddress.slice(senderAddress.lastIndexOf("@") + 1);
  const safeRun = run.replace(/[^A-Za-z0-9_-]/g, "-");
  return `<${safeRun}.${storyHash8}.${randomBytes(6).toString("hex")}@render-test.${domain}>`;
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

export class DeliveryError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DeliveryError";
  }
}

export interface PublicAssets {
  // The story asset origin ("https://x.test/").
  from: string;
  // A publicly reachable base where the content-hashed assets are
  // published, ending in "/".
  baseUrl: string;
  // Put a per-delivery /c/<token>/ prefix in the paths (only when the
  // asset host strips it and logs it).
  token: boolean;
}

export interface HostedAssetRewrite {
  from: string;
  to: string;
  token: string | null;
  count: number;
}

export interface DeliveryOptions {
  run: string;
  // Verify servers against these roots instead of the system's (tests).
  trust?: TlsTrust;
  assets?: PublicAssets;
  // How long to wait for the message to arrive (default 60 s), and
  // between looks (default 1 s).
  arrivalTimeoutMs?: number;
  pollMs?: number;
  // Per network wait (default 30 s).
  ioTimeoutMs?: number;
}

export interface Located {
  // The mailbox's role and its name on the server.
  role: "inbox" | "junk" | "sent";
  mailbox: string;
  uid: number;
}

export interface HostedDelivery {
  route: "self" | "cross";
  sender: { set: string; file: string };
  receiver: { set: string; file: string; label: string };
  messageId: string;
  subjectToken: string;
  submittedSha256: string;
  bytes: number;
  assetRewrite: HostedAssetRewrite | null;
  // Where the message arrived; "unverified" for a receiver without
  // IMAP, which the webmail adapter confirms (Inbox or Junk).
  arrival:
    | ({ state: "arrived" } & Located)
    | { state: "unverified"; reason: string };
  // For a cross-send: the sender's Sent copy that confirmed it.
  senderCopy: Located | null;
  // Who removes the receiver's copy: this module over IMAP, or the
  // webmail adapter in the UI (the copy is left until it does).
  receiverCleanup: "imap" | "webmail";
  latencyMs: number;
  timingMs: { submit: number; arrival: number; total: number };
}

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms));

async function session(
  account: HostedAccount,
  opts: DeliveryOptions,
): Promise<ImapSession> {
  const endpoint = account.profile.imap;
  const pw = account.appPassword;
  if (endpoint === null || pw === null)
    throw new DeliveryError(
      `${account.set}: no IMAP access with an app password`,
    );
  const s = await ImapSession.open(
    endpoint,
    opts.trust,
    [pw],
    opts.ioTimeoutMs ?? 30_000,
  );
  try {
    await s.login(account.address, pw);
  } catch (err) {
    s.close();
    throw err;
  }
  return s;
}

function roles(
  account: HostedAccount,
  boxes: MailboxInfo[],
): Record<"sent" | "junk" | "all" | "trash", string | null> {
  const f = account.profile.fallbacks;
  return {
    sent: specialMailbox(boxes, "\\Sent", f.sent),
    junk: specialMailbox(boxes, "\\Junk", f.junk),
    all: specialMailbox(boxes, "\\All", f.all),
    trash: specialMailbox(boxes, "\\Trash", f.trash),
  };
}

// Polls the mailboxes, in order, for the Message-ID until it is found
// or the timeout passes.
async function waitFor(
  account: HostedAccount,
  messageId: string,
  where: ("inbox" | "junk" | "sent")[],
  opts: DeliveryOptions,
): Promise<Located> {
  const timeout = opts.arrivalTimeoutMs ?? 60_000;
  const poll = opts.pollMs ?? 1000;
  const s = await session(account, opts);
  try {
    const r = roles(account, await s.list());
    const boxes = where.flatMap((role) => {
      const name = role === "inbox" ? "INBOX" : r[role];
      return name === null ? [] : [{ role, name }];
    });
    const t0 = Date.now();
    for (;;) {
      for (const b of boxes) {
        await s.open(b.name, false);
        const uids = await s.searchHeader("Message-ID", messageId);
        if (uids.length > 0)
          return { role: b.role, mailbox: b.name, uid: uids[0]! };
      }
      if (Date.now() - t0 >= timeout)
        throw new DeliveryError(
          `no message with Message-ID ${messageId} in ${boxes.map((b) => b.name).join(" or ")} of ${account.set}/${account.file.split("/").pop()} within ${timeout} ms`,
        );
      await sleep(poll);
    }
  } finally {
    await s.logout();
  }
}

export async function deliverHosted(
  mime: Uint8Array,
  route: Route,
  opts: DeliveryOptions,
): Promise<HostedDelivery> {
  const { sender, receiver } = route;
  const storyHash8 = createHash("sha256")
    .update(mime)
    .digest("hex")
    .slice(0, 8);
  const safeRun = opts.run.replace(/[^A-Za-z0-9_-]/g, "-");
  const subjectToken = `[es:${safeRun}:${storyHash8}]`;
  const messageId = deliveryMessageId(opts.run, storyHash8, sender.address);

  let body = mime;
  let assetRewrite: HostedAssetRewrite | null = null;
  if (opts.assets !== undefined) {
    const token = opts.assets.token ? captureToken() : null;
    const to = `${opts.assets.baseUrl}${token === null ? "" : tokenPrefix(token)}`;
    const r = rewriteAssetOrigin(mime, opts.assets.from, to);
    body = r.bytes;
    assetRewrite = { from: opts.assets.from, to, token, count: r.count };
  }
  const submitted = prepareSubmission(body, {
    fromAddress: sender.address,
    to: receiver.address,
    messageId,
    subjectPrefix: subjectToken,
  });

  const smtp = sender.profile.smtp;
  const pw = sender.appPassword;
  if (smtp === null || pw === null)
    throw new DeliveryError(`${sender.set} cannot submit`);
  const t0 = performance.now();
  await submitMessage({
    endpoint: smtp,
    trust: opts.trust,
    user: sender.address,
    password: pw,
    mailFrom: sender.address,
    rcptTo: [receiver.address],
    message: submitted,
    timeoutMs: opts.ioTimeoutMs,
  });
  const tSubmitted = performance.now();

  let arrival: HostedDelivery["arrival"];
  let senderCopy: Located | null = null;
  if (receiver.profile.imap !== null && receiver.appPassword !== null) {
    const at = await waitFor(receiver, messageId, ["inbox", "junk"], opts);
    arrival = { state: "arrived", ...at };
  } else {
    senderCopy = await waitFor(sender, messageId, ["sent"], opts);
    arrival = {
      state: "unverified",
      reason: `${receiver.profile.label} has no IMAP access with an app password: the webmail adapter finds the message by its run token in Inbox or Junk`,
    };
  }
  const tArrived = performance.now();
  const delivery: HostedDelivery = {
    route: route.kind,
    sender: { set: sender.set, file: sender.file },
    receiver: {
      set: receiver.set,
      file: receiver.file,
      label: receiver.profile.label,
    },
    messageId,
    subjectToken,
    submittedSha256: createHash("sha256").update(submitted).digest("hex"),
    bytes: submitted.byteLength,
    assetRewrite,
    arrival,
    senderCopy,
    receiverCleanup: receiver.profile.imap !== null ? "imap" : "webmail",
    latencyMs: tArrived - tSubmitted,
    timingMs: {
      submit: tSubmitted - t0,
      arrival: tArrived - tSubmitted,
      total: tArrived - t0,
    },
  };
  // The accounts, for removal; not serialised.
  Object.defineProperty(delivery, "accounts", {
    value: { sender, receiver },
    enumerable: false,
  });
  return delivery;
}

export interface RemovalReport {
  // Per account set and mailbox: how many copies were found and removed.
  removed: { set: string; mailbox: string; count: number }[];
  // The receiver's copy left for the webmail adapter, if any.
  left: string | null;
}

// Removes every copy of the Message-ID from an account: INBOX, Sent,
// Junk and All Mail moved to Trash, then expunged from Trash.
export async function removeCopies(
  account: HostedAccount,
  messageId: string,
  opts: DeliveryOptions,
): Promise<RemovalReport["removed"]> {
  const s = await session(account, opts);
  const removed: RemovalReport["removed"] = [];
  try {
    const r = roles(account, await s.list());
    const seen = new Set<string>();
    for (const name of ["INBOX", r.sent, r.junk, r.all]) {
      if (name === null || name === r.trash || seen.has(name)) continue;
      seen.add(name);
      await s.open(name, true);
      const uids = await s.searchHeader("Message-ID", messageId);
      if (uids.length === 0) continue;
      if (r.trash !== null) await s.move(uids, r.trash);
      else await s.expungeUids(uids);
      removed.push({ set: account.set, mailbox: name, count: uids.length });
    }
    if (r.trash !== null) {
      await s.open(r.trash, true);
      const uids = await s.searchHeader("Message-ID", messageId);
      await s.expungeUids(uids);
      removed.push({ set: account.set, mailbox: r.trash, count: uids.length });
    }
  } finally {
    await s.logout();
  }
  return removed;
}

export async function removeHosted(
  d: HostedDelivery,
  opts: DeliveryOptions,
): Promise<RemovalReport> {
  const accounts = (
    d as unknown as {
      accounts?: { sender: HostedAccount; receiver: HostedAccount };
    }
  ).accounts;
  if (accounts === undefined)
    throw new DeliveryError(
      "this delivery carries no accounts to remove it with",
    );
  const removed = await removeCopies(accounts.sender, d.messageId, opts);
  if (d.route === "cross" && d.receiverCleanup === "imap")
    removed.push(...(await removeCopies(accounts.receiver, d.messageId, opts)));
  return {
    removed,
    left:
      d.receiverCleanup === "webmail"
        ? `the ${d.receiver.label} copy (${d.messageId}) is left for the webmail adapter to delete`
        : null,
  };
}
