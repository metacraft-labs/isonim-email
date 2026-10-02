// tools/review/findings.test.ts — fixtures for the findings log:
// entry shape roundtrip, wontfix-needs-reason and
// degradation-needs-rules
// enforcement (both directions), list filters, F-id sequencing, and
// the rateFinding cap. Run with:
//   node --test tools/review/findings.test.ts

import { after, describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendFinding,
  defaultFindingsPath,
  listFindings,
  parseFindingLine,
  rateFinding,
  readFindings,
  updateFindingStatus,
  type Finding,
  type NewFinding,
} from "./findings.ts";

// Every scratch directory this file makes is under one temp dir, removed
// when the file's tests are done.
const scratch = mkdtempSync(join(tmpdir(), "findings-test-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

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
  return join(mkdtempSync(join(scratch, "findings-")), "findings.jsonl");
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

  it("reads only the entry format's fields: unknown keys are dropped", () => {
    // The entry format is closed — exactly the example's fields plus a
    // wontfix reason. A reader returns that shape and nothing else; a
    // key outside it is ignored on read (not rejected), and the line in
    // the file is left as written (the tool only ever appends).
    const extra = {
      id: "F3",
      ...fields(),
      fixed_in_run: null,
      note: "not a field of the format",
      reason: 7, // not a string: not a reason
    };
    const f = parseFindingLine(JSON.stringify(extra));
    assert.deepEqual(f, { ...fields(), id: "F3", fixed_in_run: null });
    assert.ok(!("note" in f) && !("reason" in f));
    const kept = parseFindingLine(
      JSON.stringify({ ...extra, reason: "kept: a string reason" }),
    );
    assert.equal(kept.reason, "kept: a string reason");
    assert.ok(!("note" in kept));
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
    assert.deepEqual(
      listFindings(path, { story: "receipt" }).map((f) => f.id),
      ["F2"],
    );
    assert.deepEqual(
      listFindings(path, { severity: "P2" }).map((f) => f.id),
      ["F1"],
    );
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

describe("updateFindingStatus", () => {
  it("changes one entry's status in place and keeps every other byte", () => {
    const dir = mkdtempSync(join(scratch, "findings-update-"));
    const path = join(dir, "findings.jsonl");
    appendFinding(path, fields());
    appendFinding(path, fields({ story: "alert" }));
    // A key outside the format survives on the changed entry.
    const lines = readFileSync(path, "utf8").split("\n");
    lines[1] = lines[1]!.replace('"id":"F2"', '"id":"F2","note":"kept"');
    writeFileSync(path, lines.join("\n"));
    const before = readFileSync(path, "utf8").split("\n");
    const f = updateFindingStatus(path, "F2", {
      status: "fixed",
      fixed_in_run: "r2",
    });
    assert.equal(f.status, "fixed");
    assert.equal(f.fixed_in_run, "r2");
    const after = readFileSync(path, "utf8").split("\n");
    assert.equal(after.length, before.length);
    assert.equal(after[0], before[0]);
    assert.match(after[1]!, /"note":"kept"/);
    assert.match(after[1]!, /"status":"fixed"/);
    assert.match(after[1]!, /"fixed_in_run":"r2"/);
    assert.deepEqual(
      listFindings(path, { status: "open" }).map((x) => x.id),
      ["F1"],
    );
    // wontfix carries its reason; the entry check still applies.
    const w = updateFindingStatus(path, "F1", {
      status: "wontfix",
      reason: "measured: a capture artefact",
    });
    assert.equal(w.reason, "measured: a capture artefact");
    assert.throws(
      () => updateFindingStatus(path, "F2", { status: "wontfix" }),
      /reason/,
    );
    rmSync(dir, { recursive: true, force: true });
  });

  it("records the owner of an entry left open", () => {
    const dir = mkdtempSync(join(scratch, "findings-update-"));
    const path = join(dir, "findings.jsonl");
    appendFinding(path, fields({ severity: "P3", owner: "text leaves" }));
    appendFinding(path, fields({ severity: "P3" }));
    assert.equal(readFindings(path)[0]!.owner, "text leaves");
    assert.equal(readFindings(path)[1]!.owner, undefined);
    const f = updateFindingStatus(path, "F2", {
      status: "open",
      owner: "capture provider",
    });
    assert.equal(f.owner, "capture provider");
    assert.equal(readFindings(path)[1]!.owner, "capture provider");
    assert.throws(() => appendFinding(path, fields({ owner: "" })), /owner/);
    rmSync(dir, { recursive: true, force: true });
  });

  it("refuses a fixed entry without its run, and an unknown id", () => {
    const dir = mkdtempSync(join(scratch, "findings-update-"));
    const path = join(dir, "findings.jsonl");
    appendFinding(path, fields());
    const before = readFileSync(path, "utf8");
    assert.throws(
      () => updateFindingStatus(path, "F1", { status: "fixed" }),
      /fixed_in_run/,
    );
    assert.throws(
      () =>
        updateFindingStatus(path, "F9", { status: "fixed", fixed_in_run: "r" }),
      /no entry with the id 'F9'/,
    );
    assert.equal(readFileSync(path, "utf8"), before);
    rmSync(dir, { recursive: true, force: true });
  });
});
