// Physical — the site as it is built, laid out from `network-manager topology`
// and nothing else, in two views. Rack (the default once a rack is recorded):
// the racks with each device's faceplate at its units and the cables port to
// port (physical/rack.tsx), the devices mounted nowhere in a tray. Cabling
// (ADR-034 D5, mockup ui-02): the cards and links laid out automatically.
// Click an object for its side card.

import { Background, Controls, ReactFlow } from "@xyflow/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useRead } from "../api";
import { zoneColor } from "../colors";
import { OperateButton } from "../operate";
import { nodeTypes } from "../physical/cards";
import { Sel, layoutTopology } from "../physical/layout";
import { RackCanvas } from "../physical/rack";
import { MountActions, rackAddSteps } from "../physical/rackops";
import { SidePanel } from "../physical/SidePanel";
import { Health, RacksView, Topology } from "../types";
import { ReadState, canOperate, navigate, since, useMe } from "../ui";

function selFromUrl(): Sel | null {
  const v = new URLSearchParams(window.location.search).get("select");
  if (!v) return null;
  const [kind, ...rest] = v.split(":");
  const id = rest.join(":");
  if (kind === "node" || kind === "outside" || kind === "ap" || kind === "guest" || kind === "switch" || kind === "rack" || kind === "mount") return { kind, id };
  return null;
}

export type PhysicalView = "rack" | "cabling";

// The devices mounted nowhere, each with Mount… (the catalog's plate for it,
// the first rack's highest free units).
function Unplaced({ v, pick }: { v: RacksView; pick: (s: Sel) => void }) {
  const operator = canOperate(useMe());
  const gone = v.findings.filter((f) => f.kind === "gone");
  return (
    <aside className="rack-tray">
      <h3>Unplaced</h3>
      {v.unplaced.length === 0 ? <p className="muted small">Every device is mounted.</p> : null}
      <ul className="plain">
        {v.unplaced.map((u) => (
          <li key={u.device}>
            <button className="linklike" onClick={() => pick(u.kind === "node" ? { kind: "node", id: u.device } : u.kind === "switch" ? { kind: "switch", id: u.device } : u.kind === "ap" ? { kind: "ap", id: u.device } : { kind: "mount", id: u.device })}>
              {u.device}
            </button>
            <div className="muted small">
              {u.kind}
              {u.model ? ` · ${u.model}` : ""}
              {u.suggestion ? ` · plate ${u.suggestion}` : ""}
            </div>
            {operator ? <MountActions device={u.device} v={v} /> : null}
          </li>
        ))}
      </ul>
      {gone.length ? (
        <>
          <h3>Mounted, but gone</h3>
          <ul className="plain small">
            {gone.map((g) => (
              <li key={g.device}>
                <button className="linklike" onClick={() => pick({ kind: "mount", id: g.device })}>{g.device}</button> <span className="muted">{g.text}</span>
              </li>
            ))}
          </ul>
        </>
      ) : null}
      {v.racks.some((r) => r.mounts.some((m) => m.face === "rear")) ? (
        <p className="muted small">Rear-facing mounts are not drawn: {v.racks.flatMap((r) => r.mounts.filter((m) => m.face === "rear").map((m) => m.device)).join(", ")}.</p>
      ) : null}
    </aside>
  );
}

// Standalone (the owner's route) or as the Site page's Physical tab (embedded:
// the Site page has the heading). view: the one the address names, else Rack
// when a rack is recorded.
export function Physical({ embedded, view }: { embedded?: boolean; view?: PhysicalView }) {
  const topo = useRead<Topology>("topology");
  const health = useRead<Health>("health");
  const [sel, setSel] = useState<Sel | null>(selFromUrl);
  const [showGuests, setShowGuests] = useState(true);
  const [showLabels, setShowLabels] = useState(true);
  const [showCables, setShowCables] = useState(true);
  const operator = canOperate(useMe());
  const t = topo.env?.data ?? null;
  const racks = t?.racks ?? null;
  const shown: PhysicalView = view ?? (racks && racks.racks.length > 0 ? "rack" : "cabling");

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
  const flow = useMemo(() => (t && shown === "cabling" ? layoutTopology(t, { pick, selected: sel, showGuests, showLabels, memory }) : null), [t, shown, pick, sel, showGuests, showLabels, memory]);
  const bad = (t?.sources ?? []).filter((s) => !s.ok);

  return (
    <div className={embedded ? "" : "page page-wide"}>
      <div className="page-head">
        {embedded ? null : <h1>Physical</h1>}
        <div className="seg" role="tablist" aria-label="view">
          {(["rack", "cabling"] as const).map((x) => (
            <button key={x} role="tab" aria-selected={shown === x} className={shown === x ? "seg-on" : ""} onClick={() => navigate(`/site/physical/${x}`)}>
              {x === "rack" ? "Rack" : "Cabling"}
            </button>
          ))}
        </div>
        <span className="muted">
          {t ? `${t.site.name ?? "site"} ${shown === "rack" ? "as racked" : "as cabled"} · topology ${since(t.generated)} · ${shown === "rack" ? "positions from config/racks.json" : "layout automatic"}` : ""}
        </span>
        <span className="spacer" />
        {shown === "cabling" ? (
          <>
            <label className="toggle">
              <input type="checkbox" checked={showGuests} onChange={(e) => setShowGuests(e.target.checked)} /> guests
            </label>
            <label className="toggle">
              <input type="checkbox" checked={showLabels} onChange={(e) => setShowLabels(e.target.checked)} /> link labels
            </label>
          </>
        ) : (
          <>
            <label className="toggle">
              <input type="checkbox" checked={showCables} onChange={(e) => setShowCables(e.target.checked)} /> cables
            </label>
            {operator ? <OperateButton label="Add a rack…" title="Add a rack" steps={rackAddSteps} /> : null}
          </>
        )}
      </div>
      <ReadState env={topo.env} failure={topo.failure} what="topology (network-manager topology)" />
      {bad.length ? (
        <div className="readstate readstate-warn">
          Not drawn, because these did not answer: {bad.map((s) => `${s.name} (${s.error ?? "?"})`).join("; ")}
        </div>
      ) : null}
      {shown === "rack" ? (
        <div className="physical physical-rack">
          {sel && t ? <SidePanel t={t} sel={sel} close={() => setSel(null)} /> : null}
          <div className="canvas">
            {t && racks && racks.racks.length ? (
              <RackCanvas t={t} v={racks} sel={sel} pick={pick} cables={showCables} onPane={() => setSel(null)} />
            ) : t ? (
              <div className="rack-empty">
                <p>{racks ? "No rack is recorded yet." : "The topology carries no racks (rack-manager did not answer)."}</p>
                <p className="muted small">A rack is recorded with rack-manager: its height, width and numbering; then each device is mounted at its units, with the faceplate the catalog has for its model.</p>
                {operator && racks ? <OperateButton label="Add a rack…" kind="primary" title="Add a rack" steps={rackAddSteps} /> : null}
              </div>
            ) : null}
          </div>
          {racks && racks.racks.length ? <Unplaced v={racks} pick={pick} /> : null}
        </div>
      ) : (
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
      )}
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
          <span className="muted">
            {shown === "rack" ? "— trunk · - - wan · ··· recorded · red: no link · purple ring: LAG member · green port: link up" : "— trunk · - - wan access · ··· tunnel · ⚠ finding"}
          </span>
          <span className="muted">
            Data: {(t.sources ?? []).filter((s) => s.ok).map((s) => s.name).join(" · ")}
          </span>
        </div>
      ) : null}
    </div>
  );
}
