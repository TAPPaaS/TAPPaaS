// security-queues.ts — the site's CVEs as a list of things to do, not a list of
// CVEs. One card is one component (or one update), never one CVE.
//
//   for the site's operator
//     update     an OS or channel update already offered clears these
//     coming     the next release clears these (where the train runs)
//     decision   a record's assumption fails here; an acceptance ends soon
//     tappaas    waiting on a TAPPaaS decision: unread and deferred components
//     upstream   decided, still counted: waiting on a fix upstream
//   for the maintainers (where the train runs, or --maintainer)
//     move       moving a pin clears these (config/pin-candidates.json)
//     decide     components nobody has decided, worst first
//     review     a rule's result nobody read; a decision a guard sent back;
//                a review date close; a migrated record without its use
//     deferred   put off until a date
//
// Only "update" and "decision" need the site's operator. A site that runs
// TAPPaaS as shipped has nothing under "decision".

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { DAY, levelRankOf, splitKey } from "../../../lib/ts/src/cve-decisions";
import { CveItem, FIRST_SEEN_FILE, ScanStatus, readFirstSeen, sbomDir } from "./security";
import { readAcceptances, unitName } from "./site-decisions";

export type QueueName = "update" | "coming" | "decision" | "tappaas" | "upstream" | "move" | "decide" | "review" | "deferred";
export const OPERATOR_QUEUES: QueueName[] = ["update", "coming", "decision", "tappaas", "upstream"];
export const MAINTAINER_QUEUES: QueueName[] = ["move", "decide", "review", "deferred"];
export const QUEUE_TITLE: Record<QueueName, string> = {
  update: "Update", coming: "Coming", decision: "Your decision", tappaas: "With TAPPaaS", upstream: "With upstream",
  move: "Move a pin", decide: "Decide", review: "Review", deferred: "Deferred",
};

export interface Card {
  queue: QueueName;
  title: string; // "update network: OS packages" / "network/opnsense:curl"
  text: string; // one sentence: what doing it clears, or why it waits
  component?: string;
  units: string[];
  cves: string[];
  worst: string; // the worst effective level among the CVEs: critical … low
  baseline?: boolean; // a component of the shared NixOS baseline, shown once
  action?: string; // the command that does it
}

export interface Queues {
  generated: string;
  operator: Record<string, Card[]>;
  maintainer?: Record<string, Card[]>;
}

interface Row { unit: string; target: string; layer: string; item: CveItem }

const LV = ["critical", "high", "medium", "low", "none"];
const FLAG_WORDS: Record<string, string> = {
  kev: "known exploited since it was decided", epss: "likely to be exploited now", "upstream-changed": "upstream changed its score",
  version: "a new major version", expired: "its review date passed", "review-due": "its review is due", assumption: "an assumption fails on a site",
};
const worstOf = (rows: Row[]): string => rows.map((r) => r.item.level ?? r.item.severity.toLowerCase()).sort((a, b) => LV.indexOf(a) - LV.indexOf(b))[0] ?? "low";
const bySeverity = (rows: Row[]): string => {
  const n = (l: string): number => new Set(rows.filter((r) => (r.item.level ?? "") === l).map((r) => r.item.id)).size;
  const parts = ["critical", "high"].filter((l) => n(l) > 0).map((l) => `${n(l)} ${l}`);
  return parts.length ? ` (${parts.join(", ")})` : "";
};
const ids = (rows: Row[]): string[] => [...new Set(rows.map((r) => r.item.id))].sort();
const unitsOf = (rows: Row[]): string[] => [...new Set(rows.map((r) => r.unit))].sort();
const groupBy = <T>(xs: T[], k: (x: T) => string): Map<string, T[]> => {
  const m = new Map<string, T[]>();
  for (const x of xs) {
    const key = k(x);
    const a = m.get(key);
    if (a) a.push(x);
    else m.set(key, [x]);
  }
  return m;
};
const cardOrder = (a: Card, b: Card): number => levelRankOf((b.worst as never) ?? "none") - levelRankOf((a.worst as never) ?? "none") || b.cves.length - a.cves.length || a.title.localeCompare(b.title);
const componentTitle = (key: string): string => {
  const k = splitKey(key);
  return k ? `${k.source} on ${k.module === "templates" ? "the NixOS baseline" : k.module}` : key;
};

export function buildQueues(s: ScanStatus, opts: { configDir: string; now: number; maintainer: boolean }): Queues {
  const rows: Row[] = [];
  for (const t of s.targets) for (const i of t.items ?? []) rows.push({ unit: unitName(t.id), target: t.id, layer: t.layer, item: i });
  const counted = rows.filter((r) => r.item.counted ?? (r.item.state !== "decided"));
  const op: Record<string, Card[]> = Object.fromEntries(OPERATOR_QUEUES.map((q) => [q, [] as Card[]]));

  // update: what the installed distribution or channel already offers
  const patchable = counted.filter((r) => r.item.fixed && (r.layer === "debian" || r.layer === "opnsense"));
  for (const [unit, rs] of groupBy(patchable, (r) => r.unit)) {
    const fw = rs[0].layer === "opnsense";
    op.update.push({ queue: "update", title: `${unit}: ${fw ? "firewall packages" : "OS packages"}`, units: [unit], cves: ids(rs), worst: worstOf(rs),
      text: `${fw ? "a firmware or package update" : "the pending OS package updates"} clear ${ids(rs).length} CVE(s)${bySeverity(rs)}`,
      action: fw ? "the firewall's update (System → Firmware), or the next sweep" : "the next sweep, or: update-tappaas" });
  }
  // coming: the candidate release's fixes, where the train has a preview
  const det = readJson(join(opts.configDir, "train-preview-details.json")) as { modules?: Record<string, { cves?: { fixed?: { id: string }[] } }> } | null;
  if (det?.modules) {
    const fixed = new Set(Object.values(det.modules).flatMap((m) => (m.cves?.fixed ?? []).map((c) => c.id)));
    const hit = counted.filter((r) => fixed.has(r.item.id));
    if (hit.length) op.coming.push({ queue: "coming", title: "the next release", units: unitsOf(hit), cves: ids(hit), worst: worstOf(hit),
      text: `clears ${ids(hit).length} CVE(s)${bySeverity(hit)} in ${unitsOf(hit).join(", ")}` });
  }
  // decision: an assumption fails here; an acceptance ends within 30 days
  const assumption = rows.filter((r) => (r.item.flags ?? []).includes("assumption"));
  for (const [k, rs] of groupBy(assumption, (r) => `${r.unit} ${r.item.component}`)) {
    op.decision.push({ queue: "decision", title: `${rs[0].unit}: ${componentTitle(rs[0].item.component ?? "")}`, component: rs[0].item.component, units: [rs[0].unit],
      cves: ids(rs), worst: worstOf(rs), text: `${rs[0].item.analysis ?? "a record's assumption does not hold here"} (${ids(rs).length} CVE(s))`,
      action: `change the deployment, or: health-manager accept ${rs[0].unit} --component ${rs[0].item.component} --note "<why>" --until <date>` });
    void k;
  }
  const soon = readAcceptances(opts.configDir).acceptances.filter((a) => Date.parse(a.until) - opts.now < 30 * DAY);
  if (soon.length) op.decision.push({ queue: "decision", title: `${soon.length} acceptance(s) end within 30 days`, units: [...new Set(soon.map((a) => a.unit))].sort(),
    cves: [...new Set(soon.map((a) => a.cve))].sort(), worst: "medium", text: soon.map((a) => `${a.cve} on ${a.unit} on ${a.until}`).join("; "),
    action: "renew with health-manager accept, or let it end" });

  // tappaas and upstream: grouped by component, the baseline once
  const seen = readFirstSeen(join(sbomDir(opts.configDir), FIRST_SEEN_FILE)) ?? {};
  const age = (r: Row): number => {
    const f = Object.entries(seen[r.target] ?? {}).find(([k]) => k.startsWith(`${r.item.id} `))?.[1]?.first;
    return f ? Math.floor((opts.now - Date.parse(f)) / DAY) : 0;
  };
  const waiting = counted.filter((r) => r.item.mark === "unread" || r.item.mark === "deferred" || r.item.mark === "review" || (!r.item.mark && r.item.state !== "risk"));
  for (const [comp, rs] of groupBy(waiting, (r) => r.item.component ?? `${r.unit}/?:${r.item.pkg}`)) {
    const base = comp.startsWith("templates/");
    const oldest = Math.max(...rs.map(age));
    op.tappaas.push({ queue: "tappaas", title: componentTitle(comp), component: comp, units: unitsOf(rs), cves: ids(rs), worst: worstOf(rs), ...(base ? { baseline: true } : {}),
      text: `${ids(rs).length} CVE(s)${bySeverity(rs)} not decided yet${base ? `, in ${unitsOf(rs).length} unit(s)` : ""}${oldest ? `, oldest ${oldest} day(s)` : ""}` });
  }
  const decided = counted.filter((r) => r.item.mark === "confirmed" || r.item.mark === "rule" || (!r.item.mark && r.item.state === "risk"));
  for (const [comp, rs] of groupBy(decided, (r) => r.item.component ?? `${r.unit}/?:${r.item.pkg}`)) {
    op.upstream.push({ queue: "upstream", title: componentTitle(comp), component: comp, units: unitsOf(rs), cves: ids(rs), worst: worstOf(rs),
      ...(comp.startsWith("templates/") ? { baseline: true } : {}), text: `${ids(rs).length} CVE(s) decided${bySeverity(rs)}, counted until upstream fixes them` });
  }
  for (const q of OPERATOR_QUEUES) op[q].sort(cardOrder);
  const out: Queues = { generated: s.generated, operator: op };
  if (!opts.maintainer) return out;

  const mt: Record<string, Card[]> = Object.fromEntries(MAINTAINER_QUEUES.map((q) => [q, [] as Card[]]));
  const cand = readJson(join(opts.configDir, "pin-candidates.json")) as { proposals?: { module: string; kind: string; from?: string; to?: string; clears?: string[]; adds?: string[]; patchLevel?: boolean; text?: string }[] } | null;
  for (const p of cand?.proposals ?? []) {
    if (p.kind !== "move") continue;
    mt.move.push({ queue: "move", title: `${p.module} ${p.from ?? "?"} → ${p.to ?? "?"}`, units: [p.module], cves: p.clears ?? [], worst: "high",
      text: p.text ?? `clears ${(p.clears ?? []).length}, adds ${(p.adds ?? []).length}${p.patchLevel ? ", patch-level" : ""}`,
      action: `tappaas-train.sh candidates apply ${p.module}` });
  }
  const undecided = rows.filter((r) => r.item.mark === "unread" && ["critical", "high"].includes(r.item.severity.toLowerCase()));
  for (const [comp, rs] of groupBy(undecided, (r) => r.item.component ?? `${r.unit}/?:${r.item.pkg}`)) {
    const vecs = groupBy(rs.filter((r) => r.item.vector), (r) => (r.item.vector ?? "").split("/").filter((x) => /^(AV|UI|PR):/.test(x)).join("/"));
    const common = vecs.size === 1 && rs.every((r) => r.item.vector) ? `, all ${[...vecs.keys()][0]}` : "";
    const k = splitKey(comp);
    mt.decide.push({ queue: "decide", title: componentTitle(comp), component: comp, units: unitsOf(rs), cves: ids(rs), worst: worstOf(rs), ...(comp.startsWith("templates/") ? { baseline: true } : {}),
      text: `${ids(rs).length} unread${bySeverity(rs)}${common}${(rs.some((r) => r.item.kev)) ? "; known exploited" : ""}`,
      action: k ? `cve-triage.sh component ${k.module === "templates" ? "baseline" : k.module} ${k.source} --eco ${k.eco} …` : undefined });
  }
  // A migrated record only lacks its use statement: one card per module, not
  // one per component (the migration made hundreds at once).
  const needsUse = rows.filter((r) => (r.item.flags ?? []).includes("needs-use") && r.item.mark === "confirmed" && !(r.item.flags ?? []).some((f) => ["review-due", "expired"].includes(f)));
  for (const [mod, rs] of groupBy(needsUse, (r) => splitKey(r.item.component ?? "")?.module ?? r.unit)) {
    const comps = [...new Set(rs.map((r) => r.item.component ?? ""))].sort();
    mt.review.push({ queue: "review", title: `${mod === "templates" ? "the NixOS baseline" : mod}: migrated records`, units: unitsOf(rs), cves: ids(rs), worst: "low",
      text: `${comps.length} component record(s) migrated from hand-kept VEX need their use statement; their decisions work meanwhile`,
      action: `cve-triage.sh component ${mod === "templates" ? "baseline" : mod} <source> --use "<how the module uses it>" --reason <reason>` });
  }
  const reviewRows = rows.filter((r) => r.item.mark === "rule" || r.item.mark === "review" || (r.item.flags ?? []).some((f) => ["review-due", "expired"].includes(f)));
  for (const [comp, rs] of groupBy(reviewRows, (r) => r.item.component ?? r.item.pkg)) {
    const why = [...new Set(rs.flatMap((r) => r.item.mark === "rule" ? ["by rule, unread"] : (r.item.flags ?? []).filter((f) => f in FLAG_WORDS).map((f) => FLAG_WORDS[f])))];
    const k = splitKey(comp);
    mt.review.push({ queue: "review", title: componentTitle(comp), component: comp, units: unitsOf(rs), cves: ids(rs), worst: worstOf(rs),
      text: `${ids(rs).length} CVE(s): ${why.join(", ") || "to review"}`,
      action: k ? `cve-triage.sh read ${k.module === "templates" ? "baseline" : k.module} ${k.source} <CVE>…` : undefined });
  }
  for (const [comp, rs] of groupBy(rows.filter((r) => r.item.mark === "deferred"), (r) => r.item.component ?? r.item.pkg)) {
    const until = [...new Set(rs.flatMap((r) => (r.item.flags ?? []).filter((f) => f.startsWith("deferred-until:")).map((f) => f.slice(15))))].sort()[0] ?? "?";
    mt.deferred.push({ queue: "deferred", title: componentTitle(comp), component: comp, units: unitsOf(rs), cves: ids(rs), worst: worstOf(rs),
      text: `${ids(rs).length} CVE(s) until ${until}: ${rs[0].item.note ?? ""}` });
  }
  for (const q of MAINTAINER_QUEUES) mt[q].sort(cardOrder);
  out.maintainer = mt;
  return out;
}

function readJson(path: string): unknown {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

// The queues as `report security` prints them, before the table.
export function renderQueues(q: Queues, limit = 6): string[] {
  const out: string[] = [];
  const block = (head: string, names: QueueName[], cards: Record<string, Card[]>): void => {
    out.push(head);
    for (const n of names) {
      const cs = cards[n] ?? [];
      if (!cs.length) {
        out.push(`  ${QUEUE_TITLE[n].padEnd(15)}nothing`);
        continue;
      }
      out.push(`  ${QUEUE_TITLE[n].padEnd(15)}${cs.length} card(s)`);
      for (const c of cs.slice(0, limit)) {
        out.push(`    ${c.worst.padEnd(9)}${c.title}: ${c.text}`);
        if (c.action) out.push(`             → ${c.action}`);
      }
      if (cs.length > limit) out.push(`    … and ${cs.length - limit} more (--json lists every card)`);
    }
  };
  block("FOR YOU", ["update", "coming", "decision"], q.operator);
  block("WAITING", ["tappaas", "upstream"], q.operator);
  if (q.maintainer) block("FOR THE MAINTAINERS", MAINTAINER_QUEUES, q.maintainer);
  return out;
}

// Whether this mothership runs the release train: the maintainers' queues show.
export function runsTrain(configDir: string): boolean {
  return existsSync(join(configDir, "release-train.json"));
}
