// HealthPanel.tsx — one object in the Health view (ADR-041 D5): the CI panel,
// beside the graph, a drawer on a phone. Its conditions and since when,
// what caused it or what it impacts, its drift against the record, its history,
// its relations both ways, and the health verbs as jobs: ack and maintenance;
// a module's operations are on its page, behind the Open module jump (ADR-034 D11).

import { useRead, useVerb } from "../api";
import { OperateButton, Step } from "../operate";
import { HealthCondition, HealthObject, HealthStatus } from "../types";
import { Dot, Level, Link, ReadState, Section, Tag, when } from "../ui";

const LEVEL: Record<HealthStatus, Level> = { ok: "pass", warning: "warn", critical: "fail", unknown: "skip" };
const hm = (title: string, verb: string, id: string, extra: Partial<Step> = {}): Step => ({ title, bin: "health-manager", verb, fixed: [id], ...extra });

function Pick({ id, label, status, pick }: { id: string; label: string; status?: HealthStatus | null; pick: (id: string) => void }) {
  return (
    <button className="hlink" onClick={() => pick(id)}>
      {status ? <Dot level={LEVEL[status]} title={status} /> : null} {label}
    </button>
  );
}

function ConditionRow({ o, c, canAck, canUnack }: { o: HealthObject; c: HealthCondition; canAck: boolean; canUnack: boolean }) {
  const silenced = c.acknowledged || c.maintenance;
  return (
    <li className={`att att-${LEVEL[c.status]}`}>
      <Tag level={c.status} />
      <span className="att-gate">{c.type}</span>
      <span className="att-text">
        {c.message ?? c.reason ?? c.status}
        <span className="muted small">
          {c.since ? ` · since ${when(c.since)}` : ""}
          {c.source ? ` · ${c.source}` : ""}
          {c.derived ? " · derived" : ""}
          {c.flapping ? " · flapping" : ""}
        </span>
        {c.ack ? <span className="muted small"> · acknowledged by {c.ack.by ?? "?"}{c.ack.until ? ` until ${when(c.ack.until)}` : ""}{c.ack.sticky ? ", sticky" : ""}{c.ack.note ? `: ${c.ack.note}` : ""}</span> : c.acknowledged ? <span className="muted small"> · silenced with its root</span> : null}
        {c.window ? <span className="muted small"> · maintenance{c.window.until ? ` until ${when(c.window.until)}` : ""}{c.window.note ? `: ${c.window.note}` : ""}</span> : null}
      </span>
      {c.status !== "ok" && !c.derived && !silenced ? (
        <OperateButton label="Ack…" disabled={!canAck} hint={canAck ? undefined : "health-manager on this site has no ack verb"} title={`Acknowledge ${c.type} on ${o.label}`} steps={[hm(`health-manager ack ${o.label} --type ${c.type}`, "ack", o.id, { initial: { "--type": c.type }, note: "The condition keeps its status but stops counting for validate, mails and the Overview. On a root cause it covers the symptoms too." })]} />
      ) : null}
      {c.ack ? <OperateButton label="Unack…" disabled={!canUnack} hint={canUnack ? undefined : "health-manager on this site has no unack verb"} title={`Remove the acknowledgement of ${c.type} on ${o.label}`} steps={[hm(`health-manager unack ${o.label} --type ${c.type}`, "unack", o.id, { initial: { "--type": c.type } })]} /> : null}
    </li>
  );
}

function Verbs({ o }: { o: HealthObject }) {
  // Status, not operations (ADR-034 D11): the health verbs on the object stay
  // here; a module's operations are on its page, behind the Open module jump.
  const maint = useVerb("health-manager", "maintenance");
  return (
    <div className="toolbar">
      <OperateButton label="Maintenance…" disabled={!maint} hint={maint ? undefined : "health-manager on this site has no maintenance verb"} title={`A maintenance window on ${o.label}`} steps={[hm(`health-manager maintenance ${o.label}`, "maintenance", o.id, { note: "During the window transitions are recorded but neither mailed nor counted." })]} />
    </div>
  );
}

export function HealthPanel({ id, close, pick, showInTree }: { id: string; close: () => void; pick: (id: string) => void; showInTree: () => void }) {
  const r = useRead<HealthObject>(`health/object/${encodeURIComponent(id)}`);
  const ack = useVerb("health-manager", "ack");
  const unack = useVerb("health-manager", "unack");
  const o = r.env?.data;
  const out = (o?.relations ?? []).filter((x) => x.direction === "out");
  const inc = (o?.relations ?? []).filter((x) => x.direction === "in");
  return (
    <aside className="sidepanel health-panel">
      <header>
        <div>
          <b>{o?.label ?? "…"}</b>
          <div className="muted small">{o?.class ?? ""}{o?.ancestors.length ? ` · ${o.ancestors.filter((a) => a !== o.class && a !== "object").join(" › ")}` : ""}</div>
        </div>
        <button className="btn-x" onClick={close} aria-label="Close">×</button>
      </header>
      <ReadState env={r.env} failure={r.failure} what="this object" />
      {o ? (
        <>
          <p>
            {o.module ? <Link to={`/modules/${encodeURIComponent(o.module)}`} className="jump jump-in">Open module {o.module}</Link> : null}
            {o.class === "machine" ? <Link to={`/site/assets?select=node:${encodeURIComponent(o.name)}`} className="jump jump-in">Asset · {o.name}</Link> : null}
            <button className="hlink" onClick={showInTree}>Show in tree</button>
          </p>
          <Verbs o={o} />
          <Section title="Conditions" aside={`${o.conditions.length}`}>
            {o.conditions.length === 0 ? <p className="muted">No condition: nothing has assessed this object.</p> : null}
            <ul className="attention">
              {[...o.conditions].sort((a, b) => Number(a.status === "ok") - Number(b.status === "ok")).map((c) => (
                <ConditionRow key={c.type} o={o} c={c} canAck={!!ack} canUnack={!!unack} />
              ))}
            </ul>
          </Section>
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
            {o.changes.length ? (
              <>
                <h3>Changes to it</h3>
                <ul className="findings">
                  {o.changes.slice(0, 12).map((c) => (
                    <li key={c.id}><span className="nowrap">{when(c.time)}</span> {c.verb ?? c.kind} <span className="muted small">{c.source}{c.actor ? ` · ${c.actor}` : ""}</span></li>
                  ))}
                </ul>
              </>
            ) : null}
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
