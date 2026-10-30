// nodeadd.test.ts — what the Add node wizard offers (web/src/nodeadd.ts, ADR-037
// D4): the switch ports a new node can be cabled to, the trunk a hand-configured
// port needs, and the data pool proposed from the node's free disks.

import { diskId, humanSize, manualSwitches, manualTrunkText, nodeTrunkVlans, poolDisks, proposedDisks, proposedLayout, proposedPoolClass, proposedPoolName, switchPortChoices, writeProgress, POOL_CLASSES, NodeNetwork, NodePort, lanCandidates, lldpSwitchPort, portLabel, wanCandidates, wanPort, AddNodeFacts, NodeAddJob, SESSION_MS, STAGE_NUMBER, addNodeStage, addNodeUnderway, latestNodeAdd, nodeAddName, nodeAddOngoing, setupFromOutput } from "../../web/src/nodeadd";
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
check(proposedPoolClass("nvme") === "a" && proposedPoolClass("hdd") === "b", "tanka proposed for fast disks, tankb for spinning");
check(proposedPoolName("a", []) === "tanka1" && proposedPoolName("b", ["tankb1"]) === "tankb2" && proposedPoolName("c", ["tanka1"]) === "tankc1", "the class's next free number");
check(POOL_CLASSES.map((c) => c.cls).join() === "a,b,c" && POOL_CLASSES[2].label.includes("backups"), "three classes, tankc the backups");
check(humanSize(2e12) === "2.0 TB" && humanSize(8001563222016) === "8.0 TB" && humanSize(null) === "?", "sizes as the inventory says them");

// The stick write's progress bar: the last percent line of the output, then the flush.
{
  const out = "writing x (1.8 GB) to /dev/sdb in tappaas1\n   5%  88 of 1763 MB  24.5 MB/s, about 68 s left\n  41%  734 of 1763 MB  24.5 MB/s, about 40 s left\n";
  check(writeProgress(out)?.pct === 41 && writeProgress(out)?.text === "41% — 734 of 1763 MB  24.5 MB/s, about 40 s left", "the last percent line is where the write is");
  check(writeProgress("writing x\n") === null, "no percent line yet: nothing to show");
  check(writeProgress(out + "flushed; ejecting the stick\n")?.pct === 100, "the flush is the end");
}

// A node's uplinks (stages 5a and 5b), as tappaas4's read showed them.
{
  const np = (name: string, mac: string, state: string, speed: number, lldp: NodePort["lldp"] = null): NodePort => ({ name, mac, state, speed, usb: false, lldp });
  const e1 = np("enp4s0", "m:87", "up", 2500, { chassis: "c", name: "USW-Pro-XG-10-PoE", port: "Port 1" });
  const e2 = np("enp5s0", "m:88", "up", 10000, { chassis: "c", name: "USW-Pro-XG-10-PoE", port: "Port 8" });
  const w = np("eno1", "m:8c", "down", -1);
  const net: NodeNetwork = { node: "tappaas4", live: { ports: [w, e1, e2], lan: { mode: "single", bond: "", members: [e1] }, wan: { members: [w] } }, declared: { lan: { ports: ["m:87"] }, wan: { ports: ["m:8c"] } }, findings: [] };
  check(portLabel(e1) === "enp4s0 · up 2.5G · USW-Pro-XG-10-PoE Port 1" && portLabel(w) === "eno1 · no link", "a port says its link and the switch port behind it");
  check(lanCandidates(net).map((p) => p.name).join() === "enp5s0", "a lan leg comes from neither lan nor the WAN");
  check(wanCandidates(net).map((p) => p.name).join() === "eno1,enp5s0", "the WAN takes any port lan does not have");
  check(wanPort(net)?.name === "eno1" && wanPort({ ...net, declared: { lan: net.declared!.lan } }) === null, "the declared WAN port, or none");
  const choices = [{ value: "USW Pro XG 10 PoE:8", label: "" }, { value: "USW Pro XG 10 PoE:10", label: "" }];
  check(lldpSwitchPort(e2, choices) === "USW Pro XG 10 PoE:8" && lldpSwitchPort(w, choices) === null, "LLDP's switch port is preselected when it is a free one");
}

// ── an Add node session, found again from the records ──────────────
{
  const now = Date.parse("2026-10-28T14:00:00Z");
  const job = (o: Partial<NodeAddJob> = {}): NodeAddJob => ({
    id: "20261028120000-abc123", kind: "apply", state: "running", bin: "site-manager", verb: "node add",
    argv: ["site-manager", "node", "add", "tappaas4", "--yes", "--no-wan", "--mac", "58:47:ca:7a:12:34"], object: "tappaas4",
    created: "2026-10-28T12:00:00Z", ended: null, exit: null, ...o,
  });
  check(nodeAddName(job()) === "tappaas4" && nodeAddName(job({ argv: ["site-manager", "node", "add", "--yes", "tappaas5"], object: "tappaas5" })) === "tappaas5", "the node a node add names: its first positional after the verb");
  check(nodeAddName(job({ argv: ["site-manager", "node", "add", "pve-x"], object: "pve-x" })) === null, "…a name outside tappaas1..9 is none");
  const other = job({ id: "x", verb: "node storage add", argv: ["site-manager", "node", "storage", "add", "tappaas3", "tankb1"] });
  check(latestNodeAdd([other, job()])?.name === "tappaas4", "the newest node add, other verbs passed over");
  check(latestNodeAdd([job({ id: "r", state: "refused", argv: ["site-manager", "node", "add", "tappaas5"], object: "tappaas5" }), job()])?.job.id === "20261028120000-abc123", "a refused one never ran: the one before it");
  check(latestNodeAdd([job({ kind: "preview" })]) === null && latestNodeAdd([job({ cancelled: { was: "queued" } })]) === null, "a preview, or one cancelled in the queue, is no session");

  const joined = { registration: "answered" as const, inCluster: true, inSite: true };
  const done_ = job({ state: "done", ended: "2026-10-28T12:25:00Z", exit: 0 });
  check(nodeAddOngoing(job(), now, { progress: null, dataPool: null, lanPorts: null }) === true, "a node add that runs is ongoing, whatever the reads say yet");
  check(nodeAddOngoing(done_, now, { progress: joined, dataPool: false, lanPorts: null }) === true, "joined with no data pool: still being added");
  check(nodeAddOngoing(done_, now, { progress: joined, dataPool: true, lanPorts: 1 }) === true, "…or with one lan port");
  check(nodeAddOngoing(done_, now, { progress: joined, dataPool: true, lanPorts: 2 }) === false, "a pool and a bonded lan: finished");
  check(nodeAddOngoing(done_, now, { progress: joined, dataPool: true, lanPorts: null }) === null, "…not known while its ports are still read");
  check(nodeAddOngoing(done_, now + 2 * SESSION_MS, { progress: joined, dataPool: false, lanPorts: 1 }) === false, "a day after its job ended it is no session any more");
  check(nodeAddOngoing(job({ state: "done", ended: "2026-10-28T12:25:00Z", exit: 1 }), now, { progress: { registration: "none", inCluster: false, inSite: false }, dataPool: null, lanPorts: null }) === false, "a job that failed before the join leaves nothing to continue");
  check(nodeAddOngoing(job({ state: "done", ended: "2026-10-28T12:25:00Z", exit: 130, cancelled: { was: "running" } }), now, { progress: joined, dataPool: false, lanPorts: 1 }) === false, "one an operator stopped is over");

  const f = (o: Partial<AddNodeFacts>): AddNodeFacts => ({ job: true, jobLive: true, progress: null, pooled: false, lan: false, wan: false, ...o });
  check(addNodeStage(f({ job: false, jobLive: false })) === "declare", "nothing applied, nothing registered: stage 1");
  check(addNodeStage(f({ progress: { registration: "pending", inCluster: false, inSite: false } })) === "boot", "registered, the machine not asked yet: stage 2");
  check(addNodeStage(f({ progress: { registration: "none", inCluster: false, inSite: false } })) === "boot", "a job running before its registration is written: stage 2");
  check(addNodeStage(f({ jobLive: false, progress: { registration: "none", inCluster: false, inSite: false } })) === "wait", "…ended without it: stage 3, where its output is");
  check(addNodeStage(f({ progress: { registration: "answered", inCluster: false, inSite: false } })) === "wait", "answered, installing: stage 3");
  check(addNodeStage(f({ jobLive: false, progress: joined })) === "storage" && addNodeStage(f({ progress: joined, pooled: true })) === "lan" && addNodeStage(f({ progress: joined, pooled: true, lan: true })) === "wan", "joined: the pools, then lan, then the WAN");
  check(STAGE_NUMBER.lan === "5a" && STAGE_NUMBER.wait === "3", "stages are numbered as the wizard shows them");
  check(addNodeUnderway({ job: false, progress: joined }) && !addNodeUnderway({ job: false, progress: { registration: "none", inCluster: false, inSite: false } }), "underway: a job, or the records say so");
}

{
  const out = "[node add 1] the switch port: USW port 1\n  ✓ USW port 1 is tappaas4's: a node trunk, on the switch\n\n[node add 2] register 'tappaas4'\n";
  check(!setupFromOutput(out).ready && setupFromOutput(out).step === "register 'tappaas4'", "still setting up: the step it is on");
  check(setupFromOutput(out).port === "USW port 1 is tappaas4's: a node trunk, on the switch", "the switch port it set up");
  check(setupFromOutput(out + "[node add 3] boot the machine now: from the network\n").ready, "ready once it says to boot");
  check(setupFromOutput("").step === null, "no output yet: no step");
}

done("nodeadd");
