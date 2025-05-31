#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
# This file is part of the TAPPaaS project.
# TAPPaaS is free software: you can redistribute it and/or modify
# it under the terms of the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0) license.
# Author: larsrossen
#
# This script is heavely based on the Proxmox Helper Script: Docker VM
#

function header_info() {
  clear
  cat <<"EOF"
  _______       _____             _____    _____ _____ _____ _____    ____              _       _                   
 |__   __|/\   |  __ \           / ____|  / ____|_   _/ ____|  __ \  |  _ \            | |     | |                  
    | |  /  \  | |__) |_ _  __ _| (___   | |      | || |    | |  | | | |_) | ___   ___ | |_ ___| |_ _ __ __ _ _ __  
    | | / /\ \ |  ___/ _` |/ _` |\___ \  | |      | || |    | |  | | |  _ < / _ \ / _ \| __/ __| __| '__/ _` | '_ \ 
    | |/ ____ \| |  | (_| | (_| |____) | | |____ _| || |____| |__| | | |_) | (_) | (_) | |_\__ \ |_| | | (_| | |_) |
    |_/_/    \_\_|   \__,_|\__,_|_____/   \_____|_____\_____|_____/  |____/ \___/ \___/ \__|___/\__|_|  \__,_| .__/ 
                                                                                                             | |    
                                                                                                             |_|    
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

# install ansible
msg_info "Installing Ansible"
sudo apt install ansible -y >/dev/null
msg_ok "Done Installing Ansible"

# installing opentpfu
msg_info "Installing OpenTofu"
sudo curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh >/dev/null
sudo chmod +x install-opentofu.sh
sudo ./install-opentofu.sh --install-method deb >/dev/null
sudo rm -f install-opentofu.sh
msg_ok "Done Installing OpenTofu"

msg_ok "**** Congratulation TAPPaaS is not bootstrapped ****"
msg_ok "  next step is to get firewall installed and configured"
msg_ok "  and then install all the right TAPPaaS modules"
msg_ok "Please run: sudo TAPPaaS/src/modules/install.sh opensense"


