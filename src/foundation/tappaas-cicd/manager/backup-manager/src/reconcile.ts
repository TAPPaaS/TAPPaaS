// reconcile.ts — converge the resolved backup cascade → PBS (port of
// backup-manager.sh `reconcile`). The manager RESOLVES the Site→Environment→
// Module policy here (pure planning); the controller OWNS the PBS write
// (Client.addToJob / Client.applySchedule). NO PBS API is reimplemented here.
//
// Division of labour (ADR-007 verb-alignment #3, approved):
//   manager (this file)  : resolve the cascade, decide which modules belong in
//                          the shared PBS job + what schedule each resolves to,
//                          build the plan, drive apply.
//   controller           : add-to-job <vmid> / apply-schedule <spec> — the
//                          actual PBS mutation (reuses pbs_ensure_vmid etc.).
//
// reconcile is WHOLE-CLUSTER (iterates every deployed module) and PREVIEW by
// default; --apply commits. It is idempotent (the controller's add-to-job is a
// no-op when the vmid is already covered), so it is safe to run anytime.

import { listModules, moduleInPbsJob, moduleVmid, resolvePolicy } from "./config";
import { Action, Client, JobStatus, Plan } from "./types";

export function computePlan(configDir: string, job: JobStatus): Plan {
  const actions: Action[] = [];
  const warnings: string[] = [];

  if (!job.reachable) {
    warnings.push("PBS / cluster not reachable — reconcile is preview-only (controller offline)");
  }

  const liveVmids = new Set(job.vmids);

  // Track schedules requested by enabled modules so we apply the shared job's
  // start time once (the controller's apply-schedule sets the single shared
  // job; per-environment schedules are a follow-up).
  const schedules = new Set<string>();

  for (const module of listModules(configDir)) {
    const pol = resolvePolicy(configDir, module);
    if (!pol.enabled) continue; // disabled modules are not job members
    if (!moduleInPbsJob(configDir, module)) continue; // only dependsOn backup:vm modules join

    const vmid = moduleVmid(configDir, module);
    if (!vmid) {
      warnings.push(`module '${module}' is wired into the PBS job but has no vmid — skipped`);
      continue;
    }

    if (pol.schedule) schedules.add(pol.schedule);

    // ensure-job-member: idempotent. If the live job already covers this vmid
    // (and PBS is reachable so we know the live list), skip the action.
    if (job.reachable && liveVmids.has(vmid)) continue;

    actions.push({
      kind: "ensure-job-member",
      target: `module '${module}' (vmid ${vmid}) → PBS job member (retention ${pol.retention})`,
      apply: (client: Client) => client.addToJob(vmid, pol.retention),
    });
  }

  // One apply-schedule per distinct resolved schedule. Today the shared job
  // carries a single start time, so >1 distinct schedule is reported as a
  // warning (per-environment schedules are the documented follow-up) and the
  // first is applied for determinism.
  const scheduleList = Array.from(schedules).sort();
  if (scheduleList.length > 1) {
    warnings.push(
      `modules resolve ${scheduleList.length} distinct schedules (${scheduleList.join(", ")}); ` +
        `the shared PBS job carries one start time — applying '${scheduleList[0]}' ` +
        `(per-environment schedules are a follow-up)`,
    );
  }
  if (scheduleList.length >= 1) {
    const spec = scheduleList[0];
    actions.push({
      kind: "apply-schedule",
      target: `shared PBS job start time → '${spec}'`,
      apply: (client: Client) => client.applySchedule(spec),
    });
  }

  return { actions, warnings };
}

// Apply a plan via the client (the controller mutations). Returns the count
// applied.
export function applyPlan(client: Client, plan: Plan): number {
  for (const a of plan.actions) a.apply(client);
  return plan.actions.length;
}
