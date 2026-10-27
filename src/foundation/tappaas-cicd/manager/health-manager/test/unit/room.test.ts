// room.test.ts — which pauseOk modules the update suspends for room (#891).

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkRoom } from "../../src/room";
import { GuestMemory, NodeCapacity } from "../../src/types";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const G = 1024 ** 3;
const guest = (vmid: number, node: string, gb: number, status = "running", ha = false): GuestMemory =>
  ({ vmid, name: `g${vmid}`, node, status, type: "qemu", declaredMem: gb * G, usedMem: 0, residentMem: 0, measured: true, ha });
const nodeOf = (name: string, physical: number, guests: GuestMemory[]): NodeCapacity => ({
  node: name, physicalMem: physical * G, usedMem: 0, guests,
  committedMem: guests.filter((g) => g.status === "running").reduce((a, g) => a + g.declaredMem, 0),
});
const cfg = (dir: string, name: string, obj: Record<string, unknown>): void => writeFileSync(join(dir, `${name}.json`), JSON.stringify(obj));

// ── resume: a suspended module that only fits once others are paused ──
{
  const dir = mkdtempSync(join(tmpdir(), "room-"));
  cfg(dir, "media", { vmid: 300, memory: 8192, suspended: true });
  cfg(dir, "ai", { vmid: 301, memory: 12288, pauseOk: true, pausePriority: 50 });
  cfg(dir, "wiki", { vmid: 302, memory: 4096, pauseOk: true, pausePriority: 10 });
  cfg(dir, "network", { vmid: 303, memory: 4096, pauseOk: true, stack: "foundation" });
  cfg(dir, "web", { vmid: 304, memory: 4096 });
  const c = new FakeClusterClient();
  c.capacity = [nodeOf("tappaas1", 32, [guest(300, "tappaas1", 8, "stopped"), guest(301, "tappaas1", 12), guest(302, "tappaas1", 4), guest(303, "tappaas1", 4), guest(304, "tappaas1", 4)])];
  // 24G running + 8G = 32G against 30.4G: does not fit; wiki (prio 10) frees 4G → 28G fits.
  const r = checkRoom(c, dir, "tappaas1", 95, { kind: "resume", module: "media" });
  check(!r.fits && r.possible && r.pause.join() === "wiki", `the lowest pausePriority is paused first, and only as many as needed (got: ${JSON.stringify(r)})`);
  c.capacity[0].physicalMem = 26 * G;
  const r2 = checkRoom(c, dir, "tappaas1", 95, { kind: "resume", module: "media" });
  // limit 24.7G: wiki → 28G, ai → 16G fits; network (foundation) and web (no pauseOk) never.
  check(r2.possible && r2.pause.join() === "wiki,ai", `then the next (got: ${r2.pause.join()})`);
  c.capacity[0].physicalMem = 14 * G;
  const r3 = checkRoom(c, dir, "tappaas1", 95, { kind: "resume", module: "media" });
  check(!r3.possible && r3.pause.length === 0 && r3.detail.includes("even with every pauseOk"), `a foundation module or one without pauseOk is never paused: not possible (got: ${r3.detail})`);
  c.capacity[0].physicalMem = 64 * G;
  check(checkRoom(c, dir, "tappaas1", 95, { kind: "resume", module: "media" }).fits, "with room, nothing is paused");
}

// ── drain: a node's HA guests onto the others ─────────────────────────
{
  const dir = mkdtempSync(join(tmpdir(), "room-"));
  cfg(dir, "a", { vmid: 400, memory: 8192 });
  cfg(dir, "b", { vmid: 401, memory: 8192, pauseOk: true, pausePriority: 20 });
  cfg(dir, "plain", { vmid: 402, memory: 8192, pauseOk: true, pausePriority: 1 });
  cfg(dir, "other", { vmid: 403, memory: 6144, pauseOk: true, pausePriority: 30 });
  const c = new FakeClusterClient();
  c.capacity = [
    nodeOf("tappaas1", 32, [guest(400, "tappaas1", 8, "running", true), guest(401, "tappaas1", 8, "running", true), guest(402, "tappaas1", 8, "running", false)]),
    nodeOf("tappaas2", 24, [guest(403, "tappaas2", 6), guest(404, "tappaas2", 6)]),
  ];
  // moving 16G (HA only) + 12G committed on tappaas2 = 28G against 22.8G.
  const r = checkRoom(c, dir, "tappaas1", 95, { kind: "drain", node: "tappaas1" });
  check(!r.fits && r.possible && r.pause.join() === "b", `the non-HA guest restarts with the node and is not paused; pausing b takes it out of the move (got: ${JSON.stringify(r)})`);
  check(checkRoom(c, dir, "tappaas1", 95, { kind: "drain", node: "tappaas2" }).fits, "tappaas2's guests are not HA: nothing moves");
  c.capacity = [c.capacity[0]];
  check(checkRoom(c, dir, "tappaas1", 95, { kind: "drain", node: "tappaas1" }).fits, "a single node: nothing to drain onto, nothing paused");
}

console.log(`room: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
