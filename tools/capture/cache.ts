// tools/capture/cache.ts — result cache key + store.
//
// The cache key is the sha256 of the capture inputs, so a client
// update changes the key automatically and stale results are never
// served after an upgrade. The provider's version and the version of
// the emulation transform(s) applied are inputs too: changing a
// transform or the provider can never serve a capture made by the old
// one.

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// Every field is supplied by the capture harness
// (providers/harness.ts): the provider's id, version and adapter
// version, the client build it reports, and the transform version of
// the emulation it applies.

export interface CacheKeyParts {
  mimeSha: string;
  provider: string;
  providerVersion: string;
  backend: string;
  family: string;
  clientId: string;
  clientBuild: string;
  viewport: string;
  dpr: number;
  scheme: string;
  images: string;
  adapterVersion: number;
  // The emulation transform(s) applied, as name@version joined by "+"
  // in application order ("" for a raw capture). See
  // transformVersion in transforms.ts.
  transformVersion: string;
}

// sha256 hex of the key fields joined by ‖, in field order.
export function cacheKey(p: CacheKeyParts): string {
  const joined = [
    p.mimeSha,
    p.provider,
    p.providerVersion,
    p.backend,
    p.family,
    p.clientId,
    p.clientBuild,
    p.viewport,
    String(p.dpr),
    p.scheme,
    p.images,
    String(p.adapterVersion),
    p.transformVersion,
  ].join("‖");
  return createHash("sha256").update(joined, "utf8").digest("hex");
}

export function cachePaths(
  cacheRoot: string,
  key: string,
): { dir: string; png: string; meta: string } {
  const dir = join(cacheRoot, key);
  return {
    dir,
    png: join(dir, "capture.png"),
    meta: join(dir, "capture.json"),
  };
}

// Any error (missing files, corrupt JSON, a capture.json that is not
// a JSON object, …) → null. Never throws.
export function readCache(
  cacheRoot: string,
  key: string,
): { png: Buffer; meta: Record<string, unknown> } | null {
  try {
    const paths = cachePaths(cacheRoot, key);
    const png = readFileSync(paths.png);
    const meta: unknown = JSON.parse(readFileSync(paths.meta, "utf8"));
    if (typeof meta !== "object" || meta === null || Array.isArray(meta))
      return null;
    return { png, meta: Object.fromEntries(Object.entries(meta)) };
  } catch {
    return null;
  }
}

// Writes capture.png + capture.json under cacheRoot/key, creating the
// directory. Any error → stderr warning. Never throws.
export function writeCache(
  cacheRoot: string,
  key: string,
  png: Buffer,
  meta: object,
): void {
  try {
    const paths = cachePaths(cacheRoot, key);
    mkdirSync(paths.dir, { recursive: true });
    writeFileSync(paths.png, png);
    writeFileSync(paths.meta, JSON.stringify(meta, null, 2) + "\n");
  } catch (err) {
    console.warn(`cache: write failed for key ${key}: ${String(err)}`);
  }
}
