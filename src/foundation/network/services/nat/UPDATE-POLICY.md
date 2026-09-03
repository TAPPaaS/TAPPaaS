# Update policy — `network:nat`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:** [the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

1 field — `in-place`, `apply: "reconcile"`.

| Field | Class | Apply | Normalize | Why this class |
|---|---|---|---|---|
| `natRules` | in-place | reconcile | — | Connections may reset; no guest reboots. |

Port-forward and redirect rules, reconciled against OPNsense the same way
[`network:rules`](../rules/UPDATE-POLICY.md) reconciles filter rules: the whole
set for this module is re-derived and anything no longer declared is removed.
