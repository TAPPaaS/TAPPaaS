// assess-sources.ts — what `assess` gathers (ADR-041 D2), each source turning
// what it knows into findings on the objects it is about:
//
//   gates        the checks of checks.ts, each row on the object it judged
//   alerts       Grafana's open alerts and the receiver's record (ADR-039 D8)
//   sweep        the last sweep record's lists, as `drift`
//   thresholds   over observations already in the CMDB, never from the plane
//   cve          the CVE scan's cve-status.json, as `security`
//   observations class by class over the same data (assess-observations.ts)
//
// A finding about something the CMDB does not have lands on the site, so nothing
// a gate said is lost. Pure over its inputs: the reads are in assess.ts's AssessIO.

import { BASELINE_CLASS, BASELINE_NAME } from "./baseline-ci";
import { AlertItem } from "./alerts";
import { CmdbItem, SiteIndex } from "./assess-model";
import { POOL_FAIL, POOL_WARN } from "./checks";
import { SWEEP_MAX_AGE_MS, SweepRecord } from "./cmdbsweep";
import { STALE_DAYS, ScanStatus } from "./security";
import { SiteSecurity } from "./site-score";
import { Level } from "../../../lib/ts/src/score";
import { CheckResult, CheckRow, CheckStatus, CheckSubject } from "./types";
import { ConditionStatus, ConditionType } from "../../../lib/ts/src/health-rules";

/** One thing a source said about one object. */
export interface Finding {
  object: string;
  type: ConditionType;
  status: ConditionStatus;
  reason: string; // "ok" when it is
  message: string;
  owner: string; // the gate or source, which alone can take a failure back
  labels?: Record<string, string>; // what the source says beside it, for a classify record to read: an alert's labels; { setBy: "baseline" } on a CVE level the NixOS baseline sets
}

// Each gate's condition: the type it feeds and the reason a failure carries. The
// three gates a source below reads at its root are not mapped: open-alerts,
// cve-status and cmdb.
export interface GateMap { type: ConditionType; reason: string; skip?: "ok" }
export const GATES: Record<string, GateMap> = {
  "service-liveness": { type: "operational", reason: "guest-stopped", skip: "ok" }, // a skip is a suspended module: stopped on purpose
  "disk-threshold": { type: "capacity", reason: "disk-full" },
  "memory-commitment": { type: "capacity", reason: "memory-overcommitted" },
  "guest-memory": { type: "capacity", reason: "guest-memory-short" },
  "storage-pools": { type: "capacity", reason: "pool-usage" },
  "storage-replication": { type: "operational", reason: "replication-failing" },
  "cpu-impact": { type: "maintenance", reason: "cpu-level-loss" },
  "backup-status": { type: "backup", reason: "backup-not-covered" },
  "backup-keys": { type: "maintenance", reason: "backup-key-not-escrowed" },
  "pending-reboot": { type: "maintenance", reason: "reboot-pending" },
  "site-timezone": { type: "maintenance", reason: "timezone-off" },
  quorum: { type: "operational", reason: "quorum-at-risk" },
  "lan-uplink": { type: "operational", reason: "lan-uplink", skip: "ok" }, // a skip is an informational line
  "ipv6-egress": { type: "operational", reason: "ipv6-egress" },
  internet: { type: "operational", reason: "no-internet" },
  "switch-ports": { type: "operational", reason: "switch-port" },
  "mlag-pairs": { type: "operational", reason: "mlag-pair" },
  pulse: { type: "operational", reason: "pulse" },
  "signature-status": { type: "security", reason: "repository-unverified" },
  "control-plane-trust": { type: "security", reason: "controller-unverified" },
};

const STATUS: Record<CheckStatus, ConditionStatus> = { pass: "ok", warn: "warning", fail: "critical", skip: "unknown" };
const tidy = (t: string): string => t.replace(/\s+/g, " ").trim();
export const ok = (s: ConditionStatus, reason: string): string => (s === "ok" ? "ok" : reason);

/** The rows of a gate that speak about something: its rows and its findings. */
export function gateRows(c: CheckResult): CheckRow[] {
  return [...(c.findings ?? []), ...(c.rows ?? [])];
}

export function fromGates(checks: CheckResult[], idx: SiteIndex): { findings: Finding[]; ran: Set<string>; unjudged: Map<string, Set<string>> } {
  const out: Finding[] = [];
  const ran = new Set<string>();
  const unjudged = new Map<string, Set<string>>(); // gate → the object ids it did judge
  for (const c of checks) {
    const g = GATES[c.name];
    if (!g || c.status === "skip") continue;
    ran.add(c.name);
    const place = (s: CheckSubject | undefined): CmdbItem | null => (s ? idx.resolve(s) : null);
    const add = (o: CmdbItem, status: ConditionStatus, message: string): void => {
      out.push({ object: o.id, type: g.type, status, reason: ok(status, g.reason), message, owner: c.name });
    };
    for (const r of gateRows(c)) {
      const status = r.status === "skip" && g.skip ? g.skip : STATUS[r.status];
      const placed = place(r.subject);
      if (placed) {
        add(placed, status, tidy(r.text));
        continue;
      }
      if ((status !== "critical" && status !== "warning") || !idx.site) continue;
      // What the CMDB cannot place lands on the site, naming its subject. A
      // guest the cluster runs and the CMDB does not have is for discovery to
      // find, not a site outage.
      const who = r.subject ? `${r.subject.kind} ${r.subject.name}: ` : "";
      if (r.subject && (r.subject.kind === "module" || r.subject.kind === "node") && g.reason === "guest-stopped") {
        out.push({ object: idx.site.id, type: "drift", status: "warning", reason: "not-in-cmdb", message: `${who}in the cluster, not in the CMDB (${tidy(r.text)})`, owner: c.name });
      } else add(idx.site, status, `${who}${tidy(r.text)}`);
    }
    for (const s of c.judged ?? []) {
      const o = place(s);
      if (o) add(o, "ok", "");
    }
    if (c.judged) unjudged.set(c.name, new Set(c.judged.map((s) => place(s)?.id ?? "").filter(Boolean)));
    // A verdict with nothing beneath it is about the site.
    if (!gateRows(c).some((r) => r.status === c.status) && (c.status === "warn" || c.status === "fail") && idx.site) add(idx.site, STATUS[c.status], tidy(c.detail));
  }
  return { findings: out, ran, unjudged };
}

// ── alerts (ADR-039 D8, ADR-040 D14) ─────────────────────────────────
// The rules over health-manager's own events: they report conditions, they are not one. As one, the
// digest's firing was a new warning, which kept the digest firing the next day.
// The two CVE rules (ADR-045 D4) tell what the security condition already holds.
const HEALTH_RULES = new Set(["HealthRootCause", "HealthRootRecovered", "HealthDailyDigest", "CveNewCritical", "CveLevelUp"]);
const CI_LABELS = ["tappaas_ci_id", "tappaas.ci.id", "service_instance_id", "service.instance.id", "host_id", "host.id"];
const kebab = (s: string): string => s.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();

export function fromAlerts(alerts: AlertItem[], idx: SiteIndex): Finding[] {
  const out: Finding[] = [];
  for (const a of [...alerts].sort((x, y) => x.alertname.localeCompare(y.alertname))) {
    if (HEALTH_RULES.has(a.alertname)) continue;
    if (a.labels.type === "security") continue; // a hit: siem.ts holds it (ADR-050 D12)
    const id = CI_LABELS.map((k) => a.labels[k]).find((v) => v && idx.byId.has(v));
    const o = (id ? idx.byId.get(id) : null) ?? (a.subject ? idx.resolve(a.subject) : null) ?? idx.site;
    if (!o) continue;
    out.push({
      object: o.id,
      // As the source sees it; the classify records say what it becomes (an
      // operational warning, a security one for what says something is exposed).
      type: "operational",
      status: "warning",
      reason: `alert-${kebab(a.alertname)}`,
      message: `${a.alertname}${a.host ? ` on ${a.host}` : ""} since ${a.since}`,
      owner: "alerts",
      labels: { ...a.labels, alertname: a.alertname },
    });
  }
  return out;
}

// ── the sweep's lists (ADR-040 D15) ──────────────────────────────────
const WORD: Record<string, string> = { missing: "desired without actual", unmanaged: "actual without desired", desired: "differs from desired", unread: "could not be compared", cycle: "a dependency cycle over required relations" };

export function fromSweep(rec: SweepRecord | null, nowMs: number, idx: SiteIndex): Finding[] {
  const out: Finding[] = [];
  const site = idx.site;
  const onSite = (status: ConditionStatus, reason: string, message: string): void => {
    if (site) out.push({ object: site.id, type: "drift", status, reason, message, owner: "sweep" });
  };
  if (!rec) {
    onSite("critical", "sweep-none", "no sweep has run — cmdb sweep");
    return out;
  }
  if (!(nowMs - Date.parse(rec.time) <= SWEEP_MAX_AGE_MS)) onSite("critical", "sweep-stale", `the last sweep is from ${rec.time} — is cmdb-sweep.timer running?`);
  for (const s of (rec.sources ?? []).filter((x) => !x.ok)) onSite("critical", "sweep-source-failed", `source ${s.source} failed`);
  for (const d of rec.differences ?? []) {
    if (d.expected) continue; // a verb's change, new (part of what a verb made) or words (a relation's required/redundancyGroup): not drift
    // An attribute that drifted and that a change has since put right: the
    // store cleared the object's drift, so the night's record is over for it.
    // By id where the sweep gives one: names repeat (a pool per node).
    const o = (d.id ? idx.byId.get(d.id) : undefined) ?? idx.named(d.name, [d.class]);
    if (d.kind === "changed" && d.attribute && !d.attribute.startsWith("→") && o && !o.attributes.drift) continue;
    const members = d.kind === "cycle" && Array.isArray(d.after) ? `: ${(d.after as string[]).join(", ")}` : d.kind === "unread" && typeof d.after === "string" ? `: ${d.after}` : "";
    const message = `${d.class}/${d.name}: ${WORD[d.kind] ?? `drift: ${d.kind}`}${d.attribute ? ` ${d.attribute}` : ""}${members}`;
    const status: ConditionStatus = d.kind === "missing" ? "critical" : "warning";
    const on = o ?? site;
    if (on) out.push({ object: on.id, type: "drift", status, reason: `sweep-${d.kind}`, message, owner: "sweep" });
  }
  return out;
}

// ── thresholds over the CMDB's observations ──────────────────────────
export const VPN_STALE_DAYS = 7;
export const CERT_WARN_DAYS = 30;
export const CERT_CRITICAL_DAYS = 7;
export const DAY = 86_400_000;

// ZFS's word for a pool. A pool that lost a mirror still serves: a warning.
const ZFS_STATE: Record<string, ConditionStatus> = { ONLINE: "ok", DEGRADED: "warning", FAULTED: "critical", UNAVAIL: "critical", SUSPENDED: "critical", OFFLINE: "critical", REMOVED: "critical" };

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

// A time as a source gives it: an ISO date, epoch seconds, or an age in seconds.
export function timeOf(v: unknown, nowMs: number): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  if (Number.isFinite(n)) return n <= 0 ? null : n >= 1e9 ? n * 1000 : nowMs - n * 1000;
  const t = Date.parse(String(v));
  return Number.isNaN(t) ? null : t;
}

export function fromThresholds(idx: SiteIndex, nowMs: number): Finding[] {
  const out: Finding[] = [];
  const add = (o: CmdbItem, type: ConditionType, status: ConditionStatus, reason: string, message: string): void => {
    out.push({ object: o.id, type, status, reason: ok(status, reason), message, owner: "thresholds" });
  };
  const cabled = new Set(idx.relations.filter((r) => r.type === "connects" && r.to.class === "port").flatMap((r) => [r.from.id, r.to.id]));
  for (const o of idx.objects) {
    const a = o.attributes;
    if (o.class === "storage-pool" && typeof a.zfsState === "string") {
      add(o, "operational", ZFS_STATE[a.zfsState] ?? "unknown", "pool-state", `${o.name}: zfs ${a.zfsState}`);
    }
    if (o.class === "storage-pool" || o.class === "datastore") {
      const used = num(a.used);
      const size = num(a.size);
      if (used === null || size === null || size <= 0) continue;
      const pct = (100 * used) / size;
      const status: ConditionStatus = pct >= POOL_FAIL ? "critical" : pct >= POOL_WARN ? "warning" : "ok";
      add(o, "capacity", status, o.class === "datastore" ? "datastore-usage" : "pool-usage", `${o.name}: ${pct.toFixed(0)}% used`);
    } else if (o.class === "port" && cabled.has(o.id) && typeof a.link === "string") {
      add(o, "operational", a.link === "down" ? "critical" : "ok", "link-down", `${o.name}: cabled, link ${a.link}`);
    } else if (o.class === "vpn-peer") {
      const t = timeOf(a.lastHandshake, nowMs);
      if (t === null) continue;
      const days = (nowMs - t) / DAY;
      add(o, "operational", days > VPN_STALE_DAYS ? "warning" : "ok", "vpn-handshake-stale", `last handshake ${days.toFixed(0)} day(s) ago`);
    } else if (o.class === "vm" && a.firewall && typeof a.firewall === "object") {
      certificates(o, (a.firewall as { certificates?: unknown }).certificates, nowMs, add);
    }
  }
  return out;
}

// Per common name its newest certificate: a renewal leaves the old one behind.
function certificates(o: CmdbItem, certs: unknown, nowMs: number, add: (o: CmdbItem, t: ConditionType, s: ConditionStatus, r: string, m: string) => void): void {
  const newest = new Map<string, { name: string; to: number }>();
  for (const c of Array.isArray(certs) ? (certs as Record<string, unknown>[]) : []) {
    const to = timeOf(c.validTo, nowMs);
    if (to === null) continue;
    const key = String(c.commonName || c.name || "");
    const had = newest.get(key);
    if (!had || to > had.to) newest.set(key, { name: String(c.name || key), to });
  }
  for (const { name, to } of newest.values()) {
    const days = (to - nowMs) / DAY;
    const status: ConditionStatus = days < CERT_CRITICAL_DAYS ? "critical" : days < CERT_WARN_DAYS ? "warning" : "ok";
    add(o, "security", status, "certificate-expiry", `certificate ${name}: ${days < 0 ? "expired" : `${days.toFixed(0)} day(s) left`}`);
  }
}

// ── the CVE scan (ADR-011) and its risk score (ADR-045 D4) ──────────
// The security condition of a module, a node, a zone and an environment takes
// its status from the score's level: ok and low are ok, medium and high a
// warning, critical critical. The reason names the level (cve-medium,
// cve-high, cve-critical), so a level change is a change even when the status
// stays warning. A zone and an environment carry their own score (with the
// zone's tier multiplier), not the worst of their members (derive.ts leaves
// their security alone). A target whose scan failed is a warning of its own,
// and a scan older than STALE_DAYS a warning on the site.
export function levelStatus(l: Level): ConditionStatus {
  return l === "critical" ? "critical" : l === "high" || l === "medium" ? "warning" : "ok";
}
export const CVE_LEVEL_REASONS = ["cve-medium", "cve-high", "cve-critical"];
const levelReason = (l: Level): string => (levelStatus(l) === "ok" ? "ok" : `cve-${l}`);

// What is behind a level besides its points: "3 unread, 2 accepted". Confirmed
// items need nothing from anyone and are not named.
export function marksText(m: Partial<Record<string, number>> | undefined): string {
  if (!m) return "";
  const words: [string, string][] = [["unread", "unread"], ["rule", "by rule"], ["review", "to review"], ["deferred", "deferred"], ["accepted", "accepted"]];
  return words.filter(([k]) => (m[k] ?? 0) > 0).map(([k, w]) => `${m[k]} ${w}`).join(", ");
}

function scoreMessage(a: { score: number; level: Level }, why: string): string {
  return `score ${a.score}, ${a.level}${why ? `: ${why}` : ""}`;
}

export function fromCve(s: ScanStatus | null, sec: SiteSecurity | null, nowMs: number, idx: SiteIndex): Finding[] {
  if (!s) return [];
  const out: Finding[] = [];
  const add = (o: CmdbItem | null, status: ConditionStatus, reason: string, message: string, labels?: Record<string, string>): void => {
    const at = o ?? (status !== "ok" ? idx.site : null);
    if (at) out.push({ object: at.id, type: "security", status, reason, message: status === "ok" ? "" : message, owner: "cve", ...(labels ? { labels } : {}) });
  };
  const units = sec?.units ?? {};
  // A level only the shared NixOS baseline sets is one cause, the baseline's:
  // the units carry the label (a classify record makes them derived), and the
  // baseline's CI gets its own finding, the root (the site until the CI exists).
  const base = Object.values(units).filter((u) => u.baselineOnly && u.level !== "ok").sort((a, b) => b.raw - a.raw);
  const baselineCi = idx.named(BASELINE_NAME, [BASELINE_CLASS]);
  if (base.length) {
    const top = base[0];
    add(baselineCi ?? idx.site, levelStatus(top.level), "cve-baseline",
      scoreMessage(top, `the NixOS baseline: ${top.counted} ${top.category}, in ${base.length} unit(s)${marksText(top.marks) ? ` · ${marksText(top.marks)}` : ""}`));
  } else if (baselineCi) {
    add(baselineCi, "ok", "cve-baseline", "");
  }
  for (const u of Object.values(units)) {
    const o = idx.resolve(u.subject);
    const why = [u.category ? `${u.counted} ${u.category}` : "", u.baselineOnly ? "from the NixOS baseline" : "", marksText(u.marks)].filter(Boolean).join(" · ");
    add(o, levelStatus(u.level), levelReason(u.level), scoreMessage(u, why), u.baselineOnly && u.level !== "ok" ? { setBy: "baseline" } : undefined);
    if (u.failed.length > 0) {
      const t = s.targets.filter((x) => u.failed.includes(x.id));
      add(o, "warning", "cve-scan-failed", t.map((x) => `${x.name}: ${x.note}`).join("; "));
    }
  }
  for (const [z, a] of Object.entries(sec?.zones ?? {})) {
    const o = idx.named(z, ["zone"]);
    if (!o) continue;
    const by = a.setBy.module ? units[a.setBy.module]?.name ?? a.setBy.module : "";
    add(o, levelStatus(a.level), levelReason(a.level), scoreMessage(a, `×${a.multiplier ?? 1}${by ? `, set by ${by}` : ""}`));
  }
  for (const [e, a] of Object.entries(sec?.environments ?? {})) {
    const o = idx.named(e, ["environment"]);
    if (!o) continue;
    const by = a.setBy.module ? `set by ${units[a.setBy.module]?.name ?? a.setBy.module} in ${a.setBy.zone}` : "";
    add(o, levelStatus(a.level), levelReason(a.level), scoreMessage(a, by));
  }
  const days = Math.floor((nowMs - Date.parse(s.generated)) / DAY);
  if (days > STALE_DAYS && idx.site) out.push({ object: idx.site.id, type: "security", status: "warning", reason: "cve-scan-stale", message: `the last scan is ${days} days old`, owner: "cve" });
  return out;
}
