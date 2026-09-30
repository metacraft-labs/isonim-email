// tools/capture/launch.ts — browser launch options per engine and host.
//
// Linux (where the pinned reference hashes are recorded) launches every
// engine with Playwright's defaults, plus the forced-dark switch for
// Chromium: nothing here may change a Linux pixel.
//
// macOS CI runners are launchd daemons: no GUI login session, no GPU
// access, and no unlocked user keychain. There, headless Firefox
// launched with Playwright's defaults never finished its startup
// handshake (the launch timed out after 180 s) and logged
//   GraphicsCriticalError: RenderCompositorSWGL failed mapping default
//   framebuffer, no dt
// Playwright's bundled Firefox profile turns on
// `security.enterprise_roots.enabled`, which makes Firefox read trust
// roots from the macOS keychain at startup, and client-certificate
// autoload opens the keychain too; outside a login session those calls
// can block. The darwin profile below therefore:
//   - keeps Firefox away from the keychain (enterprise roots and
//     client-certificate autoload off — captures load no TLS content
//     that needs either);
//   - forces the software paths throughout (software WebRender without
//     the native compositor, no layer/canvas acceleration, no WebGL,
//     no hardware video decoding), so nothing probes for a GPU;
//   - sets MOZ_HEADLESS and an explicit headless window size, so the
//     software compositor always has a non-empty framebuffer to map,
//     and disables the crash reporter.
// Chromium on macOS gets --disable-gpu for the same no-GPU session.
// WebKit launched fine there and keeps its defaults.

export interface LaunchOptions {
  args?: string[];
  env?: Record<string, string | undefined>;
  firefoxUserPrefs?: Record<string, string | number | boolean>;
  timeout?: number;
}

/** Launch timeout: a wedged browser fails the run with a named engine
 *  well before a CI step timeout would. */
export const LAUNCH_TIMEOUT_MS = 120_000;

export const DARWIN_FIREFOX_PREFS: Record<string, string | number | boolean> = {
  "security.enterprise_roots.enabled": false,
  "security.osclientcerts.autoload": false,
  "gfx.webrender.software": true,
  "gfx.webrender.compositor": false,
  "layers.acceleration.disabled": true,
  "gfx.canvas.accelerated": false,
  "webgl.disabled": true,
  "media.hardware-video-decoding.enabled": false,
};

export const DARWIN_FIREFOX_ENV: Record<string, string> = {
  MOZ_HEADLESS: "1",
  MOZ_HEADLESS_WIDTH: "1280",
  MOZ_HEADLESS_HEIGHT: "800",
  MOZ_CRASHREPORTER_DISABLE: "1",
};

export function launchOptions(
  engine: string,
  forcedDark: boolean,
  platform: string,
  baseEnv: Record<string, string | undefined> = {},
): LaunchOptions {
  const opts: LaunchOptions = { timeout: LAUNCH_TIMEOUT_MS };
  const args: string[] = [];
  if (engine === "chromium" && forcedDark)
    args.push("--enable-features=WebContentsForceDark");
  if (platform === "darwin") {
    if (engine === "chromium") args.push("--disable-gpu");
    if (engine === "firefox") {
      opts.firefoxUserPrefs = { ...DARWIN_FIREFOX_PREFS };
      opts.env = { ...baseEnv, ...DARWIN_FIREFOX_ENV };
    }
  }
  if (args.length > 0) opts.args = args;
  return opts;
}
