// devicedrawing.tsx — the top of the side panel for a device: its faceplate
// as the Physical view draws it (rack.tsx PlateSvg), from the rack catalog
// when it is mounted or placed by a cable record, else a generic plate made
// from what the topology knows of its ports (a switch's ports, a node's
// uplink NICs, an access point's uplink). The cabled ports are underlined,
// the selected link's ports ringed; a click on a port selects it (a switch
// port) or its link.

import { PlatePort, ResolvedPlate, Topology } from "../types";
import { DevNode } from "./devicegraph";
import { PlateSvg, Placed, R } from "./rack";

const W = 400;

const kindOfPort = (name: string): PlatePort["kind"] => (/sfp|qsfp|xg/i.test(name) ? "sfp+" : "rj45");

// A plate for a device the catalog does not draw.
function genericPlate(t: Topology, d: DevNode): ResolvedPlate | null {
  let ports: PlatePort[] = [];
  if (d.kind === "switch") {
    const s = t.switches.find((x) => x.name === d.name);
    ports = (s?.ports ?? []).map((p) => ({ id: p.port, name: p.port, kind: kindOfPort(p.port), up: p.link === "up" ? true : p.link === "down" ? false : null, disabled: false, lag: p.lag, zones: p.zones }));
  } else if (d.kind === "node") {
    const n = t.nodes.find((x) => x.name === d.name);
    ports = (n?.uplinks ?? []).flatMap((u) => u.legs.map((l) => ({ id: l.nic, name: l.nic, kind: kindOfPort(l.nic), up: l.up, disabled: false, lag: u.bond, zones: [] })));
  } else if (d.kind === "ap") {
    ports = [{ id: "uplink", name: "uplink", kind: "poe", up: null, disabled: false, lag: null, zones: [] }];
  } else {
    // A recorded device: the ports its record names.
    const rec = t.devices?.find((x) => x.name === d.name && x.recorded);
    if (!rec?.ports?.length) return null;
    ports = rec.ports.map((p) => ({ id: p, name: p, kind: rec.kind === "ups" ? "power" : "rj45", up: null, disabled: false, lag: null, zones: [] }));
    const per = ports.length > 24 ? Math.ceil(ports.length / 2) : ports.length;
    const rows: (PlatePort | null)[][] = [ports.slice(0, per), ...(ports.length > per ? [ports.slice(per)] : [])];
    const small = rec.kind === "modem" || rec.kind === "ont";
    return { key: "recorded", vendor: "Generic", model: rec.kind === "patch-panel" ? `${ports.length}-port patch panel` : rec.kind, kind: rec.kind, units: rows.length > 1 ? 2 : 1, width: small ? "half" : "full", passive: true, rows, labels: [] };
  }
  const per = ports.length > 12 ? Math.ceil(ports.length / 2) : ports.length;
  const rows: (PlatePort | null)[][] = per ? [ports.slice(0, per), ...(ports.length > per ? [ports.slice(per)] : [])] : [];
  return { key: "generic", vendor: "Generic", model: d.kind === "node" ? "server" : d.kind === "ap" ? "access point" : "switch", kind: d.kind, units: rows.length > 1 ? 2 : 1, width: d.kind === "ap" ? "half" : "full", passive: false, rows, labels: [] };
}

// The plate a device has: its mount's, the cable record's, else generic.
export function plateOf(t: Topology, d: DevNode): { plate: ResolvedPlate | null; up: boolean | null; catalog: boolean } {
  const m = t.racks?.racks.flatMap((r) => r.mounts).find((x) => x.device === d.name);
  if (m?.plate) return { plate: m.plate, up: m.up, catalog: true };
  const o = t.racks?.outside.find((x) => x.device === d.name);
  if (o?.plate) return { plate: o.plate, up: null, catalog: true };
  return { plate: genericPlate(t, d), up: null, catalog: false };
}

export function DeviceDrawing({ t, d, cabled, ringed, onPort }: { t: Topology; d: DevNode; cabled: Set<string>; ringed: Set<string>; onPort: (port: string) => void }) {
  const { plate, up, catalog } = plateOf(t, d);
  if (!plate) return null;
  const w = plate.width === "full" ? W : plate.width === "half" ? W / 2 : W / 3;
  const h = Math.max(1, plate.units) * R.u * 1.4;
  const p: Placed = {
    device: d.name,
    kind: d.kind === "node" || d.kind === "switch" || d.kind === "ap" ? d.kind : plate.passive ? "passive" : "device",
    plate,
    box: { x: 8, y: 6, w, h },
    up,
    title: d.name,
    sub: catalog ? `${plate.vendor} ${plate.model}` : `generic ${plate.model} plate`,
    rack: null,
  };
  return (
    <div className="dev-drawing">
      <svg viewBox={`0 0 ${W + 16} ${h + 14}`} width="100%" role="img" aria-label={`${d.name}'s faceplate`}>
        <PlateSvg p={p} on={false} portOn={(id) => ringed.has(id)} cabled={cabled} onPlate={() => undefined} onPort={onPort} />
      </svg>
    </div>
  );
}
