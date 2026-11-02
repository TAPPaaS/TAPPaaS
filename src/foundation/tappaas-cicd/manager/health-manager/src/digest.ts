// digest.ts — the daily digest's mail (ADR-041 D4): what is new since the last
// digest told, what is still open, what cleared.
//
// tappaas-alert-receiver asks for it when HealthDailyDigest fires, and tells it
// back with --mark once the mail went. A digest with something new is an ALERT;
// one that repeats what the last one told is a STATUS.
//
// A finding is a root condition nobody acknowledged, or a difference of the last
// sweep nothing explains. Symptoms and roll-ups follow their root and are left
// out, and an address is a count: leases come and go, and a day of them is no
// news.

import { createHash } from "crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "fs";
import { join } from "path";
import { SweepDifference, SweepRecord, WORD } from "./cmdbsweep";
import { ListRow } from "./emit-read";

const SEEN_FILE = ".health-digest-seen.json";
const MAX_NEW = 30;
const MAX_NAMES = 6;
const MAX_MESSAGE = 72;
// The sweep's findings are listed from its record; a condition that only repeats
// one is left out. sweep-none, -stale and -source-failed are about the sweep itself.
const SWEEP_FINDING = /^sweep-(changed|appeared|gone|unmanaged|missing|desired|unread)$/;

export interface DigestSeen {
  at: string;
  keys: string[];
}

export interface DigestDoc {
  word: "ALERT" | "STATUS";
  subject: string;
  body: string;
  new: number;
  open: number;
  keys: string[];
}

interface Finding {
  key: string;
  object: string;
  what: string; // a row of NEW
  group: string; // its line in STILL OPEN
  condition: boolean; // a condition can clear; a sweep's difference is only replaced by the next sweep's
}

const clip = (s: string): string => {
  const one = s.replace(/\s+/g, " ").trim();
  return one.length > MAX_MESSAGE ? `${one.slice(0, MAX_MESSAGE - 1)}…` : one;
};
const minute = (iso: string): string => `${iso.slice(0, 16).replace("T", " ")} UTC`;

function conditionFindings(rows: ListRow[]): Finding[] {
  return rows
    .filter((r) => r.status === "warning" || r.status === "critical")
    .filter((r) => !r.derived && !r.acknowledged && !r.maintenance)
    .filter((r) => !r.rootCause || r.rootCause === r.id)
    .filter((r) => !SWEEP_FINDING.test(r.reason ?? ""))
    .map((r) => {
      const object = `${r.class}/${r.name}`;
      const reason = r.reason ?? "unknown";
      return {
        key: `${object} ${r.type} ${reason}`,
        object,
        what: `${r.status === "critical" ? "CRITICAL " : ""}${clip(r.message || reason)}`,
        group: `${r.type} ${reason}`,
        condition: true,
      };
    });
}

function sweepFindings(diffs: SweepDifference[]): Finding[] {
  const objects = new Set(diffs.filter((d) => !d.attribute).map((d) => `${d.class}/${d.name} ${d.kind}`));
  return diffs
    .filter((d) => !d.attribute?.startsWith("→") || !objects.has(`${d.class}/${d.name} ${d.kind}`))
    .map((d) => {
      const object = `${d.class}/${d.name}`;
      const word = WORD[d.kind] ?? d.kind;
      // The same attribute changing again, to another value, is a new finding.
      const value = createHash("sha1").update(JSON.stringify(d.after ?? null)).digest("hex").slice(0, 8);
      return {
        key: `sweep ${object} ${d.kind} ${d.attribute ?? ""} ${value}`,
        object,
        what: clip(`${word}${d.attribute ? ` ${d.attribute}` : ""}`),
        group: `sweep ${word}`,
        condition: false,
      };
    });
}

function groupLines(found: Finding[]): string[] {
  const groups = new Map<string, string[]>();
  for (const f of found) groups.set(f.group, [...(groups.get(f.group) ?? []), f.object]);
  return [...groups.entries()]
    .sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]))
    .map(([g, objs]) => {
      const names = [...new Set(objs)];
      const more = names.length > MAX_NAMES ? `, +${names.length - MAX_NAMES} more` : "";
      return `  ${g} (${objs.length}): ${names.slice(0, MAX_NAMES).join(", ")}${more}`;
    });
}

/** The digest. Pure: seen is what the last one told, null before the first. */
export function buildDigest(rows: ListRow[], sweep: SweepRecord | null, seen: DigestSeen | null): DigestDoc {
  const unexplained = (sweep?.differences ?? []).filter((d) => !d.expected);
  const addresses = unexplained.filter((d) => d.class === "address" && !d.attribute);
  const found = [...conditionFindings(rows), ...sweepFindings(unexplained.filter((d) => d.class !== "address"))];
  const told = new Set(seen?.keys ?? []);
  const fresh = found.filter((f) => !told.has(f.key));
  const open = found.filter((f) => told.has(f.key));
  const keys = found.map((f) => f.key);
  const now = new Set(keys);
  const cleared = (seen?.keys ?? []).filter((k) => !k.startsWith("sweep ") && !now.has(k));

  const word = fresh.length ? "ALERT" : "STATUS";
  const summary = fresh.length ? `${fresh.length} new` : "nothing new";
  const rest = open.length ? `${open.length} still open` : "";
  const subject = `${word}: daily digest, ${found.length ? [summary, rest].filter(Boolean).join(", ") : "all clear"}`;

  const out: string[] = [
    seen ? `${summary[0].toUpperCase()}${summary.slice(1)} since the last digest (${minute(seen.at)}).` : `The first digest: everything open counts as new (${fresh.length}).`,
    "",
  ];
  if (fresh.length) {
    const width = Math.min(32, Math.max(...fresh.map((f) => f.object.length)));
    out.push("NEW");
    for (const f of fresh.slice(0, MAX_NEW)) out.push(`  ${f.object.padEnd(width)}  ${f.what}`);
    if (fresh.length > MAX_NEW) out.push(`  … and ${fresh.length - MAX_NEW} more`);
    out.push("");
  }
  if (open.length) out.push(`STILL OPEN (${open.length})`, ...groupLines(open), "");
  if (cleared.length) {
    out.push(`CLEARED (${cleared.length})`, ...cleared.slice(0, MAX_NAMES).map((k) => `  ${k}`));
    if (cleared.length > MAX_NAMES) out.push(`  … and ${cleared.length - MAX_NAMES} more`);
    out.push("");
  }
  if (addresses.length) {
    const count = (k: string): string => `${addresses.filter((d) => d.kind === k).length} ${k}`;
    out.push(`Addresses in the last sweep: ${["appeared", "gone"].map(count).join(", ")} (leases come and go: not findings).`, "");
  }
  out.push(
    "To look closer, on the mothership:",
    "  health-manager show <class>/<name>      an object's conditions",
    "  cmdb sweep --last                       the last sweep's differences",
    "  health-manager ack <ci> --note <why>    a known warning: not told again",
  );
  return { word, subject, body: `${out.join("\n")}\n`, new: fresh.length, open: found.length, keys };
}

export function readSeen(configDir: string): DigestSeen | null {
  const path = join(configDir, SEEN_FILE);
  if (!existsSync(path)) return null;
  try {
    const v = JSON.parse(readFileSync(path, "utf8")) as DigestSeen;
    return Array.isArray(v.keys) && typeof v.at === "string" ? v : null;
  } catch {
    return null;
  }
}

export function writeSeen(configDir: string, seen: DigestSeen): void {
  const path = join(configDir, SEEN_FILE);
  writeFileSync(`${path}.tmp`, `${JSON.stringify(seen)}\n`);
  renameSync(`${path}.tmp`, path);
}
