// layout.test.ts — where the Physical view draws things
// (web/src/physical/layout.ts): the locations one above the other, the primary
// first, each room as big as what it holds, the small ones stacked beside the
// racks, and the rack unit or room a point of the drawing falls on.

import { PlacementInfo, PositionsView, RackInfo, RoomInfo } from "../../web/src/types";
import { R, arrangeRooms, dropTargetAt, inner, layoutRacks, locationHeading, roomSize } from "../../web/src/physical/layout";
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

// A room's size follows what it holds.
const sized = (name: string, racks: RackInfo[], loose: PlacementInfo[] = []) => roomSize(room(name, "home", racks.map((r) => r.name), loose), racks);
const one = sized("closet", [], [pm("sw2", 0)]);
const main = sized("basement", [rack("a", "basement"), rack("b", "basement")]);
check(one.w === 320 + 2 * R.roomPad && one.h === R.roomHead + R.u + R.roomPad, `one switch: a small box (${one.w}×${one.h})`);
check(sized("attic", [], [pm("ap1", 0, { kind: "ap", width: "third" })]).w === 130 + 2 * R.roomPad, "one access point: smaller still");
check(main.w === 2 * (R.w19 + 2 * R.rail) + R.gap + 2 * R.roomPad && main.h === R.rackHead + 12 * R.u + R.roomPad, `two racks: as wide as they need (${main.w}×${main.h})`);
check(sized("a-rather-long-name-for-a-room-that-is-empty", []).w > R.roomMinW && sized("e", []).h === R.roomMinH, "an empty room: as wide as its title, still a drop target");
check(sized("x", [rack("a", "x", 6)], [pm("u", 0, { height: 2 })]).w === inner(rack("a", "x")) + 2 * R.rail + R.gap + 320 + 2 * R.roomPad, "a rack room with loose plates: the column beside the racks");

// The rooms' arrangement.
const big = { w: 1000, h: 400, racks: true };
const small = { w: 300, h: 120, racks: false };
const a1 = arrangeRooms([small, big, small, { ...big, w: 500, h: 300 }]);
check(a1.at[1].x === 0 && a1.at[3].x === 1000 + R.roomGap && a1.at[1].y === 0 && a1.at[3].y === 0, "the rooms with racks side by side, first");
check(a1.at[0].x === 1500 + 2 * R.roomGap && a1.at[2].x === a1.at[0].x && a1.at[0].y === 0 && a1.at[2].y === 120 + R.stackGap, "the small ones stacked in a column beside them");
check(a1.w === 1800 + 2 * R.roomGap && a1.h === 400, `its size (${a1.w}×${a1.h})`);
const tall = arrangeRooms([big, small, small, small, small]);
check(tall.at[1].x === tall.at[3].x && tall.at[3].y > 0 && tall.at[4].x > tall.at[1].x && tall.at[4].y === 0, "a column as tall as the rack row, then the next");
check(tall.h === 400, "columns stay within the rack row");
const smalls = arrangeRooms([small, { ...small, w: 200 }]);
check(smalls.at[0].x === 0 && smalls.at[1].x === 300 + R.roomGap && smalls.h === 120 && smalls.w === 500 + R.roomGap, "no rack room: the small ones side by side");
check(JSON.stringify(arrangeRooms([])) === JSON.stringify({ at: [], w: 0, h: 0 }), "no room: nothing");
check(JSON.stringify(arrangeRooms([big, small])) === JSON.stringify(arrangeRooms([big, small])), "deterministic");
const hugeSmall = arrangeRooms([{ ...big, h: 100 }, small]);
check(hugeSmall.at[1].y === 0 && hugeSmall.h === 120, "a small room taller than the rack row still stands");

// The drawing, on the test system's shape: nothing overlaps, each thing in its room.
const inside = (a: { x: number; y: number; w: number; h: number }, b: { x: number; y: number; w: number; h: number }) => a.x >= b.x && a.y >= b.y && a.x + a.w <= b.x + b.w && a.y + a.h <= b.y + b.h;
const apart = (a: { x: number; y: number; w: number; h: number }, b: { x: number; y: number; w: number; h: number }) => a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y;
const site: PositionsView = {
  ...v,
  locations: [{ ...v.locations![0], rooms: ["office", "basement", "attic", "hall"] }, v.locations![1]],
  rooms: [room("office", "home", [], [pm("sw3", 0)]), room("basement", "home", ["rack1", "rack2"]), room("attic", "home", [], [pm("ap1", 0, { kind: "ap", width: "third" })]), room("hall", "home"), v.rooms![1]],
};
const S = layoutRacks(site);
for (const a of S.rooms) for (const b of S.rooms) if (a !== b) check(apart(a, b), `rooms ${a.name} and ${b.name} do not overlap`);
const areaOf = (n: string) => S.rooms.find((m) => m.name === n)!;
const b0 = areaOf("basement");
check(b0.w === 2 * R.w19 + 4 * R.rail + 2 * R.roomPad + R.gap && areaOf("office").x > b0.x + b0.w, "the rack room first, the small ones beside it");
check(areaOf("attic").x === areaOf("office").x && areaOf("attic").y > areaOf("office").y && areaOf("office").h < 100, "a small room is a small box, stacked under the next");
for (const m of S.rooms) check(inside(m, S.locations.find((l) => (site.locations!.find((x) => x.name === l.name)!.rooms).includes(m.name))!), `room ${m.name} inside its location`);
for (const r of S.racks) check(inside({ x: r.x, y: r.y, w: inner(r.r) + 2 * R.rail, h: r.r.units * R.u }, S.rooms.find((m) => site.rooms!.find((x) => x.name === m.name)!.racks.includes(r.r.name))!), `rack ${r.r.name} inside its room`);
const sw3 = S.placed.find((p) => p.device === "sw3")!;
check(inside(sw3.box, areaOf("office")), "a loose plate inside its room");
const d3 = dropTargetAt(S, areaOf("attic").x + 4, areaOf("attic").y + 4, 0);
check(!!d3 && "room" in d3 && d3.room === "attic", "a stacked room takes a drop");
const between = dropTargetAt(S, areaOf("office").x + 4, areaOf("office").y + areaOf("office").h + R.stackGap / 2, 0);
check(between === null, "the gap between stacked rooms takes nothing");
const r2 = S.racks.find((r) => r.r.name === "rack2")!;
const d4 = dropTargetAt(S, r2.x + 40, r2.y + 3.5 * R.u, 0);
check(!!d4 && "rack" in d4 && d4.rack === "rack2" && d4.row === 3, "a rack's units beside the small rooms take a drop");

done("layout");
