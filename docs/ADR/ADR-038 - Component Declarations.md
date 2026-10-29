# ADR-038 — Component declarations: validated, per instance, changed under a class, shown in the console

| | |
|---|---|
| **Status** | **Proposed** |
| **Version** | 0.2 |
| **Date** | 2026-10-29 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #899 (configuration a Community module owns, validated by the platform). Amends [ADR-035](<ADR-035 - Pluggable Controllers and Managers.md>) D11 (a controller's or manager's own declarations live in `<name>.json`). Raised for @AndreasJe's hosting module (`hosting-manager`). |
| **Changelog** | v0.2 (2026-10-29) — **reworked (operator):** v0.1 put a module's own fields into the module JSON under a key named after the module. That is what ADR-035 D11 rules out: the module JSON's fields are the platform's, and an application's declarations live in the component's own `<name>.json`. v0.2 keeps D11's file and adds what it left open: one schema format, validation by the platform, a copy per instance, change classes, the console. A module with no component of its own gets the same through its lifecycle scripts (D2). The module JSON, `check_json` and field composition are unchanged. · v0.1 (2026-10-29) — first draft (module-owned fields in the module JSON). |

ADR-035 D11 decided *where* a controller's or manager's own declarations live: in
`<module>/<name>.json`, with the component's `schema.json`, not in the module JSON. This ADR
decides *how the platform handles them*, so every component does not do it its own way: what the
schema may say, who validates the file and when, which copy an instance has, what a change to it
costs, and how the console shows and edits it.

## Context

**D11 names the file and stops there.** Today it says:

- the release's declaration is `<module>/<name>.json` (`litellm-controller.json`);
- its schema is `controller/<name>/schema.json`, checked by `module-manager validate --blueprint`;
- the site's copy is deployed with the module and kept in step with the release by the three-way
  merge (ADR-020), so an operator's change survives an update;
- how far the declaration rules over the application's own UI is decided per controller (O4).

No component uses it yet. Left like that, each one would write its own validator, decide on its
own where the site's copy sits and how an instance gets one, and invent its own verbs to change
it. The console would have nothing generic to render.

**Hosting is the first real case.** @AndreasJe's hosting module has a `hosting-manager`. Its
configuration is a list of sites (domain, runtime, release channel, per-site options) and a few
module-wide settings (the default runtime). Today it validates them against template schemas of
its own, and the platform only warns about keys it does not know. #899 asked for module-owned
fields in the module JSON; ADR-038 v0.1 designed that, and it is withdrawn here (Alternatives):
the module JSON stays the platform's, as D11 says.

**Some modules have settings but no component.** A module whose only code is its lifecycle
scripts (`install.sh`, `update.sh`, ADR-027's basic controller) may still have a handful of
settings of its own. Requiring an extended controller or a manager just to own a file would push
modules into components they do not need.

## Decision

### D1 — One schema format: a JSON Schema subset with change annotations

A declaration's schema is a JSON Schema (draft 2020-12) document using only:

- `type` (`object`, `array`, `string`, `integer`, `number`, `boolean`), `properties`, `required`,
  `items`, `enum`, `const`, `pattern`, `minimum`/`maximum`, `minLength`/`maxLength`,
  `minItems`/`maxItems`, `uniqueItems`, `default`, `description`, `examples`;
- `additionalProperties`, default `false`: a key the schema does not name is an error;
- TAPPaaS annotations, on any property:
  - `changeClass` — `in-place`, `in-place-reboot`, `immutable` or `manual` (D5); inherited by the
    properties below it, default `in-place`;
  - `changeNote` — why that class, as in the field manifests;
  - `key` — on an array of objects, the property that names an element (`"key": "name"` for
    sites), so a change can address `sites[example]`;
  - `references` — `modules`, `zones` or `environments`: the value must name one that exists;
  - `secret: true` is **refused** in a schema: a secret never sits in a declaration. It goes to the
    module's escrow (`/home/tappaas/secrets/<module>/<instance>`, #902) and the declaration names
    it, if anything.

Nothing else (`$ref`, `oneOf`, `if`/`then`, `patternProperties`, formats). The subset is what
`ui/src/fieldmanifest.ts` already flattens for the environment and zone schemas, and what one
validator can implement exactly; widening it later is additive.

### D2 — Who owns a declaration: a component, or the module itself

- An **extended controller or a manager** (ADR-035 D1) that takes declarations has them as D11
  says: `<module>/<name>.json` and `controller/<name>/schema.json` (or `manager/<name>/schema.json`).
- A **module without such a component** may have one declaration of its own, owned by its
  lifecycle scripts: `<module>/declarations.json` and `<module>/declarations.schema.json`. Its
  name in the verbs below is the module's name.

Either way it is the same mechanism. A module never puts its own settings in the module JSON.

### D3 — Every instance has its own copy, in `config/declarations/`

- The site's copy of instance `<i>`'s declaration `<name>` is
  `config/declarations/<i>/<name>.json`, beside the instance's `config/<i>.json` (ADR-026 D6.1).
  A subdirectory, so module discovery, which reads `config/*.json`, never takes it for an instance.
- **Install** seeds it from the release's file, then validates it (D4).
- **Update** merges the release's file into it with the module config's three-way merge
  (`apply-json-merge`, with `.orig` and the operator's leaf set in `.operator`, #488), then
  validates.
- **`module delete --archive`** keeps the directory with the config; **`--remove`** deletes it.
- It is covered by the mothership's file backup with the rest of `config/`.

### D4 — The platform validates, at every point a declaration changes

`module-manager` holds the one validator for D1's subset (TypeScript), with a fixture set shared
by its tests. It runs:

| When | On failure |
|---|---|
| `validate --blueprint` (release, ADR-027) | the schema is not in the subset, or the release's file does not validate: a release finding |
| install | the install stops before the module's scripts run, naming the path (`sites[1].domain`) and the rule |
| update, after the merge | that module's update stops with the finding; its config and the declaration stay as they were |
| `declaration set` / `unset` (D5) | the change is refused, nothing is written |
| `module-manager validate` | a finding per invalid path, for every instance |

A controller or manager reads its instance's file and may trust it: by the time it is called the
file has passed. A component written in bash or Python validates by calling
`module-manager declaration validate <i> <name>`, not with a validator of its own.

### D5 — Changing a declaration: one verb, the owner applies it

```
module-manager declaration show     <instance> <name> [<path>]
module-manager declaration set      <instance> <name> <path>=<value>...  [--allow-disruption] [--check]
module-manager declaration unset    <instance> <name> <path>...
module-manager declaration validate <instance> <name>
```

`<path>` is dotted, with `[<key>]` for an element of a keyed list:
`hosting-manager sites[example].channel=beta`. `set` validates, records the changed leaves as the
operator's (so the next update keeps them), and has the **owner** apply them:

- a manager or controller is called with its `reconcile <instance>` verb (from its `--help --json`,
  ADR-035 D5), which reads the new file;
- a module's own declaration (D2) is applied by running the module's `update.sh`, as
  `module update` does.

The change class gates it:

| `changeClass` | Effect |
|---|---|
| `in-place` | written, then applied as above |
| `in-place-reboot` | the same, with a restart of the guest, under ADR-020 D8 (`rebootOk` in the scheduled pass, or `--allow-disruption`); not authorized, it is written and the apply prints `DEFERRED:` |
| `immutable` | refused once the instance is installed |
| `manual` | written and reported; nothing is applied |

If the apply fails, the file is put back as it was before `set`, as `modify` restores the config.
A manager's own verbs (`hosting-manager site add`) may write the same file; they validate through
the same verb, so there is one rule whichever way the change arrives.

### D6 — The console renders a declaration from its schema

The console's field manifest serves a declaration's schema
(`GET /api/v1/fields/declaration/<instance>/<name>`) through the existing `flattenSchema`. The
module's page shows each declaration of each instance as a form, and saving it goes through
`declaration set`, so the console can do nothing the CLI cannot. A list of objects with a `key`
renders as a table, one row per element. A component's verbs stay where ADR-035 put them, read
from its `--help --json`.

## Consequences

- One mechanism for an application's own configuration. Hosting moves its sites and its
  module-wide settings into `hosting-manager.json` with a schema, and drops its template schemas.
- The module JSON, `schemas/module-fields.json`, `compose-fields` and `check_json` are unchanged.
  Nothing composes per module, and no name has to be reserved in the field namespace.
- A module with settings but no component is not pushed into writing one (D2).
- The validator lives in `module-manager` only. Bash and Python components call it, so there is no
  jq twin to keep in step.
- D11's open point on authority (does the declaration overrule a change made in the application's
  own UI?) stays decided per component, as ADR-035 O4 left it. This ADR governs the file, not the
  application.
- A component whose schema leaves the subset fails `--blueprint`, so the subset is enforced before
  a release ships, for TAPPaaS and Community modules alike.

## Alternatives considered

- **ADR-038 v0.1: the module's fields in the module JSON, under a key named after the module.**
  Withdrawn: against ADR-035 D11 (the module JSON's fields are the platform's and do not grow per
  application). It also needed a reserved-name check in field composition, a jq validator twin
  for `check_json`, and dotted names in `modify --set`.
- **Leave validation to each component.** What D11 says today, by omission. Every component
  repeats it, the rules drift, and the console cannot render any of it.
- **Full JSON Schema with an off-the-shelf validator.** A node dependency in `module-manager` and
  error messages that differ from the console's rendering. The subset covers hosting and LiteLLM
  (#170); widening it later is additive.
- **One declaration file per module, not per instance.** Two hosting instances would share one
  site list, which is wrong: each instance is its own configuration (ADR-026 D6).

## Open questions

1. **LiteLLM (#170).** The other planned D11 user. Do its models, teams and budgets fit the subset
   without `oneOf` (a model's provider-specific settings)? If not, a discriminated object
   (`"kind"` plus per-kind properties) may need to join the subset.
2. **Declarations across instances.** A manager for a whole stack may want one declaration for the
   stack rather than per instance. Is that the stack's first instance, or a `config/declarations/
   _stack/<stack>/` copy?
3. **History.** Should `declaration set` keep the previous file (`<name>.json.prev`) for an
   operator's undo, beyond the rollback on a failed apply?

## Implementation plan

- **P1 — Validator and schema subset.** In `module-manager` (TypeScript): the subset of D1, the
  annotations, `key` paths, shared fixtures (each rule, an unknown key, a refused `secret`, a broken
  `references`). `--blueprint` checks schemas and release files.
- **P2 — Per-instance copies.** Seed on install, three-way merge on update, keep or remove on delete,
  for D2's two owners.
- **P3 — `module-manager declaration` verbs** with change classes, the owner's apply, rollback, and
  `DEFERRED:` for unauthorized restarts.
- **P4 — Console.** The field manifest serves declarations; the module page renders forms and keyed
  tables, saving through `declaration set`.
- **P5 — Hosting adopts it** (with @AndreasJe): `hosting-manager.json` and its schema; the module
  template documents both owners of D2.

Test: P1–P3 offline in module-manager's suite; P2, P3 and P4 live on hrossen with a scratch module
that has a manager with a declaration and a second module with `declarations.json`: install, an
invalid `set` refused, a valid one applied by the owner, a failing apply rolled back, a second
instance with its own copy, `delete --remove` cleaning up. Torn down after.
