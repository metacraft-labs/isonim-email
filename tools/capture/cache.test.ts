// tools/capture/cache.test.ts — fixtures for the result cache: key stability
// and sensitivity, write→read roundtrip, read-missing → null, and
// corrupt-JSON → null. Run with:
//   node --test tools/capture/cache.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ADAPTER_VERSION,
  cacheKey,
  cachePaths,
  readCache,
  writeCache,
  type CacheKeyParts,
} from "./cache.ts";

function parts(): CacheKeyParts {
  return {
    mimeSha: "abc123",
    backend: "a",
    family: "gmailWeb",
    clientId: "chromium",
    clientBuild: "build-1",
    viewport: "800x0",
    dpr: 1,
    scheme: "light",
    images: "on",
    adapterVersion: ADAPTER_VERSION,
  };
}

describe("cacheKey", () => {
  it("is stable: same parts → same key", () => {
    assert.equal(cacheKey(parts()), cacheKey(parts()));
  });

  it("is a 64-char lowercase hex sha256", () => {
    assert.match(cacheKey(parts()), /^[0-9a-f]{64}$/);
  });

  it("is sensitive: flipping each part → different key", () => {
    const base = cacheKey(parts());
    const flips: Array<[string, (p: CacheKeyParts) => void]> = [
      ["mimeSha", (p) => (p.mimeSha = "def456")],
      ["backend", (p) => (p.backend = "b")],
      ["family", (p) => (p.family = "outlookWeb")],
      ["clientId", (p) => (p.clientId = "firefox")],
      ["clientBuild", (p) => (p.clientBuild = "build-2")],
      ["viewport", (p) => (p.viewport = "375x0")],
      ["dpr", (p) => (p.dpr = 2)],
      ["scheme", (p) => (p.scheme = "dark")],
      ["images", (p) => (p.images = "off")],
      ["adapterVersion", (p) => (p.adapterVersion = ADAPTER_VERSION + 1)],
    ];
    for (const [name, flip] of flips) {
      const p = parts();
      flip(p);
      assert.notEqual(cacheKey(p), base, `flipping ${name} kept the key`);
    }
  });
});

describe("readCache/writeCache", () => {
  it("roundtrips png bytes + meta through a tmp dir", () => {
    const root = mkdtempSync(join(tmpdir(), "cache-test-"));
    const key = cacheKey(parts());
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01]);
    const meta = { story: "invoiceReady/typical", cache: "miss" };
    writeCache(root, key, png, meta);
    const got = readCache(root, key);
    assert.ok(got, "expected a cache hit after write");
    assert.deepEqual(got.png, png);
    assert.deepEqual(got.meta, meta);
  });

  it("read-missing → null", () => {
    const root = mkdtempSync(join(tmpdir(), "cache-test-"));
    assert.equal(readCache(root, cacheKey(parts())), null);
  });

  it("corrupt-JSON → null", () => {
    const root = mkdtempSync(join(tmpdir(), "cache-test-"));
    const key = cacheKey(parts());
    const paths = cachePaths(root, key);
    mkdirSync(paths.dir, { recursive: true });
    writeFileSync(paths.png, Buffer.from([0x89, 0x50]));
    writeFileSync(paths.meta, "{ not valid json");
    assert.equal(readCache(root, key), null);
  });
});
