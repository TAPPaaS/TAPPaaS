// asset.test.ts — the asset behind a node (ADR-040 D8): the machine's identity
// as sysfs prints it, the match by serial then MAC, the --asset checks, the
// cabling an asset lends node add, the new asset's tag, and the release.

import { PositionsDoc } from "../../../../lib/ts/src/positions";
import { assetCabling, assetPlaying, assetProblem, freeServers, matchAsset, newAssetArgs, parseIdentity } from "../../src/asset";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

// 1. identity: the DMI fields, placeholders dropped, physical MACs only
const id = parseIdentity("sys_vendor=Hewlett-Packard\nproduct_name=HP Z840 Workstation\nproduct_serial=CZC1234ABC\nmac=00:07:43:38:AA:F0\nmac=00:07:43:38:aa:f1\nmac=00:07:43:38:aa:f0\n");
check(id.vendor === "Hewlett-Packard" && id.model === "HP Z840 Workstation" && id.serial === "CZC1234ABC", "vendor, model and serial as DMI gives them");
check(id.macs.join() === "00:07:43:38:aa:f0,00:07:43:38:aa:f1", "MACs lower case, once each");
check(parseIdentity("product_serial=To Be Filled By O.E.M.\n").serial === null, "a vendor's placeholder is no serial");
check(parseIdentity("product_serial=Default string\nmac=00:00:00:00:00:00\nmac=junk\n").macs.length === 0, "the zero MAC and junk are dropped");

// 2. the match: serial first, then a port's MAC; only free servers
const doc: PositionsDoc = {
  assets: {
    "srv-01": { kind: "server", stage: "placed", role: "tappaas1", serial: "CZC1234ABC" },
    "srv-02": { kind: "server", stage: "placed", serial: "czc9999xyz" },
    "srv-03": { kind: "server", stage: "stock", ports: [{ name: "1", kind: "rj45", mac: "aa:bb:cc:00:00:03" }, { name: "2", kind: "rj45" }] },
    "srv-04": { kind: "server", stage: "ordered", serial: "ORDERED1" },
    "sw-01": { kind: "switch", stage: "placed", serial: "SWITCH1" },
  },
  placements: { "srv-02": { rack: "rack1", u: 10, height: 2, width: "full", face: "front" }, tappaas1: { rack: "rack1", u: 20, height: 2, width: "full", face: "front" } },
  cables: [{ from: { device: "crs-a", port: "ether7" }, to: { device: "srv-03", port: "1" }, kind: "patch" }],
} as unknown as PositionsDoc;
check(freeServers(doc).map(([k]) => k).join() === "srv-02,srv-03", "free servers: no role, here (not ordered), servers only");
const bySerial = matchAsset(doc, { vendor: null, model: null, serial: "CZC9999XYZ", macs: [] });
check(!!bySerial && "key" in bySerial && bySerial.key === "srv-02" && bySerial.by === "serial", "a serial matches regardless of case");
check(matchAsset(doc, { vendor: null, model: null, serial: "CZC1234ABC", macs: [] }) === null, "srv-01's serial does not match: it plays a role already");
const byMac = matchAsset(doc, { vendor: null, model: null, serial: "NEW1", macs: ["aa:bb:cc:00:00:03", "aa:bb:cc:00:00:04"] });
check(!!byMac && "key" in byMac && byMac.key === "srv-03" && byMac.by === "mac", "no serial match, then a port's MAC");
check(matchAsset(doc, { vendor: null, model: null, serial: "ORDERED1", macs: [] }) === null, "an ordered asset is not here to match");
const two: PositionsDoc = { ...doc, assets: { ...doc.assets, "srv-05": { kind: "server", stage: "stock", serial: "czc9999xyz" } } } as PositionsDoc;
const conflict = matchAsset(two, { vendor: null, model: null, serial: "CZC9999XYZ", macs: [] });
check(!!conflict && "conflict" in conflict && /srv-02, srv-05/.test(conflict.conflict), "two assets with one serial: a conflict, not a guess");

// 3. --asset before the install
check(assetProblem(doc, "srv-02") === null, "a free server is fine");
check(/not recorded/.test(assetProblem(doc, "srv-99") ?? ""), "an unknown asset");
check(/is a switch/.test(assetProblem(doc, "sw-01") ?? ""), "a switch is no node");
check(/ordered/.test(assetProblem(doc, "srv-04") ?? ""), "an ordered asset is not here yet");
check(/plays tappaas1 already/.test(assetProblem(doc, "srv-01") ?? ""), "an asset in a role");

// 4. what an asset's records lend node add
const cab = assetCabling(doc, "srv-03");
check(cab.switchPort === "crs-a:ether7" && cab.mac === "aa:bb:cc:00:00:03" && cab.port === "1", "the recorded cable's other end, and the cabled port's MAC");
check(assetCabling(doc, "srv-02").switchPort === null && assetCabling(doc, "srv-02").mac === null, "nothing recorded: nothing lent");

// 5. the new asset: the next tag, the identity, the role as display name
const n = newAssetArgs(doc, id, "tappaas4");
check(n.key === "srv-05", "the next free server tag (srv-04 exists, ordered)");
check(n.args.join(" ") === "asset add srv-05 --kind server --display-name tappaas4 --vendor Hewlett-Packard --model HP Z840 Workstation --serial CZC1234ABC", "asset add with what the machine said");
check(newAssetArgs(doc, { vendor: null, model: null, serial: null, macs: [] }, "tappaas4").args.join(" ") === "asset add srv-05 --kind server --display-name tappaas4", "nothing known: kind and display name only");

// 6. the asset a role has, for the release
const p = assetPlaying(doc, "tappaas1");
check(!!p && p.key === "srv-01" && p.placed === "rack1 U20-U21", "the asset playing tappaas1 and where the role's placement is");
check(assetPlaying(doc, "tappaas9") === null, "no asset plays tappaas9");

console.log(`asset: ${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
