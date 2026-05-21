#!/usr/bin/env bash
#
# TAPPaaS Cluster LXC Service - Update (drift reconciler)
#
# Reconciles a module's live Proxmox LXC container with its desired config.
# Sibling of the cluster:vm reconciler (#192); resolves the LXC half of #203.
#
# Desired : /home/tappaas/config/<module>.json (+ zones.json for VLANs)
# Current : live `pct config <vmid>` on the container's actual node
#
# Handled (auto-applied via pct set):
#   cores, memory, swap, onboot                         -> live
#   net0 (bridge, zone0->tag, trunks0; hwaddr preserved)-> pct set; a bridge/tag
#     change additionally restarts the CT (renew DHCP in the new subnet) and
#     re-registers DNS as <vmname>.<zone0>.internal
#
# Reported but not auto-applied:
#   storage / rootfs size / GPU / bind-mounts           -> warn (need recreate)
#   node drift                                          -> warn (LXC live-migrate
#     is unsafe for GPU/bind-mount CTs; move manually)
#
# Usage: update-service.sh [--check] <module-name>
#   --check   Report drift without applying (also via TAPPAAS_CHECK=1)
#

# Remote pct commands embed locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

readonly CONFIG_DIR="/home/tappaas/config"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
readonly MGMT="mgmt"

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
[[ -z "${MODULE}" ]] && { echo "Usage: $0 [--check] <module-name>"; exit 1; }

check_json "${CONFIG_DIR}/${MODULE}.json" || exit 1
JSON="$(cat "${CONFIG_DIR}/${MODULE}.json")"
cfg() { get_config_value "$1" "$2"; }

# ── Desired state ────────────────────────────────────────────────────

VMID="$(get_config_value 'vmid')"
VMNAME="$(cfg 'vmname' "${MODULE}")"
DESIRED_NODE="$(cfg 'node' "$(get_node_hostname 0)")"
[[ "${DESIRED_NODE}" == "null" || -z "${DESIRED_NODE}" ]] && DESIRED_NODE="$(get_node_hostname 0)"
ZONE0="$(cfg 'zone0' 'mgmt')"
BRIDGE0="$(cfg 'bridge0' 'lan')"
TRUNKS0_CFG="$(cfg 'trunks0' 'NONE')"
CORES="$(cfg 'cores' '2')"
MEMORY="$(cfg 'memory' '4096')"
SWAP="$(cfg 'swap' '0')"

# Zone → VLAN tag (and trunks) from zones.json.
zone_tag() {
    local t; t=$(jq -r --arg z "$1" '.[$z].vlantag // empty' "${ZONES_FILE}" 2>/dev/null)
    [[ -z "${t}" ]] && die "Cannot resolve zone '$1' in ${ZONES_FILE}"
    echo -n "${t}"
}
DESIRED_TAG0="$(zone_tag "${ZONE0}")"
DESIRED_TRUNKS0=""
if [[ "${TRUNKS0_CFG}" != "NONE" ]]; then
    IFS=';' read -ra _zs <<< "${TRUNKS0_CFG}"
    for _z in "${_zs[@]}"; do
        [[ -z "${_z}" ]] && continue
        DESIRED_TRUNKS0="${DESIRED_TRUNKS0:+${DESIRED_TRUNKS0};}$(zone_tag "${_z}")"
    done
fi

info "${BOLD}cluster:lxc update-service: reconciling ${BL}${MODULE}${CL} (VMID ${VMID})"
[[ "${CHECK_MODE}" == "1" ]] && warn "  CHECK MODE — drift will be reported, not applied"

# ── Locate the container ─────────────────────────────────────────────

actual_node=""
ct_status=""
# shellcheck disable=SC2046
for cand in "${DESIRED_NODE}" $(get_all_node_hostnames); do
    row=$(ssh "${SSH_OPTS[@]}" "root@${cand}.${MGMT}.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson id "${VMID}" \
            '.[] | select(.vmid == $id and .type == "lxc") | "\(.node) \(.status)"' 2>/dev/null) || true
    if [[ -n "${row}" ]]; then actual_node="${row%% *}"; ct_status="${row##* }"; break; fi
done
[[ -z "${actual_node}" ]] && die "LXC ${VMID} (${MODULE}) not found on the cluster — is it installed?"
NODE_FQDN="${actual_node}.${MGMT}.internal"
info "  LXC ${VMID} is on node ${BL}${actual_node}${CL} (status: ${ct_status})"

LIVE="$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct config ${VMID}" 2>/dev/null)" \
    || die "Failed to read 'pct config ${VMID}' on ${actual_node}"
live_field() { awk -F': ' -v k="$1" '$1==k {print $2; exit}' <<< "${LIVE}"; }
# Tolerate a missing key (e.g. no trunks=) under set -e/pipefail — grep with no
# match returns 1, which would otherwise abort the script.
net_opt() { { grep -oE "$1=[^,]+" <<< "$2" || true; } | head -1 | cut -d= -f2; }

# ── Drift accumulation ───────────────────────────────────────────────

declare -a PCT_SET=()
declare -a CHANGES=()
RESTART_NEEDED=0
ZONE_CHANGED=0
plan() { PCT_SET+=("$1" "$2"); CHANGES+=("$3"); }

# cores / memory / swap (live-applied)
live_cores="$(live_field 'cores')"; live_cores="${live_cores:-1}"
[[ "${live_cores}" != "${CORES}" ]] && plan "--cores" "${CORES}" "cores: ${live_cores}→${CORES}"
live_mem="$(live_field 'memory')"; live_mem="${live_mem:-512}"
[[ "${live_mem}" != "${MEMORY}" ]] && plan "--memory" "${MEMORY}" "memory: ${live_mem}→${MEMORY}"
live_swap="$(live_field 'swap')"; live_swap="${live_swap:-0}"
[[ "${live_swap}" != "${SWAP}" ]] && plan "--swap" "${SWAP}" "swap: ${live_swap}→${SWAP}"

# onboot
live_onboot="$(live_field 'onboot')"; live_onboot="${live_onboot:-0}"
[[ "${live_onboot}" != "1" ]] && plan "--onboot" "1" "onboot: ${live_onboot}→1"

# net0 (bridge / tag / trunks; preserve live hwaddr)
live_net0="$(live_field 'net0')"
live_bridge0="$(net_opt 'bridge' "${live_net0}")"
live_tag0="$(net_opt 'tag' "${live_net0}")"
live_trunks0="$(net_opt 'trunks' "${live_net0}")"
live_hw0="$(net_opt 'hwaddr' "${live_net0}")"
if [[ "${live_bridge0}" != "${BRIDGE0}" \
   || "${live_tag0:-0}" != "${DESIRED_TAG0:-0}" \
   || "${live_trunks0}" != "${DESIRED_TRUNKS0}" ]]; then
    new_net0="name=eth0,bridge=${BRIDGE0}"
    [[ -n "${live_hw0}" ]] && new_net0="${new_net0},hwaddr=${live_hw0}"
    new_net0="${new_net0},ip=dhcp"
    [[ "${DESIRED_TAG0:-0}" != "0" ]] && new_net0="${new_net0},tag=${DESIRED_TAG0}"
    [[ -n "${DESIRED_TRUNKS0}" ]]     && new_net0="${new_net0},trunks=${DESIRED_TRUNKS0}"
    plan "--net0" "${new_net0}" \
        "net0: bridge=${live_bridge0}→${BRIDGE0}, tag=${live_tag0:-0}→${DESIRED_TAG0:-0} (zone ${ZONE0})"
    if [[ "${live_bridge0}" != "${BRIDGE0}" || "${live_tag0:-0}" != "${DESIRED_TAG0:-0}" ]]; then
        RESTART_NEEDED=1
        [[ "${live_tag0:-0}" != "${DESIRED_TAG0:-0}" ]] && ZONE_CHANGED=1
    fi
fi

# node drift (report only — LXC live-migrate is unsafe for GPU/bind-mount CTs)
[[ "${DESIRED_NODE}" != "${actual_node}" ]] \
    && warn "  node drift (${actual_node}→${DESIRED_NODE}) not auto-applied — migrate the container manually"

# ── Report ───────────────────────────────────────────────────────────

if [[ ${#CHANGES[@]} -eq 0 ]]; then
    info "  ${GN}✓${CL} LXC is in sync with config — no changes needed"
    exit 0
fi
info "  Detected drift:"
for c in "${CHANGES[@]}"; do info "    • ${c}"; done
if [[ "${CHECK_MODE}" == "1" ]]; then
    info "  CHECK MODE — no changes applied"
    exit 0
fi

# ── Apply ────────────────────────────────────────────────────────────

info "  Applying pct set on ${actual_node}..."
ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
    "pct set ${VMID} $(printf '%q ' "${PCT_SET[@]}")" >/dev/null || die "pct set failed"

if [[ ${RESTART_NEEDED} -eq 1 ]]; then
    if [[ "${ct_status}" != "running" ]]; then
        warn "  container not running — network change applied; DNS will register on next boot"
        info "  ${GN}✓${CL} cluster:lxc update-service completed"
        exit 0
    fi
    info "  Restarting LXC ${VMID} to apply network change..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct reboot ${VMID}" >/dev/null || die "pct reboot failed"

    info "  Waiting for container to come back with an IP..."
    new_ip=""
    for _ in $(seq 1 30); do
        sleep 4
        new_ip=$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "pct exec ${VMID} -- hostname -I 2>/dev/null" 2>/dev/null \
                 | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -1) || true
        [[ -n "${new_ip}" ]] && break
    done
    [[ -z "${new_ip}" ]] && die "container did not report an IPv4 after restart — cannot register DNS"
    info "  Container came up with IP ${BL}${new_ip}${CL}"

    info "  Registering DNS: ${VMNAME}.${ZONE0}.internal → ${new_ip}"
    dns-manager --no-ssl-verify add "${VMNAME}" "${ZONE0}.internal" "${new_ip}" \
        --description "${MODULE} (cluster:lxc reconcile)" \
        || warn "  dns-manager add failed for ${VMNAME}.${ZONE0}.internal"

    if [[ ${ZONE_CHANGED} -eq 1 && -n "${live_tag0:-}" && "${live_tag0}" != "0" ]]; then
        old_zone="$(jq -r --argjson t "${live_tag0}" 'to_entries[] | select(.value.vlantag == $t) | .key' "${ZONES_FILE}" 2>/dev/null | head -1)"
        if [[ -n "${old_zone}" && "${old_zone}" != "${ZONE0}" ]]; then
            info "  Removing stale DNS: ${VMNAME}.${old_zone}.internal"
            dns-manager --no-ssl-verify delete "${VMNAME}" "${old_zone}.internal" \
                || debug "  no stale DNS to remove"
        fi
    fi
fi

info "  ${GN}✓${CL} cluster:lxc update-service completed"
exit 0
