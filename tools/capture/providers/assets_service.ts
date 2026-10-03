// tools/capture/providers/assets_service.ts — the `assets` shared
// service: the story images over loopback HTTP for real mail clients,
// and the egress guard for clients Playwright does not drive.
//
// Backend A answers the stories' fixture origin (https://x.test/…)
// inside each browser context. A real client has no such route: the
// copy of a story injected into its mailbox has that origin rewritten
// to this service (mime_rewrite.ts, done by the imap service's
// deliver()). The service answers `/{sha256[0:16]}/{name}` through the
// fixture host's own resolver, so a stale hash or an unknown name is
// the same 404 here as in backend A.
//
// Each injected copy is rewritten to `/c/{token}/{sha256[0:16]}/{name}`
// with a token fresh for that delivery (captureToken()). The service
// strips the token before resolving, so it changes nothing about what
// is served, and records it with the request: a provider attributes
// each request to the capture whose copy made it, also while other
// clients load the same images at the same time. A path without a
// token is still served, and logged with token null.
//
// The same port is also an HTTP proxy that refuses everything: a
// client configured with it as its proxy can fetch the asset paths
// (also when it sends them through the proxy) and nothing else; every
// refused request, CONNECT included, is answered 403 and recorded in
// the request log, so a provider can report the blocked URLs in its
// provenance. It listens on 127.0.0.1 only.
//
// One test-only knob, `bodyDelayMs`: an asset answered 200 sends its
// status and headers at once and its body that many milliseconds
// later, so a test can show that a provider waits for a slow image
// instead of capturing before it has arrived. It is never set outside
// tests (registeredServices() constructs the service without it).

import { randomBytes } from "node:crypto";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo, Socket } from "node:net";
import { dirname, join, resolve } from "node:path";
import {
  DERIVED_ASSETS_DIR,
  FIXTURE_HOST,
  resolveFixture,
} from "../fixture_host.ts";
import type { LocalService, ServiceRunInfo } from "./services.ts";
import type { AssetRequest, AssetsHandle, ServiceHandle } from "./types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
export const STORY_ASSETS_DIR = join(repoRoot, "tests", "stories", "assets");
// The library's built-in images a story publishes to the fixture host
// (the social icons), served beside the story fixtures.
export const LIBRARY_ASSETS_DIR = join(
  repoRoot,
  "src",
  "isonim_email",
  "assets",
  "social",
);

// A fresh delivery token: 16 lowercase hex digits.
export function captureToken(): string {
  return randomBytes(8).toString("hex");
}

// The part of an asset URL a token adds after the service's base URL.
export function tokenPrefix(token: string): string {
  if (!/^[0-9a-f]{16}$/.test(token))
    throw new Error(`assets: malformed delivery token '${token}'`);
  return `c/${token}/`;
}

// Splits `/c/{token}/{rest}` into the token and `/{rest}`; any other
// path has no token.
export function splitCaptureToken(path: string): {
  token: string | null;
  path: string;
} {
  const m = /^\/c\/([0-9a-f]{16})(\/.*)$/.exec(path);
  return m === null ? { token: null, path } : { token: m[1]!, path: m[2]! };
}

export function assetsHandle(h: ServiceHandle | undefined): AssetsHandle {
  if (
    h === undefined ||
    h.name !== "assets" ||
    typeof (h as Partial<AssetsHandle>).requests !== "function"
  )
    throw new Error("the assets service is not running for this provider");
  return h as AssetsHandle;
}

export class AssetsService implements LocalService {
  private server: Server | null = null;
  private readonly log: AssetRequest[] = [];
  private readonly sockets = new Set<Socket>();
  private readonly assetsDir: string | readonly string[];
  private readonly bodyDelayMs: number;
  private readonly timers = new Set<NodeJS.Timeout>();

  constructor(
    opts: { assetsDir?: string | readonly string[]; bodyDelayMs?: number } = {},
  ) {
    this.assetsDir = opts.assetsDir ?? [
      STORY_ASSETS_DIR,
      LIBRARY_ASSETS_DIR,
      DERIVED_ASSETS_DIR,
    ];
    this.bodyDelayMs = opts.bodyDelayMs ?? 0;
  }

  async start(_info: ServiceRunInfo): Promise<AssetsHandle> {
    const server = createServer((req, res) => {
      const r = this.answer(req, server);
      this.log.push(r.entry);
      res.writeHead(r.status, {
        "content-type": r.contentType,
        "content-length": r.body.length,
        "cache-control": "no-store",
      });
      const body = req.method === "HEAD" ? undefined : r.body;
      if (
        this.bodyDelayMs > 0 &&
        r.status === 200 &&
        r.entry.kind === "asset" &&
        body !== undefined
      ) {
        // Headers now (the browser sees the 200), the bytes later.
        res.flushHeaders();
        const t = setTimeout(() => {
          this.timers.delete(t);
          res.end(body);
        }, this.bodyDelayMs);
        this.timers.add(t);
        return;
      }
      res.end(body);
    });
    // A CONNECT is a tunnel to somewhere else: always refused.
    server.on("connect", (req: IncomingMessage, socket: Socket) => {
      this.log.push({
        url: req.url ?? "",
        status: 403,
        kind: "blocked",
        via: "proxy",
        token: null,
      });
      socket.end("HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n");
    });
    server.on("connection", (s: Socket) => {
      this.sockets.add(s);
      s.on("close", () => this.sockets.delete(s));
    });
    this.server = server;
    await new Promise<void>((ok, fail) => {
      server.once("error", fail);
      server.listen(0, "127.0.0.1", () => {
        server.off("error", fail);
        ok();
      });
    });
    const { port } = server.address() as AddressInfo;
    const baseUrl = `http://127.0.0.1:${port}/`;
    const log = this.log;
    return {
      name: "assets",
      endpoint: baseUrl,
      credentials: null,
      detail: { assetsDir: this.assetsDir, rewriteFrom: `${FIXTURE_HOST}/` },
      baseUrl,
      rewriteFrom: `${FIXTURE_HOST}/`,
      requests: () => log,
      requestsFor: (token: string) =>
        log.filter((e) => e.kind === "asset" && e.token === token),
    };
  }

  private answer(
    req: IncomingMessage,
    server: Server,
  ): {
    status: number;
    contentType: string;
    body: Buffer;
    entry: AssetRequest;
  } {
    const raw = req.url ?? "/";
    let path = raw;
    const via = raw.startsWith("/") ? "direct" : "proxy";
    if (!raw.startsWith("/")) {
      // Absolute form: a request sent through the proxy. Only this
      // service's own URLs are answered.
      const { port } = server.address() as AddressInfo;
      let u: URL | null = null;
      try {
        u = new URL(raw);
      } catch {
        u = null;
      }
      const own =
        u !== null &&
        u.protocol === "http:" &&
        (u.hostname === "127.0.0.1" || u.hostname === "localhost") &&
        u.port === String(port);
      if (u === null || !own)
        return {
          status: 403,
          contentType: "text/plain",
          body: Buffer.from(`assets: egress refused: ${raw}\n`),
          entry: {
            url: raw,
            status: 403,
            kind: "blocked",
            via: "proxy",
            token: null,
          },
        };
      path = u.pathname;
    }
    const { token, path: pathOnly } = splitCaptureToken(
      path.split("?")[0] ?? path,
    );
    if (req.method !== "GET" && req.method !== "HEAD")
      return {
        status: 405,
        contentType: "text/plain",
        body: Buffer.from(`assets: ${req.method ?? "?"} not allowed\n`),
        entry: { url: pathOnly, status: 405, kind: "asset", via, token },
      };
    const res = resolveFixture(`${FIXTURE_HOST}${pathOnly}`, this.assetsDir);
    return {
      status: res.status,
      contentType: res.contentType,
      body: res.body,
      entry: { url: pathOnly, status: res.status, kind: "asset", via, token },
    };
  }

  async stop(): Promise<void> {
    const server = this.server;
    this.server = null;
    if (server === null) return;
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    for (const s of this.sockets) s.destroy();
    await new Promise<void>((ok) => server.close(() => ok()));
  }
}
