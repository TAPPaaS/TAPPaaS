#!/usr/bin/env bash
# TAPPaaS CICD Module Pre-Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
MGMTVLAN="mgmt"
NODE1_FQDN="$(get_primary_node_fqdn)"
FIREWALL_FQDN="firewall.$MGMTVLAN.internal"
info "Starting TAPPaaS-CICD module update for VM: $VMNAME on node: $NODE"

# Pull all tracked repositories from configuration.json
CONFIG_FILE="/home/tappaas/config/configuration.json"
if [ -f "$CONFIG_FILE" ]; then
  # Migrate old format: convert upstreamGit+branch to repositories array
  if jq -e '.tappaas.upstreamGit' "$CONFIG_FILE" >/dev/null 2>&1; then
    echo ""
    info "Migrating configuration.json from upstreamGit/branch to repositories format..."
    OLD_URL=$(jq -r '.tappaas.upstreamGit' "$CONFIG_FILE")
    OLD_BRANCH=$(jq -r '.tappaas.branch // "stable"' "$CONFIG_FILE")
    OLD_NAME="${OLD_URL##*/}"
    OLD_NAME="${OLD_NAME%.git}"
    tmp_file=$(mktemp)
    jq --arg name "$OLD_NAME" --arg url "$OLD_URL" --arg branch "$OLD_BRANCH" \
      --arg path "/home/tappaas/${OLD_NAME}" \
      '.tappaas.repositories = [{"name": $name, "url": $url, "branch": $branch, "path": $path}] | del(.tappaas.upstreamGit) | del(.tappaas.branch)' \
      "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    info "  Migrated: upstreamGit=${OLD_URL} branch=${OLD_BRANCH} -> repositories[0]"
  fi

  REPO_COUNT=$(jq '.tappaas.repositories // [] | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
  if [ "$REPO_COUNT" -gt 0 ]; then
    echo ""
    info "Pulling latest changes from ${REPO_COUNT} repository/repositories..."
    for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
      REPO_NAME=$(jq -r ".tappaas.repositories[$i].name" "$CONFIG_FILE")
      REPO_PATH=$(jq -r ".tappaas.repositories[$i].path" "$CONFIG_FILE")
      REPO_BRANCH=$(jq -r ".tappaas.repositories[$i].branch" "$CONFIG_FILE")
      if [ -d "$REPO_PATH" ]; then
        info "  Pulling ${REPO_NAME} (branch: ${REPO_BRANCH})..."
        cd "$REPO_PATH" && git fetch origin && git checkout "$REPO_BRANCH" && git pull origin "$REPO_BRANCH" || warn "Failed to pull ${REPO_NAME}"
      else
        warn "Repository directory not found: ${REPO_PATH} (${REPO_NAME})"
      fi
    done
  else
    echo ""
    info "No repositories configured — pulling TAPPaaS from default location..."
    cd
    cd TAPPaaS || die "TAPPaaS directory not found!"
    git pull origin
  fi
else
  echo ""
  info "Configuration file not found — pulling TAPPaaS from default location..."
  cd
  cd TAPPaaS || die "TAPPaaS directory not found!"
  git pull origin
fi
# get to the right directory
cd /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd || die "TAPPaaS-CICD directory not found!"

# --- Install scripts as symlinks into /home/tappaas/bin/ ---
# NOTE: symlinks must be installed BEFORE refreshing config, so that
# create-configuration.sh in ~/bin/ points to the updated repo version.
echo ""
info "Installing scripts to /home/tappaas/bin/..."
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

# zone-controller — bare alias (no .sh) for the zone lifecycle primitive, invoked
# as `zone-controller` by variant-manager and operators. See docs/design/zone-controller.md.
if [ -f scripts/zone-controller.sh ]; then
  rm -f /home/tappaas/bin/zone-controller 2>/dev/null || true
  ln -s "$(realpath scripts/zone-controller.sh)" /home/tappaas/bin/zone-controller
fi

# --- Refresh configuration.json (re-discover nodes, validate) ---
if [[ -x /home/tappaas/bin/create-configuration.sh ]]; then
    echo ""
    info "Refreshing configuration.json..."
    /home/tappaas/bin/create-configuration.sh --update || {
        warn "Configuration refresh failed. Using existing configuration.json."
    }
fi

# --- Install foundation config files into /home/tappaas/config/ ---
# module-fields.json: symlink (read-only schema, always tracks git)
if [ -f "../module-fields.json" ]; then
  rm -f /home/tappaas/config/module-fields.json 2>/dev/null || true
  ln -s "$(realpath ../module-fields.json)" /home/tappaas/config/module-fields.json
fi

# --- Apply OPNsense os-caddy ToDomain underscore patch (issue #237 follow-up) ---
# Caddy's HostnameField rejects underscored hostnames by default; the patch
# adds <IsDNSName>Y</IsDNSName> so internal DNS labels like
# litellm.srvHome.internal can be used as reverse-proxy upstreams.
# Applied BEFORE the zone-key migration so the migration's Stage 5
# (firewall:proxy update-service per affected module) can write the
# underscored upstream without OPNsense validation failures.
FIREWALL_FQDN_EARLY="firewall.mgmt.internal"
if [ -f opnsense-patch/apply-caddy-isdnsname.sh ] \
   && ping -c 1 -W 1 "${FIREWALL_FQDN_EARLY}" >/dev/null 2>&1; then
  info "Applying os-caddy ToDomain underscore patch..."
  scp opnsense-patch/apply-caddy-isdnsname.sh root@"${FIREWALL_FQDN_EARLY}":/tmp/apply-caddy-isdnsname.sh
  ssh root@"${FIREWALL_FQDN_EARLY}" 'sh /tmp/apply-caddy-isdnsname.sh' \
    | while IFS= read -r line; do info "  $line"; done \
    || warn "  os-caddy patch reported an error — continuing"
fi

# --- One-shot rename: zone keys hyphen → underscore (issue #237) ---
# Marker-gated; runs exactly once per cluster, then becomes a no-op. Must run
# BEFORE apply-zones-merge.sh — otherwise the merge would see srv-home (current)
# vs srvHome (source) as a possible-rename and flag both for review instead of
# resolving them automatically.
if [ -f /home/tappaas/bin/migrate-zone-keys-to-underscore.sh ] \
   && [ -f /home/tappaas/config/zones.json ]; then
  /home/tappaas/bin/migrate-zone-keys-to-underscore.sh \
      || warn "  #237 zone-key migration reported issues — continuing"
fi

# --- Reconcile zones.json against upstream (3-way merge; issue #209) ---
# install2.sh seeds /home/tappaas/config/zones.json on first install but never
# revisits it. apply-zones-merge.sh closes that gap: every update-tappaas run
# adopts release changes for zones the operator hasn't touched, preserves
# operator customizations (always pins `state`), reports new/orphan/renamed
# zones, and advances zones.json.orig to the new release baseline.
if [ -f /home/tappaas/bin/apply-zones-merge.sh ] \
   && [ -f /home/tappaas/config/zones.json ]; then
  echo ""
  info "Reconciling zones.json against upstream (3-way merge)..."
  /home/tappaas/bin/apply-zones-merge.sh || warn "  zones.json merge reported an error — continuing"
fi

# --- Build and install opnsense-controller ---
echo ""
info "Building the opnsense-controller project..."
cd opnsense-controller
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/opnsense-controller-build.log | while IFS= read -r line; do printf "."; done
echo ""
# Symlink every opnsense-controller CLI from the freshly-built result into
# ~/bin (which precedes the system profile in PATH), so they all track the repo
# build via update-tappaas rather than needing a nixos-rebuild. caddy-manager,
# opnsense-firewall, rules-manager and syslog-manager were previously only in
# the system env, so their changes didn't propagate on update (issue #206).
for _oc_tool in opnsense-controller zone-manager dns-manager unbound-manager caddy-manager nat-manager opnsense-firewall rules-manager syslog-manager test-network-manager acme-manager authentik-manager; do
  _oc_src="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-controller/result/bin/${_oc_tool}"
  if [ -e "${_oc_src}" ]; then
    rm -f "/home/tappaas/bin/${_oc_tool}" 2>/dev/null || true
    ln -s "${_oc_src}" "/home/tappaas/bin/${_oc_tool}"
  fi
done

# ADR-008 network providers/orchestrator.
#  - opnsense-manager: additive alias for the OPNsense zone reconciler (same nix
#    binary as zone-manager). Per ADR-008 the orchestrator eventually takes the
#    `zone-manager` name and the binary is referenced as opnsense-manager.
#  - proxmox-manager:  Proxmox L2 provider (per-VM trunks + bridge-vids; #335).
#  - zone-reconcile:   transitional orchestrator front door (becomes zone-manager).
_oc_zm="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-controller/result/bin/zone-manager"
if [ -e "${_oc_zm}" ]; then
  rm -f /home/tappaas/bin/opnsense-manager 2>/dev/null || true
  ln -s "${_oc_zm}" /home/tappaas/bin/opnsense-manager
fi
for _fw_tool in proxmox-manager switch-manager ap-manager zone-reconcile; do
  _fw_src="/home/tappaas/TAPPaaS/src/foundation/firewall/scripts/${_fw_tool}"
  if [ -e "${_fw_src}" ]; then
    chmod +x "${_fw_src}" 2>/dev/null || true
    rm -f "/home/tappaas/bin/${_fw_tool}" 2>/dev/null || true
    ln -s "${_fw_src}" "/home/tappaas/bin/${_fw_tool}"
  fi
done
# Ensure OPNsense credentials file exists; if missing, create a skeleton and warn
if [ ! -f ~/.opnsense-credentials.txt ]; then
  warn "~/.opnsense-credentials.txt not found; creating skeleton file with empty key/secret. Please populate it with real values."
  cat > ~/.opnsense-credentials.txt <<'EOF'
key=
secret=
EOF
fi
chmod 600 ~/.opnsense-credentials.txt
info "  opnsense-controller binary installed to /home/tappaas/bin/opnsense-controller"
cd ..

# --- Build and install update-tappaas ---
echo ""
info "Building the update-tappaas project..."
cd update-tappaas
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/update-tappaas-build.log | while IFS= read -r line; do printf "."; done
echo ""
rm /home/tappaas/bin/update-tappaas 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/update-tappaas/result/bin/update-tappaas /home/tappaas/bin/update-tappaas
info "  update-tappaas binary installed to /home/tappaas/bin/"
cd ..

# --- Copy OPNsense controller patch to the firewall ---
# The os-caddy patch is already applied earlier in pre-update.sh (#237) so the
# zone-key migration's Stage 5 can write underscored upstreams.
info "Copying the AssignSettingsController.php to the OPNsense controller node..."
if ping -c 1 -W 1 "$FIREWALL_FQDN" >/dev/null 2>&1; then
  info "  Firewall $FIREWALL_FQDN reachable; will attempt to copy controller patch."
  scp opnsense-patch/InterfaceAssignController.php root@"$FIREWALL_FQDN":/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/InterfaceAssignController.php
  scp opnsense-patch/ACL.xml root@"$FIREWALL_FQDN":/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/ACL.xml
  info "  OPNsense controller patch (InterfaceAssignController.php) and ACL file copied to firewall."
else
  warn "Firewall $FIREWALL_FQDN appears unreachable; skipping controller patch copy."
fi

echo ""
info "${GN}✓${CL} All TAPPaaS-CICD programs and scripts installed successfully."
