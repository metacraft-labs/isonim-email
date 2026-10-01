// tools/capture/providers/providers.test.ts — routing requests to
// capture providers, visible unavailability, the provider fields of the
// cache key and provenance, and concurrent, streamed execution.
//
// Test doubles (justification, per the repository's mock policy): the
// routing, unavailability, caching and concurrency rules are about how
// the harness treats SEVERAL providers, some of them unavailable. Only
// one real provider exists today (the local browser engines), so a
// second provider, and an unavailable one, can only be a test double.
// The doubles are minimal CaptureProvider implementations (FakeProvider
// below) that return fixed PNG bytes; everything else is real: the
// harness, the requirement checks (an unavailable double is made
// unavailable by a requirement on a binary that is not on PATH, checked
// against the real PATH), the result cache and the run directory on
// disk. The real provider's own unavailability is tested without any
// double in unavailable_cli.test.ts. The shared-service lifecycle uses
// a real loopback HTTP server (node:http on 127.0.0.1) as the service,
// and makes it fail to start the real way, by binding a port another
// server already holds; the providers fetch from it over real HTTP.
// Run with:
//   node --test tools/capture/providers/providers.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  assessProviders,
  candidateProviders,
  executePlan,
  type Finished,
  type MatrixSpec,
  messageMap,
  type Provenance,
  providerSummaryLines,
  routeRequests,
  type RunCtx,
} from "./harness.ts";
import type { LocalService, ServiceRegistry } from "./services.ts";
import type {
  CaptureProvider,
  CaptureRequest,
  CaptureResult,
  ClientDescriptor,
  Emulation,
  ProviderHealth,
  Requirement,
  SessionCtx,
  Sha256,
  StoryMessage,
} from "./types.ts";

const MISSING_BINARY = "isonim-email-no-such-capture-tool";

interface FakeClient {
  clientId: string;
  family: string;
  schemes?: ("light" | "dark" | "forced-dark")[];
}

interface FakeOptions {
  id: string;
  backend: string;
  clients: FakeClient[];
  version?: string;
  build?: string;
  transform?: string;
  // A requirement on a binary missing from PATH makes it unavailable.
  missingBinary?: boolean;
  health?: ProviderHealth;
  prepareError?: string;
  // Fail the iterator after this many results.
  throwAfter?: number;
  // Leave this request id unanswered.
  skip?: string;
  // Awaited before the first result is yielded.
  gate?: Promise<void>;
  // Awaited after the first result is yielded, before the second.
  holdSecond?: Promise<void>;
  // Extra provider provenance on every result.
  provenance?: Record<string, unknown>;
  via?: string;
  // Shared services it declares; capture() fetches each one's endpoint.
  services?: ("imap" | "assets")[];
  // Shared event log (prepare/dispose), for lifecycle ordering.
  events?: string[];
  // The client's build() throws this.
  buildError?: string;
  // emulation() throws this.
  emulationError?: string;
  // Called after dispose() has logged.
  onDispose?: () => void;
}

class FakeProvider implements CaptureProvider {
  readonly id: string;
  readonly backend: string;
  readonly version: string;
  readonly adapterVersion = 1;
  readonly calls = { health: 0, prepare: 0, capture: 0, dispose: 0 };
  readonly batches: CaptureRequest[][] = [];
  readonly prepared: CaptureRequest[][] = [];
  readonly sessions: SessionCtx[] = [];
  readonly fetched: string[] = [];
  readonly via?: string;
  private readonly o: FakeOptions;
  constructor(o: FakeOptions) {
    this.o = o;
    this.id = o.id;
    this.backend = o.backend;
    this.version = o.version ?? "1";
    if (o.via !== undefined) this.via = o.via;
  }
  clients(): ClientDescriptor[] {
    return this.o.clients.map((c) => ({
      clientId: c.clientId,
      family: c.family,
      engine: "unknown",
      build: async () => {
        if (this.o.buildError !== undefined) throw new Error(this.o.buildError);
        return this.o.build ?? `${c.clientId}-build-7`;
      },
      viewports: "any",
      schemes: c.schemes ?? ["light", "dark"],
      imagesOff: true,
      approximation: false,
    }));
  }
  requirements(): Requirement[] {
    const services: Requirement[] = (this.o.services ?? []).map((name) => ({
      kind: "service",
      name,
      why: `${this.id} reads from it`,
    }));
    return this.o.missingBinary === true
      ? [
          {
            kind: "binary",
            name: MISSING_BINARY,
            why: "drives the fake client",
          },
          ...services,
        ]
      : [
          { kind: "binary", name: "node", why: "runs the fake client" },
          ...services,
        ];
  }
  async health(): Promise<ProviderHealth> {
    this.calls.health++;
    return this.o.health ?? { state: "ok" };
  }
  async prepare(ctx: SessionCtx): Promise<void> {
    this.calls.prepare++;
    this.o.events?.push(`prepare:${this.id}`);
    this.prepared.push(ctx.planned);
    this.sessions.push(ctx);
    if (this.o.prepareError !== undefined) throw new Error(this.o.prepareError);
  }
  emulation(_req: CaptureRequest): Emulation {
    if (this.o.emulationError !== undefined)
      throw new Error(this.o.emulationError);
    return this.o.transform === undefined
      ? { transformVersion: "", detail: null }
      : {
          transformVersion: this.o.transform,
          detail: { transform: this.o.transform },
        };
  }
  async *capture(
    batch: CaptureRequest[],
    messages: Map<Sha256, StoryMessage>,
    ctx: SessionCtx,
  ): AsyncIterable<CaptureResult> {
    this.calls.capture++;
    this.batches.push(batch);
    if (this.o.gate !== undefined) await this.o.gate;
    // A real request to every declared service.
    for (const handle of Object.values(ctx.services))
      if (handle !== undefined)
        this.fetched.push(await (await fetch(handle.endpoint)).text());
    let n = 0;
    for (const req of batch) {
      if (this.o.throwAfter !== undefined && n === this.o.throwAfter)
        throw new Error("the fake client crashed");
      if (req.id === this.o.skip) continue;
      if (n === 1 && this.o.holdSecond !== undefined) await this.o.holdSecond;
      const html = messages.get(req.mimeSha256)?.html ?? "";
      n++;
      yield {
        request: req,
        status: "done",
        png: Buffer.from(`PNG:${this.id}:${req.id}:${html.length}`),
        provenance: {
          timing_ms: { total: 1, capture: 1 },
          ...this.o.provenance,
        },
      };
    }
  }
  async dispose(): Promise<void> {
    this.calls.dispose++;
    this.o.events?.push(`dispose:${this.id}`);
    this.o.onDispose?.();
  }
}

const STORY_MIME = Buffer.from("Subject: hi\r\n\r\n<p>hi</p>\r\n");
const messages = messageMap([
  { story: "canary", mime: STORY_MIME, html: "<p>hi</p>" },
]);
const STORY_SHA: Sha256 = [...messages.keys()][0] ?? "";

function spec(over: Partial<MatrixSpec> = {}): MatrixSpec {
  return {
    stories: [{ story: "canary", mimeSha256: STORY_SHA }],
    families: ["famA", "famB", "famC"],
    clients: null,
    backends: null,
    viewports: [{ name: "mobile", width: 375, dpr: 3 }],
    schemes: ["light"],
    images: ["on"],
    ...over,
  };
}

// Local provider: famA (c1) and famB (c2). Remote provider: famB (c3)
// and famC (c4) — famC is served by nobody else.
function providers(
  remote: Partial<FakeOptions> = {},
): [FakeProvider, FakeProvider] {
  return [
    new FakeProvider({
      id: "fake-local",
      backend: "fl",
      clients: [
        { clientId: "c1", family: "famA" },
        { clientId: "c2", family: "famB" },
      ],
    }),
    new FakeProvider({
      id: "fake-remote",
      backend: "fr",
      clients: [
        { clientId: "c3", family: "famB" },
        { clientId: "c4", family: "famC" },
      ],
      ...remote,
    }),
  ];
}

interface Outcome {
  rows: Finished[];
  summary: string[];
  dir: string;
  reports: Awaited<ReturnType<typeof executePlan>>;
}

async function runAll(
  ps: CaptureProvider[],
  s: MatrixSpec = spec(),
  over: Partial<RunCtx> = {},
  registry: ServiceRegistry = {},
): Promise<Outcome> {
  const dir = over.runDir ?? mkdtempSync(join(tmpdir(), "providers-test-"));
  const { availability, services } = await assessProviders(
    candidateProviders(ps, s),
    { run: "r1", runDir: dir },
    registry,
  );
  const plan = routeRequests(ps, availability, s);
  const rows: Finished[] = [];
  const reports = await executePlan(
    ps,
    availability,
    plan,
    messages,
    {
      run: "r1",
      session: null,
      runDir: dir,
      library: { commit: "c", dirty: false, tree_hash: "t" },
      cacheRoot: join(dir, ".cache"),
      noCache: true,
      assert: false,
      cold: false,
      services,
      ...over,
    },
    (f) => rows.push(f),
  );
  return { rows, summary: providerSummaryLines(reports), dir, reports };
}

function row(o: Outcome, family: string, client: string): Finished {
  const r = o.rows.find(
    (f) => f.entry.family === family && f.entry.client === client,
  );
  assert.ok(
    r !== undefined,
    `no row for ${family}/${client}: ${JSON.stringify(o.rows.map((f) => f.entry))}`,
  );
  return r;
}

function meta(o: Outcome, f: Finished): Provenance {
  assert.ok(f.entry.meta !== null);
  return JSON.parse(
    readFileSync(join(o.dir, f.entry.meta), "utf8"),
  ) as Provenance;
}

describe("provider routing and unavailability", () => {
  it("routes requests to the providers that serve their clients and fails, with the reason, those only an unavailable provider serves", async () => {
    const [local, remote] = providers({ missingBinary: true });
    const o = await runAll([local, remote]);
    try {
      // famA and famB go to the available local provider.
      assert.equal(row(o, "famA", "c1").entry.status, "done");
      assert.equal(row(o, "famB", "c2").entry.status, "done");
      assert.equal(row(o, "famA", "c1").entry.backend, "fl");
      assert.deepEqual(
        local.batches
          .flat()
          .map((r) => `${r.family}/${r.clientId}`)
          .sort(),
        ["famA/c1", "famB/c2"],
      );
      // The unavailable provider is never prepared or asked to capture,
      // and its health is not asked either: the unmet requirement decides.
      assert.deepEqual(remote.calls, {
        health: 0,
        prepare: 0,
        capture: 0,
        dispose: 0,
      });
      // famC, which only the unavailable provider serves, fails with the reason.
      const famC = row(o, "famC", "c4");
      assert.equal(famC.entry.status, "failed");
      assert.equal(famC.entry.png, null);
      const reason = String(famC.line.reason);
      assert.match(reason, /no available provider serves famC/);
      assert.match(reason, /fake-remote is unavailable/);
      assert.match(reason, new RegExp(`${MISSING_BINARY} is not on PATH`));
      assert.equal(meta(o, famC).fail_reason, reason);
      // famB was served elsewhere: no failed row for the remote's c3.
      assert.equal(
        o.rows.some((f) => f.entry.client === "c3"),
        false,
        "a request another provider served must not fail",
      );
      // The run summary names the unavailable provider and its reason.
      const line = o.summary.find((l) => l.includes("fake-remote"));
      assert.ok(line !== undefined, o.summary.join("\n"));
      assert.match(
        line,
        /UNAVAILABLE: .*isonim-email-no-such-capture-tool is not on PATH/,
      );
      assert.match(line, /1 failed/);
      assert.match(
        line,
        /1 request\(s\) of its families served by other providers/,
      );
      const report = o.reports.find((r) => r.id === "fake-remote");
      assert.equal(report?.health, "unavailable");
    } finally {
      rmSync(o.dir, { recursive: true, force: true });
    }
  });

  it("with every provider available, the run summary lists no unavailability", async () => {
    const [local, remote] = providers();
    const o = await runAll([local, remote]);
    try {
      assert.ok(o.summary.length === 2, o.summary.join("\n"));
      for (const l of o.summary)
        assert.doesNotMatch(l, /unavailable|degraded/i);
      for (const f of o.rows)
        assert.equal(f.entry.status, "done", JSON.stringify(f.entry));
      // famB is served by both providers, each with its own client.
      assert.equal(row(o, "famB", "c2").entry.backend, "fl");
      assert.equal(row(o, "famB", "c3").entry.backend, "fr");
      assert.equal(row(o, "famC", "c4").entry.status, "done");
      assert.equal(o.rows.length, 4);
    } finally {
      rmSync(o.dir, { recursive: true, force: true });
    }
  });

  it("a provider whose health is unavailable, or whose prepare fails, is reported with the reason", async () => {
    const [l1, r1] = providers({
      health: { state: "unavailable", reason: "the guest is powered off" },
    });
    const o1 = await runAll([l1, r1]);
    const [l2, r2] = providers({
      prepareError: "the compositor did not start",
    });
    const o2 = await runAll([l2, r2]);
    try {
      assert.equal(r1.calls.health, 1);
      assert.equal(r1.calls.prepare, 0);
      assert.match(
        String(row(o1, "famC", "c4").line.reason),
        /the guest is powered off/,
      );
      assert.ok(
        o1.summary.some((l) =>
          /fake-remote .*UNAVAILABLE: the guest is powered off/.test(l),
        ),
      );
      // prepare() failed: every request it was given fails, visibly.
      assert.equal(r2.calls.capture, 0);
      assert.equal(r2.calls.dispose, 1);
      for (const c of ["c3", "c4"]) {
        const f = row(o2, c === "c3" ? "famB" : "famC", c);
        assert.equal(f.entry.status, "failed");
        assert.match(
          String(f.line.reason),
          /prepare failed: the compositor did not start/,
        );
      }
      assert.ok(
        o2.summary.some((l) =>
          /fake-remote .*UNAVAILABLE: prepare failed/.test(l),
        ),
      );
    } finally {
      rmSync(o1.dir, { recursive: true, force: true });
      rmSync(o2.dir, { recursive: true, force: true });
    }
  });

  it("degraded providers still capture and are named in the summary", async () => {
    const [local, remote] = providers({
      health: { state: "degraded", reason: "one account out of budget" },
    });
    const o = await runAll([local, remote]);
    try {
      assert.equal(row(o, "famC", "c4").entry.status, "done");
      assert.ok(
        o.summary.some((l) =>
          /fake-remote .*DEGRADED: one account out of budget/.test(l),
        ),
      );
    } finally {
      rmSync(o.dir, { recursive: true, force: true });
    }
  });

  it("--clients and --backends narrow the providers a request routes to", async () => {
    const [l1, r1] = providers();
    const byClient = routeRequests(
      [l1, r1],
      new Map([
        ["fake-local", { state: "ok" }],
        ["fake-remote", { state: "ok" }],
      ]),
      spec({ clients: ["c3"] }),
    );
    assert.deepEqual(
      byClient.items.map(
        (i) => `${i.kind}:${i.request.provider}/${i.request.clientId}`,
      ),
      ["capture:fake-remote/c3"],
    );
    const byBackend = routeRequests(
      [l1, r1],
      new Map([["fake-local", { state: "ok" }]]),
      spec({ backends: ["fl"] }),
    );
    assert.deepEqual(
      byBackend.items.map(
        (i) => `${i.kind}:${i.request.provider}/${i.request.clientId}`,
      ),
      ["capture:fake-local/c1", "capture:fake-local/c2"],
    );
    // Only the providers the matrix can reach are assessed.
    assert.deepEqual(
      candidateProviders([l1, r1], spec({ families: ["famA"] })).map(
        (p) => p.id,
      ),
      ["fake-local"],
    );
  });

  it("a scheme a client does not list is not-applicable without calling the provider", async () => {
    const local = new FakeProvider({
      id: "fake-local",
      backend: "fl",
      clients: [{ clientId: "c1", family: "famA", schemes: ["light"] }],
    });
    const o = await runAll(
      [local],
      spec({ families: ["famA"], schemes: ["light", "forced-dark"] }),
    );
    try {
      const statuses = o.rows
        .map((f) => `${f.entry.scheme}:${f.entry.status}`)
        .sort();
      assert.deepEqual(statuses, ["forced-dark:not-applicable", "light:done"]);
      assert.deepEqual(
        local.batches.flat().map((r) => r.scheme),
        ["light"],
      );
      const na = o.rows.find((f) => f.entry.status === "not-applicable");
      assert.ok(na !== undefined);
      assert.match(
        meta(o, na).skip_reason ?? "",
        /forced-dark is not a scheme client 'c1' of fake-local renders/,
      );
    } finally {
      rmSync(o.dir, { recursive: true, force: true });
    }
  });
});

describe("provider execution", () => {
  it("runs providers concurrently and streams each result as it lands", async () => {
    // The local provider holds its first result until the remote
    // provider's first row has been emitted: run one after the other,
    // or buffer results until the end, and this never completes.
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const local = new FakeProvider({
      id: "fake-local",
      backend: "fl",
      clients: [{ clientId: "c1", family: "famA" }],
      gate,
    });
    const remote = new FakeProvider({
      id: "fake-remote",
      backend: "fr",
      clients: [{ clientId: "c4", family: "famC" }],
    });
    const dir = mkdtempSync(join(tmpdir(), "providers-test-"));
    try {
      const s = spec({ families: ["famA", "famC"] });
      const availability = new Map<string, ProviderHealth>([
        ["fake-local", { state: "ok" }],
        ["fake-remote", { state: "ok" }],
      ]);
      const order: string[] = [];
      const run = executePlan(
        [local, remote],
        availability,
        routeRequests([local, remote], availability, s),
        messages,
        {
          run: "r1",
          session: null,
          runDir: dir,
          library: { commit: "c", dirty: false, tree_hash: "t" },
          cacheRoot: join(dir, ".cache"),
          noCache: true,
          assert: false,
          cold: false,
        },
        (f) => {
          order.push(f.entry.client);
          // The row is on disk when it is handed over.
          assert.ok(f.entry.png !== null && existsSync(join(dir, f.entry.png)));
          if (f.entry.client === "c4") release();
        },
      );
      const timeout = new Promise<"timeout">((r) =>
        setTimeout(() => r("timeout"), 5000).unref(),
      );
      const done = await Promise.race([
        run.then(() => "done" as const),
        timeout,
      ]);
      assert.equal(done, "done", "providers did not run concurrently");
      assert.deepEqual(order, ["c4", "c1"]);
    } finally {
      release();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("records provider, provider_version, client_build and transform_version in provenance and the cache key", async () => {
    const dir = mkdtempSync(join(tmpdir(), "providers-cache-"));
    const cacheRoot = join(dir, "cache");
    const s = spec({ families: ["famA"] });
    const make = (o: Partial<FakeOptions> = {}): FakeProvider =>
      new FakeProvider({
        id: "fake-local",
        backend: "fl",
        clients: [{ clientId: "c1", family: "famA" }],
        transform: "famA@3",
        ...o,
      });
    const once = async (p: FakeProvider): Promise<Outcome> =>
      runAll([p], s, { noCache: false, cacheRoot });
    try {
      const first = make();
      const o1 = await once(first);
      const m1 = meta(o1, row(o1, "famA", "c1"));
      assert.equal(m1.provider, "fake-local");
      assert.equal(m1.provider_version, "1");
      assert.equal(m1.client.build, "c1-build-7");
      assert.equal(m1.transform_version, "famA@3");
      assert.equal(m1.cache, "miss");
      assert.equal(first.calls.capture, 1);

      // Same inputs: a hit, with the provider never asked to capture.
      const again = make();
      const o2 = await once(again);
      assert.equal(meta(o2, row(o2, "famA", "c1")).cache, "hit");
      assert.equal(again.calls.capture, 0);
      assert.deepEqual(
        readFileSync(join(o2.dir, row(o2, "famA", "c1").entry.png ?? "")),
        readFileSync(join(o1.dir, row(o1, "famA", "c1").entry.png ?? "")),
      );

      // Each provider field is in the key: changing it misses.
      for (const [what, p] of [
        [
          "provider",
          new FakeProvider({
            id: "fake-other",
            backend: "fl",
            clients: [{ clientId: "c1", family: "famA" }],
            transform: "famA@3",
          }),
        ],
        ["provider_version", make({ version: "2" })],
        ["client_build", make({ build: "c1-build-8" })],
        ["transform_version", make({ transform: "famA@4" })],
      ] as const) {
        const o = await once(p);
        assert.equal(
          meta(o, row(o, "famA", "c1")).cache,
          "miss",
          `${what} change served a stale capture`,
        );
        assert.equal(p.calls.capture, 1, what);
        rmSync(o.dir, { recursive: true, force: true });
      }
      rmSync(o1.dir, { recursive: true, force: true });
      rmSync(o2.dir, { recursive: true, force: true });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a provider that crashes mid-batch or drops a request fails those requests visibly", async () => {
    const crashing = new FakeProvider({
      id: "fake-local",
      backend: "fl",
      clients: [
        { clientId: "c1", family: "famA" },
        { clientId: "c2", family: "famB" },
      ],
      throwAfter: 1,
    });
    const o1 = await runAll([crashing], spec({ families: ["famA", "famB"] }));
    const dropping = new FakeProvider({
      id: "fake-local",
      backend: "fl",
      clients: [{ clientId: "c1", family: "famA" }],
      skip: "fl-famA-c1-mobile-light-on",
    });
    const o2 = await runAll([dropping], spec({ families: ["famA"] }));
    try {
      assert.equal(row(o1, "famA", "c1").entry.status, "done");
      assert.equal(row(o1, "famB", "c2").entry.status, "failed");
      assert.match(
        String(row(o1, "famB", "c2").line.reason),
        /fake-local capture failed: the fake client crashed/,
      );
      assert.equal(crashing.calls.dispose, 1);
      assert.equal(row(o2, "famA", "c1").entry.status, "failed");
      assert.match(
        String(row(o2, "famA", "c1").line.reason),
        /returned no result/,
      );
    } finally {
      rmSync(o1.dir, { recursive: true, force: true });
      rmSync(o2.dir, { recursive: true, force: true });
    }
  });
});

describe("streaming within one provider", () => {
  it("emits a provider's first result before the provider yields its second", async () => {
    // One provider, one batch of two requests; the second result is held
    // until the harness has emitted the first row. A harness that
    // collects a batch's results before emitting them never completes.
    let release!: () => void;
    const holdSecond = new Promise<void>((r) => (release = r));
    const p = new FakeProvider({
      id: "fake-local",
      backend: "fl",
      clients: [
        { clientId: "c1", family: "famA" },
        { clientId: "c2", family: "famB" },
      ],
      holdSecond,
    });
    const dir = mkdtempSync(join(tmpdir(), "providers-test-"));
    try {
      const s = spec({ families: ["famA", "famB"] });
      const availability = new Map<string, ProviderHealth>([
        ["fake-local", { state: "ok" }],
      ]);
      const order: string[] = [];
      const run = executePlan(
        [p],
        availability,
        routeRequests([p], availability, s),
        messages,
        {
          run: "r1",
          session: null,
          runDir: dir,
          library: { commit: "c", dirty: false, tree_hash: "t" },
          cacheRoot: join(dir, ".cache"),
          noCache: true,
          assert: false,
          cold: false,
        },
        (f) => {
          order.push(f.entry.client);
          assert.ok(f.entry.png !== null && existsSync(join(dir, f.entry.png)));
          release();
        },
      );
      // A referenced timer: a deadlocked run fails here, on this
      // assertion, instead of draining the event loop.
      let timer: NodeJS.Timeout | undefined;
      const timeout = new Promise<"timeout">((r) => {
        timer = setTimeout(() => r("timeout"), 5000);
      });
      const done = await Promise.race([
        run.then(() => "done" as const),
        timeout,
      ]);
      clearTimeout(timer);
      assert.equal(done, "done", "the harness held a provider's batch back");
      assert.equal(p.batches.length, 1);
      assert.equal(p.batches[0]?.length, 2, "both requests in one batch");
      assert.deepEqual(order, ["c1", "c2"]);
    } finally {
      release();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("provider provenance and session", () => {
  it("merges a provider's client provenance key by key, keeps client.id and client.build, and records the provider's via", async () => {
    const remote = new FakeProvider({
      id: "fake-remote",
      backend: "fr",
      clients: [{ clientId: "c4", family: "famC" }],
      via: "inject",
      provenance: {
        client: { account: "qa-account-2", id: "spoofed", build: "spoofed" },
      },
    });
    const local = new FakeProvider({
      id: "fake-local",
      backend: "fl",
      clients: [{ clientId: "c1", family: "famA" }],
    });
    const o = await runAll(
      [local, remote],
      spec({ families: ["famA", "famC"] }),
    );
    try {
      const raw = (f: Finished): Record<string, unknown> =>
        JSON.parse(readFileSync(join(o.dir, f.entry.meta ?? ""), "utf8"));
      const r = raw(row(o, "famC", "c4"));
      assert.deepEqual(r.client, {
        id: "c4",
        build: "c4-build-7",
        account: "qa-account-2",
      });
      assert.equal(r.via, "inject");
      const l = raw(row(o, "famA", "c1"));
      assert.deepEqual(l.client, { id: "c1", build: "c1-build-7" });
      assert.equal(l.via, "local");
      assert.deepEqual(
        o.reports.map((x) => [x.id, x.via]),
        [
          ["fake-local", "local"],
          ["fake-remote", "inject"],
        ],
      );
    } finally {
      rmSync(o.dir, { recursive: true, force: true });
    }
  });

  it("hands --cold to every provider's session", async () => {
    for (const cold of [true, false]) {
      const [local, remote] = providers();
      const o = await runAll([local, remote], spec(), { cold });
      try {
        for (const p of [local, remote]) {
          assert.equal(p.sessions.length, 1, p.id);
          assert.equal(p.sessions[0]?.cold, cold, `${p.id} cold=${cold}`);
        }
        for (const r of o.reports) assert.equal(r.cold, cold, r.id);
      } finally {
        rmSync(o.dir, { recursive: true, force: true });
      }
    }
  });
});

// A real loopback HTTP server as a shared service.
class LoopbackHttpService implements LocalService {
  server: Server | null = null;
  private readonly events: string[];
  private readonly port: number;
  constructor(events: string[], port = 0) {
    this.events = events;
    this.port = port;
  }
  async start(info: { run: string }): Promise<{
    name: "assets";
    endpoint: string;
    credentials: null;
    detail: Record<string, unknown>;
  }> {
    const server = createServer((_req, res) => {
      res.setHeader("connection", "close");
      res.end(`served for ${info.run}`);
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(this.port, "127.0.0.1", () => resolve());
    });
    this.server = server;
    this.events.push("start:assets");
    const { port } = server.address() as AddressInfo;
    return {
      name: "assets",
      endpoint: `http://127.0.0.1:${port}/`,
      credentials: null,
      detail: {},
    };
  }
  async stop(): Promise<void> {
    const server = this.server;
    if (server === null || !server.listening) return;
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
    this.events.push("stop:assets");
  }
}

describe("shared local services", () => {
  it("starts a declared service once for every provider that needs it and stops it after the last provider is disposed", async () => {
    const events: string[] = [];
    const made: LoopbackHttpService[] = [];
    const registry: ServiceRegistry = {
      assets: () => {
        const svc = new LoopbackHttpService(events);
        made.push(svc);
        return svc;
      },
    };
    // Both providers declare the service.
    const both = [
      new FakeProvider({
        id: "fake-local",
        backend: "fl",
        clients: [{ clientId: "c1", family: "famA" }],
        services: ["assets"],
        events,
      }),
      new FakeProvider({
        id: "fake-remote",
        backend: "fr",
        clients: [{ clientId: "c4", family: "famC" }],
        services: ["assets"],
        events,
      }),
    ];
    const o = await runAll(
      both,
      spec({ families: ["famA", "famC"] }),
      {},
      registry,
    );
    try {
      assert.equal(made.length, 1, "one service instance per run");
      assert.equal(events.filter((e) => e === "start:assets").length, 1);
      // Started before any prepare, stopped after every dispose.
      assert.equal(events[0], "start:assets", events.join(","));
      assert.equal(events.at(-1), "stop:assets", events.join(","));
      assert.equal(events.filter((e) => e.startsWith("dispose:")).length, 2);
      // Each provider got the same handle and reached the live server.
      const endpoints = both.map(
        (p) => p.sessions[0]?.services.assets?.endpoint,
      );
      assert.ok(endpoints[0] !== undefined);
      assert.equal(endpoints[0], endpoints[1]);
      for (const p of both) assert.deepEqual(p.fetched, ["served for r1"]);
      for (const f of o.rows) assert.equal(f.entry.status, "done");
      // Stopped: no longer listening.
      assert.equal(made[0]?.server?.listening, false);
      await assert.rejects(fetch(endpoints[0] ?? ""));
    } finally {
      // A harness that leaks the service must fail, not hang the run.
      for (const svc of made) await svc.stop();
      rmSync(o.dir, { recursive: true, force: true });
    }
  });

  it("a service that fails to start, or is not registered, makes every provider that declared it unavailable with the reason", async () => {
    // Hold a port, then make the service bind it: a real EADDRINUSE.
    const blocker = createServer();
    await new Promise<void>((r) => blocker.listen(0, "127.0.0.1", () => r()));
    const port = (blocker.address() as AddressInfo).port;
    const events: string[] = [];
    const registry: ServiceRegistry = {
      assets: () => new LoopbackHttpService(events, port),
    };
    const a = new FakeProvider({
      id: "fake-a",
      backend: "fa",
      clients: [{ clientId: "c1", family: "famA" }],
      services: ["assets"],
    });
    const b = new FakeProvider({
      id: "fake-b",
      backend: "fb",
      clients: [{ clientId: "c4", family: "famC" }],
      services: ["assets"],
    });
    const plain = new FakeProvider({
      id: "fake-plain",
      backend: "fp",
      clients: [{ clientId: "c2", family: "famB" }],
    });
    const o = await runAll([a, b, plain], spec(), {}, registry);
    const imap = new FakeProvider({
      id: "fake-imap",
      backend: "fi",
      clients: [{ clientId: "c1", family: "famA" }],
      services: ["imap"],
    });
    const o2 = await runAll([imap], spec({ families: ["famA"] }), {}, registry);
    try {
      for (const [p, fam, client] of [
        [a, "famA", "c1"],
        [b, "famC", "c4"],
      ] as const) {
        assert.equal(p.calls.prepare, 0, p.id);
        const f = row(o, fam, client);
        assert.equal(f.entry.status, "failed");
        assert.match(
          String(f.line.reason),
          new RegExp(
            `${p.id} is unavailable: service assets failed to start: .*EADDRINUSE.*\\(needed: ${p.id} reads from it\\)`,
          ),
        );
        assert.ok(
          o.summary.some((l) =>
            new RegExp(
              `${p.id} .*UNAVAILABLE: service assets failed to start`,
            ).test(l),
          ),
          o.summary.join("\n"),
        );
      }
      assert.equal(row(o, "famB", "c2").entry.status, "done");
      assert.deepEqual(
        events,
        [],
        "a service that never started is never stopped",
      );
      assert.equal(imap.calls.prepare, 0);
      assert.match(
        String(row(o2, "famA", "c1").line.reason),
        /fake-imap is unavailable: service imap is not registered/,
      );
    } finally {
      blocker.close();
      rmSync(o.dir, { recursive: true, force: true });
      rmSync(o2.dir, { recursive: true, force: true });
    }
  });

  it("keeps a shared service up until every dependent is disposed when one provider fails mid-run", async () => {
    // Provider a fails (its capture crashes, its client build throws,
    // or its emulation() throws even while its failure row is written,
    // which rejects the run); provider b, which shares the service, is
    // held until a has been disposed and only then fetches from the
    // service.
    for (const failure of ["capture", "build", "emulation"] as const) {
      const events: string[] = [];
      const made: LoopbackHttpService[] = [];
      const registry: ServiceRegistry = {
        assets: () => {
          const svc = new LoopbackHttpService(events);
          made.push(svc);
          return svc;
        },
      };
      let release!: () => void;
      const gate = new Promise<void>((r) => (release = r));
      const a = new FakeProvider({
        id: "fake-a",
        backend: "fa",
        clients: [{ clientId: "c1", family: "famA" }],
        services: ["assets"],
        events,
        ...(failure === "capture"
          ? { throwAfter: 0 }
          : failure === "build"
            ? { buildError: "no client build" }
            : { emulationError: "no emulation" }),
        onDispose: () => release(),
      });
      const b = new FakeProvider({
        id: "fake-b",
        backend: "fb",
        clients: [{ clientId: "c4", family: "famC" }],
        services: ["assets"],
        events,
        gate,
      });
      const dir = mkdtempSync(join(tmpdir(), "providers-test-"));
      try {
        let o: Outcome | undefined;
        let err: unknown = null;
        try {
          o = await runAll(
            [a, b],
            spec({ families: ["famA", "famC"] }),
            { runDir: dir, cacheRoot: join(dir, ".cache") },
            registry,
          );
        } catch (e) {
          err = e;
        }
        assert.deepEqual(b.fetched, ["served for r1"], failure);
        assert.deepEqual(b.calls, {
          health: 1,
          prepare: 1,
          capture: 1,
          dispose: 1,
        });
        if (failure === "emulation") {
          // The run reports the provider's error, after the service
          // has outlived every dependent (asserted below).
          assert.match(String(err), /no emulation/);
        } else {
          assert.equal(err, null, failure);
          assert.ok(o !== undefined);
          assert.equal(row(o, "famC", "c4").entry.status, "done", failure);
          assert.equal(row(o, "famA", "c1").entry.status, "failed", failure);
          assert.match(
            String(row(o, "famA", "c1").line.reason),
            failure === "capture"
              ? /fake-a capture failed: the fake client crashed/
              : /fake-a failed before capture: no client build/,
          );
        }
        assert.equal(events.at(-1), "stop:assets", events.join(","));
        assert.ok(
          events.indexOf("dispose:fake-b") < events.indexOf("stop:assets"),
          events.join(","),
        );
      } finally {
        release();
        for (const svc of made) await svc.stop();
        rmSync(dir, { recursive: true, force: true });
      }
    }
  });
});
