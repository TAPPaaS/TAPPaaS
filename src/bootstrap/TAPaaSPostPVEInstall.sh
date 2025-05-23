#!/usr/bin/env bash

# Copyright (c) 2025 TAPaaS org
# This file is part of the TAPaaS project.
# TAPaaS is free software: you can redistribute it and/or modify
# it under the terms of the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0) license.
# Author: larsrossen
#
# This script is heavely based on the Proxmox Helper Script: Proxmost PVE post Install
#
# TODO: Display final HW config, 
# TODO: Throw warning is no mirror on zpools and boot. Configure power management


header_info() {
  clear
  cat <<"EOF"
 _______       _____             _____   _____          _     _______      ________   _____           _        _ _ 
 |__   __|/\   |  __ \           / ____| |  __ \        | |   |  __ \ \    / /  ____| |_   _|         | |      | | |
    | |  /  \  | |__) |_ _  __ _| (___   | |__) |__  ___| |_  | |__) \ \  / /| |__      | |  _ __  ___| |_ __ _| | |
    | | / /\ \ |  ___/ _` |/ _` |\___ \  |  ___/ _ \/ __| __| |  ___/ \ \/ / |  __|     | | | '_ \/ __| __/ _` | | |
    | |/ ____ \| |  | (_| | (_| |____) | | |  | (_) \__ \ |_  | |      \  /  | |____   _| |_| | | \__ \ || (_| | | |
    |_/_/    \_\_|   \__,_|\__,_|_____/  |_|   \___/|___/\__| |_|       \/   |______| |_____|_| |_|___/\__\__,_|_|_|

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

if ! pveversion | grep -Eq "pve-manager/8\.[0-4](\.[0-9]+)*"; then
  msg_error "This version of Proxmox Virtual Environment is not supported"
  echo -e "Requires Proxmox Virtual Environment Version 8.0 or later."
  echo -e "Exiting..."
  sleep 2
  exit
fi

msg_info "Checking for \"tank1\" zfspool"
if ! pvesm status -content images | grep zfspool | grep -q tank1; then
  msg_error "did not find a \"tank1\" zfspool"
  echo -e "Exiting..."
  sleep 2
  exit
fi
msg_ok "Found \"tank1\" zfspool"

msg_info "Checking for \"tank2\" zfspool"
if ! pvesm status -content images | grep zfspool | grep -q tank2 ; then
  msg_ok "did not find a \"tank2\" zfspool. Some modules of TAPaaS will not work"
else
msg_ok "Found \"tank2\" zfspool"
fi
#
# Check it this have already been run, in which case skip all the repository and other updates
#

if ! [ -f /var/log/tapaas.step1 ]; then
#
# 
msg_info "Correcting Proxmox VE Sources"
  cat <<EOF >/etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF
  echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-bookworm-firmware.conf
msg_ok "Corrected Proxmox VE Sources"
#
msg_info "Disabling 'pve-enterprise' repository"
  cat <<EOF >/etc/apt/sources.list.d/pve-enterprise.list
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
msg_ok "Disabled 'pve-enterprise' repository"
#
msg_info "Enabling 'pve-no-subscription' repository"
  cat <<EOF >/etc/apt/sources.list.d/pve-install-repo.list
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
msg_ok "Enabled 'pve-no-subscription' repository"
#
msg_info "Correcting 'ceph package repositories'"
  cat <<EOF >/etc/apt/sources.list.d/ceph.list
# deb https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
# deb https://enterprise.proxmox.com/debian/ceph-reef bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
EOF
msg_ok "Corrected 'ceph package repositories'"
#
msg_info "Disabling subscription nag"
  echo "DPkg::Post-Invoke { \"dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; if [ \$? -eq 1 ]; then { echo 'Removing subscription nag from UI...'; sed -i '/.*data\.status.*{/{s/\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi\"; };" >/etc/apt/apt.conf.d/no-nag-script
  apt --reinstall install proxmox-widget-toolkit &>/dev/null
msg_ok "Disabled subscription nag (Delete browser cache)"
#
msg_info "Enabling high availability"
  systemctl enable -q --now pve-ha-lrm
  systemctl enable -q --now pve-ha-crm
  systemctl enable -q --now corosync
msg_ok "Enabled high availability"
#
echo "The TAPaaS post proxmox install script have been run" `date` >/var/log/tapaas.step1
#
else
  msg_ok "The TAPaaS post proxmox install script has already been run: Only updating proxmox libraries"
  msg_ok "If you want to run it again, please delete /var/log/tapaas.step1"
  msg_ok "and run the script again"
fi
#  
msg_info "Updating Proxmox VE (Patience)"
apt-get update &>/dev/null
apt-get -y dist-upgrade &>/dev/null
msg_ok "Updated Proxmox VE"

msg_info "Rebooting Proxmox VE in 2 seconds"
  sleep 2
  msg_ok "rebooting Proxmox VE"
reboot
