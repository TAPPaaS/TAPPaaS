// nodes.test.ts — the cluster's nodes are their pvehost instances (ADR-036
// D6): the lib/ts helper every manager lists them through, its order, the
// window before migration 0022, and the one writer of a node's pools.

import { run } from "../../src/main";
import { FakeSiteClient } from "./fake-client";
import { clusterNode, clusterNodeNames, clusterNodes, compareNodeNames, nodeErrors, setNodeStoragePools } from "../../../../lib/ts/src/nodes";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
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

// 4. The node verbs read and write the instances.
function quiet(argv: string[]): { rc: number; out: string[] } {
  const out: string[] = [];
  const [l, e] = [console.log, console.error];
  console.log = (m: string) => void out.push(String(m));
  console.error = (m: string) => void out.push(String(m));
  try {
    return { rc: run(argv, new FakeSiteClient()), out };
  } finally {
    [console.log, console.error] = [l, e];
  }
}
{
  const SITE = { name: "acme", displayName: "Acme", owner: "acme", defaultEnvironment: "acme",
    locations: { home: { country: "DK", timezone: "Europe/Copenhagen" } }, primaryLocation: "home", repositories: [] };
  const dir = cfg({
    "site.json": SITE,
    "tappaas1.json": { ...PVE, address: "tappaas1.mgmt.internal", storagePools: ["tanka1"] },
    "tappaas2.json": { ...PVE, address: "tappaas2.mgmt.internal", storagePools: [], location: "home" },
  });
  const list = quiet(["node", "list", "--json", "--config-dir", dir]);
  const parsed = JSON.parse(list.out.join("\n")) as { name: string; storagePools: string[]; location?: string }[];
  check(list.rc === 0 && parsed.map((n) => n.name).join() === "tappaas1,tappaas2" && parsed[1].location === "home", `node list --json lists the instances (${list.out.join(" ")})`);

  // node add --config-only writes the pvehost record through copy-update-json.sh.
  const bin = join(dir, "bin");
  mkdirSync(bin);
  const mod = join(dir, "pvehost");
  mkdirSync(mod);
  writeFileSync(join(mod, "pvehost.json"), JSON.stringify({ kind: "machine" }));
  writeFileSync(join(bin, "copy-update-json.sh"),
    '#!/usr/bin/env bash\necho "$PWD $*" > "$CONFIG_DIR/copy.args"\n' +
    'printf \'{"kind":"machine","moduleSource":"%s","address":"tappaas3.mgmt.internal","storagePools":["tanka1","tankc1"]}\' "$PWD" > "$CONFIG_DIR/tappaas3.json"\n');
  chmodSync(join(bin, "copy-update-json.sh"), 0o755);
  process.env.SITE_COPY_JSON_BIN = join(bin, "copy-update-json.sh");
  process.env.SITE_PVEHOST_DIR = mod;
  const add = quiet(["node", "add", "tappaas3", "--config-only", "--storage-pools", "tanka1,tankc1", "--config-dir", dir]);
  const args = existsSync(join(dir, "copy.args")) ? readFileSync(join(dir, "copy.args"), "utf8") : "";
  check(add.rc === 0 && args.startsWith(`${mod} pvehost --instance tappaas3 --address tappaas3.mgmt.internal --zone0 mgmt --environment mgmt --storagePools ["tanka1","tankc1"]`),
    `node add --config-only writes the pvehost record with its pools (${args.trim()} | ${add.out.join(" ")})`);
  check(!("hardware" in (JSON.parse(readFileSync(join(dir, "site.json"), "utf8")) as Obj)), "node add writes nothing into site.json");
  const again = quiet(["node", "add", "tappaas1", "--config-only", "--config-dir", dir]);
  check(again.rc !== 0 && again.out.some((l) => l.includes("already exists")), "node add refuses a node that has its record");
  delete process.env.SITE_COPY_JSON_BIN;
  delete process.env.SITE_PVEHOST_DIR;

  const reboot = quiet(["node", "reboot", "tappaas9", "--config-dir", dir]);
  check(reboot.rc !== 0 && reboot.out.some((l) => l.includes("not one of this site's nodes")), "node reboot refuses a name that is no node");

  // validate refuses the retired list.
  writeFileSync(join(dir, "site.json"), JSON.stringify({ ...SITE, hardware: { nodes: [{ name: "tappaas1", storagePools: [] }] } }));
  const v = quiet(["validate", join(dir, "site.json")]);
  check(v.rc !== 0 && v.out.some((l) => l.includes("hardware, which is retired")), `validate refuses a leftover hardware (rc ${v.rc}: ${v.out.join(" | ")})`);
}

console.log(`nodes.test: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
