// tools/capture/providers/claws_driver.ts — the Claws Mail driver of the
// linux-desktop provider.
//
// Claws Mail renders HTML with its litehtml viewer plugin: a small,
// deliberately weak engine (no scripting, partial CSS), which is why it
// is here, as a stress test for graceful degradation.
//
// Driving. Claws Mail has a remote-command socket of its own (the one
// `claws-mail --select` uses, in its runtime directory), which opens a
// folder or a message by its identifier, and an accessibility tree
// (GTK). It reads its accounts only when it starts, and no remote
// command adds one, so each capture writes the profile (accountrc,
// folderlist.xml, clawsrc) for the capture's account and starts the
// client in the session (warm: the compositor, the buses and the
// accessibility client stay up; the client process is per capture).
// Then:
// - `select #imap/capture/INBOX/1` over the socket opens the INBOX and
//   its one message (a fresh mailbox's first UID is 1); the subject the
//   client shows is checked by the provider, so a wrong message fails;
// - the password prompt is answered through the accessibility tree
//   (the field is written, never typed, and the password is not
//   remembered: "remember for this session" stays off);
// - View → "Open in new window" (its menu item's action) opens the
//   message in its own window, titled with the subject, which sway
//   fullscreens;
// - the message body is the litehtml widget's viewport (its scrolled
//   window's viewport, without the scroll bar); the widget's own height
//   is the document's, so the output grows until the viewport holds it.
//
// Remote content: litehtml has one switch for all remote content
// (enable_remote_content), no per-origin list, so it is on; it fetches
// with libcurl, which takes its proxy from the environment, so the
// client's http_proxy/https_proxy is the egress guard with only
// loopback exempt, and the session's network namespace stops anything
// else.
//
// Scheme: light only. Measured (2026-10-01, Claws Mail 4.4.0): with the
// dark GTK theme (GTK_THEME=Adwaita:dark) the client's chrome turns dark
// but the litehtml viewer still paints the message on white with the
// message's own colours, and litehtml has no prefers-color-scheme, so a
// "dark" capture would show nothing a light one does not.

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createConnection } from "node:net";
import { join } from "node:path";
import {
  A11Y_REQUIREMENTS,
  A11yClient,
  answerPasswordPrompt,
} from "./desktop_a11y.ts";
import type {
  DesktopClientDriver,
  DesktopClientInstance,
  DriverLaunchCtx,
  OpenedMessage,
  OpenRequest,
} from "./desktop_clients.ts";
import type { DesktopSession } from "./desktop_session.ts";
import { currentHost, findExecutable } from "./requirements.ts";
import type { Requirement, Scheme, ViewportSpec } from "./types.ts";

const APP = "claws-mail";
const STEP_TIMEOUT_MS = 30000;
const MAX_OUTPUT_HEIGHT = 8000;
// The account's name in the profile (also the IMAP folder's).
const ACCOUNT = "capture";
// The message window's title until the message is in it.
const PLACEHOLDER_TITLE = "Claws Mail - Message View";

export const CLAWS_VIEWPORTS: ViewportSpec[] = [
  { name: "desktop", width: 800, dpr: 1 },
];
export const CLAWS_SCHEMES: Scheme[] = ["light"];

export function clawsProfile(c: {
  user: string;
  host: string;
  port: number;
  pluginDir: string;
}): Record<string, string> {
  return {
    accountrc: [
      "[Account: 1]",
      "config_version=5",
      `account_name=${ACCOUNT}`,
      "is_default=1",
      "name=Capture",
      `address=${c.user}@capture.test`,
      "protocol=1",
      `receive_server=${c.host}`,
      `user_id=${c.user}`,
      "set_imapport=1",
      `imap_port=${c.port}`,
      "ssl_imap=0",
      "imap_subsonly=0",
      "",
    ].join("\n"),
    clawsrc: [
      "[Common]",
      "config_version=5",
      // The HTML part of multipart/alternative, rendered by litehtml.
      "promote_html_part=1",
      // An HTML-only message, too.
      "invoke_plugin_on_html=1",
      "",
      "[Plugins_GTK3]",
      join(c.pluginDir, "litehtml_viewer.so"),
      "",
      "[LiteHTML]",
      "enable_remote_content=1",
      "",
    ].join("\n"),
    // A local mailbox (Claws needs one for its special folders) and the
    // account's IMAP folder with its INBOX.
    "folderlist.xml": [
      '<?xml version="1.0" encoding="UTF-8" ?>',
      '<folderlist config_version="5">',
      '\t<folder type="mh" name="Mailbox" path="Mail" collapsed="0">',
      '\t\t<folderitem type="inbox" name="inbox" path="inbox" />',
      '\t\t<folderitem type="outbox" name="sent" path="sent" />',
      '\t\t<folderitem type="queue" name="queue" path="queue" />',
      '\t\t<folderitem type="draft" name="draft" path="draft" />',
      '\t\t<folderitem type="trash" name="trash" path="trash" />',
      "\t</folder>",
      `\t<folder type="imap" name="${ACCOUNT}" account_id="1" collapsed="0">`,
      '\t\t<folderitem type="inbox" name="INBOX" path="INBOX" />',
      "\t</folder>",
      "</folderlist>",
      "",
    ].join("\n"),
  };
}

class ClawsInstance implements DesktopClientInstance {
  readonly timingMs: Record<string, number>;
  private readonly session: DesktopSession;
  private readonly a11y: A11yClient;
  private readonly ctx: DriverLaunchCtx;
  private readonly pluginDir: string;

  constructor(
    session: DesktopSession,
    a11y: A11yClient,
    ctx: DriverLaunchCtx,
    pluginDir: string,
    timingMs: Record<string, number>,
  ) {
    this.session = session;
    this.a11y = a11y;
    this.ctx = ctx;
    this.pluginDir = pluginDir;
    this.timingMs = timingMs;
  }

  private socketPath(): string | null {
    const dir = join(this.session.runtimeDir, "claws-mail");
    if (!existsSync(dir)) return null;
    const s = readdirSync(dir)[0];
    return s === undefined ? null : join(dir, s);
  }

  private async command(line: string): Promise<void> {
    const path = this.socketPath();
    if (path === null) throw new Error("claws-mail: no command socket");
    // Claws Mail handles the command before it closes the connection,
    // and opening a folder can wait on the password prompt this driver
    // answers next: so the command is sent and the connection left to
    // close by itself.
    await new Promise<void>((ok, fail) => {
      const s = createConnection({ path }, () =>
        s.end(`${line}\n`, () => ok()),
      );
      s.once("error", fail);
    });
  }

  async open(req: OpenRequest): Promise<OpenedMessage> {
    if (req.scheme !== "light")
      throw new Error(`claws-mail: no ${req.scheme} scheme`);
    const timing: Record<string, number> = {};
    const t = (): number => performance.now();
    const a = req.account;

    // The profile for this capture's account, and the client.
    let ts = t();
    const home = this.session.home;
    const dir = join(home, ".claws-mail");
    rmSync(dir, { recursive: true, force: true });
    rmSync(join(home, "Mail"), { recursive: true, force: true });
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    for (const sub of ["inbox", "sent", "queue", "draft", "trash"])
      mkdirSync(join(home, "Mail", sub), { recursive: true });
    for (const [name, text] of Object.entries(
      clawsProfile({
        user: a.user,
        host: a.host,
        port: a.port,
        pluginDir: this.pluginDir,
      }),
    ))
      writeFileSync(join(dir, name), text, { mode: 0o600 });
    rmSync(join(this.session.runtimeDir, "claws-mail"), {
      recursive: true,
      force: true,
    });
    const proxy = this.ctx.assets.baseUrl.replace(/\/$/, "");
    this.session.launch("claws", ["claws-mail"], {
      http_proxy: proxy,
      https_proxy: proxy,
      no_proxy: "127.0.0.1,localhost",
    });
    const main = await this.session.waitForWindow(
      (w) => w.appId === APP && / - Claws Mail /.test(w.name),
      "the Claws Mail main window",
      STEP_TIMEOUT_MS,
    );
    while (this.socketPath() === null)
      await new Promise((r) => setTimeout(r, 20));
    timing.client = t() - ts;

    // The message, in the main window (the password prompt answered on
    // the way).
    ts = t();
    await this.command(`select #imap/${ACCOUNT}/INBOX/1`);
    let answered = false;
    const subjectWanted = await (async () => {
      const t0 = Date.now();
      for (;;) {
        if (!answered)
          answered = await answerPasswordPrompt(
            this.a11y,
            APP,
            a.password,
            "OK",
          );
        // The message list's one row, once fetched and selected.
        const [cell] = await this.a11y.find({
          app: APP,
          window: " - Claws Mail ",
          role: "label",
          nameRe: "^1 item selected",
          limit: 1,
        });
        if (cell !== undefined) return true;
        if (Date.now() - t0 > STEP_TIMEOUT_MS)
          throw new Error("claws-mail: the INBOX message was not selected");
        await new Promise((r) => setTimeout(r, 50));
      }
    })();
    void subjectWanted;
    timing.sync = t() - ts;

    // Its own window.
    ts = t();
    const item = await this.a11y.waitFor(
      {
        app: APP,
        window: " - Claws Mail ",
        role: "menu item",
        name: "Open in new window",
      },
      "the 'Open in new window' menu item",
      STEP_TIMEOUT_MS,
    );
    const before = new Set(this.session.windows().map((w) => w.id));
    await this.a11y.act(item);
    const win = await this.session.waitForWindow(
      (w) => w.appId === APP && !before.has(w.id),
      "the Claws Mail message window",
      STEP_TIMEOUT_MS,
    );
    await this.session.fullscreen(win.id);
    timing.open = t() - ts;

    // Settle and measure, growing the output to the document. The
    // widget geometry is read once the window's accessible frame has
    // the output's size, the window shows the subject, and two reads
    // agree (a read right after a resize can carry the old allocation).
    ts = t();
    let body = null as null | {
      x: number;
      y: number;
      width: number;
      height: number;
    };
    let docHeight = 0;
    let subject = "";
    let last = "";
    const t0 = Date.now();
    for (;;) {
      if (Date.now() - t0 > STEP_TIMEOUT_MS) {
        const seen = await this.a11y.find({
          app: APP,
          role: ["viewport", "drawing area", "frame"],
        });
        throw new Error(
          `claws-mail: the message window's litehtml viewport did not settle (${JSON.stringify(seen.map((n) => [n.role, n.name, n.extents]))})`,
        );
      }
      const out = this.session.output;
      const placed = this.session.windows().find((w) => w.id === win.id);
      if (placed === undefined)
        throw new Error("claws-mail: the message window closed");
      subject = placed.name;
      const nodes = await this.a11y.find({
        app: APP,
        window: "^(?!.* - Claws Mail )",
        role: ["frame", "viewport", "drawing area"],
        showing: true,
      });
      const frame = nodes.find((n) => n.role === "frame");
      const vp = nodes.find((n) => n.role === "viewport" && n.extents !== null);
      const da = nodes.find(
        (n) => n.role === "drawing area" && n.extents !== null,
      );
      const ready =
        subject !== PLACEHOLDER_TITLE &&
        placed.rect.width === out.width &&
        placed.rect.height === out.height &&
        frame?.extents?.width === out.width &&
        frame.extents.height === out.height;
      if (!ready || vp === undefined || da === undefined) {
        last = "";
        await new Promise((r) => setTimeout(r, 30));
        continue;
      }
      const key = JSON.stringify([vp.extents, da.extents]);
      if (key !== last) {
        last = key;
        await new Promise((r) => setTimeout(r, 30));
        continue;
      }
      body = vp.extents;
      docHeight = da.extents!.height;
      const missing = docHeight - vp.extents!.height;
      if (missing <= 0) break;
      const height = Math.min(MAX_OUTPUT_HEIGHT, out.height + missing);
      if (height === out.height) break;
      this.session.setOutput({ ...out, height });
      last = "";
    }
    timing.settle = t() - ts;
    if (body === null) throw new Error("claws-mail: no message body");
    const placed = this.session.windows().find((w) => w.id === win.id)!;
    return {
      body: {
        x: placed.rect.x + body.x,
        y: placed.rect.y + body.y,
        width: body.width,
        height: body.height,
      },
      subject,
      scheme: {
        dark: false,
        evidence: { gtk_theme: "Adwaita", viewer: "litehtml (no dark mode)" },
      },
      images: null,
      detail: {
        window: { sway_id: win.id, title: placed.name, rect: placed.rect },
        content: { height: docHeight },
        main_window: main.id,
        remote_content:
          "litehtml enable_remote_content (all origins; proxy: the egress guard)",
      },
      timingMs: timing,
    };
  }

  async close(): Promise<void> {
    await this.session.stopLaunched("claws");
    rmSync(join(this.session.runtimeDir, "claws-mail"), {
      recursive: true,
      force: true,
    });
  }

  async quit(): Promise<void> {
    await this.session.stopLaunched("claws").catch(() => {});
    this.a11y.close();
  }
}

export class ClawsDriver implements DesktopClientDriver {
  readonly clientId = "claws-mail";
  readonly family = "verification";
  readonly engine = "litehtml" as const;
  readonly viewports = CLAWS_VIEWPORTS;
  readonly schemes = CLAWS_SCHEMES;

  requirements(): Requirement[] {
    return [
      {
        kind: "binary",
        name: "claws-mail",
        why: "the Claws Mail client (the dev shell provides it)",
      },
      ...A11Y_REQUIREMENTS,
    ];
  }

  version(env: Record<string, string | undefined>): string {
    const bin = findExecutable("claws-mail", { ...currentHost(), env });
    if (bin === null) throw new Error("claws-mail is not on PATH");
    const r = spawnSync(bin, ["--version"], {
      encoding: "utf8",
      env: { PATH: env.PATH ?? "", HOME: env.HOME ?? "" },
    });
    const v = /Claws Mail version (\S+)/.exec(r.stdout ?? "")?.[1];
    if (v === undefined)
      throw new Error(
        `cannot read Claws Mail's version: ${(r.stdout ?? "").trim()}`,
      );
    return v;
  }

  sessionEnv(): Record<string, string> {
    return { GDK_BACKEND: "wayland", GTK_THEME: "Adwaita" };
  }

  async launch(
    session: DesktopSession,
    ctx: DriverLaunchCtx,
  ): Promise<DesktopClientInstance> {
    const t0 = performance.now();
    const bin = findExecutable("claws-mail", currentHost());
    if (bin === null) throw new Error("claws-mail is not on PATH");
    // The wrapper's store path holds the plugins.
    const pluginDir = join(bin, "..", "..", "lib", "claws-mail", "plugins");
    const a11y = await A11yClient.start(session);
    return new ClawsInstance(session, a11y, ctx, pluginDir, {
      a11y: performance.now() - t0,
    });
  }
}
