// tools/capture/briefs.ts — which review briefs a run writes for its
// real-client captures.
//
// Backend a's captures share one brief per (family, viewport, scheme)
// (`brief-<family>-<viewport>-<scheme>.md`, written by the brief driver
// before routing). Every capture another provider makes (a webmail, a
// desktop client) gets a brief of its own, named like the capture
// without its `-<images>.png`:
// `brief-<backend>-<family>-<client>-<viewport>-<scheme>.md`. The brief
// says what the client stands in for and what it is expected to show;
// the brief driver's `--client` mode writes it. This module turns a
// routed plan into those driver calls, so the selection is testable
// without running a capture.

// The part of a routed plan item this module reads (harness.ts PlanItem
// is structurally compatible).
export interface BriefPlanItem {
  kind: "capture" | "not-applicable" | "unserved";
  request: {
    story: string;
    backend: string;
    family: string;
    clientId: string;
    viewport: { name: string };
    scheme: string;
  };
}

// One brief-driver call: one story in one client, with every viewport
// and scheme the plan captures it in (first-seen order).
export interface ClientBriefJob {
  story: string;
  backend: string;
  family: string;
  clientId: string;
  viewports: string[];
  schemes: string[];
}

export function clientBriefName(
  backend: string,
  family: string,
  clientId: string,
  viewport: string,
  scheme: string,
): string {
  return `brief-${backend}-${family}-${clientId}-${viewport}-${scheme}.md`;
}

// The driver calls for the plan's real-client captures: every
// "capture" item not served by `browserBackend`. Rows the routing
// settled without a capture (not-applicable, unserved) get no brief:
// there is nothing for a reviewer to look at.
export function clientBriefJobs(
  items: readonly BriefPlanItem[],
  browserBackend: string,
): ClientBriefJob[] {
  const jobs = new Map<string, ClientBriefJob>();
  for (const item of items) {
    if (item.kind !== "capture") continue;
    const r = item.request;
    if (r.backend === browserBackend) continue;
    const key = `${r.story}\u0000${r.backend}\u0000${r.family}\u0000${r.clientId}`;
    let job = jobs.get(key);
    if (job === undefined) {
      job = {
        story: r.story,
        backend: r.backend,
        family: r.family,
        clientId: r.clientId,
        viewports: [],
        schemes: [],
      };
      jobs.set(key, job);
    }
    if (!job.viewports.includes(r.viewport.name))
      job.viewports.push(r.viewport.name);
    if (!job.schemes.includes(r.scheme)) job.schemes.push(r.scheme);
  }
  return [...jobs.values()];
}

// The brief files a job writes (the driver writes every viewport ×
// scheme combination of the job).
export function clientBriefFiles(job: ClientBriefJob): string[] {
  const out: string[] = [];
  for (const v of job.viewports)
    for (const s of job.schemes)
      out.push(clientBriefName(job.backend, job.family, job.clientId, v, s));
  return out;
}

// The brief driver's argument vector for a job.
export function clientBriefArgs(
  job: ClientBriefJob,
  storyDir: string,
): string[] {
  return [
    "--client",
    job.backend,
    job.family,
    job.clientId,
    job.story,
    storyDir,
    job.viewports.join(","),
    job.schemes.join(","),
  ];
}
