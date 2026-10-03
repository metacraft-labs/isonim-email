// tools/capture/launch.test.ts — per-engine, per-host browser launch
// options. The Linux assertions guard the pinned reference hashes: a
// Linux launch must stay Playwright's defaults (plus Chromium's
// forced-dark switch). No mocks: pure function. Run with:
//   node --test tools/capture/launch.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  DARWIN_FIREFOX_ENV,
  DARWIN_FIREFOX_PREFS,
  FORCED_DARK_ARGS,
  LAUNCH_TIMEOUT_MS,
  launchOptions,
} from "./launch.ts";

describe("browser launch options", () => {
  it("linux launches keep Playwright defaults", () => {
    for (const engine of ["chromium", "firefox", "webkit"]) {
      const o = launchOptions(engine, false, "linux", { PATH: "/bin" });
      assert.deepEqual(o, { timeout: LAUNCH_TIMEOUT_MS }, engine);
    }
    assert.deepEqual(launchOptions("chromium", true, "linux"), {
      timeout: LAUNCH_TIMEOUT_MS,
      args: ["--blink-settings=forceDarkModeEnabled=true"],
    });
    assert.deepEqual(FORCED_DARK_ARGS, [
      "--blink-settings=forceDarkModeEnabled=true",
    ]);
  });

  it("darwin firefox stays off the keychain and the GPU", () => {
    const o = launchOptions("firefox", false, "darwin", { PATH: "/bin" });
    assert.equal(
      o.firefoxUserPrefs?.["security.enterprise_roots.enabled"],
      false,
    );
    assert.equal(
      o.firefoxUserPrefs?.["security.osclientcerts.autoload"],
      false,
    );
    assert.equal(o.firefoxUserPrefs?.["gfx.webrender.software"], true);
    assert.equal(o.firefoxUserPrefs?.["layers.acceleration.disabled"], true);
    assert.deepEqual(o.firefoxUserPrefs, DARWIN_FIREFOX_PREFS);
    // The caller's environment is kept (Playwright replaces, not
    // merges, env) with the headless variables on top.
    assert.equal(o.env?.PATH, "/bin");
    for (const [k, v] of Object.entries(DARWIN_FIREFOX_ENV))
      assert.equal(o.env?.[k], v, k);
    assert.equal(o.env?.MOZ_HEADLESS, "1");
    assert.equal(o.args, undefined);
  });

  it("darwin chromium disables the GPU and keeps forced dark", () => {
    assert.deepEqual(launchOptions("chromium", true, "darwin").args, [
      "--blink-settings=forceDarkModeEnabled=true",
      "--disable-gpu",
    ]);
    assert.deepEqual(launchOptions("chromium", false, "darwin").args, [
      "--disable-gpu",
    ]);
  });

  it("darwin webkit keeps its defaults", () => {
    assert.deepEqual(launchOptions("webkit", false, "darwin"), {
      timeout: LAUNCH_TIMEOUT_MS,
    });
  });
});
