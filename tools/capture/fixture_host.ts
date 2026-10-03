// tools/capture/fixture_host.ts — the story fixture image host.
//
// Stories reference their images on the reserved `.test` host
// `https://x.test/`, content-hashed like any hosted asset
// (`/{sha256[0:16]}/{name}`, catalogue R-IMG-07). Backend A answers
// those requests from tests/stories/assets/ through a Playwright route,
// from the library's own built-in images (the social icons in
// src/isonim_email/assets/social/, which a story publishes to the same
// host) and from the images a story's render derived (its crops,
// DERIVED_ASSETS_DIR), so story images render deterministically and
// without a network. A
// request whose hash prefix does not match the file's bytes, or whose
// name is not a plain file in that directory, gets a 404 — the capture
// then shows a broken image instead of a stale or wrong one.
//
// Because the hash is in the URL, and the URL is in the MIME, changing
// a fixture image changes the story's MIME: the result cache and the
// --affected selection both see it without any extra key.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import type { BrowserContext } from "playwright-core";

export const FIXTURE_HOST = "https://x.test";

// Images a story's render makes rather than reads (a crop the asset
// pass cut from a fixture, catalogue R-IMG-13): the story driver writes
// each one here, under its published name, when the capture CLI runs it
// with ISONIM_EMAIL_DERIVED_ASSETS set to this directory, and the
// fixture host serves it like a fixture (its hash prefix checked the
// same way).
export const DERIVED_ASSETS_DIR = join(
  resolve(dirname(new URL(import.meta.url).pathname), "..", ".."),
  "build",
  "email-shots",
  ".derived-assets",
);

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
  assetsDir: string | readonly string[],
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
  const [, prefix, name] =
    /^\/([0-9a-f]{16})\/([A-Za-z0-9._@-]+)$/.exec(path) ?? [];
  if (prefix === undefined || name === undefined || name.startsWith("."))
    return notFound(`not a hashed asset path: ${path}`);
  const dirs = typeof assetsDir === "string" ? [assetsDir] : assetsDir;
  const file = dirs
    .map((dir) => join(dir, name))
    .find((f) => existsSync(f) && statSync(f).isFile());
  if (file === undefined) return notFound(`no fixture named ${name}`);
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

// The network policy of a capture: nothing leaves the machine. The
// fixture host is answered from disk and data: URIs stay inline;
// every other request is aborted and recorded, so a message that
// points at a real server shows a missing resource in the capture and
// says so in the provenance, instead of depending on (and leaking to)
// the network. With images off, image requests to the fixture host
// are aborted too — that is what an images-off client does.
export type RouteDecision =
  | { action: "fixture" }
  | { action: "allow" }
  | { action: "block"; reason: "network" | "images-off" };

export function routeDecision(
  url: string,
  resourceType: string,
  images: string,
): RouteDecision {
  if (url.startsWith("data:")) return { action: "allow" };
  if (url.startsWith(`${FIXTURE_HOST}/`)) {
    if (images === "off" && resourceType === "image")
      return { action: "block", reason: "images-off" };
    return { action: "fixture" };
  }
  return { action: "block", reason: "network" };
}

export interface BlockedRequest {
  url: string;
  reason: "network" | "images-off";
}

// Routes every request of a Playwright browser context through
// routeDecision. Returns the list the blocked requests are appended to
// as they happen.
export async function installCapturePolicy(
  context: BrowserContext,
  assetsDir: string | readonly string[],
  images: string,
): Promise<BlockedRequest[]> {
  const blocked: BlockedRequest[] = [];
  await context.route("**/*", async (route) => {
    const request = route.request();
    const url = request.url();
    const decision = routeDecision(url, request.resourceType(), images);
    if (decision.action === "allow") {
      await route.continue();
      return;
    }
    if (decision.action === "block") {
      blocked.push({ url, reason: decision.reason });
      await route.abort("blockedbyclient");
      return;
    }
    const res = resolveFixture(url, assetsDir);
    await route.fulfill({
      status: res.status,
      contentType: res.contentType,
      body: res.body,
    });
  });
  return blocked;
}
