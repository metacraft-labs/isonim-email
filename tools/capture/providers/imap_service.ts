// tools/capture/providers/imap_service.ts — the `imap` shared service:
// Dovecot, run as the current user, holding the one-message mailboxes
// real mail clients open.
//
// The harness starts it once per run for the providers that declare
// it. It runs `dovecot -F` from the dev shell as a child of the run,
// with a config written here:
// - listening on 127.0.0.1 only, plain IMAP (loopback, and only for the
//   life of the run);
// - the current user as Dovecot's internal, login and mail user, login
//   processes not chrooted, so no root and no system service is needed;
// - passwd-file authentication (one file per user) with users and
//   random passwords generated per run (never fixed, never from the credentials
//   directory);
// - every piece of state (config, passwd-file, mail store, state_dir,
//   log) under build/email-shots/.mail/<run>/, removed at teardown.
// Dovecot's unix sockets live apart, in a short-named runtime directory
// (also removed at teardown): a socket path is limited to 108 bytes,
// a path under the checkout overflows it, and Dovecot resolves a
// symlinked base_dir before connecting, so a short link does not help.
// That directory is a private (0700) mkdtemp directory under
// $XDG_RUNTIME_DIR or /tmp, and base_dir is its subdirectory d/:
// Dovecot chmods base_dir to 0755 and creates some sockets 0666, so the
// private parent is what keeps other local users out.
//
// Nothing outlives the run, however it ends:
// - on Linux Dovecot is started under `setpriv --pdeathsig KILL`, so it
//   dies with the process that started it even on SIGKILL (its own
//   children exit when the master goes);
// - both directories carry an owner.json (the owning process's pid and
//   start time, and Dovecot's once spawned), and every start first
//   sweeps the entries whose owner is no longer running: their Dovecot
//   is killed if still alive and both directories are removed. An
//   entry whose owner is alive, or that has no owner.json, is never
//   touched.
// SIGINT/SIGTERM are handled by the run (services.ts
// installSignalTeardown), which stops the services before exiting.
//
// Each capture gets a fresh user whose INBOX holds exactly one message,
// injected with `doveadm save`; with the assets service, the injected
// copy has the story asset origin rewritten to it (mime_rewrite.ts),
// under a token fresh for each delivery (assets_service.ts).

import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { createConnection, createServer, type AddressInfo } from "node:net";
import { userInfo } from "node:os";
import { dirname, join, resolve } from "node:path";
import { rewriteAssetOrigin } from "./mime_rewrite.ts";
import { captureToken, tokenPrefix } from "./assets_service.ts";
import {
  type OwnerRecord,
  processAlive,
  removeRunDirSync,
  sweepDeadOwners,
  thisProcess,
  writeOwner,
} from "./owned_state.ts";
import { currentHost, findExecutable } from "./requirements.ts";
import type { LocalService, ServiceRunInfo } from "./services.ts";
import type {
  AssetsHandle,
  Delivery,
  ImapAccount,
  ImapHandle,
  ServiceHandle,
} from "./types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
// Where each run's mail state lives: <stateRoot>/<run>/.
export const MAIL_STATE_ROOT = join(repoRoot, "build", "email-shots", ".mail");

const START_TIMEOUT_MS = 15000;
// The longest socket path Dovecot creates below base_dir
// ("token-login/imap-urlauth" and friends) plus slack.
const SOCKET_NAME_ROOM = 40;
const SUN_PATH_MAX = 107;

export function imapHandle(h: ServiceHandle | undefined): ImapHandle {
  if (
    h === undefined ||
    h.name !== "imap" ||
    typeof (h as Partial<ImapHandle>).createAccount !== "function"
  )
    throw new Error("the imap service is not running for this provider");
  return h as ImapHandle;
}

// What a start measured, recorded in the handle's detail.
export interface ImapStartTiming {
  configMs: number;
  listenMs: number;
}

function sha256(b: Uint8Array): string {
  return createHash("sha256").update(b).digest("hex");
}

function freePort(): Promise<number> {
  return new Promise((ok, fail) => {
    const s = createServer();
    s.once("error", fail);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address() as AddressInfo;
      s.close(() => ok(port));
    });
  });
}

// Resolves once a connection to host:port gets an IMAP greeting.
function greeting(host: string, port: number): Promise<boolean> {
  return new Promise((ok) => {
    const c = createConnection({ host, port });
    let buf = "";
    const done = (v: boolean): void => {
      c.destroy();
      ok(v);
    };
    c.setTimeout(1000, () => done(false));
    c.on("data", (d) => {
      buf += d.toString("latin1");
      if (buf.includes("\r\n")) done(buf.startsWith("* OK"));
    });
    c.on("error", () => done(false));
  });
}

// Where the socket directories may go: $XDG_RUNTIME_DIR, else /tmp.
export function socketBases(env: Record<string, string | undefined>): string[] {
  const out: string[] = [];
  for (const base of [env.XDG_RUNTIME_DIR, "/tmp"])
    if (base !== undefined && base !== "" && !out.includes(base))
      out.push(base);
  return out;
}

const SOCKET_PREFIX = "ie-imap-";

// A private (0700) directory with a short name for Dovecot's sockets.
// base_dir is its subdirectory d/ (see the file header).
function runtimeDir(env: Record<string, string | undefined>): string {
  for (const base of socketBases(env)) {
    if (!existsSync(base)) continue;
    if (
      base.length + `/${SOCKET_PREFIX}XXXXXX/d/`.length + SOCKET_NAME_ROOM >
      SUN_PATH_MAX
    )
      continue;
    const dir = mkdtempSync(join(base, SOCKET_PREFIX));
    chmodSync(dir, 0o700);
    return dir;
  }
  throw new Error(
    "no directory short enough for Dovecot's unix sockets ($XDG_RUNTIME_DIR and /tmp both too long or missing)",
  );
}

// --- Ownership and the sweep of dead runs' state (owned_state.ts). ---

export { processAlive };

// Removes the state of every run whose owning process is gone: kills
// its Dovecot if that still runs, and removes its state and socket
// directories. Returns the directories removed. Never touches an entry
// whose owner is alive or that has no owner.json, nor a directory the
// record names that is not a real directory directly inside the state
// root (state) or a socket base with the socket prefix (sockets), or
// whose own owner.json does not name the same dead owner and run.
export function sweepDeadRuns(
  stateRoot: string,
  bases: string[],
): Promise<string[]> {
  return sweepDeadOwners(stateRoot, bases, SOCKET_PREFIX);
}

export interface DovecotServiceOptions {
  // Parent of each run's state directory (default MAIL_STATE_ROOT).
  stateRoot?: string;
  env?: Record<string, string | undefined>;
  // Start Dovecot under a parent-death signal (Linux; default true).
  // Off only in the test that shows what the signal prevents.
  parentDeathSignal?: boolean;
}

export class DovecotService implements LocalService {
  private child: ChildProcess | null = null;
  private exited: Promise<void> | null = null;
  private stateDir: string | null = null;
  private socketDir: string | null = null;
  // user -> password; also the handle's (live) credentials.
  private readonly users: Record<string, string> = {};
  private passwdDir = "";
  private configPath = "";
  private doveadm = "";
  private seq = 0;
  private readonly stateRoot: string;
  private readonly env: Record<string, string | undefined>;
  private readonly parentDeathSignal: boolean;
  private stopping = false;
  private swept: string[] = [];
  // process.exit() runs no async teardown: kill and remove synchronously.
  private readonly onExit = (): void => {
    this.child?.kill("SIGKILL");
    for (const d of [this.stateDir, this.socketDir])
      if (d !== null) removeRunDirSync(d);
  };

  constructor(opts: DovecotServiceOptions = {}) {
    this.stateRoot = opts.stateRoot ?? MAIL_STATE_ROOT;
    this.env = opts.env ?? process.env;
    this.parentDeathSignal = opts.parentDeathSignal ?? true;
  }

  // A failed start leaves nothing behind: no process, no directory.
  async start(info: ServiceRunInfo): Promise<ImapHandle> {
    try {
      return await this.startDovecot(info);
    } catch (err) {
      await this.stop();
      throw err;
    }
  }

  private async startDovecot(info: ServiceRunInfo): Promise<ImapHandle> {
    const host = { ...currentHost(), env: this.env };
    const dovecot = findExecutable("dovecot", host);
    const doveadm = findExecutable("doveadm", host);
    if (dovecot === null || doveadm === null)
      throw new Error(
        "dovecot/doveadm not on PATH (run inside the isonim-email dev shell)",
      );
    // On Linux, Dovecot must die with this process even on SIGKILL.
    let setpriv: string | null = null;
    if (process.platform === "linux" && this.parentDeathSignal) {
      setpriv = findExecutable("setpriv", host);
      if (setpriv === null)
        throw new Error(
          "setpriv (util-linux) not on PATH: Dovecot is started under a parent-death signal (run inside the isonim-email dev shell)",
        );
    }
    this.doveadm = doveadm;
    const t0 = performance.now();
    const ver = spawnSync(dovecot, ["--version"], { encoding: "utf8" });
    const version = /^(\d+\.\d+\.\d+)/.exec(ver.stdout ?? "")?.[1];
    if (version === undefined || !/^2\.(?:[4-9]|\d\d)\./.test(version))
      throw new Error(
        `dovecot ${(ver.stdout ?? "").trim() || "(no version)"}: 2.4 or later is needed (the config uses 2.4 syntax)`,
      );

    // What dead runs left behind goes first.
    this.swept = await sweepDeadRuns(this.stateRoot, socketBases(this.env));
    const stateDir = join(this.stateRoot, info.run);
    if (existsSync(stateDir))
      throw new Error(
        `${stateDir} exists and does not belong to a dead run (a live run of the same id?)`,
      );
    mkdirSync(this.stateRoot, { recursive: true });
    mkdirSync(stateDir, { mode: 0o700 });
    this.stateDir = stateDir;
    this.socketDir = runtimeDir(this.env);
    const owner: OwnerRecord = {
      owner: thisProcess(process.pid),
      run: info.run,
      stateDir,
      socketDir: this.socketDir,
      dovecot: null,
    };
    writeOwner(owner);
    process.once("exit", this.onExit);
    const baseDir = join(this.socketDir, "d");
    mkdirSync(baseDir, { mode: 0o700 });
    mkdirSync(join(stateDir, "mail"), { mode: 0o700 });
    mkdirSync(join(stateDir, "state"), { mode: 0o700 });
    this.passwdDir = join(stateDir, "passwd.d");
    mkdirSync(this.passwdDir, { mode: 0o700 });
    this.configPath = join(stateDir, "dovecot.conf");
    const me = userInfo();
    // Dovecot wants the group by name; os.userInfo() has only its id.
    const group = spawnSync("id", ["-gn"], { encoding: "utf8" }).stdout?.trim();
    if (group === undefined || group === "")
      throw new Error("cannot learn the current group name (id -gn)");
    const configMs = performance.now() - t0;

    // The port is chosen free, then handed to Dovecot; another process
    // may take it in between, so a failed start is retried on a new one.
    let lastErr = "";
    for (let attempt = 0; attempt < 3; attempt++) {
      const port = await freePort();
      writeFileSync(
        this.configPath,
        dovecotConfig({
          version,
          baseDir,
          stateDir,
          user: me.username,
          group,
          uid: me.uid,
          gid: me.gid,
          port,
          passwdDir: this.passwdDir,
        }),
        { mode: 0o600 },
      );
      if (this.stopping) throw new Error("stopped while starting");
      const t1 = performance.now();
      const argv = ["-F", "-c", this.configPath];
      // setpriv execs Dovecot in place: the child's pid is Dovecot's.
      const child =
        setpriv === null
          ? spawn(dovecot, argv, {
              stdio: ["ignore", "pipe", "pipe"],
              env: { PATH: this.env.PATH ?? "" },
            })
          : spawn(setpriv, ["--pdeathsig", "KILL", "--", dovecot, ...argv], {
              stdio: ["ignore", "pipe", "pipe"],
              env: { PATH: this.env.PATH ?? "" },
            });
      if (child.pid !== undefined)
        writeOwner({ ...owner, dovecot: thisProcess(child.pid) });
      let stderr = "";
      child.stderr?.on("data", (d: Buffer) => {
        stderr += d.toString();
      });
      child.stdout?.resume();
      let dead = false;
      const exited = new Promise<void>((ok) =>
        child.once("exit", () => {
          dead = true;
          ok();
        }),
      );
      this.child = child;
      this.exited = exited;
      while (
        !dead &&
        !this.stopping &&
        performance.now() - t1 < START_TIMEOUT_MS
      ) {
        if (await greeting("127.0.0.1", port)) {
          const listenMs = performance.now() - t1;
          return this.handle(port, version, { configMs, listenMs });
        }
        await new Promise((r) => setTimeout(r, 20));
      }
      const log = existsSync(join(stateDir, "dovecot.log"))
        ? readFileSync(join(stateDir, "dovecot.log"), "utf8")
        : "";
      lastErr = (stderr + log).trim().split("\n").slice(-3).join(" | ");
      await this.killChild();
      if (!dead && lastErr === "") lastErr = "no IMAP greeting within 15 s";
    }
    throw new Error(`dovecot did not start: ${lastErr}`);
  }

  private handle(
    port: number,
    version: string,
    timing: ImapStartTiming,
  ): ImapHandle {
    const host = "127.0.0.1";
    const createAccount = async (): Promise<ImapAccount> => {
      this.seq += 1;
      const user = `c${this.seq}-${randomBytes(4).toString("hex")}`;
      const password = randomBytes(18).toString("base64url");
      // One passwd-file per user, written before the user is handed
      // out and renamed into place (Dovecot never sees half a file). A
      // single shared file would not do: Dovecot re-reads a changed
      // passwd-file only when its mtime moves to another second, so a
      // user added within the same second stays unknown.
      const tmp = join(this.passwdDir, `.${user}.tmp`);
      writeFileSync(tmp, `${user}:{PLAIN}${password}::::::\n`, {
        mode: 0o600,
      });
      renameSync(tmp, join(this.passwdDir, user));
      this.users[user] = password;
      const account = {
        user,
        host,
        port,
        tls: "none",
        mailbox: "INBOX",
      } as ImapAccount;
      // Readable as account.password, but never carried by a spread or
      // JSON.stringify of the account or of a Delivery holding it.
      Object.defineProperty(account, "password", {
        value: password,
        enumerable: false,
      });
      return account;
    };
    const deliver = async (
      account: ImapAccount,
      mime: Uint8Array,
      opts: { assets?: AssetsHandle } = {},
    ): Promise<Delivery> => {
      if (this.users[account.user] !== account.password)
        throw new Error(`no account ${account.user} on this imap service`);
      let bytes = mime;
      let assetRewrite: Delivery["assetRewrite"] = null;
      if (opts.assets !== undefined) {
        // A token fresh for this delivery, so the assets service can
        // tell this copy's image requests from every other's.
        const token = captureToken();
        const from = opts.assets.rewriteFrom;
        const to = `${opts.assets.baseUrl}${tokenPrefix(token)}`;
        const r = rewriteAssetOrigin(mime, from, to);
        bytes = r.bytes;
        assetRewrite = { from, to, token, count: r.count };
      }
      const t0 = performance.now();
      const r = spawnSync(
        this.doveadm,
        ["-c", this.configPath, "save", "-u", account.user, "-m", "INBOX"],
        { input: bytes, encoding: "utf8", env: { PATH: this.env.PATH ?? "" } },
      );
      if (r.status !== 0)
        throw new Error(
          `doveadm save for ${account.user} failed (exit ${r.status ?? r.signal}): ${(r.stderr ?? "").trim()}`,
        );
      return {
        account,
        injectedSha256: sha256(bytes),
        bytes: bytes.byteLength,
        assetRewrite,
        timingMs: { account: 0, inject: performance.now() - t0 },
      };
    };
    return {
      name: "imap",
      endpoint: `imap://${host}:${port}`,
      // The users created so far, by name (a live view).
      credentials: this.users,
      detail: {
        server: `dovecot ${version}`,
        stateDir: this.stateDir,
        socketDir: this.socketDir,
        pid: this.child?.pid ?? null,
        // Directories of dead runs removed before this start.
        swept: this.swept,
        startMs: timing,
      },
      host,
      port,
      tls: "none",
      createAccount,
      deliver,
      mailboxFor: async (mime, opts) => {
        const t0 = performance.now();
        const account = await createAccount();
        const accountMs = performance.now() - t0;
        const d = await deliver(account, mime, opts);
        return { ...d, timingMs: { ...d.timingMs, account: accountMs } };
      },
    };
  }

  private async killChild(): Promise<void> {
    const child = this.child;
    const exited = this.exited;
    this.child = null;
    this.exited = null;
    if (child === null || exited === null) return;
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
      const t = setTimeout(() => child.kill("SIGKILL"), 5000);
      await exited;
      clearTimeout(t);
    }
  }

  async stop(): Promise<void> {
    this.stopping = true;
    await this.killChild();
    for (const d of [this.stateDir, this.socketDir])
      if (d !== null) removeRunDirSync(d);
    this.stateDir = null;
    this.socketDir = null;
    process.off("exit", this.onExit);
    for (const u of Object.keys(this.users)) delete this.users[u];
  }
}

interface ConfigInput {
  version: string;
  baseDir: string;
  stateDir: string;
  user: string;
  group: string;
  uid: number;
  gid: number;
  port: number;
  passwdDir: string;
}

export function dovecotConfig(c: ConfigInput): string {
  return `# Generated for one capture run; removed at teardown.
dovecot_config_version = ${c.version}
dovecot_storage_version = ${c.version}
base_dir = ${c.baseDir}
state_dir = ${c.stateDir}/state
log_path = ${c.stateDir}/dovecot.log
default_internal_user = ${c.user}
default_internal_group = ${c.group}
default_login_user = ${c.user}
first_valid_uid = ${c.uid}
last_valid_uid = ${c.uid}
protocols = imap
listen = 127.0.0.1
ssl = no
auth_allow_cleartext = yes
auth_mechanisms = plain login
# A refused login answers at once: the server is loopback-only and
# per-run, and a misconfigured client should fail fast.
auth_failure_delay = 0
mail_driver = maildir
mail_home = ${c.stateDir}/mail/%{user}
mail_path = ~/Maildir
mail_uid = ${c.uid}
mail_gid = ${c.gid}
passdb passwd-file {
  passwd_file_path = ${c.passwdDir}/%{user}
}
userdb passwd-file {
  passwd_file_path = ${c.passwdDir}/%{user}
}
service imap-login {
  chroot =
  inet_listener imap {
    listen = 127.0.0.1
    port = ${c.port}
  }
  inet_listener imaps {
    port = 0
  }
}
`;
}
