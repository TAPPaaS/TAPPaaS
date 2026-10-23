// physical.test.ts — the recorded devices, rooms, patch panels and cable
// segments of config/positions.json: the verbs, the whole-document check and the
// view the topology carries, over hrossen's topology
// (test/fixtures/topology-hrossen.json). Offline; the catalog is in memory.
//
// Run: RM_FIXTURE_DIR=<position-manager>/test/fixtures node physical.test.js

import { readFileSync } from "fs";
import { join } from "path";
import { addCable, addDevice, placeDevice, addRack, addRoom, deleteRack, deleteRoom, joinCable, modifyDevice, modifyPlacement, modifyRack, removeDevice, splitCable } from "../../src/verbs";
import { Faceplate, PositionsDoc, SiteLocs, TopoLike, checkPositions, placementsOf, recordedPlate, resolvePositions, seenCables, siteDevices } from "../../../../lib/ts/src/positions";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ok: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}
type R = { doc: PositionsDoc } | { refused: string };
const ok = (r: R): r is { doc: PositionsDoc } => "doc" in r;
const refused = (r: R, needle: string): boolean => "refused" in r && r.refused.includes(needle);
const doc = (r: R): PositionsDoc => {
  if (!ok(r)) throw new Error(`refused: ${r.refused}`);
  return r.doc;
};
const errs = (d: PositionsDoc) => checkPositions(d, catalog, devices).filter((f) => f.severity === "error").map((f) => f.message);
const warns = (d: PositionsDoc) => checkPositions(d, catalog, devices).filter((f) => f.severity === "warn").map((f) => f.message);

const t = JSON.parse(readFileSync(join(process.env.RM_FIXTURE_DIR ?? "test/fixtures", "topology-hrossen.json"), "utf8")) as TopoLike;
const devices = siteDevices(t);
const seen = devices.map((x) => x.name);
const USW = "USW Pro XG 10 PoE";
const modem: Faceplate = { key: "generic/isp-modem", vendor: "Generic", model: "ISP modem", kind: "modem", units: 1, width: "half", passive: true, rows: [[{ name: "WAN", kind: "rj45" }, { name: "LAN 1", kind: "rj45" }]] };
const patch24: Faceplate = { key: "generic/patch-panel-24", vendor: "Generic", model: "24-port patch panel", kind: "patch-panel", units: 1, width: "full", passive: true, rows: [Array.from({ length: 24 }, (_, i) => ({ name: String(i + 1), kind: "rj45" as const }))] };
const catalog = [modem, patch24];

console.log("— recorded devices");
let d: PositionsDoc = doc(addRack({}, "rack1", {}));
check(refused(addDevice(d, "tappaas1", { kind: "other", ports: 1 }, catalog, seen), "sees a device"), "a device the topology sees is not recorded");
check(refused(addDevice(d, "ups1", { kind: "battery", ports: 2 }, catalog, seen), "--kind"), "an unknown kind is refused");
check(refused(addDevice(d, "ups1", { kind: "ups" }, catalog, seen), "its ports"), "a device needs ports or a model");
check(refused(addDevice(d, "ont1", { kind: "ont", model: "acme/nope" }, catalog, seen), "not in the catalog"), "a model the catalog lacks is refused");
d = doc(addDevice(d, "ups1", { kind: "ups", ports: 4, displayName: "Basement UPS" }, catalog, seen));
check(d.devices!.ups1.ports!.join(",") === "1,2,3,4" && d.devices!.ups1.displayName === "Basement UPS", "device add --ports 4: ports 1 to 4");
check(refused(addDevice(d, "ups1", { kind: "ups", ports: 1 }, catalog, seen), "already recorded"), "a second record of a name is refused");
d = doc(addDevice(d, "ont1", { kind: "ont", port: ["PON", "LAN"] }, catalog, seen));
check(recordedPlate("ont1", d.devices!.ont1, catalog).width === "half" && recordedPlate("ont1", d.devices!.ont1, catalog).rows[0].map((p) => p!.name).join() === "PON,LAN", "an ONT's plate: half width, its named ports");
check(errs(d).length === 0, "the document with recorded devices is valid");
check(ok(modifyDevice(d, "ups1", [["ports", "6"]], catalog)) && doc(modifyDevice(d, "ups1", [["ports", "6"]], catalog)).devices!.ups1.ports!.length === 6, "device modify: a port count");
check(refused(modifyDevice(d, "ups1", [["name", "x"]], catalog), "how cables and its placement name it"), "device modify: the name is refused");
const withCable = doc(addCable(d, { device: "ont1", port: "LAN" }, { device: USW, port: "5" }, "uplink"));
check(errs(withCable).length === 0, "a recorded device's port is a valid cable end");
check(refused(removeDevice(withCable, "ont1"), "cable remove"), "device remove: refused while a cable names it");
check(ok(removeDevice(d, "ont1")), "device remove: a device nothing names");
check(errs({ ...withCable, cables: [{ from: { device: "ont1", port: "WAN" }, to: { device: USW, port: "5" }, kind: "uplink" }] }).some((m) => m.includes("ont1 has no port WAN")), "a port the record lacks is refused");

console.log("— the ISP modem: from a name on a cable to a recorded device");
const legacy: PositionsDoc = { version: 1, racks: d.racks, cables: [{ from: { device: USW, port: "5" }, to: { device: "ISP modem", port: "LAN 1", faceplate: "generic/isp-modem" }, kind: "uplink", label: "ISP hand-off" }] };
check(errs(legacy).length === 0 && warns(legacy).some((m) => m.includes("ISP modem is neither seen by the topology nor recorded") && m.includes("device add 'ISP modem' --kind") && m.includes("--model generic/isp-modem")), "validate tells the operator the modem is only a name on a cable, and how to record it");
check(resolvePositions(legacy, catalog, t).outside.some((o) => o.device === "ISP modem"), "before: placed beside the racks by its cable");
const migrated = doc(addDevice(legacy, "ISP modem", { kind: "modem", model: "generic/isp-modem" }, catalog, seen));
check(JSON.stringify(migrated.cables) === JSON.stringify(legacy.cables), "the cable is unchanged");
check(errs(migrated).length === 0 && !warns(migrated).some((m) => m.includes("neither seen")), "after: valid, and no warning");
const v = resolvePositions(migrated, catalog, t);
check(!v.outside.some((o) => o.device === "ISP modem") && v.unplaced.some((u) => u.device === "ISP modem" && u.recorded === "modem" && u.suggestion === "generic/isp-modem"), "after: a device like any other, mounted nowhere yet, its model the plate to mount");
check(v.cables.some((c) => c.source === "recorded" && c.to.device === "ISP modem" && c.zones.includes("wan")), "its cable still carries port 5's zone");
const t2: TopoLike = { ...t, devices: [...(t.devices ?? []), { name: "ISP modem", kind: "modem", recorded: true, ports: ["WAN", "LAN 1"] }] };
check(siteDevices(t2).find((x) => x.name === "ISP modem")?.recorded === "modem", "the topology's devices carry it as recorded, with its kind");

console.log("— rooms");
let r: PositionsDoc = doc(addRack({}, "rack1", { room: "basement" }));
check(errs(r).length === 0 && warns(r).some((m) => m.includes("room 'basement' is not recorded")), "a rack's room as free text: valid, with a note until the room is recorded");
check(resolvePositions(r, catalog, t).rooms.some((x) => x.name === "basement" && !x.recorded && x.racks.join() === "rack1"), "…and drawn as a room all the same");
check(refused(addRoom(r, "Basement", {}), "must match"), "a room name is lower case");
r = doc(addRoom(r, "basement", { displayName: "Basement" }));
check(!warns(r).some((m) => m.includes("not recorded")), "recorded: the rack's room is a reference now");
r = doc(addDevice(r, "ISP modem", { kind: "modem", model: "generic/isp-modem" }, catalog, seen));
check(refused(placeDevice(r, "ISP modem", { room: "attic" }, catalog), "room attic does not exist"), "mount --room: the room must exist");
check(refused(placeDevice(r, "ISP modem", { room: "basement", rack: "rack1", u: 3 }, catalog), "no --rack"), "mount --room takes no rack and no unit");
r = doc(placeDevice(r, "ISP modem", { room: "basement", faceplate: "generic/isp-modem" }, catalog));
check(r.placements!["ISP modem"].room === "basement" && r.placements!["ISP modem"].rack === undefined && r.placements!["ISP modem"].u === undefined && errs(r).length === 0, "mount add --room: loose in the room, valid");
const rv = resolvePositions(r, catalog, t);
const base = rv.rooms.find((x) => x.name === "basement")!;
check(base.recorded && base.displayName === "Basement" && base.racks.join() === "rack1" && base.loose.map((m) => m.device).join() === "ISP modem" && base.loose[0].plate?.key === "generic/isp-modem", "the view: the room with its rack and its loose modem, drawn with its plate");
check(!rv.unplaced.some((u) => u.device === "ISP modem"), "a loose device is placed");
check(refused(deleteRoom(r, "basement"), "still holds rack rack1, ISP modem"), "room delete: refused while it holds a rack or a device");
const moved = doc(modifyPlacement(r, "ISP modem", [["rack", "rack1"], ["u", "5"]], catalog));
check(moved.placements!["ISP modem"].rack === "rack1" && moved.placements!["ISP modem"].room === undefined, "mount modify: from loose into a rack");
check(refused(modifyPlacement(r, "ISP modem", [["rack", "rack1"]], catalog), "give its unit"), "…a rack needs a unit");
const back = doc(modifyPlacement(moved, "ISP modem", [["room", "basement"]], catalog));
check(back.placements!["ISP modem"].u === undefined && back.placements!["ISP modem"].room === "basement", "mount modify --set room: out of the rack, loose in the room");
check(errs({ ...r, placements: { ...r.placements, x: { height: 1, width: "full", face: "front" } } }).some((m) => m.includes("neither a rack nor a room")), "a mount in neither is refused by validate");
const old = { ...r, racks: { rack1: { ...r.racks!.rack1, building: "KnudAnchersVej" } }, rooms: { basement: { ...r.rooms!.basement, building: "House" } } } as PositionsDoc;
check(errs(old).length === 0, "a building recorded before is no error");
const migrated2 = doc(addRoom(old, "attic", {}));
check(!("building" in (migrated2.racks!.rack1 as object)) && !("building" in (migrated2.rooms!.basement as object)), "the next write drops a rack's and a room's building, silently (the site's location has it)");
const empty = doc(deleteRack(doc(modifyRack(r, "rack1", [["room", ""]])), "rack1"));
check(refused(deleteRoom(empty, "basement"), "ISP modem"), "a loose device keeps its room");

console.log("— patch panels");
let pp: PositionsDoc = doc(addRack({}, "rack1", {}));
pp = doc(addDevice(pp, "patch1", { kind: "patch-panel", ports: 24 }, catalog, seen));
pp = doc(addDevice(pp, "patch2", { kind: "patch-panel", model: "generic/patch-panel-24" }, catalog, seen));
pp = doc(placeDevice(pp, "patch1", { rack: "rack1", u: 30 }, catalog));
const pv = resolvePositions(pp, catalog, t).racks[0].mounts.find((m) => m.device === "patch1")!;
check(pv.recorded === "patch-panel" && pv.plate!.kind === "patch-panel" && pv.plate!.passive && pv.plate!.rows[0].length === 24, "a recorded panel by port count: a generic 24-port panel plate");
check(recordedPlate("patch2", pp.devices!.patch2, catalog).key === "generic/patch-panel-24", "a panel by model: the catalog's plate");
const front = doc(addCable(pp, { device: "tappaas2", port: "enp97s0" }, { device: "patch1", port: "1", side: "front" }, "patch"));
const both = doc(addCable(front, { device: "patch1", port: "1", side: "rear" }, { device: USW, port: "2" }, "patch"));
check(errs(both).length === 0, "a panel port takes one cable on its front and one on its rear");
check(refused(addCable(both, { device: "patch1", port: "1" }, { device: "tappaas3", port: "eno1" }, "patch"), "already uses"), "cable add: a side already taken is refused");
check(errs({ ...both, cables: [...both.cables!, { from: { device: "patch1", port: "1", side: "rear" }, to: { device: "tappaas3", port: "eno1" }, kind: "patch" }] }).some((m) => m.includes("patch1 port 1 (rear) already carries cable 2")), "validate refuses a panel port used twice on one side");
check(errs({ ...pp, cables: [{ from: { device: USW, port: "3", side: "rear" }, to: { device: "patch1", port: "4" }, kind: "patch" }] }).some((m) => m.includes("is no patch panel")), "a side on a port that is no panel's is refused");

console.log("— cable segments");
const wires = seenCables(t);
const sp = doc(splitCable(pp, { device: USW, port: "2" }, { device: "patch1", port: "1" }, wires));
check(sp.cables!.length === 2 && sp.cables!.every((c) => c.origin === "seen") && sp.cables![0].to.side === "front" && sp.cables![1].from.side === "rear" && sp.cables![1].to.device === "tappaas2", "cable split: the seen link USW:2 — tappaas2 becomes two segments, front and rear");
check(errs(sp).length === 0, "the split document is valid");
const sv = resolvePositions(sp, catalog, t).cables;
const one = sv.filter((c) => [c.from, c.to].some((e) => e.device === "tappaas2"));
check(one.length === 1 && one[0].source === "topology" && one[0].segments?.length === 2 && one[0].via?.[0].port === "1" && one[0].kind === "lan" && one[0].up === true, "the topology still has one link, its live state kept, its two wires and the panel port listed");
check(refused(splitCable(sp, { device: "tappaas2", port: "enp97s0" }, { device: "patch1", port: "2" }, wires), "already runs through"), "a link already through a panel is refused");
check(refused(splitCable(sp, { device: USW, port: "3" }, { device: "patch1", port: "1" }, wires), "choose a free panel port"), "a panel port in use is refused");
check(refused(splitCable(sp, { device: USW, port: "3" }, { device: USW, port: "4" }, wires), "no recorded patch panel"), "--via must be a recorded patch panel");
check(refused(splitCable(sp, { device: USW, port: "8" }, { device: "patch1", port: "5" }, wires), "no link on"), "a port with no link is refused");
const jn = doc(joinCable(sp, { device: "patch1", port: "1" }));
check((jn.cables ?? []).length === 0 && resolvePositions(jn, catalog, t).cables.filter((c) => c.to.device === "tappaas2" && !c.segments).length === 1, "cable join: the segments go, the topology's link is back as it was");
const isp = doc(addCable(doc(addDevice(pp, "ISP modem", { kind: "modem", model: "generic/isp-modem" }, catalog, seen)), { device: USW, port: "5" }, { device: "ISP modem", port: "LAN 1" }, "uplink", "ISP hand-off"));
const ispSplit = doc(splitCable(isp, { device: "ISP modem", port: "LAN 1" }, { device: "patch1", port: "3" }, wires));
check(ispSplit.cables!.length === 2 && ispSplit.cables!.every((c) => c.origin === "recorded" && c.label === "ISP hand-off"), "a recorded cable splits too, its kind and label on both segments");
check(resolvePositions(ispSplit, catalog, t).cables.some((c) => c.source === "recorded" && c.segments?.length === 2 && [c.from.device, c.to.device].sort().join() === `ISP modem,${USW}`), "…one recorded link with its two wires");
const rejoined = doc(joinCable(ispSplit, { device: USW, port: "5" }));
check(rejoined.cables!.length === 1 && rejoined.cables![0].label === "ISP hand-off" && [rejoined.cables![0].from.device, rejoined.cables![0].to.device].sort().join() === `ISP modem,${USW}` && !rejoined.cables![0].origin, "cable join from a device end: the recorded cable again");
check(refused(joinCable(isp, { device: USW, port: "5" }), "no link through a patch panel"), "join on a link that runs through no panel is refused");

console.log("— locations");
const sites: SiteLocs = { names: ["home", "hareskov", "fsn1"], primary: "home" };
const lerr = (x: PositionsDoc) => checkPositions(x, catalog, devices, sites).filter((f) => f.severity === "error").map((f) => f.message);
const lwarn = (x: PositionsDoc) => checkPositions(x, catalog, devices, sites).filter((f) => f.severity === "warn").map((f) => f.message);
let L: PositionsDoc = doc(addRoom({}, "basement", {}));
L = doc(addRoom(L, "shed", { location: "hareskov" }));
check(L.rooms!.basement.location === undefined && L.rooms!.shed.location === "hareskov", "room add --location: the room names its location; none is the primary");
check(lerr(doc(addRoom(L, "attic", { location: "mars" }))).some((m) => m.includes("location 'mars' is not one of the site's")), "a room at a location the site lacks is refused");
L = doc(addDevice(L, "ups2", { kind: "ups", ports: 2, location: "hareskov" }, catalog, seen));
check(L.devices!.ups2.location === "hareskov", "device add --location: recorded");
check(lerr(doc(placeDevice(L, "ups2", { room: "basement" }, catalog))).some((m) => m.includes("room basement is at home, the device is at hareskov")), "a device placed in a room at another location is refused");
check(lerr(doc(placeDevice(L, "ups2", { room: "shed" }, catalog))).length === 0, "…in a room at its own location it is valid");
check(lwarn(L).some((m) => m.startsWith("ups2 is at hareskov")) === false, "a device at a location with a room is not 'somewhere'");
const far = doc(addDevice(L, "ont9", { kind: "ont", ports: 1, location: "fsn1" }, catalog, seen));
check(lwarn(far).some((m) => m.startsWith("ont9 is at fsn1, which has no room")), "a device at a location with no room is pointed out, unplaced");
check(lerr(doc(addDevice(L, "ont8", { kind: "ont", ports: 1, location: "mars" }, catalog, seen))).some((m) => m.includes("device ont8: location 'mars'")), "a device at a location the site lacks is refused");
check(checkPositions(doc(placeDevice(L, "ups2", { room: "basement" }, catalog)), catalog, devices, null).every((f) => f.severity !== "error"), "without site.json the location rules are skipped");
check(refused(placeDevice(L, "ups2", { room: "shed", width: "half" }, catalog), "no height, width"), "a loose placement takes no width: its plate gives its size");
console.log("— the racks.json shape");
const racksJson = { racks: { rack1: { units: 42, width: "19in", numbering: "bottom-up", room: "basement" } }, rooms: { basement: {} }, mounts: { tappaas1: { rack: "rack1", u: 1, height: 2, width: "full", face: "front" }, "ISP modem": { room: "basement", height: 1, width: "third", face: "front", faceplate: "generic/isp-modem" } } } as unknown as PositionsDoc;
const pl = placementsOf(racksJson);
check(pl.tappaas1.height === 2 && pl["ISP modem"].room === "basement" && pl["ISP modem"].width === undefined && pl["ISP modem"].faceplate === "generic/isp-modem", "an unmigrated document's mounts read as placements, a loose one reduced");
const w = doc(addRoom(racksJson, "attic", {}));
check(w.placements!.tappaas1.u === 1 && (w as Record<string, unknown>).mounts === undefined && Object.keys(w)[0] === "version", "a write turns mounts into placements, in the schema's order");

console.log(`\nposition-manager physical: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
