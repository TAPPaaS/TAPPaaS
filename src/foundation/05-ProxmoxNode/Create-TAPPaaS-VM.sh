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

# This script create a NixOS VM on Proxmox for TAPPaaS usage.
#
# Usage: bash TAPPaaS-NixOS-Cloning.sh name-of-VM  (name of VM will be used to reference the json config file in ~/tappaas/)

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

function info() {
  local msg="$1"
  echo -e "${DGN}${msg}${CL}"
}

function create_vm_descriptions_html() {
  local TEXT="$1"
  DESCRIPTION_HTML=$(
    cat <<EOF
<div align='center'>
  <a href='https://tappaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://www.tappaas.org/taapaas.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>TAPPaaS NixOS VM</h2>

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
  $TEXT
</div>
EOF
  )
}


YW=$(echo "\033[33m")    # Yellow
BL=$(echo "\033[36m")    # Cyan
RD=$(echo "\033[01;31m") # Red
BGN=$(echo "\033[4;92m") # Bright Green with underline
GN=$(echo "\033[1;92m")  # Green with bold
DGN=$(echo "\033[32m")   # Green
CL=$(echo "\033[m")      # Clear
BOLD=$(echo "\033[1m")   # Bold
#
# ok here we go
#

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
BRG=$(echo $JSON | jq -r '.bridge')
VLANTAG=$(echo $JSON | jq -r '.vlantag')
DESCRIPTION=$(echo $JSON | jq -r '.description')
BRIDGE=$(echo $JSON | jq -r '.bridge')
MAC="$GEN_MAC"
STORAGE=$(echo $JSON | jq -r '.storage')
VMTAG=$(echo $JSON | jq -r '.vmtag')
IMAGETYPE=$(echo $JSON | jq -r '.imageType')
IMAGE=$(echo $JSON | jq -r '.image')
if ! [ $IMAGETYPE == "clone"] then
  IMAGELOCATION=$(echo $JSON | jq -r '.imageLocation')  
  URL=${IMAGELOCATION}${IMAGE}
  if [ "$IMAGETYPE" == "iso" ]; then
    info "Downlaoding ISO file: $URL"
    curl -fsSL $URL -o /var/lib/vz/template/iso/$IMAGE
    info "Downloaded ISO file to /var/lib/vz/template/iso/${IMAGE}"
  fi
  else
    if [ "$IMAGETYPE" == "img" ]; then
      info "Retrieving the Disk Image: $URL"
      curl -f#SL -o "$(basename "$URL")" "$URL"
      bzip2 -dcv $IMAGE
      info "Downloaded and decompressed IMG: ${CL}${BL}${IMAGE}${CL}"
    else
      info "inknow image type: ${IMAGETYPE}, exiting"
      exit 1 
    fi
  fi
fi

info "${BOLD}$Creating TAPPaaS NixOS VM from proxmox vm template using the following settings:"
info "     - VM ID: ${BGN}${VMID}"
info "     - VM Name: ${BGN}${VMNAME}"
info "     - Cloned from template: ${BGN}${TEMPLATEVMID}"
info "     - Disk Size: ${BGN}${DISK_SIZE}"
info "     - Disk/Storage Location: ${BGN}${STORAGE}"
info "     - CPU Cores: ${BGN}${CORE_COUNT}"
info "     - RAM Size: ${BGN}${RAM_SIZE}"
info "     - Bridge: ${BGN}${BRIDGE}"
info "     - MAC Address: ${BGN}${MAC}"
info "     - Bridge: ${BGN}${BRG}"
info "     - VLAN Tag: ${BGN}${VLANTAG}"
info "     - Description: ${BGN}${DESCRIPTION}" 
info "     - VM Tags: ${BGN}${VMTAG}"

create_vm_descriptions_html "$DESCRIPTION"

info "\n${BOLD}Starting the $VMNAME VM creation process...\n"

if [ "$IMAGETYPE" == "img" ]; then
  info "Creating a Image based VM"
  qm create $VMID -agent 1 -tablet 0 -localtime 1 -bios ovmf -cores $CORE_COUNT -memory $RAM_SIZE \
    -name $HN -tags tappaas,foundation -net0 virtio,bridge=lan -net1 virtio,bridge=wan -onboot 1 -bios seabios -ostype other -scsihw virtio-scsi-single
  qm importdisk $VMID ${IMAGE} $STORAGE  # 1>&/dev/null
  qm set $VMID \
    -scsi0 ${DISK_REF} \
    -boot order=scsi0  # >/dev/null
  qm resize $VMID scsi0 10G # >/dev/null
fi

it [ "$IMAGETYPE" == "iso" ]; then
  info "Creating an ISO based VM"
  qm create $VMID --agent 1 --tablet 0 --localtime 1 --bios ovmf --cores $CORE_COUNT --memory $RAM_SIZE \
    --name $VMNAME --net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU --onboot 1 --ostype l26 --scsihw virtio-scsi-pci >/dev/null
  info " - Created base VM configuration"
  pvesm alloc $STORAGE $VMID $DISK0 4M  1>&/dev/null
  pvesm alloc $STORAGE $VMID $DISK1 $DISK_SIZE  1>&/dev/null
  info " - Created EFI disk"
# qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} # 1>&/dev/null
# msg_ok " - Imported NixOS disk image"
  qm set $VMID \
    -ide3 local:iso/${FILE},media=cdrom\
    -efidisk0 ${DISK0_REF}${FORMAT} \
    -scsi0 ${DISK1_REF},discard=on,ssd=1,size=${DISK_SIZE} \
    -ide2 ${STORAGE}:cloudinit \
    -boot order='ide3;scsi0' >/dev/null
  msg_ok "Created the TAPPaaS NixOS VM"
fi
msg_ok "Creating the TAPPaaS NixOS VM: $VMID, name: $VMNAME"

# qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null


  DISK0="vm-${VMID}-disk-0"
  DISK0_REF=${STORAGE}:${DISK0}
  DISK1="vm-${VMID}-disk-1"
  DISK1_REF=${STORAGE}:${DISK1}

if [ "$IMAGETYPE" == "clone" ]; then
  info "Creating a Clone based VM"
  qm clone $TEMPLATEVMID $VMID --name $VMNAME --full 1 >/dev/null
fi

qm set $VMID --description "$DESCRIPTION_HTML" >/dev/null
qm set $VMID --serial0 socket >/dev/null
qm set $VMID --tags $VMTAG >/dev/null
qm set $VMID --agent enabled=1 >/dev/null
qm set $VMID --ciuser tappaas >/dev/null
qm set $VMID --ipconfig0 ip=dhcp >/dev/null
qm set $VMID --cores $CORE_COUNT --memory $RAM_SIZE >/dev/null
if [ -n "$VLANTAG" ] && [ "$VLANTAG" != "0" ]; then
  qm set $VMID --net0 virtio,bridge=$BRIDGE,tag=$VLANTAG,macaddr=$MAC >/dev/null
else
  qm set $VMID --net0 virtio,bridge=$BRIDGE,macaddr=$MAC >/dev/null
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
info "\n${BOLD}TAPPaaS NixOS VM creation completed successfully" 
# echo -e "if disksize changed then log in and resize disk!${CL}\n"
# echo -e "${TAB}${BOLD}parted /dev/vda (fix followed by resizepart 3 100% then quit), followed resize2f /dev/vda3 ${CL}"







qm start $VMID >/dev/null
msg_ok "Started the TAPPaaS VM" 

