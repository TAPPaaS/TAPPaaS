// deviceview.tsx — the Device view's graph: one plain card per physical
// device (devicegraph.ts), one line per pair of devices a cable joins, laid
// out by force around the selected device (devicegraph.ts forceLayout): the
// selection moves to the middle, its neighbours on a ring around it, the rest
// further out, animated from where they were. Cards can be dragged; Fit shows
// all. A server's card carries its bay row: a cell per disk in it, by bay,
// coloured by the disk's health (the Assets view's tree). A click on a card
// selects the device, on a line its link; the side panel has the rest.

import { BaseEdge, Background, Controls, ControlButton, Edge, EdgeProps, Handle, Node, NodeChange, NodeProps, Position, ReactFlow, ReactFlowProvider, applyNodeChanges, useInternalNode, useReactFlow, useStore } from "@xyflow/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AssetTree, AssetTreeDisk, Topology } from "../types";
import { disksOf } from "../diskview";
import { DevLabel, linkStyle, linkText } from "./devicecard";
import { BayRow } from "./disks";
import { CARD_H as H, DevNode, DevState, Pt, cardBox, cardWidth, centreZoom, deviceGraph, deviceState, forceLayout, selectedDevice } from "./devicegraph";
import { Sel } from "./layout";
import { stateClass } from "./states";

type DevData = { d: DevNode; s: DevState; on: boolean; w: number; disks: AssetTreeDisk[]; pick: (s: Sel) => void };

const hidden = { opacity: 0, width: 1, height: 1, minWidth: 0, minHeight: 0, border: 0, top: "50%", left: "50%" };

function DevCard({ data }: NodeProps<Node<DevData, "dev">>) {
  return (
    <div className={`card-flow gcard dev-node ${stateClass(data.s.state)}${data.on ? " gcard-on" : ""}`} style={{ width: data.w, height: H }} onClick={(e) => (e.stopPropagation(), data.pick(data.d.sel))}>
      <Handle type="target" position={Position.Top} style={hidden} />
      <DevLabel d={data.d} s={data.s} bays={data.disks.length ? <BayRow disks={data.disks} compact /> : null} />
      <Handle type="source" position={Position.Bottom} style={hidden} />
    </div>
  );
}

// A line from the middle of one card to the middle of the other, cut at the
// cards' edges, wherever the cards are.
function cut(c: Pt, w: number, h: number, to: Pt): Pt {
  const dx = to.x - c.x;
  const dy = to.y - c.y;
  if (!dx && !dy) return c;
  const k = Math.min(Math.abs(dx) > 0 ? w / 2 / Math.abs(dx) : Infinity, Math.abs(dy) > 0 ? h / 2 / Math.abs(dy) : Infinity);
  return { x: c.x + dx * k, y: c.y + dy * k };
}

function FloatEdge({ id, source, target, style, label, labelStyle, labelBgStyle }: EdgeProps) {
  const a = useInternalNode(source);
  const b = useInternalNode(target);
  if (!a || !b) return null;
  const ca = { x: a.internals.positionAbsolute.x + (a.measured.width ?? 0) / 2, y: a.internals.positionAbsolute.y + (a.measured.height ?? 0) / 2 };
  const cb = { x: b.internals.positionAbsolute.x + (b.measured.width ?? 0) / 2, y: b.internals.positionAbsolute.y + (b.measured.height ?? 0) / 2 };
  const p = cut(ca, a.measured.width ?? 0, a.measured.height ?? 0, cb);
  const q = cut(cb, b.measured.width ?? 0, b.measured.height ?? 0, ca);
  return <BaseEdge id={id} path={`M ${p.x},${p.y} L ${q.x},${q.y}`} style={style} label={label} labelX={(p.x + q.x) / 2} labelY={(p.y + q.y) / 2} labelStyle={labelStyle} labelBgStyle={labelBgStyle} interactionWidth={14} />;
}

const nodeTypes = { dev: DevCard };
const edgeTypes = { float: FloatEdge };

function Inner({ t, sel, pick, onPane, labels, tree }: { t: Topology; sel: Sel | null; pick: (s: Sel) => void; onPane: () => void; labels: boolean; tree?: AssetTree | null }) {
  const g = useMemo(() => deviceGraph(t), [t]);
  const bays = useMemo(() => new Map(g.nodes.map((d) => [d.id, disksOf(tree, d.name)])), [g, tree]);
  const wOf = useCallback((d: DevNode) => cardWidth(d, bays.get(d.id)?.length ?? 0), [bays]);
  const states = useMemo(() => new Map(g.nodes.map((d) => [d.id, deviceState(t, d)])), [g, t]);
  const rf = useReactFlow();
  // The device the layout centres on: the selected one; a link or nothing
  // selected keeps the last centre.
  const last = useRef<string | null>(null);
  const picked = selectedDevice(g, sel);
  if (picked) last.current = picked;
  const center = picked ?? last.current;
  // Where each card's middle is now.
  const pos = useRef(new Map<string, Pt>());
  const [nodes, setNodes] = useState<Node<DevData, "dev">[]>([]);
  const data = useCallback((d: DevNode): DevData => ({ d, s: states.get(d.id)!, on: d.id === picked, w: wOf(d), disks: bays.get(d.id) ?? [], pick }), [states, picked, pick, wOf, bays]);
  const place = useCallback((at: Map<string, Pt>) => g.nodes.map((d): Node<DevData, "dev"> => {
    return { id: d.id, type: "dev", data: data(d), ...cardBox(at.get(d.id) ?? { x: 0, y: 0 }, wOf(d)) };
  }), [g, data, wOf]);
  // The latest: a frame of the move below may come after the disks did.
  const placeNow = useRef(place);
  placeNow.current = place;

  // The selection in the middle, zoomed so the farthest card still shows;
  // without one, everything fitted.
  const paneW = useStore((s) => s.width);
  const paneH = useStore((s) => s.height);
  const centre = (at: Map<string, Pt>, duration: number) => {
    if (!center) return void rf.fitView({ padding: 0.18, duration });
    const zoom = centreZoom(g.nodes.map((d) => ({ at: at.get(d.id) ?? { x: 0, y: 0 }, w: wOf(d) })), paneW, paneH);
    void rf.setCenter(0, 0, { zoom, duration });
  };
  // A new centre (or a new topology): lay out from where the cards are, and
  // move them there.
  useEffect(() => {
    const to = forceLayout(g.nodes.map((d) => d.id), g.links, center, pos.current.size ? pos.current : undefined);
    const from = new Map(pos.current);
    const t0 = performance.now();
    const ms = from.size ? 550 : 0;
    let frame = 0;
    const ease = (x: number) => 1 - Math.pow(1 - x, 3);
    const step = (now: number) => {
      const k = ms ? ease(Math.min(1, (now - t0) / ms)) : 1;
      const at = new Map([...to].map(([id, p]) => {
        const f = from.get(id) ?? p;
        return [id, { x: f.x + (p.x - f.x) * k, y: f.y + (p.y - f.y) * k }];
      }));
      pos.current = at;
      setNodes(placeNow.current(at));
      if (k < 1) frame = requestAnimationFrame(step);
      else if (ms) requestAnimationFrame(() => centre(at, 350));
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [g, center]);
  // The selection's highlight and the states: the cards stay where they are.
  // A card's width comes with its disks (the assets read, which may come after
  // the layout): it stays centred on its point.
  useEffect(() => setNodes((ns) => ns.map((n) => {
    const p = pos.current.get(n.id);
    return { ...n, data: data(n.data.d), ...(p ? cardBox(p, wOf(n.data.d)) : {}) };
  })), [data, wOf]);
  // The picture is fitted to what it holds whichever came last: the cards, their
  // widths, the pane's size. It stands at once (only a new selection moves); a
  // poll's new read with the same widths changes nothing.
  const widths = g.nodes.map(wOf).join();
  const drawn = nodes.length > 0;
  useEffect(() => {
    if (drawn && rf.viewportInitialized && paneW > 0 && paneH > 0) centre(pos.current, 0);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [drawn, rf.viewportInitialized, widths, paneW, paneH]);

  const onNodesChange = useCallback((ch: NodeChange<Node<DevData, "dev">>[]) => {
    setNodes((ns) => {
      const next = applyNodeChanges(ch, ns);
      for (const c of ch) {
        if (c.type !== "position" || !c.position) continue;
        const n = next.find((x) => x.id === c.id);
        if (n) pos.current.set(n.id, { x: c.position.x + n.data.w / 2, y: c.position.y + H / 2 });
      }
      return next;
    });
  }, []);

  const edges: Edge[] = useMemo(() => g.links.map((l) => {
    const st = linkStyle(l, t);
    const on = sel?.kind === "link" && sel.id === l.id;
    return {
      id: l.id,
      source: l.a,
      target: l.b,
      type: "float",
      label: labels ? linkText(l) : undefined,
      style: { stroke: on ? "var(--amber-500)" : st.stroke, strokeWidth: on ? st.width + 2 : st.width, strokeDasharray: st.dash },
      labelStyle: { fontSize: 11, fill: "var(--slate-600)" },
      labelBgStyle: { fill: "var(--slate-50)" },
    };
  }), [g, t, sel, labels]);

  return (
    <div className="dev-flow">
    <ReactFlow
      nodes={nodes}
      edges={edges}
      nodeTypes={nodeTypes}
      edgeTypes={edgeTypes}
      onNodesChange={onNodesChange}
      onEdgeClick={(_: unknown, e: Edge) => pick({ kind: "link", id: e.id })}
      onPaneClick={onPane}
      minZoom={0.2}
      maxZoom={2}
      nodesDraggable
      nodesConnectable={false}
      elementsSelectable={false}
      proOptions={{ hideAttribution: true }}
    >
      <Background gap={24} color="var(--gray-200)" />
      <Controls showInteractive={false} showFitView={false}>
        <ControlButton onClick={() => void rf.fitView({ padding: 0.18, duration: 350 })} title="fit: see every device" aria-label="fit">
          <span className="fit-label">Fit</span>
        </ControlButton>
      </Controls>
    </ReactFlow>
    </div>
  );
}

export function DeviceGraph(props: { t: Topology; sel: Sel | null; pick: (s: Sel) => void; onPane: () => void; labels: boolean; tree?: AssetTree | null }) {
  return (
    <ReactFlowProvider>
      <Inner {...props} />
    </ReactFlowProvider>
  );
}
