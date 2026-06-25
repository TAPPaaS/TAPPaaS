# people-manager

The **People domain** manager. It owns the Organization → Group → User hierarchy
and the cross-cutting Role labels that back TAPPaaS identity, and it reconciles
that desired config onto the identity service (Authentik) via the identity
controller.

## What it owns

Config state lives under `config/people/` (default
`${TAPPAAS_CONFIG:-/home/tappaas/config}/people/`), one JSON file per entity:

```
config/people/
  roles/*.json          # cross-cutting role labels
  organizations/*.json  # tenant / company / family
  groups/*.json         # teams, departments, access-sets (carry roles)
  users/*.json          # people, with memberOf groups + roles + lifecycle state
```

Each file is validated against a JSON Schema (`role-fields.json`,
`organization-fields.json`, `group-fields.json`, `user-fields.json`) plus
cross-reference integrity (e.g. a user's `memberOf` groups must exist, an org's
`owner` must be a known user). User lifecycle `state` is one of `planned` (no
identity presence), `active` (full access), `suspended` (disabled + roles
stripped), `terminated` (deleted).

The repo also ships `minimal-org/` — the canonical bootstrap content (3 roles, 1
org, 2 groups, 1 installer user) with `__ORG__` / `__USER__` / `__EMAIL__`
placeholders.

## Commands

This manager exposes one compiled CLI (`people-manager`) plus two bash helpers
(`user-setup.sh`, `validate-people.sh`).

### `people-manager` — read, CRUD + reconcile

```
people-manager reconcile  [--dry-run] [--config-dir DIR]   (alias: sync, deprecated)
people-manager validate                            [--config-dir DIR]
people-manager <kind> list                         [--config-dir DIR]
people-manager <kind> show   <name>                [--config-dir DIR]   (alias: get, deprecated)
people-manager <kind> add    <name> [field flags]  [--force] [--config-dir DIR]
people-manager <kind> modify <name> [field flags]  [--config-dir DIR]
people-manager <kind> delete <name> [--force]      [--config-dir DIR]
people-manager -h | --help
```

`<kind>` is one of `role`, `org` (alias `organization`), `group`, `user`.

The standardized ADR-007 verb vocabulary applies: `add` (was create), `modify`
(was set/update-entity), `delete` (was remove), `show` (was get), `list`,
`reconcile` (was sync). `get` is kept as a deprecated alias for `show`.

Options:

- `--dry-run` — compute and print the reconcile plan; make **no** changes to the
  identity service.
- `--force` — on `add`, overwrite an existing entity; on `delete`, ignore the
  reference guard.
- `--config-dir DIR` — the People directory to read/write (default
  `$TAPPAAS_CONFIG/people`).

#### Write-then-reconcile workflow

`add` / `modify` / `delete` are **config-only**: they write the validated JSON
under `config/people/<dir>/<name>.json` and **never** call the identity service.
Each write is gated by the same `validateRefs` integrity check `reconcile` runs
(an unknown role/org reference, a dangling `memberOf`, etc. is rejected and *no*
file is written), and is atomic (`mktemp` + `rename`). After a successful write
the command prints a reminder to run `reconcile`. Admins thus drive everything
through verbs and never hand-edit JSON — see `docs/design/ADR-007-verb-alignment.md`
("admins drive verbs, not JSON").

```
people-manager <kind> add|modify|delete ...   # writes validated config
people-manager reconcile                       # then pushes config → identity service
```

#### Field flags

| Kind | Scalar flags | List flags (support `--add-<f>` / `--remove-<f>`) |
|------|--------------|----------------------------------------------------|
| `role`  | `--displayName`, `--description` | — |
| `org`   | `--displayName`, `--type`, `--owner` (a user), `--parentOrg` (an org) | — |
| `group` | `--displayName`, `--type`, `--ownerOrg` (an org) | `--roles` |
| `user`  | `--displayName`, `--email` (→ `primaryEmail`), `--state` (`planned`/`active`/`suspended`/`terminated`) | `--roles`, `--groups` (→ `memberOf`) |

List flags accept a comma/space-separated value to **replace** the whole list
(`--roles "admin,user"`), or `--add-<field>` / `--remove-<field>` (repeatable) to
incrementally add/remove a member (set semantics — adds dedupe).

Examples:

```bash
people-manager user list
people-manager org show foo-company
people-manager role add editor --displayName "Editor"
people-manager user add jan --email jan@foo.nl --roles user --groups foo__users
people-manager user modify jan --add-roles admin --remove-groups foo__users
people-manager group delete foo__users          # refused if any user is a member
people-manager role delete editor --force        # delete despite references
people-manager reconcile --dry-run                # preview the plan
people-manager reconcile                          # apply to the identity service
```

### `user-setup.sh` — bootstrap a minimal org

Copies `minimal-org/` into `config/people/`, substituting the placeholders. Pure
file bootstrap — makes no identity calls.

```
user-setup.sh --org <slug> --user <slug> --email <email>
              [--people-dir <path>]    # dest (default $TAPPAAS_CONFIG/people)
              [--minimal-org <path>]   # source templates (default ./minimal-org)
              [--force]                # overwrite a non-empty dest
              [--skip-validate]        # skip post-copy validation
```

```bash
user-setup.sh --org acme --user alice --email alice@example.org
```

### `people-manager validate` — validate the People config

The manager's `validate` operation is now a native TypeScript verb (ADR-007 #4 —
the convention end-state). It loads `config/people/` and checks reference
integrity (the same `validateRefs` gate `reconcile` runs), report-only — no
identity-service calls. Exit 0 = valid, 1 = reference errors.

```bash
people-manager validate [--config-dir DIR]
```

The bash `validate-people.sh` (a deeper JSON-Schema gate against
`role-fields.json` etc.) remains linked under its project-wide name for
back-compat and schema-level checks:

```
validate-people.sh [DIR] [--schema-dir <path>] [--quiet]
```
