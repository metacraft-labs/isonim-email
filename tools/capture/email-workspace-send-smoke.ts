// tools/capture/email-workspace-send-smoke.ts — `just
// email-workspace-send-smoke`: one live delivery through the Workspace
// sender, end to end as far as the sender can see: a reference story
// (rendered by the story driver) is sent to a QA account of a receiving
// set through the Gmail API, and the command prints the API's message
// id, the Message-ID and the timings. Whether it arrived is the webmail
// adapter's to see (the sender cannot read the QA mailbox).
//
// The sender is the credentials directory's `workspace-sender` file
// (providers/workspace_send.ts). The operator override (three
// ISONIM_EMAIL_WORKSPACE_SENDER_OVERRIDE_* variables: a key file, the
// user to act as, the sender address) replaces it for a one-off check;
// it is announced on every run and sends only to the QA accounts of the
// credentials directory. `--verify-sent` reads the sender's Sent copy
// back with gmail.metadata, which only an operator's key may have.
//
// It prints set and file names, ids and timings: never an address, a
// key or a token.

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  CredentialsUnavailable,
  HOSTED_PROFILES,
  loadHostedAccount,
} from "./providers/hosted_delivery.ts";
import { currentHost, type HostEnv } from "./providers/requirements.ts";
import {
  deliverWorkspace,
  loadWorkspaceSender,
  OVERRIDE_ENV,
  overrideSender,
  readSentCopy,
  type WorkspaceEndpoints,
  type WorkspaceSender,
} from "./providers/workspace_send.ts";

const repoRoot = resolve(
  dirname(new URL(import.meta.url).pathname),
  "..",
  "..",
);
const DEFAULT_STORY = "receiptTypical";

const USAGE = `usage: email-workspace-send-smoke TO-SET [--to-account NAME] [--sender NAME]
                            [--story NAME | --mime FILE] [--verify-sent]
                            [--dir DIR] [--endpoints FILE] [--ca FILE]

Sends one story (default ${DEFAULT_STORY}, rendered by the story driver
build/capture/build-stories; \`just email-shots-build\` builds it) from
the Workspace sender to the QA account of TO-SET (its first account
file, or --to-account NAME for TO-SET/NAME.json) through the Gmail API,
and prints the API message id, the Message-ID and the timings. Arrival
is checked in the webmail, not here. Sets: ${Object.keys(HOSTED_PROFILES).join(", ")}.

The sender is the credentials directory's workspace-sender/*.json (the
first, or --sender NAME). The credentials directory is
$ISONIM_EMAIL_CREDENTIALS_DIR, defaulting to
\${XDG_CONFIG_HOME:-$HOME/.config}/metacraft/dev-credentials/isonim-email;
--dir overrides both.

Operator override (a one-off live check before a dedicated sender
exists; never the default): ${OVERRIDE_ENV.key} names a
service-account key file, ${OVERRIDE_ENV.subject} the user to act
as and ${OVERRIDE_ENV.from} the sender address. It sends only to
the QA accounts of the credentials directory.

--mime FILE       send this message instead of a story
--verify-sent     read the sender's Sent copy back (gmail.metadata, which
                  a dedicated sender is not granted) and check its
                  Message-ID and From
--endpoints FILE  JSON {"tokenUrl": …, "gmailBase": …} replacing Google's
                  (local test servers)
--ca FILE         PEM roots to verify them with instead of the system's

Exit status: 0 sent (and verified, with --verify-sent); 1 failed;
2 usage; 3 pending (no sender, or no account file for TO-SET).
`;

function storyMime(story: string): Uint8Array {
  const driver = join(repoRoot, "build", "capture", "build-stories");
  const out = mkdtempSync(join(tmpdir(), "workspace-send-smoke-"));
  try {
    const r = spawnSync(driver, [out, story], {
      cwd: repoRoot,
      encoding: "utf8",
      // The reference emails are registered with the layout stories.
      env: { ...process.env, ISONIM_CAPTURE_LAYOUT: "1" },
    });
    if (r.error !== undefined)
      throw new Error(
        `cannot run the story driver ${driver} (run \`just email-shots-build\` first)`,
      );
    if (r.status !== 0)
      throw new Error(
        `the story driver failed for ${story}: ${(r.stderr ?? "").trim().slice(0, 300)}`,
      );
    return new Uint8Array(readFileSync(join(out, `${story}.eml`)));
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
}

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
    process.stdout.write(USAGE);
    return args.length === 0 ? 2 : 0;
  }
  let toSet: string | undefined;
  let toAccount: string | undefined;
  let senderName: string | undefined;
  let story: string | undefined;
  let mimeFile: string | undefined;
  let verify = false;
  let dir: string | null = null;
  let endpointsFile: string | null = null;
  let ca: string | null = null;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    const value = (): string => {
      const v = args[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === "--to-account") toAccount = value();
    else if (a === "--sender") senderName = value();
    else if (a === "--story") story = value();
    else if (a === "--mime") mimeFile = resolve(value());
    else if (a === "--verify-sent") verify = true;
    else if (a === "--dir") dir = resolve(value());
    else if (a === "--endpoints") endpointsFile = resolve(value());
    else if (a === "--ca") ca = resolve(value());
    else if (a.startsWith("-")) {
      process.stderr.write(
        `email-workspace-send-smoke: unknown option ${a}\n${USAGE}`,
      );
      return 2;
    } else if (toSet === undefined) toSet = a;
    else {
      process.stderr.write(
        `email-workspace-send-smoke: one TO-SET only\n${USAGE}`,
      );
      return 2;
    }
  }
  if (
    toSet === undefined ||
    !(toSet in HOSTED_PROFILES) ||
    (story !== undefined && mimeFile !== undefined)
  ) {
    process.stderr.write(
      `email-workspace-send-smoke: unknown set, or both --story and --mime\n${USAGE}`,
    );
    return 2;
  }
  const base = currentHost();
  const host: HostEnv =
    dir === null
      ? base
      : { ...base, env: { ...base.env, ISONIM_EMAIL_CREDENTIALS_DIR: dir } };
  const endpoints =
    endpointsFile === null
      ? undefined
      : (JSON.parse(readFileSync(endpointsFile, "utf8")) as WorkspaceEndpoints);
  const trust = ca === null ? undefined : { ca: readFileSync(ca, "utf8") };

  let sender: WorkspaceSender;
  let receiver;
  try {
    const over = overrideSender(host);
    if (over !== null) {
      process.stdout.write(
        `OPERATOR OVERRIDE: sending with the key file named by ${OVERRIDE_ENV.key}, not the credentials directory's workspace-sender; recipients limited to the directory's QA accounts\n`,
      );
      sender = over;
    } else sender = loadWorkspaceSender(host, { account: senderName });
    receiver = loadHostedAccount(toSet, host, {
      account: toAccount,
      needsAppPassword: false,
    });
  } catch (err) {
    if (err instanceof CredentialsUnavailable) {
      process.stdout.write(
        `PENDING: ${err.message}\nNothing was sent and no server was contacted.\n`,
      );
      return 3;
    }
    throw err;
  }

  const name = mimeFile === undefined ? (story ?? DEFAULT_STORY) : mimeFile;
  const mime =
    mimeFile === undefined
      ? storyMime(story ?? DEFAULT_STORY)
      : new Uint8Array(readFileSync(mimeFile));
  process.stdout.write(
    `workspace send: ${sender.source} -> ${receiver.file} (${receiver.profile.label}), ${mimeFile === undefined ? `story ${name}` : "a given message"}\n`,
  );
  const opts = {
    run: `smoke-${Date.now().toString(36)}`,
    endpoints,
    trust,
  };
  const d = await deliverWorkspace(mime, sender, receiver, opts);
  process.stdout.write(`  api id ${d.api.id}\n`);
  process.stdout.write(`  Message-ID ${d.messageId}\n`);
  process.stdout.write(`  subject token ${d.subjectToken}\n`);
  process.stdout.write(
    `  sent ${d.bytes} bytes (sha256 ${d.submittedSha256}) in ${Math.round(d.timingMs.send)} ms\n`,
  );
  process.stdout.write(`  arrival: ${d.arrival.state}: ${d.arrival.reason}\n`);
  if (!verify) return 0;
  const copy = await readSentCopy(sender, d.api.id, opts);
  const fromAddr = /<([^<>]+)>\s*$/.exec(copy.from ?? "")?.[1] ?? copy.from;
  const idOk = copy.messageId === d.messageId;
  const fromOk = (fromAddr ?? "").toLowerCase() === sender.from.toLowerCase();
  process.stdout.write(
    `  sent copy: labels ${copy.labelIds.join(",") || "(none)"}; Message-ID ${idOk ? "as sent" : `DIFFERS (${copy.messageId ?? "absent"})`}; From ${fromOk ? "the sender address" : "NOT the sender address"}\n`,
  );
  return idOk && fromOk ? 0 : 1;
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err: unknown) => {
    // Errors from the endpoints are redacted where they are raised.
    process.stderr.write(
      `email-workspace-send-smoke: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    process.exitCode = 1;
  },
);
