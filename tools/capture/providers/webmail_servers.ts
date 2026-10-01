// tools/capture/providers/webmail_servers.ts — Roundcube and SnappyMail
// on php-fpm behind caddy, run as the current user on loopback, for the
// selfhosted-webmail capture provider.
//
// Everything is generated per start:
// - Roundcube's config directory (config.inc.php, with Roundcube's own
//   defaults.inc.php and mimetypes.php linked beside it; Roundcube reads
//   its defaults from the config directory it is pointed at), its
//   SQLite database (created by Roundcube on first use), logs and temp;
// - two SnappyMail instances, one per colour scheme, each a document
//   root holding an index.php that names its own data folder (the
//   packaged one is fixed to /var/lib) and a link to the packaged code,
//   and a data folder with the application.ini and the IMAP domain
//   written here. SnappyMail has no automatic dark mode: its dark
//   scheme is a dark theme, and the theme is per instance;
// - a php-fpm config with one pool per webmail, listening on unix
//   sockets in a private (0700) short-named directory, and a Caddyfile
//   with one loopback site per webmail instance (admin API off, no
//   automatic HTTPS).
// Both webmails log in to the run's Dovecot (the imap service). PHP's
// outbound HTTP goes through the assets service's egress guard
// (http_proxy/https_proxy in each pool), so a server-side image fetch
// can reach the asset paths and nothing else; SnappyMail's image proxy
// is off (images load in the browser, from the assets service).
//
// Nothing outlives the run (the same discipline as the imap service):
// - caddy runs under `setpriv --pdeathsig KILL`; php-fpm runs under
//   `setpriv --pdeathsig KILL -- unshare --user --map-current-user
//   --pid --fork --kill-child`: its workers are forked by the master
//   and outlive a killed master (measured), but in a PID namespace of
//   their own they are killed by the kernel when its first process
//   goes;
// - the state directory (build/email-shots/.webmail/<run>/) and the
//   socket directory carry owner.json records (owned_state.ts) naming
//   the run and the server processes, and every start sweeps what dead
//   runs left.

import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer, type AddressInfo } from "node:net";
import { dirname, join, resolve } from "node:path";
import { socketBases } from "./imap_service.ts";
import {
  type OwnerRecord,
  type ProcessId,
  removeRunDirSync,
  sweepDeadOwners,
  thisProcess,
  writeOwner,
} from "./owned_state.ts";
import { currentHost, findExecutable } from "./requirements.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
// Where each run's webmail state lives: <stateRoot>/<run>/.
export const WEBMAIL_STATE_ROOT = join(
  repoRoot,
  "build",
  "email-shots",
  ".webmail",
);
export const WEBMAIL_SOCKET_PREFIX = "ie-web-";
// The variables naming the packaged webmail trees (set by the dev shell).
export const ROUNDCUBE_ENV = "ISONIM_EMAIL_ROUNDCUBE";
export const SNAPPYMAIL_ENV = "ISONIM_EMAIL_SNAPPYMAIL";
// SnappyMail's theme per scheme. The light one is its default theme;
// the dark one is the packaged dark variant of the same family
// (color-scheme: dark), since SnappyMail does not follow the system
// colour scheme.
export const SNAPPYMAIL_THEMES = { light: "Default", dark: "NightShine" };
// The mail domain SnappyMail appends to a bare login; its domain file
// maps it to the run's Dovecot with short (domain-less) IMAP logins.
export const SNAPPYMAIL_DOMAIN = "capture.test";

const START_TIMEOUT_MS = 30000;

export interface WebmailVersions {
  roundcube: string;
  snappymail: string;
  php: string;
  caddy: string;
}

export interface WebmailEndpoints {
  // Origins ("http://127.0.0.1:<port>") of the three sites.
  roundcube: string;
  snappymail: { light: string; dark: string };
  versions: WebmailVersions;
  stateDir: string;
  socketDir: string;
  // Directories of dead runs removed before this start.
  swept: string[];
  timingMs: { config: number; listen: number };
  // The server processes: caddy, and php-fpm's namespace launcher.
  pids: { caddy: number | null; phpFpm: number | null };
}

export interface WebmailStartInfo {
  run: string;
  imap: { host: string; port: number };
  // The egress guard: the assets service's base URL, used as PHP's
  // HTTP and HTTPS proxy.
  proxy: string;
}

export interface WebmailServersOptions {
  stateRoot?: string;
  env?: Record<string, string | undefined>;
  // Start the servers under a parent-death signal (Linux; default
  // true). Off only in the test that shows what it prevents.
  parentDeathSignal?: boolean;
  // Turn SnappyMail's server-side image proxy on (default off, as the
  // provider runs it). Only the egress-guard test turns it on, to make
  // PHP fetch an image.
  snappymailImageProxy?: boolean;
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

// The packaged versions, read from the trees themselves.
export function roundcubeVersion(root: string): string {
  const src = readFileSync(join(root, "program/include/iniset.php"), "utf8");
  const v = /define\('RCMAIL_VERSION',\s*'([^']+)'\)/.exec(src)?.[1];
  if (v === undefined) throw new Error(`no RCMAIL_VERSION under ${root}`);
  return v;
}

export function snappymailVersion(root: string): string {
  const versions = readdirSync(join(root, "snappymail", "v"));
  if (versions.length !== 1 || versions[0] === undefined)
    throw new Error(
      `expected one SnappyMail version under ${root}/snappymail/v, found: ${versions.join(", ")}`,
    );
  return versions[0];
}

// PHP single-quoted string literal.
function phpString(s: string): string {
  return `'${s.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`;
}

function roundcubeConfig(c: {
  dir: string;
  imap: { host: string; port: number };
  desKey: string;
}): string {
  return `<?php
// Generated for one capture run; removed at teardown.
$config = [];
$config['db_dsnw'] = ${phpString(`sqlite:///${c.dir}/roundcube.db?mode=0600`)};
$config['imap_host'] = ${phpString(`${c.imap.host}:${c.imap.port}`)};
$config['smtp_host'] = '';
$config['des_key'] = ${phpString(c.desKey)};
$config['plugins'] = [];
$config['skin'] = 'elastic';
$config['log_dir'] = ${phpString(`${c.dir}/logs/`)};
$config['temp_dir'] = ${phpString(`${c.dir}/temp/`)};
$config['enable_installer'] = false;
// Remote images always shown: the story images load from the assets
// service, which is the point of the capture.
$config['show_images'] = 2;
$config['refresh_interval'] = 0;
$config['timezone'] = 'UTC';
$config['language'] = 'en_US';
$config['support_url'] = '';
`;
}

function snappymailIni(c: { theme: string; imageProxy: boolean }): string {
  return `; Generated for one capture run; removed at teardown.
[webmail]
theme = "${c.theme}"
allow_themes = Off
popup_identity = Off
message_read_delay = 0
[security]
allow_admin_panel = Off
[admin_panel]
allow_update = Off
[login]
default_domain = "${SNAPPYMAIL_DOMAIN}"
allow_languages_on_login = Off
determine_user_language = Off
sign_me_auto = "Unused"
fault_delay = 0
[plugins]
enable = Off
[defaults]
view_layout = 0
show_images = On
view_images = "always"
contacts_autosave = Off
fetch_new_messages = Off
[labs]
use_local_proxy_for_external_images = ${c.imageProxy ? "On" : "Off"}
`;
}

function snappymailDomain(
  template: string,
  imap: { host: string; port: number },
): string {
  const c = JSON.parse(readFileSync(template, "utf8")) as Record<
    string,
    Record<string, unknown>
  >;
  const i = c.IMAP;
  if (i === undefined) throw new Error(`${template} has no IMAP section`);
  Object.assign(i, {
    host: imap.host,
    port: imap.port,
    type: 0,
    shortLogin: true,
    sasl: ["PLAIN", "LOGIN"],
  });
  // No SMTP: captures never send.
  if (c.SMTP !== undefined)
    Object.assign(c.SMTP, { host: "127.0.0.1", port: 1 });
  return JSON.stringify(c, null, 1) + "\n";
}

function phpFpmConfig(c: {
  stateDir: string;
  socketDir: string;
  roundcubeConfigDir: string;
  proxy: string;
}): string {
  const pool = (name: string, extraEnv: string): string => `[${name}]
listen = ${c.socketDir}/${name}.sock
listen.mode = 0600
pm = static
pm.max_children = 3
clear_env = yes
env[TMPDIR] = ${c.stateDir}/tmp
env[http_proxy] = ${c.proxy}
env[https_proxy] = ${c.proxy}
env[HTTPS_PROXY] = ${c.proxy}
${extraEnv}php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = ${c.stateDir}/php-${name}.log
php_admin_value[session.save_path] = ${c.stateDir}/sessions
php_admin_value[upload_tmp_dir] = ${c.stateDir}/tmp
php_admin_value[sys_temp_dir] = ${c.stateDir}/tmp
php_admin_value[date.timezone] = UTC
catch_workers_output = yes
`;
  return `; Generated for one capture run; removed at teardown.
[global]
pid = ${c.stateDir}/php-fpm.pid
error_log = ${c.stateDir}/php-fpm.log
daemonize = no
${pool("rc", `env[ROUNDCUBE_CONFIG_DIR] = ${c.roundcubeConfigDir}\n`)}${pool("sm", "")}`;
}

function caddyfile(c: {
  stateDir: string;
  socketDir: string;
  roundcubeRoot: string;
  sites: { port: number; root: string; pool: string; snappymail: boolean }[];
}): string {
  const site = (
    s: (typeof c.sites)[number],
  ): string => `http://127.0.0.1:${s.port} {
  bind 127.0.0.1
  root * ${s.root}
${
  s.snappymail
    ? // SnappyMail's own .htaccess denies its code directories; caddy
      // reads no .htaccess, so the same paths are refused here.
      `  @private path /snappymail/v/*/app/* /data/*
  respond @private 403
`
    : ""
}  php_fastcgi unix/${c.socketDir}/${s.pool}.sock
  file_server
}
`;
  return `# Generated for one capture run; removed at teardown.
{
  admin off
  auto_https off
  persist_config off
  skip_install_trust
  storage file_system ${c.stateDir}/caddy
}
${c.sites.map(site).join("")}`;
}

export class WebmailServers {
  private caddy: ChildProcess | null = null;
  private phpFpm: ChildProcess | null = null;
  private stateDir: string | null = null;
  private socketDir: string | null = null;
  private stopping = false;
  private readonly stateRoot: string;
  private readonly env: Record<string, string | undefined>;
  private readonly parentDeathSignal: boolean;
  private readonly imageProxy: boolean;
  private readonly onExit = (): void => {
    this.caddy?.kill("SIGKILL");
    this.phpFpm?.kill("SIGKILL");
    for (const d of [this.stateDir, this.socketDir])
      if (d !== null) removeRunDirSync(d);
  };

  constructor(opts: WebmailServersOptions = {}) {
    this.stateRoot = opts.stateRoot ?? WEBMAIL_STATE_ROOT;
    this.env = opts.env ?? process.env;
    this.parentDeathSignal = opts.parentDeathSignal ?? true;
    this.imageProxy = opts.snappymailImageProxy ?? false;
  }

  // A failed start leaves nothing behind.
  async start(info: WebmailStartInfo): Promise<WebmailEndpoints> {
    try {
      return await this.startServers(info);
    } catch (err) {
      await this.stop();
      throw err;
    }
  }

  private async startServers(
    info: WebmailStartInfo,
  ): Promise<WebmailEndpoints> {
    const t0 = performance.now();
    const host = { ...currentHost(), env: this.env };
    const phpFpmBin = findExecutable("php-fpm", host);
    const caddyBin = findExecutable("caddy", host);
    if (phpFpmBin === null || caddyBin === null)
      throw new Error(
        "php-fpm/caddy not on PATH (run inside the isonim-email dev shell)",
      );
    let setpriv: string | null = null;
    let unshare: string | null = null;
    if (process.platform === "linux" && this.parentDeathSignal) {
      setpriv = findExecutable("setpriv", host);
      unshare = findExecutable("unshare", host);
      if (setpriv === null || unshare === null)
        throw new Error(
          "setpriv/unshare (util-linux) not on PATH: the webmail servers are started under a parent-death signal, php-fpm in a PID namespace of its own (run inside the isonim-email dev shell)",
        );
    }
    const rcRoot = this.env[ROUNDCUBE_ENV];
    const smRoot = this.env[SNAPPYMAIL_ENV];
    if (rcRoot === undefined || !existsSync(rcRoot))
      throw new Error(`$${ROUNDCUBE_ENV} does not name the Roundcube tree`);
    if (smRoot === undefined || !existsSync(smRoot))
      throw new Error(`$${SNAPPYMAIL_ENV} does not name the SnappyMail tree`);
    const versions: WebmailVersions = {
      roundcube: roundcubeVersion(rcRoot),
      snappymail: snappymailVersion(smRoot),
      php:
        /PHP (\S+)/.exec(
          spawnSync(phpFpmBin, ["--version"], { encoding: "utf8" }).stdout ??
            "",
        )?.[1] ?? "",
      caddy: (
        spawnSync(caddyBin, ["version"], { encoding: "utf8" }).stdout ?? ""
      )
        .trim()
        .split(/\s+/)[0]!,
    };
    if (versions.php === "" || versions.caddy === "")
      throw new Error(
        `cannot read the php-fpm or caddy version (php '${versions.php}', caddy '${versions.caddy}')`,
      );

    const swept = await sweepDeadOwners(
      this.stateRoot,
      socketBases(this.env),
      WEBMAIL_SOCKET_PREFIX,
    );
    const stateDir = join(this.stateRoot, info.run);
    if (existsSync(stateDir))
      throw new Error(
        `${stateDir} exists and does not belong to a dead run (a live run of the same id?)`,
      );
    mkdirSync(this.stateRoot, { recursive: true });
    mkdirSync(stateDir, { mode: 0o700 });
    this.stateDir = stateDir;
    this.socketDir = this.makeSocketDir();
    const owner: OwnerRecord = {
      owner: thisProcess(process.pid),
      run: info.run,
      stateDir,
      socketDir: this.socketDir,
      processes: [],
    };
    writeOwner(owner);
    process.once("exit", this.onExit);
    for (const d of ["tmp", "sessions", "caddy", "home"])
      mkdirSync(join(stateDir, d), { mode: 0o700 });

    // Roundcube.
    const rcDir = join(stateDir, "roundcube");
    const rcConfig = join(rcDir, "config");
    for (const d of [rcDir, rcConfig, join(rcDir, "logs"), join(rcDir, "temp")])
      mkdirSync(d, { mode: 0o700 });
    writeFileSync(
      join(rcConfig, "config.inc.php"),
      roundcubeConfig({
        dir: rcDir,
        imap: info.imap,
        desKey: randomBytes(18).toString("base64").slice(0, 24),
      }),
      { mode: 0o600 },
    );
    for (const f of ["defaults.inc.php", "mimetypes.php"])
      symlinkSync(join(rcRoot, "config", f), join(rcConfig, f));

    // SnappyMail: one instance per scheme.
    const smVersionDir = join(smRoot, "snappymail", "v", versions.snappymail);
    const smRoots: Record<"light" | "dark", string> = { light: "", dark: "" };
    for (const scheme of ["light", "dark"] as const) {
      const base = join(stateDir, `snappymail-${scheme}`);
      const root = join(base, "root");
      const data = join(base, "data");
      const priv = join(data, "_data_", "_default_");
      for (const d of [base, root, data]) mkdirSync(d, { mode: 0o700 });
      for (const d of ["configs", "domains", "plugins", "storage"])
        mkdirSync(join(priv, d), { recursive: true, mode: 0o700 });
      symlinkSync(join(smRoot, "snappymail"), join(root, "snappymail"));
      writeFileSync(
        join(root, "index.php"),
        `<?php
// Generated for one capture run: the packaged index.php fixes the data
// folder to /var/lib; this one names the run's.
define('APP_VERSION', ${phpString(versions.snappymail)});
define('APP_INDEX_ROOT_PATH', __DIR__ . DIRECTORY_SEPARATOR);
define('APP_DATA_FOLDER_PATH', ${phpString(data + "/")});
include ${phpString(join(smVersionDir, "include.php"))};
`,
      );
      // Installed already: SnappyMail's first-run setup would copy its
      // sample domains in; this run has exactly one.
      writeFileSync(join(data, "INSTALLED"), versions.snappymail);
      writeFileSync(join(priv, "domains", "disabled"), "");
      writeFileSync(
        join(priv, "domains", `${SNAPPYMAIL_DOMAIN}.json`),
        snappymailDomain(
          join(smVersionDir, "app", "domains", "default.json"),
          info.imap,
        ),
      );
      writeFileSync(
        join(priv, "configs", "application.ini"),
        snappymailIni({
          theme: SNAPPYMAIL_THEMES[scheme],
          imageProxy: this.imageProxy,
        }),
      );
      smRoots[scheme] = root;
    }

    writeFileSync(
      join(stateDir, "php-fpm.conf"),
      phpFpmConfig({
        stateDir,
        socketDir: this.socketDir,
        roundcubeConfigDir: rcConfig,
        proxy: info.proxy,
      }),
      { mode: 0o600 },
    );
    const configMs = performance.now() - t0;

    const baseEnv = {
      PATH: this.env.PATH ?? "",
      HOME: join(stateDir, "home"),
      XDG_DATA_HOME: join(stateDir, "home"),
      XDG_CONFIG_HOME: join(stateDir, "home"),
      TMPDIR: join(stateDir, "tmp"),
    };
    const t1 = performance.now();
    const fpmArgv = ["-F", "-y", join(stateDir, "php-fpm.conf")];
    this.phpFpm =
      setpriv === null || unshare === null
        ? this.spawnLogged(phpFpmBin, fpmArgv, baseEnv, "php-fpm.out")
        : this.spawnLogged(
            setpriv,
            [
              "--pdeathsig",
              "KILL",
              "--",
              unshare,
              "--user",
              "--map-current-user",
              "--pid",
              "--fork",
              "--kill-child",
              "--",
              phpFpmBin,
              ...fpmArgv,
            ],
            baseEnv,
            "php-fpm.out",
          );
    this.record(owner);

    // Ports are chosen free and handed to caddy; another process may
    // take one in between, so a failed start is retried on new ones.
    let lastErr = "";
    for (let attempt = 0; attempt < 3; attempt++) {
      const ports = [await freePort(), await freePort(), await freePort()];
      const [rcPort, smLight, smDark] = ports as [number, number, number];
      writeFileSync(
        join(stateDir, "Caddyfile"),
        caddyfile({
          stateDir,
          socketDir: this.socketDir,
          roundcubeRoot: rcRoot,
          sites: [
            {
              port: rcPort,
              root: join(rcRoot, "public_html"),
              pool: "rc",
              snappymail: false,
            },
            {
              port: smLight,
              root: smRoots.light,
              pool: "sm",
              snappymail: true,
            },
            { port: smDark, root: smRoots.dark, pool: "sm", snappymail: true },
          ],
        }),
        { mode: 0o600 },
      );
      if (this.stopping) throw new Error("stopped while starting");
      const caddyArgv = [
        "run",
        "--config",
        join(stateDir, "Caddyfile"),
        "--adapter",
        "caddyfile",
      ];
      this.caddy =
        setpriv === null
          ? this.spawnLogged(caddyBin, caddyArgv, baseEnv, "caddy.out")
          : this.spawnLogged(
              setpriv,
              ["--pdeathsig", "KILL", "--", caddyBin, ...caddyArgv],
              baseEnv,
              "caddy.out",
            );
      this.record(owner);
      const endpoints = {
        roundcube: `http://127.0.0.1:${rcPort}`,
        light: `http://127.0.0.1:${smLight}`,
        dark: `http://127.0.0.1:${smDark}`,
      };
      const up = await this.waitUp(Object.values(endpoints));
      if (up === null) {
        const listenMs = performance.now() - t1;
        return {
          roundcube: endpoints.roundcube,
          snappymail: { light: endpoints.light, dark: endpoints.dark },
          versions,
          stateDir,
          socketDir: this.socketDir,
          swept,
          timingMs: { config: configMs, listen: listenMs },
          pids: {
            caddy: this.caddy?.pid ?? null,
            phpFpm: this.phpFpm?.pid ?? null,
          },
        };
      }
      lastErr = up;
      await this.killChild("caddy");
      if (this.phpFpm === null || this.phpFpm.exitCode !== null) break;
    }
    throw new Error(`the webmail servers did not start: ${lastErr}`);
  }

  private makeSocketDir(): string {
    for (const base of socketBases(this.env)) {
      if (!existsSync(base)) continue;
      // php-fpm's sockets are <dir>/rc.sock and <dir>/sm.sock.
      if (base.length + `/${WEBMAIL_SOCKET_PREFIX}XXXXXX/rc.sock`.length > 100)
        continue;
      const dir = mkdtempSync(join(base, WEBMAIL_SOCKET_PREFIX));
      chmodSync(dir, 0o700);
      return dir;
    }
    throw new Error(
      "no directory short enough for php-fpm's unix sockets ($XDG_RUNTIME_DIR and /tmp both too long or missing)",
    );
  }

  private spawnLogged(
    cmd: string,
    argv: string[],
    env: Record<string, string>,
    log: string,
  ): ChildProcess {
    const child = spawn(cmd, argv, {
      stdio: ["ignore", "pipe", "pipe"],
      env,
    });
    const path = join(this.stateDir!, log);
    const append = (d: Buffer): void => {
      try {
        writeFileSync(path, d, { flag: "a" });
      } catch {
        // the state directory is gone (teardown)
      }
    };
    child.stdout?.on("data", append);
    child.stderr?.on("data", append);
    return child;
  }

  private record(owner: OwnerRecord): void {
    const processes: ProcessId[] = [];
    for (const c of [this.phpFpm, this.caddy])
      if (c?.pid !== undefined) processes.push(thisProcess(c.pid));
    writeOwner({ ...owner, processes });
  }

  // null once every origin answers 200 (which also has PHP initialise
  // each webmail: Roundcube creates its database on the first request);
  // otherwise why not.
  private async waitUp(origins: string[]): Promise<string | null> {
    const t0 = performance.now();
    const pending = new Set(origins);
    let last = "";
    while (pending.size > 0) {
      for (const c of [this.phpFpm, this.caddy])
        if (c === null || c.exitCode !== null || c.signalCode !== null)
          return `${c === this.phpFpm ? "php-fpm" : "caddy"} exited: ${this.logTail()}`;
      if (this.stopping) return "stopped while starting";
      if (performance.now() - t0 > START_TIMEOUT_MS)
        return `no 200 from ${[...pending].join(", ")} within ${START_TIMEOUT_MS / 1000} s (last: ${last}); ${this.logTail()}`;
      for (const o of [...pending]) {
        try {
          const res = await fetch(`${o}/`, {
            signal: AbortSignal.timeout(5000),
          });
          await res.arrayBuffer();
          if (res.status === 200) pending.delete(o);
          else last = `${o}: ${res.status}`;
        } catch (err) {
          last = `${o}: ${err instanceof Error ? err.message : String(err)}`;
        }
      }
      if (pending.size > 0) await new Promise((r) => setTimeout(r, 50));
    }
    return null;
  }

  private logTail(): string {
    const out: string[] = [];
    for (const f of ["php-fpm.out", "php-fpm.log", "caddy.out"]) {
      const p = join(this.stateDir ?? "", f);
      if (this.stateDir !== null && existsSync(p))
        out.push(
          `${f}: ${readFileSync(p, "utf8").trim().split("\n").slice(-3).join(" | ")}`,
        );
    }
    return out.join("; ");
  }

  private async killChild(which: "caddy" | "phpFpm"): Promise<void> {
    const child = this[which];
    this[which] = null;
    if (child === null) return;
    if (child.exitCode === null && child.signalCode === null) {
      const exited = new Promise<void>((ok) => child.once("exit", () => ok()));
      child.kill("SIGTERM");
      const t = setTimeout(() => child.kill("SIGKILL"), 5000);
      await exited;
      clearTimeout(t);
    }
  }

  async stop(): Promise<void> {
    this.stopping = true;
    await this.killChild("caddy");
    await this.killChild("phpFpm");
    for (const d of [this.stateDir, this.socketDir])
      if (d !== null) removeRunDirSync(d);
    this.stateDir = null;
    this.socketDir = null;
    process.off("exit", this.onExit);
  }
}
