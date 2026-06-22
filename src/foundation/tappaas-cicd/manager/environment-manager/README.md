# manager/environment-manager

Owns the **Environment** taxonomy object (ADR-007c / P3): per-tenant deployment
context holding public domain(s), DNS mode, network-zone reference, data
residency, backup retention, and legal processor. Environments live at
`config/environments/<name>.json` on the target system and replace the legacy
`configuration.json` `.tappaas.variants` construct.

## Scripts

- `migrate-variants.sh` (alias `migrate-variants-to-environments.sh`) —
  one-shot migration of `configuration.json` `.tappaas.variants` (+ legacy
  `.tappaas.domain` fallback for the default) into `config/environments/*.json`.
  The `""` (default) variant becomes `default.json`. **Drops `tlsCertRefid`** —
  it is runtime state, not authored config (see ADR-007 "TLS certificate
  handling"). Idempotent (`--force` to overwrite). Does NOT delete
  `configuration.json`.
- `create-minimal-environments.sh` — bootstrap of the two always-required
  environments (`mgmt.json`, `default.json`). Single owner of those two files;
  P6/P7 consume them. Idempotent.
- `validate-environment.sh` (manager verb `validate.sh`) — validates environment
  files against `schemas/environment-fields.json` + reference integrity
  (`network.zone` ∈ zones.json, `ownerOrg` ∈ organizations) and **rejects an
  authored `tlsCertRefid`**.
- `variant-manager.sh`, `migrate-to-variants.sh` — pre-P3 (S0) scripts, left
  as-is during the phased migration.

## Schema

`src/foundation/schemas/environment-fields.json` (JSON Schema 2020-12).
Mandatory: `name`, `displayName`, `ownerOrg`, `network.zone`. `domains` optional
(mgmt omits it); `domains.dnsMode` defaults to `per-service`. `additionalProperties:false`
everywhere — `tlsCertRefid` is not a field and is rejected.

## Testing (FAST / DEEP)

`test.sh` — FAST (default, temp fixtures, non-disruptive): migration shape, the
`tlsCertRefid` drop + schema reject, reference checks, bootstrap, idempotency.
DEEP (`TAPPAAS_TEST_DEEP=1`): additionally read-only-validates live
`config/environments` when present. Fixtures under `test/fixtures/`.
