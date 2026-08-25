#!/usr/bin/env bash
#
# test-reboot-node-lib.sh — unit tests for reboot_one_node's maintenance-mode paths.
#
# Drives reboot_one_node to the HA-migration timeout with stubbed cluster calls
# (no ssh, no Proxmox, no waiting) and asserts it DISABLES HA maintenance mode
# before returning — restoring the pre-attempt state instead of stranding the
# node in maintenance — and that it does NOT proceed to reboot on that path.
#
# Usage: ./test-reboot-node-lib.sh   Exit: 0 all passed, 1 otherwise.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colour vars + logging stubs so the lib can be sourced standalone under set -u.
BOLD=""; GN=""; CL=""; YW=""; RD=""; BL=""
: "${BOLD}${GN}${CL}${YW}${RD}${BL}"  # referenced by the sourced lib, not here
info()  { :; }
debug() { :; }
warn()  { echo "WARN: $*" >&2; }
error() { echo "ERR: $*"  >&2; }
die()   { echo "DIE: $*"  >&2; exit 1; }

# shellcheck source=reboot-node-lib.sh disable=SC1091
. "${SCRIPT_DIR}/reboot-node-lib.sh"

PASS=0
FAIL=0
pass() { echo "  ok: $*";   PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SSH_LOG="${WORK}/ssh.log"; : > "${SSH_LOG}"

# ── Stubs: quorum OK, drain never completes, record every ssh command ──
sleep() { :; }                                   # no real waiting
rn_ha_active_count()       { echo 2; }           # quorum OK (>=2)
rn_latest_kernel()         { echo "6.1.0-test"; }
rn_node_fqdn()             { echo "$1"; }
havm_ha_services_on_node() { echo "vm:100"; }    # a VM never drains off → timeout
rn_node_ssh() { shift; printf '%s\n' "$*" >> "${SSH_LOG}"; return 0; }

# ── Drive it ─────────────────────────────────────────────────────────
reboot_one_node "testnode" >/dev/null 2>&1 && rc=0 || rc=$?

if [[ "${rc}" -ne 0 ]]; then
    pass "reboot_one_node returns non-zero on drain timeout"
else
    fail "reboot_one_node should return non-zero on drain timeout (got ${rc})"
fi

if grep -q 'node-maintenance disable testnode' "${SSH_LOG}"; then
    pass "drain timeout disables HA maintenance mode (#507)"
else
    fail "drain timeout did NOT disable maintenance mode — node stranded (#507); ssh log: $(tr '\n' ';' < "${SSH_LOG}")"
fi

if grep -qx 'reboot' "${SSH_LOG}"; then
    fail "drain timeout must NOT reboot the node"
else
    pass "drain timeout does not reboot the node"
fi


# ── Post-reboot maintenance-disable scenarios ────────────────────────
#
# A node that reboots and never leaves maintenance mode sits out of HA
# placement indefinitely. It used to be reported as a successful reboot, which
# hid exactly that for 13 hours (2026-08-25). Each scenario runs in a subshell
# so it can carry its own stubs.
#
# `state` holds the simulated LRM line; the rn_node_ssh stub answers
# `ha-manager status` from it, so membership and the maintenance flag are
# observable the same way the real code observes them.

# Shared stubs for a node that drains and reboots cleanly.
scenario_common() {
    rn_ha_active_count()          { echo 2; }
    rn_latest_kernel()            { echo "6.1.0-test"; }
    rn_running_kernel()           { echo "6.1.0-test"; }
    rn_node_fqdn()                { echo "$1"; }
    havm_ha_services_on_node()    { echo ""; }      # drains immediately
    rn_wait_for_node()            { return 0; }     # comes back on the first probe
    rn_sweep_cloudinit_orphans()  { :; }
    rn_wait_ha_settled()          { return 0; }
    RN_CLUSTER_WAIT_MAX=10
    RN_MAINT_DISABLE_TRIES=2
}

# A: node rejoins and the disable takes effect → success, flag cleared.
(
    scenario_common
    STATE="${WORK}/a.state"; echo "maintenance mode" > "${STATE}"
    LOG="${WORK}/a.log"; : > "${LOG}"
    rn_node_ssh() {
        local node="$1"; shift
        printf '%s\n' "$*" >> "${LOG}"
        case "$*" in
            *"ha-manager status"*) echo "lrm ${node} ($(cat "${STATE}"), watchdog)" ;;
            *"node-maintenance disable"*) echo "active" > "${STATE}" ;;
        esac
        return 0
    }
    reboot_one_node "testnode" >/dev/null 2>&1 && rc=0 || rc=$?
    [[ "${rc}" -eq 0 ]] && grep -q "active" "${STATE}"
) && pass "clean reboot clears maintenance mode and returns 0" \
  || fail "clean reboot should clear maintenance and return 0"

# B: node reboots but never rejoins the cluster → non-zero, and the HA stack is
# never touched (the disable must not be attempted against a non-member).
(
    scenario_common
    LOG="${WORK}/b.log"; : > "${LOG}"
    rn_node_ssh() {
        local node="$1"; shift
        printf '%s\n' "$*" >> "${LOG}"
        # `ha-manager status` answers, but never lists this node's LRM.
        case "$*" in *"ha-manager status"*) echo "lrm othernode (active, watchdog)" ;; esac
        return 0
    }
    reboot_one_node "testnode" >/dev/null 2>&1 && rc=0 || rc=$?
    [[ "${rc}" -ne 0 ]] && ! grep -q 'node-maintenance disable' "${LOG}"
) && pass "node that never rejoins the cluster fails the reboot, no HA call made" \
  || fail "a node that never rejoins must fail the reboot without calling ha-manager"

# C: the regression under test. The node is a member, but the disable is
# rejected every time (as `no such cluster node` did) and the flag never
# clears. This MUST fail the reboot rather than warn and report success.
(
    scenario_common
    STATE="${WORK}/c.state"; echo "maintenance mode" > "${STATE}"
    LOG="${WORK}/c.log"; : > "${LOG}"
    rn_node_ssh() {
        local node="$1"; shift
        printf '%s\n' "$*" >> "${LOG}"
        case "$*" in
            *"ha-manager status"*) echo "lrm ${node} ($(cat "${STATE}"), watchdog)" ;;
            *"node-maintenance disable"*) echo "no such cluster node '${node}'" ;;  # never clears
        esac
        return 0
    }
    reboot_one_node "testnode" >/dev/null 2>&1 && rc=0 || rc=$?
    [[ "${rc}" -ne 0 ]] && [[ "$(grep -c 'node-maintenance disable' "${LOG}")" -ge 2 ]]
) && pass "a disable that never takes effect fails the reboot (and is retried)" \
  || fail "a stuck maintenance flag must fail the reboot, not warn"

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
