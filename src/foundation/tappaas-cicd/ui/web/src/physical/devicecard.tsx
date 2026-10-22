// devicecard.tsx — a device as the Device graph draws it: its kind's small
// icon and its name on a card coloured by its state, and nothing else (the
// details are the side panel's); a link's colour and dash.

import { zoneColor } from "../colors";
import { Topology } from "../types";
import { DevKind, DevLink, DevNode, DevState } from "./devicegraph";

export const KIND_ICON: Record<DevKind, string> = { node: "▤", switch: "⇄", ap: "◉", isp: "☁", buddy: "⇆", machine: "▣", device: "▭" };
export const KIND_NAME: Record<DevKind, string> = { node: "cluster node", switch: "switch", ap: "access point", isp: "internet", buddy: "backup buddy", machine: "machine", device: "device" };

export function DevLabel({ d, s }: { d: DevNode; s: DevState }) {
  return (
    <div className="dev-card" title={`${d.name} · ${KIND_NAME[d.kind]} · ${s.reasons.length ? `${s.state}: ${s.reasons.join("; ")}` : "ok"}`}>
      <span className="dev-icon" aria-label={KIND_NAME[d.kind]}>{KIND_ICON[d.kind]}</span>
      <span className="dev-name">{d.name}</span>
    </div>
  );
}

// A link's stroke: the WAN and the internet's hand-off dashed in the WAN
// colour, a tunnel dotted, a link down red, one zone in its colour, a trunk
// slate; an aggregate (a LAG, several cables) thicker.
export function linkStyle(l: DevLink, t: Topology): { stroke: string; width: number; dash?: string } {
  const width = l.cables.length > 1 || l.cables.some((c) => c.lag) ? 3.4 : 2;
  if (l.up === false) return { stroke: "#d64545", width, dash: "3 3" };
  if (l.kind === "tunnel") return { stroke: "#7c3aed", width: 1.6, dash: "1 4" };
  if (l.kind === "wan" || l.kind === "hand-off" || (l.zones.length === 1 && l.zones[0] === t.site.wan.zone)) return { stroke: zoneColor({ name: "wan" }), width, dash: "6 4" };
  if (l.zones.length === 1) {
    const z = t.zones.find((x) => x.name === l.zones[0]);
    return { stroke: zoneColor(z ?? { name: l.zones[0] }), width };
  }
  return { stroke: "#475569", width };
}

// A link's label: the ports at its ends, or how many cables.
export function linkText(l: DevLink): string {
  if (l.cables.length === 0) return l.kind === "tunnel" ? "tunnel" : l.kind;
  if (l.cables.length > 1) return `${l.cables.length} cables${l.cables[0].lag ? ` · ${l.cables[0].lag}` : ""}`;
  const c = l.cables[0];
  return `${c.from.port} ↔ ${c.to.port}`;
}
