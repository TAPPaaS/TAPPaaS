# tappaas-cicd — tests

## How to run
- Fast: `./test.sh <module-name>` (or via `test-module.sh tappaas-cicd`). Takes seconds.
- Deep: `TAPPAAS_TEST_DEEP=1 ./test.sh tappaas-cicd` — gated solely on the `TAPPAAS_TEST_DEEP` env var (no `--deep` flag in this script). Takes minutes (creates real VMs).
- `TAPPAAS_DEBUG=1` adds debug output.
- Prerequisites: sources `/home/tappaas/bin/common-install-routines.sh`; needs `jq` and the toolbox bins on PATH. Several Standard tests degrade to skip when an optional bin (e.g. `people-manager`, `authentik-manager`, `network-manager`, `validate-people.sh`, `migrate-configuration.sh`) is not installed. SSH reachability to Proxmox nodes is exercised but a single reachable node suffices.

## Standard (fast) tests
- **Test 1: Required scripts installed** — asserts all 17 core `~/bin` scripts exist (install/update/delete/test-module.sh, inspect/migrate/snapshot/resize helpers, setup-caddy, repository, create-configuration, common-install-routines, copy-update-json).
- **Test 2: Python CLI tools available** — `caddy-manager` and `opnsense-firewall` resolve on PATH (`update-tappaas` is commented out).
- **Test 3: Configuration files** — runs `validate-site.sh --quiet` (ADR-007: `site.json` is source of truth; falls back to JSON-valid check if validator absent); `module-fields.json` has `.fieldOrder`; at least one real module config exists in `~/config` (excluding foundation/system files).
- **Test 4: Git repository** — TAPPaaS repo present and current branch resolvable.
- **Test 5: SSH connectivity to Proxmox nodes** — SSH to each node from `get_all_node_hostnames`; fails only if zero nodes reachable (per-node unreachable is a skip).
- **Test 6: Update scheduler (systemd timer)** — `update-tappaas.timer` is active AND no legacy `update-tappaas` crontab entry survives (cron retired #150).
- **Test 7: Repository management** — runs `test-repository/test.sh --skip-network`.
- **Test 8: module_exists installed-detection logic (#187)** — unit-tests `module_exists` in isolation (temp CONFIG_DIR fixtures, stubbed `vm_exists_on_cluster`, no cluster contact): absent config→not installed; VM module + live VM→installed; VM module + VM gone→stale/not installed; non-VM module→installed without probing; `cluster:vm` without vmid→trust config. Also asserts `install-module.sh --help` documents `--force`.
- **Test 9: snapshot_retention reader & cleanup wiring (#353)** — unit-tests `snapshot_retention` against temp `site.json` (configured value honoured; unset/non-integer/zero/missing-file all fall back to 5).
- **Test 9b: site.json/environments reader cutover (ADR-007 S3b)** — runs `lib/test-config-readers.sh` (NEW site.json/environments/cert-refids sources win, configuration.json fallback); asserts `update-module.sh` still invokes `snapshot-vm.sh --cleanup`.
- **Test 10: P10 template/dispatch contract (ADR-007 S1)** — runs `scripts/test/test-template-contract.sh` (TEMPLATE skipped, manager has validate.sh, scaffold dispatches).
- **Test 11: ADR-007 component smoke (lightweight, non-disruptive)** — sub-second sanity using already-built bins, NO compile/nix-build/live-Authentik/cluster: people schemas + `validate-people.sh` on minimal-org; `people-manager role list` loads + reads config; `authentik-manager --help` (identity-controller) loads; site-manager `migrate-configuration.sh`→`validate-site.sh` on a temp fixture; `network-manager zone list` reads zones.json read-only; `backup-manager resolve` cascade (site 7y→env 5y→mod 1y) on a temp fixture; `backup-controller --selftest` pure-function checks. Each degrades to skip if the bin is absent.

## Deep tests (live; TAPPAAS_TEST_DEEP=1)
- **VM creation suite** — runs `test-vm-creation/test.sh` (real VM creation, several minutes). Exercises live Proxmox.
- **install-module.sh --reinstall round-trip (#301)** — `test-vm-creation/test-reinstall.sh`: verifies `--reinstall` deletes then recreates the VM.
- **update-module.sh snapshot rollback (#307)** — `test-vm-creation/test-rollback.sh`: a broken update rolls back to the pre-update snapshot.
- **vmname → OPNsense alias length validation (#300)** — `scripts/test/test-alias-name-validation.sh`.
- **variant architecture suite (ADR-005 / #316)** — `test-variants/test.sh` run with `TAPPAAS_TEST_DEEP=1`.
- **manager/ + controller/ component dispatchers (ADR-007 S0)** — drives `manager/test.sh` and `controller/test.sh` with `TAPPAAS_TEST_DEEP=1`, so every relocated component's own test.sh (offline unit tiers + live Authentik/PBS tiers) runs under the cicd deep gate. Judged against a batch baseline ("no NEW failures") — a known pre-existing failure (e.g. ap-controller ADR-008 WIP) does not fail the gate.
- Without the deep tier, the entire VM lifecycle (create/reinstall/rollback), variant architecture, and the full manager/controller component suites are unverified — fast mode only smoke-loads their bins.

## Coverage notes
- This is the mothership's own module test; it heavily exercises config **readers** and bin **presence/load**, but the live install/lifecycle flows are deep-only.
- Test 11 component checks are deliberately shallow (load + read-only + temp-fixture resolution); they catch schema breakage and missing bins but do NOT exercise live Authentik, PBS, OPNsense, or the cluster — those live tiers run only inside each component's own suite under the deep gate.
- Many Standard tests skip silently when an optional bin is missing, so a passing fast run does not guarantee every ADR-007 component is installed.
- `update-tappaas` (Python) is excluded from Test 2 (commented out) — not tested here.
