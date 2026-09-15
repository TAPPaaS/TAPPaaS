// unitrun.ts — `site-manager update` drives update-tappaas.service (ADR-017 D4).
//
// A unit takes no arguments and `systemctl start` does not carry the caller's
// environment, so one run's options travel in a one-shot request file,
// config/.update-request.json. The unit's prepare step claims it (moves it into
// the unit's RuntimeDirectory), so it is used by exactly one run; a timer run
// has none, which is how the sweep tells a scheduled pass from an operator run.
// Pure helpers here; the systemctl / journalctl side is in client.ts.

import { existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";

export const UNIT = "update-tappaas.service";

export interface UpdateRequest {
  force: boolean;
  noGitPull: boolean;
  requestedBy: string;
  at: string; // ISO 8601
}

export function requestPath(configDir: string): string {
  return join(configDir.replace(/\/$/, ""), ".update-request.json");
}

export function buildRequest(force: boolean, noGitPull: boolean, by: string, now: Date): UpdateRequest {
  return { force, noGitPull, requestedBy: by, at: now.toISOString() };
}

export function writeRequest(configDir: string, req: UpdateRequest): string {
  const f = requestPath(configDir);
  writeFileSync(f, JSON.stringify(req) + "\n", "utf8");
  return f;
}

export function dropRequest(configDir: string): void {
  const f = requestPath(configDir);
  if (existsSync(f)) unlinkSync(f);
}

// The run's own summary line, from config/last-update-result.json — the same
// shape update-tappaas logs as its last line.
export function summaryLine(result: Record<string, unknown> | null): string {
  if (!result) return "no last-update-result.json — the run stopped before the sweep wrote one";
  if (result.stage && result.stage !== "sweep") {
    return `update-tappaas FAILED in the ${String(result.stage)} step (${String(result.end_time ?? "?")}) — no module was updated`;
  }
  const n = (k: string): string => String(result[k] ?? "?");
  return (
    `update-tappaas completed: ${n("end_time")} | control_plane=${n("control_plane")} total=${n("total")} ` +
    `succeeded=${n("succeeded")} failed=${n("failed")} not_attempted=${n("not_attempted")} ` +
    `skipped=${n("skipped")} reboot=${n("reboot")}`
  );
}

export function readResult(configDir: string): Record<string, unknown> | null {
  try {
    return JSON.parse(readFileSync(join(configDir, "last-update-result.json"), "utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
}

// One repository's line in `update --dry-run`: behind origin, current, or held.
export function repoStatusLine(name: string, branch: string, localHead: string | null,
  originTip: string | null, behind: number | null, hold: string | null): string {
  if (hold) return `${name} (${branch}): ${hold}`;
  if (!localHead) return `${name} (${branch}): no checkout`;
  if (!originTip) return `${name} (${branch}): origin not reachable — drift unknown`;
  if (originTip === localHead) return `${name} (${branch}): current`;
  if (behind === null) return `${name} (${branch}): behind origin (${originTip.slice(0, 8)} not fetched yet)`;
  return behind > 0
    ? `${name} (${branch}): ${behind} commit(s) behind origin`
    : `${name} (${branch}): ahead of origin or diverged (local ${localHead.slice(0, 8)}, origin ${originTip.slice(0, 8)})`;
}
