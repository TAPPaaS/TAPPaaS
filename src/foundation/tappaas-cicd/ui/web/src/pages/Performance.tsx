// Performance — how well the site runs (ADR-046 D7), in four tabs: Overview
// (the most saturated resources by USE, the slowest and most failing published
// services by RED, any performance root cause on top; a site at off says so
// and offers basic with its cost), Browse (the Health view's tree coloured by
// the performance condition, an object's charts with its changes),
// Investigations (the timed raises: in force, Extend, Stop, history) and
// Configuration (the levels' cascade, its cost against the logging VM, a
// change as a job). Every
// number is read by the console's server from the metrics store.

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRead } from "../api";
import { PHONE_QUERY } from "../breakpoints";
import { NO_FILTERS } from "../healthgraph";
import { ClassIcon } from "../moduleicon";
import { OperateButton } from "../operate";
import { Sparkline } from "../perfchart";
import { PerfCharts, PerfLevelVerbs, levelLine } from "../perfpanel";
import { PerfCost, PerfInvestigation, PerfInvestigations, PerfLevelRow, PerfLevels, PerfOverview, PerfTop, RANGES, fmtSeries, fmtSize, fmtValue } from "../perftypes";
import { performanceRoots } from "../perfroots";
import { investigateStep, levelStep, stopStep, usePerfVerbs } from "../perfverbs";
import { Dot, Level, Link, ReadState, Section, Tag, navigate, replacePath, when } from "../ui";
import { TreePane, useTree, Matches } from "./HealthTree";

export type PerfTab = "overview" | "browse" | "levels" | "investigations";
export const PERF_TABS: { tab: PerfTab; label: string; path: string }[] = [
  { tab: "overview", label: "Overview", path: "/performance" },
  { tab: "browse", label: "Browse", path: "/performance/browse" },
  { tab: "investigations", label: "Investigations", path: "/performance/investigations" },
  { tab: "levels", label: "Configuration", path: "/performance/configuration" },
];
// /performance/levels was the Configuration tab's earlier address.
export const perfTabOf = (path: string): PerfTab => {
  const p = path.replace(/\/+$/, "");
  return p === "/performance/levels" ? "levels" : PERF_TABS.find((t) => t.path === p)?.tab ?? "overview";
};

const LEVEL: Record<string, Level> = { ok: "pass", warning: "warn", critical: "fail", unknown: "skip" };
const browseTo = (id: string): string => `/performance/browse?select=${encodeURIComponent(id)}`;

export function costLine(c: PerfCost, retentionDays?: number): string {
  if (!c.series) return "nothing";
  return `${fmtSeries(c.series)} series · ${fmtSize(c.diskMBPerDay)} a day${retentionDays ? ` · ${fmtSize(c.diskGB * 1024)} over ${retentionDays} days` : ""} · ${fmtSize(c.memoryMB)} memory`;
}

// ── Overview ─────────────────────────────────────────────────────────

function TopRows({ rows, empty }: { rows: PerfTop[]; empty: string }) {
  if (!rows.length) return <p className="muted">{empty}</p>;
  return (
    <ul className="perf-rows">
      {rows.map((r) => (
        <li key={`${r.ci.id}${r.signal}`} className="perf-row">
          <div className="perf-row-name">
            <ClassIcon cls={r.ci.class} size={18} />
            <Link to={browseTo(r.ci.id)}>{r.ci.label}</Link>
            <span className="muted small">{r.label}</span>
          </div>
          <div className="perf-row-value">
            <Dot level={LEVEL[r.status]} title={r.status} /> <b>{fmtValue(r.value, r.unit)}</b>
            {r.warning !== null ? <span className="muted small"> warning at {fmtValue(r.warning, r.unit)}</span> : null}
          </div>
          <div className="perf-row-spark">
            <Sparkline points={r.spark} warning={r.warning} mark={r.lastChange} label={`${r.label} of ${r.ci.label} over 24 hours`} />
            <span className="muted small">{r.lastChange ? `last change ${when(r.lastChange.at)}: ${r.lastChange.label}` : "no change in 24 hours"}</span>
          </div>
        </li>
      ))}
    </ul>
  );
}

function OffSite({ o }: { o: PerfOverview }) {
  const row: PerfLevelRow = { scope: "site", name: o.site, environment: null, ciId: null, level: o.level, set: o.levelFrom === "site", from: "", resolution: "normal", resolutionSet: false, cost: { series: 0, diskMBPerDay: 0, diskGB: 0, memoryMB: 0 } };
  const c = o.basicCost;
  return (
    <section className="perf-off">
      <h2>This site collects no performance numbers</h2>
      <p>
        Its level is <b>off</b>{o.levelFrom === "size" ? `, the default for a ${o.size} site` : ", set in the site's record"}. The health checks and the logs work as before; only the numbers over time are missing.
      </p>
      {c ? (
        <p>
          Switching on <b>basic</b> collects CPU, memory, disk and network of the nodes, guests, pools and the backup server once a minute: about {costLine(c)}
          {o.logging.memoryMB ? ` on the logging VM (${fmtSize(o.logging.memoryMB)} memory, ${o.logging.diskGB ?? "?"} GB disk)` : ""}.
        </p>
      ) : null}
      {!o.logging.installed ? <p className="readstate readstate-warn">The numbers are kept by the logging module, which is not installed.</p> : null}
      <div className="toolbar">
        <OperateButton label="Switch on basic…" kind="primary" disabled={!o.logging.installed} hint={o.logging.installed ? undefined : "install the logging module first"} title="Switch on performance monitoring" steps={() => [levelStep(row, "basic")]} />
        {!o.logging.installed ? <span className="muted small">Install the logging module first.</span> : null}
      </div>
    </section>
  );
}

function OverviewTab() {
  const r = useRead<PerfOverview>("performance/overview", 60_000);
  const o = r.env?.data;
  return (
    <>
      <ReadState env={r.env} failure={r.failure} what="the performance overview" />
      {o ? (
        <>
          <p className="muted">
            Level <b>{o.level}</b> {o.levelFrom === "size" ? `(the default for a ${o.size} site)` : "(set in the site's record)"}
            {o.investigations ? <> · <Link to="/performance/investigations">{o.investigations} investigation{o.investigations === 1 ? "" : "s"} in force</Link></> : null}
          </p>
          {o.roots.length ? (
            <Section title="Root causes" aside={`${o.roots.length}`}>
              <ul className="attention">
                {o.roots.map((x) => (
                  <li key={x.id} className={`att att-${LEVEL[x.status]}`}>
                    <Tag level={x.status === "critical" ? "fail" : x.status === "warning" ? "warn" : x.status} />
                    <span className="att-gate"><Link to={browseTo(x.id)}>{x.label}</Link></span>
                    <span className="att-text">
                      {x.message ?? x.status}
                      <span className="muted small">{x.since ? ` · since ${when(x.since)}` : ""}{x.impacted.length ? ` · slows ${x.impacted.map((i) => i.label).join(", ")}` : ""}</span>
                    </span>
                  </li>
                ))}
              </ul>
            </Section>
          ) : null}
          {o.store === "off" ? <OffSite o={o} /> : null}
          {o.store === "unreachable" ? <p className="readstate readstate-warn">The metrics store did not answer: {o.storeError}</p> : null}
          {o.store === "on" ? (
            <>
              <Section title="Most saturated resources" aside="now, and the last 24 hours">
                <TopRows rows={o.saturated} empty="No node, guest or pool has numbers yet." />
              </Section>
              <Section title="Slowest and most failing services" aside="published services, the user's view">
                <TopRows rows={o.services} empty="No published service is measured: services are measured from level service. Raise a module to service in Configuration." />
              </Section>
            </>
          ) : null}
        </>
      ) : null}
    </>
  );
}

// ── Browse ───────────────────────────────────────────────────────────

const phone = (): boolean => window.matchMedia(PHONE_QUERY).matches;

function BrowseTab() {
  const tree = useTree();
  const ov = useRead<PerfOverview>("performance/overview", 60_000).env?.data;
  // The roots from their performance condition, not the object's worst one.
  const roots = useMemo(() => performanceRoots(ov?.roots ?? [], tree.doc?.roots ?? []), [ov, tree.doc]);
  const [selected, setSelected] = useState<string | null>(() => new URLSearchParams(window.location.search).get("select"));
  const [sheet, setSheet] = useState(false);
  const go = useCallback((id: string) => {
    setSelected(id);
    setSheet(false);
    replacePath(browseTo(id));
  }, []);
  // Nothing asked for: the first performance root, else the site.
  useEffect(() => {
    if (selected || !tree.doc || !ov) return;
    const first = ov.roots[0]?.id ?? tree.doc.site;
    if (first) go(first);
  }, [selected, tree.doc, ov, go]);
  useEffect(() => {
    if (selected) void tree.reveal(selected);
    // eslint-disable-next-line
  }, [selected]);
  return (
    <>
      <ReadState env={tree.read.env} failure={tree.read.failure} what="the CMDB's objects" />
      <div className="toolbar perf-browse-bar">
        <span className="muted small">Coloured by the performance condition: green is fast enough or not judged.</span>
        <span className="spacer" />
        <button className="btn health-sheet-btn" onClick={() => setSheet(!sheet)}>Tree</button>
      </div>
      <div className="health-view perf-browse">
        <TreePane m={tree} selected={selected} select={go} chooseRoot={go} filters={NO_FILTERS} open={sheet} lens="performance" roots={roots} />
        <div className="perf-browse-main">
          {selected ? <BrowseObject id={selected} pick={go} /> : <p className="muted">Pick an object in the tree.</p>}
        </div>
      </div>
    </>
  );
}

function BrowseObject({ id, pick }: { id: string; pick: (id: string) => void }) {
  const o = useRead<{ id: string; label: string; class: string }>(`health/object/${encodeURIComponent(id)}`).env?.data;
  return (
    <section className="perf-object">
      <header className="perf-object-head">
        <b className="ci-title">{o ? <ClassIcon cls={o.class} size={20} /> : null}{o?.label ?? "…"}</b>
        <span className="muted small">{o?.class}</span>
        <span className="spacer" />
        <Link to={`/health?select=${encodeURIComponent(id)}`}>Details</Link>
      </header>
      <PerfCharts key={id} id={id} ranges={RANGES} pick={pick} />
    </section>
  );
}

// ── Levels ───────────────────────────────────────────────────────────

function Meter({ used, of, label }: { used: number; of: number | null; label: string }) {
  if (!of) return <span className="muted small">{label}: the logging VM's size is not known</span>;
  const pct = Math.min(100, (used / of) * 100);
  return (
    <div className="perf-meter" title={`${label}: ${pct.toFixed(0)} %`}>
      <span className="small">{label}</span>
      <span className={`perf-meter-bar${pct > 80 ? " perf-meter-high" : ""}`}><span style={{ width: `${pct}%` }} /></span>
      <span className="small muted">{fmtSize(used)} of {fmtSize(of)}</span>
    </div>
  );
}

function LevelRows({ rows, l }: { rows: PerfLevelRow[]; l: PerfLevels }) {
  return (
    <table className="table compact perf-levels">
      <thead>
        <tr><th>Name</th><th>Level</th><th className="perf-col-cost">Cost</th><th /></tr>
      </thead>
      <tbody>
        {rows.map((r) => {
          const envBlocked = r.scope === "environment" && !l.verbs.environmentLevel;
          return (
            <tr key={`${r.scope}${r.name}`}>
              <td>
                {r.ciId ? <Link to={browseTo(r.ciId)}>{r.name}</Link> : r.name}
                {r.environment ? <div className="muted small">{r.environment}</div> : null}
              </td>
              <td>
                <b>{r.level}</b>{r.resolution === "fine" ? <span className="muted small"> · every 15 s</span> : null}
                <div className="muted small">{r.set ? "set here" : `as ${r.from}`}</div>
              </td>
              <td className="perf-col-cost small">{r.scope === "site" ? "—" : r.cost.series ? `${fmtSeries(r.cost.series)} series · ${fmtSize(r.cost.memoryMB)}` : "nothing"}</td>
              <td className="perf-col-act">
                <OperateButton label="Change…" disabled={envBlocked} hint={envBlocked ? "environment-manager does not take performance.level yet" : undefined} steps={() => [levelStep(r)]} title={r.scope === "site" ? "The site's performance level" : `Performance level of ${r.name}`} />
                {envBlocked ? <div className="muted small">not settable yet</div> : null}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

function LevelsTab() {
  const r = useRead<PerfLevels>("performance/levels", 60_000);
  const l = r.env?.data;
  return (
    <>
      <ReadState env={r.env} failure={r.failure} what="the performance levels" />
      {l ? (
        <>
          <Section title="What it costs" aside="an estimate, from the levels">
            <p>
              Kept {l.retentionDays} days{l.retentionSet ? "" : ` (the default for a ${l.size} site)`}, the 5-minute trends 90 days.
              Estimated {costLine(l.total, l.retentionDays)}.
              {l.measuredSeries !== null ? ` The store holds ${fmtSeries(l.measuredSeries)} series now.` : ""}
            </p>
            {l.logging.installed ? (
              <div className="perf-meters">
                <Meter used={l.total.memoryMB} of={l.logging.memoryMB} label="Memory of the logging VM" />
                <Meter used={l.total.diskGB * 1024} of={l.logging.diskGB === null ? null : l.logging.diskGB * 1024} label="Disk of the logging VM" />
              </div>
            ) : <p className="readstate readstate-warn">The logging module, which keeps the numbers, is not installed.</p>}
            <p className="muted small">The logging VM's memory and disk also hold the logs; the estimate counts the numbers only.</p>
          </Section>
          <Section title="Site">
            <LevelRows rows={l.rows.filter((x) => x.scope === "site")} l={l} />
          </Section>
          <Section title="Environments" aside="a module follows its environment unless it sets its own">
            <LevelRows rows={l.rows.filter((x) => x.scope === "environment")} l={l} />
          </Section>
          <Section title="Modules">
            <LevelRows rows={l.rows.filter((x) => x.scope === "module")} l={l} />
          </Section>
        </>
      ) : null}
    </>
  );
}

// ── Investigations ───────────────────────────────────────────────────

function Remaining({ until, now }: { until: string; now: number }) {
  const m = Math.max(0, Math.round((Date.parse(until) - now) / 60_000));
  return <span className="muted small">{m >= 120 ? `${Math.round(m / 60)} hours left` : `${m} minutes left`}</span>;
}

function ActiveRow({ x, now }: { x: PerfInvestigation; now: number }) {
  const verbs = usePerfVerbs();
  const ci = { id: x.ci.id, label: x.ci.name };
  return (
    <li className="perf-inv">
      <div className="perf-inv-head">
        <ClassIcon cls={x.ci.class} size={18} />
        <Link to={browseTo(x.ci.id)}>{x.ci.name}</Link>
        <b>{x.level}</b>{x.resolution === "fine" ? <span className="muted small"> · every 15 s</span> : null}
      </div>
      <div className="small">
        Until <b>{when(x.until)}</b> <Remaining until={x.until} now={now} /> · started by {x.by} {when(x.started)} · then {x.from} again
        {x.note ? <span className="muted"> · {x.note}</span> : null}
      </div>
      <div className="toolbar">
        <OperateButton label="Extend…" disabled={!verbs.perf} steps={() => [investigateStep(ci, x.from, x)]} title={`Extend the investigation of ${x.ci.name}`} />
        <OperateButton label="Stop…" disabled={!verbs.stop} steps={() => [stopStep(ci, x.from)]} title={`Stop the investigation of ${x.ci.name}`} />
      </div>
    </li>
  );
}

function StartOne() {
  const [text, setText] = useState("");
  const [q, setQ] = useState("");
  const [picked, setPicked] = useState<string | null>(null);
  useEffect(() => {
    const t = setTimeout(() => setQ(text.trim()), 250);
    return () => clearTimeout(t);
  }, [text]);
  const ci = useRead<{ id: string; label: string; class: string }>(picked ? `health/object/${encodeURIComponent(picked)}` : null).env?.data ?? null;
  return (
    <div className="perf-start">
      <input className="ht-search" type="search" value={text} onChange={(e) => setText(e.target.value)} placeholder="Find an object: a guest, a node, a pool, a published service" aria-label="find an object to investigate" />
      {q ? <Matches q={q} selected={picked} select={setPicked} lens="performance" /> : null}
      {picked && ci ? (
        <>
          <p className="small">Chosen: <b>{ci.label}</b> <span className="muted">{ci.class}</span></p>
          <PerfLevelVerbsFor id={ci.id} label={ci.label} />
        </>
      ) : null}
    </div>
  );
}

function PerfLevelVerbsFor({ id, label }: { id: string; label: string }) {
  const r = useRead<{ level: Parameters<typeof PerfLevelVerbs>[0]["level"] }>(`performance/ci/${encodeURIComponent(id)}?range=24h`, 120_000).env?.data;
  if (!r) return <p className="muted small">reading its level…</p>;
  return (
    <>
      <p className="small muted">Its level now: {levelLine(r.level)}</p>
      <PerfLevelVerbs ci={{ id, label }} level={r.level} />
    </>
  );
}

function InvestigationsTab() {
  const r = useRead<PerfInvestigations>("performance/investigations", 30_000);
  const d = r.env?.data;
  const now = d ? Date.parse(d.now) : Date.now();
  return (
    <>
      <ReadState env={r.env} failure={r.failure} what="the investigations" />
      {d && !d.available ? <p className="readstate readstate-warn">health-manager on this site has no perf verbs yet: no object can be raised for a time, and none is.</p> : null}
      {d?.error ? <p className="readstate readstate-fail">health-manager perf list failed: {d.error}</p> : null}
      {d ? (
        <>
          <Section title="In force" aside={`${d.active.length}`}>
            {d.active.length ? <ul className="plain">{d.active.map((x) => <ActiveRow key={x.ci.id} x={x} now={now} />)}</ul> : <p className="muted">No object is raised: every one runs at its level.</p>}
          </Section>
          <Section title="Investigate an object" aside="trace needs an end; it falls back by itself">
            <StartOne />
          </Section>
          <Section title="Ended" aside="the last 90 days">
            {d.history.length ? (
              <table className="table compact">
                <thead><tr><th>Object</th><th>Level</th><th>When</th><th>How it ended</th></tr></thead>
                <tbody>
                  {d.history.map((x, i) => (
                    <tr key={i}>
                      <td><Link to={browseTo(x.ci.id)}>{x.ci.name}</Link>{x.note ? <div className="muted small">{x.note}</div> : null}</td>
                      <td>{x.level}{x.resolution === "fine" ? <span className="muted small"> · 15 s</span> : null}</td>
                      <td className="small">{when(x.started)}<div className="muted">by {x.by}</div></td>
                      <td className="small">{x.endedHow === "stopped" ? `stopped${x.endedBy ? ` by ${x.endedBy}` : ""}` : "ran out"}<div className="muted">{when(x.ended)}</div></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : <p className="muted">None ended in the last 90 days.</p>}
          </Section>
        </>
      ) : null}
    </>
  );
}

export function Performance({ tab }: { tab: PerfTab }) {
  useEffect(() => {
    if (phone() && tab === "browse") window.scrollTo(0, 0);
  }, [tab]);
  return (
    <div className={`page${tab === "browse" ? " page-wide" : ""}`}>
      <div className="page-head">
        <h1>Performance</h1>
        <span className="muted">how well the site runs, and since when</span>
      </div>
      <div className="tabs" role="tablist">
        {PERF_TABS.map((t) => (
          <button key={t.tab} role="tab" aria-selected={tab === t.tab} className={tab === t.tab ? "tab tab-on" : "tab"} onClick={() => navigate(t.path)}>
            {t.label}
          </button>
        ))}
      </div>
      <div>
        {tab === "overview" ? <OverviewTab /> : tab === "browse" ? <BrowseTab /> : tab === "levels" ? <LevelsTab /> : <InvestigationsTab />}
      </div>
    </div>
  );
}
