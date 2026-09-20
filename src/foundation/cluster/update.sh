#!/usr/bin/env bash
#
# TAPPaaS Cluster Module Update
#
# Updates all Proxmox nodes in the cluster:
#   1. Runs apt update && apt dist-upgrade on each node, then prunes superseded
#      kernels (keeping running, latest and latest-1)
#   2. Distributes Create-TAPPaaS-VM.sh, Create-TAPPaaS-LXC.sh and zones.json to each node
#   3-4. Refreshes SSD lifecycle and the Realtek NIC fix on each node
#   5. Makes each node's sshd key-only (#19) — only over a key connection
#   6. Reconciles the storage node lists from site.json
#   7. Registers each node as a `pvehost` module instance, if it is not one yet
#      (ADR-026 D4 stage 1, #665) — inert: nothing on the node changes
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

info "${BOLD}*** Starting TAPPaaS Cluster module update${CL}"

# (Removed: a legacy "Step 0" that ran validate-configuration.sh against the now-
# retired config/configuration.json — warn-only, and spurious since that file is
# gone. site.json is well-formed by construction (create-site / site-manager write
# validated config); node discovery below fails fast if it were truly broken.)

# Get list of all cluster nodes
debug "Discovering Proxmox cluster nodes..."
NODES=$(ssh -o StrictHostKeyChecking=no root@"$NODE1_FQDN" \
    "pvesh get /cluster/resources --type node --output-format json | jq --raw-output '.[].node'")
debug "Found nodes: $(echo "$NODES" | tr '\n' ' ')"

# Step 1: Run apt update && apt dist-upgrade on all Proxmox nodes
info "${BOLD}Step 1: Updating Proxmox node packages${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    # One header for both apt phases; each phase renders its own line of progress
    # dots (update, then dist-upgrade) so the console stays compact (two dot lines).
    # dist-upgrade, NOT upgrade: `apt upgrade` never installs a NEW package, and
    # every Proxmox kernel bump ships a new package name (proxmox-kernel-<ver>),
    # so plain upgrade held the kernel back on every run (#591). dist-upgrade
    # matches install.sh and is the command Proxmox documents.
    info "Running apt update & dist-upgrade on $node..."
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt update"; then
            warn "apt update failed on $node"
            continue
        fi
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt dist-upgrade --assume-yes"; then
            warn "apt dist-upgrade failed on $node"
            continue
        fi
    else
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt update" 2>&1 | while IFS= read -r _; do printf "."; done; then
            echo ""
            warn "apt update failed on $node"
            continue
        fi
        echo ""
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt dist-upgrade --assume-yes" 2>&1 | while IFS= read -r _; do printf "."; done; then
            echo ""
            warn "apt dist-upgrade failed on $node"
            continue
        fi
        echo ""
    fi
    debug "$node package update completed."

    # Detect pending kernel reboot — Proxmox does not create /var/run/reboot-required.
    # Compare the running kernel with the newest installed kernel package. The
    # version read comes from the package NAMES (prefix is proxmox-kernel-* on
    # current Proxmox, pve-kernel-* on older ones); proxmox-kernel-helper has an
    # unrelated version, so the version column cannot be sorted on. Keep this in
    # step with rn_latest_kernel() in lib/reboot-node-lib.sh.
    _running=$(ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "uname -r" 2>/dev/null || true)
    _latest=$(ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" \
        "dpkg -l 'proxmox-kernel-*' 'pve-kernel-*' 2>/dev/null | awk '/^ii/ && \$2 ~ /^(proxmox|pve)-kernel-[0-9]/ {v=\$2; sub(/^(proxmox|pve)-kernel-/, \"\", v); sub(/-signed\$/, \"\", v); print v}' | sort -V | tail -1" \
        2>/dev/null || true)
    if [[ -n "$_running" && -n "$_latest" && "$_running" != "$_latest" ]]; then
        warn "Node ${node}: kernel ${_latest} installed, ${_running} running — reboot required"
        warn "  Kernel modules (e.g. amdgpu, network drivers) are stale until reboot."
        warn "  Schedule a maintenance window and run:"
        warn "    reboot-node.sh --dry-run ${node}    # preview impact"
        warn "    reboot-node.sh --execute ${node}    # execute (HITL)"
    fi

    # ── Prune superseded kernels (#592) ──────────────────────────────
    # dist-upgrade only ever ADDS kernels; nothing removed them, so /boot grew
    # without bound. lib/prune-kernels.sh keeps the running, latest and
    # latest-1 kernels and purges the rest — run node-side by piping the script
    # over ssh. It never uses `apt autoremove` (which would remove the running
    # kernel on a node that is behind); see the script header and #592. The
    # same script is unit-tested by lib/test-kernel-prune.sh (test.sh Test 2c).
    debug "Pruning superseded kernels on $node (keep: running, latest, latest-1)..."
    _prune_out="$(ssh -o StrictHostKeyChecking=no root@"$NODE_FQDN" 'bash -s' \
        2>&1 < "${SCRIPT_DIR}/lib/prune-kernels.sh")" || true
    _keep_line="$(printf '%s\n' "$_prune_out" | grep -m1 '^KEEP: ' || true)"
    _rm_line="$(printf '%s\n' "$_prune_out" | grep -m1 '^REMOVE: ' || true)"
    [[ -n "$_keep_line" ]] && debug "  $node ${_keep_line}"
    if [[ "$_rm_line" == "REMOVE: (none)" ]]; then
        debug "  $node no superseded kernels to prune"
    elif [[ -n "$_rm_line" ]]; then
        info "  $node pruned: ${_rm_line#REMOVE: }"
    else
        warn "  $node kernel prune produced no summary — check output"
        [[ "${OPT_DEBUG:-0}" -eq 1 ]] && printf '%s\n' "$_prune_out"
    fi

done <<< "$NODES"
debug "All Proxmox nodes package update completed."

# Step 2: Distribute files to all nodes
info "${BOLD}Step 2: Distributing files to all Proxmox nodes${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    debug "Copying zones.json and the VM/LXC provisioners to $node..."
    scp -q /home/tappaas/config/zones.json root@"$NODE_FQDN":/root/tappaas/
    scp -q "${SCRIPT_DIR}/Create-TAPPaaS-VM.sh" root@"$NODE_FQDN":/root/tappaas/
    scp -q "${SCRIPT_DIR}/Create-TAPPaaS-LXC.sh" root@"$NODE_FQDN":/root/tappaas/

    # The mothership's SSH public key, distributed as the canonical
    # tappaas-cicd.pub. Create-TAPPaaS-VM.sh injects it (--sshkey) so cloud-init
    # VMs created on ANY node authorize the controller. tappaas-cicd/install.sh
    # seeds it only on the nodes present at mothership-install time; a node added
    # later (join/--pxe) would otherwise lack it, and image/cloud-init VMs placed
    # there fail SSH provisioning ("Permission denied (publickey)"). Re-pushing
    # here on every update keeps every node — including new ones — self-healed.
    if [ -f /home/tappaas/.ssh/id_ed25519.pub ]; then
        scp -q /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.pub
    fi

    # Debian/Ubuntu cloud-init vendor-data snippet (issue #147). Must live at
    # /var/lib/vz/snippets/ to be referenced as 'local:snippets/...' in qm.
    debug "Deploying Debian vendor-data snippet to $node..."
    ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "mkdir -p /var/lib/vz/snippets"
    scp -q "${SCRIPT_DIR}/snippets/tappaas-debian-vendor.yaml" \
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
debug "Files distributed to all Proxmox nodes."

# Step 3: Refresh SSD lifecycle config on all nodes (issue #152).
#   - re-asserts autotrim=on on any pools added since bootstrap
#   - redeploys /etc/cron.weekly/tappaas-zpool-trim and
#     /etc/cron.monthly/tappaas-ssd-health
# smartmontools is ensured here so existing pre-#152 nodes get it too.
info "${BOLD}Step 3: Refreshing SSD lifecycle configuration${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    debug "Deploying SSD lifecycle setup to $node..."
    scp -q "${SCRIPT_DIR}/setup-ssd-lifecycle.sh" root@"$NODE_FQDN":/root/tappaas/
    # Capture the node-side script output: route it to [Debug] when green (it
    # would otherwise leak a bare "SSD lifecycle setup complete." line), surface
    # it in full on failure.
    if _ssd_out="$(ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" \
        "apt -y install smartmontools >/dev/null 2>&1 && /root/tappaas/setup-ssd-lifecycle.sh" 2>&1)"; then
        [[ -n "${_ssd_out}" ]] && while IFS= read -r _l; do debug "  ${_l}"; done <<<"${_ssd_out}"
        debug "$node SSD lifecycle setup complete."
    else
        [[ -n "${_ssd_out}" ]] && printf '%s\n' "${_ssd_out}" >&2
        warn "SSD lifecycle setup failed on $node"
        continue
    fi
done <<< "$NODES"
debug "SSD lifecycle configuration refreshed on all Proxmox nodes."

# Step 4: Realtek RTL8127 NIC driver fix on all nodes (issue #308).
#   - Hardware-gated: a no-op on nodes without an RTL8127 (e.g. Intel-igc nodes).
#   - Idempotent: installs the r8127 DKMS driver + blacklists r8169 (only after
#     the module is confirmed to build/load), so MS-S1 MAX nodes survive a warm
#     reboot instead of needing a power cycle. Re-asserted every update so the
#     fix is reinstated if a kernel/package change ever drifted it.
info "${BOLD}Step 4: Refreshing Realtek RTL8127 NIC driver fix${CL}"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    debug "Deploying Realtek NIC setup to $node..."
    scp -q "${SCRIPT_DIR}/setup-realtek-nic.sh" root@"$NODE_FQDN":/root/tappaas/
    scp -q "${SCRIPT_DIR}/assets/r8127-dkms_11.015.00-1_all.deb" \
        root@"$NODE_FQDN":/root/tappaas/ 2>/dev/null || true
    # Capture the verbose apt/DKMS output; surface only a concise reason on
    # failure (not the whole dump). Keep the console clean per node.
    if _rt_out="$(ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "/root/tappaas/setup-realtek-nic.sh" 2>&1)"; then
        debug "$node Realtek NIC setup complete."
    else
        _rt_reason="$(printf '%s\n' "${_rt_out}" | grep -iE '\[realtek-nic\]\[(error|warn)' | tail -1 | sed 's/^[[:space:]]*//')"
        warn "Realtek NIC setup issue on $node: ${_rt_reason:-see the node output} — continuing"
        continue
    fi
done <<< "$NODES"
debug "Realtek NIC driver fix refreshed on all Proxmox nodes."

# Step 5: key-only SSH on every node (issue #19).
#   No password SSH logins, for any user; root keeps key login, because PVE's
#   own node-to-node Shell and migrations, and this mothership, log in as root
#   with keys. The web GUI, its node Shell and the physical console are not
#   sshd and keep working with the root password.
#   Guard: a node is hardened only if it is reachable RIGHT NOW with a key and
#   passwords refused. That is what makes it safe — hardening can never be the
#   step that locks the mothership out, whatever state the node's keys are in.
info "${BOLD}Step 5: Enforcing key-only SSH on Proxmox nodes${CL}"
_ssh_hard_fail=0
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    if ! ssh -n -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no             -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@"$NODE_FQDN" true 2>/dev/null; then
        warn "$node: not reachable with a key — leaving its sshd alone (authorize the mothership's key, then re-run)"
        _ssh_hard_fail=1
        continue
    fi
    scp -q "${SCRIPT_DIR}/setup-ssh-hardening.sh" root@"$NODE_FQDN":/root/tappaas/
    if _sh_out="$(ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "/root/tappaas/setup-ssh-hardening.sh" 2>&1)"; then
        debug "$node: ${_sh_out}"
    else
        printf '%s\n' "${_sh_out}" >&2
        warn "$node: key-only SSH not enforced — see above"
        _ssh_hard_fail=1
    fi
done <<< "$NODES"
if [[ "${_ssh_hard_fail}" -eq 0 ]]; then
    debug "Key-only SSH enforced on all Proxmox nodes."
fi

# Step 6: Drift-heal the cluster storage `nodes` lists from site.json.
# The lists have only one-shot writers (config-storage at pool creation,
# site-manager node add after a join) — a node that joined by any other
# path shows its pools 'disabled' until reconciled (node-provisioning §7.3).
info "${BOLD}Step 6: Reconciling storage node lists from site.json${CL}"
if ! bash "${SCRIPT_DIR}/reconcile-storage-nodes.sh"; then
    warn "storage nodes reconcile reported an error — run reconcile-storage-nodes.sh manually"
fi

# Step 7: every cluster node is a module instance (ADR-026 D4 stage 1, #665).
#   `module adopt` registers a node that has no config yet: config/<node>.json,
#   module pvehost, verified by its install.sh — which changes nothing on the
#   node. Idempotent; a node already registered is left alone. A failure is a
#   warning, never a failed cluster update: registration is bookkeeping, and the
#   patching above does not depend on it (that is stage 2).
info "${BOLD}Step 7: Registering cluster nodes as pvehost instances${CL}"

# A node is adopted BY NAME, so it has to resolve first. The firewall's base
# config ships entries for the first nodes only; beyond those the entry is made
# here, from the address the cluster itself reports — that is what makes the
# node number a sequence rather than a list of nine (#673).
#
# Only when the name has NO entry at all: an entry that is already there (a
# shipped one, a MAC reservation from PXE provisioning, an operator's own) is
# left exactly as it is — `add` would otherwise create a second entry for the
# same name, since it matches on description.
_node_ips="$(ssh -n -o StrictHostKeyChecking=no root@"$NODE1_FQDN" \
    "pvesh get /cluster/status --output-format json" 2>/dev/null \
    | jq -r '.[] | select(.type == "node") | "\(.name) \(.ip)"' 2>/dev/null || true)"

ensure_node_dns() {
    local node="$1" fqdn="$1.${MGMTVLAN}.internal" ip
    if dns-manager --no-ssl-verify list 2>/dev/null | awk '{print $1}' | grep -qx "${fqdn}"; then
        debug "  ${node}: DNS entry present"
        return 0
    fi
    ip="$(awk -v n="${node}" '$1 == n {print $2; exit}' <<< "${_node_ips}")"
    if [[ -z "${ip}" ]]; then
        warn "  ${node}: no address reported by the cluster — cannot create its DNS entry"
        return 1
    fi
    if dns-manager --no-ssl-verify add "${node}" "${MGMTVLAN}.internal" "${ip}" \
            --description "TAPPaaS node ${node}" >/dev/null 2>&1; then
        info "  ${GN}✓${CL} ${node}: DNS entry ${fqdn} → ${ip}"
    else
        warn "  ${node}: could not create its DNS entry (${fqdn} → ${ip})"
        return 1
    fi
}

while read -r node; do
    [[ -n "${node}" ]] || continue
    cfg="${CONFIG_DIR}/${node}.json"
    if [[ -f "${cfg}" ]]; then
        if [[ "$(module_of "${node}" 2>/dev/null)" == pvehost ]]; then
            debug "  ${node}: already registered"
        else
            warn "  ${node}: config/${node}.json exists but is not a pvehost instance — not registering it"
        fi
        continue
    fi
    ensure_node_dns "${node}" || { warn "  ${node}: not registered — it does not resolve"; continue; }
    if adopt-module.sh "${node}.${MGMTVLAN}.internal" --wait 0 >/dev/null 2>"/tmp/adopt-${node}.err"; then
        info "  ${GN}✓${CL} ${node} registered as a pvehost instance"
    else
        warn "  ${node}: not registered — $(tail -1 "/tmp/adopt-${node}.err" | sed 's/\x1b\[[0-9;]*m//g')"
    fi
    rm -f "/tmp/adopt-${node}.err"
done <<< "$NODES"

# ── Step 8: retire the shipped node placeholders (#673) ──────────────
#
# The firewall's base config used to ship a dnsmasq entry for tappaas1-9,
# whatever the site's size, so a three-node site carries six entries for
# machines that do not exist. It ships tappaas1 only now; this clears what
# earlier installs left, on every site, at its own pace — the firewall is live
# state, so it is converged here and not by a config migration (ADR-025 D3).
#
# Only an entry of a NON-MEMBER name goes, and `release --placeholder` decides:
# the description is the shipped shape (none) or the one dhcp-manager writes
# ("TAPPaaS node <host>", left behind by a provisioning test), and it carries no
# MAC, no CNAME, and is the only entry for that name. So a pinned MAC — a node
# waiting to be PXE-installed — keeps its entry, as does anything an operator or
# another module made.
# retire_node_placeholders <zone> <members…> — one line per entry retired.
retire_node_placeholders() {
    local zone="$1"; shift
    local members; members="$(printf '%s\n' "$@")"
    local fqdn name out
    while read -r fqdn; do
        [[ -n "${fqdn}" ]] || continue
        name="${fqdn%%.*}"
        [[ "${name}" =~ ^tappaas[0-9]+$ ]] || continue
        grep -qx "${name}" <<< "${members}" && continue     # a cluster member: keep
        if ! out="$(dns-manager --no-ssl-verify release --placeholder "${name}" "${zone}.internal" 2>&1)"; then
            warn "  ${name}: could not be retired (${out##*$'\n'})"
            continue
        fi
        case "${out}" in
            *released*) info "  ${GN}✓${CL} ${name}: unused placeholder entry retired" ;;
            *)          debug "  ${out}" ;;
        esac
    done < <(dns-manager --no-ssl-verify list 2>/dev/null | awk '{print $1}' \
             | grep -E "^tappaas[0-9]+\.${zone}\.internal$" || true)
}

info "${BOLD}Step 8: Retiring unused node DNS placeholders${CL}"
# shellcheck disable=SC2086
retire_node_placeholders "${MGMTVLAN}" ${NODES}

info "${GN}✓${CL} Cluster module update completed successfully."
