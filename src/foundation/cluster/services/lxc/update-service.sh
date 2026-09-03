#!/usr/bin/env bash
#
# TAPPaaS Cluster LXC Service - Update (drift converge)
#
# Reconciles a module's live Proxmox container with its desired configuration.
# Called by update-module.sh and `module reconcile --apply` for any module that
# dependsOn cluster:lxc. The container sibling of cluster:vm (issue #203).
#
# ADR-020 SHAPE. This script no longer computes drift — it had its own `cfg()`
# default ladder, its own `pct config` parser and its own comparison rules, so
# the value it would APPLY could differ from the value `reconcile` REPORTED
# (#550). Now:
#
#   desired = module-manager module resolve   [the one resolver]
#   actual  = ./report-service.sh             [extract only]
#   drift   = module-manager module drift     [the one differ]
#   apply   = converge_apply (converge-lib.sh) → the batched `pct set`
#             + update-net.sh
#
# WHERE A CONTAINER DIFFERS FROM A VM, and why the classes differ with it:
#   - one NIC, never two (so no net1 anywhere in this service);
#   - `node` is MANUAL, not `migrate`: live-migrating a container with a GPU
#     passed through or a bind-mount from the host is unsafe, and those are
#     exactly the workloads TAPPaaS runs in containers. Reported, never moved.
#   - `diskSize`/`storage` are MANUAL for the same reason — a bind-mounted
#     rootfs is not something to resize or move mid-sweep.
#   - DNS follows the DHCP lease (masqdns), so the dns side effect REMOVES
#     stale static pins rather than registering one.
#
# Retained here because it is NOT field drift (ADR-020 D7): the `onboot=1`
# policy assertion, and the provider callbacks that know how to reach Proxmox.
#
# Usage: update-service.sh [--check] [--apply-drift <file>] [--force] <module>
#   --check              Report drift without applying (also via TAPPAAS_CHECK=1)
#   --apply-drift FILE   Apply a drift record computed elsewhere. The default is
#                        to ask the manager for one, so every existing caller
#                        keeps working unchanged.
#   --force              Authorize a disruptive change (a container restart).
#
# Exit codes:
#   0  In sync, or all applicable drift applied (deferrals included)
#   1  Drift detected that could not be safely applied
#

# The provider callbacks below are invoked BY NAME from converge-lib.sh;
# cleanup() runs from the EXIT trap. ShellCheck sees neither call site.
# shellcheck disable=SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_DIR="/home/tappaas/config"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../../tappaas-cicd/lib/converge-lib.sh disable=SC1091
. "${SCRIPT_DIR}/../../../tappaas-cicd/lib/converge-lib.sh"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

# ── Arguments ────────────────────────────────────────────────────────

CHECK_MODE="${TAPPAAS_CHECK:-0}"
DRIFT_FILE=""
FORCE=0
MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       CHECK_MODE=1 ;;
        --apply-drift) DRIFT_FILE="${2:-}"; shift ;;
        --force)       FORCE=1 ;;
        -h|--help)     echo "Usage: $0 [--check] [--apply-drift <file>] [--force] <module-name>"; exit 0 ;;
        -*)            echo "update-service.sh: unknown option '$1'" >&2; exit 1 ;;
        *)             MODULE="$1" ;;
    esac
    shift
done

[[ -n "${MODULE}" ]] || { echo "Usage: $0 [--check] [--apply-drift <file>] [--force] <module-name>"; exit 1; }

check_json "${CONFIG_DIR}/${MODULE}.json" || exit 1

debug "${BOLD}cluster:lxc update-service: reconciling ${BL}${MODULE}${CL}"
[[ "${CHECK_MODE}" == "1" ]] && warn "  CHECK MODE — drift will be reported, not applied"
CONVERGE_CHECK="${CHECK_MODE}"

# ── The drift record ─────────────────────────────────────────────────

OWN_DRIFT_FILE=""
cleanup() { [[ -n "${OWN_DRIFT_FILE}" ]] && rm -f -- "${OWN_DRIFT_FILE}"; return 0; }
trap cleanup EXIT INT TERM

if [[ -z "${DRIFT_FILE}" ]]; then
    OWN_DRIFT_FILE="$(mktemp "${TMPDIR:-/tmp}/cluster-lxc-drift.XXXXXX.json")"
    DRIFT_FILE="${OWN_DRIFT_FILE}"
    drift_err="$(mktemp "${TMPDIR:-/tmp}/cluster-lxc-drift-err.XXXXXX")"
    if ! module-manager module drift "${MODULE}" --service cluster:lxc --json \
            > "${DRIFT_FILE}" 2> "${drift_err}"; then
        # A stale module-manager is the one failure an operator cannot guess
        # from "could not compute drift" — pre-update.sh warns and continues
        # when a component build fails, leaving this script newer than the CLI.
        if grep -q "Unknown verb" "${drift_err}" 2>/dev/null; then
            error "The installed module-manager has no 'module drift' verb — it is older than this service script."
            error "Rebuild it:  ${SCRIPT_DIR}/../../../tappaas-cicd/manager/module-manager/install.sh"
            rm -f -- "${drift_err}"
            exit 1
        fi
        error "Could not compute drift for '${MODULE}':"
        sed 's/^/    /' "${drift_err}" >&2
        rm -f -- "${drift_err}"
        die "module-manager module drift ${MODULE} --service cluster:lxc failed"
    fi
    rm -f -- "${drift_err}"
fi

# ── Provider callbacks (the converge-lib contract) ───────────────────

VMID="$(jq -r '(.actual.vmid) // ""'    "${DRIFT_FILE}")"
NODE="$(jq -r '(.actual.node) // ""'    "${DRIFT_FILE}")"
CTSTATUS="$(jq -r '(.actual.status) // ""'   "${DRIFT_FILE}")"
VMNAME="$(jq -r '(.actual.hostname) // ""'   "${DRIFT_FILE}")"
[[ -n "${VMNAME}" ]] || VMNAME="${MODULE}"
ZONE0="$(module-manager module resolve "${MODULE}" --json 2>/dev/null | jq -r '(.fields.zone0.value) // "mgmt"')"
NODE_FQDN="${NODE}.${MGMT}.internal"

# ONE batched `pct set` for every in-place field, as before the refactor.
# shellcheck disable=SC2029
converge_apply_set() {
    debug "  Applying pct set on ${NODE}..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "pct set ${VMID} $(printf '%q ' "$@")" >/dev/null
}

RESTART_SKIPPED=0
# shellcheck disable=SC2029
converge_side_effect_reboot() {
    if [[ "${CTSTATUS}" != "running" ]]; then
        warn "  container not running — network change applied; DNS will register on next boot"
        RESTART_SKIPPED=1
        return 0
    fi
    debug "  Restarting LXC ${VMID} to apply the network change..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct reboot ${VMID}" >/dev/null
}

# A container reports its own addresses directly — no guest agent needed, and
# no DHCP-lease fallback, because `pct exec` reaches inside it.
NEW_IP=""
# shellcheck disable=SC2029
converge_side_effect_wait_ip() {
    [[ "${RESTART_SKIPPED}" == "1" ]] && return 0
    debug "  Waiting for the container to come back with an IP..."
    for _ in $(seq 1 30); do
        sleep 4
        NEW_IP=$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
                    "pct exec ${VMID} -- hostname -I 2>/dev/null" 2>/dev/null \
                 | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -1) || true
        [[ -n "${NEW_IP}" ]] && break
    done
    # A container that does not come back is UNHEALTHY, and unlike a VM there is
    # no lease-table fallback that could still make its name resolve — so this
    # fails the converge rather than warning, exactly as before the refactor.
    [[ -n "${NEW_IP}" ]] || { error "  container did not report an IPv4 after restart — unhealthy"; return 1; }
    debug "  Container came up with IP ${BL}${NEW_IP}${CL}"
    return 0
}

# The masqdns model: a container leases under <vmname>, so DNS FOLLOWS the live
# lease in the new subnet — there is no static record to register. What must
# happen is the opposite of the VM path: remove any LEGACY static pin, in the
# current zone and in the old one, so a stale override cannot shadow the lease.
converge_side_effect_dns() {
    [[ "${RESTART_SKIPPED}" == "1" ]] && return 0
    debug "  DNS via masqdns lease (${VMNAME}.${ZONE0}.internal) — clearing any stale static pin"
    dns-manager --no-ssl-verify delete "${VMNAME}" "${ZONE0}.internal" >/dev/null 2>&1 || true

    local old_tag old_zone
    old_tag="$(jq -r '(.actual["net0.tag"]) // ""' "${DRIFT_FILE}")"
    if [[ -n "${old_tag}" && "${old_tag}" != "0" ]]; then
        old_zone="$(jq -r --argjson t "${old_tag}" \
            'to_entries[] | select(.value.vlantag == $t) | .key' "${ZONES_FILE}" 2>/dev/null | head -1)"
        if [[ -n "${old_zone}" && "${old_zone}" != "${ZONE0}" ]]; then
            debug "  Removing any stale DNS pin from the old zone: ${VMNAME}.${old_zone}.internal"
            dns-manager --no-ssl-verify delete "${VMNAME}" "${old_zone}.internal" >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# ── onboot: a policy, not a field ────────────────────────────────────
# Every TAPPaaS container starts with its node. That is an estate rule, not a
# per-module tunable, so it is NOT in module-fields.json and cannot ride the
# drift record — and making it a field would invite per-module divergence
# nothing asked for. Asserted here instead, which is what ADR-020 D7 means by
# "logic that is not field drift stays in update-service.sh".
# The live value comes from the RECORD, not a second `pct config`: the reporter
# is the one read of the container's state, and asking twice invites the two
# answers to disagree.
# shellcheck disable=SC2029
assert_onboot() {
    local live
    live="$(jq -r '(.actual.onboot) // "0"' "${DRIFT_FILE}")"
    [[ "${live}" == "1" ]] && return 0
    if [[ "${CHECK_MODE}" == "1" ]]; then
        info "  onboot: ${live}→1 (policy: TAPPaaS containers start with their node)"
        return 0
    fi
    debug "  onboot: ${live}→1"
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct set ${VMID} --onboot 1" >/dev/null \
        || warn "  could not set onboot=1 on ${VMID}"
    return 0
}

# ── Converge ─────────────────────────────────────────────────────────
# Disruption authorization, ADR-020 D8 — identical policy to cluster:vm.
REBOOT_OK="$(module-manager module resolve "${MODULE}" --json 2>/dev/null \
             | jq -r '(.fields.rebootOk.value) // "false"')"
ALLOW_DISRUPTION=0
if [[ "${FORCE}" == "1" ]]; then
    ALLOW_DISRUPTION=1
elif [[ "${REBOOT_OK}" == "true" && "${TAPPAAS_SCHEDULED_PASS:-0}" == "1" ]]; then
    debug "  rebootOk=true in the scheduled pass — disruptive changes are authorized"
    ALLOW_DISRUPTION=1
fi

rc=0
converge_apply "${MODULE}" "${SCRIPT_DIR}" "${DRIFT_FILE}" "${CHECK_MODE}" "${ALLOW_DISRUPTION}" "${FORCE}" || rc=1
assert_onboot
[[ ${rc} -eq 0 ]] || exit 1

debug "  ${GN}✓${CL} cluster:lxc update-service completed"
exit 0
