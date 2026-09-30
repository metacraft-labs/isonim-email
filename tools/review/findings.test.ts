// tools/review/findings.test.ts — fixtures for the findings log:
// entry shape roundtrip, wontfix-needs-reason and
// degradation-needs-rules
// enforcement (both directions), list filters, F-id sequencing, and
// the rateFinding cap. Run with:
//   node --test tools/review/findings.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendFinding,
  defaultFindingsPath,
  listFindings,
  parseFindingLine,
  rateFinding,
  readFindings,
  type Finding,
  type NewFinding,
} from "./findings.ts";

function fields(over: Partial<NewFinding> = {}): NewFinding {
  return {
    story: "invoiceReady/typical",
    family: "outlookWord",
    backend: "c",
    viewport: "desktop@120dpi",
    severity: "P2",
    finding: "hero image 25% too large; overflows container",
    capture: "build/email-shots/r41/a-outlookWord-classic-desktop-light-on.png",
    rules: ["R-OL-08"],
    status: "open",
    ...over,
  };
}

function tmpFile(): string {
  return join(mkdtempSync(join(tmpdir(), "findings-")), "findings.jsonl");
}

describe("findings entry shape", () => {
  it("roundtrips the exact example entry shape", () => {
    const line =
      '{"id":"F12","story":"invoiceReady/typical","family":"outlookWord",' +
      '"backend":"c","viewport":"desktop@120dpi","severity":"P2",' +
      '"finding":"hero image 25% too large; overflows container",' +
      '"capture":"build/email-shots/r41/…png","rules":["R-OL-08"],' +
      '"status":"open","fixed_in_run":null}';
    const f = parseFindingLine(line);
    assert.equal(f.id, "F12");
    assert.equal(f.status, "open");
    assert.equal(f.fixed_in_run, null);
    assert.deepEqual(Object.keys(f).sort(), [
      "backend",
      "capture",
      "family",
      "finding",
      "fixed_in_run",
      "id",
      "rules",
      "severity",
      "status",
      "story",
      "viewport",
    ]);
  });

  it("rejects a bad status and a bad severity", () => {
    const path = tmpFile();
    assert.throws(() =>
      appendFinding(path, fields({ status: "closed" as Finding["status"] })),
    );
    assert.throws(() => appendFinding(path, fields({ severity: "P9" })));
  });
});

describe("wontfix and degradation enforcement", () => {
  it("wontfix requires a reason, on append and on parse", () => {
    const path = tmpFile();
    assert.throws(() => appendFinding(path, fields({ status: "wontfix" })));
    assert.throws(() =>
      parseFindingLine(
        JSON.stringify({ ...fields(), id: "F1", status: "wontfix" }),
      ),
    );
    const kept = appendFinding(
      path,
      fields({
        status: "wontfix",
        reason: "Word clips VML by design; documented",
      }),
    );
    assert.equal(kept.reason, "Word clips VML by design; documented");
  });

  it("degradation requires a rules entry, on append and on parse", () => {
    const path = tmpFile();
    assert.throws(() =>
      appendFinding(path, fields({ status: "degradation", rules: [] })),
    );
    assert.throws(() =>
      parseFindingLine(
        JSON.stringify({
          ...fields(),
          id: "F1",
          status: "degradation",
          rules: [],
        }),
      ),
    );
    const kept = appendFinding(
      path,
      fields({ status: "degradation", rules: ["R-BTN-02"] }),
    );
    assert.deepEqual(kept.rules, ["R-BTN-02"]);
  });
});

describe("findings file", () => {
  it("sequences F-ids, reads back, and filters", () => {
    const path = tmpFile();
    assert.deepEqual(readFindings(path), []);
    const a = appendFinding(path, fields({}));
    const b = appendFinding(
      path,
      fields({
        story: "receipt",
        severity: "P4",
        status: "fixed",
        fixed_in_run: "a1-x",
      }),
    );
    assert.equal(a.id, "F1");
    assert.equal(b.id, "F2");
    assert.equal(readFindings(path).length, 2);
    assert.equal(listFindings(path, { status: "open" }).length, 1);
    assert.equal(listFindings(path, { story: "receipt" })[0].id, "F2");
    assert.equal(listFindings(path, { severity: "P2" })[0].id, "F1");
    assert.equal(listFindings(path, { family: "outlookWord" }).length, 2);
    assert.equal(listFindings(path, { family: "gmailWeb" }).length, 0);
  });

  it("defaults to build/email-shots/findings.jsonl", () => {
    assert.ok(
      defaultFindingsPath().endsWith(
        join("build", "email-shots", "findings.jsonl"),
      ),
    );
  });
});

describe("rateFinding", () => {
  it("caps at 4 when anything is missing, passes through otherwise", () => {
    assert.equal(rateFinding(1), 4);
    assert.equal(rateFinding(3), 4);
    assert.equal(rateFinding(2, 3), 3);
    assert.equal(rateFinding(0), 10);
    assert.equal(rateFinding(0, 7), 7);
    assert.throws(() => rateFinding(-1));
  });
});
