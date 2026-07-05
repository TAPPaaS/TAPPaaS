# shellcheck shell=bash
# pbs-client.sh — reconcile proxmox-backup-client across the cluster (ADR-012 P3, #382).
#
# The backup client must be present on EVERY Proxmox node so a VM's backup can
# run wherever the VM lives. install.sh used to enumerate nodes once, at PBS
# install time — so a node ADDED later never got the client (#382). This makes
# the install an idempotent reconcile keyed on CURRENT cluster membership, so
# both install.sh and update.sh (i.e. `update-module.sh backup`) heal a cluster
# whose node set has grown.
#
# Requires: common-install-routines.sh (get_node_hostname, info/warn, colour
# vars) and pbs-placement.sh (pbs_cluster_nodes) sourced first.

# Ensure proxmox-backup-client on a single node. Idempotent: skips fast when the
# package is already installed; otherwise registers the PBS apt repo (if missing)
# and installs. Args: <node> <zone> <image-location>
_pbs_client_install_one() {
    local node="$1" zone="$2" image_location="$3"
    ssh -n -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "bash -s -- '${image_location}'" <<'REMOTE'
set -euo pipefail
image_location="$1"
if dpkg -s proxmox-backup-client >/dev/null 2>&1; then
    echo "  proxmox-backup-client already present"
    exit 0
fi
if ! grep -q "${image_location}" /etc/apt/sources.list.d/proxmox.sources 2>/dev/null; then
    cat >> /etc/apt/sources.list.d/proxmox.sources <<EOFPBS
Types: deb
URIs: ${image_location}
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOFPBS
fi
apt update
apt install -y proxmox-backup-client
echo "  proxmox-backup-client installed"
REMOTE
}

# Reconcile the client across all CURRENT cluster nodes. Idempotent; a node that
# already has the client is a no-op, a node added since install gets it now.
# Warns (does not die) per node so one unreachable node can't abort the sweep.
# Args: <zone> <image-location>
pbs_client_reconcile() {
    local zone="${1:-mgmt}" image_location="$2" reachable node rc=0
    reachable="$(get_node_hostname 0)"
    info "${BOLD}Reconciling proxmox-backup-client across cluster nodes (#382)${CL}"
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        info "  Ensuring proxmox-backup-client on ${BL}${node}${CL}..."
        _pbs_client_install_one "$node" "$zone" "$image_location" \
            || { warn "  Failed to ensure proxmox-backup-client on ${node}"; rc=1; }
    done < <(pbs_cluster_nodes "$reachable" "$zone")
    return "$rc"
}
