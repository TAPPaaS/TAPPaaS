#!/usr/bin/env bash
#
# cluster:vm — the thinDisk field hook (#773, class `in-place`).
#
# thinDisk=true  → every zvol of the guest gets refreservation=none (thin).
# thinDisk=false → refreservation=auto (thick again); ZFS refuses this when the
#                  pool cannot hold the reservation, and so does this hook.
# A module that does not declare thinDisk is never handed to this hook: the
# field has no default, so the differ skips it (no-desired-value) and a pool an
# operator made sparse by hand is left alone.
#
# The HA replica follows on the next replication run — `zfs send -RpvU` carries
# the property — so only the guest's own node is touched here. No downtime:
# refreservation is accounting, the guest does not notice.
#
# Usage (the uniform hook CLI — see tappaas-cicd/lib/converge-lib.sh):
#   update-thin.sh <module> --unit <file> [--check] [--force]
#                           [--field thinDisk --desired <v> --actual <v>]
#
# Exit codes (the uniform hook protocol):
#   0   applied, already so, or not applicable (the guest has no zvol)
#   1   error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/zfs-thin.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/zfs-thin.sh"

MODULE=""
UNIT_FILE=""
CHECK=0
DESIRED=""
ACTUAL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)    UNIT_FILE="${2:-}"; shift ;;
        --check)   CHECK=1 ;;
        --force)   : ;;  # nothing here is disruptive
        --field)   shift ;;
        --desired) DESIRED="${2:-}"; shift ;;
        --actual)  ACTUAL="${2:-}"; shift ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "update-thin.sh: unknown option '$1'" >&2; exit 1 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module> --unit <file> [--check]" >&2; exit 1; }

NODE="" VMID=""
if [[ -n "${UNIT_FILE}" && -r "${UNIT_FILE}" ]]; then
    DESIRED="$(jq -r '(.fields[] | select(.field == "thinDisk") | .desired) // ""' "${UNIT_FILE}")"
    ACTUAL="$(jq -r  '(.fields[] | select(.field == "thinDisk") | .actual)  // ""' "${UNIT_FILE}")"
    NODE="$(jq -r    '(.actual.node) // ""' "${UNIT_FILE}")"
    VMID="$(jq -r    '(.actual.vmid) // ""' "${UNIT_FILE}")"
fi
# Run by hand: locate the guest the way every consumer does — its reporter.
if [[ -z "${NODE}" || -z "${VMID}" ]]; then
    live="$("${SCRIPT_DIR}/report-service.sh" "${MODULE}")" || { error "update-thin.sh: cannot locate '${MODULE}'"; exit 1; }
    NODE="$(jq -r '.node' <<< "${live}")"; VMID="$(jq -r '.vmid' <<< "${live}")"
fi

case "${DESIRED,,}" in
    true|1|yes)  action="thin" ;;
    false|0|no)  action="thick" ;;
    *) error "update-thin.sh: thinDisk must be true or false (got '${DESIRED}')"; exit 1 ;;
esac

if [[ "${CHECK}" == "1" ]]; then
    info "  thinDisk: would make ${MODULE}'s disks ${action} (now: ${ACTUAL:-unknown})"
    exit 0
fi

changed="$(zfs_thin_remote "${NODE}" "${VMID}" "${action}")" \
    || { error "  thinDisk: setting refreservation on ${NODE} failed (thick needs the pool to hold the full size)"; exit 1; }
if [[ -z "${changed}" ]]; then
    warn "  thinDisk: ${MODULE} has no ZFS disk — not applicable"
else
    info "  thinDisk: ${action} — $(tr '\n' ' ' <<< "${changed}")(the HA replica follows on its next run)"
fi
exit 0
