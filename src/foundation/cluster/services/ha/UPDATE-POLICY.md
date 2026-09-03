# Update policy — `cluster:ha`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:** [the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

2 fields — all `in-place`, all `apply: "reconcile"`.

| Field | Class | Apply | Normalize | Why this class |
|---|---|---|---|---|
| `HANode` | in-place | reconcile | — | Re-points the affinity rule and recreates the replication job. No downtime — but a full re-sync. *See [the gap in the taxonomy](../../../tappaas-cicd/UPDATE-POLICY.md#6-a-gap-in-the-taxonomy).* |
| `replicationSchedule` | in-place | reconcile | — | A `pvesr update`; changes when the next run happens. |

## Why this service owns only two fields

Most of what `cluster:ha` repairs has **no module field behind it** — the HA
resource absent, the affinity rule missing, the guest running on the wrong node.
None of those can be expressed in a field-keyed drift record, because there is no
field whose declared value disagrees with reality. The reconcile finds and fixes
them anyway; the manifest only covers the two things an operator actually
*declares*.

`HANode` is also where guest **placement** is decided for an HA module.
[`cluster:vm node`](../vm/UPDATE-POLICY.md) explicitly refuses to migrate an HA
guest and defers to this service — see
[`node` and `HANode` today](../../../tappaas-cicd/UPDATE-POLICY.md#7-node-and-hanode--what-happens-today-adr-019s-starting-point).
