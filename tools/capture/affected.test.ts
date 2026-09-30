// tools/capture/affected.test.ts — fixtures: family
// selection from the change, dark-scheme trigger, porcelain parsing, and
// changed-files collection with a stubbed runner. Run with:
//   node --test tools/capture/affected.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  BACKEND_A_FAMILIES,
  changedFilesSince,
  darkNeeded,
  mapAffectSet,
  parsePorcelain,
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

describe("parsePorcelain", () => {
  it("takes the path field of every non-empty line, incl '??', and unquotes", () => {
    const out = [
      " M src/isonim_email/mso/cond.nim",
      "A  src/isonim_email/new.nim",
      "?? tests/t7_stories.nim",
      '?? "docs/my notes.md"',
      "",
    ].join("\n");
    assert.deepEqual(parsePorcelain(out), [
      "src/isonim_email/mso/cond.nim",
      "src/isonim_email/new.nim",
      "tests/t7_stories.nim",
      "docs/my notes.md",
    ]);
  });

  it("empty output → no files", () => {
    assert.deepEqual(parsePorcelain(""), []);
  });
});

describe("changedFilesSince", () => {
  it("unions diff + status, trims, dedupes; runner stubbed", () => {
    const calls: string[][] = [];
    const run = (cmd: string[]): string => {
      calls.push(cmd);
      if (cmd[1] === "diff") {
        return "src/isonim_email/mso/cond.nim\nsrc/isonim_email/style/tokens.nim\n";
      }
      return " M src/isonim_email/style/tokens.nim\n?? tests/t7_stories.nim\n";
    };
    assert.deepEqual(changedFilesSince(run, "abc123"), [
      "src/isonim_email/mso/cond.nim",
      "src/isonim_email/style/tokens.nim",
      "tests/t7_stories.nim",
    ]);
    assert.deepEqual(calls, [
      ["git", "diff", "--name-only", "abc123", "HEAD"],
      ["git", "status", "--porcelain"],
    ]);
  });
});
