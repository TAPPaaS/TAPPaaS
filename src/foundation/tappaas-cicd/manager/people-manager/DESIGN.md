# people-manager — design notes

## Language and build

- **CLI engine:** TypeScript (`src/*.ts`), compiled with `tsc` and **no
  `node_modules`** — Node's runtime types come from an ambient `src/env.d.ts`.
- **Build mechanism:** `install.sh` runs a Nix build (`nix-build -A default
  default.nix`) which compiles the TypeScript and wraps it with `makeWrapper`
  into `result/bin/people-manager` (a shell wrapper invoking
  `node .../lib/main.js` on Node 22). It then `ln -sfn`s that into `~/bin`.
- **`update.sh`** re-runs the same build + link (idempotent; a no-op when inputs
  are unchanged).
- Two bash helpers are linked alongside the compiled bin:
  - `user-setup.sh` → `~/bin/user-setup.sh`
  - `validate.sh` → `~/bin/validate-people.sh`

## Internal structure

```
src/main.ts        CLI: arg parsing + subcommand dispatch
src/config.ts      load config/people/*; reference-integrity checks (validateRefs)
src/types.ts       Role / Org / Group / User models + the PrimitiveClient interface
src/reconcile.ts   snapshot-and-plan reconcile engine (compute plan, then apply)
src/primitives.ts  CliPrimitiveClient — talks to the identity controller
```

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

## How it talks to controllers

The engine does **not** speak the identity service's HTTP API directly. It shells
out (via `spawnSync`) to the identity controller's CLI, `authentik-manager`
(which must be on `PATH`; override with `AUTHENTIK_MANAGER_BIN`). It calls
read primitives (`list-users`, `list-groups`, `list-roles`, `get-user`) and, when
applying, mutating primitives (`ensure-user`, `disable-user`, `delete-user`,
`ensure-group`, `ensure-role`, `add-member` / `remove-member`,
`assign-role` / `unassign-role`). This keeps people-manager (config owner) and the
identity controller (runtime owner) cleanly separated.

## Validation

`validate.sh` (linked as `validate-people.sh`) validates each file against its
JSON Schema (draft 2020-12) using Python `jsonschema` when available, with a `jq`
required-field fallback, plus `jq`-based reference-integrity checks
(`group.ownerOrg`, `user.memberOf`, user/group `roles`, `org.owner`/`parentOrg`).

## Testing

`test.sh` has three tiers:

- **Fast (default):** offline bash validation tests against fixtures and the
  `minimal-org/` templates, **plus** the TypeScript unit tests (compiled with
  `tsc`, run with the in-memory fake client). No identity service, no cluster.
- **Deep (`TAPPAAS_TEST_DEEP=1`):** a live, identity-mutating integration tier
  scoped to `zztest-*` names and self-cleaning. Skipped automatically when
  `people-manager` is not on `PATH` or the identity controller is unreachable.

## Pending / not yet implemented

- **Entity CRUD over the CLI.** `role|org|group|user create|update|delete` are
  deliberately not implemented in this build — `src/main.ts` dies with
  `"<kind> <sub>: not implemented in this build (use 'list' or 'get')"`. Editing
  the JSON files plus `sync` is the current workflow.
- **Credential delivery on user creation** is deferred (a one-time enrollment
  link once SMTP is configured, otherwise a generated password) — see the note in
  `user.sh`.
- **Per-module admin groups** (`<scope>-<module>-admins`) are created on demand at
  module-install time, not by this manager.
- **Install-time wiring** of the initial identity install (run `user-setup.sh`
  then `sync`, guarded to fire only when `config/people/` is empty) is a planned
  integration point.
