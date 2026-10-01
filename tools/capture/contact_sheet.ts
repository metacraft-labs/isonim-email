#!/usr/bin/env node
// tools/capture/contact_sheet.ts — deterministic contact sheets.
//
// One composite per (story, viewport, scheme), a grid of
// every captured family in fixed order, cells scaled to a common
// width, top-aligned, labelled `{family} · {client build} · {backend}`
// with a crosshatch label on approximations, capped at 2400 px wide,
// longer stories split into row pages. Node only, no browser.
//
// Image-library choice: no sharp, jimp
// or pngjs is pinned in the dev shell or in isonim's node_modules;
// node-canvas 3.2.3 sits in isonim/node_modules but does not load in
// this shell (libuuid.so.1 missing), and the ffmpeg on PATH is
// user-profile, not pinned — so this file vendors a dependency-free
// PNG codec (8-bit grey/RGB/RGBA, node's zlib for inflate/deflate),
// a box resampler, and a 5x7 bitmap font for the labels. It is
// deterministic: fixed row filters, a fixed zlib level, no ancillary
// chunks, no timestamps.

import { deflateSync, inflateSync } from "node:zlib";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// ---------------------------------------------------------------------------
// PNG codec (8-bit, colour types 0/2/6, non-interlaced)
// ---------------------------------------------------------------------------

export interface RgbaImage {
  width: number;
  height: number;
  data: Uint8Array; // width*height*4, row-major
}

export interface RgbImage {
  width: number;
  height: number;
  data: Uint8Array; // width*height*3, row-major
}

const PNG_SIG = [137, 80, 78, 71, 13, 10, 26, 10];

// Checked element read. Every read in this codec and in the raster
// code below is in range by construction: the chunk-length, IHDR-length
// and row-length checks bound the decoder, the CRC table has 256
// entries, every glyph has 7 rows, and scaleToWidth clamps its source
// coordinates to the image. An out-of-range index is therefore a bug
// in this file, and it throws instead of reading as some value (an
// unchecked read would give undefined, which arithmetic turns into
// NaN and a Uint8Array store into 0 — a silently black pixel).
function at<T>(arr: ArrayLike<T>, i: number): T {
  const v = arr[i];
  if (v === undefined)
    throw new RangeError(
      `contact-sheet: internal read at ${i} outside [0, ${arr.length})`,
    );
  return v;
}

function readU32BE(b: Uint8Array, o: number): number {
  return (
    (at(b, o) * 2 ** 24 +
      (at(b, o + 1) << 16) +
      (at(b, o + 2) << 8) +
      at(b, o + 3)) >>>
    0
  );
}

function paeth(a: number, b: number, c: number): number {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

function failPng(message: string): never {
  throw new Error(`contact-sheet: bad PNG (${message})`);
}

export function readPng(buf: Uint8Array): RgbaImage {
  if (buf.length < 8 || !PNG_SIG.every((byte, i) => buf[i] === byte))
    failPng("not a PNG (signature mismatch)");
  let pos = 8;
  let width = 0;
  let height = 0;
  let colorType = -1;
  const idats: Uint8Array[] = [];
  let idatLen = 0;
  let seenIhdr = false;
  while (pos + 8 <= buf.length) {
    const len = readU32BE(buf, pos);
    const type = String.fromCharCode(...buf.subarray(pos + 4, pos + 8));
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (data.length < len || pos + 8 + len + 4 > buf.length)
      failPng(`truncated ${type} chunk`);
    if (type === "IHDR") {
      if (seenIhdr || pos !== 8) failPng("IHDR must be the first chunk");
      if (len !== 13) failPng(`IHDR length ${len} (want 13)`);
      seenIhdr = true;
      width = readU32BE(data, 0);
      height = readU32BE(data, 4);
      if (data[8] !== 8) failPng(`bit depth ${data[8]} (want 8)`);
      colorType = at(data, 9);
      if (colorType !== 0 && colorType !== 2 && colorType !== 6)
        failPng(`colour type ${colorType} (want 0, 2 or 6)`);
      if (data[10] !== 0 || data[11] !== 0)
        failPng("unknown compression/filter method");
      if (data[12] !== 0) failPng("interlaced PNGs are not supported");
      if (width === 0 || height === 0) failPng("zero-size IHDR");
    } else if (type === "IDAT") {
      if (!seenIhdr) failPng("IDAT before IHDR");
      idats.push(data);
      idatLen += len;
    } else if (type === "IEND") {
      break;
    }
    // Else: ancillary chunk (pHYs, iCCP, tEXt, …) — skipped; only
    // the pixels feed the sheet. CRCs are not verified: a corrupt
    // stream fails at inflate or at the row-length check below.
    pos += 8 + len + 4;
  }
  if (!seenIhdr) failPng("missing IHDR");
  if (idats.length === 0) failPng("missing IDAT");
  const flat = new Uint8Array(idatLen);
  let off = 0;
  for (const part of idats) {
    flat.set(part, off);
    off += part.length;
  }
  let raw: Uint8Array;
  try {
    raw = inflateSync(flat);
  } catch (err) {
    failPng(`IDAT inflate failed (${String(err)})`);
  }
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : 1;
  const stride = width * channels;
  if (raw.length !== height * (stride + 1))
    failPng(`inflated ${raw.length} bytes, want ${height * (stride + 1)}`);
  const out = new Uint8Array(width * height * 4);
  const prev = new Uint8Array(stride);
  const cur = new Uint8Array(stride);
  let p = 0;
  for (let y = 0; y < height; y++) {
    const filter = at(raw, p++);
    if (filter > 4) failPng(`row ${y} has filter ${filter}`);
    for (let i = 0; i < stride; i++) {
      const v = at(raw, p++);
      const a = i >= channels ? at(cur, i - channels) : 0;
      const b = at(prev, i);
      const c = i >= channels ? at(prev, i - channels) : 0;
      cur[i] =
        filter === 0
          ? v
          : filter === 1
            ? (v + a) & 0xff
            : filter === 2
              ? (v + b) & 0xff
              : filter === 3
                ? (v + ((a + b) >> 1)) & 0xff
                : (v + paeth(a, b, c)) & 0xff;
    }
    for (let x = 0; x < width; x++) {
      const d = (y * width + x) * 4;
      if (channels === 4) {
        out.set(cur.subarray(x * 4, x * 4 + 4), d);
      } else if (channels === 3) {
        out.set(cur.subarray(x * 3, x * 3 + 3), d);
        out[d + 3] = 255;
      } else {
        const gray = at(cur, x);
        out[d] = gray;
        out[d + 1] = gray;
        out[d + 2] = gray;
        out[d + 3] = 255;
      }
    }
    prev.set(cur);
  }
  return { width, height, data: out };
}

const CRC_TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(b: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < b.length; i++)
    c = at(CRC_TABLE, (c ^ at(b, i)) & 0xff) ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function writeU32BE(b: Uint8Array, o: number, v: number): void {
  b[o] = (v >>> 24) & 0xff;
  b[o + 1] = (v >>> 16) & 0xff;
  b[o + 2] = (v >>> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

function pngChunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  writeU32BE(out, 0, data.length);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  writeU32BE(out, 8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

function concat(parts: Uint8Array[]): Uint8Array {
  let len = 0;
  for (const p of parts) len += p.length;
  const out = new Uint8Array(len);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

// RGB in, one IDAT out. Filter 0 on every row and zlib level 1:
// sheets are multi-megapixel and compose inside the CLI run, so the
// writer trades file size for speed — determinism needs a fixed
// level, not a high one. No ancillary chunks, no timestamps.
export function writePng(img: RgbImage): Uint8Array {
  const { width, height, data } = img;
  if (data.length !== width * height * 3)
    throw new Error(
      `contact-sheet: RGB buffer is ${data.length} bytes, want ${width * height * 3}`,
    );
  const raw = new Uint8Array(height * (width * 3 + 1));
  for (let y = 0; y < height; y++) {
    raw[y * (width * 3 + 1)] = 0;
    raw.set(
      data.subarray(y * width * 3, (y + 1) * width * 3),
      y * (width * 3 + 1) + 1,
    );
  }
  const ihdr = new Uint8Array(13);
  writeU32BE(ihdr, 0, width);
  writeU32BE(ihdr, 4, height);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return concat([
    Uint8Array.from(PNG_SIG),
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", deflateSync(raw, { level: 1 })),
    pngChunk("IEND", new Uint8Array(0)),
  ]);
}

// ---------------------------------------------------------------------------
// 5x7 bitmap font (vendored: the labels need no fontconfig at all)
// ---------------------------------------------------------------------------
//
// One line per printable ASCII char (codes 32–126), 7 rows of 5 bits,
// MSB left. Index 95 is U+00B7 MIDDLE DOT (the label separator);
// anything else maps to '?'. contact_sheet.test.ts renders the proof
// alphabet — eyeball it there after touching a row.
const FONT: number[][] = [
  [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000], // 32 space
  [0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100], // 33 !
  [0b01010, 0b01010, 0b01010, 0b00000, 0b00000, 0b00000, 0b00000], // 34 "
  [0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010], // 35 #
  [0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100], // 36 $
  [0b11001, 0b11010, 0b00010, 0b00100, 0b01000, 0b10110, 0b10011], // 37 %
  [0b01100, 0b10010, 0b10100, 0b01000, 0b10110, 0b10010, 0b01101], // 38 &
  [0b00100, 0b00100, 0b01000, 0b00000, 0b00000, 0b00000, 0b00000], // 39 '
  [0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010], // 40 (
  [0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000], // 41 )
  [0b00000, 0b01010, 0b00100, 0b11111, 0b00100, 0b01010, 0b00000], // 42 *
  [0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000], // 43 +
  [0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b00100, 0b01000], // 44 ,
  [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000], // 45 -
  [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100], // 46 .
  [0b00001, 0b00010, 0b00010, 0b00100, 0b00100, 0b01000, 0b01000], // 47 /
  [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110], // 48 0
  [0b00100, 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111], // 49 1
  [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111], // 50 2
  [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110], // 51 3
  [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010], // 52 4
  [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110], // 53 5
  [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110], // 54 6
  [0b11111, 0b00001, 0b00010, 0b00100, 0b00100, 0b00100, 0b00100], // 55 7
  [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110], // 56 8
  [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b00110], // 57 9
  [0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000], // 58 :
  [0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b01000], // 59 ;
  [0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010], // 60 <
  [0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000], // 61 =
  [0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000], // 62 >
  [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100], // 63 ?
  [0b01110, 0b10001, 0b10111, 0b10101, 0b10111, 0b10000, 0b01110], // 64 @
  [0b00100, 0b01010, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001], // 65 A
  [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110], // 66 B
  [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110], // 67 C
  [0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100], // 68 D
  [0b11111, 0b10000, 0b10000, 0b11100, 0b10000, 0b10000, 0b11111], // 69 E
  [0b11111, 0b10000, 0b10000, 0b11100, 0b10000, 0b10000, 0b10000], // 70 F
  [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110], // 71 G
  [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001], // 72 H
  [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111], // 73 I
  [0b00001, 0b00001, 0b00001, 0b00001, 0b00001, 0b10001, 0b01110], // 74 J
  [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001], // 75 K
  [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111], // 76 L
  [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001], // 77 M
  [0b10001, 0b11001, 0b11001, 0b10101, 0b10011, 0b10011, 0b10001], // 78 N
  [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110], // 79 O
  [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000], // 80 P
  [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101], // 81 Q
  [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001], // 82 R
  [0b01110, 0b10001, 0b10000, 0b01110, 0b00001, 0b10001, 0b01110], // 83 S
  [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100], // 84 T
  [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110], // 85 U
  [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100], // 86 V
  [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001], // 87 W
  [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001], // 88 X
  [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100], // 89 Y
  [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111], // 90 Z
  [0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110], // 91 [
  [0b10000, 0b10000, 0b01000, 0b00100, 0b00100, 0b00010, 0b00001], // 92 backslash
  [0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110], // 93 ]
  [0b00100, 0b01010, 0b10001, 0b00000, 0b00000, 0b00000, 0b00000], // 94 ^
  [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111], // 95 _
  [0b01000, 0b01000, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000], // 96 `
  [0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111], // 97 a
  [0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b11110], // 98 b
  [0b00000, 0b00000, 0b01110, 0b10001, 0b10000, 0b10001, 0b01110], // 99 c
  [0b00001, 0b00001, 0b01111, 0b10001, 0b10001, 0b10001, 0b01111], // 100 d
  [0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110], // 101 e
  [0b00010, 0b00100, 0b00100, 0b01111, 0b00100, 0b00100, 0b00100], // 102 f
  [0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b10001, 0b01111], // 103 g
  [0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b10001], // 104 h
  [0b00100, 0b00000, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100], // 105 i
  [0b00010, 0b00000, 0b00010, 0b00010, 0b00010, 0b00010, 0b11100], // 106 j
  [0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010], // 107 k
  [0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11110], // 108 l
  [0b00000, 0b00000, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001], // 109 m
  [0b00000, 0b00000, 0b11110, 0b10001, 0b10001, 0b10001, 0b10001], // 110 n
  [0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110], // 111 o
  [0b00000, 0b00000, 0b11110, 0b10001, 0b10001, 0b11110, 0b10000], // 112 p
  [0b00000, 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001], // 113 q
  [0b00000, 0b00000, 0b01011, 0b01100, 0b00100, 0b00100, 0b00100], // 114 r
  [0b00000, 0b00000, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110], // 115 s
  [0b00000, 0b00100, 0b01111, 0b00100, 0b00100, 0b00100, 0b00010], // 116 t
  [0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10001, 0b01111], // 117 u
  [0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100], // 118 v
  [0b00000, 0b00000, 0b10001, 0b10001, 0b10101, 0b11011, 0b10001], // 119 w
  [0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001], // 120 x
  [0b00000, 0b00000, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110], // 121 y
  [0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111], // 122 z
  [0b00010, 0b00100, 0b00100, 0b01000, 0b00100, 0b00100, 0b00010], // 123 {
  [0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100], // 124 |
  [0b01000, 0b00100, 0b00100, 0b00010, 0b00100, 0b00100, 0b01000], // 125 }
  [0b00000, 0b00000, 0b01011, 0b10100, 0b00000, 0b00000, 0b00000], // 126 ~
  [0b00000, 0b00000, 0b01100, 0b01100, 0b00000, 0b00000, 0b00000], // U+00B7 ·
];

const MID_DOT = 95;
const QUESTION = 63 - 32;

function fontIndex(ch: string): number {
  const code = ch.charCodeAt(0);
  if (code === 0x00b7) return MID_DOT;
  if (code >= 32 && code <= 126) return code - 32;
  return QUESTION;
}

export function renderFontProof(): string {
  // Every glyph as #/… art, 16 per block — the eyeball check for the
  // vendored font (run: node -e "import('./contact_sheet.ts').then(…)").
  const names =
    " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
    "[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~·";
  const lines: string[] = [];
  for (let start = 0; start < FONT.length; start += 16) {
    lines.push("chars " + [...names.slice(start, start + 16)].join(" "));
    for (let r = 0; r < 7; r++) {
      let row = "";
      for (let g = start; g < Math.min(start + 16, FONT.length); g++) {
        const bits = at(at(FONT, g), r);
        for (let c = 4; c >= 0; c--) row += bits & (1 << c) ? "#" : "·";
        row += " ";
      }
      lines.push(row);
    }
    lines.push("");
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Resample, layout, compose
// ---------------------------------------------------------------------------

export const CONTACT_FAMILY_ORDER = [
  "apple",
  "gmailWeb",
  "gmailApp",
  "ganga",
  "outlookWord",
  "outlookWeb",
  "outlookApp",
  "yahoo",
  "samsung",
  "thunderbird",
];

// A capture family that stands in for an audience family takes that
// family's place in the order: backend A's wordApprox is its
// approximation of outlookWord, so it sits between ganga and
// outlookWeb, not among the others.
export const CONTACT_STANDS_IN_FOR: Record<string, string> = {
  wordApprox: "outlookWord",
};

export function orderFamilies(names: string[]): string[] {
  // The fixed family order; missing families are skipped, never
  // reordered; unknown families ("others": chromium-baseline,
  // imagesOff) trail alphabetically (code-unit order,
  // locale-independent so every host agrees).
  const rank = new Map(CONTACT_FAMILY_ORDER.map((f, i) => [f, i]));
  const rankOf = (f: string): number =>
    rank.get(CONTACT_STANDS_IN_FOR[f] ?? f) ?? CONTACT_FAMILY_ORDER.length;
  return [...names].sort((a, b) => {
    const ra = rankOf(a);
    const rb = rankOf(b);
    if (ra !== rb) return ra - rb;
    return a < b ? -1 : a > b ? 1 : 0;
  });
}

// Cell widths: mobile 360, desktop 600. Named viewports
// match by prefix (mobile*/desktop*); explicit W@DPR widths use 360
// below 600 CSS px, else 600.
export function cellWidthForViewport(viewport: string): number {
  if (viewport.startsWith("mobile")) return 360;
  if (viewport.startsWith("desktop")) return 600;
  const w = parseInt(viewport, 10);
  return w < 600 ? 360 : 600;
}

const GUTTER = 8;
const BAR_H = 16;
const MAX_W = 2400;
const MAX_PAGE_H = 2400;
const BG: [number, number, number] = [223, 227, 232];
const BAR: [number, number, number] = [36, 41, 47];
const INK: [number, number, number] = [255, 255, 255];
const FRAME: [number, number, number] = [154, 160, 166];
const HATCH: [number, number, number] = [255, 180, 0];

export function columnsForWidth(cellW: number): number {
  return Math.max(1, Math.floor((MAX_W + GUTTER) / (cellW + GUTTER)));
}

// Box-filter (area-average) scale to `dstW`, aspect-preserving, with
// alpha flattened onto white (the sheet is a review surface, and the
// email canvas is white).
//
// The source box of the last row/column is clamped to the image:
// (dstH * sy) can round to a hair above src.height (1125x962 scaled to
// 360 wide gives 962.0000000000001), which without the clamp reads a
// nonexistent row past the bottom, turns the sum into NaN and paints
// the whole bottom output row black. Clamped, every source pixel read
// lies in [0, width-1] x [0, height-1].
export function scaleToWidth(src: RgbaImage, dstW: number): RgbImage {
  const dstH = Math.max(1, Math.round((src.height * dstW) / src.width));
  const out = new Uint8Array(dstW * dstH * 3);
  const sx = src.width / dstW;
  const sy = src.height / dstH;
  for (let dy = 0; dy < dstH; dy++) {
    const y0 = dy * sy;
    const y1 = Math.min((dy + 1) * sy, src.height);
    for (let dx = 0; dx < dstW; dx++) {
      const x0 = dx * sx;
      const x1 = Math.min((dx + 1) * sx, src.width);
      let r = 0;
      let g = 0;
      let b = 0;
      let area = 0;
      for (let py = Math.floor(y0); py < Math.ceil(y1); py++) {
        const wy = Math.min(py + 1, y1) - Math.max(py, y0);
        if (wy <= 0) continue;
        for (let px = Math.floor(x0); px < Math.ceil(x1); px++) {
          const wx = Math.min(px + 1, x1) - Math.max(px, x0);
          if (wx <= 0) continue;
          const w = wx * wy;
          const s = (py * src.width + px) * 4;
          const a = at(src.data, s + 3) / 255;
          r += w * (at(src.data, s) * a + 255 * (1 - a));
          g += w * (at(src.data, s + 1) * a + 255 * (1 - a));
          b += w * (at(src.data, s + 2) * a + 255 * (1 - a));
          area += w;
        }
      }
      const d = (dy * dstW + dx) * 3;
      out[d] = Math.round(r / area);
      out[d + 1] = Math.round(g / area);
      out[d + 2] = Math.round(b / area);
    }
  }
  return { width: dstW, height: dstH, data: out };
}

function blit(
  canvas: Uint8Array,
  canvasW: number,
  img: RgbImage,
  atX: number,
  atY: number,
): void {
  for (let y = 0; y < img.height; y++) {
    canvas.set(
      img.data.subarray(y * img.width * 3, (y + 1) * img.width * 3),
      ((atY + y) * canvasW + atX) * 3,
    );
  }
}

function fillRect(
  canvas: Uint8Array,
  canvasW: number,
  x: number,
  y: number,
  w: number,
  h: number,
  c: [number, number, number],
): void {
  for (let row = 0; row < h; row++) {
    for (let col = 0; col < w; col++) {
      const d = ((y + row) * canvasW + x + col) * 3;
      canvas[d] = c[0];
      canvas[d + 1] = c[1];
      canvas[d + 2] = c[2];
    }
  }
}

function drawText(
  canvas: Uint8Array,
  canvasW: number,
  text: string,
  atX: number,
  atY: number,
  c: [number, number, number],
): void {
  for (const [i, ch] of text.split("").entries()) {
    const glyph = at(FONT, fontIndex(ch));
    for (const [r, bits] of glyph.entries()) {
      for (let col = 0; col < 5; col++) {
        if (bits & (1 << (4 - col))) {
          const d = ((atY + r) * canvasW + atX + i * 6 + col) * 3;
          canvas[d] = c[0];
          canvas[d + 1] = c[1];
          canvas[d + 2] = c[2];
        }
      }
    }
  }
}

export function labelForCell(
  family: string,
  build: string,
  backend: string,
  approx: boolean,
): string {
  const label = `${family} · ${build.length > 0 ? build : "unknown-build"} · ${backend}`;
  return approx ? label + " [APPROX]" : label;
}

function fitLabel(label: string, cellW: number): string {
  const maxChars = Math.floor((cellW - 8) / 6);
  if (label.length <= maxChars) return label;
  return label.slice(0, Math.max(0, maxChars - 3)) + "...";
}

export interface SheetCell {
  family: string;
  label: string;
  approx: boolean;
  img: RgbImage; // already at the cell width
}

// One page: whole rows, each `columns` cells or fewer, top-aligned.
// Pages fill to MAX_PAGE_H (the width cap's symmetric twin — the sheet
// caps only the width, so the height twin is this file's choice); a single
// row taller than the cap still takes a page of its own (a cell is
// never split — overflow is accepted and deterministic).
export function paginateCells(
  cells: SheetCell[],
  cellW: number,
): SheetCell[][][] {
  const columns = columnsForWidth(cellW);
  const rows: SheetCell[][] = [];
  for (let i = 0; i < cells.length; i += columns)
    rows.push(cells.slice(i, i + columns));
  let page: SheetCell[][] = [];
  const pages: SheetCell[][][] = [page];
  let used = GUTTER;
  for (const row of rows) {
    const rowH = Math.max(...row.map((c) => BAR_H + c.img.height));
    if (page.length > 0 && used + rowH + GUTTER > MAX_PAGE_H) {
      page = [];
      pages.push(page);
      used = GUTTER;
    }
    page.push(row);
    used += rowH + GUTTER;
  }
  return pages;
}

export function renderPage(rows: SheetCell[][], cellW: number): RgbImage {
  const columns = columnsForWidth(cellW);
  const width = columns * (cellW + GUTTER) + GUTTER;
  const laidOut = rows.map((row) => ({
    row,
    rowH: Math.max(...row.map((c) => BAR_H + c.img.height)),
  }));
  const height = GUTTER + laidOut.reduce((sum, r) => sum + r.rowH + GUTTER, 0);
  const canvas = new Uint8Array(width * height * 3);
  fillRect(canvas, width, 0, 0, width, height, BG);
  let y = GUTTER;
  for (const { row, rowH } of laidOut) {
    let x = GUTTER;
    for (const cell of row) {
      fillRect(canvas, width, x, y, cellW, BAR_H, BAR);
      drawText(canvas, width, fitLabel(cell.label, cellW), x + 4, y + 4, INK);
      blit(canvas, width, cell.img, x, y + BAR_H);
      if (cell.approx) {
        // Crosshatch frame over the cell edges (bar + image):
        // 2 px of amber/dark diagonal stripes.
        const boxH = BAR_H + cell.img.height;
        for (let i = 0; i < cellW; i++) {
          for (let t = 0; t < 2; t++) {
            const top = ((i + t) >> 2) % 2 === 0 ? HATCH : BAR;
            const bot = ((i + boxH - 1 - t) >> 2) % 2 === 0 ? HATCH : BAR;
            const dTop = ((y + t) * width + x + i) * 3;
            const dBot = ((y + boxH - 1 - t) * width + x + i) * 3;
            canvas[dTop] = top[0];
            canvas[dTop + 1] = top[1];
            canvas[dTop + 2] = top[2];
            canvas[dBot] = bot[0];
            canvas[dBot + 1] = bot[1];
            canvas[dBot + 2] = bot[2];
          }
        }
        for (let j = 2; j < boxH - 2; j++) {
          for (let t = 0; t < 2; t++) {
            const left = ((x + t + y + j) >> 2) % 2 === 0 ? HATCH : BAR;
            const right =
              ((x + cellW - 1 - t + y + j) >> 2) % 2 === 0 ? HATCH : BAR;
            const dLeft = ((y + j) * width + x + t) * 3;
            const dRight = ((y + j) * width + x + cellW - 1 - t) * 3;
            canvas[dLeft] = left[0];
            canvas[dLeft + 1] = left[1];
            canvas[dLeft + 2] = left[2];
            canvas[dRight] = right[0];
            canvas[dRight + 1] = right[1];
            canvas[dRight + 2] = right[2];
          }
        }
      } else {
        const boxH = BAR_H + cell.img.height;
        for (let i = 0; i < cellW; i++) {
          const dTop = (y * width + x + i) * 3;
          const dBot = ((y + boxH - 1) * width + x + i) * 3;
          canvas[dTop] = FRAME[0];
          canvas[dTop + 1] = FRAME[1];
          canvas[dTop + 2] = FRAME[2];
          canvas[dBot] = FRAME[0];
          canvas[dBot + 1] = FRAME[1];
          canvas[dBot + 2] = FRAME[2];
        }
        for (let j = 1; j < boxH - 1; j++) {
          const dLeft = ((y + j) * width + x) * 3;
          const dRight = ((y + j) * width + x + cellW - 1) * 3;
          canvas[dLeft] = FRAME[0];
          canvas[dLeft + 1] = FRAME[1];
          canvas[dLeft + 2] = FRAME[2];
          canvas[dRight] = FRAME[0];
          canvas[dRight + 1] = FRAME[1];
          canvas[dRight + 2] = FRAME[2];
        }
      }
      x += cellW + GUTTER;
    }
    y += rowH + GUTTER;
  }
  return { width, height, data: canvas };
}

export function composeCells(cells: SheetCell[], cellW: number): RgbImage[] {
  return paginateCells(cells, cellW).map((rows) => renderPage(rows, cellW));
}

// ---------------------------------------------------------------------------
// Story sheets from a run dir (index.json + provenance)
// ---------------------------------------------------------------------------

interface IndexEntry {
  story: string;
  backend: string;
  family: string;
  viewport: string;
  scheme: string;
  images: string;
  png: string | null;
  meta: string | null;
  status: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// A done index entry: it has a PNG.
interface CapturedEntry extends IndexEntry {
  png: string;
}

function readMeta(
  runDir: string,
  metaRel: string,
): {
  build: string;
  backend: string;
  approx: boolean;
} {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(join(runDir, metaRel), "utf8"));
  } catch (err) {
    throw new Error(
      `contact-sheet: cannot read provenance ${metaRel} (${String(err)})`,
    );
  }
  const meta = isRecord(parsed) ? parsed : {};
  const client = isRecord(meta.client) ? meta.client : {};
  const build = typeof client.build === "string" ? client.build : "";
  const backend = typeof meta.backend === "string" ? meta.backend : "?";
  return { build, backend, approx: meta.approximation === true };
}

export function sheetFileName(
  viewport: string,
  scheme: string,
  page: number,
  pages: number,
): string {
  // contact-<viewport>-<scheme>.png, or -p<N> when split.
  if (pages === 1) return `contact-${viewport}-${scheme}.png`;
  return `contact-${viewport}-${scheme}-p${page}.png`;
}

// Every (viewport, scheme) sheet for one story. Reads the run's
// index.json (done entries carry the viewport names the provenance
// files lack), prefers images=on per family, orders families per
// the fixed order, and writes the sheets into the story's run dir.
// Returns the written relative paths.
export function composeStorySheets(runDir: string, story: string): string[] {
  let index: IndexEntry[];
  try {
    index = JSON.parse(
      readFileSync(join(runDir, "index.json"), "utf8"),
    ) as IndexEntry[];
  } catch (err) {
    throw new Error(
      `contact-sheet: cannot read ${join(runDir, "index.json")} (${String(err)})`,
    );
  }
  const groups = new Map<
    string,
    { viewport: string; scheme: string; entries: CapturedEntry[] }
  >();
  for (const e of index) {
    const png = e.png;
    if (e.story !== story || e.status !== "done" || png === null) continue;
    const key = e.viewport + "\n" + e.scheme;
    let group = groups.get(key);
    if (group === undefined) {
      group = { viewport: e.viewport, scheme: e.scheme, entries: [] };
      groups.set(key, group);
    }
    group.entries.push({ ...e, png });
  }
  const written: string[] = [];
  const storyDir = join(runDir, story);
  const byKey = (a: [string, unknown], b: [string, unknown]): number =>
    a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0;
  for (const [, { viewport, scheme, entries }] of [...groups.entries()].sort(
    byKey,
  )) {
    const byFamily = new Map<string, CapturedEntry[]>();
    for (const e of entries) {
      const cands = byFamily.get(e.family);
      if (cands === undefined) byFamily.set(e.family, [e]);
      else cands.push(e);
    }
    // One capture per family: images=on wins, then the first path
    // (deterministic — the same run always picks the same PNG).
    const before = (a: CapturedEntry, b: CapturedEntry): boolean => {
      const ai = a.images === "on" ? 0 : 1;
      const bi = b.images === "on" ? 0 : 1;
      return ai !== bi ? ai < bi : a.png < b.png;
    };
    const picked = [...byFamily.entries()].map(([family, cands]) => ({
      family,
      // Every family list holds at least the entry that created it.
      entry: cands.reduce((best, e) => (before(e, best) ? e : best)),
    }));
    const order = orderFamilies(picked.map((p) => p.family));
    picked.sort((a, b) => order.indexOf(a.family) - order.indexOf(b.family));
    const cellW = cellWidthForViewport(viewport);
    const cells: SheetCell[] = picked.map(({ family, entry }) => {
      if (entry.meta === null)
        throw new Error(
          `contact-sheet: ${entry.png} has no provenance (contact sheets label from meta)`,
        );
      const meta = readMeta(runDir, entry.meta);
      const src = readPng(readFileSync(join(runDir, entry.png)));
      return {
        family,
        label: labelForCell(family, meta.build, meta.backend, meta.approx),
        approx: meta.approx,
        img: scaleToWidth(src, cellW),
      };
    });
    const pages = composeCells(cells, cellW);
    mkdirSync(storyDir, { recursive: true });
    pages.forEach((page, i) => {
      const name = sheetFileName(viewport, scheme, i + 1, pages.length);
      writeFileSync(join(storyDir, name), writePng(page));
      written.push(join(story, name));
    });
  }
  return written.sort();
}

const isMain =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;

if (isMain) {
  const [runDir, story] = process.argv.slice(2);
  if (runDir === undefined || story === undefined) {
    process.stderr.write("usage: contact_sheet.ts <runDir> <story>\n");
    process.exit(2);
  }
  try {
    for (const rel of composeStorySheets(resolve(runDir), story))
      process.stdout.write(rel + "\n");
  } catch (err) {
    process.stderr.write(
      `contact-sheet: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    process.exit(1);
  }
}
