#!/usr/bin/env bash
# debianhost test — the machine is reachable, Debian, and healthy (ADR-026 D3).
#
#   1. root login by the mothership's key works
#   2. it runs Debian
#   3. no reboot is pending
#   4. its root filesystem is below 90% full
#   5. its clock is synchronised
#   6. (info) how many package upgrades are waiting — not a failure: new ones are
#      published every day, and the next update takes them
#
# In the pre-update gate (TAPPAAS_TEST_RUNTIME_ONLY=1) a pending reboot is
# reported, not failed: the update is what takes it, so failing would block it.
#
# Usage: test.sh <instance>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/debianhost-lib.sh"

PASS=0; FAIL=0; SKIP=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { info "  ${YW}⊘${CL} $1 (skipped)"; SKIP=$((SKIP + 1)); }

dh_load "$1"
info "${BOLD}Testing ${BL}${INSTANCE}${CL}${BOLD} (${ADDRESS})${CL}"

if ! dh_reachable; then
    fail "root@${ADDRESS} does not accept the mothership's key"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${SKIP} skipped${CL}"
    exit 1
fi
pass "root login by key"

id="$(dh_os_id)"
[[ "${id}" == "debian" ]] && pass "runs Debian" || fail "runs '${id:-unknown}', not Debian"

if dh_ssh 'test -f /var/run/reboot-required'; then
    if [[ "${TAPPAAS_TEST_RUNTIME_ONLY:-0}" == "1" ]]; then
        skip "a reboot is pending — the update takes it when authorized"
    else
        fail "a reboot is pending (/var/run/reboot-required) — run: module-manager module update ${INSTANCE} --allow-disruption"
    fi
else
    pass "no reboot pending"
fi

use="$(dh_ssh "df --output=pcent / | tail -1 | tr -dc '0-9'" 2>/dev/null || true)"
if [[ -z "${use}" ]]; then fail "could not read the root filesystem's usage"
elif (( use < 90 )); then pass "root filesystem ${use}% full"
else fail "root filesystem ${use}% full (limit 90%)"; fi

sync="$(dh_ssh 'timedatectl show -p NTPSynchronized --value' 2>/dev/null || true)"
[[ "${sync}" == "yes" ]] && pass "clock synchronised" || fail "clock not synchronised (NTPSynchronized=${sync:-unknown})"

waiting="$(dh_ssh "apt list --upgradable 2>/dev/null | grep -c '/' || true" 2>/dev/null || echo '?')"
info "  ${waiting} package upgrade(s) waiting for the next update"

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}, ${YW}${SKIP} skipped${CL}"
[[ "${FAIL}" -eq 0 ]]
