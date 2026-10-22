// inventory.test.ts — `storage-manager inventory` over hrossen's real reads
// (test/fixtures/inventory-hrossen, captured 2026-10-22: tappaas3's tankc1 on a
// failing disk, the dead 8 TB disk of a pool not imported beside it, five HA
// guests replicated from tappaas1 to tappaas3), plus the cases the fixture does
// not exercise. Offline: buildInventory is pure, collectSources runs on fakes.
//
// Run: SM_FIXTURE_DIR=<storage-manager>/test/fixtures node inventory.test.js

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { ClusterGuest, ProbeSection, parseProbeSections } from "../../../../lib/ts/src/cluster";
import {
  Disk,
  InvSources,
  Inventory,
  ModuleRow,
  buildInventory,
  collectSources,
  judgeDisk,
  parseScan,
  parseSmart,
  parseZpoolStatus,
  renderInventory,
  replicateSnapshot,
  scheduleMinutes,
  zpoolCount,
} from "../../src/inventory";

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

const FIX = join(process.env.SM_FIXTURE_DIR ?? "test/fixtures", "inventory-hrossen");
const load = <T>(f: string): T => JSON.parse(readFileSync(join(FIX, f), "utf8")) as T;
const NOW = new Date(readFileSync(join(FIX, "now.txt"), "utf8").trim());

function hrossen(): InvSources {
  return {
    site: load<Record<string, unknown>>("site.json"),
    only: null,
    smart: true,
    nodes: Object.fromEntries(["tappaas1", "tappaas2", "tappaas3"].map((n) => [n, { sections: load<Record<string, ProbeSection>>(`${n}.json`) }])),
    guests: load<ClusterGuest[]>("guests.json"),
    replicationJobs: load<Record<string, unknown>[]>("replication.json"),
    modules: load<{ modules: ModuleRow[] }>("modules.json").modules,
    shares: load<Record<string, unknown>>("shares.json"),
    errors: [],
  };
}

const inv: Inventory = buildInventory(hrossen(), NOW);
const node = (n: string) => inv.nodes.find((x) => x.name === n)!;
const pool = (n: string, p: string) => node(n).pools.find((x) => x.name === p)!;

// ── the nodes, their boot devices and pools ───────────────────────────
check(inv.nodes.map((n) => n.name).join(",") === "tappaas1,tappaas2,tappaas3", "the three nodes of site.json, in order");
check(inv.nodes.every((n) => n.reachable), "every node answered");
check(node("tappaas3").boot.map((d) => d.device).join() === "/dev/sdc", "tappaas3 boots from /dev/sdc (/ on its LVM, the ESP)");
check(node("tappaas1").boot.map((d) => d.serial).join() === "260923802321", "tappaas1's boot device is the WD SN7100 by serial");
check(node("tappaas3").boot[0].smart.temperature === null, "an SSD reporting 0°C has no temperature, not a cold one");
check(node("tappaas1").pools.map((p) => p.name).join() === "tanka1,tankb1", "tappaas1: tanka1, tankb1");
check(node("tappaas2").pools.map((p) => p.name).join() === "tanka1", "tappaas2: tanka1");
check(node("tappaas3").pools.map((p) => p.name).join() === "tanka1,tankc1", "tappaas3: tanka1, tankc1");
check(inv.nodes.every((n) => n.pools.every((p) => p.declared)), "every pool is one site.json declares");

// ── vdevs and their disks ─────────────────────────────────────────────
const t1a = pool("tappaas1", "tanka1");
check(t1a.vdevs.length === 1 && t1a.vdevs[0].type === "mirror" && t1a.vdevs[0].disks.length === 2, "tappaas1 tanka1 is one mirror of two disks");
check(t1a.vdevs[0].disks.every((d) => d.type === "nvme" && /990 PRO/.test(d.model ?? "")), "the mirror's members are matched by their nvme-eui ids to the 990 PROs");
const t1b = pool("tappaas1", "tankb1");
check(t1b.vdevs[0].type === "stripe" && t1b.vdevs[0].disks[0].serial === "ZZ30MJL6", "tankb1 is a single disk, matched by its wwn id");
check(t1a.state === "ok" && t1b.state === "ok", "tappaas1's pools are ok");

check(inv.nodes.every((n) => n.pools.every((p) => p.vdevs.every((v) => v.missing.length === 0))), "every pool member is matched to a disk of its node");
check(pool("tappaas3", "tanka1").vdevs[0].disks[0]?.serial === "8061TBFDHY25F220056" && pool("tappaas2", "tanka1").vdevs[0].disks[0]?.serial === "50026B73842AD86F", "the single-NVMe pools of tappaas2 and tappaas3");
check(t1a.vdevs[0].health === "ONLINE" && t1a.vdevs[0].state === "ok", "a vdev carries ZFS's health and its colour");

// Proxmox names one of a disk's by-id links, not always the one ZFS uses: the
// fixture has the NVMe's namespace-suffixed one (…_1), matched by its serial;
// the plain one matches by name. zpool status -L names the kernel path.
for (const variant of ["suffix", "kernel"]) {
  const v = hrossen();
  const t3 = v.nodes.tappaas3.sections!;
  if (variant === "suffix") t3.disks = { rc: 0, out: t3.disks.out.replace("nvme-ASint_AS806_1TB_8061TBFDHY25F220056_1\"", "nvme-ASint_AS806_1TB_8061TBFDHY25F220056\"") };
  else t3["zpool-status"] = { rc: 0, out: t3["zpool-status"].out.replace("/dev/disk/by-id/nvme-ASint_AS806_1TB_8061TBFDHY25F220056-part1", "/dev/nvme0n1p1").replace("/dev/disk/by-id/ata-HGST_HDN726050ALE614_NAHW317X-part1", "/dev/sdb1") };
  const vi = buildInventory(v, NOW).nodes.find((n) => n.name === "tappaas3")!;
  check(vi.pools.every((p) => p.vdevs.every((x) => x.missing.length === 0 && x.disks.length === 1)) && vi.otherDisks.length === 1, `a member is matched by ${variant === "suffix" ? "the by-id link ZFS uses" : "its kernel path"}`);
}

// ── tappaas3 tankc1: the failing disk ─────────────────────────────────
const c1 = pool("tappaas3", "tankc1");
const hgst = c1.vdevs[0].disks[0];
check(c1.health === "DEGRADED" && c1.state === "warn", "tankc1 is DEGRADED: warn");
check(hgst.serial === "NAHW317X" && hgst.state === "fail", "its disk NAHW317X fails");
check(hgst.zfs?.state === "DEGRADED" && hgst.zfs.read === 17980 && hgst.zfs.write === 558 && hgst.zfs.cksum === 25577, "ZFS's exact error counts (zpool status -p), not pvesh's 17.6");
check(hgst.smart.health === "passed" && hgst.smart.reallocated === 534 && hgst.smart.pending === 64, "SMART still says PASSED, with 534 reallocated and 64 pending sectors");
check(c1.vdevs[0].name === "ata-HGST_HDN726050ALE614_NAHW317X" && hgst.zfs?.vdev === c1.vdevs[0].name, "a single-disk vdev is named by the disk's by-id name");
check(hgst.reasons.some((r) => /too many errors/.test(r)), "the reason names ZFS's verdict");
check(c1.scrub.state === "unknown", "tankc1 has no scrub on record");

// The dead 8 TB disk is in no imported pool: its old pool larsbackup is not imported.
const dead = node("tappaas3").otherDisks.find((d) => d.serial === "Z840DMA1");
check(!!dead, "the 8 TB Z840DMA1 is listed among tappaas3's disks in no pool");
check(dead?.exportedPool?.name === "larsbackup" && dead.exportedPool.state === "DEGRADED", "…as a member of the pool larsbackup, not imported");
check(dead?.state === "warn" && dead.smart.reallocated === 2808 && dead.smart.pending === 632, "…warn: 2808 reallocated, 632 pending sectors");
check(node("tappaas3").state === "warn", "tappaas3 is warn");

// The PBS datastore is a directory on tankc1's own dataset.
const pbs = c1.datasets.find((d) => d.kind === "pbs-datastore");
check(pbs?.label === "tappaas_backup" && pbs.mountpoint === "/tankc1/tappaas_backup" && !pbs.exact, "the PBS datastore tappaas_backup on tankc1, sized by the dataset holding it");
check(c1.totals.other > 4e11 && c1.totals.own === 0 && c1.totals.mirror === 0, "tankc1 holds ~404 GB of other data, no guest volumes");

// ── own disks and HA mirror copies ────────────────────────────────────
const t3a = pool("tappaas3", "tanka1");
const kinds = (p: typeof t3a, k: string) => [...new Set(p.volumes.filter((v) => v.kind === k).map((v) => v.vmid))].join(",");
check(kinds(t3a, "mirror") === "110,130,140,361,610", "tappaas3 tanka1 holds the mirror copies of 110,130,140,361,610");
check(kinds(t3a, "own") === "811", "…and unifi-os (811) as its own");
const m110 = t3a.volumes.find((v) => v.name === "tanka1/vm-110-disk-0")!;
check(m110.module === "network" && m110.runsOn === "tappaas1" && m110.replica?.job === "110-0", "vm-110-disk-0 is network's, running on tappaas1, copied by job 110-0");
check(m110.replica?.lastSync === "2026-10-22T08:15:02.000Z", "the copy's last sync from its __replicate_ snapshot");
const o110 = t1a.volumes.find((v) => v.name === "tanka1/vm-110-disk-0")!;
check(o110.kind === "own" && o110.mirroredOn.join() === "tappaas3", "on tappaas1 the same volume is network's own, mirrored on tappaas3");
check(t1a.volumes.filter((v) => v.vmid === 8080).every((v) => v.kind === "template"), "the template's base volumes are templates");
check(t3a.totals.own + t3a.totals.mirror + t3a.totals.other + t3a.totals.free === t3a.totals.total, "the pie adds up: own + mirror + other + free = total");
check(t3a.totals.mirror > 2e11 && t3a.totals.own > 6e10, "tappaas3 tanka1: ~239 GB of mirrors, ~69 GB own");
const orphanish = t1a.datasets.filter((d) => /ORPHAN-/.test(d.name));
check(orphanish.length === 2 && orphanish.every((d) => d.kind === "volume"), "leftover ORPHAN- volumes are listed as volumes no guest owns");

// ── other datasets ────────────────────────────────────────────────────
const media = t1b.datasets.find((d) => d.kind === "nfs-share");
check(media?.label === "media" && media.mountpoint === "/tappaas-nfs/media", "tankb1 carries the NFS share media");
check(!t1b.datasets.some((d) => d.name === "tankb1/tappaas-nfs"), "the shares' parent dataset is not listed beside them");
const t2a = pool("tappaas2", "tanka1");
check(t2a.datasets.some((d) => d.label === "vllm-models" && d.kind === "dataset"), "tappaas2 tanka1's vllm-models dataset");
const ct = t2a.volumes.find((v) => v.vmid === 312);
check(ct?.type === "filesystem" && ct.kind === "own" && ct.size !== null, "vllm-amd's container subvol, sized by its refquota");

// ── replication ───────────────────────────────────────────────────────
check(node("tappaas1").replication.length === 5 && node("tappaas1").replication.every((j) => j.state === "ok"), "tappaas1 sources five jobs, all ok");
check(node("tappaas3").replication.length === 0, "tappaas3 sources none");

// ── findings ──────────────────────────────────────────────────────────
const onDisk = inv.findings.filter((f) => f.on.kind === "disk");
check(onDisk.some((f) => f.level === "fail" && f.on.node === "tappaas3" && f.on.name === "/dev/sdb" && /NAHW317X/.test(f.text)), "finding: tappaas3 /dev/sdb fails, named by serial");
check(onDisk.some((f) => f.level === "warn" && f.on.name === "/dev/sda" && /Z840DMA1/.test(f.text) && /larsbackup/.test(f.text)), "finding: tappaas3 /dev/sda (Z840DMA1) warns");
check(inv.findings.some((f) => f.on.kind === "pool" && f.on.name === "tankc1" && f.cause === "health" && f.level === "warn"), "finding: tankc1 degraded");
check(!inv.findings.some((f) => f.on.kind === "pool" && /^disk /.test(f.text)), "a pool finding does not repeat its disk's");
check(inv.findings.every((f) => f.on.node === "tappaas3"), "nothing to report elsewhere");

// ── the text view ─────────────────────────────────────────────────────
const text = renderInventory({ ...inv, nodes: [node("tappaas3")] });
check(text[0].startsWith("tappaas3") && text[0].endsWith(" warn"), "a node's line ends with its state");
check(text.some((l) => /NAHW317X/.test(l) && l.endsWith(" fail")), "the failing disk's line ends with fail");
check(text.some((l) => /mirror of tappaas1/.test(l)), "mirror copies are told apart");
check(text.some((l) => /PBS datastore tappaas_backup/.test(l)), "the PBS datastore is shown");

// ── parsers ───────────────────────────────────────────────────────────
check(zpoolCount("17.6K") === 17600 && zpoolCount("558") === 558 && zpoolCount("2M") === 2e6, "error counts with and without -p");
check(scheduleMinutes("*/15") === 15 && scheduleMinutes("02:30") === 1440 && scheduleMinutes("mon..fri 08:00") === null, "schedules");
check(replicateSnapshot("__replicate_110-0_1792656002__")?.job === "110-0" && replicateSnapshot("tappaas-20261022") === null, "replicate snapshot names");
const scrub = parseScan("scrub repaired 0B in 00:01:11 with 0 errors on Sun Oct 11 00:25:12 2026");
check(scrub.state === "finished" && scrub.errors === 0 && scrub.last !== null, "a finished scrub");
check(parseScan("scrub in progress since Sun Oct 11 00:24:01 2026").state === "running", "a running scrub");
check(parseScan("none requested").state === "none", "never scrubbed");
const sec = parseProbeSections("@@section a\n1\n2\n\n@@rc 0\n@@section b\n\n@@rc 1\n@@section c\ncut off");
check(sec.a.out === "1\n2" && sec.a.rc === 0 && sec.b.rc === 1 && !("c" in sec), "probe sections, a cut-off one dropped");

// raidz, a log device, a missing member, a faulted pool.
const st = parseZpoolStatus(
  [
    "  pool: big",
    " state: DEGRADED",
    "status: One or more devices could not be used.",
    "  scan: resilvered 1.2G in 00:10:00 with 0 errors on Sat Oct 10 10:00:00 2026",
    "config:",
    "",
    "\tNAME          STATE     READ WRITE CKSUM",
    "\tbig           DEGRADED     0     0     0",
    "\t  raidz2-0    DEGRADED     0     0     0",
    "\t    /dev/sda1 ONLINE       0     0     0",
    "\t    1234567890  UNAVAIL    0     0     0  was /dev/sdz1",
    "\tlogs",
    "\t  /dev/nvme0n1p1 ONLINE    0     0     0",
    "",
    "errors: No known data errors",
  ].join("\n"),
);
check(st[0].rows.length === 6 && st[0].rows[2].depth === 2 && st[0].rows[3].msg === "was /dev/sdz1" && st[0].rows[4].name === "logs", "a raidz tree with a log group");
const disk = (o: Partial<Disk>): Disk => ({
  device: "/dev/sdx", byId: null, model: null, serial: null, wwn: null, size: 0, type: "hdd", wearout: null,
  smart: parseSmart({ health: "PASSED" }), zfs: null, exportedPool: null, state: "ok", reasons: [], ...o,
});
const worn = disk({ type: "ssd", wearout: 8 });
judgeDisk(worn);
check(worn.state === "fail", "an SSD with 8% of its life left fails");
const failed1 = disk({ smart: parseSmart({ health: "FAILED" }) });
judgeDisk(failed1);
check(failed1.state === "fail" && failed1.reasons[0] === "SMART health FAILED", "SMART FAILED fails");
const hot = disk({ type: "nvme", smart: parseSmart({ health: "PASSED", type: "text", text: "Temperature:   75 Celsius\nCritical Warning:  0x02\n" }) });
judgeDisk(hot);
check(hot.state === "warn" && hot.smart.temperature === 75 && hot.reasons.length === 2, "an NVMe at 75°C with a critical warning warns");

// A replication job in error, one overdue, and a node that does not answer.
const broken = hrossen();
const t1sec = broken.nodes.tappaas1.sections!;
const jobs = JSON.parse(t1sec.replication.out) as Record<string, unknown>[];
jobs[0].error = "command 'zfs snapshot' failed";
jobs[0].fail_count = 3;
jobs[1].last_sync = Math.floor(NOW.getTime() / 1000) - 3 * 3600;
t1sec.replication = { rc: 0, out: JSON.stringify(jobs) };
broken.nodes.tappaas2 = { sections: null };
const b = buildInventory(broken, NOW);
const rep = b.findings.filter((f) => f.cause === "replication");
check(rep.length === 2 && rep.some((f) => /zfs snapshot/.test(f.text)) && rep.some((f) => /min ago/.test(f.text)), "findings: a job in error, a job overdue");
check(b.nodes.find((n) => n.name === "tappaas2")?.reachable === false && b.sources.some((s) => s.name === "tappaas2 storage" && !s.ok), "a silent node is said, not dropped");

// A pool over the gate's threshold, and one declared but not imported.
const full = hrossen();
const t2sec = full.nodes.tappaas2.sections!;
t2sec.zfs = { rc: 0, out: t2sec.zfs.out.replace(/^tanka1\tfilesystem\t\d+\t\d+/m, "tanka1\tfilesystem\t1800000000000\t150000000000") };
(full.site!.hardware as { nodes: { name: string; storagePools: string[] }[] }).nodes.find((n) => n.name === "tappaas2")!.storagePools.push("tankb1");
const f = buildInventory(full, NOW);
check(f.findings.some((x) => x.cause === "usage" && x.level === "fail" && x.on.node === "tappaas2"), "a pool at 92% fails on usage");
const gone = f.nodes.find((n) => n.name === "tappaas2")!.pools.find((p) => p.name === "tankb1");
check(gone?.present === false && gone.state === "fail", "a declared pool that is not imported fails");

// --no-smart: no SMART sections read, the document says so.
const ns = hrossen();
ns.smart = false;
const nsInv = buildInventory(ns, NOW);
check(nsInv.smart === false && nsInv.nodes.every((n) => n.pools.every((p) => p.vdevs.every((v) => v.disks.every((d) => !d.smart.read)))), "--no-smart: no disk carries SMART");
check(renderInventory(nsInv).some((l) => /SMART was not read/.test(l)), "--no-smart: the text says so");

// collectSources over fake reads: --node reads one node, the cluster-wide reads go through it.
const tmp = mkdtempSync(join(tmpdir(), "sm-inv-"));
writeFileSync(join(tmp, "site.json"), readFileSync(join(FIX, "site.json"), "utf8"));
const asked: string[] = [];
const src = collectSources({
  configDir: tmp,
  only: "tappaas3",
  smart: false,
  reads: {
    nodeStorage: (n, smart) => {
      asked.push(`${n}:${smart}`);
      return load<Record<string, ProbeSection>>(`${n}.json`);
    },
    guests: (n) => (asked.push(`guests@${n}`), load<ClusterGuest[]>("guests.json")),
    replication: (n) => (asked.push(`repl@${n}`), load<Record<string, unknown>[]>("replication.json")),
  },
  run: () => ({ ran: true, rc: 0, stdout: readFileSync(join(FIX, "modules.json"), "utf8"), stderr: "" }),
});
check(asked.join() === "tappaas3:false,guests@tappaas3,repl@tappaas3", "--node tappaas3 --no-smart: one node read, cluster reads via it");
check(src.shares === null && src.errors.length === 0, "no shares.json is not an error");
const one = buildInventory(src, NOW);
check(one.nodes.length === 1 && one.nodes[0].pools.find((p) => p.name === "tanka1")!.volumes.some((v) => v.kind === "mirror"), "--node still tells mirrors apart (the cluster's job list)");
rmSync(tmp, { recursive: true, force: true });

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
