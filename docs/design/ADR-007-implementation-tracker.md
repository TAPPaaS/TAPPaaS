# ADR-007 Implementation Tracker

**Companion to**: [ADR-007-implementation.md](ADR-007-implementation.md) (the plan — *what* each stage delivers)
**Purpose of this doc**: live execution state — *status, test results, commits, pushes* — for each stage in the [Implementation Sequence](ADR-007-implementation.md#implementation-sequence).
**Driver**: the PM stage-gate workflow in [`.claude/skills/adr-007-driver/SKILL.md`](../../.claude/skills/adr-007-driver/SKILL.md).
**Branch**: `ADR007`
**Started**: 2026-06-21
**Branch totals** (vs merge-base `1cb61d2`, as of 2026-06-23): **522 files** — 187 added (+17,717), 88 modified (+2,418/−1,801), 140 renamed (+1,244/−635), **107 retired (−19,643)**; **+21,379 / −22,079 lines → net −700**; 68 commits. (Despite 6 managers + 5 controllers + schemas + tests, the branch is marginally *leaner* — the Attic removal [88 files, ~16k lines] + the legacy config/variant/roles retirement roughly balance the new architecture.)

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

## Remaining outstanding

All work not yet done, in **proposed order**. (Everything else — the S0–S9 build — is recorded in **Done Work** below.) Item 1 finishes the SSO cutover; 2 is the network front-door follow-up; 3–5 are the architecture arc that build on each other; 6–7 are deferred and best done last.

> **Decided (zone stability, 2026-06-23):** already-installed modules **stay in their zones**. The occupancy guard keeps a zone Active while a deployed module references it (e.g. `srvWork` stays Active for nextcloud/nextcloud-hpb/euro-office) — and that is the intended end state, NOT a TODO. Moving a module to another zone is done by **backup data → uninstall → reinstall** in the target zone, never an in-place re-home. A zone that is active with services on a legacy/installed system is never auto-inactivated. (This retires the former "legacy-zone sunset" item — there is no forced migration.)

| # | Deliverable | Notes |
|---|-------------|-------|
| 1 | **SSO finalisation** — (a)+(b) ✅ done | ✅ (a) `install-service.sh` now binds `ALLOW_GROUPS=("users")` (the OIDC claim carries memberships, not the RBAC roles; providesAdminRole adds `<module>-admins`); ✅ (b) `root` Authentik password set (744b0eb). **Remaining (cosmetic):** (c) remove the legacy `tappaas-*` + inert `user`/`admin`/`root` bindings on the live nextcloud app — harmless (empty/inert groups; effective binding is `users`); needs the Authentik UI or a future `app-unbind` CLI (no unbind command today). |
| 2 | **S5 network front-door follow-ups** | ✅ **Physical switch registered (2026-06-23):** controller `unifi-os` (10.0.0.131) → interrogate discovered switch `USW Pro XG 10 PoE` (USWED77, 10.0.0.201, 12 ports, auto via unifi-os) + AP `Nano HD` on port 9. Topology set: port 1→tappaas1, 2→tappaas2, 3→tappaas3 (`node` trunks), port 4→mgmt-console (`uplink`, full trunk). State in `~/config/switch-configuration-{actual,desired}.json` (runtime, not repo). `reconcile --apply` NOT run — the live switch still trunks inactive VLANs 210/230/320 on those ports; applying would prune them to the active set (200,220,310,410,420,430,510,610). ✅ **Manager-driven reconciliation wired (d6c6e92):** renamed the controller exe `switch-manager`→`switch-controller` (matches its dir/role + the ap-controller pattern) so `network-manager reconcile [--only switch] [--apply]` drives the switch plane — the operator never calls the controller directly. Also fixed the test holes that hid the gap (network/test.sh listed stale pre-split bin names; the unit tests mock PlaneClient; the deep test swallowed "not on PATH" as ok) → added a fast plane-bin-resolves assertion + made the deep test hard-fail on ENOENT. **Remaining:** run `network-manager reconcile --only switch --apply` to converge the live switch (prunes inactive 210/230/320); single-front-door consolidation (port `distribute_zones` + delete-preflight fully into network-manager); the parked TS switch-controller pilot (`network/scripts/switch-controller/`) ↔ bash consolidation. |
| 3 | **All-managers-to-TypeScript migration** | The arc items 4–5 build on (people + network are TS; site / environment / module / health / backup are bash). |
| 4 | **Finish the `validate` verb convention** | Port people + network `validate.sh` → a `<manager> validate` TS subcommand and retire the bash; implement a real `validate-module.sh` (currently a stub); reconcile `manager/TEMPLATE` + the P10 contract test once managers are TS. Rides on #3. |
| 5 | **Managers expose CRUD verbs** | add / update / delete / list per manager (people org/group/user/role, site fields + nodes, environments, module config, zones) so admins manage via the CLI and never hand-edit JSON; each write validates first. Rides on #3–#4. |
| 6 | **#294 — zone-aligned VMID ranges** | Derive/allocate a VM's VMID from its zone/environment. Needs the env↔zone model fully settled. |
| 7 | **#380 — document & revalidate the install sequence** | End-to-end fresh-install write-up against the post-cutover reality. Do **last**, so it documents the settled state rather than a moving target. |

> **S8 complete (incl. step 3 — the supervised live firewall→network migration, 2026-06-23):** config/firewall.json→network.json (vmname network), Proxmox VM 110 renamed to `network`, `network.mgmt.internal` added (both it and the `firewall.mgmt.internal` lifeline resolve to 10.0.0.1). Two D5/script leftovers found + fixed (proxy services no longer require configuration.json; migration dns-manager call corrected). Snapshots `pre_network_migration_*` on vmid 110+130. The full hostname switch is a **post-conversion clean-up** (below).

---

## Post-conversion clean-up

Activities that are safe **only once EVERY TAPPaaS system has been converted** (each has run `migrate-firewall-to-network.sh` + the configuration.json cutover). Until then the transition back-compat MUST stay — removing it would break any system still on the old names. Do these as a final sweep, not before.

| Deliverable | Notes |
|-------------|-------|
| **Retire `firewall.mgmt.internal` → `network.mgmt.internal`** | **Fresh installs are now network-primary** (`fb8cc45`): source `network.json` `vmname=network`; the OPNsense bootstrap template sets `<hostname>network</hostname>` + `<althostnames>network.mgmt.internal firewall.mgmt.internal</althostnames>` (registers BOTH; un-updated `FIREWALL_FQDN` scripts resolve via the firewall alias). **Remaining (post-conversion):** re-point the 34 `FIREWALL_FQDN`/`firewall.mgmt.internal` consumers to `network.mgmt.internal`, then drop the `firewall.mgmt.internal` althostname/alias. Also optional: flip already-migrated systems' OPNsense *internal* hostname firewall→network (cosmetic — the migration adds `network.mgmt.internal` as a host override but leaves the internal hostname `firewall`; DNS resolves both either way). |
| **Remove the firewall↔network back-compat** | `resolve_provider_module` firewall↔network alias; `get_module_dir` stale-`.location` follow; update-tappaas `FOUNDATION_LEGACY_NAMES` + `deployed_foundation_name`; the `network.json`/`firewall.json` dual-resolution + `firewall:*` provides/dependsOn aliases in the network service scripts. |
| **Remove the configuration.json back-compat** | The `configuration.json` entry in update-tappaas `NON_MODULE_JSONS`; the residual `.tappaas.*` reads in the legacy `create-configuration.sh`; retire the legacy `create-configuration.sh` / `validate-configuration.sh` / `migrate-configuration.sh` + `migrate-firewall-to-network.sh` migration tooling once no un-migrated system remains. |

> **Why separate:** the items above are *removals of compatibility shims*; running them before every system is converted would strand un-migrated systems. The **Remaining outstanding** items above are forward work that is safe to do now.

---

## Done Work

| Stage | Delivers | Issues | Depends on | Status | Tests (pass/fail) | Commit | Pushed |
|-------|----------|--------|-----------|--------|-------------------|--------|--------|
| **S-TS** | TypeScript pilot (`switch-controller`) | — | none | ✅ GO (qualified) | 47 / 0 (oracle) | (in ADR007 history) | ✅ |
| **S0** | P4-structure: manager/controller skeleton + script moves + dispatchers | #365, #364 | none | ✅ done (all batches; deep gate passed) | cicd --deep 31/2 (only pre-existing); firewall --deep = pre-existing only (11 switch-WIP + proxy-env); PROGRAMS.csv 56/0-nix; 0 dangling | 42df813·876bb2c·86294ba·4573597 | ✅ |
| **S1** | P10 `manager/TEMPLATE/` + `controller/TEMPLATE/` + dispatchers | — | S0 | ✅ done | contract test 25/0; cicd unit 27/0 (Test 10 added); ShellCheck clean | (next commit) | ⏳ |
| **S2** | P1 people-manager (schemas, validate, user-setup, minimal-org, identity-controller, TS people-manager, bootstrap) | #56 | S1, S-TS | ✅ done (closes #56) | people-manager 16 offline + 32 TS unit + 7 live; identity-controller 32 (live); wired-chain dry-run OK | 79ef2c6·e5bd8c3·151d6ac·0c93685·(S2b-4) | ✅ |
| **S3** | P2 site-manager (site.json migration + schema, auto-migrate) | #313 | S1, S2 | ✅ done — S3a + the S3b live cutover complete; create-site.sh (site-native install, D1); configuration.json deleted (Phase D) | site-manager 39/0; fast gate 33/0 (no configuration.json) | 52089c9·06af529·9bddc73 | ✅ |
| **S4** | P3 environment-manager (schema + variant migration + minimal-envs) | #318 | S1, S3 | ✅ mostly — schema + variant→env migration + create-minimal-environments + `--environment` install all done. **Remaining:** CRUD verbs (parked) | env-manager 38/0 | 56a2653·06af529 | ✅ |
| **S5** | network-manager front door (owns zones.json; fold zone-controller/reconcile; controller renames) | #372, #373, #335, #364, #319 | S0 | ✅ mostly — network-manager owns zones.json: zones-init/zones-merge/zones-check/zones-distribute, rename-aware 3-file lifecycle (DA), zone-controller folded, 4-plane reconcile, controller renames. **Remaining:** register physical switch; single-front-door consolidation | network-manager 120/0 + 13/0 | cdf1ee8 (+ADR-008 history) | ✅ |
| **S6** | P6/P7 mgmt-as-environment + default-env selection + legacy-zone sunset | #319 | S4 | ✅ mostly — mgmt-as-environment + default-env selection + the live cutover (N5/P6) done. **Remaining:** legacy-zone sunset (migrate the 3 srvWork-pinned modules → the default zone; parked) | network-manager 99/0; env 38/0 | 879341b·…·06af529 | ✅ |
| **S7** | P5 module updates (tier/source + `--environment`) | #339, #356, #357 | S4, S0 | ✅ done (offline; unblocks P6) | module-manager 45/0; lint 13/0; 18 modules tagged | (next commit) | ⏳ |
| **S8** | P8 firewall→network rename + migration (wide surface; slot ≥ S7) | — | S0, S7 | ✅ done — MODULE renamed firewall→network in source with firewall↔network resolver back-compat; **step 3 live migration done** (config→network.json, VM 110→network, network.mgmt.internal added, firewall.mgmt.internal lifeline kept). Rules plane (`firewall_manager`/`opnsense-firewall`) + the `FIREWALL_FQDN` hostname intentionally KEPT (optional later retirement). | module-manager 47/0; fast gate 35/0; live `update-tappaas --dry` plans `network`; firewall reachable, services up, zones 5/0/0 | 3f587ad·ced4674 | ✅ |
| **S9** | P9 backup hierarchy (backup-manager + backup-controller) | #358 | S3, S4, S1 | ⬜ | — | — | — |

> Suggested order: **S1 → S2 → S3 → S4 → S6**, with **S5** running in parallel (rides on S0), then **S7 → S8 → S9**. S5 unblocks the live #372/#373 switch-fan-out gap early.

---

## Phase D prerequisite tree — retiring `configuration.json` ✅ COMPLETE

**Status (done):** D1 install site.json-native, DA rename-aware zones lifecycle,
D2 people model + retire roles-ensure/user.sh, D3 retire variant-manager + drop all
configuration.json fallbacks, D4 field-defs→schemas, D5 delete configuration.json +
configuration-fields.json. The last runtime reader (the Python `update-tappaas`) was
repointed to `site.json` (caught by the post-delete end-to-end run). Verified WITHOUT
configuration.json: every helper resolves from site.json/environments/cert-refids;
cicd fast gate 33/0; `update-tappaas --force --dry-run` EXIT 0 (full plan,
automaticReboot read from site.json); zones-check 5 ok/0/0; 3 services up; branch
ADR007. Live config keeps backups (configuration.json.bak, a dated .RETIRED copy,
.cutover-backup-*).

**Live people migration — `people-manager sync` DONE.** config/people regenerated to
the new model and synced into Authentik (9 actions, then 0 on re-run = converged):
group `users`, user `lars` = admin+user (root unassigned), user `root` =
admin+user+root. Old-model config/people backed up at `config/people.pre-newmodel-*`.
*Note:* the `root` user has no login password yet (created via API) and `lars` no
longer holds `root` — set root's password in Authentik before relying on it.

**Remaining forward step (not a blocker):** re-bind the deployed SSO apps from the
legacy `tappaas-*` groups to `user`/`admin`/`root` (re-run each module's identity
install/update) + live SSO test. Live SSO still works on the legacy groups until then.

---

### Original ordered plan (for reference)

The reader migration (Phase B) + repoint (B2) are done, but `configuration.json`
cannot be deleted yet: it is still what a **fresh install creates** and several
**live** components depend on it. Ordered work to make the delete safe and
permanent (each step independently gated):

- **D1 — Make the install flow site.json-native.** Today `install2.sh` calls
  `scripts/create-configuration.sh`, which writes `configuration.json`; there is
  **no** site.json creator on a fresh install (the live `site.json` exists only
  because `migrate-configuration.sh` was run during the cutover). Wire the S6
  fresh-install bootstrap: install asks/derives the TAPPaaS system name → writes
  `site.json`, runs `network-manager zones-init`, creates the `mgmt` + default
  environments — instead of writing `configuration.json`. (N5: route install
  through the new managers.) Until this lands, a reinstall regenerates
  `configuration.json` and no `site.json`. **This is the fundamental blocker.**
- **D2+D3 — People/roles + variant→environment migration (SSO-sensitive; design
  decision needed BEFORE coding).** Investigation found two **incompatible** group
  models coexisting:
  - *ADR-006 (`roles-ensure.sh`, LIVE):* creates `tappaas-admins`/`tappaas-users`/
    `tappaas-installers` (prefix = variant, or `tappaas` for the default scope),
    enumerating variants from `configuration.json .tappaas.variants`. **Every SSO
    module's OIDC allow-list uses these exact names** — `identity/services/identity/
    install-service.sh` binds ALLOW_GROUPS = `${PREFIX}-users`, `${PREFIX}-admins`,
    `tappaas-installers`. Called live by `identity/update.sh` + `install-service.sh`.
  - *ADR-007 (`people-manager`, bootstrapped):* reconciles `config/people/groups/*`
    → `test2__admin`/`test2__users` (org-scoped, double-underscore). Different
    groups entirely.

  Naively retiring `roles-ensure` (or renaming the variant scope to the
  environment name) leaves the deployed apps' allow-lists (`tappaas-*`) pointing at
  groups that are no longer created → **SSO access breaks for every app**. So D2+D3
  requires, in order: (a) a **design decision** on the one canonical group model
  (org/people-manager naming vs the deployed ADR-006 allow-list naming) and how the
  environment maps to a group scope; (b) make `identity/install-service.sh` bind
  the canonical groups + have people-manager create them; (c) migrate the LIVE
  Authentik groups + every deployed app's allow-list in lockstep; (d) retire
  `roles-ensure.sh` + `user.sh` + `variant-manager`/`.tappaas.variants`; (e) **live
  SSO test**. This is a focused, design-led, live-tested effort — not a blind code
  change. The system is stable meanwhile (SSO runs on the ADR-006 model; the two
  models coexist).
- **D4 — Migrate the field-definition files to JSON Schemas.** Move
  `module-fields.json`, the zones field definitions (`zones-fields`), and the
  module-catalogue field definitions (`module-catalog`/`module-catalogue-fields`)
  into `src/foundation/schemas/` as JSON Schema 2020-12 documents (matching the
  site/environment/role/etc. schemas), and update **all** references to them.
  `configuration-fields.json` is **not** migrated — it is **deleted** together
  with `configuration.json` in D5.
- **D5 — Delete `configuration.json` + `configuration-fields.json`.** Drop the
  `configuration.json` read-fallbacks across the helpers/readers, finish N5
  routing + P6 mgmt enforcement, then remove both files (rename-aside →
  fast/deep gate → delete, with backups as rollback).

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

### S5 — network-manager (in progress; TypeScript, chunked)
- **Design decisions:** DD1 network-manager = TS orchestrator (S-TS pattern, like people-manager→identity-controller) — owns zones.json (CRUD+delta), reconciles 4 planes by calling plane-controller bins. DD2 switch plane already TS (switch-controller, S-TS pilot). DD3 fixes the latent `zone-reconcile` stale-path bug (it hardcoded `firewall/scripts/{proxmox,switch,ap}-manager` which S0 moved → broken) by calling on-PATH bins. DD4 #372/#373 fix = switch plane reconciled on every zone add/delete (zone-controller.sh omitted it). DD5 deferred to late chunks: zones.json→config/network relocation + proxmox/ap-manager→-controller renames (compat aliases).
- **Chunk 1 (DONE, gated 2026-06-22):** `manager/network-manager/network-manager.ts` (TS, mirrors people-manager: types/zones/planes/reconcile/zonelifecycle/main; PlaneClient interface + fake for tests; Nix-built). CLI: `zone list|exists|get|add|delete`, `reconcile [--apply] [--only <plane>]`. Ports zone-reconcile (4-plane dependency-ordered reconcile, rc 0/2/1 convention) + zone-controller add/delete (+ #372/#373 switch-always fix) + zone-state. Calls on-PATH bins (zone-manager, proxmox-manager, switch-controller, ap-manager). **Gate: tsc clean; nix-build OK; test.sh 34 unit + 6 tiers /0; ShellCheck clean; `network-manager zone list` reads live zones.json; fast gate 32/0 with network smoke.** Legacy zone-reconcile/zone-controller.sh left in place (retired in chunk 4). Noted gap: zone-controller's VM-in-use SSH preflight on delete not yet ported (needs cluster SSH; chunk 3/later).
- **Chunk 3a (DONE, 1b68c85):** fixed network-manager not passing CONFIG_DIR to plane controllers (live read-only dry-run caught it — switch plane errored "CONFIG_DIR is not set"). planes.ts now passes CONFIG_DIR/TAPPAAS_CONFIG. All 4 planes report clean in live dry-run.
- **Chunk 4 (DONE, bc25d31):** zone-reconcile → thin shim exec'ing `network-manager reconcile "$@"` (retires the broken stale-path bash); zone-controller add path now also reconciles switch+ap via network-manager (the #372/#373 live-path fix — no-op until a switch is registered).
- **S5 LIVE DEEP GATE (2026-06-22, cicd --deep) — PASS, no new failures.** 37/2; **network-manager live tier PASSED** (`live: network-manager reconcile --only switch (dry-run) in sync` + zone CRUD); manager/ dispatcher passed; the 2 fails are pre-existing baseline (VM-creation 3/4 = inter-node-VLAN/node-locality installs e.g. test-deb-vlannode→zone srvHome on a non-firewall node = the #372/#373 symptom; ap-controller 16/1 = ADR-008 WIP). Clean VM teardown (0 orphans); tappaas1 up 18h34, mitigation held. **#372/#373 fix is in the code + live-verified non-regressive; the VM-creation symptom persists ONLY because no managed switch is registered (switches:{} empty — hardware/operator step).**
- **S5 remaining (follow-ups, not regressions):** (a) register a physical switch (setup-switches; needs hardware+access) to make the switch fan-out live-effective; (b) single-front-door consolidation — port zone-controller's `distribute_zones_to_nodes` + delete VM-in-use SSH preflight into network-manager, then route zone-controller/variant-manager fully through `network-manager` (currently it calls zone-manager+proxmox directly, only switch/ap via network-manager); (c) deferred: zones.json→config/network, retire zone-controller.sh, drop -manager compat aliases.
- **Chunk 2 (DONE, gated 2026-06-22, 3ae4b19):** `git mv` proxmox-manager→proxmox-controller, ap-manager→ap-controller; each controller install.sh links the new `-controller` bin + a compat `-manager` alias; network-manager planes.ts calls the canonical `-controller` names; fixed the co-located tests to source the renamed files. **Gate: proxmox 8/0, ap 16/1 (pre-existing WIP), network-manager 34/0, fast gate 32/0.** (switch already TS via switch-controller; bash switch-manager left legacy.)
- **Chunks REMAINING (recommend SUPERVISED — live-infrastructure / update-path risk):**
  - **3 — live #372/#373 enablement:** register the physical switch (`setup-switches.sh`; switch-configuration-desired.json is empty), wire `environment-manager`/zone-creation path → `network-manager`, run the VM-provisioning **network deep gate** (off-firewall-node VLAN fan-out — the exact fragile area + the NVMe-incident deep-test). Needs the cluster + a managed switch + supervision.
  - **4 — retire zone-controller/zone-reconcile → delegate to network-manager:** `zone-reconcile` (broken: stale firewall/scripts/ paths; called by pre-update.sh/setup-switches/firewall test) and `zone-controller.sh` (called by variant-manager — the live zone path; network-manager.ts has NOT yet ported its VM-in-use SSH preflight on delete) become thin wrappers. Touches the update path → supervised. Plus PROGRAMS.csv regen + optional zones.json→config/network.
  - **The #372/#373 FIX is in the code** (network-manager always reconciles the switch plane); chunks 3-4 are the live wiring/verification + cleanup.

### S6 — P6/P7 — ✅ TOPOLOGY RESOLVED (operator 2026-06-22); implementation chunked
**Resolved design (install-name `<N>`-driven; network-manager owns the whole zones lifecycle):**
- Install asks the **TAPPaaS system name `<N>`** → `site.json.name`; `<N>` is also the **default zone** name and the **default environment** name (env `<N>.json`, `network.zone:<N>`).
- **Default zone** = the distributed `srv` zone **renamed to `<N>`** (keeps VLAN/config, state Active).
- **Module install:** blank zone defaults to the **default zone `<N>`**, NOT `mgmt` (today's default).
- **Install-time zones transform** (`network-manager zones-init --name <N>`; zones.json is NOT copied verbatim): `srv`→`<N>`; `home`→`<N>-private` (its access-to `srvHome`→`<N>`); `guest`→`<N>-guest`; **Inactive**: `srvHome`,`srvWork`,`srvCust`,`srvDev`,**`work`** (operator: work inactive too); **stay**: `srvTest`,`iot*`,`dmz`,`netbird`,`test`,`mgmt`; + rewrite every `access-to`/zone-ref to a renamed key (referential integrity); idempotent.
- **network-manager owns zones.json end-to-end** (operator direction): the repo **source template moves** `foundation/firewall/zones.json` → `tappaas-cicd/manager/network-manager/zones.json`; **install + update scripts route through network-manager** (no ad-hoc copies/merge scripts); network-manager **distributes zones.json to the nodes whenever it changes it** (port `distribute_zones_to_nodes`); and **every tappaas-cicd update runs a consistency check** of the live zones.json against the installation (`network-manager zones-check`).
**Implementation chunks (N#) — STATUS:**
- **N1 ✅ (879341b)** moved source template firewall/→network-manager/zones.json + repointed all readers.
- **N2 ✅ (c2d731d)** `network-manager zones-init --name <N>` transform (75 tests, offline).
- **N3 ✅ (57624a3)** distribute-on-change (port distribute_zones_to_nodes; auto on live write; --dry-run enumerates the 3 nodes; tests never SSH).
- **N4 ✅ (e0b9e70)** `network-manager zones-check` (well-formed/VLAN-uniq/ref-integrity/mgmt-invariant/installation-consistency) + non-fatal wire into pre-update.sh. Live: 5 ok/0/0. Module configs use `zone0`.
- **N6 ✅ (8d1ea61)** create-minimal-environments `--name <N>` → default env `<N>.json` (zone `<N>`); install-module blank zone0 → default zone (site.name→single-env→mgmt fallback), safe pre/post-cutover.
- **N5 + S3b + P6 = REMAINING = the SUPERVISED LIVE CUTOVER (coupled; partly disruptive):**
  - **⚠ Blocker found by N4:** 3 deployed modules — `nextcloud`, `nextcloud-hpb`, `euro-office` — have `zone0=srvWork`, which zones-init sets **Inactive**. Running the transform on the live system orphans them ⇒ they must be **migrated to the default zone `<N>`** first (VM re-zone: re-IP/VLAN/DNS = service disruption). This is the migrate-legacy-zones step.
  - **N5:** route install2.sh (seed cp → `zones-init --name <N>`, needs the new install-name question) + pre-update (apply-zones-merge → network-manager) fully through network-manager; run zones-init on the live zones.json.
  - **S3b cutover:** switch the ~56 configuration.json readers → site.json (most via common-install-routines helpers); delete configuration.json + configuration-fields.json.
  - **P6 mgmt enforcement** (foundation auto-install to mgmt; can't-delete mandatory) **depends on S7** (P5 module tier/source classification — not yet done).
  - **Recommended:** a dedicated supervised session — it migrates 3 deployed module VMs across zones + deletes the live config + rewires the mothership install/update. All the machinery (N1–N4, N6) is built + tested; this is the "go".

(original analysis retained below)

### S6 — P6/P7 (mgmt / default / legacy-zone-sunset) — original analysis 2026-06-22

**Grounding — live zones.json has TWO tiers of zones:**
- **Client/access zones** (`type: Client/Guest/IoT/DMZ/Overlay/Management/Test`): `home`, `work`, `guest`, `iot*`, `dmz`, `netbird`, `mgmt`, `test` — where devices/users live (e.g. client `home` = 10.3.10.0/24, `access-to: [srvHome,…]`).
- **Service zones** (`type: Service`): `srv`, `srvHome`, `srvWork`, `srvCust`, `srvDev`, `srvTest` — where server *modules* (app VMs) deploy.
All `srv*` zones are still live; there is **no `default` zone** yet (so the S4-migrated `default.json` with `network.zone:"default"` currently dangles / fails validate-environment).

**P6 — mgmt as environment (straightforward).** `mgmt` (Management zone) → `mgmt` env `{name, ownerOrg, network.zone:mgmt}`, no `domains`; created by create-minimal-environments.sh (S4 ✓). Remaining work = **enforcement** in module-manager: foundation modules auto-install to mgmt + cannot delete mandatory (tier:foundation by convention, no `modules` field).

**P7 — default environment (logic clear; zone identity NOT).** Resolution when `--environment` omitted: ① single non-mgmt env→use; ② a `default` env exists→use; ③ module `preferredEnvironment` match→use; ④ else error. Compat: `--variant ""`→default, `--variant foo`→foo, `--environment` wins. **Open:** (a) default env's zone presupposes the **`srv`→`default` zone rename** (not yet done — hence the dangling default.json); (b) rule ② (use `default` if present) vs the test "multi-env requires explicit" — needs the rule "`default` = generic/agnostic services; named envs are always explicit; ④ errors only when no `default` + multiple named"; (c) `preferredEnvironment` is a **new module-side field** not in any schema yet.

**P7 — legacy zone sunset (the genuinely unresolved part).** Table maps **service zones → environments**: `srvHome→home`, `srvWork→work`, `srvCust→{client}`, `srv→default`, principle **"zone name = environment name."** COLLISION: a **client** zone `home` already exists *and* a **service** zone `srvHome` — so a `home` environment named per "zone=env name" points at the client zone, while the thing being sunset is the service zone where modules actually deploy. The design under-specifies one of:
1. **Collapse** client+service into one `home` zone (devices+servers share a segment) — simplest naming but **changes today's client/server separation** security model (`home → access-to srvHome`).
2. **Service-only rename with collision** — sunset `srvHome` into env `home`, but client `home` already owns the name → needs a disambiguation rule the plan doesn't give.
3. **Environments = server/tenancy layer only** (env = where a tenant's modules deploy + its domain = the *service* zone); client/IoT/guest/dmz stay plain network zones, never environments. "zone name = env name" then applies only to tenant/service zones (`srv→default`), and `srvHome` recollides with client `home`.

**Recommendation (to confirm):** intent appears to be **#3** — environments are the tenant/server layer; infra zones (iot/guest/dmz/netbird) are never environments. Decide explicitly how a service zone names its environment when a client zone owns the name (e.g. env `home` → keeps zone `srvHome`, OR client zone renamed, OR env owns both). Then `migrate-legacy-zones.sh` + the default-resolution + the zone-rename fall out cleanly.

**Concrete loose ends for migrate-legacy-zones.sh:** all `srv*` still live (sunset not started); `srv→default` rename owes the default env its zone; any module currently in a `srv*` zone needs an env created + VM/zone migrated; client `home↔srvHome` reach rules rewritten. **Depends:** P3 (S4), P4. Do AFTER S5/S3b.

### S4 — P3 environment-manager (in progress, pulled forward as the cutover prerequisite)
- **Env schema + variant migration (DONE, gated 2026-06-22):** `src/foundation/schemas/environment-fields.json` (JSON Schema 2020-12; rejects authored `tlsCertRefid` per ADR-007c TLS note; mgmt may omit domains); `manager/environment-manager/migrate-variants.sh` (+`migrate-variants-to-environments.sh` alias): `.tappaas.variants` (+legacy `.tappaas.domain`) → `config/environments/<name>.json`, `""`→default.json (domains.primary←domain, domains.dnsMode←dnsMode, network.zone←zone//"default", ownerOrg←first org), **drops tlsCertRefid**, idempotent, `--config-dir`; `create-minimal-environments.sh` (mgmt.json + default.json bootstrap); `validate-environment.sh` (schema + zone∈zones.json + ownerOrg ref + tlsCertRefid reject). **Gate: env-manager test.sh 29/0; ShellCheck clean; live variants→default.json (test2.tapaas.org/wildcard/zone default, tlsCertRefid ABSENT); LIVE config untouched.** This gives domain/dnsMode/zone a home so the configuration.json cutover can proceed. (Remaining S4: environment-manager CRUD + install-module --environment + P6/P7 consumption — after the cutover.)

### S3 — P2 site-manager (in progress)
- **S3a — schema + migration + validate + auto-migrate (DONE, gated 2026-06-22; PHASED):** `src/foundation/schemas/site-fields.json` (JSON Schema 2020-12); `manager/site-manager/migrate-configuration.sh` (+alias `migrate-configuration-to-site.sh`): configuration.json→site.json, idempotent, backs up to `.bak`, **does NOT delete configuration.json**, `--config-dir/--input/--output/--force`. Mapping: name←.tappaas.name|first-domain-label; owner/organizations←config/people/organizations (else ""+warn); location.timezone←system tz (fallback Europe/Amsterdam); country←tz map (fallback NL); hardware.nodes←tappaas-nodes [{name:hostname,storagePools:[]}]; repos/updateSchedule/automaticReboot/snapshotRetention carried; **domain/email/variants/nodeCount DROPPED** (domain/email/variants → environments in S4); environments[]=[] (S4 populates). `validate-site.sh` (jsonschema+jq, readlink-f schema dir). Auto-migrate guard added to pre-update.sh (configuration.json exists && site.json missing → migrate). **Gate: site-manager test.sh 39/0 (FAST, on temp fixtures); ShellCheck clean; fixture migrates to schema-valid site.json (domain/email/variants dropped, nodes mapped); LIVE /home/tappaas/config untouched; cicd Test 11 site smoke green; fast gate 31/0 in 9s.** NOT done: variant→environment (S4); reader cutover + configuration.json deletion + configuration-fields.json retirement (S3b/cutover). #313 stays open.
- **S3b — cutover IN PROGRESS (operator "go" 2026-06-22; step-gated, stop before delete).**
  - **Phase A ✅** pre-flight (cluster quorate, NVMe mitigation active) + backups → `config/.cutover-backup-20260622-180837/` (configuration.json + zones.json) = rollback. `<N>=test2`.
  - **Occupancy-safety ✅ (4a4c238)** zones-init never inactivates an occupied legacy zone (the 3 srvWork modules ⇒ srvWork stays Active; NO VM migration/downtime needed; legacy-zone sunset for them deferred to a future scheduled migration).
  - **Phase C ✅ (LIVE transform, verified non-disruptive):** migrate-configuration → live `site.json` (name/owner test2, validates); `zones-init --name test2` on the LIVE zones.json in place (srv→test2, home→test2-private, guest→test2-guest, empty legacy zones Inactive, **srvWork kept Active**, access-to rewritten) + **distributed to 3/3 nodes**; create-minimal-environments → `test2.json` (default env) + `mgmt.json`, both valid; site.json.environments wired. **Verified: zones-check 5 ok/0/0 (all 11 module refs valid), the 3 services (nextcloud/nextcloud-hpb/euro-office) STILL RUNNING, cicd fast gate 32/0.** System is in a stable DUAL state (configuration.json still authoritative for readers; site.json/environments/renamed-zones live but readers not yet switched).
  - **Phase B REMAINING (reader migration — the thorny prerequisite to delete):** switch the ~56 configuration.json readers → site.json/environments. Field homes to resolve: nodes→site.json hardware.nodes (✓ present); snapshotRetention/automaticReboot/updateSchedule/repositories/version/name→site.json (✓); **domain→the environment's domains.primary** (per-env, reworks service scripts); **email→site.json** (must re-add — migrate dropped it); **tlsCertRefid→OPNsense runtime** (ADR-007c — reworks firewall/proxy+acme, a behaviour change); **`.tappaas.org`** (Create-TAPPaaS-VM.sh + unbound_cli — investigate). Most readers go via common-install-routines.sh helpers (central). Reworks LIVE service scripts → careful.
  - **Phase D REMAINING (after B + a deep gate + operator confirm):** delete configuration.json + configuration-fields.json; N5 route install2/pre-update fully through network-manager; P6 mgmt enforcement (S7 done ⇒ unblocked).
  - **(superseded) earlier PAUSE note below.**

- **S3b — cutover (PAUSED — superseded by the IN PROGRESS entry above; original surface map retained).** Mapped the FULL surface — it's the project's riskiest change (comparable to P8), touching live service-install scripts, node scripts, and Python, with genuine design decisions (not just remaps). **Field map (distinct configuration.json reads):** `variants`(49)→environments; `repositories`(37)→site.json; `domain`(28, in firewall/proxy + identity + apps/nextcloud + hass install/update)→environment `domains.primary` (must resolve *which* env per service); `org`(10, Create-TAPPaaS-VM.sh + unbound_cli)→**investigate semantics**; `updateSchedule`(8)/`snapshotRetention`(2)/`automaticReboot`(2)/`version`(1)/`name`/`displayName`→site.json (✓ present); `tlsCertRefid`(6, **live** firewall/proxy install+update + acme)→**now RUNTIME state per ADR-007c, not config — behaviour change**; `email`(6, setup-caddy/acme Let's-Encrypt)→**needs a home (re-add to site.json as site-wide ACME/admin email)**; `upstreamGit`/`branch`(legacy repo)→already migration-only. **Node fields:** site.json `hardware.nodes[].name` suffices (FQDN = name.mgmt.internal; `ip` only in the retiring validate-configuration.sh). **Zone gap:** default env→zone "default" which isn't in zones.json yet (zone↔env-name alignment is S5/S6) — validate-environment must WARN (not fail) on unknown zone during transition. **State:** env migration + site migration code committed (56a2653, 52089c9); live site.json/environments were created+verified then REMOVED to keep a clean pre-cutover live state (configuration.json intact + authoritative; cicd fast gate 31/0). **Resume:** resolve email-home + tlsCertRefid-runtime + .tappaas.org + per-env domain in service scripts, repoint helpers then service/node/py readers, delete configuration.json + configuration-fields.json, gate on update-tappaas + service installs. #313 stays open.

### S2 — P1 people-manager (in progress)
- **S2a — offline half (DONE, gated 2026-06-22):** 4 JSON-Schema-2020-12 schemas in `src/foundation/schemas/` (role/organization/group/user); `config/people/` seed examples (roles root/admin/user; orgs myOrg/foo-company/bar-company; groups for all three orgs; users admin/jan-de-vries/piet-bakker) — repo `config/` is NOT gitignored and is separate from runtime `/home/tappaas/config/`; `manager/people-manager/minimal-org/` bootstrap with `__ORG__/__USER__/__EMAIL__` placeholders; `user-setup.sh` (copies minimal-org→config/people with substitution + validate); `validate.sh` (jsonschema + jq reference-integrity, jq fallback); `test.sh` (16 offline tests); `install.sh` links user-setup + validate-people into bin. **Gate: people-manager test.sh 16/0; ShellCheck clean; committed examples validate (rc 0).** Subagent added the 2 bar-company groups (the piet-bakker example references them — needed for reference integrity). NOT done in S2a: people-manager.ts CRUD+sync, Nix build, 40-Identity wiring (→ S2b). #56 stays open.
  - **CORRECTION (operator, 2026-06-22):** `config/` ALWAYS means the **target system** `~tappaas/config`, never the repo. The myOrg/foo/bar example JSONs first committed under repo `config/people/` were wrong; relocated to `manager/people-manager/test/fixtures/people/` (test fixtures only), repo `config/` removed, test.sh repointed, and a general "Convention: config/ means the target system" note added to the design doc. Re-gated: people-manager test.sh 16/0.
- **S2b — IN PROGRESS (live-sync vs test-Authentik, operator-approved 2026-06-22).** Authentik is up (identity VM 140; creds `~/.authentik-credentials.txt`). **Architecture decision:** the Authentik **reconcile engine lives in identity-controller (Python)** — reuses the existing `AuthentikManager` httpx client (currently in opnsense-controller, does proxy/OIDC/outpost) rather than duplicating an Authentik client in TS; **people-manager (TS) orchestrates** (config CRUD/validate → invoke identity-controller), matching the ADR's "people-manager calls identity-controller to reconcile" flow. Sub-batches:
  - **S2b-1 (DONE, gated 2026-06-22):** extracted `authentik_manager.py`+`authentik_cli.py`+test (git mv) into new `controller/identity-controller/` Python package (deps httpx only; scripts `authentik-manager` + `identity-controller`); dropped authentik-manager from opnsense-controller's pyproject scripts; added identity-controller build+relink block to pre-update.sh (depth-correct) + `identityController.default` to tappaas-cicd.nix systemPackages; P10 verbs (install builds+relinks, update, test). **Gate: nix-build both packages OK (opnsense no longer ships authentik-manager); `nixos-rebuild test` rc 0 (after `git add` — flakes only see tracked files); authentik-manager + identity-controller bins exec OK; 0 dangling; moved authentik test 26 OK; cicd unit 27/0; ShellCheck clean.**
  - **S2b-2 (DONE, gated 2026-06-22):** identity-controller (Python) PRIMITIVES only (no reconcile policy): CLI subcommands `list-users|list-groups|list-roles|get-user|ensure-user[--inactive]|disable-user|delete-user|ensure-group|ensure-role|add-member|remove-member|assign-role|unassign-role`, each emitting **JSON by default (NO --json flag)**. **Role mapping:** Authentik RBAC roles can't bind to users directly, so a Role = an Authentik core group marked `attributes.tappaas.kind="role"`; "assign role" = group membership; list-groups excludes role-marked, list-roles returns only them. **Gate: nix-build OK; identity-controller test.sh 32/32 (incl 6 LIVE primitive tests scoped to `zztest-`, all cleaned up — 0 residue confirmed); `authentik-manager list-users` emits valid JSON (2 real users).** people-manager.ts (S2b-3) invokes these CLIs (no --json).
  - **S2b-3 (DONE, gated 2026-06-22):** TypeScript people-manager (~1349 LOC; types/config/primitives/reconcile/main + env.d.ts, zero node_modules, S-TS Nix pattern). Reconcile engine implements the 3 concerns + managed-set scoping + role-union (direct ∪ inherited-via-group.roles) + lifecycle (planned/active/suspended/terminated) + dry-run; calls identity-controller primitives via `spawnSync(authentik-manager …)` behind a `PrimitiveClient` interface (fake injected for unit tests). CLI: `people-manager sync [--dry-run] [--config-dir]` + role/org/group/user list/get. **Gate: tsc --noEmit clean; nix-build OK; test.sh = offline 16 + TS unit 32/32 + LIVE integration 7/7 (zztest- scoped, 0 residue in users/groups/roles); dry-run vs fixtures → correct 21-action plan, role inheritance verified (jan-de-vries→admin via foo-company__admins; admin→root+admin union), 0 warnings.**
  - **S2b-4 (DONE, gated 2026-06-22):** wired the people bootstrap into `scripts/rest-of-foundation.sh` (operator direction: NOT the identity module; ADR-007 is authoritative over the old ADR-006/#56 design). After the foundation-modules loop, guarded to first install (config/people empty) + identity not failed: derive org (`.tappaas.name` else first domain label), user (email local-part, slugified), email (`.tappaas.email`) from configuration.json → `user-setup.sh --org --user --email` → `people-manager sync` (→ identity-controller). Idempotent (skips once config/people populated). **Gate: ShellCheck clean; derivation from live config = org=test2/user=lars/email=lars@hrossen.dk; wired chain user-setup→people-manager dry-run produces correct 9-action plan with role inheritance (installer → root direct + admin inherited).** ⇒ **S2 COMPLETE, closes #56.** (Note: user-setup.sh is the plan's name; operator's "setup-users.sh" = same file.)

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
