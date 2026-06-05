#!/usr/bin/env bash
#
# TAPPaaS install-module.sh --reinstall round-trip test (issue #301)
#
# Verifies that `install-module.sh <module> --reinstall` DELETES the existing
# VM and then installs a FRESH one (as opposed to --force, which re-runs the
# installers against the *existing* VM without removing it).
#
# Proof of recreation: after the first install we stamp a unique marker into the
# VM's Proxmox `description`. A fresh `qm create` cannot reproduce that random
# string, so its ABSENCE after --reinstall proves the old VM was destroyed and a
# new one built in its place.
#
# This is a DEEP test: it creates and destroys a real VM on the cluster. It is
# only invoked from test.sh when TAPPAAS_TEST_DEEP=1.
#
# Usage: ./test-reinstall.sh [module-name]   (default: test-debian)
#

set -euo pipefail

# shellcheck source=../scripts/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

MODULE="${1:-test-debian}"
readonly MODULE
readonly CONFIG_DIR="/home/tappaas/config"
readonly SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

PASS=0
FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

# Tear the test VM down on exit regardless of outcome (no orphaned test VMs).
cleanup() {
    if [[ -f "${CONFIG_DIR}/${MODULE}.json" ]]; then
        info "Cleanup: deleting ${MODULE}..."
        /home/tappaas/bin/delete-module.sh "${MODULE}" --force >/dev/null 2>&1 \
            || warn "Cleanup: delete of ${MODULE} returned non-zero (manual check advised)"
    fi
}
trap cleanup EXIT

# Resolve the module's vmid/node from its installed config.
module_vmid() { read_module_config "${MODULE}" 2>/dev/null | jq -r '.vmid // empty'; }
module_node() {
    local n
    n=$(read_module_config "${MODULE}" 2>/dev/null | jq -r '.node // empty')
    [[ -z "${n}" ]] && n="$(get_node_hostname 0)"
    echo "${n}"
}

# Read a VM's Proxmox description (decoded enough for a plain marker match).
vm_description() {
    local vmid="$1" node="$2"
    # shellcheck disable=SC2029,SC2086  # vmid expands locally; SSH_OPTS split on purpose
    ssh ${SSH_OPTS} "root@${node}.mgmt.internal" "qm config ${vmid}" 2>/dev/null \
        | sed -n 's/^description: //p'
}

info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
info "${BOLD}║  --reinstall round-trip test: ${BL}${MODULE}${CL}"
info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

cd "${SCRIPT_DIR}"

# ── Step 0: Clean slate ──────────────────────────────────────────────
info "${BOLD}Step 0: Ensure ${MODULE} is not already deployed${CL}"
if [[ -f "${CONFIG_DIR}/${MODULE}.json" ]]; then
    warn "  ${MODULE} already deployed — removing it for a clean test"
    /home/tappaas/bin/delete-module.sh "${MODULE}" --force >/dev/null 2>&1 \
        || die "Could not clean pre-existing ${MODULE} — aborting test"
fi
info "  ${GN}✓${CL} clean slate"

# ── Step 1: First install ────────────────────────────────────────────
info "${BOLD}Step 1: install-module.sh ${MODULE}${CL}"
if /home/tappaas/bin/install-module.sh "${MODULE}"; then
    pass "first install succeeded"
else
    fail "first install failed — cannot test --reinstall"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 1
fi

VMID="$(module_vmid)"
NODE="$(module_node)"
if [[ -z "${VMID}" ]]; then
    fail "module config has no vmid after install"
    exit 1
fi

if vm_exists_on_cluster "${VMID}" "${NODE}.mgmt.internal" >/dev/null; then
    pass "VM ${VMID} exists on cluster after first install"
else
    fail "VM ${VMID} not found on cluster after first install"
    exit 1
fi

# ── Step 2: Stamp a unique marker on the live VM ─────────────────────
info "${BOLD}Step 2: Stamp recreation marker on VM ${VMID}${CL}"
MARKER="TAPPAAS-REINSTALL-MARKER-$(date +%s)-$$-${RANDOM}"
# shellcheck disable=SC2029,SC2086  # vmid/marker expand locally; SSH_OPTS split on purpose
if ssh ${SSH_OPTS} "root@${NODE}.mgmt.internal" \
        "qm set ${VMID} --description '${MARKER}'" >/dev/null 2>&1 \
   && [[ "$(vm_description "${VMID}" "${NODE}")" == *"${MARKER}"* ]]; then
    pass "marker stamped on VM ${VMID} (${MARKER})"
else
    fail "could not stamp marker on VM ${VMID} — cannot prove recreation"
    exit 1
fi

# ── Step 3: Reinstall ────────────────────────────────────────────────
info "${BOLD}Step 3: install-module.sh ${MODULE} --reinstall${CL}"
REINSTALL_LOG="$(mktemp)"
if /home/tappaas/bin/install-module.sh "${MODULE}" --reinstall >"${REINSTALL_LOG}" 2>&1; then
    pass "--reinstall completed successfully"
else
    fail "--reinstall returned non-zero (see output below)"
    sed 's/^/    /' "${REINSTALL_LOG}" | tail -30
fi

# (a) The reinstall must have deleted the existing deployment first.
if grep -q -- "deleting it first (--reinstall)" "${REINSTALL_LOG}"; then
    pass "--reinstall deleted the existing deployment before installing"
else
    fail "--reinstall did not log a pre-install delete step"
fi
rm -f "${REINSTALL_LOG}"

# (b) A VM must exist again (re-read config in case vmid/node changed).
VMID="$(module_vmid)"
NODE="$(module_node)"
if [[ -n "${VMID}" ]] && vm_exists_on_cluster "${VMID}" "${NODE}.mgmt.internal" >/dev/null; then
    pass "VM ${VMID} exists on cluster after --reinstall (reinstalled)"
else
    fail "no VM on cluster after --reinstall — module was not reinstalled"
fi

# (c) The marker must be GONE — proving the old VM was destroyed, not reused.
if [[ -n "${VMID}" ]]; then
    CURRENT_DESC="$(vm_description "${VMID}" "${NODE}")"
    if [[ "${CURRENT_DESC}" != *"${MARKER}"* ]]; then
        pass "recreation marker absent — VM was deleted and recreated (not reused)"
    else
        fail "recreation marker still present — VM was REUSED, not recreated"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────
info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
