#!/usr/bin/env bash
#
# TAPPaaS HA Health Check (check-ha-health.sh)
#
# Alerts when an HA-managed service is stuck in a transitional state.
#
# Motivation (issue #146): a failed failback can leave the CRM retrying a
# migration every ~10s forever. That happened for 27 hours across 16437
# attempts without anything noticing — and because each attempt runs a full
# replication cycle first, the guest filesystem is frozen/thawed on every retry.
# The steady-state HA report looks almost normal, so only the *duration* of a
# transitional state distinguishes a healthy migration from a wedged one.
#
# This check records when each service first entered a transitional state and
# alerts once it has stayed there past a threshold. With --repair it also runs
# the cluster's cloud-init orphan sweep, which is the known cause of the
# failback loop (https://bugzilla.proxmox.com/show_bug.cgi?id=7608).
#
# Usage:
#   check-ha-health.sh [--repair] [--threshold SECONDS] [--quiet]
#
#   --repair            Run cloudinit-orphans.sh --execute when a service is wedged
#   --threshold SECONDS How long a transitional state may persist (default 600)
#   --quiet             Only emit output when something is wrong (for timers)
#
# Exit codes:
#   0  all HA services in a steady state (or transitioning within threshold)
#   1  could not determine HA status (no reachable node, no HA configured)
#   2  at least one service wedged beyond the threshold
#
# Designed to be run from a systemd timer on tappaas-cicd every ~5 minutes.
#

set -euo pipefail

# shellcheck source=/home/tappaas/bin/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# #533: managers run as the tappaas operator, never root — under sudo, SSH
# resolves identity from /root/.ssh and fails (ADR-018). Refuse root up front.
tappaas_require_operator

# The one `ha-manager status` parser, and the steady-state list this file used to
# keep its own copy of (#434). Falls back to the repo copy on a system that has
# not re-run pre-update.sh since it landed.
if [[ -r /home/tappaas/bin/ha-vm-lib.sh ]]; then
    # shellcheck source=../../lib/ha-vm-lib.sh disable=SC1091
    . /home/tappaas/bin/ha-vm-lib.sh
else
    _SELF="$(readlink -f "${BASH_SOURCE[0]}")"
    # shellcheck source=../../lib/ha-vm-lib.sh disable=SC1091
    . "$(dirname "${_SELF}")/../../lib/ha-vm-lib.sh"
fi

readonly STATE_FILE="${TAPPAAS_HA_STATE:-/var/lib/tappaas/ha-health.state}"

# Steady states now live in the library as HAVM_STEADY_STATES:
#   freeze — HA management deliberately paused (node maintenance/reboot)
#   ignored/disabled — operator opted the service out
# Anything else means the CRM is actively working on the service, which is only
# healthy for a short while.

THRESHOLD=600
REPAIR=0
QUIET=0

usage() {
    cat <<'EOF'
Usage: check-ha-health.sh [--repair] [--threshold SECONDS] [--quiet]

  --repair             Run the cloud-init orphan sweep when a service is wedged
  --threshold SECONDS  Transitional-state grace period (default 600)
  --quiet              Only produce output when something is wrong

Exit: 0 healthy, 1 undetermined, 2 wedged service found.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repair)    REPAIR=1; shift ;;
        --threshold) THRESHOLD="${2:-}"; shift 2 ;;
        --quiet)     QUIET=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *)           usage; die "Unknown option: $1" ;;
    esac
done

[[ "${THRESHOLD}" =~ ^[0-9]+$ ]] || die "Threshold must be numeric: ${THRESHOLD}"

say() { [[ "${QUIET}" -eq 1 ]] || info "$@"; }

###############################################################################
# Collect HA status from the first reachable node
###############################################################################
# havm_ha_services yields `<sid> <node> <state>` per service and returns non-zero
# only when the QUERY failed. That distinction matters here: a healthy cluster
# with no HA services configured produces no output at all, and the old
# "non-empty status text" test only tolerated it because `ha-manager status`
# happens to print quorum/master/lrm lines alongside the services.
# TAPPAAS_HA_STATUS_FILE (the offline test hook) is honoured inside the library.
ha_services=""
got_status=0
if [[ -n "${TAPPAAS_HA_STATUS_FILE:-}" ]]; then
    ha_services=$(havm_ha_services "") && got_status=1
else
    for node in $(get_all_node_hostnames); do
        if ha_services=$(havm_ha_services "${node}.mgmt.internal"); then
            got_status=1
            break
        fi
    done
fi

[[ "${got_status}" -eq 1 ]] || { error "Could not read ha-manager status from any node"; exit 1; }

###############################################################################
# Compare against the recorded transitional-state history
###############################################################################
now=$(date +%s)

# /var/lib/tappaas is created by a tmpfiles rule in tappaas-cicd.nix, but the
# check must still work when run by hand before that rebuild has landed (or as
# a user who cannot write there). Fall back to the user's state dir rather than
# refusing to run — losing history only costs one grace period.
ensure_state_file() {
    local candidate
    for candidate in "${STATE_FILE}" \
                     "${XDG_STATE_HOME:-${HOME}/.local/state}/tappaas/ha-health.state"; do
        mkdir -p "$(dirname "${candidate}")" 2>/dev/null || continue
        if touch "${candidate}" 2>/dev/null; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

STATE_PATH=$(ensure_state_file) || die "Cannot write a state file (tried ${STATE_FILE})"
[[ "${STATE_PATH}" == "${STATE_FILE}" ]] \
    || debug "Using fallback state file ${STATE_PATH}"

new_state=""
wedged=0
transitioning=0

while read -r sid node state; do
    [[ -n "${sid}" ]] || continue

    if [[ " ${HAVM_STEADY_STATES} " == *" ${state} "* ]]; then
        debug "  ${sid} ${state} on ${node}"
        continue
    fi

    transitioning=1

    # First seen in this transitional state, or continuing an earlier one?
    first_seen=$(awk -F'\t' -v s="${sid}" -v st="${state}" \
                     '$1 == s && $2 == st {print $3; exit}' "${STATE_PATH}")
    if [[ -z "${first_seen}" ]]; then
        first_seen="${now}"
        say "  ${YW}…${CL} ${sid} entered '${state}' on ${node}"
    fi
    new_state+="${sid}"$'\t'"${state}"$'\t'"${first_seen}"$'\n'

    elapsed=$(( now - first_seen ))
    if [[ "${elapsed}" -ge "${THRESHOLD}" ]]; then
        wedged=1
        error "HA service ${sid} stuck in '${state}' on ${node} for ${elapsed}s (threshold ${THRESHOLD}s)"
    else
        say "  ${YW}…${CL} ${sid} in '${state}' on ${node} for ${elapsed}s (within threshold)"
    fi
done < <(printf '%s\n' "${ha_services}")

# Rewrite the state file with only the currently-transitional services, so a
# service that settles forgets its history and gets a fresh grace period.
printf '%s' "${new_state}" > "${STATE_PATH}"

###############################################################################
# Report / repair
###############################################################################
if [[ "${wedged}" -eq 0 ]]; then
    if [[ "${transitioning}" -eq 0 ]]; then
        say "${GN}✓${CL} All HA services in a steady state"
    fi
    exit 0
fi

error "HA is not converging. Most common cause is a stale cloud-init volume"
error "blocking failback — see issue #146 / Proxmox bugzilla #7608."

if [[ "${REPAIR}" -eq 0 ]]; then
    warn "Run the sweep to check:  <cluster>/cloudinit-orphans.sh"
    warn "Then re-run with --repair, or free the volume manually."
    exit 2
fi

sweep=""
if cluster_dir=$(get_module_dir cluster 2>/dev/null) && [[ -x "${cluster_dir}/cloudinit-orphans.sh" ]]; then
    sweep="${cluster_dir}/cloudinit-orphans.sh"
elif [[ -x /home/tappaas/TAPPaaS/src/foundation/cluster/cloudinit-orphans.sh ]]; then
    sweep=/home/tappaas/TAPPaaS/src/foundation/cluster/cloudinit-orphans.sh
fi

if [[ -z "${sweep}" ]]; then
    error "cloudinit-orphans.sh not found — cannot auto-repair"
    exit 2
fi

info "Running cloud-init orphan sweep..."
if "${sweep}" --execute; then
    info "${GN}✓${CL} Sweep completed — the CRM should complete its next retry"
else
    error "Sweep did not complete cleanly — investigate by hand"
fi

exit 2
