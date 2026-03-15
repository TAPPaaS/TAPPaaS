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
#   TAPPAAS_TEST_DEEP=1  Run deep tests (VM creation suite)
#   TAPPAAS_DEBUG=1      Show debug output
#

set -euo pipefail

# shellcheck source=scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
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
    inspect-cluster.sh
    inspect-vm.sh
    migrate-vm.sh
    migrate-node.sh
    snapshot-vm.sh
    update-os.sh
    resize-disk.sh
    check-disk-threshold.sh
    setup-caddy.sh
    repository.sh
    create-configuration.sh
    update-cron.sh
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
    update-tappaas
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

if [[ -f /home/tappaas/config/configuration.json ]]; then
    if jq empty /home/tappaas/config/configuration.json 2>/dev/null; then
        pass "configuration.json exists and is valid JSON"
    else
        fail "configuration.json exists but is not valid JSON"
    fi
else
    fail "configuration.json not found"
fi

if [[ -f /home/tappaas/TAPPaaS/src/foundation/module-fields.json ]]; then
    if jq -e '.fieldOrder' /home/tappaas/TAPPaaS/src/foundation/module-fields.json &>/dev/null; then
        pass "module-fields.json has fieldOrder"
    else
        fail "module-fields.json missing fieldOrder"
    fi
else
    fail "module-fields.json not found"
fi

# Verify at least one module config exists
config_count=$(find /home/tappaas/config -name '*.json' -not -name 'configuration.json' | wc -l)
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
for node in tappaas1 tappaas2 tappaas3; do
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

info "${BOLD}Test 6: Update cron job${CL}"

if crontab -l 2>/dev/null | grep -q "update-tappaas"; then
    pass "update-tappaas cron entry present"
else
    fail "update-tappaas cron entry missing (run update-cron.sh)"
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
else
    info "${BOLD}Deep Test: VM creation suite${CL}"
    skip "VM creation tests (use --deep to run)"
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${SKIP} skipped${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
