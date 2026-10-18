#!/usr/bin/env bash
#
# TAPPaaS module suspend / resume (#428)
#
# Suspend pauses a module and keeps everything else: its guest is stopped, its
# config, backups, DNS and published route stay. The config records
# `"suspended": true`, which takes the module out of the nightly update and makes
# the health check report it as suspended rather than down. Resume starts it
# again and clears the mark.
#
# Stopping is done the way that stays stopped:
#   - an HA guest through the CRM (ha-vm-lib), which then keeps it stopped —
#     a failover or a node reboot does not bring it back;
#   - any other guest with `onboot` cleared, so a node reboot does not start it.
# Resume reverses both (onboot 1, as TAPPaaS creates every guest).
#
# Usage: suspend-module.sh <module> [--resume]
#
# Exit: 0 done (or already so), 1 refused or failed.

set -euo pipefail

# shellcheck source=../../lib/common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh
if [[ -r /home/tappaas/bin/ha-vm-lib.sh ]]; then
    # shellcheck source=../../lib/ha-vm-lib.sh disable=SC1091
    . /home/tappaas/bin/ha-vm-lib.sh
else
    _SELF="$(readlink -f "${BASH_SOURCE[0]}")"
    # shellcheck source=../../lib/ha-vm-lib.sh disable=SC1091
    . "$(dirname "${_SELF}")/../../lib/ha-vm-lib.sh"
fi

MODULE=""
RESUME=0
for a in "$@"; do
    case "${a}" in
        --resume) RESUME=1 ;;
        -h|--help) echo "Usage: $0 <module> [--resume]"; exit 0 ;;
        -*) die "unknown option '${a}'" ;;
        *) MODULE="${a}" ;;
    esac
done
[[ -n "${MODULE}" ]] || die "Usage: $0 <module> [--resume]"

CFG="${CONFIG_DIR:-/home/tappaas/config}/${MODULE}.json"
[[ -f "${CFG}" ]] || die "module '${MODULE}' is not installed (no ${CFG})"
JSON="$(normalize_module_config < "${CFG}")"
field() { jq -r --arg f "$1" '.[$f] // empty | tostring' <<< "${JSON}"; }

case "$(field kind)" in
    machine) die "'${MODULE}' is a machine: TAPPaaS does not switch machines on and off" ;;
esac
case "$(field status | tr '[:upper:]' '[:lower:]')" in
    archived|external) die "'${MODULE}' is $(field status): it has no lifecycle to pause" ;;
esac
VMID="$(field vmid)"
[[ -n "${VMID}" ]] || die "'${MODULE}' has no vmid — nothing to suspend"
TYPE=vm
jq -e '(.dependsOn // []) | index("cluster:lxc") != null' <<< "${JSON}" >/dev/null && TYPE=lxc
CLI=qm; [[ "${TYPE}" == lxc ]] && CLI=pct
SUSPENDED="$(field suspended)"

# Where the guest is now (it may have failed over).
NODE=""
for n in $(get_all_node_hostnames); do
    NODE="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@${n}.mgmt.internal" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
        | jq -r --argjson v "${VMID}" '.[] | select(.vmid == $v) | .node' 2>/dev/null || true)"
    [[ -n "${NODE}" ]] && break
done
[[ -n "${NODE}" ]] || die "guest ${VMID} of '${MODULE}' is not on the cluster"
FQDN="${NODE}.mgmt.internal"
RID="$(havm_resource_id "${TYPE}" "${VMID}")"
HA=0; havm_is_ha_managed "${FQDN}" "${RID}" && HA=1

if [[ "${RESUME}" == "0" ]]; then
    info "${BOLD}Suspending ${MODULE}${CL} (${TYPE} ${VMID} on ${NODE})"
    [[ "${SUSPENDED}" == "true" ]] && info "  already marked suspended — making sure the guest is stopped"
    if [[ "${HA}" == "0" ]]; then
        ssh -n "root@${FQDN}" "${CLI} set ${VMID} --onboot 0" >/dev/null \
            || die "could not clear onboot on ${VMID} — not suspending (a node reboot would start it)"
    fi
    havm_stop "${FQDN}" "${VMID}" "${TYPE}" "${STOP_TIMEOUT:-180}" \
        || die "${VMID} did not stop — '${MODULE}' is not suspended"
    jq_module_write "${MODULE}" '.suspended = true' || die "stopped, but could not mark '${MODULE}' suspended in its config"
    info "  ${GN}✓${CL} ${MODULE} suspended: stopped$([[ "${HA}" == 1 ]] && echo ", held stopped by HA" || echo ", onboot off"); config, backups and its route are kept"
    info "  Resume with: module-manager resume ${MODULE}"
else
    info "${BOLD}Resuming ${MODULE}${CL} (${TYPE} ${VMID} on ${NODE})"
    if [[ "${HA}" == "0" ]]; then
        ssh -n "root@${FQDN}" "${CLI} set ${VMID} --onboot 1" >/dev/null || warn "  could not set onboot on ${VMID} — set it by hand"
    fi
    havm_start "${FQDN}" "${VMID}" "${TYPE}" "${START_TIMEOUT:-180}" \
        || die "${VMID} did not start — '${MODULE}' stays marked suspended"
    jq_module_write "${MODULE}" 'del(.suspended)' || die "started, but could not clear the suspended mark of '${MODULE}'"
    info "  ${GN}✓${CL} ${MODULE} resumed"
fi
