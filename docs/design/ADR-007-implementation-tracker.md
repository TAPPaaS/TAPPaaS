# ADR-007 Implementation Tracker

**Companion to**: [ADR-007-implementation.md](ADR-007-implementation.md) (the plan — *what* each stage delivers)
**Purpose of this doc**: live execution state — *status, test results, commits, pushes* — for each stage in the [Implementation Sequence](ADR-007-implementation.md#implementation-sequence).
**Driver**: the PM stage-gate workflow in [`.claude/skills/adr-007-driver/SKILL.md`](../../.claude/skills/adr-007-driver/SKILL.md).
**Branch**: `ADR007`
**Started**: 2026-06-21

---

## How to read this tracker

Each stage is **not done** until it passes the gate below. The driver updates this file at every transition.

**Stage gate (Definition of Done):**

1. **Plan** — PM decomposes the stage, identifies the `test.sh` files in scope (existing + new), lists issues it closes.
2. **Implement** — specialist agents do the work (architect / nix-dev / bash-dev / typescript-dev / infra / tester / security per CLAUDE.md routing).
3. **Validate** — `bash-script-validator` (ShellCheck + security) on every changed script; `tsc --noEmit` on changed TS.
4. **Deep test** — run **existing + new `test.sh`** (the deep/regression mode), backgrounded per CLAUDE.md long-task rules. Record pass/fail counts.
5. **Gate** — ALL green → commit (`Closes #NNN`) → push. ANY red → stop-the-line: log the failure here, fix, re-test. Do **not** advance.

**Status legend**: ⬜ not started · 🟦 in progress · 🧪 testing · ✅ done (green, committed, pushed) · 🟥 blocked/red

---

## Stage status

| Stage | Delivers | Issues | Depends on | Status | Tests (pass/fail) | Commit | Pushed |
|-------|----------|--------|-----------|--------|-------------------|--------|--------|
| **S-TS** | TypeScript pilot (`switch-controller`) | — | none | ✅ GO (qualified) | 47 / 0 (oracle) | (in ADR007 history) | ✅ |
| **S0** | P4-structure: manager/controller skeleton + script moves + dispatchers | #365, #364 (layout) | none | 🧪 batch 3 left | B1 cicd: variant 6/0 (VM-suite env); B2 controllers 107/1 (1 pre-existing ap WIP); firewall --deep = baseline (no new fails) | (WIP) | 🟦 |
| **S1** | P10 `manager/TEMPLATE/` + `controller/TEMPLATE/` + dispatchers | — | S0 | 🟦 planned (blocked on S0) | — | — | — |
| **S2** | P1 people-manager (schemas, validate, user-setup, minimal-org) | #56 | S1, S-TS | ⬜ | — | — | — |
| **S3** | P2 site-manager (site.json migration + schema, auto-migrate) | #313 | S1, S2 | ⬜ | — | — | — |
| **S4** | P3 environment-manager (schema + variant migration + minimal-envs) | #318 | S1, S3 | ⬜ | — | — | — |
| **S5** | network-manager front door (owns zones.json; fold zone-controller/reconcile; controller renames) | #372, #373, #335, #364, #319 | S0 | ⬜ | — | — | — |
| **S6** | P6/P7 mgmt-as-environment + default-env selection + legacy-zone sunset | #319 | S4 | ⬜ | — | — | — |
| **S7** | P5 module updates (tier/source + `--environment`) | #339, #356, #357 | S4, S0 | ⬜ | — | — | — |
| **S8** | P8 firewall→network rename + migration (wide surface; slot ≥ S7) | — | S0, S7 | ⬜ | — | — | — |
| **S9** | P9 backup hierarchy (backup-manager + backup-controller) | #358 | S3, S4, S1 | ⬜ | — | — | — |

> Suggested order: **S1 → S2 → S3 → S4 → S6**, with **S5** running in parallel (rides on S0), then **S7 → S8 → S9**. S5 unblocks the live #372/#373 switch-fan-out gap early.

---

## Stage logs

Newest entries on top. Each stage appends a dated block as it moves through the gate.

### S0 — P4-structure (manager/controller reorg)
- **Started**: 2026-06-21 (manual; handing off to the driver for batch 3)
- **Approach**: incremental moves with a deep-test gate after each batch. Key de-risk: `bin/` symlinks are the indirection layer — nearly all cross-script refs use absolute `/home/tappaas/bin/...` (move-safe), so a move = `git mv` + repoint bins via each component's `install.sh`, driven by the `manager/`+`controller/` dispatchers (bridged into `pre-update.sh`/`install2.sh`).
- **Done & validated**:
  - **Skeleton + dispatchers**: `manager/` `controller/` `lib/` + `TEMPLATE/`s + two-level `{install,update,test}.sh` (skip `TEMPLATE/`); no-op verified, ShellCheck clean.
  - **Batch 1 — managers**: `health/people/site/environment/module/network-manager` moved (`git mv`); bins + bare aliases (`variant-manager`,`zone-controller`) relink. **Gate `test-module.sh tappaas-cicd --deep`**: caught + fixed move-broken `test-variants` paths → **variant suite 6/0**; cicd unit tests match baseline; VM-creation 3/7 fails = **pre-existing** template-locality + inter-node VLAN/switch gaps (out of S0 scope).
  - **Batch 2 — controllers**: `proxmox/switch/ap-manager` → `controller/<x>-controller/`, `zone-reconcile` → `network-manager`; co-located unit tests moved; `PLUGIN_DIR` repointed to staying `firewall/scripts/plugins/`; `pre-update.sh`+`firewall/test.sh` rewired. **controller/test.sh**: proxmox 8/0, switch 47/0, setup-switches 37/0, setup-wlan 15/0, **ap 16/1 (pre-existing ADR-008 ap-provider WIP)**. **Gate `firewall --deep`** = same 11 pre-existing fails (proxy-upstream env + Deep A/B switch/ap WIP), **no new failures**.
- **Remaining (Batch 3, for the driver)**: `lib/` move of `common-install-routines.sh` (+`apply-json-merge.sh`,`audit-jq-readers.sh`); `opnsense-controller` (Python pkg + ~12 bin entries + nix-build path in `pre-update.sh`) → `controller/opnsense-controller/` with a compiled-component `install/update`; `identity-controller` (`authentik-manager`); reduce top-level `install/update/test` to the dispatchers; regenerate `PROGRAMS.csv`/`DEPENDENCIES.csv` and assert no dangling `bin/` symlink.
- **Issues**: #365, #364 — keep open until batch 3 + regen gate complete (no `Closes` yet).

### S1 — P10 template
- **Status**: 🟦 planned (dry-run done 2026-06-21) — **blocked on S0**; do not start editing until S0 is committed (`TEMPLATE/`, dispatchers, top-level scripts are actively changing in the parallel S0 session).
- **Dry-run finding**: S0 has **already built most of S1's nominal deliverables** — `manager/TEMPLATE/` + `controller/TEMPLATE/` skeletons (controller correctly has no `validate.sh`) and the `manager/` + `controller/` `{install,update,test}.sh` dispatchers (idempotent, skip `TEMPLATE/`, worst-rc). So **S1 is reframed: finalize → document → test the contract**, not build-from-scratch.
- **Remaining S1 gap**:
  1. Top-level `tappaas-cicd/{install,update,test}.sh` call the two dispatchers — `update.sh`/`test.sh` exist (content unverified); **`install.sh` missing** (currently `install2.sh`). Verify/finish wiring.
  2. **`tappaas-cicd/README.md` missing** — document the component contract, manager-vs-controller, and the 3-level dispatch.
  3. Compiled-component rebuild rule: template `install/update` are `echo`-only stubs — encode "rebuild pkg + refresh `bin/` symlinks" guidance + a concrete Python example for the test.
  4. **Contract `test.sh`** (the deep-test gate content): prove scaffold-from-`TEMPLATE/` runs via the parent dispatcher with zero edits above; dispatcher skips `TEMPLATE/`; manager has `validate.sh` / controller doesn't; a Python component's `update.sh` rebuilds + relinks; ShellCheck-clean.
- **test.sh in scope**: NEW = P10 contract test; EXISTING = current `tappaas-cicd` `test.sh` + dispatcher run.
- **Specialists**: bash-dev (top-level wiring + harden stubs), tester (contract test), bash-dev/pm (README), `bash-script-validator` on all changed `.sh`. No security agent (no credentials).
- **Issues closed**: none — P10 is the template/contract stage; commit subject is the stage itself (no `Closes #`).

<!--
Template for a stage log entry — copy when a stage starts:

### S<n> — <name>
- **Started**: YYYY-MM-DD
- **Plan**: <one-paragraph decomposition; specialists dispatched>
- **test.sh in scope**: <paths — existing + new>
- **Validate**: ShellCheck <result>; tsc <result>
- **Deep test run** (YYYY-MM-DD HH:MM): `<command>` → **N passed, M failed**
  - <failure detail + fix, if any; re-run results>
- **Gate**: ✅ green
- **Issues closed**: #NNN, #NNN
- **Commit**: <sha> "<subject>"
- **Pushed**: ✅ origin/ADR007 @ <sha>
-->
