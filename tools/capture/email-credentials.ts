// tools/capture/email-credentials.ts — `just email-credentials-check`
// and `just email-credentials-template`: what the credentials directory
// holds for each provider that reads it, and a placeholder layout to
// fill in.
//
// The check prints paths, modes, key names and reasons, never a value
// (providers/credentials.ts, providers/requirements.ts). The template
// writes placeholders only and never replaces an existing file.

import { resolve } from "node:path";
import {
  CREDENTIAL_SETS,
  credentialsReport,
  reportLines,
  writeTemplates,
} from "./providers/credentials.ts";
import { currentHost, type HostEnv } from "./providers/requirements.ts";

const USAGE = `usage: email-credentials check [--strict] [--dir DIR]
  or:  email-credentials template [--dir DIR] [PROVIDER…]

The credentials directory is $ISONIM_EMAIL_CREDENTIALS_DIR, defaulting
to \${XDG_CONFIG_HOME:-$HOME/.config}/metacraft/dev-credentials/isonim-email;
--dir overrides both.

check     Lists, per provider, whether its declared files are present,
          private (the directory 0700, no group- or world-readable file)
          and complete, and the files no provider declares. Never prints
          a secret. Exits 1 when the directory is unsafe (not 0700, or a
          readable file in it), or with --strict when any provider's
          credentials are unavailable; 0 otherwise.
template  Writes a placeholder file (0600) per provider, every provider
          when none is named, in provider directories (0700) under the
          credentials directory (0700, created if absent). Never replaces
          an existing file.

Providers: ${CREDENTIAL_SETS.map((s) => s.id).join(", ")}
`;

function main(): number {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === undefined || cmd === "--help" || cmd === "-h") {
    process.stdout.write(USAGE);
    return cmd === undefined ? 2 : 0;
  }
  let dir: string | null = null;
  let strict = false;
  const positional: string[] = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i]!;
    if (a === "--help") {
      process.stdout.write(USAGE);
      return 0;
    }
    if (a === "--dir" && rest[i + 1] !== undefined) {
      dir = resolve(rest[++i]!);
      continue;
    }
    if (a === "--strict" && cmd === "check") {
      strict = true;
      continue;
    }
    if (a.startsWith("-")) {
      process.stderr.write(`email-credentials: unknown option ${a}\n${USAGE}`);
      return 2;
    }
    positional.push(a);
  }
  const base = currentHost();
  const host: HostEnv =
    dir === null
      ? base
      : {
          ...base,
          env: { ...base.env, ISONIM_EMAIL_CREDENTIALS_DIR: dir },
        };

  if (cmd === "check") {
    if (positional.length > 0) {
      process.stderr.write(
        `email-credentials: check takes no providers\n${USAGE}`,
      );
      return 2;
    }
    const report = credentialsReport(host);
    for (const line of reportLines(report)) process.stdout.write(`${line}\n`);
    if (report.unsafe) return 1;
    if (strict && report.sets.some((s) => !s.status.met)) return 1;
    return 0;
  }
  if (cmd === "template") {
    const known = CREDENTIAL_SETS.map((s) => s.id);
    for (const p of positional)
      if (!known.includes(p)) {
        process.stderr.write(
          `email-credentials: unknown provider ${p} (they are: ${known.join(", ")})\n`,
        );
        return 2;
      }
    const r = writeTemplates(positional, host);
    process.stdout.write(`credentials directory ${r.dir} (mode 0700)\n`);
    for (const d of r.tightened)
      process.stdout.write(`  tightened ${d} to 0700\n`);
    for (const f of r.written)
      process.stdout.write(`  wrote ${f} (0600): fill it in\n`);
    for (const f of r.kept)
      process.stdout.write(`  kept ${f}: it exists, left as it is\n`);
    return 0;
  }
  process.stderr.write(`email-credentials: unknown command ${cmd}\n${USAGE}`);
  return 2;
}

process.exitCode = main();
