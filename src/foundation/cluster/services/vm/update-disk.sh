#!/usr/bin/env bash
#
# cluster:vm — the diskSize field hook (ADR-020 D4, class `grow-only`).
#
# A disk grows through resize-disk.sh. A SHRINK is REFUSED — Proxmox will not
# shrink a volume that has a filesystem on it, and doing it by hand means taking
# the guest offline, shrinking the filesystem first, and accepting data loss if
# the new size is under the used space. That is an operator's decision, not a
# converge's.
#
# WHY THE REFUSAL LIVES HERE and not in the static pre-gate: whether a change is
# a grow or a shrink is only knowable against the LIVE size. `modify --set
# diskSize=…` therefore writes the value and finds out here, and the snapshot
# wrapper rolls back (ADR-020 D2, Resolved Question 4). Only `immutable` and
# `recreate` — refusals that need no live state — are pre-gated.
#
# Usage (the uniform hook CLI — see tappaas-cicd/lib/converge-lib.sh):
#   update-disk.sh <module> --unit <file> [--check] [--force]
#                           [--field diskSize --desired <v> --actual <v>]
#
# Exit codes (the uniform hook protocol):
#   0   grown, or already at size
#   10  (not used — growing needs no downtime)
#   20  REFUSED: a shrink. --force does not override this; it is not a
#       downtime question, it is a "this destroys data" question.
#   1   error

set -euo pipefail

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

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
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "update-disk.sh: unknown option '$1'" >&2; exit 1 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module> --unit <file> [--check]" >&2; exit 1; }

# The unit file is authoritative when present; the --desired/--actual trio keeps
# the hook runnable by hand.
if [[ -n "${UNIT_FILE}" && -r "${UNIT_FILE}" ]]; then
    DESIRED="$(jq -r '(.fields[] | select(.field == "diskSize") | .desired) // ""' "${UNIT_FILE}")"
    ACTUAL="$(jq -r  '(.fields[] | select(.field == "diskSize") | .actual)  // ""' "${UNIT_FILE}")"
    VMNAME="$(jq -r  '(.actual.name) // ""' "${UNIT_FILE}")"
else
    VMNAME=""
fi
[[ -n "${VMNAME}" ]] || VMNAME="$(get_config_value 'vmname' "${MODULE}" 2>/dev/null || echo "${MODULE}")"

[[ -n "${DESIRED}" ]] || { error "update-disk.sh: no desired diskSize in the unit"; exit 1; }

# Compare as BYTES, so "8G" and "8192M" are one size and the grow/shrink verdict
# does not depend on which unit each side happened to use. Mirrors the `size`
# normalizer the manager applies (lib/ts/src/drift.ts).
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
    error "  diskSize ${ACTUAL}→${DESIRED} is a SHRINK — not reconcilable in place"
    error "  Shrinking needs the guest offline and the filesystem shrunk first; do it deliberately, not in a converge."
    exit 20
fi

if [[ "${CHECK}" == "1" ]]; then
    info "  diskSize: would grow ${ACTUAL:-?}→${DESIRED}"
    exit 0
fi

debug "  Growing disk to ${DESIRED}..."
/home/tappaas/bin/resize-disk.sh "${VMNAME}" "${DESIRED}" || { error "  resize-disk.sh failed"; exit 1; }
exit 0
