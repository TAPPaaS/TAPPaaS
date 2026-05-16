#!/usr/bin/env bash
#
# TAPPaaS Cluster Module Update
#
# Updates all Proxmox nodes in the cluster:
#   1. Runs apt update && apt upgrade on each node
#   2. Distributes Create-TAPPaaS-VM.sh and zones.json to each node
#
# Usage: ./update.sh [module-name]
#
# Arguments:
#   module-name   (optional) Passed by update-module.sh, not used by this script
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MGMTVLAN="mgmt"
NODE1_FQDN="$(get_primary_node_fqdn)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "Starting TAPPaaS Cluster module update..."

# Step 0: Validate configuration.json
if [[ -x /home/tappaas/bin/validate-configuration.sh ]]; then
    info "Validating configuration.json..."
    /home/tappaas/bin/validate-configuration.sh --quiet || {
        warn "Configuration validation reported issues. Run: validate-configuration.sh"
    }
fi

# Get list of all cluster nodes
echo ""
info "Discovering Proxmox cluster nodes..."
NODES=$(ssh -o StrictHostKeyChecking=no root@"$NODE1_FQDN" \
    "pvesh get /cluster/resources --type node --output-format json | jq --raw-output '.[].node'")
info "Found nodes: $(echo "$NODES" | tr '\n' ' ')"

# Step 1: Run apt update && apt upgrade on all Proxmox nodes
echo ""
info "${BOLD}Step 1: Updating Proxmox node packages${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    echo ""
    info "Running apt update on $node..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt update"; then
            warn "apt update failed on $node"
            continue
        fi
    else
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt update" 2>&1 | while IFS= read -r _; do printf "."; done; then
            echo ""
            warn "apt update failed on $node"
            continue
        fi
        echo ""
    fi
    info "Running apt upgrade on $node..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt upgrade --assume-yes"; then
            warn "apt upgrade failed on $node"
            continue
        fi
    else
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt upgrade --assume-yes" 2>&1 | while IFS= read -r _; do printf "."; done; then
            echo ""
            warn "apt upgrade failed on $node"
            continue
        fi
        echo ""
    fi
    info "$node package update completed."
done <<< "$NODES"
echo ""
info "All Proxmox nodes package update completed."

# Step 2: Distribute files to all nodes
echo ""
info "${BOLD}Step 2: Distributing files to all Proxmox nodes${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    echo ""
    info "Copying zones.json and Create-TAPPaaS-VM.sh to $node..."
    scp /home/tappaas/config/zones.json root@"$NODE_FQDN":/root/tappaas/
    scp "${SCRIPT_DIR}/Create-TAPPaaS-VM.sh" root@"$NODE_FQDN":/root/tappaas/

    # Debian/Ubuntu cloud-init vendor-data snippet (issue #147). Must live at
    # /var/lib/vz/snippets/ to be referenced as 'local:snippets/...' in qm.
    info "Deploying Debian vendor-data snippet to $node..."
    ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "mkdir -p /var/lib/vz/snippets"
    scp "${SCRIPT_DIR}/snippets/tappaas-debian-vendor.yaml" \
        root@"$NODE_FQDN":/var/lib/vz/snippets/tappaas-debian-vendor.yaml
    # Ensure 'snippets' is in local storage content types (idempotent;
    # /etc/pve/storage.cfg is cluster-wide so only the first node matters).
    # Parse storage.cfg directly: there is no `pvesm config` subcommand, and
    # `pvesm set --content` REPLACES the list, so we must preserve it.
    ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "\
        current=\$(awk '/^dir: local\$/{f=1; next} f && /^[a-z]+:/{f=0} f && /^[[:space:]]*content[[:space:]]/{print \$2; exit}' /etc/pve/storage.cfg); \
        if [ -z \"\$current\" ]; then \
            echo 'WARN: could not read content list for local storage'; \
        elif ! echo \"\$current\" | grep -qw snippets; then \
            pvesm set local --content \"\${current},snippets\" >/dev/null; \
        fi" || warn "Failed to enable snippets on local storage on $node"
done <<< "$NODES"
echo ""
info "Files distributed to all Proxmox nodes."

# Step 3: Refresh SSD lifecycle config on all nodes (issue #152).
#   - re-asserts autotrim=on on any pools added since bootstrap
#   - redeploys /etc/cron.weekly/tappaas-zpool-trim and
#     /etc/cron.monthly/tappaas-ssd-health
# smartmontools is ensured here so existing pre-#152 nodes get it too.
echo ""
info "${BOLD}Step 3: Refreshing SSD lifecycle configuration${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    echo ""
    info "Deploying SSD lifecycle setup to $node..."
    scp "${SCRIPT_DIR}/setup-ssd-lifecycle.sh" root@"$NODE_FQDN":/root/tappaas/
    if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" \
        "apt -y install smartmontools >/dev/null 2>&1 && /root/tappaas/setup-ssd-lifecycle.sh"; then
        warn "SSD lifecycle setup failed on $node"
        continue
    fi
    info "$node SSD lifecycle setup complete."
done <<< "$NODES"
echo ""
info "SSD lifecycle configuration refreshed on all Proxmox nodes."

echo ""
info "${GN}✓${CL} Cluster module update completed successfully."
