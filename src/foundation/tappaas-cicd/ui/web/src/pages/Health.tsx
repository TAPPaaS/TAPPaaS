// Health — one page with one object (ADR-041 D5): the graph of every CMDB
// object, coloured by its worst condition and centred on the root causes. The
// layout is computed once per change of the topology (or of the open groups)
// and the colours patched on the live stream, so a few hundred objects redraw
// in no time. A filter or the time slider never moves a card.

import { Background, Controls, MiniMap, ReactFlow, ReactFlowProvider, useReactFlow } from "@xyflow/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useHealthStream, useRead } from "../api";
import { GEdge, GNode, edgeTypes, layout, nodeTypes } from "../graph";
import { Card, Filters, NO_FILTERS, applyPatch, boundsOf, centreCards, collapse, groupsOf, hotSet, kept, replay, rollup, statusClass, viewFor } from "../healthgraph";
import { ClassIcon, ModuleIcon } from "../moduleicon";
import { HealthGraph, HealthRoot, HealthStatus, HealthView } from "../types";
import { Dot, Level, ReadState, Tag, when } from "../ui";
import { HealthPanel } from "./HealthPanel";

const CONDITION_TYPES = ["operational", "drift", "capacity", "security", "maintenance", "backup", "impact"];
const LEVEL: Record<HealthStatus, Level> = { ok: "pass", warning: "warn", critical: "fail", unknown: "skip" };
const STROKE: Record<HealthStatus, string> = { critical: "#d64545", warning: "#d97706", unknown: "#9aa4b2", ok: "#94a3b8" };
const MAP: Record<HealthStatus, string> = { critical: "#d64545", warning: "#d97706", unknown: "#c5ccd6", ok: "#2f9e44" };
const WEEK_HOURS = 168;

const phone = (): boolean => window.matchMedia("(max-width: 700px)").matches;

function Marks({ v }: { v: HealthView }) {
  return (
    <>
      {v.flapping ? <span className="hc-mark" title="flapping: held at its worse value">↯</span> : null}
      {v.acknowledged ? <span className="hc-mark" title="acknowledged">✓</span> : null}
      {v.maintenance ? <span className="hc-mark" title="in a maintenance window">⏸</span> : null}
    </>
  );
}

function ObjectCard({ c, v }: { c: Card; v: HealthView }) {
  const n = c.node!;
  return (
    <>
      <div className="cf-title">
        {n.module ? <ModuleIcon name={n.module} size={20} /> : <ClassIcon cls={n.class} size={20} />}
        <span className="hc-name">{n.label}</span>
        <Marks v={v} />
      </div>
      <div className="cf-sub" title={v.reason ?? undefined}>{v.reason ?? n.class}</div>
    </>
  );
}

function GroupCard({ c, v, shown }: { c: Card; v: HealthView; shown: number }) {
  const bad = c.members.filter((m) => m.status === "critical" || m.status === "warning").length;
  const g = c.group!;
  return (
    <>
      <div className="cf-title">
        <span className="hc-count">{g.members}</span>
        <span className="hc-name">{g.label}</span>
        <Marks v={v} />
      </div>
      <div className="cf-sub">{c.kind === "open" ? "click here to collapse" : bad ? `${bad} of ${shown} need a look` : v.status === "ok" ? "all ok" : `${shown} objects`}</div>
    </>
  );
}

interface FlowProps {
  doc: HealthGraph;
  open: Set<string>;
  toggle: (group: string) => void;
  pick: (id: string) => void;
  picked: string | null;
  focus: string | null;
  filters: Filters;
  nonce: number; // a new value recentres
}

function Flow({ doc, open, toggle, pick, picked, focus, filters, nonce }: FlowProps) {
  const rf = useReactFlow();
  const key = `${doc.topology}|${[...open].sort().join(",")}`;
  const act = useRef({ toggle, pick });
  act.current = { toggle, pick };
  // Once per topology: what moves a card. The colours below are patched over it.
  const base = useMemo(() => {
    const { cards, lines } = collapse(doc, open);
    const nodes: GNode[] = cards.map((c) => ({
      id: c.id,
      w: c.w,
      h: c.h,
      tier: c.parent ? undefined : c.tier,
      parent: c.parent,
      at: c.at,
      content: null,
      onClick: c.kind === "node" ? () => act.current.pick(c.id) : () => act.current.toggle(c.id),
    }));
    const edges: GEdge[] = lines.map((l) => ({ id: l.id, source: l.source, target: l.target, label: l.types.join(", ") }));
    return layout(nodes, edges, "TB", 26, 74);
    // eslint-disable-next-line
  }, [key]);
  const { cards, lines } = useMemo(() => collapse(doc, open), [doc, open]);
  const hot = useMemo(() => hotSet(doc, focus), [doc, focus]);
  const nodes = useMemo(() => {
    const by = new Map(cards.map((c) => [c.id, c]));
    return base.nodes.map((n) => {
      const c = by.get(n.id);
      if (!c) return n;
      const mine = c.node ? [c.node] : c.members;
      const views = mine.filter((m) => kept(m, filters)).map((m) => viewFor(m, filters));
      const v = c.node ? viewFor(c.node, filters) : rollup(views);
      const isHot = !hot || mine.some((m) => hot.has(m.id));
      const out = !views.length || !isHot;
      const root = mine.some((m) => m.isRoot);
      const ring = root ? " hc-root" : hot && isHot ? " hc-halo" : "";
      const cls = `${c.kind === "open" ? "hgroup " : ""}${statusClass(v)}${out ? " hc-dim" : ""}${ring}${picked === c.id ? " gcard-on" : ""}`;
      const content = c.node ? <ObjectCard c={c} v={v} /> : <GroupCard c={c} v={v} shown={c.members.length} />;
      return { ...n, width: c.w, height: c.h, data: { ...n.data, g: { ...n.data.g, className: cls, content } } };
    });
  }, [base, cards, hot, filters, picked]);
  const edges = useMemo(() => {
    const by = new Map(lines.map((l) => [l.id, l]));
    return base.edges.map((e) => {
      const l = by.get(e.id);
      const strong = !!hot && !!l && l.from.some((f, i) => hot.has(f) && hot.has(l.to[i]));
      return { ...e, label: strong ? e.label : undefined, style: { stroke: strong ? STROKE.critical : STROKE.ok, strokeWidth: strong ? 2.6 : 1.1, opacity: hot && !strong ? 0.25 : 1 } };
    });
  }, [base, lines, hot]);
  const target = useRef({ doc, cards, focus, base });
  target.current = { doc, cards, focus, base };
  // By the layout's own numbers, not fitView: that waits on a measure of nodes
  // the colour patch has just replaced.
  useEffect(() => {
    const t = setTimeout(() => {
      const { doc: d, cards: cs, focus: f, base: b } = target.current;
      const box = phone() ? boundsOf(b.nodes, centreCards(d, cs, f), 260, 320) : boundsOf(b.nodes, centreCards(d, cs, f));
      if (box) void rf.fitBounds(box, { padding: 0.15, duration: 300 });
    }, 80);
    return () => clearTimeout(t);
  }, [nonce, key, rf]);
  const mapColor = useCallback((n: { data: Record<string, unknown> }): string => {
    const c = cards.find((x) => x.id === (n.data.g as GNode).id);
    return MAP[(c?.node ?? rollup(c?.members ?? [])).status];
  }, [cards]);
  return (
    <div className="graph health-canvas">
      <ReactFlow nodes={nodes} edges={edges} nodeTypes={nodeTypes} edgeTypes={edgeTypes} minZoom={0.1} maxZoom={1.5} nodesDraggable={false} nodesConnectable={false} elementsSelectable={false} proOptions={{ hideAttribution: true }} onNodeClick={() => undefined}>
        <Background gap={24} color="#e5e7eb" />
        <Controls showInteractive={false} />
        <MiniMap className="health-map" nodeColor={mapColor as never} pannable zoomable />
      </ReactFlow>
    </div>
  );
}

function RootList({ doc, focus, choose }: { doc: HealthGraph; focus: string | null; choose: (r: HealthRoot) => void }) {
  return (
    <ul className="health-roots">
      {doc.roots.map((r) => (
        <li key={r.id}>
          <button className={`hroot${focus === r.id ? " hroot-on" : ""}${r.acknowledged ? " hroot-ack" : ""}`} onClick={() => choose(r)}>
            <span className="hroot-head"><Dot level={LEVEL[r.status]} title={r.status} /> <b>{r.label}</b> <span className="muted small">{r.class}</span></span>
            <span className="small">{r.message ?? r.reason ?? r.type}</span>
            <span className="muted small">
              {r.impactedCount} impacted{r.environments.length ? ` · ${r.environments.join(", ")}` : ""}{r.since ? ` · ${when(r.since)}` : ""}{r.acknowledged ? " · acknowledged" : ""}{r.flapping ? " · flapping" : ""}
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

export function Health() {
  const g = useRead<HealthGraph>("health/graph", 60_000);
  const [live, setLive] = useState<HealthGraph | null>(null);
  useEffect(() => {
    if (g.env?.data) setLive(g.env.data);
  }, [g.env]);
  useHealthStream(
    (p) => {
      if (p.relayout) g.reload();
      else setLive((d) => (d ? applyPatch(d, p) : d));
    },
    () => g.reload(),
  );

  const [hoursBack, setHoursBack] = useState(0);
  const [at, setAt] = useState<string | null>(null);
  useEffect(() => {
    const t = setTimeout(() => setAt(hoursBack === 0 ? null : new Date(Date.now() - hoursBack * 3_600_000).toISOString()), 300);
    return () => clearTimeout(t);
  }, [hoursBack]);
  const past = useRead<HealthGraph>(at ? `health/graph?at=${encodeURIComponent(at)}` : null, 3_600_000);
  const doc = useMemo(() => (live ? replay(live, at ? past.env?.data ?? null : null) : null), [live, at, past.env]);

  const [open, setOpen] = useState<Set<string>>(new Set());
  const [picked, setPicked] = useState<string | null>(null);
  const [focus, setFocus] = useState<string | null>(null);
  const [filters, setFilters] = useState<Filters>(NO_FILTERS);
  const [pinned, setPinned] = useState(false);
  const [sheet, setSheet] = useState(false);
  const [nonce, setNonce] = useState(0);
  const recentre = () => setNonce((n) => n + 1);
  const openFor = useCallback((d: HealthGraph, ids: string[]) => {
    if (phone()) return;
    const gs = groupsOf(d, ids);
    if (gs.length) setOpen((o) => new Set([...o, ...gs]));
  }, []);

  // A root the page has not seen: its group opens, and the view goes to it
  // unless pinned. The first read is the page opening on the roots.
  const seen = useRef<Set<string> | null>(null);
  useEffect(() => {
    if (!live) return;
    const ids = live.roots.map((r) => r.id);
    const first = seen.current === null;
    const fresh = ids.filter((id) => !seen.current?.has(id));
    seen.current = new Set(ids);
    if (first) {
      const select = new URLSearchParams(window.location.search).get("select");
      if (select) setPicked(select);
      openFor(live, [...ids, ...(select ? [select] : [])]);
      recentre();
    } else if (fresh.length && !pinned) {
      openFor(live, fresh);
      setFocus(null);
      recentre();
    }
  }, [live, pinned, openFor]);

  const toggle = useCallback((id: string) => setOpen((o) => {
    const n = new Set(o);
    if (!n.delete(id)) n.add(id);
    return n;
  }), []);
  const choose = (r: HealthRoot) => {
    if (live) openFor(live, [r.id]);
    setFocus(focus === r.id ? null : r.id);
    setPicked(r.id);
    setSheet(false);
    recentre();
  };
  const pick = useCallback((id: string) => {
    setPicked(id);
    if (live) openFor(live, [id]);
  }, [live, openFor]);

  const classes = useMemo(() => [...new Set((live?.nodes ?? []).map((n) => n.class))].sort(), [live?.topology]);
  const environments = useMemo(() => [...new Set((live?.nodes ?? []).map((n) => n.environment).filter((e): e is string => !!e))].sort(), [live?.topology]);
  const set = (k: keyof Filters) => (e: { target: { value: string } }) => setFilters({ ...filters, [k]: e.target.value });
  const c = doc?.counts;
  const siteNode = doc?.nodes.find((n) => n.id === doc.site);

  return (
    <div className="page page-wide">
      <div className="page-head">
        <h1>Health</h1>
        <span className="muted">
          {c ? `${c.critical} critical · ${c.warning} warning · ${c.acknowledged} silenced · ${c.unknown} unknown · ${c.ok} ok` : "…"} · {doc?.generated ? `read ${when(doc.generated)}` : ""}
        </span>
        <span className="spacer" />
        <button className="btn health-sheet-btn" onClick={() => setSheet(!sheet)}>Root causes ({doc?.roots.length ?? 0})</button>
        <button className={`btn${pinned ? " btn-primary" : ""}`} onClick={() => setPinned(!pinned)} title="Pinned: a new root cause does not move the view">{pinned ? "Pinned" : "Pin view"}</button>
        <button className="btn" onClick={() => { setFocus(null); recentre(); }}>Centre</button>
      </div>
      <ReadState env={g.env} failure={g.failure} what="the CMDB's health graph" />
      {doc && !doc.hasConditions ? <p className="readstate readstate-warn">No object carries a condition yet: this site has not run <span className="mono">health-manager assess</span>. The graph is grey, and the other pages keep the gates of <span className="mono">health-manager validate</span>.</p> : null}
      <div className="toolbar health-filters">
        <select value={filters.type} onChange={set("type")} aria-label="condition type">
          <option value="">every condition</option>
          {CONDITION_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
        </select>
        <select value={filters.class} onChange={set("class")} aria-label="class">
          <option value="">every class</option>
          {classes.map((t) => <option key={t} value={t}>{t}</option>)}
        </select>
        <select value={filters.environment} onChange={set("environment")} aria-label="environment">
          <option value="">every environment</option>
          {environments.map((t) => <option key={t} value={t}>{t}</option>)}
        </select>
        <label className="health-time">
          <span>{hoursBack === 0 ? "now" : `as of ${when(new Date(Date.now() - hoursBack * 3_600_000).toISOString())}`}</span>
          <input type="range" min={-WEEK_HOURS} max={0} step={1} value={-hoursBack} onChange={(e) => setHoursBack(-Number(e.target.value))} aria-label="replay the graph as of a moment" />
        </label>
        {hoursBack !== 0 ? <button className="btn btn-small" onClick={() => setHoursBack(0)}>Now</button> : null}
      </div>
      {doc ? (
        <div className="health-view">
          <div className={`health-side${sheet ? " health-side-open" : ""}`}>
            <h3>Root causes</h3>
            {doc.roots.length === 0 ? (
              <p className="muted">{doc.hasConditions ? <><Tag level="ok" /> Nothing is wrong{siteNode?.reason ? `: ${siteNode.reason}` : ""}.</> : "Nothing assessed yet."}</p>
            ) : null}
            <RootList doc={doc} focus={focus} choose={choose} />
          </div>
          <ReactFlowProvider>
            <Flow doc={doc} open={open} toggle={toggle} pick={pick} picked={picked} focus={focus} filters={filters} nonce={nonce} />
          </ReactFlowProvider>
          {picked ? <HealthPanel id={picked} close={() => setPicked(null)} pick={pick} /> : null}
        </div>
      ) : null}
      <div className="legend">
        <span className="hl hc-critical">critical</span><span className="hl hc-warning">warning</span><span className="hl hc-unknown">unknown</span><span className="hl hc-ok">ok</span>
        <span className="hl hc-critical hc-ack">acknowledged</span><span className="hl hc-warning hc-maint">maintenance</span>
        <span className="muted">↯ flapping · a ring: a root cause · a halo: its symptoms · a number: a group, click to open</span>
      </div>
    </div>
  );
}
