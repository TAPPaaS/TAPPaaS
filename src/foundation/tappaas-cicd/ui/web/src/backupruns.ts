// backupruns.ts — the Backup overview's last backup and last verify, from
// `backup-manager restore list-all --json`: a line per target, the job runs,
// what needs a look, and each module's own pair for the Modules table. Plain
// data, no React: the unit tests run it over hrossen's answer.

import { BackupRuns, GuestRuns, JobLastRun, LastVerify, TargetRuns } from "./types";

// How long ago, in the largest unit that fits ("3 h ago", "2 d ago").
export function ago(epoch: number | null | undefined, nowSec: number): string {
  if (!epoch) return "never";
  const s = Math.max(0, nowSec - epoch);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 2 * 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} d ago`;
}

export function targetLabel(t: { ns: string; kind: string }): string {
  switch (t.kind) {
    case "own":
      return "this site's guests";
    case "host":
      return `${t.ns.split("/").slice(1).join("/") || "hosts"}: files`;
    case "pull":
      return `${t.ns.split("/").slice(1).join("/") || "pulled"}: their copy, pulled here`;
    case "receive":
      return `${t.ns.split("/").slice(1).join("/") || t.ns}: their copy, pushed here`;
    default:
      return t.ns;
  }
}

export type Level = "pass" | "warn" | "fail" | "skip";

// A verify: failed is a failure; none at all on a target with snapshots, a warning.
export function verifyLevel(v: LastVerify | null): Level {
  return !v ? "warn" : v.state === "ok" ? "pass" : "fail";
}

export function guestLevel(g: GuestRuns): Level {
  if (g.latestVerify === "failed" || (g.outcome === "late" && g.snapshots === 0)) return "fail";
  if (g.outcome === "late") return "warn";
  if (g.outcome === "not-in-job") return "skip";
  return "pass";
}

export function targetLevel(t: TargetRuns): Level {
  if (t.failedVerifies > 0) return "fail";
  if (!t.lastVerify || t.unverified > 0) return "warn";
  return "pass";
}

export function runLevel(r: JobLastRun | { state: string } | null): Level {
  if (!r) return "skip";
  return r.state === "OK" ? "pass" : r.state === "running" ? "skip" : "fail";
}

// The guests that need a look: late, never backed up, or a failed verify.
// A guest no job covers is not a problem (a removed guest's backups, kept).
export function attention(r: BackupRuns): GuestRuns[] {
  return r.guests.filter((g) => g.ns === "" && (g.outcome === "late" || g.latestVerify === "failed" || g.failedVerifies > 0));
}

// Each module's own guest, for the Modules table.
export function byModule(r: BackupRuns | null): Map<string, GuestRuns> {
  const m = new Map<string, GuestRuns>();
  for (const g of r?.guests ?? []) if (g.ns === "" && g.module && !m.has(g.module)) m.set(g.module, g);
  return m;
}

// The newest scheduled run per node (an on-demand one names its guest).
export function latestRuns(r: BackupRuns): BackupRuns["runs"] {
  const seen = new Set<string>();
  const out: BackupRuns["runs"] = [];
  for (const x of r.runs) {
    if (x.guest !== null || seen.has(x.node)) continue;
    seen.add(x.node);
    out.push(x);
  }
  return out;
}

// One line for the whole: "20 guests backed up on time, all verified".
export function summary(r: BackupRuns): string {
  const own = r.guests.filter((g) => g.ns === "" && g.outcome !== "not-in-job");
  const late = own.filter((g) => g.outcome === "late").length;
  const failed = own.filter((g) => g.latestVerify === "failed").length;
  const unverified = own.filter((g) => g.latestVerify === "unverified").length;
  const parts = [late === 0 ? `${own.length} guest${own.length === 1 ? "" : "s"} backed up on time` : `${late} of ${own.length} guests late`];
  parts.push(failed > 0 ? `${failed} failed verify` : unverified > 0 ? `${unverified} newest not yet verified` : "all verified");
  return parts.join(", ");
}
