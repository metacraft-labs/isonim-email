// tools/capture/latency.test.ts — the recorded-latency helpers: median,
// selection keys, the rolling-median regression verdict and the
// history file roundtrip. No mocks: pure functions plus a real temp
// file. Run with:
//   node --test tools/capture/latency.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendHistory,
  latencyVerdict,
  median,
  MIN_SAMPLES,
  readHistory,
  REGRESSION_FACTOR,
  ROLLING_WINDOW,
  selectionKey,
  type HistoryEntry,
  type Selection,
} from "./latency.ts";

function entry(key: string, total: number, n = 0): HistoryEntry {
  return {
    run: `a1-${n}`,
    date: "2026-01-01T00:00:00Z",
    commit: "c",
    dirty: false,
    key,
    requests: 48,
    total_ms: total,
    captures_ms: total - 100,
  };
}

function sel(): Selection {
  return {
    stories: ["canary"],
    families: ["apple", "thunderbird"],
    viewports: ["mobile", "desktop"],
    schemes: ["light", "dark"],
    images: ["on"],
    cache: false,
  };
}

describe("latency helpers", () => {
  it("median of odd, even and empty inputs", () => {
    assert.equal(median([3, 1, 2]), 2);
    assert.equal(median([4, 1, 3, 2]), 2.5);
    assert.equal(median([]), null);
  });

  it("selection key ignores order but not content", () => {
    const a = sel();
    const b = { ...sel(), families: ["thunderbird", "apple"] };
    assert.equal(selectionKey(a), selectionKey(b));
    assert.notEqual(selectionKey(a), selectionKey({ ...a, cache: true }));
    assert.notEqual(
      selectionKey(a),
      selectionKey({ ...a, schemes: ["light"] }),
    );
  });

  it("records only until there are enough earlier samples", () => {
    const h = Array.from({ length: MIN_SAMPLES - 1 }, (_, i) =>
      entry("k", 1000, i),
    );
    const v = latencyVerdict(h, "k", 999_999);
    assert.equal(v.median_ms, null);
    assert.equal(v.regression, false);
    assert.equal(v.warning, null);
    assert.equal(v.samples, MIN_SAMPLES - 1);
  });

  it("warns beyond 50% of the rolling median, not at it", () => {
    const h = [1000, 1100, 900, 1000, 1050].map((t, i) => entry("k", t, i));
    const at = latencyVerdict(h, "k", 1000 * REGRESSION_FACTOR);
    assert.equal(at.median_ms, 1000);
    assert.equal(at.regression, false);
    assert.equal(at.warning, null);
    const over = latencyVerdict(h, "k", 1501);
    assert.equal(over.regression, true);
    assert.match(over.warning ?? "", /1501 ms.*rolling median 1000 ms/);
  });

  it("only same-key runs within the window count", () => {
    const old = Array.from({ length: 50 }, (_, i) => entry("k", 100, i));
    const recent = Array.from({ length: ROLLING_WINDOW }, (_, i) =>
      entry("k", 10_000, 100 + i),
    );
    const other = Array.from({ length: 10 }, (_, i) => entry("x", 1, i));
    const v = latencyVerdict([...old, ...other, ...recent], "k", 12_000);
    assert.equal(v.samples, ROLLING_WINDOW);
    assert.equal(v.median_ms, 10_000);
    assert.equal(v.regression, false);
  });

  it("history roundtrip skips malformed lines", () => {
    const dir = mkdtempSync(join(tmpdir(), "latency-test-"));
    const path = join(dir, "nested", "latency-history.jsonl");
    assert.deepEqual(readHistory(path), []);
    appendHistory(path, entry("k", 1234, 1));
    appendHistory(path, entry("k", 4321, 2));
    writeFileSync(path, "not json\n{}\n", { flag: "a" });
    const got = readHistory(path);
    assert.equal(got.length, 2);
    assert.deepEqual(
      got.map((e) => e.total_ms),
      [1234, 4321],
    );
  });
});
