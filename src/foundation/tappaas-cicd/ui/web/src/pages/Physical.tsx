// Physical — the site as it is cabled (ADR-034 D5, mockup ui-02), laid out from
// `network-manager topology` and nothing else. Click an object for its side panel.

import { Background, Controls, ReactFlow } from "@xyflow/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useRead } from "../api";
import { zoneColor } from "../colors";
import { nodeTypes } from "../physical/cards";
import { Sel, layoutTopology } from "../physical/layout";
import { SidePanel } from "../physical/SidePanel";
import { Health, Topology } from "../types";
import { ReadState, since } from "../ui";

function selFromUrl(): Sel | null {
  const v = new URLSearchParams(window.location.search).get("select");
  if (!v) return null;
  const [kind, ...rest] = v.split(":");
  const id = rest.join(":");
  if (kind === "node" || kind === "outside" || kind === "ap" || kind === "guest" || kind === "switch") return { kind, id };
  return null;
}

// Standalone (the owner's route) or as the Site page's Physical tab (embedded:
// the Site page has the heading).
export function Physical({ embedded }: { embedded?: boolean }) {
  const topo = useRead<Topology>("topology");
  const health = useRead<Health>("health");
  const [sel, setSel] = useState<Sel | null>(selFromUrl);
  const [showGuests, setShowGuests] = useState(true);
  const [showLabels, setShowLabels] = useState(true);
  const t = topo.env?.data ?? null;

  useEffect(() => {
    const on = () => setSel(selFromUrl());
    window.addEventListener("popstate", on);
    return () => window.removeEventListener("popstate", on);
  }, []);

  const pick = useCallback((s: Sel) => setSel(s), []);
  const memory = useMemo(() => {
    const m: Record<string, string> = {};
    for (const f of health.env?.data?.gates.find((g) => g.name === "memory-commitment")?.findings ?? []) {
      if (f.subject?.kind === "node") m[f.subject.name] = f.text;
    }
    return m;
  }, [health.env]);
  const flow = useMemo(() => (t ? layoutTopology(t, { pick, selected: sel, showGuests, showLabels, memory }) : null), [t, pick, sel, showGuests, showLabels, memory]);
  const bad = (t?.sources ?? []).filter((s) => !s.ok);

  return (
    <div className={embedded ? "" : "page page-wide"}>
      <div className="page-head">
        {embedded ? null : <h1>Physical</h1>}
        <span className="muted">{t ? `${t.site.name ?? "site"} as cabled · topology ${since(t.generated)} · layout automatic` : ""}</span>
        <span className="spacer" />
        <label className="toggle">
          <input type="checkbox" checked={showGuests} onChange={(e) => setShowGuests(e.target.checked)} /> guests
        </label>
        <label className="toggle">
          <input type="checkbox" checked={showLabels} onChange={(e) => setShowLabels(e.target.checked)} /> link labels
        </label>
      </div>
      <ReadState env={topo.env} failure={topo.failure} what="topology (network-manager topology)" />
      {bad.length ? (
        <div className="readstate readstate-warn">
          Not drawn, because these did not answer: {bad.map((s) => `${s.name} (${s.error ?? "?"})`).join("; ")}
        </div>
      ) : null}
      <div className="physical">
        <div className="canvas">
          {flow ? (
            <ReactFlow
              nodes={flow.nodes}
              edges={flow.edges}
              nodeTypes={nodeTypes}
              fitView
              fitViewOptions={{ padding: 0.06 }}
              minZoom={0.2}
              nodesDraggable={false}
              nodesConnectable={false}
              elementsSelectable={false}
              proOptions={{ hideAttribution: true }}
              // A node with no click handler gets no pointer events at all; the
              // cards select themselves (their port rows and chips more finely).
              onNodeClick={() => undefined}
              onPaneClick={() => setSel(null)}
            >
              <Background gap={24} color="#e5e7eb" />
              <Controls showInteractive={false} />
            </ReactFlow>
          ) : null}
        </div>
        {sel && t ? <SidePanel t={t} sel={sel} close={() => setSel(null)} /> : null}
      </div>
      {t ? (
        <div className="legend">
          <span className="muted">Zones on links:</span>
          {t.zones
            .filter((z) => z.vlan && z.vlan > 0 && (z.state === "Active" || z.state === "Mandatory" || z.type === "WAN"))
            .sort((a, b) => (a.vlan ?? 0) - (b.vlan ?? 0))
            .map((z) => (
              <span key={z.name} className="zone">
                <i style={{ background: zoneColor(z) }} />
                {z.vlan} {z.name}
              </span>
            ))}
          <span className="muted">— trunk · - - wan access · ··· tunnel · ⚠ finding</span>
          <span className="muted">
            Data: {(t.sources ?? []).filter((s) => s.ok).map((s) => s.name).join(" · ")}
          </span>
        </div>
      ) : null}
    </div>
  );
}
