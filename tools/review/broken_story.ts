#!/usr/bin/env node
// tools/review/broken_story.ts — the review loop's own check: does a
// reviewer notice a missing element?
//
// The visual design methodology asks that a deliberately broken view,
// reviewed from its real capture and its unchanged brief, is reported
// as missing the element and rated 4 or lower, while the unbroken view
// passes. The reviewer is an agent, so this cannot be an ordinary test;
// it is a recorded session plus a check of what was recorded:
//
//   prepare [--out DIR]  captures the intact receipt and the receipt
//                        with its logo dropped from the output
//                        (`receiptB`, a capture fixture whose
//                        brief still expects the logo), then prints, per
//                        story, what its reviewer must be given (the
//                        static brief, the generated brief, the PNGs)
//                        and where the reviewer's report is to be saved.
//   check RUN_DIR        reads the two saved reports
//                        (RUN_DIR/review/<story>.txt) and the session
//                        findings list, and fails unless the broken
//                        story's report names the logo as missing with a
//                        rating of 4 or lower, the intact story's report
//                        finds every element present with a rating above
//                        4, and the findings list holds a P1 entry for
//                        the broken story that names the logo and points
//                        at a capture of this run.
//
// The reports are the reviewers' own words, saved verbatim by the agent
// that ran them; this module only reads them.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { defaultFindingsPath, readFindings, type Finding } from "./findings.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

export const BROKEN_STORY = "receiptB";
export const INTACT_STORY = "receipt";
// The element the broken story loses, as its brief names it.
export const DROPPED_ELEMENT = "Acme logo";
// The capture matrix: the baseline engine, both viewports, light.
export const MATRIX = [
  "--backends",
  "a",
  "--families",
  "chromium-baseline",
  "--viewports",
  "mobile,desktop",
  "--schemes",
  "light",
];

export interface ReviewReport {
  expected: string; // the "Expected elements:" line, without its label
  rating: number | null; // "Rating: N/10"
  text: string;
}

// The two lines the brief's report format requires of every review.
export function parseReport(text: string): ReviewReport {
  const expected =
    /^\s*Expected elements:\s*(.+)$/im.exec(text)?.[1]?.trim() ?? "";
  const m = /Rating:\s*(\d+(?:\.\d+)?)\s*\/\s*10/i.exec(text);
  return { expected, rating: m === null ? null : Number(m[1]), text };
}

const mentionsElement = (s: string, element: string): boolean =>
  s.toLowerCase().includes(element.toLowerCase()) ||
  // A reviewer may name the logo by its role rather than its alt.
  /\blogo\b/i.test(s);

export interface CheckInput {
  broken: ReviewReport;
  intact: ReviewReport;
  findings: Finding[];
  runRel: string; // the run dir, relative to the repo root
  element?: string;
}

// Every way the recorded session fails the item; [] when it passes.
export function checkBrokenStoryReview(input: CheckInput): string[] {
  const element = input.element ?? DROPPED_ELEMENT;
  const out: string[] = [];
  const { broken, intact } = input;
  if (!/missing/i.test(broken.expected))
    out.push(
      `the broken story's report does not start by naming a missing element ("Expected elements: ${broken.expected}")`,
    );
  else if (!mentionsElement(broken.expected, element))
    out.push(
      `the broken story's report names something missing, but not the ${element} ("${broken.expected}")`,
    );
  if (broken.rating === null)
    out.push("the broken story's report has no 'Rating: N/10' line");
  else if (broken.rating > 4)
    out.push(
      `the broken story is rated ${broken.rating}/10; a missing element caps the rating at 4`,
    );
  if (!/^present\b/i.test(intact.expected) || /missing/i.test(intact.expected))
    out.push(
      `the intact story's report does not find every element present ("Expected elements: ${intact.expected}")`,
    );
  if (intact.rating === null)
    out.push("the intact story's report has no 'Rating: N/10' line");
  else if (intact.rating <= 4)
    out.push(
      `the intact story is rated ${intact.rating}/10; it must pass (above 4)`,
    );
  const entry = input.findings.find(
    (f) =>
      f.story === BROKEN_STORY &&
      f.severity === "P1" &&
      mentionsElement(f.finding, element) &&
      /missing/i.test(f.finding) &&
      f.capture.startsWith(input.runRel + "/"),
  );
  if (entry === undefined)
    out.push(
      `the findings list has no P1 entry for ${BROKEN_STORY} naming the missing ${element} with a capture under ${input.runRel}/`,
    );
  if (
    input.findings.some(
      (f) =>
        f.story === INTACT_STORY &&
        f.capture.startsWith(input.runRel + "/") &&
        (f.severity === "P1" || f.severity === "P2") &&
        f.status === "open",
    )
  )
    out.push(
      `the findings list holds an open P1/P2 for the intact ${INTACT_STORY} in this run`,
    );
  return out;
}

function readReport(runDir: string, story: string): ReviewReport {
  const path = join(runDir, "review", `${story}.txt`);
  if (!existsSync(path))
    throw new Error(
      `broken-story: no saved report at ${path} (save the reviewer's report there verbatim)`,
    );
  return parseReport(readFileSync(path, "utf8"));
}

function prepare(args: string[]): number {
  let out = join(
    repoRoot,
    "build",
    "email-shots",
    `review-broken-${new Date().toISOString().replace(/[-:.]/g, "")}`,
  );
  for (let i = 0; i < args.length; i++)
    if (args[i] === "--out" && args[i + 1] !== undefined)
      out = resolve(repoRoot, args[++i]!);
  const r = spawnSync(
    process.execPath,
    [
      join(repoRoot, "tools", "capture", "email-shots.ts"),
      INTACT_STORY,
      BROKEN_STORY,
      ...MATRIX,
      "--no-cache",
      "--out",
      out,
    ],
    {
      cwd: repoRoot,
      stdio: ["ignore", "ignore", "inherit"],
      env: { ...process.env, ISONIM_CAPTURE_FIXTURES: "1" },
    },
  );
  if (r.status !== 0) {
    process.stderr.write(`broken-story: email-shots exited ${r.status}\n`);
    return 1;
  }
  const staticBrief = join(
    repoRoot,
    "tools",
    "review",
    "email-visual-review-brief.md",
  );
  const lines: string[] = [
    `run: ${out}`,
    "",
    "Give each story to its own read-only reviewer sub-agent. Do not tell",
    "the reviewer which story is broken. Each reviewer gets:",
    `  - the static brief: ${staticBrief}`,
  ];
  for (const story of [INTACT_STORY, BROKEN_STORY]) {
    lines.push("", `story ${story}:`);
    for (const vp of ["mobile", "desktop"]) {
      lines.push(
        `  - ${vp}: brief ${join(out, story, `brief-chromium-baseline-${vp}-light.md`)}`,
        `           capture ${join(out, story, `a-chromium-baseline-chromium-${vp}-light-on.png`)}`,
      );
    }
    lines.push(
      `  save the report verbatim to ${join(out, "review", `${story}.txt`)}`,
    );
  }
  lines.push(
    "",
    `Record the broken story's finding (P1, naming the missing ${DROPPED_ELEMENT}) in`,
    `${relative(repoRoot, defaultFindingsPath())} with a capture under ${relative(repoRoot, out)}/,`,
    `then run: just email-review-broken-check ${relative(repoRoot, out)}`,
  );
  process.stdout.write(lines.join("\n") + "\n");
  return 0;
}

function check(runArg: string | undefined): number {
  if (runArg === undefined) {
    process.stderr.write("usage: broken_story.ts check RUN_DIR\n");
    return 2;
  }
  const runDir = resolve(repoRoot, runArg);
  let problems: string[];
  try {
    problems = checkBrokenStoryReview({
      broken: readReport(runDir, BROKEN_STORY),
      intact: readReport(runDir, INTACT_STORY),
      findings: readFindings(defaultFindingsPath()),
      runRel: relative(repoRoot, runDir),
    });
  } catch (err) {
    process.stderr.write(
      `${err instanceof Error ? err.message : String(err)}\n`,
    );
    return 1;
  }
  if (problems.length > 0) {
    for (const p of problems)
      process.stderr.write(`broken-story: FAIL — ${p}\n`);
    return 1;
  }
  process.stdout.write(
    `broken-story: OK — the reviewer reported the ${DROPPED_ELEMENT} missing in ${BROKEN_STORY} (rated ≤ 4) and passed ${INTACT_STORY}; the findings list records it\n`,
  );
  return 0;
}

const isMain =
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === new URL(import.meta.url).pathname;

if (isMain) {
  const [mode, ...rest] = process.argv.slice(2);
  if (mode === "prepare") process.exit(prepare(rest));
  if (mode === "check") process.exit(check(rest[0]));
  process.stderr.write(
    "usage: broken_story.ts prepare [--out DIR] | check RUN_DIR\n",
  );
  process.exit(2);
}
