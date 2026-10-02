// tools/capture/providers/geary_driver.ts — the Geary driver of the
// linux-desktop provider.
//
// Geary renders messages in WebKitGTK and rewrites some of their HTML
// on the way (that is the point of including it); it is a verification
// client (family "verification").
//
// Driving. Geary reads its accounts (account_NN/geary.ini) only when it
// starts, and adds them otherwise only through its own editor, so each
// capture writes the capture's account and starts the client in the
// session (warm: the compositor, the buses, the keyring daemon and the
// accessibility client stay up; the client process is per capture).
// Geary needs a Secret Service on the session bus to start at all
// (measured: "Error creating controller: The name
// org.freedesktop.secrets was not provided by any .service files"), so
// the session runs a gnome-keyring-daemon with a throwaway keyring in
// its private home; the account keeps remember_password=false, so the
// password is never stored there. Then:
// - the password prompt is answered through the accessibility tree;
// - once the INBOX's one conversation is listed and selected, the
//   conversation list gets the focus and Geary's own `show-email`
//   application action (over D-Bus, with the email's identifier read
//   from Geary's database: its message row and IMAP UID) opens the
//   email in the conversation viewer, which at 800 px fills the window
//   (Geary's narrow, folded layout). Measured (Geary 46.0): this path
//   lists the email twice in the conversation, a collapsed copy above
//   the open one; the capture is the open email's body only;
// - remote images: Geary loads them on its own only for a message that
//   is DKIM/DMARC-authenticated and from a trusted sender or domain (no
//   per-origin list); for the injected message it shows "Remote images
//   not shown" with a Show button, which the driver presses (the
//   message's own allowance). Only the assets origin is reachable
//   anyway: the session's network namespace has loopback only;
// - the message body is the open email's web view, from the
//   accessibility tree; Geary sizes the web view to its document, so
//   the output grows until the whole view is inside the viewer.
//
// Dark: the dark variant of the GTK theme (GTK_THEME=Adwaita:dark),
// with which WebKitGTK reports prefers-color-scheme: dark to the message
// (measured with a message whose colours follow it); the client is
// started with the requested scheme, and the scheme's evidence is the
// luminance of the client's own header bar in the capture's output.

import { spawnSync } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
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
import type { DesktopSession, Rect } from "./desktop_session.ts";
import { currentHost, findExecutable } from "./requirements.ts";
import type { Requirement, Scheme, ViewportSpec } from "./types.ts";

const APP = "geary";
const ACCOUNT_ID = "account_01";
const STEP_TIMEOUT_MS = 30000;
const MAX_OUTPUT_HEIGHT = 8000;

export const GEARY_VIEWPORTS: ViewportSpec[] = [
  { name: "desktop", width: 800, dpr: 1 },
];
export const GEARY_SCHEMES: Scheme[] = ["light", "dark"];

export function gearyAccountIni(c: {
  user: string;
  host: string;
  port: number;
}): string {
  return [
    "# Generated for one capture; removed with the session.",
    "[Metadata]",
    "version=1",
    "status=enabled",
    "",
    "[Account]",
    "ordinal=1",
    "label=capture",
    "service_provider=other",
    `sender_mailboxes=Capture <${c.user}@capture.test>;`,
    "save_sent=false",
    "save_drafts=false",
    "",
    "[Folders]",
    "",
    "[Incoming]",
    `login=${c.user}`,
    "remember_password=false",
    `host=${c.host}`,
    `port=${c.port}`,
    "transport_security=none",
    "credentials=custom",
    "",
    "[Outgoing]",
    "remember_password=false",
    `host=${c.host}`,
    "port=9",
    "transport_security=none",
    "credentials=none",
    "",
  ].join("\n");
}

// GSettings through the keyfile backend (the session's own file).
export const GEARY_SETTINGS = [
  "[org/gnome/Geary]",
  "migrated-config=true",
  "run-in-background=false",
  "ask-open-attachment=false",
  "",
].join("\n");

export function themeFor(scheme: Scheme): string {
  return scheme === "dark" ? "Adwaita:dark" : "Adwaita";
}

// The keyring daemon some clients need on the session bus (a throwaway
// keyring, unlocked with a fixed word, in the session's private home).
export async function startKeyring(
  session: DesktopSession,
  a11y: A11yClient,
): Promise<void> {
  if (!session.hasLaunched("keyring"))
    session.launch("keyring", [
      "sh",
      "-c",
      "printf session | gnome-keyring-daemon --foreground --unlock --components=secrets",
    ]);
  await a11y.waitName("org.freedesktop.secrets", 15000);
}

export const KEYRING_REQUIREMENT: Requirement = {
  kind: "binary",
  name: "gnome-keyring-daemon",
  why: "the Secret Service the client requires on its session bus (the dev shell provides it)",
};

class GearyInstance implements DesktopClientInstance {
  readonly timingMs: Record<string, number>;
  private readonly session: DesktopSession;
  private readonly a11y: A11yClient;

  constructor(
    session: DesktopSession,
    a11y: A11yClient,
    timingMs: Record<string, number>,
  ) {
    this.session = session;
    this.a11y = a11y;
    this.timingMs = timingMs;
  }

  async open(req: OpenRequest): Promise<OpenedMessage> {
    if (req.scheme !== "light" && req.scheme !== "dark")
      throw new Error(`geary: no ${req.scheme} scheme`);
    const timing: Record<string, number> = {};
    const t = (): number => performance.now();
    const a = req.account;
    const home = this.session.home;

    // The account and settings, and the client.
    let ts = t();
    rmSync(join(home, ".config", "geary"), { recursive: true, force: true });
    rmSync(join(home, ".local", "share", "geary"), {
      recursive: true,
      force: true,
    });
    rmSync(join(home, ".cache", "geary"), { recursive: true, force: true });
    const accountDir = join(home, ".config", "geary", ACCOUNT_ID);
    mkdirSync(accountDir, { recursive: true, mode: 0o700 });
    writeFileSync(join(accountDir, "geary.ini"), gearyAccountIni(a), {
      mode: 0o600,
    });
    const settingsDir = join(home, ".config", "glib-2.0", "settings");
    mkdirSync(settingsDir, { recursive: true });
    writeFileSync(join(settingsDir, "keyfile"), GEARY_SETTINGS);
    this.session.launch("geary", ["geary"], {
      GTK_THEME: themeFor(req.scheme),
    });
    const win = await this.session.waitForWindow(
      (w) => w.appId === APP,
      "the Geary window",
      STEP_TIMEOUT_MS,
    );
    timing.client = t() - ts;

    // Password, then the INBOX's one conversation, listed and selected.
    ts = t();
    let answered = false;
    let row: A11yNode | undefined;
    for (const t0 = Date.now(); ; ) {
      if (!answered)
        answered = await answerPasswordPrompt(
          this.a11y,
          APP,
          a.password,
          "Authenticate",
        );
      [row] = await this.a11y.find({
        app: APP,
        role: "list item",
        showing: true,
        limit: 1,
      });
      if (row !== undefined && row.states.includes("selected")) break;
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error(
          "geary: the INBOX conversation was not listed and selected",
        );
      await new Promise((r) => setTimeout(r, 50));
    }
    const ids = await this.a11y.sql(
      join(home, ".local", "share", "geary", ACCOUNT_ID, "geary.db"),
      "SELECT message_id, ordering FROM MessageLocationTable",
    );
    if (ids.length !== 1)
      throw new Error(
        `geary: the account holds ${ids.length} message(s), expected exactly one`,
      );
    const [messageRow, uid] = ids[0] as [number, number];
    timing.sync = t() - ts;

    // Open it in the viewer.
    ts = t();
    await this.session.fullscreen(win.id);
    await this.a11y.focus(row!);
    await this.a11y.dbusCall({
      dest: "org.gnome.Geary",
      path: "/org/gnome/Geary",
      iface: "org.gtk.Actions",
      method: "Activate",
      args: `('show-email', [<('${ACCOUNT_ID}', <(byte 0x69, (int64 ${messageRow}, int64 ${uid}))>)>], @a{sv} {})`,
    });
    // The open email: the web view whose card is expanded and showing.
    const view = async (): Promise<{ doc: A11yNode; socket: Rect } | null> => {
      const docs = await this.a11y.find({
        app: APP,
        role: "document web",
        showing: true,
      });
      for (const d of docs) {
        // The web view's widget in Geary's tree: the ancestor that holds
        // the web process's plug (the plug's own extents are relative to
        // the web process, not the window).
        // The document's parent is the plug's scroll pane, its
        // grandparent the plug, and the plug's parent the widget, which
        // draws a border around the plug: the plug sits centred in it
        // (measured: 774x160 around 770x156), and the plug is the body.
        const anc = d.ancestors;
        const plug = anc.at(-2)?.extents;
        const widget = anc.at(-3)?.extents;
        if (
          anc.at(-1)?.role === "scroll pane" &&
          plug &&
          widget &&
          plug.width > 0
        ) {
          const dx = (widget.width - plug.width) / 2;
          const dy = (widget.height - plug.height) / 2;
          return {
            doc: d,
            socket: {
              x: widget.x + dx,
              y: widget.y + dy,
              width: plug.width,
              height: plug.height,
            },
          };
        }
      }
      return null;
    };
    let v = null as Awaited<ReturnType<typeof view>>;
    for (const t0 = Date.now(); v === null; ) {
      v = await view();
      if (v !== null) break;
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error("geary: the email did not open in the viewer");
      await new Promise((r) => setTimeout(r, 50));
    }
    // Remote images: the message's own Show.
    const [show] = await this.a11y.find({
      app: APP,
      role: "button",
      name: "Show",
      showing: true,
      limit: 1,
    });
    let imagesShown = false;
    if (show !== undefined) {
      if (!(await this.a11y.act(show)))
        throw new Error(
          `geary: the message's Show (remote images) button refused the press (states: ${show.states.join(", ")})`,
        );
      imagesShown = true;
    }
    timing.open = t() - ts;

    // Settle and measure, growing the output to the web view.
    ts = t();
    let body: Rect | null = null;
    let last = "";
    let subject = "";
    let docHeight = 0;
    for (const t0 = Date.now(); ; ) {
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error("geary: the email's body did not settle");
      const out = this.session.output;
      const placed = this.session.windows().find((w) => w.id === win.id);
      if (placed === undefined) throw new Error("geary: the window closed");
      const cur = await view();
      const [infobar] = await this.a11y.find({
        app: APP,
        role: "button",
        name: "Show",
        showing: true,
        limit: 1,
      });
      const [frame] = await this.a11y.find({
        app: APP,
        role: "frame",
        limit: 1,
      });
      const ready =
        cur !== null &&
        (!imagesShown || infobar === undefined) &&
        placed.rect.width === out.width &&
        placed.rect.height === out.height &&
        frame?.extents?.width === out.width &&
        frame.extents.height === out.height;
      if (!ready) {
        last = "";
        await new Promise((r) => setTimeout(r, 30));
        continue;
      }
      const key = JSON.stringify([cur.socket, cur.doc.extents]);
      if (key !== last) {
        last = key;
        await new Promise((r) => setTimeout(r, 30));
        continue;
      }
      // The card's header labels hold the subject.
      const card = cur.doc.ancestors
        .filter((x) => x.role === "list item")
        .at(-1);
      const labels = await this.a11y.find({
        app: APP,
        role: "label",
        showing: true,
      });
      subject = labels
        .filter(
          (l) =>
            card !== undefined &&
            l.path.slice(0, card.path.length).join() === card.path.join(),
        )
        .map((l) => l.name)
        .join(" | ");
      body = cur.socket;
      docHeight = cur.doc.extents?.height ?? 0;
      // The viewer's visible area: the scrolled list the cards are in.
      const viewport = cur.doc.ancestors
        .filter((x) => x.role === "viewport")
        .at(0);
      const bottom = viewport?.extents
        ? viewport.extents.y + viewport.extents.height
        : out.height;
      const missing = body.y + body.height - bottom;
      if (missing <= 0) break;
      const height = Math.min(MAX_OUTPUT_HEIGHT, out.height + missing + 16);
      if (height === out.height) break;
      this.session.setOutput({ ...out, height });
      last = "";
    }
    timing.settle = t() - ts;
    const placed = this.session.windows().find((w) => w.id === win.id)!;
    // The header bar, above the conversation.
    const scheme = chromeScheme(this.session, {
      x: 0,
      y: 0,
      width: placed.rect.width,
      height: 40,
    });
    return {
      body: {
        x: placed.rect.x + body.x,
        y: placed.rect.y + body.y,
        width: body.width,
        height: body.height,
      },
      subject,
      scheme: {
        dark: scheme.dark,
        evidence: { gtk_theme: themeFor(req.scheme), ...scheme.evidence },
      },
      images: null,
      detail: {
        window: { sway_id: win.id, title: placed.name, rect: placed.rect },
        content: { height: docHeight },
        email: { message_row: messageRow, uid },
        remote_images: imagesShown
          ? "the message's Show pressed"
          : "no remote image",
      },
      timingMs: timing,
    };
  }

  async close(): Promise<void> {
    await this.session.stopLaunched("geary");
  }

  async quit(): Promise<void> {
    await this.session.stopLaunched("geary").catch(() => {});
    this.a11y.close();
  }
}

export class GearyDriver implements DesktopClientDriver {
  readonly clientId = "geary";
  readonly family = "verification";
  readonly engine = "webkitgtk" as const;
  readonly viewports = GEARY_VIEWPORTS;
  readonly schemes = GEARY_SCHEMES;

  requirements(): Requirement[] {
    return [
      {
        kind: "binary",
        name: "geary",
        why: "the Geary client (the dev shell provides it)",
      },
      KEYRING_REQUIREMENT,
      ...A11Y_REQUIREMENTS,
    ];
  }

  version(env: Record<string, string | undefined>): string {
    const bin = findExecutable("geary", { ...currentHost(), env });
    if (bin === null) throw new Error("geary is not on PATH");
    const r = spawnSync(bin, ["--version"], {
      encoding: "utf8",
      env: { PATH: env.PATH ?? "", HOME: env.HOME ?? "" },
    });
    // "…/geary: 46.0"
    const v = /geary:?\s+(\d\S*)/i.exec(
      `${r.stdout ?? ""} ${r.stderr ?? ""}`,
    )?.[1];
    if (v === undefined)
      throw new Error(
        `cannot read Geary's version: ${(r.stdout ?? "").trim()}`,
      );
    return v;
  }

  sessionEnv(): Record<string, string> {
    return {
      GDK_BACKEND: "wayland",
      GSETTINGS_BACKEND: "keyfile",
      // WebKitGTK's own bubblewrap sandbox cannot start inside the
      // session's user namespace (measured: "bwrap: open
      // /proc/<pid>/ns/ns failed"); the session's namespaces are the
      // sandbox (loopback-only network, private home and buses).
      WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS: "1",
    };
  }

  async launch(
    session: DesktopSession,
    _ctx: DriverLaunchCtx,
  ): Promise<DesktopClientInstance> {
    const t0 = performance.now();
    const a11y = await A11yClient.start(session);
    await startKeyring(session, a11y);
    return new GearyInstance(session, a11y, { launch: performance.now() - t0 });
  }
}
