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
// No service is registered yet; the registry and the lifecycle are here
// so the providers that need them plug in without reshaping the harness.

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
  return {};
}

type ServiceRequirement = Requirement & { kind: "service" };

export function serviceRequirements(
  provider: CaptureProvider,
): ServiceRequirement[] {
  return provider
    .requirements()
    .filter((r): r is ServiceRequirement => r.kind === "service");
}

// The services of one run: the ones started (with their handles) and
// the ones that could not be (with the reason).
export class RunServices {
  private readonly running = new Map<
    ServiceName,
    { service: LocalService; handle: ServiceHandle }
  >();
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
      try {
        this.running.set(name, { service, handle: await service.start(info) });
      } catch (err) {
        await service.stop().catch(() => {});
        this.failed.set(
          name,
          `service ${name} failed to start: ${err instanceof Error ? err.message : String(err)}`,
        );
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
    const all = [...this.running.values()].reverse();
    this.running.clear();
    for (const { service } of all) await service.stop().catch(() => {});
  }
}
