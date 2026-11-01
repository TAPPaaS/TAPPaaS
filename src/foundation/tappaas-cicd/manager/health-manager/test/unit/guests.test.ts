// guests.test.ts — `guests`: the ZFS names Proxmox gives a guest's volumes, and
// each guest and volume joined to its module.

import { nodeGuests, parseCpu, parseVolumes } from "../../src/guests";
import { GuestMemory, NodeCapacity } from "../../src/types";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const v = parseVolumes([
  "tanka1\t100\t0\t-",
  "tanka1/vm-110-disk-0\t2048\t256\t8192",
  "tanka1/subvol-200-disk-1\t4096\t0\t-",
  "rpool/data/vm-300-cloudinit\t512\t0\t4096",
  "rpool/ROOT/pve-1\t999\t0\t-",
  "garbage line",
].join("\n"));
check(v.length === 3, "only the datasets named after a vmid");
check(v[0].pool === "tanka1" && v[0].vmid === 110 && v[0].used === 2048 && v[0].snapshots === 256 && v[0].size === 8192, "a zvol: its pool, vmid, data on disk, snapshots and size");
check(v[1].vmid === 200 && v[1].size === null, "a container's filesystem has no fixed size");
check(v[2].pool === "rpool" && v[2].volume === "vm-300-cloudinit", "a nested dataset belongs to the pool it is in");

const g = (vmid: number, name: string, declaredMem: number): GuestMemory => ({ vmid, name, node: "", status: "running", type: "qemu", declaredMem, usedMem: 1, residentMem: 1, measured: true });
const cap = (node: string, guests: GuestMemory[]): NodeCapacity => ({ node, physicalMem: 100, usedMem: 50, committedMem: 10, guests });
const docs = nodeGuests(
  [cap("a", [g(110, "small", 1), g(120, "big", 9)]), cap("b", [g(300, "elsewhere", 2)])],
  new Map([["a", [{ pool: "p", volume: "vm-110-disk-0", vmid: 110, used: 5, snapshots: 0, size: 9 }, { pool: "p", volume: "vm-300-disk-0", vmid: 300, used: 7, snapshots: 0, size: 9 }, { pool: "p", volume: "vm-999-disk-0", vmid: 999, used: 1, snapshots: 0, size: 1 }]]]),
  new Map([[110, "firewall"], [300, "nextcloud"]]),
);
check(docs[0].guests[0].name === "big" && docs[0].guests[0].module === null, "the largest guest first; a vmid no module holds has none");
check(docs[0].guests[1].module === "firewall", "a guest carries its module");
check(docs[0].volumes[0].module === "nextcloud" && docs[0].volumes[0].replica, "a guest on another node: this copy is its replica");
check(docs[0].volumes[1].replica === false, "a guest here: its own volume");
check(docs[0].volumes[2].module === null && !docs[0].volumes[2].replica, "a volume of no guest is listed, unattributed");

const twoSockets = ["# The following is the parsable format", "# CPU,Core", "0,0", "1,0", "0,0", "1,0", "0,1", "1,1", "0,1", "1,1"].join("\n");
check(parseCpu(twoSockets)?.cores === 4 && parseCpu(twoSockets)?.threads === 8, "cores and threads over every socket");
check(parseCpu("") === null, "no answer, no processors");
const cpus = nodeGuests([cap("a", []), cap("b", [])], new Map(), new Map(), new Map([["a", { cores: 12, threads: 24 }]]));
check(cpus[0].cpu?.threads === 24 && cpus[1].cpu === null, "a node's processors; a node that did not answer has none");

console.log(`\nguests: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
