#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Update (drift reconciler)
#
# Reconciles a module's live Proxmox VM with its desired configuration.
# Called by update-module.sh (Step 4) for any module that dependsOn cluster:vm.
#
# Desired state : /home/tappaas/config/<module>.json  (+ zones.json for VLANs)
# Current state : live `qm config <vmid>` on the VM's actual node
#
# For each parameter that drifts it applies the safe change; network/zone
# changes trigger a reboot so the VM renews DHCP in the new subnet, then DNS
# is (re)registered as <vmname>.<zone0>.internal. Resolves issue #192.
#
# Handled (auto-applied):
#   net0/net1 (bridge,zone->tag,trunks; MAC preserved) -> qm set; a bridge/tag
#     change additionally reboots + waits for IP + updates DNS (trunk/MAC-only
#     changes apply live, no reboot)
#   cores, memory, cputype, vmtag, vmname               -> qm set
#   diskSize (grow only)                                -> resize-disk.sh
#   node (only if module does NOT dependOn cluster:ha)  -> qm migrate
#
# Reported but not auto-applied:
#   storage drift                  -> warn (move-disk left to the operator)
#   bios drift                     -> fatal (requires power-off / reinstall)
#   vmid / image* / os / cloudInit -> not reconcilable here (implies reinstall)
#   node drift on HA modules       -> deferred to cluster:ha drift handling
#
# Usage: update-service.sh [--check] <module-name>
#   --check   Report drift without applying (also via TAPPAAS_CHECK=1)
#
# Exit codes:
#   0  In sync, or all detected drift applied successfully
#   1  Drift detected but could not be safely applied (fatal)
#

# Remote `qm`/`pvesh` commands intentionally embed locally-computed values
# (VMID, node, sizes) that expand client-side before being sent over ssh.
# shellcheck disable=SC2029
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CONFIG_DIR="/home/tappaas/config"
readonly ZONES_FILE="${CONFIG_DIR}/zones.json"
readonly MGMT="mgmt"

# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/vm-net.sh disable=SC1091
. "${SCRIPT_DIR}/../../lib/vm-net.sh"

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
JSON="$(cat "${CONFIG_DIR}/${MODULE}.json")"

# get_config_value exits when a required (empty-default) key is missing, so all
# optional reads pass an explicit default (sentinel "__none__" = unset).
cfg() { get_config_value "$1" "$2"; }

# ── Desired state (from module.json + zones.json) ────────────────────

VMID="$(get_config_value 'vmid')"
VMNAME="$(cfg 'vmname' "${MODULE}")"
DESIRED_NODE="$(cfg 'node' "$(get_node_hostname 0)")"
[[ "${DESIRED_NODE}" == "null" || -z "${DESIRED_NODE}" ]] && DESIRED_NODE="$(get_node_hostname 0)"

ZONE0="$(cfg 'zone0' 'mgmt')"
BRIDGE0="$(cfg 'bridge0' 'lan')"
MAC0_CFG="$(cfg 'mac0' '__none__')"
TRUNKS0_CFG="$(cfg 'trunks0' 'NONE')"

BRIDGE1="$(cfg 'bridge1' 'NONE')"
ZONE1="$(cfg 'zone1' 'mgmt')"
MAC1_CFG="$(cfg 'mac1' '__none__')"
TRUNKS1_CFG="$(cfg 'trunks1' 'NONE')"

CORES="$(cfg 'cores' '2')"
MEMORY="$(cfg 'memory' '4096')"
CPUTYPE="$(cfg 'cputype' 'host')"
VMTAG="$(cfg 'vmtag' '__none__')"
DISKSIZE="$(cfg 'diskSize' '__none__')"
STORAGE="$(cfg 'storage' '__none__')"
BIOS="$(cfg 'bios' '__none__')"

info "${BOLD}cluster:vm update-service: reconciling ${BL}${MODULE}${CL} (VMID ${VMID})"
[[ "${CHECK_MODE}" == "1" ]] && warn "  CHECK MODE — drift will be reported, not applied"

# Resolve desired VLAN tags (errors out on undefined/inactive zone).
DESIRED_TAG0="$(vmnet_zone_vlantag "${ZONE0}" "${ZONES_FILE}")" || die "Cannot resolve zone0 '${ZONE0}'"
DESIRED_TRUNKS0=""
[[ "${TRUNKS0_CFG}" != "NONE" ]] && DESIRED_TRUNKS0="$(vmnet_resolve_trunks "${TRUNKS0_CFG}" "${ZONES_FILE}")"

# ── Locate the VM's actual node + status (cluster-wide) ──────────────

actual_node=""
vm_status=""
# shellcheck disable=SC2046  # word-splitting of hostnames is intended
for cand in "${DESIRED_NODE}" $(get_all_node_hostnames); do
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

# ── Read live config ─────────────────────────────────────────────────

LIVE="$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "qm config ${VMID}" 2>/dev/null)" \
    || die "Failed to read 'qm config ${VMID}' on ${actual_node}"

live_field() { awk -F': ' -v k="$1" '$1==k {print $2; exit}' <<< "${LIVE}"; }

# Proxmox stores tags lowercased, de-duplicated and ';'-joined, while module
# JSON may use mixed case and ',' separators. Canonicalise both sides so the
# comparison doesn't churn on cosmetic differences.
normalize_tags() {
    tr '[:upper:]' '[:lower:]' <<< "$1" | tr ',; ' '\n' | sed '/^$/d' | sort -u | paste -sd';' -
}

# ── Drift accumulation ───────────────────────────────────────────────

declare -a QM_SET_ARGS=()   # args appended to a single `qm set`
declare -a CHANGES=()       # human-readable summary
REBOOT_NEEDED=0             # bridge/tag change (new subnet) → reboot + IP + DNS
ZONE_CHANGED=0              # triggers stale-DNS cleanup
FATAL=0
QM_DELETE_NET1=0
DISK_GROW=0
NODE_MIGRATE=0

plan_set() { QM_SET_ARGS+=("$1" "$2"); CHANGES+=("$3"); }

# ── net0 ─────────────────────────────────────────────────────────────

live_net0="$(live_field 'net0')"
live_bridge0="$(vmnet_parse "${live_net0}" bridge)"
live_tag0="$(vmnet_parse "${live_net0}" tag)"
live_trunks0="$(vmnet_parse "${live_net0}" trunks)"
live_mac0="$(vmnet_parse "${live_net0}" mac)"
live_queues0="$(vmnet_parse "${live_net0}" queues)"
OLD_TAG0="${live_tag0:-0}"

# Preserve the live MAC unless the module explicitly pins mac0.
desired_mac0="${live_mac0}"
[[ "${MAC0_CFG}" != "__none__" ]] && desired_mac0="${MAC0_CFG}"

if [[ "${live_bridge0}" != "${BRIDGE0}" \
   || "${live_tag0:-0}" != "${DESIRED_TAG0:-0}" \
   || "${live_trunks0}" != "${DESIRED_TRUNKS0}" \
   || ( "${MAC0_CFG}" != "__none__" && "${live_mac0}" != "${MAC0_CFG}" ) ]]; then
    # Preserve the live queues value — never change queues on a running NIC
    # (it forces a disruptive hot-replug; see issue #194).
    netopts="$(vmnet_build_netopts "${BRIDGE0}" "${desired_mac0}" "${DESIRED_TAG0}" "${DESIRED_TRUNKS0}" "${live_queues0}")"
    plan_set "--net0" "${netopts}" \
        "net0: bridge=${live_bridge0}→${BRIDGE0}, tag=${live_tag0:-0}→${DESIRED_TAG0:-0} (zone ${ZONE0})"
    # Only a bridge or tag change moves the VM to a new subnet (needs reboot to
    # renew DHCP). A trunk- or MAC-only change applies live on the bridge.
    if [[ "${live_bridge0}" != "${BRIDGE0}" || "${live_tag0:-0}" != "${DESIRED_TAG0:-0}" ]]; then
        REBOOT_NEEDED=1
    fi
    [[ "${live_tag0:-0}" != "${DESIRED_TAG0:-0}" ]] && ZONE_CHANGED=1
fi

# ── net1 (add / modify / remove) ─────────────────────────────────────

live_net1="$(live_field 'net1')"
if [[ "${BRIDGE1}" != "NONE" ]]; then
    desired_tag1="$(vmnet_zone_vlantag "${ZONE1}" "${ZONES_FILE}")" || die "Cannot resolve zone1 '${ZONE1}'"
    desired_trunks1=""
    [[ "${TRUNKS1_CFG}" != "NONE" ]] && desired_trunks1="$(vmnet_resolve_trunks "${TRUNKS1_CFG}" "${ZONES_FILE}")"
    live_bridge1="$(vmnet_parse "${live_net1}" bridge)"
    live_tag1="$(vmnet_parse "${live_net1}" tag)"
    live_trunks1="$(vmnet_parse "${live_net1}" trunks)"
    live_mac1="$(vmnet_parse "${live_net1}" mac)"
    live_queues1="$(vmnet_parse "${live_net1}" queues)"
    desired_mac1="${live_mac1}"
    [[ "${MAC1_CFG}" != "__none__" ]] && desired_mac1="${MAC1_CFG}"
    if [[ -z "${live_net1}" \
       || "${live_bridge1}" != "${BRIDGE1}" \
       || "${live_tag1:-0}" != "${desired_tag1:-0}" \
       || "${live_trunks1}" != "${desired_trunks1}" \
       || ( "${MAC1_CFG}" != "__none__" && "${live_mac1}" != "${MAC1_CFG}" ) ]]; then
        # Preserve live queues (see issue #194 — never hot-change queues).
        netopts1="$(vmnet_build_netopts "${BRIDGE1}" "${desired_mac1}" "${desired_tag1}" "${desired_trunks1}" "${live_queues1}")"
        plan_set "--net1" "${netopts1}" \
            "net1: bridge=${live_bridge1:-none}→${BRIDGE1}, tag=${live_tag1:-0}→${desired_tag1:-0} (zone ${ZONE1})"
        # Adding the NIC, or changing its bridge/tag, needs a reboot; a
        # trunk/MAC-only change applies live.
        if [[ -z "${live_net1}" || "${live_bridge1}" != "${BRIDGE1}" \
           || "${live_tag1:-0}" != "${desired_tag1:-0}" ]]; then
            REBOOT_NEEDED=1
        fi
    fi
elif [[ -n "${live_net1}" ]]; then
    # Module no longer declares a second NIC but the VM has one → remove it.
    CHANGES+=("net1: removing (no bridge1 in config)")
    REBOOT_NEEDED=1
    QM_DELETE_NET1=1
fi

# ── cores / memory / cputype ─────────────────────────────────────────

live_cores="$(live_field 'cores')"; live_cores="${live_cores:-1}"
[[ "${live_cores}" != "${CORES}" ]] && plan_set "--cores" "${CORES}" "cores: ${live_cores}→${CORES}"

live_mem="$(live_field 'memory')"; live_mem="${live_mem:-512}"
[[ "${live_mem}" != "${MEMORY}" ]] && plan_set "--memory" "${MEMORY}" "memory: ${live_mem}→${MEMORY}"

live_cpu="$(live_field 'cpu')"; live_cpu="${live_cpu:-kvm64}"
[[ "${live_cpu}" != "${CPUTYPE}" ]] && plan_set "--cpu" "${CPUTYPE}" "cputype: ${live_cpu}→${CPUTYPE}"

# ── tags ─────────────────────────────────────────────────────────────

if [[ "${VMTAG}" != "__none__" ]]; then
    live_tags="$(live_field 'tags')"
    if [[ "$(normalize_tags "${live_tags}")" != "$(normalize_tags "${VMTAG}")" ]]; then
        plan_set "--tags" "${VMTAG}" "tags: ${live_tags:-none}→${VMTAG}"
    fi
fi

# ── name ─────────────────────────────────────────────────────────────

live_name="$(live_field 'name')"
[[ -n "${live_name}" && "${live_name}" != "${VMNAME}" ]] \
    && plan_set "--name" "${VMNAME}" "name: ${live_name}→${VMNAME}"

# ── bios (immutable while running) ───────────────────────────────────

if [[ "${BIOS}" != "__none__" ]]; then
    live_bios="$(live_field 'bios')"; live_bios="${live_bios:-seabios}"
    if [[ "${live_bios}" != "${BIOS}" ]]; then
        error "  bios drift (${live_bios}→${BIOS}) cannot be applied to a live VM — requires power-off / reinstall"
        FATAL=1
    fi
fi

# ── storage (report only) ────────────────────────────────────────────

if [[ "${STORAGE}" != "__none__" ]]; then
    live_scsi0="$(live_field 'scsi0')"
    live_storage="${live_scsi0%%:*}"
    [[ -n "${live_storage}" && "${live_storage}" != "${STORAGE}" ]] \
        && warn "  storage drift (${live_storage}→${STORAGE}) not auto-applied — use 'qm move-disk' manually"
fi

# ── diskSize (grow only) ─────────────────────────────────────────────

if [[ "${DISKSIZE}" != "__none__" ]]; then
    live_size="$(sed -n 's/.*size=\([0-9]\+[GMTK]\?\).*/\1/p' <<< "$(live_field 'scsi0')")"
    if [[ -n "${live_size}" && "${live_size}" != "${DISKSIZE}" ]]; then
        CHANGES+=("diskSize: ${live_size}→${DISKSIZE} (via resize-disk.sh)")
        DISK_GROW=1
    fi
fi

# ── node (HA-aware) ──────────────────────────────────────────────────

if [[ "${DESIRED_NODE}" != "${actual_node}" ]]; then
    if read_module_config "${MODULE}" | jq -e '(.dependsOn // []) | index("cluster:ha") != null' >/dev/null 2>&1; then
        warn "  node drift (${actual_node}→${DESIRED_NODE}) deferred to cluster:ha drift handling"
    else
        CHANGES+=("node: ${actual_node}→${DESIRED_NODE} (qm migrate)")
        NODE_MIGRATE=1
    fi
fi

# ── Report ───────────────────────────────────────────────────────────

if [[ ${#CHANGES[@]} -eq 0 && ${FATAL} -eq 0 ]]; then
    info "  ${GN}✓${CL} VM is in sync with config — no changes needed"
    exit 0
fi

info "  Detected drift:"
for c in "${CHANGES[@]}"; do info "    • ${c}"; done

[[ ${FATAL} -eq 1 ]] && die "Unreconcilable drift detected — aborting (see errors above)"

if [[ "${CHECK_MODE}" == "1" ]]; then
    info "  CHECK MODE — no changes applied"
    exit 0
fi

# ── Apply ────────────────────────────────────────────────────────────

if [[ ${#QM_SET_ARGS[@]} -gt 0 ]]; then
    info "  Applying qm set on ${actual_node}..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "qm set ${VMID} $(printf '%q ' "${QM_SET_ARGS[@]}")" >/dev/null || die "qm set failed"
fi

if [[ ${QM_DELETE_NET1} -eq 1 ]]; then
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "qm set ${VMID} --delete net1" >/dev/null \
        || die "qm set --delete net1 failed"
fi

if [[ ${DISK_GROW} -eq 1 ]]; then
    info "  Growing disk to ${DISKSIZE}..."
    /home/tappaas/bin/resize-disk.sh "${VMNAME}" "${DISKSIZE}" || die "resize-disk.sh failed"
fi

if [[ ${NODE_MIGRATE} -eq 1 ]]; then
    info "  Migrating VM ${VMID} ${actual_node}→${DESIRED_NODE}..."
    online_flag=0
    [[ "${vm_status}" == "running" ]] && online_flag=1
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "qm migrate ${VMID} ${DESIRED_NODE} --online ${online_flag}" >/dev/null || die "qm migrate failed"
    actual_node="${DESIRED_NODE}"
    NODE_FQDN="${actual_node}.${MGMT}.internal"
fi

# ── Subnet change: reboot so the guest renews DHCP in the new subnet ─
# Only bridge/tag changes get here; trunk- and MAC-only net changes were
# already applied above via qm set and need no reboot.

if [[ ${REBOOT_NEEDED} -eq 1 ]]; then
    if [[ "${vm_status}" != "running" ]]; then
        warn "  VM not running — network change applied to config; DNS will register on next boot"
        info "  ${GN}✓${CL} cluster:vm update-service completed"
        exit 0
    fi

    info "  Rebooting VM ${VMID} to apply network change..."
    ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "qm reboot ${VMID}" >/dev/null || die "qm reboot failed"

    info "  Waiting for VM to come back with an IP..."
    new_ip=""
    for _ in $(seq 1 30); do
        sleep 4
        qm_iface=$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
            "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null) || continue
        new_ip=$(jq -r '.[] | select(.name | test("^(lo|docker)") | not)
                         | ."ip-addresses"[]?
                         | select(."ip-address-type" == "ipv4")
                         | ."ip-address"' <<< "${qm_iface}" 2>/dev/null | grep -v '^127\.' | head -1)
        [[ -n "${new_ip}" ]] && break
    done

    [[ -z "${new_ip}" ]] && die "VM did not report an IPv4 after reboot — cannot register DNS"
    info "  VM came up with IP ${BL}${new_ip}${CL}"

    # ── DNS: register new record; drop the stale one if the zone changed ─
    new_domain="${ZONE0}.internal"
    info "  Registering DNS: ${VMNAME}.${new_domain} → ${new_ip}"
    dns-manager --no-ssl-verify add "${VMNAME}" "${new_domain}" "${new_ip}" \
        --description "${MODULE} (cluster:vm reconcile)" \
        || warn "  dns-manager add failed for ${VMNAME}.${new_domain}"

    if [[ ${ZONE_CHANGED} -eq 1 ]]; then
        old_zone="$(vmnet_zone_for_tag "${OLD_TAG0}" "${ZONES_FILE}")"
        if [[ -n "${old_zone}" && "${old_zone}" != "${ZONE0}" ]]; then
            info "  Removing stale DNS: ${VMNAME}.${old_zone}.internal"
            # A missing old record is normal (install-service registers no DNS),
            # so a failure here is informational, not a warning.
            dns-manager --no-ssl-verify delete "${VMNAME}" "${old_zone}.internal" \
                || debug "  no stale DNS to remove for ${VMNAME}.${old_zone}.internal"
        fi
    fi
fi

info "  ${GN}✓${CL} cluster:vm update-service completed"
exit 0
