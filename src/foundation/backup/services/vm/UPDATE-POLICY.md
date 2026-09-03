# Update policy — `backup:vm`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:**
[the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

7 fields — all `in-place`, all `apply: "reconcile"`.

A set operation over the shared PBS job's vmid list, plus a retention cascade
resolved *above* the module.
*See [recommendation 2](../../../tappaas-cicd/UPDATE-POLICY.md#2-split-backupvm--scalars-out-cascade-in).*

| Field | Class | Apply | Normalize | Why this class |
|---|---|---|---|---|
| `backup` | in-place | reconcile | — | The module's layer of the site → environment → module cascade. Future backups only. |
| `alwaysBackup` | in-place | reconcile | — | Set on the backup module: guests that cannot declare the dependency because they bootstrap first. |
| `pbsStorageName` | in-place | reconcile | — | Which datastore the job writes to. |
| `immutableSnapshots` | in-place | reconcile | — | WORM-ish ZFS snapshots, provisioned on the PBS node. |
| `placement` | in-place | reconcile | — | Where backups may live. |
| `placementState` | in-place | reconcile | — | The resolved outcome, recorded on the deployed config. |
| `pushTarget` | in-place | reconcile | — | An off-site datastore (ADR-010). |

## Why every change is `in-place`

None of these can make a running guest unhealthy. Changing retention or placement
governs **future** backups; already-written snapshots are untouched, and a
shortened retention prunes on the next PBS GC, not on the converge. The riskiest
field is `backup` itself going false — the guest keeps running and simply stops
being protected, which is a policy decision, not a disruption.

`placementState` is the odd one: it is the *resolved outcome* of `placement`
written back onto the deployed config, so it is more a report than an input.
Recommendation 2 proposes splitting the plain scalars out to `set` and leaving
only the cascade on `reconcile`.
