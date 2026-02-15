
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


# Source common routines (expects $1 to be module name)
. /home/tappaas/bin/copy-update-json.sh
. /home/tappaas/bin/common-install-routines.sh
check_json /home/tappaas/config/$1.json || exit 1

info "${BOLD}Creating TAPPaaS Proxmox Backup Server (PBS) installation using the following settings:"
NODE="$(get_config_value 'node' 'tappaas1')"
VMNAME="$(get_config_value 'vmname' "$1")"
STORAGE="$(get_config_value 'storage' 'tankc1')"
IMAGE_TYPE="$(get_config_value 'imageType' 'apt')"
IMAGE="$(get_config_value 'image' 'pbs')"
IMAGE_LOCATION="$(get_config_value 'imageLocation' 'http://download.proxmox.com/debian/pbs')"
DESCRIPTION="$(get_config_value 'description' 'TAPPaaS APT installation')"
ZONE="$(get_config_value 'zone0' 'mgmt')"

# update the apt sources and install pbs

info "${BOLD}Test if apt $IMAGE_LOCATION repositories are registered ..."
if ssh root@${NODE}.$ZONE.internal "cat /etc/apt/sources.list.d/proxmox.sources 2>/dev/null" | grep -q "$IMAGE_LOCATION"
then
  echo "Proxmox PBS apt repository already registered."
else
  echo "Proxmox PBS apt repository not found, adding it ..."
  ssh root@${NODE}.$ZONE.internal "cat >> /etc/apt/sources.list.d/proxmox.sources" << EOF
Types: deb
URIs: ${IMAGE_LOCATION}
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi

info "${BOLD}Installing ${DESCRIPTION} on node ${BGN}${NODE}${CL} ..."
ssh root@${NODE}.$ZONE.internal bash -c "'
  set -e
  apt update
  apt install -y proxmox-backup-server proxmox-backup-client
  rm -f /etc/apt/sources.list.d/pbs-enterprise.sources
'"

# Create a backup directory on the storage tank
sudo mkdir -p /${STORAGE}/tappaas_backups

# Install proxmox-backup-client on all Proxmox VE nodes
info "${BOLD}Installing proxmox-backup-client on all Proxmox VE nodes...${CL}"

# Get list of all cluster nodes
CLUSTER_NODES=$(ssh root@${NODE}.${ZONE}.internal "pvesh get /nodes --output-format json" | jq -r '.[].node')

for PVE_NODE in $CLUSTER_NODES; do
  info "Installing proxmox-backup-client on ${PVE_NODE}..."
  ssh root@${PVE_NODE}.${ZONE}.internal bash -c "'
    set -e
    # Check if PBS repository is configured
    if ! grep -q \"${IMAGE_LOCATION}\" /etc/apt/sources.list.d/proxmox.sources 2>/dev/null; then
      # Add PBS repository
      cat >> /etc/apt/sources.list.d/proxmox.sources <<EOFPBS
Types: deb
URIs: ${IMAGE_LOCATION}
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOFPBS
    fi

    # Install proxmox-backup-client
    apt update
    apt install -y proxmox-backup-client
  '" || warn "Failed to install proxmox-backup-client on ${PVE_NODE}"
done

info "\n${GN}TAPPaaS PBS installation completed successfully.${CL}"
echo
echo "Proxmox Backup Server and client tools installed on:"
echo "  - PBS Server: ${NODE}.${ZONE}.internal"
echo "  - PBS Client: All Proxmox VE nodes"

# Get the PBS node IP address
PBS_NODE_IP=$(ssh root@${NODE}.${ZONE}.internal "hostname -I | awk '{print \$1}'")
PBS_HOSTNAME="${VMNAME}.${ZONE}.internal"
DATASTORE_NAME="tappaas_backup"
DATASTORE_PATH="/${STORAGE}/tappaas_backup"
PBS_USER="tappaas@pbs"

info "${BOLD}Configuring Proxmox Backup Server...${CL}"

# Prompt for password
read -sp "Enter the password for tappaas user (this will be used for PBS): " TAPPAAS_PASSWORD
echo

# Step 0: Add DNS entry in OPNsense
info "Adding DNS entry in OPNsense for ${VMNAME}.${ZONE}.internal..."
if dns-manager --no-ssl-verify add "${VMNAME}" "${ZONE}.internal" "${PBS_NODE_IP}" --description "PBS Backup Server"; then
  echo "DNS entry added successfully"
else
  warn "Failed to add DNS entry automatically. You may need to add it manually:"
  echo "  Hostname: ${VMNAME}"
  echo "  Domain: ${ZONE}.internal"
  echo "  IP: ${PBS_NODE_IP}"
fi

# Step 1: Create datastore on PBS
info "Creating datastore ${DATASTORE_NAME} at ${DATASTORE_PATH}..."
ssh root@${NODE}.${ZONE}.internal "bash -s" <<EOF
set -e
# Create directory if it doesn't exist
mkdir -p ${DATASTORE_PATH}

# Create datastore using PBS CLI
if ! proxmox-backup-manager datastore list | grep -q "${DATASTORE_NAME}"; then
  proxmox-backup-manager datastore create ${DATASTORE_NAME} ${DATASTORE_PATH}
  echo "Datastore ${DATASTORE_NAME} created"
else
  echo "Datastore ${DATASTORE_NAME} already exists"
fi
EOF

# Step 2: Create PBS user
info "Creating PBS user ${PBS_USER}..."
ssh root@${NODE}.${ZONE}.internal "bash -s" <<EOF
set -e
# Check if user exists
if ! proxmox-backup-manager user list | grep -q "${PBS_USER}"; then
  # Create user using proper PBS command
  proxmox-backup-manager user create ${PBS_USER} --password "${TAPPAAS_PASSWORD}"
  echo "User ${PBS_USER} created"
else
  # User exists
  echo "User ${PBS_USER} already exists"
fi
EOF

# Step 3: Set permissions for datastore
info "Setting permissions for ${PBS_USER} on ${DATASTORE_NAME}..."
ssh root@${NODE}.${ZONE}.internal "bash -s" <<EOF
set -e
# Add ACL permission for the user on the datastore
proxmox-backup-manager acl update /datastore/${DATASTORE_NAME} Admin --auth-id ${PBS_USER} || true
echo "Permissions set for ${PBS_USER}"
EOF

# Step 4: Configure retention policy and garbage collection
info "Configuring retention policy and garbage collection..."
ssh root@${NODE}.${ZONE}.internal "bash -s" <<EOF
set -e
# Create or update prune job with retention settings
# Schedule: daily at 02:00
PRUNE_JOB_ID="prune-${DATASTORE_NAME}"
if ! proxmox-backup-manager prune-job list | grep -q "\${PRUNE_JOB_ID}"; then
  proxmox-backup-manager prune-job create \${PRUNE_JOB_ID} \
    --store ${DATASTORE_NAME} \
    --schedule '02:00' \
    --keep-last 4 \
    --keep-daily 14 \
    --keep-weekly 8 \
    --keep-monthly 12 \
    --keep-yearly 6 \
    --disable false
  echo "Prune job \${PRUNE_JOB_ID} created with retention policy"
else
  echo "Prune job \${PRUNE_JOB_ID} already exists"
fi

# Configure garbage collection schedule on datastore
# Schedule: daily at 03:00
proxmox-backup-manager datastore update ${DATASTORE_NAME} --gc-schedule '03:00'
echo "Garbage collection configured for ${DATASTORE_NAME} (runs at 03:00)"
EOF

# Step 5: Get PBS fingerprint
info "Getting PBS fingerprint..."
PBS_FINGERPRINT=$(ssh root@${NODE}.${ZONE}.internal "proxmox-backup-manager cert info | grep 'Fingerprint (sha256)' | sed 's/^Fingerprint (sha256): //'")
if [ -z "$PBS_FINGERPRINT" ]; then
  error "Failed to retrieve PBS fingerprint"
  echo "Please run manually on ${NODE}: proxmox-backup-manager cert info"
  exit 1
fi
echo "PBS Fingerprint: ${PBS_FINGERPRINT}"

# Step 6: Add PBS storage to Proxmox datacenter (on tappaas1)
info "Adding PBS storage to Proxmox datacenter on tappaas1..."
ssh root@tappaas1.${ZONE}.internal "bash -s" <<EOF
set -e

# Create password file temporarily (without trailing newline)
printf '%s' "${TAPPAAS_PASSWORD}" > /tmp/pbs_password.tmp

# Add PBS storage using pvesm
if ! pvesm status | grep -q ${DATASTORE_NAME}; then
  pvesm add pbs ${DATASTORE_NAME} --server ${PBS_HOSTNAME} --datastore ${DATASTORE_NAME} --username "${PBS_USER}" --password "\$(cat /tmp/pbs_password.tmp)" --fingerprint "${PBS_FINGERPRINT}"
  echo "PBS storage added to Proxmox"
else
  echo "PBS storage already configured in Proxmox"
fi

# Clean up password file
rm -f /tmp/pbs_password.tmp
EOF

# Step 7: Create backup job in Proxmox
info "Creating backup job in Proxmox..."
ssh root@tappaas1.${ZONE}.internal "bash -s" <<EOF
set -e

# Check if backup job exists using API
if ! pvesh get /cluster/backup --output-format=json | grep -q '"storage":"${DATASTORE_NAME}"'; then
  # Create backup job using pvesh API
  pvesh create /cluster/backup \
    --storage ${DATASTORE_NAME} \
    --all 1 \
    --mode snapshot \
    --compress zstd \
    --starttime 21:00 \
    --enabled 1 \
    --mailnotification always
  echo "Backup job created (runs daily at 21:00)"
else
  echo "Backup job already exists for ${DATASTORE_NAME}"
fi
EOF

info "\n${GN}PBS configuration completed successfully!${CL}"
echo
echo "Next steps:"
echo "1. Access PBS GUI at https://${VMNAME}.${ZONE}.internal:8007"
echo "2. Consider setting up backup-of-backup to a remote PBS"
echo
