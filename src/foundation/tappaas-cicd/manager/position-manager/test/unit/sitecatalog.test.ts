// sitecatalog.test.ts — the site's own faceplates: the port spec (rows,
// groups, names, places on the plate), a site plate merged over the shipped
// catalog and checked as a shipped one is, and faceplate add/modify/delete.
//
// Run: RM_CATALOG_DIR=<position-manager>/faceplates node sitecatalog.test.js

import { loadCatalog } from "../../src/store";
import { addFaceplate, deleteFaceplate, modifyFaceplate, placeDevice, addRack, Result } from "../../src/verbs";
import { CatalogPort, PositionsDoc, blockRows, checkPositions, faceplateFile, parsePortSpec, parseFaceplate, portXs, resolvePlate, suggestFaceplate, withSiteFaceplates } from "../../../../lib/ts/src/positions";

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

const spec = (s: string) => {
  const r = parsePortSpec(s);
  if ("error" in r) throw new Error(`${s}: ${r.error}`);
  return r.blocks;
};
const err = (s: string): string => {
  const r = parsePortSpec(s);
  return "error" in r ? r.error : "";
};
const names = (r: (CatalogPort | null)[]) => r.map((p) => (p ? p.name : "_")).join(",");

console.log("— the port spec");
let b = spec("24xrj45");
check(b.length === 1 && b[0].rows.length === 1 && b[0].rows[0].length === 24 && names(b[0].rows[0]) === Array.from({ length: 24 }, (_, i) => String(i + 1)).join(","), "24xrj45: one row of 24, named 1-24");
b = spec("8xrj45, 2xsfp+");
check(b.length === 2 && names(b[0].rows[0]) === "1,2,3,4,5,6,7,8" && names(b[1].rows[0]) === "9,10" && b[1].rows[0][0]!.kind === "sfp+", "8xrj45, 2xsfp+: two groups, numbered on");
check(b[0].to < b[1].from, "…side by side, a gap between");
check(names(blockRows(b)[0]) === "1,2,3,4,5,6,7,8,_,9,10", "…as rows: a gap between the groups");
b = spec("8xsfp+/8xsfp+");
check(b.length === 1 && b[0].rows.length === 2 && names(b[0].rows[0]) === "1,2,3,4,5,6,7,8" && names(b[0].rows[1]) === "9,10,11,12,13,14,15,16", "8xsfp+/8xsfp+: two rows of eight");
b = spec("16xsfp+@2:sfp-sfpplus{n}");
check(b[0].rows.length === 2 && b[0].rows[0][0]!.name === "sfp-sfpplus1" && b[0].rows[1][0]!.name === "sfp-sfpplus2" && b[0].rows[0][7]!.name === "sfp-sfpplus15", "16xsfp+@2: odd over even, named from the template");
b = spec("rj45:WAN+gap+4xrj45:LAN {n}");
check(names(b[0].rows[0]) === "WAN,_,LAN 1,LAN 2,LAN 3,LAN 4", "rj45:WAN+gap+4xrj45:LAN {n}: names and a gap");
b = spec("2xsfp++2xrj45");
check(names(b[0].rows[0]) === "1,2,3,4" && b[0].rows[0][1]!.kind === "sfp+" && b[0].rows[0][2]!.kind === "rj45", "2xsfp++2xrj45: sfp+ then its own +");
b = spec("4xrj45:eth");
check(names(b[0].rows[0]) === "eth1,eth2,eth3,eth4", "a name without {n} on several ports: the number after it");
b = spec("12xrj45[2-98]");
check(b[0].from === 0.02 && b[0].to === 0.98, "[2-98]: its place in percent of the width");
b = spec("8xrj45, 2xsfp+");
check(Math.abs(b[1].to - 0.97) < 1e-6 && b[0].from > 0.3, "groups without a place: right of the name, packed to the right edge");
check(err("") !== "" && err("24xfoo") !== "" && err("8xrj45,,2xsfp+") !== "" && err("8xrj45/") !== "", "empty, an unknown kind, an empty group or row: refused");
check(err("rj45:a+rj45:a").includes("twice"), "a name twice: refused");
check(err("8xrj45[0-50], 2xsfp+").includes("every group"), "a place for some groups only: refused");
check(err("8xrj45[0-60], 2xsfp+[50-70]").includes("overlap"), "places that overlap: refused");
check(err("16xsfp+@2+rj45").includes("@2"), "@<rows> with other items: refused");
check(err("gap:x") !== "" && err("200xrj45") !== "", "a named gap, more than 96 in an item: refused");

console.log("— a plate in a port spec");
const p = parseFaceplate("acme/sw8", { vendor: "Acme", model: "SW8", kind: "switch", units: 1, width: "full", ports: "8xrj45, 2xsfp+" });
check(!("error" in p) && p.rows[0].length === 11 && p.blocks!.length === 2 && p.ports === "8xrj45, 2xsfp+", "parseFaceplate: ports as a spec, its rows and blocks");
check("error" in parseFaceplate("acme/x", { vendor: "A", model: "X", kind: "other", units: 1, ports: "24xrj45", rows: [] }), "rows and a spec both: refused");
check("error" in parseFaceplate("acme/x", { vendor: "A", model: "X", kind: "other", units: 1, ports: "24xbad" }), "a broken spec: refused");
if (!("error" in p)) {
  const xs = portXs(p.blocks!);
  check(Object.keys(xs).length === 10 && xs["1"] < xs["8"] && xs["8"] < xs["9"], "portXs: left to right, by id");
  const plate = resolvePlate(p, null);
  check(plate.blocks?.length === 2 && plate.blocks[1].rows[0][0]!.id === "9", "resolvePlate: the blocks with their ports");
  check(JSON.stringify(faceplateFile(p)).includes('"ports":"8xrj45, 2xsfp+"'), "faceplateFile: the catalog file, its spec kept");
}

console.log("— the site's plates over the shipped catalog");
const { catalog: shipped } = loadCatalog(process.env.RM_CATALOG_DIR ?? "faceplates");
const doc = (r: Result): PositionsDoc => {
  if ("refused" in r) throw new Error(r.refused);
  return r.doc;
};
const refused = (r: Result) => ("refused" in r ? r.refused : "");
let d = doc(addFaceplate({}, "acme/nas-4", { units: 2, ports: "4xrj45, 2xsfp+", kind: "server", match: ["NAS-4X"], displayName: "NAS 4" }, shipped));
check(d.faceplates!["acme/nas-4"].ports === "4xrj45, 2xsfp+" && d.faceplates!["acme/nas-4"].units === 2, "faceplate add: recorded with its spec");
let m = withSiteFaceplates(shipped, d);
const nas = m.catalog.find((f) => f.key === "acme/nas-4")!;
check(!!nas && nas.site === true && nas.model === "NAS 4" && nas.vendor === "acme" && nas.kind === "server" && m.findings.length === 0, "merged: the site's entry, marked site, its display name as the model");
check(m.catalog.length === shipped.length + 1, "…beside every shipped plate");
check(suggestFaceplate(m.catalog, { kind: "machine", model: "NAS-4X" }) === "acme/nas-4", "…and suggested for the model it matches");
check(withSiteFaceplates(m.catalog, d).catalog.length === m.catalog.length, "merging a merged catalog again: the same");
check(refused(addFaceplate(d, "acme/nas-4", { units: 1, ports: "rj45" }, shipped)).includes("already"), "faceplate add: a key the site has, refused");
check(refused(addFaceplate(d, "Acme/X", { units: 1, ports: "rj45" }, shipped)) !== "", "faceplate add: a key not <vendor>/<model> lower case, refused");
check(refused(addFaceplate(d, "acme/y", { units: 1, ports: "24xbad" }, shipped)).includes("--ports"), "faceplate add: a broken spec, refused");
check(refused(addFaceplate(d, "acme/y", { units: 1, ports: "rj45/rj45/rj45/rj45" }, shipped)).includes("do not fit"), "faceplate add: four rows on 1U, refused");
check(refused(addFaceplate(d, "acme/y", { units: 1 }, shipped)).includes("--ports"), "faceplate add: no ports, refused");
// Over a shipped key: the site's plate, and validate says so.
const over = doc(addFaceplate(d, "generic/patch-panel-24", { units: 1, ports: "24xrj45[2-98]", kind: "patch-panel", passive: true }, shipped));
m = withSiteFaceplates(shipped, over);
check(m.catalog.filter((f) => f.key === "generic/patch-panel-24").length === 1 && m.catalog.find((f) => f.key === "generic/patch-panel-24")!.overrides === true, "a shipped key: the site's plate in its place");
check(checkPositions(over, shipped, null).some((f) => f.severity === "warn" && f.message.includes("overrides the shipped one")), "validate: the override pointed out");
// A broken entry written by hand: an error, not merged.
const broken: PositionsDoc = { ...d, faceplates: { ...d.faceplates, "acme/bad": { units: 1, ports: "3xwhat" } } };
check(checkPositions(broken, shipped, null).some((f) => f.severity === "error" && f.message.startsWith("faceplate acme/bad")), "validate: a broken site plate is an error");
// Placed with a site plate: its height, and the check finds the key.
d = doc(addRack(d, "rack1", { units: 42 }));
d = doc(placeDevice(d, "nas", { rack: "rack1", u: 3, height: 2, faceplate: "acme/nas-4" }, m.catalog));
check(checkPositions(d, shipped, null).every((f) => f.severity !== "error"), "a placement on a site plate is valid");
check(checkPositions({ ...d, faceplates: {} }, shipped, null).some((f) => f.message.includes("acme/nas-4 is not in the catalog")), "…and without it the key is unknown");

console.log("— faceplate modify / delete");
let d2 = doc(modifyFaceplate(d, "acme/nas-4", [["ports", "4xrj45/4xrj45"], ["description", "the backup NAS"]]));
check(d2.faceplates!["acme/nas-4"].ports === "4xrj45/4xrj45" && d2.faceplates!["acme/nas-4"].description === "the backup NAS", "faceplate modify: ports and a text");
d2 = doc(modifyFaceplate(d2, "acme/nas-4", [["description", ""], ["match", "A, B"], ["passive", "true"]]));
check(d2.faceplates!["acme/nas-4"].description === undefined && d2.faceplates!["acme/nas-4"].match!.join() === "A,B" && d2.faceplates!["acme/nas-4"].passive === true, "faceplate modify: --unset, a match list, passive");
check(refused(modifyFaceplate(d, "acme/nas-4", [["ports", "9xfoo"]])) !== "", "faceplate modify: a broken spec, refused");
check(refused(modifyFaceplate(d, "acme/nas-4", [["colour", "red"]])).includes("not one of"), "faceplate modify: an unknown field, refused");
check(refused(modifyFaceplate(d, "unifi/nano-hd", [["units", "2"]])).includes("no faceplate"), "faceplate modify: a shipped plate, refused");
check(refused(deleteFaceplate(d, "acme/nas-4", shipped)).includes("placement nas"), "faceplate delete: refused while a placement names it");
check(!("refused" in deleteFaceplate(over, "generic/patch-panel-24", shipped)), "faceplate delete: an override gives way to the shipped plate");
const gone = doc(deleteFaceplate({ faceplates: { "acme/x": { units: 1, ports: "rj45" } } }, "acme/x", shipped));
check(gone.faceplates === undefined, "faceplate delete: the last one, and the section goes");
check(refused(deleteFaceplate(d, "unifi/nano-hd", shipped)).includes("shipped plate is not deleted"), "faceplate delete: a shipped plate, refused");

console.log(`\nposition-manager site catalog: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
