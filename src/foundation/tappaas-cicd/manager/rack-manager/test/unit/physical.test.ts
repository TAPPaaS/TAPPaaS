// physical.test.ts — the recorded devices, rooms, patch panels and cable
// segments of config/racks.json: the verbs, the whole-document check and the
// view the topology carries, over hrossen's topology
// (test/fixtures/topology-hrossen.json). Offline; the catalog is in memory.
//
// Run: RM_FIXTURE_DIR=<rack-manager>/test/fixtures node physical.test.js

import { readFileSync } from "fs";
import { join } from "path";
import { addCable, addDevice, addRack, modifyDevice, removeDevice } from "../../src/verbs";
import { Faceplate, RacksDoc, TopoLike, checkRacks, recordedPlate, resolveRacks, siteDevices } from "../../../../lib/ts/src/racks";

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
type R = { doc: RacksDoc } | { refused: string };
const ok = (r: R): r is { doc: RacksDoc } => "doc" in r;
const refused = (r: R, needle: string): boolean => "refused" in r && r.refused.includes(needle);
const doc = (r: R): RacksDoc => {
  if (!ok(r)) throw new Error(`refused: ${r.refused}`);
  return r.doc;
};
const errs = (d: RacksDoc) => checkRacks(d, catalog, devices).filter((f) => f.severity === "error").map((f) => f.message);
const warns = (d: RacksDoc) => checkRacks(d, catalog, devices).filter((f) => f.severity === "warn").map((f) => f.message);

const t = JSON.parse(readFileSync(join(process.env.RM_FIXTURE_DIR ?? "test/fixtures", "topology-hrossen.json"), "utf8")) as TopoLike;
const devices = siteDevices(t);
const seen = devices.map((x) => x.name);
const USW = "USW Pro XG 10 PoE";
const modem: Faceplate = { key: "generic/isp-modem", vendor: "Generic", model: "ISP modem", kind: "modem", units: 1, width: "half", passive: true, rows: [[{ name: "WAN", kind: "rj45" }, { name: "LAN 1", kind: "rj45" }]] };
const patch24: Faceplate = { key: "generic/patch-panel-24", vendor: "Generic", model: "24-port patch panel", kind: "patch-panel", units: 1, width: "full", passive: true, rows: [Array.from({ length: 24 }, (_, i) => ({ name: String(i + 1), kind: "rj45" as const }))] };
const catalog = [modem, patch24];

console.log("— recorded devices");
let d: RacksDoc = doc(addRack({}, "rack1", {}));
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
check(refused(modifyDevice(d, "ups1", [["name", "x"]], catalog), "how cables and mounts name it"), "device modify: the name is refused");
const withCable = doc(addCable(d, { device: "ont1", port: "LAN" }, { device: USW, port: "5" }, "uplink"));
check(errs(withCable).length === 0, "a recorded device's port is a valid cable end");
check(refused(removeDevice(withCable, "ont1"), "cable remove"), "device remove: refused while a cable names it");
check(ok(removeDevice(d, "ont1")), "device remove: a device nothing names");
check(errs({ ...withCable, cables: [{ from: { device: "ont1", port: "WAN" }, to: { device: USW, port: "5" }, kind: "uplink" }] }).some((m) => m.includes("ont1 has no port WAN")), "a port the record lacks is refused");

console.log("— the ISP modem: from a name on a cable to a recorded device");
const legacy: RacksDoc = { version: 1, racks: d.racks, cables: [{ from: { device: USW, port: "5" }, to: { device: "ISP modem", port: "LAN 1", faceplate: "generic/isp-modem" }, kind: "uplink", label: "ISP hand-off" }] };
check(errs(legacy).length === 0 && warns(legacy).some((m) => m.includes("ISP modem is neither seen by the topology nor recorded") && m.includes("device add 'ISP modem' --kind") && m.includes("--model generic/isp-modem")), "validate tells the operator the modem is only a name on a cable, and how to record it");
check(resolveRacks(legacy, catalog, t).outside.some((o) => o.device === "ISP modem"), "before: placed beside the racks by its cable");
const migrated = doc(addDevice(legacy, "ISP modem", { kind: "modem", model: "generic/isp-modem" }, catalog, seen));
check(JSON.stringify(migrated.cables) === JSON.stringify(legacy.cables), "the cable is unchanged");
check(errs(migrated).length === 0 && !warns(migrated).some((m) => m.includes("neither seen")), "after: valid, and no warning");
const v = resolveRacks(migrated, catalog, t);
check(!v.outside.some((o) => o.device === "ISP modem") && v.unplaced.some((u) => u.device === "ISP modem" && u.recorded === "modem" && u.suggestion === "generic/isp-modem"), "after: a device like any other, mounted nowhere yet, its model the plate to mount");
check(v.cables.some((c) => c.source === "recorded" && c.to.device === "ISP modem" && c.zones.includes("wan")), "its cable still carries port 5's zone");
const t2: TopoLike = { ...t, devices: [...(t.devices ?? []), { name: "ISP modem", kind: "modem", recorded: true, ports: ["WAN", "LAN 1"] }] };
check(siteDevices(t2).find((x) => x.name === "ISP modem")?.recorded === "modem", "the topology's devices carry it as recorded, with its kind");

console.log(`\nrack-manager physical: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
