# #872 — the cluster's nodes are their pvehost instances

Working survey and plan for #872, ADR-036 D6. `site.json` `hardware.nodes[]` repeats the names of
the cluster's `pvehost` module instances and adds one thing of its own, each node's
`storagePools[]`. The list goes: `storagePools` becomes a field of the `pvehost` instance,
`site.hardware` is retired, and every reader lists the nodes through one helper.

Out of scope: a node's `location` (step 3, #871, which puts `location` on every machine
module; the helper passes it through), the console's Physical view (unchanged: it reads the
topology, whose nodes keep their shape).

## The shape

```jsonc
// config/tappaas1.json (module pvehost, kind machine)
{
  "kind": "machine", "moduleSource": "/home/tappaas/TAPPaaS/src/foundation/pvehost",
  "address": "tappaas1.mgmt.internal", "zone0": "mgmt",
  "uplinks": { "lan": { "mode": "lacp", "ports": ["00:07:43:38:aa:f0", "00:07:43:38:aa:f8"] } },
  "storagePools": ["tanka1", "tankb1"],          // new: was site.hardware.nodes[i].storagePools
  "location": "knudanchersvej95"                  // #871 (absent = the primary location)
}
// config/site.json: no "hardware"
```

| field | | change class |
|---|---|---|
| `storagePools` (module-fields.json, `usedBy: general`; class in `schemas/fields.json`) | the `tankXY` zpools the node carries, unique strings matching `^tank` | in-place, apply none: writing it changes nothing on the node; the cluster update's storage reconcile adds the node to each named pool's storage `nodes` list; a pool taken out is reported, never removed (the reconcile only adds, so the class cannot be stronger than that) |
| `site.hardware` (site-fields.json) | retired: `deprecated`, out of `required`, classified `manual` so a site.json migration 0022 has not reached is reported rather than unknown | `site-manager validate` refuses it |

## The helper

`lib/ts/src/nodes.ts`:

- `clusterNodes(configDir): ClusterNode[]` — every `pvehost` instance (`config/*.json` whose
  `moduleSource` names the `pvehost` module; archived and external instances left out), as
  `{ name, address, storagePools, location?, uplinks? }`, in node order: by name, numbers
  compared as numbers (`tappaas2` before `tappaas10`). The first is the primary node, as
  `hardware.nodes[0]` was (create-site wrote the list in node-id order, which is name order
  on every TAPPaaS cluster: `tappaas1` creates it).
- `clusterNodeNames(configDir)`, `clusterNode(configDir, name)`.
- `setNodeStoragePools(configDir, name, pools)` — the one writer of the field outside
  `module modify` (reconcile's fill, migration-free adoption).
- `nodeErrors(site)` — `["site.json still carries hardware, which is retired: migration 0022 …"]`.
- The window between the pull and the migration: while `site.json` still has
  `hardware.nodes`, an instance without `storagePools` takes the list's, and a listed node
  with no instance yet is returned with `address: <name>.<mgmt domain>` — so every reader works
  on an unmigrated config, and nothing writes the old list.

Bash, `lib/cluster-nodes.sh` (side-effect free, re-exported by `common-install-routines.sh`
the way `module-catalog-lib.sh` is, and sourced directly by the scripts that do not load the
routines): `tappaas_cluster_nodes` (names, one per line, the same order and window rules) and
`tappaas_cluster_nodes_json` (`[{name, address, storagePools}]`). `test-config-readers.sh`
covers both. Python (`update-tappaas`) has one function of the same rules.

Who is a member of the site's cluster, when site.json no longer says: a Proxmox node whose own
`pvesh get /cluster/status` names a cluster that lists another registered pvehost instance, or,
before any is registered (the install's first node), a cluster named after the site
(`pvecm create <site-code>`; hrossen's is `rossen`). One bash function, `pn_cluster_member`,
used by `adopt-module.sh` and the pvehost `install.sh`/`test.sh`.

## The install flow

Today: `create-site.sh` discovers the cluster and writes `hardware.nodes[]` with each node's
pools; the cluster update's Step 7 then adopts every node with no config (`adopt-module.sh`,
refused unless site.json lists it). After:

1. `create-site.sh` writes no hardware block. Its discovery keeps the primary node (for the
   email, country, keyboard and timezone it reads from it), found from the helper or the
   `--primary-node` flag, else `tappaas1`.
2. The cluster update's Step 7 adopts each live member with no config, unchanged; adoption of a
   Proxmox node checks membership as above, and records its `tankXY` zpools as `storagePools`
   (an explicit `--set storagePools=…` wins).
3. Step 6 (storage reconcile) reads the pools from the instances. On a fresh install it runs
   before Step 7 registers the nodes: the window rule does not apply (no `hardware`), so it
   has nothing to add yet, and the next update converges — as `config-storage.sh` already
   listed the nodes at pool creation, nothing is missing.

`site-manager node add` (join): the pvehost record is written first — `registerNode`
(adoption, with the `--storage-pools` given or the discovered ones) runs before the storage
registration, which reads the pools from the record — where today `node reconcile` writes
site.json first. `node add --config-only` writes the record without contacting the machine
(`copy-update-json.sh pvehost --instance N --address N.mgmt.internal --zone0 mgmt
--storagePools [...]`, no install). `node delete` is `module-manager delete <n> --archive`
after the cluster side, as today minus the site.json edit.

## Readers and writers

✱ = writes. Each row: today → after.

### site-manager

| where | today | after |
|---|---|---|
| `src/types.ts` `SiteNode`, `Site.hardware` | the list's shape | `Site` loses `hardware`; nodes are `ClusterNode` from lib/ts |
| `src/config.ts` `loadSite` | parses `hardware.nodes` | not read; a leftover is kept raw (validate refuses it) |
| ✱ `src/client.ts` `addNode`, `setNodePools` | append to / fill `hardware.nodes` | `registerNode` (adopt-module.sh) and `setNodeStoragePools` on the instance |
| ✱ `src/main.ts` `node add --config-only` | append to the list | write the pvehost record (`--storage-pools a,b`; `--pool` kept as the old spelling) |
| `src/main.ts` `node list [--json]` | the list | `clusterNodes()`: name, pools, address, location |
| ✱ `src/main.ts` `node delete` | drop from list + archive module | archive module only |
| `src/main.ts` `node reboot` | refuses a name not in the list | refuses a name that is no pvehost instance |
| `src/main.ts` `site show` (Nodes line) | the list | the helper |
| `src/main.ts` validate | — | `nodeErrors()` refuses `hardware` |
| `src/provision.ts` join capture | `node reconcile --apply`, then reads pools from site.json, then registers | registers (writes the record with pools) first, then reads the pools through the helper |
| ✱ `src/reconcile.ts` nodes slice | live member missing → append to list; known with `[]` → fill from discovery; listed but gone → reported | missing → register (adopt-module.sh, records pools); instance with `[]` → fill (`setNodeStoragePools`); instance whose node left → reported |
| ✱ `create-site.sh` | builds `hardware.nodes[]` | no hardware block; `--force` drops a leftover only through migration 0022, never itself |
| `test.sh`, `test-create-site.sh`, unit tests | fixtures with `hardware` | fixtures with pvehost instances; create-site asserts no `hardware` |

### module-manager

| where | today | after |
|---|---|---|
| `adopt-module.sh` | a Proxmox node must be in `hardware.nodes` | `pn_cluster_member` (its own cluster status); records `storagePools` from `zpool list` |
| `src/config.ts`, `src/client.ts` node hostnames | site.json list, else tappaas1..9 scan | the helper, else the scan |
| `src/inspect.ts`, `src/reconcile.ts` | via config.ts | unchanged (via config.ts) |
| `scripts/test/test-adopt.sh` | site.json fixture | cluster-status fixture for `pn_cluster_member` |

### the other managers and the console

| where | today | after |
|---|---|---|
| storage-manager `src/inventory.ts` `siteNodes(site)` (sources: site.json) | pools declared per node, "not in site.json's storagePools" | `nodes` source from the helper; the finding says "not in the node's storagePools" |
| health-manager `src/config.ts`/`client.ts` node hostnames, `checks.ts` default node/HA | site.json list | the helper |
| backup-manager `src/main.ts` (is the host a cluster node) | site.json list | the helper |
| network-manager `src/topology.ts` (`site-manager node list --json`, fallback the site list) | the list | the same `node list --json` (now the helper), fallback the helper; nodes keep `storagePools` |
| network-manager `src/distribute.ts` `enumerateNodes` | site.json list, else configuration.json | the helper, else configuration.json |
| ui `src/setup.ts` (Nodes step: declared vs joined) | `site.hardware.nodes` | the helper |
| ui `src/reads.ts` (node lists for forms, node progress) | `site show --json` `nodes`, `node list --json` | unchanged calls; their output now comes from the helper |
| ui `web` Site page note, AddNode | "hardware.nodes" wording | "the nodes (their pvehost records)" |

### bash and python readers

| where | today | after |
|---|---|---|
| `lib/common-install-routines.sh` `get_node_hostname`, `get_all_node_hostnames`, `vm_node_holding` | `.hardware.nodes` | `tappaas_cluster_nodes` |
| `cluster/reconcile-storage-nodes.sh` | pools per node from site.json | `tappaas_cluster_nodes_json` |
| `cluster/test.sh` (storage drift deep test) | pools from site.json | `tappaas_cluster_nodes_json` |
| `pvehost/lib/pvehost-lib.sh` `pn_site_member`, `install.sh`, `test.sh` | site.json list | `pn_cluster_member` |
| `backup/lib/pbs-pulse.sh` (is the host a node) | site.json list | the host's own record is a pvehost instance |
| `backup/test.sh`, `storage/test.sh`, `storage/lib/test-nfs-deep.sh` | site.json list | `tappaas_cluster_nodes` |
| `scripts/site-notify.sh` | site.json list | `tappaas_cluster_nodes` (sources `cluster-nodes.sh`) |
| `update-tappaas` `cluster_vmids`, Phase 0.5 comment | site.json list | the pvehost instances |
| test fixtures that carry `hardware` only to name nodes (environment-manager, backup-manager, test-variants, node-provisioner, health-manager units) | `hardware.nodes` | a pvehost instance, or nothing where the test never reads it |
| comments (logging/update.sh, network/test.sh, node-provisioner registry) | "site.json hardware.nodes" | "the pvehost instances" |

## Migration 0022

`migrations/0022-nodes-are-pvehost-instances.sh [--check]`, after 0021:

1. No `site.json`, or no `hardware` in it: nothing to do (idempotent).
2. For each `hardware.nodes[]` entry: `config/<name>.json` must exist and be a pvehost
   instance; otherwise refuse, changing nothing, naming each such node and how to register it
   (`module-manager module adopt <name>.mgmt.internal`, or `site-manager node delete <name>
   --config-only` for a node that is gone).
3. Each entry's `storagePools` is written to its instance when the instance has none; an
   instance that already has a list keeps it (it is the record), and a difference is reported.
4. `hardware` is removed from `site.json`. Backups of `site.json` and the touched instances in
   `.migrations/backup/0022/`; `--check` says what it would do.

Fixture test `scripts/test/test-migration-0022-nodes.sh`: a copy of hrossen's config (three
nodes, three instances) → pools moved, `hardware` gone, second run a no-op; a copy with a node
lacking its instance → refused, nothing changed.

## Order of the work

1. this survey; 2. the field and the helper (TS + bash); 3. site-manager; 4. every other reader;
5. migration 0022; 6. docs (ADR-036, DATAMODEL, READMEs, install docs).
