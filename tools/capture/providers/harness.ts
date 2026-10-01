// tools/capture/providers/harness.ts — routing requests to capture
// providers and running them in-process.
//
// The harness owns what is common to every provider:
// - routing: a request (story × family × viewport × scheme × images) is
//   served by every AVAILABLE provider with a client of that family (and,
//   with --clients, of that client id); --backends narrows the providers
//   by their backend label;
// - availability: a provider's declared requirements are checked first,
//   then its health; an unavailable provider is reported in the run
//   summary with its reason, and a request no available provider can
//   serve fails with that reason — never a silent skip;
// - the result cache, keyed on the capture inputs including provider,
//   provider version, client build and transform version;
// - the generic provenance fields, the PNG and provenance files, and the
//   index rows;
// - concurrency: every provider runs at once, and each result is handed
//   to the caller the moment it lands;
// - shared local services (services.ts): started once per run for the
//   providers that declare them, stopped after the last one is disposed.
// A provider renders only what misses the cache.

import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cacheKey, readCache, writeCache } from "../cache.ts";
import {
  checkRequirements,
  currentHost,
  type HostEnv,
  unmetReason,
} from "./requirements.ts";
import {
  registeredServices,
  RunServices,
  type ServiceRegistry,
  type ServiceRunInfo,
} from "./services.ts";
import type {
  CaptureProvider,
  CaptureRequest,
  CaptureResult,
  ClientDescriptor,
  ProviderHealth,
  Scheme,
  SessionCtx,
  Sha256,
  StoryMessage,
  ViewportSpec,
} from "./types.ts";

// ---------------------------------------------------------------------------
// Shapes a finished run's readers rely on
// ---------------------------------------------------------------------------

export interface LibraryInfo {
  commit: string;
  dirty: boolean;
  tree_hash: string;
}

// One index.json row.
export interface Entry {
  story: string;
  backend: string;
  family: string;
  client: string;
  viewport: string;
  scheme: string;
  images: string;
  png: string | null;
  meta: string | null;
  status: string;
}

// One recorded Tier-3 assertion. pass: null is "not run" — it never
// gates, with or without --assert.
export interface AssertionResult {
  check: string;
  pass: boolean | null;
  detail: string;
}

export interface BlockedEntry {
  url: string;
  reason: string;
}

// A capture's provenance JSON (<story>/<id>.json), as far as readers of
// a finished run rely on it; baseProvenance() below writes it.
export interface Provenance {
  story: string;
  status: string;
  cache: string;
  provider: string;
  provider_version: string;
  client: { id: string; build: string };
  transform_version: string;
  emulation: {
    transform: string;
    chain: { transform: string; version: number }[];
    version: number | null;
  } | null;
  network?: { policy: string; blocked: BlockedEntry[] };
  assertions?: AssertionResult[];
  fail_reason?: string;
  skip_reason?: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// URLs the network policy refused for a capture (from its provenance).
function blockedUrls(meta: Record<string, unknown>): string[] {
  const network = meta.network;
  const blocked = isRecord(network) ? network.blocked : undefined;
  if (!Array.isArray(blocked)) return [];
  const urls: string[] = [];
  for (const b of blocked as unknown[])
    if (isRecord(b) && b.reason === "network") urls.push(String(b.url));
  return urls;
}

// The Tier-3 assertions a provenance recorded; [] when it has none.
function recordedAssertions(meta: Record<string, unknown>): AssertionResult[] {
  const recorded = meta.assertions;
  if (!Array.isArray(recorded)) return [];
  const out: AssertionResult[] = [];
  for (const a of recorded as unknown[])
    if (isRecord(a))
      out.push({
        check: String(a.check),
        pass: typeof a.pass === "boolean" ? a.pass : null,
        detail: String(a.detail),
      });
  return out;
}

// ---------------------------------------------------------------------------
// Registry lookups (static: clients() needs no tool)
// ---------------------------------------------------------------------------

export function servedFamilies(providers: CaptureProvider[]): string[] {
  const out: string[] = [];
  for (const p of providers)
    for (const c of p.clients())
      if (!out.includes(c.family)) out.push(c.family);
  return out;
}

export function servedClients(providers: CaptureProvider[]): string[] {
  const out: string[] = [];
  for (const p of providers)
    for (const c of p.clients())
      if (!out.includes(c.clientId)) out.push(c.clientId);
  return out;
}

export function servedBackends(providers: CaptureProvider[]): string[] {
  return [...new Set(providers.map((p) => p.backend))];
}

// ---------------------------------------------------------------------------
// Availability
// ---------------------------------------------------------------------------

// Requirements first: a provider with an unmet requirement is
// unavailable without its health() being asked. A health() that throws
// is unavailable with the error.
export async function assessProvider(
  provider: CaptureProvider,
  host: HostEnv = currentHost(),
): Promise<ProviderHealth> {
  const unmet = unmetReason(checkRequirements(provider.requirements(), host));
  if (unmet !== null) return { state: "unavailable", reason: unmet };
  try {
    return await provider.health();
  } catch (err) {
    return {
      state: "unavailable",
      reason: `health check failed: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
}

// Assesses every provider concurrently, then starts, once each, the
// shared services the available ones declare; a provider whose service
// is unregistered or fails to start becomes unavailable with that
// reason. The caller hands `services` to executePlan (RunCtx.services),
// which stops them; a caller that never runs the plan stops them itself.
export async function assessProviders(
  providers: CaptureProvider[],
  info: ServiceRunInfo,
  registry: ServiceRegistry = registeredServices(),
  host: HostEnv = currentHost(),
): Promise<{
  availability: Map<string, ProviderHealth>;
  services: RunServices;
}> {
  const availability = new Map<string, ProviderHealth>();
  await Promise.all(
    providers.map(async (p) => {
      availability.set(p.id, await assessProvider(p, host));
    }),
  );
  const services = new RunServices();
  await services.start(providers, availability, registry, info);
  return { availability, services };
}

function isAvailable(h: ProviderHealth | undefined): boolean {
  return h !== undefined && h.state !== "unavailable";
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

export interface MatrixSpec {
  stories: { story: string; mimeSha256: Sha256 }[];
  families: string[];
  clients: string[] | null;
  // null: every registered provider.
  backends: string[] | null;
  viewports: ViewportSpec[];
  schemes: Scheme[];
  images: ("on" | "off")[];
}

export type PlanItem =
  | {
      kind: "capture";
      request: CaptureRequest;
      provider: CaptureProvider;
      descriptor: ClientDescriptor;
    }
  | {
      kind: "not-applicable" | "unserved";
      request: CaptureRequest;
      provider: CaptureProvider;
      descriptor: ClientDescriptor;
      reason: string;
    };

interface Candidate {
  provider: CaptureProvider;
  descriptor: ClientDescriptor;
}

function candidatesFor(
  providers: CaptureProvider[],
  family: string,
  spec: MatrixSpec,
): Candidate[] {
  const out: Candidate[] = [];
  for (const provider of providers) {
    if (spec.backends !== null && !spec.backends.includes(provider.backend))
      continue;
    for (const descriptor of provider.clients()) {
      if (descriptor.family !== family) continue;
      if (spec.clients !== null && !spec.clients.includes(descriptor.clientId))
        continue;
      out.push({ provider, descriptor });
    }
  }
  return out;
}

// The providers the matrix could route to: the ones whose availability
// the run must establish (and report).
export function candidateProviders(
  providers: CaptureProvider[],
  spec: MatrixSpec,
): CaptureProvider[] {
  const ids = new Set<string>();
  for (const family of spec.families)
    for (const c of candidatesFor(providers, family, spec))
      ids.add(c.provider.id);
  return providers.filter((p) => ids.has(p.id));
}

function requestFor(
  c: Candidate,
  story: { story: string; mimeSha256: Sha256 },
  family: string,
  viewport: ViewportSpec,
  scheme: Scheme,
  images: "on" | "off",
): CaptureRequest {
  return {
    id: `${c.provider.backend}-${family}-${c.descriptor.clientId}-${viewport.name}-${scheme}-${images}`,
    story: story.story,
    mimeSha256: story.mimeSha256,
    provider: c.provider.id,
    backend: c.provider.backend,
    family,
    clientId: c.descriptor.clientId,
    viewport,
    scheme,
    images,
  };
}

// Why a client cannot render this variant at all (not-applicable), or
// null when it can.
function variantMismatch(
  c: Candidate,
  viewport: ViewportSpec,
  scheme: Scheme,
  images: "on" | "off",
): string | null {
  const d = c.descriptor;
  const who = `client '${d.clientId}' of ${c.provider.id}`;
  if (!d.schemes.includes(scheme))
    return `${scheme} is not a scheme ${who} renders (it renders: ${d.schemes.join(", ")})`;
  if (images === "off" && !d.imagesOff)
    return `${who} cannot render with images off`;
  if (
    d.viewports !== "any" &&
    !d.viewports.some((v) => v.name === viewport.name)
  )
    return `viewport ${viewport.name} is not one ${who} renders (it renders: ${d.viewports.map((v) => v.name).join(", ")})`;
  return null;
}

export interface RoutePlan {
  items: PlanItem[];
  // Per unavailable provider: requests it would have served that an
  // available provider took instead.
  servedElsewhere: Map<string, number>;
}

// Routes the matrix, in a stable order (stories, families, providers in
// registry order and their clients, viewports, schemes, images). A
// request is captured by every available candidate; when no candidate is
// available, each unavailable candidate contributes one "unserved" item
// carrying its provider's reason, so the failure is a visible row.
export function routeRequests(
  providers: CaptureProvider[],
  availability: Map<string, ProviderHealth>,
  spec: MatrixSpec,
): RoutePlan {
  const items: PlanItem[] = [];
  const servedElsewhere = new Map<string, number>();
  for (const story of spec.stories)
    for (const family of spec.families) {
      const candidates = candidatesFor(providers, family, spec);
      for (const viewport of spec.viewports)
        for (const scheme of spec.schemes)
          for (const images of spec.images) {
            const applicable: Candidate[] = [];
            for (const c of candidates) {
              const mismatch = variantMismatch(c, viewport, scheme, images);
              if (mismatch === null) applicable.push(c);
              else
                items.push({
                  kind: "not-applicable",
                  request: requestFor(
                    c,
                    story,
                    family,
                    viewport,
                    scheme,
                    images,
                  ),
                  provider: c.provider,
                  descriptor: c.descriptor,
                  reason: mismatch,
                });
            }
            const available = applicable.filter((c) =>
              isAvailable(availability.get(c.provider.id)),
            );
            if (available.length > 0) {
              for (const c of applicable)
                if (!available.includes(c))
                  servedElsewhere.set(
                    c.provider.id,
                    (servedElsewhere.get(c.provider.id) ?? 0) + 1,
                  );
              for (const c of available)
                items.push({
                  kind: "capture",
                  request: requestFor(
                    c,
                    story,
                    family,
                    viewport,
                    scheme,
                    images,
                  ),
                  provider: c.provider,
                  descriptor: c.descriptor,
                });
              continue;
            }
            const reasons = applicable.map((c) => {
              const h = availability.get(c.provider.id);
              const why =
                h !== undefined && h.state === "unavailable"
                  ? h.reason
                  : "availability not established";
              return `${c.provider.id} is unavailable: ${why}`;
            });
            for (const c of applicable)
              items.push({
                kind: "unserved",
                request: requestFor(c, story, family, viewport, scheme, images),
                provider: c.provider,
                descriptor: c.descriptor,
                reason: `no available provider serves ${family}${spec.clients !== null ? ` (clients ${spec.clients.join(",")})` : ""}: ${reasons.join("; ")}`,
              });
          }
    }
  return { items, servedElsewhere };
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

export interface RunCtx {
  run: string;
  session: string | null;
  runDir: string;
  library: LibraryInfo;
  cacheRoot: string;
  noCache: boolean;
  assert: boolean;
  // --cold, handed to every provider's session.
  cold: boolean;
  // The run's shared services (started before the plan runs); stopped
  // by executePlan once every provider has been disposed.
  services?: RunServices;
}

export interface ProviderReport {
  id: string;
  backend: string;
  version: string;
  via: string;
  // The session's cold flag as the provider received it; null when the
  // provider never got a session (unavailable, or nothing to capture).
  cold: boolean | null;
  health: ProviderHealth["state"];
  reason: string | null;
  // Rows this provider produced (captures, not-applicable, unserved).
  requests: number;
  // Requests it would have served that another available provider took.
  served_elsewhere: number;
  statuses: Record<string, number>;
  prepare_ms: number;
  wall_ms: number;
}

export interface Finished {
  entry: Entry;
  line: Record<string, unknown>;
}

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

interface Ctx {
  run: RunCtx;
  messages: Map<Sha256, StoryMessage>;
}

function baseProvenance(ctx: RunCtx, item: PlanItem): Record<string, unknown> {
  const { request: req, provider, descriptor } = item;
  const emulation = provider.emulation(req);
  return {
    story: req.story,
    run: ctx.run,
    session: ctx.session,
    library: ctx.library,
    mime_sha256: req.mimeSha256,
    backend: req.backend,
    provider: provider.id,
    provider_version: provider.version,
    family: req.family,
    client: { id: req.clientId, build: "" },
    viewport: { width: req.viewport.width, height: 0, dpr: req.viewport.dpr },
    scheme: req.scheme,
    images: req.images,
    via: provider.via ?? "local",
    adapter_version: provider.adapterVersion,
    // Rows that never reach a capture keep these trivial zeroes; real
    // and failed captures overwrite them (every provenance carries at
    // least total + capture).
    timing_ms: { total: 0, capture: 0 },
    captured_at: new Date().toISOString(),
    cache: "uncached",
    approximation: descriptor.approximation,
    emulation: emulation.detail,
    transform_version: emulation.transformVersion,
    status: "",
  };
}

function finish(
  ctx: RunCtx,
  req: CaptureRequest,
  status: string,
  png: Uint8Array | null,
  meta: Record<string, unknown>,
  reason?: string,
): Finished {
  const storyDir = join(ctx.runDir, req.story);
  const pngRel = png === null ? null : join(req.story, `${req.id}.png`);
  const metaRel = join(req.story, `${req.id}.json`);
  mkdirSync(storyDir, { recursive: true });
  if (png !== null && pngRel !== null)
    writeFileSync(join(ctx.runDir, pngRel), png);
  writeFileSync(
    join(ctx.runDir, metaRel),
    JSON.stringify(meta, null, 2) + "\n",
  );
  const entry: Entry = {
    story: req.story,
    backend: req.backend,
    family: req.family,
    client: req.clientId,
    viewport: req.viewport.name,
    scheme: req.scheme,
    images: req.images,
    png: pngRel,
    meta: metaRel,
    status,
  };
  const line: Record<string, unknown> = { ...entry };
  if (reason !== undefined) line.reason = reason;
  // Requests the network policy refused, on the capture's own line
  // (images-off aborts are the axis working, not news).
  const refused = blockedUrls(meta);
  if (refused.length > 0) line.blocked = refused;
  return { entry, line };
}

function failRow(
  ctx: RunCtx,
  item: PlanItem,
  build: string,
  reason: string,
): Finished {
  const meta = baseProvenance(ctx, item);
  (meta.client as Record<string, string>).build = build;
  meta.status = "failed";
  meta.fail_reason = reason;
  return finish(ctx, item.request, "failed", null, meta, reason);
}

// A row the routing settled without the provider: not-applicable or
// unserved.
function settledRow(ctx: RunCtx, item: PlanItem): Finished {
  if (item.kind === "capture") throw new Error("not a settled item");
  if (item.kind === "unserved") return failRow(ctx, item, "", item.reason);
  const meta = baseProvenance(ctx, item);
  meta.status = "not-applicable";
  meta.skip_reason = item.reason;
  return finish(ctx, item.request, "not-applicable", null, meta, item.reason);
}

function resultRow(
  ctx: RunCtx,
  item: PlanItem,
  build: string,
  ckey: string | null,
  result: CaptureResult,
): Finished {
  const meta = baseProvenance(ctx, item);
  // The provider's fields over the generic ones; its `client` block is
  // merged key by key, and the harness keeps client.id and client.build.
  const { client: providerClient, ...rest } = result.provenance;
  Object.assign(meta, rest);
  meta.client = {
    ...(isRecord(providerClient) ? providerClient : {}),
    id: item.request.clientId,
    build,
  };
  if (result.status === "done") {
    if (result.png === undefined)
      return failRow(ctx, item, build, "provider reported done without a PNG");
    meta.status = "done";
    if (ckey !== null) {
      meta.cache = "miss";
      writeCache(ctx.cacheRoot, ckey, Buffer.from(result.png), meta);
    }
    return finish(ctx, item.request, "done", result.png, meta);
  }
  const reason =
    result.reason ?? "provider reported a failure without a reason";
  meta.status = "failed";
  meta.fail_reason = reason;
  return finish(ctx, item.request, "failed", null, meta, reason);
}

// A cache hit, replayed. --assert gates hits on their RECORDED
// assertions: the key covers the capture inputs, so the DOM, and with
// it the assertion outcomes, is identical to a fresh capture's.
function hitRow(
  ctx: RunCtx,
  req: CaptureRequest,
  hit: { png: Buffer; meta: Record<string, unknown> },
): Finished {
  const recordedFailures = recordedAssertions(hit.meta).filter(
    (a) => a.pass === false,
  );
  if (ctx.assert && recordedFailures.length > 0) {
    const fails = recordedFailures
      .map((a) => `${a.check}: ${a.detail}`)
      .join("; ");
    const reason = `Tier-3 assertion(s) failed (--assert, replayed from cache): ${fails}`;
    const meta = {
      ...hit.meta,
      run: ctx.run,
      session: ctx.session,
      cache: "hit",
      captured_at: new Date().toISOString(),
      status: "failed",
      fail_reason: reason,
    };
    return finish(ctx, req, "failed", null, meta, reason);
  }
  const meta = {
    ...hit.meta,
    run: ctx.run,
    session: ctx.session,
    cache: "hit",
    captured_at: new Date().toISOString(),
  };
  return finish(ctx, req, "done", hit.png, meta);
}

async function runProvider(
  provider: CaptureProvider,
  items: PlanItem[],
  ctx: Ctx,
  report: ProviderReport,
  emit: (f: Finished) => void,
): Promise<void> {
  const t0 = Date.now();
  const planned = items.map((i) => i.request);
  const session: SessionCtx = {
    run: ctx.run.run,
    session: ctx.run.session,
    runDir: ctx.run.runDir,
    planned,
    assert: ctx.run.assert,
    cold: ctx.run.cold,
    services: ctx.run.services?.handlesFor(provider) ?? {},
  };
  report.cold = session.cold;
  try {
    try {
      await provider.prepare(session);
    } catch (err) {
      const reason = `prepare failed: ${err instanceof Error ? err.message : String(err)}`;
      report.health = "unavailable";
      report.reason = reason;
      for (const item of items)
        emit(
          failRow(
            ctx.run,
            item,
            "",
            `${provider.id} is unavailable: ${reason}`,
          ),
        );
      return;
    } finally {
      report.prepare_ms = Date.now() - t0;
    }

    const byId = new Map<
      string,
      { item: PlanItem; build: string; ckey: string | null }
    >();
    const misses: CaptureRequest[] = [];
    for (const item of items) {
      const req = item.request;
      // A provider that throws while describing a request (its client
      // build, its emulation) fails that request visibly; the others,
      // and the other providers, carry on.
      let build: string;
      let ckey: string | null;
      try {
        build = await item.descriptor.build();
        ckey = ctx.run.noCache
          ? null
          : cacheKey({
              mimeSha: req.mimeSha256,
              provider: provider.id,
              providerVersion: provider.version,
              backend: req.backend,
              family: req.family,
              clientId: req.clientId,
              clientBuild: build,
              viewport: req.viewport.name,
              dpr: req.viewport.dpr,
              scheme: req.scheme,
              images: req.images,
              adapterVersion: provider.adapterVersion,
              transformVersion: provider.emulation(req).transformVersion,
            });
      } catch (err) {
        emit(
          failRow(
            ctx.run,
            item,
            "",
            `${provider.id} failed before capture: ${err instanceof Error ? err.message : String(err)}`,
          ),
        );
        continue;
      }
      const hit = ckey === null ? null : readCache(ctx.run.cacheRoot, ckey);
      if (hit !== null) {
        emit(hitRow(ctx.run, req, hit));
        continue;
      }
      byId.set(req.id + "\u0000" + req.story, { item, build, ckey });
      misses.push(req);
    }
    if (misses.length === 0) return;

    try {
      for await (const result of provider.capture(
        misses,
        ctx.messages,
        session,
      )) {
        const k = result.request.id + "\u0000" + result.request.story;
        const pending = byId.get(k);
        if (pending === undefined) continue; // not asked for, or already answered
        // Settled only once its row is written: a row that cannot be
        // written fails with the others below, never vanishes.
        const f = resultRow(
          ctx.run,
          pending.item,
          pending.build,
          pending.ckey,
          result,
        );
        byId.delete(k);
        emit(f);
      }
    } catch (err) {
      const reason = `${provider.id} capture failed: ${err instanceof Error ? err.message : String(err)}`;
      for (const { item, build } of byId.values())
        emit(failRow(ctx.run, item, build, reason));
      byId.clear();
    }
    for (const { item, build } of byId.values())
      emit(
        failRow(
          ctx.run,
          item,
          build,
          `${provider.id} returned no result for this request`,
        ),
      );
  } finally {
    await provider.dispose().catch(() => {});
    report.wall_ms = Date.now() - t0;
  }
}

export function messageMap(
  messages: StoryMessage[],
): Map<Sha256, StoryMessage> {
  return new Map(messages.map((m) => [sha256(m.mime), m]));
}

// Runs a routed plan: settled rows first, then every provider with
// captures concurrently. `emit` is called once per row, as it lands.
// The run's shared services are stopped when every provider is done.
// Returns one report per assessed provider, in registry order.
export async function executePlan(
  providers: CaptureProvider[],
  availability: Map<string, ProviderHealth>,
  plan: RoutePlan,
  messages: Map<Sha256, StoryMessage>,
  run: RunCtx,
  emit: (f: Finished) => void,
): Promise<ProviderReport[]> {
  const reports = new Map<string, ProviderReport>();
  for (const p of providers) {
    const h = availability.get(p.id);
    if (h === undefined) continue;
    reports.set(p.id, {
      id: p.id,
      backend: p.backend,
      version: p.version,
      via: p.via ?? "local",
      cold: null,
      health: h.state,
      reason: h.state === "ok" ? null : h.reason,
      requests: 0,
      served_elsewhere: 0,
      statuses: {},
      prepare_ms: 0,
      wall_ms: 0,
    });
  }
  const count = (providerId: string, f: Finished): void => {
    const r = reports.get(providerId);
    if (r === undefined) return;
    r.requests++;
    r.statuses[f.entry.status] = (r.statuses[f.entry.status] ?? 0) + 1;
  };

  for (const [id, n] of plan.servedElsewhere) {
    const r = reports.get(id);
    if (r !== undefined) r.served_elsewhere = n;
  }

  for (const item of plan.items) {
    if (item.kind === "capture") continue;
    const f = settledRow(run, item);
    count(item.provider.id, f);
    emit(f);
  }

  const ctx: Ctx = { run, messages };
  const work: Promise<void>[] = [];
  for (const provider of providers) {
    const items = plan.items.filter(
      (i) => i.kind === "capture" && i.provider.id === provider.id,
    );
    const report = reports.get(provider.id);
    if (items.length === 0 || report === undefined) continue;
    work.push(
      runProvider(provider, items, ctx, report, (f) => {
        count(provider.id, f);
        emit(f);
      }),
    );
  }
  // allSettled, not all: one provider's failure must not stop the
  // shared services under providers that are still capturing.
  let settled: PromiseSettledResult<void>[] = [];
  try {
    settled = await Promise.allSettled(work);
  } finally {
    // Every provider has been disposed (runProvider's finally): the
    // shared services go last.
    await run.services?.stopAll();
  }
  const failure = settled.find((r) => r.status === "rejected");
  if (failure !== undefined) throw failure.reason;
  return providers.flatMap((p) => {
    const r = reports.get(p.id);
    return r === undefined ? [] : [r];
  });
}

// The provider part of the run summary: one line per provider. An
// unavailable or degraded provider always gets a line naming its reason;
// with every provider available, no line mentions unavailability.
export function providerSummaryLines(reports: ProviderReport[]): string[] {
  return reports.map((r) => {
    const statuses =
      Object.entries(r.statuses)
        .map(([k, v]) => `${v} ${k}`)
        .join(", ") || "no rows";
    const head = `provider ${r.id} (backend ${r.backend}, v${r.version})`;
    if (r.health === "unavailable")
      return (
        `${head} UNAVAILABLE: ${r.reason ?? "no reason given"} — ` +
        `${statuses}` +
        (r.served_elsewhere > 0
          ? `; ${r.served_elsewhere} request(s) of its families served by other providers`
          : "")
      );
    const degraded =
      r.health === "degraded"
        ? ` DEGRADED: ${r.reason ?? "no reason given"} —`
        : ":";
    return `${head}${degraded} ${r.requests} request(s), ${statuses} in ${r.wall_ms} ms`;
  });
}
