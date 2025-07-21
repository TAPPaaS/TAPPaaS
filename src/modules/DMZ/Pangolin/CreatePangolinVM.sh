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

function header_info() {
  # generated with https://patorjk.com/software/taag/#p=display&f=Big&t=Pangolin
  clear
  cat <<"EOF"
  _____                        _ _       
 |  __ \                      | (_)      
 | |__) |_ _ _ __   __ _  ___ | |_ _ __  
 |  ___/ _` | '_ \ / _` |/ _ \| | | '_ \ 
 | |  | (_| | | | | (_| | (_) | | | | | |
 |_|   \__,_|_| |_|\__, |\___/|_|_|_| |_|
                    __/ |                
                   |___/                 
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
  OS="${TAB}🖥️${TAB}${CL}"
  CONTAINERTYPE="${TAB}📦${TAB}${CL}"
  DISKSIZE="${TAB}💾${TAB}${CL}"
  CPUCORE="${TAB}🧠${TAB}${CL}"
  RAMSIZE="${TAB}🛠️${TAB}${CL}"
  CONTAINERID="${TAB}🆔${TAB}${CL}"
  HOSTNAME="${TAB}🏠${TAB}${CL}"
  BRIDGE="${TAB}🌉${TAB}${CL}"
  GATEWAY="${TAB}🌐${TAB}${CL}"
  DEFAULT="${TAB}⚙️${TAB}${CL}"
  MACADDRESS="${TAB}🔗${TAB}${CL}"
  VLANTAG="${TAB}🏷️${TAB}${CL}"
  CREATING="${TAB}🚀${TAB}${CL}"
  THIN="discard=on,ssd=1,"
}

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
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

function create_vm_descriptions_html() {
# TODO: update description to be descriptive!!
  DESCRIPTION=$(
    cat <<EOF
"<div align='center'>
  <a href='https://tappaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://www.tappaas.org/taapaas.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>TAPPaaS CICD VM</h2>

  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPpaas/TAPpaas' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPpaas/TAPpaas/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPpaas/TAPpaas/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
  <br>
  <br>
  This is the TAPPaaS Pangolin reverse proxy VM. It is based on the TAPPaaS Docker VM template and includes Git, Ansible and Terraform. it contain the entire TAPPaaS source
</div>"
EOF
  )
}

function default_settings() {
  GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
  DISK_SIZE="8G"
  TEMPLATEVMID=8000
  VMID=1000
  VMNAME="Pangolin"
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE=""
  DISK_SIZE="8G"
  CPU_TYPE=""
  CORE_COUNT="2"
  RAM_SIZE="4096"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  STORAGE="tanka1"
}

#
# ok here we go
#
if [ -z "$PVE_NODE" ]; then
  msg_error "PVE_NODE is not set. Please set the PVE_NODE variable to your Proxmox VE node IP."
  exit 1
fi

header_info
init_print_variables

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

default_settings
create_vm_descriptions_html


echo -e "${CREATING}${BOLD}${DGN}Creating TAPPaaS Pangolin VM from template using the following settings:${CL}"
echo -e "     - ${CONTAINERID}${BOLD}${DGN}TAPPaaS Template VM ID: ${BGN}${TEMPLATEVMID}${CL}, Template Name: ${BGN}${TEMPLATEVMNAME}${CL}"
echo -e "     - ${CONTAINERID}${BOLD}${DGN}TAPPaaS Pangolin VM ID: ${BGN}${VMID}${CL}, Template Name: ${BGN}${VMNAME}${CL}"
echo -e "     - ${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}i440fx${CL}"
echo -e "     - ${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
echo -e "     - ${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
echo -e "     - ${DISKSIZE}${BOLD}${DGN}Disk/Storage Location: ${BGN}${STORAGE}${CL}"
echo -e "     - ${OS}${BOLD}${DGN}CPU Model: ${BGN}KVM64${CL}"
echo -e "     - ${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
echo -e "     - ${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
echo -e "     - ${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
echo -e "     - ${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
echo -e "     - ${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}Default${CL}"
echo -e "     - ${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}Default${CL}"


msg_info "Creating a TAPPaaS Pangolin reverse proxy VM"

ssh root@$PVE_NODE "qm clone $TEMPLATEVMID $VMID --name $VMNAME --full 1 "
ssh root@$PVE_NODE "qm set $VMID --Tag TAPPaaS,DMZ"
ssh root@$PVE_NODE "qm set $VMID -description $DESCRIPTION"
ssh root@$PVE_NODE "qm start $VMID "

msg_ok "Done: Created a TAPPaaS Pangolin reverse proxy VM" 


echo -e "${CREATING}${BOLD}${DGN}VM created go to VM console and install pangolin from source${CL}"

