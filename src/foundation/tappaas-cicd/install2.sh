#!/usr/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm
#
# Usage:
#   install2.sh [--branch NAME] [--domain DOMAIN]
#
# Arguments passed from install-platform.sh are forwarded to create-configuration.sh.

# Strict mode: exit on error, undefined vars, pipe failures
set -euo pipefail

# Minimal logging before common-install-routines.sh is available
_info()  { echo -e "\033[32m[Info]\033[m $*"; }
_warn()  { echo -e "\033[33m[Warning]\033[m $*"; }
_error() { echo -e "\033[01;31m[Error]\033[m $*" >&2; }

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  _error "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi

# ── Argument parsing ─────────────────────────────────────────────────
# These are passed through to create-configuration.sh
DOMAIN=""
BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)  DOMAIN="${2:-}"; shift 2 ;;
    --branch)  BRANCH="${2:-}"; shift 2 ;;
    *)         shift ;;  # Ignore unknown args
  esac
done

#
# Bootstrap default: use tappaas1 as the primary node for initial cluster discovery.
# Once configuration.json exists, scripts use get_primary_node_fqdn() instead.
# For legacy systems with different hostnames, pass --primary-node to create-configuration.sh.
MGMTVLAN="mgmt"
NODE1_FQDN="${TAPPAAS_PRIMARY_NODE:-tappaas1}.$MGMTVLAN.internal"
export FIREWALL_FQDN="firewall.$MGMTVLAN.internal"  # Used by sourced scripts

# Accept SSH host keys on first connection (but still reject changed keys)
SSH_ACCEPT="-o StrictHostKeyChecking=accept-new"

# copy the public keys to the root account of every proxmox host
echo ""
_info "Installing SSH keys on Proxmox nodes..."
while read -r node; do
  NODE_FQDN="$node.$MGMTVLAN.internal"
  printf "  %s " "$node"
  ssh-copy-id $SSH_ACCEPT -i /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN" < /dev/null 2>&1 | while IFS= read -r _; do printf "."; done || echo " (failed or already installed)"
  # also make the key available for the tappaas script that configure cloud-init on the vms
  ssh -n $SSH_ACCEPT root@"$NODE_FQDN" "mkdir -p /root/tappaas" 2>/dev/null
  scp $SSH_ACCEPT /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.pub < /dev/null 2>/dev/null
  scp $SSH_ACCEPT /home/tappaas/.ssh/id_ed25519 root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.key < /dev/null 2>/dev/null
  echo " done"
done < <(ssh -n $SSH_ACCEPT root@"$NODE1_FQDN" pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node" )

# create tappaas binary director and config directory
mkdir -p /home/tappaas/config
mkdir -p /home/tappaas/bin

# Add /home/tappaas/bin to PATH
# On NixOS, .profile is sourced for login shells, and we also add to .bashrc
# for interactive non-login shells that explicitly source it
TAPPAAS_PATH_EXPORT='export PATH="/home/tappaas/bin:$PATH"'

# Export PATH for the current script execution
export PATH="/home/tappaas/bin:$PATH"

for rcfile in /home/tappaas/.profile /home/tappaas/.bashrc; do
    if ! grep -q '/home/tappaas/bin' "$rcfile" 2>/dev/null; then
        echo -e '\n# TAPPaaS bin directory' >> "$rcfile"
        echo "$TAPPAAS_PATH_EXPORT" >> "$rcfile"
        _info "Added /home/tappaas/bin to PATH in $rcfile"
    fi
done

# create the configuration.json
# Pass --domain and --branch if provided by install-platform.sh
CREATE_CONFIG_ARGS=()
[[ -n "$DOMAIN" ]] && CREATE_CONFIG_ARGS+=(--domain "$DOMAIN")
[[ -n "$BRANCH" ]] && CREATE_CONFIG_ARGS+=(--branch "$BRANCH")

if [ -f ./scripts/create-configuration.sh ]; then
  ./scripts/create-configuration.sh "${CREATE_CONFIG_ARGS[@]}"
else
  _error "./scripts/create-configuration.sh not found"
  exit 1
fi

# Seed zones.json from the canonical source (firewall module) only on first install.
# Existing /home/tappaas/config/zones.json may contain operator customizations and
# must not be overwritten here; ongoing release drift is reconciled by
# apply-zones-merge.sh (sourced from pre-update.sh on every update-tappaas; #209).
if [ ! -f /home/tappaas/config/zones.json ]; then
  cp /home/tappaas/TAPPaaS/src/foundation/firewall/zones.json /home/tappaas/config/zones.json
  _info "Seeded /home/tappaas/config/zones.json from firewall module"
else
  _info "Preserving existing /home/tappaas/config/zones.json (not overwriting)"
fi
# Seed zones.json.orig as the merge baseline (#209). Always set to the source
# at install time, so the first post-#209 update preserves any existing
# operator customizations (current diverged from orig=source → pinned).
if [ ! -f /home/tappaas/config/zones.json.orig ]; then
  cp /home/tappaas/TAPPaaS/src/foundation/firewall/zones.json /home/tappaas/config/zones.json.orig
  _info "Seeded /home/tappaas/config/zones.json.orig (3-way merge baseline)"
fi

# --- Install scripts as symlinks into /home/tappaas/bin/ ---
echo ""
_info "Installing scripts to /home/tappaas/bin/..."
cd
cd TAPPaaS || { _error "TAPPaaS directory not found!"; exit 1; }
# get to the right directory
cd src/foundation/tappaas-cicd || { _error "TAPPaaS-CICD directory not found!"; exit 1; }
for script in scripts/*.sh; do
  if [ -f "$script" ]; then
    script_name=$(basename "$script")
    target="/home/tappaas/bin/$script_name"
    # Remove the existing entry first — on NixOS it may be a symlink into a
    # read-only /etc/static/ path (issue #184), which would otherwise make
    # the subsequent chmod fail with EROFS.
    rm -f "$target" 2>/dev/null || true
    src="$(realpath "$script")"
    # chmod the resolved source, not the symlink: chmod follows symlinks,
    # so chmod'ing a /home/tappaas/bin/*.sh symlink that points into
    # /etc/static would still fail. The source lives in the writable repo.
    chmod +x "$src"
    ln -s "$src" "$target"
  fi
done

# --- ADR-007 S0: two-level dispatch links relocated components' bins ---
# scripts/*.sh above only covers not-yet-relocated scripts; components moved into
# manager/<x>/ + controller/<x>/ link their own bins via their install.sh.
for _disp in manager controller; do
  if [ -x "${_disp}/install.sh" ]; then
    _info "  linking ${_disp}/ components..."
    "./${_disp}/install.sh" || _error "  ${_disp}/install.sh reported non-zero rc"
  fi
done

# variant-manager is invoked as `variant-manager` (no .sh) per ADR-005, matching
# the zone-manager/dns-manager CLI convention. Add the bare alias alongside the
# .sh symlink the loop above created.
if [ -f scripts/variant-manager.sh ]; then
  rm -f /home/tappaas/bin/variant-manager 2>/dev/null || true
  ln -s "$(realpath scripts/variant-manager.sh)" /home/tappaas/bin/variant-manager
fi

# zone-controller — the zone lifecycle primitive (add/delete). Invoked as
# `zone-controller` (no .sh) by variant-manager and operators. See
# docs/design/zone-controller.md.
if [ -f scripts/zone-controller.sh ]; then
  rm -f /home/tappaas/bin/zone-controller 2>/dev/null || true
  ln -s "$(realpath scripts/zone-controller.sh)" /home/tappaas/bin/zone-controller
fi

# Install the cluster and firewall jsons
cd ../cluster || { _error "Cluster directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh cluster
cd ../templates || { _error "Templates directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh templates
cd ../firewall || { _error "Firewall directory not found!"; exit 1; }
FIREWALL_AVAILABLE=true
if ! ping -c 1 -W 2 "$FIREWALL_FQDN" >/dev/null 2>&1; then
    FIREWALL_AVAILABLE=false
    echo ""
    _warn "OPNsense firewall ($FIREWALL_FQDN) is not reachable."
    _warn "Deploying firewall module with firewallType=NONE."
    _warn "You will need to configure reverse proxy and firewall rules manually."
fi
/home/tappaas/bin/copy-update-json.sh firewall
if [[ "$FIREWALL_AVAILABLE" == "false" ]]; then
    # Override: remove VM dependencies and mark as non-OPNsense deployment
    tmp_fw=$(mktemp)
    jq '.dependsOn = [] | .firewallType = "NONE"' /home/tappaas/config/firewall.json > "$tmp_fw" \
        && mv "$tmp_fw" /home/tappaas/config/firewall.json
fi
cd ../tappaas-cicd || { _error "TAPPaaS-CICD directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh tappaas-cicd

# run the full tappaas-cicd update scripts with all dependencies and checks
/home/tappaas/bin/update-module.sh tappaas-cicd --no-snapshot
/home/tappaas/bin/update-module.sh cluster

# Source common-install-routines.sh to replace the minimal _info/_warn/_error with full versions
. /home/tappaas/bin/common-install-routines.sh

if [[ "$FIREWALL_AVAILABLE" == "true" ]]; then
    # Install and enable QEMU guest agent on OPNsense (FreeBSD)
    # This allows Proxmox to communicate with the firewall VM via the guest agent
    echo ""
    info "Installing QEMU guest agent on OPNsense..."
    if ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg info os-qemu-guest-agent'" &>/dev/null; then
        info "  QEMU guest agent already installed"
    else
        ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg install -y os-qemu-guest-agent'" || {
            warn "QEMU guest agent installation failed. Install manually via OPNsense UI."
        }
    fi
    info "Enabling QEMU guest agent service..."
    ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'sysrc qemu_guest_agent_enable=YES'" 2>/dev/null || true
    if ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'service qemu-guest-agent status'" &>/dev/null; then
        info "  QEMU guest agent service is already running"
    else
        ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'service qemu-guest-agent start'" 2>/dev/null || {
            warn "QEMU guest agent service could not be started. Enable manually in OPNsense."
        }
    fi

    # Set up Caddy on the firewall BEFORE updating the firewall module. The
    # firewall module's firewall:proxy update-service calls the OPNsense Caddy
    # API (/api/caddy/...), which 404s until the os-caddy plugin is installed —
    # and installing it is setup-caddy.sh's job. (It relies on opnsense-controller,
    # which the tappaas-cicd update above already installed.) On a long-lived
    # firewall os-caddy was already present, masking the ordering; the prebuilt
    # image has no plugins, so it must run first.
    echo ""
    info "Setting up Caddy reverse proxy (installs os-caddy)..."
    chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh
    /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh || {
        warn "Caddy setup encountered issues. Please review and complete manually."
    }

    # Update the firewall module (now that os-caddy/the Caddy API is available).
    /home/tappaas/bin/update-module.sh firewall --no-snapshot
else
    echo ""
    warn "Skipping firewall update (no OPNsense firewall)."
    warn "Skipping Caddy reverse proxy setup (no OPNsense firewall)."
    warn "When modules with firewall:proxy dependency are installed,"
    warn "you will see manual configuration instructions for your firewall."
fi

# Completion marker. Written ONLY here, at the very end, so a re-run can tell a
# finished install from one that wrote configuration.json early then failed later
# (install-platform.sh Phase B keys its idempotent skip off this file).
mkdir -p /home/tappaas/config
touch /home/tappaas/config/.tappaas-cicd-installed

echo ""
info "${GN}✓${CL} TAPPaaS-CICD installation completed successfully."
