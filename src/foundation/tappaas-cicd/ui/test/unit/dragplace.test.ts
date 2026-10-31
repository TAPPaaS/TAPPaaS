// dragplace.test.ts — a device dragged in the Physical view
// (web/src/physical/dragplace.ts): what it is, whether a rack's units or a
// room take it (inside the rack, free, at its location), and the argv a drop
// runs: place for a device placed nowhere, place modify for a placed one.

import { PlacementInfo, PositionsView, RackInfo } from "../../web/src/types";
import { draggedOf, dropAt, dropArgv, dropLanded, dropPending, placesFor, prefillSize, rowOf, unitAt } from "../../web/src/physical/dragplace";
import { check, done } from "./check";

const pm = (device: string, u: number, height = 1, extra: Partial<PlacementInfo> = {}): PlacementInfo => ({
  device, kind: "switch", rack: "rack1", room: "server", u, height, width: "full", slot: 0, face: "front", label: null, description: null, faceplate: null, suggested: false, plate: null, up: null, ...extra,
});
const rack = (name: string, units: number, placements: PlacementInfo[], extra: Partial<RackInfo> = {}): RackInfo => ({ name, displayName: null, units, width: "19in", numbering: "bottom-up", room: "server", description: null, placements, ...extra });

const v: PositionsView = {
  locations: [
    { name: "home", displayName: null, kind: "site", primary: true, place: null, rooms: ["server", "closet"], unplaced: ["node9", "ap1", "modem"] },
    { name: "cabin", displayName: null, kind: "site", primary: false, place: null, rooms: ["shed"], unplaced: ["far"] },
  ],
  racks: [
    rack("rack1", 12, [pm("sw1", 12), pm("node1", 9, 2, { kind: "node" }), pm("rearpdu", 1, 1, { face: "rear" }), pm("ap0", 5, 1, { kind: "ap", width: "third", slot: 1 })]),
    rack("rack2", 6, [], { numbering: "top-down" }),
    rack("rack3", 6, [], { room: "shed" }),
  ],
  rooms: [
    { name: "server", displayName: "Server room", description: null, location: "home", recorded: true, racks: ["rack1", "rack2"], loose: [] },
    { name: "closet", displayName: null, description: null, location: "home", recorded: true, racks: [], loose: [pm("ups", 0, 2, { kind: "device", rack: "" })] },
    { name: "shed", displayName: null, description: null, location: "cabin", recorded: true, racks: ["rack3"], loose: [] },
    { name: "attic", displayName: null, description: null, location: "home", recorded: false, racks: [], loose: [] },
  ],
  unplaced: [
    { device: "node9", kind: "node", vendor: null, model: null, suggestion: "minisforum/ms-01", location: "home" },
    { device: "ap1", kind: "ap", vendor: null, model: null, suggestion: null, location: "home" },
    { device: "modem", kind: "device", seen: true, vendor: null, model: null, suggestion: null, location: "home" },
    { device: "far", kind: "machine", vendor: null, model: null, suggestion: null, location: "cabin" },
  ],
  cables: [],
  outside: [],
  findings: [],
};
const r1 = v.racks[0];
// The row of a unit in a bottom-up rack of 12: U12 is the top row.
const row = (u: number) => rowOf(r1, u);

// Rows and units, both numberings.
check(rowOf(r1, 12) === 0 && unitAt(r1, 0) === 12 && unitAt(r1, 11) === 1, "bottom-up: U12 is the top row, U1 the bottom one");
check(rowOf(v.racks[1], 1) === 0 && unitAt(v.racks[1], 5) === 6, "top-down: U1 is the top row");
check(prefillSize("node").height === 2 && prefillSize("ap").width === "third" && prefillSize("switch").height === 1 && prefillSize("switch").width === "full", "the Place… form's sizes: a node 2U, an access point a third wide, else 1U full");

// What is dragged.
const n9 = draggedOf(v, "node9")!;
check(!!n9 && n9.from === null && n9.height === 2 && n9.faceplate === "minisforum/ms-01" && n9.location === "home", "an unplaced node: 2U, placed nowhere, the catalog's plate, its location");
const sw1 = draggedOf(v, "sw1")!;
check(!!sw1 && sw1.from !== null && "rack" in sw1.from && sw1.from.rack === "rack1" && sw1.from.u === 12 && sw1.location === "home", "a placed switch: its rack and unit, the rack's location");
const ups = draggedOf(v, "ups")!;
check(!!ups && ups.from !== null && "room" in ups.from && ups.from.room === "closet" && ups.height === 2, "a device loose in a room: from the room, its plate's height");
check(draggedOf(v, "rearpdu") === null, "a rear-facing device is not dragged (it is not drawn)");
check(draggedOf(v, "modem") === null, "a seen device is recorded first, not dragged");
check(draggedOf(v, "nothing") === null, "an unknown device: nothing to drag");

// Placing an unplaced node: free units, the argv the Place… form would run.
const ok = dropAt(v, n9, { rack: "rack1", row: row(4), across: 0.5 });
check(ok.ok && ok.u === 3 && ok.rows![0] === row(4) && ok.rows![1] === row(3), `U3–4 of rack1 free for a 2U node (${ok.text})`);
check(JSON.stringify(ok.argv) === JSON.stringify(["asset-manager", "place", "node9", "--rack", "rack1", "--u", "3", "--height", "2", "--faceplate", "minisforum/ms-01"]), `place --rack --u --height --faceplate (${ok.argv?.join(" ")})`);
// Overlap: node1 holds U9–10.
const hit = dropAt(v, n9, { rack: "rack1", row: row(11), across: 0.5 });
check(!hit.ok && !hit.same && /overlaps node1/.test(hit.text) && hit.argv === undefined, `U10–11 overlaps node1 (${hit.text})`);
// Does not fit: its top past the top of the rack, or its bottom past the bottom.
const over = dropAt(v, n9, { rack: "rack1", row: -1, across: 0.5 });
check(!over.ok && /does not fit/.test(over.text) && over.rows![0] === 0, `a run past the top does not fit, the highlight clipped (${over.text})`);
const under = dropAt(v, n9, { rack: "rack1", row: 11, across: 0.5 });
check(!under.ok && /does not fit/.test(under.text) && under.rows![1] === 11, `a 2U run from the bottom row does not fit (${under.text})`);
// A rear-facing device does not take the front.
check(dropAt(v, n9, { rack: "rack1", row: row(2), across: 0 }).ok, "the rear-facing PDU at U1 leaves the front's U1–2 free");
// Another location's rack, and a room that is not recorded.
const far = dropAt(v, n9, { rack: "rack3", row: 0, across: 0 });
check(!far.ok && /at cabin/.test(far.text), `a rack at another location refuses (${far.text})`);
check(!dropAt(v, n9, { room: "attic" }).ok, "a room that is not recorded refuses");
const room = dropAt(v, n9, { room: "closet" });
check(room.ok && JSON.stringify(room.argv) === JSON.stringify(["asset-manager", "place", "node9", "--room", "closet", "--faceplate", "minisforum/ms-01"]), `loose in a room: place --room (${room.argv?.join(" ")})`);
check(placesFor(v, "far").racks.map((r) => r.name).join() === "rack3" && dropAt(v, draggedOf(v, "far")!, { rack: "rack3", row: 0, across: 0 }).ok, "a device at the other location: its own rack takes it");

// A third-wide access point: its column from where the pointer is; ap0 holds column 2 of U5.
const ap1 = draggedOf(v, "ap1")!;
const col2 = dropAt(v, ap1, { rack: "rack1", row: row(5), across: 0.5 });
check(!col2.ok && /overlaps ap0/.test(col2.text), "column 2 of U5 overlaps ap0");
const col3 = dropAt(v, ap1, { rack: "rack1", row: row(5), across: 0.9 });
check(col3.ok && col3.slot === 2 && JSON.stringify(col3.argv) === JSON.stringify(["asset-manager", "place", "ap1", "--rack", "rack1", "--u", "5", "--height", "1", "--width", "third", "--slot", "2"]), `column 3 of U5 is free: --width third --slot 2 (${col3.argv?.join(" ")})`);
check(!dropAt(v, n9, { rack: "rack1", row: row(5), across: 0 }).ok, "a full-width device overlaps a third-wide one at its units");

// Moving a placed device.
const same = dropAt(v, sw1, { rack: "rack1", row: 0, across: 0.3 });
check(!same.ok && same.same, "where it already is: nothing to do, no red");
const down = dropAt(v, sw1, { rack: "rack1", row: row(7), across: 0.3 });
check(down.ok && JSON.stringify(down.argv) === JSON.stringify(["asset-manager", "place", "modify", "sw1", "--set", "u=7"]), `in its rack: place modify --set u= (${down.argv?.join(" ")})`);
const n1 = draggedOf(v, "node1")!;
check(dropAt(v, n1, { rack: "rack1", row: row(11), across: 0 }).ok, "a device moved one unit up overlaps only itself");
const other = dropAt(v, sw1, { rack: "rack2", row: 0, across: 0 });
check(other.ok && other.u === 1 && JSON.stringify(other.argv) === JSON.stringify(["asset-manager", "place", "modify", "sw1", "--set", "rack=rack2", "--set", "u=1"]), `to another rack (top-down, top row U1): --set rack= --set u= (${other.argv?.join(" ")})`);
const loose = dropAt(v, sw1, { room: "closet" });
check(loose.ok && JSON.stringify(loose.argv) === JSON.stringify(["asset-manager", "place", "modify", "sw1", "--set", "room=closet"]), "into a room: --set room=");
check(!dropAt(v, sw1, { room: "shed" }).ok, "a room at another location refuses");
check(dropAt(v, ups, { room: "closet" }).same, "a loose device dropped on its own room: nothing to do");
const in2 = dropAt(v, ups, { rack: "rack2", row: 0, across: 0 });
check(in2.ok && JSON.stringify(in2.argv) === JSON.stringify(["asset-manager", "place", "modify", "ups", "--set", "rack=rack2", "--set", "u=1"]), `out of a room into a rack: --set rack= --set u= (${in2.argv?.join(" ")})`);
const apMove = dropArgv(draggedOf(v, "ap0")!, { rack: "rack1", u: 5, slot: 0 });
check(JSON.stringify(apMove) === JSON.stringify(["asset-manager", "place", "modify", "ap0", "--set", "u=5", "--set", "slot=0"]), "a third-wide device to another column: --set slot=");

// A drop on its way: until its job has ended and the positions show it there.
const moved: PositionsView = { ...v, racks: [{ ...r1, placements: r1.placements.map((m) => (m.device === "sw1" ? { ...m, u: 7 } : m)) }, ...v.racks.slice(1)] };
const job = (state: "queued" | "running" | "done" | "refused", exit: number | null = null, extra = {}) => ({ state, exit, ended: state === "done" ? "2026-10-31T10:00:10Z" : null, ...extra });
const before = { at: "2026-10-31T10:00:00Z", error: null };
const after = { at: "2026-10-31T10:00:20Z", error: null };
check(dropLanded(moved, "sw1", down) && !dropLanded(v, "sw1", down), "landed: the positions show it at the dropped unit");
check(dropLanded({ ...v, rooms: v.rooms!.map((x) => (x.name === "closet" ? { ...x, loose: [...x.loose, pm("sw1", 0)] } : x)) }, "sw1", loose) && !dropLanded(v, "sw1", loose), "landed: loose in the dropped room");
check(dropPending(v, "sw1", down, null, before) && dropPending(v, "sw1", down, job("queued"), before) && dropPending(v, "sw1", down, job("running"), before), "pending while the job starts, waits and runs");
check(dropPending(v, "sw1", down, job("done", 0), before), "pending after a good job while the read is from before its end");
check(!dropPending(moved, "sw1", down, job("done", 0), before), "over once the positions show it");
check(!dropPending(v, "sw1", down, job("done", 0), after), "over on a read after the job's end that has it elsewhere");
check(!dropPending(v, "sw1", down, job("done", 0), { at: before.at, error: "topology failed" }), "over when the read failed");
check(!dropPending(v, "sw1", down, job("done", 1), before) && !dropPending(v, "sw1", down, job("refused"), before), "over when the job failed or was refused");
check(!dropPending(v, "sw1", down, job("done", 0, { cancelled: { by: "x", at: "", was: "running", signals: [] } }), before), "over when the job was stopped");

done("dragplace");
