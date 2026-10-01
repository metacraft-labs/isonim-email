// tools/capture/providers/evolution_driver.ts — the Evolution driver of
// the linux-desktop provider.
//
// Evolution renders messages in WebKitGTK, through its own mail display
// (the headers above, the message body in a frame of its own); it is a
// verification client (family "verification"), close to Apple Mail's
// engine family but not its wrapper.
//
// Driving. Evolution keeps its accounts in evolution-data-server's
// source registry, which the session runs (evolution-source-registry,
// started by the driver: the session's bus activates nothing) and which
// picks up a source file written into its directory while it runs, so
// Evolution stays up for the whole warm session and each capture adds
// its account as three source files (account, identity, transport) and
// removes them afterwards. Per capture:
// - the password prompts are answered through the accessibility tree
//   (Evolution asks once per connection it opens; "Add this password to
//   your keyring" stays off, so nothing is stored);
// - Evolution's own `handle-uris` application action (over D-Bus, the
//   `folder:` URI Evolution's command line takes) selects the account's
//   INBOX, and focusing the message's row in the message list (through
//   the accessibility tree) shows it in the preview;
// - the layout is set through GSettings so that the preview fills the
//   window: no sidebar, no to-do bar, no status bar or preview toolbar,
//   collapsed headers, the message list a few rows tall;
// - the message body is the message's own frame inside the mail
//   display (its extents in the accessibility tree, relative to the
//   display's web view), so Evolution's header block is not in it; the
//   output grows until the frame is inside the display.
//
// Remote content: Evolution allows remote content per site (host), in
// its remote-content list; the list holds the assets service's host
// only, and the global policy stays "never".
//
// Dark: the dark variant of the GTK theme (GTK_THEME=Adwaita:dark),
// with which WebKitGTK reports prefers-color-scheme: dark to the message
// (measured with a message whose colours follow it). GTK reads it when
// the client starts, so the client is restarted when a capture asks for
// the other scheme; the scheme's evidence is the luminance of the
// client's own tool bar in the capture's output.

import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { realpathSync } from "node:fs";
import {
  A11Y_REQUIREMENTS,
  A11yClient,
  type A11yNode,
  answerPasswordPrompt,
  chromeScheme,
} from "./desktop_a11y.ts";
import type {
  DesktopClientDriver,
  DesktopClientInstance,
  DriverLaunchCtx,
  OpenedMessage,
  OpenRequest,
} from "./desktop_clients.ts";
import type { DesktopSession, Rect, SwayWindow } from "./desktop_session.ts";
import { themeFor } from "./geary_driver.ts";
import { currentHost, findExecutable } from "./requirements.ts";
import type { Requirement, Scheme, ViewportSpec } from "./types.ts";

const APP = "org.gnome.Evolution";
const SOURCES_BUS_NAME = "org.gnome.evolution.dataserver.Sources5";
const STEP_TIMEOUT_MS = 30000;
const MAX_OUTPUT_HEIGHT = 8000;

export const EVOLUTION_VIEWPORTS: ViewportSpec[] = [
  { name: "desktop", width: 800, dpr: 1 },
];
export const EVOLUTION_SCHEMES: Scheme[] = ["light", "dark"];

// GSettings through the keyfile backend (the session's own file).
export const EVOLUTION_SETTINGS = [
  "[org/gnome/evolution/mail]",
  "prompt-check-if-default-mailer=false",
  "show-startup-wizard=false",
  "image-loading-policy='never'",
  "show-to-do-bar=false",
  "show-preview-toolbar=false",
  "headers-collapsed=true",
  // The message list's share of the window, as Evolution stores a
  // pane's proportion (1000000 + 1000000 × proportion of the preview):
  // a few rows of list, the rest preview.
  "paned-size=1900000",
  "",
  "[org/gnome/evolution/shell]",
  "sidebar-visible=false",
  "statusbar-visible=false",
  "buttons-visible=false",
  "",
].join("\n");

// The three source files of one capture's account.
export function evolutionSources(c: {
  uid: string;
  user: string;
  host: string;
  port: number;
}): Record<string, string> {
  const head = "# Generated for one capture; removed after it.";
  return {
    [`${c.uid}.source`]: [
      head,
      "[Data Source]",
      `DisplayName=${c.uid}`,
      "Enabled=true",
      "Parent=",
      "",
      "[Offline]",
      "StaySynchronized=false",
      "",
      "[Refresh]",
      "Enabled=false",
      "IntervalMinutes=60",
      "",
      "[Mail Account]",
      "BackendName=imapx",
      `IdentityUid=${c.uid}-identity`,
      "NeedsInitialSetup=false",
      "",
      "[Authentication]",
      `Host=${c.host}`,
      "Method=",
      `Port=${c.port}`,
      "RememberPassword=false",
      `User=${c.user}`,
      "",
      "[Security]",
      "Method=none",
      "",
      "[Imapx Backend]",
      "UseIdle=false",
      "CheckAll=false",
      "FilterInbox=false",
      "",
    ].join("\n"),
    [`${c.uid}-identity.source`]: [
      head,
      "[Data Source]",
      "DisplayName=Capture",
      "Enabled=true",
      `Parent=${c.uid}`,
      "",
      "[Mail Identity]",
      `Address=${c.user}@capture.test`,
      "Name=Capture",
      "",
      "[Mail Submission]",
      `TransportUid=${c.uid}-transport`,
      "",
    ].join("\n"),
    [`${c.uid}-transport.source`]: [
      head,
      "[Data Source]",
      "DisplayName=Capture",
      "Enabled=true",
      `Parent=${c.uid}`,
      "",
      "[Mail Transport]",
      "BackendName=smtp",
      "",
      "[Authentication]",
      `Host=${c.host}`,
      "Port=9",
      "",
      "[Security]",
      "Method=none",
      "",
    ].join("\n"),
  };
}

class EvolutionInstance implements DesktopClientInstance {
  readonly timingMs: Record<string, number>;
  private readonly session: DesktopSession;
  private readonly a11y: A11yClient;
  private readonly assetsHost: string;
  private scheme: Scheme | null = null;
  private win: SwayWindow | null = null;
  private sources: string[] = [];

  constructor(
    session: DesktopSession,
    a11y: A11yClient,
    assetsHost: string,
    timingMs: Record<string, number>,
  ) {
    this.session = session;
    this.a11y = a11y;
    this.assetsHost = assetsHost;
    this.timingMs = timingMs;
  }

  private get home(): string {
    return this.session.home;
  }

  // Evolution with the requested scheme, its window fullscreen.
  private async ensureClient(scheme: Scheme): Promise<SwayWindow> {
    if (this.win !== null && this.scheme === scheme) return this.win;
    if (this.win !== null) await this.session.stopLaunched("evolution");
    this.win = null;
    this.session.launch("evolution", ["evolution", "--component=mail"], {
      GTK_THEME: themeFor(scheme),
    });
    const win = await this.session.waitForWindow(
      (w) => w.appId === APP,
      "the Evolution window",
      STEP_TIMEOUT_MS,
    );
    await this.session.fullscreen(win.id);
    this.win = win;
    this.scheme = scheme;
    return win;
  }

  async open(req: OpenRequest): Promise<OpenedMessage> {
    if (req.scheme !== "light" && req.scheme !== "dark")
      throw new Error(`evolution: no ${req.scheme} scheme`);
    const timing: Record<string, number> = {};
    const t = (): number => performance.now();
    const a = req.account;

    let ts = t();
    const win = await this.ensureClient(req.scheme);
    timing.client = t() - ts;

    // The account, through the source registry.
    ts = t();
    const uid = `capture-${a.user}`;
    const dir = join(this.home, ".config", "evolution", "sources");
    mkdirSync(dir, { recursive: true });
    for (const [name, text] of Object.entries(
      evolutionSources({ uid, user: a.user, host: a.host, port: a.port }),
    )) {
      writeFileSync(join(dir, name), text, { mode: 0o600 });
      this.sources.push(join(dir, name));
    }
    timing.configure = t() - ts;

    // The INBOX, its one message focused (and so in the preview); the
    // password prompts answered on the way.
    ts = t();
    let row: A11yNode[] = [];
    let lastSelect = 0;
    for (const t0 = Date.now(); ; ) {
      await answerPasswordPrompt(this.a11y, APP, a.password, "OK");
      if (Date.now() - lastSelect > 1000) {
        lastSelect = Date.now();
        await this.a11y.dbusCall({
          dest: APP,
          path: "/org/gnome/Evolution",
          iface: "org.gtk.Actions",
          method: "Activate",
          args: `('handle-uris', [<['folder://${uid}/INBOX']>], @a{sv} {})`,
        });
      }
      row = await this.rows();
      if (row.length > 0) break;
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error(
          `evolution: the INBOX of ${a.user} did not list its message`,
        );
      await new Promise((r) => setTimeout(r, 50));
    }
    timing.sync = t() - ts;

    ts = t();
    await this.a11y.focus(row[row.length - 1]!);
    // The message's frame inside the mail display.
    const frame = async (): Promise<{
      body: Rect;
      doc: A11yNode;
      display: Rect;
    } | null> => {
      const docs = await this.a11y.find({
        app: APP,
        role: "document web",
        showing: true,
      });
      const outer = docs.find(
        (d) => !d.ancestors.some((x) => x.role === "document web"),
      );
      const inner = docs.find((d) =>
        d.ancestors.some((x) => x.role === "document web"),
      );
      if (outer === undefined || inner === undefined || inner.extents === null)
        return null;
      // The display's widget holds the web process's plug (the document
      // web's grandparent), centred; extents inside the plug are the
      // plug's own.
      const plug = outer.ancestors.at(-2)?.extents;
      const widget = outer.ancestors.at(-3)?.extents;
      if (!plug || !widget) return null;
      const ox = widget.x + (widget.width - plug.width) / 2;
      const oy = widget.y + (widget.height - plug.height) / 2;
      return {
        body: {
          x: ox + inner.extents.x,
          y: oy + inner.extents.y,
          width: inner.extents.width,
          height: inner.extents.height,
        },
        doc: inner,
        display: { x: ox, y: oy, width: plug.width, height: plug.height },
      };
    };
    let f = null as Awaited<ReturnType<typeof frame>>;
    for (const t0 = Date.now(); ; ) {
      await answerPasswordPrompt(this.a11y, APP, a.password, "OK");
      f = await frame();
      if (f !== null && f.body.width > 0) break;
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error("evolution: the message did not open in the preview");
      await new Promise((r) => setTimeout(r, 50));
    }
    timing.open = t() - ts;

    // Settle and measure, growing the output until the frame is inside
    // the display.
    ts = t();
    let last = "";
    for (const t0 = Date.now(); ; ) {
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error("evolution: the message frame did not settle");
      const out = this.session.output;
      const placed = this.session.windows().find((w) => w.id === win.id);
      if (placed === undefined) throw new Error("evolution: the window closed");
      f = await frame();
      const ready =
        f !== null &&
        f.body.width > 0 &&
        placed.rect.width === out.width &&
        placed.rect.height === out.height;
      if (!ready) {
        last = "";
        await new Promise((r) => setTimeout(r, 30));
        continue;
      }
      const key = JSON.stringify([f!.body, f!.display]);
      if (key !== last) {
        last = key;
        await new Promise((r) => setTimeout(r, 30));
        continue;
      }
      const missing =
        f!.body.y + f!.body.height + 8 - (f!.display.y + f!.display.height);
      if (missing <= 0) break;
      const height = Math.min(MAX_OUTPUT_HEIGHT, out.height + missing);
      if (height === out.height) break;
      this.session.setOutput({ ...out, height });
      last = "";
    }
    timing.settle = t() - ts;
    const placed = this.session.windows().find((w) => w.id === win.id)!;
    const scheme = chromeScheme(this.session, {
      x: 0,
      y: 0,
      width: placed.rect.width,
      height: 40,
    });
    return {
      body: f!.body,
      subject: row.map((c) => c.name).join(" | "),
      scheme: {
        dark: scheme.dark,
        evidence: { gtk_theme: themeFor(req.scheme), ...scheme.evidence },
      },
      images: null,
      detail: {
        window: { sway_id: win.id, title: placed.name, rect: placed.rect },
        account_uid: uid,
        display: f!.display,
        content: { height: f!.body.height },
        remote_content: `per site: ${this.assetsHost} only (policy "never")`,
      },
      timingMs: timing,
    };
  }

  // The message list's rows (the cells of its one message).
  private async rows(): Promise<A11yNode[]> {
    return (
      await this.a11y.find({ app: APP, role: "table cell", showing: true })
    ).filter(
      (c) =>
        c.name !== "" &&
        c.ancestors.some(
          (x) => x.role === "tree table" && x.name !== "Mail Folder Tree",
        ),
    );
  }

  async close(): Promise<void> {
    // The account goes with its sources; its message leaves the list,
    // so the next capture's row is the next account's.
    for (const p of this.sources.splice(0)) rmSync(p, { force: true });
    for (const t0 = Date.now(); (await this.rows()).length > 0; ) {
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error(
          "evolution: the previous account's message stayed in the list",
        );
      await new Promise((r) => setTimeout(r, 50));
    }
    // Evolution's own cache of remote content: each capture fetches its
    // images from the assets service (which is what shows they loaded).
    rmSync(join(this.home, ".cache", "evolution", "http"), {
      recursive: true,
      force: true,
    });
  }

  async quit(): Promise<void> {
    await this.session.stopLaunched("evolution").catch(() => {});
    this.a11y.close();
  }
}

// The client's version, from its own package's pkg-config file (the
// binary needs a display even for --version).
function evolutionVersion(bin: string): string {
  const pkg = dirname(dirname(realpathSync(bin)));
  const pc = join(pkg, "lib", "pkgconfig", "evolution-shell-3.0.pc");
  if (!existsSync(pc))
    throw new Error(`cannot read Evolution's version: no ${pc}`);
  const v = /^Version:\s*(\S+)/m.exec(readFileSync(pc, "utf8"))?.[1];
  if (v === undefined)
    throw new Error(`cannot read Evolution's version from ${pc}`);
  return v;
}

export class EvolutionDriver implements DesktopClientDriver {
  readonly clientId = "evolution";
  readonly family = "verification";
  readonly engine = "webkitgtk" as const;
  readonly viewports = EVOLUTION_VIEWPORTS;
  readonly schemes = EVOLUTION_SCHEMES;

  requirements(): Requirement[] {
    return [
      {
        kind: "binary",
        name: "evolution",
        why: "the Evolution client (the dev shell provides it)",
      },
      {
        kind: "binary",
        name: "evolution-source-registry",
        why: "Evolution's account registry, run in the session (the dev shell provides it)",
      },
      ...A11Y_REQUIREMENTS,
    ];
  }

  version(env: Record<string, string | undefined>): string {
    const bin = findExecutable("evolution", { ...currentHost(), env });
    if (bin === null) throw new Error("evolution is not on PATH");
    return evolutionVersion(bin);
  }

  sessionEnv(): Record<string, string> {
    return {
      GDK_BACKEND: "wayland",
      GSETTINGS_BACKEND: "keyfile",
      // See geary_driver.ts: WebKitGTK's own sandbox cannot start in the
      // session's user namespace, which is the sandbox.
      WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS: "1",
    };
  }

  async launch(
    session: DesktopSession,
    ctx: DriverLaunchCtx,
  ): Promise<DesktopClientInstance> {
    const t0 = performance.now();
    const home = session.home;
    const settings = join(home, ".config", "glib-2.0", "settings");
    mkdirSync(settings, { recursive: true });
    writeFileSync(join(settings, "keyfile"), EVOLUTION_SETTINGS);
    const a11y = await A11yClient.start(session);
    // Remote content: the assets host only.
    const host = new URL(ctx.assets.baseUrl).hostname;
    const mailDir = join(home, ".config", "evolution", "mail");
    mkdirSync(mailDir, { recursive: true });
    const db = join(mailDir, "remote-content.db");
    await a11y.sql(
      db,
      "CREATE TABLE IF NOT EXISTS sites (value TEXT PRIMARY KEY)",
    );
    await a11y.sql(
      db,
      "CREATE TABLE IF NOT EXISTS mails (value TEXT PRIMARY KEY)",
    );
    await a11y.sql(
      db,
      "INSERT OR IGNORE INTO sites (value) VALUES (lower(?))",
      [host],
    );
    for (const extra of ctx.extraRemoteOrigins)
      await a11y.sql(
        db,
        "INSERT OR IGNORE INTO sites (value) VALUES (lower(?))",
        [new URL(extra).hostname],
      );
    session.launch("eds-registry", ["evolution-source-registry"]);
    await a11y.waitName(SOURCES_BUS_NAME, 15000);
    return new EvolutionInstance(session, a11y, host, {
      launch: performance.now() - t0,
    });
  }
}
