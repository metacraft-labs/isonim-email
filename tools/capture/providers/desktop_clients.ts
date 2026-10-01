// tools/capture/providers/desktop_clients.ts — the seam between the
// linux-desktop provider and the mail clients it runs.
//
// The provider (linux_desktop.ts) owns everything common to every
// desktop client: the headless session (desktop_session.ts), the
// one-message IMAP account and the asset rewrite (the imap and assets
// services), the output mode per request, the capture and the crop, the
// image and scheme checks, the crop calibration, warm and cold, and the
// provenance. A client driver owns only what is particular to its
// client: how to start it in a session with a templated profile, how to
// point it at an account and open the account's only message in a
// window that fills the output, where in that window the message body
// is, which scheme it applied and which images it loaded.
//
// The crop calibration lives here too: a fixture message whose body
// carries a solid square at each corner of the client's message
// viewport, and the check that a capture's crop holds exactly those
// four squares at full size, so a crop that includes a pixel of client
// chrome, or loses a pixel of the body, fails.

import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import type { RgbaImage } from "../contact_sheet.ts";
import type { DesktopSession, Rect } from "./desktop_session.ts";
import type {
  AssetsHandle,
  Engine,
  ImapAccount,
  Requirement,
  Scheme,
  StoryMessage,
  ViewportSpec,
} from "./types.ts";

// What a driver is started with.
export interface DriverLaunchCtx {
  // The assets service: the origin the story images load from (the
  // client's remote-content allowance) and the egress guard (the
  // client's HTTP and HTTPS proxy).
  assets: AssetsHandle;
  // Test seam: further origins the client may load remote content
  // from, so a test can show that such a load ends at the egress guard.
  // Empty outside tests.
  extraRemoteOrigins: string[];
}

export interface OpenRequest {
  account: ImapAccount;
  scheme: Scheme;
  viewport: ViewportSpec;
}

// What a driver reports once the message is open and settled.
export interface OpenedMessage {
  // The message body region, in output-logical pixels.
  body: Rect;
  // The subject the client shows for the opened message.
  subject: string;
  // The scheme the client applied, and the evidence for it.
  scheme: { dark: boolean; evidence: Record<string, unknown> };
  // Every image in the body as the client sees it: its URL and whether
  // it loaded (complete with a decoded size); null when the client
  // cannot say.
  images: { url: string; loaded: boolean }[] | null;
  // Client-specific provenance (window, theme, account key, …).
  detail: Record<string, unknown>;
  // Steps of open() (configure, sync, open, settle, …).
  timingMs: Record<string, number>;
}

// One running client in one session.
export interface DesktopClientInstance {
  // Points the client at the account, opens the account's only message
  // in a window that fills the output, grows the output's height until
  // the body is not clipped, waits until the body has settled (fonts
  // and images loaded), and reports.
  open(req: OpenRequest): Promise<OpenedMessage>;
  // Closes what open() opened and removes the account, so the next
  // open() starts from the same state (warm mode).
  close(): Promise<void>;
  // Stops the client (its session is stopped by the provider).
  quit(): Promise<void>;
  readonly timingMs: Record<string, number>;
}

export interface DesktopClientDriver {
  readonly clientId: string;
  readonly family: string;
  readonly engine: Engine;
  // What the client renders: measured per client (a desktop client has
  // a minimum window width, so phone widths may not be possible).
  readonly viewports: ViewportSpec[];
  readonly schemes: Scheme[];
  requirements(): Requirement[];
  // The client's exact version, read from its own binary.
  version(env: Record<string, string | undefined>): string;
  // Environment added to the session the client runs in.
  sessionEnv(): Record<string, string>;
  launch(
    session: DesktopSession,
    ctx: DriverLaunchCtx,
  ): Promise<DesktopClientInstance>;
}

// ---------------------------------------------------------------------------
// Crop calibration
// ---------------------------------------------------------------------------

// The size of each corner square, in CSS pixels.
export const MARKER_PX = 16;
// Corner colours: saturated, and each below the luminance a client's
// dark-mode recolouring treats as "too bright" (Thunderbird adapts only
// inline styles in any case; these come from a <style> block).
export const MARKERS = {
  tl: [255, 0, 0],
  tr: [0, 0, 255],
  bl: [0, 140, 0],
  br: [255, 0, 255],
} as const satisfies Record<string, readonly [number, number, number]>;

export const CALIBRATION_STORY = "cropCalibration";
const CALIBRATION_HEADING = "Crop calibration";

function crlf(lines: string[]): string {
  return lines.join("\r\n");
}

// The calibration fixture: a one-part 7bit HTML message whose body has
// one fixed square in each corner of the message viewport and a short
// heading, nothing that could overflow it.
export function calibrationMessage(): StoryMessage {
  const rgb = (c: readonly number[]): string => `rgb(${c.join(",")})`;
  const html = crlf([
    "<!doctype html>",
    "<html><head><style>",
    "html,body{margin:0;padding:0}",
    `.m{position:fixed;width:${MARKER_PX}px;height:${MARKER_PX}px}`,
    `.tl{top:0;left:0;background:${rgb(MARKERS.tl)}}`,
    `.tr{top:0;right:0;background:${rgb(MARKERS.tr)}}`,
    `.bl{bottom:0;left:0;background:${rgb(MARKERS.bl)}}`,
    `.br{bottom:0;right:0;background:${rgb(MARKERS.br)}}`,
    "h1{margin:64px 32px;font:24px sans-serif}",
    "</style></head><body>",
    `<div class="m tl"></div><div class="m tr"></div>`,
    `<div class="m bl"></div><div class="m br"></div>`,
    `<h1>${CALIBRATION_HEADING}</h1>`,
    "</body></html>",
  ]);
  const mime = Buffer.from(
    crlf([
      "From: IsoNim Shots <shots@example.test>",
      "To: qa@example.test",
      `Subject: [shots] ${CALIBRATION_STORY}`,
      "Date: Thu, 01 Jan 2026 12:00:00 +0000",
      `Message-ID: <${CALIBRATION_STORY}@example.test>`,
      "MIME-Version: 1.0",
      "Content-Type: text/html; charset=utf-8",
      "Content-Transfer-Encoding: 7bit",
      "",
      html,
      "",
    ]),
  );
  return { story: CALIBRATION_STORY, mime, html };
}

export interface CalibrationCheck {
  ok: boolean;
  problems: string[];
  // Per corner: the square's measured run along the edge (horizontal,
  // vertical) in device pixels, against `expected`.
  corners: Record<string, { h: number; v: number }>;
  expected: number;
  width: number;
  height: number;
}

function near(
  img: RgbaImage,
  x: number,
  y: number,
  c: readonly number[],
): boolean {
  const i = (y * img.width + x) * 4;
  return (
    Math.abs(img.data[i]! - c[0]!) <= 24 &&
    Math.abs(img.data[i + 1]! - c[1]!) <= 24 &&
    Math.abs(img.data[i + 2]! - c[2]!) <= 24
  );
}

// Checks that `crop` (the cropped capture of the calibration fixture,
// device pixels) is exactly the client's message viewport: each corner
// pixel is its square's colour, and the square runs exactly
// MARKER_PX × dpr pixels along both edges from that corner and fills
// the square diagonally. A crop shifted or grown by one pixel puts
// client chrome in a corner; one shrunk by a pixel shortens a run.
export function checkCalibration(
  crop: RgbaImage,
  dpr: number,
): CalibrationCheck {
  const n = Math.round(MARKER_PX * dpr);
  const problems: string[] = [];
  const corners: Record<string, { h: number; v: number }> = {};
  const W = crop.width;
  const H = crop.height;
  if (W < 2 * n + 2 || H < 2 * n + 2) {
    problems.push(`crop ${W}x${H} is too small to hold the corner squares`);
    return { ok: false, problems, corners, expected: n, width: W, height: H };
  }
  const spec = {
    tl: { x: 0, y: 0, dx: 1, dy: 1 },
    tr: { x: W - 1, y: 0, dx: -1, dy: 1 },
    bl: { x: 0, y: H - 1, dx: 1, dy: -1 },
    br: { x: W - 1, y: H - 1, dx: -1, dy: -1 },
  } as const;
  for (const [name, s] of Object.entries(spec) as [
    keyof typeof MARKERS,
    (typeof spec)[keyof typeof spec],
  ][]) {
    const c = MARKERS[name];
    let h = 0;
    while (h < W && near(crop, s.x + s.dx * h, s.y, c)) h++;
    let v = 0;
    while (v < H && near(crop, s.x, s.y + s.dy * v, c)) v++;
    corners[name] = { h, v };
    if (h !== n || v !== n)
      problems.push(
        `${name}: the square runs ${h}x${v} px from the corner, expected ${n}x${n}`,
      );
    else if (!near(crop, s.x + s.dx * (n - 1), s.y + s.dy * (n - 1), c))
      problems.push(`${name}: the square is not filled to its far corner`);
  }
  return {
    ok: problems.length === 0,
    problems,
    corners,
    expected: n,
    width: W,
    height: H,
  };
}

// ---------------------------------------------------------------------------
// The calibration record: the last client build whose crop passed
// ---------------------------------------------------------------------------

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..", "..");
export const CALIBRATION_ROOT = join(
  repoRoot,
  "build",
  "email-shots",
  ".calibration",
);

export interface CalibrationRecord {
  provider: string;
  client: string;
  // The client build and the provider's adapter version calibrated;
  // either changing makes the next run calibrate again.
  build: string;
  adapter_version: number;
  calibrated_at: string;
  // One entry per (viewport, scheme) calibrated.
  checks: {
    viewport: string;
    dpr: number;
    scheme: Scheme;
    crop: Rect;
    corners: Record<string, { h: number; v: number }>;
  }[];
}

export function calibrationPath(
  root: string,
  provider: string,
  client: string,
): string {
  return join(root, provider, `${client}.json`);
}

export function readCalibration(
  root: string,
  provider: string,
  client: string,
): CalibrationRecord | null {
  const p = calibrationPath(root, provider, client);
  if (!existsSync(p)) return null;
  try {
    const r = JSON.parse(readFileSync(p, "utf8")) as CalibrationRecord;
    return typeof r.build === "string" && typeof r.adapter_version === "number"
      ? r
      : null;
  } catch {
    return null;
  }
}

export function writeCalibration(root: string, r: CalibrationRecord): string {
  const p = calibrationPath(root, r.provider, r.client);
  mkdirSync(dirname(p), { recursive: true });
  const tmp = `${p}.${createHash("sha256").update(String(process.pid)).digest("hex").slice(0, 8)}.tmp`;
  writeFileSync(tmp, JSON.stringify(r, null, 2) + "\n");
  renameSync(tmp, p);
  return p;
}
