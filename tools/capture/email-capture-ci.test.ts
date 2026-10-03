// tools/capture/email-capture-ci.test.ts — fixtures for
// Tier-1 (+ the Tier-2 identical-pass and pixel-flip failure,
// + Tier-3 over hand-built assertions.json): a fake run dir built
// in tmp from the checked-in genesis PNGs passes Tier-1, and fails
// naming the variant once a single byte of one canary copy flips.
// Approval state: a story awaiting re-approval (PENDING-REVIEW) is not
// compared but is always reported, --require-approved fails on it,
// --update-baselines leaves it alone and --approve clears it; the
// checked-in canary is never pending.
// Run with:
//   node --test tools/capture/email-capture-ci.test.ts

import { after, describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
  mkdtempSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  PENDING_MARKER,
  readPendingReview,
  tier1Check,
  tier2Check,
  tier2Pending,
  tier3Check,
  updateBaselines,
} from "./email-capture-ci.ts";
import { readPng, writePng } from "./contact_sheet.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
const baselinesDir = join(repoRoot, "tests", "baselines");

// Every tmp dir the fixtures create, removed when the file finishes.
const tmpDirs: string[] = [];
function tmp(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tmpDirs.push(dir);
  return dir;
}
after(() => {
  for (const dir of tmpDirs) rmSync(dir, { recursive: true, force: true });
});

// A run dir in tmp whose PNGs are copies of the checked-in genesis
// baselines, with a matching index.json (only story/status/png feed
// the checks).
function fakeRunFromBaselines(): string {
  if (!existsSync(baselinesDir))
    throw new Error(
      `no ${baselinesDir} — regenerate with \`just email-capture-ci --update-baselines\``,
    );
  const runDir = tmp("capture-ci-test-");
  const index: Record<string, unknown>[] = [];
  const stories = readdirSync(baselinesDir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .sort();
  for (const story of stories) {
    const storySrc = join(baselinesDir, story);
    const storyDst = join(runDir, story);
    mkdirSync(storyDst, { recursive: true });
    for (const file of readdirSync(storySrc)
      .filter((f) => f.endsWith(".png"))
      .sort()) {
      cpSync(join(storySrc, file), join(storyDst, file));
      index.push({ story, status: "done", png: `${story}/${file}` });
    }
  }
  writeFileSync(join(runDir, "index.json"), JSON.stringify(index));
  return runDir;
}

// A tmp copy of the checked-in baselines with every PENDING-REVIEW
// marker removed, then `pending` stories marked: the tests choose the
// approval state instead of inheriting whatever the tree holds today.
function baselinesCopy(pending: string[] = []): string {
  const dir = tmp("capture-ci-baselines-");
  cpSync(baselinesDir, dir, { recursive: true });
  for (const e of readdirSync(dir, { withFileTypes: true }))
    if (e.isDirectory())
      rmSync(join(dir, e.name, PENDING_MARKER), { force: true });
  for (const story of pending)
    writeFileSync(join(dir, story, PENDING_MARKER), "test: out of date\n");
  return dir;
}

// Shifts the red channel of 2% of one PNG's pixels by 128 — always
// past the ±2 channel tolerance, and a ≈0.02 diff ratio, over the
// 0.001 limit at any baseline size.
function flipPixels(path: string): void {
  const img = readPng(readFileSync(path));
  const rgb = new Uint8Array(img.width * img.height * 3);
  for (let p = 0; p < img.width * img.height; p++)
    rgb.set(img.data.subarray(p * 4, p * 4 + 3), p * 3);
  const flipped = Math.ceil(img.width * img.height * 0.02);
  for (let p = 0; p < flipped; p++) {
    const red = rgb[p * 3];
    assert.ok(red !== undefined, `pixel ${p} outside the image`);
    rgb[p * 3] = (red + 128) & 0xff;
  }
  writeFileSync(
    path,
    writePng({ width: img.width, height: img.height, data: rgb }),
  );
}

function firstPng(dir: string): string {
  const [first] = readdirSync(dir)
    .filter((f) => f.endsWith(".png"))
    .sort();
  assert.ok(first !== undefined, `no PNG in ${dir}`);
  return first;
}

// The one element of `items`, failing unless there is exactly one.
function only<T>(items: T[]): T {
  const [first, ...rest] = items;
  assert.ok(
    first !== undefined && rest.length === 0,
    `want exactly one, got ${JSON.stringify(items)}`,
  );
  return first;
}

describe("capture-ci Tier-1", () => {
  it("passes on the genesis baselines", () => {
    const runDir = fakeRunFromBaselines();
    assert.deepEqual(tier1Check(runDir, baselinesDir), []);
  });

  it("fails naming the variant on a 1-byte-mutated copy in tmp", () => {
    const runDir = fakeRunFromBaselines();
    const canaryDir = join(runDir, "canary");
    const victim = firstPng(canaryDir);
    const path = join(canaryDir, victim);
    const bytes = Buffer.from(readFileSync(path));
    // IEND CRC: hash flips, PNG stays valid.
    const at = bytes.length - 5;
    bytes.writeUInt8(bytes.readUInt8(at) ^ 1, at);
    writeFileSync(path, bytes);
    const failures = tier1Check(runDir, baselinesDir);
    const failure = only(failures);
    assert.match(failure, /Tier-1 hash mismatch/);
    assert.match(failure, new RegExp(`canary/${victim.replace(/\.png$/, "")}`));
  });
});

describe("capture-ci Tier-2", () => {
  it("passes on PNGs identical to the baselines", () => {
    const runDir = fakeRunFromBaselines();
    assert.deepEqual(tier2Check(runDir, baselinesCopy()), []);
    assert.deepEqual(tier2Check(runDir, baselinesDir), []);
  });

  it("fails naming the variant on a pixel-flipped PNG; CLI exits 1", () => {
    // Non-canary victim: Tier-1 only hashes canary, so this run is
    // Tier-1-clean and the failure (and the CLI exit 1) is Tier-2's
    // alone. The baselines are a copy with every story approved, so
    // the victim's story is compared whatever the tree's state.
    const runDir = fakeRunFromBaselines();
    const approved = baselinesCopy();
    const story = "alert";
    const victim = firstPng(join(runDir, story));
    const variant = `${story}/${victim.replace(/\.png$/, "")}`;
    flipPixels(join(runDir, story, victim));
    assert.deepEqual(tier1Check(runDir, approved), []);
    const failures = tier2Check(runDir, approved);
    const failure = only(failures);
    assert.match(failure, /Tier-2 diff/);
    assert.match(failure, new RegExp(variant));
    const r = spawnSync(
      process.execPath,
      [join(scriptDir, "email-capture-ci.ts"), runDir, "--baselines", approved],
      { encoding: "utf8" },
    );
    assert.equal(r.status, 1);
    assert.match(r.stdout as string, new RegExp(variant));
    assert.match(
      r.stderr as string,
      /FAIL — Tier-1 0 failure\(s\), Tier-2 1 failure\(s\)/,
    );
  });
});

describe("capture-ci baselines awaiting re-approval", () => {
  it("does not compare a pending story, and says so on every run", () => {
    // The same pixel flip that fails an approved story is not a
    // Tier-2 failure once the story awaits re-approval — but it is
    // reported, with the recorded reason, and counted in the verdict.
    const runDir = fakeRunFromBaselines();
    const pendingDir = baselinesCopy(["alert"]);
    flipPixels(join(runDir, "alert", firstPng(join(runDir, "alert"))));
    assert.deepEqual(tier2Check(runDir, pendingDir), []);
    const lines = tier2Pending(runDir, pendingDir);
    const line = only(lines);
    assert.match(
      line,
      /Tier-2 alert awaiting re-approval — 6 capture\(s\) not compared \(test: out of date\)/,
    );
    const r = spawnSync(
      process.execPath,
      [
        join(scriptDir, "email-capture-ci.ts"),
        runDir,
        "--baselines",
        pendingDir,
      ],
      { encoding: "utf8" },
    );
    assert.equal(r.status, 0);
    assert.match(r.stdout as string, /alert awaiting re-approval/);
    assert.match(
      r.stdout as string,
      /PASS — Tier-1 \+ Tier-2 clean; 1 story\(ies\) awaiting re-approval, not compared/,
    );
    // Negative control: with nothing pending the verdict says nothing
    // about approval.
    const clean = spawnSync(
      process.execPath,
      [
        join(scriptDir, "email-capture-ci.ts"),
        fakeRunFromBaselines(),
        "--baselines",
        baselinesCopy(),
      ],
      { encoding: "utf8" },
    );
    assert.equal(clean.status, 0);
    assert.doesNotMatch(clean.stdout as string, /awaiting re-approval/);
  });

  it("--require-approved fails while any story is pending", () => {
    const runDir = fakeRunFromBaselines();
    const r = spawnSync(
      process.execPath,
      [
        join(scriptDir, "email-capture-ci.ts"),
        runDir,
        "--require-approved",
        "--baselines",
        baselinesCopy(["receipt"]),
      ],
      { encoding: "utf8" },
    );
    assert.equal(r.status, 1);
    assert.match(
      r.stderr as string,
      /1 story\(ies\) awaiting re-approval \(--require-approved\)/,
    );
    const ok = spawnSync(
      process.execPath,
      [
        join(scriptDir, "email-capture-ci.ts"),
        runDir,
        "--require-approved",
        "--baselines",
        baselinesCopy(),
      ],
      { encoding: "utf8" },
    );
    assert.equal(ok.status, 0);
  });

  it("refuses an empty marker and a pending canary", () => {
    const empty = baselinesCopy();
    writeFileSync(join(empty, "alert", PENDING_MARKER), "  \n");
    assert.throws(() => readPendingReview(empty), /must record why/);
    const canary = baselinesCopy(["canary"]);
    assert.throws(() => readPendingReview(canary), /can never await/);
  });

  it("--update-baselines leaves pending stories alone; --approve clears them", () => {
    const runDir = fakeRunFromBaselines();
    const victim = firstPng(join(runDir, "alert"));
    flipPixels(join(runDir, "alert", victim));
    const dir = baselinesCopy(["alert"]);
    const before = readFileSync(join(dir, "alert", victim));
    const kept = updateBaselines(runDir, dir);
    assert.deepEqual(kept.skipped, ["alert"]);
    assert.deepEqual(kept.approved, []);
    assert.deepEqual(readFileSync(join(dir, "alert", victim)), before);
    assert.ok(existsSync(join(dir, "alert", PENDING_MARKER)));
    // Approving a story that is not pending is refused.
    assert.throws(
      () => updateBaselines(runDir, dir, ["receipt"]),
      /not awaiting re-approval/,
    );
    const done = updateBaselines(runDir, dir, ["alert"]);
    assert.deepEqual(done.approved, ["alert"]);
    assert.deepEqual(
      readFileSync(join(dir, "alert", victim)),
      readFileSync(join(runDir, "alert", victim)),
    );
    assert.ok(!existsSync(join(dir, "alert", PENDING_MARKER)));
    assert.deepEqual(tier2Check(runDir, dir), []);
  });

  it("the checked-in tree keeps the canary approved", () => {
    assert.ok(!readPendingReview(baselinesDir).has("canary"));
  });
});

// A run dir with only index.json + per-story assertions.json (Tier-3
// reads no PNGs): one story, one capture, caller-supplied results.
function fakeTier3Run(
  assertions: { check: string; pass: boolean | null; detail: string }[],
): string {
  const runDir = tmp("capture-ci-tier3-");
  const storyDir = join(runDir, "canary");
  mkdirSync(storyDir, { recursive: true });
  writeFileSync(
    join(runDir, "index.json"),
    JSON.stringify([
      {
        story: "canary",
        status: "done",
        png: "canary/a-chromium-baseline-chromium-mobile-light-on.png",
      },
    ]),
  );
  writeFileSync(
    join(storyDir, "assertions.json"),
    JSON.stringify({
      story: "canary",
      run: "test",
      captures: [
        {
          capture: "a-chromium-baseline-chromium-mobile-light-on",
          family: "chromium-baseline",
          client: "chromium",
          viewport: "mobile",
          scheme: "light",
          images: "on",
          status: "done",
          assertions,
        },
      ],
    }),
  );
  return runDir;
}

const allPass = [
  {
    check: "overflow",
    pass: true,
    detail: "scrollWidth 375px <= viewport 375px",
  },
  {
    check: "touch",
    pass: true,
    detail: "no visible links/buttons (vacuous pass)",
  },
  { check: "bodyfont", pass: true, detail: "body font-size 16px (>= 14px)" },
  { check: "contrast", pass: true, detail: "lowest 21:1 on <body>" },
  { check: "unsubscribe", pass: true, detail: "visible unsubscribe link" },
  { check: "clipped", pass: true, detail: "no '[Message clipped]' marker" },
  {
    check: "axe",
    pass: null,
    detail: "recorded as not run",
  },
];

describe("capture-ci Tier-3", () => {
  it("passes on all-pass assertions (axe null never fails)", () => {
    assert.deepEqual(tier3Check(fakeTier3Run(allPass)), []);
  });

  it("fails naming the check and story/capture on a recorded failure", () => {
    const failing = allPass.map((a) =>
      a.check === "overflow"
        ? { ...a, pass: false, detail: "scrollWidth 700px > viewport 320px" }
        : a,
    );
    const failures = tier3Check(fakeTier3Run(failing));
    const failure = only(failures);
    assert.match(failure, /Tier-3 overflow failed/);
    assert.match(
      failure,
      /canary\/a-chromium-baseline-chromium-mobile-light-on/,
    );
  });

  it("fails naming the story when assertions.json is missing", () => {
    const runDir = tmp("capture-ci-tier3-");
    mkdirSync(join(runDir, "canary"), { recursive: true });
    writeFileSync(
      join(runDir, "index.json"),
      JSON.stringify([
        { story: "canary", status: "done", png: "canary/x.png" },
      ]),
    );
    const failures = tier3Check(runDir);
    const failure = only(failures);
    assert.match(failure, /no assertions\.json for canary/);
  });

  it("fails a story whose assertions.json records no captures array", () => {
    // An assertions.json that is not an object with a captures list
    // recorded nothing: that is a failure, never a vacuous pass.
    for (const body of ["null", "{}", '{"captures": {}}']) {
      const runDir = tmp("capture-ci-tier3-");
      mkdirSync(join(runDir, "canary"), { recursive: true });
      writeFileSync(
        join(runDir, "index.json"),
        JSON.stringify([
          { story: "canary", status: "done", png: "canary/x.png" },
        ]),
      );
      writeFileSync(join(runDir, "canary", "assertions.json"), body);
      const failure = only(tier3Check(runDir));
      assert.match(
        failure,
        /canary\/assertions\.json has no captures array/,
        body,
      );
    }
  });

  it("fails a capture whose assertions field is not a list", () => {
    // A present, non-null assertions value that is not an array is not
    // a record of results: a named failure, never read as "none
    // recorded" (that is only absent or null, which pass).
    for (const assertions of [{}, { pass: false }, 5, "overflow", true]) {
      const runDir = tmp("capture-ci-tier3-");
      mkdirSync(join(runDir, "canary"), { recursive: true });
      writeFileSync(
        join(runDir, "index.json"),
        JSON.stringify([
          { story: "canary", status: "done", png: "canary/x.png" },
        ]),
      );
      writeFileSync(
        join(runDir, "canary", "assertions.json"),
        JSON.stringify({ captures: [{ capture: "x", assertions }] }),
      );
      const failure = only(tier3Check(runDir));
      assert.match(
        failure,
        /Tier-3 canary\/assertions\.json capture x has an assertions field that is not a list/,
        JSON.stringify(assertions),
      );
    }
    for (const assertions of [null, undefined]) {
      const runDir = tmp("capture-ci-tier3-");
      mkdirSync(join(runDir, "canary"), { recursive: true });
      writeFileSync(
        join(runDir, "index.json"),
        JSON.stringify([
          { story: "canary", status: "done", png: "canary/x.png" },
        ]),
      );
      writeFileSync(
        join(runDir, "canary", "assertions.json"),
        JSON.stringify({ captures: [{ capture: "x", assertions }] }),
      );
      assert.deepEqual(tier3Check(runDir), [], String(assertions));
    }
  });

  // A run dir whose canary assertions.json holds `captures` verbatim.
  function tier3RunWith(captures: unknown[]): string {
    const runDir = tmp("capture-ci-tier3-");
    mkdirSync(join(runDir, "canary"), { recursive: true });
    writeFileSync(
      join(runDir, "index.json"),
      JSON.stringify([
        { story: "canary", status: "done", png: "canary/x.png" },
      ]),
    );
    writeFileSync(
      join(runDir, "canary", "assertions.json"),
      JSON.stringify({ captures }),
    );
    return runDir;
  }

  it("fails a story whose captures list is empty", () => {
    // The story is in the index, so email-shots recorded at least one
    // capture for it: an empty list checked nothing.
    const failure = only(tier3Check(tier3RunWith([])));
    assert.match(
      failure,
      /Tier-3 canary\/assertions\.json records no captures/,
    );
  });

  it("fails a captures entry that is not a capture record", () => {
    // A captures entry that is not an object records nothing that can
    // be checked: a named failure, never read as "none recorded".
    for (const cap of [null, 5, "x", true, []]) {
      const failure = only(tier3Check(tier3RunWith([cap])));
      assert.match(
        failure,
        /Tier-3 canary\/assertions\.json captures\[0\] is not a capture record/,
        JSON.stringify(cap),
      );
    }
  });

  it("fails an assertion entry that is not a result with a boolean or null pass", () => {
    // Each recorded result must say pass true, false or null (null:
    // not run, e.g. axe). A non-object entry, or one whose pass is
    // missing or of another type, is reported instead of skipped.
    for (const a of [
      null,
      7,
      "failed",
      [],
      { check: "overflow", detail: "no pass field" },
      { check: "overflow", pass: "false", detail: "string pass" },
      { check: "overflow", pass: 0, detail: "numeric pass" },
    ]) {
      const failure = only(
        tier3Check(tier3RunWith([{ capture: "x", assertions: [a] }])),
      );
      assert.match(
        failure,
        /Tier-3 canary\/assertions\.json capture x assertions\[0\] is not a result with a pass of true, false or null/,
        JSON.stringify(a),
      );
    }
    for (const pass of [true, null])
      assert.deepEqual(
        tier3Check(
          tier3RunWith([
            { capture: "x", assertions: [{ check: "c", pass, detail: "d" }] },
          ]),
        ),
        [],
        String(pass),
      );
  });

  it("refuses a vacuous pass on a story-less run", () => {
    const runDir = tmp("capture-ci-tier3-");
    writeFileSync(join(runDir, "index.json"), JSON.stringify([]));
    assert.throws(() => tier3Check(runDir), /no stories/);
  });
});
