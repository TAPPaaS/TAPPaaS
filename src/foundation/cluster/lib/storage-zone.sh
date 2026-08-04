#!/usr/bin/env bash
#
# storage-zone.sh — shared helpers for resolving addresses on the foundation
# `storage` zone (cluster:storage's NFS/CephFS export plane, VLAN 100,
# 10.1.0.0/24 — see zones.json). Used by both cluster/nfs-manager.sh (admin
# side, needs the zone's CIDR for export ACLs) and
# services/nfs/mount-params.sh (needs a specific node's storage-zone IP).
#
# Sourced after common-install-routines.sh. Relies on: CONFIG_DIR, error/die.
#
# The storage zone has no DNS records for node addresses (they're static,
# not DHCP-leased), so node IPs are derived by the SAME numbering convention
# config-network.sh already uses for the mgmt zone (10.0.0.<9+N> for
# tappaasN) — just on the storage subnet instead of mgmt's.

# Read the storage zone's CIDR from zones.json. Never hardcode it — same
# anti-hardcoding principle common-install-routines.sh's dmz_gateway_ip
# already follows for the DMZ zone.
storage_zone_cidr() {
    local zones="${CONFIG_DIR}/zones.json"
    [[ -f "${zones}" ]] || { error "zones.json not found at ${zones}"; return 1; }
    local cidr
    cidr="$(jq -r '.storage.ip // empty' "${zones}")"
    [[ -n "${cidr}" ]] || { error "could not find the 'storage' zone in ${zones} — has it been provisioned (zone-manager)?"; return 1; }
    printf '%s\n' "${cidr}"
}

# Read the storage zone's VLAN tag from zones.json. Never hardcode it.
storage_zone_vlan() {
    local zones="${CONFIG_DIR}/zones.json"
    [[ -f "${zones}" ]] || { error "zones.json not found at ${zones}"; return 1; }
    local vid
    vid="$(jq -r '.storage.vlantag // empty' "${zones}")"
    [[ -n "${vid}" ]] || { error "could not find a vlantag for the 'storage' zone in ${zones}"; return 1; }
    printf '%s\n' "${vid}"
}

# Compute a node's static IP on the storage zone from its name (tappaasN ->
# 10.1.0.<9+N>), mirroring config-network.sh's mgmt-zone convention. Does not
# verify the node actually has this address configured — see
# cluster/config-storage-zone.sh for provisioning that.
#   storage_node_ip <node-name>
storage_node_ip() {
    local node="$1" n subnet
    if [[ ! "${node}" =~ ^tappaas([0-9]+)$ ]]; then
        error "storage_node_ip: node name '${node}' doesn't match the expected tappaasN pattern"
        return 1
    fi
    n="${BASH_REMATCH[1]}"
    subnet="$(storage_zone_cidr)" || return 1
    subnet="${subnet%.*/*}"  # "10.1.0.0/24" -> "10.1.0"
    printf '%s.%s\n' "${subnet}" "$((9 + n))"
}
