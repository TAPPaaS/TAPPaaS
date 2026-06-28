#!/usr/bin/env bash
# TAPPaaS CICD Module Pre-Update
#

set -euo pipefail

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
MGMTVLAN="mgmt"
NODE1_FQDN="$(get_primary_node_fqdn)"
FIREWALL_FQDN="firewall.$MGMTVLAN.internal"
info "Starting TAPPaaS-CICD module update for VM: $VMNAME on node: $NODE"

# Pull all tracked repositories. The repository list is now canonical in
# site.json .repositories; get_repositories() reads it there first and falls
# back to the legacy configuration.json .tappaas.repositories while both files
# coexist (so updates keep pulling after configuration.json is deleted).
CONFIG_FILE="/home/tappaas/config/configuration.json"

# Legacy one-shot migration: upstreamGit+branch -> .tappaas.repositories. This
# is retired once configuration.json is gone, so it is fully guarded on the file
# actually existing (must never error on a missing configuration.json).
if [ -f "$CONFIG_FILE" ] && jq -e '.tappaas.upstreamGit' "$CONFIG_FILE" >/dev/null 2>&1; then
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

REPOS_JSON="$(get_repositories)"
REPO_COUNT=$(echo "$REPOS_JSON" | jq 'length' 2>/dev/null || echo "0")
if [ "$REPO_COUNT" -gt 0 ]; then
  echo ""
  info "Pulling latest changes from ${REPO_COUNT} repository/repositories..."
  for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
    REPO_NAME=$(echo "$REPOS_JSON" | jq -r ".[$i].name")
    REPO_PATH=$(echo "$REPOS_JSON" | jq -r ".[$i].path")
    REPO_BRANCH=$(echo "$REPOS_JSON" | jq -r ".[$i].branch")
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

# --- ADR-007 S0: two-level dispatch links relocated components' bins ---
# The scripts/*.sh glob above only covers scripts NOT yet relocated. Components
# moved into manager/<x>/ and controller/<x>/ link their own bins via their
# install.sh, driven by the per-directory dispatcher. Additive + idempotent;
# a no-op while a component still lives under scripts/.
for _disp in manager controller; do
  if [ -x "${_disp}/install.sh" ]; then
    info "  linking ${_disp}/ components..."
    "./${_disp}/install.sh" || warn "  ${_disp}/install.sh reported non-zero rc"
  fi
done

# zone-controller — bare alias (no .sh) for the zone lifecycle primitive, invoked
# as `zone-controller` by operators and test harnesses. See docs/design/zone-controller.md.
if [ -f scripts/zone-controller.sh ]; then
  rm -f /home/tappaas/bin/zone-controller 2>/dev/null || true
  ln -s "$(realpath scripts/zone-controller.sh)" /home/tappaas/bin/zone-controller
fi

# --- Refresh configuration.json (re-discover nodes, validate) ---
# F2: ONLY refresh when the legacy configuration.json ALREADY exists (a system
# not yet migrated to site.json). On a fresh, site.json-native install there is
# no configuration.json and `create-configuration.sh --update` would MINT a
# vestigial one (with a placeholder domain) — so it must not run. site.json is
# the source of truth for fresh installs; the node-discovery refresh applies only
# to legacy systems still backed by configuration.json.
if [[ -f /home/tappaas/config/configuration.json && -x /home/tappaas/bin/create-configuration.sh ]]; then
    echo ""
    info "Refreshing configuration.json (legacy system)..."
    /home/tappaas/bin/create-configuration.sh --update || {
        warn "Configuration refresh failed. Using existing configuration.json."
    }
fi

# --- ADR-007 P2 (S3a): auto-migrate configuration.json -> site.json ---
# PHASED migration: create site.json once, when configuration.json exists and
# site.json does NOT. configuration.json is NOT deleted here (the flag-day
# cutover is a later step), and existing configuration.json readers are left
# untouched. Idempotent + guarded: once site.json exists this is a no-op, and
# the migration script itself no-ops on an existing site.json.
if [[ -f /home/tappaas/config/configuration.json && ! -f /home/tappaas/config/site.json ]]; then
    if [[ -x /home/tappaas/bin/migrate-configuration.sh ]]; then
        echo ""
        info "Migrating configuration.json -> site.json (ADR-007 P2)..."
        /home/tappaas/bin/migrate-configuration.sh --config-dir /home/tappaas/config \
            || warn "  site.json migration reported an error — continuing (configuration.json untouched)"
    else
        warn "migrate-configuration.sh not on PATH yet; skipping site.json migration this run."
    fi
fi

# --- Install foundation config files into /home/tappaas/config/ ---
# module-fields.json: symlink (read-only schema, always tracks git)
if [ -f "../schemas/module-fields.json" ]; then
  rm -f /home/tappaas/config/module-fields.json 2>/dev/null || true
  ln -s "$(realpath ../schemas/module-fields.json)" /home/tappaas/config/module-fields.json
fi

# --- Apply OPNsense os-caddy ToDomain underscore patch (issue #237 follow-up) ---
# Caddy's HostnameField rejects underscored hostnames by default; the patch
# adds <IsDNSName>Y</IsDNSName> so internal DNS labels like
# litellm.srvHome.internal can be used as reverse-proxy upstreams.
# Applied BEFORE the zone-key migration so the migration's Stage 5
# (network:proxy update-service per affected module) can write the
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
# BEFORE the zones-merge below — otherwise the merge would see srv-home (current)
# vs srvHome (source) as a possible-rename and flag both for review instead of
# resolving them automatically.
if [ -f /home/tappaas/bin/migrate-zone-keys-to-underscore.sh ] \
   && [ -f /home/tappaas/config/zones.json ]; then
  /home/tappaas/bin/migrate-zone-keys-to-underscore.sh \
      || warn "  #237 zone-key migration reported issues — continuing"
fi

# --- Reconcile zones.json against upstream (rename-aware 3-way merge; #209 / ADR-007 Design A) ---
# install.sh seeds /home/tappaas/config/zones.json on first install but never
# revisits it. `network-manager zones-merge` closes that gap (replacing the
# retired apply-zones-merge.sh): every update-tappaas run re-bases the repo
# template into THIS installation's renamed namespace (zones.rename.json), then
# 3-way-merges zones.json vs zones.json.orig vs zones.rename.json — adopting
# release changes for zones the operator hasn't touched, preserving operator
# customizations (always pins `state`), reporting new/orphan/renamed zones, and
# advancing zones.json.orig to the renamed source. Because srv/home/guest are
# renamed away in the source, the merge can never re-introduce them (the old
# duplicate-VLAN corruption). No-ops if network-manager is not yet on PATH
# (first install before its bin is linked above).
if command -v network-manager >/dev/null 2>&1 \
   && [ -f /home/tappaas/config/zones.json ]; then
  echo ""
  info "Reconciling zones.json against upstream (rename-aware 3-way merge)..."
  network-manager zones-merge || warn "  zones.json merge reported an error — continuing"
fi

# --- Consistency-check zones.json against the installation (ADR-007 S6 N4) ---
# Report-only audit run at every update: validates zones.json is well-formed,
# VLAN/subId-unique, referentially intact, has an active mgmt zone, and that
# every installed module's zone exists and is Active. Non-fatal by design — a
# non-zero result is warned and the update continues. No-ops if network-manager
# is not yet on PATH (first install before its bin is linked above).
if command -v network-manager >/dev/null 2>&1 \
   && [ -f /home/tappaas/config/zones.json ]; then
  echo ""
  info "Checking zones.json consistency (network-manager zones-check)..."
  network-manager zones-check 2>&1 | while IFS= read -r line; do info "  $line"; done
  # PIPESTATUS[0] is the zones-check rc (the while loop never fails).
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    warn "  zones-check reported errors — continuing (report-only; review the lines above)"
  fi
fi

# --- Build and install opnsense-controller ---
echo ""
info "Building the opnsense-controller project..."
cd controller/opnsense-controller
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/opnsense-controller-build.log | while IFS= read -r line; do printf "."; done
echo ""
# Symlink every opnsense-controller CLI from the freshly-built result into
# ~/bin (which precedes the system profile in PATH), so they all track the repo
# build via update-tappaas rather than needing a nixos-rebuild. caddy-manager,
# opnsense-firewall, rules-manager and syslog-manager were previously only in
# the system env, so their changes didn't propagate on update (issue #206).
for _oc_tool in opnsense-controller zone-manager dns-manager unbound-manager caddy-manager nat-manager opnsense-firewall rules-manager syslog-manager test-network-manager acme-manager; do
  _oc_src="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/controller/opnsense-controller/result/bin/${_oc_tool}"
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
_oc_zm="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/controller/opnsense-controller/result/bin/zone-manager"
if [ -e "${_oc_zm}" ]; then
  rm -f /home/tappaas/bin/opnsense-manager 2>/dev/null || true
  ln -s "${_oc_zm}" /home/tappaas/bin/opnsense-manager
fi
# ADR-007 S0: proxmox-manager/switch-controller/ap-manager moved to
# tappaas-cicd/controller/<x>-controller/ and zone-reconcile to manager/network-manager/;
# they are now linked by the controller/ + manager/ dispatchers above. (was: firewall/scripts loop)
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
cd ../..   # back to tappaas-cicd/ (opnsense-controller now under controller/)

# --- Build and install identity-controller (ADR-007 S2b-1) ---
# Authentik runtime controller, extracted from opnsense-controller. Built and
# linked the same way: nix-build then symlink its CLIs from result/bin into
# ~/bin so they track the repo build without a nixos-rebuild. Ships
# authentik-manager (the verb the people-manager calls) and identity-controller.
echo ""
info "Building the identity-controller project..."
cd controller/identity-controller
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/identity-controller-build.log | while IFS= read -r line; do printf "."; done
echo ""
for _ic_tool in authentik-manager identity-controller; do
  _ic_src="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/controller/identity-controller/result/bin/${_ic_tool}"
  if [ -e "${_ic_src}" ]; then
    rm -f "/home/tappaas/bin/${_ic_tool}" 2>/dev/null || true
    ln -s "${_ic_src}" "/home/tappaas/bin/${_ic_tool}"
  fi
done
info "  identity-controller binaries installed to /home/tappaas/bin/ (authentik-manager, identity-controller)"
cd ../..   # back to tappaas-cicd/

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
