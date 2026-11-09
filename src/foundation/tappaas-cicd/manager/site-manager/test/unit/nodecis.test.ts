// nodecis.test.ts — the CIs node delete retires (ADR-040 D7): read from a fake
// CMDB, what is known by the node (its pools, its software) and nothing else
// that points at it; the change report's order; the preview's words.

import { CmdbRefused, CmdbUnavailable } from "../../../../lib/ts/src/cmdb";
import { CmdbReader, ciWords, keyedBy, nodeCis, retireLine, retireObjects } from "../../src/nodecis";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

const runsOnKey = { keys: [{ rank: 1, components: ["name", "onNode"] }], fields: [{ name: "name", type: "string" }, { name: "onNode", type: "relation", spec: { relation: "runs-on" } }] };
const CLASSES: Record<string, unknown> = {
  "storage-pool": runsOnKey,
  app: runsOnKey,
  // a guest runs on the node but is known by its VMID: it moves, it is not retired
  vm: { keys: [{ rank: 1, components: ["vmid"] }, { rank: 2, components: ["name"] }], fields: [{ name: "vmid", type: "integer" }, { name: "onNode", type: "relation", spec: { relation: "runs-on" } }] },
  // the asset is allocated to the node: another lifecycle
  server: { keys: [{ rank: 1, components: ["serial"] }], fields: [{ name: "serial", type: "string" }] },
  datastore: { keys: [], fields: [{ name: "onNode", type: "relation", spec: { relation: "runs-on" } }] },
};
const node = { id: "n-4", class: "machine", name: "tappaas4" };
const rel = (type: string, from: { id: string; class: string; name: string }) => ({ type, from, to: node });
const RELS = [
  rel("runs-on", { id: "p-1", class: "storage-pool", name: "tanka1" }),
  rel("runs-on", { id: "p-2", class: "storage-pool", name: "rpool" }),
  rel("runs-on", { id: "a-1", class: "app", name: "pve" }),
  rel("runs-on", { id: "v-1", class: "vm", name: "nextcloud" }),
  rel("runs-on", { id: "d-1", class: "datastore", name: "tappaas_backup" }),
  rel("allocated-to", { id: "s-4", class: "server", name: "srv-04" }),
];
const reader = (rels: unknown[]): CmdbReader => ({ relationsTo: () => rels as Record<string, unknown>[], classKeys: (c) => CLASSES[c] as Record<string, unknown> });

// 1. keyedBy: a key component that is a relation of the type, outward
check(keyedBy(runsOnKey, "runs-on"), "a pool is known by its node");
check(!keyedBy(CLASSES.vm as Record<string, unknown>, "runs-on"), "a vm is not: its key is its VMID");
check(!keyedBy({ keys: [{ components: ["asset"] }], fields: [{ name: "asset", type: "relation", spec: { relation: "allocated-to", direction: "in" } }] }, "allocated-to"), "an inward key relation (the machine's asset) is not");

// 2. nodeCis: the node, its pools and software — not its guests, datastore or asset
const r = nodeCis("tappaas4", reader(RELS));
check(r.answered && r.node?.id === "n-4", "the node's own CI");
check(r.known.map((c) => c.id).join() === "a-1,p-2,p-1", `its pools and software, sorted by class and name (${r.known.map((c) => c.id).join()})`);
const other = nodeCis("tappaas4", reader([...RELS, { type: "runs-on", from: { id: "p-9", class: "storage-pool", name: "tanka1" }, to: { id: "n-3", class: "machine", name: "tappaas3" } }]));
check(!other.known.some((c) => c.id === "p-9"), "a pool of the same name on another node is not among them");

// 3. the CMDB down, or no live CI of that name
const down = nodeCis("tappaas4", { relationsTo: () => { throw new CmdbUnavailable("no socket"); }, classKeys: () => ({}) });
check(!down.answered && down.known.length === 0, "the CMDB down: not answered");
const gone = nodeCis("tappaas4", { relationsTo: () => { throw new CmdbRefused(404, { error: "no object" }); }, classKeys: () => ({}) });
check(gone.answered && gone.node === null, "no live CI: answered, nothing to retire");

// 4. the change report: the known by id first, then the node by name
const objs = retireObjects("tappaas4", r);
check(objs.map((o) => o.id ?? `${o.class}/${o.name}`).join() === "a-1,p-2,p-1,machine/tappaas4", "pools and software by id before the node");
check(objs.every((o) => o.end === true), "every one ended");
check(retireObjects("tappaas4", null).length === 1, "without the CMDB's answer: the node alone (the controller ends what is known by it)");

// 5. the words
check(ciWords(r.known) === "app pve; pools rpool, tanka1", `in the operator's words (${ciWords(r.known)})`);
check(/^then: retired in the CMDB: CI tappaas4 with its app pve; pools rpool, tanka1 — never reused, its history kept$/.test(retireLine("tappaas4", r, false)), retireLine("tappaas4", r, false));
check(/^retired in the CMDB: CI tappaas4/.test(retireLine("tappaas4", r, true)), "the apply says what went");
check(/did not answer/.test(retireLine("tappaas4", down, false)), "the preview says when the CMDB did not answer");
check(/no live CI tappaas4/.test(retireLine("tappaas4", gone, false)), "…and when there is nothing to retire");

console.log(`nodecis.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
