#!/usr/bin/env bash
# debianhost update — keep the machine's OS patched (ADR-026 D3).
#
# apt update + full-upgrade, non-interactive, keeping local configuration files.
# A reboot the upgrade asks for (/var/run/reboot-required) is taken only when it
# is AUTHORIZED — the rule a cluster node follows (ADR-020 D8):
#
#   authorized = this run allows disruption (--allow-disruption, which the
#                module-manager passes as TAPPAAS_ALLOW_DISRUPTION=1)
#             or rebootOk=true in the scheduled pass (TAPPAAS_SCHEDULED_PASS=1)
#
# Otherwise the reboot is DEFERRED and reported with a machine-parseable
# "DEFERRED:" line, which the sweep collects into its result. Not rebooting is
# not a failure.
#
# Usage: update.sh <instance>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
. "${HERE}/lib/debianhost-lib.sh"

dh_load "$1"
dh_reachable || die "cannot log in to root@${ADDRESS} with the mothership's key"

info "${BOLD}Updating packages on ${BL}${INSTANCE}${CL}${BOLD} (${ADDRESS})${CL}"
if ! out="$(dh_ssh 'export DEBIAN_FRONTEND=noninteractive
    apt-get -q update >/dev/null &&
    apt-get -q -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade' 2>&1)"; then
    printf '%s\n' "${out}" >&2
    die "apt full-upgrade failed on ${INSTANCE}"
fi
while IFS= read -r _l; do debug "  ${_l}"; done <<< "${out}"
upgraded="$(grep -oE '^[0-9]+ upgraded' <<< "${out}" | grep -oE '^[0-9]+' || echo 0)"
info "  ${GN}✓${CL} ${upgraded} package(s) upgraded"

dh_ssh 'test -f /var/run/reboot-required' || { info "${GN}✓${CL} ${INSTANCE} up to date — no reboot needed"; exit 0; }

reboot_ok="$(get_config_value 'rebootOk' 'false')"
if [[ "${TAPPAAS_ALLOW_DISRUPTION:-0}" != "1" && ! ( "${reboot_ok}" == "true" && "${TAPPAAS_SCHEDULED_PASS:-0}" == "1" ) ]]; then
    # Machine-parseable: update-tappaas collects DEFERRED: lines into deferred_changes.
    warn "DEFERRED: ${INSTANCE} reboot needs a disruptive change (reboot to finish its update) that is not authorized"
    warn "  Authorize it: module-manager module update ${INSTANCE} --allow-disruption  (or set rebootOk=true for the scheduled pass)"
    exit 0
fi

# The boot id is how "it came back" is told from "it never went": without one
# read beforehand, the first answer afterwards would count as a reboot.
before="$(dh_ssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
[[ -n "${before}" ]] || die "cannot read ${INSTANCE}'s boot id — not rebooting a machine whose return cannot be verified"
info "  Rebooting ${INSTANCE} (authorized) ..."
dh_ssh 'systemctl reboot' >/dev/null 2>&1 || true      # the connection drops; that is the point
for _ in $(seq 1 60); do                                 # up to 5 minutes
    sleep 5
    now="$(dh_ssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    [[ -n "${now}" && "${now}" != "${before}" ]] && break
done
[[ -n "${now:-}" && "${now}" != "${before}" ]] || die "${INSTANCE} did not come back within 5 minutes of its reboot"
dh_ssh 'test -f /var/run/reboot-required' && warn "  ${INSTANCE} still reports reboot-required after rebooting"
info "${GN}✓${CL} ${INSTANCE} rebooted and back"
