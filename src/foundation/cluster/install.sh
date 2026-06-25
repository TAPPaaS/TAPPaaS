#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This script is heavily based on the Proxmox Helper Script: Proxmox PVE post Install
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

#
# TODO: Display final HW config, 
# TODO: Throw warning if no mirror on zpools and boot. Configure power management


header_info() {
  # generated with https://patorjk.com/software/taag/#p=display&f=Big&t=TAPPaaS%20Post%20PVE%20Install
  # `clear` needs a terminal/$TERM; never let its absence (e.g. a non-TTY or
  # piped run) abort the whole script under `set -e`.
  clear 2>/dev/null || true
  cat <<"EOF"
  _______       _____  _____             _____   _____          _     _______      ________   _____           _        _ _ 
 |__   __|/\   |  __ \|  __ \           / ____| |  __ \        | |   |  __ \ \    / /  ____| |_   _|         | |      | | |
    | |  /  \  | |__) | |__) |_ _  __ _| (___   | |__) |__  ___| |_  | |__) \ \  / /| |__      | |  _ __  ___| |_ __ _| | |
    | | / /\ \ |  ___/|  ___/ _` |/ _` |\___ \  |  ___/ _ \/ __| __| |  ___/ \ \/ / |  __|     | | | '_ \/ __| __/ _` | | |
    | |/ ____ \| |    | |  | (_| | (_| |____) | | |  | (_) \__ \ |_  | |      \  /  | |____   _| |_| | | \__ \ || (_| | | |
    |_/_/    \_\_|    |_|   \__,_|\__,_|_____/  |_|   \___/|___/\__| |_|       \/   |______| |_____|_| |_|___/\__\__,_|_|_|
                                                                                                                           
EOF
}

RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

set -euo pipefail
shopt -s inherit_errexit nullglob

msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

# fetch <url> <dest> [mode]
#
# Robust download used for every remote file in this bootstrap (issue #175).
# The naive `curl ... >dest` pattern is structurally unable to detect a failed
# download: the shell truncates dest to 0 bytes *before* curl runs, so an
# HTTP 404 leaves an empty file behind and the script marches on reporting
# success. fetch() instead:
#   - downloads to a temp file (dest is never left partial/empty),
#   - tests curl's own exit status,
#   - verifies the result is non-empty,
#   - and treats any failure as FATAL (exit 1) so a broken node is never
#     reported as a good one.
fetch() {
  local url="$1" dest="$2" mode="${3:-644}" tmp
  tmp="$(mktemp)" || { msg_error "mktemp failed"; exit 1; }
  if ! curl -fsSL "$url" -o "$tmp"; then
    rm -f "$tmp"
    msg_error "Download failed for ${url}"
    exit 1
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    msg_error "Download produced an empty file: ${url}"
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
  chmod "$mode" "$dest"
}

#
# here we go: Check that the PVE is right version and have two zfs pools
#

header_info

# ── Arguments ────────────────────────────────────────────────────────
# Backward-compatible with the documented `install.sh <REPO> <BRANCH>`:
# REPO/BRANCH remain positional. New optional flags drive the config phases.
REPO="https://raw.githubusercontent.com/TAPPaaS/"
BRANCH="stable"
CLUSTER_MODE="auto"        # auto | create | join | none
SKIP_NETWORK=0
SKIP_STORAGE=0
SKIP_FIREWALL=0            # first node: skip the chained firewall bootstrap
SKIP_PLATFORM=0           # first node: skip the chained template + cicd install
DOMAIN=""                 # accepted for back-compat; the chain now lives in foundation/install.sh
ORGNAME=""                # the org/system name → the Proxmox cluster name (from --name)
NONINTERACTIVE=0
_pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster)         CLUSTER_MODE="create" ;;
    --join)            CLUSTER_MODE="join" ;;
    --no-cluster)      CLUSTER_MODE="none" ;;
    --skip-network)    SKIP_NETWORK=1 ;;
    --skip-storage)    SKIP_STORAGE=1 ;;
    --skip-firewall)   SKIP_FIREWALL=1 ;;
    --skip-platform)   SKIP_PLATFORM=1 ;;
    --domain)          DOMAIN="${2:-}"; shift ;;
    --name)            ORGNAME="${2:-}"; shift ;;
    --non-interactive) NONINTERACTIVE=1 ;;
    -h|--help)
      echo "Usage: install.sh [REPO] [BRANCH] --name <orgname>"
      echo "                  [--cluster|--join|--no-cluster] [--skip-network] [--skip-storage]"
      echo "                  [--non-interactive]"
      echo ""
      echo "The NODE step: Proxmox post-install, lan/wan bridges, cluster create"
      echo "(named <orgname>) / join, ZFS pools. This is step [1/5] driven by the"
      echo "orchestrator foundation/install.sh (which then runs the firewall, gateway"
      echo "cutover and platform). Writes ~/tappaas/.cluster-role for the orchestrator."
      echo "(--skip-firewall/--skip-platform/--domain are accepted for back-compat but"
      echo "ignored here — those phases belong to foundation/install.sh.)"
      exit 0 ;;
    --*) msg_error "Unknown option: $1"; exit 2 ;;
    *)   _pos+=("$1") ;;
  esac
  shift
done
[ "${#_pos[@]}" -ge 1 ] && REPO="${_pos[0]}"
[ "${#_pos[@]}" -ge 2 ] && BRANCH="${_pos[1]}"
NONINT_ARG=""; [ "$NONINTERACTIVE" = 1 ] && NONINT_ARG="--non-interactive"
# Interactive when not told otherwise AND we actually have a terminal (needed
# to drive pvecm add's password prompt).
INTERACTIVE_TTY=0
[ "$NONINTERACTIVE" = 0 ] && [ -t 0 ] && INTERACTIVE_TTY=1
# Records what the cluster phase did: created | joined | member | standalone.
# Only "created" (this is the first node) triggers the optional firewall install.
CLUSTER_ROLE=""

# ── Cluster (issue #140) ─────────────────────────────────────────────
# auto: first node (tappaas1) creates the cluster; every other node joins it.
# Join is interactive — we prompt for an existing node's address and run
# `pvecm add`, which then prompts for that node's root password. This must
# complete before the storage phase so the tank pools are created while the
# node is already a cluster member (PVE HA-failover requirement).
# This node's management IP on the lan bridge (10.0.0.<9+N> for tappaasN). Must
# match what config-network.sh placed on `lan`, so corosync binds to the stable
# mgmt network from the start — then the gateway cutover needs no reboot.
node_mgmt_ip() {
  local n; n="$(hostname -s | grep -oE '[0-9]+$' || true)"
  if [ -n "$n" ] && [ "$n" -gt 9 ]; then
    msg_error "Node number ${n} (tappaas${n}) exceeds the supported 9 nodes (tappaas1-9 → 10.0.0.10-18)."
    msg_error "The firewall reserves DNS + static IPs only for nine nodes. Aborting."
    exit 1
  fi
  if [ -n "$n" ]; then echo "10.0.0.$((9 + n))"; else echo "10.0.0.10"; fi
}

configure_cluster() {
  local host mode peer mgmt; host="$(hostname -s)"; mgmt="$(node_mgmt_ip)"
  echo -e "\n${GN}=== Cluster configuration ===${CL}"
  if pvecm status >/dev/null 2>&1; then
    msg_ok "Node is already a cluster member"
    pvecm status 2>/dev/null | grep -E 'Name:|Nodes:|Quorate:' || true
    CLUSTER_ROLE="member"
    return 0
  fi

  mode="$CLUSTER_MODE"
  if [ "$mode" = "auto" ]; then
    if [ "$host" = "tappaas1" ]; then mode="create"; else mode="join"; fi
  fi

  case "$mode" in
    create)
      # Bind corosync ring0 to the mgmt IP (10.0.0.10) — present on `lan` from the
      # network phase — so the later gateway cutover does not have to renumber the
      # ring (which previously forced a reboot before a second node could join).
      # Cluster name = the org/system name (--name). Falls back to "TAPPaaS" only
      # when run standalone without --name (back-compat). pvecm cluster names allow
      # letters/digits/hyphen — the orchestrator validates the orgname to that.
      local cname="${ORGNAME:-TAPPaaS}"
      msg_info "Creating Proxmox cluster '${cname}' (first node: ${host}, ring0 ${mgmt})"
      if pvecm create "$cname" --link0 "$mgmt" >/dev/null 2>&1 || pvecm create "$cname" >/dev/null 2>&1; then
        msg_ok "Created cluster '${cname}'"
        CLUSTER_ROLE="created"
      else
        msg_error "pvecm create ${cname} failed (already clustered? check 'pvecm status')"
      fi
      ;;
    join)
      if [ "$INTERACTIVE_TTY" != 1 ]; then
        msg_ok "Non-interactive: not joining automatically. Run on this node:"
        echo "      pvecm add tappaas1.mgmt.internal"
        return 0
      fi
      echo "  This node ('${host}') will JOIN the existing TAPPaaS cluster."
      read -r -p "  Existing cluster node address [tappaas1.mgmt.internal]: " peer
      peer="${peer:-tappaas1.mgmt.internal}"
      msg_info "Joining cluster via ${peer} (ring0 ${mgmt}) — you'll be prompted for that node's root password"
      echo ""
      # pvecm add is interactive (password + SSH fingerprint); run on the TTY.
      # --link0 binds this node's ring to its mgmt IP (already on `lan`).
      if pvecm add "$peer" --link0 "$mgmt" || pvecm add "$peer"; then
        msg_ok "Joined cluster via ${peer}"
        CLUSTER_ROLE="joined"
      else
        msg_error "pvecm add ${peer} failed — fix connectivity and re-run, or: pvecm add ${peer}"
      fi
      ;;
    none)
      msg_ok "Cluster step skipped (--no-cluster); node stays standalone."
      CLUSTER_ROLE="standalone"
      ;;
  esac
}


# ── Final summary (addresses the long-standing TODO at top of file) ──
print_summary() {
  local p
  echo -e "\n${GN}========== TAPPaaS node summary ==========${CL}"
  echo "  Host: $(hostname -f 2>/dev/null || hostname)"
  echo "  --- Network (bridges) ---"
  ip -br addr show type bridge 2>/dev/null | sed 's/^/    /' || true
  echo "  --- ZFS pools ---"
  zpool list 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  for p in $(zpool list -H -o name 2>/dev/null); do
    zpool status "$p" 2>/dev/null | grep -qE 'mirror|raidz' \
      || echo -e "    ${YW}WARN: pool '$p' has no mirror/raidz redundancy${CL}"
  done
  echo "  --- Cluster ---"
  pvecm status 2>/dev/null | grep -E 'Name:|Nodes:|Quorate:' | sed 's/^/    /' || echo "    (standalone)"
  echo -e "${GN}==========================================${CL}"
}

get_pve_version() {
  local pve_ver
  pve_ver="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  echo "$pve_ver"
}

get_pve_major_minor() {
  local ver="$1"
  local major minor
  IFS='.' read -r major minor _ <<<"$ver"
  echo "$major $minor"
}

component_exists_in_sources() {
  local component="$1"
  grep -h -E "^[^#]*Components:[^#]*\b${component}\b" /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -q .
}



if ! pveversion | grep -Eq "pve-manager/9\.[0-4](\.[0-9]+)*"; then
  msg_error "This version of Proxmox Virtual Environment is not supported"
  echo -e "Requires Proxmox Virtual Environment Version 9"
  echo -e "Exiting..."
  sleep 2
  exit
fi

#
# If the base post-install (repos, nag, packages, helper scripts, dist-upgrade)
# has already run, skip it but STILL run the config phases below — they are
# idempotent and may have been added/changed since the first run.
#
RUN_BASE=1
if [ -f /var/log/tappaas.step1 ]; then
  msg_ok "Base post-install already done — skipping repos/apt; running config phases only"
  msg_ok "(delete /var/log/tappaas.step1 to re-run the base install)"
  RUN_BASE=0
fi

if [ "$RUN_BASE" = 1 ]; then

# Disable any existing PVE enterprise / Ceph enterprise repo files by
# replacing them with a single, canonical disabled stanza. This avoids
# fragile in-place edits of multi-stanza deb822 files where appended
# `Enabled: false` lines can land in the wrong stanza.
msg_info "Disabling 'pve-enterprise' repository"
cat >/etc/apt/sources.list.d/pve-enterprise.sources <<EOF
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF
# Remove any legacy .list variant
rm -f /etc/apt/sources.list.d/pve-enterprise.list
msg_ok "Disabled 'pve-enterprise' repository"

msg_info "Disabling 'ceph enterprise' repository"
cat >/etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false

Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF
msg_ok "Disabled 'ceph enterprise' repository"

# Write canonical pve-no-subscription file (enabled). Remove any other
# .sources / .list files that reference pve-no-subscription to prevent
# a stale disabled entry elsewhere from confusing PVE.
msg_info "Adding 'pve-no-subscription' repository (deb822)"
for file in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
  [ -e "$file" ] || continue
  [ "$file" = "/etc/apt/sources.list.d/proxmox.sources" ] && continue
  if grep -q "pve-no-subscription" "$file"; then
    rm -f "$file"
  fi
done
cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: true
EOF
msg_ok "Added 'pve-no-subscription' repository"

# Refresh the package lists now that the repo set has changed (enterprise off,
# no-subscription on). Without this, a fresh node has no package list that
# contains community packages (jq, powertop, …) and the first `apt install`
# below fails with "Unable to locate package". Fatal: nothing after this works
# without it.
msg_info "Refreshing apt package lists"
apt-get update &>/dev/null || { msg_error "apt update failed"; exit 1; }
msg_ok "Refreshed apt package lists"


msg_info "Disabling subscription nag"
# Create external script, this is needed because DPkg::Post-Invoke is fidly with quote interpretation
mkdir -p /usr/local/bin
cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    echo "Patching Web UI nag..."
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    echo "Patching Mobile UI nag..."
    printf "%s\n" \
      "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    // --- Remove subscription dialogs ---" \
      "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
      "    dialogs.forEach(dialog => {" \
      "      const text = (dialog.textContent || '').toLowerCase();" \
      "      if (text.includes('subscription')) {" \
      "        dialog.remove();" \
      "        console.log('Removed subscription dialog');" \
      "      }" \
      "    });" \
      "" \
      "    // --- Remove subscription cards, but keep Reboot/Shutdown/Console ---" \
      "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
      "    cards.forEach(card => {" \
      "      const text = (card.textContent || '').toLowerCase();" \
      "      const hasButton = card.querySelector('button');" \
      "      if (!hasButton && text.includes('subscription')) {" \
      "        card.remove();" \
      "        console.log('Removed subscription card');" \
      "      }" \
      "    });" \
      "  }" \
      "" \
      "  const observer = new MutationObserver(removeSubscriptionElements);" \
      "  observer.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => {observer.disconnect();}, 10000);" \
      "</script>" \
      "" >> "$MOBILE_TPL"
fi
EOF
chmod 755 /usr/local/bin/pve-remove-nag.sh

cat >/etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
chmod 644 /etc/apt/apt.conf.d/no-nag-script

msg_ok "Disabled subscription nag (Delete browser cache)"

apt --reinstall install proxmox-widget-toolkit &>/dev/null || msg_error "Widget toolkit reinstall failed"

msg_info "Enabling high availability"
  systemctl enable -q --now pve-ha-lrm
  systemctl enable -q --now pve-ha-crm
  systemctl enable -q --now corosync
msg_ok "Enabled high availability"

msg_ok "Using TAPPaaS repo ${REPO} branch ${BRANCH}"

msg_info "Install TAPPaaS helper script"
cd
mkdir -p tappaas
apt -y install jq &>/dev/null || { msg_error "apt install jq failed"; exit 1; }
fetch "${REPO}${BRANCH}/src/foundation/cluster/Create-TAPPaaS-VM.sh"  ~/tappaas/Create-TAPPaaS-VM.sh  744
fetch "${REPO}${BRANCH}/src/foundation/cluster/Create-TAPPaaS-LXC.sh" ~/tappaas/Create-TAPPaaS-LXC.sh 744
fetch "${REPO}${BRANCH}/src/foundation/cluster/sanity-check.sh"       ~/tappaas/sanity-check.sh       744
msg_ok "Installed TAPPaaS helper scripts (VM + LXC + sanity-check)"

# Pre-stage the scripts/configs for the subsequent foundation steps so the whole
# install can proceed on this node without re-fetching: the firewall bootstrap,
# the NixOS VM template, and the tappaas-cicd mothership.
msg_info "Staging firewall / platform installers + template/cicd configs"
fetch "${REPO}${BRANCH}/src/foundation/network/config-firewall.sh"    ~/tappaas/config-firewall.sh    744
fetch "${REPO}${BRANCH}/src/foundation/cluster/install-platform.sh"    ~/tappaas/install-platform.sh   744
fetch "${REPO}${BRANCH}/src/foundation/templates/tappaas-nixos.json"   ~/tappaas/tappaas-nixos.json    644
fetch "${REPO}${BRANCH}/src/foundation/tappaas-cicd/tappaas-cicd.json"  ~/tappaas/tappaas-cicd.json     644
msg_ok "Staged config-firewall.sh, install-platform.sh, tappaas-nixos.json, tappaas-cicd.json"

msg_info "Copy zones.json"
fetch "${REPO}${BRANCH}/src/foundation/tappaas-cicd/manager/network-manager/zones.json" ~/tappaas/zones.json 644
msg_ok "Copied zones.json"

# Debian/Ubuntu cloud-init vendor-data snippet (issue #147).
# Pre-installs qemu-guest-agent on first boot so Proxmox can see the VM IP
# before SSH bootstrap. /etc/pve/storage.cfg is cluster-wide; the pvesm set
# only takes effect on the first node to run it, the others see it via PVE.
msg_info "Enabling 'snippets' content type on 'local' storage"
# Parse the current content list from storage.cfg (there is no `pvesm config`
# subcommand). pvesm set --content REPLACES the list, so we must preserve it.
current_content="$(awk '/^dir: local$/{f=1; next} f && /^[a-z]+:/{f=0} f && /^[[:space:]]*content[[:space:]]/{print $2; exit}' /etc/pve/storage.cfg)"
if [[ -z "$current_content" ]]; then
  msg_error "Could not read content list for 'local' storage from /etc/pve/storage.cfg"
elif ! echo "$current_content" | grep -qw snippets; then
  pvesm set local --content "${current_content},snippets" >/dev/null \
    || msg_error "Failed to enable snippets on local storage"
fi
msg_ok "Enabled 'snippets' content type on 'local' storage"

msg_info "Copy Debian vendor-data snippet"
fetch "${REPO}${BRANCH}/src/foundation/cluster/snippets/tappaas-debian-vendor.yaml" \
  /var/lib/vz/snippets/tappaas-debian-vendor.yaml 644
msg_ok "Copied Debian vendor-data snippet"

msg_info "Install power top:"
apt -y install powertop &>/dev/null || msg_error "apt update failed"
msg_ok "Installed power top"

msg_info "Install smartmontools:"
apt -y install smartmontools &>/dev/null || msg_error "smartmontools install failed"
msg_ok "Installed smartmontools"

msg_info "Configuring SSD lifecycle management (autotrim + cron jobs)"
# Download is fatal-on-failure via fetch() (issue #175); the runtime result is
# then checked explicitly so a 0-byte/broken script can never report success.
fetch "${REPO}${BRANCH}/src/foundation/cluster/setup-ssd-lifecycle.sh" \
    /root/tappaas/setup-ssd-lifecycle.sh 755
if ! /root/tappaas/setup-ssd-lifecycle.sh >/dev/null; then
    msg_error "SSD lifecycle setup failed at runtime"
    exit 1
fi
msg_ok "Configured SSD lifecycle management"

msg_info "Configuring Realtek RTL8127 NIC driver (if present)"
# MS-S1 MAX dual 10GbE (RTL8127) needs the r8127 DKMS driver — the in-tree r8169
# drops the NIC on a warm reboot (issue #308). Hardware-gated: a no-op on nodes
# without an RTL8127. The vendored, SHA256-pinned .deb is fetched alongside so the
# install is reproducible. Non-fatal: a fresh node still has working (pre-reboot)
# networking via r8169, and update.sh re-runs this enforcer every cycle to
# converge it. Needs Secure Boot off + one power cycle (the script instructs).
fetch "${REPO}${BRANCH}/src/foundation/cluster/setup-realtek-nic.sh" \
    /root/tappaas/setup-realtek-nic.sh 755
fetch "${REPO}${BRANCH}/src/foundation/cluster/assets/r8127-dkms_11.015.00-1_all.deb" \
    /root/tappaas/r8127-dkms_11.015.00-1_all.deb 644
if ! /root/tappaas/setup-realtek-nic.sh; then
    msg_error "Realtek NIC setup reported an issue (see output above) — continuing"
fi
msg_ok "Realtek NIC driver step complete"

# msg_info "Install netbird client:"
# curl -fsSL https://pkgs.netbird.io/install.sh | sh


msg_info "Updating Proxmox VE (Patience)"
apt update &>/dev/null || msg_error "apt update failed"
apt -y dist-upgrade &>/dev/null || msg_error "apt dist-upgrade failed"
msg_ok "Updated Proxmox VE"

echo "The TAPPaaS post proxmox install script was run" "$(date)" >/var/log/tappaas.step1
msg_ok "Completed TAPPaaS base post-install"

fi   # ── end RUN_BASE ────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────
# Config phases — run on every invocation, each individually idempotent.
# Order: network first (operator is at the console; corosync needs the mgmt
# IP), THEN cluster, THEN storage. Storage MUST come after the cluster is
# created: a ZFS pool created on a standalone node before it joins/forms the
# cluster is not usable as HA failover storage in Proxmox, so the tank pools
# have to be defined while the node is already a cluster member.
# ──────────────────────────────────────────────────────────────────────
mkdir -p ~/tappaas

# Phase 2 — Network: lan/wan bridges (issue #141)
if [ "$SKIP_NETWORK" = 1 ]; then
  msg_ok "Skipping network configuration (--skip-network)"
else
  msg_info "Fetching config-network.sh"
  fetch "${REPO}${BRANCH}/src/foundation/cluster/config-network.sh" ~/tappaas/config-network.sh 755
  msg_ok "Fetched config-network.sh"
  ~/tappaas/config-network.sh ${NONINT_ARG} \
    || msg_error "config-network.sh did not complete — re-run ~/tappaas/config-network.sh"
fi

# Phase 1 — Cluster (issue #140). Must run BEFORE storage (see note above).
configure_cluster
# Hand the cluster role (created|joined|member|standalone) to the orchestrator
# (foundation/install.sh) so it knows whether to run the firewall/platform chain.
printf '%s' "${CLUSTER_ROLE}" > ~/tappaas/.cluster-role 2>/dev/null || true

# Phase 3 — Storage: ZFS pools tanka1/tankb1/tankc1 (after cluster membership)
if [ "$SKIP_STORAGE" = 1 ]; then
  msg_ok "Skipping storage configuration (--skip-storage)"
else
  msg_info "Fetching config-storage.sh"
  fetch "${REPO}${BRANCH}/src/foundation/cluster/config-storage.sh" ~/tappaas/config-storage.sh 755
  msg_ok "Fetched config-storage.sh"
  ~/tappaas/config-storage.sh ${NONINT_ARG} \
    || msg_error "config-storage.sh did not complete — re-run ~/tappaas/config-storage.sh"
fi

print_summary

# This is the NODE step only ([1/5] of foundation/install.sh). The first-node
# chain (firewall → gateway cutover → sanity → platform) lives in the
# orchestrator (foundation/install.sh), which reads ~/tappaas/.cluster-role
# (written above) to decide whether to continue. So we just report node status.
echo ""
case "$CLUSTER_ROLE" in
  created)
    msg_ok "Node base + cluster '${ORGNAME:-TAPPaaS}' + storage ready (this node CREATED the cluster)." ;;
  joined)
    msg_ok "Node base + cluster join + storage ready (this node JOINED the cluster)." ;;
  *)
    msg_ok "Completed TAPPaaS node post-install (cluster role: ${CLUSTER_ROLE:-standalone})." ;;
esac



