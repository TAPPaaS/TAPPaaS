# ADR-038 — Module-owned fields: a module declares, and the platform validates, its own configuration

| | |
|---|---|
| **Status** | **Proposed** |
| **Version** | 0.1 |
| **Date** | 2026-10-29 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #899 (schemas: module-owned config fields that validate). Raised for @AndreasJe's hosting module; relates to #250 (`dependsOn` ownership for Community modules) and [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) (change classes, `modify --set`). |
| **Changelog** | v0.1 (2026-10-29) — first draft. |

A module may ship a definition of its own configuration fields. They live in the module's
config under one key named after the module, and the platform treats them as it treats its
own: `validate` checks them, `modify --set <module>.<field>=…` changes them with their change
class, and the console shows them.

## Context

**Every field is the platform's.** A module config is checked against the composed field
schema, `~/config/module-fields.json`, which `scripts/compose-fields.sh` builds from three
tiers in the foundation tree: `schemas/module-fields.json` (generic fields),
`<module>/fields.json` (shared by a module's services) and
`<module>/services/<svc>/fields.json` (owned by one service). `lib/ts/src/compose-fields.ts`
is its in-process twin, and a unit test keeps the two in agreement. The tiers cover foundation
modules only, and every field they define is a top-level key in one global namespace.

**A Community module's own settings are unknown fields.** `check_json`
(`lib/common-install-routines.sh`) warns `Unknown field: <key> (not in schema)` and skips the
value. So for a field only the module knows:

- the platform validates nothing: a typo or a wrong type reaches the module's scripts;
- `module modify --set` and `install-module.sh --<field>` refuse it, because the composed schema
  does not declare it;
- the console's field manifest (`ui/src/fieldmanifest.ts`) has nothing to render;
- every module validates its own config in its own code, differently.

The hosting module is the first that needs more: a list of sites (`sites[]` with domain,
runtime, release channel), its own service settings, and per-site options. Today it validates
them against template schemas of its own and core only warns.

**Two constraints shape the answer.**

- **Bash readers.** `check_json` runs in bash with jq, before any manager is built, and in
  scripts that never load node. A module-owned definition must be checkable there.
- **No clash with core.** A module must never be able to define, or redefine, a field the
  platform or another module owns.

## Decision

### D1 — A module ships `<module>-fields.json` next to its module JSON

The file is optional. Its entries use the same field-definition format as the existing tiers
(`schemas/fields-schema.json`): `description`, `type`, `default`, `pattern`, `values`,
`minimum`/`maximum`, `example`, `note`, and the change half, `class` and `changeNote`. Two
additions for structured values:

- `"type": "object"` with `properties` (a map of field definitions) and an optional `required`
  list;
- `"type": "array"` with `items`, which may itself be an object definition (a list of sites).

Nothing else from JSON Schema (`$ref`, `oneOf`, `if/then`, `patternProperties`): the subset is
one every reader can implement in jq and in TypeScript, and test against the same fixtures.
`additionalProperties` is always false: an unknown key inside a module's subtree is an error,
not a warning, because nothing else can own it.

### D2 — The fields live under one key named after the module

```json
{
  "vmname": "hosting",
  "dependsOn": ["cluster:lxc", "network:proxy"],
  "hosting": {
    "defaultRuntime": "php-8.3",
    "sites": [{ "name": "example", "domain": "example.com", "channel": "stable" }]
  }
}
```

- The key is the **module** name (ADR-026 D6.3: `basename(.location)`), not the instance name,
  so every instance of a module shares one definition.
- The composed schema reserves every module name that ships a definition file: a core or
  service field of that name is a composition error, as two tiers defining one field are today.
- A module may define fields only under its own key. It cannot add top-level fields, or change
  the definition of a core or service field.

### D3 — Composition stays global for core, per module for module-owned fields

`compose-fields.sh` and `compose-fields.ts` do not merge module-owned definitions into
`module-fields.json`. A reader that meets a config's own module key loads that module's file
from its source directory (`.location`, the same resolution `module_of` uses), on demand. So:

- the global schema does not grow with every Community module installed;
- a module's definition changes with the module's version, not with a recomposition step (no
  `compose-fields.sh` run needed before `--set` works for a new field);
- a module that is not installed contributes nothing.

Both composers get a `--module <name>` mode that prints one module's definition, normalised.
The agreement test covers it.

### D4 — Every reader uses the definition

| Reader | Today | With a definition |
|---|---|---|
| `check_json` | `Unknown field: hosting` (warning) | validates the subtree (jq); a type, pattern, value or unknown-key error is an error |
| `module-manager validate` | as `check_json` | the same, in TypeScript; findings name the path (`hosting.sites[1].domain`) |
| `module modify --set` | refuses an undeclared field | `--set hosting.defaultRuntime=php-8.4`, `--set 'hosting.sites[example].channel=beta'` (a list element by its `name`), `--unset` likewise |
| `install-module.sh --<field>` | refuses | `--hosting.defaultRuntime php-8.4` |
| drift / change classes | not seen | the field's `class` gates the change (D5) |
| console field manifest | nothing | rendered from the definition, under the module's own section |

A module without a definition file behaves exactly as today: its subtree, if any, is an
unknown field and warns.

### D5 — Change classes for module-owned fields

A module-owned field is applied by the module, not by a platform service: the platform does not
know what changing `defaultRuntime` means. The usable classes are therefore:

- `in-place` — written to config, then the module's own `update.sh` runs (as `module update`
  does), which reads the new value;
- `in-place-reboot` — the same, with the module's restart, under ADR-020 D8's disruption rules
  (`rebootOk`, `--allow-disruption`);
- `immutable` — refused by `modify --set` once installed (an ID, a storage path);
- `manual` — accepted into config and reported, applied by an operator.

`grow-only`, `migrate` and `recreate` describe platform operations on a guest and are refused
in a module's file. The snapshot and rollback around `modify` stay as they are: a failing
`update.sh` rolls the config back.

### D6 — Defaults and the deployed config

A default in a module's definition is desired state, as for core fields (ADR-020 D9): the
module's scripts read the effective value through `module-manager module resolve` (which applies
the definition's defaults) or `get_config_value`, not by reading the file and inventing their own
default. `copy-update-json` keeps the module's subtree like any other deployed field; the
operator's changes to it are protected by `<module>.json.operator` (#488) leaf by leaf.

## Consequences

- A Community module gets first-class configuration with no change to foundation, and drops its
  own validation code (hosting: its template schemas).
- `check_json` gains a small jq validator for the subset, and `validate` a TypeScript one. They
  are a second pair of twins with a shared fixture set; a disagreement fails both test suites.
- `modify --set` learns paths. The parser change is shared by the core fields: a dotted name was
  never valid before, so no existing call changes meaning.
- A module can ship a definition that is wrong. It is validated against `fields-schema.json`
  (extended with D1's two additions) by `module-manager validate --blueprint` at release time
  (ADR-027) and on install, which refuses a module whose definition does not parse.
- The console renders a module's fields without knowing the module; layout hints (grouping,
  order) are out of scope here.

## Alternatives considered

- **Merge module definitions into the global schema** (a fourth tier in `compose-fields`).
  Rejected: the global namespace grows with every installed module, a name clash between two
  Community modules becomes a site-wide composition failure, and a new field needs a recompose
  before `--set` sees it (the trap in `compose-fields.sh` today).
- **Full JSON Schema.** Rejected for now: no jq implementation the bash readers could share, and
  the error messages differ between validators. D1's subset covers what hosting needs; widening
  it later is additive.
- **Module validates, platform only stores.** What exists today. Every module repeats it,
  `modify --set` cannot work, and the console cannot render.
- **Fields under `config."<module>"`** (Pattern A, beside `config."cluster:vm"`). Rejected:
  `config.*` keys are service coordinates (`<provider>:<service>`), and copy-update-json flattens
  them on install. A plain module key needs no special case there.

## Open questions

1. **Secrets in fields.** A module-owned field must never hold a secret (ADR on secrets, #902:
   `/home/tappaas/secrets/<module>/<instance>.env`). Should the definition be able to mark a
   field `secret: true`, so `modify --set` refuses it and points to the escrow instead?
2. **Cross-module references.** Hosting's site may name another module (`"module": "go-campaign"`).
   A `references: "modules"` annotation, as `proxyAllowedZones` has `references: "zones"`, would
   let `validate` check it exists. In scope for v1, or later?
3. **Console layout.** Is the console's existing per-field rendering enough for a list of
   objects (sites), or does it need a table form first?

## Implementation plan

- **P1 — Format and validators.** Extend `fields-schema.json` with D1's object and array forms;
  the jq validator behind `check_json` and the TypeScript one behind `validate`, with shared
  fixtures (valid, each error kind, unknown key, clash with a core name).
- **P2 — Loading.** `compose-fields.sh --module` / `compose-fields.ts`; the reserved-name check in
  composition; definition checked on install and by `--blueprint`.
- **P3 — `modify --set` / `--unset` with paths**, change classes D5, install-time `--<module>.<field>`.
- **P4 — Console.** The field manifest serves a module's definition; the module page renders it.
- **P5 — Hosting adopts it** (with @AndreasJe), dropping its own schemas; documented in the
  module template.

Test: P1–P3 offline in module-manager's and tappaas-cicd's suites; P3 and P4 live on hrossen
with a scratch module that ships a definition (install, invalid `--set` refused, valid one applied
through `update.sh`, rollback on a failing `update.sh`), torn down after.
