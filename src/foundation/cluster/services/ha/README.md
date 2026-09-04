# cluster:ha service

Places a module's guest under **Proxmox HA** and keeps its node-affinity and
replication in line with the module's declaration. Most of what it repairs has no
module field behind it — an absent HA resource, a missing rule, a guest on the
wrong node — which is why it owns only two declared fields but does considerably
more than two things.

## Why this service owns only two fields

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

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`cluster:ha` owns **2** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

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

<!-- END GENERATED FIELDS -->
