// unitrun.ts — `site-manager update` drives update-tappaas.service (ADR-017 D4).
//
// A unit takes no arguments and `systemctl start` does not carry the caller's
// environment, so one run's options travel in a one-shot request file,
// config/.update-request.json. The unit's prepare step claims it (moves it into
// the unit's RuntimeDirectory), so it is used by exactly one run; a timer run
// has none, which is how the sweep tells a scheduled pass from an operator run.
// Pure helpers here; the systemctl / journalctl side is in client.ts.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { unlinkGuarded, writeFileGuarded } from "../../../lib/ts/src/config-io";

export const UNIT = "update-tappaas.service";

export interface UpdateRequest {
  // ADR-020 v0.10 D8: force = proceed past a refusal; allowDisruption = open the
  // downtime window for rebootOk modules. Two levers, never one.
  force: boolean;
  allowDisruption: boolean;
  noGitPull: boolean;
  requestedBy: string;
  at: string; // ISO 8601
}

export function requestPath(configDir: string): string {
  return join(configDir.replace(/\/$/, ""), ".update-request.json");
}

export function buildRequest(force: boolean, allowDisruption: boolean, noGitPull: boolean, by: string, now: Date): UpdateRequest {
  return { force, allowDisruption, noGitPull, requestedBy: by, at: now.toISOString() };
}

export function writeRequest(configDir: string, req: UpdateRequest): string {
  const f = requestPath(configDir);
  writeFileGuarded(f, JSON.stringify(req) + "\n", "utf8");
  return f;
}

export function dropRequest(configDir: string): void {
  const f = requestPath(configDir);
  if (existsSync(f)) unlinkGuarded(f);
}

// A graceful stop (`site-manager update --stop`): config/.update-stop names the
// run it is for by the unit's InvocationID. The sweep reads it before each
// module, so the module in progress finishes; it then skips the rest and records
// the run as interrupted. A request left behind names an invocation that is
// over, so it can never stop the next run.
export interface StopRequest {
  requestedBy: string;
  at: string; // ISO 8601
  invocation: string;
}

export function stopPath(configDir: string): string {
  return join(configDir.replace(/\/$/, ""), ".update-stop");
}

export function writeStop(configDir: string, req: StopRequest): string {
  const f = stopPath(configDir);
  writeFileGuarded(f, JSON.stringify(req) + "\n", "utf8");
  return f;
}

// The run's own summary line, from config/last-update-result.json — the same
// shape update-tappaas logs as its last line.
export function summaryLine(result: Record<string, unknown> | null): string {
  if (!result) return "no last-update-result.json — the run stopped before the sweep wrote one";
  if (result.stage && result.stage !== "sweep") {
    return `update-tappaas FAILED in the ${String(result.stage)} step (${String(result.end_time ?? "?")}) — no module was updated`;
  }
  const n = (k: string): string => String(result[k] ?? "?");
  if (result.result === "interrupted") {
    const i = (result.interrupted ?? {}) as Record<string, unknown>;
    return (
      `update-tappaas STOPPED on request of ${String(i.requestedBy ?? "?")} (${n("end_time")}) | ` +
      `succeeded=${n("succeeded")} failed=${n("failed")} not_attempted=${n("not_attempted")} — ` +
      `the next update takes the rest`
    );
  }
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

// ── following a run (`site-manager update`) ──────────────────────────────
// The run outlives the follower's view of systemd: early on the mothership
// switches its own NixOS system, and that switch re-executes PID 1 and restarts
// journald. While PID 1 re-executes, `systemctl show` fails for a moment
// ("Connection reset by peer"). The old follower read that as "the run is over",
// stopped following and printed the previous run's result. So the run is over
// only when systemd SAYS so (ActiveState inactive/failed, or a newer invocation);
// a failed query is a hiccup, retried. The journal is read by cursor, one short
// journalctl per poll, so a hiccup on either side loses or repeats no line.
export interface UnitProbe {
  ok: boolean; // systemd answered
  state: string; // ActiveState
  invocation: string; // InvocationID
  interrupted?: boolean; // Ctrl-C reached the query
}

export interface JournalPoll {
  ok: boolean;
  text: string; // the new lines, as the run printed them
  cursor: string | null; // where the next poll starts (null: nothing read yet)
  interrupted?: boolean;
}

export interface FollowIO {
  probe(): UnitProbe;
  poll(after: string | null): JournalPoll;
  sleep(seconds: number): boolean; // true when Ctrl-C reached it
  write(text: string): void;
  note(line: string): void;
  now(): number; // ms
}

export type FollowEnd = "finished" | "detached" | "lost";

// How long systemd may stay unreachable before the follower gives up (the run
// itself is not touched). A re-exec takes well under a second.
export const FOLLOW_LOST_AFTER_MS = 5 * 60 * 1000;
export const REATTACHED_NOTE = "the mothership switched its own system under the run — still following";

const RUNNING = new Set(["active", "activating", "deactivating", "reloading"]);

// The cursor journalctl --show-cursor prints last; the lines before it are the run's.
export function splitCursor(out: string): { text: string; cursor: string | null } {
  const m = /(^|\n)-- cursor: (\S+)\n?$/.exec(out);
  if (!m) return { text: out, cursor: null };
  return { text: out.slice(0, m.index + m[1].length), cursor: m[2] };
}

export function followRun(invocationId: string, io: FollowIO, pollSeconds = 1): FollowEnd {
  let cursor: string | null = null;
  let hiccup = false;
  let noted = false;
  let unreachableSince: number | null = null;
  const drain = (): boolean => {
    const p = io.poll(cursor);
    if (p.interrupted) return false;
    if (p.ok) {
      if (p.text) io.write(p.text);
      if (p.cursor) cursor = p.cursor;
    } else {
      hiccup = true;
    }
    return true;
  };
  for (;;) {
    if (!drain()) return "detached";
    const u = io.probe();
    if (u.interrupted) return "detached";
    if (!u.ok) {
      hiccup = true;
      unreachableSince ??= io.now();
      if (io.now() - unreachableSince >= FOLLOW_LOST_AFTER_MS) return "lost";
    } else {
      unreachableSince = null;
      const ours = !invocationId || !u.invocation || u.invocation === invocationId;
      if (!RUNNING.has(u.state) || !ours) {
        // Over. journald may still hold the last lines a moment.
        if (!drain()) return "detached";
        if (io.sleep(1)) return "detached";
        drain();
        return "finished";
      }
      if (hiccup && !noted) {
        io.note(REATTACHED_NOTE);
        noted = true;
      }
      hiccup = false;
    }
    if (io.sleep(pollSeconds)) return "detached";
  }
}
