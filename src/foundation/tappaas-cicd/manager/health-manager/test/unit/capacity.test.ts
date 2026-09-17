// capacity.test.ts — the memory-commitment gate (#569).
//
// COMMITTED, not used: without ballooning a guest's declared memory is pinned by
// the host whether the guest wants it or not, so committed is what decides
// whether another guest fits. `used` can legitimately exceed it — ZFS ARC and
// host overhead live outside any guest — which is why the gate must not be
// written against `used`.

import { checkGuestMemory, checkMemoryCommitment } from "../../src/checks";
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
  check(/totals[\s\S]*reclaimable 2\.9G/.test(rows), `totals count resident-minus-used only (got: ${rows})`);
  check(/── totals\s+24\.0G\s+8\.6G\s+5\.7G/.test(rows), `each column is totalled (got: ${rows})`);
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
  check(r.detail.includes("1 unmeasured"), "the summary line counts it");
}

{
  // An LXC limit is not an allocation and needs no agent.
  const c = new FakeClusterClient();
  c.capacity = [withGuests([guest("vllm", 46, 0, 2.1, true, "lxc")])];
  const r = checkGuestMemory(c);
  const rows = (r.rows ?? []).map((x) => x.text).join("\n");
  check(r.status === "pass", "an LXC with a large unused limit is not a problem");
  check(rows.includes("cgroup, not an allocation"), "an LXC row says its figure is a limit");
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

console.log(`capacity: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
