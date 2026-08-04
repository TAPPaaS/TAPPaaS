#!/usr/bin/env bash
#
# TAPPaaS Cluster Storage Service - Test (dispatcher)
#
# For each of a module's declared `sharedStorage` entries: confirms the name is
# still registered in some backend's registry (a stale entry — provisioned
# once, then removed via nfs-manager.sh remove or equivalent — is a real
# failure, not a silent no-op), then checks the mount is live on the
# consumer VM (mountpoint -q), a write test if access is rw, and reports
# `df -h`. Mount verification doesn't need to know which backend set it up —
# it's a normal NixOS-managed mount either way — so this dispatcher checks
# directly rather than delegating per backend.
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed (or no 'sharedStorage' entries declared → nothing to test)
#   1  One or more checks failed
#   2  Fatal error
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

check_json "/home/tappaas/config/${MODULE}.json" || exit 2
# shellcheck source=storage-common.sh disable=SC1091
. "${SCRIPT_DIR}/storage-common.sh"

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
ZONE0="$(get_config_value 'zone0' 'mgmt')"
TARGET="${VMNAME}.${ZONE0}.internal"

PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}cluster:storage dispatcher tests for ${BL}${MODULE}${CL} (target: ${TARGET})"

ENTRY_COUNT=$(echo "${JSON}" | jq '(.sharedStorage // []) | length')
if [[ "${ENTRY_COUNT}" -eq 0 ]]; then
    info "    No 'sharedStorage' entries declared — nothing to test"
    exit 0
fi

while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue

    name=$(echo "${entry}" | jq -r '.name')
    mount_point=$(echo "${entry}" | jq -r '.mountPoint')
    access=$(echo "${entry}" | jq -r '.access // "rw"')

    if [[ "${name}" == *"'"* || "${mount_point}" == *"'"* ]]; then
        fail "sharedStorage entry contains a single quote in 'name' or 'mountPoint' — not allowed: ${entry}"
        continue
    fi

    if storage_name_registered "${name}"; then
        pass "share '${name}' is registered (some backend claims it)"
    else
        fail "share '${name}' is not registered in any backend's registry — was it removed?"
        continue
    fi

    info "  Check: share '${name}' at ${mount_point} (${access})"

    if ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "tappaas@${TARGET}" "mountpoint -q '${mount_point}'" 2>/dev/null; then
        pass "${mount_point} is mounted"
    else
        fail "${mount_point} is not mounted"
        continue
    fi

    if [[ "${access}" == "rw" ]]; then
        test_file="${mount_point}/.tappaas-test-${MODULE}"
        if ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
            "tappaas@${TARGET}" \
            "touch '${test_file}' && rm -f '${test_file}'" 2>/dev/null; then
            pass "${mount_point} write test succeeded"
        else
            fail "${mount_point} write test failed (rw share not writable)"
        fi
    fi

    df_line=$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "tappaas@${TARGET}" "df -h '${mount_point}' 2>/dev/null | tail -1") || true
    if [[ -n "${df_line}" ]]; then
        info "    ${df_line}"
    fi
done < <(echo "${JSON}" | jq -c '(.sharedStorage // [])[]')

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
