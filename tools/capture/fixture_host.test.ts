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
import {
  DELIBERATELY_MISSING_PREFIX,
  FIXTURE_HOST,
  firstFrameGif,
  resolveFixture,
} from "./fixture_host.ts";
import { storyImagePaths } from "./providers/selfhosted_webmail.ts";

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

describe("a deliberately missing image", () => {
  it("is a 404, and not an image a real client must load", () => {
    const url = `${FIXTURE_HOST}${DELIBERATELY_MISSING_PREFIX}missing-product.png`;
    assert.equal(resolveFixture(url, assetsDir).status, 404);
    const logo = hashedUrl("logo.png");
    const html = `<img src="${logo}" alt="a"><img src="${url}" alt="b">`;
    assert.deepEqual(storyImagePaths(html), [logo.slice(FIXTURE_HOST.length)]);
    // Any other unknown image still counts.
    const other = `${FIXTURE_HOST}/0000000000000000/missing-product.png`;
    assert.deepEqual(storyImagePaths(`<img src="${other}" alt="c">`), [
      "/0000000000000000/missing-product.png",
    ]);
  });
});

// Counts the image descriptors of a GIF (its frames), walking the
// block structure rather than searching for the 0x2c byte.
function gifFrames(b: Buffer): number {
  let i = 13;
  if (b[10]! & 0x80) i += 3 * (1 << ((b[10]! & 7) + 1));
  const skip = (at: number): number => {
    let j = at;
    while (b[j] !== 0) j += b[j]! + 1;
    return j + 1;
  };
  let frames = 0;
  while (b[i] !== 0x3b) {
    if (b[i] === 0x21) i = skip(i + 2);
    else if (b[i] === 0x2c) {
      let j = i + 10;
      if (b[i + 9]! & 0x80) j += 3 * (1 << ((b[i + 9]! & 7) + 1));
      i = skip(j + 1);
      frames += 1;
    } else throw new Error(`not a GIF block at ${i}`);
  }
  assert.equal(i, b.length - 1, "the trailer ends the file");
  return frames;
}

describe("an animated GIF is served as its first frame", () => {
  const countdown = readFileSync(join(assetsDir, "countdown.gif"));

  it("keeps the first frame and drops the rest", () => {
    assert.equal(gifFrames(countdown), 2, "the fixture animates");
    const first = firstFrameGif(countdown);
    assert.equal(gifFrames(first), 1);
    // The header, screen and global colour table are kept as they are,
    // and so is the first image (its bytes are a prefix-free slice).
    assert.deepEqual(first.subarray(0, 13), countdown.subarray(0, 13));
    assert.ok(first.length < countdown.length);
    assert.ok(!first.includes(Buffer.from("NETSCAPE2.0")));
  });

  it("leaves a still GIF and other bytes alone", () => {
    const still = readFileSync(
      join(repoRoot, "tests", "fixtures", "t6_sample.gif"),
    );
    assert.equal(gifFrames(still), 1);
    assert.deepEqual(firstFrameGif(still), still);
    const png = readFileSync(join(assetsDir, "logo.png"));
    assert.deepEqual(firstFrameGif(png), png);
    const truncated = countdown.subarray(0, 200);
    assert.deepEqual(firstFrameGif(truncated), truncated);
  });
});
