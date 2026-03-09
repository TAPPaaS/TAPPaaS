#!/usr/bin/env bash
#
# TAPPaaS OpenWebUI Application Data Restore
#
# Restores OpenWebUI application data (PostgreSQL, Redis, container data,
# env secrets) from backup files onto the target VM defined in openwebui.json.
#
# Two modes:
#   --from-instance <host>   Pull backups from another TAPPaaS OpenWebUI instance
#   --from-path <dir>        Use local backup files (any source)
#
# See RESTORE.md for full documentation.
#
# Usage: ./restore.sh --from-instance <host> | --from-path <dir> [--date YYYY-MM-DD]
# Example: ./restore.sh --from-instance openwebui-old.srv.internal
#          ./restore.sh --from-path /tmp/openwebui-backups
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Pre-load JSON config so common-install-routines.sh doesn't interpret
# our --flags as a module name
JSON_CONFIG="/home/tappaas/config/openwebui.json"
JSON=$(cat "${JSON_CONFIG}")

# shellcheck source=../../foundation/tappaas-cicd/scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ─────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' 'openwebui')"
VMID="$(get_config_value 'vmid')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
readonly VMNAME VMID ZONE0NAME

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# Backup file patterns (must match naming in openwebui.nix)
readonly PG_PATTERN="openwebui-pg-*.sql.gz"
readonly REDIS_PATTERN="openwebui-redis-*.rdb"
readonly DATA_PATTERN="openwebui-data-*.tar.gz"
readonly ENV_PATTERN="openwebui-env-*.tar.gz"

# Remote backup paths on a TAPPaaS instance
readonly REMOTE_PG_DIR="/var/backup/postgresql"
readonly REMOTE_REDIS_DIR="/var/backup/redis"
readonly REMOTE_DATA_DIR="/var/backup/openwebui-data"
readonly REMOTE_ENV_DIR="/var/backup/openwebui-env"

# ── Variables ─────────────────────────────────────────────────────────

FROM_INSTANCE=""
FROM_PATH=""
BACKUP_DATE=""
STAGING_DIR=""

# ── Helper functions ──────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} --from-instance <host> | --from-path <dir> [OPTIONS]

Restore OpenWebUI application data onto ${VM_HOST}.

Source (one required):
    --from-instance <host>   Pull latest backups from another TAPPaaS OpenWebUI VM
    --from-path <dir>        Use backup files from a local directory

Options:
    --date YYYY-MM-DD        Use backups from a specific date (default: latest)
    -h, --help               Show this help message

Expected files in --from-path directory:
    ${PG_PATTERN}            PostgreSQL dump
    ${REDIS_PATTERN}         Redis RDB snapshot
    ${DATA_PATTERN}          Container data (uploads, models)
    ${ENV_PATTERN}           Environment secrets

Examples:
    # Restore from another TAPPaaS instance
    ${SCRIPT_NAME} --from-instance openwebui-old.srv.internal

    # Restore from local backup files
    ${SCRIPT_NAME} --from-path /tmp/openwebui-backups

    # Restore specific date from another instance
    ${SCRIPT_NAME} --from-instance openwebui-old.srv.internal --date 2026-03-09
EOF
}

cleanup() {
    if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
        info "Cleaning up staging directory"
        # Safe: STAGING_DIR is always created by mktemp in /tmp/openwebui-restore-*
        rm -rf "${STAGING_DIR}"  # shellcheck disable=SC2115
    fi
}

trap cleanup EXIT

die() {
    error "$1"
    exit 1
}

# Find the latest (or date-specific) backup file matching a pattern in a directory
find_backup_file() {
    local dir="$1"
    local pattern="$2"
    local date_filter="${3:-}"

    if [[ -n "${date_filter}" ]]; then
        # Replace * in pattern with the specific date
        local specific
        specific=$(echo "${pattern}" | sed "s/\*/${date_filter}/")
        if [[ -f "${dir}/${specific}" ]]; then
            echo "${dir}/${specific}"
            return 0
        fi
        return 1
    fi

    # Find latest file matching pattern
    local latest
    latest=$(find "${dir}" -maxdepth 1 -name "${pattern}" -type f 2>/dev/null | sort -r | head -1)
    if [[ -n "${latest}" ]]; then
        echo "${latest}"
        return 0
    fi
    return 1
}

# ── Fetch backups from remote TAPPaaS instance ────────────────────────

fetch_from_instance() {
    local source_host="$1"
    local date_filter="${2:-}"

    info "Fetching backups from ${source_host}..."

    STAGING_DIR=$(mktemp -d /tmp/openwebui-restore-XXXXXX)

    if [[ -z "${date_filter}" ]]; then
        info "No date specified — using latest backups"
    fi

    # Find and copy each backup type from the remote instance
    local ssh_source="tappaas@${source_host}"

    # PostgreSQL
    info "  Fetching PostgreSQL backup..."
    local pg_file
    # shellcheck disable=SC2086
    pg_file=$(ssh ${SSH_OPTS} "${ssh_source}" \
        "sudo find ${REMOTE_PG_DIR} -maxdepth 1 -name '${PG_PATTERN}' -type f 2>/dev/null | sort -r | head -1") || true
    if [[ -n "${date_filter}" ]]; then
        # shellcheck disable=SC2086
        pg_file=$(ssh ${SSH_OPTS} "${ssh_source}" \
            "sudo find ${REMOTE_PG_DIR} -maxdepth 1 -name 'openwebui-pg-${date_filter}.sql.gz' -type f 2>/dev/null") || true
    fi
    [[ -n "${pg_file}" ]] || die "PostgreSQL backup not found on ${source_host}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${ssh_source}" "sudo cat ${pg_file}" > "${STAGING_DIR}/$(basename "${pg_file}")"
    info "  Found: $(basename "${pg_file}")"

    # Redis
    info "  Fetching Redis backup..."
    local redis_file
    # shellcheck disable=SC2086
    redis_file=$(ssh ${SSH_OPTS} "${ssh_source}" \
        "sudo find ${REMOTE_REDIS_DIR} -maxdepth 1 -name '${REDIS_PATTERN}' -type f 2>/dev/null | sort -r | head -1") || true
    if [[ -n "${date_filter}" ]]; then
        # shellcheck disable=SC2086
        redis_file=$(ssh ${SSH_OPTS} "${ssh_source}" \
            "sudo find ${REMOTE_REDIS_DIR} -maxdepth 1 -name 'openwebui-redis-${date_filter}.rdb' -type f 2>/dev/null") || true
    fi
    [[ -n "${redis_file}" ]] || die "Redis backup not found on ${source_host}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${ssh_source}" "sudo cat ${redis_file}" > "${STAGING_DIR}/$(basename "${redis_file}")"
    info "  Found: $(basename "${redis_file}")"

    # Container data
    info "  Fetching container data backup..."
    local data_file
    # shellcheck disable=SC2086
    data_file=$(ssh ${SSH_OPTS} "${ssh_source}" \
        "sudo find ${REMOTE_DATA_DIR} -maxdepth 1 -name '${DATA_PATTERN}' -type f 2>/dev/null | sort -r | head -1") || true
    if [[ -n "${date_filter}" ]]; then
        # shellcheck disable=SC2086
        data_file=$(ssh ${SSH_OPTS} "${ssh_source}" \
            "sudo find ${REMOTE_DATA_DIR} -maxdepth 1 -name 'openwebui-data-${date_filter}.tar.gz' -type f 2>/dev/null") || true
    fi
    [[ -n "${data_file}" ]] || die "Container data backup not found on ${source_host}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${ssh_source}" "sudo cat ${data_file}" > "${STAGING_DIR}/$(basename "${data_file}")"
    info "  Found: $(basename "${data_file}") ($(du -h "${STAGING_DIR}/$(basename "${data_file}")" | cut -f1))"

    # Env secrets
    info "  Fetching env secrets backup..."
    local env_file
    # shellcheck disable=SC2086
    env_file=$(ssh ${SSH_OPTS} "${ssh_source}" \
        "sudo find ${REMOTE_ENV_DIR} -maxdepth 1 -name '${ENV_PATTERN}' -type f 2>/dev/null | sort -r | head -1") || true
    if [[ -n "${date_filter}" ]]; then
        # shellcheck disable=SC2086
        env_file=$(ssh ${SSH_OPTS} "${ssh_source}" \
            "sudo find ${REMOTE_ENV_DIR} -maxdepth 1 -name 'openwebui-env-${date_filter}.tar.gz' -type f 2>/dev/null") || true
    fi
    [[ -n "${env_file}" ]] || die "Env secrets backup not found on ${source_host}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${ssh_source}" "sudo cat ${env_file}" > "${STAGING_DIR}/$(basename "${env_file}")"
    info "  Found: $(basename "${env_file}")"

    info "All backups fetched to ${STAGING_DIR}"
    FROM_PATH="${STAGING_DIR}"
}

# ── Restore functions ─────────────────────────────────────────────────

restore_postgresql() {
    local pg_file="$1"
    info "Restoring PostgreSQL from $(basename "${pg_file}")..."

    # Copy to target
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "sudo tee /tmp/pg-restore.sql.gz > /dev/null" < "${pg_file}"

    # Terminate active connections, drop and recreate database, then import
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "
        sudo -u postgres psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='openwebui' AND pid <> pg_backend_pid();\" postgres
        sudo -u postgres dropdb --if-exists openwebui
        sudo -u postgres createdb -O openwebui openwebui
        gunzip -c /tmp/pg-restore.sql.gz | sudo -u postgres psql -q openwebui
        sudo rm -f /tmp/pg-restore.sql.gz
    "
    info "  PostgreSQL restored"
}

restore_redis() {
    local redis_file="$1"
    info "Restoring Redis from $(basename "${redis_file}")..."

    # Copy to target
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "sudo tee /tmp/redis-restore.rdb > /dev/null" < "${redis_file}"

    # Stop Redis, replace dump, fix ownership, start Redis
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "
        sudo systemctl stop redis-openwebui
        sudo cp /tmp/redis-restore.rdb /var/lib/redis-openwebui/dump.rdb
        sudo chown redis:redis /var/lib/redis-openwebui/dump.rdb
        sudo chmod 600 /var/lib/redis-openwebui/dump.rdb
        sudo systemctl start redis-openwebui
        sudo rm -f /tmp/redis-restore.rdb
    "
    info "  Redis restored"
}

restore_data() {
    local data_file="$1"
    info "Restoring container data from $(basename "${data_file}") (this may take a while)..."

    # Copy to target
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "sudo tee /tmp/data-restore.tar.gz > /dev/null" < "${data_file}"

    # Extract over existing data
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "
        sudo tar -xzf /tmp/data-restore.tar.gz -C /
        sudo rm -f /tmp/data-restore.tar.gz
    "
    info "  Container data restored"
}

restore_env() {
    local env_file="$1"
    info "Restoring env secrets from $(basename "${env_file}")..."

    # Copy to target
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "sudo tee /tmp/env-restore.tar.gz > /dev/null" < "${env_file}"

    # Extract over existing secrets
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "
        sudo tar -xzf /tmp/env-restore.tar.gz -C /
        sudo rm -f /tmp/env-restore.tar.gz
    "
    info "  Env secrets restored"
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-instance)
                FROM_INSTANCE="${2:-}"
                [[ -n "${FROM_INSTANCE}" ]] || die "--from-instance requires a hostname"
                shift 2
                ;;
            --from-path)
                FROM_PATH="${2:-}"
                [[ -n "${FROM_PATH}" ]] || die "--from-path requires a directory"
                shift 2
                ;;
            --date)
                BACKUP_DATE="${2:-}"
                [[ -n "${BACKUP_DATE}" ]] || die "--date requires YYYY-MM-DD"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    # Validate: exactly one source
    if [[ -z "${FROM_INSTANCE}" && -z "${FROM_PATH}" ]]; then
        error "Must specify --from-instance or --from-path"
        usage
        exit 1
    fi
    if [[ -n "${FROM_INSTANCE}" && -n "${FROM_PATH}" ]]; then
        die "Cannot use both --from-instance and --from-path"
    fi

    echo ""
    info "=== OpenWebUI Application Data Restore ==="
    info "Target: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"

    # Fetch from remote instance if needed
    if [[ -n "${FROM_INSTANCE}" ]]; then
        info "Source: ${FROM_INSTANCE}"
        fetch_from_instance "${FROM_INSTANCE}" "${BACKUP_DATE}"
    else
        info "Source: ${FROM_PATH}"
    fi

    # Validate backup directory
    [[ -d "${FROM_PATH}" ]] || die "Backup directory not found: ${FROM_PATH}"

    # Locate all 4 backup files
    local pg_file redis_file data_file env_file
    pg_file=$(find_backup_file "${FROM_PATH}" "${PG_PATTERN}" "${BACKUP_DATE}") \
        || die "PostgreSQL backup not found in ${FROM_PATH} (expected: ${PG_PATTERN})"
    redis_file=$(find_backup_file "${FROM_PATH}" "${REDIS_PATTERN}" "${BACKUP_DATE}") \
        || die "Redis backup not found in ${FROM_PATH} (expected: ${REDIS_PATTERN})"
    data_file=$(find_backup_file "${FROM_PATH}" "${DATA_PATTERN}" "${BACKUP_DATE}") \
        || die "Container data backup not found in ${FROM_PATH} (expected: ${DATA_PATTERN})"
    env_file=$(find_backup_file "${FROM_PATH}" "${ENV_PATTERN}" "${BACKUP_DATE}") \
        || die "Env secrets backup not found in ${FROM_PATH} (expected: ${ENV_PATTERN})"

    info ""
    info "Backup files found:"
    info "  PostgreSQL:     $(basename "${pg_file}")"
    info "  Redis:          $(basename "${redis_file}")"
    info "  Container data: $(basename "${data_file}")"
    info "  Env secrets:    $(basename "${env_file}")"

    # Stop OpenWebUI container before restore
    info ""
    info "Step 1: Stop OpenWebUI container"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "sudo podman stop openwebui" 2>/dev/null || true
    info "  Container stopped"

    # Restore in order: PostgreSQL → Redis → Data → Env
    info ""
    info "Step 2: Restore application data"
    restore_postgresql "${pg_file}"
    restore_redis "${redis_file}"
    restore_data "${data_file}"
    restore_env "${env_file}"

    # Start OpenWebUI container
    info ""
    info "Step 3: Start OpenWebUI container"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "sudo podman start openwebui"
    info "  Container started"

    # Run health checks
    info ""
    info "Step 4: Verify restore"
    if "${SCRIPT_DIR}/test.sh" "${VMNAME}"; then
        info "Health checks passed — restore confirmed successful"
    else
        error "Health checks FAILED after restore — investigate manually"
        exit 1
    fi

    echo ""
    info "=== Restore Complete ==="
}

main "$@"
