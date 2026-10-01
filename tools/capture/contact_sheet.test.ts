// tools/capture/contact_sheet.test.ts — fixtures for the contact sheets:
// PNG roundtrip + hand-rolled filter coverage, family order, cell
// widths, scale/top-align/label/hatch pixels, row paging, and a
// fake-run composeStorySheets end-to-end. Run with:
//   node --test tools/capture/contact_sheet.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { deflateSync } from "node:zlib";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cellWidthForViewport,
  columnsForWidth,
  composeCells,
  composeStorySheets,
  labelForCell,
  orderFamilies,
  readPng,
  scaleToWidth,
  sheetFileName,
  writePng,
  type RgbaImage,
  type RgbImage,
  type SheetCell,
} from "./contact_sheet.ts";

function solidRgb(w: number, h: number, c: [number, number, number]): RgbImage {
  const data = new Uint8Array(w * h * 3);
  for (let i = 0; i < w * h; i++) {
    data[i * 3] = c[0];
    data[i * 3 + 1] = c[1];
    data[i * 3 + 2] = c[2];
  }
  return { width: w, height: h, data };
}

function solidRgba(
  w: number,
  h: number,
  c: [number, number, number, number],
): RgbaImage {
  const data = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    data[i * 4] = c[0];
    data[i * 4 + 1] = c[1];
    data[i * 4 + 2] = c[2];
    data[i * 4 + 3] = c[3];
  }
  return { width: w, height: h, data };
}

// [r, g, b]; shorter when (x, y) lies outside the image.
function pixel(img: RgbImage, x: number, y: number): number[] {
  const d = (y * img.width + x) * 3;
  return [...img.data.subarray(d, d + 3)];
}

// A hand-rolled PNG (zero CRCs — the reader skips them) for filter
// and colour-type paths the writer never emits.
function rawPng(
  width: number,
  height: number,
  colorType: number,
  filtered: number[],
): Uint8Array {
  const ihdr = new Uint8Array(13);
  const view = new DataView(ihdr.buffer);
  view.setUint32(0, width);
  view.setUint32(4, height);
  ihdr[8] = 8;
  ihdr[9] = colorType;
  const idat = deflateSync(Uint8Array.from(filtered));
  const out: number[] = [137, 80, 78, 71, 13, 10, 26, 10];
  for (const [type, data] of [
    ["IHDR", ihdr],
    ["IDAT", idat],
    ["IEND", new Uint8Array(0)],
  ] as const) {
    const len = new Uint8Array(4);
    new DataView(len.buffer).setUint32(0, data.length);
    out.push(...len);
    for (const ch of type) out.push(ch.charCodeAt(0));
    out.push(...data);
    out.push(0, 0, 0, 0);
  }
  return Uint8Array.from(out);
}

describe("PNG codec", () => {
  it("roundtrips RGB and is byte-deterministic", () => {
    const img = solidRgb(7, 5, [200, 30, 140]);
    img.data[0] = 1;
    img.data[1] = 2;
    img.data[2] = 3;
    const a = writePng(img);
    const b = writePng(img);
    assert.deepEqual(a, b);
    const back = readPng(a);
    assert.equal(back.width, 7);
    assert.equal(back.height, 5);
    for (let i = 0; i < 7 * 5; i++) {
      assert.equal(back.data[i * 4], img.data[i * 3]);
      assert.equal(back.data[i * 4 + 1], img.data[i * 3 + 1]);
      assert.equal(back.data[i * 4 + 2], img.data[i * 3 + 2]);
      assert.equal(back.data[i * 4 + 3], 255);
    }
  });

  it("reads RGBA with a Sub filter row", () => {
    // 2x1: (255,0,0,255) then (0,255,0,128), Sub-encoded.
    const png = rawPng(2, 1, 6, [1, 255, 0, 0, 255, 1, 255, 0, 129]);
    const img = readPng(png);
    assert.deepEqual([...img.data], [255, 0, 0, 255, 0, 255, 0, 128]);
  });

  it("reads grey with an Up filter row", () => {
    // 2x2 grey, rows [10,20] and Up-encoded [5,5] → [15,25].
    const png = rawPng(2, 2, 0, [0, 10, 20, 2, 5, 5]);
    const img = readPng(png);
    assert.deepEqual(
      [...img.data],
      [10, 10, 10, 255, 20, 20, 20, 255, 15, 15, 15, 255, 25, 25, 25, 255],
    );
  });

  it("rejects non-PNGs and interlaced input", () => {
    assert.throws(() => readPng(Uint8Array.from([1, 2, 3])));
    const good = writePng(solidRgb(2, 2, [0, 0, 0]));
    const bad = Uint8Array.from(good);
    bad[28] = 1; // IHDR interlace byte
    assert.throws(() => readPng(bad));
  });

  it("rejects an IHDR whose length is not 13", () => {
    // The PNG spec fixes IHDR at 13 data bytes. A 14-byte IHDR (the
    // 13 good bytes plus one extra) is refused by name, not decoded.
    const good = writePng(solidRgb(2, 2, [0, 0, 0]));
    const ihdrEnd = 8 + 8 + 13; // signature, length+type, data
    const bad = new Uint8Array(good.length + 1);
    bad.set(good.subarray(0, ihdrEnd), 0);
    bad[ihdrEnd] = 0; // the 14th IHDR byte
    bad.set(good.subarray(ihdrEnd), ihdrEnd + 1);
    new DataView(bad.buffer).setUint32(8, 14);
    assert.throws(() => readPng(bad), /bad PNG \(IHDR length 14 \(want 13\)\)/);
  });
});

describe("order and widths", () => {
  it("orders families per the sheet order, missing skipped, others alphabetical", () => {
    assert.deepEqual(
      orderFamilies([
        "thunderbird",
        "wordApprox",
        "apple",
        "chromium-baseline",
        "ganga",
      ]),
      ["apple", "ganga", "wordApprox", "thunderbird", "chromium-baseline"],
    );
    assert.deepEqual(orderFamilies([]), []);
  });

  it("orders the whole backend-A set with wordApprox in outlookWord's place", () => {
    // apple, gmailWeb, gmailApp, ganga, outlookWord, outlookWeb,
    // outlookApp, yahoo, samsung, thunderbird, others.
    assert.deepEqual(
      orderFamilies([
        "imagesOff",
        "wordApprox",
        "outlookWeb",
        "thunderbird",
        "chromium-baseline",
        "gmailWeb",
        "ganga",
        "apple",
      ]),
      [
        "apple",
        "gmailWeb",
        "ganga",
        "wordApprox",
        "outlookWeb",
        "thunderbird",
        "chromium-baseline",
        "imagesOff",
      ],
    );
  });

  it("derives cell widths from the viewport name", () => {
    assert.equal(cellWidthForViewport("mobile"), 360);
    assert.equal(cellWidthForViewport("mobile-ldpi"), 360);
    assert.equal(cellWidthForViewport("desktop"), 600);
    assert.equal(cellWidthForViewport("desktop-hidpi"), 600);
    assert.equal(cellWidthForViewport("375@3x"), 360);
    assert.equal(cellWidthForViewport("600@2x"), 600);
    assert.equal(cellWidthForViewport("800@1x"), 600);
    // 6 mobile columns (6*368+8 = 2216) and 3 desktop (3*608+8 = 1832)
    // stay under the 2400 cap.
    assert.equal(columnsForWidth(360), 6);
    assert.equal(columnsForWidth(600), 3);
  });

  it("labels cells '{family} · {build} · {backend}'", () => {
    assert.equal(
      labelForCell("gmailWeb", "1.49.0", "a", false),
      "gmailWeb · 1.49.0 · a",
    );
    assert.equal(
      labelForCell("gmailWeb", "1.49.0", "a", true),
      "gmailWeb · 1.49.0 · a [APPROX]",
    );
    assert.equal(
      labelForCell("apple", "", "a", false),
      "apple · unknown-build · a",
    );
  });

  it("names sheets plain, or -p<N> when split", () => {
    assert.equal(
      sheetFileName("mobile", "light", 1, 1),
      "contact-mobile-light.png",
    );
    assert.equal(
      sheetFileName("mobile", "light", 2, 3),
      "contact-mobile-light-p2.png",
    );
  });
});

describe("scale and compose", () => {
  it("scales solid colours exactly and flattens alpha onto white", () => {
    const red = scaleToWidth(solidRgba(4, 4, [255, 0, 0, 255]), 2);
    assert.equal(red.width, 2);
    assert.equal(red.height, 2);
    assert.deepEqual(pixel(red, 0, 0), [255, 0, 0]);
    assert.deepEqual(pixel(red, 1, 1), [255, 0, 0]);
    const flat = scaleToWidth(solidRgba(4, 4, [0, 0, 0, 0]), 2);
    assert.deepEqual(pixel(flat, 0, 0), [255, 255, 255]);
    const tall = scaleToWidth(solidRgba(4, 2, [0, 255, 0, 255]), 2);
    assert.equal(tall.height, 1);
  });

  it("keeps the bottom row the source colour when the last source box rounds past the image", () => {
    // 1125x962 to 360 wide: 308 rows of 962/308 source rows each, and
    // 308 * (962/308) is 962.0000000000001 in floating point — the last
    // box reaches a hair past row 961. A uniform source must scale to
    // that same colour everywhere, bottom row included (unclamped, the
    // read past the image made the bottom row black).
    const colour: [number, number, number] = [30, 120, 200];
    const out = scaleToWidth(solidRgba(1125, 962, [...colour, 255]), 360);
    assert.equal(out.width, 360);
    assert.equal(out.height, 308);
    for (const y of [0, out.height - 1])
      for (let x = 0; x < out.width; x++)
        assert.deepEqual(pixel(out, x, y), colour, `pixel (${x}, ${y})`);
  });

  function cell(
    family: string,
    color: [number, number, number],
    h: number,
    approx = false,
  ): SheetCell {
    return {
      family,
      label: labelForCell(family, "b1", "a", approx),
      approx,
      img: solidRgb(360, h, color),
    };
  }

  it("top-aligns cells and paints the label bar", () => {
    const pages = composeCells(
      [cell("apple", [255, 0, 0], 100), cell("ganga", [0, 0, 255], 40)],
      360,
    );
    const [page, ...more] = pages;
    assert.ok(page !== undefined && more.length === 0, "want one page");
    assert.equal(page.width, 6 * (360 + 8) + 8);
    assert.equal(page.height, 8 + (16 + 100) + 8);
    // Bar is dark slate left of the text (text starts at x+4).
    assert.deepEqual(pixel(page, 8 + 2, 8 + 8), [36, 41, 47]);
    // Tall cell red at its top; short cell blue at its top…
    assert.deepEqual(pixel(page, 8 + 180, 8 + 16 + 5), [255, 0, 0]);
    const gx = 8 + (360 + 8);
    assert.deepEqual(pixel(page, gx + 180, 8 + 16 + 5), [0, 0, 255]);
    // …and background below the short cell (top-aligned, row-sized).
    assert.deepEqual(pixel(page, gx + 180, 8 + 16 + 60), [223, 227, 232]);
  });

  it("crosshatches approximation cells and frames the rest", () => {
    const pages = composeCells(
      [cell("ganga", [10, 20, 30], 40, true), cell("apple", [10, 20, 30], 40)],
      360,
    );
    const page = pages[0];
    assert.ok(page !== undefined, "no page");
    // Approx top-left corner: ((0+0)>>2)%2==0 → amber.
    assert.deepEqual(pixel(page, 8, 8), [255, 180, 0]);
    const ax = 8 + (360 + 8);
    assert.deepEqual(pixel(page, ax, 8), [154, 160, 166]);
  });

  it("splits tall rows into pages deterministically", () => {
    const cells = Array.from({ length: 7 }, (_, i) =>
      cell(`zz${i}`, [50, 60, 70], 1200),
    );
    // 6 columns: rows of 6 + 1, each 1216 tall; two rows (2456 px)
    // exceed the 2400 page cap → two pages.
    const a = composeCells(cells, 360).map((p) => writePng(p));
    const b = composeCells(cells, 360).map((p) => writePng(p));
    assert.equal(a.length, 2);
    assert.deepEqual(a[0], b[0]);
    assert.deepEqual(a[1], b[1]);
  });
});

describe("composeStorySheets", () => {
  function fakeRun(): string {
    const run = mkdtempSync(join(tmpdir(), "contact-"));
    const storyDir = join(run, "canary");
    mkdirSync(storyDir, { recursive: true });
    const families: [string, [number, number, number], boolean][] = [
      ["thunderbird", [255, 0, 0], true],
      ["apple", [0, 255, 0], false],
    ];
    const index: unknown[] = [];
    for (const [family, color, approx] of families) {
      const base = `a-${family}-chromium-mobile-light-on`;
      writeFileSync(
        join(storyDir, `${base}.png`),
        writePng(solidRgb(120, 60, color)),
      );
      const meta = {
        backend: "a",
        family,
        client: { id: "chromium", build: "test-build-9" },
        approximation: approx,
      };
      writeFileSync(join(storyDir, `${base}.json`), JSON.stringify(meta));
      index.push({
        story: "canary",
        backend: "a",
        family,
        viewport: "mobile",
        scheme: "light",
        images: "on",
        png: join("canary", `${base}.png`),
        meta: join("canary", `${base}.json`),
        status: "done",
      });
    }
    // A decoy: same apple capture with images=off must lose to on,
    // and a failed entry must never reach a sheet.
    index.push({
      story: "canary",
      backend: "a",
      family: "apple",
      viewport: "mobile",
      scheme: "light",
      images: "off",
      png: join("canary", "a-apple-chromium-mobile-light-off.png"),
      meta: join("canary", "a-apple-chromium-mobile-light-off.json"),
      status: "done",
    });
    index.push({
      story: "canary",
      backend: "a",
      family: "ganga",
      viewport: "mobile",
      scheme: "light",
      images: "on",
      png: null,
      meta: join("canary", "a-ganga-chromium-mobile-light-on.json"),
      status: "failed",
    });
    writeFileSync(join(run, "index.json"), JSON.stringify(index));
    return run;
  }

  it("composes one ordered sheet per group from a run dir", () => {
    const run = fakeRun();
    const written = composeStorySheets(run, "canary");
    const sheetRel = join("canary", "contact-mobile-light.png");
    assert.deepEqual(written, [sheetRel]);
    const sheet = readPng(readFileSync(join(run, sheetRel)));
    // 120x60 → 360x180 cells; one row of two.
    assert.equal(sheet.width, 6 * (360 + 8) + 8);
    assert.equal(sheet.height, 8 + (16 + 180) + 8);
    // Sheet order, not index order: apple (green) left of thunderbird.
    const flat = {
      width: sheet.width,
      height: sheet.height,
      data: new Uint8Array(sheet.width * sheet.height * 3),
    };
    for (let i = 0; i < sheet.width * sheet.height; i++)
      flat.data.set(sheet.data.subarray(i * 4, i * 4 + 3), i * 3);
    assert.deepEqual(pixel(flat, 8 + 180, 8 + 16 + 90), [0, 255, 0]);
    assert.deepEqual(
      pixel(flat, 8 + (360 + 8) + 180, 8 + 16 + 90),
      [255, 0, 0],
    );
    // Deterministic: a second compose overwrites byte-identically.
    const before = readFileSync(join(run, sheetRel));
    composeStorySheets(run, "canary");
    assert.deepEqual(readFileSync(join(run, sheetRel)), before);
  });

  it("fails loudly without an index.json", () => {
    const empty = mkdtempSync(join(tmpdir(), "contact-empty-"));
    assert.throws(() => composeStorySheets(empty, "canary"));
  });
});
