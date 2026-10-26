// capacity.test.ts — the memory-commitment gate (#569).
//
// COMMITTED, not used: without ballooning a guest's declared memory is pinned by
// the host whether the guest wants it or not, so committed is what decides
// whether another guest fits. `used` can legitimately exceed it — ZFS ARC and
// host overhead live outside any guest — which is why the gate must not be
// written against `used`.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkGuestMemory, checkMemoryCommitment, checkUpdateCapacity } from "../../src/checks";
import { NodeCapacity } from "../../src/types";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const G = 1024 ** 3;
const node = (
  name: string, physical: number, used: number,
  guests: [string, number, string][],
): NodeCapacity => ({
  node: name,
  physicalMem: physical * G,
  usedMem: used * G,
  committedMem: guests.filter((g) => g[2] === "running").reduce((a, g) => a + g[1] * G, 0),
  guests: guests.map((g, i) => ({
    vmid: 100 + i, name: g[0], node: name, status: g[2], type: "qemu",
    declaredMem: g[1] * G, usedMem: 0, residentMem: 0, measured: true,
  })),
});

// ── a node within its means ──────────────────────────────────────────
{
  const c = new FakeClusterClient();
  c.capacity = [node("tappaas1", 64, 30, [["a", 16, "running"], ["b", 8, "running"]])];
  const r = checkMemoryCommitment(c, 100);
  check(r.status === "pass", "a node committing less than it has passes");
  check(r.detail.includes("38%"), `the ratio is reported (got: ${r.detail})`);
}

// ── a node that has promised more than it has ────────────────────────
{
  const c = new FakeClusterClient();
  c.capacity = [node("tappaas1", 31, 25, [["a", 16, "running"], ["b", 17, "running"]])];
  const r = checkMemoryCommitment(c, 100);
  check(r.status === "fail", "committing more than physical fails the gate");
  check(r.detail.includes("tappaas1"), "the failing node is named");
}

// ── a stopped guest holds nothing ────────────────────────────────────
{
  const c = new FakeClusterClient();
  c.capacity = [node("tappaas1", 32, 4, [["live", 8, "running"], ["off", 64, "stopped"]])];
  const r = checkMemoryCommitment(c, 100);
  check(r.status === "pass", "a stopped guest is not counted as committed");
}

// ── used above committed is NOT a failure ────────────────────────────
// ZFS ARC and host overhead are not guest memory. A gate written against
// `used` would fail a perfectly healthy node with a warm cache.
{
  const c = new FakeClusterClient();
  c.capacity = [node("tappaas2", 123, 80, [["a", 54, "running"]])];
  const r = checkMemoryCommitment(c, 100);
  check(r.status === "pass", "a node whose USED exceeds its committed still passes");
}

// ── an idle node is reported, not hidden ─────────────────────────────
{
  const c = new FakeClusterClient();
  c.capacity = [node("busy", 31, 25, [["a", 30, "running"]]), node("idle", 23, 1, [])];
  const r = checkMemoryCommitment(c, 100);
  check(r.detail.includes("idle") && r.detail.includes("0%"),
    `an empty node appears at 0% — a placement problem worth seeing (got: ${r.detail})`);
}

// ── threshold is honoured, and an unreachable cluster skips ──────────
{
  const c = new FakeClusterClient();
  c.capacity = [node("tappaas1", 64, 30, [["a", 48, "running"]])];
  check(checkMemoryCommitment(c, 100).status === "pass", "75% passes a 100% threshold");
  check(checkMemoryCommitment(c, 70).status === "fail", "…and fails a 70% one");

  const d = new FakeClusterClient();
  d.capacityThrows = "No Proxmox nodes reachable";
  const r = checkMemoryCommitment(d, 100);
  check(r.status === "skip", "an unreachable cluster skips rather than failing");
  check(r.detail.includes("No Proxmox nodes reachable"), "…and says why");

  const e = new FakeClusterClient();
  check(checkMemoryCommitment(e, 100).status === "skip", "no nodes reported skips");
}

// ── guest-memory: the three numbers, and the one we must not print ───
// declared/resident/used, in GiB.
const guest = (
  name: string, declared: number, resident: number, used: number,
  measured = true, type = "qemu", status = "running",
) => ({
  vmid: 900, name, node: "tappaas1", status, type,
  declaredMem: declared * G, residentMem: resident * G, usedMem: used * G, measured,
});
const withGuests = (gs: ReturnType<typeof guest>[]): NodeCapacity => ({
  node: "tappaas1", physicalMem: 64 * G, usedMem: 32 * G, committedMem: 0, guests: gs,
});

{
  // Never-touched memory is not reclaimable; touched-then-freed is.
  const c = new FakeClusterClient();
  c.capacity = [withGuests([guest("nextcloud", 8, 1.3, 0.8), guest("cicd", 16, 7.3, 4.9)])];
  const r = checkGuestMemory(c);
  const rows = (r.rows ?? []).map((x) => x.text).join("\n");
  check(r.status === "pass", "a healthy estate passes");
  check(/cicd\s+16\.0G\s+7\.3G\s+4\.9G/.test(rows), `each module gets declared/resident/used (got: ${rows})`);
  check(rows.indexOf("cicd") < rows.indexOf("nextcloud"), "rows are ordered largest gap first");
  // cicd 2.4 + nextcloud 0.5 = 2.9, NOT the 22.9 a declared-minus-used sum would give
  check(/VM totals[\s\S]*reclaimable 2\.9G/.test(rows), `totals count allocated-minus-used only (got: ${rows})`);
  check(/── VM totals\s+24\.0G\s+8\.6G\s+5\.7G/.test(rows), `each column is totalled (got: ${rows})`);
}

{
  // The FreeBSD firewall. Its agent ANSWERS — ping, get-osinfo, all fine — but
  // provides no memory statistics, so Proxmox reports the HOST's view as the
  // guest's. Printing 8.0/8.0 would say "full" about a VM using 1.15G, which is
  // why the signal is `free_mem` in the balloon stats, not agent liveness.
  const c = new FakeClusterClient();
  c.capacity = [withGuests([guest("network", 8, 8, 8, false)])];
  const r = checkGuestMemory(c);
  const rows = (r.rows ?? []).map((x) => x.text).join("\n");
  check(rows.includes("unmeasured"), "a guest reporting no memory statistics is marked unmeasured");
  check(rows.includes("host's, not the guest's"), "…and the row says whose figure it is");
  check(/reclaimable 0\.0G/.test(rows), "…and is never counted as a reclaimable gap");
  check(r.detail === "declared / allocated / used, largest gap first",
    `the header names the columns and nothing else (got: ${r.detail})`);
}

{
  // An LXC limit is not an allocation and needs no agent.
  const c = new FakeClusterClient();
  c.capacity = [withGuests([guest("vllm", 46, 0, 2.1, true, "lxc")])];
  const r = checkGuestMemory(c);
  const rows = (r.rows ?? []).map((x) => x.text).join("\n");
  check(r.status === "pass", "an LXC with a large unused limit is not a problem");
  check(rows.includes("of its LXC limit"), "an LXC row says its figure is a limit");
  check(rows.includes("── LXC totals"), "LXC is totalled separately from VMs");
  check(!/── VM totals/.test(rows), "…and an LXC-only estate reports no VM total");
}

{
  // Resident above declared is the one real anomaly.
  const c = new FakeClusterClient();
  c.capacity = [withGuests([guest("odd", 4, 8, 2)])];
  check(checkGuestMemory(c).status === "fail", "resident above declared fails");
}

{
  const c = new FakeClusterClient();
  c.capacity = [withGuests([guest("off", 8, 0, 0, true, "qemu", "stopped")])];
  const sr = checkGuestMemory(c);
  check(sr.status === "skip", "nothing running: the gate asserts nothing");
  check((sr.rows ?? []).some((x) => x.text.includes("(stopped)")), "…but a stopped module is still listed");
  const d = new FakeClusterClient();
  d.capacityThrows = "unreachable";
  check(checkGuestMemory(d).status === "skip", "an unreachable cluster skips");
}

{
  // Short of memory is a MODULE problem; over-declared is not. The bands must
  // read the guest's use against its own declaration, not against the node.
  const c = new FakeClusterClient();
  c.capacity = [withGuests([
    guest("tight", 4, 3.8, 3.7),   // 92% — critical
    guest("busy", 4, 3.2, 3.1),    // 78% — warn
    guest("roomy", 8, 2.0, 1.0),   // 13% — fine
  ])];
  const r = checkGuestMemory(c);
  const byName = (n: string) => (r.rows ?? []).find((x) => x.text.startsWith(n));
  check(byName("tight")?.status === "fail", "a guest using 92% of its memory is critical");
  check(byName("busy")?.status === "warn", "a guest at 78% warns");
  check(byName("roomy")?.status === "pass", "a guest with room passes");
  check(r.status === "fail", "the gate takes the worst row");
}

{
  // A PVE template is the image modules are cloned from. The client filters it
  // out before the gate ever sees it, so this pins the gate's own behaviour:
  // whatever reaches it is a module, and stopped modules still get a row.
  const c = new FakeClusterClient();
  c.capacity = [withGuests([guest("live", 4, 2, 1), guest("halted", 8, 0, 0, true, "qemu", "stopped")])];
  const rows = (checkGuestMemory(c).rows ?? []).map((x) => x.text).join("\n");
  check(rows.includes("halted") && rows.includes("(stopped)"), "a stopped module is still listed");
}

{
  // Mixed estate: the VM total must not absorb the LXC limit. This is the
  // number that read 106G when the VMs had been promised 60G.
  const c = new FakeClusterClient();
  c.capacity = [withGuests([guest("vm", 8, 4, 3), guest("ct", 46, 0, 2, true, "lxc")])];
  const rows = (checkGuestMemory(c).rows ?? []).map((x) => x.text).join("\n");
  check(/── VM totals\s+8\.0G/.test(rows), `the VM total excludes the LXC limit (got: ${rows})`);
  check(/── LXC totals\s+46\.0G/.test(rows), "the LXC total carries it instead");
}

// ── #833: what the node commits once the update has converged ─────────
// The reporter's 16 GB node: identity tuned to 1.75G in Proxmox, 4G in config.
{
  const dir = mkdtempSync(join(tmpdir(), "hm-cap-"));
  // vmids follow node()'s numbering: 100 cicd, 101 network, 102 identity.
  writeFileSync(join(dir, "tappaas-cicd.json"), JSON.stringify({ vmid: 100, memory: 6144 }));
  writeFileSync(join(dir, "network.json"), JSON.stringify({ vmid: 101, config: { "cluster:vm": { memory: 4096 } } }));
  writeFileSync(join(dir, "identity.json"), JSON.stringify({ vmid: 102, memory: 4096 }));
  const c = new FakeClusterClient();
  c.capacity = [node("tappaas1", 15, 14, [["tappaas-cicd", 6, "running"], ["network", 4, "running"], ["identity", 1.75, "running"]])];
  check(checkMemoryCommitment(c, 100).status === "pass", "today's sizes fit (78%): the live gate cannot see it coming");
  const r = checkUpdateCapacity(c, dir, "tappaas1", 90);
  check(r.status === "fail", "after the update identity is 4G: growth takes the node over 90% — refused");
  check(r.detail.includes("identity 1.8→4.0G"), `the guest that grows is named (got: ${r.detail})`);
  const ok = checkUpdateCapacity(c, dir, "tappaas1", 100);
  check(ok.status === "warn" && (ok.rows?.[0].text.includes("93%") ?? false), `growth under the threshold warns, with the projection (got: ${ok.rows?.[0].text})`);
  check(ok.detail.includes("memory changes") && ok.detail.includes("78% now"), `the warning says memory changes and where it is now (got: ${ok.detail})`);
  writeFileSync(join(dir, "identity.json"), JSON.stringify({ vmid: 102, memory: 1024 }));
  check(checkUpdateCapacity(c, dir, "tappaas1", 90).status === "pass", "a config smaller than live never counts below live (no shrink assumed)");
}

// The makerfloss case: every guest on one node, already past the threshold,
// and the update grows nothing — the update goes ahead with a warning.
{
  const dir = mkdtempSync(join(tmpdir(), "hm-cap-"));
  writeFileSync(join(dir, "tappaas-cicd.json"), JSON.stringify({ vmid: 100, memory: 6144 }));
  writeFileSync(join(dir, "network.json"), JSON.stringify({ vmid: 101, memory: 4096 }));
  const c = new FakeClusterClient();
  c.capacity = [node("tappaas1", 9.5, 10, [["tappaas-cicd", 6, "running"], ["network", 4, "running"]])];
  const r = checkUpdateCapacity(c, dir, "tappaas1", 95);
  check(r.status === "warn", `over the threshold, nothing grows: warn, not refuse (got: ${r.status} ${r.detail})`);
  check(r.detail.includes("already so") && r.detail.includes("rebalance"), `it says so, and what to do (got: ${r.detail})`);

  // A new module on that node: the hard stop.
  writeFileSync(join(dir, "vault.json"), JSON.stringify({ vmid: 140, node: "tappaas1", memory: 2048 }));
  const add = checkUpdateCapacity(c, dir, "tappaas1", 95, "vault");
  check(add.status === "fail" && add.detail.includes("new vault 2.0G"), `installing onto an over-committed node is refused (got: ${add.detail})`);
  check(checkUpdateCapacity(c, dir, "tappaas1", 95).status === "warn", "an un-installed config is not counted by the sweep");

  // The same module placed on an empty node passes.
  c.capacity.push(node("tappaas2", 30, 0, []));
  writeFileSync(join(dir, "vault.json"), JSON.stringify({ vmid: 140, config: { "cluster:vm": { node: "tappaas2", memory: 2048 } } }));
  const elsewhere = checkUpdateCapacity(c, dir, "tappaas1", 95, "vault");
  const t2 = elsewhere.rows?.find((x) => x.text.startsWith("tappaas2"));
  check(t2?.status === "warn" && elsewhere.status === "warn", `on a node with room it is a memory change, not a refusal (got: ${elsewhere.detail})`);
}

console.log(`capacity: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
