#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Migrate
#
# Migrates VMs between Proxmox cluster nodes. Attempts live migration first;
# if it fails, falls back to shutdown → offline migrate → start.
#
# Usage:
#   migrate-vm.sh <module-name>           Migrate module VM to its HANode
#   migrate-vm.sh --node <node-name>      Migrate all VMs that belong on <node> back to it
#
# Arguments:
#   module-name   Name of the module (must have config in ~/config with HANode)
#
# Options:
#   --node <name>   Target node name (e.g., tappaas1). Finds all modules whose
#                   configured 'node' matches and migrates them there if they
#                   are currently running elsewhere.
#   --offline       Skip live migration attempt; go straight to offline migration
#   -h, --help      Show this help message
#
# Examples:
#   migrate-vm.sh identity               # Migrate identity VM to its HANode
#   migrate-vm.sh --node tappaas1        # Bring all tappaas1 VMs back home
#   migrate-vm.sh --offline identity     # Force offline migration
#

set -euo pipefail

# Where the sibling controller lives (the live-OK verdict, ADR-019).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ── Logging ──────────────────────────────────────────────────────────

# Source for read_module_config (#207); local logging defs below override
# common's so output style is unchanged.
# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# HA-aware stop/start + the one `ha-manager status` parser (#434). Falls back to
# the repo copy on a system that has not re-run pre-update.sh since it landed.
if [[ -r /home/tappaas/bin/ha-vm-lib.sh ]]; then
    # shellcheck source=../../lib/ha-vm-lib.sh disable=SC1091
    . /home/tappaas/bin/ha-vm-lib.sh
else
    _SELF="$(readlink -f "${BASH_SOURCE[0]}")"
    # shellcheck source=../../lib/ha-vm-lib.sh disable=SC1091
    . "$(dirname "${_SELF}")/../../lib/ha-vm-lib.sh"
fi

readonly YW=$'\033[33m'
readonly RD=$'\033[01;31m'
readonly GN=$'\033[1;92m'
readonly DGN=$'\033[32m'
readonly BL=$'\033[36m'
readonly CL=$'\033[m'
readonly BOLD=$'\033[1m'

info()  { echo -e "${DGN}$*${CL}"; }
warn()  { echo -e "${YW}[WARN]${CL} $*"; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Configuration ────────────────────────────────────────────────────

# Overridable for the offline unit test, which needs a module fixture without a
# real deployment; every other reader of TAPPaaS config honours this variable.
readonly CONFIG_DIR="${TAPPAAS_CONFIG:-/home/tappaas/config}"
readonly MGMT="mgmt"

# Global state for HA save/restore
_HA_RULE_NAME=""
_HA_RULE_NODES=""
_HA_RULES_JSON="[]"

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage: migrate-vm.sh <module-name>
       migrate-vm.sh --node <node-name>

Migrate VMs between Proxmox cluster nodes.

Modes:
    <module-name>         Migrate a single module's VM to its HANode
    --node <node-name>    Migrate all VMs that belong on <node> back to it

Options:
    --offline             Skip the live attempt; migrate offline (stops the guest)
    --force               Authorize an OFFLINE move IF the guest cannot move live
    -h, --help            Show this help message

Examples:
    migrate-vm.sh identity               # Migrate identity to its HANode
    migrate-vm.sh --node tappaas1        # Return all tappaas1 VMs home
    migrate-vm.sh --offline identity     # Force offline migration
EOF
}

# ── Helper functions ─────────────────────────────────────────────────

# Find which node a VM is currently running on.
# Arguments: <vmid>
# Outputs: node name or empty string if VM not found/not running
get_vm_current_node() {
    local vmid="$1"
    local first_node

    # Find a reachable node to query the cluster
    first_node=$(find_reachable_node) || die "No Proxmox nodes reachable"

    ssh root@"${first_node}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${vmid}" \
            '.[] | select(.vmid == $id and .type == "qemu") | .node // empty'
}

# Find the first reachable Proxmox node
find_reachable_node() {
    local i node
    for i in 1 2 3 4 5 6 7 8 9; do
        node="tappaas${i}"
        if ping -c 1 -W 1 "${node}.${MGMT}.internal" &>/dev/null; then
            echo "${node}"
            return 0
        fi
    done
    return 1
}

# Check if a node is reachable via SSH
check_node_reachable() {
    local node="$1"
    ssh -o ConnectTimeout=5 -o BatchMode=yes \
        "root@${node}.${MGMT}.internal" "true" &>/dev/null
}

# Attempt live migration of a VM.
# Returns 0 on success, 1 on failure.
try_live_migration() {
    local vmid="$1"
    local source_node="$2"
    local target_node="$3"

    info "  Attempting live migration of VMID ${vmid}: ${BL}${source_node}${CL} → ${BL}${target_node}${CL}"

    # Check if VM is managed by HA — if so, must remove from HA first
    # to avoid HA intercepting the migrate command
    local ha_managed=false
    local ha_state=""
    ha_state=$(havm_ha_state "${source_node}.${MGMT}.internal" "vm:${vmid}")

    if [[ -n "${ha_state}" ]]; then
        ha_managed=true
        info "  VM is HA-managed (state: ${ha_state}) — temporarily removing from HA"
        save_ha_state "${vmid}" "${source_node}"
        remove_ha "${vmid}" "${source_node}"
        sleep 2
    fi

    local migrate_result=0
    ssh root@"${source_node}.${MGMT}.internal" \
        "qm migrate ${vmid} ${target_node} --online 1 --with-local-disks 1" 2>&1 \
        || migrate_result=$?

    if [[ ${migrate_result} -eq 0 ]]; then
        info "  ${GN}✓${CL} Live migration succeeded"
        if [[ "${ha_managed}" == "true" ]]; then
            restore_ha "${vmid}" "${target_node}"
        fi
        return 0
    else
        warn "Live migration failed (exit code ${migrate_result})"
        # Re-add HA on source if we removed it (VM is still there)
        if [[ "${ha_managed}" == "true" ]]; then
            restore_ha "${vmid}" "${source_node}"
        fi
        return 1
    fi
}

# Perform offline migration (shutdown → migrate → start).
do_offline_migration() {
    local vmid="$1"
    local source_node="$2"
    local target_node="$3"
    local vmname="${4:-VM ${vmid}}"

    info "  Performing offline migration of ${BL}${vmname}${CL} (VMID ${vmid}): ${BL}${source_node}${CL} → ${BL}${target_node}${CL}"

    # Check if VM is managed by HA
    local ha_managed=false
    local ha_state=""
    local source_fqdn="${source_node}.${MGMT}.internal"
    ha_state=$(havm_ha_state "${source_fqdn}" "vm:${vmid}")

    if [[ -n "${ha_state}" ]]; then
        ha_managed=true
        save_ha_state "${vmid}" "${source_node}"
    fi

    # Stop and CONFIRM stopped before migrating. havm_stop routes an HA resource
    # through the CRM (a bare `qm stop` there only queues a command) and polls
    # real state — the hand-rolled version here issued the HA stop with its exit
    # status discarded and gave up quietly after 30 polls (#434).
    info "  Stopping VM ${vmid} before migration..."
    if [[ "${ha_managed}" == "false" ]]; then
        # Not HA-managed — try a graceful guest shutdown first; havm_stop below
        # falls back to a hard stop and is what actually confirms the result.
        ssh root@"${source_fqdn}" "qm shutdown ${vmid} --timeout 90" 2>&1 \
            || warn "Graceful shutdown failed — forcing stop"
    fi
    havm_stop "${source_fqdn}" "${vmid}" qemu 120 \
        || die "VM ${vmid} did not stop — aborting migration to ${target_node}"

    if [[ "${ha_managed}" == "true" ]]; then
        info "  Removing from HA..."
        remove_ha "${vmid}" "${source_node}"
        sleep 2
    fi

    # Migrate
    info "  Migrating VM ${vmid} to ${target_node}..."
    ssh root@"${source_fqdn}" \
        "qm migrate ${vmid} ${target_node}" 2>&1 || die "Offline migration failed for VM ${vmid}"
    info "  ${GN}✓${CL} Migration completed"

    # Start on target and confirm it is RUNNING — a `qm start` that returns 0
    # only means the command was accepted. The VM is out of HA at this point, so
    # havm_start takes the plain qm path and polls the cluster API.
    info "  Starting VM ${vmid} on ${target_node}..."
    havm_start "${target_node}.${MGMT}.internal" "${vmid}" qemu 120 \
        || die "VM ${vmid} is not running on ${target_node} after migration"
    info "  ${GN}✓${CL} VM started on ${target_node}"

    # Restore HA on target node
    if [[ "${ha_managed}" == "true" ]]; then
        restore_ha "${vmid}" "${target_node}"
    fi

    return 0
}

# Save HA state (resource + EVERY rule) for a VM before removing it.
#
# Sets: _HA_RULE_NAME / _HA_RULE_NODES (the node-affinity rule, kept for the
# ha_nodes_prefer re-preference on restore) and _HA_RULES_JSON (ALL rules
# referencing this VM, verbatim).
#
# The whole object is saved, not just rule+nodes. Dropping the rest is a live
# hazard, not an untidiness: `ha-network` on this estate carries
#   strict=1
#   comment="WAN-capable nodes only: … tappaas2 has no WAN cable."
# and a save/restore that keeps only `nodes` silently downgrades that hard
# constraint to a preference. HA is then free to place the firewall on a node
# with no WAN cable, and the comment explaining why not is gone too. Anything
# the API returns is carried back (ADR-019, "full rule round-trip").
save_ha_state() {
    local vmid="$1"
    local any_node="$2"

    _HA_RULE_NAME=""
    _HA_RULE_NODES=""
    _HA_RULES_JSON="[]"

    local rule_json
    rule_json=$(ssh root@"${any_node}.${MGMT}.internal" \
        "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null || echo "[]")

    # EVERY rule for this VM, not just the first node-affinity one — a guest may
    # also carry a resource-affinity rule, and losing it is as silent as losing
    # `strict`.
    _HA_RULES_JSON=$(echo "${rule_json}" | jq -c \
        --arg res "vm:${vmid}" '[.[] | select(.resources == $res)]' 2>/dev/null || echo "[]")

    _HA_RULE_NAME=$(echo "${_HA_RULES_JSON}" | jq -r \
        '.[] | select(.type == "node-affinity") | .rule // empty' 2>/dev/null | head -1 || true)

    if [[ -n "${_HA_RULE_NAME}" ]]; then
        _HA_RULE_NODES=$(echo "${_HA_RULES_JSON}" | jq -r \
            --arg name "${_HA_RULE_NAME}" \
            '.[] | select(.rule == $name) | .nodes // empty' 2>/dev/null || true)
        local extra
        extra=$(echo "${_HA_RULES_JSON}" | jq -r \
            --arg name "${_HA_RULE_NAME}" \
            '.[] | select(.rule == $name) | [ (if .strict then "strict=\(.strict)" else empty end),
                                              (if .comment then "comment" else empty end) ] | join(", ")' 2>/dev/null || true)
        info "  Saved HA rule: ${_HA_RULE_NAME} (nodes: ${_HA_RULE_NODES}${extra:+, ${extra}})"
    fi
    # `if`, not `[[ … ]] && …`: as the LAST statement of the function that form
    # returns 1 whenever the test is false, and under `set -e` that aborts the
    # migration before restore_ha ever runs — losing the HA rule it just saved.
    local n
    n=$(echo "${_HA_RULES_JSON}" | jq -r 'length' 2>/dev/null || echo 0)
    if [[ "${n}" -gt 1 ]]; then
        info "  Saved ${n} HA rule(s) for vm:${vmid} — all will be restored"
    fi
}

# Remove HA resource and rule for a VM.
remove_ha() {
    local vmid="$1"
    local any_node="$2"

    # Remove affinity rule first (if saved)
    if [[ -n "${_HA_RULE_NAME}" ]]; then
        ssh root@"${any_node}.${MGMT}.internal" \
            "pvesh delete /cluster/ha/rules/${_HA_RULE_NAME}" 2>/dev/null || true
    fi

    # Remove HA resource
    ssh root@"${any_node}.${MGMT}.internal" \
        "ha-manager remove vm:${vmid}" 2>/dev/null || true
}

# Re-point a node-affinity node list at `prefer`, keeping the same membership.
# Input/output shape is PVE's own: "nodeA:2,nodeB:1", higher priority preferred.
# The preferred node gets 2, every other member 1; a node list that does not
# contain `prefer` is returned unchanged (nothing sensible to re-point).
ha_nodes_prefer() {
    local nodes="$1" prefer="$2" out="" entry name
    [[ ",${nodes}," == *",${prefer}:"* ]] || { printf '%s' "${nodes}"; return; }
    local IFS=','
    for entry in ${nodes}; do
        name="${entry%%:*}"
        [[ -z "${name}" ]] && continue
        if [[ "${name}" == "${prefer}" ]]; then
            out="${out:+${out},}${name}:2"
        else
            out="${out:+${out},}${name}:1"
        fi
    done
    printf '%s' "${out}"
}

# Restore HA resource and affinity rule for a VM after migration.
restore_ha() {
    local vmid="$1"
    local node="$2"

    info "  Re-adding VM ${vmid} to HA on ${node}..."
    ssh root@"${node}.${MGMT}.internal" \
        "ha-manager add vm:${vmid} --state started" 2>/dev/null || {
        warn "Could not re-add VM ${vmid} to HA — please add manually"
        return
    }

    # Restore the affinity rule if one was saved, with the priorities re-pointed
    # at where the VM now is (#528). Replaying the pre-migration string leaves
    # the source node preferred, so the CRM immediately tries to move the VM
    # back — an online migration that cannot succeed on a CPU-heterogeneous
    # cluster, leaving the service stuck in 'migrate'. Higher priority wins.
    # Replay every saved rule with every property it had. Only `nodes` on the
    # node-affinity rule is rewritten, to prefer where the VM now IS (#528) —
    # everything else, `strict` and `comment` included, goes back verbatim.
    local rules_n
    rules_n=$(echo "${_HA_RULES_JSON:-[]}" | jq -r 'length' 2>/dev/null || echo 0)
    if [[ "${rules_n}" -gt 0 ]]; then
        local rule_obj rname rtype rnodes rstrict rcomment args
        while IFS= read -r rule_obj; do
            [[ -n "${rule_obj}" ]] || continue
            rname=$(jq -r '.rule'          <<< "${rule_obj}")
            rtype=$(jq -r '.type'          <<< "${rule_obj}")
            rnodes=$(jq -r '.nodes   // ""' <<< "${rule_obj}")
            rstrict=$(jq -r '.strict // ""' <<< "${rule_obj}")
            rcomment=$(jq -r '.comment // ""' <<< "${rule_obj}")

            args=(--rule "${rname}" --type "${rtype}" --resources "vm:${vmid}")
            if [[ -n "${rnodes}" ]]; then
                # Prefer the destination so the CRM does not immediately fail
                # the guest back (#528 / PR #529).
                rnodes="$(ha_nodes_prefer "${rnodes}" "${node}")"
                args+=(--nodes "${rnodes}")
            fi
            [[ -n "${rstrict}"  ]] && args+=(--strict "${rstrict}")
            [[ -n "${rcomment}" ]] && args+=(--comment "${rcomment}")

            info "  Restoring HA rule: ${rname} (${rtype}${rnodes:+, nodes: ${rnodes}}${rstrict:+, strict=${rstrict}})"
            # printf %q so a comment with spaces/quotes survives the remote shell
            # intact — the WAN-pin comment is a sentence, not a token.
            ssh root@"${node}.${MGMT}.internal" \
                "pvesh create /cluster/ha/rules $(printf '%q ' "${args[@]}")" 2>/dev/null || {
                warn "Could not restore HA rule '${rname}' — please recreate manually"
            }
        done < <(echo "${_HA_RULES_JSON}" | jq -c '.[]' 2>/dev/null)
    fi
}

# Migrate a single module by name.
# Determines source/target, attempts live then offline.
migrate_module() {
    local module="$1"
    local force_offline="${2:-false}"
    local allow_offline="${3:-false}"
    local module_json="${CONFIG_DIR}/${module}.json"

    if [[ ! -f "${module_json}" ]]; then
        die "Module config not found: ${module_json}"
    fi

    local cfg vmid vmname ha_node config_node
    cfg=$(read_module_config "${module}")
    vmid=$(echo "${cfg}" | jq -r '.vmid // empty')
    vmname=$(echo "${cfg}" | jq -r '.vmname // empty')
    ha_node=$(echo "${cfg}" | jq -r '.HANode // empty')
    config_node=$(echo "${cfg}" | jq -r '.node // empty')

    if [[ -z "${vmid}" ]]; then
        die "Module '${module}' has no vmid configured"
    fi
    if [[ -z "${ha_node}" ]]; then
        die "Module '${module}' has no HANode configured — cannot determine migration target"
    fi

    vmname="${vmname:-${module}}"

    # Find where the VM is currently running
    local current_node
    current_node=$(get_vm_current_node "${vmid}")

    if [[ -z "${current_node}" ]]; then
        die "VM ${vmid} (${vmname}) is not running on any node"
    fi

    # Determine target: migrate to the HA node (the "other" node)
    local target_node
    if [[ "${current_node}" == "${ha_node}" ]]; then
        # VM is on its HA node — migrate back to its primary (config) node
        target_node="${config_node}"
        info "VM ${BL}${vmname}${CL} is on HA node ${BL}${ha_node}${CL} — migrating back to primary ${BL}${config_node}${CL}"
    elif [[ "${current_node}" == "${config_node}" ]]; then
        # VM is on its primary node — migrate to HA node
        target_node="${ha_node}"
        info "VM ${BL}${vmname}${CL} is on primary node ${BL}${config_node}${CL} — migrating to HA node ${BL}${ha_node}${CL}"
    else
        # VM is on some other node — migrate to config node
        target_node="${config_node}"
        info "VM ${BL}${vmname}${CL} is on ${BL}${current_node}${CL} — migrating to configured node ${BL}${config_node}${CL}"
    fi

    if [[ "${current_node}" == "${target_node}" ]]; then
        info "VM ${BL}${vmname}${CL} (VMID ${vmid}) is already on ${BL}${target_node}${CL} — nothing to do"
        return 0
    fi

    # Check target node is reachable
    if ! check_node_reachable "${target_node}"; then
        die "Target node ${target_node} is not reachable"
    fi

    echo ""
    info "${BOLD}Migrating ${BL}${vmname}${CL}${BOLD} (VMID ${vmid}): ${BL}${current_node}${CL} → ${BL}${target_node}${CL}${BOLD}${CL}"

    # ADR-019: NO SILENT DISRUPTIVE FALLBACK.
    #
    # This used to attempt a live migration and, on any failure, "fall back to
    # offline" — which stops the guest. An operator who asked to move a service
    # got it stopped and restarted instead, learning only from the log. Downtime
    # is now always an explicit decision:
    #
    #   --offline  do it offline, no live attempt (the operator has decided)
    #   --force    authorize offline IF the guest cannot move live
    #   neither    live only; if that is impossible, refuse and say why
    #
    # The verdict comes first, so the refusal happens BEFORE anything is touched
    # rather than after a failed attempt has already disturbed the guest.
    if [[ "${force_offline}" == "true" ]]; then
        info "  --offline given — skipping the live attempt"
        do_offline_migration "${vmid}" "${current_node}" "${target_node}" "${vmname}"
        return $?
    fi

    # Overridable so the offline unit test can script the verdict without a
    # cluster — the same seam TAPPAAS_HAVM_EXEC provides for the CRM.
    local liveok_bin="${TAPPAAS_LIVEOK_BIN:-${SCRIPT_DIR}/proxmox-controller}"
    local live_rc=0
    "${liveok_bin}" live-ok "${module}" "${target_node}" || live_rc=$?
    if [[ "${live_rc}" -eq 0 ]]; then
        if try_live_migration "${vmid}" "${current_node}" "${target_node}"; then
            return 0
        fi
        # Live was judged possible and still failed: that is a real fault, not a
        # cue to stop the guest. Say so and stop — the operator decides whether
        # an offline move is acceptable.
        error "Live migration failed although the destination offers every CPU feature."
        error "Not falling back to an offline move: that would stop ${vmname}."
        error "Re-run with --force (or --offline) if downtime is acceptable."
        return 1
    fi

    if [[ "${allow_offline}" != "true" ]]; then
        warn "${vmname} cannot move live to ${target_node} (see the verdict above)."
        warn "An offline migration stops it. Re-run with --force to authorize that."
        return 10
    fi
    info "  --force given — migrating OFFLINE (the guest will stop and restart)"
    do_offline_migration "${vmid}" "${current_node}" "${target_node}" "${vmname}"
}

# Migrate all VMs that belong on the given node back to it.
migrate_to_node() {
    local target_node="$1"
    local force_offline="${2:-false}"

    info "${BOLD}Migrating all VMs back to node: ${BL}${target_node}${CL}"
    echo ""

    if ! check_node_reachable "${target_node}"; then
        die "Target node ${target_node} is not reachable"
    fi

    # Find all modules whose configured 'node' matches the target
    local migrated=0
    local skipped=0
    local failed=0

    for module_json in "${CONFIG_DIR}"/*.json; do
        [[ -f "${module_json}" ]] || continue
        local basename
        basename=$(basename "${module_json}" .json)

        # Skip non-module configs (configuration.json, zones.json, etc.)
        # Read normalized once per module (Pattern A / flat agnostic; #207).
        local cfg vmid
        cfg=$(read_module_config "${basename}" 2>/dev/null) || continue
        vmid=$(echo "${cfg}" | jq -r '.vmid // empty')
        if [[ -z "${vmid}" ]]; then
            continue
        fi

        local config_node
        config_node=$(echo "${cfg}" | jq -r '.node // empty')

        if [[ "${config_node}" != "${target_node}" ]]; then
            continue
        fi

        # Check where the VM is actually running
        local current_node
        current_node=$(get_vm_current_node "${vmid}")

        if [[ -z "${current_node}" ]]; then
            warn "VM ${vmid} (${basename}) is not running — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "${current_node}" == "${target_node}" ]]; then
            info "  ${GN}✓${CL} ${basename} (VMID ${vmid}) — already on ${target_node}"
            skipped=$((skipped + 1))
            continue
        fi

        # This VM needs migration
        local vmname
        vmname=$(echo "${cfg}" | jq -r '.vmname // empty')
        vmname="${vmname:-${basename}}"

        echo ""
        info "${BOLD}Migrating ${BL}${vmname}${CL}${BOLD} (VMID ${vmid}): ${BL}${current_node}${CL} → ${BL}${target_node}${CL}${BOLD}${CL}"

        local migrate_ok=false
        if [[ "${force_offline}" == "true" ]]; then
            info "  --offline flag set — using offline migration"
            if do_offline_migration "${vmid}" "${current_node}" "${target_node}" "${vmname}"; then
                migrate_ok=true
            fi
        else
            if try_live_migration "${vmid}" "${current_node}" "${target_node}"; then
                migrate_ok=true
            else
                echo ""
                info "  Falling back to offline migration..."
                if do_offline_migration "${vmid}" "${current_node}" "${target_node}" "${vmname}"; then
                    migrate_ok=true
                fi
            fi
        fi

        if [[ "${migrate_ok}" == "true" ]]; then
            migrated=$((migrated + 1))
        else
            error "Failed to migrate ${vmname} (VMID ${vmid})"
            failed=$((failed + 1))
        fi
    done

    echo ""
    info "${BOLD}Migration summary for node ${BL}${target_node}${CL}:"
    info "  Migrated:  ${migrated}"
    info "  Skipped:   ${skipped}"
    if [[ ${failed} -gt 0 ]]; then
        error "  Failed:    ${failed}"
        return 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local mode=""            # "module" or "node"
    local target=""          # module name or node name
    local force_offline=false
    local allow_offline=false

    # Parse arguments
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --node)
                if [[ -z "${2:-}" ]]; then
                    die "--node requires a node name argument"
                fi
                mode="node"
                target="$2"
                shift 2
                ;;
            --offline)
                force_offline=true
                shift
                ;;
            --force)
                # Authorizes downtime IF the guest cannot move live; distinct
                # from --offline, which skips the live attempt outright
                # (ADR-019).
                allow_offline=true
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -n "${mode}" ]]; then
                    die "Unexpected argument: $1"
                fi
                mode="module"
                target="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${mode}" || -z "${target}" ]]; then
        die "No module name or --node specified"
    fi

    # Validate dependencies
    command -v jq &>/dev/null || die "Required command 'jq' not found"
    command -v ssh &>/dev/null || die "Required command 'ssh' not found"

    echo ""
    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS VM Migration                        ${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    case "${mode}" in
        module)
            migrate_module "${target}" "${force_offline}" "${allow_offline}"
            ;;
        node)
            migrate_to_node "${target}" "${force_offline}"
            ;;
    esac

    echo ""
    info "${GN}${BOLD}Migration completed${CL}"
}

# Only run when executed directly — allows test-migrate-vm.sh to source this and
# exercise do_offline_migration/try_live_migration against a stubbed cluster,
# the same guard proxmox-controller uses.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
