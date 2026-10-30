// cmdb-discover.test.ts — `site-manager report --discover` (ADR-040 D15) over
// fixtures of pvesh, lsblk, zpool, ethtool: the ports, disks and pools; a NIC
// with no link and a disk in no pool appear; the plain report is unchanged.

import { run } from "../../src/main";
import { parseNodeDiscovery, parseCorosync } from "../../src/cmdb-discover";
import { parseClusterProbe } from "../../src/cmdb-report";
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
  const sfp = nic("enp2s0f0");
  check(sfp?.kind === "sfp" && sfp?.speed === "10g", "a fibre port is an sfp at its fastest mode");
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

  const pools = objs.filter((o) => o.class === "storage-pool");
  const pool = pools.find((p) => p.name === "rpool" && p.attributes.onNode.ref === m1?.ref);
  check(pool?.attributes?.onNode?.ref === m1?.ref && pool?.attributes?.vdevs?.[0]?.members?.length === 2, "a pool, on its node, with its layout");
  check(pool?.attributes?.health?.status === "ok" && pool?.attributes?.health?.check === "zfs ONLINE", "its ZFS state as a CI's health");
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

console.log(`cmdb-discover: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
