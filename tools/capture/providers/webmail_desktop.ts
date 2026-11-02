// tools/capture/providers/webmail_desktop.ts — the hosted-webmail
// captures' hands and eyes: the webmail browser on one QA account's
// profile, in a private GuiAssert session of its own, driven the way a
// person drives it.
//
// - The session: `guiassert session-start --kind headless
//   --session-backend linux-xvfb` at the capture window's size; stopped
//   with the browser.
// - The browser: the dev shell's webmail browser started normally by the
//   launcher the sign-in uses (webmail_browser.ts: no Playwright, no
//   DevTools, no automation switch, the sandbox checked), on the whole
//   display, its profile's colour mode light or dark (webmail_profiles.ts
//   `colorSchemePrefs`).
// - Navigation: typed into the browser's own address bar (a click on
//   it, ctrl+a, the URL on `type --stdin`, Delete to drop an inline
//   completion, Return; F5 when the address bar already holds the URL,
//   so a search is run again), never a page script.
// - Reading: the browser's accessibility tree (`guiassert tree`), the
//   address bar's value from it, OCR of the display.
// - Pixels: `guiassert screenshot --region` of the display.
// - Input: OS-level clicks (XTest in the session).
// Nothing is evaluated in a page and nothing in one is changed. Stopped
// with SIGINT (webmail_profiles.ts `stopBrowser`), so the browser writes
// its cookies.

import type { ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import {
  ADDRESS_BAR,
  addressBarValue,
  type Flat,
  flatten,
  sameLocation,
} from "./a11y_tree.ts";
import {
  type GaSession,
  type GuiAssert,
  GuiAssertError,
  type Rect,
  sessionEnv,
} from "./guiassert.ts";
import type { Scheme } from "./types.ts";
import { sessionSwitches, startWebmailBrowser } from "./webmail_browser.ts";
import { stopBrowser, type WebmailBrowser } from "./webmail_profiles.ts";

export interface DesktopOptions {
  /** A GuiAssert client (not yet in a session). */
  ga: GuiAssert;
  chrome: WebmailBrowser;
  userDataDir: string;
  /** The environment the session's environment is laid over. */
  env: Record<string, string | undefined>;
  width: number;
  height: number;
  scheme: Scheme;
  /** Where the browser starts. */
  startUrl: string;
  /** The session's name (unique per run and worker). */
  name: string;
  /** The tree read's node cap. */
  maxNodes?: number;
  /** A session with an owner-only VNC socket, to watch a capture. */
  vnc?: boolean;
  /** How long the browser's tree may take to appear (default 30 s). */
  treeReadyMs?: number;
  /** Test seam: the launcher (webmail_browser.ts `startWebmailBrowser`). */
  startBrowser?: typeof startWebmailBrowser;
}

/** One read of the browser: its tree, flattened, and its address. */
export interface Snapshot {
  flat: Flat[];
  location: string | null;
  truncated: boolean;
  nodes: number;
  ms: number;
}

/** The host cannot run a capture browser (no session, no sandbox). */
export class DesktopUnavailable extends Error {}

export class WebmailDesktop {
  readonly session: GaSession;
  readonly ga: GuiAssert;
  readonly argv: string[];
  readonly pid: number;
  /** The session display's size (the window fills it). */
  readonly width: number;
  readonly height: number;
  private readonly base: GuiAssert;
  private readonly child: ChildProcess;
  /** Where frames are written while read (each removed at once). */
  readonly framesDir: string;
  private readonly maxNodes: number;
  private n = 0;
  private closed = false;

  private constructor(o: {
    base: GuiAssert;
    session: GaSession;
    child: ChildProcess;
    argv: string[];
    framesDir: string;
    maxNodes: number;
    width: number;
    height: number;
  }) {
    this.base = o.base;
    this.session = o.session;
    this.ga = o.base.inSession(o.session.id);
    this.child = o.child;
    this.argv = o.argv;
    this.pid = o.child.pid!;
    this.framesDir = o.framesDir;
    this.maxNodes = o.maxNodes;
    this.width = o.width;
    this.height = o.height;
  }

  /** Starts the session and the browser in it; DesktopUnavailable when it cannot. */
  static async open(o: DesktopOptions): Promise<WebmailDesktop> {
    let session: GaSession;
    try {
      session = await o.ga.sessionStart({
        name: o.name,
        width: o.width,
        height: o.height,
        vncSocket: o.vnc === true,
      });
    } catch (err) {
      if (err instanceof GuiAssertError)
        throw new DesktopUnavailable(
          `no private display session: ${err.message}`,
        );
      throw err;
    }
    let child = null as ChildProcess | null;
    try {
      const started = await (o.startBrowser ?? startWebmailBrowser)({
        chrome: o.chrome,
        userDataDir: o.userDataDir,
        url: o.startUrl,
        env: sessionEnv(o.env, session),
        extra: sessionSwitches(o.width, o.height),
        scheme: o.scheme === "dark" ? "dark" : "light",
        unsafeNoSandbox: false,
        onChild: (c) => (child = c),
      });
      if (!started.ok) throw new DesktopUnavailable(started.reason);
      if (started.child.pid === undefined)
        throw new DesktopUnavailable("the webmail browser did not start");
      const desk = new WebmailDesktop({
        base: o.ga,
        session,
        child: started.child,
        argv: started.argv,
        framesDir: mkdtempSync(join(tmpdir(), "webmail-desktop-")),
        maxNodes: o.maxNodes ?? 20_000,
        width: o.width,
        height: o.height,
      });
      // The browser registers on the session's accessibility bus a moment
      // after it starts: until then its tree cannot be read.
      const deadline = Date.now() + (o.treeReadyMs ?? 30_000);
      for (;;) {
        try {
          await desk.snapshot();
          break;
        } catch (err) {
          const notYet =
            err instanceof GuiAssertError &&
            err.kind === "not-found" &&
            err.reason === "app";
          if (!notYet) throw err;
          if (Date.now() >= deadline) {
            await desk.close();
            throw new DesktopUnavailable(
              `the webmail browser's accessibility tree did not appear on the session's bus within ${Math.round((o.treeReadyMs ?? 30_000) / 1000)} s`,
            );
          }
          await sleep(250);
        }
      }
      return desk;
    } catch (err) {
      if (child !== null) await stopBrowser(child);
      await o.ga.sessionStop(session.id).catch(() => undefined);
      throw err;
    }
  }

  private frame(ext = "png"): string {
    return join(this.framesDir, `f${this.n++}.${ext}`);
  }

  /** The browser's accessibility tree and its address bar, read once. */
  async snapshot(): Promise<Snapshot> {
    const t0 = performance.now();
    const t = await this.ga.tree(this.pid, this.maxNodes);
    const flat = flatten(t.root);
    return {
      flat,
      location: addressBarValue(flat),
      truncated: t.truncated,
      nodes: t.nodeCount,
      ms: performance.now() - t0,
    };
  }

  /** Reads until `ready` holds; the last read and whether it held. */
  async waitFor(
    ready: (s: Snapshot) => boolean,
    timeoutMs: number,
    pollMs = 250,
  ): Promise<{ snap: Snapshot; ok: boolean }> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const snap = await this.snapshot();
      if (ready(snap)) return { snap, ok: true };
      if (Date.now() >= deadline) return { snap, ok: false };
      await sleep(pollMs);
    }
  }

  /**
   * Goes to `url` through the address bar (F5 when it already holds it),
   * then reads until the address bar holds it and `ready` holds; `how`
   * says which (the search record's). With `reloadWhen` holding for the
   * read before, a typed URL is reloaded (F5) once the address bar holds
   * it ("typed-reload"): a page that swaps its content a moment after
   * its address changes (a webmail routed by its fragment) would
   * otherwise still show the previous content under the new address.
   * The address bar holds `url` when it holds it or one of `aliases`
   * (addresses the webmail rewrites it to: Outlook.com's bare /mail/0/
   * for its Inbox).
   */
  async navigate(
    url: string,
    ready: (s: Snapshot) => boolean,
    timeoutMs: number,
    opts: {
      reloadWhen?: (before: Snapshot) => boolean;
      aliases?: string[];
    } = {},
  ): Promise<{
    snap: Snapshot;
    ok: boolean;
    how: "typed" | "reload" | "typed-reload";
  }> {
    const here = (loc: string | null): boolean =>
      sameLocation(loc, url) ||
      (opts.aliases ?? []).some((a) => sameLocation(loc, a));
    const now = await this.snapshot();
    const reload = here(now.location);
    let how: "typed" | "reload" | "typed-reload" = reload ? "reload" : "typed";
    if (reload) await this.ga.key("F5");
    else {
      const bar = now.flat.find(
        (f) => f.node.role === "text-field" && f.node.name === ADDRESS_BAR,
      );
      const b = bar?.node.bounds ?? null;
      if (b === null)
        throw new Error(
          `the browser's address bar ("${ADDRESS_BAR}") is not in its accessibility tree`,
        );
      await this.click(b);
      await this.ga.key("ctrl+a");
      await this.ga.type(url);
      // An inline completion is selected text after the typed URL.
      await this.ga.key("Delete");
      await this.ga.key("Return");
      if (opts.reloadWhen?.(now) === true) {
        const at = await this.waitFor((s) => here(s.location), timeoutMs);
        if (at.ok) {
          await this.ga.key("F5");
          how = "typed-reload";
        }
      }
    }
    const r = await this.waitFor(
      (s) => here(s.location) && ready(s),
      timeoutMs,
    );
    return { ...r, how };
  }

  /** The whole display, as a PNG (a failure's last frame). */
  async displayFrame(): Promise<Uint8Array> {
    return this.capture([0, 0, this.width, this.height]);
  }

  /** One click at the centre of `r`. */
  async click(r: Rect): Promise<void> {
    await this.ga.click(r[0] + r[2] / 2, r[1] + r[3] / 2);
  }

  /** The PNG of a region of the display (its file removed). */
  async capture(r: Rect): Promise<Uint8Array> {
    const out = this.frame();
    try {
      await this.ga.screenshotRegion(out, r);
      return new Uint8Array(readFileSync(out));
    } finally {
      rmSync(out, { force: true });
    }
  }

  /** The display's text (its frame removed). */
  async ocrText(): Promise<string> {
    const out = this.frame();
    try {
      return (await this.ga.ocr(out, null)).text;
    } finally {
      rmSync(out, { force: true });
    }
  }

  /** A region's text (its frame removed). */
  async ocrRegion(r: Rect): Promise<string> {
    const out = this.frame();
    try {
      return (await this.ga.ocrRegion(out, r)).text;
    } finally {
      rmSync(out, { force: true });
    }
  }

  /** Stops the browser (SIGINT) and the session; idempotent. */
  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await stopBrowser(this.child);
    await this.base.sessionStop(this.session.id).catch(() => undefined);
    rmSync(this.framesDir, { recursive: true, force: true });
  }

  /** For an exit handler, where nothing may be awaited. */
  closeSync(): void {
    if (this.closed) return;
    this.closed = true;
    if (this.child.exitCode === null && this.child.signalCode === null)
      this.child.kill("SIGINT");
    this.base.sessionStopSync(this.session.id);
    rmSync(this.framesDir, { recursive: true, force: true });
  }
}
