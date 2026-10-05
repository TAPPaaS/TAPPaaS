#!/usr/bin/env bash
#
# storage:nfs — test-service (ADR-029 v0.9). Is each of this consumer's shares
# actually there, from the consumer's own side?
#
#   1. the mount still passes its checks (D11); a pending mount passes as pending,
#      unless its directory is mounted from a share that is gone (D14)
#   2. in the guest, the path is an NFS mount of the declared source (the share
#      alias, D2b) — a share that is available but not mounted because a migration
#      waits for consent fails here, so it is seen
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

target="$(nfs_consumer_target "${CONSUMER}")" || { info "storage:nfs: ${CONSUMER} has no guest — nothing to test"; exit 0; }
while IFS= read -r m <&3; do
    [[ -n "${m}" ]] || continue
    path="$(jq -r .path <<< "${m}")"
    if problems="$(nfs_check_mount "${CONSUMER}" "${m}")"; then :; else
        fail "${path}: ${problems//$'\n'/; }"; continue
    fi
    IFS=$'\t' read -r _ src _ access _ status < <(nfs_resolve_mount "${m}")
    facts="$(nfs_guest_facts "${target}" "${path}")"
    if [[ "${status}" == "pending" ]]; then
        if [[ -n "$(nfs_fact "${facts}" mounted)" ]]; then
            fail "${path}: its share $(jq -r .share <<< "${m}") is no longer declared, yet ${path} is mounted from it (ADR-029 D14)"
        else
            pass "${path}: pending — share $(jq -r .share <<< "${m}") is not declared yet; the directory is local"
        fi
        continue
    fi
    pass "${path}: granted"
    # ls first: an automount only mounts when the path is touched.
    tappaas_ssh_guest -o BatchMode=yes "${target}" "timeout 40 ls '${path}' >/dev/null 2>&1" 2>/dev/null
    facts="$(nfs_guest_facts "${target}" "${path}")"
    live="$(nfs_fact "${facts}" mounted)"
    if [[ "${live}" == "${src}" ]]; then pass "${path}: mounted from ${src}"
    elif [[ -z "${live}" && "$(nfs_fact "${facts}" local)" == "yes" ]]; then
        fail "${path}: share available but not mounted — the directory still holds local data (migration pending: needs consent, ADR-029 D14)"; continue
    else fail "${path}: not mounted from ${src} (found '${live:-nothing}')"; continue; fi
    probe="${path}/.tappaas-nfs-probe-$$"
    if tappaas_ssh_guest -o BatchMode=yes "${target}" "timeout 20 sudo touch '${probe}' 2>/dev/null && sudo rm -f '${probe}'" 2>/dev/null; then
        [[ "${access}" == "rw" ]] && pass "${path}: writable" || fail "${path}: declared ro but writable — the export grants more than the mount asks"
    else
        [[ "${access}" == "ro" ]] && pass "${path}: read-only" || fail "${path}: declared rw but not writable — check the grant and the server's export table"
    fi
done 3< <(nfs_mounts "${CONSUMER}")

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
