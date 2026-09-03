# Update policy — `network:dns`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:** [the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

1 field — `in-place`, `apply: "reconcile"`.

| Field | Why this class |
|---|---|
| `ip` | A resolver update. Absent means the module resolves from its DHCP lease via masqdns. |

Absence is meaningful here rather than merely undeclared: a module with no `ip`
is not misconfigured, it has chosen the DHCP + masqdns path. This is why the
field is reconciled and not `set` — "no static record" is a state the reconcile
can reach, and a scalar diff against an empty desired value could not.

A NIC change on the guest side is what usually moves this: see `mac0` in
[`cluster:vm`](../../../cluster/services/vm/UPDATE-POLICY.md), classed
`in-place-reboot` precisely because a new MAC means a new lease and DNS has to
follow.
