#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#

# This script create a NixOS VM on Proxmox for TAPPaaS usage.


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

function msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${msg}${CL}"
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}

function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear
    msg_error "Please run this script as root."
    echo -e "\nExiting..."
    sleep 2
    exit
  fi
}

function exit-script() {
  clear
  echo -e "\n${CROSS}${RD}User exited script${CL}\n"
  exit
}

function create_vm_descriptions_html() {
# TODO: update description to be descriptive!! and use variables for text
  DESCRIPTION=$(
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
  This is a TAPPaaS NixOS VM template.
</div>
EOF
  )
}

function default_settings() {
  GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
  FORMAT=",efitype=4m"
  DISK_SIZE="16G"
  CORE_COUNT="2"
  RAM_SIZE="4096"
  BRG="lan"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  STORAGE="tanka1"
  # FILE=latest-nixos-minimal-x86_64-linux.iso
  FILE=latest-nixos-graphical-x86_64-linux.iso
  NIXURL=https://channels.nixos.org/nixos-25.05/$FILE
  VMID=8080
  VMNAME=tappaas-nixos  
  DISK0="vm-${VMID}-disk-0"
  DISK0_REF=${STORAGE}:${DISK0}
  DISK1="vm-${VMID}-disk-1"
  DISK1_REF=${STORAGE}:${DISK1}
}

#
# ok here we go
#
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

init_print_variables
default_settings
create_vm_descriptions_html
check_root

msg_ok "downlaoding NixOS ISO file: $NIXURL"
curl -fsSL $NIXURL -o /var/lib/vz/template/iso/$FILE
msg_ok "Creating the TAPPaaS NixOS VM: $VMID, name: $VMNAME"
qm create $VMID --agent 1 --tablet 0 --localtime 1 --bios ovmf --cores $CORE_COUNT --memory $RAM_SIZE \
  --name $VMNAME --net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU --onboot 1 --ostype l26 --scsihw virtio-scsi-pci >/dev/null
msg_ok " - Created base VM configuration"
pvesm alloc $STORAGE $VMID $DISK0 4M  1>&/dev/null
pvesm alloc $STORAGE $VMID $DISK1 $DISK_SIZE  1>&/dev/null
msg_ok " - Created EFI disk"
# qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} # 1>&/dev/null
# msg_ok " - Imported NixOS disk image"
qm set $VMID \
  -ide3 local:iso/${FILE},media=cdrom\
  -efidisk0 ${DISK0_REF}${FORMAT} \
  -scsi0 ${DISK1_REF},discard=on,ssd=1,size=${DISK_SIZE} \
  -ide2 ${STORAGE}:cloudinit \
  -boot order='ide3;scsi0' >/dev/null
msg_ok " - Set VM disks and cloudinit"
qm set $VMID -serial0 socket >/dev/null
qm set $VMID --tags TAPPaaS >/dev/null
qm set $VMID --description "$DESCRIPTION" >/dev/null
qm set $VMID --agent enabled=1 >/dev/null
qm set $VMID --ciuser tappaas >/dev/null
qm set $VMID --ipconfig0 ip=dhcp >/dev/null
qm set $VMID --sshkey ~/.ssh/id_rsa.pub >/dev/null
# qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null
msg_ok "Created the TAPPaaS NixOS VM"

qm start $VMID >/dev/null
msg_ok "Started the TAPPaaS VM" 


