#!/usr/bin/env bash
#
# TAPPaaS CI/CD Module Test
#
# Validates the tappaas-cicd foundation module: scripts, binaries,
# configuration, SSH connectivity to cluster nodes, and Python tools.
#
# Called by test-module.sh as the module's own test.sh, or run standalone.
#
# Standard mode: quick sanity checks (~seconds)
# Deep mode:     additionally runs VM creation test suite (~minutes)
#
# Usage: ./test.sh <module-name>
#
# Environment:
#   TAPPAAS_TEST_DEEP=1  Run deep tests (VM creation suite) — or pass --deep
#   TAPPAAS_DEBUG=1      Show debug output
#

set -euo pipefail

# shellcheck source=lib/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEEP="${TAPPAAS_TEST_DEEP:-0}"

# Honour --deep as well as the environment variable. Every "use --deep to run"
# skip below said so already, but only the variable was read, so `test.sh --deep`
# ran the FAST suite while reporting six deep tests as skipped — a run that looks
# deep and is not. Exported, so the dispatched component suites inherit it (the
# same contract test-module.sh --deep and network/test.sh already use).
for _arg in "$@"; do
    case "${_arg}" in
        --deep)     DEEP=1 ;;
        --help|-h)  echo "Usage: $0 [--deep]"; exit 0 ;;
        *)          ;;
    esac
done
[[ "${DEEP}" == "1" ]] && export TAPPAAS_TEST_DEEP=1
PASS=0
FAIL=0
SKIP=0

pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { info "  ${YW}⊘${CL} $1 (skipped)"; SKIP=$((SKIP + 1)); }

# ── Test 1: Required scripts in ~/bin ────────────────────────────────

info "${BOLD}Test 1: Required scripts installed${CL}"

required_scripts=(
    common-install-routines.sh
    copy-update-json.sh
    install-module.sh
    update-module.sh
    delete-module.sh
    test-module.sh
    migrate-vm.sh
    migrate-node.sh
    snapshot-vm.sh
    update-os.sh
    resize-disk.sh
    check-disk-threshold.sh
    setup-caddy.sh
    repository.sh
    create-configuration.sh
)

missing=0
for script in "${required_scripts[@]}"; do
    if [[ ! -f "/home/tappaas/bin/${script}" ]]; then
        fail "Missing: ~/bin/${script}"
        missing=$((missing + 1))
    fi
done
if [[ "${missing}" -eq 0 ]]; then
    pass "All ${#required_scripts[@]} required scripts present in ~/bin"
fi

# ── Test 2: Python CLI tools ────────────────────────────────────────

info "${BOLD}Test 2: Python CLI tools available${CL}"

python_tools=(
    caddy-manager
    opnsense-firewall
#    update-tappaas
)

for tool in "${python_tools[@]}"; do
    if command -v "${tool}" &>/dev/null; then
        pass "${tool} found in PATH"
    else
        fail "${tool} not found in PATH"
    fi
done

# ── Test 3: Configuration files ─────────────────────────────────────

info "${BOLD}Test 3: Configuration files${CL}"

# ADR-007: site.json is the source of truth (configuration.json retired).
if [[ -x /home/tappaas/bin/validate-site.sh ]]; then
    if /home/tappaas/bin/validate-site.sh --quiet 2>/dev/null; then
        pass "site.json passes all validation checks"
    else
        fail "site.json validation failed (run: validate-site.sh)"
    fi
elif [[ -f /home/tappaas/config/site.json ]]; then
    if jq empty /home/tappaas/config/site.json 2>/dev/null; then
        pass "site.json exists and is valid JSON"
    else
        fail "site.json exists but is not valid JSON"
    fi
else
    fail "site.json not found"
fi

if [[ -f /home/tappaas/TAPPaaS/src/foundation/schemas/module-fields.json ]]; then
    if jq -e '.fieldOrder' /home/tappaas/TAPPaaS/src/foundation/schemas/module-fields.json &>/dev/null; then
        pass "module-fields.json has fieldOrder"
    else
        fail "module-fields.json missing fieldOrder"
    fi
else
    fail "module-fields.json not found"
fi

# Verify at least one module config exists (exclude the foundation/system files)
config_count=$(find /home/tappaas/config -maxdepth 1 -name '*.json' \
    -not -name 'configuration.json' -not -name 'site.json' \
    -not -name 'zones.json' -not -name 'zones.json.orig' -not -name 'zones.rename.json' \
    -not -name 'cert-refids.json' | wc -l)
if [[ "${config_count}" -gt 0 ]]; then
    pass "${config_count} module config(s) in ~/config"
else
    fail "No module configs found in ~/config"
fi

# ── Test 4: Git repository ──────────────────────────────────────────

info "${BOLD}Test 4: Git repository${CL}"

if [[ -d /home/tappaas/TAPPaaS/.git ]]; then
    pass "TAPPaaS repository present"
else
    fail "TAPPaaS repository not found at /home/tappaas/TAPPaaS"
fi

if git -C /home/tappaas/TAPPaaS rev-parse --abbrev-ref HEAD &>/dev/null; then
    branch=$(git -C /home/tappaas/TAPPaaS rev-parse --abbrev-ref HEAD)
    pass "On branch: ${branch}"
else
    fail "Cannot determine git branch"
fi

# ── Test 5: SSH connectivity to Proxmox nodes ───────────────────────

info "${BOLD}Test 5: SSH connectivity to Proxmox nodes${CL}"

readonly SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

nodes_reachable=0
for node in $(get_all_node_hostnames); do
    fqdn="${node}.mgmt.internal"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "root@${fqdn}" "true" &>/dev/null; then
        pass "SSH to ${node}"
        nodes_reachable=$((nodes_reachable + 1))
    else
        skip "${node} not reachable"
    fi
done

if [[ "${nodes_reachable}" -eq 0 ]]; then
    fail "No Proxmox nodes reachable via SSH"
fi

# ── Test 6: Cron job ────────────────────────────────────────────────

info "${BOLD}Test 6: Update scheduler (systemd timer)${CL}"

# cron was retired in issue #150; update-tappaas is scheduled by a systemd
# timer declared in tappaas-cicd.nix. Confirm the timer is active and that no
# stale crontab entry survives to re-create a dual scheduler.
if systemctl is-active --quiet update-tappaas.timer; then
    pass "update-tappaas.timer is active"
else
    fail "update-tappaas.timer not active (check tappaas-cicd.nix / nixos-rebuild)"
fi

if crontab -l 2>/dev/null | grep -q "update-tappaas"; then
    fail "stale update-tappaas crontab entry present (cron retired in #150; remove it)"
else
    pass "no legacy update-tappaas cron entry"
fi

# ── Test 7: Repository management ───────────────────────────────────

info "${BOLD}Test 7: Repository management${CL}"

cd "${SCRIPT_DIR}"
if [[ -x test-repository/test.sh ]]; then
    if test-repository/test.sh --skip-network &>/dev/null; then
        pass "Repository management tests passed"
    else
        fail "Repository management tests failed"
    fi
else
    skip "test-repository/test.sh not found"
fi

# ── Test 8: module_exists / install guard (Issue #187) ──────────────

info "${BOLD}Test 8: module_exists installed-detection logic${CL}"

# Unit-test module_exists in isolation: a temp CONFIG_DIR holds fixture
# configs and vm_exists_on_cluster is stubbed, so no cluster is contacted.
me_tmp=$(mktemp -d)
trap 'rm -rf "${me_tmp}"' EXIT

# Fixtures
printf '{"dependsOn":["cluster:vm","backup:vm"],"vmid":140}\n' > "${me_tmp}/vmmod.json"
printf '{"dependsOn":["network:proxy"]}\n'                    > "${me_tmp}/svcmod.json"
printf '{"dependsOn":["cluster:vm"]}\n'                        > "${me_tmp}/novmid.json"

# Helper: run module_exists in a subshell with overridden CONFIG_DIR and a
# stubbed vm_exists_on_cluster ($2 = "found" | "gone"). Echoes the exit code.
me_run() {
    local module="$1" vm_state="$2"
    (
        CONFIG_DIR="${me_tmp}"
        if [[ "${vm_state}" == "found" ]]; then
            vm_exists_on_cluster() { echo "tappaas1"; return 0; }
        else
            vm_exists_on_cluster() { return 1; }
        fi
        module_exists "${module}" >/dev/null 2>&1
    )
}

# (a) No config in CONFIG_DIR => not installed (rc 1)
if ! me_run "ghost" found; then pass "absent config -> not installed"; else fail "absent config should be not installed"; fi

# (b) VM module + VM present on cluster => installed (rc 0)
if me_run "vmmod" found; then pass "vm module + live VM -> installed"; else fail "vm module + live VM should be installed"; fi

# (c) VM module + VM gone => not installed / stale (rc 1)
if ! me_run "vmmod" gone; then pass "vm module + missing VM -> not installed (stale)"; else fail "vm module + missing VM should be not installed"; fi

# (d) Non-VM module + config present => installed (rc 0), never probes cluster
if me_run "svcmod" gone; then pass "non-VM module + config -> installed"; else fail "non-VM module + config should be installed"; fi

# (e) cluster:vm declared but no vmid => trust config, installed (rc 0)
if me_run "novmid" gone; then pass "cluster:vm without vmid -> installed (trust config)"; else fail "cluster:vm without vmid should be installed"; fi

rm -rf "${me_tmp}"
trap - EXIT

# install-module.sh advertises the --force escape hatch
if /home/tappaas/bin/install-module.sh --help 2>&1 | grep -q -- '--force'; then
    pass "install-module.sh --help documents --force"
else
    fail "install-module.sh --help missing --force"
fi

# ── Test 9: snapshot_retention config reader (Issue #353) ───────────

info "${BOLD}Test 9: snapshot_retention reader & cleanup wiring${CL}"

# Unit-test snapshot_retention against a temp site.json (ADR-007: site.json is the
# source; configuration.json retired): configured value is honoured; unset /
# non-integer / zero / missing-file fall back to 5.
sr_tmp=$(mktemp -d)
trap 'rm -rf "${sr_tmp}"' EXIT
sr_run() {
    ( CONFIG_DIR="${sr_tmp}"; snapshot_retention )
}

printf '{"snapshotRetention":3}\n' > "${sr_tmp}/site.json"
[[ "$(sr_run)" == "3" ]] && pass "configured retention honoured (3)" || fail "configured retention should be 3"

printf '{}\n' > "${sr_tmp}/site.json"
[[ "$(sr_run)" == "5" ]] && pass "unset retention -> default 5" || fail "unset retention should default to 5"

printf '{"snapshotRetention":"abc"}\n' > "${sr_tmp}/site.json"
[[ "$(sr_run)" == "5" ]] && pass "non-integer retention -> default 5" || fail "non-integer retention should default to 5"

printf '{"snapshotRetention":0}\n' > "${sr_tmp}/site.json"
[[ "$(sr_run)" == "5" ]] && pass "zero retention -> default 5" || fail "zero retention should default to 5"

rm -f "${sr_tmp}/site.json"
[[ "$(sr_run)" == "5" ]] && pass "missing config file -> default 5" || fail "missing config file should default to 5"

rm -rf "${sr_tmp}"
trap - EXIT

# ── Test 9b: site.json + environments reader cutover (ADR-007 S3b) ──────────
# Unit-tests the central config readers against TEMP fixtures: NEW sources
# (site.json / environments / cert-refids.json) win when present; fall back to
# configuration.json when absent. Never touches the live config or the cluster.
info "${BOLD}Test 9b: site.json/environments reader cutover${CL}"
if [[ -x "${SCRIPT_DIR}/lib/test-config-readers.sh" ]]; then
    if "${SCRIPT_DIR}/lib/test-config-readers.sh" >/dev/null 2>&1; then
        pass "config readers: site.json/environments/cert-refids + configuration.json fallback"
    else
        fail "config-readers cutover test failed (run lib/test-config-readers.sh)"
    fi
else
    skip "lib/test-config-readers.sh not found"
fi

# Test 9c: repo-sync reconciler (forge/branch switch) — the fix for a site.json
# repository url/branch change silently pulling the OLD forge. Temp bare repos only.
info "${BOLD}Test 9c: repo-sync reconcile (forge + branch switch)${CL}"
if [[ -x "${SCRIPT_DIR}/lib/test-repo-sync.sh" ]]; then
    if "${SCRIPT_DIR}/lib/test-repo-sync.sh" >/dev/null 2>&1; then
        pass "repo-sync: re-points origin + checks out branch at new forge tip"
    else
        fail "repo-sync test failed (run lib/test-repo-sync.sh)"
    fi
else
    skip "lib/test-repo-sync.sh not found"
fi

# Test 9d: HA-aware stop/start (#434) — a stop against a slow CRM must be waited
# out and confirmed, and a transition that never happens must fail rather than
# report success. Stubbed cluster only; no ssh, no node, no VM.
info "${BOLD}Test 9d: HA-aware VM stop/start (#434)${CL}"
if [[ -x "${SCRIPT_DIR}/lib/test-ha-vm-lib.sh" ]]; then
    if "${SCRIPT_DIR}/lib/test-ha-vm-lib.sh" >/dev/null 2>&1; then
        pass "ha-vm-lib: CRM stop/start confirmed, timeouts fail loudly"
    else
        fail "ha-vm-lib test failed (run lib/test-ha-vm-lib.sh)"
    fi
else
    skip "lib/test-ha-vm-lib.sh not found"
fi

# Test 9dd: the ADR-020 drift-record runner — what it batches, what it
# dispatches, in what order, and what verdict it returns. Stubbed provider
# callbacks and stub hooks only; no cluster.
info "${BOLD}Test 9dd: converge-lib drift-record runner (ADR-020)${CL}"
if [[ -x "${SCRIPT_DIR}/lib/test-converge-lib.sh" ]]; then
    if "${SCRIPT_DIR}/lib/test-converge-lib.sh" >/dev/null 2>&1; then
        pass "converge-lib: one batched set, migrate last, side effects once, deferral is not failure"
    else
        fail "converge-lib test failed (run lib/test-converge-lib.sh)"
    fi
else
    skip "lib/test-converge-lib.sh not found"
fi

# Test 9e: stale per-service Unbound override pruning (#505) — a wildcard now
# covering a host must have any leftover per-service <host>.<zone> record pruned,
# without ever deleting the shared '*' wildcard. Stubbed unbound-manager only.
info "${BOLD}Test 9e: Unbound stale per-service override pruning (#505)${CL}"
if [[ -x "${SCRIPT_DIR}/lib/test-unbound-prune.sh" ]]; then
    if "${SCRIPT_DIR}/lib/test-unbound-prune.sh" >/dev/null 2>&1; then
        pass "unbound-prune: prunes stale <host>.<zone>, never the '*' wildcard"
    else
        fail "unbound-prune test failed (run lib/test-unbound-prune.sh)"
    fi
else
    skip "lib/test-unbound-prune.sh not found"
fi

# update-module.sh wires cleanup into the success path (prune_snapshots calls
# snapshot-vm.sh --cleanup); guard against the wiring silently disappearing.
if grep -q 'snapshot-vm.sh.*--cleanup' /home/tappaas/bin/update-module.sh; then
    pass "update-module.sh invokes snapshot-vm.sh --cleanup"
else
    fail "update-module.sh no longer invokes --cleanup (snapshot retention unwired)"
fi

# ── Test 10: P10 manager/controller dispatch contract (ADR-007 S1) ───────────

info "${BOLD}Test 10: P10 dispatch contract${CL}"

if [[ -x "${SCRIPT_DIR}/scripts/test/test-dispatch-contract.sh" ]]; then
    if "${SCRIPT_DIR}/scripts/test/test-dispatch-contract.sh" >/dev/null 2>&1; then
        pass "P10 dispatch contract holds (dropped-in component dispatches, TEMPLATE/ skipped)"
    else
        fail "P10 dispatch contract test failed (run scripts/test/test-dispatch-contract.sh)"
    fi
else
    skip "scripts/test/test-dispatch-contract.sh not found"
fi

# ── Test 10b: post-reboot module readiness gate (#468) ───────────────────────
# Offline: temp fixtures only, no VM contact (the port-probe branch needs a live
# guest and is exercised by a real module update instead).

info "${BOLD}Test 10b: module readiness gate${CL}"

if [[ -x "${SCRIPT_DIR}/scripts/test/test-module-ready.sh" ]]; then
    if "${SCRIPT_DIR}/scripts/test/test-module-ready.sh" >/dev/null 2>&1; then
        pass "readiness port list + ready.sh polling behave (module_ready_ports/wait_for_module_ready)"
    else
        fail "module readiness test failed (run scripts/test/test-module-ready.sh)"
    fi
else
    skip "scripts/test/test-module-ready.sh not found"
fi

# ── Test 11: ADR-007 component smoke (lightweight, non-disruptive) ───────────
# A sub-second sanity check that the new ADR-007 components' BASIC functionality
# is present — using the already-built bins. NO compile, NO nix-build, NO live
# Authentik, NO cluster. The components' FULL suites (offline unit tiers + the
# live Authentik tiers) run under --deep via the dispatchers below. Add new
# fast/deep-aware components' smokes here as they land (see tappaas-cicd/README.md).

info "${BOLD}Test 11: ADR-007 component smoke (lightweight)${CL}"

# opnsense-controller + update-tappaas: the linked CLIs load. This is the gate
# that surfaces a broken compiled-component build — pre-update.sh's dispatcher
# deliberately warns-and-continues on build failure (stale bins keep working),
# so a build regression must fail HERE, not block the fleet update.
if [[ -x /home/tappaas/bin/opnsense-controller ]]; then
    if /home/tappaas/bin/opnsense-controller --help >/dev/null 2>&1; then
        pass "opnsense-controller: linked CLI loads"
    else
        fail "opnsense-controller: linked CLI fails to load (broken/stale build)"
    fi
else
    skip "opnsense-controller not installed"
fi
if [[ -x /home/tappaas/bin/update-tappaas ]]; then
    if /home/tappaas/bin/update-tappaas --help >/dev/null 2>&1; then
        pass "update-tappaas: linked CLI loads"
    else
        fail "update-tappaas: linked CLI fails to load (broken/stale build)"
    fi
else
    skip "update-tappaas not installed"
fi

_min_org="${SCRIPT_DIR}/manager/people-manager/minimal-org"
_pm_fix="${SCRIPT_DIR}/manager/people-manager/test/fixtures/people"
# people: schemas + validator work (minimal-org validates) — catches schema breakage
if [[ -x /home/tappaas/bin/validate-people.sh ]]; then
    if /home/tappaas/bin/validate-people.sh --quiet "${_min_org}" >/dev/null 2>&1; then
        pass "people: schemas valid + minimal-org validates"
    else
        fail "people: validate-people on minimal-org failed"
    fi
else
    skip "validate-people.sh not installed"
fi
# people-manager TS bin loads + reads config (no Authentik contact)
if command -v people-manager >/dev/null 2>&1; then
    if people-manager role list --config-dir "${_pm_fix}" >/dev/null 2>&1; then
        pass "people-manager CLI loads + reads config (role list)"
    else
        fail "people-manager role list failed"
    fi
else
    skip "people-manager not installed"
fi
# identity-controller CLI loads
if command -v authentik-manager >/dev/null 2>&1; then
    if authentik-manager --help >/dev/null 2>&1; then
        pass "identity-controller CLI (authentik-manager) loads"
    else
        fail "authentik-manager --help failed"
    fi
else
    skip "authentik-manager not installed"
fi
# site-manager: configuration.json -> site.json migration + schema validation
# (on the fixture, into a temp dir — never the live config)
_site_fix="${SCRIPT_DIR}/manager/site-manager/test/fixtures"
if [[ -x /home/tappaas/bin/migrate-configuration.sh && -f "${_site_fix}/configuration.json" ]]; then
    _st="$(mktemp -d "${TMPDIR:-/tmp}/site-smoke.XXXXXX")"
    cp "${_site_fix}/configuration.json" "${_st}/"
    if /home/tappaas/bin/migrate-configuration.sh --config-dir "${_st}" >/dev/null 2>&1 \
        && /home/tappaas/bin/validate-site.sh --quiet "${_st}/site.json" >/dev/null 2>&1; then
        pass "site: configuration.json -> site.json migrates + validates"
    else
        fail "site: fixture migrate/validate failed"
    fi
    rm -rf "${_st}"
else
    skip "site-manager migrate/validate not installed"
fi
# network-manager TS bin loads + reads zones.json (no reconcile — read-only)
if command -v network-manager >/dev/null 2>&1; then
    if network-manager list >/dev/null 2>&1; then
        pass "network-manager CLI loads + reads zones.json (list)"
    else
        fail "network-manager list failed"
    fi
else
    skip "network-manager not installed"
fi
# backup-manager: cascade resolves on a temp fixture (site 7y -> env 5y -> mod 1y),
# never touching the live config or PBS. Uses the installed TS bin (the legacy
# backup-manager.sh was retired in the ADR-007 post-implementation refactor 7.4).
if command -v backup-manager >/dev/null 2>&1; then
    _bf="$(mktemp -d "${TMPDIR:-/tmp}/backup-smoke.XXXXXX")"
    mkdir -p "${_bf}/environments"
    printf '{"backup":{"target":"pbs1","defaultRetention":"7y"}}\n' > "${_bf}/site.json"
    printf '{"name":"bar","backup":{"retention":"5y"}}\n' > "${_bf}/environments/bar.json"
    printf '{"vmid":210,"environment":"bar","backup":{"retention":"1y"}}\n' > "${_bf}/m.json"
    if [[ "$(backup-manager resolve m --config-dir "${_bf}" | jq -r .retention)" == "1y" ]]; then
        pass "backup-manager: cascade resolves module override (7y->5y->1y)"
    else
        fail "backup-manager: cascade resolution wrong"
    fi
    rm -rf "${_bf}"
else
    skip "backup-manager not present"
fi
# backup-controller: pure-function selftest (no PBS contact)
_bc="${SCRIPT_DIR}/controller/backup-controller/backup-controller"
if [[ -x "${_bc}" ]]; then
    if "${_bc}" --selftest 2>&1 | grep -q "pure-function checks passed"; then
        pass "backup-controller: pure-function selftest passes"
    else
        fail "backup-controller: selftest failed"
    fi
else
    skip "backup-controller not present"
fi

# ── Deep Test: VM creation suite ────────────────────────────────────

if [[ "${DEEP}" -eq 1 ]]; then
    info "${BOLD}Deep Test: VM creation suite${CL}"

    cd "${SCRIPT_DIR}"
    if [[ -x test-vm-creation/test.sh ]]; then
        info "  Running VM creation tests (this takes several minutes)..."
        if test-vm-creation/test.sh; then
            pass "VM creation test suite passed"
        else
            fail "VM creation test suite failed"
        fi
    else
        skip "test-vm-creation/test.sh not found"
    fi

    # ── Deep Test: --reinstall round-trip (issue #301) ───────────────
    info "${BOLD}Deep Test: install-module.sh --reinstall round-trip${CL}"

    if [[ -x test-vm-creation/test-reinstall.sh ]]; then
        info "  Verifying --reinstall deletes then recreates the VM..."
        if test-vm-creation/test-reinstall.sh; then
            pass "--reinstall round-trip test passed"
        else
            fail "--reinstall round-trip test failed"
        fi
    else
        skip "test-vm-creation/test-reinstall.sh not found"
    fi

    # ── Deep Test: update -> snapshot rollback (issue #307) ──────────
    info "${BOLD}Deep Test: update-module.sh snapshot rollback${CL}"

    if [[ -x test-vm-creation/test-rollback.sh ]]; then
        info "  Verifying a broken update rolls back to the pre-update snapshot..."
        if test-vm-creation/test-rollback.sh; then
            pass "update->rollback test passed"
        else
            fail "update->rollback test failed"
        fi
    else
        skip "test-vm-creation/test-rollback.sh not found"
    fi

    # ── Deep Test: vmname -> OPNsense alias length guard (issue #300) ─
    info "${BOLD}Deep Test: vmname alias-name length validation${CL}"

    if [[ -x scripts/test/test-alias-name-validation.sh ]]; then
        if scripts/test/test-alias-name-validation.sh; then
            pass "alias-name length validation test passed"
        else
            fail "alias-name length validation test failed"
        fi
    else
        skip "scripts/test/test-alias-name-validation.sh not found"
    fi

    # ── Deep Test: variant architecture suite (ADR-005 / #316) ───────
    info "${BOLD}Deep Test: variant architecture suite (ADR-005)${CL}"

    if [[ -x test-variants/test.sh ]]; then
        if TAPPAAS_TEST_DEEP=1 test-variants/test.sh; then
            pass "variant architecture suite passed"
        else
            fail "variant architecture suite failed"
        fi
    else
        skip "test-variants/test.sh not found"
    fi

    # ── Deep Test: relocated component dispatchers (ADR-007 S0 P4 3d, option A) ─
    # The cicd module test additionally drives the manager/ + controller/ parent
    # dispatchers, so every relocated component's own test.sh runs as part of the
    # cicd deep gate. Placed in the deep section so the fast unit gate stays green;
    # a known pre-existing component failure (e.g. ap-controller ADR-008 WIP) is
    # judged against the batch baseline ("no NEW failures"), not absolute zero.
    info "${BOLD}Deep Test: manager/ + controller/ component dispatchers${CL}"
    for _disp in manager controller; do
        if [[ -x "${SCRIPT_DIR}/${_disp}/test.sh" ]]; then
            # TAPPAAS_TEST_DEEP=1 so fast/deep-aware components also run their
            # live tiers (Authentik mutation etc.) in the deep gate.
            if TAPPAAS_TEST_DEEP=1 "${SCRIPT_DIR}/${_disp}/test.sh"; then
                pass "${_disp}/ component test dispatcher passed"
            else
                fail "${_disp}/ component test dispatcher reported failures (see above)"
            fi
        else
            skip "${_disp}/test.sh not found"
        fi
    done
else
    info "${BOLD}Deep Test: VM creation suite${CL}"
    skip "VM creation tests (use --deep to run)"
    info "${BOLD}Deep Test: install-module.sh --reinstall round-trip${CL}"
    skip "--reinstall round-trip test (use --deep to run)"
    info "${BOLD}Deep Test: update-module.sh snapshot rollback${CL}"
    skip "update->rollback test (use --deep to run)"
    info "${BOLD}Deep Test: vmname alias-name length validation${CL}"
    skip "alias-name length validation test (use --deep to run)"
    info "${BOLD}Deep Test: variant architecture suite (ADR-005)${CL}"
    skip "variant architecture suite (use --deep to run)"
fi

# ── Deep Test: tracked exec-mode is authoritative (#565) ────────────
# The lifecycle chmod paths must honour the tracked git mode: restore +x on a
# script committed 100755, but never widen a sourced library committed 100644
# (even one carrying a shebang) — widening shows as spurious `git` mode drift on
# the control-plane checkout. Exercises the real ensure_scripts_executable in a
# throwaway git repo, so it asserts behaviour, not just the tracked modes.
info "${BOLD}Deep Test: tracked exec-mode is authoritative (#565)${CL}"
if [[ "${DEEP}" == "1" ]]; then
    _e565="$(mktemp -d)"
    (
        cd "${_e565}" || exit 1
        git init -q && git config user.email t@t && git config user.name t
        printf '#!/usr/bin/env bash\necho run\n' > runme.sh   # genuine executable
        printf '#!/usr/bin/env bash\n: lib\n'    > lib.sh      # sourced lib — has a shebang
        git add runme.sh lib.sh
        git update-index --chmod=+x runme.sh                  # runme.sh tracked 100755
        git commit -qm init
        chmod -x runme.sh lib.sh                              # simulate a mode-losing checkout
    )
    ensure_scripts_executable "${_e565}"
    if [[ -x "${_e565}/runme.sh" ]]; then
        pass "tracked-755 script restored to executable"
    else
        fail "#565: tracked-755 script was left non-executable"
    fi
    if [[ -x "${_e565}/lib.sh" ]]; then
        fail "#565: tracked-644 lib (with shebang) was wrongly widened to 755"
    else
        pass "tracked-644 lib left 644 (no spurious mode drift)"
    fi
    rm -rf "${_e565}"
else
    skip "tracked exec-mode guard (use --deep to run)"
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${SKIP} skipped${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
