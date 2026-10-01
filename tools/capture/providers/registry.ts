// tools/capture/providers/registry.ts — the capture providers
// `just email-shots` routes to, in routing order.
//
// Today that is the local browser provider only. Real mail clients
// (desktop clients in a headless compositor, self-hosted and hosted
// webmail, clients in VM guests, a device-farm service) join this list
// later; each declares its clients, requirements and health, and the
// harness routes, reports and caches for all of them alike.

import { BrowserEmulationProvider } from "./browser_emulation.ts";
import type { CaptureProvider } from "./types.ts";

export function registeredProviders(
  env: Record<string, string | undefined> = process.env,
): CaptureProvider[] {
  return [new BrowserEmulationProvider(env)];
}
