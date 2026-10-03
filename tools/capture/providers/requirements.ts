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
// world-readable. A declared file must be a JSON object whose `schema`
// is CREDENTIALS_SCHEMA, carrying the declared keys, and not an unfilled
// template (credentials.ts writes those). The check reads a declared
// file to look at its keys, but what it reports names only paths, modes
// and key names: never a value, never the schema it found, and never a
// JSON parser's message (V8's quotes the text it failed on), so it
// cannot print a secret.

import {
  accessSync,
  constants,
  readdirSync,
  readFileSync,
  statSync,
} from "node:fs";
import { delimiter, dirname, join } from "node:path";
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

export const CREDENTIALS_SCHEMA = "isonim-email.credentials.v1";
// A placeholder file credentials.ts wrote and nobody filled in yet.
export const TEMPLATE_MARKER = "_template";
// A `files` entry naming an account pool: "<dir>/*.json" matches every
// .json file directly in <dir> (not in its subdirectories).
const POOL_SUFFIX = "/*.json";

export function isAccountPool(entry: string): boolean {
  return entry.endsWith(POOL_SUFFIX);
}

export function poolDir(entry: string): string {
  return entry.slice(0, -POOL_SUFFIX.length);
}

export interface CredentialFile {
  // Relative to the credentials directory.
  path: string;
  // The mode of what the path resolves to (a link is followed); null
  // when it cannot be resolved.
  mode: string | null;
  // Why the file exposes or loses its secret; null when it is private.
  problem: string | null;
}

export interface CredentialsDirState {
  dir: string;
  // The directory's own mode, when it exists.
  mode: string | null;
  // Why the directory cannot be used at all; null when it is a private
  // directory that could be listed.
  problem: string | null;
  files: CredentialFile[];
}

// The credentials directory and every file in it, declared or not: one
// readable file exposes its secret whichever provider it belongs to.
// Reads modes only.
export function inspectCredentialsDir(host: HostEnv): CredentialsDirState {
  const dir = credentialsDir(host);
  const state: CredentialsDirState = {
    dir,
    mode: null,
    problem: null,
    files: [],
  };
  let dirStat;
  try {
    dirStat = statSync(dir);
  } catch {
    state.problem = `credentials directory ${dir} does not exist`;
    return state;
  }
  state.mode = octal(dirStat.mode);
  if (!dirStat.isDirectory()) {
    state.problem = `credentials directory ${dir} is not a directory`;
    return state;
  }
  if ((dirStat.mode & 0o777) !== 0o700) {
    state.problem = `credentials directory ${dir} has mode ${octal(dirStat.mode)}; it must be 0700`;
    return state;
  }
  let present: string[];
  try {
    present = filesUnder(dir).sort();
  } catch (err) {
    state.problem = `credentials directory ${dir} cannot be listed (${err instanceof Error ? err.message : String(err)})`;
    return state;
  }
  for (const path of present) {
    let st;
    try {
      st = statSync(join(dir, path));
    } catch {
      state.files.push({
        path,
        mode: null,
        problem: `${path} cannot be read (a dangling link?)`,
      });
      continue;
    }
    state.files.push({
      path,
      mode: octal(st.mode),
      problem:
        (st.mode & SHARED_READ) !== 0
          ? `${path} is group- or world-readable (mode ${octal(st.mode)}; want 0600)`
          : null,
    });
  }
  return state;
}

// The declared files an entry matches among those present.
export function entryMatches(
  entry: string,
  state: CredentialsDirState,
): string[] {
  if (!isAccountPool(entry))
    return state.files.some((f) => f.path === entry) ? [entry] : [];
  const dir = poolDir(entry);
  return state.files
    .map((f) => f.path)
    .filter((p) => dirname(p) === dir && p.endsWith(".json"));
}

// What is wrong with one declared file's contents, or null. Never
// includes a value: only the path and key names.
function contentProblem(
  dir: string,
  path: string,
  keys: string[],
): string | null {
  const full = join(dir, path);
  try {
    if (!statSync(full).isFile()) return `${path} is not a regular file`;
  } catch {
    return null; // reported by inspectCredentialsDir
  }
  let text: string;
  try {
    text = readFileSync(full, "utf8");
  } catch {
    return `${path} cannot be read`;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    // Not the parser's message: it quotes the text it failed on.
    return `${path} is not valid JSON`;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
    return `${path} is not a JSON object`;
  const obj = parsed as Record<string, unknown>;
  if (obj.schema !== CREDENTIALS_SCHEMA)
    return `${path} does not have "schema": "${CREDENTIALS_SCHEMA}"`;
  if (TEMPLATE_MARKER in obj)
    return `${path} is an unfilled template (fill it in and remove "${TEMPLATE_MARKER}")`;
  const missing = keys.filter((k) => !(k in obj));
  if (missing.length > 0) return `${path} lacks ${missing.join(", ")}`;
  const empty = keys.filter((k) => obj[k] === "" || obj[k] === null);
  if (empty.length > 0) return `${path} has an empty ${empty.join(", ")}`;
  return null;
}

function checkCredentials(
  files: string[],
  fields: Record<string, string[]>,
  host: HostEnv,
): string | null {
  const state = inspectCredentialsDir(host);
  if (state.problem !== null) return state.problem;
  const problems: string[] = state.files.flatMap((f) =>
    f.problem === null ? [] : [f.problem],
  );
  for (const entry of files) {
    const matches = entryMatches(entry, state);
    if (matches.length === 0) {
      problems.push(
        isAccountPool(entry)
          ? `no account file matches ${entry}`
          : `${entry} is missing`,
      );
      continue;
    }
    for (const path of matches) {
      const p = contentProblem(state.dir, path, fields[entry] ?? []);
      if (p !== null) problems.push(p);
    }
  }
  return problems.length === 0
    ? null
    : `in credentials directory ${state.dir}: ${problems.join("; ")}`;
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
      const problem = checkCredentials(req.files, req.fields ?? {}, host);
      return problem === null
        ? met(`${req.files.join(", ")} in ${credentialsDir(host)}`)
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
