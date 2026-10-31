// disks.test.ts — disks as assets (ADR-042 D1, D2, D4): disk add, modify,
// remove, place --in (the move), unplace, adopt from the CMDB's server CIs,
// and what the whole-document check says of a disk and its placement. Over
// hrossen's positions.json as migration 0027 leaves it
// (scripts/test/fixtures/0027-hrossen/positions-after.json). Offline.
//
// Run: RM_FIXTURE_DIR=<asset-manager>/test/fixtures node disks.test.js

import { readFileSync } from "fs";
import { join } from "path";
import { PositionsDoc, assetWithSerial, checkPositions, disksIn, nextTag, parseSize, placeWhere, recordedDevicesOf, roomOf, serialKey, stageOf } from "../../../../lib/ts/src/positions";
import { serverDisks } from "../../src/main";
import { Result, addAsset, addDisk, adoptDisks, allocateAsset, disposeAsset, modifyDisk, placeDevice, placeDisk, removeAsset, removeDisk, unplaceDevice } from "../../src/verbs";

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
const doc = (r: Result): PositionsDoc => {
  if ("refused" in r) throw new Error(r.refused);
  return r.doc;
};
const refused = (r: Result, needle: string): boolean => "refused" in r && r.refused.includes(needle);
// The errors a document has beyond the fixture's own (its faceplates are not
// in the empty catalog used here).
const allErrs = (d: PositionsDoc) => checkPositions(d, [], null).filter((f) => f.severity === "error").map((f) => f.message);
let base: Set<string> = new Set();
const errs = (d: PositionsDoc) => allErrs(d).filter((e) => !base.has(e));

const FIX = process.env.RM_FIXTURE_DIR ?? "test/fixtures";
const doc0 = JSON.parse(readFileSync(join(FIX, "..", "..", "..", "..", "scripts/test/fixtures/0027-hrossen/positions-after.json"), "utf8")) as PositionsDoc;
const BYID = "ata-Samsung_SSD_870_EVO_1TB_S6PTNX0R123456A";
base = new Set(allErrs(doc0));

// ── the model ─────────────────────────────────────────────────────────────
check(nextTag(doc0, "disk") === "dsk-01", "a disk's tag is dsk-NN");
check(serialKey(" s6ptnx0r-123 456a ") === serialKey("S6PTNX0R123456A"), "a serial is compared without case, spaces and dashes (D2)");
check(parseSize("1TB") === 1e12 && parseSize("960G") === 96e10 && parseSize("4TiB") === 4 * 2 ** 40 && parseSize("1000204886016") === 1000204886016 && parseSize("1.5x") === null, "a size: bytes, K/M/G/T in 1000s, KiB… in 1024s");
check(placeWhere({ in: "srv-02", bay: "3" }) === "in srv-02, bay 3" && placeWhere({ in: "srv-02" }) === "in srv-02", "where a disk is, in words");

// ── disk add ──────────────────────────────────────────────────────────────
const a1 = addDisk(doc0, "tappaas1", BYID, { serial: "S6PTNX0R123456A", model: "Samsung SSD 870 EVO 1TB", size: "1TB", kind: "ssd", bus: "sata" });
const d1 = doc(a1);
check("act" in a1 && a1.what.startsWith("disk 'dsk-01'") && a1.what.includes("in srv-01, bay " + BYID), `disk add: dsk-01 in the role's asset, its by-id name the bay (${"what" in a1 ? a1.what : ""})`);
check(d1.assets?.["dsk-01"]?.kind === "disk" && d1.assets["dsk-01"].displayName === BYID && d1.assets["dsk-01"].stage === "placed" && d1.assets["dsk-01"].disk?.size === 1e12 && d1.assets["dsk-01"].disk?.kind === "ssd", "disk add: a disk asset, placed, its record");
check(JSON.stringify(d1.placements?.["dsk-01"]) === JSON.stringify({ in: "srv-01", bay: BYID }), "disk add: placed in the asset by its own name");
check(errs(d1).length === 0, `disk add: the document stays valid (${errs(d1).join("; ")})`);
check(refused(addDisk(d1, "srv-02", "sdb", { serial: "s6ptnx0r-123456a" }), "is asset dsk-01's"), "disk add: a serial an asset records is refused, the asset named");
check(refused(addDisk(d1, "srv-02", "sdb", {}), "--serial"), "disk add: the serial is required");
check(refused(addDisk(d1, "dsk-01", "sdb", { serial: "X1" }), "is a disk"), "disk add: not into a disk");
check(refused(addDisk(d1, "nowhere", "sdb", { serial: "X1" }), "not recorded"), "disk add: not into an asset nobody recorded");
check(refused(addDisk(d1, "srv-02", "sdb", { serial: "X1", kind: "floppy" }), "--kind"), "disk add: a kind is nvme, ssd, hdd or usb");
const d2 = doc(addDisk(d1, "srv-01", "nvme-X", { serial: "NV1", bay: "M.2 slot 1" }));
check(d2.placements?.["dsk-02"]?.bay === "M.2 slot 1" && disksIn(d2, "srv-01").map((x) => x.key).join() === "dsk-01,dsk-02", "disk add: a bay given; the disks in an asset");
check(!recordedDevicesOf(d2).some((r) => r.key.startsWith("dsk-")), "a disk is no topology device");
check(roomOf(d2, d2.placements!["dsk-01"]) === roomOf(d2, d2.placements!["tappaas1"]), "a disk is in the room of the asset it is in");
check(assetWithSerial(d2, "nv-1") === "dsk-02", "the asset with a serial, as compared");

// ── place --in, unplace ───────────────────────────────────────────────────
const mv = placeDisk(d2, "dsk-01", "tappaas2");
const moved = doc(mv);
check(moved.placements?.["dsk-01"]?.in === "srv-02" && "what" in mv && mv.what.includes("moved out of srv-01"), "place --in another asset: the move");
check(moved.placements?.["dsk-01"]?.bay === BYID, "the move: its by-id name the bay, unless told");
check(doc(placeDisk(d2, "dsk-01", "srv-01", "4")).placements?.["dsk-01"]?.bay === "4", "place --in the same asset: a new bay");
check(refused(placeDisk(d2, "dsk-01", "srv-01"), "already"), "place --in where it is: refused");
check(refused(placeDisk(d2, "srv-02", "srv-01"), "only a disk"), "place --in: only a disk");
check(refused(placeDevice(d2, "dsk-01", { rack: "rack1", u: 30 }, []), "--in <asset>"), "a disk is never placed in a rack");
const stock = doc(unplaceDevice(d2, "dsk-02", false));
check(!stock.placements?.["dsk-02"] && stockStage(stock, "dsk-02") === "stock", "unplace: a disk goes to stock");
const back = doc(placeDevice(stock, "dsk-02", { in: "srv-03" }, []));
check(back.placements?.["dsk-02"]?.in === "srv-03" && back.assets?.["dsk-02"]?.stage === "placed", "place --in: out of stock");
function stockStage(d: PositionsDoc, k: string): string {
  return stageOf(d, k, d.assets![k]);
}

// ── modify, remove; what holds disks ──────────────────────────────────────
check(doc(modifyDisk(d2, "dsk-01", [["firmware", "SVT02B6Q"], ["bay", "1"], ["size", "1000204886016"]])).assets?.["dsk-01"]?.disk?.firmware === "SVT02B6Q", "disk modify: its firmware");
check(doc(modifyDisk(d2, "dsk-01", [["bay", "1"]])).placements?.["dsk-01"]?.bay === "1", "disk modify: its bay");
check(refused(modifyDisk(d2, "dsk-01", [["serial", "NV-1"]]), "dsk-02's"), "disk modify: a serial another records is refused");
check(refused(modifyDisk(d2, "dsk-01", [["serial", ""]]), "keeps its serial"), "disk modify: the serial stays");
check(refused(modifyDisk(d2, "srv-01", [["firmware", "x"]]), "no recorded disk"), "disk modify: only a disk");
const rm = doc(removeDisk(d2, "dsk-02"));
check(!rm.assets?.["dsk-02"] && !rm.placements?.["dsk-02"], "disk remove: the record and its placement");
const spare = doc(addDisk(doc(addAsset(doc0, "srv-04", { kind: "server" }, [], null)), "srv-04", "sda", { serial: "SP1" }));
check(refused(disposeAsset(spare, "srv-04", "recycled", false, "2026-10-31"), "holds the disk"), "asset dispose: refused while it holds a disk (was it wiped?)");
const emptyish = doc(addDisk(doc0, "patchpanel1", "sda", { serial: "PP1" }));
check(refused(removeAsset(emptyish, "patchpanel1"), "holds the disk"), "asset remove: refused while it holds a disk");
check(refused(allocateAsset(d2, "dsk-01", "tappaas9", null), "plays no role"), "asset allocate: a disk plays no role");

// ── the whole-document check ──────────────────────────────────────────────
const bad1: PositionsDoc = { ...d2, placements: { ...d2.placements, "dsk-01": { rack: "rack1", u: 30, height: 1, width: "full", face: "front" } } };
check(errs(bad1).some((e) => e.includes("not in a rack or a room")), "check: a disk in a rack is an error");
const bad2: PositionsDoc = { ...d2, placements: { ...d2.placements, "printer": { in: "srv-01" } } };
check(errs(bad2).some((e) => e.includes("only a disk is placed in another asset")), "check: only a disk is in another asset");
const bad3: PositionsDoc = { ...d2, placements: { ...d2.placements, "dsk-02": { in: "dsk-01" } } };
check(errs(bad3).some((e) => e.includes("which is a disk")), "check: a disk is not in a disk");
const bad4: PositionsDoc = { ...d2, placements: { ...d2.placements, "dsk-02": { in: "srv-99" } } };
check(errs(bad4).some((e) => e.includes("no recorded asset")), "check: a disk in an asset nobody recorded");
const bad5: PositionsDoc = { ...d2, assets: { ...d2.assets, "dsk-02": { ...d2.assets!["dsk-02"], serial: "s6ptnx0r123456a" } } };
check(errs(bad5).some((e) => e.includes("one asset per serial")), "check: two disks of one serial, as compared");

// ── disk adopt ────────────────────────────────────────────────────────────
const servers = [
  {
    id: "o1", class: "server", name: "srv-01",
    attributes: {
      disks: [
        { name: BYID, serial: "S6PTNX0R123456A", model: "Samsung SSD 870 EVO 1TB", size: 1000204886016, type: "ssd", bus: "sata" },
        { name: "nvme-WD_BLACK_SN850X_2000GB_23280K800123", serial: "23280K800123", size: 2000398934016, type: "nvme" },
        { name: "usb-Generic_Flash", type: "usb" },
      ],
    },
  },
  { id: "o2", class: "server", name: "srv-02", attributes: { disks: [{ name: "ata-HGST_HDN726050ALE614_NAHW317X", serial: "NAHW317X", type: "hdd", size: 5000981078016 }] } },
  { id: "o3", class: "server", name: "srv-09", attributes: { disks: [{ name: "x", serial: "Z9" }] } },
  { id: "o4", class: "server", name: "srv-03", attributes: {} },
];
const found = serverDisks(servers);
check(found.length === 3 && found[0].disks.length === 3 && found[0].disks[1].type === "nvme", "adopt: the disks each server CI lists");
const ad = adoptDisks(d1, found);
const adopted = ad.result && "doc" in ad.result ? ad.result.doc : null;
check(!!adopted && Object.values(adopted.assets ?? {}).filter((a) => a.kind === "disk").length === 3, "adopt: the unrecorded ones with a serial recorded (dsk-02 in srv-01, dsk-03 in srv-02)");
check(adopted?.placements?.["dsk-03"]?.in === "srv-02" && adopted.assets?.["dsk-03"]?.disk?.kind === "hdd" && adopted.assets["dsk-03"].displayName === "ata-HGST_HDN726050ALE614_NAHW317X", "adopt: in its server, its kind and by-id name");
check(ad.lines.some((l) => l.includes(BYID) && l.includes("dsk-01 already")), "adopt: a recorded one skipped, said");
check(ad.lines.some((l) => l.includes("usb-Generic_Flash") && l.includes("no serial")), "adopt: one without a serial skipped, said");
check(ad.lines.some((l) => l.startsWith("srv-09") && l.includes("not recorded")), "adopt: a server CI no asset records, said");
check(!!adopted && errs(adopted).length === 0, "adopt: the document stays valid");
check(adoptDisks(adopted!, found).result === null, "adopt: again, nothing to do");

console.log(`\ndisks: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
