// tools/capture/providers/workspace_send.ts — putting a rendered
// message in front of a hosted webmail by sending it from a Google
// Workspace sender through the Gmail API.
//
// The sender is a service account of a Workspace tenant whose
// domain-wide delegation grants https://www.googleapis.com/auth/gmail.send
// and nothing else, acting as one user of the tenant (the `subject`),
// with a sender address that is that user's or one of its send-as
// aliases (`from`). Its credential file (credentials.ts,
// `workspace-sender/<name>.json`) also lists the QA addresses it may
// send to (`allowed_recipients`); any other recipient is refused before
// anything connects. A key with wider delegation is never wanted here:
// the credentials directory is materialised on every machine that runs
// captures, so the key in it must be worth no more than "send mail as
// the test sender".
//
// A delivery: a token by the JWT bearer grant (RFC 7523), signed RS256
// with the service account's key (iss = the service account, sub = the
// subject, scope = gmail.send, aud = the token endpoint, exp = an hour;
// a token request that got no HTTP answer is made once more, never the
// send), then `POST /gmail/v1/users/{subject}/messages/send` with the copy
// hosted_delivery.ts's submittedCopy() builds (From = the sender
// address, To = the QA account, a fresh Message-ID, the run token in
// the subject), base64url-encoded. The receiving mailbox cannot be read
// without IMAP access, so arrival and removal are the webmail adapter's
// (in the UI): the handle says so.
//
// Nothing here prints or carries a secret: the key, the signed
// assertion and the access token are kept out of every error (errors
// are built from the HTTP status and the error fields only, then
// redacted of each), and a WorkspaceSender serialises without its key.

import { Buffer } from "node:buffer";
import { createPrivateKey, createSign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { request } from "node:https";
import { join } from "node:path";
import {
  CREDENTIAL_SETS,
  credentialRequirement,
  credentialSet,
  WORKSPACE_SENDER_SET,
} from "./credentials.ts";
import {
  CredentialsUnavailable,
  type HostedAccount,
  type HostedAssetRewrite,
  type PublicAssets,
  submittedCopy,
} from "./hosted_delivery.ts";
import type { TlsTrust } from "./mail_socket.ts";
import {
  checkRequirement,
  credentialsDir,
  entryMatches,
  type HostEnv,
  inspectCredentialsDir,
} from "./requirements.ts";

export const GMAIL_SEND_SCOPE = "https://www.googleapis.com/auth/gmail.send";
export const GMAIL_METADATA_SCOPE =
  "https://www.googleapis.com/auth/gmail.metadata";

export interface WorkspaceEndpoints {
  // The OAuth token endpoint; also the assertion's audience.
  tokenUrl: string;
  // The Gmail API origin.
  gmailBase: string;
}

// Google's. The key file's own token_uri is not used: the endpoint a
// signed assertion goes to is the harness's choice, not the file's.
export const GOOGLE_ENDPOINTS: WorkspaceEndpoints = {
  tokenUrl: "https://oauth2.googleapis.com/token",
  gmailBase: "https://gmail.googleapis.com",
};

// The operator override: a one-off live check with another service
// account's key file before a dedicated sender exists. Never the
// default, and announced by every command that honours it.
export const OVERRIDE_ENV = {
  key: "ISONIM_EMAIL_WORKSPACE_SENDER_OVERRIDE_KEY",
  subject: "ISONIM_EMAIL_WORKSPACE_SENDER_OVERRIDE_SUBJECT",
  from: "ISONIM_EMAIL_WORKSPACE_SENDER_OVERRIDE_FROM",
} as const;

export class WorkspaceSendError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WorkspaceSendError";
  }
}

// A request that got no HTTP answer at all: no connection, a reset, or
// no answer within the I/O timeout (the only kind a token request
// retries).
export class WorkspaceNetworkError extends WorkspaceSendError {
  constructor(message: string) {
    super(message);
    this.name = "WorkspaceNetworkError";
  }
}

// ---------------------------------------------------------------------------
// The sender
// ---------------------------------------------------------------------------

interface ServiceAccountKey {
  clientEmail: string;
  privateKeyPem: string;
  privateKeyId: string | null;
  key: KeyObject;
}

export interface WorkspaceSender {
  // Where it came from: the credential file (relative to the
  // credentials directory), or "operator override (<path>)".
  source: string;
  override: boolean;
  subject: string;
  from: string;
  allowedRecipients: string[];
  // Non-enumerable: readable, never carried by a spread or JSON.
  readonly serviceAccount: ServiceAccountKey;
  // Non-enumerable: every string an error must never carry.
  readonly secrets: string[];
}

const isAddress = (v: unknown): v is string =>
  typeof v === "string" && /^[^@\s]+@[^@\s]+$/.test(v);

// The service account key: an object with client_email and a PEM
// private_key that parses. Errors name `where` and the field, never a
// value (and never the parser's message, which can quote the input).
function serviceAccountKey(raw: unknown, where: string): ServiceAccountKey {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw))
    throw new CredentialsUnavailable(
      `${where}: key must be the service account's JSON key, as an object`,
    );
  const o = raw as Record<string, unknown>;
  if (!isAddress(o.client_email))
    throw new CredentialsUnavailable(`${where}: key has no client_email`);
  if (typeof o.private_key !== "string" || o.private_key === "")
    throw new CredentialsUnavailable(`${where}: key has no private_key`);
  let key: KeyObject;
  try {
    key = createPrivateKey(o.private_key);
  } catch {
    throw new CredentialsUnavailable(
      `${where}: key's private_key is not a PEM private key`,
    );
  }
  if (key.asymmetricKeyType !== "rsa")
    throw new CredentialsUnavailable(
      `${where}: key's private_key is not an RSA key (RS256 needs one)`,
    );
  return {
    clientEmail: o.client_email,
    privateKeyPem: o.private_key,
    privateKeyId:
      typeof o.private_key_id === "string" && o.private_key_id !== ""
        ? o.private_key_id
        : null,
    key,
  };
}

// The strings to redact: the PEM whole and line by line (a line of
// base64 is what a server or a log would echo), and the key id.
function keySecrets(sa: ServiceAccountKey): string[] {
  const lines = sa.privateKeyPem
    .split(/\r?\n|\\n/)
    .map((l) => l.trim())
    .filter((l) => l.length >= 16 && !l.startsWith("-----"));
  return [
    sa.privateKeyPem,
    ...lines,
    ...(sa.privateKeyId === null ? [] : [sa.privateKeyId]),
  ];
}

function makeSender(
  fields: Omit<WorkspaceSender, "serviceAccount" | "secrets">,
  sa: ServiceAccountKey,
): WorkspaceSender {
  const sender = { ...fields } as WorkspaceSender;
  Object.defineProperty(sender, "serviceAccount", {
    value: sa,
    enumerable: false,
  });
  Object.defineProperty(sender, "secrets", {
    value: keySecrets(sa),
    enumerable: false,
  });
  return sender;
}

function readJson(path: string, label: string): Record<string, unknown> {
  let obj: unknown;
  try {
    obj = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    // Not the parser's message: it quotes the text it failed on.
    throw new CredentialsUnavailable(`${label} cannot be read as JSON`);
  }
  if (obj === null || typeof obj !== "object" || Array.isArray(obj))
    throw new CredentialsUnavailable(`${label} is not a JSON object`);
  return obj as Record<string, unknown>;
}

// The sender from the credentials directory: the first
// workspace-sender file (sorted), or the named one.
export function loadWorkspaceSender(
  host: HostEnv,
  opts: { account?: string } = {},
): WorkspaceSender {
  const set = credentialSet(WORKSPACE_SENDER_SET);
  const state = inspectCredentialsDir(host);
  if (state.problem !== null) throw new CredentialsUnavailable(state.problem);
  const files = entryMatches(set.entry, state).sort();
  const file =
    opts.account === undefined
      ? files[0]
      : files.find((f) => f === `${set.id}/${opts.account}.json`);
  if (file === undefined)
    throw new CredentialsUnavailable(
      opts.account === undefined
        ? `no sender file for ${set.id} in ${credentialsDir(host)}`
        : `no sender file ${set.id}/${opts.account}.json in ${credentialsDir(host)}`,
    );
  const status = checkRequirement(credentialRequirement(set.id), host);
  if (!status.met)
    throw new CredentialsUnavailable(`${set.id}: ${status.detail}`);
  const obj = readJson(join(credentialsDir(host), file), file);
  if (!isAddress(obj.subject))
    throw new CredentialsUnavailable(`${file}: subject is not an address`);
  if (!isAddress(obj.from))
    throw new CredentialsUnavailable(`${file}: from is not an address`);
  const rcpts = obj.allowed_recipients;
  if (
    !Array.isArray(rcpts) ||
    rcpts.length === 0 ||
    !rcpts.every((r) => isAddress(r))
  )
    throw new CredentialsUnavailable(
      `${file}: allowed_recipients must be a non-empty list of addresses`,
    );
  const sa = serviceAccountKey(obj.key, file);
  return makeSender(
    {
      source: file,
      override: false,
      subject: obj.subject,
      from: obj.from,
      allowedRecipients: rcpts as string[],
    },
    sa,
  );
}

// Every account address of the receiving sets in the credentials
// directory: the allow-list of an override sender, which has none of
// its own.
export function qaAddresses(host: HostEnv): string[] {
  const state = inspectCredentialsDir(host);
  if (state.problem !== null) throw new CredentialsUnavailable(state.problem);
  const out: string[] = [];
  for (const set of CREDENTIAL_SETS) {
    if (set.id === WORKSPACE_SENDER_SET || !("address" in set.keys)) continue;
    for (const f of entryMatches(set.entry, state)) {
      let obj: Record<string, unknown>;
      try {
        obj = readJson(join(state.dir, f), f);
      } catch {
        continue;
      }
      if (isAddress(obj.address)) out.push(obj.address);
    }
  }
  return out;
}

// The operator override, when its variables are set; null otherwise.
// Its key file is any service account key; its allow-list is the QA
// accounts of the credentials directory.
export function overrideSender(host: HostEnv): WorkspaceSender | null {
  const path = host.env[OVERRIDE_ENV.key];
  if (path === undefined || path === "") return null;
  const subject = host.env[OVERRIDE_ENV.subject];
  const from = host.env[OVERRIDE_ENV.from];
  if (!isAddress(subject) || !isAddress(from))
    throw new CredentialsUnavailable(
      `${OVERRIDE_ENV.key} is set, so ${OVERRIDE_ENV.subject} and ${OVERRIDE_ENV.from} must be addresses too`,
    );
  const label = `the override key file (${OVERRIDE_ENV.key})`;
  const sa = serviceAccountKey(readJson(path, label), label);
  const allowed = qaAddresses(host);
  if (allowed.length === 0)
    throw new CredentialsUnavailable(
      `the override sends only to QA accounts of the credentials directory, and ${credentialsDir(host)} has none`,
    );
  return makeSender(
    {
      source: `operator override (${OVERRIDE_ENV.key})`,
      override: true,
      subject,
      from,
      allowedRecipients: allowed,
    },
    sa,
  );
}

// ---------------------------------------------------------------------------
// Redaction and HTTPS
// ---------------------------------------------------------------------------

function redact(text: string, secrets: string[]): string {
  let out = text;
  for (const s of [...secrets].sort((a, b) => b.length - a.length))
    if (s.length >= 8) out = out.split(s).join("[redacted]");
  return out;
}

interface HttpResult {
  status: number;
  body: string;
}

function https(
  url: string,
  init: {
    method: "GET" | "POST";
    headers: Record<string, string>;
    body?: string;
    trust?: TlsTrust;
    timeoutMs: number;
    stage: string;
  },
): Promise<HttpResult> {
  const u = new URL(url);
  if (u.protocol !== "https:")
    throw new WorkspaceSendError(
      `${init.stage}: refusing a non-HTTPS endpoint (${u.protocol}//${u.host})`,
    );
  return new Promise((resolve, reject) => {
    const req = request(
      u,
      {
        method: init.method,
        headers: {
          ...init.headers,
          ...(init.body === undefined
            ? {}
            : { "content-length": String(Buffer.byteLength(init.body)) }),
        },
        ca: init.trust?.ca,
        servername: init.trust?.servername,
        timeout: init.timeoutMs,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () =>
          resolve({
            status: res.statusCode ?? 0,
            body: Buffer.concat(chunks).toString("utf8"),
          }),
        );
        res.on("error", reject);
      },
    );
    req.on("timeout", () =>
      req.destroy(
        new WorkspaceNetworkError(
          `${init.stage}: no answer from ${u.host} within ${init.timeoutMs} ms`,
        ),
      ),
    );
    req.on("error", (err) =>
      reject(
        err instanceof WorkspaceSendError
          ? err
          : new WorkspaceNetworkError(
              `${init.stage}: cannot reach ${u.host}: ${(err as NodeJS.ErrnoException).code ?? err.message}`,
            ),
      ),
    );
    if (init.body !== undefined) req.write(init.body);
    req.end();
  });
}

// The error fields of a Google error body, and nothing else from it:
// OAuth's {"error","error_description"} or the API's
// {"error":{"code","status","message"}}.
function errorFields(body: string): {
  code: string | null;
  text: string | null;
} {
  let o: unknown;
  try {
    o = JSON.parse(body);
  } catch {
    return { code: null, text: null };
  }
  if (o === null || typeof o !== "object") return { code: null, text: null };
  const e = (o as Record<string, unknown>).error;
  if (typeof e === "string") {
    const d = (o as Record<string, unknown>).error_description;
    return { code: e, text: typeof d === "string" ? d : null };
  }
  if (e !== null && typeof e === "object") {
    const r = e as Record<string, unknown>;
    return {
      code: typeof r.status === "string" ? r.status : null,
      text: typeof r.message === "string" ? r.message : null,
    };
  }
  return { code: null, text: null };
}

const clip = (s: string, n = 300): string =>
  s.length > n ? `${s.slice(0, n)}…` : s;

// ---------------------------------------------------------------------------
// Token
// ---------------------------------------------------------------------------

export interface WorkspaceOptions {
  endpoints?: WorkspaceEndpoints;
  // Verify the endpoints against these roots instead of the system's
  // (tests).
  trust?: TlsTrust;
  // Per request (default 30 s).
  ioTimeoutMs?: number;
  // The clock, in ms (tests).
  now?: () => number;
  // How long a token request that got no HTTP answer waits before its
  // one retry (default TOKEN_RETRY_MS; tests).
  tokenRetryMs?: number;
}

// A token request that got no HTTP answer is made once more after this.
export const TOKEN_RETRY_MS = 2_000;

const b64url = (b: Buffer | string): string =>
  Buffer.from(b).toString("base64url");

// The signed JWT bearer assertion for a scope.
export function delegationAssertion(
  sender: WorkspaceSender,
  scope: string,
  aud: string,
  nowMs: number,
): string {
  const sa = sender.serviceAccount;
  const iat = Math.floor(nowMs / 1000);
  const header = {
    alg: "RS256",
    typ: "JWT",
    ...(sa.privateKeyId === null ? {} : { kid: sa.privateKeyId }),
  };
  const claims = {
    iss: sa.clientEmail,
    sub: sender.subject,
    scope,
    aud,
    iat,
    exp: iat + 3600,
  };
  const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const signature = createSign("RSA-SHA256").update(input).sign(sa.key);
  return `${input}.${b64url(signature)}`;
}

interface CachedToken {
  token: string;
  expiresAtMs: number;
}

// Tokens per sender and scope, reused until a minute before they expire.
const tokenCache = new WeakMap<WorkspaceSender, Map<string, CachedToken>>();

export async function delegatedToken(
  sender: WorkspaceSender,
  scope: string,
  opts: WorkspaceOptions = {},
): Promise<string> {
  const now = opts.now ?? Date.now;
  const cache = tokenCache.get(sender) ?? new Map<string, CachedToken>();
  tokenCache.set(sender, cache);
  const hit = cache.get(scope);
  if (hit !== undefined && hit.expiresAtMs - 60_000 > now()) return hit.token;

  const ep = opts.endpoints ?? GOOGLE_ENDPOINTS;
  const assertion = delegationAssertion(sender, scope, ep.tokenUrl, now());
  const secrets = [...sender.secrets, assertion];
  const body = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion,
  }).toString();
  // One bounded retry, only of a request that got no HTTP answer (a
  // token is not a provider input: asking again changes nothing but the
  // network's luck); an HTTP answer, a refusal included, is final.
  let res: HttpResult | null = null;
  for (let attempt = 0; res === null; attempt++) {
    try {
      res = await https(ep.tokenUrl, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body,
        trust: opts.trust,
        timeoutMs: opts.ioTimeoutMs ?? 30_000,
        stage: "token",
      });
    } catch (err) {
      if (err instanceof WorkspaceNetworkError && attempt === 0) {
        await new Promise((r) =>
          setTimeout(r, opts.tokenRetryMs ?? TOKEN_RETRY_MS),
        );
        continue;
      }
      const text = redact(
        err instanceof Error ? err.message : String(err),
        secrets,
      );
      throw new WorkspaceSendError(
        attempt > 0 ? `${text} (after one retry)` : text,
      );
    }
  }
  if (res.status === 200) {
    let o: Record<string, unknown> = {};
    try {
      o = JSON.parse(res.body) as Record<string, unknown>;
    } catch {
      // handled below
    }
    if (typeof o.access_token === "string" && o.access_token !== "") {
      const ttl =
        typeof o.expires_in === "number" && o.expires_in > 0
          ? o.expires_in
          : 3600;
      cache.set(scope, {
        token: o.access_token,
        expiresAtMs: now() + ttl * 1000,
      });
      return o.access_token;
    }
    throw new WorkspaceSendError(
      "token: the token endpoint answered 200 without an access_token",
    );
  }
  const f = errorFields(res.body);
  const cause =
    f.code === "unauthorized_client" ||
    f.code === "access_denied" ||
    f.code === "invalid_scope"
      ? `the service account is not authorised for ${scope}: in the Workspace tenant's admin console (Security > API controls > Domain-wide delegation), the service account's client id (in the key) must be listed with exactly that scope`
      : f.code === "invalid_grant"
        ? `the grant was refused: the subject in ${sender.source} must be an active user of the tenant whose delegation lists the service account, and the host clock must be right`
        : `the token endpoint refused the delegated grant for ${scope} (domain-wide delegation for the subject in ${sender.source})`;
  // Redacted before it is shortened, so no secret is cut in two.
  throw new WorkspaceSendError(
    clip(
      redact(
        `token: HTTP ${res.status}${f.code === null ? "" : ` ${f.code}`}${f.text === null ? "" : ` (${f.text})`}: ${cause}`,
        secrets,
      ),
      800,
    ),
  );
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

export interface SentMessage {
  // The Gmail API's id of the sender's Sent copy, and its thread.
  id: string;
  threadId: string | null;
}

async function gmailCall(
  sender: WorkspaceSender,
  scope: string,
  method: "GET" | "POST",
  path: string,
  json: unknown,
  opts: WorkspaceOptions,
  stage: string,
): Promise<Record<string, unknown>> {
  const token = await delegatedToken(sender, scope, opts);
  const secrets = [...sender.secrets, token];
  const ep = opts.endpoints ?? GOOGLE_ENDPOINTS;
  let res: HttpResult;
  try {
    res = await https(`${ep.gmailBase}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        ...(json === undefined ? {} : { "content-type": "application/json" }),
      },
      body: json === undefined ? undefined : JSON.stringify(json),
      trust: opts.trust,
      timeoutMs: opts.ioTimeoutMs ?? 30_000,
      stage,
    });
  } catch (err) {
    throw new WorkspaceSendError(
      redact(err instanceof Error ? err.message : String(err), secrets),
    );
  }
  let o: unknown = null;
  try {
    o = JSON.parse(res.body);
  } catch {
    // handled below
  }
  if (res.status === 200 && o !== null && typeof o === "object")
    return o as Record<string, unknown>;
  const f = errorFields(res.body);
  const hint =
    res.status === 403
      ? `: the token's scope (${scope}) does not allow this, or the sender may not use this From address`
      : "";
  throw new WorkspaceSendError(
    clip(
      redact(
        `${stage}: HTTP ${res.status}${f.code === null ? "" : ` ${f.code}`}${f.text === null ? "" : ` (${f.text})`}${hint}`,
        secrets,
      ),
      800,
    ),
  );
}

const userPath = (subject: string): string =>
  `/gmail/v1/users/${encodeURIComponent(subject)}`;

// Sends the exact bytes as the subject, with the gmail.send scope.
export async function sendRaw(
  sender: WorkspaceSender,
  raw: Uint8Array,
  opts: WorkspaceOptions = {},
): Promise<SentMessage> {
  const o = await gmailCall(
    sender,
    GMAIL_SEND_SCOPE,
    "POST",
    `${userPath(sender.subject)}/messages/send`,
    { raw: Buffer.from(raw).toString("base64url") },
    opts,
    "send",
  );
  if (typeof o.id !== "string" || o.id === "")
    throw new WorkspaceSendError("send: the answer carries no message id");
  return {
    id: o.id,
    threadId: typeof o.threadId === "string" ? o.threadId : null,
  };
}

export interface SentCopy {
  labelIds: string[];
  messageId: string | null;
  from: string | null;
}

// The sender's own copy of a sent message, by its API id: its labels
// and its Message-ID and From headers. Needs gmail.metadata, which the
// dedicated sender is not granted: for an operator's check only.
export async function readSentCopy(
  sender: WorkspaceSender,
  id: string,
  opts: WorkspaceOptions = {},
): Promise<SentCopy> {
  const o = await gmailCall(
    sender,
    GMAIL_METADATA_SCOPE,
    "GET",
    `${userPath(sender.subject)}/messages/${encodeURIComponent(id)}?format=metadata&metadataHeaders=Message-ID&metadataHeaders=From`,
    undefined,
    opts,
    "read-sent",
  );
  const payload = o.payload as
    | { headers?: { name?: unknown; value?: unknown }[] }
    | undefined;
  const header = (name: string): string | null => {
    const h = (payload?.headers ?? []).find(
      (x) =>
        typeof x.name === "string" &&
        x.name.toLowerCase() === name.toLowerCase(),
    );
    return typeof h?.value === "string" ? h.value : null;
  };
  return {
    labelIds: Array.isArray(o.labelIds)
      ? o.labelIds.filter((l): l is string => typeof l === "string")
      : [],
    messageId: header("Message-ID"),
    from: header("From"),
  };
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

export interface WorkspaceDeliveryOptions extends WorkspaceOptions {
  run: string;
  assets?: PublicAssets;
}

export interface WorkspaceDelivery {
  route: "workspace";
  sender: { set: string; source: string; override: boolean };
  receiver: { set: string; file: string; label: string };
  messageId: string;
  subjectToken: string;
  submittedSha256: string;
  bytes: number;
  assetRewrite: HostedAssetRewrite | null;
  // The Gmail API's id of the sender's Sent copy (not the recipient's).
  api: SentMessage;
  // The webmail adapter confirms arrival (Inbox, then Junk/Spam).
  arrival: { state: "unverified"; reason: string };
  // And removes the copy, in the UI.
  receiverCleanup: "webmail";
  timingMs: { send: number; total: number };
}

export function isAllowedRecipient(
  sender: WorkspaceSender,
  address: string,
): boolean {
  const a = address.toLowerCase();
  return sender.allowedRecipients.some((r) => r.toLowerCase() === a);
}

export async function deliverWorkspace(
  mime: Uint8Array,
  sender: WorkspaceSender,
  receiver: HostedAccount,
  opts: WorkspaceDeliveryOptions,
): Promise<WorkspaceDelivery> {
  if (!isAllowedRecipient(sender, receiver.address))
    throw new WorkspaceSendError(
      `refused: the address of ${receiver.file} is not among the allowed recipients of ${sender.source}; nothing was sent`,
    );
  const copy = submittedCopy(mime, {
    run: opts.run,
    fromAddress: sender.from,
    to: receiver.address,
    assets: opts.assets,
  });
  const t0 = performance.now();
  const api = await sendRaw(sender, copy.bytes, opts);
  const t1 = performance.now();
  return {
    route: "workspace",
    sender: {
      set: WORKSPACE_SENDER_SET,
      source: sender.source,
      override: sender.override,
    },
    receiver: {
      set: receiver.set,
      file: receiver.file,
      label: receiver.profile.label,
    },
    messageId: copy.messageId,
    subjectToken: copy.subjectToken,
    submittedSha256: copy.sha256,
    bytes: copy.bytes.byteLength,
    assetRewrite: copy.assetRewrite,
    api,
    arrival: {
      state: "unverified",
      reason: `sent through the Gmail API; the webmail adapter finds the message in ${receiver.profile.label} by its Message-ID or run token (Inbox, then Junk)`,
    },
    receiverCleanup: "webmail",
    timingMs: { send: t1 - t0, total: t1 - t0 },
  };
}
