// Health — one page with one selected object (ADR-041 D5): the tree to find it,
// its ego graph, its CI panel. The graph is laid out once per shape and the
// colours patched on the live stream, so a filter, the time slider or a change
// in the CMDB never moves a card, and nothing but the operator moves the
// selection.

import { Background, Controls, ReactFlow, ReactFlowProvider, useReactFlow } from "@xyflow/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { get, useHealthStream } from "../api";
import { GEdge, GNode, edgeTypes, layout, nodeTypes } from "../graph";
import { Anchor, Card, EgoState, Filters, NO_FILTERS, boundsOf, egoCards, expand, fold, kept, patchEgo, patchPaths, rollup, shapeOf, statusClass, viewFor, wrapRanks } from "../healthgraph";
import { ClassIcon, ModuleIcon } from "../moduleicon";
import { HealthEgo, HealthPath, HealthPatch, HealthView } from "../types";
import { ReadState, replacePath, when } from "../ui";
import { HealthPanel } from "./HealthPanel";
import { TreePane, useTree } from "./HealthTree";

const CONDITION_TYPES = ["operational", "drift", "capacity", "security", "maintenance", "backup", "impact"];
const STRONG = "#d64545";
const THIN = "#94a3b8";
const WEEK_HOURS = 168;
const NODESEP = 22;
const RANKSEP = 52;
const MAX_ZOOM = 1.25;

// Within a tenth of the size laid out for: no new layout for a pixel.
const near = (v: { width: number; height: number }, w: number, h: number): boolean => Math.abs(w - v.width) < v.width / 10 && Math.abs(h - v.height) < v.height / 10;

type Chain = HealthPath["to"];

const phone = (): boolean => window.matchMedia("(max-width: 700px)").matches;
const atQuery = (at: string | null, joiner: string): string => (at ? `${joiner}at=${encodeURIComponent(at)}` : "");

function Marks({ v }: { v: HealthView }) {
  return (
    <>
      {v.flapping ? <span className="hc-mark" title="flapping: held at its worse value">↯</span> : null}
      {v.acknowledged ? <span className="hc-mark" title="acknowledged">✓</span> : null}
      {v.maintenance ? <span className="hc-mark" title="in a maintenance window">⏸</span> : null}
    </>
  );
}

function ObjectCard({ c, v, grow }: { c: Card; v: HealthView; grow: () => void }) {
  const n = c.node!;
  const mark = c.plus ? "+" : c.minus ? "−" : null;
  return (
    <>
      <div className="cf-title">
        {n.module ? <ModuleIcon name={n.module} size={20} /> : <ClassIcon cls={n.class} size={20} />}
        <span className="hc-name">{n.label}</span>
        <Marks v={v} />
      </div>
      <div className="cf-sub" title={v.reason ?? undefined}>{v.reason ?? n.class}</div>
      {mark ? <button className="hc-more nodrag" onClick={(e) => { e.stopPropagation(); grow(); }} aria-label={`${c.plus ? "Expand" : "Fold"} ${n.label}`} title={c.plus ? "One more hop from here" : "Fold this"}>{mark}</button> : null}
    </>
  );
}

function GroupCard({ c, open }: { c: Card; open: boolean }) {
  const bad = c.members.filter((m) => m.status === "critical" || m.status === "warning").length;
  return (
    <div className="hc-pill">
      <span className="hc-name">{c.group!.label}</span>
      <span className="hc-count">{c.members.length}</span>
      {bad ? <span className="muted small">{bad} bad</span> : null}
      {c.folded || open ? <span className="muted small">{open ? "fold" : "open"}</span> : null}
    </div>
  );
}

interface FlowProps {
  state: EgoState;
  filters: Filters;
  pick: (id: string) => void;
  grow: (c: Card) => void;
  toggleGroup: (key: string) => void;
  nonce: number; // a new value fits again
}

function Flow({ state, filters, pick, grow, toggleGroup, nonce }: FlowProps) {
  const rf = useReactFlow();
  const { cards, lines } = useMemo(() => egoCards(state), [state]);
  const shape = shapeOf(cards, lines);
  const act = useRef({ pick, grow, toggleGroup, cards });
  act.current = { pick, grow, toggleGroup, cards };
  // The canvas's size: a wide rank wraps to use its height, not a strip across it.
  const canvas = useRef<HTMLDivElement>(null);
  const [view, setView] = useState({ width: 1000, height: 600 });
  useEffect(() => {
    const el = canvas.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(([e]) => {
      const { width, height } = e.contentRect;
      if (width > 0 && height > 0) setView((v) => (near(v, width, height) ? v : { width, height }));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  // Once per shape and canvas: what moves a card. The colours below are patched over it.
  const base = useMemo(() => {
    const nodes: GNode[] = cards.map((c) => ({
      id: c.id,
      w: c.w,
      h: c.h,
      content: null,
      onClick: c.node ? () => act.current.pick(c.id) : () => act.current.toggleGroup(c.group!.key),
    }));
    const edges: GEdge[] = lines.map((l) => ({ id: l.id, source: l.source, target: l.target, label: l.label ?? undefined, dashed: l.dashed, color: l.strong ? STRONG : THIN }));
    const laid = layout(nodes, edges, "TB", NODESEP, RANKSEP);
    const moved = wrapRanks(laid.nodes.map((n) => ({ id: n.id, x: n.position.x, y: n.position.y, w: n.data.g.w, h: n.data.g.h })), view, NODESEP, RANKSEP, MAX_ZOOM);
    return moved.size ? { ...laid, nodes: laid.nodes.map((n) => ({ ...n, position: moved.get(n.id) ?? n.position })) } : laid;
    // eslint-disable-next-line
  }, [shape, view]);
  const nodes = useMemo(() => {
    const by = new Map(cards.map((c) => [c.id, c]));
    return base.nodes.map((n) => {
      const c = by.get(n.id);
      if (!c) return n;
      const mine = c.node ? [c.node] : c.members;
      const views = mine.filter((m) => kept(m, filters)).map((m) => viewFor(m, filters));
      const v = c.node ? viewFor(c.node, filters) : rollup(views);
      const ring = c.node?.isRoot ? " hc-root" : "";
      const opened = !!c.group && state.openGroups.has(c.group.key);
      const cls = `${c.group ? "hgroup " : ""}${statusClass(v)}${views.length ? "" : " hc-dim"}${ring}${c.id === state.center ? " gcard-on" : ""}`;
      const content = c.node ? <ObjectCard c={c} v={v} grow={() => act.current.grow(c)} /> : <GroupCard c={c} open={opened} />;
      return { ...n, width: c.w, height: c.h, data: { ...n.data, g: { ...n.data.g, className: cls, content } } };
    });
  }, [base, cards, filters, state.center, state.openGroups]);
  const edges = useMemo(() => {
    const by = new Map(lines.map((l) => [l.id, l]));
    return base.edges.map((e) => {
      const strong = !!by.get(e.id)?.strong;
      return { ...e, style: { ...e.style, stroke: strong ? STRONG : THIN, strokeWidth: strong ? 2.6 : 1.2 } };
    });
  }, [base, lines]);
  const target = useRef(base);
  target.current = base;
  // By the layout's own numbers, not fitView: that waits on a measure of nodes
  // the colour patch has just replaced.
  useEffect(() => {
    const t = setTimeout(() => {
      const box = boundsOf(target.current.nodes, phone() ? 300 : 560);
      if (box) void rf.fitBounds(box, { padding: 0.12, duration: 300 });
    }, 80);
    return () => clearTimeout(t);
  }, [nonce, shape, view, rf]);
  return (
    <div className="graph health-canvas" ref={canvas}>
      <ReactFlow nodes={nodes} edges={edges} nodeTypes={nodeTypes} edgeTypes={edgeTypes} minZoom={0.1} maxZoom={MAX_ZOOM} nodesDraggable={false} nodesConnectable={false} elementsSelectable={false} proOptions={{ hideAttribution: true }} onNodeClick={() => undefined}>
        <Background gap={24} color="#e5e7eb" />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  );
}

export function Health() {
  const tree = useTree();
  const doc = tree.doc;

  const [hoursBack, setHoursBack] = useState(0);
  const [at, setAt] = useState<string | null>(null);
  useEffect(() => {
    const t = setTimeout(() => setAt(hoursBack === 0 ? null : new Date(Date.now() - hoursBack * 3_600_000).toISOString()), 300);
    return () => clearTimeout(t);
  }, [hoursBack]);

  const [center, setCenter] = useState<string | null>(() => new URLSearchParams(window.location.search).get("select"));
  const [anchors, setAnchors] = useState<Anchor[]>(center ? [{ id: center, parent: null }] : []);
  const [reads, setReads] = useState<Map<string, HealthEgo>>(new Map());
  const [chains, setChains] = useState<Set<Chain>>(new Set());
  const [paths, setPaths] = useState<Map<Chain, HealthPath>>(new Map());
  const [openGroups, setOpenGroups] = useState<Set<string>>(new Set());
  const [epoch, setEpoch] = useState(0); // a new value reads everything again
  const [filters, setFilters] = useState<Filters>(NO_FILTERS);
  const [sheet, setSheet] = useState(false);
  const [panel, setPanel] = useState(() => !phone());
  const [nonce, setNonce] = useState(0);
  const [failure, setFailure] = useState<string | null>(null);
  // Landing on a root opens on its symptoms (D5): the page's entry and a pick
  // from the root list, not a walk through the tree.
  const landing = useRef(true);

  const go = useCallback((id: string, land = false) => {
    landing.current = land;
    setCenter(id);
    setAnchors([{ id, parent: null }]);
    setReads(new Map());
    setChains(new Set());
    setPaths(new Map());
    setOpenGroups(new Set());
    setSheet(false);
    if (!phone()) setPanel(true);
    replacePath(`/health?select=${encodeURIComponent(id)}`);
  }, []);

  // No object asked for: the worst root, or the site when nothing is wrong.
  useEffect(() => {
    if (center || !doc) return;
    const first = doc.roots[0]?.id ?? doc.site;
    if (first) go(first, true);
  }, [center, doc, go]);

  const read = useRef("");
  useEffect(() => {
    const round = `${at}|${epoch}`;
    const again = read.current !== round;
    read.current = round;
    const fail = (e: Error): void => setFailure(e.message);
    for (const a of anchors) {
      if (!again && reads.has(a.id)) continue;
      void get<HealthEgo>(`health/ego/${encodeURIComponent(a.id)}${atQuery(at, "?")}`).then((e) => {
        if (e.data) setReads((m) => new Map(m).set(a.id, e.data as HealthEgo));
        setFailure(e.error ?? null);
      }, fail);
    }
    if (!center) return;
    for (const to of chains) {
      if (!again && paths.has(to)) continue;
      void get<HealthPath>(`health/ego/${encodeURIComponent(center)}/path?to=${to}${atQuery(at, "&")}`).then((e) => {
        if (e.data?.id === center) setPaths((m) => new Map(m).set(to, e.data as HealthPath));
      }, fail);
    }
    // eslint-disable-next-line
  }, [anchors, chains, at, epoch, center]);

  const ego = center ? reads.get(center) : undefined;
  useEffect(() => {
    if (!landing.current || !ego) return;
    landing.current = false;
    if (ego.center.isRoot) setChains(new Set<Chain>(["impact"]));
  }, [ego]);

  const onPatch = useCallback((p: HealthPatch) => {
    if (p.relayout) {
      tree.reload();
      setEpoch((n) => n + 1);
      return;
    }
    tree.patch(p.rollups, p.roots, p.counts, p.hasConditions);
    if (at) return; // the past does not change
    setReads((m) => patchEgo(m, p));
    setPaths((m) => new Map(patchPaths([...m.values()], p).map((x) => [x.to, x])));
  }, [tree.reload, tree.patch, at]);
  const onOpen = useCallback(() => {
    tree.reload();
    setEpoch((n) => n + 1);
  }, [tree.reload]);
  useHealthStream(onPatch, onOpen);

  const state: EgoState | null = useMemo(() => (center ? { center, anchors, reads, paths: [...paths.values()], openGroups } : null), [center, anchors, reads, paths, openGroups]);
  const grow = useCallback((c: Card) => {
    setAnchors((a) => (c.plus ? expand(a, c.id, c.via ?? c.id) : fold(a, c.id)));
  }, []);
  const toggleGroup = useCallback((key: string) => setOpenGroups((o) => {
    const n = new Set(o);
    if (!n.delete(key)) n.add(key);
    return n;
  }), []);
  const toggleChain = (to: Chain): void => {
    const n = new Set(chains);
    if (!n.delete(to)) n.add(to);
    setChains(n);
    setPaths((m) => new Map([...m].filter(([k]) => n.has(k))));
  };
  const show = (id: string): void => {
    setSheet(true);
    if (phone()) setPanel(false);
    void tree.reveal(id);
  };

  const classes = useMemo(() => [...new Set((doc?.facets ?? []).flatMap((f) => f.classes))].sort(), [doc]);
  const environments = useMemo(() => [...new Set((doc?.facets ?? []).flatMap((f) => f.environments))].sort(), [doc]);
  const set = (k: keyof Filters) => (e: { target: { value: string } }) => setFilters({ ...filters, [k]: e.target.value });
  const c = doc?.counts;
  const explained = !!ego && ego.center.rootCause.length > 0;
  const hurts = !!ego && (ego.center.isRoot || explained);

  return (
    <div className="page page-wide">
      <div className="page-head">
        <h1>Health</h1>
        <span className="muted">
          {c ? `${c.critical} critical · ${c.warning} warning · ${c.acknowledged} silenced · ${c.unknown} unknown · ${c.ok} ok` : "…"} · {doc?.generated ? `read ${when(doc.generated)}` : ""}
        </span>
        <span className="spacer" />
        <button className="btn health-sheet-btn" onClick={() => setSheet(!sheet)}>Tree</button>
        <button className="btn" disabled={!center} onClick={() => setPanel(!panel)}>Details</button>
        <button className="btn" onClick={() => setNonce((n) => n + 1)}>Fit</button>
      </div>
      <ReadState env={tree.read.env} failure={tree.read.failure ?? failure} what="the CMDB's health" />
      {doc && !doc.hasConditions ? <p className="readstate readstate-warn">No object carries a condition yet: this site has not run <span className="mono">health-manager assess</span>. The dots are grey, and the other pages keep the gates of <span className="mono">health-manager validate</span>.</p> : null}
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
          <span>{hoursBack === 0 ? "now" : `as of ${when(new Date(Date.now() - hoursBack * 3_600_000).toISOString())}, in the graph`}</span>
          <input type="range" min={-WEEK_HOURS} max={0} step={1} value={-hoursBack} onChange={(e) => setHoursBack(-Number(e.target.value))} aria-label="replay the graph as of a moment" />
        </label>
        {hoursBack !== 0 ? <button className="btn btn-small" onClick={() => setHoursBack(0)}>Now</button> : null}
      </div>
      <div className="health-view">
        <TreePane m={tree} selected={center} select={(id) => go(id)} chooseRoot={(id) => go(id, true)} filters={filters} open={sheet} />
        <div className="health-centre">
          <div className="toolbar health-chain">
            <button className={`btn btn-small${chains.has("root") ? " btn-primary" : ""}`} disabled={!explained} title={explained ? undefined : ego?.center.isRoot ? "This is a root cause" : "Nothing else explains this object"} onClick={() => toggleChain("root")}>To the root cause</button>
            <button className={`btn btn-small${chains.has("impact") ? " btn-primary" : ""}`} disabled={!hurts} title={hurts ? undefined : "Nothing fails because of this object"} onClick={() => toggleChain("impact")}>What this impacts</button>
          </div>
          {state ? (
            <ReactFlowProvider>
              <Flow state={state} filters={filters} pick={go} grow={grow} toggleGroup={toggleGroup} nonce={nonce} />
            </ReactFlowProvider>
          ) : <p className="muted">Pick an object in the tree.</p>}
        </div>
        {center && panel ? <HealthPanel id={center} close={() => setPanel(false)} pick={go} showInTree={() => show(center)} /> : null}
      </div>
      <div className="legend">
        <span className="hl hc-critical">critical</span><span className="hl hc-warning">warning</span><span className="hl hc-unknown">unknown</span><span className="hl hc-ok">ok</span>
        <span className="hl hc-critical hc-ack">acknowledged</span><span className="hl hc-warning hc-maint">maintenance</span>
        <span className="muted">↯ flapping · a ring: a root cause · + one more hop · − fold · a pill: a relation type · a number in the tree: objects that need a look</span>
      </div>
    </div>
  );
}
