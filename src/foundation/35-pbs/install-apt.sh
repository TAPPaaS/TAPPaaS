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
}

function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}

function info() {
  local msg="$1"
  echo -e "${DGN}${msg}${CL}"
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
  echo -e "Usage: bash TAPPaaS-NixOS-Cloning.sh <VMNAME>\n"
  echo -e "A JSON configuration file is expected to be located at: /root/tappaas/<VMNAME>.json"
  exit 1
fi
JSON=$(cat $JSON_CONFIG)

function get_config_value() {
  local key="$1"
  local default="$2"
  if ! echo "$JSON" | jq -e --arg K "$key" 'has($K)' >/dev/null ; then
  # JSON lacks the key 
    if [ -z "$default" ]; then
      echo -e "\n${RD}[ERROR]${CL} Missing required key '${YW}$key${CL}' in JSON configuration." >&2
      exit 1
    else
      value="$default"
    fi
  else
    value=$(echo $JSON | jq -r --arg KEY "$key" '.[$KEY]')
  fi
  info "     - $key has value: ${BGN}${value}" >&2 #TODO, this is a hack using std error for info logging
  echo -n "${value}"
  return 0
}

# generate some MAC addresses
info "${BOLD}$Creating TAPPaaS NixOS VM from proxmox vm template using the following settings:"
NODE="$(get_config_value 'node' 'tappaas1')"
VMNAME="$(get_config_value 'vmname' "$1")"
STORAGE="$(get_config_value 'storage' 'tankc1')"
IMAGE_TYPE="$(get_config_value 'imageType' 'apt')"
IMAGE="$(get_config_value 'image' 'pbs')"
IMAGE_LOCATION="$(get_config_value 'imageLocation' 'https://enterprise.proxmox.com/iso/')"
DESCRIPTION="$(get_config_value 'description' 'TAPPaaS APT installation')"

# update the apt sources and install pbs
# TODO: not correct yet
info "${BOLD}$Installing ${DESCIPTION} on node ${BGN}${NODE}${CL} ..."
ssh root@${NODE} bash -c "'
  set -e
  apt update
  apt install -y wget gnupg
  wget -qO - ${IMAGE_LOCATION}/proxmox-backup-server.gpg | apt-key add -
  echo \"deb ${IMAGE_LOCATION} buster pbs-enterprise\" > /etc/apt/sources.list.d/proxmox-backup-server.list
  apt update
  apt install -y proxmox-backup-server
'"  
info "\n${GN}TAPPaaS PBS installation completed successfully.${CL}"S