// capacity.test.ts — the memory-commitment gate (#569).
//
// COMMITTED, not used: without ballooning a guest's declared memory is pinned by
// the host whether the guest wants it or not, so committed is what decides
// whether another guest fits. `used` can legitimately exceed it — ZFS ARC and
// host overhead live outside any guest — which is why the gate must not be
// written against `used`.

import { checkMemoryCommitment } from "../../src/checks";
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
    vmid: 100 + i, name: g[0], node: name, status: g[2],
    declaredMem: g[1] * G, usedMem: 0,
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

console.log(`capacity: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
