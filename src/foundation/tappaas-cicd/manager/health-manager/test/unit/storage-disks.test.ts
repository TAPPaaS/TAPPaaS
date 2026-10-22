// storage-disks.test.ts — the storage-disks gate: storage-manager inventory's
// verdicts on disks, pools and replication jobs become WARN rows, each on its
// disk ("<node>:<device>"), pool ("<node>/<pool>") or module. Offline:
// storageDisksResult over an inventory shaped as hrossen's on 2026-10-22, and
// checkStorageDisks against a fake storage-manager.

import { chmodSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkStorageDisks, storageDisksResult } from "../../src/checks";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const job = (id: string, module: string, state: string, reasons: string[] = []) => ({ id, module, state, reasons, source: "tappaas1", target: "tappaas3" });
const inv = {
  nodes: [
    { name: "tappaas1", replication: [job("110-0", "network", "ok"), job("361-0", "immich", "warn", ["error: command 'zfs snapshot' failed"])] },
    { name: "tappaas2", replication: [] },
    { name: "tappaas3", replication: [] },
  ],
  findings: [
    { level: "fail", cause: "zfs", on: { kind: "disk", node: "tappaas3", name: "/dev/sdb" }, text: "tappaas3 /dev/sdb (HGST_HDN726050ALE614, NAHW317X) in tankc1: ZFS DEGRADED in tankc1: too many errors" },
    { level: "warn", cause: "smart", on: { kind: "disk", node: "tappaas3", name: "/dev/sda" }, text: "tappaas3 /dev/sda (ST8000AS0002-1NA17Z, Z840DMA1), in the pool larsbackup that is not imported: SMART: 2808 reallocated, 632 pending sectors" },
    { level: "warn", cause: "health", on: { kind: "pool", node: "tappaas3", name: "tankc1" }, text: "tappaas3/tankc1: DEGRADED: one or more devices has experienced an unrecoverable error" },
    { level: "warn", cause: "usage", on: { kind: "pool", node: "tappaas2", name: "tanka1" }, text: "tappaas2/tanka1: 85% used (warns at 80%)" },
    { level: "warn", cause: "scrub", on: { kind: "pool", node: "tappaas2", name: "tanka1" }, text: "tappaas2/tanka1: last scrub 2026-08-01, over 40 days ago" },
  ],
};

const r = storageDisksResult(inv);
const rows = r.rows ?? [];
check(r.status === "warn", "a failing disk is a WARN gate — it never fails validate");
check(rows.some((x) => x.subject?.kind === "disk" && x.subject.name === "tappaas3:/dev/sdb" && /NAHW317X/.test(x.text)), "the failing disk, on <node>:<device>, named by serial");
check(rows.some((x) => x.subject?.name === "tappaas3:/dev/sda" && /Z840DMA1/.test(x.text)), "the disk with pending sectors outside any pool");
check(rows.some((x) => x.subject?.kind === "pool" && x.subject.name === "tappaas3/tankc1"), "the degraded pool, on <node>/<pool>");
check(!rows.some((x) => /% used|scrub/.test(x.text)), "pool usage and scrub age are not this gate's (storage-pools has usage)");
check(rows.some((x) => x.subject?.kind === "module" && x.subject.name === "immich" && /zfs snapshot/.test(x.text)), "a replication job in error, on its module");
check(rows.every((x) => x.status === "warn") && rows.length === 4, "four WARN rows");

const healthy = storageDisksResult({ nodes: inv.nodes.map((n) => ({ ...n, replication: [] })), findings: [] });
check(healthy.status === "pass" && /3 node/.test(healthy.detail), "nothing to say: pass");
check(storageDisksResult({ error: "x" }).status === "skip", "no document: skip");

// checkStorageDisks runs `storage-manager inventory --json`.
const dir = mkdtempSync(join(tmpdir(), "hm-sd-"));
const fake = join(dir, "storage-manager");
writeFileSync(fake, `#!/bin/sh\n[ "$1 $2" = "inventory --json" ] || exit 2\ncat <<'JSON'\n${JSON.stringify(inv)}\nJSON\n`);
chmodSync(fake, 0o755);
const prev = process.env.STORAGE_MANAGER_BIN;
process.env.STORAGE_MANAGER_BIN = fake;
check(checkStorageDisks(dir).rows?.length === 4, "checkStorageDisks reads the inventory");
process.env.STORAGE_MANAGER_BIN = join(dir, "missing");
check(checkStorageDisks(dir).status === "skip", "no storage-manager: skip");
if (prev === undefined) delete process.env.STORAGE_MANAGER_BIN;
else process.env.STORAGE_MANAGER_BIN = prev;

console.log(`\nstorage-disks: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
