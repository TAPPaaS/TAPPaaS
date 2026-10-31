// asset.test.ts — the asset behind a node (ADR-040 D8): the machine's identity
// as sysfs prints it, the match by serial then MAC, the --asset checks, the
// cabling an asset lends node add, the new asset's tag, the release, and
// what node delete does with the asset: kept, or removed.

import { PositionsDoc } from "../../../../lib/ts/src/positions";
import { IDENTITY_SH, assetCabling, assetFate, assetFillArgs, assetPlaying, assetProblem, assetRemovalSteps, diskArgs, freeServers, identityFromRegistration, matchAsset, newAssetArgs, parseIdentity } from "../../src/asset";

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
const id = parseIdentity("sys_vendor=Hewlett-Packard\nproduct_name=HP Z840 Workstation\nproduct_serial=CZC1234ABC\nnic=nic1 00:07:43:38:AA:F0\nnic=nic2 00:07:43:38:aa:f1\nnic=nic1 00:07:43:38:aa:f0\n");
check(id.vendor === "Hewlett-Packard" && id.model === "HP Z840 Workstation" && id.serial === "CZC1234ABC", "vendor, model and serial as DMI gives them");
check(id.macs.join() === "00:07:43:38:aa:f0,00:07:43:38:aa:f1", "MACs lower case, once each");
check(id.nics.map((n) => `${n.name}=${n.mac}`).join() === "nic1=00:07:43:38:aa:f0,nic2=00:07:43:38:aa:f1", "the NICs with their names");
check(parseIdentity("product_serial=To Be Filled By O.E.M.\n").serial === null, "a vendor's placeholder is no serial");
check(parseIdentity("product_serial=Default string\nnic=eth0 00:00:00:00:00:00\nnic=eth1 junk\n").macs.length === 0, "the zero MAC and junk are dropped");

// 1b. the identity the installer posted, on the consumed registration
const reg = identityFromRegistration({ name: "tappaas4", install_ip: "10.0.0.13", identity: { vendor: "Default string", model: "QDNV01", serial: "Default string", nics: [{ link: "enp2s0", mac: "AA:BB:CC:00:00:04" }, { link: "", mac: "aa:bb:cc:00:00:05" }] } });
check(!!reg && reg.vendor === "Default string" && reg.model === "QDNV01" && reg.serial === null, "the registration's vendor and model; its placeholder serial dropped");
check(!!reg && reg.nics.map((n) => `${n.name}=${n.mac}`).join() === "enp2s0=aa:bb:cc:00:00:04,nic2=aa:bb:cc:00:00:05", "NICs by link name, lower-case MACs, a nameless one numbered");
check(identityFromRegistration({ name: "tappaas4" }) === null, "a registration without identity: nothing");
check(identityFromRegistration({ identity: { serial: "To be filled by O.E.M.", nics: [] } }) === null, "nothing worth matching by: nothing");

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
const bySerial = matchAsset(doc, { vendor: null, model: null, serial: "CZC9999XYZ", macs: [], nics: [] });
check(!!bySerial && "key" in bySerial && bySerial.key === "srv-02" && bySerial.by === "serial", "a serial matches regardless of case");
check(matchAsset(doc, { vendor: null, model: null, serial: "CZC1234ABC", macs: [], nics: [] }) === null, "srv-01's serial does not match: it plays a role already");
const byMac = matchAsset(doc, { vendor: null, model: null, serial: "NEW1", macs: ["aa:bb:cc:00:00:03", "aa:bb:cc:00:00:04"], nics: [] });
check(!!byMac && "key" in byMac && byMac.key === "srv-03" && byMac.by === "mac", "no serial match, then a port's MAC");
check(matchAsset(doc, { vendor: null, model: null, serial: "ORDERED1", macs: [], nics: [] }) === null, "an ordered asset is not here to match");
const two: PositionsDoc = { ...doc, assets: { ...doc.assets, "srv-05": { kind: "server", stage: "stock", serial: "czc9999xyz" } } } as PositionsDoc;
const conflict = matchAsset(two, { vendor: null, model: null, serial: "CZC9999XYZ", macs: [], nics: [] });
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
check(n.ports.map((p) => p.join(" ")).join("; ") === "port add srv-05 nic1 --kind rj45 --mac 00:07:43:38:aa:f0; port add srv-05 nic2 --kind rj45 --mac 00:07:43:38:aa:f1", "a port per NIC, with its MAC, for the next match");
const bare = newAssetArgs(doc, { vendor: null, model: null, serial: null, macs: [], nics: [] }, "tappaas4");
check(bare.args.join(" ") === "asset add srv-05 --kind server --display-name tappaas4" && bare.ports.length === 0, "nothing known: kind and display name only");

// 6. the asset a role has, for the release
const p = assetPlaying(doc, "tappaas1");
check(!!p && p.key === "srv-01" && p.placed === "rack1 U20-U21", "the asset playing tappaas1 and where the role's placement is");
check(assetPlaying(doc, "tappaas9") === null, "no asset plays tappaas9");

// 5. the machine's disks (ADR-042 D4): read with its identity, recorded by node add
{
  const lsblk = JSON.stringify({ blockdevices: [
    { name: "sda", model: "Samsung SSD 870", serial: "S6P1", size: 1000204886016, type: "disk", tran: "sata", wwn: "0x5002538f4", rota: false },
    { name: "sdc", model: "ST4000", serial: "ZA11", size: 4000787030016, type: "disk", tran: "sata", rota: true },
    { name: "nvme0n1", model: "WD SN850", serial: "WD77", size: 2000398934016, type: "disk", tran: "nvme", rota: false },
    { name: "sdd", model: "Flash", serial: "USB1", size: 32000000000, type: "disk", tran: "usb", rota: "1" },
    { name: "zd0", size: 34359738368, type: "disk", rota: false },
    { name: "sr0", type: "rom" },
  ] });
  const out = [
    "sys_vendor=HP", "product_serial=CZC1",
    "byid=wwn-0x5002538f4 sda", "byid=ata-Samsung_SSD_870_S6P1 sda", "byid=nvme-eui.0025 nvme0n1", "byid=nvme-WD_SN850_WD77_1 nvme0n1", "byid=nvme-WD_SN850_WD77 nvme0n1",
    `lsblk=${lsblk}`,
  ].join("\n");
  const m = parseIdentity(out);
  const by = (s: string) => m.disks?.find((d) => d.serial === s);
  check(m.disks?.length === 4, `whole disks only: no zvol, no optical (${m.disks?.length})`);
  check(by("S6P1")?.name === "ata-Samsung_SSD_870_S6P1" && by("S6P1")?.type === "ssd" && by("S6P1")?.bus === "sata" && by("S6P1")?.size === 1000204886016 && by("S6P1")?.wwn === "0x5002538f4", "a disk by its vendor's by-id name, not its WWN; kind, bus, size, wwn");
  check(by("WD77")?.name === "nvme-WD_SN850_WD77" && by("WD77")?.type === "nvme", "an NVMe disk by its own name, not the EUI or a namespace's");
  check(by("ZA11")?.name === "sdc" && by("ZA11")?.type === "hdd", "no by-id link: the kernel's name; a spinning disk is an hdd");
  check(by("USB1")?.type === "usb", "a disk on USB");
  check(parseIdentity("sys_vendor=HP\n").disks === undefined, "no disk read: no disks, not none");
  check(IDENTITY_SH.includes("lsblk -J -d -b -o NAME,MODEL,SERIAL,SIZE,TYPE,TRAN,WWN") && IDENTITY_SH.includes("/dev/disk/by-id/"), "the ssh read: lsblk's whole disks and the by-id links");
  const posted = identityFromRegistration({ identity: { serial: "CZC1", nics: [], disks: [{ name: "ata-Samsung_SSD_870_S6P1", serial: "S6P1", size: 1000204886016, type: "ssd", bus: "sata" }, { serial: "nameless" }] } });
  check(posted?.disks?.length === 1 && posted.disks[0].serial === "S6P1" && posted.disks[0].size === 1000204886016, "the disks the installer posted, on the registration");
  check(identityFromRegistration({ identity: { serial: "CZC1", nics: [] } })?.disks === undefined, "a registration without disks leaves them to the ssh read");

  const docD: PositionsDoc = {
    assets: {
      "srv-05": { kind: "server", stage: "placed", role: "tappaas5" },
      "srv-01": { kind: "server", stage: "placed", role: "tappaas1" },
      "dsk-01": { kind: "disk", stage: "placed", serial: "S6P1", displayName: "ata-Samsung_SSD_870_S6P1" },
      "dsk-02": { kind: "disk", stage: "placed", serial: "za-11" },
      "dsk-03": { kind: "disk", stage: "stock", serial: "WD77" },
      "srv-09": { kind: "server", stage: "stock", serial: "USB1" },
    },
    placements: { "dsk-01": { in: "srv-05", bay: "1" }, "dsk-02": { in: "srv-01" } },
  };
  const plan = diskArgs(docD, "srv-05", [...m.disks!, { name: "sde" }, { name: "sdf", serial: "NEW1", type: "floppy", size: 1000 }]);
  const calls = plan.calls.map((c) => c.join(" "));
  check(!calls.some((c) => c.includes("dsk-01") || c.includes("S6P1")), "a disk the asset holds already: nothing");
  check(calls.includes("place dsk-02 --in srv-05"), "a disk recorded in another server (its serial as compared): moved in");
  check(calls.includes("place dsk-03 --in srv-05"), "a disk in stock: placed in");
  check(plan.notes.some((n) => n.includes("USB1") && n.includes("srv-09")), "a serial a non-disk asset has: a note, not a disk");
  check(plan.notes.some((n) => n.startsWith("sde has no serial")), "a disk without a serial: a note");
  check(calls.includes("disk add srv-05 sdf --serial NEW1 --size 1000"), `a new one: disk add, an unknown kind left out (${calls.join(" | ")})`);
}

// 7. node delete --asset: kept by default, removed for a lost node or on request
check(assetFate(undefined, false) === "keep", "the asset is kept by default");
check(assetFate(undefined, true) === "remove", "a lost node's asset is removed");
check(assetFate("keep", true) === "keep", "a lost node's asset kept when told");
check(assetFate("remove", false) === "remove", "remove on request");
const badFate = assetFate("dispose", false);
check(typeof badFate !== "string" && /keep or remove/.test(badFate.refused), "anything else is refused");

// 8. removing an asset: its cables by its own end, its placement, its record
const gone: PositionsDoc = {
  assets: {
    "srv-07": { kind: "server", stage: "placed", ports: [{ name: "1", kind: "rj45" }, { name: "2", kind: "rj45" }] },
    "srv-08": { kind: "server", stage: "stock" },
  },
  placements: { "srv-07": { rack: "rack1", u: 30, height: 1, width: "full", face: "front" } },
  cables: [
    { from: { device: "crs-a", port: "ether3" }, to: { device: "srv-07", port: "1" }, kind: "patch" },
    { from: { device: "srv-07", port: "2" }, to: { device: "pp-1", port: "4" }, kind: "patch" },
    { from: { device: "crs-a", port: "ether4" }, to: { device: "srv-08", port: "1" }, kind: "patch" },
  ],
} as unknown as PositionsDoc;
const rm = assetRemovalSteps(gone, "srv-07");
check(rm.steps.map((x) => x.join(" ")).join("; ") === "cable remove srv-07:1; cable remove srv-07:2; unplace srv-07; asset remove srv-07", `cables, then the placement, then the record (${rm.steps.map((x) => x.join(" ")).join("; ")})`);
check(rm.cables === 2 && rm.placed === "rack1 U30", "what it removes, for the preview");
check(assetRemovalSteps(gone, "srv-08").steps.map((x) => x.join(" ")).join("; ") === "cable remove srv-08:1; asset remove srv-08", "an asset in stock: no unplace");
const playing = assetRemovalSteps(doc, "srv-01");
check(playing.steps.map((x) => x.join(" ")).join("; ") === "unplace tappaas1; asset remove srv-01", "an asset still in a role is named as it plays");
check(assetRemovalSteps(gone, "srv-99").steps.length === 0, "no such asset: nothing");

// 9. node add completes a known asset's record from the machine
const fill: PositionsDoc = {
  assets: {
    "srv-10": { kind: "server", stage: "stock", serial: "SN10" },
    "srv-11": { kind: "server", stage: "stock", vendor: "HP", ports: [{ name: "enp1s0", kind: "rj45" }, { name: "enp2s0", kind: "rj45", mac: "aa:bb:cc:00:11:02" }] },
    "srv-12": { kind: "server", stage: "stock", ports: [{ name: "1", kind: "rj45" }] },
  },
} as unknown as PositionsDoc;
const mach = { vendor: "HP", model: "Z840", serial: "SN10", macs: ["aa:bb:cc:00:10:01"], nics: [{ name: "eno1", mac: "aa:bb:cc:00:10:01" }] };
const f10 = assetFillArgs(fill, "srv-10", mach);
check(f10.calls.map((c) => c.join(" ")).join("; ") === "asset modify srv-10 --set vendor=HP --set model=Z840; port add srv-10 eno1 --kind rj45 --mac aa:bb:cc:00:10:01" && !f10.note && !f10.mismatch,
  `what the record lacks, and a port per NIC on an asset with none (${f10.calls.map((c) => c.join(" ")).join("; ")})`);
const f11 = assetFillArgs(fill, "srv-11", { vendor: "HP", model: null, serial: "SN11", macs: [], nics: [{ name: "enp1s0", mac: "aa:bb:cc:00:11:01" }, { name: "enp2s0", mac: "aa:bb:cc:00:11:02" }] });
check(f11.calls.map((c) => c.join(" ")).join("; ") === "asset modify srv-11 --set serial=SN11; port modify srv-11 enp1s0 --set mac=aa:bb:cc:00:11:01", "a port named as the NIC gets its MAC; a known MAC and a recorded vendor stay");
const f12 = assetFillArgs(fill, "srv-12", { ...mach, serial: null });
check(f12.calls.length === 1 && !!f12.note && /srv-12's ports do not name these NICs: eno1/.test(f12.note), "ports under other names: not guessed, said");
const f13 = assetFillArgs(fill, "srv-10", { ...mach, serial: "OTHER" });
check(!!f13.mismatch && f13.calls.length === 0, "another machine's serial: nothing filled, said");

console.log(`asset: ${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
