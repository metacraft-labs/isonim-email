// tools/capture/providers/requirements.test.ts — the requirement checks
// a provider's declarations go through before it is used: binaries on
// PATH, a usable nix, an environment variable naming a directory, the
// host OS, and the credentials directory (location, 0700 directory, no
// group- or world-readable file anywhere in it, declared or not, never
// printing a secret).
//
// No test doubles: every check runs against real files, directories and
// executables created under a scratch directory, with PATH and the
// credentials location pointed at them. Run with:
//   node --test tools/capture/providers/requirements.test.ts

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  checkRequirement,
  credentialsDir,
  type HostEnv,
  unmetReason,
  checkRequirements,
} from "./requirements.ts";
import type { Requirement } from "./types.ts";

const scratch = mkdtempSync(join(tmpdir(), "capture-requirements-"));
after(() => rmSync(scratch, { recursive: true, force: true }));

const bin = join(scratch, "bin");
mkdirSync(bin);
for (const name of ["sway-like", "nix"]) {
  writeFileSync(join(bin, name), "#!/bin/sh\nexit 0\n");
  chmodSync(join(bin, name), 0o755);
}
// Present but not executable: not a usable binary.
writeFileSync(join(bin, "not-exec"), "data");
chmodSync(join(bin, "not-exec"), 0o644);

function host(
  env: Record<string, string | undefined>,
  platform = "linux",
): HostEnv {
  return { env, platform };
}

const why = { why: "the test provider needs it" };

describe("binary and nix requirements", () => {
  it("finds an executable on PATH and names a missing one", () => {
    const h = host({ PATH: `/nonexistent:${bin}` });
    const ok = checkRequirement(
      { kind: "binary", name: "sway-like", ...why },
      h,
    );
    assert.equal(ok.met, true);
    assert.match(ok.detail, new RegExp(`sway-like at ${bin}/sway-like`));
    const missing = checkRequirement(
      { kind: "binary", name: "grim-like", ...why },
      h,
    );
    assert.equal(missing.met, false);
    assert.match(
      missing.detail,
      /grim-like is not on PATH \(needed: the test provider needs it\)/,
    );
    const notExec = checkRequirement(
      { kind: "binary", name: "not-exec", ...why },
      h,
    );
    assert.equal(notExec.met, false);
  });

  it("nix is available only when a nix executable is on PATH", () => {
    const req: Requirement = { kind: "nix", ...why };
    assert.equal(checkRequirement(req, host({ PATH: bin })).met, true);
    const r = checkRequirement(req, host({ PATH: join(scratch, "empty") }));
    assert.equal(r.met, false);
    assert.match(r.detail, /nix is not on PATH/);
  });
});

describe("environment and host requirements", () => {
  it("env-dir needs the variable set to an existing directory", () => {
    const req: Requirement = { kind: "env-dir", variable: "BROWSERS", ...why };
    assert.equal(checkRequirement(req, host({ BROWSERS: scratch })).met, true);
    assert.match(checkRequirement(req, host({})).detail, /BROWSERS is not set/);
    assert.match(
      checkRequirement(req, host({ BROWSERS: join(scratch, "nope") })).detail,
      /is not a readable directory/,
    );
    assert.equal(
      checkRequirement(req, host({ BROWSERS: join(bin, "nix") })).met,
      false,
      "a file is not a directory",
    );
  });

  it("host-os compares the platform with the supported list", () => {
    const req: Requirement = {
      kind: "host-os",
      os: ["linux", "darwin"],
      ...why,
    };
    assert.equal(checkRequirement(req, host({}, "linux")).met, true);
    const r = checkRequirement(req, host({}, "win32"));
    assert.equal(r.met, false);
    assert.match(
      r.detail,
      /host OS win32 is not supported \(supported: linux, darwin\)/,
    );
  });

  it("unmetReason joins every unmet requirement and is null when all are met", () => {
    const h = host({ PATH: bin }, "linux");
    const all: Requirement[] = [
      { kind: "binary", name: "sway-like", ...why },
      { kind: "host-os", os: ["linux"], ...why },
    ];
    assert.equal(unmetReason(checkRequirements(all, h)), null);
    const reason = unmetReason(
      checkRequirements(
        [
          ...all,
          { kind: "binary", name: "a-missing", ...why },
          { kind: "host-os", os: ["darwin"], ...why },
        ],
        h,
      ),
    );
    assert.match(
      reason ?? "",
      /a-missing is not on PATH.*; host OS linux is not supported/,
    );
  });
});

describe("credentials requirements", () => {
  it("locates the directory from the explicit variable, then XDG_CONFIG_HOME, then HOME", () => {
    assert.equal(
      credentialsDir(
        host({ ISONIM_EMAIL_CREDENTIALS_DIR: "/x/creds", HOME: "/h" }),
      ),
      "/x/creds",
    );
    assert.equal(
      credentialsDir(host({ XDG_CONFIG_HOME: "/cfg", HOME: "/h" })),
      "/cfg/metacraft/dev-credentials/isonim-email",
    );
    assert.equal(
      credentialsDir(host({ HOME: "/h" })),
      "/h/.config/metacraft/dev-credentials/isonim-email",
    );
  });

  const SECRET = "hunter2-do-not-print";
  function credsDir(name: string, dirMode: number, fileMode: number): string {
    const dir = join(scratch, name);
    mkdirSync(join(dir, "inspect"), { recursive: true });
    writeFileSync(
      join(dir, "inspect", "api.json"),
      JSON.stringify({
        schema: "isonim-email.credentials.v1",
        api_key: SECRET,
      }),
    );
    chmodSync(join(dir, "inspect", "api.json"), fileMode);
    chmodSync(dir, dirMode);
    return dir;
  }
  // A good directory plus a file no requirement declares.
  function withExtra(name: string, extraMode: number): string {
    const dir = credsDir(name, 0o700, 0o600);
    mkdirSync(join(dir, "microsoft"));
    writeFileSync(
      join(dir, "microsoft", "qa-1.json"),
      JSON.stringify({ password: SECRET }),
    );
    chmodSync(join(dir, "microsoft", "qa-1.json"), extraMode);
    return dir;
  }
  const req: Requirement = {
    kind: "credentials",
    files: ["inspect/api.json"],
    ...why,
  };

  it("accepts a 0700 directory holding the declared 0600 files", () => {
    const dir = credsDir("good", 0o700, 0o600);
    const r = checkRequirement(
      req,
      host({ ISONIM_EMAIL_CREDENTIALS_DIR: dir }),
    );
    assert.equal(r.met, true, r.detail);
    // Undeclared files are fine when they are private too.
    const extra = checkRequirement(
      req,
      host({ ISONIM_EMAIL_CREDENTIALS_DIR: withExtra("extra-ok", 0o600) }),
    );
    assert.equal(extra.met, true, extra.detail);
  });

  it("refuses a missing directory, a directory not 0700, a readable file and a missing file, never printing a secret", () => {
    const cases: [string, HostEnv, RegExp][] = [
      [
        "missing dir",
        host({ ISONIM_EMAIL_CREDENTIALS_DIR: join(scratch, "absent") }),
        /does not exist/,
      ],
      [
        "0755 dir",
        host({ ISONIM_EMAIL_CREDENTIALS_DIR: credsDir("open", 0o755, 0o600) }),
        /has mode 0755; it must be 0700/,
      ],
      [
        "0644 file",
        host({ ISONIM_EMAIL_CREDENTIALS_DIR: credsDir("leaky", 0o700, 0o644) }),
        /inspect\/api.json is group- or world-readable \(mode 0644; want 0600\)/,
      ],
      [
        "0640 file (group-readable only)",
        host({ ISONIM_EMAIL_CREDENTIALS_DIR: credsDir("group", 0o700, 0o640) }),
        /inspect\/api.json is group- or world-readable \(mode 0640; want 0600\)/,
      ],
      [
        "undeclared 0644 file",
        host({ ISONIM_EMAIL_CREDENTIALS_DIR: withExtra("extra", 0o644) }),
        /microsoft\/qa-1.json is group- or world-readable \(mode 0644; want 0600\)/,
      ],
    ];
    for (const [name, h, pattern] of cases) {
      const r = checkRequirement(req, h);
      assert.equal(r.met, false, name);
      assert.match(r.detail, pattern, name);
      assert.doesNotMatch(
        r.detail,
        new RegExp(SECRET),
        `${name} printed a secret`,
      );
    }
    const missingFile = checkRequirement(
      {
        kind: "credentials",
        files: ["inspect/api.json", "mailgun/sending.json"],
        ...why,
      },
      host({ ISONIM_EMAIL_CREDENTIALS_DIR: join(scratch, "good") }),
    );
    assert.equal(missingFile.met, false);
    assert.match(missingFile.detail, /mailgun\/sending.json is missing/);
    assert.doesNotMatch(missingFile.detail, /inspect\/api.json/);
  });
});
