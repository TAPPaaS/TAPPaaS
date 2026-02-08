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
if [ -z "$1" ]; then
  echo -e "\n${RD}[ERROR]${CL} Missing required argument VMNAME."
  echo -e "Usage: bash TAPPaaS-NixOS-Cloning.sh <VMNAME>\n"
  echo -e "A JSON configuration file is expected to be located at: /root/tappaas/<VMNAME>.json"
  exit 1
fi
JSON_CONFIG="/root/tappaas/$1.json"
if [ ! -f "$JSON_CONFIG" ]; then
  echo -e "\n${RD}[ERROR]${CL} JSON configuration file not found: ${YW}$JSON_CONFIG${CL}"
  exit 1
fi
JSON=$(cat "$JSON_CONFIG")
ZONES=$(cat /root/tappaas/zones.json)

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

function get_vlan_value() {
  local key="$1"
  if ! echo "$ZONES" | jq -e --arg K "$key" 'has($K)' >/dev/null ; then
  # VLAN lacks the key
    echo -e "\n${RD}[ERROR]${CL} Missing required zone '${YW}$key${CL}' in \"zones.json\" configuration." >&2
    exit 1
  fi
  state=$(echo $ZONES | jq -r --arg KEY "$key" '.[$KEY].state')
  value=$(echo $ZONES | jq -r --arg KEY "$key" '.[$KEY].vlantag')
  if [ "$state" == "Inactive" ]; then
    echo -e "\n${RD}[ERROR]${CL} Zone '${YW}$key${CL}' in \"zones.json\" is not active. Current state: '${YW}$state${CL}'." >&2
    exit 1
  fi
  info "     - $key has vlan value: ${BGN}${value}" >&2 #TODO, this is a hack using std error for info logging
  echo -n "${value}"
  return 0
}

function resolve_trunks() {
  # Converts a semicolon-separated list of zone names to their VLAN tags
  # e.g. "srv;private;iot;dmz" -> "210;310;410;610"
  # Fails if a zone is not defined in zones.json, but only warns and skips if inactive.
  local zone_list="$1"
  local result=""
  IFS=';' read -ra zone_names <<< "$zone_list"
  for zone_name in "${zone_names[@]}"; do
    if ! echo "$ZONES" | jq -e --arg K "$zone_name" 'has($K)' >/dev/null ; then
      echo -e "\n${RD}[ERROR]${CL} Trunk zone '${YW}$zone_name${CL}' is not defined in \"zones.json\"." >&2
      exit 1
    fi
    local state
    state=$(echo $ZONES | jq -r --arg KEY "$zone_name" '.[$KEY].state')
    if [ "$state" == "Inactive" ]; then
      echo -e "${YW}[WARN]${CL} Trunk zone '${YW}$zone_name${CL}' is inactive (state: '${YW}$state${CL}'), skipping." >&2
      continue
    fi
    local tag
    tag=$(echo $ZONES | jq -r --arg KEY "$zone_name" '.[$KEY].vlantag')
    info "     - trunk $zone_name has vlan value: ${BGN}${tag}" >&2
    if [ -n "$result" ]; then
      result="${result};${tag}"
    else
      result="${tag}"
    fi
  done
  echo -n "${result}"
}

# generate some MAC addresses
info "${BOLD}Creating TAPPaaS VM in proxmox using the following settings:"
NODE="$(get_config_value 'node' 'tappaas1')"
VMID="$(get_config_value 'vmid')"

# Check if VMID already exists - exit without destroying the existing VM
if qm status $VMID &>/dev/null; then
  echo -e "\n${RD}[ERROR]${CL} VM with VMID ${YW}$VMID${CL} already exists on this node."
  echo -e "Please choose a different VMID or manually remove the existing VM if intended.\n"
  trap - ERR  # Disable error handler to prevent cleanup of existing VM
  exit 1
fi

VMNAME="$(get_config_value 'vmname' "$1")"
VMTAG="$(get_config_value 'vmtag')"
BIOS="$(get_config_value 'bios' 'ovmf')"
CORE_COUNT="$(get_config_value 'cores' '2')"
VM_OSTYPE="$(get_config_value 'ostype' 'l26')"
CPU_TYPE="$(get_config_value 'cputype' 'host')"
RAM_SIZE="$(get_config_value 'memory' '4096')"
DISK_SIZE="$(get_config_value 'diskSize' '8G')"
STORAGE="$(get_config_value 'storage' 'tanka1')"
IMAGETYPE="$(get_config_value 'imageType')"
IMAGE="$(get_config_value 'image' '8080')"
if [ "${IMAGETYPE:-}" != "clone" ]; then
  IMAGELOCATION="$(get_config_value 'imageLocation')"
fi
BRIDGE0="$(get_config_value 'bridge0' 'lan')"
GEN_MAC0=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
MAC0="$(get_config_value 'mac0' "$GEN_MAC0")"
ZONE0="$(get_config_value 'zone0' 'mgmt')"
VLANTAG0=$(get_vlan_value "$ZONE0")
TRUNKS0="$(get_config_value 'trunks0' 'NONE')"
if [[ "$TRUNKS0" != "NONE" ]]; then
  TRUNKS0=$(resolve_trunks "$TRUNKS0")
fi
BRIDGE1="$(get_config_value 'bridge1' 'NONE')"
if [[ "$BRIDGE1" != "NONE" ]]; then
  GEN_MAC1=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
  MAC1="$(get_config_value 'mac1' "$GEN_MAC1")"
  ZONE1="$(get_config_value 'zone1' 'mgmt')"
  VLANTAG1=$(get_vlan_value "$ZONE1")
  TRUNKS1="$(get_config_value 'trunks1' 'NONE')"
  if [[ "$TRUNKS1" != "NONE" ]]; then
    TRUNKS1=$(resolve_trunks "$TRUNKS1")
  fi
else
  info "     - No second bridge configured"
fi
CLOUDINIT="$(get_config_value 'cloudInit' 'true')"
DESCRIPTION="$(get_config_value 'description')"

# not needed if clone, but no harm either
DISK0="vm-${VMID}-disk-0"
DISK0_REF=${STORAGE}:${DISK0}
DISK1="vm-${VMID}-disk-1"
DISK1_REF=${STORAGE}:${DISK1}

create_vm_descriptions_html "$DESCRIPTION"

if [ "${IMAGETYPE:-}" != "clone" ]; then
  URL="${IMAGELOCATION%/}/${IMAGE#/}"
  if [ "$IMAGETYPE" = "iso" ]; then
    info "Downloading ISO file: $URL"
    mkdir -p /var/lib/vz/template/iso
    curl -fSLo "/var/lib/vz/template/iso/$IMAGE" "$URL"
    info "Downloaded ISO file to /var/lib/vz/template/iso/${IMAGE}"
  elif [ "$IMAGETYPE" = "img" ]; then
    info "Retrieving the Disk Image: $URL"
    curl -fSLo "$IMAGE" "$URL"
    if [[ "$IMAGE" == *.bz2 ]]; then
      TARGET_IMAGE="${IMAGE%.bz2}"
      info "Decompressing $TARGET_IMAGE after download, have patience"
      bzip2 -dc "$IMAGE" > "$TARGET_IMAGE"
    else
      TARGET_IMAGE="$IMAGE"
    fi  
    info "Downloaded and prepared IMG: ${CL}${BL}${TARGET_IMAGE}${CL}"
  else
    info "unknown image type: ${IMAGETYPE}, exiting"
    exit 1
  fi
fi

info "\n${BOLD}Starting the $VMNAME VM creation process..."
if [ "$IMAGETYPE" == "img" ]; then  # First use: this is used to stand up a firewall vm from a disk image
  info "${BOLD}Creating a Image based VM"
  qm create $VMID -agent 1 -tablet 0 -localtime 1 \
    -name $VMNAME  -onboot 1 -bios $BIOS -ostype $VM_OSTYPE -cpu "$CPU_TYPE" -scsihw virtio-scsi-single 1>/dev/null
  qm importdisk $VMID ${TARGET_IMAGE} $STORAGE  1>/dev/null
  qm set $VMID \
    -scsi0 ${DISK0_REF} \
    -boot order=scsi0   >/dev/null
  qm resize $VMID scsi0 $DISK_SIZE  >/dev/null
fi

if [ "$IMAGETYPE" == "iso" ]; then # First use: this is used to stand up a nixos template vm from an iso image
  info "${BOLD}Creating an ISO based VM"
  qm create $VMID --agent 1 --tablet 0 --localtime 1 --bios $BIOS \
    --name $VMNAME --onboot 1 --ostype $VM_OSTYPE --cpu "$CPU_TYPE" --scsihw virtio-scsi-pci >/dev/null
  info " - Created base VM configuration"
  pvesm alloc $STORAGE $VMID $DISK0 4M  1>/dev/null
  pvesm alloc $STORAGE $VMID $DISK1 $DISK_SIZE  1>/dev/null
  info " - Created EFI disk"
  qm set $VMID \
    -ide3 local:iso/${IMAGE},media=cdrom\
    -efidisk0 ${DISK0_REF} \
    -scsi0 ${DISK1_REF},discard=on,ssd=1,size=${DISK_SIZE} \
    -boot order='ide3;scsi0' >/dev/null
fi
# qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null

if [ "$IMAGETYPE" == "clone" ]; then
  info "${BOLD}Creating a Clone based VM"

  # Find the cluster node that has the template
  TEMPLATE_NODE=""
  CURRENT_NODE=$(hostname)
  
  while read -r node; do
    if ssh -o StrictHostKeyChecking=no root@"${node}.mgmt.internal" "qm status $IMAGE &>/dev/null"; then
      TEMPLATE_NODE="$node"
      break
    fi
  done < <(pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node")
  
  if [ -z "$TEMPLATE_NODE" ]; then
    error "Template $IMAGE not found on any cluster node"
    exit 1
  fi

  # Check if we're running on the node that has the template
  if [ "$CURRENT_NODE" == "$TEMPLATE_NODE" ]; then
    # Local clone - template is on this node
    qm clone "$IMAGE" "$VMID" --name "$VMNAME" --full 1 >/dev/null
  else
    # Remote clone - need to clone on template node then migrate to current node
    info "Template is on ${TEMPLATE_NODE}, current node is ${CURRENT_NODE}"
    info "Cloning on ${TEMPLATE_NODE} and migrating to ${CURRENT_NODE}..."

    # Clone on the template node via SSH
    ssh -o StrictHostKeyChecking=no root@${TEMPLATE_NODE} "qm clone $IMAGE $VMID --name $VMNAME --full 1" >/dev/null
    info " - Cloned VM ${VMID} on ${TEMPLATE_NODE}"

    # Migrate the VM to the current node (online=0 means offline migration)
    info " - Migrating VM ${VMID} from ${TEMPLATE_NODE} to ${CURRENT_NODE}..."
    ssh -o StrictHostKeyChecking=no root@${TEMPLATE_NODE} "qm migrate $VMID $CURRENT_NODE --online 0" >/dev/null
    info " - Migration complete"
  fi

  # Set CPU type after cloning (clone inherits from template)
  qm set $VMID --cpu "$CPU_TYPE" >/dev/null
fi

info "${BOLD}Configuring the $VMNAME VM settings..."

qm set $VMID --description "$DESCRIPTION_HTML" >/dev/null
qm set $VMID --serial0 socket >/dev/null
qm set $VMID --tags $VMTAG >/dev/null
qm set $VMID --agent enabled=1 >/dev/null
qm set $VMID --cores $CORE_COUNT --memory $RAM_SIZE >/dev/null
NET0_OPTS="virtio,bridge=${BRIDGE0},macaddr=${MAC0}"
if [ "$VLANTAG0" != "0" ]; then
  NET0_OPTS="${NET0_OPTS},tag=${VLANTAG0}"
fi
if [ "$TRUNKS0" != "NONE" ]; then
  NET0_OPTS="${NET0_OPTS},trunks=${TRUNKS0}"
fi
qm set $VMID --net0 "${NET0_OPTS}" >/dev/null
if [[ "$BRIDGE1" == "NONE" ]]; then
  info "No second bridge configured"
else
  NET1_OPTS="virtio,bridge=${BRIDGE1},macaddr=${MAC1}"
  if [ "$VLANTAG1" != "0" ]; then
    NET1_OPTS="${NET1_OPTS},tag=${VLANTAG1}"
  fi
  if [ "$TRUNKS1" != "NONE" ]; then
    NET1_OPTS="${NET1_OPTS},trunks=${TRUNKS1}"
  fi
  qm set $VMID --net1 "${NET1_OPTS}" >/dev/null
  info "Configured second bridge on $BRIDGE1"
fi
if [[ "$CLOUDINIT" == "true" ]]; then
  info "Configuring Cloud-init for VM $VMNAME"
  if [[ "$IMAGETYPE" != "clone" ]]; then
    qm set $VMID -scsi1 ${STORAGE}:cloudinit >/dev/null
  fi
  qm set $VMID --ciuser tappaas >/dev/null
  qm set $VMID --ipconfig0 ip=dhcp >/dev/null
  if [[ "$VMNAME" == "tappaas-cicd" ]]; then
    qm set $VMID --sshkey ~/.ssh/id_rsa.pub >/dev/null
  elif [[ -f ~/tappaas/tappaas-cicd.pub ]]; then
    qm set $VMID --sshkey ~/tappaas/tappaas-cicd.pub >/dev/null
  fi
  info " - Hostname set to $VMNAME via cloud-init"
  qm cloudinit update $VMID >/dev/null
else
  info "Cloud-init configuration skipped as per JSON configuration"
fi


# TODO fix disk resize
# qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null  

qm start $VMID >/dev/null
info "\n${BOLD}TAPPaaS $VMNAME VM creation completed successfully\n" 
# echo -e "if disksize changed then log in and resize disk!${CL}\n"
# echo -e "${TAB}${BOLD}parted /dev/vda (fix followed by resizepart 3 100% then quit), followed resize2f /dev/vda3 ${CL}"

