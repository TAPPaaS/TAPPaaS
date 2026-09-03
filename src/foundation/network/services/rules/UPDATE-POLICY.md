# Update policy — `network:rules`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:** [the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

4 fields — all `in-place`, all `apply: "reconcile"`.

The module's firewall surface. Every change is a live OPNsense API call;
established connections may reset, but nothing reboots.

| Field | Class | Apply | Normalize | Why this class |
|---|---|---|---|---|
| `ingress` | in-place | reconcile | — | Who may reach the module. A live API call. |
| `egress` | in-place | reconcile | — | What it may reach (ADR-COM-0002). |
| `ports` | in-place | reconcile | — | The declared surface the default rules derive from. |
| `aliases` | in-place | reconcile | — | Named groups; changing one re-points every rule using it. |

## Why `reconcile`

A rule set is reconciled by adding, changing **and removing** rules against
OPNsense's own model. Removing a rule the operator deleted from `ingress` cannot
be expressed as a scalar diff — a generic differ would see "the value changed"
and have nothing to apply. `update-service.sh` re-derives the whole rule set for
this module on every pass and deletes what is no longer declared.
