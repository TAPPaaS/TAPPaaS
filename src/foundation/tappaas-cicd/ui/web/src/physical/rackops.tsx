// rackops.tsx — the changes the Physical view offers, as position-manager's own
// verbs: a room or a rack added, changed or deleted; a device placed in a rack
// or a room, moved or unplaced; a device nothing manages recorded, or one a
// switch port sees recorded from its port; a cable nothing can see recorded or
// removed. Each is a Step (operate.tsx): Change → Preview (--check) → Apply.
// Nothing here touches a device.

import { useRead } from "../api";
import { fieldsStep } from "../fields";
import { OperateButton, Step, Values } from "../operate";
import { ManifestVerb, PositionsView, RackInfo, TopoDevice } from "../types";

const RM = "position-manager";

// The highest free run of `height` units at full width on a face, as the rack
// numbers its units (the lowest unit of the run); null when none is free.
export function firstFree(r: RackInfo, height: number, face: "front" | "rear" = "front", except?: string): number | null {
  const taken = new Set<number>();
  for (const m of r.placements) {
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

// What a new placement starts from: the catalog's plate for the device, its
// height and width, the first rack and the highest units free there.
export function placePrefill(v: PositionsView | null | undefined, device: string, rack?: string): Record<string, string> {
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

// A placement's fields: in a rack, or loose in a room (its plate gives its size).
const IN_RACK = ["rack", "u", "height", "width", "slot", "face", "faceplate", "label", "description"];
const IN_ROOM = ["room", "faceplate", "label", "description"];

// Place…: one form, a rack and its units or a room. Switching between the two
// starts the fields again, so a rack's units never go with a room.
function PlaceWhere({ values, set, verb, rack, room, canRack, canRoom }: { values: Values; set: (v: Values) => void; verb: ManifestVerb; rack: Step; room: Step; canRack: boolean; canRoom: boolean }) {
  const where = values["@where"] === "room" || (!canRack && canRoom) ? "room" : "rack";
  const pick = (w: "rack" | "room") => set({ ...values, "@where": w, "@fields": [], "@classes": [] });
  return (
    <>
      <div className="seg" role="radiogroup" aria-label="where">
        <button type="button" role="radio" aria-checked={where === "rack"} className={where === "rack" ? "seg-on" : ""} disabled={!canRack} onClick={() => pick("rack")}>
          In a rack
        </button>
        <button type="button" role="radio" aria-checked={where === "room"} className={where === "room" ? "seg-on" : ""} disabled={!canRoom} onClick={() => pick("room")}>
          Loose in a room
        </button>
      </div>
      <div key={where}>{(where === "rack" ? rack : room).render!(values, set, verb)}</div>
    </>
  );
}

export function placeSteps(device: string, v: PositionsView | null | undefined, rack?: string): Step[] {
  const base = { title: `position-manager place '${device}'`, bin: RM, verb: "place", fixed: [device], kind: "placement", name: device, mode: "add" as const };
  const inRack = fieldsStep({ ...base, fields: IN_RACK });
  const inRoom = fieldsStep({ ...base, fields: IN_ROOM });
  const canRack = !!v?.racks.length;
  const canRoom = (v?.rooms ?? []).some((r) => r.recorded);
  return [
    {
      ...inRack,
      note: "Records where the device stands, in config/positions.json: in a rack at its units, or loose in a room (its plate gives its size). The device and its record are not touched. The plate is the catalog's suggestion for its model unless you choose another; its ports are drawn with the topology's live state.",
      render: (values, set, verb) => <PlaceWhere values={values} set={set} verb={verb} rack={inRack} room={inRoom} canRack={canRack} canRoom={canRoom} />,
      prefill: placePrefill(v, device, rack),
    },
  ];
}

// Move to…: a rack and its units, or a room (out of the rack, loose in it).
export function moveSteps(device: string, loose = false): Step[] {
  return [
    fieldsStep({
      title: `position-manager place modify '${device}' — move it`,
      bin: RM,
      verb: "place modify",
      fixed: [device],
      kind: "placement",
      name: device,
      mode: "modify",
      fields: loose ? ["room", "rack", "u"] : ["rack", "u", "width", "slot", "face", "room"],
      note: "A move is a new rack and unit (or column, or face), or a room: out of the rack, loose in it. The check refuses a place another device takes, and a room at another location than the device's.",
    }),
  ];
}

export function placementModifySteps(device: string): Step[] {
  return [fieldsStep({ title: `position-manager place modify '${device}'`, bin: RM, verb: "place modify", fixed: [device], kind: "placement", name: device, mode: "modify" })];
}

export function unplaceSteps(device: string): Step[] {
  return [{ title: `position-manager unplace '${device}'`, bin: RM, verb: "unplace", fixed: [device], note: "The device leaves its rack or room and goes to Unplaced, under its location; nothing else changes. A passive device's recorded cables go with it." }];
}

// Add a room: its name, location, display name and description (positions-fields' room).
export function roomAddSteps(): Step[] {
  return [fieldsStep({ title: "position-manager room add", bin: RM, verb: "room add", kind: "room", name: null, mode: "add", note: "A room in config/positions.json: where racks stand and devices stand loose, in one of the site's locations (the primary one unless you choose another). Racks and devices are placed in it afterwards." })];
}

export const RECORDED_KINDS = ["modem", "ont", "ups", "patch-panel", "other"];

// Record a device nothing manages: its kind, its model from the faceplate
// catalog (or typed), its ports (a count, or names), its location, how it is shown.
export function deviceAddSteps(models: string[], locations: string[]): Step[] {
  return [
    {
      title: "position-manager device add <name>",
      bin: RM,
      verb: "device add",
      only: ["--kind", "--model", "--ports", "--port", "--location", "--display-name", "--description"],
      choices: { "--kind": RECORDED_KINDS, ...(locations.length ? { "--location": locations } : {}) },
      suggest: { "--model": models },
      placeholders: { "--ports": "a count: 24", "--port": "a port's name: WAN, LAN 1, …", "--location": "the primary location" },
      note: "A device nothing manages — a modem, an ONT, a UPS, a patch panel — recorded with its kind and its ports (from its model, a count, or by name), at the primary location unless you choose another. It then stands unplaced under its location: Place… it in a rack or a room. A patch panel: place it in a rack, then select a wire and Attach to patch panel…. --check previews.",
    },
  ];
}

// A name for a seen device: what LLDP or its lease calls it, in the letters a
// device name takes.
export function seenName(d: TopoDevice): string {
  const raw = d.seen?.lldp?.name ?? d.seen?.lease?.hostname ?? d.displayName ?? "";
  return raw.replace(/[^A-Za-z0-9 ._-]+/g, "-").replace(/^[^A-Za-z0-9]+/, "").slice(0, 63);
}

// Record…: a device a switch port sees becomes a recorded one, with the port's cable.
export function deviceRecordSteps(d: TopoDevice, models: string[], locations: string[]): Step[] {
  const s = d.seen!;
  const target = s.mac ?? `${s.switch}:${s.port}`;
  return [
    {
      title: `position-manager device record '${target}'`,
      bin: RM,
      verb: "device record",
      fixed: [target],
      only: ["--name", "--kind", "--port", "--model", "--location", "--display-name", "--description"],
      initial: { "--name": seenName(d), "--kind": "other" },
      choices: { "--kind": RECORDED_KINDS, ...(locations.length ? { "--location": locations } : {}) },
      suggest: { "--model": models },
      placeholders: { "--port": s.lldp?.port ?? "1", "--location": d.location ?? "the switch's location" },
      note: `Records the device ${s.switch} port ${s.port} sees${s.mac ? ` (${s.mac})` : ""}: its MAC is kept so it is no longer listed as seen, and the port's link is recorded as its cable. It then stands unplaced under its location: Place… it.`,
    },
  ];
}

export function rackAddSteps(): Step[] {
  return [fieldsStep({ title: "position-manager rack add", bin: RM, verb: "rack add", kind: "rack", name: null, mode: "add", note: "A rack in config/positions.json: its height in units, its width, how its units are numbered and the room it stands in. Devices are placed in it afterwards." })];
}

export function rackModifySteps(rack: string): Step[] {
  return [fieldsStep({ title: `position-manager rack modify ${rack}`, bin: RM, verb: "rack modify", fixed: [rack], kind: "rack", name: rack, mode: "modify" })];
}

export function rackDeleteSteps(rack: string): Step[] {
  return [{ title: `position-manager rack delete ${rack}`, bin: RM, verb: "rack delete", fixed: [rack], note: "Only an empty rack: move or unplace its devices first." }];
}

export function cableAddSteps(from: string): Step[] {
  return [
    {
      title: `position-manager cable add --from '${from}'`,
      bin: RM,
      verb: "cable add",
      initial: { "--from": from, "--kind": "patch" },
      choices: { "--kind": ["patch", "uplink", "power"] },
      note: "Only a cable nothing can see: the ISP's modem, a patch panel, a PDU. A link the switches or LLDP see is drawn from the topology. A device only this cable names (the ISP's modem) takes its faceplate from --to-faceplate.",
    },
  ];
}

export function cableRemoveSteps(end: string): Step[] {
  return [{ title: `position-manager cable remove '${end}'`, bin: RM, verb: "cable remove", fixed: [end] }];
}

// Where a device is placed in the view: in a rack, loose in a room, or nowhere.
export function placedIn(v: PositionsView, device: string): "rack" | "room" | null {
  if (v.racks.some((r) => r.placements.some((m) => m.device === device))) return "rack";
  if ((v.rooms ?? []).some((r) => r.loose.some((m) => m.device === device))) return "room";
  return null;
}

// The placement actions on a device's side card: Place… when it is placed
// nowhere, else Move to…, Change placement… and Unplace….
export function PlaceActions({ device, v }: { device: string; v: PositionsView | null | undefined }) {
  if (!v) return null;
  const at = placedIn(v, device);
  if (!at) {
    const room = (v.rooms ?? []).some((r) => r.recorded);
    if (!v.racks.length && !room) return <OperateButton label="Add a room…" title="Add a room" steps={roomAddSteps} />;
    return <OperateButton label="Place…" title={`Place ${device}`} steps={() => placeSteps(device, v)} />;
  }
  return (
    <>
      <OperateButton label="Move to…" title={`Move ${device}`} steps={() => moveSteps(device, at === "room")} />
      <OperateButton label="Change placement…" title={`${device}'s placement`} steps={() => placementModifySteps(device)} hint="Its plate, label and place" />
      <OperateButton label="Unplace…" kind="danger" title={`Unplace ${device}`} steps={() => unplaceSteps(device)} />
    </>
  );
}

export function AddRoomButton({ kind }: { kind?: "primary" }) {
  return <OperateButton label="Add a room…" kind={kind} title="Add a room" steps={roomAddSteps} />;
}

// The catalog's models and the site's locations, for the record forms.
function useRecordChoices(): { models: string[]; locations: string[] } {
  const fp = useRead<{ key: string }[]>("faceplates", 600_000);
  const site = useRead<{ site?: { locations?: Record<string, unknown> } }>("site");
  return { models: (fp.env?.data ?? []).map((f) => f.key), locations: Object.keys(site.env?.data?.site?.locations ?? {}).sort() };
}

// Record a device…: the catalog's models as the model's suggestions.
export function RecordDeviceButton() {
  const { models, locations } = useRecordChoices();
  return <OperateButton label="Record a device…" title="Record a device nothing manages" steps={() => deviceAddSteps(models, locations)} />;
}

// Record… on a seen device's card.
export function RecordSeenButton({ d }: { d: TopoDevice }) {
  const { models, locations } = useRecordChoices();
  return <OperateButton label="Record…" kind="primary" title={`Record the device ${d.seen?.switch} port ${d.seen?.port} sees`} steps={() => deviceRecordSteps(d, models, locations)} />;
}

// The Physical view with nothing selected: what to do, in order.
export function PhysicalHowTo() {
  return (
    <aside className="sidepanel howto">
      <header>
        <h2>How to</h2>
      </header>
      <ol className="small">
        <li><b>Add a room</b> the hardware stands in, at one of the site's locations.</li>
        <li><b>Add a rack</b> to the room.</li>
        <li><b>Place</b> the devices the topology sees — nodes, switches, access points — from Unplaced: in a rack, or loose in a room.</li>
        <li><b>Record a device</b> nothing manages — a modem, an ONT, a UPS, a patch panel — then place it. A device a switch port sees is listed under its location: open it and Record… it.</li>
        <li><b>Record a cable</b> nothing sees: select a port, then Record a cable….</li>
        <li><b>Split a wire at a patch panel</b>: select the wire, then Attach to patch panel….</li>
      </ol>
      <p className="muted small">A click on a location, a room, a rack, a device or a wire opens its card here.</p>
    </aside>
  );
}
