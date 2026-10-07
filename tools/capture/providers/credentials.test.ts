// tools/capture/providers/credentials.test.ts — the credentials
// directory contract end to end: the providers' declared credential
// files, `email-credentials check` and `email-credentials template` as
// a developer runs them, and the harness's provider-unavailable reason.
//
// What is proven: a 0700 directory of 0600 files (plain files, and
// links to 0600 files elsewhere, the form a tool that materialises the
// directory from a secrets store leaves) satisfies every provider's
// declared requirement (the negative control for the refusals); a
// group- or world-readable file, or a directory that is not 0700, makes
// the providers unavailable with a reason naming the file and its mode,
// in the check's output and in the harness's run summary line; missing,
// incomplete, mis-schemed, malformed and unfilled-template files are
// named by path and key; templates are written 0600 in 0700 directories
// and never replace a file; and no value is ever printed: a sentinel
// secret seeded into every value (and into a malformed file, where
// V8's own parser message would quote it) appears in no output of either
// command and in no file they write.
//
// Test doubles (justification, per the repository's mock policy): one.
// The providers that will read these credentials (hosted webmail, the
// device farm) do not exist yet, so the harness's visible-unavailability
// path is exercised with a minimal CaptureProvider that declares a real
// credentials requirement and has no clients to capture; the harness's
// assessProvider and providerSummaryLines, the requirement check, the
// CLI (spawned with node, as `just` runs it) and every file and
// directory are real.
// Run with:
//   node --test tools/capture/providers/credentials.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  cpSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  CREDENTIAL_SETS,
  credentialRequirement,
  templatePath,
} from "./credentials.ts";
import { assessProvider, providerSummaryLines } from "./harness.ts";
import {
  checkRequirement,
  CREDENTIALS_SCHEMA,
  type HostEnv,
} from "./requirements.ts";
import type { CaptureProvider } from "./types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
const cli = join(repoRoot, "tools", "capture", "email-credentials.ts");
const scratch = mkdtempSync(join(tmpdir(), "capture-credentials-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

// Seeded into every value; it must never be printed, not even in part:
// V8's JSON.parse message quotes only the first characters it failed on,
// so the leak checks look for this prefix, not the whole value.
const SENTINEL = "s3ntinel-9f41c7d2-never-print";
const SENTINEL_PART = SENTINEL.slice(0, 8);

function host(dir: string): HostEnv {
  return {
    env: { ISONIM_EMAIL_CREDENTIALS_DIR: dir, HOME: scratch },
    platform: "linux",
  };
}

function fill(keys: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(keys))
    out[k] =
      v !== null && typeof v === "object"
        ? fill(v as Record<string, unknown>)
        : `${SENTINEL}-${k}`;
  return out;
}

function writePrivate(path: string, body: string): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, body, { mode: 0o600 });
  chmodSync(path, 0o600);
}

// A complete directory: every provider's files, filled with sentinel
// values. Account pools get two accounts, one of them a link to a 0600
// file in a private directory elsewhere; plus files no provider
// declares (a service-account key, a verification file).
function goodDir(name: string): string {
  const dir = join(scratch, name);
  const store = join(scratch, `${name}-store`);
  mkdirSync(dir, { mode: 0o700 });
  mkdirSync(store, { mode: 0o700 });
  for (const set of CREDENTIAL_SETS) {
    const body = JSON.stringify({
      schema: CREDENTIALS_SCHEMA,
      ...fill(set.keys),
    });
    if (set.entry.endsWith("/*.json")) {
      writePrivate(join(dir, set.id, "qa-1.json"), body);
      const target = join(store, `${set.id}-qa-2.json`);
      writePrivate(target, body);
      symlinkSync(target, join(dir, set.id, "qa-2.json"));
    } else {
      writePrivate(join(dir, set.entry), body);
    }
  }
  writePrivate(
    join(dir, "gmail-workspace", "keys", "sa.json"),
    JSON.stringify({ private_key: SENTINEL }),
  );
  writePrivate(
    join(dir, "verification.json"),
    JSON.stringify({ nonce: SENTINEL }),
  );
  chmodSync(dir, 0o700);
  return dir;
}

interface Run {
  status: number;
  out: string;
}

const outputs: string[] = [];

function run(args: string[], dir: string): Run {
  const r = spawnSync(process.execPath, [cli, ...args], {
    encoding: "utf8",
    env: { ...process.env, ISONIM_EMAIL_CREDENTIALS_DIR: dir },
  });
  const out = `${r.stdout}${r.stderr}`;
  outputs.push(out);
  return { status: r.status ?? -1, out };
}

function modeOf(path: string): number {
  return statSync(path).mode & 0o777;
}

// A provider that declares one credential set and captures nothing.
function credentialProvider(set: string): CaptureProvider {
  const never = (): never => {
    throw new Error("not called: the provider only declares requirements");
  };
  return {
    id: `needs-${set}`,
    backend: `needs-${set}`,
    version: "1",
    adapterVersion: 1,
    clients: () => [],
    requirements: () => [credentialRequirement(set)],
    health: async () => ({ state: "ok" }),
    prepare: async () => never(),
    emulation: () => never(),
    capture: () => never(),
    dispose: async () => {},
  };
}

describe("credentials directory contract", () => {
  it("accepts a 0700 directory of 0600 files and links: every declared provider's requirement is satisfied", () => {
    const dir = goodDir("good");
    for (const set of CREDENTIAL_SETS) {
      const r = checkRequirement(credentialRequirement(set.id), host(dir));
      assert.equal(r.met, true, `${set.id}: ${r.detail}`);
    }
    const r = run(["check", "--strict"], dir);
    assert.equal(r.status, 0, r.out);
    assert.match(r.out, /credentials directory .*: mode 0700/);
    for (const set of CREDENTIAL_SETS)
      assert.match(r.out, new RegExp(`\\n  ${set.id}( \\(optional\\))?: ok `));
    assert.doesNotMatch(r.out, /UNAVAILABLE|UNSAFE/);
    assert.match(
      r.out,
      new RegExp(
        `${CREDENTIAL_SETS.length} of ${CREDENTIAL_SETS.length} provider credential sets satisfied\\n`,
      ),
    );
    // Undeclared files are listed by path and mode.
    assert.match(r.out, /files no provider declares:/);
    assert.match(r.out, /gmail-workspace\/keys\/sa\.json \(mode 0600\)/);
    assert.match(r.out, /verification\.json \(mode 0600\)/);
  });

  it("refuses group- or world-readable files and a directory not 0700, with a visible provider-unavailable reason", async () => {
    const dir = goodDir("leaky");
    chmodSync(join(dir, "yahoo", "qa-1.json"), 0o640);
    // A link is judged by what it reaches.
    chmodSync(join(scratch, "leaky-store", "aol-qa-2.json"), 0o604);
    const r = run(["check"], dir);
    assert.equal(r.status, 1, "an unsafe directory exits 1");
    assert.match(r.out, /UNSAFE/);
    // Every provider is refused, since one readable file exposes its
    // secret whichever provider it belongs to; each names both files.
    for (const set of CREDENTIAL_SETS) {
      const line = r.out.split("\n").find((l) => l.startsWith(`  ${set.id}`));
      assert.ok(line !== undefined, set.id);
      assert.match(line, /UNAVAILABLE: in credentials directory /);
      assert.match(
        line,
        /yahoo\/qa-1\.json is group- or world-readable \(mode 0640; want 0600\)/,
      );
      assert.match(
        line,
        /aol\/qa-2\.json is group- or world-readable \(mode 0604; want 0600\)/,
      );
    }

    // The harness: the provider is unavailable, and its run summary
    // line carries the same reason.
    const health = await assessProvider(credentialProvider("yahoo"), host(dir));
    assert.equal(health.state, "unavailable");
    assert.ok(health.state === "unavailable");
    assert.match(
      health.reason,
      /yahoo\/qa-1\.json is group- or world-readable \(mode 0640; want 0600\)/,
    );
    const [line] = providerSummaryLines([
      {
        id: "needs-yahoo",
        backend: "needs-yahoo",
        version: "1",
        via: "local",
        cold: null,
        health: "unavailable",
        reason: health.reason,
        requests: 0,
        served_elsewhere: 0,
        statuses: {},
        prepare_ms: 0,
        wall_ms: 0,
      },
    ]);
    assert.match(
      line ?? "",
      /provider needs-yahoo .* UNAVAILABLE: .*yahoo\/qa-1\.json is group- or world-readable/,
    );
    // The same provider over the good directory is available.
    const ok = await assessProvider(
      credentialProvider("yahoo"),
      host(join(scratch, "good")),
    );
    assert.equal(ok.state, "ok");

    const open = goodDir("open");
    chmodSync(open, 0o755);
    const o = run(["check"], open);
    assert.equal(o.status, 1);
    assert.match(o.out, /credentials directory .*: mode 0755/);
    assert.match(
      o.out,
      /mailgun \(optional\): UNAVAILABLE: credentials directory .* has mode 0755; it must be 0700/,
    );
    const openHealth = await assessProvider(
      credentialProvider("mailgun"),
      host(open),
    );
    assert.equal(openHealth.state, "unavailable");
  });

  it("names missing, incomplete, mis-schemed, malformed and unfilled files by path and key", () => {
    const dir = goodDir("broken");
    rmSync(join(dir, "yahoo"), { recursive: true });
    rmSync(join(dir, "inspect", "api.json"));
    writePrivate(
      join(dir, "aol", "qa-1.json"),
      JSON.stringify({ schema: CREDENTIALS_SCHEMA, address: SENTINEL }),
    );
    writePrivate(
      join(dir, "microsoft", "qa-1.json"),
      JSON.stringify({ schema: SENTINEL, password: SENTINEL }),
    );
    // V8's message for this quotes the text: `Unexpected token 's',
    // "s3ntinel-…" is not valid JSON`.
    writePrivate(join(dir, "mailgun", "sending.json"), `${SENTINEL}{`);
    assert.throws(
      () =>
        JSON.parse(readFileSync(join(dir, "mailgun", "sending.json"), "utf8")),
      new RegExp(SENTINEL_PART),
      "the parser's own message would leak the value",
    );
    writePrivate(
      join(dir, "outlook-com", "qa-1.json"),
      JSON.stringify({
        schema: CREDENTIALS_SCHEMA,
        address: "",
        password: SENTINEL,
      }),
    );
    const r = run(["check"], dir);
    assert.equal(r.status, 0, "incomplete is not unsafe: " + r.out);
    assert.match(
      r.out,
      /yahoo: UNAVAILABLE: .*no account file matches yahoo\/\*\.json/,
    );
    assert.match(
      r.out,
      /inspect: UNAVAILABLE: .*inspect\/api\.json is missing/,
    );
    assert.match(
      r.out,
      /aol: UNAVAILABLE: .*aol\/qa-1\.json lacks password, app_password/,
    );
    assert.match(
      r.out,
      /microsoft \(optional\): UNAVAILABLE: .*microsoft\/qa-1\.json does not have "schema": "isonim-email\.credentials\.v1"/,
    );
    assert.match(
      r.out,
      /mailgun \(optional\): UNAVAILABLE: .*mailgun\/sending\.json is not valid JSON/,
    );
    assert.match(
      r.out,
      /outlook-com: UNAVAILABLE: .*outlook-com\/qa-1\.json has an empty address/,
    );
    assert.match(r.out, /gmail-workspace: ok/);
    assert.equal(run(["check", "--strict"], dir).status, 1);
  });

  it("writes templates 0600 in 0700 directories, reports them unfilled, and never replaces a file", () => {
    const dir = join(scratch, "fresh", "isonim-email");
    const t = run(["template"], dir);
    assert.equal(t.status, 0, t.out);
    assert.equal(modeOf(dir), 0o700);
    for (const set of CREDENTIAL_SETS) {
      const rel = templatePath(set);
      assert.match(
        t.out,
        new RegExp(`wrote ${rel.replace(/[.*]/g, "\\$&")} \\(0600\\)`),
      );
      assert.equal(modeOf(join(dir, rel)), 0o600, rel);
      assert.equal(modeOf(dirname(join(dir, rel))), 0o700, rel);
      const body = JSON.parse(readFileSync(join(dir, rel), "utf8"));
      assert.equal(body.schema, CREDENTIALS_SCHEMA);
      for (const k of Object.keys(set.keys))
        assert.ok(k in body, `${rel} ${k}`);
    }
    const c = run(["check", "--strict"], dir);
    assert.equal(c.status, 1);
    for (const set of CREDENTIAL_SETS)
      assert.match(
        c.out,
        new RegExp(
          `${templatePath(set).replace(/[.*]/g, "\\$&")} is an unfilled template`,
        ),
      );

    // A filled file is kept as it is; a loose directory is tightened.
    const filled = join(dir, "inspect", "api.json");
    writeFileSync(filled, "kept");
    chmodSync(join(dir, "inspect"), 0o755);
    const again = run(["template", "inspect", "mailgun"], dir);
    assert.equal(again.status, 0, again.out);
    assert.match(again.out, /kept inspect\/api\.json/);
    assert.match(again.out, /kept mailgun\/sending\.json/);
    assert.match(again.out, /tightened .*inspect to 0700/);
    assert.equal(readFileSync(filled, "utf8"), "kept");
    assert.equal(modeOf(join(dir, "inspect")), 0o700);
    assert.equal(run(["template", "nope"], dir).status, 2);
  });

  it("requires an app password for the sending sets, keeps the insert route's keys optional, and does not list the verification file", () => {
    const dir = goodDir("selfsend");
    // The verification file a team's tooling places: not listed as
    // undeclared, while another undeclared file still is.
    writePrivate(
      join(dir, "seam-check.json"),
      JSON.stringify({ purpose: "verification", nonce: "n" }),
    );
    // A Gmail account with an app password and no gmail_api is complete.
    writePrivate(
      join(dir, "gmail-workspace", "qa-1.json"),
      JSON.stringify({
        schema: CREDENTIALS_SCHEMA,
        address: `${SENTINEL}-a`,
        password: `${SENTINEL}-p`,
        app_password: `${SENTINEL}-ap`,
      }),
    );
    const ok = run(["check", "--strict"], dir);
    assert.equal(ok.status, 0, ok.out);
    assert.match(ok.out, /\n  gmail-workspace: ok /);
    assert.doesNotMatch(ok.out, /seam-check\.json/);
    assert.match(ok.out, /verification\.json \(mode 0600\)/);
    // The optional sets say so; the account sets do not.
    for (const id of ["microsoft", "mailgun"])
      assert.match(ok.out, new RegExp(`\\n  ${id} \\(optional\\): ok `));
    for (const id of ["gmail-workspace", "yahoo", "aol", "outlook-com"])
      assert.match(ok.out, new RegExp(`\\n  ${id}: ok `));

    // An account with only its own password cannot send: Gmail, Yahoo
    // and AOL need app_password; Outlook.com (it only receives) does not.
    for (const id of ["gmail-workspace", "yahoo", "aol", "outlook-com"])
      writePrivate(
        join(dir, id, "qa-1.json"),
        JSON.stringify({
          schema: CREDENTIALS_SCHEMA,
          address: `${SENTINEL}-a`,
          password: `${SENTINEL}-p`,
        }),
      );
    const r = run(["check"], dir);
    for (const id of ["gmail-workspace", "yahoo", "aol"])
      assert.match(
        r.out,
        new RegExp(
          `\\n  ${id}: UNAVAILABLE: .*${id}/qa-1\\.json lacks app_password`,
        ),
      );
    assert.match(r.out, /\n  outlook-com: ok /);

    // A world-readable verification file is still refused.
    chmodSync(join(dir, "seam-check.json"), 0o644);
    const leaky = run(["check"], dir);
    assert.equal(leaky.status, 1);
    assert.match(leaky.out, /seam-check\.json is group- or world-readable/);

    // The template carries the optional keys, marked as optional.
    const tdir = join(scratch, "selfsend-template");
    run(["template", "gmail-workspace"], tdir);
    const body = JSON.parse(
      readFileSync(join(tdir, "gmail-workspace", "example.json"), "utf8"),
    );
    assert.match(body.app_password, /^REPLACE: an app password/);
    assert.match(
      body.gmail_api.mode,
      /^OPTIONAL: .*delete this key if unused$/,
    );
  });

  it("never prints a value: a sentinel seeded in every file appears in no output and no written file", () => {
    // Positive control: the sentinel is really in the files checked,
    // including where a parser message would quote it.
    const dir = goodDir("sentinel");
    cpSync(join(scratch, "broken"), join(scratch, "sentinel-broken"), {
      recursive: true,
    });
    const seeded = readdirSync(dir, { recursive: true, withFileTypes: true })
      .filter((e) => e.isFile())
      .map((e) => readFileSync(join(e.parentPath, e.name), "utf8"));
    assert.ok(seeded.length > 5 && seeded.every((t) => t.includes(SENTINEL)));

    const leaky = join(scratch, "leaky");
    for (const d of [dir, join(scratch, "sentinel-broken"), leaky]) {
      run(["check"], d);
      run(["check", "--strict"], d);
    }
    // A template run over a directory full of secrets keeps them and
    // writes only placeholders.
    const tdir = join(scratch, "sentinel-template");
    cpSync(dir, tdir, { recursive: true });
    rmSync(join(tdir, "yahoo"), { recursive: true });
    run(["template"], tdir);
    const written = readFileSync(join(tdir, "yahoo", "example.json"), "utf8");
    assert.doesNotMatch(written, new RegExp(SENTINEL_PART));

    // Every output of every command this file ran.
    assert.ok(outputs.length >= 10, `${outputs.length} outputs`);
    for (const out of outputs)
      assert.equal(out.includes(SENTINEL_PART), false, `leaked in: ${out}`);
    // And every file the commands wrote (the template directories).
    for (const d of [join(scratch, "fresh"), tdir]) {
      for (const e of readdirSync(d, {
        recursive: true,
        withFileTypes: true,
      })) {
        if (!e.isFile()) continue;
        const rel = join(e.parentPath, e.name);
        const fromSeed = rel.startsWith(tdir) && !rel.endsWith("example.json");
        if (fromSeed) continue; // copied in by the test, not written
        assert.equal(
          readFileSync(rel, "utf8").includes(SENTINEL_PART),
          false,
          rel,
        );
      }
    }
  });
});
