// rackops.tsx — the changes the rack view offers, as rack-manager's own verbs:
// a rack added, changed or deleted; a device mounted, moved or unmounted; a
// cable nothing can see recorded or removed. Each is a Step (operate.tsx):
// Change → Preview (--check) → Apply. Nothing here touches a device.

import { fieldsStep } from "../fields";
import { OperateButton, Step } from "../operate";
import { RackInfo, RacksView } from "../types";

const RM = "rack-manager";

// The highest free run of `height` units at full width on a face, as the rack
// numbers its units (the lowest unit of the run); null when none is free.
export function firstFree(r: RackInfo, height: number, face: "front" | "rear" = "front", except?: string): number | null {
  const taken = new Set<number>();
  for (const m of r.mounts) {
    if (m.face !== face || m.device === except) continue;
    for (let u = m.u; u < m.u + m.height; u++) taken.add(u);
  }
  for (let top = r.units; top >= height; top--) {
    let ok = true;
    for (let u = top - height + 1; u <= top; u++) if (taken.has(u)) ok = false;
    if (ok) return top - height + 1;
  }
  return null;
}

// What a new mount starts from: the catalog's plate for the device, its height
// and width, the first rack and the highest units free there.
export function mountPrefill(v: RacksView | null | undefined, device: string, rack?: string): Record<string, string> {
  const u = v?.unplaced.find((x) => x.device === device);
  const r = v?.racks.find((x) => x.name === rack) ?? v?.racks[0];
  const out: Record<string, string> = {};
  if (u?.suggestion) out.faceplate = u.suggestion;
  if (r) {
    out.rack = r.name;
    const height = u?.kind === "node" ? 2 : 1;
    out.height = String(height);
    const at = firstFree(r, height);
    if (at !== null) out.u = String(at);
  }
  if (u?.kind === "ap") out.width = "third";
  return out;
}

export function mountSteps(device: string, v: RacksView | null | undefined, rack?: string): Step[] {
  const step = fieldsStep({
    title: `rack-manager mount add '${device}'`,
    bin: RM,
    verb: "mount add",
    fixed: [device],
    kind: "mount",
    name: device,
    mode: "add",
    note: "Records where the device sits, in config/racks.json; the device and its record are not touched. The plate is the catalog's suggestion for its model unless you choose another; its ports are drawn with the topology's live state.",
  });
  return [{ ...step, prefill: mountPrefill(v, device, rack) }];
}

export function moveSteps(device: string): Step[] {
  return [
    fieldsStep({
      title: `rack-manager mount modify '${device}' — move it`,
      bin: RM,
      verb: "mount modify",
      fixed: [device],
      kind: "mount",
      name: device,
      mode: "modify",
      fields: ["rack", "u", "width", "slot", "face"],
      note: "A move is a new rack and unit (or column, or face); the check refuses a place another device takes.",
    }),
  ];
}

export function mountModifySteps(device: string): Step[] {
  return [fieldsStep({ title: `rack-manager mount modify '${device}'`, bin: RM, verb: "mount modify", fixed: [device], kind: "mount", name: device, mode: "modify" })];
}

export function unmountSteps(device: string): Step[] {
  return [{ title: `rack-manager mount remove '${device}'`, bin: RM, verb: "mount remove", fixed: [device], note: "The device leaves the rack drawing and goes to Unplaced; nothing else changes. A passive device's recorded cables go with it." }];
}

export function rackAddSteps(): Step[] {
  return [fieldsStep({ title: "rack-manager rack add", bin: RM, verb: "rack add", kind: "rack", name: null, mode: "add", note: "A rack in config/racks.json: its height in units, its width and how its units are numbered. Devices are mounted in it afterwards." })];
}

export function rackModifySteps(rack: string): Step[] {
  return [fieldsStep({ title: `rack-manager rack modify ${rack}`, bin: RM, verb: "rack modify", fixed: [rack], kind: "rack", name: rack, mode: "modify" })];
}

export function rackDeleteSteps(rack: string): Step[] {
  return [{ title: `rack-manager rack delete ${rack}`, bin: RM, verb: "rack delete", fixed: [rack], note: "Only an empty rack: move or unmount its devices first." }];
}

export function cableAddSteps(from: string): Step[] {
  return [
    {
      title: `rack-manager cable add --from '${from}'`,
      bin: RM,
      verb: "cable add",
      initial: { "--from": from, "--kind": "patch" },
      choices: { "--kind": ["patch", "uplink", "power"] },
      note: "Only a cable nothing can see: the ISP's modem, a patch panel, a PDU. A link the switches or LLDP see is drawn from the topology. A device only this cable names (the ISP's modem) takes its faceplate from --to-faceplate.",
    },
  ];
}

export function cableRemoveSteps(end: string): Step[] {
  return [{ title: `rack-manager cable remove '${end}'`, bin: RM, verb: "cable remove", fixed: [end] }];
}

// The rack actions on a device's side card: Mount… when it is mounted
// nowhere, else Move to… and Unmount….
export function MountActions({ device, v }: { device: string; v: RacksView | null | undefined }) {
  if (!v) return null;
  const mounted = v.racks.some((r) => r.mounts.some((m) => m.device === device));
  if (!mounted) {
    if (!v.racks.length) return <OperateButton label="Add a rack…" title="Add a rack" steps={rackAddSteps} />;
    return <OperateButton label="Mount…" title={`Mount ${device}`} steps={() => mountSteps(device, v)} />;
  }
  return (
    <>
      <OperateButton label="Move to…" title={`Move ${device}`} steps={() => moveSteps(device)} />
      <OperateButton label="Change mount…" title={`${device}'s mount`} steps={() => mountModifySteps(device)} hint="Its plate, label and place" />
      <OperateButton label="Unmount…" kind="danger" title={`Unmount ${device}`} steps={() => unmountSteps(device)} />
    </>
  );
}
