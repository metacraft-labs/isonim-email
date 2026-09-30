// tools/capture/perceptual.test.ts — fixtures for the Tier-2
// perceptual diff: identical → zero diff, single-pixel change counted
// with the exact ratio, the ±2 per-channel tolerance boundary, and
// dimension mismatch throwing. Fixtures go through the PNG
// codec (writePng/readPng), never hand-built bytes. Run with:
//   node --test tools/capture/perceptual.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { writePng, type RgbImage } from "./contact_sheet.ts";
import { diffPng } from "./perceptual.ts";

function solidRgb(w: number, h: number, c: [number, number, number]): RgbImage {
  const data = new Uint8Array(w * h * 3);
  for (let i = 0; i < w * h; i++) {
    data[i * 3] = c[0];
    data[i * 3 + 1] = c[1];
    data[i * 3 + 2] = c[2];
  }
  return { width: w, height: h, data };
}

function pngOf(img: RgbImage): Buffer {
  return Buffer.from(writePng(img));
}

function withPixel(
  img: RgbImage,
  x: number,
  y: number,
  c: [number, number, number],
): RgbImage {
  const data = new Uint8Array(img.data);
  const d = (y * img.width + x) * 3;
  data[d] = c[0];
  data[d + 1] = c[1];
  data[d + 2] = c[2];
  return { width: img.width, height: img.height, data };
}

describe("diffPng", () => {
  it("identical → {0, 0.0}", () => {
    const png = pngOf(solidRgb(4, 3, [10, 20, 30]));
    assert.deepEqual(diffPng(png, png), { diffPixels: 0, diffRatio: 0.0 });
  });

  it("one-pixel-red → {1, 1/(w*h)}", () => {
    const base = solidRgb(4, 3, [10, 20, 30]);
    const red = withPixel(base, 1, 2, [255, 20, 30]);
    assert.deepEqual(diffPng(pngOf(base), pngOf(red)), {
      diffPixels: 1,
      diffRatio: 1 / (4 * 3),
    });
  });

  it("channel diff exactly 2 → 0; exactly 3 → counted", () => {
    const base = solidRgb(2, 2, [100, 100, 100]);
    const plus2 = withPixel(base, 0, 0, [102, 100, 100]);
    assert.deepEqual(diffPng(pngOf(base), pngOf(plus2)), {
      diffPixels: 0,
      diffRatio: 0.0,
    });
    const plus3 = withPixel(base, 0, 0, [103, 100, 100]);
    assert.deepEqual(diffPng(pngOf(base), pngOf(plus3)), {
      diffPixels: 1,
      diffRatio: 1 / 4,
    });
  });

  it("dimension mismatch throws", () => {
    const a = pngOf(solidRgb(2, 2, [1, 2, 3]));
    const b = pngOf(solidRgb(3, 2, [1, 2, 3]));
    assert.throws(() => diffPng(a, b), /dimension mismatch/);
  });

  it("malformed PNG throws (never silently compared)", () => {
    const a = pngOf(solidRgb(2, 2, [1, 2, 3]));
    assert.throws(() => diffPng(a, Buffer.from("not a png")), /bad PNG/);
  });
});
