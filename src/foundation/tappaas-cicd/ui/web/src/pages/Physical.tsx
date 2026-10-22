// Physical — the site as it is built, in four views, each a tab of the Site
// page (physical/views.ts). Overview: the other three summed up. Physical: the
// racks with each device's faceplate at its units and the
// cables port to port (physical/rack.tsx), the devices mounted nowhere in a
// tray. Device (ADR-034 D5, mockup ui-02): every physical device as a card and
// its connections as lines, laid out automatically. Storage: the nodes, their
// pools and disks. Click an object for its side card.

import { Background, Controls, ReactFlow } from "@xyflow/react";
import { ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import { useRead } from "../api";
import { zoneColor } from "../colors";
import { OperateButton } from "../operate";
import { nodeTypes } from "../physical/cards";
import { Sel, layoutTopology } from "../physical/layout";
import { RackCanvas } from "../physical/rack";
import { MountActions, rackAddSteps } from "../physical/rackops";
import { SidePanel } from "../physical/SidePanel";
import { Health, RacksView, StorageInventory, Topology } from "../types";
import { StateLegend } from "../physical/state";
import { storageNotes } from "../physical/storage";
import { StorageGraph } from "../physical/storageview";
import { PhysicalOverview } from "../physical/overview";
import { PHYSICAL_TABS, PhysicalView, VIEW_NAME, VIEW_PATH } from "../physical/views";
import { ReadState, canOperate, navigate, since, useMe } from "../ui";

function selFromUrl(): Sel | null {
  const v = new URLSearchParams(window.location.search).get("select");
  if (!v) return null;
  const [kind, ...rest] = v.split(":");
  const id = rest.join(":");
  if (kind === "node" || kind === "outside" || kind === "ap" || kind === "guest" || kind === "switch" || kind === "rack" || kind === "mount" || kind === "isp" || kind === "firewall") return { kind, id };
  // port:<switch>:<port>, lag:<switch>:<lag>
  if ((kind === "port" || kind === "lag") && id.includes(":")) return { kind, switch: id.slice(0, id.lastIndexOf(":")), id: id.slice(id.lastIndexOf(":") + 1) };
  // disk:<node>:<device>, pool:<node>:<pool>
  if ((kind === "disk" || kind === "pool") && id.includes(":")) return { kind, node: id.slice(0, id.indexOf(":")), id: id.slice(id.indexOf(":") + 1) };
  return null;
}

export type { PhysicalView } from "../physical/views";

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

// Standalone (the owner's route: its own switch between the views) or on the
// Site page (embedded: the Site page has the heading and the tabs). view: the
// one the address names, else the Overview.
export function Physical({ embedded, view, aside }: { embedded?: boolean; view?: PhysicalView; aside?: ReactNode }) {
  const topo = useRead<Topology>("topology");
  const health = useRead<Health>("health");
  const [sel, setSel] = useState<Sel | null>(selFromUrl);
  const [showGuests, setShowGuests] = useState(true);
  const [showLabels, setShowLabels] = useState(true);
  const [showCables, setShowCables] = useState(true);
  const operator = canOperate(useMe());
  const t = topo.env?.data ?? null;
  const racks = t?.racks ?? null;
  const shown: PhysicalView = view ?? "overview";
  // The storage inventory: read once a view shows it (SMART, ≈15 s the first time).
  const store = useRead<StorageInventory>(shown === "storage" || shown === "overview" || sel?.kind === "node" ? "storage" : null);
  const inv = store.env?.data ?? null;
  const gates = health.env?.data?.gates;
  const storage = useMemo(() => (inv ? { inv, notes: storageNotes(inv, gates ?? []) } : null), [inv, gates]);

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
  const flow = useMemo(() => (t && shown === "device" ? layoutTopology(t, { pick, selected: sel, showGuests, showLabels, memory }) : null), [t, shown, pick, sel, showGuests, showLabels, memory]);
  const bad = (t?.sources ?? []).filter((s) => !s.ok);

  return (
    <div className={embedded ? "" : "page page-wide"}>
      <div className="page-head">
        {embedded ? null : <h1>Site</h1>}
        {embedded ? null : (
          <div className="seg" role="tablist" aria-label="view">
            {PHYSICAL_TABS.map((x) => (
              <button key={x} role="tab" aria-selected={shown === x} className={shown === x ? "seg-on" : ""} onClick={() => navigate(VIEW_PATH[x])}>
                {VIEW_NAME[x]}
              </button>
            ))}
          </div>
        )}
        <span className="muted">
          {t && (shown === "rack" || shown === "device") ? `${t.site.name ?? "site"} ${shown === "rack" ? "as racked" : "as cabled"} · topology ${since(t.generated)} · ${shown === "rack" ? "positions from config/racks.json" : "layout automatic"}` : ""}
        </span>
        <span className="spacer" />
        {shown === "device" ? (
          <>
            <label className="toggle">
              <input type="checkbox" checked={showGuests} onChange={(e) => setShowGuests(e.target.checked)} /> guests
            </label>
            <label className="toggle">
              <input type="checkbox" checked={showLabels} onChange={(e) => setShowLabels(e.target.checked)} /> link labels
            </label>
          </>
        ) : shown === "rack" ? (
          <>
            <label className="toggle">
              <input type="checkbox" checked={showCables} onChange={(e) => setShowCables(e.target.checked)} /> cables
            </label>
            {operator ? <OperateButton label="Add a rack…" title="Add a rack" steps={rackAddSteps} /> : null}
          </>
        ) : null}
      </div>
      <ReadState env={topo.env} failure={topo.failure} what="topology (network-manager topology)" />
      {bad.length ? (
        <div className="readstate readstate-warn">
          Not drawn, because these did not answer: {bad.map((s) => `${s.name} (${s.error ?? "?"})`).join("; ")}
        </div>
      ) : null}
      {shown === "overview" ? (
        <PhysicalOverview aside={aside} t={t} inv={inv} notes={storage?.notes ?? new Map()} storageError={store.failure ?? store.env?.error ?? null} />
      ) : shown === "storage" ? (
        <>
          <ReadState env={store.env} failure={store.failure} what="storage (storage-manager inventory)" />
          {inv && inv.sources.some((s) => !s.ok) ? (
            <div className="readstate readstate-warn">Not read: {inv.sources.filter((s) => !s.ok).map((s) => `${s.name} (${s.error ?? "?"})`).join("; ")}</div>
          ) : null}
          <div className="physical">
            <div className="canvas" key={sel ? "with-card" : "alone"}>{storage ? <StorageGraph inv={storage.inv} notes={storage.notes} sel={sel} pick={pick} /> : null}</div>
            {sel && t ? <SidePanel t={t} sel={sel} close={() => setSel(null)} storage={storage} /> : null}
          </div>
          <div className="legend">
            <StateLegend extra="a pool's bar is its fill" />
            <span className="muted">
              Data: storage-manager inventory {since(inv?.generated)}{inv && !inv.smart ? " (without SMART)" : ""}
            </span>
          </div>
        </>
      ) : shown === "rack" ? (
        <div className="physical physical-rack">
          {sel && t ? <SidePanel t={t} sel={sel} close={() => setSel(null)} storage={storage} /> : null}
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
          {sel && t ? <SidePanel t={t} sel={sel} close={() => setSel(null)} storage={storage} /> : null}
        </div>
      )}
      {t && (shown === "rack" || shown === "device") ? (
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
          {shown === "device" ? <StateLegend /> : null}
          <span className="muted">
            Data: {(t.sources ?? []).filter((s) => s.ok).map((s) => s.name).join(" · ")}
          </span>
        </div>
      ) : null}
    </div>
  );
}
