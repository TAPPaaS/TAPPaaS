#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
# This file is part of the TAPPaaS project.
# TAPPaaS is free software: you can redistribute it and/or modify
# it under the terms of the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0) license.
# Author: larsrossen
#
# This script is heavely based on the Proxmox Helper Script: Proxmost PVE post Install
#
# TODO: Display final HW config, 
# TODO: Throw warning is no mirror on zpools and boot. Configure power management

#
# Validate that the ports are availabel and PCI passthrug is possible

function header_info {
  clear
  cat <<"EOF"

  Validating before installing
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

PVE_NODE=192.168.2.250



msg_info "Checking for IOMMU (interrupt remapping)" 
if ssh root@$PVE_NODE 'dmesg' | grep -q -e "DMAR-IR: Enabled IRQ remapping in x2apic mode" -e "AMD-Vi: Interrupt remapping enabled" ; then
  msg_ok "IOMMU is enabled"
else
  msg_error "IOMMU is not enabled. Please enable IOMMU in your BIOS settings."
  exit 1
fi

#
# ensure vfio modules loaded
msg_info  "Loading vfio modules into kernel"
if ! ssh root@$PVE_NODE 'lsmod' | grep -q vfio; then
  ssh root@$PVE_NODE 'modprobe vfio; modprobe vfio_iommu_type1; modprobe vfio_pci'
  ssh root@$PVE_NODE 'cat <<EOF >>/etc/modules
# Load vfio modules on boot
vfio
vfio_iommu_type1
vfio_pci
EOF
'
  ssh root@$PVE_NODE 'update-initramfs -u -k all'
  msg_ok "vfio modules loaded"
else
  msg_ok "vfio modules already loaded"
fi