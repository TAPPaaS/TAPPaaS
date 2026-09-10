// fake-client.ts — in-memory Client for offline unit tests (no backup-controller,
// no PBS, no cluster). Records calls so tests can assert exactly what the manager
// asked the controller to do. Mirrors people-manager/test/unit/fake-client.ts.

import { Client, JobStatus, ScheduleBucket } from "../../src/types";

export class FakeClient implements Client {
  job: JobStatus = { jobId: null, vmids: [], storage: null, buckets: [], reachable: true };
  snapshots = new Map<string, string[]>();
  log: string[] = [];
  // Method names that throw when called — for failure-path tests (applyPlan
  // must continue past a failing action and report it).
  failOn = new Set<string>();

  seedJob(job: Partial<JobStatus>): void {
    this.job = { ...this.job, ...job };
  }
  seedSnapshots(module: string, snaps: string[]): void {
    this.snapshots.set(module, snaps);
  }

  // Seed a bucket job's membership (#627: coverage is the union over buckets,
  // so a test that only seeds `vmids` is only testing daily).
  seedBucket(bucket: ScheduleBucket, vmids: string[], jobId = `job-${bucket}`): void {
    this.job = {
      ...this.job,
      buckets: [...this.job.buckets.filter((b) => b.bucket !== bucket), { bucket, jobId, vmids }],
    };
    if (bucket === "daily") this.job = { ...this.job, jobId, vmids: [...vmids] };
  }

  jobStatus(): JobStatus {
    this.log.push("job-status");
    return {
      ...this.job,
      vmids: [...this.job.vmids],
      buckets: this.job.buckets.map((b) => ({ ...b, vmids: [...b.vmids] })),
    };
  }
  listSnapshots(module: string): string[] {
    this.log.push(`list ${module}`);
    return [...(this.snapshots.get(module) ?? [])];
  }
  addToJob(vmid: string, retention?: string, bucket?: string): void {
    if (this.failOn.has("addToJob")) throw new Error("simulated addToJob failure");
    this.log.push(
      `add-to-job ${vmid}${retention ? ` retention=${retention}` : ""}${bucket ? ` bucket=${bucket}` : ""}`,
    );
    // Mirror pbs_place_vmid: a guest belongs to exactly ONE bucket, so an add
    // is a move — otherwise a test could not tell a re-add from a placement.
    const b = (bucket ?? "daily") as ScheduleBucket;
    const others = this.job.buckets
      .filter((x) => x.bucket !== b)
      .map((x) => ({ ...x, vmids: x.vmids.filter((v) => v !== vmid) }));
    const cur = this.job.buckets.find((x) => x.bucket === b);
    const merged = cur && cur.vmids.includes(vmid) ? cur.vmids : [...(cur?.vmids ?? []), vmid];
    this.job = {
      ...this.job,
      buckets: [...others, { bucket: b, jobId: cur?.jobId ?? `job-${b}`, vmids: merged }],
    };
    if (b === "daily") this.job = { ...this.job, vmids: merged };
    else this.job = { ...this.job, vmids: this.job.vmids.filter((v) => v !== vmid) };
  }
  applySchedule(spec: string): void {
    if (this.failOn.has("applySchedule")) throw new Error("simulated applySchedule failure");
    this.log.push(`apply-schedule ${spec}`);
  }
  keyList(): void {
    this.log.push("key list");
  }
  keyExport(dest: string): void {
    this.log.push(`key export ${dest}`);
  }
  keyImport(src: string): void {
    this.log.push(`key import ${src}`);
  }
}
