// hold.ts — hold the scheduled pull of one repository on this site (#653).
//
// A hold is a local marker, config/.repo-hold/<repo>.json. While it is active
// the control-plane refresh (refresh-control-plane.sh) skips the pull for that
// repository and runs the rest of the sweep on whatever is checked out — so a
// test site can put unpushed changes through real sweeps. Every hold expires:
// an expired hold warns, is removed, and the next sweep pulls again, so a
// forgotten hold cannot freeze a site. lib/repo-hold.sh reads the same file.

import { existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";

export interface RepoHold {
  repository: string;
  reason: string;
  by: string;
  since: string; // ISO 8601, UTC
  until: string; // ISO 8601, UTC
  untilEpoch: number; // seconds; what the bash reader compares
}

export const DEFAULT_HOLD = "24h";

export function holdDir(configDir: string): string {
  return join(configDir.replace(/\/$/, ""), ".repo-hold");
}

// "--until" accepts a duration (30m, 12h, 7d) or an ISO date / date-time.
// Returns epoch seconds, or throws with a message fit for the operator.
export function parseUntil(spec: string, nowSec: number): number {
  const m = /^(\d+)([mhd])$/.exec(spec);
  if (m) {
    const n = Number(m[1]);
    const unit = { m: 60, h: 3600, d: 86400 }[m[2] as "m" | "h" | "d"];
    if (n <= 0) throw new Error(`--until ${spec}: the duration must be positive`);
    return nowSec + n * unit;
  }
  const t = Date.parse(spec);
  if (Number.isNaN(t)) {
    throw new Error(`--until ${spec}: expected a duration (30m, 12h, 7d) or an ISO date/time`);
  }
  const sec = Math.floor(t / 1000);
  if (sec <= nowSec) throw new Error(`--until ${spec}: that is not in the future`);
  return sec;
}

export function makeHold(repository: string, reason: string, by: string, untilSec: number, nowSec: number): RepoHold {
  return {
    repository,
    reason,
    by,
    since: new Date(nowSec * 1000).toISOString(),
    until: new Date(untilSec * 1000).toISOString(),
    untilEpoch: untilSec,
  };
}

export function isActive(h: RepoHold, nowSec: number): boolean {
  return h.untilEpoch > nowSec;
}

export function writeHold(configDir: string, h: RepoHold): string {
  const dir = holdDir(configDir);
  mkdirSync(dir, { recursive: true });
  const f = join(dir, `${h.repository}.json`);
  writeFileSync(f, JSON.stringify(h, null, 2) + "\n", "utf8");
  return f;
}

// Removes the hold; returns false when there was none.
export function releaseHold(configDir: string, repository: string): boolean {
  const f = join(holdDir(configDir), `${repository}.json`);
  if (!existsSync(f)) return false;
  unlinkSync(f);
  return true;
}

// Every readable hold, keyed by repository. A file that does not parse is
// skipped here (the bash reader treats it as no hold too).
export function readHolds(configDir: string): Map<string, RepoHold> {
  const out = new Map<string, RepoHold>();
  const dir = holdDir(configDir);
  if (!existsSync(dir)) return out;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    try {
      const h = JSON.parse(readFileSync(join(dir, f), "utf8")) as RepoHold;
      if (typeof h.untilEpoch === "number" && typeof h.repository === "string") out.set(h.repository, h);
    } catch {
      // unreadable marker: ignored
    }
  }
  return out;
}

// One line for `repository list` / `update`.
export function describeHold(h: RepoHold, nowSec: number): string {
  return isActive(h, nowSec)
    ? `HELD until ${h.until} by ${h.by}: ${h.reason}`
    : `hold EXPIRED ${h.until} (the next sweep pulls again)`;
}
