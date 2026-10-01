// tools/review/broken_story.test.ts — the check of a recorded
// broken-story review.
//
// The reviewer is an agent and cannot run here; what this pins is the
// check of what a session recorded: the report format the brief asks
// for is parsed, and the item passes only when the broken story is
// reported missing its logo with a rating of 4 or lower, the intact
// story passes, and the findings list records the broken story's P1.
// The reports below are written in the brief's report format; each
// failing case changes one thing from the passing one.
//
// No test double: the inputs are plain values (report text and
// finding entries in the findings list's own format).
//
// Run with:
//   node --test tools/review/broken_story.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  BROKEN_STORY,
  checkBrokenStoryReview,
  INTACT_STORY,
  parseReport,
} from "./broken_story.ts";
import type { Finding } from "./findings.ts";

const RUN = "build/email-shots/review-broken-x";

const brokenText = `Expected elements: missing-"Acme logo" (a-chromium-baseline-chromium-desktop-light-on.png)
[P1] a-chromium-baseline-chromium-desktop-light-on.png: the logo below the line item is not there.
Top fix: restore the image.
Rating: 3/10`;

const intactText = `Expected elements: present
[P3] a-chromium-baseline-chromium-desktop-light-on.png: tight gap above the logo.
Rating: 7/10`;

function finding(over: Partial<Finding> = {}): Finding {
  return {
    id: "F1",
    story: BROKEN_STORY,
    family: "chromium-baseline",
    backend: "a",
    viewport: "mobile,desktop",
    severity: "P1",
    finding: "reviewer: Acme logo missing below the line item (rated 3/10)",
    capture: `${RUN}/${BROKEN_STORY}/a-chromium-baseline-chromium-desktop-light-on.png`,
    rules: [],
    status: "open",
    fixed_in_run: null,
    ...over,
  };
}

function run(
  broken = brokenText,
  intact = intactText,
  findings: Finding[] = [finding()],
): string[] {
  return checkBrokenStoryReview({
    broken: parseReport(broken),
    intact: parseReport(intact),
    findings,
    runRel: RUN,
  });
}

describe("parseReport", () => {
  it("reads the expected-elements line and the rating", () => {
    const r = parseReport(brokenText);
    assert.equal(r.expected.startsWith('missing-"Acme logo"'), true);
    assert.equal(r.rating, 3);
    assert.equal(parseReport("Rating: 7 / 10").rating, 7);
    assert.equal(parseReport("no rating here").rating, null);
    assert.equal(parseReport("nothing").expected, "");
  });
});

describe("checkBrokenStoryReview", () => {
  it("passes a session that caught the missing logo and passed the intact story", () => {
    assert.deepEqual(run(), []);
  });

  it("fails when the broken story is rated above 4", () => {
    const p = run(brokenText.replace("Rating: 3/10", "Rating: 5/10"));
    assert.equal(p.length, 1);
    assert.match(p[0]!, /rated 5\/10/);
  });

  it("fails when the broken story's report does not name anything missing", () => {
    const p = run(
      brokenText.replace(
        /^Expected elements: .*$/m,
        "Expected elements: present",
      ),
    );
    assert.ok(
      p.some((x) => /does not start by naming a missing element/.test(x)),
      p.join("\n"),
    );
  });

  it("fails when something other than the logo is reported missing", () => {
    const p = run(
      brokenText.replace(
        /^Expected elements: .*$/m,
        'Expected elements: missing-"Widget: $10.00"',
      ),
    );
    assert.ok(
      p.some((x) => /not the Acme logo/.test(x)),
      p.join("\n"),
    );
  });

  it("fails when the intact story does not pass", () => {
    const low = run(
      brokenText,
      intactText.replace("Rating: 7/10", "Rating: 4/10"),
    );
    assert.ok(
      low.some((x) => /intact story is rated 4\/10/.test(x)),
      low.join("\n"),
    );
    const miss = run(
      brokenText,
      intactText.replace("present", "missing-heading"),
    );
    assert.ok(
      miss.some((x) => /does not find every element present/.test(x)),
      miss.join("\n"),
    );
    const open = run(brokenText, intactText, [
      finding(),
      finding({
        story: INTACT_STORY,
        severity: "P2",
        capture: `${RUN}/receipt/x.png`,
      }),
    ]);
    assert.ok(
      open.some((x) => /open P1\/P2 for the intact/.test(x)),
      open.join("\n"),
    );
  });

  it("fails without the broken story's P1 in the findings list of this run", () => {
    for (const findings of [
      [],
      [finding({ severity: "P2" })],
      [finding({ finding: "heading off-centre" })],
      [finding({ capture: "build/email-shots/other-run/receiptB/a.png" })],
    ]) {
      const p = run(brokenText, intactText, findings);
      assert.ok(
        p.some((x) => /no P1 entry/.test(x)),
        JSON.stringify(findings),
      );
    }
  });

  it("fails a report without a rating line", () => {
    const p = run(brokenText.replace("Rating: 3/10", ""));
    assert.ok(
      p.some((x) => /no 'Rating: N\/10' line/.test(x)),
      p.join("\n"),
    );
  });
});
