// activity.ts — Activity in P1 (ADR-034 D4): what the sweep did, read-only.
// The nightly `update-tappaas.service` runs are cut from its journal — a run
// starts at systemd's "Starting TAPPaaS scheduler" and ends at "Finished"
// (succeeded) or a "Failed" line — keeping the errors and warnings each run
// logged; beside them the failures ledger (config/update-tappaas.failures) and
// the last run's result file. From P2 the console's own jobs join this list.

export interface JournalEntry {
  at: string; // as the journal prints it (ISO with offset)
  message: string;
  pid1: boolean; // logged by systemd itself (the unit's start and end)
}

export interface RunLine {
  at: string;
  level: "error" | "warning";
  text: string;
}

export interface SweepRun {
  start: string;
  end: string | null;
  result: "ok" | "failed" | "running" | "unknown";
  lines: RunLine[];
  truncated: number; // lines beyond the cap, not kept
}

const ANSI = /\x1b\[[0-9;]*m/g;
const MAX_LINES = 200;

// `journalctl -o short-iso`: "<ISO time> <host> <ident>[<pid>]: <message>".
const SHORT_ISO = /^(\d{4}-\d{2}-\d{2}T[0-9:.]+(?:Z|[+-]\d{2}:?\d{2}))\s+\S+\s+([^\s:[]+)(?:\[(\d+)\])?:\s?(.*)$/;

export function parseJournal(text: string): JournalEntry[] {
  const out: JournalEntry[] = [];
  for (const line of text.split("\n")) {
    const m = SHORT_ISO.exec(line);
    if (!m) continue; // "-- No entries --", a boot marker
    out.push({ at: m[1], message: m[4].replace(ANSI, ""), pid1: m[2] === "systemd" && m[3] === "1" });
  }
  return out;
}

function levelOf(e: JournalEntry): "error" | "warning" | null {
  if (/\[Error\]|\bFAILED\b/.test(e.message)) return "error";
  if (/\[Warning\]|\[WARN\]/.test(e.message)) return "warning";
  return null;
}

export function sweepRuns(entries: JournalEntry[]): SweepRun[] {
  const runs: SweepRun[] = [];
  let cur: SweepRun | null = null;
  for (const e of entries) {
    if (e.pid1 && /^Starting TAPPaaS scheduler/.test(e.message)) {
      if (cur && cur.result === "running") cur.result = "unknown"; // started again without an end
      cur = { start: e.at, end: null, result: "running", lines: [], truncated: 0 };
      runs.push(cur);
      continue;
    }
    if (!cur) continue;
    if (e.pid1 && /^Finished TAPPaaS scheduler/.test(e.message)) {
      cur.end = e.at;
      cur.result = "ok";
      continue;
    }
    if (e.pid1 && /(Failed with result|: Failed\b|^Failed to start TAPPaaS scheduler)/.test(e.message)) {
      cur.end = cur.end ?? e.at;
      cur.result = "failed";
      continue;
    }
    if (e.pid1) continue;
    const level = levelOf(e);
    if (!level) continue;
    if (cur.lines.length >= MAX_LINES) cur.truncated++;
    else cur.lines.push({ at: e.at, level, text: e.message.trim() });
  }
  return runs.reverse(); // newest first
}

// config/update-tappaas.failures: "<ISO time> <text>" per line.
export function parseLedger(text: string): { at: string | null; text: string }[] {
  return text
    .split("\n")
    .filter((l) => l.trim().length > 0)
    .map((l) => {
      const m = /^(\d{4}-\d{2}-\d{2}T\S+)\s+(.*)$/.exec(l.trim());
      return m ? { at: m[1], text: m[2] } : { at: null, text: l.trim() };
    })
    .reverse();
}

// A module's slice of the sweep: the lines that name it.
export function linesNaming(runs: SweepRun[], module: string): { run: string; line: RunLine }[] {
  const re = new RegExp(`(^|[^A-Za-z0-9-])${module.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}([^A-Za-z0-9-]|$)`);
  const out: { run: string; line: RunLine }[] = [];
  for (const r of runs) for (const l of r.lines) if (re.test(l.text)) out.push({ run: r.start, line: l });
  return out;
}
