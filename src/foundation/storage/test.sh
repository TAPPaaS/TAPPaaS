#!/usr/bin/env bash
#
# storage test (ADR-029 v0.9).
#
#   fast (always)  the share model's unit suite (lib/test-nfs-lib.sh): offline
#   live           config/shares.json passes storage-manager's validation, and each
#                  share's alias follows its server
#   --deep         the end-to-end NFS suite (lib/test-nfs-deep.sh) against a real
#                  node — a disposable consumer, a throwaway share declared through
#                  storage-manager, and a teardown that leaves nothing behind (about
#                  25 minutes; never in the sweep). The node is --node <instance>, else
#                  the first node that has tankb1.
#
# Usage: test.sh [<instance>] [--deep] [--node <instance>]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEEP=0; NODE=""
args=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --deep) DEEP=1; shift ;;
        --node) NODE="${2:?--node needs an instance}"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
[[ "${TAPPAAS_TEST_DEEP:-}" == "1" ]] && DEEP=1
set --
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/nfs-lib.sh"
. "${HERE}/lib/nfs-converge.sh"

PASS=0; FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

info "${BOLD}Testing storage${CL}"
if out="$("${HERE}/lib/test-nfs-lib.sh" 2>&1)"; then pass "share model unit suite ($(tail -1 <<< "${out}" | tr -s ' '))"
else fail "share model unit suite:"; printf '%s\n' "${out}" | grep -E "FAIL" | head -10 >&2; fi

if [[ -f "${CONFIG_DIR}/shares.json" ]]; then
    if out="$(storage-manager validate 2>&1)"; then pass "config/shares.json is valid"
    else fail "config/shares.json: ${out//$'\n'/; }"; fi
    while IFS= read -r s; do
        [[ -n "${s}" ]] || continue
        name="$(jq -r .name <<< "${s}")"; server="$(jq -r .server <<< "${s}")"
        read -r host domain < <(nfs_alias_target "${server}")
        cur="$(nfs_alias_list | awk -v a="$(nfs_share_alias "${name}")" '$1 == a {print $2}')"
        [[ "${cur}" == "${host}.${domain}" ]] && pass "share ${name}: its alias follows ${server}" \
            || fail "share ${name}: its alias follows '${cur:-nothing}', not ${host}.${domain}"
    done < <(nfs_shares)
fi

if [[ "${DEEP}" -eq 1 ]]; then
    if [[ -z "${NODE}" ]]; then
        for n in $(tappaas_cluster_nodes "${CONFIG_DIR}"); do
            ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@$(jq -r '.address // empty' "${CONFIG_DIR}/${n}.json")" \
                "zpool list -H -o name tankb1" >/dev/null 2>&1 && { NODE="${n}"; break; }
        done
        NODE="${NODE:-$(tappaas_cluster_nodes "${CONFIG_DIR}" | head -1)}"
    fi
    if "${HERE}/lib/test-nfs-deep.sh" "${NODE}"; then pass "NFS deep suite on ${NODE}"
    else fail "NFS deep suite on ${NODE} (above)"; fi
fi

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
