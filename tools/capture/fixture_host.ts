// tools/capture/fixture_host.ts — the story fixture image host.
//
// Stories reference their images on the reserved `.test` host
// `https://x.test/`, content-hashed like any hosted asset
// (`/{sha256[0:16]}/{name}`, catalogue R-IMG-07). Backend A answers
// those requests from tests/stories/assets/ through a Playwright route,
// so story images render deterministically and without a network. A
// request whose hash prefix does not match the file's bytes, or whose
// name is not a plain file in that directory, gets a 404 — the capture
// then shows a broken image instead of a stale or wrong one.
//
// Because the hash is in the URL, and the URL is in the MIME, changing
// a fixture image changes the story's MIME: the result cache and the
// --affected selection both see it without any extra key.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

export const FIXTURE_HOST = "https://x.test";

export interface FixtureResponse {
  status: number;
  contentType: string;
  body: Buffer;
}

const CONTENT_TYPES: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
};

function notFound(why: string): FixtureResponse {
  return {
    status: 404,
    contentType: "text/plain",
    body: Buffer.from(`fixture host: ${why}\n`),
  };
}

// Resolves one request URL against the fixture directory.
export function resolveFixture(
  url: string,
  assetsDir: string,
): FixtureResponse {
  let path: string;
  try {
    const u = new URL(url);
    if (`${u.protocol}//${u.host}` !== FIXTURE_HOST)
      return notFound(`not the fixture host: ${url}`);
    path = u.pathname;
  } catch {
    return notFound(`unparseable URL: ${url}`);
  }
  const m = /^\/([0-9a-f]{16})\/([A-Za-z0-9._@-]+)$/.exec(path);
  if (m === null || m[2].startsWith("."))
    return notFound(`not a hashed asset path: ${path}`);
  const [, prefix, name] = m;
  const file = join(assetsDir, name);
  if (!existsSync(file) || !statSync(file).isFile())
    return notFound(`no fixture named ${name}`);
  const body = readFileSync(file);
  const sha = createHash("sha256").update(body).digest("hex");
  if (sha.slice(0, 16) !== prefix)
    return notFound(
      `${name} hashes to ${sha.slice(0, 16)}, not ${prefix} (stale URL)`,
    );
  const ext = name.slice(name.lastIndexOf(".") + 1).toLowerCase();
  return {
    status: 200,
    contentType: CONTENT_TYPES[ext] ?? "application/octet-stream",
    body,
  };
}

// Routes every fixture-host request of a Playwright browser context.
export async function installFixtureHost(
  context: any,
  assetsDir: string,
): Promise<void> {
  await context.route(`${FIXTURE_HOST}/**`, async (route: any) => {
    const res = resolveFixture(route.request().url(), assetsDir);
    await route.fulfill({
      status: res.status,
      contentType: res.contentType,
      body: res.body,
    });
  });
}
