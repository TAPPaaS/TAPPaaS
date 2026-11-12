// security-alerts.ts — what a scan tells the alert rules (ADR-045 D4,
// tappaas-cicd-alerts.json): one journal line per scan, identifier
// tappaas-security.
//
//   cve-new      the scan found new critical/high CVEs nobody has analysed
//                (unread), or a CVE joined the known-exploited list:
//                cve-new-critical mails it at once, listing them
//   cve-changes  anything else moved since the last scan (a new item in another
//                state, a carried one, a level going down): the daily digest
//                picks it up
//
// A module whose security condition is acknowledged or in maintenance is
// quiet: its items are left out of both. The level rising to high or critical
// is health's (emit's transition carries levelUp; cve-level-up mails it).

import { spawnGuarded } from "../../../lib/ts/src/exec";
import { ScanStatus } from "./security";
import { SiteSecurity, levelRank } from "./site-score";

export const SECURITY_IDENTIFIER = "tappaas-security";
const MAX_ITEMS = 25;

export interface CveNewEvent {
  event: "cve-new";
  scan: string;
  count: number;
  modules: string;
  items: string; // "CVE-… critical brotli 1.1.0 (immich); …"
  silenced: false;
}

export interface CveChangesEvent {
  event: "cve-changes";
  scan: string;
  count: number;
  what: string; // "immich: 2 new risk, level high → medium"
  silenced: false;
}

// The new open items of a scan, per unit, minus the quiet ones.
export function cveNewEvent(s: ScanStatus, sec: SiteSecurity, quiet: Set<string>): CveNewEvent | null {
  const lines: string[] = [];
  const mods = new Set<string>();
  for (const [key, u] of Object.entries(sec.units)) {
    if (quiet.has(key)) continue;
    const fresh = new Set(s.targets.filter((t) => u.targets.includes(t.id)).flatMap((t) => t.newOpen ?? []));
    const kev = new Set(s.targets.filter((t) => u.targets.includes(t.id)).flatMap((t) => t.newKev ?? []));
    for (const i of u.items.filter((x) => (x.mark ? x.mark === "unread" : x.state === "open") && fresh.has(x.id) && !kev.has(x.id))) {
      mods.add(u.name);
      lines.push(`${i.id} ${i.severity.toLowerCase()} ${i.pkg} ${i.version} (${u.name})`);
    }
    // Known-exploited now: mailed whatever was decided for it — it counts at
    // its upstream level until a person reads it again.
    for (const i of u.items.filter((x) => kev.has(x.id))) {
      mods.add(u.name);
      lines.push(`${i.id} ${i.severity.toLowerCase()} ${i.pkg} ${i.version} (${u.name}, known exploited)`);
    }
  }
  if (lines.length === 0) return null;
  lines.sort((a, b) => (a.includes(" critical ") ? 0 : 1) - (b.includes(" critical ") ? 0 : 1) || a.localeCompare(b));
  const shown = lines.slice(0, MAX_ITEMS).join("; ") + (lines.length > MAX_ITEMS ? `; and ${lines.length - MAX_ITEMS} more` : "");
  return { event: "cve-new", scan: s.generated, count: lines.length, modules: [...mods].sort().join(", "), items: shown, silenced: false };
}

// What moved between two scores, beyond new open items: new items in another
// state, and levels going down (going up is health's). One line per unit.
export function cveChangesEvent(prev: SiteSecurity | null, sec: SiteSecurity, quiet: Set<string>): CveChangesEvent | null {
  if (!prev) return null;
  const parts: string[] = [];
  let count = 0;
  for (const [key, u] of Object.entries(sec.units)) {
    if (quiet.has(key)) continue;
    const was = prev.units[key];
    const before = new Set((was?.items ?? []).map((i) => `${i.id} ${i.state}`));
    const fresh = u.items.filter((i) => i.state !== "open" && i.state !== "decided" && !before.has(`${i.id} ${i.state}`));
    const by = new Map<string, number>();
    for (const i of fresh) by.set(i.state, (by.get(i.state) ?? 0) + 1);
    const bits = [...by].map(([st, n]) => `${n} new ${st}`);
    const down = !!was && levelRank(u.level) < levelRank(was.level);
    if (down) bits.push(`level ${was.level} → ${u.level}`);
    if (bits.length) {
      count += fresh.length + (down ? 1 : 0);
      parts.push(`${u.name}: ${bits.join(", ")}`);
    }
  }
  if (parts.length === 0) return null;
  return { event: "cve-changes", scan: sec.generated, count, what: parts.join("; "), silenced: false };
}

export function securityJournal(lines: string[]): void {
  if (!lines.length) return;
  const r = spawnGuarded("systemd-cat", ["-t", SECURITY_IDENTIFIER], { input: lines.join("\n") + "\n", encoding: "utf8" });
  if (r.error || r.status !== 0) {
    process.stderr.write(`[Warning] no journal (${r.error?.message ?? `exit ${String(r.status)}`}); the lines follow\n${lines.join("\n")}\n`);
  }
}

// The units whose security condition is acknowledged or in maintenance, from
// health's objects: by name (a module) or by node name (`node:<name>`).
export function quietUnits(sec: SiteSecurity, objects: { class: string; name: string; attributes: { conditions?: { type: string; acknowledged?: { until?: string | null } | null; maintenance?: { until?: string | null } | null }[] } }[], now: Date): Set<string> {
  const live = (w: { until?: string | null } | null | undefined): boolean => !!w && (!w.until || Date.parse(w.until) > now.getTime());
  const quiet = new Set<string>();
  for (const [key, u] of Object.entries(sec.units)) {
    const classes = u.kind === "node" ? ["machine"] : ["vm", "lxc", "machine", "device", "app"];
    const o = objects.find((x) => x.name === u.name && classes.includes(x.class));
    const c = (o?.attributes.conditions ?? []).find((x) => x.type === "vulnerability");
    if (c && (live(c.acknowledged) || live(c.maintenance))) quiet.add(key);
  }
  return quiet;
}
