// tools/capture/providers/services.ts — shared local services the
// harness owns on behalf of the capture providers.
//
// Some resources are needed by several providers at once: the IMAP
// server real clients open their message from, a loopback server for
// asset URLs. A provider declares such a service as a requirement
// ({ kind: "service", name, why }); the harness starts each declared
// service once per run, after the requirement and health checks and
// before any provider is prepared, hands the running service's handle
// to every provider that declared it (SessionCtx.services), and stops
// it after the last provider has been disposed. A service that is not
// registered, or fails to start, makes every provider that declared it
// unavailable with that reason.
//
// Two services are registered: `imap` (Dovecot as the current user,
// imap_service.ts) and `assets` (the story images over loopback HTTP,
// which is also the egress guard proxy, assets_service.ts). Neither is
// started unless an available provider declares it.

import { AssetsService } from "./assets_service.ts";
import { DovecotService } from "./imap_service.ts";
import type {
  CaptureProvider,
  ProviderHealth,
  Requirement,
  ServiceHandle,
  ServiceName,
} from "./types.ts";

// What a service is started with.
export interface ServiceRunInfo {
  run: string;
  runDir: string;
}

// One startable service. start() is called at most once per instance.
export interface LocalService {
  start(info: ServiceRunInfo): Promise<ServiceHandle>;
  stop(): Promise<void>;
}

// The services the harness can start, by name: a fresh instance per run.
export type ServiceRegistry = Partial<Record<ServiceName, () => LocalService>>;

export function registeredServices(): ServiceRegistry {
  return {
    imap: () => new DovecotService(),
    assets: () => new AssetsService(),
  };
}

type ServiceRequirement = Requirement & { kind: "service" };

export function serviceRequirements(
  provider: CaptureProvider,
): ServiceRequirement[] {
  return provider
    .requirements()
    .filter((r): r is ServiceRequirement => r.kind === "service");
}

// Every RunServices with something started or starting, for the
// signal teardown below.
const live = new Set<RunServices>();
let teardownInstalled = false;

// Installs the run's SIGINT/SIGTERM handlers: stop every started
// service (and every one still starting), then exit with the
// conventional code (130, 143). A second signal exits at once. Called
// once by the email-shots process before any service starts.
export function installSignalTeardown(): void {
  if (teardownInstalled) return;
  teardownInstalled = true;
  let stopping = false;
  const handle = (signal: NodeJS.Signals, code: number): void => {
    process.on(signal, () => {
      if (stopping) process.exit(code);
      stopping = true;
      process.stderr.write(
        `email-shots: ${signal}: stopping the local services\n`,
      );
      void Promise.allSettled([...live].map((s) => s.stopAll())).then(() =>
        process.exit(code),
      );
    });
  };
  handle("SIGINT", 130);
  handle("SIGTERM", 143);
}

// The services of one run: the ones started (with their handles) and
// the ones that could not be (with the reason).
export class RunServices {
  private readonly running = new Map<
    ServiceName,
    { service: LocalService; handle: ServiceHandle }
  >();
  // Started but not yet answered: stopAll() stops these too.
  private readonly starting = new Set<LocalService>();
  private readonly failed = new Map<ServiceName, string>();

  // The running services a provider declared, by name.
  handlesFor(
    provider: CaptureProvider,
  ): Partial<Record<ServiceName, ServiceHandle>> {
    const out: Partial<Record<ServiceName, ServiceHandle>> = {};
    for (const r of serviceRequirements(provider)) {
      const s = this.running.get(r.name);
      if (s !== undefined) out[r.name] = s.handle;
    }
    return out;
  }

  // Why a provider cannot run for want of its services, or null.
  unmetFor(provider: CaptureProvider): string | null {
    const reasons: string[] = [];
    for (const r of serviceRequirements(provider)) {
      const why = this.failed.get(r.name);
      if (why !== undefined) reasons.push(`${why} (needed: ${r.why})`);
    }
    return reasons.length === 0 ? null : reasons.join("; ");
  }

  // Starts, once each, every service an available provider declares;
  // then marks unavailable each available provider one of whose
  // services is unregistered or failed to start. Mutates availability.
  async start(
    providers: CaptureProvider[],
    availability: Map<string, ProviderHealth>,
    registry: ServiceRegistry,
    info: ServiceRunInfo,
  ): Promise<void> {
    const wanted: ServiceName[] = [];
    for (const p of providers) {
      const h = availability.get(p.id);
      if (h === undefined || h.state === "unavailable") continue;
      for (const r of serviceRequirements(p))
        if (!wanted.includes(r.name)) wanted.push(r.name);
    }
    for (const name of wanted) {
      if (this.running.has(name) || this.failed.has(name)) continue;
      const make = Object.hasOwn(registry, name) ? registry[name] : undefined;
      if (make === undefined) {
        this.failed.set(name, `service ${name} is not registered`);
        continue;
      }
      const service = make();
      live.add(this);
      this.starting.add(service);
      try {
        this.running.set(name, { service, handle: await service.start(info) });
      } catch (err) {
        await service.stop().catch(() => {});
        this.failed.set(
          name,
          `service ${name} failed to start: ${err instanceof Error ? err.message : String(err)}`,
        );
      } finally {
        this.starting.delete(service);
      }
    }
    for (const p of providers) {
      const h = availability.get(p.id);
      if (h === undefined || h.state === "unavailable") continue;
      const unmet = this.unmetFor(p);
      if (unmet !== null)
        availability.set(p.id, { state: "unavailable", reason: unmet });
    }
  }

  // Stops every running service, in reverse start order.
  async stopAll(): Promise<void> {
    const all = [
      ...[...this.starting].map((service) => ({ service })),
      ...[...this.running.values()].reverse(),
    ];
    this.starting.clear();
    this.running.clear();
    live.delete(this);
    for (const { service } of all) await service.stop().catch(() => {});
  }
}
