// verbs.test.ts — what each position-manager verb does to config/positions.json, the
// whole-document check, and the view the topology carries, over hrossen's
// topology (test/fixtures/topology-hrossen.json, captured 2026-10-22).
// Offline: documents in, documents out; the catalog is in memory here
// (catalog.test.ts reads the real one).
//
// Run: RM_FIXTURE_DIR=<position-manager>/test/fixtures node verbs.test.js

import { readFileSync } from "fs";
import { join } from "path";
import { addCable, addMount, addRack, deleteRack, modifyMount, modifyRack, removeCable, removeMount } from "../../src/verbs";
import { CatalogPort, Faceplate, PositionsDoc, TopoLike, checkPositions, columnSpan, parseEnd, resolvePositions, seenCables, siteDevices, suggestFaceplate, unitAtRow } from "../../../../lib/ts/src/positions";

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
const ok = (r: unknown): r is { doc: PositionsDoc } => !!r && typeof r === "object" && "doc" in r;
const refused = (r: unknown, needle: string): boolean =>
  !!r && typeof r === "object" && "refused" in r && String((r as { refused: string }).refused).includes(needle);
const errs = (fs: { severity: string; message: string }[]) => fs.filter((f) => f.severity === "error").map((f) => f.message);

const t = JSON.parse(readFileSync(join(process.env.RM_FIXTURE_DIR ?? "test/fixtures", "topology-hrossen.json"), "utf8")) as TopoLike;
const devices = siteDevices(t);

const USW = "USW Pro XG 10 PoE";
const usw: Faceplate = {
  key: "unifi/usw-pro-xg-10-poe", vendor: "UniFi", model: "USW Pro XG 10 PoE", match: ["USWED77"], kind: "switch", units: 1, width: "full",
  rows: [
    [1, 3, 5, 7, 9].map((n): CatalogPort => ({ name: `Port ${n}`, kind: "poe" })).concat([{ name: "Port 11", kind: "sfp+" as const }]),
    [2, 4, 6, 8, 10].map((n): CatalogPort => ({ name: `Port ${n}`, kind: "poe" })).concat([{ name: "Port 12", kind: "sfp+" as const }]),
  ],
};
const server2u: Faceplate = { key: "generic/server-2u", vendor: "Generic", model: "2U server", kind: "server", units: 2, width: "full", generic: "nics", rows: [] };
const switch1u: Faceplate = { key: "generic/switch-1u", vendor: "Generic", model: "1U switch", kind: "switch", units: 1, width: "full", generic: "ports", rows: [] };
const modem: Faceplate = { key: "generic/isp-modem", vendor: "Generic", model: "ISP modem", kind: "modem", units: 1, width: "half", passive: true, rows: [[{ name: "WAN", kind: "rj45" }, { name: "LAN 1", kind: "rj45" }]] };
const patch: Faceplate = { key: "generic/patch-panel-24", vendor: "Generic", model: "24-port patch panel", kind: "patch-panel", units: 1, width: "full", passive: true, rows: [Array.from({ length: 24 }, (_, i) => ({ name: String(i + 1), kind: "rj45" as const }))] };
const catalog = [usw, server2u, switch1u, modem, patch];

console.log("— the fixture's devices");
check(devices.map((d) => d.name).join(",") === `tappaas1,tappaas3,tappaas2,${USW},crs-a,crs-b,Nano HD`, "nodes, switches and the access point, as the topology names them");
check(devices.find((d) => d.name === "tappaas1")!.ports.map((p) => p.id).join(",") === "nic2,nic3,nic4", "a node's ports are its uplinks' NICs");
check(devices.find((d) => d.name === "tappaas1")!.ports.find((p) => p.id === "nic2")!.lag === "lanbond", "an LACP leg carries the bond");
check(devices.find((d) => d.name === USW)!.ports.length === 12, "the UniFi switch has its 12 ports");
check(devices.find((d) => d.name === "Nano HD")!.ports[0].up === true, "the access point's link is its switch port's");
check(suggestFaceplate(catalog, devices.find((d) => d.name === USW)!) === "unifi/usw-pro-xg-10-poe", "the switch's model USWED77 finds its plate");
check(suggestFaceplate(catalog, devices.find((d) => d.name === "crs-a")!) === "generic/switch-1u", "a switch the catalog lacks gets the generic 1U switch");
check(suggestFaceplate(catalog, devices.find((d) => d.name === "tappaas2")!) === "generic/server-2u", "a node gets the generic 2U server");

console.log("— rack verbs");
let d: PositionsDoc = {};
const r1 = addRack(d, "rack1", { room: "Basement" });
check(ok(r1), "rack add");
if (ok(r1)) d = r1.doc;
check(d.racks!.rack1.units === 42 && d.racks!.rack1.width === "19in" && d.racks!.rack1.numbering === "bottom-up", "rack add: 42U, 19in, bottom-up unless told");
check(d.version === 1, "the document carries its version");
check(refused(addRack(d, "rack1", {}), "already exists"), "rack add: a duplicate refused");
check(refused(addRack(d, "Rack 2", {}), "must match"), "rack add: a bad name refused");
check(refused(addRack(d, "r2", { width: "23in" }), "--width"), "rack add: an unknown width refused");
check(refused(modifyRack(d, "rack1", [["name", "x"]]), "its key"), "rack modify: the name refused");
const rm = modifyRack(d, "rack1", [["room", "Utility"], ["units", "24"]]);
check(ok(rm) && rm.doc.racks!.rack1.room === "Utility" && rm.doc.racks!.rack1.units === 24, "rack modify: room and units");
check(ok(modifyRack(d, "rack1", [["description", ""]])), "rack modify: an empty text clears it");

console.log("— mount verbs");
const m1 = addMount(d, "tappaas1", { rack: "rack1", u: 10, faceplate: "generic/server-2u", description: "placeholder position, set by the operator" }, catalog);
check(ok(m1) && m1.doc.placements!.tappaas1.height === 2, "mount add: the height is the faceplate's");
if (ok(m1)) d = m1.doc;
check(refused(addMount(d, "tappaas1", { rack: "rack1", u: 20 }, catalog), "already mounted"), "mount add: a mounted device refused (modify moves it)");
check(refused(addMount(d, "tappaas2", { rack: "nope", u: 20 }, catalog), "does not exist"), "mount add: an unknown rack refused");
check(refused(addMount(d, "tappaas2", { rack: "rack1", u: 20, faceplate: "acme/x" }, catalog), "not in the catalog"), "mount add: an unknown faceplate refused");
const half = addMount(d, "tappaas3", { rack: "rack1", u: 5, width: "half", slot: 1 }, catalog);
check(ok(half) && half.doc.placements!.tappaas3.slot === 1 && half.doc.placements!.tappaas3.height === 1, "mount add: a half-width device in slot 1, 1U without a plate");
if (ok(half)) d = half.doc;
const mv = modifyMount(d, "tappaas3", [["rack", "rack1"], ["u", "12"], ["width", "full"]], catalog);
check(ok(mv) && mv.doc.placements!.tappaas3.u === 12 && mv.doc.placements!.tappaas3.slot === undefined, "mount modify: a move to full width drops the slot");
check(refused(modifyMount(d, "tappaas3", [["device", "x"]], catalog), "key"), "mount modify: the device refused");
check(refused(modifyMount(d, "tappaas3", [["face", "side"]], catalog), "front or rear"), "mount modify: an unknown face refused");
check(refused(deleteRack(d, "rack1"), "still holds"), "rack delete: refused while it holds mounts");

console.log("— checkPositions");
check(errs(checkPositions(d, catalog, devices)).length === 0, "the document so far is valid");
const over = addMount(d, "tappaas2", { rack: "rack1", u: 11, faceplate: "generic/server-2u" }, catalog);
check(ok(over) && errs(checkPositions(over.doc, catalog, devices)).some((m) => m.includes("overlap")), "two mounts in the same units overlap");
const rearOk = addMount(d, "tappaas2", { rack: "rack1", u: 11, face: "rear", faceplate: "generic/server-2u" }, catalog);
check(ok(rearOk) && errs(checkPositions(rearOk.doc, catalog, devices)).length === 0, "the same units at the rear do not overlap the front");
const sideBySide = addMount(d, "Nano HD", { rack: "rack1", u: 5, width: "half", slot: 0 }, catalog);
check(ok(sideBySide) && errs(checkPositions(sideBySide.doc, catalog, devices)).length === 0, "two halves side by side do not overlap");
check(columnSpan({ width: "third", slot: 2 })[0] === 4 && columnSpan({ width: "half", slot: 1 })[0] === 3, "column spans in sixths");
const top = addMount(d, "tappaas2", { rack: "rack1", u: 42, faceplate: "generic/server-2u" }, catalog);
check(ok(top) && errs(checkPositions(top.doc, catalog, devices)).some((m) => m.includes("does not fit")), "U42-U43 does not fit 42U");
const ghost = addMount(d, "tappaas9", { rack: "rack1", u: 30 }, catalog);
check(ok(ghost) && errs(checkPositions(ghost.doc, catalog, devices)).some((m) => m.includes("no device 'tappaas9'")), "a device the topology lacks is refused");
check(ok(ghost) && errs(checkPositions(ghost.doc, catalog, null)).length === 0, "without the topology the device is not checked");
const pp = addMount(d, "patch panel A", { rack: "rack1", u: 30, faceplate: "generic/patch-panel-24" }, catalog);
check(ok(pp) && errs(checkPositions(pp.doc, catalog, devices)).length === 0, "a passive plate's device needs no topology device");
const badPlate: PositionsDoc = { ...d, placements: { ...d.placements, tappaas2: { rack: "rack1", u: 20, height: 1, width: "full", face: "front", faceplate: "acme/x" } } };
check(errs(checkPositions(badPlate, catalog, devices)).some((m) => m.includes("acme/x is not in the catalog")), "a faceplate key the catalog lacks");

console.log("— cables");
check(JSON.stringify(parseEnd(`${USW}:5`)) === JSON.stringify({ device: USW, port: "5" }), "an end splits on its last colon");
check(parseEnd("tappaas1") === null, "an end with no port is refused");
const isp = addCable(d, { device: USW, port: "5" }, { device: "ISP modem", port: "LAN 1", faceplate: "generic/isp-modem" }, "uplink", "ISP hand-off");
check(ok(isp), "cable add: the ISP hand-off");
if (ok(isp)) d = isp.doc;
check(errs(checkPositions(d, catalog, devices)).length === 0, "the ISP modem's port is on its faceplate, port 5 on the switch's");
check(refused(addCable(d, { device: USW, port: "5" }, { device: "x", port: "1" }, "patch"), "already uses"), "cable add: a port carries one cable");
check(refused(addCable(d, { device: "a", port: "1" }, { device: "b", port: "2" }, "fibre"), "--kind"), "cable add: an unknown kind refused");
const bad = addCable(d, { device: USW, port: "13" }, { device: "nowhere", port: "1" }, "patch");
check(ok(bad) && errs(checkPositions(bad.doc, catalog, devices)).length === 2, "a port the switch lacks and a device nothing knows are both errors");
const rc = removeCable(d, { device: "ISP modem", port: "LAN 1" });
check(ok(rc) && (rc.doc.cables ?? []).length === 0 && rc.doc.cables === undefined, "cable remove by either end; an empty list is dropped");
check(refused(removeCable(d, { device: USW, port: "6" }), "no recorded cable"), "cable remove: a seen link is not recorded");
if (ok(pp)) {
  const withPatch = addCable(pp.doc, { device: "patch panel A", port: "1" }, { device: USW, port: "1" }, "patch");
  check(ok(withPatch) && errs(checkPositions(withPatch.doc, catalog, devices)).length === 0, "a patch panel's port to a switch port");
  if (ok(withPatch)) {
    const gone = removeMount(withPatch.doc, "patch panel A", true);
    check(ok(gone) && gone.doc.cables === undefined, "mount remove of a passive device drops its recorded cables");
  }
}
const keep = removeMount(d, "tappaas1", false);
check(ok(keep) && (keep.doc.cables ?? []).length === 1, "mount remove of a topology device keeps the recorded cables");

console.log("— the view the topology carries");
const seen = seenCables(t);
const has = (a: string, ap: string, b: string, bp: string) => seen.some((c) => (c.from.device === a && c.from.port === ap && c.to.device === b && c.to.port === bp) || (c.to.device === a && c.to.port === ap && c.from.device === b && c.from.port === bp));
check(has("crs-a", "sfp-sfpplus1", "tappaas1", "nic2") && has("crs-b", "sfp-sfpplus1", "tappaas1", "nic3"), "tappaas1's LACP legs to crs-a and crs-b");
check(has(USW, "6", "tappaas1", "nic4") && has(USW, "7", "tappaas3", "enp3s0"), "the wan links on 6 and 7");
check(has(USW, "11", "crs-a", "sfp-sfpplus14") && has(USW, "12", "crs-b", "sfp-sfpplus14"), "the uplink LAG 11+12 to the CRS pair");
check(has(USW, "9", "Nano HD", "uplink"), "the access point on 9");
check(seen.filter((c) => c.from.device === USW && c.from.port === "11" || c.to.device === USW && c.to.port === "11").length === 1, "a switch-to-switch link is drawn once");
check(!seen.some((c) => c.from.port === "5" && c.from.device === USW), "the ISP hand-off is not seen: it is recorded");
check(seen.find((c) => has(c.from.device, c.from.port, c.to.device, c.to.port) && c.to.port === "nic4")!.kind === "wan", "a wan link is kind wan");
check(seen.find((c) => c.to.port === "nic2")!.lag === "tappaas1-lan", "an LACP leg names its LAG");

const view = resolvePositions(d, catalog, t);
check(view.racks.length === 1 && view.racks[0].mounts.length === 2, "one rack with its two mounts");
const t1 = view.racks[0].mounts.find((m) => m.device === "tappaas1")!;
check(t1.plate!.rows.length === 1 && t1.plate!.rows[0].map((p) => p!.id).join(",") === "nic2,nic3,nic4", "a generic server plate shows the node's NICs");
check(t1.up === true && t1.plate!.rows[0][0]!.lag === "lanbond", "live state: up, the bond on its LACP NICs");
const t3 = view.racks[0].mounts.find((m) => m.device === "tappaas3")!;
check(t3.faceplate === "generic/server-2u" && t3.suggested, "an unrecorded plate is the catalog's suggestion, marked so");
check(view.unplaced.map((u) => u.device).join(",") === `tappaas2,${USW},crs-a,crs-b,Nano HD`, "the devices mounted nowhere");
check(view.findings.filter((f) => f.kind === "unplaced").length === 5, "a finding for each, since a rack exists");
check(view.outside.length === 1 && view.outside[0].device === "ISP modem" && view.outside[0].plate!.rows[0].length === 2, "the ISP modem is placed by its cable record");
check(view.cables.some((c) => c.source === "recorded" && c.to.device === "ISP modem" && c.up === true && c.zones.includes("wan")), "the recorded ISP cable takes port 5's link and zone");
const gone = resolvePositions({ ...d, placements: { ...d.placements, tappaas9: { rack: "rack1", u: 30, height: 1, width: "full", face: "front" } } }, catalog, t);
check(gone.findings.some((f) => f.kind === "gone" && f.device === "tappaas9"), "a mount whose device is gone is a finding");
check(resolvePositions({}, catalog, t).findings.length === 0, "no rack: no unplaced findings");
const withSw = addMount(d, USW, { rack: "rack1", u: 20, faceplate: "unifi/usw-pro-xg-10-poe" }, catalog) as { doc: PositionsDoc };
const sw = resolvePositions(withSw.doc, catalog, t);
const plate = sw.racks[0].mounts.find((m) => m.device === USW)!.plate!;
check(plate.rows[0][2]!.id === "5" && plate.rows[0][2]!.zones.includes("wan") && plate.rows[1][5]!.lag === "crs-uplink", "the UniFi plate's ports carry the switch's live state");
check(unitAtRow({ units: 42, numbering: "bottom-up" }, 0) === 42 && unitAtRow({ units: 42, numbering: "top-down" }, 0) === 1, "the top row is U42 bottom-up, U1 top-down");

console.log(`\nposition-manager verbs: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
