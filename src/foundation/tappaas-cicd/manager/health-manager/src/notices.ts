// notices.ts — the critical-root mail: one notice per critical root cause, from
// when it enters the root-cause set to when it leaves it, for any reason.
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
// Not a notice of its own: a warning root (the daily digest), a performance
// root (the digest too), a module's CVE level (cve-level-up mails it), a zone's
// or environment's score (derived from its modules).

import { silenced } from "./ack";
import { Condition, HealthObject, RootEntry, conditionsOf, rootsOf } from "./emit-cmdb";
import { CVE_LEVEL_RANK } from "./events";
import { spawnGuarded } from "../../../lib/ts/src/exec";

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
  opened: string; // when the notice went out
  rules?: string; // the first eight characters of the rule-set hash it was decided under
}

export type CloseWhy = "recovered" | "eased" | "unchecked" | "retired" | "acknowledged" | "maintenance" | "symptom" | "digest";

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
  symptom: "now explained by another root cause",
  digest: "told in the daily digest",
};

// Told elsewhere: a performance condition in the digest, a zone's or an
// environment's score with the module that set it.
const NOT_NOTICED_CLASSES = new Set(["zone", "environment", "site"]);

const conditionOf = (o: HealthObject | undefined, type: string): Condition | undefined => (o ? conditionsOf(o).find((c) => c.type === type) : undefined);

/** Does this condition of a root cause call for a notice of its own? */
export function noticeable(o: HealthObject, c: Condition | undefined, now: Date): boolean {
  if (!c || c.status !== "critical" || c.derived || silenced(c, now)) return false;
  if (c.type === "performance" || c.type === "impact" || NOT_NOTICED_CLASSES.has(o.class)) return false;
  return !(c.type === "security" && (c.reason ?? "") in CVE_LEVEL_RANK);
}

/** The notices the root-cause set calls for now, by key. */
export function wantedNotices(objects: HealthObject[], roots: RootEntry[], impactedOf: (key: string) => string, now: Date): Map<string, Omit<Notice, "opened">> {
  const byId = new Map(objects.map((o) => [o.id, o]));
  const out = new Map<string, Omit<Notice, "opened">>();
  for (const r of roots) {
    const o = byId.get(r.id);
    if (!o) continue;
    const types = r.type ? [r.type] : conditionsOf(o).filter((c) => c.status === "critical").map((c) => c.type);
    for (const type of types) {
      const c = conditionOf(o, type);
      if (!noticeable(o, c, now)) continue;
      const key = `${o.id}:${type}`;
      out.set(key, { key, ci: o.id, class: o.class, name: o.name, type, reason: c!.reason ?? "", message: c!.message ?? "", impacted: impactedOf(key), since: c!.since ?? now.toISOString() });
    }
  }
  return out;
}

/** Why an open notice's root left the set, and what it is now. */
export function closeWhy(n: Notice, objects: HealthObject[], roots: RootEntry[], now: Date): { why: CloseWhy; detail: string } {
  const o = objects.find((x) => x.id === n.ci);
  if (!o) return { why: "retired", detail: `${n.class} ${n.name} is no longer in the CMDB` };
  const c = conditionOf(o, n.type);
  if (!c || c.status === "ok") return { why: "recovered", detail: "" };
  if (c.status === "warning") return { why: "eased", detail: c.message ?? "" };
  if (c.status === "unknown") return { why: "unchecked", detail: c.message ?? "" };
  if (c.acknowledged && silenced(c, now)) return { why: "acknowledged", detail: `by ${c.acknowledged.by}${c.acknowledged.note ? `: ${c.acknowledged.note}` : ""}` };
  if (c.maintenance && silenced(c, now)) return { why: "maintenance", detail: c.maintenance.note ?? "" };
  const isRoot = roots.some((r) => r.id === o.id && (!r.type || r.type === n.type));
  if (c.derived || !isRoot) {
    const by = rootsOf(c)[0];
    const root = by ? objects.find((x) => x.id === by) : undefined;
    return { why: "symptom", detail: root ? `of ${root.class} ${root.name}` : "" };
  }
  return { why: "digest", detail: "" };
}

export interface NoticePlan {
  open: Omit<Notice, "opened">[];
  close: { notice: Notice; why: CloseWhy; detail: string }[];
  byRules?: boolean; // decided in a run under changed health rules
}

/** What to open and what to close. A flapping condition holds its notice as it
 *  is: neither opened nor closed while it flaps. */
export function planNotices(open: Record<string, Notice>, want: Map<string, Omit<Notice, "opened">>, objects: HealthObject[], roots: RootEntry[], now: Date): NoticePlan {
  const flapping = (ci: string, type: string): boolean => conditionOf(objects.find((o) => o.id === ci), type)?.flapping === true;
  const plan: NoticePlan = { open: [], close: [] };
  for (const [k, n] of want) if (!open[k] && !flapping(n.ci, n.type)) plan.open.push(n);
  for (const [k, n] of Object.entries(open)) {
    if (want.has(k) || flapping(n.ci, n.type)) continue;
    plan.close.push({ notice: n, ...closeWhy(n, objects, roots, now) });
  }
  return plan;
}

export const noticeKey = (n: { ci: string; type: string }): string => `health-root:${n.ci}:${n.type}`;

/** The mail of an opened notice. */
export function openMail(n: Omit<Notice, "opened">, rulesChanged = false): { subject: string; body: string } {
  return {
    subject: `ALERT: critical root cause ${n.name} (impacts ${n.impacted})${rulesChanged ? " (rules changed)" : ""}`,
    body: [
      `== Critical root cause: ${n.class} ${n.name}`,
      ...(rulesChanged ? ["the health rules changed in this run: it is a root under the new rules"] : []),
      `condition: ${n.type}, ${n.reason}`,
      ...(n.message ? [`what: ${n.message}`] : []),
      `impacts: ${n.impacted}`,
      `since: ${n.since}`,
      ...(n.rules ? [`health rules: ${n.rules}`] : []),
      "",
      "One RESOLVED follows when it is no longer a critical root cause, saying why.",
      `health-manager roots shows what it impacts; health-manager ack ${n.name} --note <why> silences it and its symptoms.`,
      "",
    ].join("\n"),
  };
}

/** The mail of a closed notice. */
export function closeMail(n: Notice, why: CloseWhy, detail: string, rulesChanged = false): { subject: string; body: string } {
  return {
    subject: `RESOLVED: critical root cause ${n.name} (${WHY[why]}${rulesChanged ? ", rules changed" : ""})`,
    body: [
      `== No longer a critical root cause: ${n.class} ${n.name}`,
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
