
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

#
# ok here we go
#

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

. /home/tappaas/bin/common-install-routines.sh


info "${BOLD}Creating TAPPaaS Proxmox Backup Server (PBS) installation using the following settings:"
NODE="$(get_config_value 'node' 'tappaas1')"
VMNAME="$(get_config_value 'vmname' "$1")"
STORAGE="$(get_config_value 'storage' 'tankc1')"
IMAGE_TYPE="$(get_config_value 'imageType' 'apt')"
IMAGE="$(get_config_value 'image' 'pbs')"
IMAGE_LOCATION="$(get_config_value 'imageLocation' 'http://download.proxmox.com/debian/pbs')"
DESCRIPTION="$(get_config_value 'description' 'TAPPaaS APT installation')"

# update the apt sources and install pbs

info "${BOLD}$Test if apt $IMAGE_LOCATION repositories are registered ..."
if [[ ssh root@${NODE}.tappaas.internal "cat  /etc/apt/sources.list.d/proxmox.sources" | grep "$IMAGE_LOCATION" >/dev/null 2>&1 ]]
then
  echo "Proxmox PBS apt repository already registered."
else
  echo "Proxmox PBS apt repository not found, adding it ..."
  ssh root@${NODE}.tappaas.internal "cat >> /etc/apt/sources.list.d/proxmox.sources" << EOF
Types: deb
URIs: ${IMAGE_LOCATION}
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi

info "${BOLD}$Installing ${DESCIPTION} on node ${BGN}${NODE}${CL} ..."
ssh root@${NODE}.tappaas.internal bash -c "'
  set -e
  apt update
  apt install -y proxmox-backup-server
'"  
# copy the config file to the tappass pbs service to keep a record of what has been installed
scp $JSON_CONFIG root@${NODE}.tappaas.internal:/root/tappaas/$JSON_CONFIG

info "\n${GN}TAPPaaS PBS installation completed successfully.${CL}"
