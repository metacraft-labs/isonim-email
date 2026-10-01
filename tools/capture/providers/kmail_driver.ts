// tools/capture/providers/kmail_driver.ts — the KMail driver of the
// linux-desktop provider.
//
// KMail renders messages in QtWebEngine (Chromium) behind its own
// message viewer; it is a verification client (family "verification").
//
// Akonadi. KMail reads mail only through Akonadi, KDE's PIM store, which
// the session runs with its SQLite backend (akonadiserverrc: no MySQL
// server, no system service): `akonadictl start` brings up the control
// process, the server and KMail's default agents. Measured (2026-10-01,
// Akonadi 26.04.0): the control and the server answer within about a
// second of the start; the driver records the time to the agent manager
// in its launch timings. Akonadi and KMail stay up for the warm session.
// The IMAP resource keeps the account's password through QtKeychain,
// which needs a Secret Service, so the session runs a gnome-keyring
// daemon whose throwaway keyring lives in the session's private home.
//
// Driving. KMail and Akonadi have D-Bus APIs of their own. Per capture:
// - a fresh IMAP resource (Akonadi's agent manager), configured through
//   its own settings interface (server, port, user, no TLS, PLAIN, no
//   interval check) and its password interface, then synchronized;
// - the message's item, once Akonadi holds it, read from Akonadi's own
//   database (the INBOX collection of that resource, exactly one item);
// - KMail's `showMail` (its D-Bus interface) opens the item in a reader
//   window, which sway fullscreens;
// - the message body is the reader's web view, from the accessibility
//   tree (Qt's, switched on with QT_LINUX_ACCESSIBILITY_ALWAYS_ON).
//   KMail renders its header block (subject, sender, date) inside that
//   same web document, above the message, and offers no header style
//   without it, so the capture includes it; the message's viewport is
//   the whole web view (a fixed-position element of the message sits at
//   the web view's corners, which the crop calibration checks);
// - afterwards the reader window is closed and the resource removed.
//
// Remote content: KMail has no per-origin list, only a global switch
// (htmlLoadExternal), which a reader window opened by showMail ignores
// (KMail opens it with external references off), and the viewer's own
// "load external references" action is not among the actions KMail
// exports on D-Bus; so the driver follows the link in KMail's notice
// ("... load the external references for this message by clicking
// here"): the link takes the focus through the accessibility tree and
// Return (wtype) follows it. The session's network namespace has
// loopback only.
//
// Dark: the session's colour scheme (Breeze Dark's colours in
// kdeglobals, read by the KDE platform theme, as a Plasma session has
// them) and KMail's own colour-scheme setting, both read when KMail
// starts, so KMail restarts when a capture asks for the other scheme.
// Measured (2026-10-01): with KMail's own setting alone the chrome turns
// dark but QtWebEngine still reports prefers-color-scheme: light to the
// message; the platform theme is what reports dark to Qt.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  A11Y_REQUIREMENTS,
  A11yClient,
  type A11yNode,
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
import { KEYRING_REQUIREMENT, startKeyring } from "./geary_driver.ts";
import { currentHost, findExecutable } from "./requirements.ts";
import type { Requirement, Scheme, ViewportSpec } from "./types.ts";

const APP = "kmail2";
const APP_ID = "org.kde.kmail2";
const KDE = "isonim-email-kde";
const STEP_TIMEOUT_MS = 60000;
// How long a message without story images may show its text without
// KMail's external-references notice before it counts as rendered.
const LINK_GRACE_MS = 2000;
// How long the notice's link may stay after it was followed before it
// is followed again.
const LINK_RETRY_MS = 5000;
const MAX_OUTPUT_HEIGHT = 8000;
const AKONADI = "org.freedesktop.Akonadi.Control";

// A string as a GVariant text literal.
export function gvString(s: string): string {
  return `'${s.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}'`;
}

export const KMAIL_VIEWPORTS: ViewportSpec[] = [
  { name: "desktop", width: 800, dpr: 1 },
];
export const KMAIL_SCHEMES: Scheme[] = ["light", "dark"];

export function akonadiServerRc(home: string): string {
  return [
    "[%General]",
    "Driver=QSQLITE",
    "",
    "[QSQLITE]",
    `Name=${join(home, ".local", "share", "akonadi", "akonadi.db")}`,
    "",
  ].join("\n");
}

export function colorSchemeName(scheme: Scheme): string {
  return scheme === "dark" ? "BreezeDark" : "BreezeLight";
}

export const COLOR_SCHEMES_ENV = "ISONIM_EMAIL_KDE_COLOR_SCHEMES";

export function kmailRc(scheme: Scheme): string {
  return [
    "[General]",
    "first-start=false",
    "AskEnableUnifiedMailboxes=false",
    "",
    "[UiSettings]",
    `ColorScheme=${colorSchemeName(scheme)}`,
    "",
    "[Reader]",
    "htmlMail=true",
    "htmlLoadExternal=true",
    "",
  ].join("\n");
}

// The viewer's own settings file (the message viewer library's).
export const MAILVIEWER_RC = [
  "[Reader]",
  "htmlMail=true",
  "htmlLoadExternal=true",
  "",
].join("\n");

class KMailInstance implements DesktopClientInstance {
  readonly timingMs: Record<string, number>;
  private readonly session: DesktopSession;
  private readonly a11y: A11yClient;
  private scheme: Scheme | null = null;
  private main: SwayWindow | null = null;
  private readonly colorSchemes: string;
  private resource: string | null = null;
  private reader: SwayWindow | null = null;
  private readonly noticeLink: string;

  constructor(
    session: DesktopSession,
    a11y: A11yClient,
    colorSchemes: string,
    timingMs: Record<string, number>,
    noticeLink: string,
  ) {
    this.noticeLink = noticeLink;
    this.session = session;
    this.a11y = a11y;
    this.colorSchemes = colorSchemes;
    this.timingMs = timingMs;
  }

  private get home(): string {
    return this.session.home;
  }

  private async call(
    dest: string,
    path: string,
    iface: string,
    method: string,
    args?: string,
  ): Promise<unknown> {
    return this.a11y.dbusCall({ dest, path, iface, method, args });
  }

  private async ensureKMail(scheme: Scheme): Promise<SwayWindow> {
    if (this.main !== null && this.scheme === scheme) return this.main;
    if (this.main !== null) await this.session.stopLaunched("kmail");
    this.main = null;
    writeFileSync(join(this.home, ".config", "kmail2rc"), kmailRc(scheme));
    // The session-wide colour scheme, as applying one writes it: the
    // scheme's colours in kdeglobals, read by the KDE platform theme.
    const name = colorSchemeName(scheme);
    writeFileSync(
      join(this.home, ".config", "kdeglobals"),
      `[General]\nColorScheme=${name}\n\n${readFileSync(join(this.colorSchemes, `${name}.colors`), "utf8")}`,
    );
    this.session.launch("kmail", [KDE, "kmail"]);
    const main = await this.session.waitForWindow(
      (w) =>
        w.appId === APP_ID &&
        /KMail/.test(w.name) &&
        !/ – KMail$|Unified|Mailboxes/.test(w.name),
      "the KMail main window",
      STEP_TIMEOUT_MS,
    );
    await this.a11y.waitName("org.kde.kmail", STEP_TIMEOUT_MS);
    this.main = main;
    this.scheme = scheme;
    return main;
  }

  async open(req: OpenRequest): Promise<OpenedMessage> {
    if (req.scheme !== "light" && req.scheme !== "dark")
      throw new Error(`kmail: no ${req.scheme} scheme`);
    const timing: Record<string, number> = {};
    const t = (): number => performance.now();
    const a = req.account;

    let ts = t();
    await this.ensureKMail(req.scheme);
    timing.client = t() - ts;

    // A fresh IMAP resource for the capture's account.
    ts = t();
    const [instance] = (await this.call(
      AKONADI,
      "/AgentManager",
      "org.freedesktop.Akonadi.AgentManager",
      "createAgentInstance",
      "('akonadi_imap_resource',)",
    )) as [string];
    this.resource = instance;
    const resBus = `org.freedesktop.Akonadi.Resource.${instance}`;
    await this.a11y.waitName(resBus, STEP_TIMEOUT_MS);
    const set = (method: string, arg: string): Promise<unknown> =>
      this.call(
        resBus,
        "/Settings",
        "org.kde.Akonadi.Imap.Settings",
        method,
        `(${arg},)`,
      );
    await set("setImapServer", gvString(a.host));
    await set("setImapPort", `${a.port}`);
    await set("setUserName", gvString(a.user));
    await set("setSafety", "'None'");
    // MailTransport's PLAIN.
    await set("setAuthentication", "1");
    await set("setSubscriptionEnabled", "false");
    await set("setDisconnectedModeEnabled", "false");
    await set("setIntervalCheckEnabled", "false");
    await this.call(
      resBus,
      "/Settings",
      "org.kde.Akonadi.Imap.Wallet",
      "setPassword",
      `(${gvString(a.password)},)`,
    );
    await this.call(
      resBus,
      "/Settings",
      "org.kde.Akonadi.Imap.Settings",
      "save",
    );
    await this.call(
      resBus,
      "/",
      "org.freedesktop.Akonadi.Agent.Control",
      "reconfigure",
    );
    timing.configure = t() - ts;

    // Synchronized: the INBOX of this resource holds exactly one item.
    ts = t();
    const db = join(this.home, ".local", "share", "akonadi", "akonadi.db");
    let item: number | null = null;
    let lastSync = 0;
    for (const t0 = Date.now(); ; ) {
      if (Date.now() - lastSync > 2000) {
        lastSync = Date.now();
        await this.call(
          resBus,
          "/",
          "org.freedesktop.Akonadi.Resource",
          "synchronize",
        );
      }
      const rows = await this.a11y.sql(
        db,
        "SELECT i.id FROM PimItemTable i" +
          " JOIN CollectionTable c ON i.collectionId = c.id" +
          " JOIN ResourceTable r ON c.resourceId = r.id" +
          " WHERE r.name = ? AND c.name = 'INBOX'",
        [instance],
      );
      if (rows.length > 1)
        throw new Error(
          `kmail: the INBOX of ${a.user} holds ${rows.length} messages, expected exactly one`,
        );
      if (rows.length === 1) {
        item = Number(rows[0]![0]);
        break;
      }
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error(`kmail: Akonadi did not fetch the INBOX of ${a.user}`);
      await new Promise((r) => setTimeout(r, 50));
    }
    timing.sync = t() - ts;

    // The reader window.
    ts = t();
    const before = new Set(this.session.windows().map((w) => w.id));
    await this.call(
      "org.kde.kmail",
      "/KMail",
      "org.kde.kmail.kmail",
      "showMail",
      `(int64 ${item},)`,
    );
    const win = await this.session.waitForWindow(
      (w) =>
        w.appId === APP_ID && !before.has(w.id) && / – KMail$/.test(w.name),
      "the KMail reader window",
      STEP_TIMEOUT_MS,
    );
    this.reader = win;
    await this.session.fullscreen(win.id);
    // Remote content: a reader opened by showMail never loads external
    // references by itself (KMail opens it with that default off,
    // whatever the setting), so the link in KMail's notice is followed
    // once the message is rendered with it. A message with story images
    // waits for the link as long as any other step, and fails the open
    // without it: a capture never passes with its images silently not
    // loaded. Without story images, a link that shows up while the
    // message renders is still followed (other remote content then
    // reaches the egress guard), and the message counts as rendered
    // without one LINK_GRACE_MS after its first text shows.
    let externalLoaded = false;
    for (const t0 = Date.now(); ; ) {
      const [link] = await this.a11y.find({
        app: APP,
        window: " – KMail$",
        role: "link",
        name: this.noticeLink,
        limit: 1,
      });
      const [heading] = await this.a11y.find({
        app: APP,
        window: " – KMail$",
        role: ["heading", "paragraph", "section"],
        showing: true,
        limit: 1,
      });
      if (link !== undefined) {
        externalLoaded = true;
        break;
      }
      if (
        !req.remoteImages &&
        heading !== undefined &&
        Date.now() - t0 > LINK_GRACE_MS
      )
        break;
      if (Date.now() - t0 > STEP_TIMEOUT_MS) {
        if (req.remoteImages)
          throw new Error(
            `kmail: the message has remote images but KMail's notice offered no 'load the external references' link within ${STEP_TIMEOUT_MS / 1000} s`,
          );
        break;
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    // Following it: the link's only accessible action gives it the
    // focus, and Return follows it, as a reader's keyboard would. Under
    // load a Return can be lost (measured: the link stayed for 60 s
    // after one), so while the link is still there it is focused and
    // followed again every LINK_RETRY_MS (following it twice only loads
    // the references twice), until it is gone or the step times out.
    let presses = 0;
    if (externalLoaded)
      for (const t0 = Date.now(), last = { at: 0 }; ; ) {
        const [link] = await this.a11y.find({
          app: APP,
          window: " – KMail$",
          role: "link",
          name: this.noticeLink,
          limit: 1,
        });
        if (link === undefined) break;
        if (Date.now() - t0 > STEP_TIMEOUT_MS)
          throw new Error(
            `kmail: the external references did not load (the notice's link followed ${presses} times in ${STEP_TIMEOUT_MS / 1000} s)`,
          );
        if (presses === 0 || Date.now() - last.at > LINK_RETRY_MS) {
          await this.a11y.act(link, "SetFocus");
          this.session.swaymsg([`[con_id=${win.id}]`, "focus"]);
          this.session.key("Return");
          presses++;
          last.at = Date.now();
        }
        await new Promise((r) => setTimeout(r, 50));
      }
    timing.open = t() - ts;

    // Settle and measure: the web document, its size the window's; the
    // output grows until the document does not scroll.
    ts = t();
    let doc: A11yNode | undefined;
    let last = "";
    let seen = "";
    let grown: { height: number; missing: number } | null = null;
    let settled = false;
    for (const t0 = Date.now(); ; ) {
      if (Date.now() - t0 > STEP_TIMEOUT_MS)
        throw new Error(
          `kmail: the reader's web view did not settle (${seen})`,
        );
      const out = this.session.output;
      const placed = this.session.windows().find((w) => w.id === win.id);
      if (placed === undefined)
        throw new Error("kmail: the reader window closed");
      const docs = await this.a11y.find({
        app: APP,
        window: " – KMail$",
        role: "document web",
        showing: true,
      });
      // Qt's accessible web document can report the size it had before
      // a resize for a moment (measured: 19 px taller than the view right
      // after the window went fullscreen), so it counts once it agrees
      // with its widget, ends where the status bar begins, and the status
      // bar ends at the window's bottom edge.
      const [status] = await this.a11y.find({
        app: APP,
        window: " – KMail$",
        role: "status bar",
        showing: true,
        limit: 1,
      });
      doc = docs.find((d) => {
        const e = d.extents;
        const w = d.ancestors.at(-1)?.extents;
        return (
          e !== null &&
          e.width > 0 &&
          w !== null &&
          w !== undefined &&
          w.x === e.x &&
          w.y === e.y &&
          w.width === e.width &&
          w.height === e.height &&
          status?.extents != null &&
          status.extents.y === e.y + e.height &&
          status.extents.y + status.extents.height === placed.rect.height
        );
      });
      seen = `docs ${JSON.stringify(docs.map((d) => [d.name, d.extents]))} window ${JSON.stringify(placed.rect)} output ${JSON.stringify(out)}`;
      const ready =
        doc !== undefined &&
        placed.rect.width === out.width &&
        placed.rect.height === out.height;
      if (!ready) {
        last = "";
        await new Promise((r) => setTimeout(r, 30));
        continue;
      }
      // The document's content: the lowest bottom edge of its elements,
      // leaving out those that end exactly at the view's bottom edge
      // (fixed to it, or a body of the view's full height), which follow
      // the view as it grows.
      const viewBottom0 = doc!.extents!.y + doc!.extents!.height;
      const parts = await this.a11y.find({
        app: APP,
        window: " – KMail$",
        role: [
          "section",
          "paragraph",
          "heading",
          "image",
          "table",
          "label",
          "link",
          "article",
        ],
        showing: true,
      });
      const bottom = parts.reduce((m, p) => {
        if (p.extents === null) return m;
        const b = p.extents.y + p.extents.height;
        return Math.abs(b - viewBottom0) <= 1 ? m : Math.max(m, b);
      }, 0);
      const key = JSON.stringify([doc!.extents, bottom]);
      seen = `${key} output ${JSON.stringify(out)}`;
      if (key !== last) {
        last = key;
        await new Promise((r) => setTimeout(r, 50));
        continue;
      }
      const viewBottom = doc!.extents!.y + doc!.extents!.height;
      const missing = bottom - viewBottom;
      if (missing <= 0 || settled) break;
      // An overflow that grows with the view (a box sized to the view
      // plus a margin) is not content below the view: back to the
      // height before, measured again there.
      if (grown !== null && Math.abs(missing - grown.missing) <= 1) {
        this.session.setOutput({ ...out, height: grown.height });
        settled = true;
        last = "";
        continue;
      }
      const height = Math.min(MAX_OUTPUT_HEIGHT, out.height + missing);
      if (height === out.height) break;
      grown = { height: out.height, missing };
      this.session.setOutput({ ...out, height });
      last = "";
    }
    timing.settle = t() - ts;
    const placed = this.session.windows().find((w) => w.id === win.id)!;
    const body: Rect = {
      x: placed.rect.x + doc!.extents!.x,
      y: placed.rect.y + doc!.extents!.y,
      width: doc!.extents!.width,
      height: doc!.extents!.height,
    };
    const scheme = chromeScheme(this.session, {
      x: 0,
      y: 0,
      width: placed.rect.width,
      height: 24,
    });
    return {
      body,
      subject: placed.name,
      scheme: {
        dark: scheme.dark,
        evidence: {
          color_scheme: req.scheme === "dark" ? "BreezeDark" : "BreezeLight",
          ...scheme.evidence,
        },
      },
      images: null,
      detail: {
        window: { sway_id: win.id, title: placed.name, rect: placed.rect },
        akonadi: { resource: instance, item },
        header_in_body:
          "KMail renders its header block inside the message's web view",
        remote_content: externalLoaded
          ? "the notice's 'load the external references for this message' link followed (all origins)"
          : "no external reference",
        notice_link_followed: presses,
      },
      timingMs: timing,
    };
  }

  async close(): Promise<void> {
    if (this.reader !== null) {
      const id = this.reader.id;
      this.reader = null;
      try {
        this.session.swaymsg([`[con_id=${id}]`, "kill"]);
      } catch {
        // already gone
      }
      await this.session.waitForWindow(
        () => !this.session.windows().some((w) => w.id === id),
        "the reader window to close",
        STEP_TIMEOUT_MS,
      );
    }
    if (this.resource !== null) {
      const r = this.resource;
      this.resource = null;
      await this.call(
        AKONADI,
        "/AgentManager",
        "org.freedesktop.Akonadi.AgentManager",
        "removeAgentInstance",
        `(${gvString(r)},)`,
      );
    }
  }

  async quit(): Promise<void> {
    await this.session.stopLaunched("kmail").catch(() => {});
    this.a11y.close();
  }
}

// The accessible name of the link in KMail's external-references notice.
export const KMAIL_NOTICE_LINK = "by clicking here";

export class KMailDriver implements DesktopClientDriver {
  // Test seam: the notice link's accessible name to look for, so a test
  // can make the link never found and show that the capture then fails
  // rather than passing without its images. Never set outside tests.
  private readonly noticeLink: string;
  private readonly env: Record<string, string | undefined>;

  constructor(
    opts: {
      env?: Record<string, string | undefined>;
      noticeLink?: string;
    } = {},
  ) {
    this.env = opts.env ?? process.env;
    this.noticeLink = opts.noticeLink ?? KMAIL_NOTICE_LINK;
  }

  readonly clientId = "kmail";
  readonly family = "verification";
  readonly engine = "qtwebengine" as const;
  readonly viewports = KMAIL_VIEWPORTS;
  readonly schemes = KMAIL_SCHEMES;

  requirements(): Requirement[] {
    return [
      {
        kind: "binary",
        name: KDE,
        why: "KMail and Akonadi with their Qt plugin and data paths (the dev shell provides it)",
      },
      KEYRING_REQUIREMENT,
      {
        kind: "env-dir",
        variable: COLOR_SCHEMES_ENV,
        why: "Breeze's colour schemes, for the light and dark captures (the dev shell sets it)",
      },
      ...A11Y_REQUIREMENTS,
    ];
  }

  version(env: Record<string, string | undefined>): string {
    const bin = findExecutable(KDE, { ...currentHost(), env });
    if (bin === null) throw new Error(`${KDE} is not on PATH`);
    const r = spawnSync(bin, ["kmail", "--version"], {
      encoding: "utf8",
      env: {
        PATH: env.PATH ?? "",
        HOME: env.HOME ?? "",
        QT_QPA_PLATFORM: "offscreen",
      },
    });
    // "kmail2 6.7.0 (26.04.0)": KMail's own version and its release.
    const m = /kmail2? (\S+) \((\S+)\)/.exec(r.stdout ?? "");
    if (m === null)
      throw new Error(
        `cannot read KMail's version: ${(r.stdout ?? "").trim()} ${(r.stderr ?? "").trim()}`,
      );
    return `${m[1]}-${m[2]}`;
  }

  private colorSchemes(): string {
    const dir = this.env[COLOR_SCHEMES_ENV] ?? "";
    if (dir === "" || !existsSync(join(dir, "BreezeDark.colors")))
      throw new Error(
        `$${COLOR_SCHEMES_ENV} does not name Breeze's colour schemes (run inside the dev shell)`,
      );
    return dir;
  }

  sessionEnv(): Record<string, string> {
    return {
      QT_QPA_PLATFORM: "wayland",
      // The KDE platform theme: the colour scheme in kdeglobals, which
      // Qt (and QtWebEngine's prefers-color-scheme) take from it.
      QT_QPA_PLATFORMTHEME: "kde",
      // Qt registers with the accessibility bus only when asked.
      QT_LINUX_ACCESSIBILITY_ALWAYS_ON: "1",
      // Chromium's own sandbox (QtWebEngine) cannot start inside the
      // session's user namespace either; the session is the sandbox.
      QTWEBENGINE_DISABLE_SANDBOX: "1",
    };
  }

  async launch(
    session: DesktopSession,
    _ctx: DriverLaunchCtx,
  ): Promise<DesktopClientInstance> {
    const t0 = performance.now();
    const home = session.home;
    mkdirSync(join(home, ".config", "akonadi"), { recursive: true });
    mkdirSync(join(home, ".local", "share", "akonadi"), { recursive: true });
    writeFileSync(
      join(home, ".config", "akonadi", "akonadiserverrc"),
      akonadiServerRc(home),
    );
    writeFileSync(join(home, ".config", "mailviewerrc"), MAILVIEWER_RC);
    const a11y = await A11yClient.start(session);
    const tk = performance.now();
    await startKeyring(session, a11y);
    const keyring = performance.now() - tk;
    // Akonadi: up when its agent manager answers.
    const ta = performance.now();
    session.launch("akonadi", [KDE, "akonadictl", "start"]);
    await a11y.waitName(AKONADI, STEP_TIMEOUT_MS);
    for (const tw = Date.now(); ; ) {
      try {
        await a11y.dbusCall({
          dest: AKONADI,
          path: "/AgentManager",
          iface: "org.freedesktop.Akonadi.AgentManager",
          method: "agentTypes",
        });
        break;
      } catch (err) {
        if (Date.now() - tw > STEP_TIMEOUT_MS) throw err;
        await new Promise((r) => setTimeout(r, 50));
      }
    }
    const akonadi = performance.now() - ta;
    return new KMailInstance(
      session,
      a11y,
      this.colorSchemes(),
      {
        launch: performance.now() - t0,
        keyring,
        akonadi,
      },
      this.noticeLink,
    );
  }
}
