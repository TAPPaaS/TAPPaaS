
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

# Get the directory where this script resides (the module directory)
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# NOTE (ADR-007 module contract): install-module.sh (the orchestrator) has already
# staged + validated + tagged config/<module>.json (its Step 2 copy-update-json)
# BEFORE invoking this script (Step 6) — exactly as for every other module. We do
# NOT re-copy here: a re-copy would drop install-module's --field overrides and
# strip the kind:"module" tag. This script just consumes the staged config.

# Source common routines (just function definitions, no execution)
. /home/tappaas/bin/common-install-routines.sh

# Run a command with its (noisy apt/ssh) output routed to [Debug] — shown only
# with TAPPAAS_DEBUG=1; on failure the captured output is surfaced so errors stay
# visible. Returns the command's rc (so `run_quiet … || die/warn` still works).
run_quiet() {
  local _out _rc _l
  _out="$("$@" 2>&1)" && _rc=0 || _rc=$?
  if [ "${_rc}" -ne 0 ]; then
    if [ -n "${_out}" ]; then printf '%s\n' "${_out}" >&2; fi
    return "${_rc}"
  fi
  if [ -n "${_out}" ]; then while IFS= read -r _l; do debug "  ${_l}"; done <<<"${_out}"; fi
  return 0
}
# shellcheck source=lib/pbs-job.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-job.sh"
# shellcheck source=lib/pbs-namespace.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-namespace.sh"
# shellcheck source=lib/pbs-placement.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-placement.sh"
# shellcheck source=lib/pbs-client.sh disable=SC1091
. "${MODULE_DIR}/lib/pbs-client.sh"

# Now change to temp directory for the rest of the installation
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

VMNAME="$(get_config_value 'vmname' "$1")"
IMAGE_LOCATION="$(get_config_value 'imageLocation' 'http://download.proxmox.com/debian/pbs')"
DESCRIPTION="$(get_config_value 'description' 'TAPPaaS APT installation')"
ZONE="$(get_config_value 'zone0' 'mgmt')"

# ── Placement (ADR-012 P1) ───────────────────────────────────────────
# Decide WHERE (or whether) PBS is realized before doing any work. The old hard
# node:tappaas3 / storage:tankc1 literals are now just the preferred hints for
# `auto`; `auto` discovers a tankc pool and falls back to a shim if none exists.
POLICY="$(placement_policy)"
PREFERRED_NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
info "${BOLD}Resolving backup placement (policy ${BGN}${POLICY}${CL}${BOLD}, preferred node ${BGN}${PREFERRED_NODE}${CL}${BOLD})...${CL}"
read -r MODE NODE STORAGE < <(pbs_discover_placement "${POLICY}" "${PREFERRED_NODE}" "${ZONE}")

case "${MODE}" in
  shim)
    pbs_write_placement_state shim
    warn "No usable 'tankc' pool found (policy ${POLICY}) — installing backup as a SHIM (no PBS datastore)."
    warn "  dependsOn:backup is satisfied so dependent modules still install; promote later with:"
    warn "    update-module.sh backup      (once a tankc pool exists)"
    info "\n${GN}TAPPaaS backup shim recorded.${CL}"
    exit 0
    ;;
  remote-only)
    pbs_write_placement_state remote-only
    warn "Placement 'remote-only' — no local PBS datastore is installed."
    warn "  Off-site push backup is configured separately (ADR-012 P4)."
    info "\n${GN}TAPPaaS backup remote-only placement recorded.${CL}"
    exit 0
    ;;
  local)
    info "${BOLD}Creating TAPPaaS PBS on node ${BGN}${NODE}${CL}${BOLD}, storage ${BGN}${STORAGE}${CL}${BOLD}.${CL}"
    pbs_write_placement_state local "${NODE}" "${STORAGE}"
    ;;
  *)
    die "Unexpected placement result: '${MODE}' (policy ${POLICY})"
    ;;
esac

# update the apt sources and install pbs

info "${BOLD}Test if apt $IMAGE_LOCATION repositories are registered ..."
if ssh root@${NODE}.$ZONE.internal "cat /etc/apt/sources.list.d/proxmox.sources 2>/dev/null" | grep -q "$IMAGE_LOCATION"
then
  debug "Proxmox PBS apt repository already registered."
else
  debug "Proxmox PBS apt repository not found, adding it ..."
  ssh root@${NODE}.$ZONE.internal "cat >> /etc/apt/sources.list.d/proxmox.sources" << EOF
Types: deb
URIs: ${IMAGE_LOCATION}
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi

info "${BOLD}Installing ${DESCRIPTION} on node ${BGN}${NODE}${CL} ..."
run_quiet ssh root@${NODE}.$ZONE.internal bash -c "'
  set -e
  apt update
  apt install -y proxmox-backup-server proxmox-backup-client
  rm -f /etc/apt/sources.list.d/pbs-enterprise.sources
'" || die "PBS server installation failed on ${NODE}"

# The PBS datastore lives on a ZFS pool; make the services wait for the mount
# so they don't open the chunk store before ZFS is up on boot (issue #230).
pbs_ensure_zfs_ordering

# Create a backup directory on the storage tank
sudo mkdir -p /${STORAGE}/tappaas_backups

# Install proxmox-backup-client on ALL current Proxmox VE nodes (ADR-012 P3,
# #382). Idempotent reconcile keyed on live cluster membership — the same
# routine update.sh runs, so a node added later gets its client on update.
pbs_client_reconcile "${ZONE}" "${IMAGE_LOCATION}" \
  || warn "One or more nodes could not be reconciled for proxmox-backup-client (see above)"

info "\n${GN}TAPPaaS PBS installation completed successfully.${CL}"
echo
echo "Proxmox Backup Server and client tools installed on:"
echo "  - PBS Server: ${NODE}.${ZONE}.internal"
echo "  - PBS Client: All Proxmox VE nodes"

# Get the PBS node IP address
PBS_NODE_IP=$(ssh root@${NODE}.${ZONE}.internal "hostname -I | awk '{print \$1}'")
PBS_HOSTNAME="${VMNAME}.${ZONE}.internal"
# PBS datastore / Proxmox storage name — configurable via backup.json (issue #199)
DATASTORE_NAME="$(get_config_value 'pbsStorageName' 'tappaas_backup')"
DATASTORE_PATH="/${STORAGE}/${DATASTORE_NAME}"
PBS_USER="tappaas@pbs"

info "${BOLD}Configuring Proxmox Backup Server...${CL}"

# PBS tappaas@pbs password. Resolution order (so the module can install
# UNATTENDED — F1: backup/install.sh used to hard-block on an interactive prompt):
#   1. $TAPPAAS_PBS_PASSWORD  (explicit; e.g. exported by an unattended installer)
#   2. interactive prompt      (a TTY is attached)
#   3. no TTY + no env var → generate a strong one and save it (mode 600), the
#      same pattern config-firewall.sh uses, so a scripted run never hangs.
if [[ -n "${TAPPAAS_PBS_PASSWORD:-}" ]]; then
  TAPPAAS_PASSWORD="${TAPPAAS_PBS_PASSWORD}"
  info "Using PBS password from \$TAPPAAS_PBS_PASSWORD (non-interactive)."
elif [[ -t 0 ]]; then
  read -rsp "Enter the password for tappaas user (this will be used for PBS): " TAPPAAS_PASSWORD
  echo
else
  # Generate from /dev/urandom (dependency-free — openssl is NOT guaranteed on
  # tappaas-cicd; a missing openssl here used to yield an EMPTY password and a
  # cryptic PBS "must be at least 8 characters" failure, notably on the ADR-012
  # shim→local promotion path which re-runs this installer non-interactively).
  TAPPAAS_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  PBS_CRED_FILE="${HOME}/.pbs-credentials.txt"
  printf 'pbs_user=%s\npbs_password=%s\n' "${PBS_USER}" "${TAPPAAS_PASSWORD}" >"${PBS_CRED_FILE}"
  chmod 600 "${PBS_CRED_FILE}"
  warn "No TTY and \$TAPPAAS_PBS_PASSWORD unset — generated a PBS password and saved it to ${PBS_CRED_FILE} (mode 600)."
fi

# Never proceed with a too-short/empty password — PBS requires ≥8 chars, and a
# silent empty value (e.g. a failed generator) otherwise fails deep inside the
# user-create step with an opaque error.
if [[ "${#TAPPAAS_PASSWORD}" -lt 8 ]]; then
  die "Failed to obtain a PBS password (need ≥8 chars). Set \$TAPPAAS_PBS_PASSWORD and retry."
fi

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

# Create datastore using PBS CLI (idempotent across re-installs).
if proxmox-backup-manager datastore list | grep -q "${DATASTORE_NAME}"; then
  echo "Datastore ${DATASTORE_NAME} already exists"
elif [ -d "${DATASTORE_PATH}/.chunks" ]; then
  # The path already holds a valid PBS datastore from a prior install: the
  # directory survives teardown (it's a plain dir, not a destroyed tank* pool)
  # and a PBS reinstall clears the registry — so it's present on disk but not
  # registered. PBS refuses to 'create' on a non-empty path ("datastore path not
  # empty"); re-attach the existing chunk store instead of failing.
  proxmox-backup-manager datastore create ${DATASTORE_NAME} ${DATASTORE_PATH} --reuse-datastore true
  echo "Datastore ${DATASTORE_NAME} re-attached (existing chunk store reused)"
else
  proxmox-backup-manager datastore create ${DATASTORE_NAME} ${DATASTORE_PATH}
  echo "Datastore ${DATASTORE_NAME} created"
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

# Configure datastore integrity verification: daily verify-job (04:00) + auto-
# verify new backups, so silent bit-rot is caught early (issue #228).
pbs_ensure_verify

# Create the top-level namespaces that isolate other backup sources from the
# local VM backups (which stay in the root namespace): remote/<buddy> for
# TAPPaaS buddies (pull) and external/<client> for third parties (push).
# Per-source child namespaces are created on demand by backup-manage.sh
# add-remote / add-external (issue #227).
info "${BOLD}Ensuring multi-source backup namespaces (issue #227)${CL}"
pbs_ns_ensure remote
pbs_ns_ensure external

# Step 5: Get PBS fingerprint
info "Getting PBS fingerprint..."
PBS_FINGERPRINT=$(ssh root@${NODE}.${ZONE}.internal "proxmox-backup-manager cert info | grep 'Fingerprint (sha256)' | sed 's/^Fingerprint (sha256): //'")
if [ -z "$PBS_FINGERPRINT" ]; then
  error "Failed to retrieve PBS fingerprint"
  echo "Please run manually on ${NODE}: proxmox-backup-manager cert info"
  exit 1
fi
echo "PBS Fingerprint: ${PBS_FINGERPRINT}"

# Step 6: Add PBS storage to Proxmox datacenter (on primary node)
MGMT_NODE="$(get_node_hostname 0)"
info "Adding PBS storage to Proxmox datacenter on ${MGMT_NODE}..."
ssh "root@${MGMT_NODE}.${ZONE}.internal" "bash -s" <<EOF
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

# Step 7: Backup job — managed per-module, dependsOn-driven (issue #200)
#
# We deliberately do NOT create an "--all" job here. The cluster backup job is
# now owned by the backup:vm service: each module that declares
# "dependsOn": ["backup:vm"] adds its VMID to a single shared, marker-tagged
# job via backup/services/vm/install-service.sh (and removes it on delete).
# This backs up only the VMs that opt in (data-bearing modules); foundation
# VMs that are reproducible from git are intentionally not auto-backed-up.
#
# A pre-existing legacy "--all" job (from earlier installs) is migrated in
# place to the managed vmid-list model the first time any backup:vm module is
# installed or updated (see lib/pbs-job.sh::pbs_migrate_all_job).
info "Backup job is managed per-module via backup:vm (no --all job created)."

# Register the alwaysBackup foundation VMs (firewall, tappaas-cicd) — they
# bootstrap before this backup server so cannot dependsOn backup:vm, but should
# still be backed up. Also migrates any legacy --all job. (issue #200)
info "Registering alwaysBackup VMs in the managed backup job..."
pbs_ensure_always || warn "Could not register some alwaysBackup VMs (check backup job)"

info "\n${GN}PBS configuration completed successfully!${CL}"
echo
echo "Next steps:"
echo "1. Access PBS GUI at https://${VMNAME}.${ZONE}.internal:8007"
echo "2. Consider setting up backup-of-backup to a remote PBS"
echo
