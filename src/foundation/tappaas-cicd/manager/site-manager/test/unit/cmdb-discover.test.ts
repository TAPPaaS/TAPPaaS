// cmdb-discover.test.ts — `site-manager report --discover` (ADR-040 D15) over
// fixtures of pvesh, lsblk, zpool, ethtool: the ports, disks and pools; a NIC
// with no link and a disk in no pool appear; the plain report is unchanged.

// Verbs run here report changes: never to a live CMDB (test.sh sets this too).
process.env.TAPPAAS_CMDB = "off";

import { run } from "../../src/main";
import { disksAttribute, nodeDiscoveryProbe, nodeStorageProbe, parseNodeDiscovery, parseNodeStorage, parseCorosync, stableById } from "../../src/cmdb-discover";
import { parseClusterProbe, splitStorage } from "../../src/cmdb-report";
import { FakeSiteClient } from "./fake-client";
import { cmdbProblems } from "../../../../lib/ts/test/cmdb-check";
import { mkdtempSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

function capture(f: () => unknown): string[] {
  const out: string[] = [];
  const log = console.log;
  const err = console.error;
  console.log = (m: string) => void out.push(String(m));
  console.error = (m: string) => void out.push(String(m));
  try {
    f();
  } finally {
    console.log = log;
    console.error = err;
  }
  return out;
}

type Obj = Record<string, any>;

// test/fixtures, from dist-test/manager/site-manager/test/unit.
const FIXTURE = readFileSync(join(__dirname, "..", "..", "..", "..", "..", "test", "fixtures", "discover-node.txt"), "utf8");
const d = parseNodeDiscovery(FIXTURE);

// ── the parsers ────────────────────────────────────────────────────────
{
  const nic = (n: string): Obj | undefined => d.nics.find((x) => x.name === n);
  check(d.nics.length === 3, `every NIC, used or not (${d.nics.length})`);
  const eno1 = nic("eno1");
  check(eno1?.mac === "aa:bb:cc:00:00:01", `a bond slave's own MAC, not the bond's (${eno1?.mac})`);
  check(eno1?.kind === "rj45" && eno1?.speed === "1g" && eno1?.link === true, "kind, D9 speed, link");
  check(eno1?.bond === "bond0" && eno1?.bridge === "lan", "the bond it is in and that bond's bridge");
  check(eno1?.linkSpeed === "1g", "the speed negotiated now");
  const sfp = nic("enp2s0f0");
  check(sfp?.kind === "sfp" && sfp?.speed === "10g", "a fibre port is an sfp at its fastest mode");
  check(sfp?.linkSpeed === undefined, "no link, no negotiated speed");
  check(sfp?.link === false && sfp?.bond === undefined && sfp?.bridge === undefined, "a NIC with no link, in nothing");
  const slow = nic("enp3s0");
  check(slow?.speed === undefined && slow?.maxMbps === 100 && slow?.bridge === "wan", "100M: no D9 speed, the maximum kept");

  check(d.disks.length === 4, `every disk (${d.disks.length})`);
  const a = d.disks.find((x) => x.serial === "S6P1")!;
  check(a.name === "ata-Samsung_SSD_870_S6P1" && a.bus === "sata" && a.type === "ssd" && a.health === "PASSED", "by-id name, bus, type, health");
  check(a.partitions.map((p) => p.holds).join() === "bios-boot,efi,zfs", `partitions and what each holds (${a.partitions.map((p) => p.holds)})`);
  check(a.partitions[2].pool === "rpool", "the ZFS member's pool");
  const nv = d.disks.find((x) => x.serial === "WD77")!;
  check(nv.health === "FAILED" && nv.partitions[0].holds === "swap" && nv.bus === "nvme", "SMART health, swap");
  check(stableById("/dev/disk/by-id/nvme-AS806_8061TB_1") === "nvme-AS806_8061TB", "an NVMe namespace link is the disk's one name");
  check(stableById("nvme-WD_BLACK_1TB_260923802321") === "nvme-WD_BLACK_1TB_260923802321", "…an all-digit serial is kept");
  const lone = d.disks.find((x) => x.serial === "ZA11")!;
  check(lone.holds === "nothing" && lone.partitions.length === 0, "a disk in no pool, holding nothing");

  const r = d.pools.find((p) => p.name === "rpool")!;
  check(r.state === "ONLINE" && r.size === 900000000000 && r.used === 100000000000, "pool: state, usable size and used, as storage-manager");
  check(r.vdevs.length === 1 && r.vdevs[0].name === "mirror-0", "a mirror vdev");
  check(r.vdevs[0].members.map((m) => m.serial).join() === "S6P1,S6P2", "members by serial");
  const t = d.pools.find((p) => p.name === "tanka1")!;
  check(t.state === "DEGRADED" && t.vdevs[0].name === "disk" && t.vdevs[0].members[0].serial === "WD77", "a single-disk vdev");
  check(t.vdevs[1]?.group === "cache", "a cache vdev is grouped");
  check(d.cpu?.startsWith("Intel") === true && d.cpus === 28 && d.memory === 131072, "CPU and memory");
  check(d.storages.length === 2 && d.storages[1].type === "zfspool", "the storages the node knows");
  check(d.pci[0]?.vendor === "NVIDIA Corporation" && d.pci[0]?.iommuGroup === 14, "PCI devices");
  const links = parseCorosync("Local node ID 1, transport knet\nnodeid: 2 reachable\n   LINK: 0 udp (10.0.0.11->10.0.0.12) enabled connected mtu: 1397\n");
  check(links[0]?.nodeid === 2 && links[0]?.connected === true && links[0]?.remote === "10.0.0.12", "corosync links");
}

// ── report --discover ──────────────────────────────────────────────────
const CLUSTER = [
  "@@status",
  JSON.stringify([{ type: "cluster", quorate: 1 }, { type: "node", name: "tappaas1", online: 1 }, { type: "node", name: "tappaas2", online: 1 }]),
  "@@resources",
  JSON.stringify([{ type: "qemu", vmid: 140, name: "identity", node: "tappaas1" }, { type: "lxc", vmid: 201, name: "ct", node: "tappaas2" }]),
  "@@ha",
  "[]",
  "@@conf /etc/pve/nodes/tappaas1/qemu-server/140.conf",
  "cores: 2\nnet0: virtio=BC:24:11:00:00:01,bridge=lan,tag=200\nscsi0: tanka1:vm-140-disk-0,size=32G",
  "@@conf /etc/pve/nodes/tappaas2/lxc/201.conf",
  "rootfs: tankb1:subvol-201-disk-0,size=8G\nmp0: tankb1:subvol-201-disk-1,size=4G\nnet0: name=eth0,bridge=lan,hwaddr=BC:24:11:00:00:02,ip=dhcp",
  "@@corosync",
  "nodeid: 2 reachable\n   LINK: 0 udp (10.0.0.11->10.0.0.12) enabled connected mtu: 1397",
].join("\n");

function fixture(): string {
  const cfg = mkdtempSync(join(tmpdir(), "discover-"));
  const w = (f: string, v: unknown): void => writeFileSync(join(cfg, f), JSON.stringify(v));
  w("site.json", { name: "hrossen" });
  w("tappaas1.json", { moduleSource: "/r/pvehost", kind: "machine", version: "0.3.0", address: "tappaas1.mgmt.internal" });
  w("tappaas2.json", { moduleSource: "/r/pvehost", kind: "machine", version: "0.3.0", address: "tappaas2.mgmt.internal" });
  // tappaas1 stands on a recorded server, whose eno1 is labelled lan1.
  w("positions.json", { assets: { "srv-01": { kind: "server", role: "tappaas1", ports: [{ name: "lan1", kind: "rj45", speed: "10g", mac: "AA:BB:CC:00:00:01" }] } } });
  return cfg;
}

function report(extra: string[], cfg: string): Obj {
  const fake = new FakeSiteClient();
  fake.cluster = parseClusterProbe(CLUSTER);
  fake.cluster.hosts.tappaas1 = { discovery: d };
  fake.cluster.hosts.tappaas2 = { discovery: d };
  return JSON.parse(capture(() => run(["report", "--json", ...extra, "--config-dir", cfg], fake)).join("\n"));
}

// The fields D15 needs and cmdb-controller's metamodel does not have yet; the
// store refuses these until they are added. Anything else is a bug here.

{
  const r = report(["--discover"], fixture());
  const objs: Obj[] = r.objects;
  const one = (c: string, n: string): Obj | undefined => objs.find((o) => o.class === c && o.name === n);
  const left = cmdbProblems(r);
  check(left.length === 0, `the metamodel takes the rest: ${left.join("; ")}`);

  const srv = one("server", "srv-01");
  check(srv?.attributes?.disks?.length === 4 && srv?.attributes?.nics?.length === 3, "disks[] and nics[] on the server the machine is allocated to");
  check(srv?.attributes?.cpu?.startsWith("Intel") && srv?.attributes?.memory === 131072, "its CPU and memory");
  check(srv?.attributes?.serial === undefined, "a sweep sets no asset identity");
  const m1 = one("machine", "tappaas1");
  check(m1?.attributes?.disks === undefined && m1?.attributes?.pciDevices?.length === 1 && m1?.attributes?.storages?.length === 2, "the machine keeps what is the node's");
  const m2 = one("machine", "tappaas2");
  check(m2?.attributes?.disks?.some((x: Obj) => x.serial === "ZA11") && m2?.attributes?.nics?.some((n: Obj) => n.link === false), "no asset: on the machine, the idle disk and NIC too");

  const ports = objs.filter((o) => o.class === "port");
  check(ports.length === 3 && ports.every((p) => p.attributes.asset.ref === srv?.ref), "a port per NIC, of the server only");
  const lan1 = ports.find((p) => p.name === "lan1");
  check(lan1?.attributes?.mac === "aa:bb:cc:00:00:01" && lan1?.attributes?.speed === undefined, "a recorded port keeps its name; asset-manager's speed stands");
  check(ports.some((p) => p.name === "enp2s0f0" && p.attributes.kind === "sfp" && p.attributes.speed === "10g"), "the NIC with no link is a port");
  check(!ports.some((p) => p.name === "eno1"), "no second port for the same MAC");
  check(lan1?.attributes?.link === "up" && lan1?.attributes?.linkSpeed === "1g", "a port carries its link, for health-manager to judge");
  check(ports.find((p) => p.name === "enp2s0f0")?.attributes?.link === "down", "…down too");

  const pools = objs.filter((o) => o.class === "storage-pool");
  const pool = pools.find((p) => p.name === "rpool" && p.attributes.onNode.ref === m1?.ref);
  check(pool?.attributes?.onNode?.ref === m1?.ref && pool?.attributes?.vdevs?.[0]?.members?.length === 2, "a pool, on its node, with its layout");
  check(pool?.attributes?.zfsState === "ONLINE", "ZFS's word for it");
  check(pools.filter((p) => p.name === "tanka1").length === 2, "per node");
  check(one("cluster", "hrossen")?.attributes?.corosyncLinks?.[0]?.connected === true, "corosync links on the cluster");
  const vm = one("vm", "identity");
  check(vm?.attributes?.nics?.[0]?.bridge === "lan" && vm?.attributes?.nics?.[0]?.tag === 200 && vm?.attributes?.nics?.[0]?.mac === "bc:24:11:00:00:01", "a guest's NICs");
  check(vm?.attributes?.disks?.[0]?.storage === "tanka1", "and the storage each disk sits on");
  const ct = one("lxc", "ct");
  check(ct?.attributes?.nics?.[0]?.name === "eth0" && ct?.attributes?.disks?.[0]?.size === "4G", "an lxc's NIC and mount point");
}

// Without --discover the report stays as it is.
{
  const r = report([], fixture());
  const objs: Obj[] = r.objects;
  check(!objs.some((o) => o.class === "port" || o.class === "server" || o.class === "storage-pool"), "plain report: no ports, assets or pools");
  check(!JSON.stringify(r).includes("nics") && !JSON.stringify(r).includes("corosyncLinks") && cmdbProblems(r).length === 0, "plain report: no depth, and the metamodel takes it");
}

// ── disks as CIs (ADR-042): a disk the server's asset records, built-on ──
// The sweep reads SMART per disk; the plain report the disks and pools only.
const SMART = [
  "@@section smart /dev/sda",
  JSON.stringify({ health: "PASSED", type: "ata", attributes: [{ id: "  5", raw: "8" }, { id: "  9", raw: "21000" }, { id: "194", raw: "41 (Min/Max 20/55)" }] }),
  "",
  "@@rc 0",
  "@@section smart /dev/nvme0n1",
  JSON.stringify({ health: "FAILED", type: "text", text: "Temperature:   75 Celsius\nMedia and Data Integrity Errors:    3\n" }),
  "",
  "@@rc 0",
].join("\n");
const swept = parseNodeDiscovery(`${FIXTURE}\n${SMART}\n`);
{
  const sda = swept.disks.find((x) => x.device === "/dev/sda")!;
  check(sda.smart?.reallocated === 8 && sda.smart?.powerOnHours === 21000 && sda.temperature === 41, "the sweep: a disk's SMART attributes and temperature");
  const nv = swept.disks.find((x) => x.device === "/dev/nvme0n1")!;
  check(nv.temperature === 75 && nv.smart?.mediaErrors === 3, "…an NVMe disk's from smartctl's text");
  check(swept.disks.find((x) => x.device === "/dev/sdc")?.smart === undefined, "…none where SMART was not read");
  check(nodeDiscoveryProbe("tappaas1").includes("disks/smart --disk") && !nodeStorageProbe("tappaas1").includes("disks/smart"), "SMART in the sweep's read only");
  const st = parseNodeStorage(FIXTURE);
  check(st.disks.length === 4 && st.pools.length === 2 && st.disks.every((x) => x.smart === undefined), "the plain report's read: the disks and pools, no SMART");
  const [own, rest] = splitStorage("os=debian\npools=tanka1\n@@@storage\n@@section disks\n[]\n@@rc 0\n");
  check(own.includes("os=debian") && !own.includes("@@section") && rest?.startsWith("@@section disks") === true && splitStorage("os=debian")[1] === null, "one ssh: the host's read, then its storage's");
}

// ── the server's disks[]: the same disks read twice are the same attribute ──
// pvesh and lsblk answer in no fixed order, and SMART moves on every read:
// the array is sorted and keeps no measurement (those are the disk CI's).
function section(text: string, name: string, f: (v: any) => any): string {
  return text.replace(new RegExp(`(@@section ${name}\\n)([\\s\\S]*?)\\n\\n@@rc`), (_m, head: string, body: string) => `${head}${JSON.stringify(f(JSON.parse(body)))}\n\n@@rc`);
}
{
  const smart2 = SMART.replace(/"21000"/, '"21007"').replace("41 (Min", "44 (Min").replace("Temperature:   75", "Temperature:   71");
  let other = section(FIXTURE, "disks", (rows: Obj[]) => [...rows].reverse().map((r) => ({ ...r, wearout: (Number(r.wearout) || 90) - 1 })));
  other = section(other, "lsblk", (b: Obj) => ({ blockdevices: [...b.blockdevices].reverse().map((x: Obj) => ({ ...x, children: x.children ? [...x.children].reverse() : x.children })) }));
  check(other !== FIXTURE, "the second read differs from the first (order, SMART)");
  const again = parseNodeDiscovery(`${other}\n${smart2}\n`);
  check(JSON.stringify(again.disks.map((x) => x.name)) === JSON.stringify(swept.disks.map((x) => x.name)), "parseDisks: by by-id name, whatever order pvesh lists them in");
  const a1 = disksAttribute(swept.disks) as Obj[];
  const a2 = disksAttribute(again.disks) as Obj[];
  check(JSON.stringify(a1) === JSON.stringify(a2), `two reads in a different order, with other SMART: the same disks[] (${JSON.stringify(a1).slice(0, 120)} vs ${JSON.stringify(a2).slice(0, 120)})`);
  check(a1.every((x) => x.temperature === undefined && x.wearout === undefined && x.smart === undefined), "disks[] keeps no measurement");
  const sda = a1.find((x) => x.device === "/dev/sda")!;
  check(sda.serial === "S6P1" && sda.model !== undefined && sda.health === "PASSED" && sda.partitions.map((p: Obj) => p.holds).join() === "bios-boot,efi,zfs" && sda.partitions[2].pool === "rpool", "…and what identifies a disk, what it and its partitions hold");
  check(a1.map((x) => x.name).join() === [...a1.map((x) => x.name)].sort((x, y) => x.localeCompare(y, "en", { numeric: true })).join(), "…sorted by by-id name");
}

function diskFixture(): string {
  const cfg = fixture();
  // srv-01 (tappaas1) holds four recorded disks: both rpool mirror members,
  // the NVMe of tanka1, and the idle one; one more disk is recorded elsewhere.
  writeFileSync(join(cfg, "positions.json"), JSON.stringify({
    assets: {
      "srv-01": { kind: "server", role: "tappaas1", stage: "placed", ports: [{ name: "lan1", kind: "rj45", speed: "10g", mac: "AA:BB:CC:00:00:01" }] },
      "srv-02": { kind: "server", stage: "stock" },
      "dsk-01": { kind: "disk", stage: "placed", serial: "S6P1" },
      "dsk-02": { kind: "disk", stage: "placed", serial: "s6p2" },
      "dsk-03": { kind: "disk", stage: "placed", serial: "WD77" },
      "dsk-04": { kind: "disk", stage: "placed", serial: "ZA11" },
      "dsk-05": { kind: "disk", stage: "placed", serial: "ELSEWHERE" },
    },
    placements: { "dsk-01": { in: "srv-01" }, "dsk-02": { in: "srv-01" }, "dsk-03": { in: "srv-01" }, "dsk-04": { in: "srv-01" }, "dsk-05": { in: "srv-02" } },
  }));
  return cfg;
}

for (const mode of ["--discover", "plain"]) {
  const fake = new FakeSiteClient();
  fake.cluster = parseClusterProbe(CLUSTER);
  if (mode === "--discover") fake.cluster.hosts.tappaas1 = { discovery: swept };
  else fake.cluster.hosts.tappaas1 = { storage: parseNodeStorage(FIXTURE) };
  const r: Obj = JSON.parse(capture(() => run(["report", "--json", ...(mode === "plain" ? [] : [mode]), "--config-dir", diskFixture()], fake)).join("\n"));
  const objs: Obj[] = r.objects;
  const rels: Obj[] = r.relations;
  const at = mode === "plain" ? "plain report" : "report --discover";
  const left = cmdbProblems(r);
  check(left.length === 0, `${at}: the metamodel takes the disks and built-on: ${left.join("; ")}`);
  const disks = objs.filter((o) => o.class === "disk");
  check(disks.map((o) => o.name).sort().join() === "dsk-01,dsk-02,dsk-03,dsk-04", `${at}: a disk CI for each disk the server's asset records, by serial (${disks.map((o) => o.name)})`);
  check(disks.every((o) => o.attributes.asset.ref === "server/srv-01"), `${at}: each part of the server`);
  const d3 = disks.find((o) => o.name === "dsk-03")!;
  check(d3.attributes.health === "FAILED" && d3.attributes.holds !== undefined && Array.isArray(d3.attributes.partitions), `${at}: its health, what it holds, its partitions`);
  const d1 = disks.find((o) => o.name === "dsk-01")!;
  if (mode === "plain") check(d1.attributes.smart === undefined && d1.attributes.temperature === undefined, "plain report: no SMART");
  else check(d1.attributes.smart?.reallocated === 8 && d1.attributes.temperature === 41, "report --discover: SMART on the disk CI");
  const built = rels.filter((x) => x.type === "built-on" && !x.end);
  const to = (ref: string) => built.filter((x) => x.to.ref === ref);
  const rpool = objs.find((o) => o.class === "storage-pool" && o.name === "rpool" && o.attributes.onNode.ref === "machine/tappaas1");
  check(!!rpool?.ref && to("disk/dsk-01").length === 1 && to("disk/dsk-01")[0].from.ref === rpool.ref, `${at}: rpool built-on its mirror's members`);
  check(to("disk/dsk-01")[0]?.attributes?.redundancyGroup === "tappaas1:rpool:mirror-0" && to("disk/dsk-02")[0]?.attributes?.redundancyGroup === "tappaas1:rpool:mirror-0", `${at}: the members of a mirror one redundancy group, <node>:<pool>:<vdev>`);
  check(to("disk/dsk-03").length === 1 && to("disk/dsk-03")[0].attributes.redundancyGroup === null && to("disk/dsk-03")[0].attributes.required === null, `${at}: a single-disk vdev: no group, required`);
  check(to("disk/dsk-04").length === 0, `${at}: a disk in no pool is built on by nothing`);
  check(rels.some((x) => x.type === "built-on" && x.end && x.to.ref === "disk/dsk-04"), `${at}: …and loses a built-on it had`);
  check(!disks.some((o) => o.name === "dsk-05") && !JSON.stringify(rels).includes("ELSEWHERE"), `${at}: a disk recorded in another asset is not this node's`);
  if (mode === "plain") check(objs.some((o) => o.class === "server" && o.ref === "server/srv-01") && !objs.some((o) => o.class === "port"), "plain report: the server by name only, no ports");
}
{
  // A cache device: optional; a member of no recorded disk: no relation.
  const fake = new FakeSiteClient();
  fake.cluster = parseClusterProbe(CLUSTER);
  const st = parseNodeStorage(FIXTURE);
  st.pools.find((p) => p.name === "tanka1")!.vdevs[1].members[0].serial = "ZA11";
  fake.cluster.hosts.tappaas1 = { storage: st };
  const r: Obj = JSON.parse(capture(() => run(["report", "--json", "--config-dir", diskFixture()], fake)).join("\n"));
  const cache = (r.relations as Obj[]).find((x) => x.type === "built-on" && !x.end && x.to.ref === "disk/dsk-04");
  check(cache?.attributes?.required === false && cache.attributes.redundancyGroup === null, "a cache member: built-on, required false");
}

console.log(`cmdb-discover: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
