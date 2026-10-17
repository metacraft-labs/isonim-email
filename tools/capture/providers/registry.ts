// tools/capture/providers/registry.ts — the capture providers
// `just email-shots` routes to, in routing order.
//
// The local browser provider (backend a), the self-hosted webmail
// provider (Roundcube and SnappyMail, verification clients) and the
// Linux desktop provider (real desktop clients in a headless
// compositor: Thunderbird) and the hosted-webmail provider (backend b:
// the real Gmail, Yahoo Mail and Outlook.com after real delivery; opt-in,
// so it joins a run only when named). Clients in VM guests and a
// device-farm service join this list later; each declares its clients,
// requirements and health, and the harness routes, reports and caches
// for all of them alike.

import { BrowserEmulationProvider } from "./browser_emulation.ts";
import { HostedWebmailProvider } from "./hosted_webmail.ts";
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
    new HostedWebmailProvider({ env }),
  ];
}
