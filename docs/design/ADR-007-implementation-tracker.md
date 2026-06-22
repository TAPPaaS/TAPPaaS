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
| **S0** | P4-structure: manager/controller skeleton + script moves + dispatchers | #365, #364 | none | ✅ done (all batches; deep gate passed) | cicd --deep 31/2 (only pre-existing); firewall --deep = pre-existing only (11 switch-WIP + proxy-env); PROGRAMS.csv 56/0-nix; 0 dangling | 42df813·876bb2c·86294ba·4573597 | ✅ |
| **S1** | P10 `manager/TEMPLATE/` + `controller/TEMPLATE/` + dispatchers | — | S0 | ✅ done | contract test 25/0; cicd unit 27/0 (Test 10 added); ShellCheck clean | (next commit) | ⏳ |
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
- **⚠ INCIDENT (2026-06-21 21:24) — Batch-2 gate interrupted by a tappaas1 hard-reset.** The `firewall --deep` gate (which provisions test VMs `test-fw-a/b/c` = 921/922/923 on tanka1) stressed tappaas1's **tanka1 NVMe (recurring PCIe AER transaction-layer faults — see memory `nvme-hang-tanka1-incident`)** into an I/O stall; the HA `softdog` watchdog (60 s) couldn't be petted → **hard reset of tappaas1** (journal stops 21:21:20 with no panic/OOM/shutdown; boots 21:24:31). Single node; cluster recovered quorate; HA restarted firewall/cicd/identity on tappaas1. **No data loss** (`zones.json` intact; S0 work committed+pushed `c2480cc`). **Collateral cleaned**: deleted orphaned VMs 921/922/923 + removed `testAllowA/B/Pinhole` zones + restored firewall trunks. **Action: deep-test gates PAUSED until the tanka1 NVMe mitigation (`nvme_core.default_ps_max_latency_us=0` + ASPM-off) is applied + active on tappaas1.** Batch-2 `firewall --deep` was *not* completed (only pre-existing failures seen before the reset) — must be re-run post-mitigation.
  - **✅ CLEARED (2026-06-21 ~21:49, driver):** tappaas1 `/proc/cmdline` now carries `nvme_core.default_ps_max_latency_us=0 pcie_aspm=off`; runtime param = 0; rebooted into the fix (uptime ~24 min at check); no AER/nvme errors since boot. **Deep-test gates resume.** Batch-2 `firewall --deep` re-run folds into the S0 final gate alongside batch 3.
- **Remaining (Batch 3, for the driver)**: `lib/` move of `common-install-routines.sh` (+`apply-json-merge.sh`,`audit-jq-readers.sh`); `opnsense-controller` (Python pkg + ~12 bin entries + nix-build path in `pre-update.sh`) → `controller/opnsense-controller/` with a compiled-component `install/update`; `identity-controller` (`authentik-manager`); reduce top-level `install/update/test` to the dispatchers; regenerate `PROGRAMS.csv`/`DEPENDENCIES.csv` and assert no dangling `bin/` symlink.
  - **Operating mode (2026-06-21 ~22:00):** operator away ~8h; driver runs **unattended + conservative** — every gated sub-step is committed+pushed immediately so progress is durable. **System is a test cluster** (no live services/data at risk as long as work is committed+pushed). Stop-the-line on any red gate it can't confidently fix.
  - **Batch 3a — `lib/` move (DONE, fast-gated):** `git mv scripts/{common-install-routines,apply-json-merge,audit-jq-readers}.sh → lib/`; added `lib/*.sh` to install2.sh's bin-symlink loop (keeps the ~160 `. bin/...` sourcers stable); rewrote all non-Attic refs scripts/→lib/ (2 runtime sources in update.sh/pre-update.sh, 2 runtime relative sources in test-variants, the rest shellcheck hints); repointed the 3 live bin symlinks. **Gate: ShellCheck clean** on logic-changed scripts (pre-update.sh's SC2034/SC2088 are pre-existing, lines 12/200, not touched); **`test.sh tappaas-cicd` (non-deep) = 26 passed, 0 failed.** Full deep gate deferred to end of batch 3.
  - **Unattended scope decisions (2026-06-21 ~22:05):** (1) **3b opnsense-controller move = ATTEMPT**, gated by `nix-build` (pure) + `nixos-rebuild test` (NOT `switch`) + revert-on-failure — bounded entanglement (1 nix import line + 3 pre-update.sh path refs + git mv; no flake ref). (2) **3d top-level→dispatcher reduction = DEFERRED** to operator: real design decision (where does the cicd VM's own `nixos-rebuild`+test-suite live once top-level is a pure dispatcher?) with behaviour-change risk that conflicts with S0's "no behaviour change" mandate. (3) **Full S0 deep gate (firewall --deep + cicd --deep, VM-provisioning) = DEFERRED** to a supervised run: it is the exact operation that hard-reset tappaas1 on 2026-06-21; mitigation is active but unproven under that load, and an unattended reset could orphan VMs/zones needing manual cleanup. So **S0 stays WIP / #365+#364 stay open** until 3d + deep gate are done with the operator. Fast unit gates + nix-build + `nixos-rebuild test` are the unattended confidence bar.
  - **Batch 3b — `opnsense-controller` → `controller/` (DONE, nix-gated):** `git mv opnsense-controller controller/opnsense-controller` (38 tracked files; cleaned regenerable `result*`/`__pycache__` first). 6 path edits across 3 files: `tappaas-cicd.nix:30` import path; `pre-update.sh` `cd` target (168), two absolute `result/bin` paths (177,190), and the paired `cd ..`→`cd ../..` (208, critical — else the subsequent update-tappaas build runs from the wrong dir); `scripts/test/test-acme-provider-hook.sh:17` relative path. **Gate: `nix-build -A default default.nix` from new location = rc 0; `nixos-rebuild test --flake .#tappaas-cicd --impure` = rc 0 (import path resolves; NOT `switch`); repointed the 12 live opnsense-CLI bin symlinks + `opnsense-manager` to new `result/bin`; no dangling bin symlinks; `test.sh tappaas-cicd` = 26/0; `opnsense-controller --help` + `caddy-manager --help` exec OK.** authentik split still deferred to S2 (lives in this pkg for now).
  - **Driver decisions (2026-06-21):** run batch 3 **mechanical-first, gating the nix move** — sub-steps **3a** `lib/` move + **3d** top-level→dispatchers + **3e** regen/dangling-symlink assert land first (each gated by the fast cicd unit test), then **3b** `opnsense-controller` nix move as its own gated step (nixos-rebuild test before the full deep gate). **3c authentik→identity-controller is DEFERRED to S2** — `authentik_manager.py`/`authentik_cli.py` live *inside* the opnsense-controller pkg today; extracting them is a package split that S2 (P1 people-manager + identity-controller) will build properly. S0 stays a pure reorg.
- **S0 firewall --deep gate (2026-06-22) — PASS (no new failures):** ran to completion, **tappaas1 did NOT reset** (NVMe mitigation held through all 3 deep runs ≈21 VM provisions). Failures = pre-existing only: 11× "Deep A/B" switch-provider WIP (physical switch unregistered, #372/#373 switch side → S5) + 1× proxy "upstream unreachable status 000" (test-env, no upstream). **opnsense-controller exercised 11× — all succeeded** (test-fw-a/b/c install + DNS + firewall:rules `applied=3`), validating the 3b nix move against real OPNsense ops. No orphaned VMs.
- **Batch 3e — dep-doc regen (DONE):** regenerated `PROGRAMS.csv` (56 programs, 0 `/nix/store` in source paths, all relocated to manager/controller/lib + opnsense CLIs mapped to their .py source), `DEPENDENCIES.csv` (22 dir groups), `DEPENDENCIES.md` (summary + 5 chains + entry points + mermaid). **Completeness assert: every program resolves to its new path, 0 dangling bin symlinks.** (Done via subagent; verified.)
- **✅ S0 COMPLETE (2026-06-22).** All batches landed + deep gate passed (no new failures). Closing **#365, #364**. Note follow-ups (non-blocking): opnsense-controller still lacks its own P10 install/update/test.sh (build in pre-update.sh); 4 manager/* scripts have a wrong-dir fallback source (work via bin primary); switch-controller TS bin (S-TS pilot) vs switch-manager bash coexist.
- **Issues**: #365, #364 — CLOSED by S0 completion commit.
- **S0 deep gate run #2 (2026-06-22, post-fix) — cicd PASS (no new failures):** `test-module.sh tappaas-cicd --deep` = **31 passed, 2 failed** (was 30/3). The only delta from run #1 is the alias test flipping to pass — regression gone. The 2 remaining fails are **identical pre-existing**: VM-creation 3/4 (VLAN/node-locality installs #372/#373 — byte-identical to run #1, i.e. stable infra not flaky/code) + ap-controller 16/1 (ADR-008 WIP). **Verdict: no new code regressions from S0; cicd deep gate passes the no-new-failures bar.** mitigation held through two 7-VM deep runs (no node reset).
- **S0 deep gate run #1 (2026-06-22 07:08) — caught a regression, fixed:** `test-module.sh tappaas-cicd --deep` = 30 passed, 3 failed. Triage: **(NEW regression — mine)** `test-alias-name-validation` 1/10 → root cause: 3a's lib move missed the `${SCRIPT_DIR}/../<file>.sh` source form in **8 `scripts/test/*.sh`** (pattern didn't contain literal `scripts/`). **Fixed** → rewrote those to `${SCRIPT_DIR}/../../lib/…`; `test-alias-name-validation` now **11/0**. **(pre-existing, not mine)** VM-creation 3 pass/4 fail = `deb-n3noha`/`deb-vlannode`/`ubuntu-vlan` inter-node-VLAN/node-locality installs (#372/#373, S5 territory) + `nixos` PARTIAL 16/1 — non-VLAN installs passed with the moved scripts, so the core path is intact; ap-controller 16/1 = ADR-008 ap-provider WIP. Also noted: `test-json-merge.sh` sources `../convert-json-to-config.sh` (moved to site-manager by batch 1) — separate pre-existing batch-1 breakage, orphan test (no gate runs it). **Latent (batch-1, not blocking):** 4 `manager/*` scripts' fallback source `${SCRIPT_DIR}/common-install-routines.sh` points to their own dir (works via the bin primary) — fix to `../../lib/` in a follow-up.
- **Batch 3d — top-level → dispatchers, OPTION A (additive) (DONE, fast-gated; operator chose A 2026-06-22):** `update.sh` keeps its cicd-self `nixos-rebuild switch`+plugin-ensure AND now additively runs `manager/update.sh`+`controller/update.sh` (idempotent bin relink; dispatcher skips TEMPLATE/ and verb-less components like opnsense-controller). `test.sh` keeps the 26-test cicd suite AND, in its **deep** section, drives `manager/test.sh`+`controller/test.sh` (fast unit gate stays green; component health folds into the deep gate under "no new failures vs baseline"). Install path already additive via install2.sh. **Gate: ShellCheck clean** (test.sh SC2034 is pre-existing in Test 9); **fast unit `test.sh tappaas-cicd` = 26/0.** Follow-up: opnsense-controller still lacks its own install/update/test.sh (compiled build lives in pre-update.sh) — give it the P10 compiled-component verbs in a later step.
- **UNATTENDED RUN OUTCOME (2026-06-21 ~22:40, driver):** Completed + committed + pushed **3a** (lib move, `42df813`) and **3b** (opnsense-controller→controller/, `876bb2c`), each fully gated (ShellCheck / nix-build / `nixos-rebuild test` / cicd unit 26/0 / controller units at baseline / no dangling symlinks / CLI exec smoke). **Deferred to the operator** (deliberate conservative choices while unattended):
  - **3d — top-level `install/update/test` → dispatchers: NEEDS A DECISION.** Today `update.sh` does the cicd VM's own `nixos-rebuild switch` + OPNsense-plugin ensure, and `test.sh` is the 26-test cicd suite; both run as the module's verb scripts via `update-module.sh`/`test-module.sh tappaas-cicd`. Making top-level a *pure* dispatcher would drop that cicd-self lifecycle → behaviour change, which S0 forbids. **Options:** (A) **Additive** — top-level keeps its cicd-self logic AND also calls `manager/<verb>.sh`+`controller/<verb>.sh` (smallest delta; recommended). (B) **Extract** a `manager/cicd-self/` component owning the rebuild+plugin-ensure+test-suite, top-level becomes pure dispatcher (cleanest, more work). (C) leave top-level as-is for S0, treat pure-dispatcher as an S1 concern. Pick one → driver implements + gates.
  - **3e — regen PROGRAMS.csv/DEPENDENCIES.csv/DEPENDENCIES.md: DEFERRED to S0-final.** Dated Jun 16, already predate batches 1–2; a correct regen needs the *final* structure (after 3d changes top-level entry points), and a full hand-regen of the ~300-file graph unsupervised is too error-prone to trust. Safety substitute done now: **dangling-bin-symlink assert = PASS**.
  - **Full S0 deep gate (`firewall --deep` + `cicd --deep`, VM-provisioning): DEFERRED to a supervised run** — exact op that hard-reset tappaas1; must be re-run (incl. the interrupted batch-2 `firewall --deep`) before S0 closes #365/#364.
- **RESUME CHECKLIST (next session / operator):** (1) decide 3d A/B/C → driver implements+gates. (2) supervised full deep gate (`test-module.sh tappaas-cicd --deep` + firewall `--deep`); clean up any orphaned test VMs/zones. (3) regen the 3 dep docs against final structure; assert all programs resolve, no dangling. (4) mark S0 ✅, commit closing **#365 #364**, push. (5) then S1 (P10 finalize — 3d may already cover its top-level-dispatcher half).

### S1 — P10 template  ✅ DONE 2026-06-22
- **Delivered**: TEMPLATEs + dispatchers (S0) + top-level→dispatchers (3d, option A) + NEW `tappaas-cicd/README.md` (component contract, 3-level dispatch, compiled-component rebuild rule, TS→Py→Bash order) + NEW `scripts/test/test-template-contract.sh` (P10 criteria: scaffold dispatches via parent, TEMPLATE/ skipped, manager-has-validate/controller-doesn't, ShellCheck clean) + compiled-component guidance comments in the 4 TEMPLATE install/update stubs.
- **Gate**: contract test **25/0**; wired as cicd **Test 10** → `test.sh tappaas-cicd` **27/0**; ShellCheck clean (test.sh SC2034 is pre-existing Test 9). S1 criteria are all unit-level (no VM provisioning) so the fast gate is the complete deep test.
- **Issues**: none (P10 is the template/contract stage).
- **Implementation**: via subagent, independently verified + wired + gated by the driver.

### S1 — P10 template (original dry-run plan, superseded by the DONE entry above)
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
