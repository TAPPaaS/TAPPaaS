#!/usr/bin/env bash
#
# TAPPaaS Cluster LXC Service - Install
#
# Creates an LXC container on the Proxmox cluster for a consuming module.
# Sibling of cluster:vm install-service. Called by install-module.sh for any
# module that lists "cluster:lxc" in dependsOn. Resolves issue #203.
#
# Steps:
#   1. Copy <module>.json (+ optional <module>.meta.json) to the target node
#   2. Run the shared /root/tappaas/Create-TAPPaaS-LXC.sh provisioner
#   3. Wait for the container to obtain an IPv4 and register DNS
#      (<vmname>.<zone0>.internal), mirroring the cluster:vm reconciler
#
# Usage: install-service.sh <module-name>
#

# Remote pct/ssh commands embed locally-computed values that expand client-side.
# shellcheck disable=SC2029
set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Creates an LXC container for the specified module."
    exit 1
fi

. /home/tappaas/bin/common-install-routines.sh
check_json "/home/tappaas/config/$1.json" || exit 1

MODULE="$1"
readonly CONFIG_DIR="/home/tappaas/config"
MGMT="mgmt"

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'mgmt')"
NODE_FQDN="${NODE}.${MGMT}.internal"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

info "${BOLD}cluster:lxc install-service for ${BL}${MODULE}${CL} (VMID ${VMID}) on ${NODE}"

# ── 1. Copy config (+ optional meta) and create the container ────────

scp "${SSH_OPTS[@]}" "${CONFIG_DIR}/${MODULE}.json" "root@${NODE_FQDN}:/root/tappaas/${MODULE}.json" >/dev/null
if [[ -f "${CONFIG_DIR}/${MODULE}.meta.json" ]]; then
    info "  Shipping ${MODULE}.meta.json (LXC passthrough/bind-mount config)"
    scp "${SSH_OPTS[@]}" "${CONFIG_DIR}/${MODULE}.meta.json" "root@${NODE_FQDN}:/root/tappaas/${MODULE}.meta.json" >/dev/null
fi

ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" "/root/tappaas/Create-TAPPaaS-LXC.sh ${MODULE}"

# Tidy up the shipped config files (the container keeps its own state).
ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
    "rm -f /root/tappaas/${MODULE}.json /root/tappaas/${MODULE}.meta.json" || true

# ── 2. Wait for an IPv4 and register DNS ─────────────────────────────

info "  Waiting for container ${VMID} to obtain an IPv4..."
ip=""
for _ in $(seq 1 30); do
    ip=$(ssh "${SSH_OPTS[@]}" "root@${NODE_FQDN}" \
        "pct exec ${VMID} -- hostname -I 2>/dev/null" 2>/dev/null \
        | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -1) || true
    [[ -n "${ip}" ]] && break
    sleep 4
done

if [[ -z "${ip}" ]]; then
    warn "  Container did not report an IPv4 yet — DNS not registered (register later via update-service)"
else
    info "  Container came up with IP ${BL}${ip}${CL}"
    info "  Registering DNS: ${VMNAME}.${ZONE0}.internal → ${ip}"
    dns-manager --no-ssl-verify add "${VMNAME}" "${ZONE0}.internal" "${ip}" \
        --description "${MODULE} (cluster:lxc)" \
        || warn "  dns-manager add failed for ${VMNAME}.${ZONE0}.internal"
fi

info "${GN}✓${CL} LXC ${VMNAME} (VMID ${VMID}) created on ${NODE}, zone ${ZONE0}"
