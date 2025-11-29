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
# usage: bash TAPPaaS-NixOS-Cloning.sh VMID NEWVMNAME CORECount RAMSIZE DISKSIZE VLANTAG "description" 

function init_print_variables() {
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
}

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


function default_settings() {
  GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
  DISK_SIZE="8G"
  TEMPLATEVMID="8080"
  VMID=$1
  VMNAME=$2
  DESCRIPTION=$3
  CORE_COUNT=$3
  RAM_SIZE=$4
  DISK_SIZE=$5
  VLANTAG=$6
  BRG="lan"
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE=""
  CPU_TYPE=""
  MAC="$GEN_MAC"
  MTU=""
  STORAGE="tanka1"
}

#
# ok here we go
#
init_print_variables

# Sanity checks for input args
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] || [ -z "$6" ]; then
  echo -e "\n${RD}[ERROR]${CL} Missing required arguments."
  echo -e "Usage: bash TAPPaaS-NixOS-Cloning.sh VMID NEWVMNAME CORECount RAMSIZE DISKSIZE VLANTAG\n"
  exit 1
fi

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

default_settings

echo -e "${CREATING}${BOLD}${DGN}Creating TAPPaaS NixOS VM from proxmox vm template using the following settings:${CL}"
echo -e "     - ${BOLD}${DGN}VM ID: ${BGN}${VMID}${CL}, VM Name: ${BGN}${TVMNAME}${CL}"
echo -e "     - ${BOLD}${DGN}Cloned from template: ${BGN}${TEMPLATEVMID}${CL}"
echo -e "     - ${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
echo -e "     - ${BOLD}${DGN}Disk/Storage Location: ${BGN}${STORAGE}${CL}"
echo -e "     - ${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
echo -e "     - ${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
echo -e "     - ${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
echo -e "     - ${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
echo -e "     - ${BOLD}${DGN}VLAN: ${BGN}Default${CL}"
echo -e "     - ${BOLD}${DGN}Description: ${BGN}${DESCRIPTION}${CL}"

echo -e "\n${CREATING}${BOLD}${DGN}Starting the TAPPaaS NixOS VM creation process...${CL}\n"

qm clone $TEMPLATEVMID $VMID --name $VMNAME --full 1 >/dev/null
qm set $VMID --Tag TAPPaaS >/dev/null
qm set $VMID -description "$DESCRIPTION" >/dev/null
qm start $VMID >/dev/null
echo -e "\n${OK}${BOLD}${GN}TAPPaaS NixOS VM creation completed successfully!${CL}\n"


