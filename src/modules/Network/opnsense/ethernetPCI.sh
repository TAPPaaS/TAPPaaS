#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
#
# This script is heavily based on the Proxmox Helper Script: Proxmost PVE post Install
#
# TODO: Display final HW config, 
# TODO: Throw warning is no mirror on zpools and boot. Configure power management

#
# Validate that the ports are available and PCI passthrugh is possible

function header_info {
  clear
  cat <<"EOF"

  PCI Passthrough for 
   ____  ____  _   __                        
  / __ \/ __ \/ | / /_______  ____  ________ 
 / / / / /_/ /  |/ / ___/ _ \/ __ \/ ___/ _ \
/ /_/ / ____/ /|  (__  )  __/ / / (__  )  __/
\____/_/   /_/ |_/____/\___/_/ /_/____/\___/ 
                                                                         
EOF
}

function init_print_variables() {
  YW=$(echo "\033[33m")
  BL=$(echo "\033[36m")
  HA=$(echo "\033[1;34m")
  RD=$(echo "\033[01;31m")
  BGN=$(echo "\033[4;92m")
  GN=$(echo "\033[1;92m")
  DGN=$(echo "\033[32m")
  CL=$(echo "\033[m")

  CL=$(echo "\033[m")
  BOLD=$(echo "\033[1m")
  BFR="\\r\\033[K"
  HOLD=" "
  TAB="  "

  CM="${TAB}✔️${TAB}${CL}"
  CROSS="${TAB}✖️${TAB}${CL}"
  INFO="${TAB}💡${TAB}${CL}"
}

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
}

function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}

function msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}


function exit-script() {
  clear
  echo -e "\n${CROSS}${RD}User exited script${CL}\n"
  exit
}

#
# ok here we go
#
header_info
init_print_variables

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

if [ -z "$PVE_NODE" ]; then
  msg_error "PVE_NODE is not set. Please set the PVE_NODE variable to your Proxmox VE node IP."
  exit 1
fi


#
# find the ethernet pci devices
msg_info "Finding ethernet PCI devices\n"
msg_info "ensure that the ethernet devices are on different iommugroups. if not then mappin is not possible \n"
msg_info "if the iommu group numner for the ethernet ports you intend to PCI map are not unique in the list below then you might have issues\n"
echo
ssh root@$PVE_NODE 'pvesh get /nodes/testserver1/hardware/pci --pci-class-blacklist ""' | grep -e Ethernet -e class |  cut -c 25-131

msg_info "Now let us find the PCI devices to map into the VM for WAN and LAN"

# Get Ethernet controllers and format as whiptail menu pairs: "<PCI_ID> <Description>"
ETHERNET_MENU_ITEMS=()
while IFS= read -r line; do
  PCI_ID=$(echo "$line" | awk '{print $1}')
  DESC=$(echo "$line" | cut -d' ' -f2-)
  ETHERNET_MENU_ITEMS+=("$PCI_ID" "$DESC")
done < <(ssh root@$PVE_NODE 'lspci -nnk' | grep "Ethernet controller")

if [ ${#ETHERNET_MENU_ITEMS[@]} -eq 0 ]; then
  msg_error "No Ethernet controllers found."
  exit 1
fi

SELECTED_LAN_PCI=$(
  whiptail --backtitle "OPNSense PCI Port selection" \
    --title "Ethernet Port for LAN" \
    --menu "Please select" 25 70 16 \
    "${ETHERNET_MENU_ITEMS[@]}" \
    3>&1 1>&2 2>&3
)

if [ -z "$SELECTED_LAN_PCI" ]; then
  exit-script
fi

msg_ok "Selected PCI device for LAN port: $SELECTED_LAN_PCI\n"

# create passthrough for LAN port
msg_info "Configuring PCI passthrough for LAN port ($SELECTED_LAN_PCI) to VM 666..."

ssh root@$PVE_NODE "qm set 666 -hostpci1 $SELECTED_LAN_PCI"

if [ $? -eq 0 ]; then
  msg_ok "PCI passthrough configured for LAN port ($SELECTED_LAN_PCI) on VM 666."
else
  msg_error "Failed to configure PCI passthrough for LAN port ($SELECTED_LAN_PCI) on VM 666."
  exit 1
fi

SELECTED_WAN_PCI=$(
  whiptail --backtitle "OPNSense PCI Port selection" \
    --title "Ethernet Port for WAN" \
    --menu "Please select" 25 70 16 \
    "${ETHERNET_MENU_ITEMS[@]}" \
    3>&1 1>&2 2>&3
)

if [ -z "$SELECTED_WAN_PCI" ]; then
  exit-script
fi

msg_ok "Selected PCI device for WAN port: $SELECTED_WAN_PCI\n"

# create passthrough for WAN port
msg_info "Configuring PCI passthrough for WAN port ($SELECTED_WAN_PCI) to VM 666..."

ssh root@$PVE_NODE "qm set 666 -hostpci2 $SELECTED_WAN_PCI"

if [ $? -eq 0 ]; then
  msg_ok "PCI passthrough configured for WAN port ($SELECTED_WAN_PCI) on VM 666."
else
  msg_error "Failed to configure PCI passthrough for WAN port ($SELECTED_WAN_PCI) on VM 666."
  exit 1
fi


