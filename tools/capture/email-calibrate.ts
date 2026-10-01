// tools/capture/email-calibrate.ts — `just email-calibrate`: check the
// crop calibration of the desktop mail clients now.
//
// Every capture run already calibrates a desktop client automatically
// when the client's build (or the provider's adapter version) differs
// from the last one calibrated; this runs the same check on demand,
// whatever is recorded: each client captures the calibration fixture (a
// message with a solid square in each corner of the message viewport)
// in every scheme it renders, the crop must hold exactly those squares,
// and a pass is recorded under build/email-shots/.calibration/. A
// failure leaves the whole output and the crop beside the record
// (<client>.failed/) and exits 1. The imap and assets services are
// started for the check and stopped after it.

import { dirname, join, resolve } from "node:path";
import { mkdirSync, rmSync } from "node:fs";
import { assessProviders } from "./providers/harness.ts";
import { LinuxDesktopProvider } from "./providers/linux_desktop.ts";
import { installSignalTeardown } from "./providers/services.ts";

const USAGE = `usage: email-calibrate [--clients C,…]

Checks the crop calibration of the linux-desktop clients (all of them,
or those named with --clients) now, whatever build was calibrated last,
and records each pass under build/email-shots/.calibration/. A capture
run does the same by itself for a client whose build changed since its
last calibration. Exits 1 when a client fails its calibration or the
provider is unavailable.
`;

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  let only: string[] | null = null;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--help") {
      process.stdout.write(USAGE);
      return 0;
    }
    if (a === "--clients" && args[i + 1] !== undefined) {
      only = args[++i]!.split(",").filter((c) => c !== "");
      continue;
    }
    process.stderr.write(`email-calibrate: unknown argument ${a}\n${USAGE}`);
    return 2;
  }
  const provider = new LinuxDesktopProvider();
  const clients = provider.clients().map((c) => c.clientId);
  for (const c of only ?? [])
    if (!clients.includes(c)) {
      process.stderr.write(
        `email-calibrate: '${c}' is not a desktop client (they are: ${clients.join(", ")})\n`,
      );
      return 2;
    }
  const run = `calibrate-${new Date().toISOString().replace(/[-:.]/g, "")}-${process.pid}`;
  const runDir = join(repoRoot, "build", "email-shots", ".calibration", run);
  mkdirSync(runDir, { recursive: true });
  installSignalTeardown();
  const { availability, services } = await assessProviders([provider], {
    run,
    runDir,
  });
  let failed = 0;
  try {
    const h = availability.get(provider.id);
    if (h === undefined || h.state === "unavailable") {
      process.stderr.write(
        `email-calibrate: ${provider.id} is unavailable: ${h !== undefined && h.state === "unavailable" ? h.reason : "unknown"}\n`,
      );
      return 1;
    }
    await provider.prepare({
      run,
      session: null,
      runDir,
      planned: [],
      assert: false,
      cold: false,
      services: services.handlesFor(provider),
    });
    for (const client of only ?? clients) {
      const r = await provider.calibrate(client, true);
      const where = r.ok ? ` (recorded: ${r.recordPath})` : "";
      process.stdout.write(
        `${client} ${r.build}: ${r.ok ? "ok" : "FAILED"} in ${(r.timingMs / 1000).toFixed(1)} s${where}\n`,
      );
      for (const c of r.checks)
        process.stdout.write(
          `  ${c.viewport.name}@${c.viewport.dpr} ${c.scheme}: crop ${c.crop.width}x${c.crop.height}+${c.crop.x}+${c.crop.y}, corners ${JSON.stringify(c.check.corners)} (want ${c.check.expected})\n`,
        );
      for (const p of r.problems) process.stdout.write(`  problem: ${p}\n`);
      if (!r.ok) failed++;
    }
  } finally {
    await provider.dispose();
    await services.stopAll();
    rmSync(runDir, { recursive: true, force: true });
  }
  return failed === 0 ? 0 : 1;
}

process.exitCode = await main();
