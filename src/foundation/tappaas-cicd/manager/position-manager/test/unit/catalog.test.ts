// catalog.test.ts — the faceplate catalog as shipped (faceplates/): every entry
// parses, the plates hrossen's devices are drawn with have the ports their
// controllers name, and each device gets the plate it should.
//
// Run: RM_FIXTURE_DIR=<position-manager>/test/fixtures RM_CATALOG_DIR=<position-manager>/faceplates node catalog.test.js

import { readFileSync } from "fs";
import { join } from "path";
import { loadCatalog } from "../../src/store";
import { CatalogPort, PlateBlock, TopoLike, platePorts, portId, portXs, recordedPlate, renderPlate, resolvePlate, siteDevices, suggestFaceplate } from "../../../../lib/ts/src/positions";

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
check(usw.rows.length === 1 && usw.rows[0].filter(Boolean).map((p) => portId(p!)).join(",") === "1,2,3,4,5,6,7,8,9,10,11,12", "one row, 1-12 left to right");
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
check(renderPlate(resolvePlate(usw, null)).length === 1 + 1 + 2, "faceplates show: a head, one port row, two labels");

// Where each plate puts its ports: x as a share of the plate's width, the
// centre of the port's column.
const near = (a: number, b: number) => Math.abs(a - b) < 0.001;
const evenly = (xs: number[]) => xs.slice(1).every((x, i) => near(x - xs[i], xs[1] - xs[0]));
const rowXs = (blocks: PlateBlock<CatalogPort>[], b: number, r: number) => {
  const all = portXs(blocks);
  return blocks[b].rows[r].filter((p): p is CatalogPort => !!p).map((p) => all[portId(p)]);
};
console.log("— port positions");
// The patch panel: 24 across the whole plate, a 25th of it apart.
const pp = get("generic/patch-panel-24");
const ppx = rowXs(pp.blocks!, 0, 0);
check(pp.blocks!.length === 1 && pp.blocks![0].rows.length === 1 && ppx.length === 24, "patch panel: one row of 24");
check(near(ppx[0], 0.04) && near(ppx[23], 0.96) && evenly(ppx), `patch panel: from 0.04 to 0.96, evenly (${ppx[0]}…${ppx[23]})`);
// A recorded panel the same; 48 ports in two rows of 24, edge to edge.
const rec24 = recordedPlate("p", { kind: "patch-panel", ports: Array.from({ length: 24 }, (_, i) => String(i + 1)) }, catalog);
check(JSON.stringify(portXs(rec24.blocks!)) === JSON.stringify(portXs(pp.blocks!)), "a recorded 24-port panel: the generic panel's places");
const rec48 = recordedPlate("p", { kind: "patch-panel", ports: Array.from({ length: 48 }, (_, i) => String(i + 1)) }, catalog);
const r48 = [rowXs(rec48.blocks!, 0, 0), rowXs(rec48.blocks!, 0, 1)];
check(rec48.units === 1 && r48[0].length === 24 && r48[1].length === 24 && near(r48[1][0], 0.04) && near(r48[1][23], 0.96) && evenly(r48[1]), "a recorded 48-port panel: two rows of 24, edge to edge, 1U");
const rec30 = recordedPlate("p", { kind: "patch-panel", ports: Array.from({ length: 30 }, (_, i) => String(i + 1)) }, catalog);
check(rec30.rows.length === 2 && rec30.rows[0].length === 15, "a recorded 30-port panel: two rows of 15");
// The UniFi switch: one row, thirteen places across the plate (a gap before the SFP+).
const ux = portXs(usw.blocks!);
const pitch = 0.96 / 13;
check(usw.blocks!.length === 1 && near(ux["1"], 0.02 + pitch / 2) && near(ux["10"], 0.02 + 9.5 * pitch) && near(ux["11"], 0.02 + 11.5 * pitch) && near(ux["12"], 0.98 - pitch / 2), `UniFi: 1 at ${ux["1"]}, 10 at ${ux["10"]}, 11 at ${ux["11"]}, 12 at ${ux["12"]}`);
check(evenly(Array.from({ length: 10 }, (_, i) => ux[String(i + 1)])), "UniFi: 1-10 evenly apart");
// The CRS317: the cages two rows of eight in the left two thirds, ether1 over
// the console just right of them, the rest of the right third blank.
const cx = portXs(crs.blocks!);
const top = rowXs(crs.blocks!, 0, 0);
const bottom = rowXs(crs.blocks!, 0, 1);
check(crs.blocks![0].rows[0].map((p) => p!.name).join() === "sfp-sfpplus1,sfp-sfpplus3,sfp-sfpplus5,sfp-sfpplus7,sfp-sfpplus9,sfp-sfpplus11,sfp-sfpplus13,sfp-sfpplus15", "CRS317: odd cages on top");
check(near(top[0], 0.06) && near(top[7], 0.62) && evenly(top) && JSON.stringify(top) === JSON.stringify(bottom), `CRS317: cages from 0.06 to 0.62, the rows aligned (${top.join(",")})`);
check(Math.max(...Object.entries(cx).filter(([k]) => k.startsWith("sfp")).map(([, x]) => x)) < 2 / 3, "CRS317: every cage in the left two thirds");
check(near(cx["ether1"], 0.71) && near(cx["console"], 0.71) && crs.blocks![1].rows.length === 2, "CRS317: ether1 over the console at 0.71");
check(Math.max(...Object.values(cx)) < 0.75, "CRS317: right of 0.75 blank, its name's place");

console.log(`\nposition-manager catalog: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
