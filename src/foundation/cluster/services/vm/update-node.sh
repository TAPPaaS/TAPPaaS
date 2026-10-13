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
#       `qm migrate`, online when the guest is running and can move live; with
#       --force, stop → offline migrate → start when it cannot.
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
#   10  would need downtime that is not authorized (ADR-019 live-OK verdict)
#   20  refused
#   1   error

# The remote `qm` command embeds locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# The confirmed stop/start an offline migrate of a running guest needs (#825).
# shellcheck source=/home/tappaas/bin/ha-vm-lib.sh
. /home/tappaas/bin/ha-vm-lib.sh

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

MODULE=""
FORCE=0
UNIT_FILE=""
CHECK=0
DESIRED=""
ACTUAL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)    UNIT_FILE="${2:-}"; shift ;;
        --check)   CHECK=1 ;;
        --force)   FORCE=1 ;;  # authorizes an OFFLINE migrate (ADR-019)
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
# Run by hand (no --unit) the status is unknown, and an unknown status must not
# read as "stopped": a running guest would then get `--online 0`, which Proxmox
# refuses. Ask the node.
if [[ -z "${STATUS}" ]]; then
    STATUS="$(ssh "${SSH_OPTS[@]}" "root@${ACTUAL}.${MGMT}.internal" \
        "qm status ${VMID} 2>/dev/null" 2>/dev/null | awk '{print $2}')" || STATUS=""
fi


# ── Live-OK verdict (ADR-019) ────────────────────────────────────────
# A STOPPED guest has no downtime to authorize — moving it is just a move. A
# RUNNING one is the question: can it move without stopping?
#
# `proxmox-controller live-ok` answers from what the GUEST sees (QEMU's
# query-cpu-model-expansion), not from host flags. Its exit codes:
#   0  live-safe            → migrate --online 1
#   2  would lose features  → an offline migrate is DOWNTIME
#   1  cannot determine     → treat as downtime; unknown is never "safe"
#
# When downtime is needed and not authorized, return 10 rather than migrating
# offline. That is the whole point: before ADR-019 this passed --online 1 and
# let Proxmox decide, which on a rejection left the operator with a failed
# migrate, and on a stopped-guest path took downtime nobody asked for.
# Computed BEFORE the --check early return, so a dry run reports not just THAT
# the guest would move but whether moving it costs downtime — which is the part
# an operator plans around.
online_flag=0
live_rc=0
if [[ "${STATUS}" == "running" ]]; then
    proxmox-controller live-ok "${MODULE}" "${DESIRED}" >&2 || live_rc=$?
    [[ "${live_rc}" -eq 0 ]] && online_flag=1
fi

if [[ "${CHECK}" == "1" ]]; then
    if [[ "${STATUS}" != "running" ]]; then
        info "  node: would migrate ${ACTUAL}→${DESIRED} (guest is ${STATUS}; no downtime to take)"
    elif [[ "${online_flag}" == "1" ]]; then
        info "  node: would migrate ${ACTUAL}→${DESIRED} LIVE — no downtime"
    else
        info "  node: would migrate ${ACTUAL}→${DESIRED}, but only OFFLINE — needs --force"
    fi
    exit 0
fi

if [[ "${STATUS}" == "running" ]]; then
    case "${live_rc}" in
        0)  : ;;
        *)
            if [[ "${FORCE}" != "1" ]]; then
                warn "  node: ${ACTUAL}→${DESIRED} cannot be done live (see above)."
                warn "  An offline migrate stops ${MODULE}. Re-run with --force to authorize it."
                exit 10
            fi
            warn "  node: migrating ${MODULE} OFFLINE ${ACTUAL}→${DESIRED} (--force given)"
            ;;
    esac
fi

# ── Migrate ──────────────────────────────────────────────────────────
# Proxmox's own output is kept and shown on failure: its reason ("non-replicated
# snapshot exists", "VM is running") is the only useful part of a refusal (#825).
migrate_out="$(mktemp "${TMPDIR:-/tmp}/update-node.XXXXXX")"
trap 'rm -f -- "${migrate_out}"' EXIT
qm_migrate() {
    ssh "${SSH_OPTS[@]}" "root@${ACTUAL}.${MGMT}.internal" \
        "qm migrate ${VMID} ${DESIRED} $*" > "${migrate_out}" 2>&1
}

# A RUNNING guest cannot be migrated with --online 0: Proxmox refuses. Offline
# means stop, move, start — confirmed at each step (#825).
offline_migrate() {
    warn "  node: stopping ${MODULE} for an offline migrate ${ACTUAL}→${DESIRED}"
    ssh "${SSH_OPTS[@]}" "root@${ACTUAL}.${MGMT}.internal" \
        "qm shutdown ${VMID} --timeout 90" >/dev/null 2>&1 || true
    havm_stop "${ACTUAL}.${MGMT}.internal" "${VMID}" qemu 120 \
        || { error "  ${MODULE} did not stop on ${ACTUAL} — not migrating"; return 1; }
    if ! qm_migrate; then
        sed 's/^/    /' "${migrate_out}" >&2
        error "  offline migrate ${ACTUAL}→${DESIRED} failed — starting ${MODULE} again on ${ACTUAL}"
        havm_start "${ACTUAL}.${MGMT}.internal" "${VMID}" qemu 120 || true
        return 1
    fi
    havm_start "${DESIRED}.${MGMT}.internal" "${VMID}" qemu 120 \
        || { error "  ${MODULE} moved to ${DESIRED} but is not running there"; return 1; }
    info "  node: ${MODULE} moved offline ${ACTUAL}→${DESIRED} and is running"
}

if [[ "${STATUS}" == "running" && "${online_flag}" != "1" ]]; then
    offline_migrate || exit 1
    exit 0
fi

debug "  Migrating VM ${VMID} ${ACTUAL}→${DESIRED} (online=${online_flag})..."
online_args="--online ${online_flag}"
[[ "${online_flag}" == "1" ]] && online_args+=" --with-local-disks 1"
if ! qm_migrate "${online_args}"; then
    sed 's/^/    /' "${migrate_out}" >&2
    error "  qm migrate ${ACTUAL}→${DESIRED} failed for ${MODULE} (vmid ${VMID})"
    # Live was judged possible and still failed. With downtime authorized, the
    # move the operator asked for is still available offline.
    if [[ "${STATUS}" == "running" && "${FORCE}" == "1" ]]; then
        post_status="$(ssh "${SSH_OPTS[@]}" "root@${ACTUAL}.${MGMT}.internal" \
            "qm status ${VMID} 2>/dev/null" 2>/dev/null | awk '{print $2}')" || post_status=""
        if [[ "${post_status}" == "running" ]]; then
            warn "  live migrate failed; --force given — falling back to an offline migrate"
            offline_migrate || exit 1
            exit 0
        fi
    fi
    # A failed migrate is not, by itself, a broken guest. Ask where the guest
    # actually is before deciding (#393): a shared-storage check, a resource
    # constraint or an HA lock can refuse the move while the guest carries on
    # serving from the node it is already on. Reporting that as an error made
    # the whole module update Fatal, and under D9 a dependency failure rolls the
    # guest back to its pre-update snapshot — so a healthy guest lost its update
    # because of where it happened to live.
    # Ask the node itself, not the unit file: STATUS there is the pre-migrate
    # snapshot, which is exactly the value that must not be trusted here.
    post_status="$(ssh "${SSH_OPTS[@]}" "root@${ACTUAL}.${MGMT}.internal" \
        "qm status ${VMID} 2>/dev/null" 2>/dev/null | awk '{print $2}')" || post_status=""
    if [[ "${STATUS}" == "running" && "${post_status}" == "running" ]]; then
        warn "  ${MODULE} is still running on ${ACTUAL} — leaving it there and continuing"
        warn "  Node placement drift (${ACTUAL}→${DESIRED}) stays recorded; resolve it separately"
        exit 11
    fi
    # Either it was not running to begin with, or the migrate left it down.
    # The second is a real failure and must stay one.
    error "  ${MODULE} is '${post_status:-unknown}' on ${ACTUAL} after the failed migrate"
    exit 1
fi
exit 0
