// tools/capture/providers/assets_service.test.ts — the `assets` shared
// service: the story images over loopback HTTP, answered exactly as the
// fixture host answers them, and the egress guard proxy that refuses
// everything else.
//
// The real service on a real loopback port, real HTTP requests (fetch,
// and raw proxy-form requests over a socket), and the real
// tests/stories/assets/ files. No mocks. Run with:
//   node --test tools/capture/providers/assets_service.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { connect } from "node:net";
import { join } from "node:path";
import { FIXTURE_HOST, resolveFixture } from "../fixture_host.ts";
import { AssetsService, STORY_ASSETS_DIR } from "./assets_service.ts";
import type { AssetsHandle } from "./types.ts";

function hashedPath(name: string): string {
  const sha = createHash("sha256")
    .update(readFileSync(join(STORY_ASSETS_DIR, name)))
    .digest("hex");
  return `/${sha.slice(0, 16)}/${name}`;
}

// One raw HTTP/1.1 exchange; returns the status code.
function raw(port: number, request: string): Promise<number> {
  return new Promise((ok, fail) => {
    const s = connect({ host: "127.0.0.1", port }, () => s.write(request));
    let buf = "";
    s.on("data", (d: Buffer) => {
      buf += d.toString("latin1");
      const m = /^HTTP\/1\.1 (\d{3})/.exec(buf);
      if (m !== null) {
        s.destroy();
        ok(Number(m[1]));
      }
    });
    s.on("error", fail);
    s.setTimeout(5000, () => {
      s.destroy();
      fail(new Error(`no response to ${request.split("\r\n")[0]}`));
    });
  });
}

const service = new AssetsService();
let h: AssetsHandle;
let port = 0;
before(async () => {
  h = await service.start({ run: "assets-test", runDir: "/nonexistent" });
  port = Number(new URL(h.baseUrl).port);
});
after(() => service.stop());

describe("assets service", () => {
  it("listens on loopback and rewrites the fixture origin to itself", () => {
    assert.match(h.baseUrl, /^http:\/\/127\.0\.0\.1:\d+\/$/);
    assert.equal(h.endpoint, h.baseUrl);
    assert.equal(h.rewriteFrom, `${FIXTURE_HOST}/`);
    assert.equal(h.credentials, null);
  });

  it("serves each story image at its content-hashed path with the fixture's bytes", async () => {
    for (const name of ["logo.png", "shield.png"]) {
      const res = await fetch(`${h.baseUrl}${hashedPath(name).slice(1)}`);
      assert.equal(res.status, 200);
      assert.equal(res.headers.get("content-type"), "image/png");
      assert.deepEqual(
        Buffer.from(await res.arrayBuffer()),
        readFileSync(join(STORY_ASSETS_DIR, name)),
      );
    }
  });

  it("gives a stale hash, an unknown name and a malformed path the fixture host's own 404s", async () => {
    const good = hashedPath("logo.png");
    for (const path of [
      good.replace(/^\/[0-9a-f]{16}\//, "/0000000000000000/"), // stale
      good.replace("logo.png", "nope.png"), // unknown
      good.replace("logo.png", "shield.png"), // another file's hash
      "/logo.png", // no hash
      "/0123456789abcdef/.hidden",
      "/0123456789abcdef/%2e%2e%2fflake.nix",
    ]) {
      const res = await fetch(`${h.baseUrl}${path.slice(1)}`);
      const want = resolveFixture(`${FIXTURE_HOST}${path}`, STORY_ASSETS_DIR);
      assert.equal(want.status, 404, path);
      assert.equal(res.status, 404, path);
      assert.equal(
        Buffer.from(await res.arrayBuffer()).toString(),
        want.body.toString(),
        path,
      );
    }
  });

  it("as a proxy, refuses every request but its own asset paths and logs each refusal", async () => {
    const before = h.requests().length;
    // Proxy-form requests for elsewhere, and a CONNECT tunnel.
    assert.equal(
      await raw(
        port,
        "GET http://example.com/a.png HTTP/1.1\r\nHost: example.com\r\n\r\n",
      ),
      403,
    );
    assert.equal(
      await raw(
        port,
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
      ),
      403,
    );
    assert.equal(
      await raw(
        port,
        `GET http://127.0.0.1:${port + 1}${hashedPath("logo.png")} HTTP/1.1\r\nHost: x\r\n\r\n`,
      ),
      403,
      "another loopback port is elsewhere too",
    );
    // Its own asset URL, sent through the proxy, is served.
    assert.equal(
      await raw(
        port,
        `GET http://127.0.0.1:${port}${hashedPath("logo.png")} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`,
      ),
      200,
    );
    assert.deepEqual(
      h
        .requests()
        .slice(before)
        .map((r) => [r.kind, r.status, r.url]),
      [
        ["blocked", 403, "http://example.com/a.png"],
        ["blocked", 403, "example.com:443"],
        [
          "blocked",
          403,
          `http://127.0.0.1:${port + 1}${hashedPath("logo.png")}`,
        ],
        ["asset", 200, hashedPath("logo.png")],
      ],
    );
  });

  it("is gone after stop", async () => {
    const s = new AssetsService();
    const hh = await s.start({ run: "assets-stop", runDir: "/nonexistent" });
    await s.stop();
    await assert.rejects(fetch(hh.baseUrl));
  });
});
