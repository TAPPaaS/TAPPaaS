# Component template — building a new manager or controller

This directory is the **scaffold skeleton** for a new TAPPaaS control component.
Copy it to create a new manager (here) or controller (under `controller/`). The
parent dispatchers **skip `TEMPLATE/`**, so this skeleton never runs in place.

This README is the canonical reference for the shared component contract. Read it
before scaffolding anything.

## Managers vs controllers

TAPPaaS has two kinds of control component:

- A **manager owns configuration state** — it does CRUD + validation on the JSON
  config files (and schemas) for one domain, and may orchestrate one or more
  controllers to apply that config. A manager ships a `validate.sh`.
- A **controller owns runtime / device state** — it talks to a live service or
  device and reconciles the real world toward a desired config. A controller does
  **not** ship `validate.sh`.

Managers live under `manager/`, controllers under `controller/`. Otherwise they
share the same verb contract and dispatch model described below.

## The verb contract

Every component is driven generically through a fixed set of **verb scripts** in
its own directory. The mothership never needs to know what language a component
is written in — it just runs the verbs.

| Verb | Required for | What it does |
|------|--------------|--------------|
| `install.sh` | all | One-time setup: build the compiled artifact (if any) and link the component's CLI(s) onto `PATH`. |
| `update.sh`  | all | Re-build + re-link; migrate on-disk state if the schema changed. |
| `test.sh`    | all | Self-contained tests; exit non-zero on failure. |
| `validate.sh`| managers | Schema / reference validation of this domain's config. |

**Every verb must be idempotent** — running it twice in a row must be safe and
the second run must be a no-op when nothing changed.

The main CLI itself is conventionally named after the component
(`<name>.{ts,py,sh}`) and exposes the domain verbs: CRUD for a manager,
`reconcile` for a controller.

## Three-level dispatch

The mothership runs components through a three-level fan-out:

1. **Top level** — the `tappaas-cicd` module's `install.sh` / `update.sh` /
   `test.sh` call the two group dispatchers.
2. **Group dispatchers** — `manager/{install,update,test}.sh` and
   `controller/{install,update,test}.sh` iterate their child directories,
   **skip `TEMPLATE/`**, run each child's matching verb script (if present and
   executable), and continue past a failure, returning the worst exit code.
3. **Component level** — each child's own verb script does the real work.

There is no shared runner: each component's verb scripts are fully
self-contained. Dropping a new component directory in place is all that is needed
to enroll it — the next install/update/test picks it up automatically.

## Testing: fast vs deep

Every `test.sh` runs a **fast, non-disruptive slice by default** and a **deep
slice only when `TAPPAAS_TEST_DEEP=1`**:

- **Fast (default)** — schema / CLI / validation checks plus mocked-logic unit
  tests. No live services, no identity mutation, no cluster or VM operations.
  Quick and safe to run anytime.
- **Deep (`TAPPAAS_TEST_DEEP=1`)** — adds the disruptive / slow tiers: live
  reconciles, cluster operations, VM provisioning. These mutate real state, so
  they must be tightly scoped (use a recognisable test prefix such as `zztest-`)
  and self-cleaning.

Gate disruptive tests behind:

```bash
if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    # live / heavy tests here
fi
```

The mothership's fast gate also runs a one-line per-component *smoke* (validate
schema, CLI loads, config reads) using already-built bins. When you add a
component, add a one-line smoke for it there too.

## Compiled-component rule

`install.sh` and `update.sh` must produce a **built artifact**, not just copy
source:

- **TypeScript** — build with `tsc` (the TAPPaaS pattern uses a Nix derivation:
  `tsc` + `makeWrapper` to produce `result/bin/<name>`, with no `node_modules`
  and an ambient `src/env.d.ts` for Node types), then link `result/bin/<name>`
  into `~/bin` with `ln -sf` (idempotent).
- **Python** — build the package (`nix build` of the component, or
  `pip install -e ./src`), then re-link the entry point(s) into `~/bin`.
- **Bash** — nothing to compile; just `ln -sf` the entry script(s) onto `PATH`.

The build step must be idempotent: a no-op when its inputs are unchanged. For a
compiled component, `update.sh` re-builds so code changes are picked up, then
re-links; if the on-disk schema changed it also runs any state migration.

## Preferred language

In order: **TypeScript → Python → Bash.** For a new component, pick the highest
applicable tier — prefer TypeScript; use Python where an existing
package/ecosystem fit makes it cheaper (e.g. extending an existing Python
controller); reserve Bash for thin glue, install-time scripts, and small
wrappers. Existing Bash/Python components are not rewritten by this rule — they
are migrated opportunistically.

## Scaffolding a new component

```bash
# a new manager
cp -r manager/TEMPLATE manager/my-manager

# a new controller
cp -r controller/TEMPLATE controller/my-controller
```

Then:

1. Rename and write the main CLI `<name>.{ts,py,sh}`.
2. Fill in the verb scripts (`install.sh`, `update.sh`, `test.sh`, and
   `validate.sh` for a manager). Follow the compiled-component rule for your
   language and keep every verb idempotent.
3. Gate any disruptive test behind `TAPPAAS_TEST_DEEP=1` and add a smoke line to
   the mothership's fast gate.

The dispatcher will run the new component on the next install/update/test with no
changes needed above the component directory.

## Files in this template

- `manager.sh` — placeholder for the main CLI entry (`<name>.{ts,py,sh}`).
- `install.sh` / `update.sh` — annotated compiled-component patterns for each
  language.
- `test.sh` — the fast/deep convention stub.
- `validate.sh` — the manager-only schema/reference validation stub.
