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

### `people-manager` — read + sync

```
people-manager sync  [--dry-run] [--config-dir DIR]
people-manager role         list | get [<name>]   [--config-dir DIR]
people-manager organization list | get [<name>]   [--config-dir DIR]   # alias: org
people-manager group        list | get [<name>]   [--config-dir DIR]
people-manager user         list | get [<name>]   [--config-dir DIR]
people-manager -h | --help
```

Options:

- `--dry-run` — compute and print the reconcile plan; make **no** changes to the
  identity service.
- `--config-dir DIR` — the People directory to read (default
  `$TAPPAAS_CONFIG/people`).

`sync` reconciles `config/people/` into the identity service. `list` / `get` are
read-only inspection of the on-disk config. (Entity `create` / `update` / `delete`
are not yet implemented — see DESIGN.md; use `list`/`get` plus editing the JSON
files, then `sync`.)

Examples:

```bash
people-manager user list
people-manager org get foo-company
people-manager sync --dry-run          # preview the plan
people-manager sync                    # apply to the identity service
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

### `validate-people.sh` — validate the People config

(This is the manager's `validate.sh`, linked onto `PATH` under the project-wide
name `validate-people.sh`.)

```
validate-people.sh [DIR]                  # dir to validate (default $TAPPAAS_CONFIG/people)
                   [--schema-dir <path>]  # schema location
                   [--quiet]              # errors/warnings only
```

```bash
validate-people.sh                        # validate the live People dir
```
