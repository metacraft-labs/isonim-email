// tools/capture/latency.ts — recorded run latency and the rolling-median
// regression warning.
//
// Wall time on shared machines (CI runners, loaded workstations) says
// more about the neighbours than about the code, so capture latency is
// RECORDED, never asserted: every successful run appends one line to a
// history file and compares its total against the rolling median of
// the previous runs of the same selection. A run slower than the
// median by more than REGRESSION_FACTOR prints a warning in the run
// summary; nothing fails on it.
//
// Pure helpers (median, selection key, verdict) plus two small file
// helpers; email-shots.ts wires them in.

import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";

/** How many previous runs of the same selection the median spans. */
export const ROLLING_WINDOW = 20;
/** Fewer previous samples than this: record only, no verdict. */
export const MIN_SAMPLES = 3;
/** Warn when total > median × this (i.e. more than 50% slower). */
export const REGRESSION_FACTOR = 1.5;

export interface HistoryEntry {
  run: string;
  date: string;
  commit: string;
  dirty: boolean;
  key: string;
  requests: number;
  total_ms: number;
  captures_ms: number;
}

export interface Selection {
  stories: string[];
  families: string[];
  viewports: string[];
  schemes: string[];
  images: string[];
  cache: boolean;
}

export interface Verdict {
  samples: number;
  median_ms: number | null;
  threshold_ms: number | null;
  regression: boolean;
  warning: string | null;
}

export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  const hi = s[mid];
  const lo = s[mid - 1];
  // hi exists whenever s is non-empty; lo whenever the length is even.
  if (hi === undefined) return null;
  return s.length % 2 === 1 || lo === undefined ? hi : (lo + hi) / 2;
}

/** Runs are only comparable when they captured the same matrix the
 *  same way; the key covers every selection axis plus cache use. */
export function selectionKey(sel: Selection): string {
  const norm = {
    stories: [...sel.stories].sort(),
    families: [...sel.families].sort(),
    viewports: [...sel.viewports].sort(),
    schemes: [...sel.schemes].sort(),
    images: [...sel.images].sort(),
    cache: sel.cache,
  };
  return createHash("sha256")
    .update(JSON.stringify(norm))
    .digest("hex")
    .slice(0, 16);
}

/** Compare `totalMs` with the rolling median of the previous runs
 *  (same key, last ROLLING_WINDOW of them). */
export function latencyVerdict(
  history: HistoryEntry[],
  key: string,
  totalMs: number,
): Verdict {
  const prev = history
    .filter((h) => h.key === key && Number.isFinite(h.total_ms))
    .slice(-ROLLING_WINDOW)
    .map((h) => h.total_ms);
  const med = prev.length >= MIN_SAMPLES ? median(prev) : null;
  if (med === null)
    return {
      samples: prev.length,
      median_ms: null,
      threshold_ms: null,
      regression: false,
      warning: null,
    };
  const threshold = Math.round(med * REGRESSION_FACTOR);
  const regression = totalMs > threshold;
  return {
    samples: prev.length,
    median_ms: med,
    threshold_ms: threshold,
    regression,
    warning: regression
      ? `latency warning: this run took ${totalMs} ms, more than 50% over the rolling median ${med} ms of the previous ${prev.length} run(s) of the same selection (recorded, not a failure)`
      : null,
  };
}

/** Malformed lines are skipped: the history is advisory. */
export function readHistory(path: string): HistoryEntry[] {
  if (!existsSync(path)) return [];
  const out: HistoryEntry[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (line.trim().length === 0) continue;
    try {
      const e = JSON.parse(line);
      if (typeof e.key === "string" && typeof e.total_ms === "number")
        out.push(e as HistoryEntry);
    } catch {
      /* skip */
    }
  }
  return out;
}

export function appendHistory(path: string, entry: HistoryEntry): void {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(entry) + "\n");
}
