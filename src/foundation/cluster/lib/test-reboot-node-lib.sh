#!/usr/bin/env bash
#
# test-reboot-node-lib.sh — unit test for reboot_one_node's drain-timeout path (#507).
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

echo "  Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
