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
  clear
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

#
# here we go: Check that the PVE is right version and have two zfs pools
#

header_info

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

msg_info "Checking for \"tanka1\" zfspool"
if ! pvesm status -content images | grep zfspool | grep -q tanka1; then
  msg_ok "did not find a \"tanka1\" zfspool. This system will likely only work as a backup server"
fi
msg_ok "Found \"tanka1\" zfspool"

msg_info "Checking for \"tankb1\" zfspool"
if ! pvesm status -content images | grep zfspool | grep -q tankb1 ; then
  msg_ok "did not find a \"tankb1\" zfspool. Some modules of TAPPaaS will not work"
else
msg_ok "Found \"tankb1\" zfspool"
fi
#
# Check it this have already been run, in which case skip all the repository and other updates
#
if [ -f /var/log/tappaas.step1 ]; then
  msg_ok "The TAPPaaS post proxmox install script has already been run: Only updating proxmox libraries"
  msg_ok "If you want to run it again, please delete /var/log/tappaas.step1"
  msg_ok "and run the script again"
  exit 0
fi

  # check if deb822 Sources (*.sources) exist
  if find /etc/apt/sources.list.d/ -maxdepth 1 -name '*.sources' | grep -q .; then
    msg_info "Modern deb822 sources (*.sources) already exist.\n\nNo changes to sources format required.\n\nYou may still have legacy sources.list or .list files, which you can disable in the next step." 12 65 || true
  else
    check_and_disable_legacy_sources() {
      local LEGACY_COUNT=0
      local listfile="/etc/apt/sources.list"

      # Check sources.list
      if [[ -f "$listfile" ]] && grep -qE '^\s*deb ' "$listfile"; then
        ((++LEGACY_COUNT))
      fi

      # Check .list files
      local list_files
      list_files=$(find /etc/apt/sources.list.d/ -type f -name "*.list" 2>/dev/null)
      if [[ -n "$list_files" ]]; then
        LEGACY_COUNT=$((LEGACY_COUNT + $(echo "$list_files" | wc -l)))
      fi

      if ((LEGACY_COUNT > 0)); then
        # Show summary to user
        local MSG="Legacy APT sources found:\n"
        [[ -f "$listfile" ]] && MSG+=" - /etc/apt/sources.list\n"
        [[ -n "$list_files" ]] && MSG+="$(echo "$list_files" | sed 's|^| - |')\n"
        MSG+="\nDo you want to disable (comment out/rename) all legacy sources and use ONLY deb822 .sources format?\n\nRecommended for Proxmox VE 9."

        whiptail --backtitle "Proxmox VE Helper Scripts" --title "Disable legacy sources?" \
          --yesno "$MSG" 18 80
        if [[ $? -eq 0 ]]; then
          # Backup and disable sources.list
          if [[ -f "$listfile" ]] && grep -qE '^\s*deb ' "$listfile"; then
            cp "$listfile" "$listfile.bak"
            sed -i '/^\s*deb /s/^/# Disabled by Proxmox Helper Script /' "$listfile"
            msg_ok "Disabled entries in sources.list (backup: sources.list.bak)"
          fi
          # Rename all .list files to .list.bak
          if [[ -n "$list_files" ]]; then
            while IFS= read -r f; do
              mv "$f" "$f.bak"
            done <<<"$list_files"
            msg_ok "Renamed legacy .list files to .bak"
          fi
        else
          msg_error "Kept legacy sources as-is (may cause APT warnings)"
        fi
      fi
    }

    check_and_disable_legacy_sources

    # === Trixie/9.x: deb822 .sources ===
      msg_info "Correcting Proxmox VE Sources (deb822)"
      # remove all existing .list files
      rm -f /etc/apt/sources.list.d/*.list
      # remove bookworm and proxmox entries from sources.list
      sed -i '/proxmox/d;/bookworm/d' /etc/apt/sources.list || true
      # Create new deb822 sources
      cat >/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
      msg_ok "Corrected Proxmox VE 9 (Trixie) Sources"
  fi

  # ---- PVE-ENTERPRISE ----
  if component_exists_in_sources "pve-enterprise"; then
      msg_info "Disabling 'pve-enterprise' repository"
      # Use Enabled: false instead of commenting to avoid malformed entry
      for file in /etc/apt/sources.list.d/*.sources; do
        if grep -q "Components:.*pve-enterprise" "$file"; then
          if grep -q "^Enabled:" "$file"; then
            sed -i 's/^Enabled:.*/Enabled: false/' "$file"
          else
            echo "Enabled: false" >>"$file"
          fi
        fi
      done
      msg_ok "Disabled 'pve-enterprise' repository"
  fi


  # ---- PVE-NO-SUBSCRIPTION ----
  REPO_FILE=""
  REPO_ACTIVE=0
  REPO_COMMENTED=0
  for file in /etc/apt/sources.list.d/*.sources; do
    if grep -q "Components:.*pve-no-subscription" "$file"; then
      REPO_FILE="$file"
      if grep -E '^[^#]*Components:.*pve-no-subscription' "$file" >/dev/null; then
        REPO_ACTIVE=1
      elif grep -E '^#.*Components:.*pve-no-subscription' "$file" >/dev/null; then
        REPO_COMMENTED=1
      fi
      break
    fi
  done

  if [[ "$REPO_ACTIVE" -eq 1 ]]; then
      msg_ok "Kept 'pve-no-subscription' repository"
    elif [[ "$REPO_COMMENTED" -eq 1 ]]; then
      msg_info "Enabling (uncommenting) 'pve-no-subscription' repository"
      sed -i '/^#\s*Types:/,/^$/s/^#\s*//' "$REPO_FILE"
      msg_ok "Enabled 'pve-no-subscription' repository"
  else
      msg_info "Adding 'pve-no-subscription' repository (deb822)"
      cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
      msg_ok "Added 'pve-no-subscription' repository"
  fi


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

msg_info "install TAPPaaS helper script"
cd
mkdir tappaas
apt -y install jq
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh >~/tappaas/Create-TAPPaaS-VM.sh
chmod 744 ~/tappaas/Create-TAPPaaS-VM.sh
msg_ok "install TAPPaaS helper script"

msg_info "copy configuration.json"
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/configuration.json >~/tappaas/configuration.json
msg_ok "copy configuration.json"

echo "The TAPPaaS post proxmox install script have been run" `date` >/var/log/tappaas.step1

msg_info "Updating Proxmox VE (Patience)"
apt update &>/dev/null || msg_error "apt update failed"
apt -y dist-upgrade &>/dev/null || msg_error "apt dist-upgrade failed"
msg_ok "Updated Proxmox VE"

msg_info "install and measure baseline power usage:"
apt -y install powertop
msg_ok "installed and measure baseline power usage:


msg_info "Rebooting Proxmox VE"
msg_info "please press any key to continue or press ctrl-c to cancel"
read -n 1 -s
msg_ok "Rebooting Proxmox VE in 5 seconds"
sleep 5
reboot


