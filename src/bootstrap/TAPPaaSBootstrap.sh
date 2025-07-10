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
# This script is heavily based on the Proxmox Helper Script: Docker VM
#

function header_info() {
  # generated with https://patorjk.com/software/taag/#p=display&f=Big&t=TAPPaaS%20Bootstrap
  clear
  cat <<"EOF"
  _______       _____  _____             _____   ____              _       _                   
 |__   __|/\   |  __ \|  __ \           / ____| |  _ \            | |     | |                  
    | |  /  \  | |__) | |__) |_ _  __ _| (___   | |_) | ___   ___ | |_ ___| |_ _ __ __ _ _ __  
    | | / /\ \ |  ___/|  ___/ _` |/ _` |\___ \  |  _ < / _ \ / _ \| __/ __| __| '__/ _` | '_ \ 
    | |/ ____ \| |    | |  | (_| | (_| |____) | | |_) | (_) | (_) | |_\__ \ |_| | | (_| | |_) |
    |_/_/    \_\_|    |_|   \__,_|\__,_|_____/  |____/ \___/ \___/ \__|___/\__|_|  \__,_| .__/ 
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
  if qm status $TEMPLATEVMID &>/dev/null; then
    qm destroy $TEMPLATEVMID &>/dev/null
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

function pve_check() {
  if ! pveversion | grep -Eq "pve-manager/8\.[1-4](\.[0-9]+)*"; then
    msg_error "${CROSS}${RD}This version of Proxmox Virtual Environment is not supported"
    echo -e "Requires Proxmox Virtual Environment Version 8.1 or later."
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${INFO}${YWB}This script will not work with PiMox! \n"
    echo -e "\n ${YWB}Visit https://github.com/asylumexp/Proxmox for ARM64 support. \n"
    echo -e "Exiting..."
    sleep 2
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH, since SSH can create issues while gathering variables. Would you like to proceed with using SSH?" 10 62; then
        echo "you've been warned"
      else
        clear
        exit
      fi
    fi
  fi
}

function exit-script() {
  clear
  echo -e "\n${CROSS}${RD}User exited script${CL}\n"
  exit
}

function create_vm_descriptions_html() {
  TEMPLATEDESCRIPTION=$(
    cat <<EOF
<div align='center'>
  <a href='https://tappaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://www.tappaas.org/taapaas.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>TAPPaaS Ubuntu Template</h2>

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
  This is the template for the generic TAPPaaS VM. It is based on Ubuntu Nobel Numbat (24.04 LTS) and includes Docker foundation tools.
</div>
EOF
  )
# TODO: update description to be descriptive!!
  DESCRIPTION=$(
    cat <<EOF
<div align='center'>
  <a href='https://tappaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://raw.githubusercontent.com/larsrossen/TAPPaaS/Documentation/taapaas.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>TAPPaaS CICD VM</h2>

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
  This is the TAPPaaS CI/CD VM. It is based on the TAPPaaS Docker VM template and includes Git, Ansible and Terraform. it contain the entire TAPPaaS source
</div>
EOF
  )
}

function default_settings() {
  GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
  DISK_SIZE="8G"
  TEMPLATEVMID="8000"
  VMID=$(get_valid_nextid)
  VMNAME="tappaas-cicd"
  TEMPLATEVMNAME="tappaas-ubuntu"
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE=""
  DISK_SIZE="8G"
  CPU_TYPE=""
  CORE_COUNT="2"
  RAM_SIZE="4096"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  STORAGE="tanka1"
  URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
  # TODO: clean up this code
  for i in {0,1}; do
    disk="DISK$i"
    eval DISK${i}=vm-${TEMPLATEVMID}-disk-${i}${DISK_EXT:-}
    eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
  done
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

default_settings
create_vm_descriptions_html

echo -e "${CREATING}${BOLD}${DGN}Creating TAPPaaS Template VM and TAPPaaS CICD VM using the following settings:${CL}"
echo -e "     - ${CONTAINERID}${BOLD}${DGN}TAPPaaS Template VM ID: ${BGN}${TEMPLATEVMID}${CL}, Template Name: ${BGN}${TEMPLATEVMNAME}${CL}"
echo -e "     - ${CONTAINERID}${BOLD}${DGN}TAPPaaS CICD VM ID: ${BGN}${VMID}${CL}, Template Name: ${BGN}${VMNAME}${CL}"
echo -e "     - ${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}i440fx${CL}"
echo -e "     - ${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
echo -e "     - ${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
echo -e "     - ${DISKSIZE}${BOLD}${DGN}Disk/Storage Location: ${BGN}${STORAGE}${CL}"
echo -e "     - ${OS}${BOLD}${DGN}CPU Model: ${BGN}KVM64${CL}"
echo -e "     - ${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
echo -e "     - ${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
echo -e "     - ${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
echo -e "     - ${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
echo -e "     - ${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}Default${CL}"
echo -e "     - ${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}Default${CL}"
echo -e "     - ${DISKSIZE}${BOLD}${DGN}Linux Distribution: ${BGN}Ubuntu Nobel Numbat (24.04 LTS)${CL}"
echo -e "     - ${DISKSIZE}${BOLD}${DGN}URL of Distribution Image: ${BGN}${URL}${CL}"

msg_info "Doing sanity check of Proxmox PVE."
check_root
arch_check
pve_check
ssh_check
msg_ok "Done sanity check of Proxmox PVE. Everything is OK to proceed"

msg_ok "We have 5 steps to complete: 1. install VM tools 2. download Ubuntu 3. add Docker to image 4. Create a TAPPaaS template. 5. Create TAPPaaS CICD VM."

msg_info "Step 1: Installing Pre-Requisite libguestfs-tools onto Host"
apt-get -qq update && apt-get -qq install libguestfs-tools lsb-release -y >/dev/null
msg_ok "Step 1 Done: Installed libguestfs-tools successfully"

msg_info "Step 2. Downloading Ubuntu Nobel Numbat (24.04 LTS) Image"
curl -f#SL -o "$(basename "$URL")" "$URL"
echo -en "\e[1A\e[0K"
FILE=$(basename $URL)
msg_ok "Step 2 Done: Downloaded Ubuntu Nobel Numbat (24.04 LTS): ${CL}${BL}${FILE}${CL}"

msg_info "Step 3: Adding Docker and Docker Compose Plugin to Ubuntu Nobel Numbat (24.04 LTS) Disk Image"
virt-customize -q -a "${FILE}" --install qemu-guest-agent,apt-transport-https,ca-certificates,curl,gnupg,software-properties-common,lsb-release >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "mkdir -p /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable' > /etc/apt/sources.list.d/docker.list" >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "apt-get update -qq && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin" >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "systemctl enable docker" >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "echo -n > /etc/machine-id" >/dev/null
msg_ok "Step 3 Done: Added Docker and Docker Compose Plugin to Ubuntu Nobel Numbat (24.04 LTS) Disk Image successfully"

msg_info "Step 4: Creating the TAPPaaS Unbuntu with Docker VM template"
qm create $TEMPLATEVMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $TEMPLATEVMNAME -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
pvesm alloc $STORAGE $TEMPLATEVMID $DISK0 4M 1>&/dev/null
qm importdisk $TEMPLATEVMID ${FILE} $STORAGE ${DISK_IMPORT:-} 1>&/dev/null
qm set $TEMPLATEVMID \
  -efidisk0 ${DISK0_REF}${FORMAT} \
  -scsi0 ${DISK1_REF},${DISK_CACHE}${THIN}size=${DISK_SIZE} \
  -ide2 ${STORAGE}:cloudinit \
  -boot order=scsi0 \
  -serial0 socket >/dev/null
qm resize $TEMPLATEVMID scsi0 8G >/dev/null
qm set $TEMPLATEVMID --agent enabled=1 >/dev/null
qm set $TEMPLATEVMID --ciuser tappaas >/dev/null
qm set $TEMPLATEVMID --Tag TAPPaaS >/dev/null
qm set $TEMPLATEVMID --ipconfig0 ip=dhcp >/dev/null
qm set $TEMPLATEVMID --sshkey ~/.ssh/id_rsa.pub >/dev/null
qm set $TEMPLATEVMID -description "$TEMPLATEDESCRIPTION" >/dev/null
qm resize $TEMPLATEVMID scsi0 ${DISK_SIZE} >/dev/null
qm template $TEMPLATEVMID >/dev/null
msg_ok "Step 4 Done: Created the TAPPaaS Unbuntu with Docker VM template"

msg_info "Step 5: Creating a TAPPaaS CICD VM"
qm clone $TEMPLATEVMID $VMID --name $VMNAME --full 1 >/dev/null
qm set $VMID --Tag TAPPaaS,CICD >/dev/null
qm set $TEMPLATEVMID -description "$DESCRIPTION" >/dev/null
qm start $VMID >/dev/null
msg_ok "Step 5 Done: Created a TAPPaaS CICD VM" 

msg_info "Bonus Step: set up a few configurartions on PVE node to support terraform and ansible"
apt-get install -y sudo >/dev/null
msg_ok "Bonus Step Done: Installed sudo on PVE node"

echo -e "${CREATING}${BOLD}${DGN}** Congratulation ** You are almost done bootstraping. Please do the following:${CL}"
echo -e "${CREATING}${BOLD}${DGN} 1) Log into TAPPaaS CICD VM using ssh from a host teminal: ssh tappaas@<insert ip of CICD VM>${CL}"
echo -e "${CREATING}${BOLD}${DGN} 2) In the shell of the TAPPaaS CICD VM do:${CL}:"
echo -e "${CREATING}${BOLD}${DGN}   2a) create ssh keys: ssh-keygen -t ed25519 ${CL}"
echo -e "${CREATING}${BOLD}${DGN}   2b) add ssh keys to your github: cat ~/.ssh/id_rsa${CL} (not needed when TAPPaas is public)${CL}"
echo -e "${CREATING}${BOLD}${DGN}       test that the key authentication works: ssh -T git@github.com${CL}"
echo -e "${CREATING}${BOLD}${DGN}   2c) clone the tappaas repository: git clone git@github.com:TAPpaas/TAPpaas.git${CL}"
echo -e "${CREATING}${BOLD}${DGN}   2d) run the final bootstrap code: ./TAPPaaS/src/bootstrap/TAPPaaS-CICD-bootstrap.sh${CL}"
echo -e "${CREATING}${BOLD}${DGN}   2e) set the git user name: git config --global user.name <your name> ${CL}" 
echo -e "${CREATING}${BOLD}${DGN}   2f) set the git user email: git config --global user.email <your email> ${CL}"
echo -e "${CREATING}${BOLD}${DGN} You might want to consult the bootstrap information in TAPPaaS/Documentation/Bootstrap.md${CL}"

