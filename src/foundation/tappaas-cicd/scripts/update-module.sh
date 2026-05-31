#!/usr/bin/env bash
#
# TAPPaaS Module Updater with Dependency Management
#
# Updates a TAPPaaS module safely: snapshots the VM, runs pre-update
# tests, performs the update, then verifies with post-update tests.
# Rolls back automatically on fatal post-update failure.
#
# Usage: update-module.sh [options] <module-name>
#
# Arguments:
#   module-name   Name of the module to update (must have a
#                 <module-name>.json in /home/tappaas/config/)
#
# Options:
#   -h, --help       Show this help message
#   --force          Proceed even if pre-update test fails
#   --no-snapshot    Skip pre-update test, snapshot, and rollback
#   --debug          Show Debug-level messages
#   --silent         Suppress Info-level messages
#
# Exit codes:
#   0  Update succeeded, all tests passed
#   1  Update completed but post-update test failed (non-fatal)
#   2  Fatal error (rollback attempted if snapshot exists)
#
# Examples:
#   update-module.sh vaultwarden
#   update-module.sh --force litellm
#   update-module.sh --no-snapshot nextcloud
#   update-module.sh --debug openwebui
#
# The script performs these steps:
#   1. Create pre-update VM snapshot
#   2. Run pre-update tests (test-module.sh)
#   3. Run pre-update.sh hook (if present)
#   4. Call dependency update-service.sh scripts
#   5. Run module update.sh
#   6. Run post-update tests (rollback on fatal failure)
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="/home/tappaas/config"

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Options ──────────────────────────────────────────────────────────

OPT_FORCE=0
OPT_NO_SNAPSHOT=0

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [options] <module-name>

Update a TAPPaaS module with snapshot, testing, and rollback support.

Arguments:
    module-name    Name of the module (must have config in ${CONFIG_DIR}/)

Options:
    -h, --help        Show this help message
    --force           Proceed even if pre-update test fails
    --no-snapshot     Skip pre-update test, snapshot, and rollback
    --debug           Show Debug-level messages
    --silent          Suppress Info-level messages

Exit codes:
    0  Update succeeded, all tests passed
    1  Update completed but post-update test failed (non-fatal)
    2  Fatal error (rollback attempted if snapshot exists)

Examples:
    ${SCRIPT_NAME} vaultwarden
    ${SCRIPT_NAME} --force litellm
    ${SCRIPT_NAME} --no-snapshot nextcloud
    ${SCRIPT_NAME} --debug openwebui
EOF
}

# ── Helpers ──────────────────────────────────────────────────────────

# Update the module JSON: set updateTime and re-render in canonical Pattern A.
# Field reordering is now handled by regroup_to_pattern_a (called inside
# jq_module_write), so the explicit reorder step is no longer needed (#207).
finalize_config() {
    local module="$1"

    # Set updateTime (local time, YYYYMMDD-HH:MM:SS). Pattern A-aware write.
    local update_time
    update_time=$(date +'%Y%m%d-%H:%M:%S')
    if jq_module_write "${module}" '.updateTime = $t' --arg t "${update_time}"; then
        info "  Set updateTime = ${update_time}"
    else
        warn "Could not set updateTime"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local module=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)   usage; exit 0 ;;
            --force)        OPT_FORCE=1; shift ;;
            --no-snapshot)  OPT_NO_SNAPSHOT=1; shift ;;
            --debug)        OPT_DEBUG=1; export TAPPAAS_DEBUG=1; shift ;;
            --silent)    OPT_SILENT=1; export TAPPAAS_SILENT=1; shift ;;
            -*)          fatal "Unknown option: $1"; usage; exit 2 ;;
            *)
                if [[ -z "${module}" ]]; then
                    module="$1"
                else
                    fatal "Unexpected argument: $1"
                    usage
                    exit 2
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${module}" ]]; then
        fatal "Module name is required"
        usage
        exit 2
    fi

    local module_json="${CONFIG_DIR}/${module}.json"

    # Quick sanity check — config must exist
    if [[ ! -f "${module_json}" ]]; then
        fatal "Module config not found: ${module_json} — is the module installed?"
        exit 2
    fi

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Module Update: ${BL}${module}${CL}"
    if [[ "${OPT_FORCE}" -eq 1 ]]; then
        info "${BOLD}║  Mode: ${YW}--force${CL}"
    fi
    if [[ "${OPT_NO_SNAPSHOT}" -eq 1 ]]; then
        info "${BOLD}║  Mode: ${YW}--no-snapshot${CL}"
    fi
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 0: 3-way merge module config against new release source (#207) ──
    # Reconciles operator customizations with release updates BEFORE we
    # snapshot or run hooks, so the snapshot and all hooks see the merged
    # config. Per-leaf rule: adopt release for fields the operator hasn't
    # touched; pin fields the operator has customized. .orig advances to the
    # current release. If .orig is missing (pre-#207 install) we backfill it
    # from source so existing customizations remain pinned.
    echo ""
    info "${BOLD}Step 0: Reconcile module config (3-way merge)${CL}"
    if module_dir_pre=$(get_module_dir "${module}" 2>/dev/null); then
        if [[ -f /home/tappaas/bin/apply-json-merge.sh ]]; then
            # shellcheck disable=SC1091
            . /home/tappaas/bin/apply-json-merge.sh
            if apply_three_way_merge "${module}" "${module_dir_pre}"; then
                info "  ${GN}✓${CL} Config reconciliation complete"
            else
                warn "  3-way merge reported an error — continuing with current config unchanged"
            fi
        else
            warn "  apply-json-merge.sh not available — skipping 3-way merge"
        fi
    else
        info "  Module location not resolved — skipping (first-update before location was set)"
    fi

    # ── Step 1: Pre-update snapshot (only for modules with a VM) ─────
    echo ""
    info "${BOLD}Step 1: Create pre-update snapshot${CL}"

    local snapshot_created=false
    local has_vm=false
    if read_module_config "${module}" | jq -e '.dependsOn // [] | index("cluster:vm")' &>/dev/null; then
        has_vm=true
    fi

    if [[ "${OPT_NO_SNAPSHOT}" -eq 1 ]]; then
        info "  Skipped (--no-snapshot)"
    elif [[ "${has_vm}" == true ]]; then
        if /home/tappaas/bin/snapshot-vm.sh "${module}"; then
            info "  ${GN}✓${CL} Snapshot created"
            snapshot_created=true
        else
            warn "Snapshot failed — continuing without rollback safety net"
        fi
    else
        info "  Skipped (module has no VM)"
    fi

    # ── Step 2: Pre-update test ───────────────────────────────────────
    echo ""
    info "${BOLD}Step 2: Run pre-update tests${CL}"

    if [[ "${OPT_NO_SNAPSHOT}" -eq 1 ]]; then
        info "  Skipped (--no-snapshot)"
    else
        local pre_test_exit=0
        /home/tappaas/bin/test-module.sh "${module}" || pre_test_exit=$?

        if [[ "${pre_test_exit}" -eq 0 ]]; then
            info "  ${GN}✓${CL} Pre-update tests passed"
        elif [[ "${OPT_FORCE}" -eq 1 ]]; then
            warn "Pre-update tests failed (exit ${pre_test_exit}) — continuing due to --force"
        else
            fatal "Pre-update tests failed (exit ${pre_test_exit}) — aborting update"
            error "  Use --force to override"
            exit 2
        fi
    fi

    # ── Step 3: Run pre-update.sh if present ─────────────────────────
    echo ""
    info "${BOLD}Step 3: Run pre-update hook${CL}"

    local module_dir=""
    if module_dir=$(get_module_dir "${module}" 2>/dev/null); then
        ensure_scripts_executable "${module_dir}"
        if [[ -x "${module_dir}/pre-update.sh" ]]; then
            info "  Running ${module_dir}/pre-update.sh..."
            cd "${module_dir}"
            if ./pre-update.sh "${module}"; then
                info "  ${GN}✓${CL} pre-update.sh completed"
            else
                fatal "Module pre-update.sh failed"
                exit 2
            fi
        else
            info "  No pre-update.sh found — skipping"
        fi
    else
        info "  Module location not set — skipping"
    fi

    # ── Step 4: Call dependency update-service.sh scripts ─────────────
    echo ""
    info "${BOLD}Step 4: Call dependency service updaters${CL}"

    local depends_on
    depends_on=$(read_module_config "${module}" | jq -r '.dependsOn // [] | .[]' 2>/dev/null)

    if [[ -z "${depends_on}" ]]; then
        info "  No dependency services to call"
    else
        # cd to the module directory so service scripts can find module files
        if [[ -n "${module_dir}" ]]; then
            cd "${module_dir}"
        fi

        for dep in ${depends_on}; do
            local provider_module="${dep%%:*}"
            local service_name="${dep##*:}"
            local provider_dir

            if ! provider_dir=$(get_module_dir "${provider_module}" 2>/dev/null); then
                fatal "Cannot find provider module '${provider_module}' for dependency '${dep}'"
                exit 2
            fi

            ensure_scripts_executable "${provider_dir}"
            local svc_script="${provider_dir}/services/${service_name}/update-service.sh"

            if [[ ! -x "${svc_script}" ]]; then
                fatal "Missing update-service.sh for dependency '${dep}': ${svc_script}"
                exit 2
            fi

            info "  Calling ${BL}${dep}${CL} update-service.sh for module '${module}'..."
            if "${svc_script}" "${module}"; then
                info "  ${GN}✓${CL} ${dep} update-service completed"
            else
                fatal "Service updater failed: ${dep}"
                exit 2
            fi
        done
    fi

    # ── Step 5: Call the module's own update.sh ───────────────────────
    echo ""
    info "${BOLD}Step 5: Run module update.sh${CL}"

    if [[ -n "${module_dir}" ]]; then
        if [[ -x "${module_dir}/update.sh" ]]; then
            info "  Running ${module_dir}/update.sh..."
            cd "${module_dir}"
            if ./update.sh "${module}"; then
                info "  ${GN}✓${CL} Module update.sh completed"
            else
                fatal "Module update.sh failed"
                exit 2
            fi
        else
            info "  No executable update.sh found — skipping"
        fi
    else
        warn "Cannot find module directory for '${module}' — skipping update.sh"
    fi

    # ── Step 6: Post-update test ──────────────────────────────────────
    echo ""
    info "${BOLD}Step 6: Run post-update tests${CL}"

    local post_test_exit=0
    /home/tappaas/bin/test-module.sh "${module}" || post_test_exit=$?

    if [[ "${post_test_exit}" -eq 0 ]]; then
        info "  ${GN}✓${CL} Post-update tests passed"
    elif [[ "${post_test_exit}" -eq 2 ]]; then
        # Fatal test failure — attempt rollback (unless --no-snapshot)
        fatal "Post-update tests reported a fatal error"
        if [[ "${OPT_NO_SNAPSHOT}" -eq 1 ]]; then
            warn "Rollback skipped (--no-snapshot) — manual intervention required"
            finalize_config "${module}"
            exit 2
        elif [[ "${snapshot_created}" == true ]]; then
            echo ""
            warn "Attempting rollback to pre-update snapshot..."
            if /home/tappaas/bin/snapshot-vm.sh "${module}" --restore 1; then
                info "  ${GN}✓${CL} Rollback completed — VM restored to pre-update state"
                # Re-test after rollback
                info "  Running post-rollback verification..."
                local rollback_test_exit=0
                /home/tappaas/bin/test-module.sh "${module}" || rollback_test_exit=$?
                if [[ "${rollback_test_exit}" -eq 0 ]]; then
                    info "  ${GN}✓${CL} Post-rollback tests passed — module is back to working state"
                else
                    fatal "Post-rollback tests also failed (exit ${rollback_test_exit})"
                fi
            else
                fatal "Rollback failed — manual intervention required"
            fi
        else
            error "  No snapshot available for rollback — manual intervention required"
        fi
        exit 2
    else
        # Non-fatal test failure — warn but don't rollback
        warn "Post-update tests failed (exit ${post_test_exit}) — update completed but module may have issues"
        finalize_config "${module}"
        exit 1
    fi

    # ── Success ───────────────────────────────────────────────────────
    finalize_config "${module}"

    echo ""
    info "${GN}${BOLD}Module '${module}' updated successfully${CL}"
}

main "$@"
