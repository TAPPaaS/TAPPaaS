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

import { listBackupModules, moduleInPbsJob, moduleVmid, resolvePolicy } from "./config";
import { Action, Client, JobStatus, Plan } from "./types";

export function computePlan(configDir: string, job: JobStatus): Plan {
  const actions: Action[] = [];
  const warnings: string[] = [];

  if (!job.reachable) {
    warnings.push("PBS / cluster not reachable — reconcile is preview-only (controller offline)");
  }

  const liveVmids = new Set(job.vmids);

  // Each module's resolved schedule decides WHICH job it belongs in — one
  // cluster backup job per distinct frequency (ADR-012 D16). The controller's
  // add-to-job carries the bucket, so a schedule change is a move between jobs.
  const buckets = new Set<string>();

  // Target discovery is the opted-in set (#544): real modules, shape-detected,
  // that declare a backup capability under dependsOn or integratesWith. It used
  // to be every *.json in config/ minus a five-name deny-list, which swept up
  // state files as phantom modules.
  for (const module of listBackupModules(configDir)) {
    const pol = resolvePolicy(configDir, module);
    if (!pol.enabled) continue; // disabled modules are not job members
    if (!moduleInPbsJob(configDir, module)) continue; // backup:vm opt-in only (not filesystem)

    const vmid = moduleVmid(configDir, module);
    if (!vmid) {
      warnings.push(`module '${module}' is wired into the PBS job but has no vmid — skipped`);
      continue;
    }

    if (!pol.scheduleBucket) {
      warnings.push(
        `module '${module}' has unsupported schedule '${pol.schedule}' — skipped ` +
          `(use daily | weekly | monthly | HH:MM; see 'backup-manager validate')`,
      );
      continue;
    }
    buckets.add(pol.scheduleBucket);

    // ensure-job-member: idempotent. If the live job already covers this vmid
    // (and PBS is reachable so we know the live list), skip the action.
    // The live vmid set we can see is the DAILY job's, so this skip is only
    // safe for a module that resolves to daily; anything else must be placed
    // explicitly so a schedule change actually moves it.
    if (job.reachable && liveVmids.has(vmid) && pol.scheduleBucket === "daily") continue;

    actions.push({
      kind: "ensure-job-member",
      target: `module '${module}' (vmid ${vmid}) → ${pol.scheduleBucket} PBS job (retention ${pol.retention})`,
      apply: (client: Client) => client.addToJob(vmid, pol.retention, pol.scheduleBucket ?? "daily"),
    });
  }

  // Each distinct bucket in use gets its schedule asserted on its own job.
  // Several distinct schedules is now the NORMAL case, not a warning — that is
  // what buckets are for.
  for (const bucket of Array.from(buckets).sort()) {
    actions.push({
      kind: "apply-schedule",
      target: `${bucket} PBS job schedule`,
      apply: (client: Client) => client.applySchedule(bucket),
    });
  }

  return { actions, warnings };
}

export interface ApplyOutcome {
  applied: number;
  total: number;
  failures: { target: string; message: string }[];
}

// Apply a plan via the client (the controller mutations), continuing past a
// failing action so one bad mutation cannot silently strand the rest of the
// plan — the caller reports "applied N of M" and fails on any failure.
export function applyPlan(client: Client, plan: Plan): ApplyOutcome {
  const failures: { target: string; message: string }[] = [];
  let applied = 0;
  for (const a of plan.actions) {
    try {
      a.apply(client);
      applied++;
    } catch (e) {
      failures.push({
        target: `${a.kind}: ${a.target}`,
        message: e instanceof Error ? e.message : String(e),
      });
    }
  }
  return { applied, total: plan.actions.length, failures };
}
