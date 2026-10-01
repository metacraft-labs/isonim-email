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
// The same port is also an HTTP proxy that refuses everything: a
// client configured with it as its proxy can fetch the asset paths
// (also when it sends them through the proxy) and nothing else; every
// refused request, CONNECT included, is answered 403 and recorded in
// the request log, so a provider can report the blocked URLs in its
// provenance. It listens on 127.0.0.1 only.

import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo, Socket } from "node:net";
import { dirname, join, resolve } from "node:path";
import { FIXTURE_HOST, resolveFixture } from "../fixture_host.ts";
import type { LocalService, ServiceRunInfo } from "./services.ts";
import type { AssetRequest, AssetsHandle, ServiceHandle } from "./types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
export const STORY_ASSETS_DIR = join(repoRoot, "tests", "stories", "assets");

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
  private readonly assetsDir: string;

  constructor(opts: { assetsDir?: string } = {}) {
    this.assetsDir = opts.assetsDir ?? STORY_ASSETS_DIR;
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
      res.end(req.method === "HEAD" ? undefined : r.body);
    });
    // A CONNECT is a tunnel to somewhere else: always refused.
    server.on("connect", (req: IncomingMessage, socket: Socket) => {
      this.log.push({ url: req.url ?? "", status: 403, kind: "blocked" });
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
          entry: { url: raw, status: 403, kind: "blocked" },
        };
      path = u.pathname;
    }
    if (req.method !== "GET" && req.method !== "HEAD")
      return {
        status: 405,
        contentType: "text/plain",
        body: Buffer.from(`assets: ${req.method ?? "?"} not allowed\n`),
        entry: { url: path, status: 405, kind: "asset" },
      };
    const pathOnly = path.split("?")[0] ?? path;
    const res = resolveFixture(`${FIXTURE_HOST}${pathOnly}`, this.assetsDir);
    return {
      status: res.status,
      contentType: res.contentType,
      body: res.body,
      entry: { url: pathOnly, status: res.status, kind: "asset" },
    };
  }

  async stop(): Promise<void> {
    const server = this.server;
    this.server = null;
    if (server === null) return;
    for (const s of this.sockets) s.destroy();
    await new Promise<void>((ok) => server.close(() => ok()));
  }
}
