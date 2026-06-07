#!/usr/bin/env bash
#
# TAPPaaS update -> snapshot-rollback deep test (issue #307)
#
# Verifies the safety net that update-module.sh provides: when an update breaks a
# module, the pre-update snapshot is rolled back and the module returns healthy.
# It exercises BOTH rollback triggers using a throwaway NixOS fixture VM whose
# "functionality" is a single guest-disk sentinel (GOOD/BROKEN):
#
#   Cycle A (Step 5):  update.sh exits non-zero          -> fatal_with_rollback
#   Cycle B (Step 6):  update.sh breaks health, exits 0  -> post-test exit 2 -> rollback
#
# In both cycles the proof is the same: the guest sentinel is BROKEN by the
# update but the disk snapshot still holds GOOD, so after rollback it reads GOOD
# again and the post-rollback test passes. (qm snapshot is disk-only, and the
# disk is exactly what qm rollback restores — the rock-solid invariant.)
#
# This is a DEEP test: it creates and destroys a real VM. Only invoked from
# test.sh when TAPPAAS_TEST_DEEP=1.
#
# Usage: ./test-rollback.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FIXTURE_DIR="${SCRIPT_DIR}/rollback-fixture"

# shellcheck source=../scripts/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=rollback-fixture/lib.sh
. "${FIXTURE_DIR}/lib.sh"

readonly MODULE="rollback-test"
readonly CONFIG_DIR="/home/tappaas/config"
readonly MODE_FILE="/tmp/tappaas-rollback-test.mode"

PASS=0
FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

# Always remove the control file and tear the fixture VM down — no orphans.
cleanup() {
    rm -f "${MODE_FILE}"
    if [[ -f "${CONFIG_DIR}/${MODULE}.json" ]]; then
        info "Cleanup: deleting ${MODULE}..."
        /home/tappaas/bin/delete-module.sh "${MODULE}" --force >/dev/null 2>&1 \
            || warn "Cleanup: delete of ${MODULE} returned non-zero (manual check advised)"
    fi
}
trap cleanup EXIT

# Run one break/rollback cycle and assert the rollback restored health.
#   $1 = mode (fail|test)   $2 = human label
run_cycle() {
    local mode="$1" label="$2"
    local vmid node log rc
    vmid="$(rbt_vmid "${MODULE}")"
    node="$(rbt_node "${MODULE}")"

    info "${BOLD}── Cycle: ${label} (mode=${mode}) ────────────────────${CL}"
    echo "${mode}" > "${MODE_FILE}"

    log="$(mktemp)"
    rc=0
    /home/tappaas/bin/update-module.sh "${MODULE}" >"${log}" 2>&1 || rc=$?
    rm -f "${MODE_FILE}"

    # A successful rollback path ends in `exit 2` (fatal_with_rollback), so a
    # non-zero rc here is the EXPECTED outcome — we assert on the log + state.
    if [[ "${rc}" -eq 2 ]]; then
        pass "${label}: update-module.sh took the fatal-rollback path (exit 2)"
    else
        fail "${label}: update-module.sh exited ${rc} (expected 2 = fatal+rollback)"
        sed 's/^/    /' "${log}" | tail -40
    fi

    if grep -q "Rollback completed" "${log}"; then
        pass "${label}: snapshot rollback completed"
    else
        fail "${label}: no 'Rollback completed' in update log"
        sed 's/^/    /' "${log}" | tail -40
    fi

    if grep -q "Post-rollback tests passed" "${log}"; then
        pass "${label}: post-rollback verification passed"
    else
        fail "${label}: no 'Post-rollback tests passed' in update log"
        sed 's/^/    /' "${log}" | tail -40
    fi
    rm -f "${log}"

    # Independent proof: the live guest sentinel is GOOD again (BROKEN discarded).
    local val
    val="$(rbt_read_sentinel "${vmid}" "${node}")"
    if [[ "${val}" == "GOOD" ]]; then
        pass "${label}: guest sentinel restored to GOOD after rollback"
    else
        fail "${label}: guest sentinel='${val}' after rollback (expected GOOD)"
    fi
}

info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
info "${BOLD}║  update -> rollback deep test: ${BL}${MODULE}${CL}"
info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

# ── Step 0: Clean slate ──────────────────────────────────────────────
info "${BOLD}Step 0: Ensure ${MODULE} is not already deployed${CL}"
rm -f "${MODE_FILE}"
if [[ -f "${CONFIG_DIR}/${MODULE}.json" ]]; then
    warn "  ${MODULE} already deployed — removing it for a clean test"
    /home/tappaas/bin/delete-module.sh "${MODULE}" --force >/dev/null 2>&1 \
        || die "Could not clean pre-existing ${MODULE} — aborting test"
fi
info "  ${GN}✓${CL} clean slate"

# ── Step 1: Install the fixture (healthy GOOD baseline) ──────────────
info "${BOLD}Step 1: install-module.sh ${MODULE}${CL}"
cd "${FIXTURE_DIR}"
if /home/tappaas/bin/install-module.sh "${MODULE}"; then
    pass "fixture installed"
else
    fail "fixture install failed — cannot test rollback"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 1
fi

VMID="$(rbt_vmid "${MODULE}")"
NODE="$(rbt_node "${MODULE}")"
if [[ -z "${VMID}" ]]; then
    fail "module config has no vmid after install"
    exit 1
fi
if [[ "$(rbt_read_sentinel "${VMID}" "${NODE}")" == "GOOD" ]]; then
    pass "baseline guest sentinel = GOOD"
else
    fail "baseline sentinel not GOOD — fixture install did not establish health"
    exit 1
fi

# ── Step 2: Cycle A — update.sh failure (Step-5 rollback) ────────────
run_cycle "fail" "update.sh failure -> Step-5 rollback"

# ── Step 3: Cycle B — broken health caught by post-test (Step-6) ─────
run_cycle "test" "broken health -> Step-6 post-test rollback"

# ── Summary ──────────────────────────────────────────────────────────
info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
