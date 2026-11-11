// perfpanel.tsx — one CI's performance (ADR-046 D7): its level and where it
// comes from, a raise's expiry, the Investigate / Extend / Stop verbs, and its
// key signals over a range with the changes on it. The CI panel's Performance
// section (24 h / 7 d) and the Browse view's charts (all four ranges) are both
// this component.

import { useState } from "react";
import { useRead } from "./api";
import { OperateButton } from "./operate";
import { Chart, Markers } from "./perfchart";
import { PerfCi, PerfEffective, PerfInvestigations, PerfRange, chartsShown } from "./perftypes";
import { investigateStep, stopStep, usePerfVerbs } from "./perfverbs";
import { ReadState, when } from "./ui";

const FROM: Record<PerfEffective["from"], string> = {
  site: "the site's level",
  size: "the site's size",
  environment: "its environment",
  module: "its module",
  investigation: "an investigation",
};

export function levelLine(l: PerfEffective): string {
  const res = l.resolution === "fine" ? ", every 15 seconds" : "";
  if (l.from === "investigation") return `${l.level}${res} until ${when(l.until)}${l.by ? `, started by ${l.by}` : ""}; then ${l.cascaded} again`;
  return `${l.level}${res}, from ${FROM[l.from]}`;
}

export function PerfLevelVerbs({ ci, level }: { ci: { id: string; label: string }; level: PerfEffective }) {
  const verbs = usePerfVerbs();
  const inv = useRead<PerfInvestigations>("performance/investigations", 60_000).env?.data;
  const current = inv?.active.find((x) => x.ci.id === ci.id) ?? null;
  const why = "health-manager on this site has no perf verb yet";
  return (
    <div className="toolbar">
      <OperateButton label={current ? "Extend…" : "Investigate…"} disabled={!verbs.perf} hint={verbs.perf ? undefined : why} title={current ? `Extend the investigation of ${ci.label}` : `Investigate ${ci.label}`} steps={() => [investigateStep(ci, level.cascaded, current)]} />
      {current ? <OperateButton label="Stop…" disabled={!verbs.stop} hint={verbs.stop ? undefined : why} title={`Stop the investigation of ${ci.label}`} steps={() => [stopStep(ci, level.cascaded)]} /> : null}
      {!verbs.perf ? <span className="muted small">{why}</span> : null}
    </div>
  );
}

export function PerfCharts({ id, ranges, pick, max }: { id: string; ranges: PerfRange[]; pick?: (id: string) => void; max?: number }) {
  const [range, setRange] = useState<PerfRange>(ranges[0]);
  const r = useRead<PerfCi>(`performance/ci/${encodeURIComponent(id)}?range=${range}`, 120_000);
  const d = r.env?.data;
  const shown = d ? chartsShown(d.series, max) : [];
  return (
    <div className="perf-ci">
      <ReadState env={r.env} failure={r.failure} what="its numbers" />
      {d ? (
        <>
          <p className="small">
            Level <b>{levelLine(d.level)}</b>
          </p>
          <PerfLevelVerbs ci={{ id: d.ci.id, label: d.ci.label }} level={d.level} />
          <div className="tabs perf-ranges" role="tablist" aria-label="range">
            {ranges.map((x) => (
              <button key={x} role="tab" aria-selected={x === range} className={x === range ? "tab tab-on" : "tab"} onClick={() => setRange(x)}>
                {x === "90d" ? "90-day trend" : x}
              </button>
            ))}
          </div>
          {d.store === "unreachable" ? <p className="readstate readstate-warn">The metrics store did not answer: {d.storeError}</p> : null}
          {d.note ? <p className="muted">{d.note}</p> : null}
          {shown.map((s) => <Chart key={s.key} series={s} marks={d.annotations} range={range} now={Date.now()} />)}
          {d.annotations.length ? (
            <>
              <h3>Changes in this range</h3>
              <Markers marks={d.annotations} />
            </>
          ) : d.series.length ? <p className="muted small">No change to it in this range.</p> : null}
          <p className="perf-links">
            {d.links.rootCause && pick ? <button className="hlink" onClick={() => pick(d.links.rootCause!.id)}>Root cause: {d.links.rootCause.label}</button> : null}
            {d.links.grafana ? <a href={d.links.grafana} target="_blank" rel="noreferrer">Grafana ↗</a> : <span className="muted small">Grafana: the logging module is not installed</span>}
            {d.links.traces ? <a href={d.links.traces} target="_blank" rel="noreferrer">Traces ↗</a> : <span className="muted small">Traces: only while it is at level trace and traces are stored</span>}
          </p>
        </>
      ) : null}
    </div>
  );
}
