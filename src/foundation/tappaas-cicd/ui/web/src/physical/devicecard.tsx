// devicecard.tsx — a device as the Device graph draws it: its kind's small
// icon and its name on a card coloured by its state, and nothing else (the
// details are the side panel's); a link's colour and dash.

import { zoneColor } from "../colors";
import { RecordedKind, Topology } from "../types";
import { DevKind, DevLink, DevNode, DevState } from "./devicegraph";

export const KIND_ICON: Record<DevKind, string> = { node: "▤", switch: "⇄", ap: "◉", isp: "☁", buddy: "⇆", machine: "▣", device: "▭" };
export const KIND_NAME: Record<DevKind, string> = { node: "cluster node", switch: "switch", ap: "access point", isp: "internet", buddy: "backup buddy", machine: "machine", device: "device" };

// A recorded device's own kind: its icon and its word.
export const RECORDED_ICON: Record<RecordedKind, string> = { modem: "⌁", ont: "⌁", ups: "ϟ", "patch-panel": "▦", other: "▭" };
export const RECORDED_NAME: Record<RecordedKind, string> = { modem: "modem", ont: "fibre terminal (ONT)", ups: "UPS", "patch-panel": "patch panel", other: "device" };
export const iconOf = (d: DevNode): string => (d.recorded ? RECORDED_ICON[d.recorded] : d.seen ? "?" : KIND_ICON[d.kind]);
export const kindName = (d: DevNode): string => (d.recorded ? `${RECORDED_NAME[d.recorded]} (recorded)` : d.seen ? "device seen at a switch port, recorded nowhere" : KIND_NAME[d.kind]);

export function DevLabel({ d, s }: { d: DevNode; s: DevState }) {
  return (
    <div className={`dev-card${d.seen ? " dev-seen" : ""}`} title={`${d.name} · ${kindName(d)} · ${s.reasons.length ? `${s.state}: ${s.reasons.join("; ")}` : "ok"}`}>
      <span className="dev-icon" aria-label={kindName(d)}>{iconOf(d)}</span>
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
  // (a pair joined by a wan and a lan cable is drawn as the lan's)
  if (l.kind === "hand-off" || (l.cables.length > 0 && l.cables.every((c) => c.kind === "wan")) || (l.zones.length === 1 && l.zones[0] === t.site.wan.zone)) return { stroke: zoneColor({ name: "wan" }), width, dash: "6 4" };
  const zs = l.cables.every((c) => c.kind === "wan") ? l.zones : l.cables.filter((c) => c.kind !== "wan").flatMap((c) => c.zones);
  if (new Set(zs).size === 1) {
    const z = t.zones.find((x) => x.name === zs[0]);
    return { stroke: zoneColor(z ?? { name: zs[0] }), width };
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
