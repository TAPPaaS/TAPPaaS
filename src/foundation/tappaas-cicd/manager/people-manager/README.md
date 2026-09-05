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
org, the `users` and `authentik Admins` groups, and 2 users: `root` + the
installer) with `__ORG__` / `__USER__` / `__EMAIL__` / `__ROOT_EMAIL__`
placeholders, seeded by `people-manager bootstrap`.

`authentik Admins` is **Authentik's own built-in superuser group**, adopted by
name rather than invented (issue #476). Membership in an `is_superuser` group is
the only thing that grants the Authentik admin UI — the `admin`/`root` *roles*
are labels TAPPaaS passes to apps and confer nothing there. The installer (= the
site / default-environment owner) is a member, so day-2 user administration does
not need the `akadmin` break-glass login; `root` is deliberately not.

## Commands

This manager exposes one compiled CLI (`people-manager`) plus one bash helper
(`validate-people.sh`).

### `people-manager` — bootstrap, read, CRUD + reconcile

```
people-manager bootstrap --org O --user U --email E [--minimal-org DIR] [--force] [--skip-validate] [--config-dir DIR]
people-manager reconcile  [--apply]  [--config-dir DIR]   (alias: sync, deprecated)
people-manager validate                            [--config-dir DIR]
people-manager <kind> list   [--json] [--deep]     [--config-dir DIR]
people-manager <kind> show   <name> [--json]       [--config-dir DIR]   (alias: get, deprecated)
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

- `--apply` — on `reconcile`, push the plan to the identity service. **Without it,
  `reconcile` only PREVIEWS the plan** (the default) — matching `site-manager`,
  `network-manager`, etc. (`--dry-run` is a deprecated no-op: preview is already
  the default.)
- `--json` — on `list` / `show`, emit structured JSON (default is human-readable).
- `--deep` — on `org` / `group` `list`, recurse into groups + user membership.
- `--force` — on `add`, overwrite an existing entity; on `delete`, ignore the
  reference guard.
- `--config-dir DIR` — the People directory to read/write (default
  `$TAPPAAS_CONFIG/people`).

#### Write-and-push workflow

`add` / `modify` / `delete` write the validated JSON under
`config/people/<dir>/<name>.json` **and then push it to the identity service**
(issue #482) — a change is live when the command returns, with no second command
to remember. Admins thus drive everything through verbs and never hand-edit JSON
— see `docs/design/ADR-007-verb-alignment.md` ("admins drive verbs, not JSON").

```
people-manager <kind> add|modify|delete ...                  # write + push
people-manager <kind> add|modify|delete ... --no-reconcile   # write only (stage)
people-manager reconcile [--apply]                            # preview / push
```

Order of operations, and why it is that order:

1. **Validate, then write.** Each write is gated by the same `validateRefs`
   integrity check `reconcile` runs (an unknown role/org reference, a dangling
   `memberOf`, etc. is rejected and *no* file is written), and is atomic
   (`mktemp` + `rename`). A rejected edit therefore never reaches the identity
   service.
2. **`delete` pushes the removal explicitly** *before* reconciling. `reconcile`
   is driven by what config **contains**, so an entity whose file was just
   removed is invisible to the plan — without this step it would live on in
   Authentik forever. Users, groups and roles are removed; an Organization has no
   Authentik object, so there is nothing to push. Groups Authentik ships itself
   (`authentik Admins`, `authentik Read-only`) are dropped from config only,
   never deleted from Authentik.
3. **Then a full reconcile**, not just this entity's actions: `config/people` is
   the desired state, so the moment we are already talking to the identity
   service is the right moment to converge all of it.

If the push fails (identity service down, a rejected action), the command exits
non-zero and says so — **the config write stays on disk**. The fix is to re-run
`people-manager reconcile --apply`, not to redo the edit.

`--no-reconcile` keeps the old config-only behaviour, for staging several edits
into one push or for editing while the identity service is down.

#### Field flags

| Kind | Scalar flags | List flags (support `--add-<f>` / `--remove-<f>`) |
|------|--------------|----------------------------------------------------|
| `role`  | `--displayName`, `--description` | — |
| `org`   | `--displayName`, `--type`, `--owner` (a user), `--parentOrg` (an org) | — |
| `group` | `--displayName`, `--type`, `--ownerOrg` (an org) | `--roles` |
| `user`  | `--displayName`, `--email` (→ `primaryEmail`), `--state` (`planned`/`active`/`suspended`/`terminated`) | `--roles`, `--groups` (→ `memberOf`) |

List flags accept a comma-separated value to **replace** the whole list
(`--roles "admin,user"`), or `--add-<field>` / `--remove-<field>` (repeatable) to
incrementally add/remove a member (set semantics — adds dedupe). Only the comma
separates: a `Group.name` may contain internal spaces so that an Authentik-created
group can be named, so `--add-groups "authentik Admins"` is one member, not two.

Examples:

```bash
people-manager user list
people-manager org show foo-company
people-manager role add editor --displayName "Editor"
people-manager user add jan --email jan@foo.nl --roles user --groups foo__users
people-manager user modify jan --add-roles admin --remove-groups foo__users
people-manager group delete foo__users          # refused if any user is a member
people-manager role delete editor --force        # delete despite references
people-manager user add jan --email jan@foo.nl --no-reconcile   # stage, do not push
people-manager reconcile                          # preview the plan (default)
people-manager reconcile --apply                  # apply to the identity service
```

### `people-manager bootstrap` — bootstrap a minimal org

Copies `minimal-org/` into `config/people/`, substituting the placeholders
(`__ORG__` / `__USER__` / `__EMAIL__` / `__ROOT_EMAIL__`) in both filenames and
contents. Pure file bootstrap — makes no identity calls (run
`people-manager reconcile --apply` afterwards). Native TypeScript since the
ADR-007 refactor Phase 8.2 (the former `user-setup.sh` is retired; the flags
are preserved, with `--people-dir` folded into the manager's `--config-dir`).

```
people-manager bootstrap --org <slug> --user <slug> --email <email>
              [--config-dir <path>]    # dest (default $TAPPAAS_CONFIG/people)
              [--minimal-org <path>]   # source templates (default: the
                                       #   component's minimal-org/; env
                                       #   override PM_MINIMAL_ORG_DIR)
              [--force]                # overwrite a non-empty dest
              [--skip-validate]        # skip post-copy validation
```

Refuses a non-empty destination without `--force`, so install-time callers
(`rest-of-foundation.sh`) stay idempotent — they skip
the bootstrap once `config/people/` is populated. The result is validated for
reference integrity (the `people-manager validate` gate); exit 0 = success,
1 = error.

```bash
people-manager bootstrap --org acme --user alice --email alice@example.org
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
