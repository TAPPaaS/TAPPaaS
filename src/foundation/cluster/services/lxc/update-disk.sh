#!/usr/bin/env bash
#
# cluster:lxc — the diskSize field hook (ADR-020 D4, class `grow-only`, #901).
#
# The container sibling of cluster:vm's update-disk.sh. A rootfs grows live with
# `pct resize <vmid> rootfs <size>` on the node it runs on (a ZFS subvolume's
# quota, or an image grown and its filesystem with it). A SHRINK is REFUSED:
# Proxmox will not shrink a container's rootfs, and doing it by hand risks the
# data on it. Bind mounts and other mount points are never touched — only the
# rootfs is the field.
#
# Usage (the uniform hook CLI — see tappaas-cicd/lib/converge-lib.sh):
#   update-disk.sh <module> --unit <file> [--check] [--force]
#                           [--field diskSize --desired <v> --actual <v>]
#
# Exit codes (the uniform hook protocol):
#   0   grown, or already at size
#   20  REFUSED: a shrink. --force does not override this.
#   1   error

set -euo pipefail

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

readonly MGMT="mgmt"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

MODULE=""
UNIT_FILE=""
CHECK=0
DESIRED=""
ACTUAL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)    UNIT_FILE="${2:-}"; shift ;;
        --check)   CHECK=1 ;;
        --force)   : ;;  # deliberately ignored — see the exit-20 note above
        --field)   shift ;;
        --desired) DESIRED="${2:-}"; shift ;;
        --actual)  ACTUAL="${2:-}"; shift ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "update-disk.sh: unknown option '$1'" >&2; exit 1 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module> --unit <file> [--check]" >&2; exit 1; }

VMID="" NODE=""
if [[ -n "${UNIT_FILE}" && -r "${UNIT_FILE}" ]]; then
    DESIRED="$(jq -r '(.fields[] | select(.field == "diskSize") | .desired) // ""' "${UNIT_FILE}")"
    ACTUAL="$(jq -r  '(.fields[] | select(.field == "diskSize") | .actual)  // ""' "${UNIT_FILE}")"
    VMID="$(jq -r '(.actual.vmid) // ""' "${UNIT_FILE}")"
    NODE="$(jq -r '(.actual.node) // ""' "${UNIT_FILE}")"
fi

[[ -n "${DESIRED}" ]] || { error "update-disk.sh: no desired diskSize in the unit"; exit 1; }

# Compare as BYTES, as cluster:vm's hook does (the manager's `size` normalizer).
to_bytes() {
    local v="${1^^}" num unit
    [[ "${v}" =~ ^([0-9]+)([BKMGTP]?)I?B?$ ]] || { printf ''; return 1; }
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "${unit}" in
        ""|B) printf '%s' "$((num))" ;;
        K)    printf '%s' "$((num * 1024))" ;;
        M)    printf '%s' "$((num * 1024 ** 2))" ;;
        G)    printf '%s' "$((num * 1024 ** 3))" ;;
        T)    printf '%s' "$((num * 1024 ** 4))" ;;
        P)    printf '%s' "$((num * 1024 ** 5))" ;;
    esac
}

want="$(to_bytes "${DESIRED}")" || { error "update-disk.sh: cannot parse desired size '${DESIRED}'"; exit 1; }
have="$(to_bytes "${ACTUAL}")"  || have=""

if [[ -n "${have}" && "${want}" -eq "${have}" ]]; then
    debug "  diskSize: already ${DESIRED}"
    exit 0
fi

if [[ -n "${have}" && "${want}" -lt "${have}" ]]; then
    error "  diskSize ${ACTUAL}→${DESIRED} is a SHRINK — a container's rootfs only grows"
    exit 20
fi

if [[ "${CHECK}" == "1" ]]; then
    info "  diskSize: would grow ${ACTUAL:-?}→${DESIRED}"
    exit 0
fi

[[ "${VMID}" =~ ^[0-9]+$ && -n "${NODE}" ]] || { error "  update-disk.sh: the unit names no container (vmid/node)"; exit 1; }
debug "  Growing rootfs of CT ${VMID} on ${NODE} to ${DESIRED}..."
# shellcheck disable=SC2029
ssh -n "${SSH_OPTS[@]}" "root@${NODE}.${MGMT}.internal" "pct resize ${VMID} rootfs ${DESIRED}" >/dev/null \
    || { error "  pct resize ${VMID} rootfs ${DESIRED} failed on ${NODE}"; exit 1; }
exit 0
