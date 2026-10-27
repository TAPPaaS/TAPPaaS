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
#   6. Reconciles the storage node lists from the node records (storagePools)
#   7. Registers each node as a `pvehost` module instance, if it is not one yet
#      (ADR-026 D4 stage 1, #665) — inert: nothing on the node changes
#   7b. lldpd (receive-only) on each node, and its lan uplink recorded as its
#      declaration when it has none (#40) — the uplink itself is not changed
#
# Usage: ./update.sh [module-name]
#
# Arguments:
#   module-name   (optional) Passed by update-module.sh, not used by this script
#
# Environment:
#   CLUSTER_UPDATE_NODES  (optional) the nodes the per-node steps run on, space or
#                         comma separated — node add brings a new node to the
#                         baseline with it. Cluster-wide steps run as always.
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MGMTVLAN="mgmt"
NODE1_FQDN="$(get_primary_node_fqdn)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

debug "*** Starting TAPPaaS Cluster module update"

# (Removed: a legacy "Step 0" that ran validate-configuration.sh against the now-
# retired config/configuration.json — warn-only, and spurious since that file is
# gone. site.json is well-formed by construction (create-site / site-manager write
# validated config); node discovery below fails fast if it were truly broken.)

# Get list of all cluster nodes
debug "Discovering Proxmox cluster nodes..."
NODES=$(ssh -o StrictHostKeyChecking=no root@"$NODE1_FQDN" \
    "pvesh get /cluster/resources --type node --output-format json | jq --raw-output '.[].node'")
debug "Found nodes: $(echo "$NODES" | tr '\n' ' ')"
ALL_NODES="${NODES}"   # Step 8 decides membership: it always sees every node
if [[ -n "${CLUSTER_UPDATE_NODES:-}" ]]; then
    NODES="$(grep -Fx -f <(tr ', ' '\n\n' <<< "${CLUSTER_UPDATE_NODES}" | grep -vx '') <<< "${ALL_NODES}" || true)"
    [[ -n "${NODES}" ]] || die "CLUSTER_UPDATE_NODES='${CLUSTER_UPDATE_NODES}' names no cluster node"
    debug "Limited to: $(echo "$NODES" | tr '\n' ' ')"
fi

# Step 1: Run apt update && apt dist-upgrade on all Proxmox nodes
debug "Step 1: Updating Proxmox node packages"
_apt_ok=()
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    # apt's own output shows with --debug only; the outcome is one ✓ line per node.
    # dist-upgrade, NOT upgrade: `apt upgrade` never installs a NEW package, and
    # every Proxmox kernel bump ships a new package name (proxmox-kernel-<ver>),
    # so plain upgrade held the kernel back on every run (#591). dist-upgrade
    # matches install.sh and is the command Proxmox documents.
    debug "Running apt update & dist-upgrade on $node..."
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
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt update" 2>&1 | while IFS= read -r _; do :; done; then
            warn "apt update failed on $node"
            continue
        fi
        if ! ssh -n -o StrictHostKeyChecking=no root@"$NODE_FQDN" "apt dist-upgrade --assume-yes" 2>&1 | while IFS= read -r _; do :; done; then
            warn "apt dist-upgrade failed on $node"
            continue
        fi
    fi
    debug "  ${GN}✓${CL} $node: packages up to date (apt dist-upgrade)"
    _apt_ok+=("$node")

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
        info "  ${GN}✓${CL} $node: superseded kernels pruned: ${_rm_line#REMOVE: }"
    else
        warn "  $node kernel prune produced no summary — check output"
        [[ "${OPT_DEBUG:-0}" -eq 1 ]] && printf '%s\n' "$_prune_out"
    fi

done <<< "$NODES"
if [[ ${#_apt_ok[@]} -gt 0 ]]; then
    info "  ${GN}✓${CL} packages up to date (apt dist-upgrade) on ${#_apt_ok[@]} node(s): ${_apt_ok[*]}"
fi
debug "All Proxmox nodes package update completed."

# Step 2: Distribute files to all nodes
_baseline_fail=0
debug "Step 2: Distributing files to all Proxmox nodes"
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    debug "Copying zones.json and the VM/LXC provisioners to $node..."
    scp -q /home/tappaas/config/zones.json root@"$NODE_FQDN":/root/tappaas/
    scp -q "${SCRIPT_DIR}/Create-TAPPaaS-VM.sh" root@"$NODE_FQDN":/root/tappaas/
    scp -q "${SCRIPT_DIR}/Create-TAPPaaS-LXC.sh" root@"$NODE_FQDN":/root/tappaas/
    scp -q "${SCRIPT_DIR}/lib/storage-placement.sh" root@"$NODE_FQDN":/root/tappaas/   # sourced by both (ADR-037 D1)

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
debug "Step 3: Refreshing SSD lifecycle configuration"
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
        _baseline_fail=1
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
debug "Step 4: Refreshing Realtek RTL8127 NIC driver fix"
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
        _baseline_fail=1
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
debug "Step 5: Enforcing key-only SSH on Proxmox nodes"
_ssh_hard_fail=0
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    if ! ssh -n -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no             -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@"$NODE_FQDN" true 2>/dev/null; then
        warn "$node: not reachable with a key — leaving its sshd alone (authorize the mothership's key, then re-run)"
        _ssh_hard_fail=1
        continue
    fi
    # The script is fed over the key login (ssh-key-only.sh, shared with the
    # machine modules, #756); the copy older releases left on the node goes.
    if _sh_out="$(ssh -o StrictHostKeyChecking=no root@"$NODE_FQDN" \
            'rm -f /root/tappaas/setup-ssh-hardening.sh; bash -s -- apply' \
            < "${SCRIPT_DIR}/../tappaas-cicd/scripts/ssh-key-only.sh" 2>&1)"; then
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

# Step 5b: CPU microcode and the audit trail on every node (issue #128).
#   The vendor's microcode package, and auditd recording changes made from a
#   login session to /etc/pve, /etc/ssh, /root/.ssh and /etc/network — forwarded
#   through the journal to the logging module, so they are searched in Loki, not
#   node by node. Fed over the key login like Step 5; a node that does not take
#   it is reported and the update goes on: neither control is a precondition for
#   anything else the sweep does.
debug "Step 5b: CPU microcode and the audit trail on Proxmox nodes"
_host_hard_fail=0
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    if _hh_out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$NODE_FQDN" \
            'bash -s -- apply' < "${SCRIPT_DIR}/setup-host-hardening.sh" 2>&1)"; then
        while IFS= read -r _l; do debug "$node: ${_l}"; done <<<"${_hh_out}"
    else
        printf '%s\n' "${_hh_out}" >&2
        warn "$node: host hardening not in force — see above"
        _host_hard_fail=1
    fi
done <<< "$NODES"
if [[ "${_host_hard_fail}" -eq 0 ]]; then
    debug "Microcode and the audit trail in force on all Proxmox nodes."
fi

# Step 5d: guests wait for the firewall before they start (#127).
#   Guests take their address by DHCP from the firewall VM; after a cold start of
#   the site each node starts its guests at once, while the HA firewall waits for
#   quorum. A pre-start hookscript on every guest but the firewall waits until it
#   answers DNS, at most 180s. The firewall is network's VM; a site without one
#   gets '-' and a hook that waits for nothing. Report-and-continue, as Step 5b.
debug "Step 5d: guests wait for the firewall before they start"
_fw_vmid="$(jq -r '.vmid // empty' /home/tappaas/config/network.json 2>/dev/null)"
_fw_vmid="${_fw_vmid:--}"
_guest_hook_fail=0
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    if _gh_out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$NODE_FQDN" \
            "bash -s -- apply ${_fw_vmid}" < "${SCRIPT_DIR}/setup-guest-hook.sh" 2>&1)"; then
        while IFS= read -r _l; do debug "$node: ${_l}"; done <<<"${_gh_out}"
    else
        printf '%s\n' "${_gh_out}" >&2
        warn "$node: guest start hook not in force — see above"
        _guest_hook_fail=1
    fi
done <<< "$NODES"
[[ "${_guest_hook_fail}" -eq 0 ]] && debug "Every guest waits for the firewall (VM ${_fw_vmid}) before it starts."
# Steps 2-5d re-assert the same node baseline every run: one line for all of it.
if [[ "${_baseline_fail}" -eq 0 && "${_ssh_hard_fail}" -eq 0 && "${_host_hard_fail}" -eq 0 && "${_guest_hook_fail}" -eq 0 ]]; then
    info "  ${GN}✓${CL} node baseline on $(wc -w <<< "${NODES}") nodes: SSD lifecycle, RTL8127 fix, key-only SSH, microcode and audit trail, guests wait for the firewall"
fi

# Step 5c: Proxmox's own notification mails off (#126).
#   PVE mails root@pam's address through its built-in `default-matcher`: smartd
#   and ZED warnings (as system mail), every backup job, replication failures,
#   fencing, available updates. The logging module's alert rules now cover what
#   matters of that — disks, backups, replication, fencing, quorum — and mail
#   it the controlled way (site-notify.sh, grouped, repeated at most daily for
#   disks), with a heartbeat the mothership watches. Two channels about one
#   disk is one too many (operator, 2026-10-04). The matcher is disabled, not
#   deleted: `pvesh set /cluster/notifications/matchers/default-matcher
#   --disable 0` brings PVE's mails back, and a site that adds its OWN matcher
#   keeps it. /etc/pve is cluster-wide, so one node is enough.
debug "Step 5c: Proxmox's own notification mails off (alerting is the logging module's)"
_pve_notify_done=0
while read -r node; do
    NODE_FQDN="$node.$MGMTVLAN.internal"
    _dm="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@"$NODE_FQDN" \
        "pvesh get /cluster/notifications/matchers --output-format json" 2>/dev/null \
        | jq -r '.[] | select(.name == "default-matcher") | .disable // 0' 2>/dev/null)" || _dm=""
    [[ -n "${_dm}" ]] || continue
    if [[ "${_dm}" == "1" ]]; then
        debug "PVE default-matcher already disabled"
    elif ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@"$NODE_FQDN" \
            "pvesh set /cluster/notifications/matchers/default-matcher --disable 1 --comment 'Disabled by TAPPaaS: alerts come from the logging module (#126)'" >/dev/null 2>&1; then
        info "  ${GN}✓${CL} PVE notification mails off (default-matcher disabled, cluster-wide)"
    else
        warn "  could not disable PVE's default-matcher via $node — PVE keeps mailing as before"
    fi
    _pve_notify_done=1
    break
done <<< "$NODES"
[[ "${_pve_notify_done}" -eq 1 ]] || warn "  no node answered the notifications API — PVE's mails are unchanged"

# Step 5e: every node runs the site's timezone (#837). Guests are converged to
#   the site's timezone (site.json, its primary location's) on every OS update; the nodes were not, so a
#   node installed with another answer kept it (and its logs and backup times
#   with it). Only the timezone: a node's keyboard and locale are the console's.
_site_tz="$(jq -r '(.locations[.primaryLocation // ""] // .location // {}).timezone // empty' "${CONFIG_DIR:-/home/tappaas/config}/site.json" 2>/dev/null || true)"
if [[ -n "${_site_tz}" ]]; then
    debug "Step 5e: node timezone ${_site_tz} (site.json)"
    while read -r node; do
        [[ -n "${node}" ]] || continue
        NODE_FQDN="$node.$MGMTVLAN.internal"
        _cur="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 root@"$NODE_FQDN" 'timedatectl show -p Timezone --value' 2>/dev/null || true)"
        [[ -n "${_cur}" && "${_cur}" != "${_site_tz}" ]] || continue
        if ssh -n -o BatchMode=yes -o ConnectTimeout=10 root@"$NODE_FQDN" "timedatectl set-timezone '${_site_tz}'" >/dev/null 2>&1; then
            info "  ${GN}✓${CL} $node: timezone ${_cur} → ${_site_tz}"
        else
            warn "  could not set the timezone on $node (it stays ${_cur})"
        fi
    done <<< "$NODES"
fi

# Step 6: Drift-heal the cluster storage `nodes` lists from the nodes' records.
# The lists have only one-shot writers (config-storage at pool creation,
# site-manager node add after a join) — a node that joined by any other
# path shows its pools 'disabled' until reconciled (node-provisioning §7.3).
debug "Step 6: Reconciling storage node lists from the node records"
if ! bash "${SCRIPT_DIR}/reconcile-storage-nodes.sh"; then
    warn "storage nodes reconcile reported an error — run reconcile-storage-nodes.sh manually"
fi

# Step 7: every cluster node is a module instance (ADR-026 D4 stage 1, #665).
#   `module adopt` registers a node that has no config yet: config/<node>.json,
#   module pvehost, verified by its install.sh — which changes nothing on the
#   node. Idempotent; a node already registered is left alone. A failure is a
#   warning, never a failed cluster update: registration is bookkeeping, and the
#   patching above does not depend on it (that is stage 2).
debug "Step 7: Registering cluster nodes as pvehost instances"

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

# Step 7b: each node's lan uplink (#40).
#   lldpd, receive-only, so each port can say which switch it reaches; and a node
#   with no `uplinks` in its config gets the layout it runs recorded as its
#   declaration — nothing on the node changes. Converging a declaration is never
#   done here: re-carrying a lan bridge drains the node, so it is the operator's
#   `site-manager node network set <node> --apply`. Drift is reported by
#   health-manager (lan-uplink). Report-and-continue, as Step 5b.
debug "Step 7b: lan uplinks — lldpd and the recorded declaration"
while read -r node; do
    [[ -n "${node}" ]] || continue
    [[ "$(module_of "${node}" 2>/dev/null)" == pvehost ]] || continue
    if _lu_out="$("${SCRIPT_DIR}/lan-uplink.sh" ensure-lldp "${node}" 2>&1)"; then
        while IFS= read -r _l; do [[ -n "${_l}" ]] && debug "${node}: ${_l}"; done <<<"${_lu_out}"
    else
        printf '%s\n' "${_lu_out}" >&2
        warn "${node}: lldpd not in place — see above"
    fi
    "${SCRIPT_DIR}/lan-uplink.sh" capture "${node}" || warn "${node}: lan uplink not recorded"
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

debug "Step 8: Retiring unused node DNS placeholders"
# shellcheck disable=SC2086
retire_node_placeholders "${MGMTVLAN}" ${ALL_NODES}

# Step 9: what each node's CPU offers a guest, and which live moves are safe
# (#827). Re-read every update: a CPU can be swapped or a node added. The page
# config/cluster-cpu.md is the operator's view; .json is what HA placement reads.
debug "Step 9: CPU inventory of the cluster nodes"
if proxmox-controller cpu-inventory --apply > /dev/null; then
    info "  ${GN}✓${CL} CPU inventory: $(jq -r '"common level \(.common.level // "none"); " + ([.nodes[] | "\(.node) \(.level // "?")"] | join(", "))' /home/tappaas/config/cluster-cpu.json)"
else
    warn "  CPU inventory incomplete — see: proxmox-controller cpu-inventory"
fi

