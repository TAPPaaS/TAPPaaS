#!/usr/bin/env bash
# pvenode test — the node is reachable, Proxmox, in the cluster, and healthy.
#
#   1. root login by the mothership's key works
#   2. it runs Proxmox VE, and calls itself by its instance name
#   3. it is in site.json hardware.nodes, and the cluster it sees is quorate
#   4. its root filesystem is below 90% full
#   5. its clock is synchronised (corosync depends on it)
#   6. (info) a pending reboot — the cluster module's reboot pass takes it
#
# Usage: test.sh <instance>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/pvenode-lib.sh"

PASS=0; FAIL=0
pass() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

pn_load "$1"
info "${BOLD}Testing cluster node ${BL}${INSTANCE}${CL}${BOLD} (${ADDRESS})${CL}"

if ! pn_reachable; then
    fail "root@${ADDRESS} does not accept the mothership's key"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 1
fi
pass "root login by key"

host="$(pn_ssh 'hostname -s' 2>/dev/null)"
pve="$(pn_ssh 'pveversion 2>/dev/null | head -1' 2>/dev/null)"
[[ "${pve}" == pve-manager/* ]] && pass "runs ${pve}" || fail "runs no Proxmox VE"
[[ "${host}" == "${INSTANCE}" ]] && pass "calls itself ${host}" || fail "calls itself '${host}', not '${INSTANCE}'"

pn_site_member "${INSTANCE}" && pass "in site.json hardware.nodes" || fail "not in site.json hardware.nodes"
if pn_ssh "pvecm status 2>/dev/null | grep -qE '^Quorate:[[:space:]]+Yes'"; then pass "cluster quorate"
else fail "the cluster ${INSTANCE} sees is not quorate (pvecm status)"; fi

use="$(pn_ssh "df --output=pcent / | tail -1 | tr -dc '0-9'" 2>/dev/null || true)"
if [[ -z "${use}" ]]; then fail "could not read the root filesystem's usage"
elif (( use < 90 )); then pass "root filesystem ${use}% full"
else fail "root filesystem ${use}% full (limit 90%)"; fi

sync="$(pn_ssh 'timedatectl show -p NTPSynchronized --value' 2>/dev/null || true)"
[[ "${sync}" == "yes" ]] && pass "clock synchronised" || fail "clock not synchronised (NTPSynchronized=${sync:-unknown})"

if pn_ssh 'test -f /var/run/reboot-required'; then
    info "  a reboot is pending — the cluster module's reboot pass takes it"
fi

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -eq 0 ]]
