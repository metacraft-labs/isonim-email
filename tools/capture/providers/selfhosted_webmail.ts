// tools/capture/providers/selfhosted_webmail.ts — the selfhosted-webmail
// capture provider: real webmail sanitisers (Roundcube, SnappyMail)
// rendered in the dev shell's pinned Chromium.
//
// For every capture the story's MIME is delivered into a fresh
// one-message IMAP account (the imap service, with the story asset
// origin rewritten to the assets service), Playwright logs that account
// in to the webmail, opens the only message and screenshots the
// message-body element, nothing around it. The webmails run on php-fpm
// behind caddy as the user, on loopback (webmail_servers.ts).
//
// What a capture may load: the webmail's own origin and the assets
// service; every other request of the page is aborted and listed in the
// provenance (network.blocked), and PHP's own outbound HTTP goes through
// the assets service's egress guard. A capture fails, never passes
// quietly, when:
// - a locator this file relies on matches nothing or more than one
//   element (a webmail UI change), naming the locator;
// - the login does not reach the mailbox, or the opened message is not
//   the delivered one (subject check);
// - the requested colour scheme is not the one the webmail applied;
// - an image the story contains was not served 200 by the assets
//   service (a sanitiser or image proxy that drops or breaks images).
//
// Warm (the default): the servers start once per run, in prepare(), and
// each (webmail, viewport, scheme) keeps one browser context for the
// whole run; a capture clears its cookies and logs in as its own fresh
// account. --cold: fresh servers (fresh databases and data folders) and
// a fresh browser context for every capture, one capture at a time.

import { join } from "node:path";
import { pathToFileURL } from "node:url";
import type { Browser, BrowserContext, Locator, Page } from "playwright-core";
import { FIXTURE_HOST } from "../fixture_host.ts";
import { launchOptions } from "../launch.ts";
import { assetsHandle, splitCaptureToken } from "./assets_service.ts";
import { resolveDriver } from "./browser_emulation.ts";
import { imapHandle } from "./imap_service.ts";
import type {
  AssetsHandle,
  CaptureProvider,
  CaptureRequest,
  CaptureResult,
  ClientDescriptor,
  Emulation,
  ImapHandle,
  ProviderHealth,
  Requirement,
  Scheme,
  SessionCtx,
  Sha256,
  StoryMessage,
  ViewportSpec,
} from "./types.ts";
import {
  ROUNDCUBE_ENV,
  roundcubeVersion,
  SNAPPYMAIL_ENV,
  SNAPPYMAIL_THEMES,
  snappymailVersion,
  type WebmailEndpoints,
  WebmailServers,
  type WebmailServersOptions,
} from "./webmail_servers.ts";

export const SELFHOSTED_WEBMAIL_ID = "selfhosted-webmail";
// Bump whenever output can change for reasons no other key field
// captures (the webmail and browser versions are in client_build).
export const SELFHOSTED_WEBMAIL_VERSION = "1";
// Bump by hand when crop, wait or login logic changes.
export const SELFHOSTED_WEBMAIL_ADAPTER_VERSION = 1;

export type WebmailClient = "roundcube" | "snappymail";
export const WEBMAIL_CLIENTS: readonly WebmailClient[] = [
  "roundcube",
  "snappymail",
];

// Measured: both skins lay out at the phone and the desktop widths of
// the capture matrix (Roundcube's Elastic switches to its phone layout,
// SnappyMail shows the message full width with its preview pane off).
// Other widths are untested and not offered.
export const WEBMAIL_VIEWPORTS: ViewportSpec[] = [
  { name: "mobile", width: 375, dpr: 3 },
  { name: "desktop", width: 800, dpr: 1 },
];
// Roundcube's Elastic skin follows the browser's prefers-color-scheme
// (html.dark-mode); SnappyMail has no automatic dark mode, so its dark
// scheme is its dark theme. Neither has a forced-dark mode.
export const WEBMAIL_SCHEMES: Scheme[] = ["light", "dark"];

const STEP_TIMEOUT_MS = 20000;
const IMAGE_TIMEOUT_MS = 10000;
const VIEWPORT_HEIGHT = 800;

// The selectors the drivers rely on. Every one must match exactly one
// element where it is used; anything else fails the capture naming it.
export interface WebmailLocators {
  user: string;
  password: string;
  submit: string | null;
  listItem: string | null;
  subject: string;
  body: string;
  // Inside `body`: present once the message HTML has been inserted.
  bodyReady: string | null;
}

export const DEFAULT_LOCATORS: Record<WebmailClient, WebmailLocators> = {
  roundcube: {
    user: "#rcmloginuser",
    password: "#rcmloginpwd",
    submit: "#rcmloginsubmit",
    listItem: null,
    subject: "h2.subject",
    body: "#messagebody",
    bodyReady: ".message-htmlpart, .message-part",
  },
  snappymail: {
    user: 'input[name="Email"]',
    password: 'input[name="Password"]',
    submit: null,
    listItem: ".messageListItem",
    subject: "#V-MailMessageView .subject",
    body: "#messageItem .bodyText",
    bodyReady: ".b-text-part",
  },
};

export interface SelfhostedWebmailOptions {
  env?: Record<string, string | undefined>;
  // Test seam (see selfhosted_webmail.test.ts): replace locators to
  // show that a UI the drivers do not recognise fails loudly.
  locators?: Partial<Record<WebmailClient, Partial<WebmailLocators>>>;
  // Passed to every WebmailServers this provider starts.
  servers?: WebmailServersOptions;
}

type Playwright = typeof import("playwright-core");

class CaptureError extends Error {}

function isWebmailClient(c: string): c is WebmailClient {
  return (WEBMAIL_CLIENTS as readonly string[]).includes(c);
}

// The Subject header of a message (unfolded); null when it is
// encoded-word (=?…?=) and so not comparable as text.
export function subjectOf(mime: Uint8Array): string | null {
  const text = Buffer.from(mime).toString("latin1");
  const head = text.split(/\r?\n\r?\n/, 1)[0] ?? "";
  const m = /^Subject:[ \t]*(.*(?:\r?\n[ \t].*)*)/im.exec(head);
  if (m === null || m[1] === undefined) return null;
  const v = m[1].replace(/\r?\n[ \t]/g, " ").trim();
  return v.includes("=?") ? null : v;
}

function decodeEntities(s: string): string {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_m, h: string) =>
      String.fromCodePoint(parseInt(h, 16)),
    )
    .replace(/&#(\d+);/g, (_m, d: string) => String.fromCodePoint(Number(d)))
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

// The story asset paths (/{hash}/{name}) of every <img src> a browser
// renders from the story HTML: comments, and so the MSO-only
// conditional blocks, are left out.
export function storyImagePaths(html: string): string[] {
  const visible = html.replace(/<!--[\s\S]*?-->/g, "");
  const out: string[] = [];
  const origin = `${FIXTURE_HOST}/`;
  for (const m of visible.matchAll(
    /<img\b[^>]*?\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi,
  )) {
    const url = decodeEntities((m[1] ?? m[2] ?? m[3] ?? "").trim());
    if (url.toLowerCase().startsWith(origin)) {
      const path = `/${url.slice(origin.length)}`.split(/[?#]/)[0]!;
      if (!out.includes(path)) out.push(path);
    }
  }
  return out;
}

// The part of the DOM the in-page image checks use (the type-check
// has no DOM library).
interface ImgHost {
  querySelectorAll(s: "img"): ArrayLike<{ loading: string; complete: boolean }>;
}

interface Blocked {
  url: string;
  reason: "network";
}

interface AssetResponse {
  url: string;
  status: number;
}

// One browser context with its network policy and its logs.
interface Session {
  context: BrowserContext;
  page: Page;
  origin: string;
  blocked: Blocked[];
  assets: AssetResponse[];
}

interface Servers {
  instance: WebmailServers;
  endpoints: WebmailEndpoints;
}

export class SelfhostedWebmailProvider implements CaptureProvider {
  readonly id = SELFHOSTED_WEBMAIL_ID;
  readonly backend = SELFHOSTED_WEBMAIL_ID;
  readonly version = SELFHOSTED_WEBMAIL_VERSION;
  readonly adapterVersion = SELFHOSTED_WEBMAIL_ADAPTER_VERSION;
  // Messages reach the webmail through the IMAP store, injected.
  readonly via = "inject";

  private readonly env: Record<string, string | undefined>;
  private readonly locators: Record<WebmailClient, WebmailLocators>;
  private readonly serverOptions: WebmailServersOptions;
  private pw: Playwright | null = null;
  private browser: Browser | null = null;
  private imap: ImapHandle | null = null;
  private assets: AssetsHandle | null = null;
  private versions: Record<WebmailClient, string> | null = null;
  // Warm servers (null when cold or not prepared).
  private servers: Servers | null = null;
  private readonly sessions = new Map<string, Session>();
  private run = "";
  private coldSeq = 0;

  constructor(opts: SelfhostedWebmailOptions = {}) {
    this.env = opts.env ?? process.env;
    this.locators = {
      roundcube: { ...DEFAULT_LOCATORS.roundcube, ...opts.locators?.roundcube },
      snappymail: {
        ...DEFAULT_LOCATORS.snappymail,
        ...opts.locators?.snappymail,
      },
    };
    this.serverOptions = { env: this.env, ...opts.servers };
  }

  clients(): ClientDescriptor[] {
    return WEBMAIL_CLIENTS.map((client) => ({
      clientId: client,
      // A real sanitiser that stands in for no audience family.
      family: "verification",
      engine: "blink",
      build: async () => this.build(client),
      viewports: WEBMAIL_VIEWPORTS,
      schemes: WEBMAIL_SCHEMES,
      imagesOff: false,
      approximation: false,
    }));
  }

  // The webmail version and the browser that renders it: both decide
  // the pixels. "" before prepare().
  private build(client: WebmailClient): string {
    if (this.versions === null || this.browser === null) return "";
    return `${client}-${this.versions[client]}+chromium-${this.browser.version()}`;
  }

  requirements(): Requirement[] {
    const reqs: Requirement[] = [
      {
        kind: "host-os",
        os: ["linux", "darwin"],
        why: "php-fpm, caddy and the pinned Playwright browsers run on Linux and macOS",
      },
      {
        kind: "binary",
        name: "php-fpm",
        why: "runs Roundcube and SnappyMail",
      },
      { kind: "binary", name: "caddy", why: "serves the webmails on loopback" },
      {
        kind: "env-dir",
        variable: ROUNDCUBE_ENV,
        why: "the Roundcube tree (the dev shell sets it)",
      },
      {
        kind: "env-dir",
        variable: SNAPPYMAIL_ENV,
        why: "the SnappyMail tree (the dev shell sets it)",
      },
      {
        kind: "env-dir",
        variable: "PLAYWRIGHT_BROWSERS_PATH",
        why: "the dev shell's pinned browser builds; browsers are never downloaded (run under `nix develop`)",
      },
      {
        kind: "service",
        name: "imap",
        why: "each capture logs in to a fresh one-message account",
      },
      {
        kind: "service",
        name: "assets",
        why: "the story images, and the egress guard for PHP's outbound HTTP",
      },
    ];
    if (process.platform === "linux")
      reqs.push(
        {
          kind: "binary",
          name: "setpriv",
          why: "the webmail servers die with the run (parent-death signal)",
        },
        {
          kind: "binary",
          name: "unshare",
          why: "php-fpm's workers die with it (a PID namespace of its own)",
        },
      );
    return reqs;
  }

  async health(): Promise<ProviderHealth> {
    const driver = resolveDriver(this.env);
    if ("reason" in driver)
      return { state: "unavailable", reason: driver.reason };
    try {
      roundcubeVersion(this.env[ROUNDCUBE_ENV] ?? "");
      snappymailVersion(this.env[SNAPPYMAIL_ENV] ?? "");
    } catch (err) {
      return {
        state: "unavailable",
        reason: err instanceof Error ? err.message : String(err),
      };
    }
    return { state: "ok" };
  }

  async prepare(ctx: SessionCtx): Promise<void> {
    this.imap = imapHandle(ctx.services.imap);
    this.assets = assetsHandle(ctx.services.assets);
    this.run = ctx.run;
    this.versions = {
      roundcube: roundcubeVersion(this.env[ROUNDCUBE_ENV] ?? ""),
      snappymail: snappymailVersion(this.env[SNAPPYMAIL_ENV] ?? ""),
    };
    if (this.pw === null) {
      const driver = resolveDriver(this.env);
      if ("reason" in driver) throw new Error(driver.reason);
      const pw: Playwright = await import(
        pathToFileURL(join(driver.dir, "index.mjs")).href
      );
      this.pw = pw;
    }
    if (this.browser === null)
      this.browser = await this.pw.chromium.launch(
        launchOptions("chromium", false, process.platform, this.env),
      );
    if (!ctx.cold && this.servers === null)
      this.servers = await this.startServers(ctx.run);
  }

  private async startServers(run: string): Promise<Servers> {
    const imap = this.imap!;
    const instance = new WebmailServers(this.serverOptions);
    const endpoints = await instance.start({
      run,
      imap: { host: imap.host, port: imap.port },
      proxy: this.assets!.baseUrl,
    });
    return { instance, endpoints };
  }

  emulation(_req: CaptureRequest): Emulation {
    return { transformVersion: "", detail: null };
  }

  private origin(
    endpoints: WebmailEndpoints,
    client: WebmailClient,
    scheme: Scheme,
  ): string {
    if (client === "roundcube") return endpoints.roundcube;
    return scheme === "dark"
      ? endpoints.snappymail.dark
      : endpoints.snappymail.light;
  }

  private async newSession(
    origin: string,
    req: CaptureRequest,
  ): Promise<Session> {
    const assetsOrigin = new URL(this.assets!.baseUrl).origin;
    const context = await this.browser!.newContext({
      viewport: { width: req.viewport.width, height: VIEWPORT_HEIGHT },
      deviceScaleFactor: req.viewport.dpr,
      colorScheme: req.scheme === "dark" ? "dark" : "light",
      timezoneId: "UTC",
      locale: "en-US",
    });
    const session: Session = {
      context,
      page: await context.newPage(),
      origin,
      blocked: [],
      assets: [],
    };
    // The webmail's own origin, the assets service and inline data:
    // and blob: URLs load; everything else is aborted and recorded.
    await context.route("**/*", async (route) => {
      const url = route.request().url();
      let allowed = url.startsWith("data:") || url.startsWith("blob:");
      if (!allowed)
        try {
          const o = new URL(url).origin;
          allowed = o === origin || o === assetsOrigin;
        } catch {
          allowed = false;
        }
      if (allowed) {
        await route.continue();
        return;
      }
      session.blocked.push({ url, reason: "network" });
      await route.abort("blockedbyclient");
    });
    session.page.on("response", (res) => {
      const url = res.url();
      if (url.startsWith(`${assetsOrigin}/`))
        session.assets.push({ url, status: res.status() });
    });
    return session;
  }

  async *capture(
    batch: CaptureRequest[],
    messages: Map<Sha256, StoryMessage>,
    ctx: SessionCtx,
  ): AsyncIterable<CaptureResult> {
    // Warm: one worker per webmail (each webmail's captures in order,
    // the two webmails at once). Cold: one capture at a time.
    const queues: CaptureRequest[][] = ctx.cold
      ? [batch]
      : WEBMAIL_CLIENTS.map((c) => batch.filter((r) => r.clientId === c));
    const ready: CaptureResult[] = [];
    let wake: (() => void) | null = null;
    let running = 0;
    const worker = async (queue: CaptureRequest[]): Promise<void> => {
      for (const req of queue) {
        let result: CaptureResult;
        try {
          result = await this.captureOne(req, messages, ctx.cold);
        } catch (err) {
          result = {
            request: req,
            status: "failed",
            reason: err instanceof Error ? err.message : String(err),
            provenance: {},
          };
        }
        ready.push(result);
        wake?.();
      }
    };
    const work = queues
      .filter((q) => q.length > 0)
      .map(async (q) => {
        running++;
        try {
          await worker(q);
        } finally {
          running--;
          wake?.();
        }
      });
    const all = Promise.all(work);
    for (;;) {
      const next = ready.shift();
      if (next !== undefined) {
        yield next;
        continue;
      }
      if (running === 0) break;
      await new Promise<void>((r) => {
        wake = r;
      });
      wake = null;
    }
    await all;
  }

  private async captureOne(
    req: CaptureRequest,
    messages: Map<Sha256, StoryMessage>,
    cold: boolean,
  ): Promise<CaptureResult> {
    const t0 = performance.now();
    const timing: Record<string, number> = {};
    const provenance: Record<string, unknown> = { timing_ms: timing };
    const fail = (reason: string): CaptureResult => {
      timing.total = performance.now() - t0;
      timing.capture ??= 0;
      return { request: req, status: "failed", reason, provenance };
    };
    if (!isWebmailClient(req.clientId))
      return fail(`unknown webmail client '${req.clientId}'`);
    const client = req.clientId;
    const message = messages.get(req.mimeSha256);
    if (message === undefined)
      return fail(`no message for ${req.story} (${req.mimeSha256})`);
    const imap = this.imap!;
    const assets = this.assets!;

    // The servers: the run's (warm) or this capture's own (cold).
    let own: Servers | null = null;
    let servers = this.servers;
    let session: Session | null = null;
    try {
      if (cold || servers === null) {
        const ts = performance.now();
        own = await this.startServers(`${this.run}-c${++this.coldSeq}`);
        servers = own;
        timing.servers = performance.now() - ts;
      }
      const origin = this.origin(servers.endpoints, client, req.scheme);
      provenance.servers = {
        warm: own === null,
        php: servers.endpoints.versions.php,
        caddy: servers.endpoints.versions.caddy,
      };
      provenance.client = {
        webmail: client,
        webmail_version: this.versions![client],
        browser: `chromium ${this.browser!.version()}`,
        ...(client === "snappymail"
          ? {
              theme:
                SNAPPYMAIL_THEMES[req.scheme === "dark" ? "dark" : "light"],
            }
          : {}),
      };

      // A fresh one-message mailbox.
      const assetsBefore = assets.requests().length;
      const delivery = await imap.mailboxFor(message.mime, { assets });
      timing.account = delivery.timingMs.account;
      timing.inject = delivery.timingMs.inject;
      (provenance.client as Record<string, unknown>).account =
        delivery.account.user;
      provenance.asset_rewrite =
        delivery.assetRewrite === null
          ? null
          : {
              ...delivery.assetRewrite,
              injected_sha256: delivery.injectedSha256,
            };

      // The browser context: the run's for this (webmail, viewport,
      // scheme), or a fresh one.
      const key = `${client}|${req.viewport.name}|${req.scheme}`;
      if (own === null) {
        session = this.sessions.get(key) ?? null;
        if (session === null) {
          session = await this.newSession(origin, req);
          this.sessions.set(key, session);
        }
        await session.context.clearCookies();
        await session.page.setViewportSize({
          width: req.viewport.width,
          height: VIEWPORT_HEIGHT,
        });
      } else session = await this.newSession(origin, req);
      const page = session.page;
      const blockedBefore = session.blocked.length;
      const assetResponsesBefore = session.assets.length;
      const loc = this.locators[client];

      const tLogin = performance.now();
      await this.login(client, page, origin, loc, delivery.account);
      timing.login = performance.now() - tLogin;

      const tOpen = performance.now();
      const body = await this.open(client, page, origin, loc);
      const subject = subjectOf(message.mime);
      const shown =
        (await (
          await this.exactlyOne(page, loc.subject, "subject", client)
        ).textContent()) ?? "";
      if (subject !== null && !shown.includes(subject))
        throw new CaptureError(
          `${client}: the opened message is not the delivered one (subject shown: '${shown.trim()}', delivered: '${subject}')`,
        );
      timing.open = performance.now() - tOpen;

      // The scheme the webmail applied.
      const dark = (await page.evaluate(
        client === "roundcube"
          ? "document.documentElement.classList.contains('dark-mode')"
          : "getComputedStyle(document.documentElement).colorScheme === 'dark'",
      )) as boolean;
      provenance.scheme_applied = {
        dark,
        evidence:
          client === "roundcube"
            ? "html.dark-mode (Elastic follows prefers-color-scheme)"
            : `color-scheme of theme ${SNAPPYMAIL_THEMES[req.scheme === "dark" ? "dark" : "light"]}`,
      };
      if (dark !== (req.scheme === "dark"))
        throw new CaptureError(
          `${client}: requested ${req.scheme} but the webmail shows ${dark ? "dark" : "light"}`,
        );

      // Settle: fonts, then every image in the body (lazy images are
      // made eager so the whole body loads, not only what is in view).
      const tSettle = performance.now();
      const lazy = (await body.evaluate((el: ImgHost) => {
        let n = 0;
        for (const img of Array.from(el.querySelectorAll("img")))
          if (img.loading === "lazy") {
            img.loading = "eager";
            n++;
          }
        return n;
      })) as number;
      await page.evaluate("document.fonts.ready.then(() => true)");
      const settled = await this.imagesComplete(body);
      timing.settle = performance.now() - tSettle;

      // The images the story contains, against what the assets service
      // served this page for this capture's copy: the page's responses
      // under the delivery's token, each also in the service's own log
      // under that token (the other webmail loads the same paths at
      // the same time, under its own).
      const token = delivery.assetRewrite?.token ?? null;
      const mine = token === null ? [] : assets.requestsFor(token);
      const expected = storyImagePaths(message.html);
      const served = session.assets.slice(assetResponsesBefore).map((a) => {
        const t = splitCaptureToken(new URL(a.url).pathname);
        return { path: t.path, token: t.token, status: a.status };
      });
      const missing = expected.filter(
        (p) =>
          !served.some(
            (s) => s.path === p && s.token === token && s.status === 200,
          ) || !mine.some((e) => e.url === p && e.status === 200),
      );
      provenance.images = {
        expected,
        served,
        missing,
        lazy_made_eager: lazy,
        all_complete: settled,
        ...(expected.length === 0
          ? { note: "the story loads no story image" }
          : {}),
      };
      // This capture's asset requests in the service's log (its token's),
      // and every request the egress guard refused while it ran (PHP's
      // outbound HTTP goes through the guard; a refusal carries no
      // token, so with both webmails capturing at once it can include
      // the other one's).
      provenance.assets_log = mine;
      provenance.assets_refused = assets
        .requests()
        .slice(assetsBefore)
        .filter((e) => e.kind === "blocked");
      provenance.network = {
        policy: "webmail-and-assets-only",
        blocked: session.blocked.slice(blockedBefore),
      };
      provenance.sanitised_html = (await body.evaluate(
        (el) => el.outerHTML,
      )) as string;
      if (req.images === "on" && missing.length > 0)
        throw new CaptureError(
          `${client}: image(s) the story contains were not served 200 by the assets service: ${missing.join(", ")}`,
        );
      if (!settled)
        throw new CaptureError(
          `${client}: an image in the message body never finished loading within ${IMAGE_TIMEOUT_MS} ms`,
        );

      // The crop: the message body element. A body taller than the
      // window grows the window, so no scroll container clips it.
      const tCap = performance.now();
      let box = await body.boundingBox();
      if (box === null)
        throw new CaptureError(`${client}: the message body has no box`);
      const need = Math.ceil(box.y + box.height + 16);
      let viewportHeight = VIEWPORT_HEIGHT;
      if (need > VIEWPORT_HEIGHT) {
        viewportHeight = need;
        await page.setViewportSize({
          width: req.viewport.width,
          height: viewportHeight,
        });
        box = (await body.boundingBox()) ?? box;
      }
      const png = await body.screenshot({
        animations: "disabled",
        caret: "hide",
      });
      timing.capture = performance.now() - tCap;
      provenance.crop = {
        selector: loc.body,
        x: box.x,
        y: box.y,
        width: box.width,
        height: box.height,
        viewport_height: viewportHeight,
      };
      timing.total = performance.now() - t0;
      return { request: req, status: "done", png, provenance };
    } catch (err) {
      return fail(err instanceof Error ? err.message : String(err));
    } finally {
      if (own !== null) {
        if (session !== null) await session.context.close().catch(() => {});
        await own.instance.stop();
      }
    }
  }

  // Waits for `selector` and requires it to match exactly one element.
  private async exactlyOne(
    page: Page | Locator,
    selector: string,
    name: string,
    client: WebmailClient,
    state: "visible" | "attached" = "visible",
  ): Promise<Locator> {
    const l = page.locator(selector);
    try {
      await l.first().waitFor({ state, timeout: STEP_TIMEOUT_MS });
    } catch {
      throw new CaptureError(
        `${client}: locator '${name}' (${selector}) matched no ${state} element within ${STEP_TIMEOUT_MS / 1000} s (a webmail UI change?)`,
      );
    }
    const n = await l.count();
    if (n !== 1)
      throw new CaptureError(
        `${client}: locator '${name}' (${selector}) matched ${n} elements, expected exactly one`,
      );
    return l;
  }

  private async login(
    client: WebmailClient,
    page: Page,
    origin: string,
    loc: WebmailLocators,
    account: { user: string; password: string },
  ): Promise<void> {
    await page.goto(
      client === "roundcube" ? `${origin}/?_task=login` : `${origin}/`,
      { timeout: STEP_TIMEOUT_MS },
    );
    const user = await this.exactlyOne(page, loc.user, "user", client);
    const pass = await this.exactlyOne(page, loc.password, "password", client);
    await user.fill(account.user);
    await pass.fill(account.password);
    if (loc.submit !== null) {
      const submit = await this.exactlyOne(page, loc.submit, "submit", client);
      await submit.click();
    } else await pass.press("Enter");
    if (client === "roundcube") {
      try {
        await page.waitForURL(/[?&]_task=mail/, { timeout: STEP_TIMEOUT_MS });
      } catch {
        const why = await page
          .locator("#messagestack")
          .textContent()
          .catch(() => null);
        throw new CaptureError(
          `roundcube: the login did not reach the mailbox (at ${page.url()}${why ? `: ${why.trim()}` : ""})`,
        );
      }
    }
  }

  private async open(
    client: WebmailClient,
    page: Page,
    origin: string,
    loc: WebmailLocators,
  ): Promise<Locator> {
    if (client === "roundcube")
      // The only message of a fresh mailbox has UID 1.
      await page.goto(`${origin}/?_task=mail&_mbox=INBOX&_uid=1&_action=show`, {
        timeout: STEP_TIMEOUT_MS,
      });
    if (loc.listItem !== null) {
      const item = await this.exactlyOne(
        page,
        loc.listItem,
        "list item",
        client,
      );
      await item.click();
    }
    const body = await this.exactlyOne(page, loc.body, "body", client);
    if (loc.bodyReady !== null)
      await this.exactlyOne(
        body,
        loc.bodyReady,
        "body ready",
        client,
        "attached",
      );
    return body;
  }

  private async imagesComplete(body: Locator): Promise<boolean> {
    const t0 = Date.now();
    for (;;) {
      const done = (await body.evaluate((el: ImgHost) =>
        Array.from(el.querySelectorAll("img")).every((i) => i.complete),
      )) as boolean;
      if (done) return true;
      if (Date.now() - t0 >= IMAGE_TIMEOUT_MS) return false;
      await new Promise((r) => setTimeout(r, 50));
    }
  }

  async dispose(): Promise<void> {
    for (const s of this.sessions.values())
      await s.context.close().catch(() => {});
    this.sessions.clear();
    await this.browser?.close().catch(() => {});
    this.browser = null;
    if (this.servers !== null) await this.servers.instance.stop();
    this.servers = null;
  }
}
