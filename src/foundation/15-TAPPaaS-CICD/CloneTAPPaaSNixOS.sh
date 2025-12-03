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
# This script is heavily based on the Proxmox Helper Script: Docker VM
#

# This script create a NixOS VM on Proxmox for TAPPaaS usage.
#
# usage: bash TAPPaaS-NixOS-Cloning.sh namOfVM  (name of VM will be used to reference the json config file in ~/tappaas/)
 

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  if qm status $VMID &>/dev/null; then
     qm stop $VMID &>/dev/null
     qm destroy $VMID &>/dev/null
  fi
  if zfs list $STORAGE/vm-$VMID-disk-0 &>/dev/null; then
    zfs destroy $STORAGE/vm-$VMID-disk-0
  fi
   if zfs list $STORAGE/vm-$VMID-disk-1 &>/dev/null; then
    zfs destroy $STORAGE/vm-$VMID-disk-1
  fi
}

function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
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

  YW=$(echo "\033[33m")
  BL=$(echo "\033[36m")
  HA=$(echo "\033[1;34m")
  RD=$(echo "\033[01;31m")
  BGN=$(echo "\033[4;92m")
  GN=$(echo "\033[1;92m")
  DGN=$(echo "\033[32m")
  CL=$(echo "\033[m")
  BOLD=$(echo "\033[1m")
  BFR="\\r\\033[K"
  TAB="  "

#
# ok here we go
#

# Sanity checks for input args

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

# test to see if the json config file exist
JSON_CONFIG="/root/tappaas/$1.json"
if [ -z "$JSON_CONFIG" ]; then
  echo -e "\n${RD}[ERROR]${CL} Missing or mispelled required argument VMNAME. Current value: '$1'"
  echo -e "Usage: bash TAPPaaS-NixOS-Cloning.sh VMNAME\n"
  exit 1
fi
JSON=$(cat $JSON_CONFIG)

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
DISK_SIZE="8G"
TEMPLATEVMID="8080"
VMID=$(echo $JSON | jq -r '.vmid')
VMNAME=$(echo $JSON | jq -r '.hostname')
CORE_COUNT=$(echo $JSON | jq -r '.cores')
RAM_SIZE=$(echo $JSON | jq -r '.memory')
DISK_SIZE=$(echo $JSON | jq -r '.diskSize')
VLANTAG=$(echo $JSON | jq -r '.vlantag')
DESCRIPTION=$(echo $JSON | jq -r '.description')
BRG="lan"
MAC="$GEN_MAC"
STORAGE=$(echo $JSON | jq -r '.storage')
#TODO add VM tag support

#
# ok here we go
#

echo -e "${CREATING}${BOLD}${DGN}Creating TAPPaaS NixOS VM from proxmox vm template using the following settings:${CL}"
echo -e "     - ${BOLD}${DGN}VM ID: ${BGN}${VMID}${CL}"
echo -e "     - ${BOLD}${DGN}VM Name: ${BGN}${VMNAME}${CL}"
echo -e "     - ${BOLD}${DGN}Cloned from template: ${BGN}${TEMPLATEVMID}${CL}"
echo -e "     - ${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
echo -e "     - ${BOLD}${DGN}Disk/Storage Location: ${BGN}${STORAGE}${CL}"
echo -e "     - ${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
echo -e "     - ${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
echo -e "     - ${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
echo -e "     - ${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
echo -e "     - ${BOLD}${DGN}VLAN Tag: ${BGN}${VLANTAG}${CL}"
echo -e "     - ${BOLD}${DGN}Description: ${BGN}${DESCRIPTION}${CL}"

echo -e "\n${CREATING}${BOLD}${DGN}Starting the TAPPaaS NixOS VM creation process...${CL}\n"

qm clone $TEMPLATEVMID $VMID --name $VMNAME --full 1 >/dev/null
qm set $VMID --Tag TAPPaaS >/dev/null  #TODO update to take tags from json
qm set $VMID --description "$DESCRIPTION" >/dev/null
qm set $VMID --serial0 socket >/dev/null
qm set $VMID --tags TAPPaaS >/dev/null
qm set $VMID --agent enabled=1 >/dev/null
qm set $VMID --ciuser tappaas >/dev/null
qm set $VMID --ipconfig0 ip=dhcp >/dev/null
qm set $VMID --cores $CORE_COUNT --memory $RAM_SIZE >/dev/null
if [ -n "$VLANTAG" ] && [ "$VLANTAG" != "0" ]; then
  qm set $VMID --net0 virtio,bridge=$BRG,tag=$VLANTAG,macaddr=$MAC >/dev/null
else
  qm set $VMID --net0 virtio,bridge=$BRG,macaddr=$MAC >/dev/null
fi
if [ "$VMNAME" == "tappaas-cicd" ]; then
  qm set $VMID --sshkey ~/.ssh/id_rsa.pub >/dev/null
else
  qm set $VMID --sshkey ~/tappaas/tappaas-cicd.pub >/dev/null
fi
qm cloudinit update $VMID >/dev/null
# TODO fix disk resize
# qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null  

qm start $VMID >/dev/null
echo -e "\n${OK}${BOLD}${GN}TAPPaaS NixOS VM creation completed successfully" 
# echo -e "if disksize changed then log in and resize disk!${CL}\n"
# echo -e "${TAB}${BOLD}parted /dev/vda (fix followed by resizepart 3 100% then quit), followed resize2f /dev/vda3 ${CL}"



