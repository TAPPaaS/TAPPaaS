# manager/people-manager

The **People domain** component (ADR-007 P1 / ADR-007a). It owns the
Organization → Group → User hierarchy and the cross-cutting Role labels that
back TAPPaaS identity in Authentik.

See `docs/design/ADR-007-implementation.md` → "P1: People Schema" for the full
design (schema, sync semantics, lifecycle).

## What this component owns

- **Schemas** (in `src/foundation/schemas/`):
  `role-fields.json`, `organization-fields.json`, `group-fields.json`,
  `user-fields.json` — JSON Schema 2020-12 definitions of the People entities.
- **`config/people/`** — the live People data:
  `roles/`, `organizations/`, `groups/`, `users/` (the repo ships example/seed
  files: roles root/admin/user, orgs myOrg/foo-company/bar-company, etc.).
- **`minimal-org/`** — the stored bootstrap default (3 roles, 1 org, 2 groups,
  1 installer user) with `__ORG__` / `__USER__` / `__EMAIL__` placeholders. This
  is the canonical "minimal org" content a fresh install copies; it is *not*
  generated in code.

## Bash entry points (this is a manager → it ships `validate.sh`)

| Script | Linked into `~/bin` as | Purpose |
|--------|------------------------|---------|
| `user-setup.sh` | `user-setup.sh` | Copy `minimal-org/` → `config/people/`, substituting `__ORG__`/`__USER__`/`__EMAIL__` from `--org`/`--user`/`--email`, then validate. Pure bootstrap — no Authentik calls. |
| `validate.sh` | `validate-people.sh` | Validate a People directory against the schemas + reference integrity (group.ownerOrg, user.memberOf, user/group roles, org.owner/parentOrg). Exit non-zero on any violation. |
| `install.sh` | — | Idempotently links the above into `~/bin`. |
| `update.sh` | — | Re-runs `install.sh` (bash component: nothing to rebuild). |
| `test.sh` | — | Self-contained OFFLINE tests (no Authentik, no cluster). |

`validate.sh` uses the project's existing validation mechanism: Python
`jsonschema` (draft 2020-12) for schema conformance when available — with a jq
required-field fallback — plus jq-based reference-integrity checks, exactly like
`site-manager/validate-configuration.sh`.

## Not here yet — arrives in S2b

- **`people-manager.ts`** — the TypeScript CRUD + Authentik **sync** engine
  (`people-manager role|org|group|user list|get|create|update|delete`,
  `people-manager sync [--dry-run]`). Pending the S-TS TypeScript pilot; falls
  back to Python with the same CLI if the pilot does not pass.
- **Wiring into `40-Identity/install.sh`** — the initial identity install will
  call `user-setup.sh … && people-manager sync`, guarded to run only when
  `config/people/` is empty.

This S2a deliverable is the OFFLINE half: schema + config + bootstrap +
validation. No TypeScript and no Authentik sync.
