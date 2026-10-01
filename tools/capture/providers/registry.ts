// tools/capture/providers/registry.ts — the capture providers
// `just email-shots` routes to, in routing order.
//
// The local browser provider (backend a), the self-hosted webmail
// provider (Roundcube and SnappyMail, verification clients) and the
// Linux desktop provider (real desktop clients in a headless
// compositor: Thunderbird). Hosted webmail, clients in VM guests and a
// device-farm service join this list later; each declares its clients,
// requirements and health, and the harness routes, reports and caches
// for all of them alike.

import { BrowserEmulationProvider } from "./browser_emulation.ts";
import { LinuxDesktopProvider } from "./linux_desktop.ts";
import { SelfhostedWebmailProvider } from "./selfhosted_webmail.ts";
import type { CaptureProvider } from "./types.ts";

export function registeredProviders(
  env: Record<string, string | undefined> = process.env,
): CaptureProvider[] {
  return [
    new BrowserEmulationProvider(env),
    new SelfhostedWebmailProvider({ env }),
    new LinuxDesktopProvider({ env }),
  ];
}
