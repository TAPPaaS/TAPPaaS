// deviceview.tsx — the Device view's graph: one plain card per physical
// device (devicegraph.ts), one line per pair of devices a cable joins, laid
// out by force around the selected device (devicegraph.ts forceLayout): the
// selection moves to the middle, its neighbours on a ring around it, the rest
// further out, animated from where they were. Cards can be dragged; Fit shows
// all. A click on a card selects the device, on a line its link; the side
// panel has the rest.

import { BaseEdge, Background, Controls, ControlButton, Edge, EdgeProps, Handle, Node, NodeChange, NodeProps, Position, ReactFlow, ReactFlowProvider, applyNodeChanges, useInternalNode, useReactFlow } from "@xyflow/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Topology } from "../types";
import { DevLabel, linkStyle, linkText } from "./devicecard";
import { DevNode, DevState, Pt, deviceGraph, deviceState, forceLayout, selectedDevice } from "./devicegraph";
import { Sel } from "./layout";
import { stateClass } from "./states";

type DevData = { d: DevNode; s: DevState; on: boolean; w: number; pick: (s: Sel) => void };

const H = 36;
const widthOf = (d: DevNode) => 58 + d.name.length * 8;
const hidden = { opacity: 0, width: 1, height: 1, minWidth: 0, minHeight: 0, border: 0, top: "50%", left: "50%" };

function DevCard({ data }: NodeProps<Node<DevData, "dev">>) {
  return (
    <div className={`card-flow gcard dev-node ${stateClass(data.s.state)}${data.on ? " gcard-on" : ""}`} style={{ width: data.w, height: H }} onClick={(e) => (e.stopPropagation(), data.pick(data.d.sel))}>
      <Handle type="target" position={Position.Top} style={hidden} />
      <DevLabel d={data.d} s={data.s} />
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

function Inner({ t, sel, pick, onPane, labels }: { t: Topology; sel: Sel | null; pick: (s: Sel) => void; onPane: () => void; labels: boolean }) {
  const g = useMemo(() => deviceGraph(t), [t]);
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
  const data = useCallback((d: DevNode): DevData => ({ d, s: states.get(d.id)!, on: d.id === picked, w: widthOf(d), pick }), [states, picked, pick]);
  const place = useCallback((at: Map<string, Pt>) => g.nodes.map((d): Node<DevData, "dev"> => {
    const p = at.get(d.id) ?? { x: 0, y: 0 };
    return { id: d.id, type: "dev", position: { x: p.x - widthOf(d) / 2, y: p.y - H / 2 }, data: data(d), width: widthOf(d), height: H };
  }), [g, data]);

  // The selection in the middle, zoomed so the farthest card still shows;
  // without one, everything fitted.
  const wrap = useRef<HTMLDivElement>(null);
  const centre = (at: Map<string, Pt>) => {
    const el = wrap.current;
    if (!center || !el) return void rf.fitView({ padding: 0.18, duration: 350 });
    const far = Math.max(...g.nodes.map((d) => Math.max(Math.abs(at.get(d.id)?.x ?? 0) + widthOf(d) / 2, Math.abs(at.get(d.id)?.y ?? 0) + H / 2)));
    const zoom = Math.max(0.25, Math.min(1.3, (Math.min(el.clientWidth, el.clientHeight) / 2 - 20) / far));
    void rf.setCenter(0, 0, { zoom, duration: 350 });
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
      setNodes(place(at));
      if (k < 1) frame = requestAnimationFrame(step);
      // (the first picture is centred once React Flow has its size: onInit)
      else if (rf.viewportInitialized) requestAnimationFrame(() => centre(at));
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [g, center]);
  // The selection's highlight and the states: the cards stay where they are.
  useEffect(() => setNodes((ns) => ns.map((n) => ({ ...n, data: data(n.data.d) }))), [data]);

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
      style: { stroke: on ? "#f59e0b" : st.stroke, strokeWidth: on ? st.width + 2 : st.width, strokeDasharray: st.dash },
      labelStyle: { fontSize: 11, fill: "#475569" },
      labelBgStyle: { fill: "#f8fafc" },
    };
  }), [g, t, sel, labels]);

  return (
    <div ref={wrap} className="dev-flow">
    <ReactFlow
      nodes={nodes}
      edges={edges}
      nodeTypes={nodeTypes}
      edgeTypes={edgeTypes}
      onNodesChange={onNodesChange}
      onEdgeClick={(_: unknown, e: Edge) => pick({ kind: "link", id: e.id })}
      onPaneClick={onPane}
      onInit={() => requestAnimationFrame(() => centre(pos.current))}
      minZoom={0.2}
      maxZoom={2}
      nodesDraggable
      nodesConnectable={false}
      elementsSelectable={false}
      proOptions={{ hideAttribution: true }}
    >
      <Background gap={24} color="#e5e7eb" />
      <Controls showInteractive={false} showFitView={false}>
        <ControlButton onClick={() => void rf.fitView({ padding: 0.18, duration: 350 })} title="fit: see every device" aria-label="fit">
          <span className="fit-label">Fit</span>
        </ControlButton>
      </Controls>
    </ReactFlow>
    </div>
  );
}

export function DeviceGraph(props: { t: Topology; sel: Sel | null; pick: (s: Sel) => void; onPane: () => void; labels: boolean }) {
  return (
    <ReactFlowProvider>
      <Inner {...props} />
    </ReactFlowProvider>
  );
}
