#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: michelroegl-brunner
# Modified by: Lars Rossen to be used for TAPpaas
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

function header_info {
  clear
  cat <<"EOF"
   ____  ____  _   __                        
  / __ \/ __ \/ | / /_______  ____  ________ 
 / / / / /_/ /  |/ / ___/ _ \/ __ \/ ___/ _ \
/ /_/ / ____/ /|  (__  )  __/ / / (__  )  __/
\____/_/   /_/ |_/____/\___/_/ /_/____/\___/ 
                                                                         
EOF
}

header_info
echo -e "Loading..."
#API VARIABLES
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="opnsense-vm"
var_os="opnsense"
var_version="25.1"
#
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
set -Eeo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null
function send_line_to_vm() {
  echo -e "${DGN}Sending line: ${YW}$1${CL}"
  for ((i = 0; i < ${#1}; i++)); do
    character=${1:i:1}
    case $character in
    " ") character="spc" ;;
    "-") character="minus" ;;
    "=") character="equal" ;;
    ",") character="comma" ;;
    ".") character="dot" ;;
    "/") character="slash" ;;
    "'") character="apostrophe" ;;
    ";") character="semicolon" ;;
    '\') character="backslash" ;;
    '`') character="grave_accent" ;;
    "[") character="bracket_left" ;;
    "]") character="bracket_right" ;;
    "_") character="shift-minus" ;;
    "+") character="shift-equal" ;;
    "?") character="shift-slash" ;;
    "<") character="shift-comma" ;;
    ">") character="shift-dot" ;;
    '"') character="shift-apostrophe" ;;
    ":") character="shift-semicolon" ;;
    "|") character="shift-backslash" ;;
    "~") character="shift-grave_accent" ;;
    "{") character="shift-bracket_left" ;;
    "}") character="shift-bracket_right" ;;
    "A") character="shift-a" ;;
    "B") character="shift-b" ;;
    "C") character="shift-c" ;;
    "D") character="shift-d" ;;
    "E") character="shift-e" ;;
    "F") character="shift-f" ;;
    "G") character="shift-g" ;;
    "H") character="shift-h" ;;
    "I") character="shift-i" ;;
    "J") character="shift-j" ;;
    "K") character="shift-k" ;;
    "L") character="shift-l" ;;
    "M") character="shift-m" ;;
    "N") character="shift-n" ;;
    "O") character="shift-o" ;;
    "P") character="shift-p" ;;
    "Q") character="shift-q" ;;
    "R") character="shift-r" ;;
    "S") character="shift-s" ;;
    "T") character="shift-t" ;;
    "U") character="shift-u" ;;
    "V") character="shift-v" ;;
    "W") character="shift-w" ;;
    "X") character="shift=x" ;;
    "Y") character="shift-y" ;;
    "Z") character="shift-z" ;;
    "!") character="shift-1" ;;
    "@") character="shift-2" ;;
    "#") character="shift-3" ;;
    '$') character="shift-4" ;;
    "%") character="shift-5" ;;
    "^") character="shift-6" ;;
    "&") character="shift-7" ;;
    "*") character="shift-8" ;;
    "(") character="shift-9" ;;
    ")") character="shift-0" ;;
    esac
    qm sendkey $VMID "$character"
  done
  qm sendkey $VMID ret
}

function msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

function exit-script() {
  clear
  echo -e "⚠  User exited script \n"
  exit
}

function default_settings() {
  VMID=$(get_valid_nextid)
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE=""
  HN="opnsense"
  CPU_TYPE=""
  CORE_COUNT="4"
  RAM_SIZE="8192"
  STORAGE="tank1"
  BRG=""
  IP_ADDR=""
  WAN_IP_ADDR=""
  LAN_GW=""
  WAN_GW=""
  NETMASK=""
  WAN_NETMASK=""
  VLAN=""
  MAC=$GEN_MAC
  WAN_MAC=$GEN_MAC_LAN
  WAN_BRG=""
  MTU=""
  START_VM="yes"
  METHOD="default"

  # TODO optimize this
  for i in {0,1}; do
    disk="DISK$i"
    eval DISK${i}=vm-${VMID}-disk-${i}${DISK_EXT:-}
    eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
  done

  echo -e "${DGN}Using Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${DGN}Using Hostname: ${BGN}${HN}${CL}"
  echo -e "${DGN}Allocated Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${DGN}Using WAN MAC Address: ${BGN}${WAN_MAC}${CL}"
  echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${DGN}Using Storage Location: ${BGN}${STORAGE}${CL}"
  echo -e "${BL}Creating a OPNsense VM using the above default settings${CL}"
}


header_info
echo -e "${BL}Using Default Settings${CL}"
default_settings

# find the WAN and LAN PCI netcards to pass through to the VM


NETPORTS=$(ip a | grep DOWN | grep -v NO-CARRIER | cut -d":" -f2 | sed 's/^[ \t]*//;s/[ \t]*$//')

    echo -e "${DGN}Using WAN Bridge: ${BGN}${WAN_BRG}${CL}"
    echo -e "${DGN}Using LAN Bridge: ${BGN}${LAN_BRG}${CL}"

msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."
msg_info "Retrieving the URL for the OPNsense Qcow2 Disk Image"
URL=https://download.freebsd.org/releases/VM-IMAGES/14.2-RELEASE/amd64/Latest/FreeBSD-14.2-RELEASE-amd64.qcow2.xz
sleep 2
msg_ok "${CL}${BL}${URL}${CL}"
curl -f#SL -o "$(basename "$URL")" "$URL"
echo -en "\e[1A\e[0K"
FILE=Fressbsd.qcow2
unxz -cv $(basename $URL) >${FILE}
msg_ok "Downloaded ${CL}${BL}${FILE}${CL}"


msg_info "Creating a OPNsense VM"
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags proxmox-helper-scripts -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
pvesm alloc $STORAGE $VMID $DISK0 4M 1>&/dev/null
qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} 1>&/dev/null
qm set $VMID \
  -efidisk0 ${DISK0_REF}${FORMAT} \
  -scsi0 ${DISK1_REF},${DISK_CACHE}${THIN}size=2G \
  -boot order=scsi0 \
  -serial0 socket \
  -tags community-script >/dev/null
qm resize $VMID scsi0 10G >/dev/null
DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <a href='https://Helper-Scripts.com' target='_blank' rel='noopener noreferrer'>
    <img src='https://raw.githubusercontent.com/michelroegl-brunner/ProxmoxVE/refs/heads/develop/misc/images/logo-81x112.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>OPNsense VM</h2>

  <p style='margin: 16px 0;'>
    <a href='https://ko-fi.com/community_scripts' target='_blank' rel='noopener noreferrer'>
      <img src='https://img.shields.io/badge/&#x2615;-Buy us a coffee-blue' alt='spend Coffee' />
    </a>
  </p>
  
  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/community-scripts/ProxmoxVE/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" >/dev/null

msg_info "Bridge interfaces are being added."
qm set $VMID \
  -net0 virtio,bridge=${BRG},macaddr=${MAC}${VLAN}${MTU} 2>/dev/null
msg_ok "Bridge interfaces have been successfully added."

msg_ok "Created a OPNsense VM ${CL}${BL}(${HN})"
msg_ok "Starting OPNsense VM (Patience this takes 20-30 minutes)"
qm start $VMID
sleep 90
send_line_to_vm "root"
send_line_to_vm "fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in"
qm set $VMID \
  -net1 virtio,bridge=${WAN_BRG},macaddr=${WAN_MAC} &>/dev/null
sleep 10
send_line_to_vm "sh ./opnsense-bootstrap.sh.in -y -f -r 25.1"
msg_ok "OPNsense VM is being installed, do not close the terminal, or the installation will fail."
#We need to wait for the OPNsense build proccess to finish, this takes a few minutes
sleep 1000
send_line_to_vm "root"
send_line_to_vm "opnsense"
send_line_to_vm "2"

if [ "$IP_ADDR" != "" ]; then
  send_line_to_vm "1"
  send_line_to_vm "n"
  send_line_to_vm "${IP_ADDR}"
  send_line_to_vm "${NETMASK}"
  send_line_to_vm "${LAN_GW}"
  send_line_to_vm "n"
  send_line_to_vm " "
  send_line_to_vm "n"
  send_line_to_vm "n"
  send_line_to_vm " "
  send_line_to_vm "n"
  send_line_to_vm "n"
  send_line_to_vm "n"
  send_line_to_vm "n"
  send_line_to_vm "n"
else
  send_line_to_vm "1"
  send_line_to_vm "y"
  send_line_to_vm "n"
  send_line_to_vm "n"
  send_line_to_vm " "
  send_line_to_vm "n"
  send_line_to_vm "n"
  send_line_to_vm "n"
fi
#we need to wait for the Config changes to be saved
sleep 20
if [ "$WAN_IP_ADDR" != "" ]; then
  send_line_to_vm "2"
  send_line_to_vm "2"
  send_line_to_vm "n"
  send_line_to_vm "${WAN_IP_ADDR}"
  send_line_to_vm "${NETMASK}"
  send_line_to_vm "${LAN_GW}"
  send_line_to_vm "n"
  send_line_to_vm " "
  send_line_to_vm "n"
  send_line_to_vm " "
  send_line_to_vm "n"
  send_line_to_vm "n"
  send_line_to_vm "n"
fi
sleep 10
send_line_to_vm "0"
msg_ok "Started OPNsense VM"

msg_ok "Completed Successfully!\n"
if [ "$IP_ADDR" != "" ]; then
  echo -e "${INFO}${YW} Access it using the following URL:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${IP_ADDR}${CL}"
else
  echo -e "${INFO}${YW} LAN IP was DHCP.${CL}"
  echo -e "${INFO}${BGN}To find the IP login to the VM shell${CL}"
fi
