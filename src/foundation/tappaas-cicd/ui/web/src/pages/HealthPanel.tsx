// HealthPanel.tsx — one object in the Health view (ADR-041 D5): the CI panel,
// beside the graph, a drawer on a phone. Its conditions and since when,
// what caused it or what it impacts, its drift against the record, its history,
// its relations both ways, and the health verbs as jobs: ack and maintenance.
// Details at its top opens the page that shows the object in full and changes
// it (details.ts): a module's page, an asset's, the Network page for a zone.
// CMDB record opens the CI's record in its place (CiPanel.tsx): attributes and
// their sources, the full history, the trace up the backbone.

import { useEffect, useState } from "react";
import { useRead, useVerb } from "../api";
import { OperateButton, Step } from "../operate";
import { HealthCondition, HealthObject, HealthStatus, HealthWhy } from "../types";
import { rulePath } from "./Rules";
import { DetailsLinks, Dot, Level, Link, ReadState, Section, Tag, when } from "../ui";
import { ciDetails } from "../details";
import { CiPanel } from "./CiPanel";
import { ClassIcon } from "../moduleicon";
import { PerfCharts } from "../perfpanel";
import { ackEffect, hitsCount, holdText } from "../healthwords";

const LEVEL: Record<HealthStatus, Level> = { ok: "pass", warning: "warn", critical: "fail", unknown: "skip" };
const hm = (title: string, verb: string, id: string, extra: Partial<Step> = {}): Step => ({ title, bin: "health-manager", verb, fixed: [id], ...extra });

// The dialogs' fields in words: the calendar sends a date, which the verb reads
// as that day's midnight UTC.
const WHY = "why, for the record";
const UNTIL = "It ends at the start of that day (midnight UTC).";

function Pick({ id, label, status, pick }: { id: string; label: string; status?: HealthStatus | null; pick: (id: string) => void }) {
  return (
    <button className="hlink" onClick={() => pick(id)}>
      {status ? <Dot level={LEVEL[status]} title={status} /> : null} {label}
    </button>
  );
}

const DAY_MS = 86_400_000;

/** The Ack… step for one condition: the type fixed, the note required, and what
 *  the acknowledgement does said from the rule that holds it. Shared with the
 *  Security page's Threats. */
export function ackStep(target: { id: string; label: string }, c: { type: string; heldUntil?: string; heldBy?: string }): Step {
  return hm(`health-manager ack ${target.label} --type ${c.type}`, "ack", target.id, { initial: { "--type": c.type }, hide: ["--type"], kinds: { "--until": "future-date" }, placeholders: { "--note": WHY, "--until": "when the condition recovers" }, labels: { "--note": "note", "--until": "until", "--sticky": "keep it when the status changes (a warning turning critical); it still ends when the condition recovers. Without it, the next status change ends it." }, descriptions: { "--note": "Required.", "--until": UNTIL, "--sticky": "" /* the label says it all; "" hides the verb's own help */ }, note: ackEffect(c) });
}

// The order of a list of conditions: what needs a look, then what is
// acknowledged (yellow), then what is ok.
const conditionOrder = (c: { status: string; acknowledged?: boolean }): number => (c.status === "ok" ? 2 : c.acknowledged ? 1 : 0);

function ConditionRow({ o, c, canAck, canUnack }: { o: HealthObject; c: HealthCondition; canAck: boolean; canUnack: boolean }) {
  const silenced = c.acknowledged || c.maintenance || !!c.quiet;
  return (
    <li className={`att att-${LEVEL[c.status]}${c.acknowledged ? " att-ack" : ""}${c.quiet ? " att-quiet" : ""}`}>
      {c.acknowledged ? <span className="tag tag-ack" title="acknowledged">{c.status.toUpperCase()}</span> : <Tag level={c.status} />}
      <span className="att-gate">{c.type}</span>
      <span className="att-text">
        {c.message ?? c.reason ?? c.status}
        <span className="muted small">
          {c.since ? ` · since ${when(c.since)}` : ""}
          {c.source ? ` · ${c.source}` : ""}
          {c.derived ? " · derived" : ""}
          {c.flapping ? " · flapping" : ""}
        </span>
        {c.hits ? <span className="att-col muted small" title={`first ${when(c.hits.first)}, last ${when(c.hits.last)}${c.hits.alerts?.length ? ` · ${c.hits.alerts.join(", ")}` : ""}`}> · {hitsCount(c.hits)}, last {when(c.hits.last)}</span> : null}
        {c.heldUntil ? <span className="att-col muted small"> · held {holdText(c.heldUntil)}</span> : null}
        {c.ack ? <span className="muted small"> · acknowledged by {c.ack.by ?? "?"}{c.ack.until ? ` until ${when(c.ack.until)}` : ""}{c.ack.sticky ? ", sticky" : ""}{c.ack.note ? `: ${c.ack.note}` : ""}</span> : c.acknowledged ? <span className="muted small"> · silenced with its root</span> : null}
        {c.window ? <span className="muted small"> · maintenance{c.window.until ? ` until ${when(c.window.until)}` : ""}{c.window.note ? `: ${c.window.note}` : ""}</span> : null}
        {c.quieted ? <span className="muted small"> · quiet by <Link to={rulePath(c.quieted.rule)}>{c.quieted.rule}</Link>{c.quieted.via ? " (its root)" : ""}</span> : null}
        {c.raw ? <span className="muted small"> · its source said {c.raw.status}; rated {c.status} by <Link to={rulePath(c.raw.rule)}>{c.raw.rule}</Link></span> : null}
      </span>
      {c.status !== "ok" && !c.derived && !silenced ? (
        <OperateButton label="Ack…" disabled={!canAck} hint={canAck ? undefined : "health-manager on this site has no ack verb"} title={`Acknowledge ${c.type} on ${o.label}`} steps={[ackStep(o, c)]} />
      ) : null}
      {c.ack ? <OperateButton label="Unack…" disabled={!canUnack} hint={canUnack ? undefined : "health-manager on this site has no unack verb"} title={`Remove the acknowledgement of ${c.type} on ${o.label}`} steps={[hm(`health-manager unack ${o.label} --type ${c.type}`, "unack", o.id, { initial: { "--type": c.type }, hide: ["--type"] })]} /> : null}
    </li>
  );
}

// Grafana Explore on the object's lines; a threat's own rule query beside it.
function Logs({ o }: { o: HealthObject }) {
  const l = o.logs;
  if (!l || (!l.url && !l.rules.length)) return null;
  return (
    <>
      {l.url ? <>{" · "}<a className="hlink" href={l.url} target="_blank" rel="noreferrer" title={`Grafana Explore: the lines of ${l.host}`}>Logs</a></> : null}
      {l.rules.map((r) => <span key={`${r.type}${r.alert}`}>{" · "}<a className="hlink" href={r.url} target="_blank" rel="noreferrer" title="Grafana Explore: the query of the rule that raised it, as its mail has it">Logs: {r.alert || r.type}</a></span>)}
    </>
  );
}

// What changed on the object: a root cause's last day first, the question an
// incident starts with; the rest on asking.
function Changes({ o }: { o: HealthObject }) {
  const [all, setAll] = useState(false);
  useEffect(() => setAll(false), [o.id]);
  if (!o.changes.length) return null;
  const day = Date.now() - DAY_MS;
  const recent = o.changes.filter((c) => Date.parse(c.time) >= day);
  const lastDay = !!o.isRoot && !all;
  const list = lastDay ? recent : o.changes.slice(0, 12);
  return (
    <>
      <h3>{lastDay ? "Changes to it in the last day" : "Changes to it"}</h3>
      {lastDay && !recent.length ? <p className="muted small">Nothing changed on it in the last day.</p> : null}
      <ul className="findings">
        {list.map((c) => (
          <li key={c.id}><span className="nowrap">{when(c.time)}</span> {c.verb ?? c.kind} <span className="muted small">{c.source}{c.actor ? ` · ${c.actor}` : ""}</span></li>
        ))}
      </ul>
      {o.isRoot ? <button className="hlink small" onClick={() => setAll(!all)}>{all ? "the last day only" : `every change (${o.changes.length})`}</button> : null}
    </>
  );
}

function Verbs({ o }: { o: HealthObject }) {
  // Status, not operations: the health verbs on the object stay here; its
  // operations are on its page, behind Details.
  const maint = useVerb("health-manager", "maintenance");
  return (
    <div className="toolbar">
      <OperateButton label="Maintenance…" disabled={!maint} hint={maint ? undefined : "health-manager on this site has no maintenance verb"} title={`A maintenance window on ${o.label}`} steps={[hm(`health-manager maintenance ${o.label}`, "maintenance", o.id, { placeholders: { "--note": WHY }, kinds: { "--until": "future-date" }, labels: { "--note": "note", "--until": "until" }, descriptions: { "--note": "Required.", "--until": `Required. ${UNTIL}` }, note: "During the window transitions are recorded but neither mailed nor counted." })]} />
    </div>
  );
}

const HOW: Record<HealthWhy["conditions"][number]["how"], string> = {
  root: "a root cause",
  derived: "the same failure as its root, seen from here",
  sum: "a sum of others, never a root (a health rule says so)",
  covered: "its own, but not a root while its root stands",
  impact: "reached from its root",
  follows: "takes its parent's colour",
  "roll-up": "the sum of its members",
  ok: "ok",
};

// Why each condition is what it is (health-manager rules explain): the chain
// from the root, hop by hop, with the rule that decided each; read on demand.
function Why({ id, pick }: { id: string; pick: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  useEffect(() => setOpen(false), [id]);
  return (
    <Section title="Why" aside={open ? undefined : <button className="hlink" onClick={() => setOpen(true)}>explain</button>}>
      {open ? <WhyBody id={id} pick={pick} /> : <p className="muted small">How each condition came about, and the health rule that decided it.</p>}
    </Section>
  );
}

function WhyBody({ id, pick }: { id: string; pick: (id: string) => void }) {
  const r = useRead<HealthWhy>(`health/why/${encodeURIComponent(id)}`);
  const w = r.env?.data;
  return (
    <>
      <ReadState env={r.env} failure={r.failure} what="the explanation" />
      {w ? (
        <ul className="why">
          {w.conditions.filter((c) => c.how !== "ok").map((c) => (
            <li key={c.type}>
              <Tag level={c.status} /> <b>{c.type}</b> {c.reason ? <span className="muted small">({c.reason})</span> : null}: {HOW[c.how]}
              {c.how === "root" ? ` impacting ${c.impacts ?? 0}` : ""}
              {c.rootCause && c.how !== "impact" ? <> · <button className="hlink" onClick={() => pick(c.rootCause!)}>its root</button></> : null}
              {c.rule ? <div className="small">by <Link to={rulePath(c.rule)} className="mono">{c.rule}</Link>{c.ruleText ? <span className="muted">: {c.ruleText}</span> : null}</div> : null}
              {c.path?.length ? (
                <ol className="why-path">
                  {c.path.map((h, i) => (
                    <li key={i} className="small">
                      {h.from} → {h.to}{h.relation ? <span className="muted"> over {h.relation}</span> : null}: {h.type} {h.status} · <Link to={rulePath(h.rule)} className="mono">{h.rule}</Link>
                      {h.lost.map((l) => <div key={l.id} className="muted">lost: <span className="mono">{l.id}</span> ({l.why === "overridden" ? "overridden by" : "less specific than"} {l.by})</div>)}
                    </li>
                  ))}
                </ol>
              ) : null}
            </li>
          ))}
          {!w.conditions.some((c) => c.how !== "ok") ? <li className="muted">Nothing to explain: every condition is ok.</li> : null}
        </ul>
      ) : null}
    </>
  );
}

export function HealthPanel({ id, close, pick, showInTree }: { id: string; close: () => void; pick: (id: string) => void; showInTree: () => void }) {
  const r = useRead<HealthObject>(`health/object/${encodeURIComponent(id)}`);
  const ack = useVerb("health-manager", "ack");
  const unack = useVerb("health-manager", "unack");
  const o = r.env?.data;
  const out = (o?.relations ?? []).filter((x) => x.direction === "out");
  const inc = (o?.relations ?? []).filter((x) => x.direction === "in");
  const [record, setRecord] = useState(false);
  useEffect(() => setRecord(false), [id]);
  if (record) return <CiPanel start={{ id }} close={close} back={{ label: "Health", go: () => setRecord(false) }} />;
  return (
    <aside className="sidepanel health-panel">
      <header>
        <div>
          <b className="ci-title">{o ? <ClassIcon cls={o.class} size={20} /> : null}{o?.label ?? "…"}</b>
          <div className="muted small">{o?.class ?? ""}{o?.ancestors.length ? ` · ${o.ancestors.filter((a) => a !== o.class && a !== "object").join(" › ")}` : ""}</div>
        </div>
        <button className="btn-x" onClick={close} aria-label="Close">×</button>
      </header>
      <ReadState env={r.env} failure={r.failure} what="this object" />
      {o ? (
        <>
          <DetailsLinks targets={ciDetails(o)} />
          <p>
            <button className="hlink" onClick={showInTree}>Show in tree</button>{" · "}
            <button className="hlink" onClick={() => setRecord(true)}>CMDB record and trace</button>
            <Logs o={o} />
          </p>
          <Verbs o={o} />
          <Section title="Conditions">
            {o.conditions.length === 0 ? <p className="muted">No condition: nothing has assessed this object.</p> : null}
            <ul className="attention">
              {[...o.conditions].sort((a, b) => conditionOrder(a) - conditionOrder(b)).map((c) => (
                <ConditionRow key={c.type} o={o} c={c} canAck={!!ack} canUnack={!!unack} />
              ))}
            </ul>
          </Section>
          <Why id={o.id} pick={pick} />
          {o.rootCauses.length ? (
            <Section title="Root cause">
              <ul className="plain">
                {o.rootCauses.map((c) => <li key={c.id}><Pick id={c.id} label={c.label} pick={pick} /> <span className="muted small">{c.reason ?? ""}</span></li>)}
              </ul>
            </Section>
          ) : null}
          {o.impacts.length ? (
            <Section title="What it impacts" aside={`${o.impacts.length}`}>
              <ul className="plain">
                {o.impacts.map((c) => <li key={c.id}><Pick id={c.id} label={c.label} status={c.status} pick={pick} /> <span className="muted small">{c.class}</span></li>)}
              </ul>
            </Section>
          ) : null}
          <Section title="Performance" aside={<Link to={`/performance/browse?select=${encodeURIComponent(o.id)}`}>all of it</Link>}>
            <PerfCharts key={o.id} id={o.id} ranges={["24h", "7d"]} pick={pick} max={3} />
          </Section>
          {o.drift ? (
            <Section title="Drift — against its record">
              <pre className="output">{typeof o.drift === "string" ? o.drift : JSON.stringify(o.drift, null, 2)}</pre>
            </Section>
          ) : null}
          <Section title="History" aside="the conditions' periods">
            {o.history.length === 0 ? <p className="muted">No transition recorded.</p> : null}
            <ul className="findings">
              {o.history.map((h, i) => (
                <li key={i}>
                  <Tag level={h.to} /> <span className="nowrap">{when(h.at)}</span> {h.type}{h.from ? ` from ${h.from}` : ""}: {h.message ?? h.reason ?? h.to}
                </li>
              ))}
            </ul>
            <Changes o={o} />
          </Section>
          <Section title="Relations">
            <ul className="plain">
              {out.map((x) => <li key={`o${x.id}`}><span className="muted small">{x.type} →</span> <Pick id={x.other.id} label={x.other.name} status={x.other.status} pick={pick} /></li>)}
              {inc.map((x) => <li key={`i${x.id}`}><span className="muted small">{x.type} ←</span> <Pick id={x.other.id} label={x.other.name} status={x.other.status} pick={pick} /></li>)}
            </ul>
          </Section>
        </>
      ) : null}
    </aside>
  );
}
