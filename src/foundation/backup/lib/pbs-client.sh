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

# The PBS stanza a PVE node's proxmox.sources gets — the one text both writers
# (install.sh for the PBS node, _pbs_client_install_one for every node) append.
# The LEADING BLANK LINE is required, not cosmetic (#749): deb822 separates
# stanzas with an empty line; without one apt reads this and the pve stanza above
# it as a SINGLE stanza with duplicate keys, the later URIs win, and the node's
# PVE repository silently ceases to exist. Args: <image-location>
pbs_sources_stanza() {
    printf '\nTypes: deb\nURIs: %s\nSuites: trixie\nComponents: pbs-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' "$1"
}

# Ensure proxmox-backup-client on a single node. Idempotent: skips fast when the
# package is already installed; otherwise registers the PBS apt repo (if missing)
# and installs. The stanza is prepended as a variable so the remote side writes
# exactly pbs_sources_stanza's text. Args: <node> <zone> <image-location>
_pbs_client_install_one() {
    local node="$1" zone="$2" image_location="$3"
    { printf 'stanza=%q\n' "$(pbs_sources_stanza "${image_location}")"; _pbs_client_remote; } \
    | ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "root@${node}.${zone}.internal" "bash -s -- '${image_location}'"
}

# The script _pbs_client_install_one runs on the node, after `stanza=...`.
# $2 (the sources file) exists for the offline test; the node never gets one.
_pbs_client_remote() {
    cat <<'REMOTE'
set -euo pipefail
image_location="$1"
f="${2:-/etc/apt/sources.list.d/proxmox.sources}"
if dpkg -s proxmox-backup-client >/dev/null 2>&1; then
    echo "  proxmox-backup-client already present"
    exit 0
fi
if ! grep -q "${image_location}" "$f" 2>/dev/null; then
    printf '%s\n' "${stanza}" >> "$f"
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
    local zone="${1:-mgmt}" image_location="$2" reachable node rc=0 out n=0 added=""
    reachable="$(get_node_hostname 0)"
    debug "Reconciling proxmox-backup-client across cluster nodes (#382)"
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        debug "  Ensuring proxmox-backup-client on ${node}..."
        # Its narration (apt) is [Debug]; printed whole when it fails.
        if out="$(_pbs_client_install_one "$node" "$zone" "$image_location" 2>&1)"; then
            while IFS= read -r _l; do [[ -n "${_l}" ]] && debug "  ${_l}"; done <<< "${out}"
            n=$((n + 1))
            [[ "${out}" == *"proxmox-backup-client installed"* ]] && added+=" ${node}"
        else
            printf '%s\n' "${out}"
            warn "  Failed to ensure proxmox-backup-client on ${node}"; rc=1
        fi
    done < <(pbs_cluster_nodes "$reachable" "$zone")
    if [[ -n "${added}" ]]; then
        info "  ${GN}✓${CL} proxmox-backup-client installed on${added}"
    elif [[ ${n} -gt 0 ]]; then
        debug "  ${GN}✓${CL} proxmox-backup-client on ${n} node(s)"
    fi
    return "$rc"
}
