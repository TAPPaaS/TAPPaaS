// layout.ts — what the Physical, Device and Storage views select (the side
// panel shows it), and a switch port's far end in words.

import { TopoPort } from "../types";

export type Sel =
  | { kind: "node"; id: string }
  | { kind: "port"; id: string; switch: string }
  | { kind: "switch"; id: string }
  | { kind: "lag"; id: string; switch: string }
  | { kind: "ap"; id: string }
  | { kind: "outside"; id: string }
  | { kind: "guest"; id: string }
  | { kind: "isp"; id: string }
  | { kind: "firewall"; id: string }
  | { kind: "rack"; id: string }
  | { kind: "mount"; id: string }
  | { kind: "disk"; id: string; node: string } // id: the device
  | { kind: "pool"; id: string; node: string }
  | { kind: "link"; id: string; port?: string }; // id: devicegraph.ts linkId; port: the end clicked, "<device>:<port>"

export type Pick = (s: Sel) => void;

export function portLabel(p: TopoPort): string {
  if (p.parked) return `parked · ${p.zones[0] ?? "?"}`;
  if (!p.target) return p.description ?? "—";
  if (p.target.kind === "isp") return p.description ?? "ISP hand-off";
  const nm = p.target.name ?? "?";
  return `${nm}${p.target.port ? ` ${p.target.port}` : ""}${p.role === "node-wan" ? " (wan)" : ""}`;
}
