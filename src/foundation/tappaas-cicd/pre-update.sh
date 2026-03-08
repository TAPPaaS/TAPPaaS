#!/usr/bin/env bash
# TAPPaaS CICD Module Update
#

set -e

. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$1")"
NODE="$(get_config_value 'node' 'tappaas1')"
MGMTVLAN="mgmt"
NODE1_FQDN="tappaas1.$MGMTVLAN.internal"
FIREWALL_FQDN="firewall.$MGMTVLAN.internal"
echo -e "\nStarting TAPPaaS-CICD module update for VM: $VMNAME on node: $NODE"

# Pull all tracked repositories from configuration.json
CONFIG_FILE="/home/tappaas/config/configuration.json"
if [ -f "$CONFIG_FILE" ]; then
  # Migrate old format: convert upstreamGit+branch to repositories array
  if jq -e '.tappaas.upstreamGit' "$CONFIG_FILE" >/dev/null 2>&1; then
    echo -e "\nMigrating configuration.json from upstreamGit/branch to repositories format..."
    OLD_URL=$(jq -r '.tappaas.upstreamGit' "$CONFIG_FILE")
    OLD_BRANCH=$(jq -r '.tappaas.branch // "main"' "$CONFIG_FILE")
    OLD_NAME="${OLD_URL##*/}"
    OLD_NAME="${OLD_NAME%.git}"
    tmp_file=$(mktemp)
    jq --arg name "$OLD_NAME" --arg url "$OLD_URL" --arg branch "$OLD_BRANCH" \
      --arg path "/home/tappaas/${OLD_NAME}" \
      '.tappaas.repositories = [{"name": $name, "url": $url, "branch": $branch, "path": $path}] | del(.tappaas.upstreamGit) | del(.tappaas.branch)' \
      "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    echo "  Migrated: upstreamGit=${OLD_URL} branch=${OLD_BRANCH} -> repositories[0]"
  fi

  REPO_COUNT=$(jq '.tappaas.repositories // [] | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
  if [ "$REPO_COUNT" -gt 0 ]; then
    echo -e "\nPulling latest changes from ${REPO_COUNT} repository/repositories..."
    for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
      REPO_NAME=$(jq -r ".tappaas.repositories[$i].name" "$CONFIG_FILE")
      REPO_PATH=$(jq -r ".tappaas.repositories[$i].path" "$CONFIG_FILE")
      REPO_BRANCH=$(jq -r ".tappaas.repositories[$i].branch" "$CONFIG_FILE")
      if [ -d "$REPO_PATH" ]; then
        echo "  Pulling ${REPO_NAME} (branch: ${REPO_BRANCH})..."
        cd "$REPO_PATH" && git fetch origin && git checkout "$REPO_BRANCH" && git pull origin "$REPO_BRANCH" || echo "  Warning: Failed to pull ${REPO_NAME}"
      else
        echo "  Warning: Repository directory not found: ${REPO_PATH} (${REPO_NAME})"
      fi
    done
  else
    echo -e "\nNo repositories configured — pulling TAPPaaS from default location..."
    cd
    cd TAPPaaS || { echo "TAPPaaS directory not found!"; exit 1; }
    git pull origin
  fi
else
  echo -e "\nConfiguration file not found — pulling TAPPaaS from default location..."
  cd
  cd TAPPaaS || { echo "TAPPaaS directory not found!"; exit 1; }
  git pull origin
fi
# get to the right directory
cd /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd || { echo "TAPPaaS-CICD directory not found!"; exit 1; }

# --- Install scripts as symlinks into /home/tappaas/bin/ ---
echo -e "\nInstalling scripts to /home/tappaas/bin/..."
for script in scripts/*.sh; do
  if [ -f "$script" ]; then
    script_name=$(basename "$script")
    target="/home/tappaas/bin/$script_name"
    # Remove existing file or symlink if it exists
    rm -f "$target" 2>/dev/null || true
    # Create symlink to the script in the repo
    ln -s "$(realpath "$script")" "$target"
  fi
done
# chmod only real files/valid symlinks, skip dangling symlinks
for f in /home/tappaas/bin/*.sh; do
  [ -e "$f" ] && chmod +x "$f"
done

# --- Install foundation config files into /home/tappaas/config/ ---
# module-fields.json: symlink (read-only schema, always tracks git)
if [ -f "../module-fields.json" ]; then
  rm -f /home/tappaas/config/module-fields.json 2>/dev/null || true
  ln -s "$(realpath ../module-fields.json)" /home/tappaas/config/module-fields.json
fi
# zones.json: copy (may be modified locally by the user)
if [ -f "../zones.json" ]; then
  cp "../zones.json" /home/tappaas/config/zones.json
fi

# --- Build and install opnsense-controller ---
echo -en "\nBuilding the opnsense-controller project"
cd opnsense-controller
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/opnsense-controller-build.log | while IFS= read -r line; do printf "."; done
rm /home/tappaas/bin/opnsense-controller 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-controller/result/bin/opnsense-controller /home/tappaas/bin/opnsense-controller
rm /home/tappaas/bin/zone-manager 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-controller/result/bin/zone-manager /home/tappaas/bin/zone-manager
rm /home/tappaas/bin/dns-manager 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-controller/result/bin/dns-manager /home/tappaas/bin/dns-manager
# Ensure OPNsense credentials file exists; if missing, create a skeleton and warn
if [ ! -f ~/.opnsense-credentials.txt ]; then
  echo "Warning: ~/.opnsense-credentials.txt not found; creating skeleton file with empty key/secret. Please populate it with real values."
  cat > ~/.opnsense-credentials.txt <<'EOF'
key=
secret=
EOF
fi
chmod 600 ~/.opnsense-credentials.txt
echo -e "\nopnsense-controller binary installed to /home/tappaas/bin/opnsense-controller"
cd ..

# --- Build and install update-tappaas ---
echo -en "\nBuilding the update-tappaas project"
cd update-tappaas
stdbuf -oL nix-build -A default default.nix 2>&1 | tee /tmp/update-tappaas-build.log | while IFS= read -r line; do printf "."; done
rm /home/tappaas/bin/update-tappaas 2>/dev/null || true
ln -s /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/update-tappaas/result/bin/update-tappaas /home/tappaas/bin/update-tappaas
echo -e "\nupdate-tappaas binary installed to /home/tappaas/bin/"
cd ..

# --- Copy OPNsense controller patch to the firewall ---
echo -e "Copying the AssignSettingsController.php to the OPNsense controller node..."
if ping -c 1 -W 1 "$FIREWALL_FQDN" >/dev/null 2>&1; then
  echo "Firewall $FIREWALL_FQDN reachable; will attempt to copy controller patch."
  scp opnsense-patch/InterfaceAssignController.php root@"$FIREWALL_FQDN":/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/InterfaceAssignController.php
  scp opnsense-patch/ACL.xml root@"$FIREWALL_FQDN":/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/ACL.xml
  echo "OPNsense controller patch (InterfaceAssignController.php) and ACL file copied to firewall."
else
  echo "Warning: Firewall $FIREWALL_FQDN appears unreachable; skipping controller patch copy."
fi

echo -e "\nAll TAPPaaS-CICD programs and scripts installed successfully."
