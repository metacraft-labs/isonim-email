// tools/capture/providers/thunderbird_driver.ts — the Thunderbird
// driver of the linux-desktop provider.
//
// Thunderbird runs in the provider's headless session with a profile
// templated per instance (user.js, below): no first-run, default-client,
// telemetry or update traffic; the message opens in a window of its
// own; the HTTP and HTTPS proxy is the assets service's egress guard
// with no exception and no failover to a direct connection (Gecko never
// proxies loopback, so the assets service itself is reached directly
// and everything else ends at the guard; the session's network
// namespace, which has loopback only, stops what ignores the proxy);
// remote content stays blocked except for the assets service's
// origin (a per-origin permission, which is how Thunderbird records
// "allow remote content from"); software rendering.
//
// The driver talks to the running client over Marionette
// (marionette.ts), started with `--marionette --remote-allow-system-access`
// and bound to 127.0.0.1, using Thunderbird's own account and window
// APIs: it creates the capture's IMAP account with its password held in
// memory (nothing is written to the profile's password store), fetches
// the INBOX, checks it holds exactly one message, and opens that
// message with MailUtils.openMessageInNewWindow. The message body is
// the message window's `messagepane` browser; its geometry comes from
// the client's own layout, and the window fills the output (sway
// fullscreen), so the crop needs no calibrated offsets. The calibration
// fixture (desktop_clients.ts) still checks it per client build.
//
// Dark: `ui.systemUsesDarkTheme` and Thunderbird's built-in dark theme,
// switched at run time; the message pane then reports
// prefers-color-scheme: dark to the message, and Thunderbird's own
// dark-mode adaptation of messages (`mail.dark-reader.enabled`, on by
// default) is left at its default and recorded.

import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer, type AddressInfo } from "node:net";
import { join } from "node:path";
import type {
  DesktopClientDriver,
  DesktopClientInstance,
  DriverLaunchCtx,
  OpenedMessage,
  OpenRequest,
} from "./desktop_clients.ts";
import type { DesktopSession, SwayWindow } from "./desktop_session.ts";
import { Marionette } from "./marionette.ts";
import { currentHost, findExecutable } from "./requirements.ts";
import type { Requirement, Scheme, ViewportSpec } from "./types.ts";

export const THUNDERBIRD_APP_ID = "thunderbird";
const DARK_THEME = "thunderbird-compact-dark@mozilla.org";
const LIGHT_THEME = "default-theme@mozilla.org";
const START_TIMEOUT_MS = 60000;
const STEP_TIMEOUT_MS = 20000;
const IMAGE_TIMEOUT_MS = 10000;
// The tallest output the driver grows to (logical pixels).
const MAX_OUTPUT_HEIGHT = 8000;

// Measured (2026-10-01, Thunderbird 150.0.1): the message window does
// not get narrower than 660 CSS pixels, so a phone width is clipped by
// the output rather than laid out; only the desktop width is offered.
export const THUNDERBIRD_VIEWPORTS: ViewportSpec[] = [
  { name: "desktop", width: 800, dpr: 1 },
];
export const THUNDERBIRD_SCHEMES: Scheme[] = ["light", "dark"];

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

function prefValue(v: string | number | boolean): string {
  return typeof v === "string" ? JSON.stringify(v) : String(v);
}

// The profile's user.js: everything but the account, which is created
// per capture.
export function thunderbirdUserJs(c: {
  marionettePort: number;
  proxyHost: string;
  proxyPort: number;
}): string {
  const prefs: [string, string | number | boolean][] = [
    ["marionette.port", c.marionettePort],
    // First run, default client, start page, what's-new, rights notice.
    ["mail.shell.checkDefaultClient", false],
    ["mail.provider.suppress_dialog_on_startup", true],
    ["mail.startup.enabledMailCheckOnce", true],
    ["mailnews.start_page.enabled", false],
    ["mailnews.start_page_override.mstone", "ignore"],
    ["mail.rights.version", 1],
    ["mail.spotlight.firstRunDone", true],
    ["browser.aboutConfig.showWarning", false],
    // The message opens in a window of its own.
    ["mail.openMessageBehavior", 0],
    ["mailnews.open_window_warning", 0],
    // No telemetry, reporting, updates or add-on traffic.
    ["datareporting.policy.dataSubmissionEnabled", false],
    ["datareporting.healthreport.uploadEnabled", false],
    ["toolkit.telemetry.enabled", false],
    ["toolkit.telemetry.unified", false],
    ["toolkit.telemetry.server", ""],
    ["app.update.auto", false],
    ["app.update.checkInstallTime", false],
    ["extensions.update.enabled", false],
    ["extensions.getAddons.cache.enabled", false],
    ["mail.instrumentation.postUrl", ""],
    ["mail.phishing.detection.enabled", false],
    ["mailnews.auto_config.fetchFromISP.enabled", false],
    ["mail.cloud_files.enabled", false],
    ["calendar.timezone.local", "UTC"],
    ["calendar.timezone.useSystemTimezone", false],
    // No background mail activity beyond what a capture asks for.
    ["mail.biff.play_sound", false],
    ["mail.biff.show_alert", false],
    ["mail.biff.show_tray_icon", false],
    ["mail.server.default.check_new_mail", false],
    ["mail.server.default.login_at_startup", false],
    ["mail.server.default.autosync_offline_stores", false],
    ["mailnews.database.global.indexer.enabled", false],
    // Network: everything through the egress guard; loopback (the
    // assets service, the IMAP server, Marionette) is never proxied.
    ["network.proxy.type", 1],
    ["network.proxy.http", c.proxyHost],
    ["network.proxy.http_port", c.proxyPort],
    ["network.proxy.ssl", c.proxyHost],
    ["network.proxy.ssl_port", c.proxyPort],
    ["network.proxy.share_proxy_settings", false],
    ["network.proxy.no_proxies_on", ""],
    // Measured (2026-10-01): with the proxy alone, after the guard
    // refused a CONNECT to Thunderbird's settings server, Gecko failed
    // over to a direct TCP+TLS and a QUIC connection to it. The session's
    // network namespace stops those (it has loopback only); these two
    // stop Gecko from trying (QUIC cannot go through an HTTP proxy).
    ["network.proxy.failover_direct", false],
    ["network.http.http3.enable", false],
    ["network.proxy.socks_remote_dns", true],
    ["network.trr.mode", 5],
    ["network.dns.disablePrefetch", true],
    ["network.prefetch-next", false],
    ["network.http.speculative-parallel-limit", 0],
    ["network.captive-portal-service.enabled", false],
    ["network.connectivity-service.enabled", false],
    ["browser.safebrowsing.malware.enabled", false],
    ["browser.safebrowsing.phishing.enabled", false],
    ["browser.safebrowsing.downloads.enabled", false],
    // Remote content stays blocked but for the origins granted at
    // launch (the default; stated so the profile says it).
    ["mailnews.message_display.disable_remote_image", true],
    // Rendering: software, so every host draws the same pixels.
    ["gfx.webrender.software", true],
    ["ui.systemUsesDarkTheme", 0],
    ["intl.locale.requested", "en-US"],
    ["intl.regional_prefs.use_os_locales", false],
  ];
  return (
    "// Generated for one capture session; removed at teardown.\n" +
    prefs
      .map(([k, v]) => `user_pref(${JSON.stringify(k)}, ${prefValue(v)});`)
      .join("\n") +
    "\n"
  );
}

// --- Chrome scripts (run in Thunderbird's main window over Marionette). --

const GRANT_REMOTE_CONTENT = `
const [origins] = arguments;
for (const o of origins)
  Services.perms.addFromPrincipal(
    Services.scriptSecurityManager.createContentPrincipal(Services.io.newURI(o), {}),
    "image", Services.perms.ALLOW_ACTION);
return origins.map((o) => Services.perms.testPermissionFromPrincipal(
  Services.scriptSecurityManager.createContentPrincipal(Services.io.newURI(o), {}), "image"));
`;

const SET_SCHEME = `
const [dark, light, darkTheme, done] = arguments;
const { AddonManager } = ChromeUtils.importESModule("resource://gre/modules/AddonManager.sys.mjs");
(async () => {
  Services.prefs.setIntPref("ui.systemUsesDarkTheme", dark ? 1 : 0);
  const id = dark ? darkTheme : light;
  const addon = await AddonManager.getAddonByID(id);
  if (addon === null) throw new Error("no theme " + id);
  if (!addon.isActive) await addon.enable();
  const t0 = Date.now();
  while (window.matchMedia("(prefers-color-scheme: dark)").matches !== dark) {
    if (Date.now() - t0 > 5000) throw new Error("the main window does not report the requested scheme");
    await new Promise((r) => setTimeout(r, 20));
  }
  return { theme: id, active: addon.isActive };
})().then(done, (e) => done({ error: String(e) }));
`;

const CONFIGURE_AND_SYNC = `
const [user, password, host, port, done] = arguments;
const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
const { MailUtils } = ChromeUtils.importESModule("resource:///modules/MailUtils.sys.mjs");
const t0 = Date.now();
try {
  const server = MailServices.accounts.createIncomingServer(user, host, "imap");
  server.port = port;
  server.socketType = Ci.nsMsgSocketType.plain;
  server.authMethod = Ci.nsMsgAuthMethod.passwordCleartext;
  server.loginAtStartUp = false;
  server.doBiff = false;
  // In memory only: nothing reaches the profile's password store.
  server.password = password;
  const identity = MailServices.accounts.createIdentity();
  identity.email = user + "@capture.test";
  const account = MailServices.accounts.createAccount();
  account.incomingServer = server;
  account.addIdentity(identity);
  const inbox = MailUtils.getOrCreateFolder(server.serverURI + "/INBOX");
  const t1 = Date.now();
  // A fetch can finish before the new folder's headers are in
  // (measured: now and then the first update of a fresh account's INBOX
  // ends with no message); update again until the message is there.
  let updates = 0;
  const update = () => {
    updates++;
    inbox.updateFolderWithListener(null, {
      OnStartRunningUrl() {},
      OnStopRunningUrl(url, rc) {
        const hdrs = [...inbox.messages];
        if (hdrs.length === 0 && rc === 0 && Date.now() - t1 < ${STEP_TIMEOUT_MS}) {
          setTimeout(update, 50);
          return;
        }
        done({ key: account.key, rc, count: hdrs.length, updates,
          subject: hdrs[0]?.mime2DecodedSubject ?? null,
          messageId: hdrs[0]?.messageId ?? null,
          configureMs: t1 - t0, syncMs: Date.now() - t1 });
      },
    });
  };
  update();
} catch (e) { done({ error: String(e) }); }
`;

const OPEN_FIRST = `
const [key, done] = arguments;
const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
const { MailUtils } = ChromeUtils.importESModule("resource:///modules/MailUtils.sys.mjs");
const account = MailServices.accounts.getAccount(key);
const inbox = MailUtils.getExistingFolder(account.incomingServer.serverURI + "/INBOX");
const hdr = [...inbox.messages][0];
const t0 = Date.now();
const win = MailUtils.openMessageInNewWindow(hdr);
const poll = () => {
  const mp = win.document?.getElementById("messageBrowser")?.contentDocument?.getElementById("messagepane");
  const d = mp?.contentDocument;
  if (d && d.readyState === "complete" && d.URL !== "about:blank") done({ ms: Date.now() - t0, url: d.URL });
  else if (Date.now() - t0 > ${STEP_TIMEOUT_MS}) done({ error: "the message did not load within ${STEP_TIMEOUT_MS / 1000} s (window " + (win.closed ? "closed" : "open") + ", document " + (d ? d.URL + " " + d.readyState : "none") + ")" });
  else setTimeout(poll, 10);
};
setTimeout(poll, 0);
`;

// Waits until the message window has the requested size, every image
// in the body has finished (or the image timeout passed), the fonts are
// loaded, and two frames have been painted; then reports the body's
// geometry and what it holds.
const SETTLE_AND_MEASURE = `
const [width, height, done] = arguments;
const win = Services.wm.getMostRecentWindow("mail:messageWindow");
const t0 = Date.now();
const frames = (w) => new Promise((r) => w.requestAnimationFrame(() => w.requestAnimationFrame(r)));
(async () => {
  while (win.innerWidth !== width || win.innerHeight !== height) {
    if (Date.now() - t0 > ${STEP_TIMEOUT_MS}) throw new Error("the message window is " + win.innerWidth + "x" + win.innerHeight + ", not " + width + "x" + height);
    await new Promise((r) => setTimeout(r, 10));
  }
  const mb = win.document.getElementById("messageBrowser");
  const about = mb.contentDocument;
  const mp = about.getElementById("messagepane");
  const cw = mp.contentWindow;
  const cd = mp.contentDocument;
  let imagesComplete = true;
  while (![...cd.images].every((i) => i.complete)) {
    if (Date.now() - t0 > ${IMAGE_TIMEOUT_MS}) { imagesComplete = false; break; }
    await new Promise((r) => setTimeout(r, 20));
  }
  await cd.fonts.ready;
  await frames(cw);
  await frames(win);
  const r1 = mb.getBoundingClientRect();
  const r2 = mp.getBoundingClientRect();
  const se = cd.scrollingElement ?? cd.documentElement;
  return {
    body: { x: r1.x + r2.x, y: r1.y + r2.y, width: r2.width, height: r2.height },
    contentHeight: Math.max(se.scrollHeight, cd.body?.scrollHeight ?? 0),
    contentWidth: se.scrollWidth,
    window: { inner: [win.innerWidth, win.innerHeight], dpr: win.devicePixelRatio },
    images: [...cd.images].map((i) => ({ url: i.currentSrc || i.src, loaded: i.complete && i.naturalWidth > 0 })),
    imagesComplete,
    subject: about.getElementById("expandedsubjectBox")?.textContent?.trim() ?? win.document.title,
    scheme: {
      message_prefers_dark: cw.matchMedia("(prefers-color-scheme: dark)").matches,
      window_prefers_dark: win.matchMedia("(prefers-color-scheme: dark)").matches,
      ui_systemUsesDarkTheme: Services.prefs.getIntPref("ui.systemUsesDarkTheme"),
      theme: Services.prefs.getStringPref("extensions.activeThemeID", ""),
      dark_reader: Services.prefs.getBoolPref("mail.dark-reader.enabled", false),
    },
    settleMs: Date.now() - t0,
  };
})().then(done, (e) => done({ error: String(e) }));
`;

const CLOSE = `
const [key, done] = arguments;
const { MailServices } = ChromeUtils.importESModule("resource:///modules/MailServices.sys.mjs");
for (const w of [...Services.wm.getEnumerator("mail:messageWindow")]) w.close();
try {
  // The account is retired, not removed: removing an account and its
  // files while the next one is created under the same host name left
  // the next capture with an empty INBOX or a message that never loaded
  // (measured). A retired account keeps no connection and never checks
  // for mail; the profile lives only as long as the session.
  const account = key ? MailServices.accounts.getAccount(key) : null;
  if (account) account.incomingServer.closeCachedConnections();
  done({ accounts: MailServices.accounts.accounts.length });
} catch (e) { done({ error: String(e) }); }
`;

function checked<T extends Record<string, unknown>>(
  v: unknown,
  step: string,
): T {
  if (typeof v !== "object" || v === null)
    throw new Error(`thunderbird: ${step}: no answer`);
  const r = v as Record<string, unknown>;
  if (typeof r.error === "string")
    throw new Error(`thunderbird: ${step}: ${r.error}`);
  return r as T;
}

interface Measured {
  body: { x: number; y: number; width: number; height: number };
  contentHeight: number;
  contentWidth: number;
  window: { inner: [number, number]; dpr: number };
  images: { url: string; loaded: boolean }[];
  imagesComplete: boolean;
  subject: string;
  scheme: {
    message_prefers_dark: boolean;
    window_prefers_dark: boolean;
    ui_systemUsesDarkTheme: number;
    theme: string;
    dark_reader: boolean;
  };
  settleMs: number;
  [k: string]: unknown;
}

class ThunderbirdInstance implements DesktopClientInstance {
  private scheme: Scheme | null = null;
  private account: string | null = null;
  readonly timingMs: Record<string, number>;
  private readonly session: DesktopSession;
  private readonly m: Marionette;
  private readonly main: SwayWindow;

  constructor(
    session: DesktopSession,
    m: Marionette,
    main: SwayWindow,
    timingMs: Record<string, number>,
  ) {
    this.session = session;
    this.m = m;
    this.main = main;
    this.timingMs = timingMs;
  }

  async open(req: OpenRequest): Promise<OpenedMessage> {
    const timing: Record<string, number> = {};
    const t = (): number => performance.now();
    const dark = req.scheme === "dark";
    if (req.scheme !== "light" && req.scheme !== "dark")
      throw new Error(`thunderbird: no ${req.scheme} scheme`);

    let ts = t();
    if (this.scheme !== req.scheme) {
      checked(
        await this.m.asyncScript(SET_SCHEME, [dark, LIGHT_THEME, DARK_THEME]),
        "scheme",
      );
      this.scheme = req.scheme;
    }
    timing.scheme = t() - ts;

    const a = req.account;
    const synced = checked<{
      key: string;
      rc: number;
      count: number;
      updates: number;
      subject: string | null;
      configureMs: number;
      syncMs: number;
    }>(
      await this.m.asyncScript(CONFIGURE_AND_SYNC, [
        a.user,
        a.password,
        a.host,
        a.port,
      ]),
      "account",
    );
    this.account = synced.key;
    timing.configure = synced.configureMs;
    timing.sync = synced.syncMs;
    timing.sync_updates = synced.updates;
    if (synced.rc !== 0 || synced.count !== 1)
      throw new Error(
        `thunderbird: the INBOX of ${a.user} holds ${synced.count} message(s) after the fetch (status ${synced.rc}), expected exactly one`,
      );

    ts = t();
    const before = new Set(this.session.windows().map((w) => w.id));
    checked(await this.m.asyncScript(OPEN_FIRST, [synced.key]), "open");
    const win = await this.session.waitForWindow(
      (w) => w.appId === THUNDERBIRD_APP_ID && !before.has(w.id),
      "Thunderbird message window",
      STEP_TIMEOUT_MS,
    );
    await this.session.fullscreen(win.id);
    timing.open = t() - ts;

    // Settle and measure; grow the output until the body is not
    // clipped (a scrolling message pane would cut the capture).
    ts = t();
    let measured: Measured | null = null;
    for (let i = 0; i < 4; i++) {
      const out = this.session.output;
      measured = checked<Measured>(
        await this.m.asyncScript(SETTLE_AND_MEASURE, [out.width, out.height]),
        "settle",
      );
      const missing = Math.ceil(measured.contentHeight - measured.body.height);
      if (missing <= 0) break;
      const height = Math.min(MAX_OUTPUT_HEIGHT, out.height + missing);
      if (height === out.height) break;
      this.session.setOutput({ ...out, height });
      await this.session.waitForWindow(
        (w) => w.id === win.id && w.rect.height === height,
        `the message window at height ${height}`,
        STEP_TIMEOUT_MS,
      );
    }
    timing.settle = t() - ts;
    const m = measured!;
    const placed = this.session.windows().find((w) => w.id === win.id);
    const origin = placed?.rect ?? { x: 0, y: 0 };
    return {
      body: {
        x: origin.x + m.body.x,
        y: origin.y + m.body.y,
        width: m.body.width,
        height: m.body.height,
      },
      subject: m.subject,
      scheme: {
        // Dark only when the message, the window and the theme all are;
        // light only when none is. A mixed state is reported as the
        // opposite of what was asked, so it fails the capture.
        dark: dark
          ? m.scheme.message_prefers_dark &&
            m.scheme.window_prefers_dark &&
            m.scheme.theme === DARK_THEME
          : m.scheme.message_prefers_dark ||
            m.scheme.window_prefers_dark ||
            m.scheme.theme !== LIGHT_THEME,
        evidence: m.scheme,
      },
      images: m.images,
      detail: {
        account_key: synced.key,
        window: {
          sway_id: win.id,
          title: placed?.name ?? win.name,
          rect: placed?.rect ?? null,
          inner: m.window.inner,
          dpr: m.window.dpr,
        },
        content: { height: m.contentHeight, width: m.contentWidth },
        images_complete: m.imagesComplete,
        main_window: this.main.id,
      },
      timingMs: timing,
    };
  }

  async close(): Promise<void> {
    const key = this.account;
    this.account = null;
    checked(await this.m.asyncScript(CLOSE, [key]), "close");
    await this.session.waitForWindow(
      () =>
        this.session.windows().filter((w) => w.appId === THUNDERBIRD_APP_ID)
          .length === 1,
      "the message window to close",
      STEP_TIMEOUT_MS,
    );
  }

  async quit(): Promise<void> {
    this.m.close();
  }
}

export class ThunderbirdDriver implements DesktopClientDriver {
  readonly clientId = "thunderbird";
  // The real Thunderbird is the thunderbird audience family's client.
  readonly family = "thunderbird";
  readonly engine = "gecko" as const;
  readonly viewports = THUNDERBIRD_VIEWPORTS;
  readonly schemes = THUNDERBIRD_SCHEMES;

  requirements(): Requirement[] {
    return [
      {
        kind: "binary",
        name: "thunderbird",
        why: "the Thunderbird client (the dev shell provides it)",
      },
    ];
  }

  version(env: Record<string, string | undefined>): string {
    const bin = findExecutable("thunderbird", { ...currentHost(), env });
    if (bin === null) throw new Error("thunderbird is not on PATH");
    const r = spawnSync(bin, ["--version"], {
      encoding: "utf8",
      env: { PATH: env.PATH ?? "", HOME: env.HOME ?? "" },
    });
    const v = /Thunderbird (\S+)/.exec(r.stdout ?? "")?.[1];
    if (v === undefined)
      throw new Error(
        `cannot read Thunderbird's version: ${(r.stdout ?? "").trim()} ${(r.stderr ?? "").trim()}`,
      );
    return v;
  }

  sessionEnv(): Record<string, string> {
    return {
      MOZ_ENABLE_WAYLAND: "1",
      GDK_BACKEND: "wayland",
      MOZ_CRASHREPORTER_DISABLE: "1",
    };
  }

  async launch(
    session: DesktopSession,
    ctx: DriverLaunchCtx,
  ): Promise<DesktopClientInstance> {
    const t0 = performance.now();
    const bin = findExecutable("thunderbird", currentHost());
    if (bin === null) throw new Error("thunderbird is not on PATH");
    const port = await freePort();
    const proxy = new URL(ctx.assets.baseUrl);
    const profile = join(session.home, "thunderbird-profile");
    mkdirSync(profile, { mode: 0o700 });
    writeFileSync(
      join(profile, "user.js"),
      thunderbirdUserJs({
        marionettePort: port,
        proxyHost: proxy.hostname,
        proxyPort: Number(proxy.port),
      }),
    );
    session.launch("thunderbird", [
      bin,
      "--profile",
      profile,
      "--no-remote",
      "--marionette",
      "--remote-allow-system-access",
    ]);
    // Marionette listens on the session's own loopback; it is reached
    // through the session's bridge.
    const m = await Marionette.connect(
      port,
      START_TIMEOUT_MS,
      () => session.connectInner(port),
      `port ${port} inside the session`,
    );
    try {
      await m.send("WebDriver:NewSession", { capabilities: {} });
      await m.send("Marionette:SetContext", { value: "chrome" });
      const main = await session.waitForWindow(
        (w) => w.appId === THUNDERBIRD_APP_ID,
        "the Thunderbird main window",
        START_TIMEOUT_MS,
      );
      const origins = [
        new URL(ctx.assets.baseUrl).origin,
        ...ctx.extraRemoteOrigins,
      ];
      const granted = (await m.script(GRANT_REMOTE_CONTENT, [
        origins,
      ])) as number[];
      if (!granted.every((g) => g === 1))
        throw new Error(
          `thunderbird: remote content could not be allowed for ${origins.join(", ")}`,
        );
      return new ThunderbirdInstance(session, m, main, {
        launch: performance.now() - t0,
      });
    } catch (err) {
      m.close();
      throw err;
    }
  }
}
