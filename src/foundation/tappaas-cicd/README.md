# tappaas-cicd

The TAPPaaS "mothership" control plane. This document describes the **internal
component contract** and the **three-level dispatch** that drives every manager
and controller uniformly (ADR-007 P10 deliverable #5).

For the full rationale see
[`docs/design/ADR-007-implementation.md`](../../../docs/design/ADR-007-implementation.md)
(packages **P4** — layout — and **P10** — the template + dispatch).

## Overview — internal layout

```
src/foundation/tappaas-cicd/
├── install.sh / update.sh / test.sh   # top-level entry scripts (drive the dispatchers)
├── manager/                           # domain-object lifecycle (CONFIG state)
│   ├── install.sh / update.sh / test.sh   # dispatcher: loop children, skip TEMPLATE/
│   ├── TEMPLATE/                      # P10 skeleton manager (copy to scaffold)
│   └── <name>-manager/               # one dir per manager component
├── controller/                        # infrastructure control (RUNTIME state)
│   ├── install.sh / update.sh / test.sh   # dispatcher: loop children, skip TEMPLATE/
│   ├── TEMPLATE/                      # P10 skeleton controller (copy to scaffold)
│   └── <name>-controller/            # one dir per controller component
├── lib/                               # shared libraries, sourced (never copied per component)
└── scripts/                           # foundation bring-up + unit tests (scripts/test/)
```

- **`manager/`** — owns **config state**: JSON config files, schemas, and their
  validation. A manager may call controllers to realize that config. Managers
  ship a `validate.sh`. Examples: `people-manager`, `site-manager`,
  `environment-manager`, `module-manager`, `network-manager`, `health-manager`.
- **`controller/`** — owns **runtime state**: APIs, network devices, VMs. A
  controller does **not** ship a `validate.sh`. Examples: `opnsense-controller`,
  `proxmox-controller`, `switch-controller`, `ap-controller`,
  `identity-controller`.
- **`lib/`** — shared code sourced by components (e.g.
  `common-install-routines.sh`). Shared logic lives here once; it is never
  copied into individual components.
- **top-level entry scripts** — `install.sh` / `update.sh` / `test.sh` at the
  cicd root.

## Component contract

Each manager/controller lives in its own subdirectory and exposes a fixed set of
files:

```
<component>/
├── <name>.{ts,py,sh}   # main entry: domain verbs (CRUD for a manager, reconcile for a controller)
├── install.sh          # idempotent: build artifact, place bin/ symlink, one-time setup
├── update.sh           # idempotent: rebuild, re-link, migrate on-disk state if schema changed
├── test.sh             # self-contained tests; exit non-zero on failure
├── validate.sh         # (managers only) schema/reference validation for the domain
└── README.md           # what it owns; manager-vs-controller; which controllers it calls
```

- `install.sh`, `update.sh`, and `test.sh` are **mandatory** and must be
  **idempotent** in every component.
- `validate.sh` is **present for managers** and **absent for controllers**.
- The preferred entry-point language order is **TypeScript → Python → Bash**
  (see "Preferred language" below).

## Three-level dispatch

The control plane is driven by three trivial levels — adding a component never
changes anything above it:

1. **Top level** — `tappaas-cicd/{install,update,test}.sh` call
   `manager/<verb>.sh` and `controller/<verb>.sh`.
2. **Dispatcher level** — `manager/<verb>.sh` and `controller/<verb>.sh` each
   loop their child component directories and run the matching verb script,
   **skipping `TEMPLATE/`**. There is no shared runner; each dispatcher is a few
   lines:

   ```bash
   for d in "${here}"/*/; do
       [ "$(basename "${d}")" = TEMPLATE ] && continue
       [ -x "${d}install.sh" ] || continue
       "${d}install.sh" "$@"
   done
   ```

3. **Component level** — each component's own `install.sh` / `update.sh` /
   `test.sh` does the actual work.

**Adding a component** = drop a directory containing the standard verb scripts
(scaffold from `TEMPLATE/`). The dispatcher picks it up automatically; nothing
above it is edited.

> **Top-level wiring is additive (option A).** The cicd VM keeps its own
> `nixos-rebuild`/`test` for the VM itself **and** drives the manager/controller
> dispatchers — the dispatch is added alongside the existing VM lifecycle, it
> does not replace it.

## Compiled components

A component that ships a **built/packaged artifact** must **rebuild the package
and refresh its `bin/` entry-point symlinks** in `install.sh`/`update.sh` — not
merely copy source. This is what makes a code change get picked up on update.

- **Python** (e.g. `opnsense-controller`, `update-tappaas`) — nix build /
  `pip install -e` of the component's `pyproject.toml`, then relink its entry
  points (the former whole-VM `pre-update.sh` behaviour, now per-component).
- **TypeScript** (future) — `npm`/`pnpm install && build`, then link the bin.
- **Bash** — nothing to compile; just symlink the entry script onto `PATH`.

The build step must be **idempotent**: a no-op when its inputs are unchanged.

## Testing: fast vs deep slices

Every component `test.sh` runs a **fast, non-disruptive slice by default** and a
**deep slice only when `TAPPAAS_TEST_DEEP=1`**:

- **Fast (default)** — schema/CLI/validation + mocked-logic unit tests. No live
  services, no Authentik mutation, no cluster/VM ops. Quick and safe anytime.
- **Deep (`TAPPAAS_TEST_DEEP=1`)** — adds the disruptive/slow tests: live
  Authentik reconcile, cluster ops, VM provisioning. These mutate real state, so
  they are scoped (e.g. `zztest-` names) and self-cleaning.

The cicd module gate honours the split:

- `test-module.sh tappaas-cicd` (**fast**, ~seconds) runs the quick checks plus
  **Test 11**, a lightweight per-component *smoke* using the already-built bins
  (validate schemas, CLI loads, config reads) — confirms basic functionality
  without touching anything.
- `test-module.sh tappaas-cicd --deep` runs the VM/variant suites **and** the
  `manager/` + `controller/` dispatchers with `TAPPAAS_TEST_DEEP=1`, so every
  component's full suite (offline unit + live tiers) runs.

When adding a component: gate its disruptive tests behind
`[[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]`, and add a one-line smoke to Test 11.

## Preferred language

In order: **TypeScript → Python → Bash.** Pick the highest applicable tier for a
new component: prefer TypeScript; use Python where an existing package/ecosystem
fit makes it cheaper (e.g. extending `opnsense-controller`); reserve Bash for
thin glue, install-time scripts, and small wrappers. Existing Bash/Python
components are not rewritten by this rule — they are migrated opportunistically.

## Scaffolding a new component

Copy the matching template and edit in place:

```bash
# a new manager
cp -r manager/TEMPLATE manager/my-manager

# a new controller
cp -r controller/TEMPLATE controller/my-controller
```

Then rename `<name>.{ts,py,sh}`, fill in the verb scripts, and (for a manager)
the `validate.sh`. The dispatcher will run it on the next install/update/test
with no changes above the component directory.
