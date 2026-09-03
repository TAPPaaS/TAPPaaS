# Update policy — `identity:identity`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:** [the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

1 field — `in-place`, `apply: "reconcile"`.

| Field | Why this class |
|---|---|
| `identity` | The whole SSO block. Issued sessions keep working. *See [recommendation 5](../../../tappaas-cicd/UPDATE-POLICY.md#5-break-up-identityidentity).* |

## One field carrying a whole subsystem

`identity` is a single object holding the module's entire SSO configuration —
client id, redirect URIs, group mappings, the lot. Changing any part of it is one
drift record on one field, so the converge cannot say *what* changed and an
operator cannot `--set` one piece without restating the whole object.

It is `in-place` because the reconcile rewrites the OIDC client at the provider
and reloads; sessions already issued keep working until they expire.
Recommendation 5 proposes breaking the object into declared sub-fields so drift
is legible.
