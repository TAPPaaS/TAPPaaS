
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

if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi      

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

info "${BOLD}$Creating TAPPaaS NixOS VM from proxmox vm template using the following settings:"
NODE="$(get_config_value 'node' 'tappaas1')"
VMNAME="$(get_config_value 'vmname' "$1")"
STORAGE="$(get_config_value 'storage' 'tankc1')"
IMAGE_TYPE="$(get_config_value 'imageType' 'apt')"
IMAGE="$(get_config_value 'image' 'pbs')"
IMAGE_LOCATION="$(get_config_value 'imageLocation' 'http://download.proxmox.com/debian/pbs')"
DESCRIPTION="$(get_config_value 'description' 'TAPPaaS APT installation')"

# update the apt sources and install pbs

info "${BOLD}$Test if apt $IMAGE_LOCATION repositories are registered ..."
if [[ ssh root@${NODE}.lan.internal "cat  /etc/apt/sources.list.d/proxmox.sources" | grep "$IMAGE_LOCATION" >/dev/null 2>&1 ]]
then
  echo "Proxmox PBS apt repository already registered."
else
  echo "Proxmox PBS apt repository not found, adding it ..."
  ssh root@${NODE}.lan.internal "cat >> /etc/apt/sources.list.d/proxmox.sources" << EOF
Types: deb
URIs: ${IMAGE_LOCATION}
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi

info "${BOLD}$Installing ${DESCIPTION} on node ${BGN}${NODE}${CL} ..."
ssh root@${NODE}.lan.internal bash -c "'
  set -e
  apt update
  apt install -y proxmox-backup-server
'"  
# copy the config file to the tappass pbs service to keep a record of what has been installed
scp $JSON_CONFIG root@${NODE}.lan.internal:/root/tappaas/$JSON_CONFIG

info "\n${GN}TAPPaaS PBS installation completed successfully.${CL}"
