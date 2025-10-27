#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#

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
  This is a TAPPaaS NixOS VM.
</div>
EOF
  )
}

function default_settings() {
  GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
  DISK_SIZE="8G"
  FORMAT=",efitype=4m"
  DISK_SIZE="8G"
  CORE_COUNT="2"
  RAM_SIZE="4096"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  STORAGE="tanka1"
#  NIXURL=https://channels.nixos.org/nixos-25.05/latest-nixos-minimal-x86_64-linux.iso
  # TODO: clean up this code
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
VMID=$1
VMNAME=$2
FILE=$3
default_settings
create_vm_descriptions_html
check_root

msg_info "Using NixOS ISO file: $FILE"
msg_info "Creating the TAPPaaS NixOS VM: $VMID, name: $VMNAME"
qm create $VMID --agent 1 --tablet 0 --localtime 1 --bios ovmf --cores $CORE_COUNT --memory $RAM_SIZE \
  --name $VMNAME --net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU --onboot 1 --ostype l26 --scsihw virtio-scsi-pci
msg_info " - Created base VM configuration"
pvesm alloc $STORAGE $TEMPLATEVMID $DISK0 4M # 1>&/dev/null
msg_info " - Created EFI disk"
qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} # 1>&/dev/null
msg_info " - Imported NixOS disk image"
qm set $VMID \
  -efidisk0 ${DISK0_REF}${FORMAT} \
  -scsi0 ${DISK1_REF},discard=on,ssd=1,size=${DISK_SIZE} \
  -ide2 ${STORAGE}:cloudinit \
  -boot order=scsi0 \
  -serial0 socket # >/dev/null
msg_info " - Set VM disks and cloudinit"
qm resize $VMID scsi0 8G >/dev/null
qm set $VMID --tags TAPPaaS >/dev/null
qm set $VMID --description "$DESCRIPTION" >/dev/null
qm set $VMID --agent enabled=1 >/dev/null
qm set $VMID --ciuser tappaas >/dev/null
qm set $VMID --ipconfig0 ip=dhcp >/dev/null
qm set $VMID --sshkey ~/.ssh/id_rsa.pub >/dev/null
qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null
msg_ok "Step 3 Done: Created the TAPPaaS NixOS VM"

qm start $VMID >/dev/null
msg_ok "Step 4 Done: Started the TAPPaaS VM" 


