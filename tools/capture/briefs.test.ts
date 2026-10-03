// tools/capture/briefs.test.ts — the real-client review briefs.
//
// Two parts:
// - Selection: a plan routed by the real harness over the registered
//   providers' real client descriptors (every provider reported
//   available, so no tool is started) gives one brief-driver call per
//   story and real client, with exactly the viewports and schemes the
//   client is captured in; backend a's captures and the rows routing
//   settled without a capture get none.
// - The driver: the built brief driver (`just email-shots-build`), run
//   in its `--client` mode for a webmail, a verification desktop client
//   and the real Thunderbird, writes one brief per capture, named like
//   the capture, saying what the client stands in for and what it is
//   expected to show; it refuses a client it does not know and a client
//   named under another backend or family.
//
// No test double: availability is the one input not measured, and it
// is a plain value the harness takes as an argument (the routing under
// test reads nothing else from a provider but its static descriptors).
//
// Run with:
//   node --test tools/capture/briefs.test.ts

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  clientBriefArgs,
  clientBriefFiles,
  clientBriefJobs,
  clientBriefName,
} from "./briefs.ts";
import { routeRequests, type MatrixSpec } from "./providers/harness.ts";
import { registeredProviders } from "./providers/registry.ts";
import type { ProviderHealth } from "./providers/types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
const briefDriver = join(repoRoot, "build", "review", "brief-driver");

const PROVIDERS = registeredProviders();
const allAvailable = new Map<string, ProviderHealth>(
  PROVIDERS.map((p) => [p.id, { state: "ok" } as ProviderHealth]),
);

function plan(families: string[], clients: string[] | null = null) {
  const spec: MatrixSpec = {
    stories: [
      { story: "receipt", mimeSha256: "0".repeat(64) },
      { story: "alert", mimeSha256: "1".repeat(64) },
    ],
    families,
    clients,
    backends: null,
    viewports: [
      { name: "mobile", width: 375, dpr: 3 },
      { name: "desktop", width: 800, dpr: 1 },
    ],
    schemes: ["light", "dark"],
    images: ["on"],
  };
  return routeRequests(PROVIDERS, allAvailable, spec);
}

describe("real-client brief selection", () => {
  it("one job per story and real client, with the viewports and schemes it is captured in", () => {
    const p = plan(["verification", "thunderbird", "apple"]);
    const jobs = clientBriefJobs(p.items, "a");
    const byKey = new Map(
      jobs.map((j) => [`${j.story}/${j.backend}/${j.family}/${j.clientId}`, j]),
    );
    // Every real client of both stories, and nothing of backend a.
    assert.deepEqual([...byKey.keys()].sort(), [
      "alert/linux-desktop/thunderbird/thunderbird",
      "alert/linux-desktop/verification/claws-mail",
      "alert/linux-desktop/verification/evolution",
      "alert/linux-desktop/verification/geary",
      "alert/linux-desktop/verification/kmail",
      "alert/selfhosted-webmail/verification/roundcube",
      "alert/selfhosted-webmail/verification/snappymail",
      "receipt/linux-desktop/thunderbird/thunderbird",
      "receipt/linux-desktop/verification/claws-mail",
      "receipt/linux-desktop/verification/evolution",
      "receipt/linux-desktop/verification/geary",
      "receipt/linux-desktop/verification/kmail",
      "receipt/selfhosted-webmail/verification/roundcube",
      "receipt/selfhosted-webmail/verification/snappymail",
    ]);
    assert.ok(jobs.every((j) => j.backend !== "a"));
    // The webmails render both viewports; a desktop client the desktop
    // width only; Claws Mail light only (its dark row is not-applicable
    // and gets no brief).
    const rc = byKey.get("receipt/selfhosted-webmail/verification/roundcube")!;
    assert.deepEqual(rc.viewports, ["mobile", "desktop"]);
    assert.deepEqual(rc.schemes, ["light", "dark"]);
    const tb = byKey.get("receipt/linux-desktop/thunderbird/thunderbird")!;
    assert.deepEqual(tb.viewports, ["desktop"]);
    assert.deepEqual(tb.schemes, ["light", "dark"]);
    const claws = byKey.get("alert/linux-desktop/verification/claws-mail")!;
    assert.deepEqual(claws.viewports, ["desktop"]);
    assert.deepEqual(claws.schemes, ["light"]);
    assert.ok(
      p.items.some(
        (i) =>
          i.kind === "not-applicable" && i.request.clientId === "claws-mail",
      ),
      "the plan holds Claws Mail's not-applicable dark rows",
    );
  });

  it("a backend-a-only plan writes no client brief", () => {
    const p = plan(["apple", "gmailWeb"]);
    assert.ok(p.items.length > 0);
    assert.deepEqual(clientBriefJobs(p.items, "a"), []);
  });

  it("a brief is named like its capture, without the images suffix", () => {
    const p = plan(["verification"], ["snappymail"]);
    const captures = p.items.filter((i) => i.kind === "capture");
    assert.equal(captures.length, 8);
    const files = new Set(
      clientBriefJobs(p.items, "a").flatMap((j) => clientBriefFiles(j)),
    );
    for (const c of captures) {
      const r = c.request;
      assert.equal(r.id.endsWith("-on"), true, r.id);
      assert.equal(
        `brief-${r.id.slice(0, -"-on".length)}.md`,
        clientBriefName(
          r.backend,
          r.family,
          r.clientId,
          r.viewport.name,
          r.scheme,
        ),
      );
      assert.ok(
        files.has(
          clientBriefName(
            r.backend,
            r.family,
            r.clientId,
            r.viewport.name,
            r.scheme,
          ),
        ),
        r.id,
      );
    }
  });
});

describe("the brief driver's --client mode", () => {
  let out = "";
  before(() => {
    if (!existsSync(briefDriver))
      throw new Error(
        `${briefDriver} missing — run \`just email-shots-build\` first`,
      );
    out = mkdtempSync(join(tmpdir(), "client-briefs-"));
  });
  after(() => {
    if (out !== "") rmSync(out, { recursive: true, force: true });
  });

  function drive(args: string[]) {
    return spawnSync(briefDriver, args, { cwd: repoRoot, encoding: "utf8" });
  }

  it("writes one brief per capture for each real client of a plan", () => {
    const p = plan(["verification", "thunderbird"]);
    const jobs = clientBriefJobs(p.items, "a").filter(
      (j) => j.story === "receipt",
    );
    const dir = join(out, "plan");
    const want: string[] = [];
    for (const j of jobs) {
      const r = drive(clientBriefArgs(j, dir));
      assert.equal(r.status, 0, r.stderr);
      want.push(...clientBriefFiles(j));
    }
    assert.deepEqual(readdirSync(dir).sort(), want.sort());
    // 2 webmails × 2 viewports × 2 schemes, 4 desktop clients × 2
    // schemes, Claws Mail × 1.
    assert.equal(want.length, 8 + 8 + 1);
  });

  it("a verification client's brief says it stands in for no audience family, and what it shows", () => {
    const dir = join(out, "snappymail");
    const r = drive([
      "--client",
      "selfhosted-webmail",
      "verification",
      "snappymail",
      "receipt",
      dir,
      "mobile",
      "dark",
    ]);
    assert.equal(r.status, 0, r.stderr);
    const brief = readFileSync(
      join(
        dir,
        "brief-selfhosted-webmail-verification-snappymail-mobile-dark.md",
      ),
      "utf8",
    );
    assert.match(
      brief,
      /^### Expected: receipt — snappymail \(verification\) — mobile 375 — dark — selfhosted-webmail \(real client\)$/m,
    );
    assert.match(brief, /stands in for no audience family/);
    // The elements, from the story's tree.
    assert.match(brief, /Heading "Receipt #1234" \(largest text\)\./);
    assert.match(brief, /"Acme logo"/);
    // The sanitiser and the dark theme.
    assert.match(brief, /removes every `<style>` block, class and id/);
    assert.match(brief, /NightShine theme/);
    assert.match(brief, /defect \(R-TXT-02\)/);
    assert.match(brief, /the message's own dark rules do not apply/);
  });

  it("the real Thunderbird's brief says it is the thunderbird audience family", () => {
    const dir = join(out, "thunderbird");
    const r = drive([
      "--client",
      "linux-desktop",
      "thunderbird",
      "thunderbird",
      "alert",
      dir,
      "desktop",
      "light,dark",
    ]);
    assert.equal(r.status, 0, r.stderr);
    const light = readFileSync(
      join(dir, "brief-linux-desktop-thunderbird-thunderbird-desktop-light.md"),
      "utf8",
    );
    const dark = readFileSync(
      join(dir, "brief-linux-desktop-thunderbird-thunderbird-desktop-dark.md"),
      "utf8",
    );
    assert.match(light, /real client of the `thunderbird` audience family/);
    assert.doesNotMatch(light, /stands in for no audience family/);
    assert.match(light, /never stretched to the column width/);
    // Dark behaviour only in the dark brief.
    assert.doesNotMatch(light, /recolours a message/);
    assert.match(dark, /recolours a message on its own/);
    // The receipt is `accommodate`: it keeps its light design there
    // (catalogue R-DRK-08).
    assert.match(dark, /`darkMode = accommodate`\) keeps its light design/);
    assert.match(dark, /Dark palette \(dark\): no @dark overrides/);
  });

  it("refuses an unknown client and a client under another backend or family", () => {
    const unknown = drive([
      "--client",
      "linux-desktop",
      "verification",
      "mutt",
      "receipt",
      join(out, "x"),
      "desktop",
      "light",
    ]);
    assert.equal(unknown.status, 1);
    assert.match(unknown.stderr, /unknown real client 'mutt'/);
    const drifted = drive([
      "--client",
      "selfhosted-webmail",
      "verification",
      "kmail",
      "receipt",
      join(out, "y"),
      "desktop",
      "light",
    ]);
    assert.equal(drifted.status, 1);
    assert.match(
      drifted.stderr,
      /client 'kmail' is linux-desktop\/verification/,
    );
    assert.equal(existsSync(join(out, "x")), false);
    assert.equal(existsSync(join(out, "y")), false);
  });
});
