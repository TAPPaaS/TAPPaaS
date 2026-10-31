// layout.test.ts — where the Physical view draws things
// (web/src/physical/layout.ts): the locations one above the other, the primary
// first, and the rack unit or room a point of the drawing falls on.

import { PlacementInfo, PositionsView, RackInfo, RoomInfo } from "../../web/src/types";
import { R, dropTargetAt, layoutRacks, locationHeading } from "../../web/src/physical/layout";
import { check, done } from "./check";

const pm = (device: string, u: number, extra: Partial<PlacementInfo> = {}): PlacementInfo => ({
  device, kind: "switch", rack: "", room: "", u, height: 1, width: "full", slot: 0, face: "front", label: null, description: null, faceplate: null, suggested: false, plate: null, up: null, ...extra,
});
const rack = (name: string, room: string | null, units = 12, placements: PlacementInfo[] = []): RackInfo => ({ name, displayName: null, units, width: "19in", numbering: "bottom-up", room, description: null, placements });
const room = (name: string, location: string, racks: string[] = [], loose: PlacementInfo[] = []): RoomInfo => ({ name, displayName: null, description: null, location, recorded: true, racks, loose });

// The test system's shape: a primary with a rack room, a backup site.
const v: PositionsView = {
  locations: [
    { name: "home", displayName: "Home", kind: "site", primary: true, place: { address: "Vej 95", city: "Birkerød", country: "DK" }, rooms: ["basement"], unplaced: [] },
    { name: "cabin", displayName: null, kind: "remote", primary: false, place: { address: "Hareskov 1", city: "Værløse", country: null }, rooms: ["shed"], unplaced: ["far"] },
  ],
  racks: [rack("rack1", "basement", 12, [pm("sw1", 12), pm("node1", 9, { kind: "node", height: 2 })]), rack("rack2", "basement", 6), rack("rack3", "shed", 6)],
  rooms: [room("basement", "home", ["rack1", "rack2"]), room("shed", "cabin", ["rack3"])],
  unplaced: [{ device: "far", kind: "machine", vendor: null, model: null, suggestion: null, location: "cabin" }],
  cables: [],
  outside: [],
  findings: [],
};
const L = layoutRacks(v);
const at = (name: string) => L.racks.find((r) => r.r.name === name)!;
const [home, cabin] = L.locations;

// Locations one above the other.
check(home.name === "home" && cabin.name === "cabin", "the primary first");
check(cabin.y >= home.y + home.h && cabin.x === home.x, `stacked: the second below the first (${home.y}+${home.h} ≤ ${cabin.y})`);
check(home.w === cabin.w, "one width for the stack");
check(at("rack3").y > home.y + home.h && at("rack1").y < home.y + home.h, "each rack in its own location's area");
check(at("rack1").y === at("rack2").y && at("rack2").x > at("rack1").x, "a room's racks side by side");
check(L.height >= cabin.y + cabin.h && L.width >= cabin.x + cabin.w, "the drawing holds them all");
check(L.fitH === home.y + home.h + 4, "fit shows the first location");
check(cabin.nowhereY > home.y + home.h && cabin.nowhere[0]?.device === "far", "what is placed nowhere stands in its own location");

// The headings.
check(home.title === "Home" && home.sub === "Vej 95, Birkerød, DK · the primary location", `the primary: its address, then "the primary location" (${home.sub})`);
check(cabin.title === "cabin" && cabin.sub === "Hareskov 1, Værløse", `another location: its name and address, nothing more (${cabin.sub})`);
check(locationHeading({ name: "x", displayName: null, primary: false, place: null }).sub === "", "no address: the name alone");

// A plate at its unit in a rack of a later location.
const s = rack("r", "shed", 6, [pm("x", 6)]);
const L2 = layoutRacks({ ...v, racks: [...v.racks.slice(0, 2), s], rooms: [v.rooms![0], room("shed", "cabin", ["r"])] });
const x = L2.placed.find((p) => p.device === "x")!;
check(x.box.y === L2.racks.find((r) => r.r.name === "r")!.y + 1, "a plate at its rack's own height");

// A rack in no room: below the locations, in no area.
const none = layoutRacks({ ...v, racks: [...v.racks, rack("spare", null, 6)] });
const spare = none.racks.find((r) => r.r.name === "spare")!;
check(spare.y > none.locations[1].y + none.locations[1].h && none.height >= spare.y + 6 * R.u, "a rack in no room below the locations");

// No locations recorded: the rooms alone, no area.
const bare = layoutRacks({ ...v, locations: undefined });
check(bare.locations.length === 0 && bare.rooms.length === 2 && bare.racks.length === 3, "no location: the rooms are still drawn");

// The drop targets read the layout.
const r1 = at("rack1");
const t = dropTargetAt(L, r1.x + R.rail + 220, r1.y + 2.5 * R.u, 0);
check(!!t && "rack" in t && t.rack === "rack1" && t.row === 2 && Math.abs(t.across - 0.5) < 0.001, "a point on a rack: its row and the fraction across");
const t3 = at("rack3");
const far = dropTargetAt(L, t3.x + R.rail + 10, t3.y + 0.5 * R.u, 0);
check(!!far && "rack" in far && far.rack === "rack3" && far.row === 0, "a rack in a lower location: the row from its own top");
const held = dropTargetAt(L, r1.x + 30, r1.y + 2.5 * R.u, 1);
check(!!held && "rack" in held && held.row === 1, "the grab offset comes off the row");
const shed = L.rooms.find((m) => m.name === "shed")!;
const inShed = dropTargetAt(L, shed.x + 4, shed.y + 4, 0);
check(!!inShed && "room" in inShed && inShed.room === "shed", "a point in a room's area outside its racks: the room");
check(dropTargetAt(L, shed.x + 4, shed.y - 6, 0) === null, "the space between locations takes nothing");

done("layout");
