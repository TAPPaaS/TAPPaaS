#!/usr/bin/env bash

# Copyright (c) 2025 TAPaaS org
# This file is part of the TAPaaS project.
# TAPaaS is free software: you can redistribute it and/or modify
# it under the terms of the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0) license.
# Author: larsrossen
#
# This script is heavely based on the Proxmox Helper Script: Docker VM
#

function header_info() {
  clear
  cat <<"EOF"
  _______       _____             _____   ____              _       _                   
 |__   __|/\   |  __ \           / ____| |  _ \            | |     | |                  
    | |  /  \  | |__) |_ _  __ _| (___   | |_) | ___   ___ | |_ ___| |_ _ __ __ _ _ __  
    | | / /\ \ |  ___/ _` |/ _` |\___ \  |  _ < / _ \ / _ \| __/ __| __| '__/ _` | '_ \ 
    | |/ ____ \| |  | (_| | (_| |____) | | |_) | (_) | (_) | |_\__ \ |_| | | (_| | |_) |
    |_/_/    \_\_|   \__,_|\__,_|_____/  |____/ \___/ \___/ \__|___/\__|_|  \__,_| .__/ 
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
# TODO: update description to be descriptive!!
  TEMPLATEDESCRIPTION=$(
    cat <<EOF
<div align='center'>
  <a href='https://tapaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://raw.githubusercontent.com/larsrossen/TAPaaS/Documentation/taapaas.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>Docker VM</h2>

  <p style='margin: 16px 0;'>
    <a href='https://ko-fi.com/community_scripts' target='_blank' rel='noopener noreferrer'>
      <img src='https://img.shields.io/badge/&#x2615;-Buy us a coffee-blue' alt='spend Coffee' />
    </a>
  </p>

  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/larsrossen/tapaas' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/larsrossen/tapaas/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/larsrossen/tapaas/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
  This is the template for the TAPaaS Docker VM. It is based on Ubuntu Nobel Numbat (24.04 LTS) and includes Docker and Docker Compose Plugin.
</div>
EOF
  )
# TODO: update description to be descriptive!!
  DESCRIPTION=$(
    cat <<EOF
<div align='center'>
  <a href='https://tapaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://raw.githubusercontent.com/larsrossen/TAPaaS/Documentation/taapaas.png' alt='Logo' style='width:81px;height:112px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>Docker VM</h2>

  <p style='margin: 16px 0;'>
    <a href='https://ko-fi.com/community_scripts' target='_blank' rel='noopener noreferrer'>
      <img src='https://img.shields.io/badge/&#x2615;-Buy us a coffee-blue' alt='spend Coffee' />
    </a>
  </p>

  <span style='margin: 0 10px;'>
    <i class="fa fa-github fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/larsrossen/tapaas' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>GitHub</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-comments fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/larsrossen/tapaas/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Discussions</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class="fa fa-exclamation-circle fa-fw" style="color: #f5f5f5;"></i>
    <a href='https://github.com/larsrossen/tapaas/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
  This is the TAPaaS CICD VM. It is based on the TAPaaS Docker VM template and includes Gitea, Ansible and Terraform. it contain the entire TAPaaS source
  go to <a href='http://tapaas-cicd:xxxx' gitea web interface </a>
</div>
EOF
  )
}

function default_settings() {
  GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
  DISK_SIZE="8G"
  TEMPLATEVMID="8000"
  VMID=$(get_valid_nextid)
  VMNAME="tapaas-cicd"
  TEMPLATEVMNAME="tapaas-ubuntu"
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
  STORAGE="tank1"
  URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
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

echo -e "${CREATING}${BOLD}${DGN}Creating TAPaaS Template VM and TAPaaS CICD VM using the following settings${CL}:"
echo -e " - ${CONTAINERID}${BOLD}${DGN}TAPaaS Template VM ID: ${BGN}${TEMPLATEVMID}${CL}, Template Name: ${BGN}${TEMPLATEVMNAME}${CL}"
echo -e " - ${CONTAINERID}${BOLD}${DGN}TAPaaS CICD VM ID: ${BGN}${VMID}${CL}, Template Name: ${BGN}${VMNAME}${CL}"
echo -e " - ${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}i440fx${CL}"
echo -e " - ${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
echo -e " - ${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
echo -e " - ${DISKSIZE}${BOLD}${DGN}Disk/Storage Location: ${BGN}${STORAGE}${CL}"
echo -e " - ${OS}${BOLD}${DGN}CPU Model: ${BGN}KVM64${CL}"
echo -e " - ${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
echo -e " - ${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
echo -e " - ${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
echo -e " - ${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
echo -e " - ${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}Default${CL}"
echo -e " - ${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}Default${CL}"
echo -e " - ${DISKSIZE}${BOLD}${DGN}Linux Distribution: ${BGN}Ubuntu Nobel Numbat (24.04 LTS)${CL}"
echo -e " - ${DISKSIZE}${BOLD}${DGN}URL of Distribution Image: ${BGN}${URL}${CL}"

msg_info "Doing sanity check of Proxmox PVE."
check_root
arch_check
pve_check
ssh_check
msg_ok "Done sanity check of Proxmox PVE. Everything OK to proceed"

msg_ok "We have 4 steps to complete: 1. Create a TAPaaS template. 2. Create TAPaaS CICD VM. 3. Install Gitea, Ansible and Teraform in VM. 4. Pobulate Git"

# TODO: clean up this code
for i in {0,1}; do
  disk="DISK$i"
  eval DISK${i}=vm-${TEMPLATEVMID}-disk-${i}${DISK_EXT:-}
  eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
done

msg_info "Downloading Ubuntu Nobel Numbat (24.04 LTS) Image"
curl -f#SL -o "$(basename "$URL")" "$URL"
echo -en "\e[1A\e[0K"
FILE=$(basename $URL)
msg_ok "Downloaded Ubuntu Nobel Numbat (24.04 LTS): ${CL}${BL}${FILE}${CL}"

msg_info "Installing Pre-Requisite libguestfs-tools onto Host"
apt-get -qq update && apt-get -qq install libguestfs-tools lsb-release -y >/dev/null
msg_ok "Installed libguestfs-tools successfully"

msg_info "Adding Docker and Docker Compose Plugin to Ubuntu Nobel Numbat (24.04 LTS) Disk Image"
virt-customize -q -a "${FILE}" --install qemu-guest-agent,apt-transport-https,ca-certificates,curl,gnupg,software-properties-common,lsb-release >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "mkdir -p /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable' > /etc/apt/sources.list.d/docker.list" >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "apt-get update -qq && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin" >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "systemctl enable docker" >/dev/null &&
  virt-customize -q -a "${FILE}" --run-command "echo -n > /etc/machine-id" >/dev/null
msg_ok "Added Docker and Docker Compose Plugin to Ubuntu Nobel Numbat (24.04 LTS) Disk Image successfully"

msg_info "Step 1: Creating the TAPaaS Unbuntu with Docker VM template"
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
qm set $TEMPLATEVMID --Tag TAPaaS >/dev/null
qm set $TEMPLATEVMID --ipconfig0 ip=dhcp >/dev/null
qm set $TEMPLATEVMID --sshkey ~/.ssh/id_rsa.pub >/dev/null
qm set $TEMPLATEVMID -description "$TEMPLATEDESCRIPTION" >/dev/null
#TODO create tapaas user and set in cloud init
qm resize $TEMPLATEVMID scsi0 ${DISK_SIZE} >/dev/null
qm template $TEMPLATEVMID >/dev/null
msg_ok "Done Step 1: Creating the TAPaaS Unbuntu with Docker VM template"

msg_info "Step 2: Creating a TAPaaS CICD VM"
qm clone $TEMPLATEVMID $VMID --name $VMNAME --full 1 >/dev/null
qm set $VMID --Tag TAPaaS,CICD >/dev/null
qm start $VMID >/dev/null
sleep 5
msg_ok "Done Step 2: Creating a TAPaaS CICD VM" 

msg_info "Step 3: Installing Gitea, Ansible and Terraform in VM"
# get VM IP
VMIP=$(qm guest exec $VMID -- ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
ssh ubuntu@$VMIP "sudo wget -q -O gitea https://dl.gitea.com/gitea/1.23.8/gitea-1.23.8-linux-amd64" >/dev/null
ssh ubuntu@$VMIP "sudo adduser --system --shell /bin/bash --gecos 'Git Version Control' --group --disabled-password --home /home/git  git" >/dev/null
ssh ubuntu@$VMIP "sudo mkdir -p /var/lib/gitea/{custom,data,log}; sudo chown -R git:git /var/lib/gitea/; sudo chmod -R 750 /var/lib/gitea/; sudo mkdir /etc/gitea; sudo chown root:git /etc/gitea; sudo chmod 770 /etc/gitea"
ssh ubuntu@$VMIP "sudo mv gitea /usr/local/bin/gitea; sudo chmod +x /usr/local/bin/gitea"
# set it as a systemd service
ssh ubuntu@$VMIP "sudo tee /etc/systemd/system/gitea.service >/dev/null" <<EOF
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target
[Service]
RestartSec=2s
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea
[Install]
WantedBy=multi-user.target
EOF
ssh ubuntu@$VMIP sudo systemctl enable gitea --now
sleep 2
# Now to the inital registration
# curl -H "Content-type: application/x-www-form-urlencoded" -d "db_type=SQLite3" -d "db_path=/var/lib/gitea/data/gitea.db" -d "app_name=\"Local TAPaaS Git Repository\"" -d "repo_root_path=/var/lib/gitea/data/git-repositories" -d "lfs_root_path=/var/liv/gitea/data/lfs" -d "run_user=git" -d "domain=192.168.14.57" -d "ssh_port=22" -d "http_port=3000" -d "app_url=http://192.158.14.57:3000/" -d "log_root_path=/var/lib/gitea/log" -d "default_allow_create_organization=on"  -X POST  http://192.168.14.57:3000/

install ansible
ssh ubuntu@$VMIP sudo apt install ansible -y >/dev/null

# installing opentpfu
ssh ubuntu@$VMIP sudo curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
ssh ubuntu@$VMIP sudo chmod +x install-opentofu.sh
ssh ubuntu@$VMIP sudo ./install-opentofu.sh --install-method deb
ssh ubuntu@$VMIP sudo rm -f install-opentofu.sh

msg_ok "Done Step 3: Installing Gitea, Ansible and Terraform in VM"

msg_info "Step 4: Populating Git with TAPaaS"
msg_ok "Done Step 4: Populating Git with TAPaaS"

