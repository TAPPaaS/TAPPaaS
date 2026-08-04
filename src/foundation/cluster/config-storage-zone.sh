#!/usr/bin/env bash
#
# TAPPaaS Cluster Storage Zone - Node Provisioning
#
# Idempotently ensures a Proxmox node has a working presence on the
# foundation `storage` zone (VLAN + CIDR from zones.json), so cluster:storage's
# NFS/CephFS exports on that node are reachable from consumer service zones
# without touching mgmt's isolation (mgmt is Tier-0 — no inbound pinholes, see
# zones.json's isolation_invariant; a straight pinhole into mgmt is not an
# option, hence a dedicated zone instead).
#
# This script only ORCHESTRATES — it resolves values from zones.json (which
# lives on this host, tappaas-cicd) and hands them to the two canonical,
# already-existing tools that own the actual changes:
#   - proxmox-manager bridge-vids --apply : reconciles every node's `lan`
#     bridge trunk membership against zones.json's active VLAN set. Node
#     bridge-vids is NOT edited here.
#   - config-network.sh --zone-presence   : the node's own tagged sub-interface
#     + IP + policy routing, using the same backup/apply conventions as every
#     other config-network.sh mode. Copied fresh from source control to the
#     node on every run (not relying on whatever was fetched at bootstrap), so
#     the node always runs the current, reviewed version.
#   - proxmox-manager trunks --apply      : syncs the firewall VM's own
#     Proxmox netN trunks= list (a newly-active VLAN is invisible to any VM,
#     including the firewall, until its trunk list includes it — #194/#335).
#
# Usage: config-storage-zone.sh <node>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <node>"
    echo "Ensures <node> has a working presence on the foundation storage zone."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/storage-zone.sh disable=SC1091
. "${SCRIPT_DIR}/lib/storage-zone.sh"

NODE="$1"
NODE_FQDN="${NODE}.mgmt.internal"

if ! echo "${NODE}" | grep -qE '^tappaas[0-9]+$'; then
    die "Node name '${NODE}' doesn't match the expected tappaasN pattern"
fi

STORAGE_CIDR="$(storage_zone_cidr)" || die "Run zone-manager --execute first to provision the 'storage' zone"
VLAN_ID="$(storage_zone_vlan)" || exit 1
STORAGE_GATEWAY="${STORAGE_CIDR%.*/*}.1"
NODE_STORAGE_IP="$(storage_node_ip "${NODE}")" || exit 1

# Optional per-node dedicated NIC (site.json hardware.nodes[].storageNic) — see
# config-network.sh's --physical-nic doc for the bandwidth-isolation rationale.
# Absent by default: every node keeps the existing lan.<vid> sub-interface path
# unless an operator explicitly wires up and declares a spare NIC.
SITE_JSON="${CONFIG_DIR}/site.json"
STORAGE_NIC=""
if [[ -f "${SITE_JSON}" ]]; then
    STORAGE_NIC="$(jq -r --arg n "${NODE}" '.hardware.nodes[]? | select(.name == $n) | .storageNic // empty' "${SITE_JSON}" 2>/dev/null)"
fi
if [[ -n "${STORAGE_NIC}" ]]; then
    info "Ensuring ${NODE} has a presence on the storage zone (VLAN ${VLAN_ID}, ${NODE_STORAGE_IP}/24, dedicated NIC ${STORAGE_NIC})"
else
    info "Ensuring ${NODE} has a presence on the storage zone (VLAN ${VLAN_ID}, ${NODE_STORAGE_IP}/24)"
fi

# ── 1. Bridge trunk membership: the canonical, zones.json-driven reconciler ──
info "Reconciling node bridge-vids against zones.json (proxmox-manager)..."
if command -v proxmox-manager >/dev/null 2>&1; then
    proxmox-manager bridge-vids --apply \
        || warn "  proxmox-manager reported drift/errors on bridge-vids — the storage VLAN may not be trunked yet"
else
    warn "  proxmox-manager not on PATH — skipping bridge-vids reconcile"
fi

# ── 2. Node's own tagged sub-interface + IP + policy routing ─────────────
# Refresh the node's config-network.sh to the current source-controlled
# version before invoking it, so this always runs the reviewed code rather
# than whatever was fetched at that node's original bootstrap.
info "Deploying current config-network.sh to ${NODE} and provisioning zone presence..."
ssh -o BatchMode=yes "root@${NODE_FQDN}" "mkdir -p ~/tappaas"
scp -q "${SCRIPT_DIR}/config-network.sh" "root@${NODE_FQDN}:tappaas/config-network.sh" \
    || die "Failed to copy config-network.sh to ${NODE}"
REMOTE_ZONE_CMD="~/tappaas/config-network.sh --zone-presence storage --vlan-id ${VLAN_ID} --zone-ip ${NODE_STORAGE_IP}/24 --zone-gateway ${STORAGE_GATEWAY}"
[[ -n "${STORAGE_NIC}" ]] && REMOTE_ZONE_CMD="${REMOTE_ZONE_CMD} --physical-nic ${STORAGE_NIC}"
ssh -o BatchMode=yes "root@${NODE_FQDN}" \
    "chmod 755 ~/tappaas/config-network.sh && ${REMOTE_ZONE_CMD}"

# ── 3. Sync the firewall VM's Proxmox trunk list (proxmox-manager) ────────
# Same reconcile network/update.sh already runs after any zone change
# (#194/#335) — a newly-enabled VLAN is invisible to VMs (including the
# firewall itself) until their netN trunks= list includes it.
info "Syncing Proxmox VM trunks with active VLAN zones (proxmox-manager)..."
if command -v proxmox-manager >/dev/null 2>&1; then
    proxmox-manager trunks --apply \
        || warn "  proxmox-manager reported drift/errors — the storage zone may not carry traffic yet"
else
    warn "  proxmox-manager not on PATH — skipping VM trunk sync"
fi

info "${GN}✓${CL} ${NODE} storage-zone provisioning complete (${NODE_STORAGE_IP})"
