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
// Nothing outlives the run (the discipline of the imap service and the
// webmail servers):
// - the session runs as `setpriv --pdeathsig KILL -- unshare --user
//   --map-root-user --net --pid --fork --kill-child`, which brings
//   loopback up and then, in a nested user namespace that maps the
//   caller's uid and gid back (everything runs as the caller), runs
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
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
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
] as const;

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
  private readonly bridges: Server[] = [];
  private readonly bridged = new Set<Socket>();
  private readonly onExit = (): void => {
    this.child?.kill("SIGKILL");
    for (const d of [this.stateDirPath, this.runtimeDirPath])
      if (d !== null) rmSync(d, { recursive: true, force: true });
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
    writeFileSync(
      join(stateDir, "init.sh"),
      `#!${sh}
# Generated for one capture session; removed at teardown.
set -e
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
  // environment); its output goes to <stateDir>/<name>.log.
  launch(name: string, argv: string[]): void {
    const sh = findExecutable("sh", {
      ...currentHost(),
      env: { PATH: storeOnly(this.env.PATH) },
    });
    if (sh === null) throw new Error("no sh on PATH");
    const script = join(this.stateDir, `launch-${++this.launches}-${name}.sh`);
    writeFileSync(
      script,
      `#!${sh}\nexec ${argv.map(shQuote).join(" ")} >>${shQuote(join(this.stateDir, `${name}.log`))} 2>&1\n`,
      { mode: 0o700 },
    );
    this.swaymsg(["exec", script]);
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
      if (d !== null) rmSync(d, { recursive: true, force: true });
    this.stateDirPath = null;
    this.runtimeDirPath = null;
    process.off("exit", this.onExit);
  }
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
