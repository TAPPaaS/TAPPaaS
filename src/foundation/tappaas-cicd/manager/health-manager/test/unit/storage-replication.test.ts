// storage-replication.test.ts — the storage-replication gate: storage-manager
// inventory's replication jobs (an HA guest's copy on its other node) in error
// or behind their schedule become WARN rows on their module. The disks and
// pools are no longer this gate's: a disk is judged from its CI, a pool from
// its zfsState. Offline: storageReplicationResult over an inventory shaped as
// hrossen's on 2026-10-22, and checkStorageReplication against a fake
// storage-manager, which must be asked without SMART.

import { chmodSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkStorageReplication, storageReplicationResult } from "../../src/checks";
import { GATES } from "../../src/assess-sources";

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
    { level: "warn", cause: "health", on: { kind: "pool", node: "tappaas3", name: "tankc1" }, text: "tappaas3/tankc1: DEGRADED: one or more devices has experienced an unrecoverable error" },
  ],
};

const r = storageReplicationResult(inv);
const rows = r.rows ?? [];
check(r.name === "storage-replication" && r.status === "warn", "a replication job in error is a WARN gate — it never fails validate");
check(rows.length === 1 && rows[0].subject?.kind === "module" && rows[0].subject.name === "immich" && /zfs snapshot/.test(rows[0].text), "the job in error, on its module");
check(!rows.some((x) => x.subject?.kind === "disk" || x.subject?.kind === "pool"), "no disk or pool rows: those are judged from their CIs");
const healthy = storageReplicationResult({ nodes: inv.nodes.map((n) => ({ ...n, replication: n.replication.filter((j) => j.state === "ok") })) });
check(healthy.status === "pass" && /1 replication job\(s\) on 3 node/.test(healthy.detail), `nothing to say: pass (${healthy.detail})`);
check(storageReplicationResult({ error: "x" }).status === "skip", "no document: skip");
check(GATES["storage-replication"]?.type === "operational" && GATES["storage-disks"] === undefined, "assess maps the gate; storage-disks is gone");

// checkStorageReplication runs `storage-manager inventory --json --no-smart`.
const dir = mkdtempSync(join(tmpdir(), "hm-sr-"));
const fake = join(dir, "storage-manager");
writeFileSync(fake, `#!/bin/sh\n[ "$1 $2 $3" = "inventory --json --no-smart" ] || exit 2\ncat <<'JSON'\n${JSON.stringify(inv)}\nJSON\n`);
chmodSync(fake, 0o755);
const prev = process.env.STORAGE_MANAGER_BIN;
process.env.STORAGE_MANAGER_BIN = fake;
check(checkStorageReplication(dir).rows?.length === 1, "checkStorageReplication reads the inventory, without SMART");
process.env.STORAGE_MANAGER_BIN = join(dir, "missing");
check(checkStorageReplication(dir).status === "skip", "no storage-manager: skip");
if (prev === undefined) delete process.env.STORAGE_MANAGER_BIN;
else process.env.STORAGE_MANAGER_BIN = prev;

console.log(`\nstorage-replication: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
