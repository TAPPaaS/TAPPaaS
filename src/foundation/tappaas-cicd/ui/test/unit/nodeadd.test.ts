// nodeadd.test.ts — what the Add node wizard offers (web/src/nodeadd.ts, ADR-037
// D4): the switch ports a new node can be cabled to, the trunk a hand-configured
// port needs, and the data pool proposed from the node's free disks.

import { diskId, humanSize, manualSwitches, manualTrunkText, nodeTrunkVlans, poolDisks, proposedDisks, proposedLayout, proposedPoolName, switchPortChoices, writeProgress } from "../../web/src/nodeadd";
import { StorageDisk, TopoPort, TopoSwitch } from "../../web/src/types";
import { check, done } from "./check";

const port = (p: string, o: Partial<TopoPort> = {}): TopoPort => ({
  port: p, role: "", type: null, mode: "access", native: 0, tagged: [], zones: [], target: null, description: null,
  lag: null, drift: "in-sync", add: [], remove: [], seen: null, ...o,
});
const sw = (name: string, managed: string, ports: TopoPort[]): TopoSwitch => ({
  name, managed, ports, lldpName: null, vendor: null, model: null, managementIp: null, controller: null, controllerAddress: null, lags: [],
} as unknown as TopoSwitch);

const switches = [
  sw("USW Pro XG 10 PoE", "auto", [
    port("1", { parked: true, link: "down" }),
    port("2", { type: "node", target: { kind: "node", name: "tappaas2", port: null }, link: "up" }),
    port("3", { link: "up" }),
    port("4", { type: "node", target: { kind: "node", name: "tappaas4", port: null } }),
    port("11", { lag: "l1" }), port("12", { lagLead: "11" }),
    port("10", { link: "down" }),
    port("9", { target: { kind: "switch", name: "crs-b", port: "sfp-sfpplus15" }, link: "up" }),
  ]),
  sw("closet", "manual", [port("1")]),
];
const c = switchPortChoices(switches, "tappaas4");
check(c.map((x) => x.value).join() === "USW Pro XG 10 PoE:4,USW Pro XG 10 PoE:1,USW Pro XG 10 PoE:10,USW Pro XG 10 PoE:3",
  `the node's own port first, then free ports without a link, then with one (${c.map((x) => x.value).join()})`);
check(!c.some((x) => /:2$|:9$|:11$|:12$/.test(x.value)), "another node's port, an inter-switch link and an aggregate's are not offered");
check(!c.some((x) => x.value.startsWith("closet")), "a switch configured by hand offers no port");
check(c[1].label.includes("parked") && c[3].label.includes("link up"), "each says what it is");
check(manualSwitches(switches).join() === "closet", "the switches configured by hand are named");

const zones = [{ state: "Manual", vlantag: 0 }, { state: "Active", vlantag: 310 }, { state: "Mandatory", vlantag: 610 }, { state: "Inactive", vlantag: 320 }, { state: "Active", vlantag: 200 }];
check(nodeTrunkVlans(zones).join() === "200,310,610", "the trunk tags every active zone's VLAN, mgmt untagged");
check(manualTrunkText([200]).includes("untagged") && manualTrunkText([]).includes("no VLAN"), "the hand configuration says it");

const disk = (serial: string, size: number, type: StorageDisk["type"], o: Partial<StorageDisk> = {}): StorageDisk => ({
  device: `/dev/${serial}`, byId: null, model: "M1", serial, wwn: null, size, type, wearout: null, smart: null, zfs: null,
  exportedPool: null, error: null, state: "ok", reasons: [], ...o,
} as StorageDisk);
const free = [disk("H1", 8e12, "hdd"), disk("N1", 2e12, "nvme"), disk("N2", 2e12, "nvme"), disk("N3", 1e12, "nvme", { model: "M2" }),
  disk("BAD", 2e12, "nvme", { state: "warn" as StorageDisk["state"] })];
check(poolDisks(free).map(diskId).join() === "H1,N1,N2,N3", "a disk whose health is not ok is never proposed");
check(proposedDisks(free).map(diskId).join() === "N1,N2", "two fast disks alike: a mirror of them");
check(proposedDisks([disk("H1", 8e12, "hdd")]).map(diskId).join() === "H1", "only a spinning disk: that one");
check(proposedDisks([disk("BAD", 1e12, "ssd", { state: "fail" as StorageDisk["state"] })]).length === 0, "nothing healthy: nothing");
check(proposedLayout(1) === "single" && proposedLayout(2) === "mirror" && proposedLayout(3) === "raidz1", "the layout for a count");
check(proposedPoolName("nvme", []) === "tanka1" && proposedPoolName("hdd", ["tankb1"]) === "tankb2", "tanka for fast disks, tankb for spinning, the next free number");
check(humanSize(2e12) === "2.0 TB" && humanSize(8001563222016) === "8.0 TB" && humanSize(null) === "?", "sizes as the inventory says them");

// The stick write's progress bar: the last percent line of the output, then the flush.
{
  const out = "writing x (1.8 GB) to /dev/sdb in tappaas1\n   5%  88 of 1763 MB  24.5 MB/s, about 68 s left\n  41%  734 of 1763 MB  24.5 MB/s, about 40 s left\n";
  check(writeProgress(out)?.pct === 41 && writeProgress(out)?.text === "41% — 734 of 1763 MB  24.5 MB/s, about 40 s left", "the last percent line is where the write is");
  check(writeProgress("writing x\n") === null, "no percent line yet: nothing to show");
  check(writeProgress(out + "flushed; ejecting the stick\n")?.pct === 100, "the flush is the end");
}

done("nodeadd");
