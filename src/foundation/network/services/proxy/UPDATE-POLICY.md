# Update policy — `network:proxy`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:**
[the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

9 fields — all `in-place`, all `apply: "reconcile"`.

The module's public face. Nothing here touches a guest: the changes land on Caddy
and the firewall, and the workload never notices.
*The largest drift blind spot — see [recommendation 1](../../../tappaas-cicd/UPDATE-POLICY.md#1-give-networkproxy-a-reporter).*

| Field | Class | Apply | Normalize | Why this class |
|---|---|---|---|---|
| `proxyDomain` | in-place | reconcile | — | Re-issues the certificate and moves the handler; no guest is touched. |
| `proxyPort` | in-place | reconcile | integer | A handler rewrite, applied live. |
| `proxyUpstreamTls` | in-place | reconcile | boolean | Declared a string in the schema; the normalizer makes `"true"` and `true` one value. |
| `proxyUpstreamHttp1` | in-place | reconcile | boolean | For a backend that cannot speak h2c. |
| `proxyPreserveHost` | in-place | reconcile | boolean | For a backend generating absolute URLs. |
| `proxyTls` | in-place | reconcile | — | Per-service vs the environment wildcard. |
| `proxyAllowedZones` | in-place | reconcile | — | Internal service vs exposed to the internet — the field most worth a verb. |
| `firewallType` | in-place | reconcile | — | `NONE` switches to printed instructions — the non-field branch the script keeps. |
| `aliasType` | in-place | reconcile | — | host vs network in the generated alias. |

## Why `reconcile` and not `set`

`update-service.sh` rewrites this module's whole Caddy site block and its OPNsense
alias from the declared values on every pass, then reloads. That is already
idempotent and already handles removal — a handler that should no longer exist is
deleted, which no scalar field diff can express. Flattening it into `set` fields
would lose that. The manifest declares the class, which is what makes `--set`
sanctioned; the apply stays where the domain knowledge is.

Because there is no `report-service.sh`, `module-manager module drift` reports
these fields as `not-reported` rather than comparing them — the converge is
trusted to have made config true. That is the blind spot recommendation 1 closes.
