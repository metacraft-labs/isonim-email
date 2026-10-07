// tools/capture/providers/credentials.ts — the credentials each hosted
// provider declares, the report `just email-credentials-check` prints,
// and the placeholder layout `just email-credentials-template` writes.
//
// The credentials directory (requirements.ts: location, a 0700
// directory, no group- or world-readable file, the schema and declared
// keys of every declared file) holds one JSON file per account, grouped
// by provider. Nothing in this library puts accounts there: a
// contributor fills it from the templates, or a team's own tooling
// places the files. The providers that read it declare their files here,
// in one table, so the check and the providers read the same list.
//
// Nothing here prints a value: the report is built from requirement
// details (paths, modes and key names) and from the directory listing
// (paths and modes), and a template holds placeholders only.

import {
  chmodSync,
  existsSync,
  mkdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import {
  checkRequirement,
  credentialsDir,
  CREDENTIALS_SCHEMA,
  entryMatches,
  type HostEnv,
  inspectCredentialsDir,
  isAccountPool,
  poolDir,
  type RequirementStatus,
  TEMPLATE_MARKER,
} from "./requirements.ts";
import type { Requirement } from "./types.ts";

export interface CredentialSet {
  // The provider directory, and what the check calls the set.
  id: string;
  // Who reads it, for the requirement's `why`.
  usedBy: string;
  // "<id>/*.json" (an account pool) or an exact path.
  entry: string;
  // Keys every matching file must carry, and what to put in each, for
  // the template.
  keys: Record<string, unknown>;
  // Keys a file may carry for an optional route, written into the
  // template (each saying it may be deleted) but never required.
  optionalKeys?: Record<string, unknown>;
  // A set the hosted webmail does not need (the check marks it
  // "(optional)").
  optional?: boolean;
}

const REPLACE = (what: string): string => `REPLACE: ${what}`;

const ACCOUNT = {
  address: REPLACE("the account's email address"),
  password: REPLACE(
    "the account's password (for the person who signs the webmail in; never sent over SMTP or IMAP)",
  ),
};

const APP_PASSWORD = REPLACE(
  "an app password for SMTP and IMAP (the provider issues it once 2-Step Verification is on); delivery sends with it",
);

const OPTIONAL = (what: string): string =>
  `OPTIONAL: ${what}; delete this key if unused`;

export const CREDENTIAL_SETS: CredentialSet[] = [
  {
    // Any Gmail account, consumer or Workspace (the directory keeps its
    // name).
    id: "gmail-workspace",
    usedBy:
      "hosted webmail (Gmail, a consumer or Workspace account; delivery sends with its app password)",
    entry: "gmail-workspace/*.json",
    keys: { ...ACCOUNT, app_password: APP_PASSWORD },
    optionalKeys: {
      gmail_api: {
        mode: OPTIONAL(
          'only for the Gmail API insert route: "service-account-dwd" or "oauth"',
        ),
        key_file: OPTIONAL(
          'with service-account-dwd: "keys/sa.json", the key file beside the accounts',
        ),
        client_id: OPTIONAL("with oauth: the OAuth client id"),
        client_secret: OPTIONAL("with oauth: the OAuth client secret"),
        refresh_token: OPTIONAL("with oauth: the refresh token"),
      },
    },
  },
  {
    id: "yahoo",
    usedBy: "hosted webmail (Yahoo Mail; delivery sends with its app password)",
    entry: "yahoo/*.json",
    keys: { ...ACCOUNT, app_password: APP_PASSWORD },
  },
  {
    id: "aol",
    usedBy: "hosted webmail (AOL Mail; delivery sends with its app password)",
    entry: "aol/*.json",
    keys: { ...ACCOUNT, app_password: APP_PASSWORD },
  },
  {
    id: "outlook-com",
    usedBy:
      "hosted webmail (Outlook.com, a consumer account; it receives from another account, so it needs no app password)",
    entry: "outlook-com/*.json",
    keys: { ...ACCOUNT },
  },
  {
    id: "microsoft",
    usedBy:
      "hosted webmail (Outlook on the web, a Microsoft 365 tenant user; optional, for the injection route)",
    entry: "microsoft/*.json",
    keys: {
      ...ACCOUNT,
      tenant: REPLACE("the tenant id"),
      client_id: REPLACE("the app registration's client id"),
      client_secret: REPLACE("the app registration's client secret"),
    },
    optional: true,
  },
  {
    id: "mailgun",
    usedBy:
      "sending from a domain of our own (Mailgun; optional: hosted webmail delivery sends from the QA accounts themselves)",
    entry: "mailgun/sending.json",
    keys: {
      domain: REPLACE("the sending domain"),
      api_key: REPLACE("a sending key scoped to that domain only"),
    },
    optional: true,
  },
  {
    id: "inspect",
    usedBy:
      "the device-farm service (Inspect; that backend only, not needed for hosted webmail)",
    entry: "inspect/api.json",
    keys: {
      api_key: REPLACE("the API key"),
      monthly_cap: REPLACE("the most captures a month may use, a number"),
    },
  },
];

// A file a team's tooling may place at the top of the directory to
// prove that its secrets decrypt there: not a credential and no
// provider's, so the check does not list it as undeclared (its mode is
// still checked, like every file's).
export const VERIFICATION_FILE = "seam-check.json";

export function credentialSet(id: string): CredentialSet {
  const set = CREDENTIAL_SETS.find((s) => s.id === id);
  if (set === undefined)
    throw new Error(
      `unknown credential set ${id} (known: ${CREDENTIAL_SETS.map((s) => s.id).join(", ")})`,
    );
  return set;
}

// The requirement a provider returns from requirements() for a set.
export function credentialRequirement(id: string): Requirement {
  const set = credentialSet(id);
  return {
    kind: "credentials",
    files: [set.entry],
    fields: { [set.entry]: Object.keys(set.keys) },
    why: `credentials for ${set.usedBy}`,
  };
}

export interface CredentialsReport {
  dir: string;
  dirMode: string | null;
  // The directory itself is unusable or exposes a file.
  unsafe: boolean;
  sets: { set: CredentialSet; status: RequirementStatus }[];
  // Files present that no set declares, with their modes.
  undeclared: { path: string; mode: string | null }[];
}

export function credentialsReport(host: HostEnv): CredentialsReport {
  const state = inspectCredentialsDir(host);
  const exposed = state.files.some((f) => f.problem !== null);
  // The directory exists but is refused (not 0700, not a directory).
  const dirUnsafe = state.mode !== null && state.problem !== null;
  const declared = new Set<string>();
  for (const set of CREDENTIAL_SETS)
    for (const p of entryMatches(set.entry, state)) declared.add(p);
  return {
    dir: state.dir,
    dirMode: state.mode,
    unsafe: dirUnsafe || exposed,
    sets: CREDENTIAL_SETS.map((set) => ({
      set,
      status: checkRequirement(credentialRequirement(set.id), host),
    })),
    undeclared: state.files
      .filter((f) => !declared.has(f.path) && f.path !== VERIFICATION_FILE)
      .map((f) => ({ path: f.path, mode: f.mode })),
  };
}

export function reportLines(r: CredentialsReport): string[] {
  const lines = [
    `credentials directory ${r.dir}: ${
      r.dirMode === null ? "absent" : `mode ${r.dirMode}`
    }`,
  ];
  for (const { set, status } of r.sets) {
    const name = `${set.id}${set.optional === true ? " (optional)" : ""}`;
    lines.push(
      status.met
        ? `  ${name}: ok (${status.detail})`
        : `  ${name}: UNAVAILABLE: ${status.detail}`,
    );
  }
  if (r.undeclared.length > 0) {
    lines.push("  files no provider declares:");
    for (const f of r.undeclared)
      lines.push(
        `    ${f.path} (${f.mode === null ? "unresolved" : `mode ${f.mode}`})`,
      );
  }
  const met = r.sets.filter((s) => s.status.met).length;
  lines.push(
    `${met} of ${r.sets.length} provider credential sets satisfied${
      r.unsafe ? "; the directory is UNSAFE (see above)" : ""
    }`,
  );
  return lines;
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------

// The placeholder file a set's template writes: the fixed name, or
// example.json in an account pool's directory.
export function templatePath(set: CredentialSet): string {
  return isAccountPool(set.entry)
    ? join(poolDir(set.entry), "example.json")
    : set.entry;
}

export interface TemplateResult {
  dir: string;
  written: string[];
  kept: string[];
  // Directory modes tightened to 0700.
  tightened: string[];
}

function privateDir(path: string, tightened: string[]): void {
  if (!existsSync(path)) {
    mkdirSync(path, { recursive: true, mode: 0o700 });
  } else if ((statSync(path).mode & 0o777) === 0o700) {
    return;
  } else {
    tightened.push(path);
  }
  chmodSync(path, 0o700);
}

export function writeTemplates(ids: string[], host: HostEnv): TemplateResult {
  const sets =
    ids.length === 0 ? CREDENTIAL_SETS : ids.map((id) => credentialSet(id));
  const dir = credentialsDir(host);
  const result: TemplateResult = {
    dir,
    written: [],
    kept: [],
    tightened: [],
  };
  privateDir(dir, result.tightened);
  for (const set of sets) {
    const rel = templatePath(set);
    privateDir(join(dir, dirname(rel)), result.tightened);
    const full = join(dir, rel);
    if (existsSync(full)) {
      result.kept.push(rel);
      continue;
    }
    const body = {
      schema: CREDENTIALS_SCHEMA,
      [TEMPLATE_MARKER]: isAccountPool(set.entry)
        ? `a placeholder: fill in every REPLACE value, remove "${TEMPLATE_MARKER}", and rename the file to <account>.json`
        : `a placeholder: fill in every REPLACE value and remove "${TEMPLATE_MARKER}"`,
      ...set.keys,
      ...(set.optionalKeys ?? {}),
    };
    // wx: never replace a file that appeared since the check above.
    writeFileSync(full, `${JSON.stringify(body, null, 2)}\n`, {
      mode: 0o600,
      flag: "wx",
    });
    chmodSync(full, 0o600);
    result.written.push(rel);
  }
  return result;
}
