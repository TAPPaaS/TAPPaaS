// notices.ts — the root-cause mail: one notice per root cause the `notify`
// records say is told at once (shipped: a critical one), from when it enters
// the root-cause set to when it leaves it, for any reason.
//
// The mail follows the set, not a condition's transitions: a condition that
// becomes a root without changing status (its node came back, a silence ended
// while the fault held) opens a notice; one that leaves the set closes it,
// whatever the way out — recovered, eased to a warning, no longer checked,
// retired, silenced, or now explained by another root — and the close says
// which. emit decides; site-notify.sh delivers it from this host, so a notice
// does not wait for the logging VM, and the journal line stays as the record.
//
// What is open lives in emit's cursor. A notice that could not be delivered is
// not recorded as open and is tried again on the next run; a close that could
// not be delivered stays open and is tried again. site-notify.sh threads the
// close as a reply to its alert by the key.
//
// Which roots are told at once is the `notify` records' (shipped: not a warning
// root, a performance root, a module's CVE level, nor what is about the site, a
// zone or an environment). Who can be told is the engine's: only a root, never a
// symptom, nor one acknowledged, in maintenance or quiet.

import { silenced } from "./ack";
import { Condition, HealthObject, RootEntry, conditionsOf, rootsOf } from "./emit-cmdb";
import { spawnGuarded } from "../../../lib/ts/src/exec";
import { Ancestors, Candidate, HealthRecord, Notify, flatten, matches, pick } from "../../../lib/ts/src/health-records";

export interface Notice {
  key: string; // <ci>:<type>
  ci: string;
  class: string;
  name: string;
  type: string;
  reason: string;
  message: string;
  impacted: string; // what it impacts by class: "3 vm, 2 service", or "nothing"
  since: string; // the condition's since
  status?: string; // the root's status when it opened: a warning root may be told at once too
  opened: string; // when the notice went out
  rules?: string; // the first eight characters of the rule-set hash it was decided under
}

export type CloseWhy = "recovered" | "eased" | "unchecked" | "retired" | "acknowledged" | "maintenance" | "quiet" | "symptom" | "digest" | "rules";

export interface NoticeEvent {
  event: "notice";
  phase: "open" | "close";
  ci: string;
  class: string;
  name: string;
  type: string;
  reason: string;
  message: string;
  impacted: string;
  why?: CloseWhy;
  detail?: string; // a close: what it is now
  cause?: "rules"; // it opened or closed because the health rules changed
  rules?: string; // the rule-set hash it was decided under (eight characters)
  sent: boolean;
  at: string;
}

const WHY: Record<CloseWhy, string> = {
  recovered: "recovered",
  eased: "eased to a warning",
  unchecked: "no longer checked",
  retired: "retired from the CMDB",
  acknowledged: "acknowledged",
  maintenance: "in maintenance",
  quiet: "quieted by a health rule",
  symptom: "now explained by another root cause",
  digest: "told in the daily digest",
  rules: "the health rules changed: now told in the daily digest or not at all",
};

/** The notify records a run decides by, with the classes' ancestors. */
export interface NotifyRules { records: HealthRecord[]; ancestors: Ancestors }

/** The core notify records as released (metamodel/health/notify.json): what
 *  decides where no installed set is given. A test keeps the two equal. */
export const CORE_NOTIFY: Notify[] = [
  { id: "core.notify.root", kind: "notify", description: "A root cause is in the daily digest.", when: { condition: { status: ["warning", "critical"] } }, notify: "digest" },
  { id: "core.notify.critical-root", kind: "notify", description: "A critical root cause is mailed at once.", when: { condition: { status: "critical" } }, notify: "at-once" },
  { id: "core.notify.performance", kind: "notify", description: "Performance is trend, not outage: the digest.", when: { condition: { type: "performance" } }, notify: "digest", overrides: ["core.notify.critical-root"] },
  { id: "core.notify.cve-level", kind: "notify", description: "A module's CVE level is mailed when it rises, by its own event.", when: { condition: { type: "security", reason: ["cve-medium", "cve-high", "cve-critical"] } }, notify: "digest", overrides: ["core.notify.critical-root"] },
  { id: "core.notify.site-own", kind: "notify", description: "What is about the site, a zone or an environment as a whole is told in the digest.", when: { object: { class: ["site", "zone", "environment"] } }, notify: "digest", overrides: ["core.notify.critical-root"] },
];

const DEFAULT_NOTIFY: NotifyRules = { records: CORE_NOTIFY, ancestors: {} };
const cache = new WeakMap<HealthRecord[], Candidate<Notify>[]>();
const candidates = (r: NotifyRules): Candidate<Notify>[] => {
  if (!cache.has(r.records)) cache.set(r.records, r.records.filter((x): x is Notify => x.kind === "notify" && x.enabled !== false).map((rec) => ({ rec, flat: flatten(rec) })));
  return cache.get(r.records)!;
};

/** How a root's condition is told under the records: at once, in the digest, or not at all. */
export function notifyOf(o: HealthObject, c: Condition, rules: NotifyRules = DEFAULT_NOTIFY): "at-once" | "digest" | "none" {
  const ctx = (k: string): unknown => {
    if (k === "condition.type") return c.type;
    if (k === "condition.status") return c.status;
    if (k === "condition.reason") return c.reason;
    if (k === "object.class") return o.class;
    if (k === "object.name") return o.name;
    if (k === "object.id") return o.id;
    if (k.startsWith("object.attr.")) return (o.attributes as Record<string, unknown>)[k.slice(12)];
    if (k.startsWith("object.")) return (o.attributes as Record<string, unknown>)[k.slice(7)];
    return undefined;
  };
  return pick(candidates(rules).filter((x) => matches(x.flat, ctx, rules.ancestors)), rules.ancestors).winner?.notify ?? "none";
}

const conditionOf = (o: HealthObject | undefined, type: string): Condition | undefined => (o ? conditionsOf(o).find((c) => c.type === type) : undefined);

/** Does this condition of a root cause call for a notice of its own? Only a
 *  failing root of its own (no symptom, nothing silenced) can; the records say whether it does. */
export function noticeable(o: HealthObject, c: Condition | undefined, now: Date, rules: NotifyRules = DEFAULT_NOTIFY): boolean {
  if (!c || (c.status !== "critical" && c.status !== "warning") || c.derived || c.type === "impact" || silenced(c, now)) return false;
  return notifyOf(o, c, rules) === "at-once";
}

/** The notices the root-cause set calls for now, by key. */
export function wantedNotices(objects: HealthObject[], roots: RootEntry[], impactedOf: (key: string) => string, now: Date, rules: NotifyRules = DEFAULT_NOTIFY): Map<string, Omit<Notice, "opened">> {
  const byId = new Map(objects.map((o) => [o.id, o]));
  const out = new Map<string, Omit<Notice, "opened">>();
  for (const r of roots) {
    const o = byId.get(r.id);
    if (!o) continue;
    const types = r.type ? [r.type] : conditionsOf(o).filter((c) => c.status === "critical" || c.status === "warning").map((c) => c.type);
    for (const type of types) {
      const c = conditionOf(o, type);
      if (!noticeable(o, c, now, rules)) continue;
      const key = `${o.id}:${type}`;
      out.set(key, { key, ci: o.id, class: o.class, name: o.name, type, reason: c!.reason ?? "", message: c!.message ?? "", impacted: impactedOf(key), since: c!.since ?? now.toISOString(), ...(c!.status === "warning" ? { status: "warning" } : {}) });
    }
  }
  return out;
}

/** Why an open notice's root left the set, and what it is now. `byRules`: the
 *  run is under changed health rules. */
export function closeWhy(n: Notice, objects: HealthObject[], roots: RootEntry[], now: Date, rules: NotifyRules = DEFAULT_NOTIFY, byRules = false): { why: CloseWhy; detail: string } {
  const o = objects.find((x) => x.id === n.ci);
  if (!o) return { why: "retired", detail: `${n.class} ${n.name} is no longer in the CMDB` };
  const c = conditionOf(o, n.type);
  if (!c || c.status === "ok") return { why: "recovered", detail: "" };
  if (c.status === "unknown") return { why: "unchecked", detail: c.message ?? "" };
  if (c.acknowledged && silenced(c, now)) return { why: "acknowledged", detail: `by ${c.acknowledged.by}${c.acknowledged.note ? `: ${c.acknowledged.note}` : ""}` };
  if (c.maintenance && silenced(c, now)) return { why: "maintenance", detail: c.maintenance.note ?? "" };
  if (c.quieted) return { why: "quiet", detail: c.quieted.rule };
  const isRoot = roots.some((r) => r.id === o.id && (!r.type || r.type === n.type));
  if (c.derived || !isRoot) {
    const by = rootsOf(c)[0];
    const root = by ? objects.find((x) => x.id === by) : undefined;
    return { why: "symptom", detail: root ? `of ${root.class} ${root.name}` : "" };
  }
  // Still a root: the records no longer tell it at once.
  if (byRules) return { why: "rules", detail: notifyOf(o, c, rules) === "none" ? "not told any more" : "now in the daily digest" };
  if (c.status === "warning" && (n.status ?? "critical") === "critical") return { why: "eased", detail: c.message ?? "" };
  return { why: "digest", detail: "" };
}

export interface NoticePlan {
  open: Omit<Notice, "opened">[];
  close: { notice: Notice; why: CloseWhy; detail: string }[];
  byRules?: boolean; // decided in a run under changed health rules
}

/** What to open and what to close. A flapping condition holds its notice as it
 *  is: neither opened nor closed while it flaps. */
export function planNotices(open: Record<string, Notice>, want: Map<string, Omit<Notice, "opened">>, objects: HealthObject[], roots: RootEntry[], now: Date, rules: NotifyRules = DEFAULT_NOTIFY, byRules = false): NoticePlan {
  const flapping = (ci: string, type: string): boolean => conditionOf(objects.find((o) => o.id === ci), type)?.flapping === true;
  const plan: NoticePlan = { open: [], close: [] };
  for (const [k, n] of want) if (!open[k] && !flapping(n.ci, n.type)) plan.open.push(n);
  for (const [k, n] of Object.entries(open)) {
    if (want.has(k) || flapping(n.ci, n.type)) continue;
    plan.close.push({ notice: n, ...closeWhy(n, objects, roots, now, rules, byRules) });
  }
  return plan;
}

export const noticeKey = (n: { ci: string; type: string }): string => `health-root:${n.ci}:${n.type}`;

/** The mail of an opened notice. */
export function openMail(n: Omit<Notice, "opened">, rulesChanged = false): { subject: string; body: string } {
  return {
    subject: `ALERT: ${n.status === "warning" ? "" : "critical "}root cause ${n.name} (impacts ${n.impacted})${rulesChanged ? " (rules changed)" : ""}`,
    body: [
      `== ${n.status === "warning" ? "Root cause" : "Critical root cause"}: ${n.class} ${n.name}`,
      ...(rulesChanged ? ["the health rules changed in this run: it is a root under the new rules"] : []),
      `condition: ${n.type}, ${n.reason}`,
      ...(n.message ? [`what: ${n.message}`] : []),
      `impacts: ${n.impacted}`,
      `since: ${n.since}`,
      ...(n.rules ? [`health rules: ${n.rules}`] : []),
      "",
      n.status === "warning" ? "One RESOLVED follows when it is no longer a root cause told at once, saying why." : "One RESOLVED follows when it is no longer a critical root cause, saying why.",
      `health-manager roots shows what it impacts; health-manager ack ${n.name} --note <why> silences it and its symptoms.`,
      "",
    ].join("\n"),
  };
}

/** The mail of a closed notice. */
export function closeMail(n: Notice, why: CloseWhy, detail: string, rulesChanged = false): { subject: string; body: string } {
  return {
    subject: `RESOLVED: ${n.status === "warning" ? "" : "critical "}root cause ${n.name} (${WHY[why]}${rulesChanged ? ", rules changed" : ""})`,
    body: [
      `== No longer a ${n.status === "warning" ? "root cause told at once" : "critical root cause"}: ${n.class} ${n.name}`,
      `why: ${WHY[why]}${detail ? ` — ${detail}` : ""}`,
      ...(rulesChanged ? ["the health rules changed in this run: the condition did not"] : []),
      `condition: ${n.type}, ${n.reason}`,
      `opened: ${n.opened}`,
      "",
      why === "recovered" || why === "retired" ? "health-manager list shows what is still not ok." : "health-manager show " + n.name + " shows its conditions now.",
      "",
    ].join("\n"),
  };
}

/** Delivers one mail; true once it went (or there was nothing to resolve). */
export type Deliver = (mail: { subject: string; body: string }, key: string, resolve: boolean) => boolean;

/** site-notify.sh on this host: SITE_NOTIFY_BIN, else on PATH. */
export const siteNotify: Deliver = (mail, key, resolve) => {
  const bin = process.env.SITE_NOTIFY_BIN ?? "site-notify.sh";
  const r = spawnGuarded(bin, ["--what", "health notice", "--subject", mail.subject, "--key", key, ...(resolve ? ["--resolve"] : [])], {
    input: mail.body,
    encoding: "utf8",
    timeout: 120_000,
  });
  return !r.error && r.status === 0;
};
