#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# This script automates guest restoration from PBS backups — VMs and LXC
# containers; the backup's volid says which (lib/restore-guest.sh)
# Run this from tappaas-cicd as the tappaas user
#
# Usage: ./restore.sh [options]
#   -v, --vmid <vmid>           VMID to restore (required)
#   -n, --node <node>           Target Proxmox node (default: the first mgmt node from site.json)
#   -s, --storage <storage>     Target storage for VM (default: original)
#   -b, --backup-id <id>        Specific backup ID to restore (default: latest)
#   -t, --target-vmid <vmid>    Restore INTO a different (unused) VMID, leaving the
#                               original untouched. The restored guest is left
#                               STOPPED with fresh MACs. This is how a recovery
#                               path is rehearsed, and how you compare a restore
#                               against a running original before committing.
#   --replace                   With --target-vmid: that guest EXISTS and is replaced by
#                               the backup of --vmid, keeping its name, onboot and
#                               network devices — RESTORE.md §2, `backup-manager
#                               restore restore <module> --from <src>` (#729)
#   -l, --list                  List available backups for a VMID
#   --list-all                  List all available backups
#   -h, --help                  Show this help message

function show_help() {
  cat << EOF
TAPPaaS PBS Restore Script

Usage: $0 [options]

Options:
  -v, --vmid <vmid>           VMID to restore (required for restore)
  -n, --node <node>           Target Proxmox node (default: the first mgmt node from site.json)
  -s, --storage <storage>     Target storage for VM (default: original)
  -b, --backup-id <id>        Specific backup ID to restore (default: latest)
  -t, --target-vmid <vmid>    Restore into a different, unused VMID (left STOPPED,
                              fresh MACs) instead of over the original
                              A repeated --vmid overrides the earlier one, so a
                              caller that already supplied one (backup-manager
                              restore) can be pointed at a different SOURCE vmid
  --replace                   With --target-vmid: replace that EXISTING guest with the
                              backup of --vmid, keeping its name, onboot and network
                              devices, so its DNS, DHCP reservation and firewall
                              rules still hold (RESTORE.md §2). Left stopped.
  --start / --no-start        A plain restore (no --target-vmid): start the guest
                              afterwards, or don't. Neither: asked on a terminal;
                              with none (backup-manager over ssh), left stopped.
  -l, --list                  List available backups for a VMID (requires -v)
  --list-all                  List all available backups
  -h, --help                  Show this help message

Examples:
  # List all backups
  $0 --list-all

  # List backups for specific VM
  $0 --vmid 101 --list

  # Restore latest backup of VMID 101 to primary node
  $0 --vmid 101

  # Restore specific backup to tappaas2
  $0 --vmid 101 --node tappaas2 --backup-id vm/101/2025-01-26T21:00:00Z

  # Restore to different storage
  $0 --vmid 101 --storage tanka2
EOF
}

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
}

function cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    popd >/dev/null 2>&1 || true
    rm -rf $TEMP_DIR
  fi
}

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# Source common routines and load backup module config
. /home/tappaas/bin/common-install-routines.sh
# ha-vm-lib (#434): stopping an HA resource safely. Installed copy first, repo
# copy as the fallback so the script works from a checkout too.
if [[ -r /home/tappaas/bin/ha-vm-lib.sh ]]; then
    # shellcheck source=../../tappaas-cicd/lib/ha-vm-lib.sh disable=SC1091
    . /home/tappaas/bin/ha-vm-lib.sh
elif [[ -r "$(dirname "${BASH_SOURCE[0]}")/../../tappaas-cicd/lib/ha-vm-lib.sh" ]]; then
    # shellcheck source=../../tappaas-cicd/lib/ha-vm-lib.sh disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/../../tappaas-cicd/lib/ha-vm-lib.sh"
fi
# The guest type a backup holds (#729): beside this script in a checkout.
# shellcheck source=../lib/restore-guest.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/restore-guest.sh"
JSON_CONFIG="${CONFIG_DIR}/backup.json"
JSON=$(cat "${JSON_CONFIG}")

# The node PBS runs on. ADR-012 §2.1: the RESOLVED node is carried by the
# placement (`placementState: node` + `.node`, §2.1/#600; the pre-#600
# `node:<name>` form is still read). Otherwise `.node` is only a discovery
# constraint, and the fallback.
PBS_NODE="$(jq -r 'if .placementState == "node" then (.node // "") else ((.placementState // "") | if startswith("node:") then ltrimstr("node:") else "" end) end' "${JSON_CONFIG}" 2>/dev/null)"
[[ -n "${PBS_NODE}" ]] || PBS_NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE="$(get_config_value 'zone0' 'mgmt')"
STORAGE_NAME="$(get_config_value 'pbsStorageName' 'tappaas_backup')"  # configurable, issue #199

# Default values
TARGET_NODE="$(get_node_hostname 0)"
VMID=""
TARGET_STORAGE=""
BACKUP_ID=""
TARGET_VMID=""
REPLACE=false
START=""   # yes | no | "" = ask, when there is someone to ask
LIST_MODE=false
LIST_ALL_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--vmid)
      VMID="$2"
      shift 2
      ;;
    -n|--node)
      TARGET_NODE="$2"
      shift 2
      ;;
    -s|--storage)
      TARGET_STORAGE="$2"
      shift 2
      ;;
    -b|--backup-id)
      BACKUP_ID="$2"
      shift 2
      ;;
    -t|--target-vmid)
      TARGET_VMID="$2"
      shift 2
      ;;
    --replace)
      REPLACE=true
      shift
      ;;
    --start)
      START=yes
      shift
      ;;
    --no-start)
      START=no
      shift
      ;;
    -l|--list)
      LIST_MODE=true
      shift
      ;;
    --list-all)
      LIST_ALL_MODE=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# List all backups
if [ "$LIST_ALL_MODE" = true ]; then
  info "${BOLD}Listing all backups from PBS...${CL}"

  # Check if PBS storage is configured
  if ! ssh root@${TARGET_NODE}.${ZONE}.internal "pvesm status 2>/dev/null | grep -q ${STORAGE_NAME}"; then
    echo "${RD}Error: PBS storage '${STORAGE_NAME}' is not configured in Proxmox${CL}"
    echo "Please run ./configure.sh first to set up the PBS storage backend."
    exit 1
  fi

  # Check if PBS storage is active
  STORAGE_STATUS=$(ssh root@${TARGET_NODE}.${ZONE}.internal "pvesm status 2>&1 | grep ${STORAGE_NAME}" || true)
  if echo "$STORAGE_STATUS" | grep -q "error fetching"; then
    echo "${RD}Error: PBS storage is configured but cannot connect to the PBS server${CL}"
    echo "This usually means:"
    echo "  1. The PBS server hasn't been installed yet (run: cd ~/TAPPaaS/src/foundation/backup && ./install.sh)"
    echo "  2. The DNS entry for the PBS server doesn't exist (run: ./configure.sh)"
    echo "  3. The PBS server is not running on ${PBS_NODE}.${ZONE}.internal"
    exit 1
  fi

  # List backups from PBS storage
  ssh root@${TARGET_NODE}.${ZONE}.internal "pvesh get /nodes/${TARGET_NODE}/storage/${STORAGE_NAME}/content --content backup" 2>/dev/null || {
    echo "${RD}Error: Failed to list backups${CL}"
    echo "No backups found in PBS storage '${STORAGE_NAME}'"
    exit 1
  }
  exit 0
fi

# List backups for specific VMID
if [ "$LIST_MODE" = true ]; then
  if [ -z "$VMID" ]; then
    echo "Error: --vmid required when using --list"
    show_help
    exit 1
  fi

  info "${BOLD}Listing backups for VMID ${VMID}...${CL}"
  ssh root@${TARGET_NODE}.${ZONE}.internal "bash -s" <<EOF
set -e
# List backups for this VMID from PBS
pvesh get /nodes/${TARGET_NODE}/storage/${STORAGE_NAME}/content --vmid ${VMID}
EOF
  exit 0
fi

# Validate required parameters for restore
if [ -z "$VMID" ]; then
  echo "Error: --vmid is required for restore operation"
  show_help
  exit 1
fi

info "${BOLD}Starting restore process for VMID ${VMID}...${CL}"

# Get backup information
info "Fetching backup information..."
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

# If no specific backup ID provided, find the latest
if [ -z "$BACKUP_ID" ]; then
  info "Finding latest backup for VMID ${VMID}..."
  # --output-format json, NOT the human table. The old form was
  #   pvesh get ... | grep volid | tail -1 | awk '{print $3}'
  # and `grep volid` matched the TABLE HEADER — the only line containing the
  # word — so it extracted a box-drawing character and restored from a volid
  # that could not exist. The restore then reported success (see below), which
  # is how a backup system convinces you it works while restoring nothing.
  # Newest = highest ctime, not "last line".
  BACKUP_ID=$(ssh -n root@${TARGET_NODE}.${ZONE}.internal \
    "pvesh get /nodes/${TARGET_NODE}/storage/${STORAGE_NAME}/content --vmid ${VMID} --output-format json" \
    | jq -r 'sort_by(.ctime) | last | .volid // empty')

  # A volid always looks like <storage>:backup/<type>/<vmid>/<time>. Anything
  # else means the lookup failed, and restoring from it must not be attempted.
  if [ -n "${BACKUP_ID}" ] && ! printf '%s' "${BACKUP_ID}" | grep -qE '^[A-Za-z0-9_.-]+:backup/'; then
    echo "${RD}Error: backup lookup returned something that is not a volume id: '${BACKUP_ID}'${CL}"
    exit 1
  fi

  if [ -z "$BACKUP_ID" ]; then
    echo "${RD}Error: No backups found for VMID ${VMID}${CL}"
    exit 1
  fi
  info "Latest backup found: ${BACKUP_ID}"
else
  info "Using specified backup: ${BACKUP_ID}"
fi

# Normalize whatever form of backup identifier we were given into a volid:
#   tappaas_backup:backup/vm/110/…  already a volid (what --list prints)
#   backup/vm/110/…                 storage-relative path
#   vm/110/…                        the bare snapshot triple
case "${BACKUP_ID}" in
  *:backup/*) VOLID="${BACKUP_ID}" ;;
  backup/*)   VOLID="${STORAGE_NAME}:${BACKUP_ID}" ;;
  *)          VOLID="${STORAGE_NAME}:backup/${BACKUP_ID}" ;;
esac
info "Using volume ID: ${VOLID}"

# A VM and a container restore through different calls, and are stopped,
# destroyed and checked with different commands. The volid says which (#729).
GUEST_TYPE="$(restore_guest_type "${VOLID}")" \
  || die "cannot tell from ${VOLID} whether the backup holds a VM or a container (expected …backup/vm/… or …backup/ct/…)"
CLI="$(restore_guest_cli "${GUEST_TYPE}")"
if [ "${GUEST_TYPE}" = "lxc" ] && [ -z "${TARGET_STORAGE}" ]; then
  # A container restore without a storage lands on 'local', not where it came
  # from — a different guest from the one backed up. Name it.
  die "VMID ${VMID}'s backup is a container: give its storage with --storage (e.g. --storage tanka1)"
fi
info "Backup holds a ${GUEST_TYPE} guest"

# From here on, VMID is the SOURCE (whose backup we read) and RESTORE_VMID is
# the DESTINATION. They differ only for --target-vmid, whose whole point is to
# leave the original alone — so a rehearsal can never eat the thing it is
# rehearsing the recovery of.
RESTORE_VMID="${TARGET_VMID:-${VMID}}"
if [ "${REPLACE}" = true ] && [ -z "${TARGET_VMID}" ]; then
  die "--replace needs --target-vmid: it names the guest the backup of ${VMID} replaces"
fi
if [ -n "${TARGET_VMID}" ]; then
  info "Restoring INTO VMID ${RESTORE_VMID} (source VM ${VMID} is left untouched)"
fi
# The guest the backup was taken of. When it is not the destination, this is a
# copy of another guest, which may be running on the same network: fresh MACs,
# always — not only for --target-vmid (#729: a --backup-id naming another
# guest's snapshot used to restore that guest's MAC beside it).
SOURCE_VMID="$(restore_volid_vmid "${VOLID}")" || SOURCE_VMID="${VMID}"

# Check if the DESTINATION VMID is taken — by a VM or a container: one VMID
# space, two commands.
info "Checking if VMID ${RESTORE_VMID} already exists..."
EXISTING_TYPE=$(ssh root@${TARGET_NODE}.${ZONE}.internal \
  "if qm status ${RESTORE_VMID} >/dev/null 2>&1; then echo qemu; elif pct status ${RESTORE_VMID} >/dev/null 2>&1; then echo lxc; else echo none; fi")
VM_EXISTS=no
[ "${EXISTING_TYPE}" = "none" ] || VM_EXISTS=yes
if [ "$VM_EXISTS" = "yes" ] && [ "${EXISTING_TYPE}" != "${GUEST_TYPE}" ]; then
  die "VMID ${RESTORE_VMID} on ${TARGET_NODE} is a ${EXISTING_TYPE} guest but the backup holds a ${GUEST_TYPE} — refusing to replace one kind with the other"
fi

if [ "${REPLACE}" = true ] && [ "$VM_EXISTS" != "yes" ]; then
  die "--replace: VMID ${RESTORE_VMID} does not exist on ${TARGET_NODE} — declare (install) the module first, then restore into it (RESTORE.md §2)"
fi

IDENTITY=""
if [ "$VM_EXISTS" = "yes" ]; then
  if [ -n "${TARGET_VMID}" ] && [ "${REPLACE}" != true ]; then
    echo "${RD}Error: target VMID ${RESTORE_VMID} is already in use${CL}"
    echo "Pick an unused VMID — --target-vmid exists to avoid destroying anything."
    echo "To replace that guest with this backup on purpose: --replace (backup-manager: --from)."
    exit 1
  fi
  if [ "${REPLACE}" = true ]; then
    # Named explicitly on the command line: that is the consent. What makes it
    # the platform's guest is kept and put back after the restore.
    IDENTITY="$(ssh -n root@${TARGET_NODE}.${ZONE}.internal "${CLI} config ${RESTORE_VMID}" | restore_identity_lines)" \
      || die "could not read ${RESTORE_VMID}'s config — refusing to replace a guest whose identity cannot be kept"
    [ -n "${IDENTITY}" ] || die "${RESTORE_VMID} has no name/network lines to keep — refusing to replace it"
    info "Replacing ${GUEST_TYPE} ${RESTORE_VMID} with the backup of ${VMID}; keeping:"
    printf '%s\n' "${IDENTITY}" | sed 's/^/    /'
  else
    info "VM ${RESTORE_VMID} already exists on ${TARGET_NODE}"
    # No terminal (backup-manager over ssh, a script): nobody to ask — the
    # flag that says so is --replace (#729 §3).
    [ -t 0 ] || die "VM ${RESTORE_VMID} exists and there is no terminal to confirm on — pass --replace to overwrite it"
    read -p "Do you want to overwrite it? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
      echo "Restore cancelled by user"
      exit 0
    fi
  fi
  # Stopping an HA-managed VM is NOT `qm stop; sleep`. `qm stop` hands a request
  # to the CRM, which completes it on its own schedule — the exact race that
  # left this site's gateway down for 7h41m (#434), which is why ha-vm-lib
  # exists. Drive HA through ha-manager and CONFIRM the transition; only fall
  # back to a direct stop when the resource is genuinely not HA-managed.
  # ha-vm-lib takes the node's FQDN and logs in as root itself: passing
  # root@<node> made it ssh to root@root@<node>, so every restore over an
  # existing guest stopped here, refusing to guess (#729, found in §2).
  info "Stopping and removing existing VM ${RESTORE_VMID}..."
  if declare -F havm_stop >/dev/null 2>&1; then
    if ! havm_stop "${TARGET_NODE}.${ZONE}.internal" "${RESTORE_VMID}" "$([ "${GUEST_TYPE}" = lxc ] && echo lxc || echo vm)" "${STOP_TIMEOUT:-180}"; then
      # The resource may have been handed to HA as 'stopped' before the failure;
      # give it back rather than leaving it parked.
      [[ "${HAVM_LAST_STOP_WAS_HA:-0}" -eq 1 ]] \
        && havm_release_ha_stop "${TARGET_NODE}.${ZONE}.internal" "$([ "${GUEST_TYPE}" = lxc ] && echo ct || echo vm):${RESTORE_VMID}"
      die "Could not confirm VM ${RESTORE_VMID} stopped — refusing to destroy it. Nothing was changed."
    fi
  else
    warn "ha-vm-lib not available — falling back to a direct stop (unsafe for an HA-managed VM, #434)"
    ssh root@${TARGET_NODE}.${ZONE}.internal "${CLI} stop ${RESTORE_VMID} || true"
    sleep 5
  fi

  # --purge clears the VMID out of backup/replication jobs and HA;
  # --destroy-unreferenced-disks removes disks carrying this VMID that the
  # config no longer references, so a restore does not silently inherit an
  # older incarnation's leftover volumes.
  ssh root@${TARGET_NODE}.${ZONE}.internal \
    "${CLI} destroy ${RESTORE_VMID} --purge --destroy-unreferenced-disks 1" \
    || die "Could not destroy VM ${RESTORE_VMID}"
fi

# Perform the restore
info "Restoring ${GUEST_TYPE} ${VMID} from backup into VMID ${RESTORE_VMID}..."


# A copy restored alongside its original MUST get fresh MAC addresses, or two
# guests answer for the same address the moment either is started.
UNIQUE_OPT=""
[ "${SOURCE_VMID}" != "${RESTORE_VMID}" ] && UNIQUE_OPT="--unique 1"

# Build restore options
RESTORE_OPTS=""
if [ -n "$TARGET_STORAGE" ]; then
  RESTORE_OPTS="--storage ${TARGET_STORAGE}"
  info "Target storage: ${TARGET_STORAGE}"
fi

# Try different restore methods based on available commands
# Capture the SSH output to check for errors
RESTORE_OUTPUT=$(ssh root@${TARGET_NODE}.${ZONE}.internal "bash -s" <<EOF
set -e

# Clean up any stale lock files for this VMID
if [ -f /var/lock/qemu-server/lock-${RESTORE_VMID}.conf ]; then
  echo "Removing stale lock file for VM ${RESTORE_VMID}..."
  rm -f /var/lock/qemu-server/lock-${RESTORE_VMID}.conf
fi

# Unlock the guest if it's locked
if ${CLI} status ${RESTORE_VMID} >/dev/null 2>&1; then
  echo "Unlocking ${GUEST_TYPE} ${RESTORE_VMID}..."
  ${CLI} unlock ${RESTORE_VMID} 2>/dev/null || true
fi

# Capture restore output AND its real exit code. Piping pvesh into tee used to
# hide the failure: a pipeline exits with tee status, so the remote set -e never
# fired and the only detection left was grepping the output for the word
# "error". A restore that did nothing at all reported success.
# (No backticks in this comment: the heredoc is unquoted, so they would be
# command substitution executed on THIS side.)
RESTORE_TMP=\$(mktemp)
RESTORE_RC=0

# A VM restores from --archive; a container is CREATED from the backup as its
# template with --restore 1 (#729).
if [ "${GUEST_TYPE}" = "lxc" ]; then
  pvesh create /nodes/${TARGET_NODE}/lxc --vmid ${RESTORE_VMID} --ostemplate ${VOLID} --restore 1 --storage ${TARGET_STORAGE} --force 1 ${UNIQUE_OPT} > \$RESTORE_TMP 2>&1 || RESTORE_RC=\$?
elif [ -n "${TARGET_STORAGE}" ]; then
  pvesh create /nodes/${TARGET_NODE}/qemu --vmid ${RESTORE_VMID} --archive ${VOLID} --storage ${TARGET_STORAGE} --force 1 ${UNIQUE_OPT} > \$RESTORE_TMP 2>&1 || RESTORE_RC=\$?
else
  pvesh create /nodes/${TARGET_NODE}/qemu --vmid ${RESTORE_VMID} --archive ${VOLID} --force 1 ${UNIQUE_OPT} > \$RESTORE_TMP 2>&1 || RESTORE_RC=\$?
fi
cat \$RESTORE_TMP
if [ "\$RESTORE_RC" -ne 0 ]; then
  echo "RESTORE_FAILED_RC=\$RESTORE_RC"
fi

# Check for errors in restore output
if grep -qi "error\|timeout\|failed" \$RESTORE_TMP; then
  echo "RESTORE_ERRORS_DETECTED"
  if grep -qi "storage.*lock\|can't lock.*storage" \$RESTORE_TMP; then
    echo "STORAGE_LOCK_ERROR"
  fi
fi

rm -f \$RESTORE_TMP
EOF
)

# Check for errors. The rc marker is authoritative; the text grep below stays
# as a second net for the cases where pvesh reports trouble but exits 0.
if echo "$RESTORE_OUTPUT" | grep -q "RESTORE_FAILED_RC="; then
  echo "${RD}Error: the restore command failed${CL} ($(echo "$RESTORE_OUTPUT" | grep -o 'RESTORE_FAILED_RC=[0-9]*'))"
  echo "$RESTORE_OUTPUT" | grep -v RESTORE_FAILED_RC | tail -15
  echo
  echo "Nothing was restored into VMID ${RESTORE_VMID}."
  exit 1
fi
if echo "$RESTORE_OUTPUT" | grep -q "STORAGE_LOCK_ERROR"; then
  echo "${RD}Error: Storage lock timeout during restore${CL}"
  echo "The target storage '${TARGET_STORAGE}' is currently locked by another operation."
  echo ""
  echo "Solutions:"
  echo "  1. Wait a few minutes and try again"
  echo "  2. Try without --storage option to use original storage location"
  echo "  3. Choose a different target storage"
  echo ""
  echo "Note: VM ${RESTORE_VMID} was partially created but disks were not fully restored."
  echo "You may need to run: ssh root@${TARGET_NODE}.${ZONE}.internal ${CLI} destroy ${RESTORE_VMID}"
  exit 1
elif echo "$RESTORE_OUTPUT" | grep -q "RESTORE_ERRORS_DETECTED"; then
  echo "${RD}Error: Restore completed with errors${CL}"
  echo "Check the output above for details."
  echo "VM ${VMID} may not be fully functional."
  exit 1
fi

# Trust, then verify: ask Proxmox whether the guest is really there. A restore
# that reports success without producing a VM is the one failure mode a backup
# system must never have.
if ! ssh -n root@${TARGET_NODE}.${ZONE}.internal "${CLI} config ${RESTORE_VMID}" >/dev/null 2>&1; then
  echo "${RD}Error: restore reported success but VMID ${RESTORE_VMID} does not exist on ${TARGET_NODE}${CL}"
  exit 1
fi

# --replace: put the destination's identity back — name/hostname, onboot and its
# network devices with their MACs. The disks are the backup's; the guest is
# still the one the platform declared (DNS, DHCP reservation, firewall rules).
if [ "${REPLACE}" = true ]; then
  SET_ARGS=""
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    key="${line%%: *}"; val="${line#*: }"
    # Network devices come back with the carrier OFF. The disks are the source
    # guest's, so until cloud-init has given it this guest's hostname at first
    # boot, it asks DHCP for the SOURCE's name — and dnsmasq hands it over, taking
    # it from the original. That is how a §2 rehearsal put the production
    # openwebui's name, and its public site, on the restored copy (#729).
    case "${key}" in net[0-9]*) val="$(printf '%s' "${val}" | sed 's/,link_down=[01]//'),link_down=1" ;; esac
    SET_ARGS="${SET_ARGS} --${key} '${val}'"
  done <<< "${IDENTITY}"
  # A network device the SOURCE had and the destination did not would survive
  # as an undeclared NIC; drop it.
  EXTRA_NETS="$(ssh -n root@${TARGET_NODE}.${ZONE}.internal "${CLI} config ${RESTORE_VMID}" \
    | restore_identity_lines | grep -oE '^net[0-9]+' | grep -vxF -f <(printf '%s\n' "${IDENTITY}" | grep -oE '^net[0-9]+') || true)"
  [ -z "${EXTRA_NETS}" ] || SET_ARGS="${SET_ARGS} --delete $(echo ${EXTRA_NETS} | tr ' ' ',')"
  ssh -n root@${TARGET_NODE}.${ZONE}.internal "${CLI} set ${RESTORE_VMID}${SET_ARGS}" \
    || die "restored, but could not put ${RESTORE_VMID}'s identity back — set it by hand before starting it:\n${IDENTITY}"
  info "  ${GN}✓${CL} ${RESTORE_VMID} keeps its name, onboot and network devices (links DOWN until its hostname is checked)"
fi

# A copy beside its original must not start by itself: the backup carries the
# original's onboot, and the next reboot of the node would bring up a second
# guest of the same name (seen restoring vllm-amd beside itself, #729).
if [ -n "${TARGET_VMID}" ] && [ "${REPLACE}" != true ]; then
  ssh -n root@${TARGET_NODE}.${ZONE}.internal "${CLI} set ${RESTORE_VMID} --onboot 0" \
    || warn "could not set onboot 0 on ${RESTORE_VMID} — it would start at the next boot of ${TARGET_NODE}"
fi

# A container's host bind mounts (mpN: /path) are never in its backup: the
# restored config still names them, the data is wherever it was — or gone with
# the node it lived on. Say which, before anyone starts it.
if [ "${GUEST_TYPE}" = "lxc" ]; then
  BINDS="$(ssh -n root@${TARGET_NODE}.${ZONE}.internal "pct config ${RESTORE_VMID}" 2>/dev/null | restore_bind_mounts)"
  for b in ${BINDS}; do
    if ssh -n root@${TARGET_NODE}.${ZONE}.internal "test -e '${b}'" 2>/dev/null; then
      warn "bind mount ${b} is not in the backup — it exists on ${TARGET_NODE}, so the container sees what is there now"
    else
      warn "bind mount ${b} is not in the backup and does not exist on ${TARGET_NODE} — create or repopulate it before starting ${RESTORE_VMID}"
    fi
  done
fi

info "\n${GN}Restore completed successfully!${CL}"
echo
echo "${GUEST_TYPE} ${VMID} has been restored to ${TARGET_NODE} as VMID ${RESTORE_VMID}"
echo
if [ "${REPLACE}" = true ]; then
  N="root@${TARGET_NODE}.${ZONE}.internal"
  echo "It is STOPPED. It holds ${VMID}'s disks under ${RESTORE_VMID}'s own name and network"
  echo "identity, with its network links DOWN: inside, it is still ${VMID}'s system, and"
  echo "online it would ask DHCP for ${VMID}'s hostname and take that guest's DNS name."
  echo "In this order (RESTORE.md §2):"
  echo "  1. ssh ${N} ${CLI} start ${RESTORE_VMID}"
  if [ "${GUEST_TYPE}" = "lxc" ]; then
    echo "  2. ssh ${N} pct exec ${RESTORE_VMID} -- hostname            # must be this guest's name"
    echo "  3. ssh ${N} pct set ${RESTORE_VMID} --net0 '<same line, link_down=0>'"
  else
    echo "  2. Make DHCP ask for THIS guest's name. On a NixOS guest the static hostname is the"
    echo "     source's until step 4 rebuilds it, and NetworkManager sends the static one:"
    echo "       ssh ${N} qm guest exec ${RESTORE_VMID} -- nmcli c modify tappaas-ethernet ipv4.dhcp-hostname <name>"
    echo "  3. ssh ${N} qm set ${RESTORE_VMID} --net0 '<same line without link_down=1>'   # each netN"
    echo "     then check the SOURCE's DNS name still points at the source (dig <source>.<zone>.internal)"
    echo "  3b. Backup older than the last cicd-key.sh rotate? It trusts the old mothership key only:"
    echo "       cicd-key.sh recover    # installs the current key through the guest agent"
  fi
  echo "  4. module-manager module update <module>; module-manager module test <module> --deep"
  echo "The replace dropped it from HA, replication and the backup job (destroy --purge);"
  echo "step 4 puts them back. SSH host keys and certificates inside are still ${VMID}'s."
  exit 0
fi
if [ -n "${TARGET_VMID}" ]; then
  echo "It is STOPPED and has fresh MAC addresses. Starting a restored COPY on the"
  echo "same network as its original is how you get two guests answering for one"
  echo "identity — inspect it, then start it deliberately if that is what you want:"
  echo "  ssh root@${TARGET_NODE}.${ZONE}.internal ${CLI} start ${RESTORE_VMID}"
  echo "  ssh root@${TARGET_NODE}.${ZONE}.internal ${CLI} destroy ${RESTORE_VMID}   # when done"
  exit 0
fi
# --start/--no-start decide; otherwise ask — and with no terminal to ask on
# (#729 §3: the prompt read EOF), leave it stopped and say so.
START_VM="${START}"
if [ -z "${START_VM}" ] && [ -t 0 ]; then
  read -p "Do you want to start the VM now? (yes/no): " START_VM
fi
if [ "$START_VM" = "yes" ]; then
  info "Starting VM ${VMID}..."
  ssh root@${TARGET_NODE}.${ZONE}.internal "${CLI} start ${RESTORE_VMID}"
  echo "${GN}VM ${VMID} started successfully${CL}"
else
  echo "VM ${VMID} is ready but not started. Start it when ready (or restore with --start):"
  echo "  ssh root@${TARGET_NODE}.${ZONE}.internal ${CLI} start ${RESTORE_VMID}"
fi
