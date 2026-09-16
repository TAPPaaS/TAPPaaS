# ADR-007 Migration Design — converting a mainline system to the ADR-007 model

**Status:** analysis + proposal
**Date:** 2026-06-26
**Scope:** What happens when a fully-updated *mainline* TAPPaaS system (one that has
**not** been aligned to ADR-007) is pointed at the `ADR007` branch and an
`update-tappaas` run is performed. Does it self-convert?

---

## TL;DR — the verdict

> **Pointing a mainline system at `ADR007` and running `update-tappaas` does NOT
> fully convert it.** It performs exactly **one** of the three ADR-007 migrations
> automatically.

| ADR-007 migration | Auto on `update-tappaas`? | Where it lives |
|---|:--:|---|
| `configuration.json` → `site.json` | ✅ **YES** | `tappaas-cicd/pre-update.sh:116-131` (guarded, idempotent) |
| base **environments** (`mgmt` + `<org>`) + `zones-init` | ❌ **NO** | only `tappaas-cicd/install.sh:198-216` (fresh-install bootstrap) |
| **firewall → network** (deployed VM/config rename) | ❌ **NO** | `network/migrate-firewall-to-network.sh` — manual/supervised, called by nothing |

The system **keeps running** afterwards (back-compat aliases + graceful zone
fallback), but it lands in a **half-migrated state**: it has a `site.json`, yet it
has **no environments** and is **still on `firewall.json`**. That is functional,
but it is *not* the ADR-007 target model.

There are also two **prerequisites / hazards** that mean "just `git checkout
ADR007` and run it" is not even reliable for the one migration that *is*
automatic — see [§4](#4-will-it-actually-work--prerequisites-and-hazards).

---

## 1. What `update-tappaas` actually does, in order

`update-tappaas` (`tappaas-cicd/update-tappaas/src/update_tappaas/main.py`) is a
**per-module update orchestrator**. It contains **no migration or bootstrap logic
of its own** — confirmed by reading `main.py:377-499`. Its run is:

1. **Setup** (`main.py:377-406`) — `load_config()` reads `/home/tappaas/config/site.json`
   (`main.py:132-139`); schedule gate `should_update_now()` (`--force` bypasses).
2. **Phase 1 — foundation modules, fixed order** (`main.py:449-458`). The order is
   hardcoded (`FOUNDATION_MODULES`, `main.py:31-39`):
   `cluster → tappaas-cicd → templates → network → backup → identity → logging`.
   Each is updated via `module-manager module update <name>` (`main.py:326`).
   `deployed_foundation_name()` (`main.py:51-63`) resolves `network`→`firewall.json`
   on a not-yet-migrated system.
3. **Phase 2 — app modules, topologically sorted** (`main.py:460-472`). Discovered
   by globbing `config/*.json`, filtered by `NON_MODULE_JSONS` + `_is_module_json()`
   (`kind=="module"` or has `vmname`), then Kahn-sorted on `dependsOn`.
4. **Phase 3 — node reboot pass** (`main.py:474-481`), gated by
   `automaticReboot` (`reboot_pass()` passes `--execute` only when true and not
   `--dry-run`).

**The migration work is a side-effect of step 2 (modifying `tappaas-cicd`).**
`module update` → `update-module.sh` → runs the module's **`pre-update.sh`**. For
`tappaas-cicd` that hook is the real migration engine.

### What `tappaas-cicd/pre-update.sh` does (the engine), in order

Read in full at `src/foundation/tappaas-cicd/pre-update.sh`:

| Step | Lines | Action | Migration-relevant? |
|---|---|---|---|
| repo branch pull | 40-62 | `git checkout <repo.branch>` + `git pull` per `repositories[]` | ⚠️ **see hazard** |
| link bins | 66-105 | symlink `scripts/*.sh` + `manager/`+`controller/` dispatchers into `~/bin` | rebuilds the toolchain |
| refresh config | 107-114 | `create-configuration.sh --update` (re-discovers nodes) | — |
| **config → site** | **116-131** | **`migrate-configuration.sh` iff `configuration.json` exists AND `site.json` missing** | ✅ **the one auto-migration** |
| schema symlink | 135-138 | link `module-fields.json` into config | — |
| caddy patch | 140-155 | apply os-caddy ISDNSName patch to `firewall.mgmt.internal` | — |
| zone-key rename | 157-166 | one-shot hyphen→underscore (`#237`), marker-gated | zone hygiene, **not** zones-init |
| **zones-merge** | 168-185 | `network-manager zones-merge` — 3-way merge of the repo template into this install | re-bases template; **not** org-zone setup |
| zones-check | 187-202 | `network-manager zones-check` — report-only audit | — |
| build controllers | 204-278 | nix-build + link opnsense-controller, identity-controller, **update-tappaas** | rebuilds the orchestrator itself |
| OPNsense patch | 280-291 | scp controller patch to `firewall.mgmt.internal` | — |

**Conspicuously absent from `pre-update.sh`:** `create-minimal-environments.sh`,
`zones-init --name`, and `migrate-firewall-to-network.sh`. Those exist **only** in
`install.sh` (the first two) or are **manual** (the third).

---

## 2. The three migrations, one by one

### 2.1 `configuration.json` → `site.json` — ✅ automatic

- **Trigger:** `pre-update.sh:122` — `if [[ -f config/configuration.json && ! -f config/site.json ]]`.
- **Action:** `migrate-configuration.sh` (`manager/site-manager/migrate-configuration-to-site.sh`)
  maps `.tappaas.*` → flat `site.json` (`name`, `owner`, `version`, `hardware.nodes[]`,
  `repositories`, `updateSchedule`, `automaticReboot`, `snapshotRetention`).
- **Idempotent + non-destructive:** no-ops once `site.json` exists; **does not delete**
  `configuration.json` (back-compat readers still fall back to it).
- **Caveat — it does NOT create environments.** `migrate-configuration-to-site.sh:268`
  writes `environments: []` deliberately (variants→environments is deferred to S4/P3).
  So `site.json` lands with an empty environments list and **no env files**.

**Verdict:** works, automatic, safe. This part of the conversion *does* happen.

### 2.2 Base environments (`mgmt` + `<org>`) and `zones-init` — ❌ not on upgrade

- The only caller of `create-minimal-environments.sh` is `install.sh:213`; the only
  caller of `network-manager zones-init` is `install.sh:209`. **Both** are inside the
  fresh-install bootstrap and are **guarded** (`install.sh:216`: *"Environments already
  initialised … skipping zones-init/environments"*).
- `install.sh` is a **one-time bootstrap** (completion marker `.tappaas-cicd-installed`);
  `update-tappaas` **never re-runs it**, and `pre-update.sh` does not call either script.
- Therefore, after an upgrade: `config/environments/` is **empty** — no `mgmt.json`,
  no `<org>.json` — and the ADR-007 org-zone setup (`srv` → `<org>`, mgmt zone
  activation) never runs.
- **Why the system still works anyway:** `install-module.sh` resolves a module's zone
  with a fallback chain that ends at **`mgmt`** and emits a *warning* rather than
  failing (graceful degradation). So `module update` keeps succeeding without
  environments — it just silently parks everything in `mgmt`.

**Verdict:** **gap.** The environment model is never materialized on upgrade. The
system is "ADR-007 shaped" (`site.json` present) but environment-less.

### 2.3 `firewall` → `network` (deployed) — ❌ not on upgrade

- `network/migrate-firewall-to-network.sh` performs the deployed rename (config
  `firewall.json`→`network.json`, `qm set <vmid> --name network`, add
  `network.mgmt.internal` DNS alias, Caddy reconcile). It is **supervised/manual**:
  called by **no** install/update/orchestration path (grep returns nothing), requires
  `--yes`/`--node`, and warns that `firewall.mgmt.internal` is the cicd's control
  lifeline.
- `update-tappaas` instead just keeps modifying whatever exists:
  `deployed_foundation_name("network")` (`main.py:51-63`) prefers `network.json` but
  **falls back to `firewall.json`** → `module-manager module update firewall`. It
  **never creates `network.json`** on a legacy system.
- **Why apps still resolve:** the network module's `provides` lists `"firewall"`
  (`network/network.json`), and `common-install-routines.sh` `resolve_provider_module()`
  / `_legacy_module_alias()` map `firewall`↔`network`, so `dependsOn: ["firewall:…"]`
  keeps resolving. `network/update.sh` is dual-mode (reads `network.json` **or**
  `firewall.json`).
- **The host rename is deliberately deferred regardless:** even after the supervised
  migration, the OPNsense is still reached as `root@firewall.mgmt.internal`
  (`FIREWALL_FQDN`), and `firewall.mgmt.internal` is kept as a lifeline. (This is why a
  test that assumed the VM was reachable as `network.mgmt.internal` broke — see the
  cluster:vm `test-service.sh` `firewall|network` special-case.)

**Verdict:** **gap by design.** Functional (back-compat), but the system stays on
`firewall.json` indefinitely. A half-migrated `firewall.json` + `network.json`
coexistence (if the operator runs the manual script partway) is **not detected or
warned** by `update-tappaas`.

---

## 3. End state after a naive "checkout ADR007 + update-tappaas"

```
/home/tappaas/config/
├── site.json              ✅ created (auto-migration)
├── configuration.json     ⚠️ still present + still authoritative for fallback readers
├── environments/          ❌ EMPTY — no mgmt.json, no <org>.json
├── zones.json             ⚠️ merged/hygiene-fixed, but NOT zones-init'd to the org namespace
├── firewall.json          ❌ still the live network-module config (network.json absent)
└── …app configs…          ✅ updated in place; dependsOn:firewall:* resolves via alias
```

Functionally up; structurally half-migrated. Everything that *reads* the new model
degrades to `mgmt`/fallbacks; nothing that the operator can *see* in the new model
(environments, the renamed network module) is actually there.

---

## 4. Will it actually work? — prerequisites and hazards

Even the one automatic migration is gated by realities the operator must handle:

1. **Branch pinning (blocker).** `pre-update.sh:51` does
   `git checkout "$REPO_BRANCH" && git pull` for each configured repository, where
   `REPO_BRANCH` comes from `repositories[].branch` in `site.json`/`configuration.json`.
   A manual `git checkout ADR007` in the working tree is **overwritten** back to the
   configured branch (`main`/`stable`) on the very first run — so the ADR-007 code
   never activates. **The operator must set `repositories[].branch` to `ADR007` first.**
   (Only the no-repositories fallback, `pre-update.sh:56-62`, pulls the *current*
   branch and would preserve a manual checkout.)

2. **Two-pass settle.** The **installed** `update-tappaas` binary is the *mainline*
   one until `pre-update.sh:269-277` rebuilds it — but that rebuild only takes effect
   on the **next** invocation (the current process is already the old binary in
   memory). Same for `module-manager` and the controllers, which are relinked
   mid-run. So a full settle realistically needs **two `update-tappaas` runs**, and
   the first run drives the loop with mainline orchestration logic against
   freshly-migrated artifacts.

3. **Ordering wrinkle.** The config→site migration is a side-effect of modifying
   `tappaas-cicd`, which is **step 2** of Phase 1 — *after* `cluster` (step 1). On the
   first run, `cluster` is therefore modified against pre-migration state (no
   `site.json` yet; readers fall back to `configuration.json`). Self-heals on the next
   run, but the dependency of correctness on "tappaas-cicd happens to be second" is
   fragile.

4. **No half-migration detection.** Nothing warns when `site.json` exists but
   `environments/` is empty, or when both `firewall.json` and `network.json` exist.
   A partially-migrated system looks "green".

---

## 5. Proposed improvements

Goal: make **`update-tappaas` idempotently converge a mainline system onto the
ADR-007 model**, deterministically and observably — without the operator having to
know the internal bootstrap steps.

### P1 — A single, ordered, idempotent migration orchestrator — ✅ IMPLEMENTED
`tappaas-cicd/scripts/migrate-to-adr007.sh` runs the full sequence in order, each
step guarded + idempotent + resumable:
1. config → site (`migrate-configuration.sh`) — skipped once `site.json` exists.
2. derive `<name>` from `site.json` `.name` (fallback: first label of
   `configuration.json .tappaas.domain`) → `network-manager zones-init --name <name>`.
3. `create-minimal-environments.sh --name <name> [--domain …]`. Steps 2+3 are
   guarded together on `environments/<name>.json` (mirroring `install.sh`), and a
   targeted backup of `zones.json`/`configuration.json`/`site.json` is taken first.
4. firewall → network: **supervised/opt-in**. Runs `migrate-firewall-to-network.sh`
   only with `--include-firewall --node <FQDN>`; otherwise it *detects + warns*
   ("ACTION REQUIRED") and flags the half-migrated `firewall.json`+`network.json`
   case — never touches the OPNsense lifeline automatically (closes P4 and P5).
5. validation: `zones-check` + a structure audit (site.json valid + `.name`,
   `environments/{mgmt,<name>}.json` present, not both firewall/network configs).

Exit codes: `0` fully converged, `1` hard error, `2` action still required.
It is auto-linked to `~/bin` by `pre-update.sh`'s `scripts/*.sh` loop. Tested by
`scripts/test-migrate-to-adr007.sh` (14 dry-run assertions, no live side effects).
This also delivers the substance of **P3** (env/zone bootstrap on upgrade),
**P4** (firewall step safe-but-visible), and **P5** (half-migration detection).

### P2 — Run migration as an explicit PRE-PHASE in `update-tappaas` — ✅ IMPLEMENTED
`update-tappaas` now runs a **Phase 0** (`migration_pass()` in `main.py`) that
invokes the orchestrator *before* the foundation loop, so ordering no longer
depends on "tappaas-cicd is step 2" and `cluster` is updated against an
already-migrated config. It is **non-fatal** (a migration hiccup logs loudly but
never blocks module updates; the orchestrator is idempotent and retries next run),
never triggers the supervised firewall step (rc=2 surfaces as an action-required
warning), and resolves the script from `~/bin` → in-repo → `$MIGRATE_SCRIPT`.
Shown in `--dry-run` as "Phase 0 - ADR-007 migration pass".

> **Note on the two-pass settle ([§4](#4-will-it-actually-work--prerequisites-and-hazards)).**
> The *installed* `update-tappaas` is the mainline binary until `pre-update.sh`
> rebuilds it; Phase 0 therefore becomes active from the **second** run. On the
> first run the legacy `pre-update.sh:116-131` guard still creates `site.json`, so
> nothing regresses — Phase 0 simply takes over (and adds the environment/zone +
> firewall steps) once the new binary is in place.

### P3 — Close the environment gap on upgrade
At minimum, in `pre-update.sh` (or the P1 orchestrator): **after** the config→site
step, if `config/environments/` is empty, derive the name from `site.json` and run
`zones-init` + `create-minimal-environments` (both already idempotent). This is the
single highest-value fix — it is the difference between "has a site.json" and "is an
ADR-007 system".

### P4 — Make firewall→network safe-but-automatic (or loudly manual)
Two acceptable designs:
- **Semi-auto, guarded:** in the orchestrator, run `migrate-firewall-to-network.sh`
  only when `firewall.json` exists, `network.json` does not, the node is reachable,
  and a fresh snapshot was taken — preserving the `firewall.mgmt.internal` lifeline
  exactly as the manual script does today.
- **Stay manual, but visible:** have `zones-check`/`update-tappaas` emit a persistent
  **"ACTION REQUIRED: run migrate-firewall-to-network.sh"** warning whenever
  `firewall.json` is still the live network config, so the half-state can't hide.

Given the OPNsense control-lifeline risk, the semi-auto path must remain
conservative (snapshot first, lifeline kept, host rename still deferred).

### P5 — Half-migration detection
`zones-check` (already run every update) should additionally flag:
- `site.json` present **and** `environments/` empty,
- `firewall.json` **and** `network.json` both present,
- a module whose resolved zone fell back to `mgmt` because no environment matched.

### P6 — Document the operator upgrade procedure — ✅ IMPLEMENTED
Published as [ADR-007-migration-runbook.md](ADR-007-migration-runbook.md): an
operator-facing, command-by-command procedure — pre-flight (health + snapshots +
config backup), pin the repo branch to `ADR007`, the two-pass `update-tappaas`
settle (or the direct `migrate-to-adr007.sh` path), verification
(`site.json`, `environments/{mgmt,<org>}.json`, `zones-check`, module deep tests),
the **supervised firewall→network cutover** (snapshot → dry-run → execute →
verify), and rollback. Closes the gap that previously left only the fresh-install
path documented in `INSTALL.md`.

---

## 6. Sources

- `src/foundation/tappaas-cicd/update-tappaas/src/update_tappaas/main.py` — phases,
  foundation order, `deployed_foundation_name`, reboot gate (no migration logic).
- `src/foundation/tappaas-cicd/pre-update.sh` — the actual migration engine: config→site
  (116-131), branch checkout (51), zones-merge/check (168-202), toolchain rebuild.
- `src/foundation/tappaas-cicd/install.sh:198-216` — the **only** caller of `zones-init`
  + `create-minimal-environments` (guarded, one-time).
- `src/foundation/tappaas-cicd/manager/site-manager/migrate-configuration-to-site.sh:268`
  — `environments: []` (env files are not created here).
- `src/foundation/network/migrate-firewall-to-network.sh` — supervised/manual deployed
  rename; called by nothing automatic.
- `src/foundation/tappaas-cicd/lib/common-install-routines.sh` —
  `resolve_provider_module()` / `_legacy_module_alias()` firewall↔network back-compat.
- `src/foundation/network/network.json` (`provides: ["firewall", …]`),
  `src/foundation/network/update.sh` (dual-mode `network.json`|`firewall.json`).
- `docs/design/ADR-007-implementation.md`, `docs/design/ADR-007-implementation-tracker.md`
  — stage status (S3 site ✅, S4 environments ✅ at install, S8 firewall→network ✅ in
  source + supervised); no documented upgrade procedure.
</content>
</invoke>
