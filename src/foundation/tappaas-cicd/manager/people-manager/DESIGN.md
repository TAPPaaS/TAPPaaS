# people-manager — design notes

## Language and build

- **CLI engine:** TypeScript (`src/*.ts`), compiled with `tsc` and **no
  `node_modules`** — Node's runtime types come from the shared ambient
  `../../lib/ts/src/env.d.ts`, and the CLI/help/config/exec plumbing is
  imported from `../../lib/ts/src/` (no vendored copies).
- **Build mechanism:** `install.sh` runs a Nix build (`nix-build -A default
  default.nix`; a thin import of the shared `../../lib/nix/ts-manager.nix`
  builder) which compiles the TypeScript and wraps it with `makeWrapper`
  into `result/bin/people-manager` (a shell wrapper invoking
  `node .../lib/manager/people-manager/src/main.js` on Node 22). It then
  `ln -sfn`s that into `~/bin`.
- **`update.sh`** re-runs the same build + link (idempotent; a no-op when inputs
  are unchanged).
- One bash helper is linked alongside the compiled bin:
  - `validate.sh` → `~/bin/validate-people.sh` — JSON-Schema + reference
    validation in bash. A `people-manager validate` subcommand also exists
    (see "Validation" below for how the two overlap).
  - (`user-setup.sh` is retired — ADR-007 refactor Phase 8.2; its logic is the
    native `people-manager bootstrap` verb, `src/bootstrap.ts`. `install.sh`
    removes the stale `~/bin/user-setup.sh` link from older installs.)

## Internal structure

```
src/main.ts        CLI: arg parsing + subcommand dispatch
src/bootstrap.ts   `bootstrap` — seed config/people from minimal-org/ (the retired user-setup.sh)
src/config.ts      load config/people/* (per-kind decoders); reference-integrity checks (validateRefs)
src/entity.ts      entity CRUD (add/modify/delete) — validated atomic config writes
src/queries.ts     pure relationship queries for the --deep list views
src/types.ts       Role / Org / Group / User models + the PrimitiveClient interface
src/reconcile.ts   snapshot-and-plan reconcile engine (compute plan, then apply)
src/primitives.ts  CliPrimitiveClient — talks to the identity controller
```

### Entity CRUD

`src/entity.ts` implements `add` / `modify` / `delete` for the four kinds
(`role`, `org`, `group`, `user`). These are the ADR-007 #5 verbs — admins drive
the config through them and never hand-edit JSON. Key properties:

- **The write itself is config-only**, producing a validated JSON file under
  `config/people/<dir>/<name>.json`. The *push* is `main.ts`'s job: since issue
  #482 every successful write is followed by a reconcile, so an operator's change
  is live when the command returns. `--no-reconcile` stages the write instead.
  Keeping the two separable is what lets a rejected edit never reach Authentik,
  and lets `entity.ts` stay testable without a client.
- **Validated before write.** The op loads the on-disk model, merges the
  candidate entity (or removes it, for delete), runs the same `validateRefs`
  integrity gate `reconcile` uses, and refuses on any error. So a write can never
  leave the tree referentially broken.
- **Atomic.** Writes go to a temp file in the target dir and are `rename`d into
  place (`atomicWrite`), so a rejected/interrupted write leaves no partial file.
- **`add` guards on existence** (refuses an existing entity unless `--force`).
- **`delete` guards on inbound references** (`referencesTo`): refuses while
  another entity still points at it (role used by a group/user, org used as
  `ownerOrg`/`owner`/`parentOrg`, group still in a user's `memberOf`) unless
  `--force`.
- **List fields** (`group.roles`, `user.roles`, `user.memberOf`) support a
  whole-list replace (`--roles "a,b"`) and incremental `--add-<f>` / `--remove-<f>`
  (set semantics: adds dedupe). User flag aliases: `--email`→`primaryEmail`,
  `--groups`→`memberOf`.

The reconcile engine is built around a `PrimitiveClient` interface, so the
planning logic is decoupled from the live identity service. Tests inject an
in-memory fake (`test/unit/fake-client.ts`); production uses `CliPrimitiveClient`.

### Reconcile semantics

- **Snapshot-and-plan:** fetch the identity service's current users/groups/roles
  once, compute the desired state from `config/people/`, diff, then apply the
  plan action-by-action.
- **Entity existence is additive:** roles/groups are created if missing; they are
  never implicitly deleted. Attribute drift is a warning, not an action.
- **Access is authoritative within the managed set:** managed group/role links
  are added or removed to match config, but entities not present in
  `config/people/` are never touched (foreign-entity scope guard).
- **Lifecycle:** `planned` users get no identity presence; `active` are present
  with full access; `suspended` are disabled and stripped of managed roles;
  `terminated` are deleted (the only governed deletion).
- **Deletion is pushed separately (#482).** The plan is computed from what
  `config/people/` *contains*, so an entity whose file was just deleted is not in
  the managed set at all — the plan cannot see it, and the foreign-entity guard
  would leave it in the identity service forever. `pushEntityDeletion` closes
  that gap: `<kind> delete` removes the entity explicitly (`delete-user` /
  `delete-group` / `delete-role`) *before* the reconcile converges the rest.
  Exceptions: an Organization has no identity-service object, and the groups
  Authentik ships itself (`AUTHENTIK_OWNED_GROUPS` — `authentik Admins`,
  `authentik Read-only`) are dropped from config only. Deleting `authentik
  Admins` would strip the last route into the admin UI (see the identity
  module's DESIGN.md, issue #476).

## How it talks to controllers

The engine does **not** speak the identity service's HTTP API directly. It shells
out (via `spawnSync`) to the identity controller's CLI, `authentik-manager`
(which must be on `PATH`; override with `AUTHENTIK_MANAGER_BIN`). It calls
read primitives (`list-users`, `list-groups`, `list-roles`) and, when
applying, mutating primitives (`ensure-user`, `disable-user`, `delete-user`,
`ensure-group`, `ensure-role`, `delete-group`, `delete-role`,
`add-member` / `remove-member`, `assign-role` / `unassign-role`). This keeps people-manager (config owner) and the
identity controller (runtime owner) cleanly separated.

## Validation

Two overlapping paths exist:

- **`people-manager validate`** (the ADR-007 verb, implemented — `cmdValidate`
  in `src/main.ts`): loads `config/people/` and runs the in-process
  `validateRefs` reference-integrity gate (the same gate `reconcile` and the
  entity CRUD use). It does **reference checks only** — no JSON-Schema
  validation.
- **`validate.sh`** (linked as `validate-people.sh`): validates each file
  against its JSON Schema (draft 2020-12) using Python `jsonschema` when
  available, with a `jq` required-field fallback, plus `jq`-based
  reference-integrity checks (`group.ownerOrg`, `user.memberOf`, user/group
  `roles`, `org.owner`/`parentOrg`). It remains the schema-validation path
  (and what `test.sh` and the P10 `validate.sh` contract exercise) until the
  TS verb grows schema checks.

## Testing

`test.sh` has three tiers:

- **Fast (default):** offline bash validation tests against fixtures and the
  `minimal-org/` templates, **plus** the TypeScript unit tests (compiled with
  `tsc`, run with the in-memory fake client). No identity service, no cluster.
- **Deep (`TAPPAAS_TEST_DEEP=1`):** a live, identity-mutating integration tier
  scoped to `zztest-*` names and self-cleaning. Skipped automatically when
  `people-manager` is not on `PATH` or the identity controller is unreachable.

## Pending / not yet implemented

- **Verb naming (ADR-007 alignment).** Done: the reconcile verb is **`reconcile`**
  (`sync` kept as a deprecated alias); per-entity CRUD is **`add` / `modify` /
  `delete`** and the read verb is **`show`** (`get` kept as a deprecated alias).
- **Credential delivery on user creation** is deferred (a one-time enrollment
  link once SMTP is configured, otherwise a generated password) — see the note in
  `user.sh`.
- **Per-module admin groups** (`<scope>-<module>-admins`) are created on demand at
  module-install time, not by this manager.
- **Install-time wiring** of the initial identity install is DONE:
  `rest-of-foundation.sh` (fresh install) and `migrate-to-adr007.sh` (upgrade)
  run `people-manager bootstrap` then `reconcile --apply`, guarded to fire only
  when `config/people/` is empty.
