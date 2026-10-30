// job.ts — the console job a manager verb runs in (ADR-040 D4, D6): every
// change report names it. The console sets TAPPAAS_JOB_ID (its Activity id
// for the job) and TAPPAAS_ACTOR (the console user) on each verb it runs; a
// verb run from a shell has no job, and its actor is the OS user.
// The bash managers' equivalent: cmdb_current_job in lib/cmdb-report.sh.

import { userInfo } from "os";

export interface CurrentJob {
  id?: string;
  actor: string;
}

/** The console job and actor a verb runs for, from its environment. */
export function currentJob(env: Record<string, string | undefined> = process.env): CurrentJob {
  const id = env.TAPPAAS_JOB_ID || undefined;
  return { ...(id ? { id } : {}), actor: env.TAPPAAS_ACTOR || osUser(env) };
}

function osUser(env: Record<string, string | undefined>): string {
  try {
    const u = userInfo().username;
    if (u) return u;
  } catch {
    // no passwd entry for the uid (a container): $USER, if anything
  }
  return env.USER || "unknown";
}

/** The job and actor as a change report carries them: {job?, actor}. */
export function changeJob(env: Record<string, string | undefined> = process.env): { job?: string; actor: string } {
  const j = currentJob(env);
  return { ...(j.id ? { job: j.id } : {}), actor: j.actor };
}
