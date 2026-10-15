# cluster:ha service

Places a module's guest under **Proxmox HA** and keeps its node-affinity and
replication in line with the module's declaration. Most of what it repairs has no
module field behind it — an absent HA resource, a missing rule, a guest on the
wrong node — which is why it owns only a few declared fields but does considerably
more than that.

## Why this service owns so few fields

Most of what `cluster:ha` repairs has **no module field behind it** — the HA
resource absent, the affinity rule missing, the guest running on the wrong node.
None of those can be expressed in a field-keyed drift record, because there is no
field whose declared value disagrees with reality. The reconcile finds and fixes
them anyway; the manifest only covers the two things an operator actually
*declares*.

`HANode` is also where guest **placement** is decided for an HA module.
[`cluster:vm node`](../vm/README.md) explicitly refuses to migrate an HA
guest and defers to this service — see
[`node` and `HANode` today](../../../tappaas-cicd/UPDATE-POLICY.md#7-node-and-hanode--what-happens-today-adr-019s-starting-point).

## Only its node and its `HANode`

The node-affinity rule is **strict**: the guest runs on its `node` (preferred)
or its `HANode`, and nowhere else. When both are down it stays stopped rather
than starting on a node that may not carry it — the firewall on a node without
a WAN port, a guest on a node without its storage or bridges. A rule found
without strict is made strict by the next update.

## The CPU an HA guest runs (`haCpu`)

An HA guest moves between its node and its `HANode`, and a move is only safe
live when the second node runs every instruction the guest may be using. Nodes
with different CPUs do not, so `haCpu` decides how the guest meets that:

| `haCpu` | CPU model (`cputype`) | Moves between unlike CPUs |
|---|---|---|
| `common` (default) | the richest x86-64 level both nodes offer; `host` when both offer the same features | live — every move is safe |
| `host` | the node's own CPU, all of it | stop and start: HA failback off, node reboots relocate the guest and bring it back |

`cluster:ha` decides the model and `cluster:vm` applies it: after writing a
changed `cputype` into the config, `cluster:ha` runs the `cluster:vm` converge
itself, so the order the two services run in does not matter.

The levels come from the cluster's CPU inventory (`config/cluster-cpu.md`,
written by the cluster update). When the pair runs a guest below what its
primary node offers, the update says so and names the nodes that would keep
it — or `haCpu: host`. A changed CPU model takes effect when the guest
restarts: `module-manager module update <module> --allow-disruption`, or
`rebootOk` in the scheduled pass. Until then a node reboot will not drain
the guest's node live (it is reported `DEFERRED`).

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`cluster:ha` owns **3** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `HANode`

Secondary node for High Availability. Defaults to the first node in configuration.json that differs from 'node'. Must be different from 'node' and have the same storage defined. HA is only active when 'cluster:ha' is in dependsOn.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | *(none)* |
| Used by | `cluster:ha` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** The failover node. Changing it re-points the node-affinity rule and recreates the ZFS replication job against the new target — which means a full initial re-sync, so it is IO-heavy and can take a long time. It is still in-place: the running guest is not moved, not rebooted, and stays served throughout. The move that DOES relocate a guest is cluster:vm's `node`, which defers to this service for an HA module.

### `replicationSchedule`

Cron-style schedule for HA replication interval

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `*/15` |
| Example | `*/15` |
| Required by | *(none)* |
| Used by | `cluster:ha` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Default is every 15 minutes

**Why this change class.** How often the guest's disk is replicated to the failover node — the bound on how much is lost if the primary dies. A `pvesr update`: it changes when the next run happens, nothing else.

### `haCpu`

The CPU model the HA guest runs. 'common': the richest x86-64 level its node and HANode both offer (config/cluster-cpu.json) — 'host' when both offer the same features — so every move between them is live-safe; a newer CPU's extra instructions (AVX-512 …) are not used. 'host': the full CPU of the node it starts on; then a move between nodes with different CPUs is a stop and start (HA failback off, node drains relocate it), never a live migration.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `common` |
| Allowed values | `common` — Live-safe moves; the instructions both nodes share<br>`host` — The node's full CPU; moves between unlike CPUs stop and start the guest |
| Example | `host` |
| Required by | *(none)* |
| Used by | `cluster:ha` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** Sets the module's cputype (common: the shared level; host: host) and the HA resource's failback. The new CPU model takes effect when the guest restarts — held until a restart is authorized, like any held hardware change.

<!-- END GENERATED FIELDS -->
