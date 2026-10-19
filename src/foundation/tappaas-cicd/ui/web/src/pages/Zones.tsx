// Zones.tsx — the zones as cards joined by what they may reach: a solid arrow
// for `access-to` (the zone may open connections to the other), a dashed one
// for `pinhole-allowed-from` (the other may be let in through a pinhole),
// coloured by zone type and laid out automatically. A click opens the zone's
// fields and its verbs; Modify lists every field of zones-fields.json with its
// value, default and change class, several per job.

import { useMemo } from "react";
import { useRead } from "../api";
import { fieldsStep } from "../fields";
import { FieldRow, ZoneFieldSpec, shortValue, zoneFieldRows } from "../forms";
import { GEdge, GNode, Graph } from "../graph";
import { OperateButton, Step } from "../operate";
import { Dot, ReadState } from "../ui";

export interface ZoneRead {
  name: string;
  type?: string;
  state?: string;
  vlantag?: number;
  ip?: string;
  tier?: number;
  serves?: string | string[];
  description?: string;
  error?: string;
  "access-to"?: string[];
  "pinhole-allowed-from"?: string[];
  [k: string]: unknown;
}

export const TYPE_COLOR: Record<string, string> = {
  Management: "#475569",
  Service: "#3b6fd4",
  Client: "#2f9e44",
  IoT: "#e8a317",
  Guest: "#0ea5a4",
  DMZ: "#d64545",
  Overlay: "#7c3aed",
  WAN: "#8e8e8e",
};
// Words in access-to that are not zones.
const PSEUDO: Record<string, string> = { internet: "the internet", all: "every zone" };

const net = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "network-manager", verb, ...extra });
const reconcile = net("network-manager reconcile", "reconcile", { note: "The preview runs every plane dry (OPNsense, Proxmox, the switches, the APs); apply makes the change live." });

const live = (z: ZoneRead) => z.state === "Active" || z.state === "Mandatory" || z.state === "Manual";

// The columns of the zones graph: trust runs left to right. Overlays (no
// tier) first, then tier 0 to 4, the internet (which counts as tier 5, with
// the WAN), and the tier-6 zones that reach nothing last.
const COLUMN_TITLES: Record<number, string> = { 0: "overlays", 1: "tier 0 · management", 2: "tier 1 · services", 3: "tier 2 · trusted clients", 4: "tier 3", 5: "tier 4 · DMZ", 6: "internet · tier 5", 7: "tier 6 · no egress" };
// A zone with no tier recorded (an inactive one, or one authored the low-level
// way) takes its type's usual tier, as the archetypes give it.
const TYPE_TIER: Record<string, number> = { Management: 0, Service: 1, Client: 2, Guest: 3, IoT: 3, DMZ: 4 };
export function zoneColumn(z: Pick<ZoneRead, "type" | "tier">): number {
  if (z.type === "WAN") return 6;
  if (z.type === "Overlay") return 0;
  const tier = typeof z.tier === "number" ? z.tier : TYPE_TIER[z.type ?? ""];
  if (tier === undefined) return 0;
  return tier >= 6 ? 7 : tier + 1;
}

export function zoneGraph(zones: ZoneRead[], pick: (z: string) => void, selected: string | null): { nodes: GNode[]; edges: GEdge[] } {
  const names = new Set(zones.map((z) => z.name));
  const edges: GEdge[] = [];
  const pseudo = new Set<string>();
  for (const z of zones) {
    const color = TYPE_COLOR[z.type ?? ""] ?? "#94a3b8";
    for (const t of z["access-to"] ?? []) {
      if (!names.has(t)) pseudo.add(t);
      edges.push({ source: z.name, target: t, color, arrow: true });
    }
    for (const f of z["pinhole-allowed-from"] ?? []) {
      if (!names.has(f)) pseudo.add(f);
      edges.push({ source: f, target: z.name, color: "#f08c3a", dashed: true, arrow: true, label: "pinhole" });
    }
  }
  const nodes: GNode[] = zones.map((z) => ({
    id: z.name,
    w: 190,
    h: 74,
    col: zoneColumn(z),
    order: z.vlantag ?? 0,
    accent: TYPE_COLOR[z.type ?? ""] ?? "#94a3b8",
    className: `zcard${live(z) ? "" : " zcard-off"}${selected === z.name ? " zcard-on" : ""}`,
    onClick: () => pick(z.name),
    content: (
      <div>
        <div className="cf-title">
          <Dot level={z.state === "Active" || z.state === "Mandatory" ? "pass" : z.state === "Manual" ? "info" : "skip"} />
          <span className="mono">{z.name}</span>
          <span className="cf-roles">{z.vlantag ? `vlan ${z.vlantag}` : ""}</span>
        </div>
        <div className="cf-sub">{z.type ?? "?"} · {z.state ?? "?"}{z.tier !== undefined ? ` · tier ${z.tier}` : ""}</div>
        <div className="cf-sub">{z.serves ? `serves ${Array.isArray(z.serves) ? z.serves.join(", ") : z.serves}` : z.ip ?? ""}</div>
      </div>
    ),
  }));
  for (const p of pseudo) {
    nodes.push({ id: p, w: 130, h: 44, col: 6, order: p === "internet" ? 0 : 1, className: "zcard-pseudo", content: <div className="cf-title">{PSEUDO[p] ?? p}</div> });
  }
  // A title above each column in use.
  for (const c of new Set(nodes.map((n) => n.col ?? 0))) {
    nodes.push({ id: `col-${c}`, w: 190, h: 22, col: c, order: -1, className: "zcard-head", content: <div className="cf-sub">{COLUMN_TITLES[c] ?? `column ${c}`}</div> });
  }
  return { nodes, edges };
}

function ZoneDetail({ z, schema, envNames, close }: { z: ZoneRead; schema: Record<string, ZoneFieldSpec> | null; envNames: string[]; close: () => void }) {
  const rows: FieldRow[] = schema ? zoneFieldRows(z, schema) : [];
  return (
    <aside className="sidepanel">
      <header>
        <div>
          <h2 className="mono">{z.name}</h2>
          <div className="muted small">{z.type} · {z.state} · vlan {z.vlantag ?? "—"} · {z.ip ?? ""}</div>
        </div>
        <button className="btn-x" onClick={close} aria-label="close">×</button>
      </header>
      {z.description ? <p className="small">{z.description}</p> : null}
      <div className="toolbar">
        <OperateButton
          label="Modify…"
          kind="primary"
          title={`Modify zone ${z.name}`}
          steps={() => [
            fieldsStep({
              title: `The fields of ${z.name}`,
              bin: "network-manager",
              verb: "modify",
              fixed: [z.name],
              kind: "zone",
              name: z.name,
              mode: "modify",
              note: "One modify for every field changed, all or none. It writes zones.json only; the reconcile after makes it live.",
            }),
            reconcile,
          ]}
        />
        {(z.state === "Active" ? ["disable", "manual"] : ["enable"]).map((w) => (
          <OperateButton
            key={w}
            label={`${w[0].toUpperCase()}${w.slice(1)}…`}
            title={`network-manager ${w} ${z.name}`}
            steps={[{ ...net(`network-manager ${w} ${z.name}`, "enable|disable|manual", { fixed: [z.name], note: "Writes the zone's state into zones.json only; the reconcile after makes it live." }), words: [w] }, reconcile]}
          />
        ))}
        <OperateButton label="Bind…" title={`Bind ${z.name} to an environment`} steps={[net(`network-manager bind ${z.name}`, "bind", { fixed: [z.name], choices: { "--environment": envNames } })]} />
        <OperateButton label="Delete…" kind="danger" title={`Delete zone ${z.name}`} steps={[net(`network-manager delete ${z.name}`, "delete", { fixed: [z.name] })]} />
      </div>
      <table className="table compact zfields">
        <tbody>
          {rows.map((r) => (
            <tr key={r.field} title={r.description}>
              <td className="mono">{r.field}</td>
              <td className={`mono wrap${r.configured ? "" : " muted"}`}>{shortValue(r.value, 60)}{r.configured ? "" : <span className="dflt"> default</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </aside>
  );
}

export function ZonesGraph({ zones, envNames, sel, setSel }: { zones: ZoneRead[]; envNames: string[]; sel: string | null; setSel: (z: string | null) => void }) {
  const schemaR = useRead<{ fields?: Record<string, ZoneFieldSpec> }>("schemas/zones", 600_000);
  const schema = schemaR.env?.data?.fields ?? null;
  const graph = useMemo(() => zoneGraph(zones, setSel, sel), [zones, sel, setSel]);
  const z = zones.find((x) => x.name === sel) ?? null;
  return (
    <>
      <ReadState env={schemaR.env} failure={schemaR.failure} what="zones-fields.json" />
      <div className="zones-view">
        <div className="zones-canvas">
          <Graph nodes={graph.nodes} edges={graph.edges} rankdir="LR" height={560} nodesep={18} ranksep={70} />
        </div>
        {z ? <ZoneDetail key={z.name} z={z} schema={schema} envNames={envNames} close={() => setSel(null)} /> : null}
      </div>
      <div className="legend">
        {Object.entries(TYPE_COLOR).map(([t, c]) => (
          <span key={t} className="zone">
            <i style={{ background: c }} />
            {t}
          </span>
        ))}
        <span className="muted">→ may reach (access-to) · ⇢ may be let in through a pinhole (pinhole-allowed-from) · faded: inactive or disabled · click a zone for its fields and Modify</span>
      </div>
    </>
  );
}
