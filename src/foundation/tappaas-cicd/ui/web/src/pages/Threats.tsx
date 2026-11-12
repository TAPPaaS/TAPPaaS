// Threats — the Security page's second tab: what is happening on the running
// systems, from the threat conditions health-manager wrote on the CIs (the
// SIEM's findings, a system not built from the repository, an alert that says
// something is exposed). The open findings per node and module, critical
// first, with their hits, first and last, and the hold left; the CVE state of
// the same object beside each, so a hit on something with an open CVE stands
// out. Each row: Ack… in the words of the rule that holds it, Logs (the rule's
// own query), and the object's panel. Below, the acknowledgements of the last
// 30 days and why. Read-only but for the ack.

import { useState } from "react";
import { useHealthStream, useRead, useVerb } from "../api";
import { holdText, hitsCount } from "../healthwords";
import { OperateButton } from "../operate";
import { ThreatRow, ThreatsView } from "../types";
import { Badge, ReadState, Section, Tag, navigate, since, when } from "../ui";
import { HealthPanel, ackStep } from "./HealthPanel";

const CVE_TONE: Record<string, "fail" | "warn" | "pass" | "skip"> = { critical: "fail", warning: "warn", ok: "pass", unknown: "skip" };

function CveState({ c }: { c: ThreatRow["cve"] }) {
  if (!c) return <span className="muted small">not scanned</span>;
  const word = c.reason && c.reason !== "ok" ? c.reason.replace(/^cve-/, "") : c.status === "ok" ? "no open CVE" : c.status;
  return <Badge level={CVE_TONE[c.status] ?? "skip"} title={c.message ?? undefined}>{c.open ? `open CVE: ${word}` : word}</Badge>;
}

function Rows({ rows, pick, selected, canAck }: { rows: ThreatRow[]; pick: (id: string) => void; selected: string | null; canAck: boolean }) {
  return (
    <div className="thr-table">
      <div className="thr-row thr-head muted small">
        <span>status</span><span>object</span><span>what</span><span>hits</span><span>first</span><span>last</span><span>hold</span><span>CVE</span><span />
      </div>
      {rows.map((r) => {
        const logs = r.logs?.rules[0]?.url ?? r.logs?.url ?? null;
        return (
          <div key={`${r.id}-${r.reason}`} className={`thr-row${r.cve?.open ? " thr-cve" : ""}${selected === r.id ? " thr-on" : ""}`}>
            <span>{r.acknowledged ? <span className="tag tag-ack" title="acknowledged">{r.status.toUpperCase()}</span> : <Tag level={r.status} />}</span>
            <span className="thr-object">
              <button className="hlink" onClick={() => pick(r.id)} title="Open its panel"><b>{r.label}</b></button>
              <span className="muted small"> {r.class}{r.module && r.module !== r.name ? ` · ${r.module}` : ""}{r.environment ? ` · ${r.environment}` : ""}</span>
            </span>
            <span className="thr-what">{r.message ?? r.reason ?? r.status}{r.maintenance ? <span className="muted" title="in a maintenance window: a critical stays listed"> ⏸</span> : null}</span>
            <span className="nowrap">{r.hits ? hitsCount(r.hits) : "—"}</span>
            <span className="nowrap small" data-label="first">{r.hits ? when(r.hits.first) : r.since ? when(r.since) : "—"}</span>
            <span className="nowrap small" data-label="last">{r.hits ? since(r.hits.last) : "—"}</span>
            <span className="nowrap small" data-label="hold">{holdText(r.heldUntil) || "—"}</span>
            <span><CveState c={r.cve} /></span>
            <span className="thr-acts">
              {!r.acknowledged ? <OperateButton label="Ack…" disabled={!canAck} hint={canAck ? undefined : "health-manager on this site has no ack verb"} title={`Acknowledge threat on ${r.label}`} steps={[ackStep(r, { type: "threat", heldUntil: r.heldUntil, heldBy: r.heldBy })]} /> : null}
              {logs ? <a className="hlink" href={logs} target="_blank" rel="noreferrer" title={r.logs?.rules.length ? "Grafana Explore: the query of the rule that raised it, as its mail has it" : "Grafana Explore: the object's lines"}>Logs</a> : null}
            </span>
          </div>
        );
      })}
    </div>
  );
}

export function Threats() {
  const r = useRead<ThreatsView>("security/threats", 60_000);
  const v = r.env?.data ?? null;
  const ack = useVerb("health-manager", "ack");
  const [sel, setSel] = useState<string | null>(() => new URLSearchParams(window.location.search).get("select"));
  useHealthStream(() => r.reload(), () => undefined);
  const pick = (id: string): void => setSel(id);
  return (
    <div className="thr-view">
      <div className="thr-main">
        <ReadState env={r.env} failure={r.failure} what="the threat conditions" />
        {v && !v.hasConditions ? <p className="readstate readstate-warn">No object carries a condition yet: this site has not run <span className="mono">health-manager assess</span>.</p> : null}
        <Section title="Open findings" aside={v ? `${v.counts.critical} critical · ${v.counts.warning} warning · ${v.counts.silenced} silenced` : undefined}>
          {v && v.hasConditions && !v.open.length ? <p className="muted">No open threat finding.</p> : null}
          {v?.open.length ? <Rows rows={v.open} pick={pick} selected={sel} canAck={!!ack} /> : null}
          {v?.silenced.length ? (
            <details className="thr-silenced">
              <summary className="small">{v.silenced.length} acknowledged or in a maintenance window</summary>
              <Rows rows={v.silenced} pick={pick} selected={sel} canAck={!!ack} />
            </details>
          ) : null}
          <p className="muted small">A warning holds a day from its last hit; a critical holds until someone acknowledges it with a reason. A new hit opens it again. A hit on something with an open CVE is marked.</p>
        </Section>
        <Section title="Recent acknowledgements" aside="the last 30 days">
          {v && !v.acks.length ? <p className="muted">None.</p> : null}
          {v?.acks.length ? (
            <table className="table compact">
              <thead>
                <tr><th>when</th><th>object</th><th>by</th><th>why</th><th>until</th></tr>
              </thead>
              <tbody>
                {v.acks.map((a) => (
                  <tr key={`${a.id}-${a.at}`}>
                    <td className="nowrap">{when(a.at)}</td>
                    <td><button className="hlink" onClick={() => pick(a.id)}>{a.label}</button> <span className="muted small">{a.class}</span></td>
                    <td>{a.by || "—"}</td>
                    <td className="wrap">{a.note || <span className="muted">no reason given</span>}</td>
                    <td className="nowrap">{a.until ? when(a.until) : "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : null}
        </Section>
      </div>
      {sel ? <HealthPanel id={sel} close={() => setSel(null)} pick={pick} showInTree={() => navigate(`/health?select=${encodeURIComponent(sel)}`)} /> : null}
    </div>
  );
}
