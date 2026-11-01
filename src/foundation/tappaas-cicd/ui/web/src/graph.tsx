// graph.tsx — cards joined by lines, laid out by dagre (or in columns, or as a
// tree's grid) and drawn by React Flow: a module's config tree, the zones and
// their reach, the identity objects and their relations. Nothing is placed by
// hand; each card gives its own size.

import dagre from "@dagrejs/dagre";
import { BaseEdge, Background, Controls, Edge, EdgeProps, Handle, MarkerType, Node, NodeProps, Position, ReactFlow, getBezierPath, useReactFlow, useStore } from "@xyflow/react";
import { ReactNode, useEffect, useMemo } from "react";
import { Route, columnPositions, routeEdges } from "./columns";

export interface GNode {
  id: string;
  w: number;
  h: number;
  content: ReactNode;
  onClick?: () => void;
  className?: string;
  accent?: string; // the card's left border colour
  col?: number; // when every node has one: laid out in columns, left to right, instead of by dagre
  order?: number; // the starting row within its column (ascending), then the id (columns.ts reorders)
  head?: boolean; // the column's title: pinned to the top
  after?: string; // kept directly below this node of its column
  parent?: string; // a sub-flow: drawn inside that node, at `at`, which is sized to hold it
  at?: { x: number; y: number };
}

export interface GEdge {
  id?: string; // a name that outlives a layout, for a page that restyles the line
  source: string;
  target: string;
  label?: string;
  color?: string;
  dashed?: boolean;
  arrow?: boolean;
}

type BoxData = { g: GNode; vertical: boolean };

const hidden = { opacity: 0, width: 6, height: 6, minWidth: 0, minHeight: 0, border: 0 };

function Box({ data }: NodeProps<Node<BoxData, "box">>) {
  const g = data.g;
  return (
    <div
      className={`card-flow gcard${g.className ? ` ${g.className}` : ""}${g.onClick ? "" : " gcard-static"}`}
      style={{ width: g.w, height: g.h, borderLeft: g.accent ? `4px solid ${g.accent}` : undefined }}
      onClick={g.onClick}
    >
      <Handle type="target" position={data.vertical ? Position.Top : Position.Left} style={hidden} />
      <Handle type="target" id="l" position={Position.Left} style={{ ...hidden, top: 22 }} />
      {g.content}
      <Handle type="source" position={data.vertical ? Position.Bottom : Position.Right} style={hidden} />
    </div>
  );
}

export const nodeTypes = { box: Box };

// A tree's line: down from the parent to a bus just below it, along the bus to
// the gap left of the child, down the gap, and into the child's side.
function BusEdge({ sourceX, sourceY, targetX, targetY, style, markerEnd }: EdgeProps) {
  const bus = sourceY + 22;
  const lane = targetX - 16;
  return <BaseEdge path={`M ${sourceX},${sourceY} V ${bus} H ${lane} V ${targetY} H ${targetX}`} style={style} markerEnd={markerEnd} />;
}

// A line between columns: a bezier from the side of one card to the side of
// the other, at the points columns.ts chose for it.
function RouteEdge({ data, style, markerEnd, label, labelStyle, labelBgStyle }: EdgeProps<Edge<{ route: Route }, "route">>) {
  const r = data!.route;
  const [path, labelX, labelY] = getBezierPath({
    sourceX: r.sx,
    sourceY: r.sy,
    sourcePosition: r.ss === "right" ? Position.Right : Position.Left,
    targetX: r.tx,
    targetY: r.ty,
    targetPosition: r.ts === "left" ? Position.Left : Position.Right,
  });
  return <BaseEdge path={path} style={style} markerEnd={markerEnd} label={label} labelX={labelX} labelY={labelY} labelStyle={labelStyle} labelBgStyle={labelBgStyle} />;
}

export const edgeTypes = { bus: BusEdge, route: RouteEdge };

// A tree as a grid: the root centred on top, its children in rows below.
export interface TreeGrid {
  root: string;
  cols: number;
}

function gridPositions(nodes: GNode[], grid: TreeGrid, gapX: number, gapY: number): Map<string, { x: number; y: number }> {
  const root = nodes.find((n) => n.id === grid.root);
  const kids = nodes.filter((n) => n.id !== grid.root);
  const cols = Math.max(1, Math.min(grid.cols, kids.length));
  const colW = Math.max(0, ...kids.map((k) => k.w));
  const width = cols * colW + (cols - 1) * gapX;
  const pos = new Map<string, { x: number; y: number }>();
  const top = root ? root.h + gapY + 20 : 0;
  if (root) pos.set(root.id, { x: gapX + Math.max(0, (width - root.w) / 2), y: 0 });
  let y = top;
  for (let i = 0; i < kids.length; i += cols) {
    const row = kids.slice(i, i + cols);
    row.forEach((k, j) => pos.set(k.id, { x: gapX + j * (colW + gapX), y }));
    y += Math.max(...row.map((k) => k.h)) + gapY;
  }
  return pos;
}

export function layout(nodes: GNode[], edges: GEdge[], rankdir: "TB" | "LR", nodesep: number, ranksep: number, grid?: TreeGrid): { nodes: Node<BoxData, "box">[]; edges: Edge[] } {
  const g = new dagre.graphlib.Graph({ multigraph: true });
  g.setGraph({ rankdir, nodesep, ranksep, marginx: 10, marginy: 10 });
  g.setDefaultEdgeLabel(() => ({}));
  // A sub-flow's card is placed by its parent's: dagre sees only the parent.
  const top = nodes.filter((n) => !n.parent);
  const parentOf = new Map(nodes.filter((n) => n.parent).map((n) => [n.id, n.parent as string]));
  const rep = (id: string): string => parentOf.get(id) ?? id;
  for (const n of top) g.setNode(n.id, { width: n.w, height: n.h });
  const ids = new Set(nodes.map((n) => n.id));
  const live = edges.filter((e) => ids.has(e.source) && ids.has(e.target) && e.source !== e.target);
  live.forEach((e, i) => {
    if (rep(e.source) !== rep(e.target)) g.setEdge(rep(e.source), rep(e.target), {}, `e${i}`);
  });
  const columns = !grid && nodes.length > 0 && nodes.every((n) => n.col !== undefined);
  const fixed = grid ? gridPositions(nodes, grid, nodesep, ranksep) : columns ? columnPositions(nodes, live, ranksep, nodesep) : null;
  const bus = !!grid; // a tree's lines; dagre keeps React Flow's own
  const routes = columns && fixed ? routeEdges(nodes, fixed, live) : null;
  if (!fixed) dagre.layout(g);
  const vertical = rankdir === "TB";
  // Each card is the size it says (`.gcard` is border-box), so React Flow is
  // told its measure up front. A node handed over again without `measured`
  // (a new layout, a colour patch) has its handles' bounds dropped, and a card
  // whose size did not change is not measured again: its lines were never drawn.
  const measured = (n: GNode) => ({ width: n.w, height: n.h });
  return {
    // A parent before its children, as React Flow needs them.
    nodes: [...top, ...nodes.filter((n) => n.parent)].map((n) => {
      if (n.parent) return { id: n.id, type: "box", position: n.at ?? { x: 0, y: 0 }, parentId: n.parent, extent: "parent" as const, data: { g: n, vertical }, measured: measured(n) };
      const at = fixed?.get(n.id);
      if (at || fixed) return { id: n.id, type: "box", position: at ?? { x: 0, y: 0 }, data: { g: n, vertical }, measured: measured(n) };
      const p = g.node(n.id) as { x: number; y: number };
      return { id: n.id, type: "box", position: { x: p.x - n.w / 2, y: p.y - n.h / 2 }, data: { g: n, vertical }, measured: measured(n) };
    }),
    edges: live.map((e, i) => ({
      id: e.id ?? `e${i}-${e.source}-${e.target}`,
      source: e.source,
      target: e.target,
      targetHandle: bus ? "l" : undefined,
      label: e.label,
      type: bus ? "bus" : routes ? "route" : "default",
      data: routes ? { route: routes[i] } : undefined,
      style: { stroke: e.color ?? "var(--slate-400)", strokeWidth: 1.6, strokeDasharray: e.dashed ? "5 4" : undefined },
      labelStyle: { fontSize: 11, fill: "var(--slate-600)" },
      labelBgStyle: { fill: "var(--slate-50)" },
      markerEnd: e.arrow ? { type: MarkerType.ArrowClosed, color: e.color ?? "var(--slate-400)", width: 16, height: 16 } : undefined,
    })),
  };
}

// Fitted again when the layout or the pane's size changes: `fitView` alone
// fits once, at whatever size the pane had then (on a phone the page widens
// after the first paint), so the picture depended on which came first.
const FIT = { padding: 0.08 };
function Refit({ flow }: { flow: unknown }) {
  const { fitView } = useReactFlow();
  const width = useStore((s) => s.width);
  const height = useStore((s) => s.height);
  useEffect(() => {
    if (width > 0 && height > 0) void fitView(FIT);
  }, [flow, width, height, fitView]);
  return null;
}

export function Graph({ nodes, edges, rankdir = "TB", height = 520, nodesep = 30, ranksep = 60, grid }: { nodes: GNode[]; edges: GEdge[]; rankdir?: "TB" | "LR"; height?: number | string; nodesep?: number; ranksep?: number; grid?: TreeGrid }) {
  const flow = useMemo(() => layout(nodes, edges, rankdir, nodesep, ranksep, grid), [nodes, edges, rankdir, nodesep, ranksep, grid]);
  return (
    <div className="graph" style={{ height }}>
      <ReactFlow
        nodes={flow.nodes}
        edges={flow.edges}
        nodeTypes={nodeTypes}
        edgeTypes={edgeTypes}
        fitView
        fitViewOptions={FIT}
        minZoom={0.2}
        maxZoom={1.5}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        proOptions={{ hideAttribution: true }}
        // A node with no click handler gets no pointer events; the cards handle their own.
        onNodeClick={() => undefined}
      >
        <Background gap={24} color="var(--gray-200)" />
        <Controls showInteractive={false} />
        <Refit flow={flow} />
      </ReactFlow>
    </div>
  );
}
