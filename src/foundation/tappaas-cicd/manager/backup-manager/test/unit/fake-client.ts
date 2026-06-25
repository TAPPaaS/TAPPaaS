// fake-client.ts — in-memory Client for offline unit tests (no backup-controller,
// no PBS, no cluster). Records calls so tests can assert exactly what the manager
// asked the controller to do. Mirrors people-manager/test/unit/fake-client.ts.

import { Client, JobStatus } from "../../src/types";

export class FakeClient implements Client {
  job: JobStatus = { jobId: null, vmids: [], storage: null, reachable: true };
  snapshots = new Map<string, string[]>();
  ns: string[] = [];
  log: string[] = [];

  seedJob(job: Partial<JobStatus>): void {
    this.job = { ...this.job, ...job };
  }
  seedSnapshots(module: string, snaps: string[]): void {
    this.snapshots.set(module, snaps);
  }

  jobStatus(): JobStatus {
    this.log.push("job-status");
    return { ...this.job, vmids: [...this.job.vmids] };
  }
  listSnapshots(module: string): string[] {
    this.log.push(`list ${module}`);
    return [...(this.snapshots.get(module) ?? [])];
  }
  namespaces(): string[] {
    this.log.push("namespaces");
    return [...this.ns];
  }
  verify(module: string): void {
    this.log.push(`verify ${module}`);
  }
  addToJob(vmid: string, retention?: string): void {
    this.log.push(`add-to-job ${vmid}${retention ? ` retention=${retention}` : ""}`);
    if (!this.job.vmids.includes(vmid)) this.job.vmids = [...this.job.vmids, vmid];
  }
  applySchedule(spec: string): void {
    this.log.push(`apply-schedule ${spec}`);
  }
}
