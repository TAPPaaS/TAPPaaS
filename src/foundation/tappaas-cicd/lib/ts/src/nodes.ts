// nodes.ts — the cluster's nodes are their pvehost instances (ADR-036 D6).
//
// Every Proxmox node of the cluster is a module instance of kind machine,
// module `pvehost`: config/<node>.json, with its `address`, `uplinks`, `zone0`,
// `location` and the `storagePools` (the tankXY zpools) it carries. There is no
// other list of nodes: every manager, the console and the bash layer
// (lib/cluster-nodes.sh, the same rules) list them from the instances, here.
//
// Order: by name, numbers compared as numbers (tappaas2 before tappaas10).
// The first is the primary node — tappaas1 creates the cluster and is node 1.
//
// A site.json from before migration 0022 still has `hardware.nodes[]`
// ({name, storagePools}). Until the migration has run, an instance without
// `storagePools` takes the list's, and a listed node with no instance yet is a
// node at <name>.<mgmt domain> — so a reader works between the pull and the
// migration. Nothing writes the old list.

import { existsSync, readFileSync, readdirSync } from "fs";
import { basename, join } from "path";
import { mgmtDomain } from "./cluster";
import { defaultConfigDir, readJsonObject, writeJsonAtomic } from "./config-io";
import { moduleOfLocation, moduleSourceOf } from "./instance";

type Obj = Record<string, unknown>;

export const NODE_MODULE = "pvehost";

export interface ClusterNode {
  name: string;
  address: string;
  storagePools: string[];
  location?: string;
  uplinks?: Obj;
}

const obj = (v: unknown): Obj | null => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

/** Node order: by name, a run of digits compared as a number. */
export function compareNodeNames(a: string, b: string): number {
  return a.localeCompare(b, "en", { numeric: true });
}

/** True when a parsed config is a pvehost instance that is part of the site
 *  (an archived one is a node that was deleted). */
export function isNodeInstance(raw: Obj | null): boolean {
  if (!raw) return false;
  const src = moduleSourceOf(raw);
  return src !== "" && moduleOfLocation(src) === NODE_MODULE && raw.status !== "archived";
}

function readObj(file: string): Obj | null {
  try {
    const v = JSON.parse(readFileSync(file, "utf8"));
    return obj(v);
  } catch {
    return null;
  }
}

/** site.json's retired node list, while migration 0022 has not run. */
function legacyNodes(configDir: string): { name: string; storagePools: string[] }[] {
  const site = readObj(join(configDir, "site.json"));
  const nodes = obj(site?.hardware)?.nodes;
  if (!Array.isArray(nodes)) return [];
  return nodes
    .map(obj)
    .filter((n): n is Obj => n !== null && typeof n.name === "string" && n.name !== "")
    .map((n) => ({ name: n.name as string, storagePools: strings(n.storagePools) }));
}

/** The cluster's nodes: every pvehost instance, in node order. */
export function clusterNodes(configDir: string = defaultConfigDir()): ClusterNode[] {
  const out = new Map<string, ClusterNode>();
  if (existsSync(configDir)) {
    for (const f of readdirSync(configDir)) {
      if (!f.endsWith(".json")) continue;
      const raw = readObj(join(configDir, f));
      if (!isNodeInstance(raw)) continue;
      const name = basename(f, ".json");
      const node: ClusterNode = {
        name,
        address: typeof raw!.address === "string" && raw!.address !== "" ? raw!.address : `${name}.${mgmtDomain()}`,
        storagePools: strings(raw!.storagePools),
      };
      if (typeof raw!.location === "string" && raw!.location !== "" && !raw!.location.includes("/")) node.location = raw!.location;
      const up = obj(raw!.uplinks);
      if (up) node.uplinks = up;
      out.set(name, node);
    }
  }
  for (const l of legacyNodes(configDir)) {
    const known = out.get(l.name);
    if (!known) out.set(l.name, { name: l.name, address: `${l.name}.${mgmtDomain()}`, storagePools: l.storagePools });
    else if (known.storagePools.length === 0 && !hasOwnPools(configDir, l.name)) known.storagePools = l.storagePools;
  }
  return [...out.values()].sort((a, b) => compareNodeNames(a.name, b.name));
}

// An instance that states `storagePools: []` has said so; only an instance
// without the field takes the retired list's.
function hasOwnPools(configDir: string, name: string): boolean {
  return Array.isArray(readObj(join(configDir, `${name}.json`))?.storagePools);
}

export function clusterNodeNames(configDir: string = defaultConfigDir()): string[] {
  return clusterNodes(configDir).map((n) => n.name);
}

export function clusterNode(configDir: string, name: string): ClusterNode | null {
  return clusterNodes(configDir).find((n) => n.name === name) ?? null;
}

/** Set a node's storagePools on its pvehost instance. Throws when <name> is
 *  no pvehost instance. */
export function setNodeStoragePools(configDir: string, name: string, pools: string[]): void {
  const file = join(configDir, `${name}.json`);
  const raw = readJsonObject(file);
  if (!isNodeInstance(raw)) throw new Error(`${name} is not a cluster node (no pvehost instance config/${name}.json)`);
  raw!.storagePools = [...new Set(pools)].sort();
  writeJsonAtomic(file, raw);
}

/** What `validate` refuses about the nodes in site.json: the retired list. */
export function nodeErrors(site: Obj): string[] {
  return "hardware" in site
    ? ["site.json still carries hardware, which is retired: the nodes are their pvehost instances, and migration 0022 moves each node's storagePools onto its instance (it runs with the next update)"]
    : [];
}
