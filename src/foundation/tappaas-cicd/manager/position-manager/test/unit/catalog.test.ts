// catalog.test.ts — the faceplate catalog as shipped (faceplates/): every entry
// parses, the plates hrossen's devices are drawn with have the ports their
// controllers name, and each device gets the plate it should.
//
// Run: RM_FIXTURE_DIR=<position-manager>/test/fixtures RM_CATALOG_DIR=<position-manager>/faceplates node catalog.test.js

import { readFileSync } from "fs";
import { join } from "path";
import { loadCatalog } from "../../src/store";
import { TopoLike, platePorts, portId, renderPlate, resolvePlate, siteDevices, suggestFaceplate } from "../../../../lib/ts/src/racks";

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

const { catalog, errors } = loadCatalog(process.env.RM_CATALOG_DIR ?? "faceplates");
check(errors.length === 0, `every entry parses (${errors.join("; ")})`);
const keys = catalog.map((f) => f.key);
for (const k of ["unifi/usw-pro-xg-10-poe", "unifi/nano-hd", "mikrotik/crs317-1g-16s", "generic/server-1u", "generic/server-2u", "generic/server-4u", "generic/switch-1u", "generic/ap", "generic/patch-panel-24", "generic/pdu-8", "generic/isp-modem"]) {
  check(keys.includes(k), `the catalog has ${k}`);
}
const get = (k: string) => catalog.find((f) => f.key === k)!;

const usw = get("unifi/usw-pro-xg-10-poe");
const uswPorts = usw.rows.flat().filter((p) => p !== null);
check(uswPorts.length === 12 && uswPorts.every((p) => /^Port \d+$/.test(p!.name)), "the UniFi switch: 12 ports, named as UniFi names them");
check(uswPorts.filter((p) => p!.kind === "poe").map((p) => portId(p!)).sort((a, b) => +a - +b).join(",") === "1,2,3,4,5,6,7,8,9,10", "1-10 are 10 GbE RJ45 with PoE");
check(uswPorts.filter((p) => p!.kind === "sfp+").map((p) => portId(p!)).join(",") === "11,12", "11-12 are SFP+");
check(usw.rows[0].filter(Boolean).map((p) => portId(p!)).join(",") === "1,3,5,7,9,11", "odd ports on the top row");
check(usw.units === 1 && usw.width === "full", "1U, full width");
const crs = get("mikrotik/crs317-1g-16s");
check(crs.rows.flat().filter((p) => p?.kind === "sfp+").length === 16 && crs.rows.flat().some((p) => p?.name === "ether1"), "the CRS317: sixteen SFP+ and ether1, as RouterOS names them");
check(get("unifi/nano-hd").rows[0][0]!.id === "uplink", "the Nano HD's port is the topology's uplink");
check(get("generic/patch-panel-24").passive === true && get("generic/pdu-8").passive === true && get("generic/isp-modem").passive === true, "patch panel, PDU and modem are passive");
check(get("generic/server-2u").generic === "nics" && get("generic/switch-1u").generic === "ports", "the generic server takes NICs, the generic switch ports");

const t = JSON.parse(readFileSync(join(process.env.RM_FIXTURE_DIR ?? "test/fixtures", "topology-hrossen.json"), "utf8")) as TopoLike;
const devs = siteDevices(t);
const sug = (n: string) => suggestFaceplate(catalog, devs.find((d) => d.name === n)!);
check(sug("USW Pro XG 10 PoE") === "unifi/usw-pro-xg-10-poe", "USWED77 → the UniFi plate");
check(sug("crs-a") === "mikrotik/crs317-1g-16s" && sug("crs-b") === "mikrotik/crs317-1g-16s", "CRS317-1G-16S+ → the MikroTik plate");
check(sug("Nano HD") === "unifi/nano-hd", "U7NHD → the Nano HD plate");
check(sug("tappaas1") === "generic/server-2u", "a node → the generic 2U server");

// Every port the topology knows on each switch is on its plate.
for (const name of ["USW Pro XG 10 PoE", "crs-a"]) {
  const d = devs.find((x) => x.name === name)!;
  const plate = resolvePlate(get(sug(name)!), d);
  const ids = new Set(platePorts(plate).map((p) => p.id));
  const off = d.ports.map((p) => p.id).filter((id) => !ids.has(id));
  check(off.length === 0, `${name}: every port the switch reports is on its plate${off.length ? ` (not: ${off.join(", ")})` : ""}`);
}
const crsPlate = resolvePlate(crs, devs.find((d) => d.name === "crs-a")!);
check(platePorts(crsPlate).find((p) => p.id === "sfp-sfpplus1")!.lag === "tappaas1-lan", "crs-a's sfp-sfpplus1 carries tappaas1's LAG");
check(renderPlate(resolvePlate(usw, null)).length === 1 + 2 + 2, "faceplates show: a head, two port rows, two labels");

console.log(`\nposition-manager catalog: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
