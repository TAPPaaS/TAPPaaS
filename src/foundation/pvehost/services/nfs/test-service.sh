#!/usr/bin/env bash
#
# pvehost:nfs — test-service (ADR-029, #766). Is each of this consumer's shares
# actually there, from the consumer's own side?
#
#   1. the mount still passes the two-key check against its export (D11)
#   2. in the guest, the path is an NFS mount of the declared source
#   3. an rw mount can write (a probe file, removed again); an ro mount cannot
#
# For a registered, unmanaged server this is the ONLY drift signal TAPPaaS has:
# a server whose export table has fallen behind its descriptor fails here (D2a).
# Read-only apart from the probe file.
#
# Usage: test-service.sh <consumer>
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=nfs-service.sh disable=SC1091
. "${SCRIPT_DIR}/nfs-service.sh"

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { echo "Usage: $0 <consumer>"; exit 2; }
PASS=0; FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

target="$(nfs_consumer_target "${CONSUMER}")" || { info "pvehost:nfs: ${CONSUMER} has no guest — nothing to test"; exit 0; }
while IFS= read -r m; do
    [[ -n "${m}" ]] || continue
    path="$(jq -r .path <<< "${m}")"
    if problems="$(nfs_check_mount "${CONSUMER}" "${m}")"; then pass "${path}: granted"
    else fail "${path}: ${problems//$'\n'/; }"; continue; fi
    IFS=$'\t' read -r _ src _ access _ _ < <(nfs_resolve_mount "${m}")
    # ls first: an automount only mounts when the path is touched.
    live="$(tappaas_ssh_guest -o BatchMode=yes "${target}" \
        "timeout 40 ls '${path}' >/dev/null 2>&1; findmnt -n -t nfs,nfs4 -o SOURCE '${path}'" 2>/dev/null | tail -1)"
    if [[ "${live}" == "${src}" ]]; then pass "${path}: mounted from ${src}"
    else fail "${path}: not mounted from ${src} (found '${live:-nothing}')"; continue; fi
    probe="${path}/.tappaas-nfs-probe-$$"
    if tappaas_ssh_guest -o BatchMode=yes "${target}" "timeout 20 touch '${probe}' 2>/dev/null && rm -f '${probe}'" 2>/dev/null; then
        [[ "${access}" == "rw" ]] && pass "${path}: writable" || fail "${path}: declared ro but writable — the export grants more than the mount asks"
    else
        [[ "${access}" == "ro" ]] && pass "${path}: read-only" || fail "${path}: declared rw but not writable — check the grant and the server's export table"
    fi
done < <(nfs_mounts "${CONSUMER}")

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
