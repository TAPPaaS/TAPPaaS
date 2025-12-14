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


msg_info "Enabling high availability"
  systemctl enable -q --now pve-ha-lrm
  systemctl enable -q --now pve-ha-crm
  systemctl enable -q --now corosync
msg_ok "Enabled high availability"

msg_info "install TAPPaaS helper script"
cd
mkdir tappaas
apt install jq
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh >~/tappaas/Create-TAPPaaS-VM.sh
chmod 744 ~/tappaas/Create-TAPPaaS-VM.sh
msg_ok "install TAPPaaS helper script"

msg_info "copy configuration.json"
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/configuration.json >~/tappaas/configuration.json
msg_ok "copy configuration.json"

echo "The TAPPaaS post proxmox install script have been run" `date` >/var/log/tappaas.step1

msg_info "Updating Proxmox VE (Patience)"
apt-get update &>/dev/null
apt-get -y dist-upgrade &>/dev/null
msg_ok "Updated Proxmox VE"

msg_info "Rebooting Proxmox VE"
msg_info "please press any key to continue or press ctrl-c to cancel"
read -n 1 -s
msg_ok "Rebooting Proxmox VE in 5 seconds"
sleep 5
reboot
