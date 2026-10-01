// tools/capture/providers/requirements.ts — checking what a provider
// declares it needs before it is used.
//
// Every check reads the real host (PATH, the file system, the platform);
// the host's environment and platform are parameters so a check can be
// pointed at a scratch PATH or directory. A failed check is a reason,
// never an exception: the harness turns it into a visible
// provider-unavailable line in the run summary.
//
// Credentials live in one directory on the machine running the
// captures: $ISONIM_EMAIL_CREDENTIALS_DIR, defaulting to
// ${XDG_CONFIG_HOME:-$HOME/.config}/metacraft/dev-credentials/isonim-email/.
// The directory must be mode 0700 and no file in it may be group- or
// world-readable. A check names paths and modes only; it never reads a
// file's contents, so it cannot print a secret.

import { accessSync, constants, readdirSync, statSync } from "node:fs";
import { delimiter, join } from "node:path";
import type { Requirement } from "./types.ts";

export interface HostEnv {
  env: Record<string, string | undefined>;
  platform: string;
}

export function currentHost(): HostEnv {
  return { env: process.env, platform: process.platform };
}

export interface RequirementStatus {
  requirement: Requirement;
  met: boolean;
  // What was found (met) or what is missing and why it is needed.
  detail: string;
}

export function credentialsDir(host: HostEnv): string {
  const explicit = host.env.ISONIM_EMAIL_CREDENTIALS_DIR;
  if (explicit !== undefined && explicit !== "") return explicit;
  const config =
    host.env.XDG_CONFIG_HOME !== undefined && host.env.XDG_CONFIG_HOME !== ""
      ? host.env.XDG_CONFIG_HOME
      : join(host.env.HOME ?? "", ".config");
  return join(config, "metacraft", "dev-credentials", "isonim-email");
}

// The first executable `name` on the host's PATH, or null.
export function findExecutable(name: string, host: HostEnv): string | null {
  for (const dir of (host.env.PATH ?? "").split(delimiter)) {
    if (dir === "") continue;
    const candidate = join(dir, name);
    try {
      if (!statSync(candidate).isFile()) continue;
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      continue;
    }
  }
  return null;
}

function octal(mode: number): string {
  return (mode & 0o777).toString(8).padStart(4, "0");
}

// Every non-directory entry under dir, as paths relative to it.
function filesUnder(dir: string, rel = ""): string[] {
  const out: string[] = [];
  for (const e of readdirSync(join(dir, rel), { withFileTypes: true })) {
    const path = rel === "" ? e.name : join(rel, e.name);
    if (e.isDirectory()) out.push(...filesUnder(dir, path));
    else out.push(path);
  }
  return out;
}

// Group- or world-readable.
const SHARED_READ = 0o044;

function checkCredentials(files: string[], host: HostEnv): string | null {
  const dir = credentialsDir(host);
  let dirStat;
  try {
    dirStat = statSync(dir);
  } catch {
    return `credentials directory ${dir} does not exist`;
  }
  if (!dirStat.isDirectory())
    return `credentials directory ${dir} is not a directory`;
  if ((dirStat.mode & 0o777) !== 0o700)
    return `credentials directory ${dir} has mode ${octal(dirStat.mode)}; it must be 0700`;
  const problems: string[] = [];
  // Every file in the directory, declared or not: one readable file
  // exposes its secret whichever provider it belongs to.
  let present: string[];
  try {
    present = filesUnder(dir).sort();
  } catch (err) {
    return `credentials directory ${dir} cannot be listed (${err instanceof Error ? err.message : String(err)})`;
  }
  for (const file of present) {
    let st;
    try {
      st = statSync(join(dir, file));
    } catch {
      problems.push(`${file} cannot be read (a dangling link?)`);
      continue;
    }
    if ((st.mode & SHARED_READ) !== 0)
      problems.push(
        `${file} is group- or world-readable (mode ${octal(st.mode)}; want 0600)`,
      );
  }
  for (const file of files) {
    let st;
    try {
      st = statSync(join(dir, file));
    } catch {
      problems.push(`${file} is missing`);
      continue;
    }
    if (!st.isFile()) problems.push(`${file} is not a regular file`);
  }
  return problems.length === 0
    ? null
    : `in credentials directory ${dir}: ${problems.join("; ")}`;
}

export function checkRequirement(
  req: Requirement,
  host: HostEnv,
): RequirementStatus {
  const met = (detail: string): RequirementStatus => ({
    requirement: req,
    met: true,
    detail,
  });
  const unmet = (detail: string): RequirementStatus => ({
    requirement: req,
    met: false,
    detail: `${detail} (needed: ${req.why})`,
  });
  switch (req.kind) {
    case "binary": {
      const found = findExecutable(req.name, host);
      return found !== null
        ? met(`${req.name} at ${found}`)
        : unmet(`${req.name} is not on PATH`);
    }
    case "nix": {
      const found = findExecutable("nix", host);
      return found !== null
        ? met(`nix at ${found}`)
        : unmet("nix is not on PATH");
    }
    case "env-dir": {
      const value = host.env[req.variable];
      if (value === undefined || value === "")
        return unmet(`${req.variable} is not set`);
      try {
        if (statSync(value).isDirectory())
          return met(`${req.variable}=${value}`);
      } catch {
        // fall through: not a readable directory
      }
      return unmet(`${req.variable}=${value} is not a readable directory`);
    }
    case "credentials": {
      const problem = checkCredentials(req.files, host);
      return problem === null
        ? met(
            `${req.files.length} credential file(s) in ${credentialsDir(host)}`,
          )
        : unmet(problem);
    }
    case "service":
      // Shared services are the harness's to start (services.ts); a
      // service that is not registered or fails to start makes the
      // provider unavailable there, with that reason.
      return met(`service ${req.name} (started by the harness)`);
    case "host-os":
      return req.os.includes(host.platform)
        ? met(`host OS ${host.platform}`)
        : unmet(
            `host OS ${host.platform} is not supported (supported: ${req.os.join(", ")})`,
          );
  }
}

export function checkRequirements(
  reqs: Requirement[],
  host: HostEnv,
): RequirementStatus[] {
  return reqs.map((r) => checkRequirement(r, host));
}

// Every unmet requirement's detail, joined; null when all are met.
export function unmetReason(statuses: RequirementStatus[]): string | null {
  const unmet = statuses.filter((s) => !s.met).map((s) => s.detail);
  return unmet.length === 0 ? null : unmet.join("; ");
}
