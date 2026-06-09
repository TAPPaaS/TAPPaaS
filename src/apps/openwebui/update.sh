#!/usr/bin/env bash
#
# TAPPaaS OpenWebUI Module Update
#
# Post-rebuild steps for the OpenWebUI module. Called after update-os.sh
# has applied nixos-rebuild switch and the VM has rebooted.
#
# Runs health checks to verify the upgrade succeeded, then prunes
# unused container images. If health checks fail, old images are
# preserved for rollback.
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh openwebui
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../../foundation/tappaas-cicd/scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ─────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"
readonly VMNAME VMID NODE ZONE0NAME HANODE

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

# SSH options: accept changed host keys after reboot, hard timeout, no interactive prompts
readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# ── Helper functions ──────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname>

Post-rebuild update steps for OpenWebUI module.

Arguments:
    vmname    Name of the VM (must have config in /home/tappaas/config/)

Examples:
    ${SCRIPT_NAME} openwebui
EOF
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    echo ""
    info "=== OpenWebUI Post-Update ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"

    # ── Step 1: PostgreSQL version migration (if needed) ─────────────
    info ""
    info "Step 1: Check for PostgreSQL version migration"

    # shellcheck disable=SC2086
    local pg_migration_result
    pg_migration_result=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" bash << 'REMOTE'
        set -euo pipefail

        CURRENT_VER=$(sudo -u postgres psql --version 2>/dev/null | grep -oP '\d+(?=\.\d+)' | head -1)
        OLD_DIRS=$(sudo find /var/lib/postgresql -mindepth 1 -maxdepth 1 -type d \
            ! -name "${CURRENT_VER}" 2>/dev/null | sort -V)

        if [[ -z "${OLD_DIRS}" ]]; then
            echo "NO_MIGRATION_NEEDED"; exit 0
        fi

        USER_COUNT=$(sudo -u postgres psql -d openwebui -tAc \
            "SELECT COUNT(*) FROM auth;" 2>/dev/null || echo "0")
        CHAT_COUNT=$(sudo -u postgres psql -d openwebui -tAc \
            "SELECT COUNT(*) FROM chat;" 2>/dev/null || echo "0")

        if [[ "${USER_COUNT}" -gt 0 || "${CHAT_COUNT}" -gt 0 ]]; then
            echo "DATA_ALREADY_PRESENT:users=${USER_COUNT},chats=${CHAT_COUNT}"; exit 0
        fi

        OLD_VER=$(echo "${OLD_DIRS}" | tail -1 | xargs basename)
        OLD_DATA="/var/lib/postgresql/${OLD_VER}"
        OLD_PG=$(find /nix/store -name 'pg_ctl' -path "*postgresql-${OLD_VER}*" 2>/dev/null \
            | head -1 | xargs dirname 2>/dev/null)

        if [[ -z "${OLD_PG}" ]]; then
            echo "ERROR:pg${OLD_VER}_binary_not_found"; exit 0
        fi

        echo "MIGRATING:pg${OLD_VER}→pg${CURRENT_VER}"

        # Start old PG temporarily, dump live data, restore into new PG
        sudo rm -f "${OLD_DATA}/postmaster.pid"
        sudo -u postgres "${OLD_PG}/pg_ctl" start \
            -D "${OLD_DATA}" -o "-p 5498 -k /tmp" -l /tmp/pg-migration.log
        sleep 3
        sudo -u postgres "${OLD_PG}/pg_dump" -h /tmp -p 5498 -d openwebui \
            | sudo -u postgres psql -d openwebui -q 2>&1 | grep -c "^ERROR" || true
        sudo -u postgres "${OLD_PG}/pg_ctl" stop -D "${OLD_DATA}" -m fast

        NEW_USERS=$(sudo -u postgres psql -d openwebui -tAc "SELECT COUNT(*) FROM auth;")
        NEW_CHATS=$(sudo -u postgres psql -d openwebui -tAc "SELECT COUNT(*) FROM chat;")
        echo "MIGRATED:users=${NEW_USERS},chats=${NEW_CHATS}"
REMOTE
    )

    case "${pg_migration_result}" in
        NO_MIGRATION_NEEDED)
            info "  No PostgreSQL migration needed"
            ;;
        DATA_ALREADY_PRESENT:*)
            info "  PostgreSQL already has data (${pg_migration_result#*:}) — skipping migration"
            ;;
        MIGRATING:*)
            info "  ${pg_migration_result}"
            ;;
        MIGRATED:*)
            info "  Migration complete: ${pg_migration_result#*:}"
            ;;
        ERROR:*)
            warn "  Migration warning: ${pg_migration_result#*:}"
            ;;
        *)
            warn "  Unexpected migration status: ${pg_migration_result}"
            ;;
    esac

    # ── Step 2: Run health checks ─────────────────────────────────────
    info ""
    info "Step 2: Verify upgrade health"

    if "${SCRIPT_DIR}/test.sh" "${VMNAME}"; then
        info "Health checks passed — upgrade confirmed healthy"
    else
        error "Health checks FAILED — skipping image prune to preserve rollback capability"
        error "Old container images retained on ${VM_HOST}"
        exit 1
    fi

    # ── Step 3: Prune unused container images ─────────────────────────
    info ""
    info "Step 3: Prune unused container images"

    local prune_output
    # shellcheck disable=SC2086
    prune_output=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "sudo podman image prune -a -f" 2>&1) || true

    if [[ -n "${prune_output}" ]]; then
        info "Pruned images:"
        echo "${prune_output}" | while IFS= read -r line; do
            info "  ${line}"
        done
    else
        info "No unused images to prune"
    fi

    # ── Done ──────────────────────────────────────────────────────────
    echo ""
    info "=== Update Complete ==="
    info "VM: ${VMNAME} (VMID: ${VMID})"
    info "Node: ${NODE}"
    info "Zone: ${ZONE0NAME}"
    if [[ -n "${HANODE}" ]]; then
        info "HA Node: ${HANODE}"
    fi
}

main "$@"
