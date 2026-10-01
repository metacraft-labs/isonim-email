#!/usr/bin/env node
// tools/review/findings.ts — the session findings list.
//
// The session log: `build/email-shots/findings.jsonl`, one entry per
// finding, maintained by the agent through the iteration. Entry shape
// exactly per the log contract (id/story/family/backend/viewport/
// severity/finding/capture/rules/status/fixed_in_run); `wontfix`
// carries a `reason` (wontfix needs a reason — enforced on append
// and on parse),
// `degradation` requires a non-empty `rules` (enforced both ways).
// The entry format is closed: a reader returns exactly those fields
// (plus a string `reason`), and a key outside the format is ignored on
// read — not rejected, and never removed from the file, which this
// tool only appends to.
// `rateFinding` is the brief's mechanical rating rule (methodology:
// anything missing means a rating ≤ 4).

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

export const FINDINGS_REL = join("build", "email-shots", "findings.jsonl");

export function defaultFindingsPath(): string {
  return join(repoRoot, FINDINGS_REL);
}

export type FindingStatus = "open" | "fixed" | "wontfix" | "degradation";

const STATUSES: ReadonlySet<string> = new Set([
  "open",
  "fixed",
  "wontfix",
  "degradation",
]);

const SEVERITIES: ReadonlySet<string> = new Set(["P1", "P2", "P3", "P4"]);

export interface Finding {
  id: string;
  story: string;
  family: string;
  backend: string;
  viewport: string;
  severity: string;
  finding: string;
  capture: string;
  rules: string[];
  status: FindingStatus;
  fixed_in_run: string | null;
  // Present only on wontfix entries: the required reason.
  reason?: string;
}

export type NewFinding = Omit<Finding, "id" | "fixed_in_run" | "reason"> & {
  fixed_in_run?: string | null;
  reason?: string;
};

function fail(message: string): never {
  throw new Error(`findings: ${message}`);
}

function isStatus(value: string): value is FindingStatus {
  return STATUSES.has(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Strict shape check: the entry keys with the right scalar types, the
// status/severity enums, and the two conditional rules (wontfix needs
// a reason, degradation needs a rules entry). Throws on violation.
export function parseFindingLine(line: string): Finding {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    fail(`not JSON: ${line.slice(0, 80)}`);
  }
  if (!isRecord(raw)) fail("entry is not an object");
  const fields: Record<string, unknown> = raw;
  const text = (key: string): string => {
    const value = fields[key];
    if (typeof value !== "string" || value.length === 0)
      fail(`entry needs a non-empty string '${key}'`);
    return value;
  };
  const id = text("id");
  const story = text("story");
  const family = text("family");
  const backend = text("backend");
  const viewport = text("viewport");
  const severity = text("severity");
  const finding = text("finding");
  const capture = text("capture");
  const status = text("status");
  const rules: unknown = fields.rules;
  if (
    !Array.isArray(rules) ||
    !rules.every((r) => typeof r === "string" && r.length > 0)
  )
    fail("entry needs 'rules' as an array of non-empty strings");
  const ruleList = rules.filter((r): r is string => typeof r === "string");
  const fixedInRun = fields.fixed_in_run;
  if (fixedInRun !== null && typeof fixedInRun !== "string")
    fail("entry needs 'fixed_in_run' as a string or null");
  if (!isStatus(status))
    fail(`bad status '${status}' (want open|fixed|wontfix|degradation)`);
  if (!SEVERITIES.has(severity))
    fail(`bad severity '${severity}' (want P1–P4)`);
  const reason = fields.reason;
  if (
    status === "wontfix" &&
    (typeof reason !== "string" || reason.length === 0)
  )
    fail("a wontfix entry needs a non-empty 'reason'");
  if (status === "degradation" && ruleList.length === 0)
    fail("a degradation entry needs at least one 'rules' entry");
  const entry: Finding = {
    id,
    story,
    family,
    backend,
    viewport,
    severity,
    finding,
    capture,
    rules: ruleList,
    status,
    fixed_in_run: fixedInRun,
  };
  if (typeof reason === "string") entry.reason = reason;
  return entry;
}

// Missing file → []. A corrupt line throws (fail loudly: the list is
// the session's memory, and a half-read list lies about the gate).
export function readFindings(path: string): Finding[] {
  if (!existsSync(path)) return [];
  const lines = readFileSync(path, "utf8").split("\n");
  const out: Finding[] = [];
  for (const line of lines) {
    if (line.trim().length === 0) continue;
    out.push(parseFindingLine(line));
  }
  return out;
}

export interface FindingFilter {
  status?: FindingStatus;
  story?: string;
  family?: string;
  severity?: string;
}

export function listFindings(path: string, filter?: FindingFilter): Finding[] {
  return readFindings(path).filter((f) => {
    if (filter === undefined) return true;
    if (filter.status !== undefined && f.status !== filter.status) return false;
    if (filter.story !== undefined && f.story !== filter.story) return false;
    if (filter.family !== undefined && f.family !== filter.family) return false;
    if (filter.severity !== undefined && f.severity !== filter.severity)
      return false;
    return true;
  });
}

function nextId(path: string): string {
  // F<k> with k one past the highest numeric suffix in the file;
  // a missing or empty file starts at F1.
  let max = 0;
  for (const f of readFindings(path)) {
    const k = /^F(\d+)$/.exec(f.id)?.[1];
    if (k !== undefined) max = Math.max(max, parseInt(k, 10));
  }
  return `F${max + 1}`;
}

// Validates, assigns the next F-id, appends one JSON line (creating
// the parent dir), and returns the stored entry.
export function appendFinding(path: string, fields: NewFinding): Finding {
  const entry: Finding = {
    ...fields,
    id: nextId(path),
    fixed_in_run: fields.fixed_in_run ?? null,
  };
  if (fields.reason !== undefined) entry.reason = fields.reason;
  // Validate before writing: parseFindingLine is the single gate.
  parseFindingLine(JSON.stringify(entry));
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(entry) + "\n");
  return entry;
}

// The brief's mechanical rating rule (methodology: a
// missing expected element caps the rating at 4 whatever the polish).
export function rateFinding(countMissing: number, draft = 10): number {
  if (!Number.isInteger(countMissing) || countMissing < 0)
    fail(`countMissing must be a non-negative integer, got ${countMissing}`);
  return countMissing > 0 ? Math.min(4, draft) : draft;
}
