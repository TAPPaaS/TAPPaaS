#!/usr/bin/env bash
#
# cluster:vm — the node field hook (ADR-020 D4, class `migrate`).
#
# Changing `node` relocates the guest. Two cases, and which one applies is a
# property of the MODULE, not of the field — which is why the manifest keys the
# change class by the (field, service) pair and lets the hook route internally:
#
#   HA module (dependsOn cluster:ha)
#       Placement is owned by the HA rule, not by a one-off migrate. Moving the
#       guest here would fight the rule, which would move it back. So this
#       reports the drift and leaves it to cluster:ha — the same deferral
#       update-service.sh has always made.
#
#   plain module
#       `qm migrate`, online when the guest is running, offline when it is not.
#
# ADR-019 SEAM. ADR-019 (HA and Cross-Node VM Migration Policy) is still
# Proposed: its live-OK CPU-compatibility verdict and the restructured migrate
# primitive do not exist yet. When they land, this is where they plug in — a
# migrate that is not live-OK returns 10 ("needs disruption authorization")
# instead of migrating offline behind the operator's back, which is ADR-019's
# rule of thumb: never a silent disruptive fallback. Until then this preserves
# today's behaviour exactly, and `--force` is accepted but changes nothing,
# because there is not yet a refusal for it to override.
#
# Usage (the uniform hook CLI — see tappaas-cicd/lib/converge-lib.sh):
#   update-node.sh <module> --unit <file> [--check] [--force]
#                           [--field node --desired <v> --actual <v>]
#
# Exit codes (the uniform hook protocol):
#   0   migrated, already there, or deliberately left to cluster:ha
#   10  would need downtime that is not authorized  [ADR-019, not yet reachable]
#   20  refused
#   1   error

# The remote `qm` command embeds locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

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
        --force)   : ;;  # see the ADR-019 seam above
        --field)   shift ;;
        --desired) DESIRED="${2:-}"; shift ;;
        --actual)  ACTUAL="${2:-}"; shift ;;
        -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "update-node.sh: unknown option '$1'" >&2; exit 1 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}" ]] || { echo "Usage: $0 <module> --unit <file> [--check] [--force]" >&2; exit 1; }

VMID=""
STATUS=""
if [[ -n "${UNIT_FILE}" && -r "${UNIT_FILE}" ]]; then
    DESIRED="$(jq -r '(.fields[] | select(.field == "node") | .desired) // ""' "${UNIT_FILE}")"
    ACTUAL="$(jq -r  '(.fields[] | select(.field == "node") | .actual)  // ""' "${UNIT_FILE}")"
    VMID="$(jq -r    '(.actual.vmid)   // ""' "${UNIT_FILE}")"
    STATUS="$(jq -r  '(.actual.status) // ""' "${UNIT_FILE}")"
fi

[[ -n "${DESIRED}" ]] || { error "update-node.sh: no desired node in the unit"; exit 1; }

if [[ -z "${VMID}" ]]; then
    JSON="$(normalize_module_config < "/home/tappaas/config/${MODULE}.json")"
    VMID="$(get_config_value 'vmid')"
fi
[[ -n "${VMID}" ]] || { error "update-node.sh: ${MODULE} has no vmid"; exit 1; }

if [[ "${DESIRED}" == "${ACTUAL}" ]]; then
    debug "  node: already on ${DESIRED}"
    exit 0
fi

# ── HA modules: placement belongs to the HA rule ─────────────────────
# Reported, not applied, and NOT counted as a deferral: nothing here is waiting
# for authorization, the work simply belongs to another service. Same verdict
# (warn, keep going) update-service.sh has always given.
if read_module_config "${MODULE}" | jq -e '(.dependsOn // []) | index("cluster:ha") != null' >/dev/null 2>&1; then
    warn "  node drift (${ACTUAL:-unknown}→${DESIRED}) deferred to cluster:ha drift handling"
    exit 0
fi

[[ -n "${ACTUAL}" ]] || { error "update-node.sh: the record carries no current node for ${MODULE}"; exit 1; }

if [[ "${CHECK}" == "1" ]]; then
    info "  node: would migrate ${ACTUAL}→${DESIRED}"
    exit 0
fi

# ── Migrate ──────────────────────────────────────────────────────────
# Online for a running guest, offline for a stopped one. ADR-019 will insert
# the live-OK verdict here: when a live migration is not possible, an OFFLINE
# migration is downtime, and downtime is never silent — that case returns 10.
online_flag=0
[[ "${STATUS}" == "running" ]] && online_flag=1

debug "  Migrating VM ${VMID} ${ACTUAL}→${DESIRED} (online=${online_flag})..."
ssh "${SSH_OPTS[@]}" "root@${ACTUAL}.${MGMT}.internal" \
    "qm migrate ${VMID} ${DESIRED} --online ${online_flag}" >/dev/null \
    || { error "  qm migrate failed"; exit 1; }
exit 0
