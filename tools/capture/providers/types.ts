// tools/capture/providers/types.ts — the capture provider interface.
//
// Every way of producing a screenshot is a provider: the local browser
// engines with their emulation transforms today, and later real mail
// clients (desktop clients in a headless compositor, self-hosted and
// hosted webmail, clients in VM guests, a device-farm service). Each one
// is implemented once against CaptureProvider; the harness (harness.ts)
// owns everything common to all of them: routing, requirement and health
// checks, the result cache, the generic provenance fields, the output
// files and the run summary. A provider only renders what the cache
// cannot answer.

export type Sha256 = string;

export type Scheme = "light" | "dark" | "forced-dark";

export type Engine =
  | "webkit"
  | "webkitgtk"
  | "blink"
  | "gecko"
  | "qtwebengine"
  | "litehtml"
  | "word"
  | "unknown";

export interface ViewportSpec {
  name: string;
  width: number;
  dpr: number;
}

export interface ClientDescriptor {
  // What --clients selects: "thunderbird", "roundcube", …; the local
  // browser provider's clients are its engines (chromium, webkit,
  // firefox).
  clientId: string;
  // What --families selects: an audience family, one of the local
  // emulation labels (gmailWeb, wordApprox, chromium-baseline, …), or
  // "verification" for a client that stands in for no audience family.
  family: string;
  engine: Engine;
  // The exact client version, valid after prepare(). It enters the
  // cache key (client_build) and the provenance (client.build), so a
  // client update never serves a stale capture.
  build(): Promise<string>;
  // "any": every CSS width × DPR the matrix asks for.
  viewports: ViewportSpec[] | "any";
  // A requested scheme a client does not list is recorded as
  // not-applicable without calling the provider.
  schemes: Scheme[];
  imagesOff: boolean;
  // True for emulations: the capture approximates a client, it is not
  // one.
  approximation: boolean;
}

interface RequirementBase {
  // Why the provider needs it; printed with an unmet requirement.
  why: string;
}

export type Requirement = RequirementBase &
  (
    | { kind: "binary"; name: string }
    | { kind: "nix" }
    | { kind: "env-dir"; variable: string }
    // Files in the credentials directory (requirements.ts): each entry
    // an exact relative path ("mailgun/sending.json") or "<dir>/*.json",
    // at least one account file directly in <dir>; `fields` lists, per
    // entry, the JSON keys every matching file must carry.
    | {
        kind: "credentials";
        files: string[];
        fields?: Record<string, string[]>;
      }
    | { kind: "host-os"; os: string[] }
    // A shared local service the harness starts once per run for every
    // provider that declares it (services.ts).
    | { kind: "service"; name: ServiceName }
  );

// The shared local services the harness can own: an IMAP server holding
// the messages real clients open, and a loopback server for asset URLs.
export type ServiceName = "imap" | "assets";

// A running shared service, as the providers that declared it see it.
export interface ServiceHandle {
  name: ServiceName;
  // Where it listens, e.g. "imap://127.0.0.1:41143" or
  // "http://127.0.0.1:38211/".
  endpoint: string;
  // Per-run users and passwords the service generated; never read from
  // the credentials directory.
  credentials: Record<string, string> | null;
  detail: Record<string, unknown>;
}

// An IMAP account the imap service created for one capture: a fresh
// user with a generated password and an INBOX of its own. Everything a
// client needs to be configured with it, or a webmail to log in.
export interface ImapAccount {
  user: string;
  password: string;
  host: string;
  port: number;
  // Plain IMAP: the server listens on loopback only and lives only as
  // long as the run.
  tls: "none";
  mailbox: "INBOX";
}

// How the copy injected into IMAP was changed so that a real client
// can load the story's images: every `from` became `to`, which is the
// assets service's base URL followed by `c/<token>/`. The token is
// fresh for each delivery, so every request for the copy's images
// carries it and the service's log attributes each request to the
// capture that made it, also while other captures load the same
// images at once.
export interface AssetRewrite {
  from: string;
  to: string;
  token: string;
  count: number;
}

// One message delivered into an account's INBOX.
export interface Delivery {
  account: ImapAccount;
  // The injected bytes (after any asset rewrite); they carry the
  // per-run port, so they are never compared across runs. The cache
  // key keeps the story's canonical mime_sha256.
  injectedSha256: Sha256;
  bytes: number;
  // null: delivered without the assets service, so the story's images
  // point at a host the client cannot reach.
  assetRewrite: AssetRewrite | null;
  timingMs: { account: number; inject: number };
}

// The running imap service, as a declaring provider sees it
// (ctx.services.imap; narrow it with imapHandle() from
// imap_service.ts).
export interface ImapHandle extends ServiceHandle {
  name: "imap";
  host: string;
  port: number;
  tls: "none";
  // A fresh user with a generated password and an empty INBOX.
  createAccount(): Promise<ImapAccount>;
  // Injects one message into the account's INBOX (or `mailbox`). With
  // `assets`, the story's asset URLs are rewritten to that service
  // first.
  deliver(
    account: ImapAccount,
    mime: Uint8Array,
    opts?: { assets?: AssetsHandle; mailbox?: string },
  ): Promise<Delivery>;
  // createAccount() + deliver(): the one-message mailbox of a capture.
  mailboxFor(
    mime: Uint8Array,
    opts?: { assets?: AssetsHandle },
  ): Promise<Delivery>;
}

// One request the assets service answered or refused.
export interface AssetRequest {
  // The path served, or the full URL / host:port a proxied request
  // asked for.
  url: string;
  status: number;
  // "asset": an asset path; "blocked": a proxied request for anything
  // else, refused.
  kind: "asset" | "blocked";
  // "proxy": the request came through the egress guard (a proxied
  // absolute-form request or a CONNECT); "direct": an ordinary request
  // for a path of this service.
  via: "proxy" | "direct";
  // The delivery token an asset path was requested under (its
  // `/c/<token>/` prefix, stripped from `url`); null for a path
  // without one and for a refused request.
  token: string | null;
}

// The running assets service (ctx.services.assets; narrow it with
// assetsHandle() from assets_service.ts).
export interface AssetsHandle extends ServiceHandle {
  name: "assets";
  // "http://127.0.0.1:<port>/": what the story asset origin is
  // rewritten to, and the HTTP proxy URL of the egress guard.
  baseUrl: string;
  // The origin the stories' MIME uses ("https://x.test/").
  rewriteFrom: string;
  // Every request since the service started, in order. One capture's
  // asset requests are those carrying its delivery's token
  // (requestsFor); refused requests carry none.
  requests(): readonly AssetRequest[];
  // The asset requests made under `token`, in order.
  requestsFor(token: string): AssetRequest[];
}

export type ProviderHealth =
  | { state: "ok" }
  | { state: "degraded"; reason: string }
  | { state: "unavailable"; reason: string };

export interface CaptureRequest {
  // The output base name (<backend>-<family>-<client>-<viewport>-
  // <scheme>-<images>), unique within a run.
  id: string;
  story: string;
  mimeSha256: Sha256;
  provider: string;
  backend: string;
  family: string;
  clientId: string;
  viewport: ViewportSpec;
  scheme: Scheme;
  images: "on" | "off";
}

export interface StoryMessage {
  story: string;
  mime: Uint8Array;
  // The message's rendered HTML part, as the library wrote it, so local
  // engines need not decode the MIME.
  html: string;
}

export interface SessionCtx {
  run: string;
  session: string | null;
  runDir: string;
  // Every request routed to this provider in this run, cache hits
  // included (a provider may warm resources for all of them).
  planned: CaptureRequest[];
  // Gate captures on their Tier-3 DOM assertions.
  assert: boolean;
  // --cold: a fresh client and profile per capture. Without it a
  // provider may keep clients warm between the captures of this run (and
  // only this run: nothing stays warm across runs in-process).
  cold: boolean;
  // The running shared services this provider declared, by name.
  services: Partial<Record<ServiceName, ServiceHandle>>;
}

// The emulation a request applies. transformVersion enters the cache key
// ("" for a real client); detail is recorded as the provenance's
// `emulation` (null for a real client).
export interface Emulation {
  transformVersion: string;
  detail: Record<string, unknown> | null;
}

export interface CaptureResult {
  request: CaptureRequest;
  status: "done" | "failed";
  png?: Uint8Array;
  reason?: string;
  // Provider-specific provenance (timings, network, assertions), merged
  // over the generic fields the harness writes. A `client` object is
  // merged key by key (e.g. client.account); client.id and client.build
  // stay the harness's.
  provenance: Record<string, unknown>;
}

export interface CaptureProvider {
  id: string;
  // Label in output names, index rows and --backends: "a" for the local
  // browser provider; providers without a lettered backend use their id.
  backend: string;
  // Bumped whenever output can change; part of the cache key.
  version: string;
  // Bumped by hand when crop, mask or wait logic changes; part of the
  // cache key.
  adapterVersion: number;
  // How captures reach the client, recorded as `via` in every provenance
  // and in run.json; "local" when unset.
  via?: string;
  // Static: answering needs no tool, so routing and --help work on a
  // host where the provider is unavailable.
  clients(): ClientDescriptor[];
  requirements(): Requirement[];
  health(): Promise<ProviderHealth>;
  prepare(ctx: SessionCtx): Promise<void>;
  emulation(req: CaptureRequest): Emulation;
  capture(
    batch: CaptureRequest[],
    messages: Map<Sha256, StoryMessage>,
    ctx: SessionCtx,
  ): AsyncIterable<CaptureResult>;
  dispose(): Promise<void>;
}
