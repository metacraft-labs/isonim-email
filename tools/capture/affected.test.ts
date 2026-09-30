// tools/capture/affected.test.ts — fixtures: family
// selection from the change, dark-scheme trigger, the all-families
// fallback, and the tree-to-tree changed-files diff with a stubbed
// runner (the real-git half lives in affected_worktree.test.ts). Run with:
//   node --test tools/capture/affected.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  BACKEND_A_FAMILIES,
  changedFilesSince,
  darkNeeded,
  mapAffectSet,
  familiesForChange,
  selectFamilies,
} from "./affected.ts";

const ALL8 = [...BACKEND_A_FAMILIES];
const NO_GANGA = ALL8.filter((f) => f !== "ganga");

describe("mapAffectSet", () => {
  it("OUTLOOK_WORD → wordApprox only", () => {
    assert.deepEqual(mapAffectSet("OUTLOOK_WORD"), ["wordApprox"]);
  });

  it("HEAD → all except ganga", () => {
    assert.deepEqual(mapAffectSet("HEAD"), NO_GANGA);
  });

  it("ALL → all 8", () => {
    assert.deepEqual(mapAffectSet("ALL"), ALL8);
  });
});

describe("selectFamilies", () => {
  it("mso/ edit → wordApprox only", () => {
    assert.deepEqual(selectFamilies(["src/isonim_email/mso/cond.nim"]), [
      "wordApprox",
    ]);
  });

  it("passes/head.nim edit → all except ganga", () => {
    assert.deepEqual(
      selectFamilies(["src/isonim_email/passes/head.nim"]),
      NO_GANGA,
    );
  });

  it("passes/styles.nim edit → all 8 (negative control: only head.nim narrows)", () => {
    assert.deepEqual(
      selectFamilies(["src/isonim_email/passes/styles.nim"]),
      ALL8,
    );
  });

  it("unknown path → all 8", () => {
    assert.deepEqual(selectFamilies(["docs/notes.md"]), ALL8);
  });

  it("unions across files and keeps BACKEND_A_FAMILIES order", () => {
    assert.deepEqual(
      selectFamilies([
        "src/isonim_email/mso/cond.nim",
        "src/isonim_email/passes/head.nim",
      ]),
      NO_GANGA,
    );
    assert.deepEqual(
      selectFamilies([
        "src/isonim_email/mso/cond.nim",
        "src/isonim_email/passes/styles.nim",
      ]),
      ALL8,
    );
  });

  it("empty change → no families", () => {
    assert.deepEqual(selectFamilies([]), []);
  });
});

describe("darkNeeded", () => {
  it("true for a token change", () => {
    assert.equal(darkNeeded(["src/isonim_email/style/tokens.nim"]), true);
  });

  it("false for an mso-only change", () => {
    assert.equal(darkNeeded(["src/isonim_email/mso/cond.nim"]), false);
  });
});

describe("changedFilesSince", () => {
  it("diffs the previous run's tree against this run's; runner stubbed", () => {
    const calls: string[][] = [];
    const run = (cmd: string[]): string => {
      calls.push(cmd);
      return "src/isonim_email/mso/cond.nim\n  \nsrc/isonim_email/style/tokens.nim\n";
    };
    assert.deepEqual(changedFilesSince(run, "abc123", "def456"), [
      "src/isonim_email/mso/cond.nim",
      "src/isonim_email/style/tokens.nim",
    ]);
    assert.deepEqual(calls, [
      ["git", "diff", "--name-only", "abc123", "def456"],
    ]);
  });
});

describe("familiesForChange", () => {
  const all = ["apple", "thunderbird", "wordApprox"];
  it("selects from the changed files when there are any", () => {
    assert.deepEqual(
      familiesForChange(["src/isonim_email/mso/cond.nim"], all),
      ["wordApprox"],
    );
  });
  it("selects every family when the MIME changed but no file did", () => {
    assert.deepEqual(familiesForChange([], all), all);
  });
});
