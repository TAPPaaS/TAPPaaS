// nodes.test.ts — the cluster's nodes are their pvehost instances (ADR-036
// D6): the lib/ts helper every manager lists them through, its order, the
// window before migration 0022, and the one writer of a node's pools.

import { clusterNode, clusterNodeNames, clusterNodes, compareNodeNames, nodeErrors, setNodeStoragePools } from "../../../../lib/ts/src/nodes";
import { mkdtempSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}
function throws(f: () => unknown, re: RegExp, msg: string): void {
  try {
    f();
    check(false, `${msg} (did not throw)`);
  } catch (e) {
    check(re.test(String((e as Error).message)), `${msg} (threw: ${(e as Error).message})`);
  }
}
type Obj = Record<string, unknown>;
const PVE = { kind: "machine", moduleSource: "/home/tappaas/TAPPaaS/src/foundation/pvehost", zone0: "mgmt" };

function cfg(files: Record<string, Obj>): string {
  const dir = mkdtempSync(join(tmpdir(), "nodes-test-"));
  for (const [f, doc] of Object.entries(files)) writeFileSync(join(dir, f), JSON.stringify(doc));
  return dir;
}

// 1. The instances, in node order; nothing else in config/ is a node.
{
  const dir = cfg({
    "tappaas10.json": { ...PVE, address: "tappaas10.mgmt.internal", storagePools: [] },
    "tappaas2.json": { ...PVE, address: "10.0.0.11", storagePools: ["tanka1"], location: "home", uplinks: { lan: { mode: "single", ports: [] } } },
    "tappaas1.json": { ...PVE, address: "tappaas1.mgmt.internal", storagePools: ["tanka1", "tankb1"] },
    "tappaas4.json": { ...PVE, address: "tappaas4.mgmt.internal", status: "archived" },
    "nas.json": { kind: "machine", moduleSource: "/home/tappaas/TAPPaaS/src/foundation/debianhost", address: "10.0.0.90" },
    "nextcloud.json": { kind: "vm", moduleSource: "/home/tappaas/TAPPaaS/src/collaboration/nextcloud", node: "tappaas1" },
    "site.json": { name: "acme" },
  });
  check(clusterNodeNames(dir).join() === "tappaas1,tappaas2,tappaas10", `node order, numbers as numbers (${clusterNodeNames(dir).join()})`);
  const n2 = clusterNode(dir, "tappaas2");
  check(n2?.address === "10.0.0.11" && n2.storagePools.join() === "tanka1" && n2.location === "home" && !!n2.uplinks, "a node carries its address, pools, location and uplinks");
  check(clusterNode(dir, "tappaas4") === null, "an archived instance is no node");
  check(clusterNode(dir, "nas") === null, "a debianhost is no node");
  check(compareNodeNames("tappaas9", "tappaas10") < 0, "tappaas9 sorts before tappaas10");

  setNodeStoragePools(dir, "tappaas10", ["tankb1", "tanka1", "tanka1"]);
  const raw = JSON.parse(readFileSync(join(dir, "tappaas10.json"), "utf8")) as Obj;
  check(JSON.stringify(raw.storagePools) === '["tanka1","tankb1"]' && raw.address === "tappaas10.mgmt.internal", "setNodeStoragePools writes the field, sorted and unique, and keeps the rest");
  throws(() => setNodeStoragePools(dir, "nas", ["tanka1"]), /not a cluster node/, "setNodeStoragePools refuses a machine that is no node");
  throws(() => setNodeStoragePools(dir, "tappaas7", ["tanka1"]), /not a cluster node/, "setNodeStoragePools refuses a node with no instance");
}

// 2. Before migration 0022: site.json's retired list fills what the instances lack.
{
  const dir = cfg({
    "tappaas1.json": { ...PVE, address: "tappaas1.mgmt.internal", storagePools: ["tanka1", "tankb1"] },
    "tappaas3.json": { ...PVE, address: "tappaas3.mgmt.internal" },
    "tappaas2.json": { ...PVE, address: "tappaas2.mgmt.internal", storagePools: [] },
    "site.json": { name: "acme", hardware: { nodes: [
      { name: "tappaas1", storagePools: ["other"] },
      { name: "tappaas3", storagePools: ["tanka1", "tankc1"] },
      { name: "tappaas2", storagePools: ["tanka1"] },
      { name: "tappaas5", storagePools: ["tanka1"] },
    ] } },
  });
  const ns = clusterNodes(dir);
  check(ns.map((n) => n.name).join() === "tappaas1,tappaas2,tappaas3,tappaas5", `a listed node with no instance is still a node (${ns.map((n) => n.name).join()})`);
  check(ns[0].storagePools.join() === "tanka1,tankb1", "an instance's own pools win over the list");
  check(ns[1].storagePools.length === 0, "an instance that states [] keeps it");
  check(ns[2].storagePools.join() === "tanka1,tankc1", "an instance without the field takes the list's");
  check(ns[3].address === "tappaas5.mgmt.internal" && ns[3].storagePools.join() === "tanka1", "a listed node is reached at <name>.<mgmt domain>");
}

// 3. validate refuses the retired list.
check(nodeErrors({ name: "s", hardware: { nodes: [] } }).some((e) => /hardware.*retired.*0022/.test(e)), "nodeErrors refuses a leftover hardware");
check(nodeErrors({ name: "s" }).length === 0, "nodeErrors is quiet without it");
check(clusterNodes("/nonexistent/config").length === 0, "no config directory: no nodes");

console.log(`nodes.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
