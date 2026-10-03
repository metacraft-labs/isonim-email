// tools/capture/axe.ts — axe-core, the seventh Tier-3 check.
//
// Backend a injects the pinned axe-core (flake.nix `axeCore`; the
// directory is $ISONIM_EMAIL_AXE) into every capture after its
// screenshot, so the check can never change the pixels, runs
// `axe.run` on the message, and records the result beside the six DOM
// assertions (dom_assertions.ts): `pass` is true when no rule that
// applies to email is violated, and `--assert` gates on it like the
// others. The provenance also keeps axe's version, the violation count
// and the first violated rule IDs.
//
// Which rules apply to email: axe's WCAG 2.0/2.1/2.2 A and AA rules and
// its best practices, less the ones that judge a web page's structure,
// which a message cannot and must not have:
//
// - the landmark rules (`region`, `landmark-*`): a message carries no
//   `main`/`nav`/`header` landmarks of its own; sectioning elements are
//   never emitted (catalogue R-A11Y-10: clients rewrite or strip them),
//   and the mail client's own page supplies the landmarks around it;
// - `bypass` (a skip link): a message is read inside the client's
//   reading pane, which owns keyboard navigation;
// - `page-has-heading-one` stays on: every message has an h1
//   (R-A11Y-03), and so does `html-has-lang`, `document-title` and
//   every content rule (alt text, contrast, link names, table headers).
//
// Plain JS in the page, typed here: the evaluate callbacks run in the
// browser, so they use no imports.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const AXE_ENV = "ISONIM_EMAIL_AXE";

// axe's rule tags run on a message.
export const AXE_TAGS = [
  "wcag2a",
  "wcag2aa",
  "wcag21a",
  "wcag21aa",
  "wcag22aa",
  "best-practice",
];

// Rules switched off, each with why it does not apply to email.
export const AXE_DISABLED: Record<string, string> = {
  region:
    "content outside landmarks: a message has none of its own (R-A11Y-10)",
  "landmark-one-main": "a message has no main landmark (R-A11Y-10)",
  "landmark-complementary-is-top-level": "no landmarks in a message",
  "landmark-no-duplicate-banner": "no landmarks in a message",
  "landmark-no-duplicate-contentinfo": "no landmarks in a message",
  "landmark-no-duplicate-main": "no landmarks in a message",
  "landmark-unique": "no landmarks in a message",
  "landmark-banner-is-top-level": "no landmarks in a message",
  "landmark-contentinfo-is-top-level": "no landmarks in a message",
  "landmark-main-is-top-level": "no landmarks in a message",
  bypass: "the reading pane owns keyboard navigation, not the message",
};

// The options passed to axe.run.
export function axeOptions(): Record<string, unknown> {
  const rules: Record<string, { enabled: boolean }> = {};
  for (const id of Object.keys(AXE_DISABLED)) rules[id] = { enabled: false };
  return {
    runOnly: { type: "tag", values: AXE_TAGS },
    rules,
    resultTypes: ["violations"],
    // axe may scroll elements into view to measure them; put the page
    // back where it was.
    restoreScroll: true,
  };
}

// The pinned axe source, read from $ISONIM_EMAIL_AXE/axe.min.js; null
// with the reason when it is not there.
export function loadAxeSource(
  env: Record<string, string | undefined> = process.env,
): { source: string } | { reason: string } {
  const dir = env[AXE_ENV];
  if (dir === undefined || dir.length === 0)
    return { reason: `${AXE_ENV} is unset (run under \`nix develop\`)` };
  const file = join(dir, "axe.min.js");
  if (!existsSync(file)) return { reason: `${file} does not exist` };
  return { source: readFileSync(file, "utf8") };
}

export interface AxeViolation {
  id: string;
  impact: string | null;
  nodes: number;
  target: string;
}

export interface AxeOutcome {
  version: string;
  violations: AxeViolation[];
}

export interface AxeAssertion {
  check: "axe";
  pass: boolean;
  detail: string;
}

// The assertion for one capture: the violations, at most five named.
export function axeAssertion(outcome: AxeOutcome): AxeAssertion {
  const v = outcome.violations;
  if (v.length === 0)
    return {
      check: "axe",
      pass: true,
      detail: `axe-core ${outcome.version}: no violations of the email rules`,
    };
  const named = v
    .slice(0, 5)
    .map(
      (x) =>
        `${x.id} (${x.impact ?? "?"}, ${x.nodes} node${x.nodes === 1 ? "" : "s"}, first: ${x.target})`,
    )
    .join("; ");
  return {
    check: "axe",
    pass: false,
    detail:
      `axe-core ${outcome.version}: ${v.length} rule${v.length === 1 ? "" : "s"} violated: ${named}` +
      (v.length > 5 ? `; and ${v.length - 5} more` : ""),
  };
}

// Injects `source` and runs axe in the page; the outcome as plain data.
export async function runAxe(
  page: import("playwright-core").Page,
  source: string,
): Promise<AxeOutcome> {
  await page.addScriptTag({ content: source });
  return (await page.evaluate(async (opts) => {
    const g = globalThis as unknown as { axe: AxeLike; document: unknown };
    const axe = g.axe;
    const r = await axe.run(g.document, opts);
    return {
      version: String(axe.version),
      violations: r.violations.map((v) => ({
        id: v.id,
        impact: v.impact ?? null,
        nodes: v.nodes.length,
        target: v.nodes.length > 0 ? String(v.nodes[0]!.target) : "",
      })),
    };
  }, axeOptions())) as AxeOutcome;
}

// The slice of axe's API the page uses.
interface AxeLike {
  version: string;
  run(
    context: unknown,
    options: unknown,
  ): Promise<{
    violations: {
      id: string;
      impact?: string | null;
      nodes: { target: unknown }[];
    }[];
  }>;
}
