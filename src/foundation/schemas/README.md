# TAPPaaS configuration schemas

This directory holds the JSON-Schema (draft 2020-12) field definitions for every
**typed configuration object** in TAPPaaS. Each type has:

- a **schema** here in `schemas/` (the field definitions + validation rules),
- a **live location** under `~/config/` on the `tappaas-cicd` mothership (the
  deployed instances), and
- an **owning manager** that performs all create/read/update/delete through
  **verbs**.

> **Admins drive verbs, not JSON** (ADR-007). You never hand-edit these files —
> the owning manager writes validated config and a `reconcile` pushes it to the
> live system. Hand-editing remains *possible* but is only valid when followed by
> the manager's `reconcile`. Every write is schema- + reference-validated first.

`configuration.json` (the old monolith) is **retired** — it was split into
`site.json` + per-environment files + per-module config (this is why there is no
`configuration.md` anymore).

## The configuration objects

| Object | Schema (`schemas/`) | Live location (`~/config/`) | Owning manager — CRUD verbs |
|--------|---------------------|------------------------------|------------------------------|
| **Site** (singleton) | `site-fields.json` | `site.json` | **site-manager** — `site show`/`modify`; `node list`/`add`/`delete`; `repository list`/`add`/`delete`/`reconcile`; `validate`; `reconcile [--deep]` |
| **Environment** | `environment-fields.json` | `environments/<env>.json` | **environment-manager** — `add`/`modify`/`delete`/`list`/`show`/`validate`; `reconcile [--deep]` (env + its zone via network; `--deep` → consuming modules). `--dns-mode per-service\|wildcard` |
| **Organization** | `organization-fields.json` | `people/organizations/<name>.json` | **people-manager** — `org add`/`modify`/`delete`/`list`/`show` |
| **Group** | `group-fields.json` | `people/groups/<name>.json` | **people-manager** — `group add`/`modify`/`delete`/`list`/`show` |
| **Role** | `role-fields.json` | `people/roles/<name>.json` | **people-manager** — `role add`/`modify`/`delete`/`list`/`show` |
| **User** | `user-fields.json` | `people/users/<name>.json` | **people-manager** — `user add`/`modify`/`delete`/`list`/`show`. People-wide: `reconcile` (push → Authentik; alias `sync`), `validate` |
| **Module** (deployed) | `module-fields.json` | `<module>.json` | **module-manager** — `module add`/`modify`/`delete`/`list`/`show`/`validate`/`reconcile`/`test`/`snapshot-vm`. `add`=deploy, `modify`=redeploy, `reconcile`=re-apply current config (leaf) |
| **Module catalog** | `module-catalog-fields.json` | `src/module-catalog.json` (in each repo) | **site-manager** — `repository add`/`delete`/`list`/`reconcile` (registers/clones the repo that ships the catalog) |
| **Zones** | `zones-fields.json` | `zones.json` | **network-manager** — `zone add`/`delete`/`list`/`show`; `validate` (alias `zones-check`); `zones-init`/`zones-merge`/`zones-distribute`; `reconcile [--apply] [--only <plane>]`. (No free-form `zone modify` — state + access-to are governed by the lifecycle + zones-init/merge.) |

### Objects without a schema in this directory

| Object | Live location | Owner / how it's written |
|--------|---------------|--------------------------|
| **Switch / AP topology** | `switch-configuration-{actual,desired}.json` | schema is `network/switch-configuration-schema.json`; **switch-controller** / **ap-controller** (`add-controller`/`add-switch`/`add-port`/`interrogate`/`reconcile`), driven by **network-manager** `reconcile --only switch\|ap`. |
| **TLS cert refids** | `cert-refids.json` | **runtime state** (no schema) — written by `acme-setup.sh`, keyed by environment name. An environment's `domains.dnsMode` (`environment-manager --dns-mode`) selects whether a wildcard cert refid is stored here. |
| **Backup policy** | not a file — the `.backup` block on `site.json` / `environments/<env>.json` / `<module>.json` (cascade: module > env > site) | **backup-manager** — `modify <module>` writes the module `.backup` layer; site/env layers via `site`/`environment modify`. `list`/`show`/`validate`/`reconcile` (resolve cascade → PBS via backup-controller); `restore`. |

## Conventions

- **`validate`** — every config manager exposes a `validate` verb (the schema +
  reference-integrity gate). Writes are validated before they land.
- **`reconcile`** — pushes config → live. Shallow by default; `--deep` cascades
  into dependents (`site → people + network + environments → modules`); `--apply`
  commits (default is preview). Reconcile is idempotent.
- **Managers vs controllers** — *managers* own configuration (these objects) and
  the verb front door; *controllers* (opnsense / proxmox / switch / ap / backup /
  identity) execute against live infrastructure and are driven by their manager.

See `docs/design/ADR-007-verb-alignment.md` for the full verb/CRUD model and the
reconcile cascade.
