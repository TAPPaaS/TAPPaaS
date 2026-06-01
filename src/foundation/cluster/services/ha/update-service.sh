#!/usr/bin/env bash
#
# TAPPaaS Cluster HA Service - Update (drift reconciler)
#
# Reconciles a module's live Proxmox HA configuration with its desired state.
# Called by update-module.sh for any module that dependsOn cluster:ha, and the
# sibling of the cluster:vm reconciler (issue #192). Resolves issue #193.
#
# Desired state : /home/tappaas/config/<module>.json
#                   node               -> HA primary node (priority 2)
#                   HANode             -> HA failover node (priority 1)
#                   replicationSchedule-> ZFS replication interval (default */15)
#                   storage            -> pool that must exist on the failover node
# Current state : live cluster HA config on the VM's actual node
#                   /cluster/ha/resources    (membership + state)
#                   /cluster/ha/rules        (node-affinity nodes/priorities)
#                   /cluster/replication     (job target + schedule)
#
# Detected and reconciled:
#   ha resource absent / not 'started'        -> ha-manager add/set
#   node-affinity rule missing or nodes drift -> ha-manager rules add/set
#       (covers "primary node moved" and "HA node moved" in config)
#   replication target drift (HANode moved)   -> delete + recreate job
#   replication schedule drift                -> pvesr update
#   replication job missing                   -> create job
#   placement drift (VM not on primary)       -> ha-manager crm-command migrate
#       (the HA-aware equivalent of the node move that cluster:vm defers here)
#
# Skipped gracefully:
#   single-node cluster / no distinct HANode  -> nothing to do
#   placement migrate when primary is offline -> reported, not forced
#
# Usage: update-service.sh [--check] <module-name>
#   --check   Report drift without applying (also via TAPPAAS_CHECK=1)
#
# Exit codes:
#   0  In sync, or all detected drift applied successfully
#   1  Drift detected but could not be safely applied (fatal)
#

# Remote ha-manager/pvesh/pvesr commands intentionally embed locally-computed
# values (VMID, nodes, schedule) that expand client-side before the ssh send.
# shellcheck disable=SC2029
set -euo pipefail

readonly CONFIG_DIR="/home/tappaas/config"
readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

# ── Arguments ────────────────────────────────────────────────────────

CHECK_MODE="${TAPPAAS_CHECK:-0}"
MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   CHECK_MODE=1 ;;
        -h|--help) echo "Usage: $0 [--check] <module-name>"; exit 0 ;;
        *)         MODULE="$1" ;;
    esac
    shift
done

if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 [--check] <module-name>"
    exit 1
fi

check_json "${CONFIG_DIR}/${MODULE}.json" || exit 1

# Load the module config into $JSON for get_config_value. The library's
# source-time auto-loader keys off the script's first arg, which may be a flag
# (e.g. --check), so set it explicitly now that the module name is known.
# Normalize Pattern-A configs (nested under .config."<module>:<service>") to flat form.
JSON="$(normalize_module_config < "${CONFIG_DIR}/${MODULE}.json")"

# get_config_value exits when a required (empty-default) key is missing, so all
# optional reads pass an explicit default.
cfg() { get_config_value "$1" "$2"; }

# ── Desired state (from module.json + configuration.json) ────────────

VMID="$(get_config_value 'vmid')"

DESIRED_PRIMARY="$(cfg 'node' "$(get_node_hostname 0)")"
[[ "${DESIRED_PRIMARY}" == "null" || -z "${DESIRED_PRIMARY}" ]] && DESIRED_PRIMARY="$(get_node_hostname 0)"

HANODE="$(cfg 'HANode' "$(get_default_ha_node "${DESIRED_PRIMARY}")")"
[[ "${HANODE}" == "null" ]] && HANODE=""

REPL_SCHEDULE="$(cfg 'replicationSchedule' '*/15')"
STORAGE="$(cfg 'storage' 'tanka1')"

readonly HA_RULE_NAME="ha-${MODULE}"

info "${BOLD}cluster:ha update-service: reconciling ${BL}${MODULE}${CL} (VMID ${VMID})"
[[ "${CHECK_MODE}" == "1" ]] && warn "  CHECK MODE — drift will be reported, not applied"

# ── Single-node / no-failover guard ──────────────────────────────────

if [[ -z "${HANODE}" ]]; then
    warn "  single-node cluster — HA not applicable, skipping (no failover node)"
    exit 0
fi
if [[ "${HANODE}" == "${DESIRED_PRIMARY}" ]]; then
    error "  HANode (${HANODE}) equals primary node (${DESIRED_PRIMARY}) — HA requires two distinct nodes"
    exit 1
fi

info "  Desired: primary=${BL}${DESIRED_PRIMARY}${CL}, failover=${BL}${HANODE}${CL}, schedule=${REPL_SCHEDULE}"

# ── Locate the VM's actual node + status (cluster-wide) ──────────────

actual_node=""
vm_status=""
# shellcheck disable=SC2046  # word-splitting of hostnames is intended
for cand in "${DESIRED_PRIMARY}" $(get_all_node_hostnames); do
    row=$(ssh "${SSH_OPTS[@]}" "root@${cand}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${VMID}" \
            '.[] | select(.vmid == $id and .type == "qemu") | "\(.node) \(.status)"' 2>/dev/null) || true
    if [[ -n "${row}" ]]; then
        actual_node="${row%% *}"
        vm_status="${row##* }"
        break
    fi
done

[[ -z "${actual_node}" ]] && die "VM ${VMID} (${MODULE}) not found on the cluster — is it installed?"
NODE_FQDN="${actual_node}.${MGMT}.internal"
info "  VM ${VMID} is on node ${BL}${actual_node}${CL} (status: ${vm_status})"

# ── Read live HA / replication state ─────────────────────────────────

live_ha_state="$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
    "pvesh get /cluster/ha/resources --output-format json" 2>/dev/null \
    | jq -r --arg sid "vm:${VMID}" '.[] | select(.sid == $sid) | .state // empty' 2>/dev/null)" || true

live_rule_nodes="$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
    "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null \
    | jq -r --arg res "vm:${VMID}" '.[] | select(.resources == $res) | .nodes // empty' 2>/dev/null)" || true

repl_line="$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
    "pvesh get /cluster/replication --output-format json" 2>/dev/null \
    | jq -r --argjson id "${VMID}" \
        '.[] | select(.guest == $id) | "\(.id)\t\(.target)\t\(.schedule)"' 2>/dev/null | head -1)" || true
live_repl_id="${repl_line%%$'\t'*}"
live_repl_rest="${repl_line#*$'\t'}"
live_repl_target="${live_repl_rest%%$'\t'*}"
live_repl_sched="${live_repl_rest##*$'\t'}"
[[ "${live_repl_id}" == "${repl_line}" ]] && { live_repl_id=""; live_repl_target=""; live_repl_sched=""; }

# Desired node-affinity: primary outranks failover.
readonly DESIRED_NODES="${DESIRED_PRIMARY}:2,${HANODE}:1"

# Proxmox may store the nodes list in any order; compare as a sorted set.
normalize_nodes() { tr ', ' '\n' <<< "$1" | sed '/^$/d' | sort | paste -sd',' -; }

# ── Drift accumulation ───────────────────────────────────────────────

declare -a CHANGES=()
DO_ADD_RESOURCE=0
DO_SET_STATE=0
RULE_EXISTS=0
DO_SET_RULE=0
DO_REPL_RECREATE=0
DO_REPL_UPDATE=0
DO_MIGRATE=0

# 1. HA resource membership / state
if [[ -z "${live_ha_state}" ]]; then
    CHANGES+=("ha-resource: absent→started (add vm:${VMID})")
    DO_ADD_RESOURCE=1
elif [[ "${live_ha_state}" != "started" ]]; then
    CHANGES+=("ha-state: ${live_ha_state}→started")
    DO_SET_STATE=1
fi

# 2. node-affinity rule (covers primary-moved and HANode-moved in config)
if [[ -z "${live_rule_nodes}" ]]; then
    CHANGES+=("ha-rule '${HA_RULE_NAME}': missing→${DESIRED_NODES}")
    DO_SET_RULE=1
else
    RULE_EXISTS=1
    if [[ "$(normalize_nodes "${live_rule_nodes}")" != "$(normalize_nodes "${DESIRED_NODES}")" ]]; then
        CHANGES+=("ha-rule nodes: ${live_rule_nodes}→${DESIRED_NODES}")
        DO_SET_RULE=1
    fi
fi

# 3. replication job (target drift = HANode moved; schedule drift; or missing)
if [[ -z "${live_repl_id}" ]]; then
    CHANGES+=("replication: missing→target ${HANODE}, schedule ${REPL_SCHEDULE}")
    DO_REPL_RECREATE=1
elif [[ "${live_repl_target}" != "${HANODE}" ]]; then
    CHANGES+=("replication target: ${live_repl_target}→${HANODE} (recreate job)")
    DO_REPL_RECREATE=1
elif [[ "${live_repl_sched}" != "${REPL_SCHEDULE}" ]]; then
    CHANGES+=("replication schedule: ${live_repl_sched}→${REPL_SCHEDULE}")
    DO_REPL_UPDATE=1
fi

# 4. placement drift (VM running off its desired primary)
if [[ "${actual_node}" != "${DESIRED_PRIMARY}" ]]; then
    if ssh "${SSH_OPTS[@]}" "root@${DESIRED_PRIMARY}.${MGMT}.internal" "true" &>/dev/null; then
        CHANGES+=("placement: ${actual_node}→${DESIRED_PRIMARY} (ha-manager migrate)")
        DO_MIGRATE=1
    else
        warn "  placement drift (${actual_node}→${DESIRED_PRIMARY}) — primary offline, not migrating"
    fi
fi

# ── Report ───────────────────────────────────────────────────────────

if [[ ${#CHANGES[@]} -eq 0 ]]; then
    info "  ${GN}✓${CL} HA config is in sync with config — no changes needed"
    exit 0
fi

info "  Detected drift:"
for c in "${CHANGES[@]}"; do info "    • ${c}"; done

if [[ "${CHECK_MODE}" == "1" ]]; then
    info "  CHECK MODE — no changes applied"
    exit 0
fi

# ── Pre-apply validation: failover node + storage must be usable ─────

HA_NODE_FQDN="${HANODE}.${MGMT}.internal"
if [[ ${DO_SET_RULE} -eq 1 || ${DO_REPL_RECREATE} -eq 1 ]]; then
    if ! ssh "${SSH_OPTS[@]}" "root@${HA_NODE_FQDN}" "true" &>/dev/null; then
        die "Failover node ${HANODE} is not reachable — cannot reconcile HA"
    fi
    if ! ssh "${SSH_OPTS[@]}" "root@${HA_NODE_FQDN}" "pvesm status --storage ${STORAGE}" &>/dev/null; then
        die "Storage ${STORAGE} does not exist on failover node ${HANODE}"
    fi
fi

# ── Apply ────────────────────────────────────────────────────────────

if [[ ${DO_ADD_RESOURCE} -eq 1 ]]; then
    info "  Adding VM ${VMID} to HA resources (state=started)..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "ha-manager add vm:${VMID} --state started" >/dev/null || die "ha-manager add failed"
fi

if [[ ${DO_SET_STATE} -eq 1 ]]; then
    info "  Setting HA resource vm:${VMID} state=started..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "ha-manager set vm:${VMID} --state started" >/dev/null || die "ha-manager set failed"
fi

if [[ ${DO_SET_RULE} -eq 1 ]]; then
    if [[ ${RULE_EXISTS} -eq 1 ]]; then
        info "  Updating node-affinity rule ${HA_RULE_NAME} → ${DESIRED_NODES}..."
        ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
            "ha-manager rules set node-affinity ${HA_RULE_NAME} --nodes ${DESIRED_NODES} --resources vm:${VMID}" \
            >/dev/null || die "ha-manager rules set failed"
    else
        info "  Creating node-affinity rule ${HA_RULE_NAME} → ${DESIRED_NODES}..."
        ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
            "ha-manager rules add node-affinity ${HA_RULE_NAME} --nodes ${DESIRED_NODES} --resources vm:${VMID}" \
            >/dev/null || die "ha-manager rules add failed"
    fi
fi

if [[ ${DO_REPL_RECREATE} -eq 1 ]]; then
    if [[ -n "${live_repl_id}" ]]; then
        info "  Removing stale replication job ${live_repl_id} (target ${live_repl_target})..."
        ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
            "pvesr delete ${live_repl_id} --force 1" >/dev/null 2>&1 || true
    fi
    JOB_ID="${VMID}-0"
    info "  Creating replication job ${JOB_ID} → ${HANODE} (schedule ${REPL_SCHEDULE})..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "pvesr create-local-job ${JOB_ID} ${HANODE} --schedule '${REPL_SCHEDULE}'" \
        >/dev/null || die "pvesr create-local-job failed"
elif [[ ${DO_REPL_UPDATE} -eq 1 ]]; then
    info "  Updating replication job ${live_repl_id} schedule → ${REPL_SCHEDULE}..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "pvesr update ${live_repl_id} --schedule '${REPL_SCHEDULE}'" \
        >/dev/null || die "pvesr update failed"
fi

if [[ ${DO_MIGRATE} -eq 1 ]]; then
    info "  Migrating VM ${VMID} ${actual_node}→${DESIRED_PRIMARY} (HA online migrate)..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "ha-manager crm-command migrate vm:${VMID} ${DESIRED_PRIMARY}" \
        >/dev/null || die "ha-manager crm-command migrate failed"
fi

info "  ${GN}✓${CL} cluster:ha update-service completed"
exit 0
