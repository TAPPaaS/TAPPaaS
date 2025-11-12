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
 
  # generated with https://patorjk.com/software/taag/#p=display&f=Big&t=TAPPaaS%20Bootstrap
clear
cat <<"EOF"
   ____  ____  _   __                        
  / __ \/ __ \/ | / /_______  ____  ________ 
 / / / / /_/ /  |/ / ___/ _ \/ __ \/ ___/ _ \
/ /_/ / ____/ /|  (__  )  __/ / / (__  )  __/
\____/_/   /_/ |_/____/\___/_/ /_/____/\___/ 
                                                                         
EOF

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
set -Eeo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

function exit-script() {
  clear
  echo -e "⚠  User exited script \n"
  exit
}


VMID=888
HN="opnsense"
CORE_COUNT="4"
RAM_SIZE="8192"
STORAGE="tanka1"
START_VM="yes"
  
DISK="vm-${VMID}-disk-0"
DISK_REF=${STORAGE}:${DISK}

echo -e "${DGN}Using Virtual Machine ID: ${BGN}${VMID}${CL}"
echo -e "${DGN}Using Hostname: ${BGN}${HN}${CL}"
echo -e "${DGN}Allocated Cores: ${BGN}${CORE_COUNT}${CL}"
echo -e "${DGN}Allocated RAM Size: ${BGN}${RAM_SIZE}MB${CL}"
echo -e "${DGN}Using WAN MAC Address: ${BGN}${WAN_MAC}${CL}"
echo -e "${DGN}Using Storage Location: ${BGN}${STORAGE}${CL}"
echo -e "${BL}Creating a OPNsense VM using the above default settings${CL}"

msg_ok "Retrieving the URL for the OPNsense nano Disk Image"
URL=https://pkg.opnsense.org/releases/25.7/OPNsense-25.7-nano-amd64.img.bz2
msg_ok "${CL}${BL}${URL}${CL}"
curl -f#SL -o "$(basename "$URL")" "$URL"
FILE=opnsense-vm-disk1.img
bzip2 -dcv $(basename $URL) >${FILE}
msg_ok "Downloaded ${CL}${BL}${FILE}${CL}"
# qemu-img resize ${FILE} 10G


msg_ok "Creating a OPNsense VM"
qm create $VMID -agent 1 -tablet 0 -localtime 1 -bios ovmf -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags tappaas,foundation -net0 virtio,bridge=lan -net1 virtio,bridge=wan -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
qm importdisk $VMID ${FILE} $STORAGE  # 1>&/dev/null
qm set $VMID \
  -scsi0 ${DISK_REF} \
  -boot order=scsi0 \
  -serial0 socket   # >/dev/null
qm resize $VMID scsi0 10G # >/dev/null

DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <a href='https://tappaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://tappaas.org/TAPPaaS.png' alt='TAPPaaS Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>TAPPaaS Firewall</h2>

  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPPaaS/TAPPaaS' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPPaaS/TAPPaaS/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/TAPPaaS/TAPPaaS/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
  <br>
  <br>
  This is the OPNSense Firewall/Router for TAPPaaS.
</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" # >/dev/null


msg_ok "Created a OPNsense VM ${CL}${BL}(${HN})"
