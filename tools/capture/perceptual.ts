#!/usr/bin/env node
// tools/capture/perceptual.ts — Tier-2 perceptual PNG diff.
//
// Tier-2: every story's captures are diffed against the
// approved baselines in tests/baselines/. The diff decodes both PNGs
// with the PNG codec (contact_sheet.ts) and counts pixels whose
// channels differ beyond tolerance.

import { readPng } from "./contact_sheet.ts";

export interface PngDiff {
  diffPixels: number;
  diffRatio: number;
}

// Per-channel tolerance: absolute channel differences at or below
// this are subpixel noise, not a visible change.
const CHANNEL_TOLERANCE = 2;

export function diffPng(a: Buffer, b: Buffer): PngDiff {
  const imgA = readPng(a); // throws on malformed PNG — never silently compared
  const imgB = readPng(b);
  if (imgA.width !== imgB.width || imgA.height !== imgB.height)
    throw new Error(
      `perceptual: dimension mismatch (${imgA.width}x${imgA.height} vs ` +
        `${imgB.width}x${imgB.height}) — refusing to compare`,
    );
  const totalPixels = imgA.width * imgA.height;
  let diffPixels = 0;
  for (let i = 0; i < imgA.data.length; i++) {
    if (Math.abs(imgA.data[i] - imgB.data[i]) > CHANNEL_TOLERANCE) {
      diffPixels++;
      // Skip the pixel's remaining channels: one over-tolerance
      // channel already marks the whole pixel as different.
      i += 3 - (i % 4);
    }
  }
  return { diffPixels, diffRatio: diffPixels / totalPixels };
}
