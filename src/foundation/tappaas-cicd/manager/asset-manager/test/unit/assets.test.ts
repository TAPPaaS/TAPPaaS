// assets.test.ts — the assets of config/positions.json (ADR-040 D7-D9): the
// lifecycle verbs, the whole-document rules, the ports and their kinds, the
// catalog's speeds, the reading of devices{} before migration 0027, and the
// assets the topology carries, over hrossen's topology
// (test/fixtures/topology-hrossen.json). Offline; the catalog is in memory.
//
// Run: RM_FIXTURE_DIR=<asset-manager>/test/fixtures node assets.test.js

import { readFileSync } from "fs";
import { join } from "path";
import {
  addAsset,
  addCable,
  addPort,
  addRack,
  allocateAsset,
  disposeAsset,
  faultAsset,
  modifyPort,
  placeDevice,
  receiveAsset,
  releaseAsset,
  removePort,
  repairAsset,
  unplaceDevice,
} from "../../src/verbs";
import { Asset, Faceplate, PositionsDoc, TopoLike, assetPorts, assetsOf, checkPositions, nextTag, parseFaceplate, parsePortArg, parsePortSpec, portProblem, resolvePositions, siteDevices, stageOf } from "../../../../lib/ts/src/positions";

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

const t = JSON.parse(readFileSync(join(process.env.RM_FIXTURE_DIR ?? "test/fixtures", "topology-hrossen.json"), "utf8")) as TopoLike;
const devices = siteDevices(t);
const seen = devices.map((x) => x.name);
const USW = "USW Pro XG 10 PoE";
const usw = parseFaceplate("unifi/usw-pro-xg-10-poe", { vendor: "UniFi", model: "USW Pro XG 10 PoE", kind: "switch", units: 1, ports: "10xpoe-10g:Port {n}+2xsfp+:Port {n}[51-98]" }) as Faceplate;
const server = parseFaceplate("generic/server-2u", { vendor: "Generic", model: "2U server", kind: "server", units: 2, generic: "nics", rows: [] }) as Faceplate;
const catalog = [usw, server];
const errs = (d: PositionsDoc) => checkPositions(d, catalog, devices).filter((f) => f.severity === "error").map((f) => f.message);
const warns = (d: PositionsDoc) => checkPositions(d, catalog, devices).filter((f) => f.severity === "warn").map((f) => f.message);
const asset = (d: PositionsDoc, n: string): Asset => assetsOf(d)[n];

console.log("— ports (D9)");
check(portProblem({ name: "eth0", kind: "rj45", speed: "2.5g" }, false) === null, "an rj45 at 2.5g");
check(portProblem({ name: "eth0", kind: "rj45", speed: "25g" }, false)?.includes("1g, 2.5g, 10g") === true, "an rj45 at 25g is refused");
check(portProblem({ name: "sfp1", kind: "sfp", speed: "25g", module: "sr" }, false) === null, "an sfp28 cage with a short-range optic");
check(portProblem({ name: "eth0", kind: "rj45", module: "dac" }, false)?.includes("sfp cage") === true, "a module outside a cage is refused");
check(portProblem({ name: "wl0", kind: "wifi", standard: "wifi6", bands: ["2.4", "5", "6"] }, false) === null, "Wi-Fi 6E: wifi6 with band 6");
check(portProblem({ name: "wl0", kind: "wifi", speed: "1g" }, false)?.includes("no speed") === true, "a wifi port has no speed");
check(portProblem({ name: "eth0", kind: "rj45", standard: "wifi5" }, false)?.includes("wifi port") === true, "a standard on an rj45 is refused");
check(portProblem({ name: "usb1", kind: "usb-c", speed: "usb3" }, false) === null && portProblem({ name: "usb1", kind: "usb-a", speed: "10g" }, false) !== null, "usb speeds are usb2 and usb3");
check(portProblem({ name: "x", kind: "bmc" as never }, false)?.includes("kind is one of") === true, "bmc is no kind: a BMC is an rj45 with role bmc");
check(portProblem({ name: "1", kind: "rj45", side: "rear" }, false)?.includes("patch panel") === true && portProblem({ name: "1", kind: "rj45", side: "rear" }, true) === null, "a side only on a patch panel's port");
check(portProblem({ name: "a:b", kind: "rj45" }, false) !== null, "a port's name has no colon");
const pa = parsePortArg("eth1:rj45:2.5g");
check(!("error" in pa) && pa.speed === "2.5g", "--port eth1:rj45:2.5g");
const pb = parsePortArg("WAN");
check(!("error" in pb) && pb.kind === "rj45" && pb.speed === "1g", "--port WAN: an rj45 at 1g");
check("error" in parsePortArg("usb0:usb-a:10g"), "--port with a speed its kind lacks is refused");

console.log("— the catalog's speeds");
const spec = parsePortSpec("8xrj45-2.5g, 2xsfp+");
check(!("error" in spec) && spec.blocks[0].rows[0][0]?.speed === "2.5g" && spec.blocks[1].rows[0][0]?.speed === undefined, "a spec's speed is the port's; absent, its kind's");
check("error" in parsePortSpec("8xrj45-25g") && "error" in parsePortSpec("console-1g") && "error" in parsePortSpec("2xsfp+-2.5g"), "a speed the connector lacks is refused, and a console has none");
check("error" in (parseFaceplate("acme/x", { vendor: "a", model: "x", kind: "switch", units: 1, rows: [[{ name: "1", kind: "rj45", speed: "40g" }]] }) as object), "a row port's speed is checked too");
const uswPorts = assetPorts({ model: usw.key }, catalog);
check(uswPorts.length === 12 && uswPorts[0].kind === "rj45" && uswPorts[0].speed === "10g" && uswPorts[10].kind === "sfp" && uswPorts[10].speed === "10g", "a plate's ports as the asset's: poe-10g is a 10G rj45, sfp+ a 10G cage");
const merged = assetPorts({ model: usw.key, ports: [{ name: "11", kind: "sfp", module: "dac" }, { name: "mgmt", kind: "rj45", speed: "1g" }] }, catalog);
check(merged.length === 13 && merged[10].module === "dac" && merged[10].speed === "10g" && merged[12].name === "mgmt", "its own ports merge over the plate's by name, the rest after");

console.log("— a plate's ports, refined");
let sw: PositionsDoc = doc(addAsset({}, undefined, { kind: "switch", model: usw.key }, catalog, seen));
sw = doc(modifyPort(sw, "sw-01", "11", [["module", "sr"]], catalog));
check(JSON.stringify(asset(sw, "sw-01").ports) === JSON.stringify([{ name: "11", kind: "sfp", module: "sr" }]) && assetPorts(asset(sw, "sw-01"), catalog)[10].speed === "10g", "port modify on a plate's port: an entry of its own, only what it adds");
check(refused(modifyPort(sw, "sw-01", "1", [["speed", "25g"]], catalog), "1g, 2.5g, 10g"), "…checked as merged with the plate's (a 10G rj45 is no 25G)");
check(refused(addPort(sw, "sw-01", "11", { kind: "sfp" }, catalog), "has a port 11 already"), "port add: a plate's port is there already");
check(refused(removePort(sw, "sw-01", "1", catalog), "a plate's port stays"), "port remove: a plate's port stays");
sw = doc(removePort(sw, "sw-01", "11", catalog));
check(!asset(sw, "sw-01").ports && assetPorts(asset(sw, "sw-01"), catalog)[10].module === undefined, "port remove: the refinement goes, the plate's port is back");

console.log("— the lifecycle");
let d: PositionsDoc = doc(addRack({}, "rack1", {}));
check(nextTag(d, "server") === "srv-01" && nextTag(d, "access-point") === "ap-01" && nextTag(d, "ups") === "dev-01", "the tags per kind: srv, ap, dev");
d = doc(addAsset(d, undefined, { kind: "server", serial: "CZC1", stage: "ordered" }, catalog, seen));
d = doc(addAsset(d, undefined, { kind: "server", serial: "CZC2" }, catalog, seen));
check(Object.keys(assetsOf(d)).join() === "srv-01,srv-02" && nextTag(d, "server") === "srv-03", "no name: the next free tag");
check(refused(addAsset(d, undefined, { kind: "server", stage: "placed" }, catalog, seen), "--stage is ordered or stock"), "a stage other than ordered or stock is refused at add");
check(stageOf(d, "srv-01", asset(d, "srv-01")) === "ordered" && stageOf(d, "srv-02", asset(d, "srv-02")) === "stock", "ordered, and in stock");
check(refused(allocateAsset(d, "srv-01", "tappaas1", devices), "asset receive"), "an ordered asset takes no role");
d = doc(receiveAsset(d, "srv-01"));
d = doc(placeDevice(d, "srv-01", { rack: "rack1", u: 1, faceplate: "generic/server-2u" }, catalog));
check(asset(d, "srv-01").stage === "placed" && stageOf(d, "srv-01", asset(d, "srv-01")) === "placed", "placed: the stage follows the placement");
check(errs(d).length === 0, "a placed asset with no role is valid");
check(refused(allocateAsset(d, "srv-01", USW, devices), "a server plays a node or machine"), "a server does not play a switch");
check(refused(allocateAsset(d, "srv-01", "tappaas9", devices), "no node or machine named tappaas9"), "a server's role is one the topology has");
d = doc(allocateAsset(d, "srv-01", "tappaas1", devices));
check(asset(d, "srv-01").role === "tappaas1" && d.placements!.tappaas1?.u === 1 && !d.placements!["srv-01"], "allocate: the role, the placement under its name");
check(stageOf(d, "srv-01", asset(d, "srv-01")) === "operational" && asset(d, "srv-01").stage === "placed", "operational (derived from the role), placed as recorded");
check(refused(allocateAsset(d, "srv-02", "tappaas1", devices), "played by asset srv-01"), "one asset per role");
check(errs(d).length === 0, "an allocated asset is valid");
const view = resolvePositions(d, catalog, t);
check(view.racks[0].placements[0].device === "tappaas1" && view.racks[0].placements[0].asset === "srv-01", "the rack draws the node, with its asset");
check(view.assets.find((a) => a.name === "srv-01")?.stage === "operational" && view.assets.find((a) => a.name === "srv-02")?.stage === "stock", "the topology carries the assets with their stages");
check(!view.findings.some((f) => f.device === "srv-02"), "an asset in stock is no 'placed nowhere' finding");
d = doc(addPort(d, "srv-01", "ilo", { kind: "rj45", role: "bmc", mac: "aa:bb:cc:00:00:01" }, catalog));
d = doc(addCable(d, { device: USW, port: "7" }, { device: "srv-01", port: "ilo" }, "patch"));
check(d.cables![0].to.device === "tappaas1" && errs(d).length === 0, "a cable to the asset's own port, under the role, is valid");
d = doc(faultAsset(d, "srv-01", "fan 2"));
check(stageOf(d, "srv-01", asset(d, "srv-01")) === "operational" && asset(d, "srv-01").faulty === true, "operational and faulty");
check(refused(disposeAsset(d, "srv-01", "sold", false, "2026-10-29"), "asset release"), "dispose: refused while it has a role");
d = doc(releaseAsset(d, "srv-01"));
check(!asset(d, "srv-01").role && d.placements!["srv-01"]?.u === 1 && !d.placements!.tappaas1 && d.cables![0].to.device === "srv-01", "release: the placement and the cable stay with the box, under its name");
check(resolvePositions(d, catalog, t).unplaced.some((u) => u.device === "tappaas1"), "…and the node is unplaced: its box is no longer it");
d = doc(repairAsset(d, "srv-01"));
check(refused(disposeAsset(d, "srv-01", "sold", false, "2026-10-29"), "unplace"), "dispose: refused while placed");
d = doc(unplaceDevice(d, "srv-01", false));
check(asset(d, "srv-01").stage === "stock", "unplace: back in stock");
check(refused(disposeAsset(d, "srv-01", "sold", false, "2026-10-29"), "cable remove"), "dispose: refused while a recorded cable names it");
d = { ...d, cables: [] };
d = doc(disposeAsset(d, "srv-01", "sold", true, "2026-10-29"));
check(asset(d, "srv-01").stage === "disposed" && asset(d, "srv-01").disposal?.how === "sold" && asset(d, "srv-01").disposal?.wiped === true, "dispose: sold, wiped");
check(!resolvePositions(d, catalog, t).unplaced.some((u) => u.device === "srv-01"), "a disposed asset is no device any more");
check(refused(placeDevice(d, "srv-01", { rack: "rack1", u: 1 }, catalog), "disposed"), "a disposed asset is not placed");

console.log("— the rules");
const base: PositionsDoc = { version: 1, racks: { rack1: { units: 42, width: "19in", numbering: "bottom-up" } } };
const A = (assets: Record<string, Asset>, extra: Partial<PositionsDoc> = {}): PositionsDoc => ({ ...base, assets, ...extra });
check(errs(A({ a: { kind: "server", stage: "disposed", disposal: { how: "lost" } } }, { placements: { a: { rack: "rack1", u: 1, height: 1, width: "full", face: "front" } } })).some((m) => m.includes("disposed, and still placed")), "a disposed asset has no placement");
check(errs(A({ a: { kind: "server", stage: "ordered", role: "tappaas1" } })).some((m) => m.includes("ordered, and still in the role")), "an ordered asset has no role");
check(errs(A({ a: { kind: "server", stage: "stock", serial: "S1" }, b: { kind: "server", stage: "stock", serial: "S1" } })).some((m) => m.includes("serial S1")), "serials are unique");
check(errs(A({ a: { kind: "other", stage: "stock", ports: [{ name: "1", kind: "rj45", mac: "aa:bb:cc:dd:ee:ff" }] }, b: { kind: "ups", stage: "stock", ports: [{ name: "x", kind: "rj45", mac: "aa:bb:cc:dd:ee:ff" }] } })).some((m) => m.includes("MAC aa:bb:cc:dd:ee:ff")), "MACs are unique across every port");
check(errs(A({ a: { kind: "server", stage: "stock", role: "tappaas1" }, b: { kind: "server", stage: "stock", role: "tappaas1" } })).some((m) => m.includes("one asset plays a role")), "a role is one asset's");
check(errs(A({ a: { kind: "server", stage: "stock", role: "tappaas9" } })).some((m) => m.includes("no node or machine the topology knows")), "a server's role is a node the topology knows");
check(errs(A({ a: { kind: "access-point", stage: "stock", role: "Nano HD" }, b: { kind: "switch", stage: "stock", role: "crs-a" } })).length === 0, "an AP plays the AP, a switch the switch");
check(errs(A({ a: { kind: "modem", stage: "stock", role: "ISP modem" } })).length === 0, "a modem plays a device nothing manages: its role is a name the topology does not have");
check(errs(A({ a: { kind: "server", stage: "stock", disposal: { how: "sold" } } })).some((m) => m.includes("a disposal on an asset that is stock")), "a disposal only on a disposed asset");
check(errs(A({ a: { kind: "server", stage: "disposed" } })).some((m) => m.includes("no disposal says how")), "a disposed asset says how");
check(errs(A({ a: { kind: "server", stage: "stock", faultNote: "x" } })).some((m) => m.includes("fault note")), "a fault note only on a faulty asset");
check(errs(A({ a: { kind: "server", stage: "stock", procurement: { purchaseDate: "29/10/2026" } } })).some((m) => m.includes("purchaseDate is a date")), "procurement dates are YYYY-MM-DD");
check(errs(A({ a: { kind: "toaster" as never, stage: "stock" } })).some((m) => m.includes("kind is one of")), "an unknown kind is refused");
check(errs(A({ a: { kind: "server", stage: "stock", ports: [{ name: "e", kind: "rj45", speed: "25g" }] } })).some((m) => m.includes("port e")), "validate checks every port");
check(errs(A({ tappaas1: { kind: "server", stage: "stock" } })).some((m) => m.includes("the topology has a device of that name")), "an asset named as a node, playing nothing, is refused");
check(errs(A({ tappaas1: { kind: "server", stage: "stock", role: "tappaas1" } })).length === 0, "…playing it, it is fine");
check(warns(A({ a: { kind: "server", stage: "placed" } })).some((m) => m.includes("placed nowhere")), "a recorded stage the placement does not bear out is a warning");
check(errs({ ...base, devices: {}, assets: {} }).some((m) => m.includes("both devices{} and assets{}")), "devices{} beside assets{} is refused");

console.log("— devices{} before migration 0027");
const legacy = { version: 1, placements: { patch1: { rack: "rack1", u: 30, height: 1, width: "full", face: "front" } }, racks: base.racks, devices: { patch1: { kind: "patch-panel", ports: ["1", "2"] }, printer: { kind: "other", ports: ["eth0"], mac: "aa:bb:cc:00:11:22" } }, cables: [{ from: { device: USW, port: "8" }, to: { device: "printer", port: "eth0" }, kind: "patch" }] } as PositionsDoc;
const la = assetsOf(legacy);
check(la.patch1.stage === "placed" && la.patch1.role === "patch1" && la.patch1.ports!.map((p) => `${p.name}:${p.kind}:${p.speed}`).join() === "1:rj45:1g,2:rj45:1g", "a placed device reads as an asset playing itself, placed, its ports rj45 at 1g");
check(la.printer.stage === "stock" && la.printer.ports![0].mac === "aa:bb:cc:00:11:22", "an unplaced one in stock, its MAC on its cabled port");
check(errs(legacy).length === 0, "the unmigrated document is valid as it reads");
check(resolvePositions(legacy, catalog, t).racks[0].placements[0].recorded === "patch-panel", "the topology draws it as before");

console.log(`\nasset-manager assets: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
