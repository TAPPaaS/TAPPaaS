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

  <h2 style='font-size: 24px; margin: 20px 0;'>$TEXT</h2>

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
  A TAPPaaS configured VM
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

function get_config_value() {
  local key="$1"
  local default="$2"
  # If JSON lacks the key and default is empty -> enter then-branch
  if ! echo "$JSON" | jq -e --arg K "$key" 'has($K)' >/dev/null && [ -z "$default" ]; then
    echo -e "\n${RD}[ERROR]${CL} Missing required key '${YW}$key${CL}' in JSON configuration." >&2
    exit 1
  else
    if ! jq -e --arg K "$key" 'has($K)' <<<"$JSON" >/dev/null; then
      echo -n "$default"
      return  0
    fi
  fi
  echo -n $(echo $JSON | jq -r --arg KEY "$key" '.[$KEY]')
}

# generate some MAC addresses
GEN_MAC0=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC1=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
DISK_SIZE="8G"
TEMPLATEVMID="8080"
VMID=$(echo $JSON | jq -r '.vmid')
VMNAME=$(echo $JSON | jq -r '.hostname')
CORE_COUNT=$(echo $JSON | jq -r '.cores')
RAM_SIZE=$(echo $JSON | jq -r '.memory')
DISK_SIZE=$(echo $JSON | jq -r '.diskSize')
VLANTAG=$(echo $JSON | jq -r '.vlantag')
DESCRIPTION=$(echo $JSON | jq -r '.description')
BRIDGE0=$(echo $JSON | jq -r '.bridge0')
MAC0="$(get_config_value 'mac0' $GEN_MAC0)"
BRIDGE1="$(get_config_value 'bridge2' 'NONE')"
MAC1="$(get_config_value 'mac1' $GEN_MAC1)"
BIOS="$(get_config_value 'bios' "ovmf")"
VM_OSTYPE="$(get_config_value 'ostype' 'l26')"
STORAGE=$(echo $JSON | jq -r '.storage')
VMTAG=$(echo $JSON | jq -r '.vmtag')
IMAGETYPE=$(echo $JSON | jq -r '.imageType')
IMAGE=$(echo $JSON | jq -r '.image')

if [ "${IMAGETYPE:-}" != "clone" ]; then
  IMAGELOCATION=$(jq -r '.imageLocation' <<<"$JSON")
  # ensure exactly one slash between location and image name
  URL="${IMAGELOCATION%/}/${IMAGE#/}"
  if [ "$IMAGETYPE" = "iso" ]; then
    info "Downloading ISO file: $URL"
    mkdir -p /var/lib/vz/template/iso
    curl -fSLo "/var/lib/vz/template/iso/$IMAGE" "$URL"
    info "Downloaded ISO file to /var/lib/vz/template/iso/${IMAGE}"
  elif [ "$IMAGETYPE" = "img" ]; then
    info "Retrieving the Disk Image: $URL"
    OUTFILE="$(basename "$URL")"
    curl -fSLo "$OUTFILE" "$URL"
    # if the downloaded file is bzip2 compressed, decompress to target name
    if file --mime-type -b "$OUTFILE" | grep -qi 'x-bzip2'; then
      bzip2 -dc "$OUTFILE" > "$IMAGE"
    else
      mv -- "$OUTFILE" "$IMAGE"
    fi
    info "Downloaded and prepared IMG: ${CL}${BL}${IMAGE}${CL}"
  else
    info "unknown image type: ${IMAGETYPE}, exiting"
    exit 1
  fi
fi

# not needed if clone, but no harm either
DISK0="vm-${VMID}-disk-0"
DISK0_REF=${STORAGE}:${DISK0}
DISK1="vm-${VMID}-disk-1"
DISK1_REF=${STORAGE}:${DISK1}

info "${BOLD}$Creating TAPPaaS NixOS VM from proxmox vm template using the following settings:"
info "     - VM ID: ${BGN}${VMID}"
info "     - VM Name: ${BGN}${VMNAME}"
info "     - Cloned from template: ${BGN}${TEMPLATEVMID}"
info "     - Disk Size: ${BGN}${DISK_SIZE}"
info "     - Disk/Storage Location: ${BGN}${STORAGE}"
info "     - CPU Cores: ${BGN}${CORE_COUNT}"
info "     - RAM Size: ${BGN}${RAM_SIZE}"
info "     - Bridge 0: ${BGN}${BRIDGE0}"
info "     - Bridge 1: ${BGN}${BRIDGE1}"
info "     - MAC0 Address: ${BGN}${MAC0}"
info "     - MAC1 Address: ${BGN}${MAC1}"
info "     - VLAN Tag: ${BGN}${VLANTAG}"
info "     - Description: ${BGN}${DESCRIPTION}" 
info "     - VM Tags: ${BGN}${VMTAG}"
info "     - Image Type: ${BGN}${IMAGETYPE}"
info "     - Image: ${BGN}${IMAGE}" 
info "     - BIOS Type: ${BGN}${BIOS}"
info "     - OS Type: ${BGN}${VM_OSTYPE}"

create_vm_descriptions_html "$DESCRIPTION"

info "\n${BOLD}Starting the $VMNAME VM creation process..."

if [ "$IMAGETYPE" == "img" ]; then  # First use: this is used to stand up a firewall vm from a disk image
  info "${BOLD}Creating a Image based VM"
  qm create $VMID -agent 1 -tablet 0 -localtime 1 \
    -name $VMNAME  -onboot 1 -bios $BIOS -ostype $VM_OSTYPE -scsihw virtio-scsi-single
  qm importdisk $VMID ${IMAGE} $STORAGE  # 1>&/dev/null
  qm set $VMID \
    -scsi0 ${DISK_REF} \
    -boot order=scsi0  # >/dev/null
  qm resize $VMID scsi0 $DISKSIZE # >/dev/null
fi

if [ "$IMAGETYPE" == "iso" ]; then # First use: this is used to stand up a nixos template vm from an iso image
  info "${BOLD}Creating an ISO based VM"
  qm create $VMID --agent 1 --tablet 0 --localtime 1 --bios $BIOS \
    --name $VMNAME --onboot 1 --ostype $VM_OSTYPE --scsihw virtio-scsi-pci >/dev/null
  info " - Created base VM configuration"
  pvesm alloc $STORAGE $VMID $DISK0 4M  1>&/dev/null
  pvesm alloc $STORAGE $VMID $DISK1 $DISK_SIZE  1>&/dev/null
  info " - Created EFI disk"
# qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} # 1>&/dev/null
  qm set $VMID \
    -ide3 local:iso/${FILE},media=cdrom\
    -efidisk0 ${DISK0_REF}${FORMAT} \
    -scsi0 ${DISK1_REF},discard=on,ssd=1,size=${DISK_SIZE} \
    -ide2 ${STORAGE}:cloudinit \
    -boot order='ide3;scsi0' >/dev/null
fi

# qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null

if [ "$IMAGETYPE" == "clone" ]; then
  info "${BOLD}Creating a Clone based VM"
  qm clone $TEMPLATEVMID $VMID --name $VMNAME --full 1 >/dev/null
fi

info "\n${BOLD}Configuring the $VMNAME VM settings...\n"

qm set $VMID --description "$DESCRIPTION_HTML" >/dev/null
qm set $VMID --serial0 socket >/dev/null
qm set $VMID --tags $VMTAG >/dev/null
qm set $VMID --agent enabled=1 >/dev/null
qm set $VMID --ciuser tappaas >/dev/null
qm set $VMID --ipconfig0 ip=dhcp >/dev/null
qm set $VMID --cores $CORE_COUNT --memory $RAM_SIZE >/dev/null
if [ -n "$VLANTAG" ] && [ "$VLANTAG" != "0" ]; then
  qm set $VMID --net0 "virtio,bridge=${BRIDGE0},tag=$VLANTAG,macaddr=${MAC0}" >/dev/null
else
  qm set $VMID --net0 "virtio,bridge=${BRIDGE0},macaddr=${MAC0}" >/dev/null
fi
if [[ "$VMNAME" == "tappaas-cicd" ]]; then
  qm set $VMID --sshkey ~/.ssh/id_rsa.pub >/dev/null
else
  qm set $VMID --sshkey ~/tappaas/tappaas-cicd.pub >/dev/null
fi
if [[ "$BRIDGE1" == "NONE" ]]; then
  info "No second bridge configured"
else
  qm set $VMID --net1 "virtio,bridge=$BRIDGE1,macaddr=$MAC1" >/dev/null
  info "Configured second bridge on $BRIDGE1"
fi


qm cloudinit update $VMID >/dev/null
# TODO fix disk resize
# qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null  

qm start $VMID >/dev/null
info "\n${BOLD}TAPPaaS VM creation completed successfully" 
# echo -e "if disksize changed then log in and resize disk!${CL}\n"
# echo -e "${TAB}${BOLD}parted /dev/vda (fix followed by resizepart 3 100% then quit), followed resize2f /dev/vda3 ${CL}"
info "Started the TAPPaaS VM" 

