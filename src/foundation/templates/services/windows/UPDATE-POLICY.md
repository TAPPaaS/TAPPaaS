# Update policy — `templates:windows`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:** [the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

1 field — `in-place`, `apply: "reconcile"`.

| Field | Why this class |
|---|---|
| `windows` | Affects guests provisioned afterwards; an existing guest is not rebuilt. |

## Why changing it is free

This is template-time configuration: answer-file content, driver injection, the
image the next Windows guest is built from. Changing it costs nothing on any
running guest, because it is never re-applied to one — it is read the next time a
guest is provisioned. That makes it `in-place` in the strictest sense: the
converge writes it and no workload is touched.
