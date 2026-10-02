// tools/capture/cache.test.ts — fixtures for the result cache: key stability
// and sensitivity, the transform version in the key (a bumped transform
// misses, an unchanged one hits), write→read roundtrip, read-missing →
// null, and corrupt-JSON → null. Run with:
//   node --test tools/capture/cache.test.ts

import { after, describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cacheKey,
  cachePaths,
  readCache,
  writeCache,
  type CacheKeyParts,
} from "./cache.ts";
import {
  TRANSFORMS,
  transformChain,
  transformVersion,
  type TransformRegistry,
} from "./transforms.ts";
import {
  BROWSER_EMULATION_ADAPTER_VERSION as ADAPTER_VERSION,
  BROWSER_EMULATION_ID as PROVIDER_ID,
  BROWSER_EMULATION_VERSION as PROVIDER_VERSION,
} from "./providers/browser_emulation.ts";

// Every scratch directory this file makes is under one temp dir, removed
// when the file's tests are done.
const scratch = mkdtempSync(join(tmpdir(), "cache-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

function parts(): CacheKeyParts {
  return {
    mimeSha: "abc123",
    provider: PROVIDER_ID,
    providerVersion: PROVIDER_VERSION,
    backend: "a",
    family: "gmailWeb",
    clientId: "chromium",
    clientBuild: "build-1",
    viewport: "800x0",
    dpr: 1,
    scheme: "light",
    images: "on",
    adapterVersion: ADAPTER_VERSION,
    transformVersion: transformVersion(transformChain("gmailWeb", "on")),
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
      ["provider", (p) => (p.provider = "linux-desktop")],
      ["providerVersion", (p) => (p.providerVersion = `${PROVIDER_VERSION}.1`)],
      ["transformVersion", (p) => (p.transformVersion = "gmailWeb@999")],
    ];
    for (const [name, flip] of flips) {
      const p = parts();
      flip(p);
      assert.notEqual(cacheKey(p), base, `flipping ${name} kept the key`);
    }
  });
});

describe("the transform version in the key", () => {
  // A registry identical to the real one except for one transform's
  // version: what a transform change looks like to the cache.
  function bumped(name: string): TransformRegistry {
    const registry: TransformRegistry = TRANSFORMS;
    const t = registry[name];
    if (t === undefined) throw new Error(`no transform named ${name}`);
    return { ...TRANSFORMS, [name]: { ...t, version: t.version + 1 } };
  }

  it("names the chain: family transform, then imagesOff for images=off", () => {
    const v = (family: string, images: string): string =>
      transformVersion(transformChain(family, images));
    const g = TRANSFORMS.gmailWeb.version;
    const i = TRANSFORMS.imagesOff.version;
    assert.equal(v("apple", "on"), "");
    assert.equal(v("gmailWeb", "on"), `gmailWeb@${g}`);
    assert.equal(v("apple", "off"), `imagesOff@${i}`);
    assert.equal(v("gmailWeb", "off"), `gmailWeb@${g}+imagesOff@${i}`);
    // The imagesOff family is its own images-off view: never twice.
    assert.equal(v("imagesOff", "off"), `imagesOff@${i}`);
    assert.equal(v("imagesOff", "on"), `imagesOff@${i}`);
  });

  it("a bumped transform misses; an unchanged one hits", () => {
    const root = mkdtempSync(join(scratch, "cache-test-"));
    const cases: [family: string, images: string, transform: string][] = [
      ["gmailWeb", "on", "gmailWeb"],
      ["ganga", "on", "ganga"],
      ["outlookWeb", "on", "outlookWeb"],
      ["wordApprox", "on", "wordApprox"],
      ["imagesOff", "on", "imagesOff"],
      // images=off layers imagesOff on any family, raw ones included.
      ["apple", "off", "imagesOff"],
      ["gmailWeb", "off", "imagesOff"],
    ];
    for (const [family, images, transform] of cases) {
      const key = (registry: TransformRegistry = TRANSFORMS): string =>
        cacheKey({
          ...parts(),
          family,
          images,
          transformVersion: transformVersion(
            transformChain(family, images, registry),
          ),
        });
      writeCache(root, key(), Buffer.from([1, 2, 3]), { family, images });
      assert.ok(
        readCache(root, key()) !== null,
        `${family}/${images}: unchanged transform missed`,
      );
      assert.equal(
        readCache(root, key(bumped(transform))),
        null,
        `${family}/${images}: bumping ${transform} still hit`,
      );
    }
  });

  it("a raw capture with images on does not depend on any transform version", () => {
    const raw = (registry: TransformRegistry): string =>
      transformVersion(transformChain("apple", "on", registry));
    assert.equal(raw(bumped("gmailWeb")), raw(TRANSFORMS));
    assert.equal(raw(bumped("imagesOff")), raw(TRANSFORMS));
  });

  it("a family named like an Object.prototype member has no transform", () => {
    for (const family of ["toString", "constructor", "hasOwnProperty"]) {
      assert.deepEqual(transformChain(family, "on"), [], family);
      assert.deepEqual(
        transformChain(family, "off").map((t) => t.name),
        ["imagesOff"],
        family,
      );
    }
  });
});

describe("readCache/writeCache", () => {
  it("roundtrips png bytes + meta through a tmp dir", () => {
    const root = mkdtempSync(join(scratch, "cache-test-"));
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
    const root = mkdtempSync(join(scratch, "cache-test-"));
    assert.equal(readCache(root, cacheKey(parts())), null);
  });

  it("corrupt-JSON → null", () => {
    const root = mkdtempSync(join(scratch, "cache-test-"));
    const key = cacheKey(parts());
    const paths = cachePaths(root, key);
    mkdirSync(paths.dir, { recursive: true });
    writeFileSync(paths.png, Buffer.from([0x89, 0x50]));
    writeFileSync(paths.meta, "{ not valid json");
    assert.equal(readCache(root, key), null);
  });

  it("valid JSON that is not an object → null", () => {
    const root = mkdtempSync(join(scratch, "cache-test-"));
    const key = cacheKey(parts());
    const paths = cachePaths(root, key);
    mkdirSync(paths.dir, { recursive: true });
    writeFileSync(paths.png, Buffer.from([0x89, 0x50]));
    for (const body of ["null", "[]", "42", '"meta"']) {
      writeFileSync(paths.meta, body);
      assert.equal(readCache(root, key), null, body);
    }
  });
});
