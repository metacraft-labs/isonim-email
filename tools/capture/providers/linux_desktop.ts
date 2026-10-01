// tools/capture/providers/linux_desktop.ts — the linux-desktop capture
// provider: real desktop mail clients, each in a headless sway session
// of its own (desktop_session.ts), driven by a client driver
// (desktop_clients.ts; Thunderbird in thunderbird_driver.ts).
//
// For every capture the story's MIME is delivered into a fresh
// one-message IMAP account (the imap service, with the story asset
// origin rewritten to the assets service); the driver points the
// client at that account and opens the message in a window filling the
// output; the output is set to the request's width at its device-pixel
// ratio (and grown in height until the body is not clipped); grim
// captures the output and the PNG is the message body region the
// driver reports, cropped in device pixels, nothing around it. The
// capture is taken once two consecutive frames of that region are
// identical.
//
// A capture fails, never passes quietly, when:
// - the account's INBOX does not hold exactly the delivered message, or
//   the client shows another subject;
// - the client did not apply the requested scheme;
// - an image the story contains was not served 200 by the assets
//   service, or the client did not load it;
// - the client's crop calibration failed for its current build.
//
// Crop calibration. The first run with a client build (or provider
// adapter version) other than the last one calibrated captures the
// calibration fixture (desktop_clients.ts) in every scheme the client
// renders and checks that the crop holds exactly the message body; a
// pass is recorded under build/email-shots/.calibration/, a failure fails
// that client's captures with the reason. `just email-calibrate` runs it
// on demand.
//
// Network. The client's HTTP and HTTPS proxy is the assets service's
// egress guard, with no exception: loopback (the assets service, IMAP)
// is reached directly and everything else is refused there and listed
// in the provenance (network.blocked).
//
// Warm (the default): one session per client for the whole run, started
// in prepare(); each capture creates its account, captures, closes the
// message and removes the account. A client's captures run one at a
// time; different clients capture at once. --cold: a fresh session,
// profile and client for every capture, one capture at a time.

import { storyImagePaths, subjectOf } from "./selfhosted_webmail.ts";
import { assetsHandle } from "./assets_service.ts";
import {
  CALIBRATION_ROOT,
  calibrationMessage,
  type CalibrationCheck,
  type CalibrationRecord,
  checkCalibration,
  type DesktopClientDriver,
  type DesktopClientInstance,
  type OpenedMessage,
  readCalibration,
  writeCalibration,
} from "./desktop_clients.ts";
import {
  cropImage,
  DesktopSession,
  type DesktopSessionInfo,
  encodePng,
  LOCALES_ENV,
  type Rect,
  SESSION_BINARIES,
} from "./desktop_session.ts";
import type { RgbaImage } from "../contact_sheet.ts";
import { imapHandle } from "./imap_service.ts";
import { ThunderbirdDriver } from "./thunderbird_driver.ts";
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
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { currentHost, findExecutable } from "./requirements.ts";

export const LINUX_DESKTOP_ID = "linux-desktop";
// Bump whenever output can change for reasons no other key field
// captures (the client and compositor versions are in client_build).
export const LINUX_DESKTOP_VERSION = "1";
// Bump by hand when the crop, wait or open logic of the provider or of
// any driver changes.
export const LINUX_DESKTOP_ADAPTER_VERSION = 1;
// The output's logical height before the driver grows it.
export const DEFAULT_OUTPUT_HEIGHT = 900;
// Frames compared before a capture is taken.
const MAX_FRAMES = 6;

export function defaultDrivers(): DesktopClientDriver[] {
  return [new ThunderbirdDriver()];
}

export interface LinuxDesktopOptions {
  env?: Record<string, string | undefined>;
  drivers?: DesktopClientDriver[];
  // Parent of every session's state directory.
  stateRoot?: string;
  // Where calibration records live.
  calibrationRoot?: string;
  // Test seam: origins (besides the assets service) the clients may
  // load remote content from, so a test can show that such a load ends
  // at the egress guard. Never set outside tests.
  extraRemoteOrigins?: string[];
}

interface Running {
  session: DesktopSession;
  sessionInfo: DesktopSessionInfo;
  instance: DesktopClientInstance;
}

// One calibration pass: the check and the images behind it.
export interface CalibrationRun {
  client: string;
  build: string;
  ok: boolean;
  problems: string[];
  checks: {
    viewport: ViewportSpec;
    scheme: Scheme;
    // Device pixels.
    crop: Rect;
    check: CalibrationCheck;
    // The whole output as captured, and the crop.
    full: RgbaImage;
    cropped: RgbaImage;
  }[];
  record: CalibrationRecord | null;
  recordPath: string | null;
  timingMs: number;
}

class CaptureError extends Error {}

// The body's device-pixel rectangle. Gecko snaps a browser element's
// origin and its size to device pixels separately (measured: a pane at
// y 182.4 with height 691.27 paints rows 182 to 872), so the size is
// rounded on its own rather than derived from the rounded far edge; the
// crop calibration checks this per client build.
export function deviceRect(body: Rect, dpr: number): Rect {
  return {
    x: Math.round(body.x * dpr),
    y: Math.round(body.y * dpr),
    width: Math.round(body.width * dpr),
    height: Math.round(body.height * dpr),
  };
}

function sameImage(a: RgbaImage, b: RgbaImage): boolean {
  return (
    a.width === b.width &&
    a.height === b.height &&
    Buffer.from(a.data.buffer, a.data.byteOffset, a.data.length).equals(
      Buffer.from(b.data.buffer, b.data.byteOffset, b.data.length),
    )
  );
}

export class LinuxDesktopProvider implements CaptureProvider {
  readonly id = LINUX_DESKTOP_ID;
  readonly backend = LINUX_DESKTOP_ID;
  readonly version = LINUX_DESKTOP_VERSION;
  readonly adapterVersion = LINUX_DESKTOP_ADAPTER_VERSION;
  // Messages reach the client through the IMAP store, injected.
  readonly via = "inject";

  private readonly env: Record<string, string | undefined>;
  private readonly drivers: DesktopClientDriver[];
  private readonly stateRoot: string | undefined;
  private readonly calibrationRoot: string;
  private readonly extraRemoteOrigins: string[];
  private imap: ImapHandle | null = null;
  private assets: AssetsHandle | null = null;
  private swayVersion = "";
  private readonly versions = new Map<string, string>();
  private readonly warm = new Map<string, Running>();
  // Why a client's captures fail (its calibration failed), by client.
  private readonly unusable = new Map<string, string>();
  private readonly calibrated = new Map<string, CalibrationRun | "current">();
  private run = "";
  private seq = 0;

  constructor(opts: LinuxDesktopOptions = {}) {
    this.env = opts.env ?? process.env;
    this.drivers = opts.drivers ?? defaultDrivers();
    this.stateRoot = opts.stateRoot;
    this.calibrationRoot = opts.calibrationRoot ?? CALIBRATION_ROOT;
    this.extraRemoteOrigins = opts.extraRemoteOrigins ?? [];
  }

  private driver(clientId: string): DesktopClientDriver | undefined {
    return this.drivers.find((d) => d.clientId === clientId);
  }

  clients(): ClientDescriptor[] {
    return this.drivers.map((d) => ({
      clientId: d.clientId,
      family: d.family,
      engine: d.engine,
      build: async () => this.build(d.clientId),
      viewports: d.viewports,
      schemes: d.schemes,
      imagesOff: false,
      approximation: false,
    }));
  }

  // The client's version and the compositor that draws it: both decide
  // the pixels. "" before prepare().
  build(clientId: string): string {
    const v = this.versions.get(clientId);
    if (v === undefined || this.swayVersion === "") return "";
    return `${clientId}-${v}+sway-${this.swayVersion}`;
  }

  requirements(): Requirement[] {
    const reqs: Requirement[] = [
      {
        kind: "host-os",
        os: ["linux"],
        why: "the clients run in a headless Wayland compositor (sway), which is Linux-only; on macOS use a Linux builder or the VM mode",
      },
      ...SESSION_BINARIES.map(
        (name): Requirement => ({
          kind: "binary",
          name,
          why: "the headless session the clients run in",
        }),
      ),
      {
        kind: "binary",
        name: "setpriv",
        why: "the session dies with the run (parent-death signal)",
      },
      {
        kind: "binary",
        name: "unshare",
        why: "the session's processes live in a PID namespace of their own, so they all die with it",
      },
      {
        kind: "env-dir",
        variable: LOCALES_ENV,
        why: "the fixed locale the clients run with (the dev shell sets it)",
      },
      {
        kind: "service",
        name: "imap",
        why: "each capture opens a fresh one-message account",
      },
      {
        kind: "service",
        name: "assets",
        why: "the story images, and the egress guard the clients' proxy points at",
      },
    ];
    for (const d of this.drivers)
      for (const r of d.requirements())
        if (
          !reqs.some((x) => JSON.stringify(x) === JSON.stringify(r)) &&
          !(
            r.kind === "binary" &&
            reqs.some((x) => x.kind === "binary" && x.name === r.name)
          )
        )
          reqs.push(r);
    return reqs;
  }

  async health(): Promise<ProviderHealth> {
    const fc = this.env.FONTCONFIG_FILE ?? "";
    if (fc === "" || !existsSync(fc))
      return {
        state: "unavailable",
        reason:
          "$FONTCONFIG_FILE does not name the pinned font configuration (run inside the isonim-email dev shell)",
      };
    try {
      for (const d of this.drivers) d.version(this.env);
    } catch (err) {
      return {
        state: "unavailable",
        reason: err instanceof Error ? err.message : String(err),
      };
    }
    return { state: "ok" };
  }

  private readSwayVersion(): string {
    const sway = findExecutable("sway", { ...currentHost(), env: this.env });
    if (sway === null) throw new Error("sway is not on PATH");
    const v = /sway version (\S+)/.exec(
      spawnSync(sway, ["--version"], { encoding: "utf8" }).stdout ?? "",
    )?.[1];
    if (v === undefined) throw new Error("cannot read sway's version");
    return v;
  }

  // Services, versions, and (warm) a running session per planned client;
  // then the crop calibration of each planned client whose build was not
  // calibrated yet.
  async prepare(ctx: SessionCtx): Promise<void> {
    this.imap = imapHandle(ctx.services.imap);
    this.assets = assetsHandle(ctx.services.assets);
    this.run = ctx.run;
    if (this.swayVersion === "") this.swayVersion = this.readSwayVersion();
    for (const d of this.drivers)
      if (!this.versions.has(d.clientId))
        this.versions.set(d.clientId, d.version(this.env));
    const planned = this.drivers.filter((d) =>
      ctx.planned.some((r) => r.clientId === d.clientId),
    );
    if (!ctx.cold)
      await Promise.all(
        planned
          .filter((d) => !this.warm.has(d.clientId))
          .map(async (d) => {
            this.warm.set(d.clientId, await this.startClient(d, d.clientId));
          }),
      );
    await Promise.all(
      planned.map(async (d) => {
        if (this.calibrated.has(d.clientId)) return;
        const rec = readCalibration(this.calibrationRoot, this.id, d.clientId);
        if (
          rec !== null &&
          rec.build === this.build(d.clientId) &&
          rec.adapter_version === this.adapterVersion
        ) {
          this.calibrated.set(d.clientId, "current");
          return;
        }
        const r = await this.calibrate(d.clientId, ctx.cold);
        if (!r.ok)
          this.unusable.set(
            d.clientId,
            `crop calibration failed for ${r.build}: ${r.problems.join("; ")}`,
          );
      }),
    );
  }

  private async startClient(
    d: DesktopClientDriver,
    instance: string,
  ): Promise<Running> {
    const session = new DesktopSession({
      env: this.env,
      ...(this.stateRoot !== undefined ? { stateRoot: this.stateRoot } : {}),
    });
    const viewport = d.viewports[0]!;
    const sessionInfo = await session.start({
      run: this.run,
      instance,
      output: {
        width: viewport.width,
        height: DEFAULT_OUTPUT_HEIGHT,
        scale: viewport.dpr,
      },
      env: d.sessionEnv(),
      // The only host ports the client can reach: IMAP, and the assets
      // service (the story images and the egress guard).
      forward: [this.imap!.port, Number(new URL(this.assets!.baseUrl).port)],
    });
    try {
      const inst = await d.launch(session, {
        assets: this.assets!,
        extraRemoteOrigins: this.extraRemoteOrigins,
      });
      return { session, sessionInfo, instance: inst };
    } catch (err) {
      await session.stop();
      throw err;
    }
  }

  private async stopClient(r: Running): Promise<void> {
    await r.instance.quit().catch(() => {});
    await r.session.stop();
  }

  emulation(_req: CaptureRequest): Emulation {
    return { transformVersion: "", detail: null };
  }

  // Opens `message` in a fresh account and captures the body region,
  // waiting for two identical consecutive frames.
  private async openAndCapture(
    r: Running,
    message: StoryMessage,
    viewport: ViewportSpec,
    scheme: Scheme,
    timing: Record<string, number>,
  ): Promise<{
    delivery: Awaited<ReturnType<ImapHandle["mailboxFor"]>>;
    opened: OpenedMessage;
    full: RgbaImage;
    crop: Rect;
    cropped: RgbaImage;
    frames: number;
  }> {
    r.session.setOutput({
      width: viewport.width,
      height: DEFAULT_OUTPUT_HEIGHT,
      scale: viewport.dpr,
    });
    const delivery = await this.imap!.mailboxFor(message.mime, {
      assets: this.assets!,
    });
    timing.account = delivery.timingMs.account;
    timing.inject = delivery.timingMs.inject;
    const opened = await r.instance.open({
      account: delivery.account,
      scheme,
      viewport,
    });
    Object.assign(timing, opened.timingMs);
    const tCap = performance.now();
    const crop = deviceRect(opened.body, viewport.dpr);
    let full = r.session.screenshot();
    let cropped = cropImage(full, crop);
    let frames = 1;
    for (; frames < MAX_FRAMES; frames++) {
      await new Promise((ok) => setTimeout(ok, 50));
      const nextFull = r.session.screenshot();
      const next = cropImage(nextFull, crop);
      const same = sameImage(next, cropped);
      full = nextFull;
      cropped = next;
      if (same) break;
    }
    timing.capture = performance.now() - tCap;
    if (frames >= MAX_FRAMES)
      throw new CaptureError(
        `the message body did not settle: ${MAX_FRAMES} consecutive frames all differed`,
      );
    return { delivery, opened, full, crop, cropped, frames: frames + 1 };
  }

  // Captures the calibration fixture in every scheme the client renders
  // (at its first viewport) and checks each crop; records a pass.
  async calibrate(clientId: string, cold: boolean): Promise<CalibrationRun> {
    const t0 = performance.now();
    const d = this.driver(clientId);
    if (d === undefined) throw new Error(`no desktop client '${clientId}'`);
    const build = this.build(clientId);
    let running = cold ? null : (this.warm.get(clientId) ?? null);
    const own = running === null;
    const run: CalibrationRun = {
      client: clientId,
      build,
      ok: false,
      problems: [],
      checks: [],
      record: null,
      recordPath: null,
      timingMs: 0,
    };
    try {
      running ??= await this.startClient(d, `${clientId}-cal${++this.seq}`);
      const viewport = d.viewports[0]!;
      for (const scheme of d.schemes) {
        const timing: Record<string, number> = {};
        try {
          const c = await this.openAndCapture(
            running,
            calibrationMessage(),
            viewport,
            scheme,
            timing,
          );
          const check = checkCalibration(c.cropped, viewport.dpr);
          run.checks.push({
            viewport,
            scheme,
            crop: c.crop,
            check,
            full: c.full,
            cropped: c.cropped,
          });
          for (const p of check.problems)
            run.problems.push(`${viewport.name} ${scheme}: ${p}`);
        } finally {
          await running.instance.close();
        }
      }
      run.ok = run.problems.length === 0 && run.checks.length > 0;
    } catch (err) {
      run.problems.push(err instanceof Error ? err.message : String(err));
    } finally {
      if (own && running !== null) await this.stopClient(running);
    }
    run.timingMs = performance.now() - t0;
    if (run.ok) {
      run.record = {
        provider: this.id,
        client: clientId,
        build,
        adapter_version: this.adapterVersion,
        calibrated_at: new Date().toISOString(),
        checks: run.checks.map((c) => ({
          viewport: c.viewport.name,
          dpr: c.viewport.dpr,
          scheme: c.scheme,
          crop: c.crop,
          corners: c.check.corners,
        })),
      };
      run.recordPath = writeCalibration(this.calibrationRoot, run.record);
      this.unusable.delete(clientId);
    } else {
      // The evidence of a failed calibration, for whoever looks into it:
      // the whole output and the crop, per scheme.
      const dir = join(this.calibrationRoot, this.id, `${clientId}.failed`);
      rmSync(dir, { recursive: true, force: true });
      mkdirSync(dir, { recursive: true });
      for (const c of run.checks) {
        writeFileSync(join(dir, `${c.scheme}-output.png`), encodePng(c.full));
        writeFileSync(join(dir, `${c.scheme}-crop.png`), encodePng(c.cropped));
      }
      writeFileSync(
        join(dir, "problems.json"),
        JSON.stringify(
          {
            build,
            problems: run.problems,
            crops: run.checks.map((c) => ({ scheme: c.scheme, crop: c.crop })),
          },
          null,
          2,
        ) + "\n",
      );
    }
    this.calibrated.set(clientId, run);
    return run;
  }

  async *capture(
    batch: CaptureRequest[],
    messages: Map<Sha256, StoryMessage>,
    ctx: SessionCtx,
  ): AsyncIterable<CaptureResult> {
    // Warm: one worker per client (each client's captures in order,
    // different clients at once). Cold: one capture at a time.
    const queues: CaptureRequest[][] = ctx.cold
      ? [batch]
      : this.drivers.map((d) => batch.filter((r) => r.clientId === d.clientId));
    const ready: CaptureResult[] = [];
    let wake: (() => void) | null = null;
    let running = 0;
    const work = queues
      .filter((q) => q.length > 0)
      .map(async (q) => {
        running++;
        try {
          for (const req of q) {
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
    const d = this.driver(req.clientId);
    if (d === undefined)
      return fail(`unknown desktop client '${req.clientId}'`);
    const message = messages.get(req.mimeSha256);
    if (message === undefined)
      return fail(`no message for ${req.story} (${req.mimeSha256})`);
    const unusable = this.unusable.get(d.clientId);
    if (unusable !== undefined) return fail(unusable);
    const assets = this.assets!;

    let own: Running | null = null;
    let running = cold ? null : (this.warm.get(d.clientId) ?? null);
    let opened = false;
    try {
      if (running === null) {
        const ts = performance.now();
        own = await this.startClient(d, `${d.clientId}-c${++this.seq}`);
        running = own;
        timing.session = own.sessionInfo.timingMs.start;
        timing.launch = performance.now() - ts - timing.session;
      }
      provenance.client = {
        version: this.versions.get(d.clientId) ?? "",
      };
      provenance.compositor = {
        name: "sway",
        version: this.swayVersion,
        backend: "headless",
        renderer: "pixman",
        warm: own === null,
      };
      const assetsBefore = assets.requests().length;
      opened = true;
      const c = await this.openAndCapture(
        running,
        message,
        req.viewport,
        req.scheme,
        timing,
      );
      (provenance.client as Record<string, unknown>).account =
        c.delivery.account.user;
      provenance.asset_rewrite =
        c.delivery.assetRewrite === null
          ? null
          : {
              ...c.delivery.assetRewrite,
              injected_sha256: c.delivery.injectedSha256,
            };
      Object.assign(
        provenance.client as Record<string, unknown>,
        c.opened.detail,
      );
      provenance.output = running.session.output;
      provenance.crop = {
        method: "client geometry (message body), window fullscreen",
        logical: c.opened.body,
        device: c.crop,
        frames: c.frames,
        calibration: this.calibrationSummary(d.clientId),
      };
      provenance.scheme_applied = c.opened.scheme;

      // The opened message must be the delivered one.
      const subject = subjectOf(message.mime);
      if (subject !== null && !c.opened.subject.includes(subject))
        throw new CaptureError(
          `${d.clientId}: the opened message is not the delivered one (subject shown: '${c.opened.subject}', delivered: '${subject}')`,
        );
      if (c.opened.scheme.dark !== (req.scheme === "dark"))
        throw new CaptureError(
          `${d.clientId}: requested ${req.scheme} but the client shows ${c.opened.scheme.dark ? "dark" : "light"} (${JSON.stringify(c.opened.scheme.evidence)})`,
        );

      // The story's images: served 200 by the assets service during
      // this capture, and loaded by the client.
      const log = assets.requests().slice(assetsBefore);
      const assetsOrigin = new URL(assets.baseUrl).origin;
      const expected = storyImagePaths(message.html);
      const served = log
        .filter((e) => e.kind === "asset")
        .map((e) => ({ path: e.url, status: e.status, via: e.via }));
      const clientLoaded = (c.opened.images ?? [])
        .filter((i) => {
          try {
            return new URL(i.url).origin === assetsOrigin;
          } catch {
            return false;
          }
        })
        .map((i) => ({ path: new URL(i.url).pathname, loaded: i.loaded }));
      const missing = expected.filter(
        (p) =>
          !served.some((s) => s.path === p && s.status === 200) ||
          (c.opened.images !== null &&
            !clientLoaded.some((i) => i.path === p && i.loaded)),
      );
      provenance.images = {
        expected,
        served,
        client: c.opened.images,
        missing,
        ...(expected.length === 0
          ? { note: "the story loads no story image" }
          : {}),
      };
      // The service's log over this capture; with other providers
      // capturing at once it can include their requests.
      provenance.assets_log = log;
      provenance.network = {
        policy:
          "proxy: the assets service's egress guard, no exception (loopback is not proxied)",
        blocked: log.filter((e) => e.kind === "blocked"),
      };
      if (req.images === "on" && missing.length > 0)
        throw new CaptureError(
          `${d.clientId}: image(s) the story contains were not served 200 by the assets service and loaded by the client: ${missing.join(", ")}`,
        );
      timing.total = performance.now() - t0;
      return {
        request: req,
        status: "done",
        png: encodePng(c.cropped),
        provenance,
      };
    } catch (err) {
      return fail(err instanceof Error ? err.message : String(err));
    } finally {
      if (own !== null) await this.stopClient(own);
      else if (opened && running !== null)
        try {
          await running.instance.close();
        } catch {
          // A client that cannot close its message is not reused: the
          // next capture of this client starts a fresh session.
          this.warm.delete(d.clientId);
          await this.stopClient(running);
        }
    }
  }

  private calibrationSummary(clientId: string): Record<string, unknown> {
    const c = this.calibrated.get(clientId);
    if (c === undefined) return { state: "unknown" };
    if (c === "current") {
      const rec = readCalibration(this.calibrationRoot, this.id, clientId);
      return {
        state: "recorded",
        build: rec?.build ?? null,
        calibrated_at: rec?.calibrated_at ?? null,
      };
    }
    return {
      state: c.ok ? "calibrated in this run" : "failed",
      build: c.build,
      problems: c.problems,
    };
  }

  async dispose(): Promise<void> {
    const all = [...this.warm.values()];
    this.warm.clear();
    await Promise.all(all.map((r) => this.stopClient(r)));
  }
}
