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

# This script creates a VM on Proxmox for TAPPaaS usage.
# Supports NixOS, Debian/Ubuntu and Windows Server VMs.
#
# Usage: bash Create-TAPPaaS-VM.sh name-of-VM  (name of VM will be used to reference the json config file in ~/tappaas/)

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
  echo -e "${DGN}[Info]${CL} ${msg}"
}

function warn() {
  local msg="$1"
  echo -e "${YW}[Warning]${CL} ${msg}"
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
NODE="$(get_config_value 'node' "$(hostname)")"

# Check if the specified node exists in the cluster
CLUSTER_NODES=$(pvesh get /cluster/resources --type node --output-format json 2>/dev/null | jq -r '.[].node' 2>/dev/null || echo "")
if [ -n "$CLUSTER_NODES" ]; then
  if ! echo "$CLUSTER_NODES" | grep -qx "$NODE"; then
    FALLBACK_NODE=$(echo "$CLUSTER_NODES" | head -1)
    warn "Node '${NODE}' does not exist in the cluster. Available nodes: $(echo "$CLUSTER_NODES" | tr '\n' ' ')"
    warn "Falling back to first cluster node '${FALLBACK_NODE}'"
    NODE="$FALLBACK_NODE"
  fi
else
  # If we can't query cluster nodes (single node or API issue), just continue with specified node
  info "Could not query cluster nodes, proceeding with node '${NODE}'"
fi

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
  IMAGELOCATION="$(get_config_value 'imageLocation' '')"
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
  if [ "$IMAGETYPE" = "iso" ]; then
    if [ -f "/var/lib/vz/template/iso/$IMAGE" ]; then
      info "ISO already present locally: /var/lib/vz/template/iso/${IMAGE} — skipping download"
    elif [ -n "${IMAGELOCATION:-}" ]; then
      URL="${IMAGELOCATION%/}/${IMAGE#/}"
      info "Downloading ISO file: $URL"
      mkdir -p /var/lib/vz/template/iso
      curl -fSLo "/var/lib/vz/template/iso/$IMAGE" "$URL"
      info "Downloaded ISO file to /var/lib/vz/template/iso/${IMAGE}"
    else
      error "ISO '${IMAGE}' not found at /var/lib/vz/template/iso/ and no imageLocation set to download from"
      exit 1
    fi
  elif [ "$IMAGETYPE" = "img" ]; then
    URL="${IMAGELOCATION%/}/${IMAGE#/}"
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

echo ""
info "${BOLD}Starting the $VMNAME VM creation process..."
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

if [ "$IMAGETYPE" == "iso" ]; then # First use: this is used to stand up a template vm from an iso image
  info "${BOLD}Creating an ISO based VM"

  # Detect Windows OS types for special handling
  IS_WINDOWS=false
  case "$VM_OSTYPE" in
    win10|win11|win2k19|win2k22|win2k25) IS_WINDOWS=true ;;
  esac

  if [ "$IS_WINDOWS" == "true" ]; then
    # Windows VM: use q35 machine type, add TPM 2.0, mount VirtIO drivers ISO
    info " - Windows OS detected ($VM_OSTYPE) — using q35 machine type with TPM"

    # Remove any leftover VM or disk from a previous failed run.
    # Use --purge so all disks on all storage pools are cleaned up cleanly.
    if qm status $VMID >/dev/null 2>&1; then
      warn " - VMID ${VMID} already exists — destroying before recreating"
      qm stop $VMID --skiplock 2>/dev/null || true
      qm destroy $VMID --destroy-unreferenced-disks 1 --purge 1 2>/dev/null || true
    fi
    for _stale_disk in 0 1 2 3; do
      pvesm free "${STORAGE}:vm-${VMID}-disk-${_stale_disk}" 2>/dev/null || true
    done

    qm create $VMID --agent 1 --tablet 1 --localtime 1 --bios $BIOS \
      --machine q35 --vga std \
      --name $VMNAME --onboot 1 --ostype $VM_OSTYPE --cpu "$CPU_TYPE" --scsihw virtio-scsi-pci >/dev/null
    info " - Created base VM configuration (q35)"

    pvesm alloc $STORAGE $VMID $DISK0 4M  1>/dev/null
    pvesm alloc $STORAGE $VMID $DISK1 $DISK_SIZE  1>/dev/null
    # Proxmox 9/QEMU 10.x does not auto-populate the EFI NVRAM disk even when
    # pre-enrolled-keys=1 is set — the ZFS volume stays all-zeros, causing OVMF
    # to hang with no display.  Copy the MS vars template explicitly so OVMF gets
    # valid NVRAM with SecureBoot keys on first boot.
    dd if=/usr/share/pve-edk2-firmware/OVMF_VARS_4M.ms.fd \
       of=/dev/zvol/${STORAGE}/vm-${VMID}-disk-0 bs=1M 2>/dev/null || true
    info " - Created EFI disk (NVRAM initialised from OVMF_VARS_4M.ms.fd)"

    # Add TPM 2.0 (required for Windows Server 2025 / Windows 11)
    # TPM on local-zfs: vTPM state is cryptographically node-bound; keep on fast local storage.
    qm set $VMID --tpmstate0 local-zfs:1,version=v2.0 >/dev/null
    info " - Added TPM 2.0"

    qm set $VMID \
      -ide2 local:iso/${IMAGE},media=cdrom \
      -efidisk0 ${DISK0_REF},efitype=4m,ms-cert=2023k,pre-enrolled-keys=1 \
      -scsi0 ${DISK1_REF},discard=on,ssd=1,size=${DISK_SIZE} \
      -boot order='scsi0;ide2' >/dev/null

    # Mount VirtIO drivers ISO as secondary CD-ROM (if available)
    VIRTIO_ISO=$(ls /var/lib/vz/template/iso/virtio-win*.iso 2>/dev/null | sort -V | tail -1)
    if [ -n "$VIRTIO_ISO" ]; then
      VIRTIO_ISO_NAME=$(basename "$VIRTIO_ISO")
      qm set $VMID -ide3 local:iso/${VIRTIO_ISO_NAME},media=cdrom >/dev/null
      info " - Mounted VirtIO drivers ISO: ${VIRTIO_ISO_NAME}"
    else
      warn "VirtIO drivers ISO not found in /var/lib/vz/template/iso/ — Windows will need drivers during install"
      warn "Download from: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    fi

    # Attach unattended config ISO if provided — enables fully automated install.
    # Also includes startup.nsh so the OVMF EFI Shell auto-launches the Windows
    # bootloader: with a zeroed NVRAM the shell runs startup.nsh instead of the
    # "Please select boot device" menu.
    if [[ -f "/root/tappaas/autounattend.xml" ]]; then
      apt-get install -y -q genisoimage 2>/dev/null || true
      mkdir -p /tmp/tappaas-winconfig
      cp /root/tappaas/autounattend.xml /tmp/tappaas-winconfig/
      # startup.nsh: refresh device map, then scan FS0-FS9 for the Windows bootloader
      cat > /tmp/tappaas-winconfig/startup.nsh <<'STARTUP_NSH'
@echo -off
map -r
for %f run (0 9)
  if exist FS%f:\EFI\BOOT\BOOTX64.EFI then
    FS%f:\EFI\BOOT\BOOTX64.EFI
  endif
endfor
STARTUP_NSH
      genisoimage -quiet -J -o /var/lib/vz/template/iso/tappaas-winconfig.iso \
          /tmp/tappaas-winconfig/ 2>/dev/null
      rm -rf /tmp/tappaas-winconfig /root/tappaas/autounattend.xml
      qm set $VMID -ide1 local:iso/tappaas-winconfig.iso,media=cdrom >/dev/null
      info " - Mounted unattended config ISO (ide1)"
    fi
  else
    # Linux VM: standard setup
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
fi
# qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null

if [ "$IMAGETYPE" == "clone" ]; then
  info "${BOLD}Creating a Clone based VM"

  # Find the cluster node that has the template
  TEMPLATE_NODE=""
  CURRENT_NODE="$(hostname -s)"
  
  while read -r node; do
    info "Checking for template $IMAGE on node: $node"
    if ssh -n -o StrictHostKeyChecking=no root@"${node}.mgmt.internal" "qm status $IMAGE" >/dev/null 2>&1; then
      TEMPLATE_NODE="$node"
      info "Found template $IMAGE on ${node}.mgmt.internal"
      break
    else
      info "Template $IMAGE not found on ${node}.mgmt.internal"
    fi
  # Use a management cluster node to list all cluster nodes (pvesh may only
  # return local node info on some hosts). We use the current node's hostname
  # to query the cluster via pvesh.
  done < <(ssh -n -o StrictHostKeyChecking=no "root@$(hostname).mgmt.internal" "pvesh get /cluster/resources --type node --output-format json | jq --raw-output '.[] | select(.type==\"node\") | .node'")
  
  if [ -z "$TEMPLATE_NODE" ]; then
    info "Template $IMAGE not found on any cluster node"
    exit 1
  fi

  # Helper: clone with live progress output via pvesh task log
  # Usage: _clone_with_progress <node> <src-vmid> <new-vmid> <name> [via-ssh]
  _clone_with_progress() {
    local _node="$1" _src="$2" _new="$3" _name="$4" _via_ssh="${5:-}"
    local _pvesh_cmd="pvesh create /nodes/${_node}/qemu/${_src}/clone --newid ${_new} --name '${_name}' --full 1 2>&1"
    info "  Cloning template ${_src} → VM ${_new} on ${_node}..."
    if [[ -n "$_via_ssh" ]]; then
      # shellcheck disable=SC2029
      ssh -o StrictHostKeyChecking=no "root@${_node}.mgmt.internal" "${_pvesh_cmd}" \
        | while IFS= read -r _line; do
            [[ "$_line" =~ ^UPID: ]] && continue
            [[ -n "$_line" ]] && info "  ${_line}"
          done
    else
      eval "${_pvesh_cmd}" \
        | while IFS= read -r _line; do
            [[ "$_line" =~ ^UPID: ]] && continue
            [[ -n "$_line" ]] && info "  ${_line}"
          done
    fi
    _clone_rc=${PIPESTATUS[0]}
    if [[ $_clone_rc -ne 0 ]]; then
      error "Clone failed (exit ${_clone_rc})"
      exit 1
    fi
    info "  ${GN}✓${CL} Clone complete"
  }

  # Check if we're running on the node that has the template
  if [ "$CURRENT_NODE" == "$TEMPLATE_NODE" ]; then
    # Local clone - template is on this node
    _clone_with_progress "${CURRENT_NODE}" "${IMAGE}" "${VMID}" "${VMNAME}"
  else
    # Remote clone - need to clone on template node then migrate to current node
    info "Template is on ${TEMPLATE_NODE}, current node is ${CURRENT_NODE}"

    # Pre-flight: a prior failed migration can leave orphaned '@__migration__'
    # snapshots or D-state 'zfs recv' processes on the target. Any new recv
    # into the poisoned pool will hang indefinitely in __flush_workqueue.
    # Detect that up-front and capture diagnostics so the operator can act.
    info "Pre-flight check for stale migration state on ${CURRENT_NODE}..."
    STALE_SNAPS=$(zfs list -H -t snapshot -o name 2>/dev/null | grep '@__migration__' || true)
    STUCK_RECV=$(ps -eo pid,stat,cmd --no-headers 2>/dev/null | awk '$2 ~ /D/ && /zfs recv/' || true)
    if [ -n "$STALE_SNAPS" ] || [ -n "$STUCK_RECV" ]; then
      LOG="/root/tappaas/migration-stale-${CURRENT_NODE}-$(date +%Y%m%d-%H%M%S).log"
      mkdir -p /root/tappaas
      {
        echo "=== Pre-flight detected stale migration state on ${CURRENT_NODE} at $(date) ==="
        echo
        echo "--- Stale '@__migration__' snapshots ---"
        echo "${STALE_SNAPS:-<none>}"
        echo
        echo "--- D-state 'zfs recv' processes ---"
        echo "${STUCK_RECV:-<none>}"
        echo
        echo "--- Kernel stacks of stuck zfs recv PIDs ---"
        echo "$STUCK_RECV" | awk '{print $1}' | while read -r pid; do
          [ -n "$pid" ] || continue
          echo "-- PID $pid --"
          cat "/proc/${pid}/stack" 2>/dev/null || echo "(no /proc/${pid}/stack)"
        done
        echo
        echo "--- zpool status ${STORAGE} ---"
        zpool status "$STORAGE" 2>&1
        echo
        echo "--- zpool events (last 100) ---"
        zpool events -v 2>/dev/null | tail -100
        echo
        echo "--- dmesg (last 500 lines) ---"
        dmesg -T 2>/dev/null | tail -500
      } > "$LOG" 2>&1
      echo -e "\n${RD}[ERROR]${CL} Stale migration state detected on ${YW}${CURRENT_NODE}${CL}." >&2
      echo -e "A previous migration likely left a stuck 'zfs recv' (D-state) or an orphan" >&2
      echo -e "'@__migration__' snapshot. New migrations will hang indefinitely." >&2
      echo -e "Diagnostics captured to: ${YW}${LOG}${CL}" >&2
      echo -e "Inspect the log; D-state processes cannot be killed and require a reboot" >&2
      echo -e "of ${CURRENT_NODE} to clear. Orphan snapshots can be removed with 'zfs destroy -r'.\n" >&2
      trap - ERR
      exit 1
    fi
    info "Pre-flight check passed — no stale migration state on ${CURRENT_NODE}"

    info "Cloning on ${TEMPLATE_NODE} and migrating to ${CURRENT_NODE}..."

    # Clone on the template node via SSH (with live progress)
    _clone_with_progress "${TEMPLATE_NODE}" "${IMAGE}" "${VMID}" "${VMNAME}" "ssh"

    # Migrate the VM to the current node (online=0 means offline migration)
    info " - Migrating VM ${VMID} from ${TEMPLATE_NODE} to ${NODE}..."
    ssh -o StrictHostKeyChecking=no root@${TEMPLATE_NODE}.mgmt.internal "qm migrate $VMID $NODE --online 0" >/dev/null
    info " - Migration complete"
  fi

  # Set CPU type after cloning (clone inherits from template)
  qm set $VMID --cpu "$CPU_TYPE" >/dev/null
fi

info "${BOLD}Configuring the $VMNAME VM settings..."

qm set $VMID --description "$DESCRIPTION_HTML" >/dev/null
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


function resize_disk_in_vm() {
  # Resize the filesystem inside the VM after Proxmox disk resize.
  # Uses QEMU guest agent for OS detection and IP discovery (no SSH from Proxmox node needed).
  # For NixOS: skips manual resize (boot.growPartition handles it automatically).
  # For Debian/Ubuntu: uses guest agent exec for growpart + resize2fs.
  local vm_hostname="$1"
  local vmid="$2"
  local max_wait=60
  local waited=0

  info "Waiting for VM $vm_hostname guest agent to become available..."

  # Wait for QEMU guest agent to respond
  while ! qm guest cmd "$vmid" ping &>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [ $waited -ge $max_wait ]; then
      warn "VM $vm_hostname: guest agent not responding after ${max_wait}s, skipping filesystem resize"
      return 1
    fi
  done

  info "VM $vm_hostname guest agent is responding"

  # Detect OS type via guest agent exec (no SSH needed)
  local os_id=""
  local exec_result
  exec_result=$(qm guest exec "$vmid" -- grep '^ID=' /etc/os-release 2>/dev/null) || true
  os_id=$(echo "$exec_result" | jq -r '."out-data" // ""' 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d '[:space:]')
  info "Detected OS: $os_id"

  case "$os_id" in
    nixos)
      # NixOS handles partition and filesystem growth automatically via boot.growPartition
      info "NixOS detected — boot.growPartition handles disk resize automatically, skipping manual resize"
      return 0
      ;;
    debian|ubuntu)
      # Find the root partition device via guest agent
      local root_dev
      root_dev=$(qm guest exec "$vmid" -- bash -c '
        dev=$(findmnt -n -o SOURCE /)
        if [[ "$dev" == /dev/disk/by-* ]]; then
          readlink -f "$dev"
        else
          echo "$dev"
        fi
      ' 2>/dev/null | jq -r '."out-data" // ""' | tr -d '[:space:]')
      info "Root device: $root_dev"

      # Extract disk and partition number (e.g., /dev/sda2 -> disk=/dev/sda, partnum=2)
      local disk partnum
      if [[ "$root_dev" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
        disk="${BASH_REMATCH[1]}"
        partnum="${BASH_REMATCH[2]}"
      elif [[ "$root_dev" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
        disk="${BASH_REMATCH[1]}"
        partnum="${BASH_REMATCH[2]}"
      else
        warn "Cannot parse root device $root_dev, skipping filesystem resize"
        return 1
      fi
      info "Disk: $disk, Partition: $partnum"

      # Detect filesystem type
      local fstype
      fstype=$(qm guest exec "$vmid" -- findmnt -n -o FSTYPE / 2>/dev/null | jq -r '."out-data" // ""' | tr -d '[:space:]')
      info "Filesystem type: $fstype"

      info "Resizing partition on Debian/Ubuntu using growpart..."
      qm guest exec "$vmid" -- growpart "${disk}" "${partnum}" &>/dev/null || true
      if [ "$fstype" == "ext4" ]; then
        info "Resizing ext4 filesystem..."
        qm guest exec "$vmid" -- resize2fs "${root_dev}" &>/dev/null || true
      else
        warn "Unsupported filesystem $fstype, partition resized but filesystem not expanded"
        return 1
      fi
      ;;
        "")
      # Empty os_id may indicate Windows (no /etc/os-release)
      # Try Windows resize via guest agent
      info "No Linux OS detected — attempting Windows disk extend via guest agent"
      qm guest exec "$vmid" -- powershell -NoProfile -Command "
        \$partition = Get-Partition -DriveLetter C -ErrorAction SilentlyContinue
        if (\$partition) {
          \$maxSize = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
          if (\$partition.Size -lt \$maxSize) {
            Resize-Partition -DriveLetter C -Size \$maxSize
            Write-Output 'Partition C: extended'
          } else {
            Write-Output 'Partition C: already at maximum size'
          }
        }
      " &>/dev/null || true
      ;;
    *)
      warn "Unsupported OS '$os_id', skipping filesystem resize"
      return 1
      ;;
  esac

  info "Filesystem resize completed for $vm_hostname"
  return 0
}

# Resize disk if this is a clone and target size is larger than current
NEEDS_RESIZE=false
if [ "$IMAGETYPE" == "clone" ]; then
  # Get current disk size from VM config (e.g., "size=16G" -> "16G")
  CURRENT_SIZE=$(qm config $VMID | grep -oP 'scsi0:.*size=\K[0-9]+[GMTK]?' || echo "0")
  # Convert both sizes to bytes for comparison
  size_to_bytes() {
    local size="$1"
    local num="${size%[GMTK]}"
    local unit="${size: -1}"
    case "$unit" in
      G) echo $((num * 1024 * 1024 * 1024)) ;;
      M) echo $((num * 1024 * 1024)) ;;
      T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
      K) echo $((num * 1024)) ;;
      *) echo "$num" ;;  # Assume bytes if no unit
    esac
  }
  CURRENT_BYTES=$(size_to_bytes "$CURRENT_SIZE")
  TARGET_BYTES=$(size_to_bytes "$DISK_SIZE")

  if [ "$TARGET_BYTES" -gt "$CURRENT_BYTES" ]; then
    info "Resizing disk from $CURRENT_SIZE to $DISK_SIZE..."
    qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null
    NEEDS_RESIZE=true
  elif [ "$TARGET_BYTES" -lt "$CURRENT_BYTES" ]; then
    warn "Target size $DISK_SIZE is smaller than current $CURRENT_SIZE - disk shrinking not supported"
  else
    info "Disk already at target size $DISK_SIZE"
  fi
fi

# Windows clone VMs: OOBE setup is handled via QEMU guest agent in
# cluster/services/vm/install-service.sh after this script returns.
# Windows post-sysprep ignores CDROMs for answer files (only reads
# C:\Windows\Panther\unattend.xml), so the old ISO approach is not used.

if [[ "${IMAGETYPE}" != "iso" ]]; then
    qm start $VMID >/dev/null
    echo ""
    info "${BOLD}TAPPaaS $VMNAME VM started successfully"
fi

# Resize filesystem inside VM if disk was expanded
if [ "$NEEDS_RESIZE" == "true" ]; then
  resize_disk_in_vm "$VMNAME" "$VMID" || info "Filesystem resize skipped or failed"
fi

info "${BOLD}TAPPaaS $VMNAME VM creation completed successfully"

