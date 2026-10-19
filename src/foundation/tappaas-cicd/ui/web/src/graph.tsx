// graph.tsx — cards joined by lines, laid out by dagre (or in columns, or as a
// tree's grid) and drawn by React Flow: a module's config tree, the zones and
// their reach, the identity objects and their relations. Nothing is placed by
// hand; each card gives its own size.

import dagre from "@dagrejs/dagre";
import { BaseEdge, Background, Controls, Edge, EdgeProps, Handle, MarkerType, Node, NodeProps, Position, ReactFlow, getBezierPath } from "@xyflow/react";
import { ReactNode, useMemo } from "react";
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
}

export interface GEdge {
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

const nodeTypes = { box: Box };

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

const edgeTypes = { bus: BusEdge, route: RouteEdge };

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
  for (const n of nodes) g.setNode(n.id, { width: n.w, height: n.h });
  const ids = new Set(nodes.map((n) => n.id));
  const live = edges.filter((e) => ids.has(e.source) && ids.has(e.target) && e.source !== e.target);
  live.forEach((e, i) => g.setEdge(e.source, e.target, {}, `e${i}`));
  const columns = !grid && nodes.length > 0 && nodes.every((n) => n.col !== undefined);
  const fixed = grid ? gridPositions(nodes, grid, nodesep, ranksep) : columns ? columnPositions(nodes, live, ranksep, nodesep) : null;
  const bus = !!grid; // a tree's lines; dagre keeps React Flow's own
  const routes = columns && fixed ? routeEdges(nodes, fixed, live) : null;
  if (!fixed) dagre.layout(g);
  const vertical = rankdir === "TB";
  return {
    nodes: nodes.map((n) => {
      if (fixed) return { id: n.id, type: "box", position: fixed.get(n.id) ?? { x: 0, y: 0 }, data: { g: n, vertical } };
      const p = g.node(n.id) as { x: number; y: number };
      return { id: n.id, type: "box", position: { x: p.x - n.w / 2, y: p.y - n.h / 2 }, data: { g: n, vertical } };
    }),
    edges: live.map((e, i) => ({
      id: `e${i}-${e.source}-${e.target}`,
      source: e.source,
      target: e.target,
      targetHandle: bus ? "l" : undefined,
      label: e.label,
      type: bus ? "bus" : routes ? "route" : "default",
      data: routes ? { route: routes[i] } : undefined,
      style: { stroke: e.color ?? "#94a3b8", strokeWidth: 1.6, strokeDasharray: e.dashed ? "5 4" : undefined },
      labelStyle: { fontSize: 11, fill: "#475569" },
      labelBgStyle: { fill: "#f8fafc" },
      markerEnd: e.arrow ? { type: MarkerType.ArrowClosed, color: e.color ?? "#94a3b8", width: 16, height: 16 } : undefined,
    })),
  };
}

export function Graph({ nodes, edges, rankdir = "TB", height = 520, nodesep = 30, ranksep = 60, grid }: { nodes: GNode[]; edges: GEdge[]; rankdir?: "TB" | "LR"; height?: number; nodesep?: number; ranksep?: number; grid?: TreeGrid }) {
  const flow = useMemo(() => layout(nodes, edges, rankdir, nodesep, ranksep, grid), [nodes, edges, rankdir, nodesep, ranksep, grid]);
  return (
    <div className="graph" style={{ height }}>
      <ReactFlow
        nodes={flow.nodes}
        edges={flow.edges}
        nodeTypes={nodeTypes}
        edgeTypes={edgeTypes}
        fitView
        fitViewOptions={{ padding: 0.08 }}
        minZoom={0.2}
        maxZoom={1.5}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        proOptions={{ hideAttribution: true }}
        // A node with no click handler gets no pointer events; the cards handle their own.
        onNodeClick={() => undefined}
      >
        <Background gap={24} color="#e5e7eb" />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  );
}
