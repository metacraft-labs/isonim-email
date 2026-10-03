// tools/capture/fixture_host.test.ts — the story fixture image host:
// a content-hashed URL on the fixture host serves the fixture's bytes;
// a stale hash, an unknown name, a traversal attempt and a foreign
// host all get a 404. Runs against the real tests/stories/assets/
// files (no mocks). Run with:
//   node --test tools/capture/fixture_host.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { FIXTURE_HOST, resolveFixture } from "./fixture_host.ts";

const repoRoot = resolve(
  dirname(new URL(import.meta.url).pathname),
  "..",
  "..",
);
const assetsDir = join(repoRoot, "tests", "stories", "assets");

function hashedUrl(name: string): string {
  const bytes = readFileSync(join(assetsDir, name));
  const sha = createHash("sha256").update(bytes).digest("hex");
  return `${FIXTURE_HOST}/${sha.slice(0, 16)}/${name}`;
}

const iconsDir = join(repoRoot, "src", "isonim_email", "assets", "social");

describe("fixture host", () => {
  it("serves the library's built-in icons beside the story fixtures", () => {
    const name = "social-x-light.png";
    const bytes = readFileSync(join(iconsDir, name));
    const sha = createHash("sha256").update(bytes).digest("hex");
    const url = `${FIXTURE_HOST}/${sha.slice(0, 16)}/${name}`;
    // One directory: not found; both: served, story fixtures still first.
    assert.equal(resolveFixture(url, assetsDir).status, 404);
    const res = resolveFixture(url, [assetsDir, iconsDir]);
    assert.equal(res.status, 200);
    assert.equal(res.contentType, "image/png");
    assert.deepEqual(res.body, bytes);
    assert.equal(
      resolveFixture(hashedUrl("logo.png"), [assetsDir, iconsDir]).status,
      200,
    );
  });

  it("serves a story image at its content-hashed URL", () => {
    for (const name of ["logo.png", "shield.png"]) {
      const res = resolveFixture(hashedUrl(name), assetsDir);
      assert.equal(res.status, 200);
      assert.equal(res.contentType, "image/png");
      assert.deepEqual(res.body, readFileSync(join(assetsDir, name)));
    }
  });

  it("refuses a stale hash, unknown names, traversal and other hosts", () => {
    const good = hashedUrl("logo.png");
    const stale = good.replace(/\/[0-9a-f]{16}\//, "/0000000000000000/");
    assert.equal(resolveFixture(stale, assetsDir).status, 404);
    assert.match(resolveFixture(stale, assetsDir).body.toString(), /stale URL/);
    assert.equal(
      resolveFixture(`${FIXTURE_HOST}/0000000000000000/nope.png`, assetsDir)
        .status,
      404,
    );
    assert.equal(
      resolveFixture(`${FIXTURE_HOST}/logo.png`, assetsDir).status,
      404,
    );
    assert.equal(
      resolveFixture(
        `${FIXTURE_HOST}/0000000000000000/..%2F..%2FJustfile`,
        assetsDir,
      ).status,
      404,
    );
    assert.equal(
      resolveFixture(good.replace("x.test", "y.test"), assetsDir).status,
      404,
    );
  });
});
