// storage.test.ts — the Storage view's read and data over hrossen's inventory
// (test/fixtures/storage-inventory.json, 2026-10-22: tappaas3's tankc1 on a
// failing disk, the dead Z840DMA1 in no pool): the cached read and its shape,
// the findings on each object, the columns, and each pool's pie.

import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { Reads, TTL } from "../../src/reads";
import { Gate, StorageInventory } from "../../web/src/types";
import { bytes, diskKey, findDisk, poolKey, poolSlices, stateWith, storageLayout, storageNotes } from "../../web/src/physical/storage";
import { check, done } from "./check";
import { fakeSite } from "./fake-site";

async function main(): Promise<void> {
  // ── the read ────────────────────────────────────────────────────────
  let t = 0;
  const site = fakeSite();
  const dir = mkdtempSync(join(tmpdir(), "console-storage-"));
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7, now: () => t });
  const e = await reads.storage.get();
  const inv = e.value as unknown as StorageInventory;
  check(site.calls.filter((c) => c === "storage-manager inventory --json").length === 1, "the read is `storage-manager inventory --json` (SMART included)");
  check(e.error === null && inv.nodes.map((n) => n.name).join(" ") === "tappaas1 tappaas2 tappaas3", "every node, in order");
  check(inv.nodes.every((n) => Array.isArray(n.boot) && Array.isArray(n.pools) && Array.isArray(n.otherDisks) && ["ok", "warn", "fail"].includes(n.state)), "a node: boot, pools, disks in no pool, a state");
  const t3 = inv.nodes.find((n) => n.name === "tappaas3")!;
  const tankc1 = t3.pools.find((p) => p.name === "tankc1")!;
  const sdb = tankc1.vdevs[0].disks[0];
  check(tankc1.health === "DEGRADED" && tankc1.state === "warn" && sdb.state === "fail" && sdb.serial === "NAHW317X", "tankc1 DEGRADED (warn) on /dev/sdb (fail)");
  check(sdb.smart !== null && sdb.smart.reallocated === 534 && sdb.smart.pending === 64 && sdb.smart.uncorrectable === 1667 && sdb.zfs?.cksum === 25577, "a disk carries its SMART counts and its ZFS errors");
  check(t3.otherDisks.length === 1 && t3.otherDisks[0].serial === "Z840DMA1" && t3.otherDisks[0].state === "warn", "the dead Z840DMA1: in no pool, warn");
  check(TTL.storage === 10 * 60_000, "the storage read lives 10 minutes");
  t = 9 * 60_000;
  await reads.storage.get();
  check(site.calls.filter((c) => c.startsWith("storage-manager")).length === 1, "within 10 minutes it is served from the cache");
  t = 11 * 60_000;
  await reads.storage.get();
  await reads.storage.refresh();
  check(site.calls.filter((c) => c.startsWith("storage-manager")).length >= 2, "older than 10 minutes it is read again");
  check(!reads.timed().includes(reads.storage as never), "no timer of its own: SMART runs only when someone looks");
  site.fail.add("storage-manager inventory");
  await reads.storage.refresh();
  check(reads.storage.peek().value !== null && /exit|failed/.test(reads.storage.peek().error ?? ""), "a failed read keeps the last inventory and says why");
  {
    const s2 = fakeSite();
    const r2 = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: async (b, a) => (b === "storage-manager" ? { rc: 0, stdout: '{"nodes": 3}', stderr: "", ran: true } : s2.run(b, a)), journalDays: 7 });
    const bad = await r2.storage.get();
    check(bad.value === null && /no inventory/.test(bad.error ?? ""), "a document without nodes and findings is refused");
  }

  // ── findings on objects ─────────────────────────────────────────────
  const gates: Gate[] = [
    { name: "storage-pools", status: "warn", detail: "", findings: [{ status: "warn", text: "tappaas2/tanka1: 85% used", subject: { kind: "pool", name: "tappaas2/tanka1" } }, { status: "pass", text: "tappaas1/tanka1: 17% used", subject: { kind: "pool", name: "tappaas1/tanka1" } }] },
    { name: "storage-disks", status: "warn", detail: "", findings: [{ status: "warn", text: inv.findings[0].text, subject: { kind: "disk", name: "tappaas3:/dev/sdb" } }, { status: "warn", text: "tappaas3/tankc1: DEGRADED (gate)", subject: { kind: "pool", name: "tappaas3/tankc1" } }] },
    { name: "quorum", status: "warn", detail: "", findings: [{ status: "warn", text: "not storage", subject: { kind: "node", name: "tappaas1" } }] },
  ];
  const notes = storageNotes(inv, gates);
  check((notes.get(diskKey("tappaas3", "/dev/sdb")) ?? []).length === 1, "the gate's row of the same text as the inventory's is one finding");
  check((notes.get(poolKey("tappaas3", "tankc1")) ?? []).some((n) => n.source === "storage-disks") && (notes.get(poolKey("tappaas3", "tankc1")) ?? []).some((n) => n.source === "inventory"), "a pool shows the inventory's finding and the gate's");
  check(stateWith("ok", notes.get(poolKey("tappaas2", "tanka1"))) === "warn" && !notes.has(poolKey("tappaas1", "tanka1")), "a storage-pools warning raises the pool's state; a pass is no finding");
  check(!notes.has("node:tappaas1"), "other gates' findings are not storage findings");
  check(notes.has(diskKey("tappaas3", "/dev/sda")), "the disk in no pool carries its finding");

  // ── the columns ─────────────────────────────────────────────────────
  const lay = storageLayout(inv);
  const col = (id: string) => lay.items.find((i) => i.id === id)?.col;
  check(col("node:tappaas3") === 0 && col(poolKey("tappaas3", "tankc1")) === 1 && col(diskKey("tappaas3", "/dev/sdb")) === 2, "node, pool, disk: columns 1, 2, 3");
  check(lay.items.some((i) => i.kind === "boot" && i.node === "tappaas3" && i.col === 1), "the boot device sits beside the pools");
  check(lay.edges.some((x) => x.source === "node:tappaas3" && x.target === poolKey("tappaas3", "tankc1")) && lay.edges.some((x) => x.source === poolKey("tappaas3", "tankc1") && x.target === diskKey("tappaas3", "/dev/sdb")), "lines node → pool → disk");
  const t1disks = lay.items.filter((i) => i.kind === "disk" && i.node === "tappaas1" && i.pool === "tanka1");
  const g = t1disks.map((i) => (i.kind === "disk" ? i.group : null));
  check(t1disks.length === 2 && g.every((x) => x !== null && /^mirror-0/.test(x.label)) && g[0]!.first && g[1]!.last && t1disks[1].kind === "disk" && t1disks[1].after === t1disks[0].id, "a mirror's two disks carry its label and stay together");
  check(lay.items.every((i) => i.kind !== "disk" || i.node !== "tappaas3" || i.group === null), "a lone disk has no vdev label");
  check(lay.items.some((i) => i.kind === "nopool" && i.node === "tappaas3") && lay.edges.some((x) => x.source === "nopool:tappaas3" && x.target === diskKey("tappaas3", "/dev/sda")), "disks in no pool hang off a group of their own");
  check(findDisk(inv, "tappaas3", "/dev/sdb")?.pool?.name === "tankc1" && findDisk(inv, "tappaas3", "/dev/sda")?.pool === null && findDisk(inv, "tappaas3", t3.boot[0].device)?.boot === true, "a disk is found wherever it is");

  // ── the pie ─────────────────────────────────────────────────────────
  for (const n of inv.nodes) {
    for (const p of n.pools) {
      const s = poolSlices(p);
      const sum = s.reduce((x, y) => x + y.bytes, 0);
      check(sum === p.totals.total, `${n.name}/${p.name}: the slices add up to the pool (${bytes(sum)} of ${bytes(p.totals.total)})`);
      check(s[s.length - 1].kind === "free" && s.every((x) => x.bytes > 0 || x.kind === "free"), `${n.name}/${p.name}: free last, no empty slice`);
    }
  }
  const c1 = poolSlices(tankc1);
  check(c1.map((x) => x.kind).join(" ") === "store other free" && c1[0].parts?.[0].label === "PBS datastore tappaas_backup" && c1[0].bytes === 404216061952, "tankc1: the PBS datastore, the rest, free");
  const a3 = poolSlices(t3.pools.find((p) => p.name === "tanka1")!);
  const unifi = a3.find((x) => x.kind === "guest");
  const ha = a3.find((x) => x.kind === "mirror");
  check(unifi?.label === "unifi-os" && unifi.module === "unifi-os" && a3.filter((x) => x.kind === "guest").length === 1, "tappaas3/tanka1: one guest of its own, unifi-os, labelled by its module");
  check(ha?.label === "HA mirrors" && ha.bytes === 239177461760 && (ha.parts ?? []).map((x) => x.label).sort().join(" ") === "identity immich network tappaas-cicd vaultwarden", "the HA mirror copies are one slice, its parts the guests");
  check((ha?.parts ?? []).every((x) => x.of === "tappaas1") && Math.abs((ha?.parts ?? []).reduce((s, x) => s + x.bytes, 0) - ha!.bytes) === 0, "each mirrored guest runs on tappaas1; the parts add up to the slice");
  const a1 = poolSlices(inv.nodes[0].pools.find((p) => p.name === "tanka1")!);
  const guests = a1.filter((x) => x.kind === "guest");
  check(guests.length > 5 && guests.every((g, i) => i === 0 || guests[i - 1].bytes >= g.bytes) && !a1.some((x) => x.kind === "mirror"), "tappaas1/tanka1: one slice per guest, the largest first; no mirror here");
  check(a1.find((x) => x.kind === "other")?.parts?.some((x) => /^template /.test(x.label)) === true, "templates and orphans are among the other datasets");
  const b2 = poolSlices(inv.nodes[1].pools[0]);
  check(b2.find((x) => x.kind === "other")?.parts?.some((x) => x.label === "vllm-models") === true, "a dataset of its own (vllm-models) is an other dataset");
  check(bytes(404216061952) === "376 GiB" && bytes(0) === "0 B" && bytes(null) === "?", "sizes in binary units");
  done("storage");
}

void main();
