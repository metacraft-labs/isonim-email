#!/usr/bin/env node
// tools/capture/email-webmail-checklist.ts — `just email-webmail-checklist`:
// what a person does, in order, before `just email-shots --backends b`
// can capture the hosted webmails, and how far this machine has got.
//
// It reads only local state (the credentials directory, the webmail
// profiles and their markers) and contacts nothing. It names files and
// account names, never an address or a secret. Exits 0 when the
// automatic checks (steps 1-3) pass for at least one webmail, 3 when
// something is pending.

import { WORKSPACE_SENDER_SET } from "./providers/credentials.ts";
import {
  credentialsDir,
  currentHost,
  type HostEnv,
  inspectCredentialsDir,
} from "./providers/requirements.ts";
import {
  BUDGET_ENV,
  dailyBudget,
  poolAccounts,
  readiness,
} from "./providers/webmail_accounts.ts";
import { WEBMAIL_ADAPTERS } from "./providers/webmail_adapters.ts";
import { profilesRoot } from "./providers/webmail_profiles.ts";
import { loadWorkspaceSender } from "./providers/workspace_send.ts";

const USAGE = `usage: email-webmail-checklist

The steps a person runs, in order, before hosted-webmail captures
(\`just email-shots --backends b\`) can run on this machine, each with
what this machine shows of it now:

  1. Unlock the QA credential set into the credentials directory
      (\$ISONIM_EMAIL_CREDENTIALS_DIR; a team's materialiser does it, or
      fill it from \`just email-credentials-template\`), then
      \`just email-credentials-check\`.
  2. The Workspace sender: a service account delegated gmail.send only,
      acting as the sender user, sealed into the set as
      ${WORKSPACE_SENDER_SET}/<name>.json with subject, from and
      allowed_recipients (the QA addresses).
  3. Sign in each QA account's webmail profile:
      \`just email-webmail-signin <set> --account <name>\` (automated: one
      attempt per account, then a 24 h cool-down; a challenge stops it
      for a person over VNC, --takeover; --manual for a person's sign-in;
      docs/webmail-signin.md).
  4. One smoke send per set: \`just email-workspace-send-smoke <set>\`,
      then look for the message in that webmail (Inbox or Spam) by hand.
  5. The first capture:
      \`just email-shots receiptTypical --backends b --clients gmail-web --no-cache\`
      and check <run>/hosted-webmail-cleanup.jsonl says "removed".

Steps 1-3 are checked here; 4 and 5 are live and only listed. Nothing
is contacted and no address or secret is printed. Exits 0 when steps
1-3 pass for at least one webmail, 3 when something is pending.
`;

function main(): number {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) {
    process.stdout.write(USAGE);
    return 0;
  }
  if (args.length > 0) {
    process.stderr.write(
      `email-webmail-checklist: unknown argument ${args[0]}\n${USAGE}`,
    );
    return 2;
  }
  const host: HostEnv = currentHost();
  const out: string[] = [];
  const mark = (ok: boolean | null): string =>
    ok === null ? "[ live ]" : ok ? "[  ok  ]" : "[PENDING]";

  // 1. The credentials directory.
  const state = inspectCredentialsDir(host);
  const dirOk = state.problem === null;
  out.push(
    `${mark(dirOk)} 1. credentials directory ${credentialsDir(host)}${dirOk ? "" : `: ${state.problem}`}`,
  );
  if (!dirOk)
    out.push(
      "           unlock the QA set there (or `just email-credentials-template` and fill it in), then `just email-credentials-check`",
    );

  // 2. The sender.
  let senderOk = false;
  let senderWhy = "";
  if (dirOk)
    try {
      const s = loadWorkspaceSender(host);
      senderOk = true;
      senderWhy = ` (${s.source}, ${s.allowedRecipients.length} allowed recipient(s))`;
    } catch (err) {
      senderWhy = `: ${err instanceof Error ? err.message : String(err)}`;
    }
  else senderWhy = ": needs step 1";
  out.push(`${mark(senderOk)} 2. the Workspace sender${senderWhy}`);
  if (!senderOk && dirOk)
    out.push(
      `           a tenant admin creates the gmail.send-only sender; its file goes in as ${WORKSPACE_SENDER_SET}/<name>.json (\`just email-credentials-check\` names what is missing)`,
    );

  // 3. The sign-ins, per set and account.
  let limit: number;
  try {
    limit = dailyBudget(host.env);
  } catch (err) {
    process.stderr.write(
      `email-webmail-checklist: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    return 2;
  }
  out.push(`         3. sign-ins (profiles under ${profilesRoot(host)}):`);
  let readySets = 0;
  for (const adapter of WEBMAIL_ADAPTERS) {
    const accounts = dirOk
      ? poolAccounts(host, adapter.set, limit, Date.now())
      : [];
    if (accounts.length === 0) {
      out.push(
        `${mark(false)}    ${adapter.label} (${adapter.set}): no account file ${adapter.set}/*.json`,
      );
      continue;
    }
    let anyReady = false;
    for (const a of accounts) {
      const r = readiness(a);
      if (r.ready) anyReady = true;
      out.push(
        r.ready
          ? `${mark(true)}    ${adapter.label} ${a.set}/${a.name}: signed in ${a.signin?.signed_in_at ?? ""}; ${a.budget.count}/${a.budget.limit} deliveries today (${BUDGET_ENV}; drops out at ${a.budget.cutoff})`
          : `${mark(false)}    ${adapter.label} ${a.set}/${a.name}: ${r.why} — run: ${r.remedy}`,
      );
    }
    if (adapter.id === "outlook-com")
      out.push(
        "           Outlook.com: its theme must follow the system (Settings, General, Appearance), so that it is light in a light capture and dark in a dark one (each is checked); set it once in the webmail's settings while signing in",
      );
    if (anyReady) readySets++;
  }

  // 4 and 5: live, listed only.
  const sets = WEBMAIL_ADAPTERS.map((a) => a.set);
  out.push(
    `${mark(null)} 4. one smoke send per set, then look for it in that webmail (Inbox or Spam) by hand:`,
  );
  for (const s of sets)
    out.push(`             just email-workspace-send-smoke ${s}`);
  out.push(
    `${mark(null)} 5. the first capture, then check its cleanup record:`,
  );
  out.push(
    "             just email-shots receiptTypical --backends b --clients gmail-web --no-cache",
  );
  out.push(
    '             (then <run>/hosted-webmail-cleanup.jsonl: "state": "removed")',
  );
  const ok = dirOk && senderOk && readySets > 0;
  out.push(
    ok
      ? `ready: ${readySets} of ${WEBMAIL_ADAPTERS.length} webmails can capture; steps 4 and 5 are the live checks`
      : "PENDING: steps 1-3 are not done for any webmail yet",
  );
  process.stdout.write(`${out.join("\n")}\n`);
  return ok ? 0 : 3;
}

process.exitCode = main();
