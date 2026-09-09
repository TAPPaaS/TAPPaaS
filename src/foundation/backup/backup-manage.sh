#!/usr/bin/env bash

# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# TAPPaaS Backup Management Script
# Provides utilities for managing PBS backups
#
# Usage: ./backup-manage.sh <command> [options]
#
# Commands:
#   list-jobs           List configured backup jobs
#   run-now <vmid>      Run immediate backup for a VM
#   verify <backup-id>  Verify backup integrity
#   prune              Run prune operation
#   gc                 Run garbage collection
#   status             Show PBS status
#   help               Show this help

function show_help() {
  cat << EOF
TAPPaaS Backup Management Script

Usage: $0 <command> [options]

Commands:
  list-jobs                   List all configured backup jobs
  run-now <vmid>              Run immediate backup for a specific VM
  run-now-all                 Run immediate backup for all VMs
  verify <backup-id>          Verify backup integrity
  prune                       Run prune operation on datastore
  gc                          Run garbage collection on datastore
  status                      Show PBS datastore status
  retention                   Show current retention policy

Multi-source datastore (issue #227):
  list-sources                List namespaces, buddies (remotes) and sync jobs
  add-remote <name>           Onboard a TAPPaaS buddy (pull) from remote-<name>.json
  remove-remote <name> [--purge]   Offboard a buddy (--purge also deletes its data)
  add-external <name>         Onboard a third-party push client from external-<name>.json
  remove-external <name> [--purge]  Offboard an external client (--purge deletes its data)
  add-push <name> [--make-default]  Register an off-site push target WE push to (push-<name>.json)
  remove-push <name>          Remove an off-site push target (local storage only; remote data untouched)

Externally-managed PBS (ADR-012 §1.3, #456):
  use-external <url> [--datastore <ds>] [--namespace <ns>] [--fingerprint <fp>]
                              Consume a PBS this site did NOT provision — on the LAN, at a
                              satellite, or a third party. Registers it as the module's backup
                              storage and records placementState=external + pbsUrl. Creates no
                              datastore and never touches what is already stored there.

  help                        Show this help message

Examples:
  # List backup jobs
  $0 list-jobs

  # Run immediate backup for VM 101
  $0 run-now 101

  # Backup all VMs immediately
  $0 run-now-all

  # Show PBS status
  $0 status

  # Run prune and garbage collection
  $0 prune && $0 gc

  # Adopt a PBS the site already runs on the LAN (#456)
  $0 use-external pbs.lan.example --datastore tappaas_backup
EOF
}

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  echo -e "\n${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}\n"
}

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

# Source common routines and load backup module config
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. /home/tappaas/bin/common-install-routines.sh
JSON_CONFIG="${CONFIG_DIR}/backup.json"
JSON=$(cat "${JSON_CONFIG}")

# The node PBS runs on. ADR-012 §2.1: the RESOLVED node is carried by the
# placement state (`placementState: node:<name>`); `.node` is only the operator's
# discovery constraint and may be empty, so it is a back-compat fallback.
PBS_NODE="$(jq -r '.placementState // empty' "${JSON_CONFIG}" 2>/dev/null | sed -n 's/^node://p')"
[[ -n "${PBS_NODE}" ]] || PBS_NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE="$(get_config_value 'zone0' 'mgmt')"
# PBS datastore / Proxmox storage name — configurable via backup.json (issue #199)
STORAGE_NAME="$(get_config_value 'pbsStorageName' 'tappaas_backup')"
DATASTORE_NAME="${STORAGE_NAME}"
MGMT_NODE="$(get_node_hostname 0)"

COMMAND="${1:-help}"

case "$COMMAND" in
  list-jobs)
    info "${BOLD}Configured backup jobs:${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "cat /etc/pve/vzdump.cron"
    echo
    info "${BOLD}Backup job history:${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "pvesh get /cluster/backup"
    ;;

  run-now)
    if [ -z "$2" ]; then
      echo "Error: VMID required"
      echo "Usage: $0 run-now <vmid>"
      exit 1
    fi
    VMID="$2"
    info "${BOLD}Running immediate backup for VM ${VMID}...${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "vzdump ${VMID} --storage ${STORAGE_NAME} --mode snapshot --compress zstd"
    info "${GN}Backup completed for VM ${VMID}${CL}"
    ;;

  run-now-all)
    info "${BOLD}Running immediate backup for all VMs...${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "vzdump --all 1 --storage ${STORAGE_NAME} --mode snapshot --compress zstd"
    info "${GN}Backup completed for all VMs${CL}"
    ;;

  verify)
    if [ -z "$2" ]; then
      echo "Error: Backup ID required"
      echo "Usage: $0 verify <backup-id>"
      exit 1
    fi
    BACKUP_ID="$2"
    info "${BOLD}Verifying backup ${BACKUP_ID}...${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-client verify ${BACKUP_ID}"
    ;;

  prune)
    info "${BOLD}Running prune operation on ${DATASTORE_NAME}...${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager datastore prune ${DATASTORE_NAME}"
    info "${GN}Prune operation completed${CL}"
    ;;

  gc)
    info "${BOLD}Running garbage collection on ${DATASTORE_NAME}...${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager garbage-collection start ${DATASTORE_NAME}"
    info "${GN}Garbage collection started${CL}"
    ;;

  status)
    info "${BOLD}PBS Datastore Status:${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager datastore list"
    echo
    info "${BOLD}Datastore Usage:${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "df -h | grep -E '(Filesystem|${DATASTORE_NAME})'"
    echo
    info "${BOLD}Recent Backups:${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "pvesh get /nodes/${MGMT_NODE}/storage/${STORAGE_NAME}/content" | head -20
    ;;

  retention)
    info "${BOLD}Current Retention Policy for ${DATASTORE_NAME}:${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager datastore list" | grep -A 10 "${DATASTORE_NAME}"
    ;;

  list-sources)
    info "${BOLD}Namespaces in ${DATASTORE_NAME}:${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-debug api get /admin/datastore/${DATASTORE_NAME}/namespace --output-format json" 2>/dev/null \
      | jq -r '.[].ns | if . == "" then "(root — local VM backups)" else . end'
    echo
    info "${BOLD}Buddies (remotes):${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager remote list" 2>/dev/null || true
    echo
    info "${BOLD}Sync jobs:${CL}"
    ssh root@${PBS_NODE}.${ZONE}.internal "proxmox-backup-manager sync-job list" 2>/dev/null || true
    echo
    info "${BOLD}Push targets (we push off-site — ADR-012 P4):${CL}"
    ssh root@${MGMT_NODE}.${ZONE}.internal "pvesm status" 2>/dev/null | awk 'NR==1 || $1 ~ /^offsite-/' || true
    ;;

  add-remote)
    [[ -n "${2:-}" ]] || die "Usage: $0 add-remote <name>"
    "${SCRIPT_DIR}/services/remote/install-service.sh" "$2"
    ;;

  remove-remote)
    [[ -n "${2:-}" ]] || die "Usage: $0 remove-remote <name> [--purge]"
    "${SCRIPT_DIR}/services/remote/delete-service.sh" "$2" "${3:-}"
    ;;

  add-external)
    [[ -n "${2:-}" ]] || die "Usage: $0 add-external <name>"
    "${SCRIPT_DIR}/services/external/install-service.sh" "$2"
    ;;

  remove-external)
    [[ -n "${2:-}" ]] || die "Usage: $0 remove-external <name> [--purge]"
    "${SCRIPT_DIR}/services/external/delete-service.sh" "$2" "${3:-}"
    ;;

  add-push)
    [[ -n "${2:-}" ]] || die "Usage: $0 add-push <name> [--make-default]"
    "${SCRIPT_DIR}/services/push/install-service.sh" "$2" "${3:-}"
    ;;

  remove-push)
    [[ -n "${2:-}" ]] || die "Usage: $0 remove-push <name>"
    "${SCRIPT_DIR}/services/push/delete-service.sh" "$2"
    ;;

  use-external)
    # Consume an externally-managed PBS (ADR-012 §1.3/§4.2, #456). Registers it
    # as the module's backup storage and flips placement to external — which is
    # PERMANENT, so it is refused where a local datastore would be orphaned.
    URL="${2:-}"
    [[ -n "${URL}" ]] || die "Usage: $0 use-external <url> [--datastore <ds>] [--namespace <ns>] [--fingerprint <fp>]"
    shift 2
    EXT_STORE=""; EXT_NS=""; EXT_FP=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --datastore)   EXT_STORE="${2:-}"; shift 2 ;;
        --namespace)   EXT_NS="${2:-}";    shift 2 ;;
        --fingerprint) EXT_FP="${2:-}";    shift 2 ;;
        *) die "use-external: unknown option '$1'" ;;
      esac
    done

    # shellcheck source=lib/pbs-storage.sh disable=SC1091
    . "${SCRIPT_DIR}/lib/pbs-storage.sh"
    # shellcheck source=lib/pbs-external.sh disable=SC1091
    . "${SCRIPT_DIR}/lib/pbs-external.sh"
    # shellcheck source=lib/pbs-placement.sh disable=SC1091
    . "${SCRIPT_DIR}/lib/pbs-placement.sh"
    # shellcheck source=lib/pbs-client.sh disable=SC1091
    . "${SCRIPT_DIR}/lib/pbs-client.sh"

    STATE="$(pbs_placement_state)"
    pbs_external_allowed "${STATE}" || die \
      "backup already has a local PBS (placementState '${STATE}'). Consuming an external PBS is permanent and would orphan that datastore — relocate it first (QUICKREF: relocation-by-pull), or reinstall the module deliberately."

    EXT_STORE="$(pbs_external_datastore "${EXT_STORE}" "$(get_config_value 'pbsStorageName' 'tappaas_backup')")"
    SNAME="$(get_config_value 'pbsStorageName' 'tappaas_backup')"

    # Credential: prompted, never stored in JSON (§2.5). It is the REMOTE that
    # issues it, scoped write-no-delete, and the REMOTE owns prune/retention.
    read -rp "  PBS auth id on ${URL} (e.g. tappaas@pbs): " EXT_USER
    [[ -n "${EXT_USER}" ]] || die "use-external: an auth id is required"
    read -rsp "  Password / API token secret for ${EXT_USER}: " EXT_PW; echo
    [[ -n "${EXT_PW}" ]] || die "use-external: a credential is required"

    pbs_external_register "${URL}" "${SNAME}" "${EXT_STORE}" "${EXT_NS}" \
                          "${EXT_USER}" "${EXT_PW}" "${EXT_FP}" "${ZONE}" \
      || die "use-external: could not register ${URL} as storage ${SNAME}"
    pbs_external_verify "${SNAME}" "${ZONE}" \
      || warn "  registered, but the storage did not verify — check the credential/fingerprint"

    # Record the placement LAST, so a failed registration leaves the config as
    # it was rather than claiming an external PBS that was never wired up.
    jq --arg u "${URL}" '.placementState = "external" | .pbsUrl = $u' \
       "${JSON_CONFIG}" > "${JSON_CONFIG}.tmp" && mv "${JSON_CONFIG}.tmp" "${JSON_CONFIG}"
    info "  ${GN}✓${CL} placementState=external, pbsUrl=${URL}"

    # Clients push to it exactly as to a local PBS (§1.4).
    pbs_client_reconcile "${ZONE}" "$(get_config_value 'imageLocation' 'http://download.proxmox.com/debian/pbs')" \
      || warn "One or more nodes could not be reconciled for proxmox-backup-client"
    info "${GN}Consuming the externally-managed PBS at ${URL}.${CL} Existing snapshots there were not touched."
    ;;

  help|--help|-h)
    show_help
    ;;

  *)
    echo "Unknown command: $COMMAND"
    echo
    show_help
    exit 1
    ;;
esac
