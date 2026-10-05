// tools/capture/providers/desktop_session.ts — one headless Wayland
// desktop for one mail-client instance: sway with wlroots' headless
// backend and its software (pixman) renderer, so no GPU and no display
// is involved and every host renders the same pixels.
//
// What a session gives a client driver:
// - the output's mode and scale, set per request through `swaymsg`
//   (`output HEADLESS-1 mode <w*s>x<h*s> scale <s>`: a logical w×h
//   desktop at device-pixel ratio s);
// - the client's windows, from `swaymsg -t get_tree`, and fullscreening
//   one of them;
// - a capture of the whole output with `grim` at the output's scale,
//   cropped here in device pixels (grim's own -g takes logical
//   coordinates, which cannot address a device pixel at scale 3);
// - keyboard input through `wtype` (sway's virtual-keyboard protocol);
// - launching a client inside the session (`swaymsg exec` of a script
//   written here), so the client inherits the session's environment.
//
// Isolation. Every session has its own HOME, XDG_CONFIG_HOME,
// XDG_DATA_HOME, XDG_CACHE_HOME, XDG_STATE_HOME and XDG_RUNTIME_DIR, and
// a private D-Bus session bus (dbus-run-session with a configuration
// written here that listens in the session's runtime directory and
// activates no services); the system bus address points at nothing. The
// environment is built from scratch: TZ=UTC, LANG/LC_ALL en_US.UTF-8
// from the dev shell's locale archive, the dev shell's pinned
// FONTCONFIG_FILE, and PATH and XDG_DATA_DIRS reduced to their Nix
// store entries. Nothing is inherited from the caller's environment
// beyond those.
//
// Network. The session has a network namespace of its own whose only
// interface is loopback, so nothing a client does reaches the network,
// whatever it makes of its proxy settings. The host loopback ports the
// session's clients need (the imap and assets services) are bridged in
// over unix sockets in the runtime directory, on the same port numbers
// (netns_bridge.ts is the inside half, this file the outside half), and
// a client's own port inside (Thunderbird's Marionette) is reached from
// outside through the same bridge (connectInner).
//
// Host sockets. A network namespace separates abstract unix sockets but
// not filesystem ones, so the session also has a mount namespace of its
// own, in which the host directories that hold filesystem sockets are
// covered by empty tmpfs mounts (coveredDirs(): /run, a separate
// /var/run, /tmp, /var/tmp, the caller's home directory, and
// the Nix daemon's socket directories). That hides, among others, the host's
// journal (/run/systemd/journal), its system bus (/run/dbus), systemd's
// private sockets, nscd, the caller's own user runtime directory
// (/run/user/<uid>: the host session bus, ssh and gpg agents), tmux and
// other sockets under /tmp, ssh-agent sockets under the home directory
// and the Nix daemon; the session's POSIX shared memory (/dev/shm) is
// its own too (see Host devices). Bound back on top, and nothing else: the
// session's own runtime and state directories, the directory of the
// bridge's inside half, and /run/opengl-driver (a Nix store path the
// graphics libraries look in). The rest of the host filesystem stays
// visible.
// One host socket is reached before the covering: the setup shell
// (bash) looks its own uid up through the host's nscd as it starts,
// before its first line runs; nothing started after the covering, and
// so no client, reaches it.
//
// Host devices. The same mount namespace replaces /dev, before any
// other covering, by an empty tmpfs holding only the pseudo-devices
// (SESSION_DEVICES, bound from the host's), a devpts instance of its
// own, an empty /dev/shm, and the fd/stdin/stdout/stderr links. No GPU,
// DRM render node, input, sound or other host device is visible, so the
// clients render in software, as the compositor does. Measured before:
// every client and helper opened the host's GPU device nodes through the
// vendor libraries in /run/opengl-driver, and a killed client's exit then
// waited in the GPU driver's close path for a lock the driver holds for
// the whole host; with two runs at once it waited there, blocked, for
// longer than stopLaunched() waits for a teardown that does not move.
// The GPU is a host resource every concurrent run would share; a
// session holds no host device that another run contends for.
//
// Name resolution. With /run covered, the host's nscd cannot resolve
// names for the session (which would be a real DNS query by the host);
// /etc/hosts holds localhost only and /etc/resolv.conf names no
// nameserver.
//
// A session can run a command to completion inside it (runInside) and
// end what it launched (stopLaunched), for the drivers of clients that
// restart per capture and for the tests.
//
// Nothing outlives the run (the discipline of the imap service and the
// webmail servers):
// - the session runs as `setpriv --pdeathsig KILL -- unshare --user
//   --map-root-user --net --mount --pid --fork --kill-child`, which sets
//   up name resolution, brings loopback up and then, in a nested user
//   namespace that maps the caller's uid and gid back (everything runs
//   as the caller), runs
//   `dbus-run-session -- sway` and the bridge: sway, the bus, the
//   bridge and every client launched in the session live in a PID
//   namespace of their own, so when the namespace's first process goes
//   (because the run, its parent, went) the kernel kills all of them, a
//   client's helper processes included;
// - the state directory (build/email-shots/.desktop/<run>-<instance>/)
//   and the runtime directory (a short-named private ie-desk-XXXXXX
//   under $XDG_RUNTIME_DIR or /tmp: Wayland and D-Bus sockets live
//   there, and a socket path is limited to 108 bytes) carry owner.json
//   records (owned_state.ts), and every start sweeps what dead runs
//   left.

import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { userInfo } from "node:os";
import {
  createConnection,
  createServer,
  type Server,
  type Socket,
} from "node:net";
import { delimiter, dirname, join, resolve } from "node:path";
import { readPng, type RgbaImage, writePng } from "../contact_sheet.ts";
import { socketBases } from "./imap_service.ts";
import {
  type OwnerRecord,
  processAlive,
  removeRunDirSync,
  sweepDeadOwners,
  thisProcess,
  writeOwner,
} from "./owned_state.ts";
import { currentHost, findExecutable } from "./requirements.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
// Where each session's state lives: <stateRoot>/<run>-<instance>/.
export const DESKTOP_STATE_ROOT = join(
  repoRoot,
  "build",
  "email-shots",
  ".desktop",
);
export const DESKTOP_SOCKET_PREFIX = "ie-desk-";
// The inside half of the session's network bridge.
const BRIDGE_SCRIPT = join(scriptDir, "netns_bridge.ts");
// The dev shell's glibc locale directory (holds locale-archive).
export const LOCALES_ENV = "ISONIM_EMAIL_LOCALES";
// The one output wlroots' headless backend creates.
export const HEADLESS_OUTPUT = "HEADLESS-1";
// The binaries a session runs (setpriv/unshare too, on Linux).
export const SESSION_BINARIES = [
  "sway",
  "swaymsg",
  "grim",
  "wtype",
  "dbus-run-session",
  "ip",
  "mount",
  "umount",
  "ln",
] as const;
// The host devices a session sees: the pseudo-devices only, each bound
// from the host's /dev into the session's own (devScript()).
export const SESSION_DEVICES = [
  "null",
  "zero",
  "full",
  "random",
  "urandom",
  "tty",
] as const;
// Everything in a session's /dev: the devices above, its own devpts
// (pts, and ptmx linking into it), its own POSIX shared memory (shm),
// and the links to the calling process's descriptors.
export const SESSION_DEV_ENTRIES = [
  ...SESSION_DEVICES,
  "pts",
  "ptmx",
  "shm",
  "fd",
  "stdin",
  "stdout",
  "stderr",
] as const;
// The host directories covered by an empty tmpfs inside a session,
// with the tmpfs mode: each that exists as a directory of its own (not
// a symlink to another), outermost first, none inside another. The
// caller's home directory is added by coveredDirs().
export const COVERED_DIRS: readonly (readonly [string, string])[] = [
  ["/run", "0755"],
  ["/var/run", "0755"],
  ["/tmp", "1777"],
  ["/var/tmp", "1777"],
  ["/nix/var/nix/daemon-socket", "0755"],
  ["/nix/var/nix/gc-socket", "0755"],
];
// Links under a covered directory that point into the Nix store and
// are re-exposed (bound from their target) inside a session.
export const REEXPOSED_STORE_LINKS = ["/run/opengl-driver"] as const;
// Programs some client helpers run by a fixed NixOS system path under
// /run (nixpkgs builds at-spi-bus-launcher to spawn
// /run/current-system/sw/bin/dbus-daemon): inside a session that
// directory holds only these, linked to the dev shell's own (the
// dbus-daemon beside dbus-run-session), never the host system's.
export const SESSION_SYSTEM_BIN = "/run/current-system/sw/bin";
export const SESSION_SYSTEM_PROGRAMS = ["dbus-daemon"] as const;

// The directories covered inside a session, with their tmpfs modes.
export function coveredDirs(home: string): [string, string][] {
  const all: [string, string][] = [...COVERED_DIRS, [home, "0700"]].map(
    ([d, m]) => [d, m],
  );
  const out: [string, string][] = [];
  for (const [d, m] of all.sort((a, b) => a[0].length - b[0].length)) {
    let st;
    try {
      st = lstatSync(d);
    } catch {
      continue;
    }
    if (!st.isDirectory() || st.isSymbolicLink()) continue;
    if (out.some(([o]) => within(d, o))) continue;
    out.push([d, m]);
  }
  return out;
}

// `p` is `dir` or below it.
function within(p: string, dir: string): boolean {
  return p === dir || p.startsWith(dir.endsWith("/") ? dir : `${dir}/`);
}

// Of `keep`, those under a covered directory, each bound back after the
// covering (none inside another kept one).
export function boundBack(keep: string[], covered: string[]): string[] {
  const under = [
    ...new Set(keep.filter((k) => covered.some((c) => within(k, c)))),
  ].sort((a, b) => a.length - b.length);
  const out: string[] = [];
  for (const k of under) if (!out.some((o) => within(k, o))) out.push(k);
  return out;
}

// Name resolution inside a session: /etc/hosts and /etc/resolv.conf
// are replaced by these: localhost only, and no nameserver (glibc then
// asks 127.0.0.1:53, which inside the namespace is nobody).
export const SESSION_HOSTS =
  "# Generated for one capture session: localhost only.\n127.0.0.1 localhost\n::1 localhost\n";
export const SESSION_RESOLV_CONF =
  "# Generated for one capture session: no nameserver.\noptions attempts:1 timeout:1\n";

const START_TIMEOUT_MS = 20000;
const WTYPE_SETTLE_MS = 100;

export interface OutputMode {
  // Logical (CSS) pixels.
  width: number;
  height: number;
  // Device pixels per logical pixel.
  scale: number;
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

// A client window as sway reports it.
export interface SwayWindow {
  id: number;
  name: string;
  appId: string | null;
  pid: number;
  // In output-logical pixels.
  rect: Rect;
  fullscreen: boolean;
  focused: boolean;
}

export interface DesktopSessionOptions {
  stateRoot?: string;
  env?: Record<string, string | undefined>;
}

export interface DesktopStartInfo {
  run: string;
  // Names this session among the run's (e.g. "thunderbird" for the warm
  // instance, "thunderbird-c3" for a cold capture's).
  instance: string;
  output: OutputMode;
  // Ports on the host's 127.0.0.1 the session's clients may reach (the
  // imap and assets services); nothing else on the host or beyond is
  // reachable from inside.
  forward?: number[];
  // Client-specific environment, added to the session's own (e.g.
  // MOZ_ENABLE_WAYLAND=1). Every client launched in the session sees it.
  env?: Record<string, string>;
}

export interface DesktopSessionInfo {
  stateDir: string;
  runtimeDir: string;
  home: string;
  swayVersion: string;
  // The namespace launcher (setpriv/unshare) in this PID namespace.
  pid: number | null;
  swept: string[];
  timingMs: { start: number };
}

// Single-quoted for sh.
// The path with symlinks resolved, or itself when it does not resolve.
function realOr(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

function shQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

// PATH-like lists reduced to their Nix store entries (all of them when
// none is in the store, on a host without Nix).
function storeOnly(list: string | undefined): string {
  const all = (list ?? "").split(delimiter).filter((p) => p !== "");
  const store = all.filter((p) => p.startsWith("/nix/store/"));
  return (store.length > 0 ? store : all).join(delimiter);
}

export function swayConfig(output: OutputMode): string {
  return `# Generated for one capture session; removed at teardown.
output ${HEADLESS_OUTPUT} mode ${outputModeArg(output)} scale ${output.scale} bg #808080 solid_color
default_border none
default_floating_border none
focus_follows_mouse no
focus_on_window_activation focus
xwayland disable
`;
}

function outputModeArg(o: OutputMode): string {
  return `${Math.round(o.width * o.scale)}x${Math.round(o.height * o.scale)}`;
}

function busConfig(runtimeDir: string): string {
  return `<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<!-- Generated for one capture session: a private session bus that
  listens in the session's runtime directory and activates nothing. -->
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:dir=${runtimeDir}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
`;
}

export class DesktopSession {
  private child: ChildProcess | null = null;
  private exited: Promise<void> | null = null;
  private stateDirPath: string | null = null;
  private runtimeDirPath: string | null = null;
  private swaySock = "";
  private waylandDisplay = "";
  private mode: OutputMode = { width: 0, height: 0, scale: 1 };
  private readonly stateRoot: string;
  private readonly env: Record<string, string | undefined>;
  private bins: Record<string, string> = {};
  private launches = 0;
  private readonly launched = new Set<string>();
  private readonly bridges: Server[] = [];
  private readonly bridged = new Set<Socket>();
  private readonly onExit = (): void => {
    this.child?.kill("SIGKILL");
    for (const d of [this.stateDirPath, this.runtimeDirPath])
      if (d !== null) removeRunDirSync(d);
  };

  constructor(opts: DesktopSessionOptions = {}) {
    this.stateRoot = opts.stateRoot ?? DESKTOP_STATE_ROOT;
    this.env = opts.env ?? process.env;
  }

  get stateDir(): string {
    if (this.stateDirPath === null) throw new Error("session not started");
    return this.stateDirPath;
  }

  get runtimeDir(): string {
    if (this.runtimeDirPath === null) throw new Error("session not started");
    return this.runtimeDirPath;
  }

  get home(): string {
    return join(this.stateDir, "home");
  }

  get output(): OutputMode {
    return { ...this.mode };
  }

  // The namespace launcher's pid, or null when not running.
  get pid(): number | null {
    return this.child?.pid ?? null;
  }

  get running(): boolean {
    return (
      this.child !== null &&
      this.child.exitCode === null &&
      this.child.signalCode === null
    );
  }

  // A failed start leaves nothing behind.
  async start(info: DesktopStartInfo): Promise<DesktopSessionInfo> {
    try {
      return await this.startSession(info);
    } catch (err) {
      await this.stop();
      throw err;
    }
  }

  private async startSession(
    info: DesktopStartInfo,
  ): Promise<DesktopSessionInfo> {
    const t0 = performance.now();
    const host = { ...currentHost(), env: this.env };
    const names = [...SESSION_BINARIES, "setpriv", "unshare", "sh"];
    for (const n of names) {
      const p = findExecutable(n, host);
      if (p === null)
        throw new Error(
          `${n} is not on PATH (run inside the isonim-email dev shell)`,
        );
      this.bins[n] = p;
    }
    const locales = this.env[LOCALES_ENV] ?? "";
    if (locales === "" || !existsSync(join(locales, "locale-archive")))
      throw new Error(
        `$${LOCALES_ENV} does not name a glibc locale directory (run inside the isonim-email dev shell)`,
      );
    const fontconfig = this.env.FONTCONFIG_FILE ?? "";
    if (fontconfig === "" || !existsSync(fontconfig))
      throw new Error(
        "$FONTCONFIG_FILE does not name the pinned font configuration (run inside the isonim-email dev shell)",
      );
    const swayVersion =
      /sway version (\S+)/.exec(
        spawnSync(this.bins.sway!, ["--version"], { encoding: "utf8" })
          .stdout ?? "",
      )?.[1] ?? "";
    if (swayVersion === "") throw new Error("cannot read sway's version");

    const swept = await sweepDeadOwners(
      this.stateRoot,
      socketBases(this.env),
      DESKTOP_SOCKET_PREFIX,
    );
    const stateDir = join(this.stateRoot, `${info.run}-${info.instance}`);
    if (existsSync(stateDir))
      throw new Error(
        `${stateDir} exists and does not belong to a dead run (a live run of the same id?)`,
      );
    mkdirSync(this.stateRoot, { recursive: true });
    mkdirSync(stateDir, { mode: 0o700 });
    this.stateDirPath = stateDir;
    this.runtimeDirPath = this.makeRuntimeDir();
    const owner: OwnerRecord = {
      owner: thisProcess(process.pid),
      run: info.run,
      stateDir,
      socketDir: this.runtimeDirPath,
      processes: [],
    };
    writeOwner(owner);
    process.once("exit", this.onExit);
    const home = join(stateDir, "home");
    for (const d of [
      home,
      join(home, ".config"),
      join(home, ".local", "share"),
      join(home, ".local", "state"),
      join(home, ".cache"),
    ])
      mkdirSync(d, { recursive: true, mode: 0o700 });
    writeFileSync(join(stateDir, "sway.conf"), swayConfig(info.output));
    writeFileSync(join(stateDir, "bus.conf"), busConfig(this.runtimeDirPath));
    writeFileSync(join(stateDir, "hosts"), SESSION_HOSTS);
    writeFileSync(join(stateDir, "resolv.conf"), SESSION_RESOLV_CONF);
    this.mode = { ...info.output };

    const env: Record<string, string> = {
      PATH: storeOnly(this.env.PATH),
      XDG_DATA_DIRS: storeOnly(this.env.XDG_DATA_DIRS),
      HOME: home,
      XDG_CONFIG_HOME: join(home, ".config"),
      XDG_DATA_HOME: join(home, ".local", "share"),
      XDG_STATE_HOME: join(home, ".local", "state"),
      XDG_CACHE_HOME: join(home, ".cache"),
      XDG_RUNTIME_DIR: this.runtimeDirPath,
      // Nothing on the host's system bus is reachable.
      DBUS_SYSTEM_BUS_ADDRESS: `unix:path=${join(stateDir, "no-system-bus")}`,
      TZ: "UTC",
      LANG: "en_US.UTF-8",
      LC_ALL: "en_US.UTF-8",
      LOCALE_ARCHIVE: join(locales, "locale-archive"),
      FONTCONFIG_FILE: fontconfig,
      WLR_BACKENDS: "headless",
      WLR_LIBINPUT_NO_DEVICES: "1",
      WLR_RENDERER: "pixman",
      XDG_CURRENT_DESKTOP: "sway",
      XDG_SESSION_TYPE: "wayland",
      ...info.env,
    };
    // The bridge's outside half: each forwarded port's unix socket, relayed
    // to the host's 127.0.0.1 (netns_bridge.ts has the inside half).
    const forward = [...new Set(info.forward ?? [])];
    for (const port of forward) {
      const server = createServer((inside) => {
        const host = createConnection({ host: "127.0.0.1", port });
        this.bridged.add(inside);
        this.bridged.add(host);
        inside.pipe(host);
        host.pipe(inside);
        const close = (): void => {
          inside.destroy();
          host.destroy();
          this.bridged.delete(inside);
          this.bridged.delete(host);
        };
        for (const s of [inside, host]) {
          s.on("error", close);
          s.on("close", close);
        }
      });
      await new Promise<void>((ok, fail) => {
        server.once("error", fail);
        server.listen(
          join(this.runtimeDirPath!, `bridge-out-${port}.sock`),
          () => {
            server.off("error", fail);
            ok();
          },
        );
      });
      this.bridges.push(server);
    }
    // The namespaces: an outer user namespace (root in it, so loopback
    // can be brought up in the new network namespace), and inside it a
    // user namespace that maps the caller's own uid and gid back, so
    // everything in the session runs as the caller. Then the bus, the
    // bridge's inside half, and sway.
    const sh = this.bins.sh!;
    const q = (argv: string[]): string => argv.map(shQuote).join(" ");
    const devScript = this.devScript(stateDir, q);
    const coverScript = this.coverScript(stateDir, q);
    writeFileSync(
      join(stateDir, "init.sh"),
      `#!${sh}
# Generated for one capture session; removed at teardown.
set -e
# Name resolution: localhost only, no nameserver.
if [ -e /etc/hosts ]; then ${q([this.bins.mount!, "--bind", join(stateDir, "hosts"), "/etc/hosts"])}; fi
if [ -e /etc/resolv.conf ]; then ${q([this.bins.mount!, "--bind", join(stateDir, "resolv.conf"), "/etc/resolv.conf"])}; fi
# Host devices: none but the pseudo-devices.
${devScript}
# Host sockets: the directories that hold them covered, the session's
# own directories bound back (through descriptors opened before).
${coverScript}
${q([this.bins.ip!, "link", "set", "lo", "up"])}
exec ${q([
        this.bins.unshare!,
        "--user",
        `--map-user=${process.getuid?.() ?? 0}`,
        `--map-group=${process.getgid?.() ?? 0}`,
        "--",
        this.bins["dbus-run-session"]!,
        `--config-file=${join(stateDir, "bus.conf")}`,
        "--",
        sh,
        join(stateDir, "session.sh"),
      ])}
`,
      { mode: 0o700 },
    );
    writeFileSync(
      join(stateDir, "session.sh"),
      `#!${sh}
# Generated for one capture session; removed at teardown.
${q([process.execPath, BRIDGE_SCRIPT, this.runtimeDirPath, ...forward.map(String)])} &
exec ${q([this.bins.sway!, "-c", join(stateDir, "sway.conf")])}
`,
      { mode: 0o700 },
    );
    const argv = [
      this.bins.setpriv!,
      "--pdeathsig",
      "KILL",
      "--",
      this.bins.unshare!,
      "--user",
      "--map-root-user",
      "--net",
      "--mount",
      "--pid",
      "--fork",
      "--kill-child",
      "--",
      sh,
      join(stateDir, "init.sh"),
    ];
    const child = spawn(argv[0]!, argv.slice(1), {
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.child = child;
    this.exited = new Promise((ok) => child.once("exit", () => ok()));
    const log = join(stateDir, "session.log");
    const append = (d: Buffer): void => {
      try {
        writeFileSync(log, d, { flag: "a" });
      } catch {
        // the state directory is gone (teardown)
      }
    };
    child.stdout?.on("data", append);
    child.stderr?.on("data", append);
    if (child.pid !== undefined)
      writeOwner({ ...owner, processes: [thisProcess(child.pid)] });

    // Up: sway's IPC socket answers and the Wayland socket exists.
    const rt = this.runtimeDirPath;
    for (;;) {
      if (!this.running)
        throw new Error(`the session exited while starting: ${this.logTail()}`);
      if (performance.now() - t0 > START_TIMEOUT_MS)
        throw new Error(
          `sway did not start within ${START_TIMEOUT_MS / 1000} s: ${this.logTail()}`,
        );
      const files = readdirSync(rt);
      const ipc = files.find((f) => f.startsWith("sway-ipc."));
      const wl = files.find((f) => /^wayland-\d+$/.test(f));
      if (
        ipc !== undefined &&
        wl !== undefined &&
        files.includes("bridge-ready")
      ) {
        this.swaySock = join(rt, ipc);
        this.waylandDisplay = wl;
        const r = spawnSync(
          this.bins.swaymsg!,
          ["-s", this.swaySock, "-t", "get_version"],
          { encoding: "utf8", env: this.toolEnv() },
        );
        if (r.status === 0) break;
      }
      await new Promise((r) => setTimeout(r, 10));
    }
    return {
      stateDir,
      runtimeDir: rt,
      home,
      swayVersion,
      pid: child.pid ?? null,
      swept,
      timingMs: { start: performance.now() - t0 },
    };
  }

  // The init script's part that replaces /dev by the session's own: an
  // empty tmpfs, the pseudo-devices bound from the host's /dev (reached
  // through a recursive bind of it, made first and detached last), a
  // devpts instance of its own, an empty /dev/shm and the descriptor
  // links. Runs before coverScript(), while the state directory (under
  // the covered home directory) is still reachable by its path.
  private devScript(stateDir: string, q: (argv: string[]) => string): string {
    const mount = this.bins.mount!;
    const ln = this.bins.ln!;
    const stage = join(stateDir, "host-dev");
    mkdirSync(stage, { mode: 0o700 });
    const lines = [
      q([mount, "--rbind", "/dev", stage]),
      q([mount, "-t", "tmpfs", "-o", "mode=0755,nosuid", "ie-dev", "/dev"]),
    ];
    for (const d of SESSION_DEVICES)
      lines.push(
        `: >${shQuote(`/dev/${d}`)}`,
        q([mount, "--bind", join(stage, d), `/dev/${d}`]),
      );
    lines.push(
      q([
        mount,
        "-t",
        "devpts",
        "-o",
        "X-mount.mkdir,newinstance,ptmxmode=0666,mode=0620",
        "ie-devpts",
        "/dev/pts",
      ]),
      q([ln, "-s", "pts/ptmx", "/dev/ptmx"]),
      q([
        mount,
        "-t",
        "tmpfs",
        "-o",
        "X-mount.mkdir,mode=1777,nosuid,nodev",
        "ie-cover",
        "/dev/shm",
      ]),
      q([ln, "-s", "/proc/self/fd", "/dev/fd"]),
      q([ln, "-s", "/proc/self/fd/0", "/dev/stdin"]),
      q([ln, "-s", "/proc/self/fd/1", "/dev/stdout"]),
      q([ln, "-s", "/proc/self/fd/2", "/dev/stderr"]),
      q([this.bins.umount!, "--lazy", stage]),
    );
    return lines.join("\n");
  }

  // The init script's part that covers the host directories holding
  // unix sockets and binds the session's own directories back.
  private coverScript(stateDir: string, q: (argv: string[]) => string): string {
    const mount = this.bins.mount!;
    const covered = coveredDirs(realOr(userInfo().homedir));
    const keep = boundBack(
      [this.runtimeDirPath!, stateDir, dirname(BRIDGE_SCRIPT)].map(realOr),
      covered.map(([d]) => d),
    );
    const lines: string[] = [];
    keep.forEach((k, i) => lines.push(`exec ${i + 3}<${shQuote(k)}`));
    for (const [d, mode] of covered)
      lines.push(
        q([mount, "-t", "tmpfs", "-o", `mode=${mode}`, "ie-cover", d]),
      );
    keep.forEach((k, i) =>
      lines.push(
        q([
          mount,
          "--bind",
          "-o",
          "X-mount.mkdir",
          `/proc/self/fd/${i + 3}`,
          k,
        ]),
      ),
    );
    keep.forEach((_, i) => lines.push(`exec ${i + 3}<&-`));
    if (covered.some(([d]) => within(SESSION_SYSTEM_BIN, d))) {
      const dir = join(stateDir, "system-bin");
      mkdirSync(dir, { recursive: true });
      for (const prog of SESSION_SYSTEM_PROGRAMS) {
        const target = realOr(
          join(dirname(this.bins["dbus-run-session"]!), prog),
        );
        if (!existsSync(target))
          throw new Error(`${prog} is not beside dbus-run-session`);
        symlinkSync(target, join(dir, prog));
      }
      lines.push(
        q([mount, "--bind", "-o", "X-mount.mkdir", dir, SESSION_SYSTEM_BIN]),
      );
    }
    for (const link of REEXPOSED_STORE_LINKS) {
      let target: string;
      try {
        if (!lstatSync(link).isSymbolicLink()) continue;
        target = realpathSync(link);
      } catch {
        continue;
      }
      if (!target.startsWith("/nix/store/")) continue;
      if (!covered.some(([d]) => within(link, d))) continue;
      lines.push(q([mount, "--bind", "-o", "X-mount.mkdir", target, link]));
    }
    return lines.join("\n");
  }

  private makeRuntimeDir(): string {
    for (const base of socketBases(this.env)) {
      if (!existsSync(base)) continue;
      // The longest socket names: sway-ipc.<uid>.<pid>.sock and the
      // bus's dbus-XXXXXXXXXX, with room to spare.
      if (base.length + `/${DESKTOP_SOCKET_PREFIX}XXXXXX/`.length + 40 > 107)
        continue;
      const dir = mkdtempSync(join(base, DESKTOP_SOCKET_PREFIX));
      chmodSync(dir, 0o700);
      return dir;
    }
    throw new Error(
      "no directory short enough for the session's sockets ($XDG_RUNTIME_DIR and /tmp both too long or missing)",
    );
  }

  private logTail(): string {
    const p =
      this.stateDirPath === null ? "" : join(this.stateDirPath, "session.log");
    if (p === "" || !existsSync(p)) return "(no log)";
    return readFileSync(p, "utf8").trim().split("\n").slice(-5).join(" | ");
  }

  // The environment the Wayland and IPC tools run with from outside the
  // session.
  private toolEnv(): Record<string, string> {
    return {
      PATH: this.env.PATH ?? "",
      XDG_RUNTIME_DIR: this.runtimeDir,
      WAYLAND_DISPLAY: this.waylandDisplay,
      SWAYSOCK: this.swaySock,
    };
  }

  // Runs swaymsg with the given arguments; throws with sway's answer on
  // failure. Returns its standard output.
  swaymsg(args: string[]): string {
    const r = spawnSync(this.bins.swaymsg!, ["-s", this.swaySock, ...args], {
      encoding: "utf8",
      env: this.toolEnv(),
    });
    if (r.status !== 0)
      throw new Error(
        `swaymsg ${args.join(" ")} failed (${r.status}): ${(r.stdout ?? "").trim()} ${(r.stderr ?? "").trim()}`,
      );
    return r.stdout ?? "";
  }

  // Sets the output to a logical width×height at the given scale.
  setOutput(mode: OutputMode): void {
    this.swaymsg([
      "output",
      HEADLESS_OUTPUT,
      "mode",
      outputModeArg(mode),
      "scale",
      String(mode.scale),
    ]);
    this.mode = { ...mode };
  }

  // A connection to 127.0.0.1:port inside the session's network
  // namespace (a client's remote-control port), through the bridge.
  connectInner(port: number): Socket {
    const s = createConnection({
      path: join(this.runtimeDir, "bridge-in.sock"),
    });
    s.once("connect", () => s.write(`${port}\n`));
    return s;
  }

  // Every client window in the tree.
  windows(): SwayWindow[] {
    const tree = JSON.parse(this.swaymsg(["-t", "get_tree", "-r"])) as unknown;
    const out: SwayWindow[] = [];
    interface Node {
      id: number;
      name: string | null;
      app_id?: string | null;
      pid?: number;
      rect: Rect;
      fullscreen_mode?: number;
      focused: boolean;
      nodes?: Node[];
      floating_nodes?: Node[];
    }
    const walk = (n: Node): void => {
      if (typeof n.pid === "number" && n.pid > 0)
        out.push({
          id: n.id,
          name: n.name ?? "",
          appId: n.app_id ?? null,
          pid: n.pid,
          rect: n.rect,
          fullscreen: (n.fullscreen_mode ?? 0) !== 0,
          focused: n.focused,
        });
      for (const c of [...(n.nodes ?? []), ...(n.floating_nodes ?? [])])
        walk(c);
    };
    walk(tree as Node);
    return out;
  }

  async waitForWindow(
    pred: (w: SwayWindow) => boolean,
    what: string,
    timeoutMs: number,
  ): Promise<SwayWindow> {
    const t0 = Date.now();
    for (;;) {
      const w = this.windows().find(pred);
      if (w !== undefined) return w;
      if (!this.running)
        throw new Error(`the session exited waiting for ${what}`);
      if (Date.now() - t0 > timeoutMs)
        throw new Error(
          `no ${what} within ${timeoutMs / 1000} s (windows: ${JSON.stringify(this.windows().map((x) => x.name))})`,
        );
      await new Promise((r) => setTimeout(r, 20));
    }
  }

  // Makes the window fill the output and waits until sway reports it
  // at the output's full size.
  async fullscreen(id: number, timeoutMs = 5000): Promise<SwayWindow> {
    this.swaymsg([`[con_id=${id}]`, "fullscreen", "enable"]);
    this.swaymsg([`[con_id=${id}]`, "focus"]);
    return this.waitForWindow(
      (w) =>
        w.id === id &&
        w.fullscreen &&
        w.rect.width === this.mode.width &&
        w.rect.height === this.mode.height,
      `window ${id} fullscreen at ${this.mode.width}x${this.mode.height}`,
      timeoutMs,
    );
  }

  // Launches `argv` inside the session (it inherits the session's
  // environment, plus `env`); its output goes to <stateDir>/<name>.log.
  // sway runs it in a process group of its own, whose leader's pid
  // (inside the session) is recorded so that stopLaunched() can end the
  // whole group.
  launch(name: string, argv: string[], env: Record<string, string> = {}): void {
    const sh = findExecutable("sh", {
      ...currentHost(),
      env: { PATH: storeOnly(this.env.PATH) },
    });
    if (sh === null) throw new Error("no sh on PATH");
    const script = join(this.stateDir, `launch-${++this.launches}-${name}.sh`);
    const exports = Object.entries(env)
      .map(([k, v]) => `export ${k}=${shQuote(v)}\n`)
      .join("");
    writeFileSync(
      script,
      `#!${sh}\necho $$ >${shQuote(join(this.stateDir, `${name}.pid`))}\n${exports}exec ${argv.map(shQuote).join(" ")} >>${shQuote(join(this.stateDir, `${name}.log`))} 2>&1\n`,
      { mode: 0o700 },
    );
    this.launched.add(name);
    this.swaymsg(["exec", script]);
  }

  hasLaunched(name: string): boolean {
    return this.launched.has(name);
  }

  // Ends the process group launch(name) started (SIGKILL), and returns
  // once every process of it is gone (see teardownVerdict: the wait
  // lasts while the kernel tears them down, and fails when the teardown
  // has stalled for `stallMs`, or has not finished within `capMs` in
  // all). The kill and the wait are done from outside, on the host's
  // pids of the session's processes, so neither depends on sway starting
  // a command under load. The group is found by its id inside the
  // session, so its members are ended even when its leader has exited.
  async stopLaunched(
    name: string,
    stallMs = 10000,
    capMs = 60000,
  ): Promise<void> {
    const pidFile = join(this.stateDir, `${name}.pid`);
    if (!existsSync(pidFile)) return;
    const pid = readFileSync(pidFile, "utf8").trim();
    rmSync(pidFile, { force: true });
    this.launched.delete(name);
    if (!/^\d+$/.test(pid) || this.child?.pid === undefined) return;
    const group = hostGroupOf(Number(pid), this.child.pid);
    if (group === null) return;
    try {
      process.kill(-group, "SIGKILL");
    } catch {
      // the group is already gone
    }
    const t0 = Date.now();
    let last = teardownSample(groupPids(group));
    let lastChange = t0;
    for (;;) {
      const now = teardownSample(groupPids(group));
      const v = teardownVerdict(last, now, Date.now() - lastChange, stallMs, {
        elapsedMs: Date.now() - t0,
        capMs,
      });
      if (v.state === "gone") return;
      if (v.state === "stalled") throw new Error(`stop-${name}: ${v.reason}`);
      if (v.state === "progress") lastChange = Date.now();
      last = now;
      await new Promise((r) => setTimeout(r, 20));
    }
  }

  // Runs `argv` inside the session to completion; its exit status and
  // output (stdout and stderr together).
  async runInside(
    name: string,
    argv: string[],
    timeoutMs = 20000,
  ): Promise<{ status: number; output: string }> {
    const tag = `run-${++this.launches}-${name}`;
    const done = join(this.stateDir, `${tag}.status`);
    const log = join(this.stateDir, `${tag}.log`);
    this.launch(tag, [
      "sh",
      "-c",
      `"$@" >${shQuote(log)} 2>&1; echo $? >${shQuote(`${done}.tmp`)}; mv ${shQuote(`${done}.tmp`)} ${shQuote(done)}`,
      "sh",
      ...argv,
    ]);
    const t0 = Date.now();
    while (!existsSync(done)) {
      if (!this.running)
        throw new Error(`the session exited while running ${name}`);
      if (Date.now() - t0 > timeoutMs)
        throw new Error(`${name} did not finish within ${timeoutMs / 1000} s`);
      await new Promise((r) => setTimeout(r, 20));
    }
    this.launched.delete(tag);
    const status = Number(readFileSync(done, "utf8").trim());
    const output = existsSync(log) ? readFileSync(log, "utf8") : "";
    return { status, output };
  }

  // The session bus's address (the bus listens in the runtime
  // directory), for a client of it outside the session.
  busAddress(): string {
    const sock = readdirSync(this.runtimeDir).find((f) => /^dbus-/.test(f));
    if (sock === undefined) throw new Error("the session bus has no socket");
    return `unix:path=${join(this.runtimeDir, sock)}`;
  }

  // The whole output at its scale, as an RGBA image (device pixels).
  screenshot(): RgbaImage {
    const r = spawnSync(
      this.bins.grim!,
      [
        "-o",
        HEADLESS_OUTPUT,
        "-s",
        String(this.mode.scale),
        "-t",
        "png",
        "-l",
        "1",
        "-",
      ],
      { env: this.toolEnv(), maxBuffer: 512 * 1024 * 1024 },
    );
    if (r.status !== 0)
      throw new Error(
        `grim failed (${r.status}): ${r.stderr?.toString().trim() ?? ""}`,
      );
    return readPng(r.stdout);
  }

  // Types text, or presses keys (`key("Return")`, `key("ctrl", "k")`
  // presses the modifiers around the last key), through wtype.
  type(text: string): void {
    this.wtype(["--", text]);
  }

  key(...keys: string[]): void {
    const mods = keys.slice(0, -1);
    const last = keys[keys.length - 1];
    if (last === undefined) return;
    const args: string[] = [];
    for (const m of mods) args.push("-M", m);
    args.push("-k", last);
    for (const m of [...mods].reverse()) args.push("-m", m);
    this.wtype(args);
  }

  // Every wtype run brings a virtual keyboard with a keymap of its own;
  // a key sent at once can arrive before the client has taken the
  // keymap in, and is lost (measured: the first character of a typed
  // string went missing), so each run waits briefly before its first
  // key.
  private wtype(args: string[]): void {
    const r = spawnSync(
      this.bins.wtype!,
      ["-s", String(WTYPE_SETTLE_MS), ...args],
      {
        encoding: "utf8",
        env: this.toolEnv(),
      },
    );
    if (r.status !== 0)
      throw new Error(
        `wtype ${args.join(" ")} failed (${r.status}): ${(r.stderr ?? "").trim()}`,
      );
  }

  async stop(): Promise<void> {
    const child = this.child;
    this.child = null;
    if (
      child !== null &&
      child.exitCode === null &&
      child.signalCode === null
    ) {
      // The launcher (unshare) takes the namespace down with it: its
      // child, the namespace's first process, is killed when it goes,
      // and with it every process in the namespace.
      child.kill("SIGKILL");
      await this.exited;
    }
    for (const s of this.bridged) s.destroy();
    this.bridged.clear();
    for (const b of this.bridges.splice(0))
      await new Promise<void>((ok) => b.close(() => ok()));
    // Every process of the namespace is gone once its first process is
    // reaped; wait for that before removing the directories they use.
    for (const d of [this.stateDirPath, this.runtimeDirPath])
      if (d !== null) removeRunDirSync(d);
    this.stateDirPath = null;
    this.runtimeDirPath = null;
    process.off("exit", this.onExit);
  }
}

// --- Ending a launched process group. --------------------------------
//
// SIGKILL cannot be refused, but a killed process is not gone at once:
// the kernel first tears it down (its threads exit, its memory is
// unmapped, its descriptors closed), and that takes CPU time the process
// competes for like any other. On a loaded host it took KMail with its
// QtWebEngine processes several seconds. A fixed deadline would fail a
// stop that is merely slow; no deadline at all would hang on a teardown
// that waits on something that never comes. So the wait follows the
// teardown: it lasts while the remaining processes still run (a task
// runnable or using CPU time, or the set of tasks shrinking), and fails,
// naming where each task waits, once nothing has moved for the bound,
// or once the teardown has lasted longer than any measured one by far
// (the overall cap), whatever it is doing.

// The host id of the process group whose id inside the session's PID
// namespace is `inner`, among the descendants of `root` (the session's
// launcher); null when no process of it is left.
export function hostGroupOf(inner: number, root: number): number | null {
  for (const p of descendants(root)) {
    const ns = /^NSpgid:\s+(.*)$/m
      .exec(readProc(`/proc/${p}/status`) ?? "")?.[1]
      ?.trim()
      .split(/\s+/);
    if (ns !== undefined && ns.length > 1 && Number(ns.at(-1)) === inner)
      return Number(ns[0]);
  }
  return null;
}

function readProc(path: string): string | null {
  try {
    return readFileSync(path, "latin1");
  } catch {
    return null;
  }
}

// /proc/<pid>/stat's fields after the command name (field 3 first).
function statFields(text: string): string[] {
  return text.slice(text.lastIndexOf(")") + 2).split(" ");
}

function descendants(root: number): number[] {
  const children = new Map<number, number[]>();
  for (const e of readdirSync("/proc")) {
    if (!/^\d+$/.test(e)) continue;
    const st = readProc(`/proc/${e}/stat`);
    if (st === null) continue;
    const ppid = Number(statFields(st)[1]);
    children.set(ppid, [...(children.get(ppid) ?? []), Number(e)]);
  }
  const out: number[] = [];
  const queue = [root];
  while (queue.length > 0) {
    const p = queue.shift()!;
    out.push(p);
    queue.push(...(children.get(p) ?? []));
  }
  return out;
}

// Every process in the process group `group` (host pids).
function groupPids(group: number): number[] {
  const out: number[] = [];
  for (const e of readdirSync("/proc")) {
    if (!/^\d+$/.test(e)) continue;
    const st = readProc(`/proc/${e}/stat`);
    if (st !== null && Number(statFields(st)[2]) === group) out.push(Number(e));
  }
  return out;
}

// One task of a process being torn down.
export interface TeardownTask {
  // "pid/tid".
  id: string;
  // The scheduler state letter (R, S, D, Z, ...).
  state: string;
  // utime + stime, in clock ticks.
  cpu: number;
  // Where it sleeps (/proc/<pid>/task/<tid>/wchan), "" when running.
  wchan: string;
}

// The tasks of the given processes that still have work to do: a
// zombie whose threads are all gone has nothing left to tear down (it
// only waits for its parent to collect its status).
export function teardownSample(pids: number[]): TeardownTask[] {
  const out: TeardownTask[] = [];
  for (const pid of pids) {
    let tids: string[];
    try {
      tids = readdirSync(`/proc/${pid}/task`);
    } catch {
      continue;
    }
    for (const tid of tids) {
      const st = readProc(`/proc/${pid}/task/${tid}/stat`);
      if (st === null) continue;
      const f = statFields(st);
      const state = f[0] ?? "";
      if (state === "Z" || state === "X") continue;
      out.push({
        id: `${pid}/${tid}`,
        state,
        cpu: Number(f[11]) + Number(f[12]),
        wchan: (readProc(`/proc/${pid}/task/${tid}/wchan`) ?? "").trim(),
      });
    }
  }
  return out;
}

// What two consecutive samples of a teardown say: "gone" when no task
// is left; "progress" when a task finished, used CPU time or is
// runnable (waiting for a CPU, which it will get); otherwise "waiting",
// or "stalled" once nothing has moved for `stallMs` (the reason names
// each task's state and wait channel). Progress extends the wait only
// up to `cap.capMs` after the kill: a teardown still not finished then
// is "stalled" too, however busy its tasks look, so no stop waits
// longer than that.
export function teardownVerdict(
  prev: TeardownTask[],
  now: TeardownTask[],
  sinceChangeMs: number,
  stallMs: number,
  cap: { elapsedMs: number; capMs: number } = {
    elapsedMs: 0,
    capMs: Infinity,
  },
):
  | { state: "gone" | "progress" | "waiting" }
  | { state: "stalled"; reason: string } {
  if (now.length === 0) return { state: "gone" };
  const tasks = now
    .map((t) => `${t.id} ${t.state}${t.wchan === "" ? "" : ` in ${t.wchan}`}`)
    .join(", ");
  if (cap.elapsedMs >= cap.capMs)
    return {
      state: "stalled",
      reason: `the killed processes were not gone ${cap.capMs / 1000} s after the kill (${tasks})`,
    };
  const before = new Map(prev.map((t) => [t.id, t]));
  const moved =
    now.length < prev.length ||
    now.some((t) => {
      const b = before.get(t.id);
      return b === undefined || t.cpu !== b.cpu || t.state === "R";
    });
  if (moved) return { state: "progress" };
  if (sinceChangeMs < stallMs) return { state: "waiting" };
  return {
    state: "stalled",
    reason: `the killed processes made no progress for ${stallMs / 1000} s (${tasks})`,
  };
}

// The part of an RGBA image inside a device-pixel rectangle (clamped
// to the image).
export function cropImage(img: RgbaImage, r: Rect): RgbaImage {
  const x0 = Math.max(0, Math.min(img.width, r.x));
  const y0 = Math.max(0, Math.min(img.height, r.y));
  const x1 = Math.max(x0, Math.min(img.width, r.x + r.width));
  const y1 = Math.max(y0, Math.min(img.height, r.y + r.height));
  const w = x1 - x0;
  const h = y1 - y0;
  const data = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++)
    data.set(
      img.data.subarray(
        ((y0 + y) * img.width + x0) * 4,
        ((y0 + y) * img.width + x1) * 4,
      ),
      y * w * 4,
    );
  return { width: w, height: h, data };
}

// An RGBA image as an RGB PNG (captures are opaque).
export function encodePng(img: RgbaImage): Uint8Array {
  const rgb = new Uint8Array(img.width * img.height * 3);
  for (let i = 0, j = 0; i < img.data.length; i += 4, j += 3) {
    rgb[j] = img.data[i]!;
    rgb[j + 1] = img.data[i + 1]!;
    rgb[j + 2] = img.data[i + 2]!;
  }
  return writePng({ width: img.width, height: img.height, data: rgb });
}

export { processAlive };
