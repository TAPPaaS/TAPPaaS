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
#   7. On success, prune old snapshots to tappaas.snapshotRetention (#353)
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

# Roll back to the pre-update snapshot after a fatal failure (#307). Mirrors the
# post-update-test fatal handling so that ANY mutating step — the pre-update
# hook, the dependency updaters, the module's own update.sh, or the post-update
# test — recovers the same way instead of leaving a half-updated module. The VM
# is reachable for the restore via the node FQDNs pinned in the cicd's
# /etc/hosts (networking.hosts in tappaas-cicd.nix), so rollback works even when
# a firewall update has taken DNS down. Does NOT exit — the caller exits.
# Args: <module> <snapshot_created: true|false>
attempt_rollback() {
    local module="$1" snap_created="$2"
    if [[ "${OPT_NO_SNAPSHOT}" -eq 1 ]]; then
        warn "Rollback skipped (--no-snapshot) — manual intervention required"
        finalize_config "${module}"
        return
    fi
    if [[ "${snap_created}" == true ]]; then
        echo ""
        warn "Attempting rollback to pre-update snapshot..."
        if /home/tappaas/bin/snapshot-vm.sh "${module}" --restore 1; then
            info "  ${GN}✓${CL} Rollback completed — VM restored to pre-update state"
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
}

# fatal() + rollback + exit 2, for any failure AFTER the pre-update snapshot
# (#307). Use at every post-snapshot fatal exit so a broken update is rolled
# back rather than left in place.
# Args: <module> <snapshot_created> <message>
fatal_with_rollback() {
    local module="$1" snap_created="$2" message="$3"
    fatal "${message}"
    attempt_rollback "${module}" "${snap_created}"
    exit 2
}

# Prune old pre-update snapshots down to tappaas.snapshotRetention (#353). Every
# update creates a snapshot (Step 1) but nothing pruned them, so per-VM chains
# grew without bound (observed on vm:130). Runs only on the success paths — never
# after a rollback, which wants the history kept — and only when this run
# actually created a snapshot. Best-effort: a cleanup failure is a warning, not
# fatal, so it can never fail an otherwise-successful update. snapshot-vm.sh
# --cleanup keeps the newest N, so this run's snapshot (and --restore 1) is safe.
# Args: <module> <snapshot_created: true|false>
prune_snapshots() {
    local module="$1" snap_created="$2"
    [[ "${snap_created}" == true ]] || return 0
    local keep
    keep="$(snapshot_retention)"
    info "  Pruning old snapshots, keeping last ${keep}..."
    if /home/tappaas/bin/snapshot-vm.sh "${module}" --cleanup "${keep}"; then
        info "  ${GN}✓${CL} Snapshot retention enforced (keeping last ${keep})"
    else
        warn "Snapshot cleanup failed — old snapshots may remain (non-fatal)"
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

    local self_vm; self_vm="$(read_module_config "${module}" | jq -r '.vmname // empty')"
    [[ -n "${self_vm}" ]] || self_vm="${module}"

    if [[ "${OPT_NO_SNAPSHOT}" -eq 1 ]]; then
        info "  Skipped (--no-snapshot)"
    elif [[ "${self_vm}" == "$(hostname)" || "${self_vm}" == "$(hostname -s)" ]]; then
        # SELF-UPDATE GUARD (#352, incident 2026-06-15): never snapshot the VM that
        # is running THIS updater. `qm snapshot` fsfreezes the guest via the QEMU
        # agent; freezing the controller's own root FS mid-update can hang the thaw
        # and strand the VM for hours (same class as the #275 self-reboot guard).
        # Proceed WITHOUT a snapshot — so snapshot_created stays false and no later
        # rollback will try to stop/restore this VM from inside.
        warn "  Skipping pre-update snapshot: ${self_vm} is THIS controller VM (#352)."
        warn "    Snapshotting it from inside fsfreezes its own root FS and can strand it."
        warn "    Continuing WITHOUT a rollback safety net (take a node-side snapshot under supervision if needed)."
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
                fatal_with_rollback "${module}" "${snapshot_created}" "Module pre-update.sh failed"
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
    # Variant of the consuming module — used to resolve same-variant providers
    # (e.g. "nextcloud:fileservice" → "nextcloud-test" when variant=="test").
    local module_variant
    module_variant=$(read_module_config "${module}" | jq -r '.variant // ""' 2>/dev/null) || module_variant=""

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

            # Prefer the same-variant provider when it exists (issue #344).
            provider_module="$(resolve_provider_module "${provider_module}" "${module_variant}")"

            if ! provider_dir=$(get_module_dir "${provider_module}" 2>/dev/null); then
                fatal_with_rollback "${module}" "${snapshot_created}" \
                    "Cannot find provider module '${provider_module}' for dependency '${dep}'"
            fi

            ensure_scripts_executable "${provider_dir}"
            local svc_script="${provider_dir}/services/${service_name}/update-service.sh"

            if [[ ! -x "${svc_script}" ]]; then
                fatal_with_rollback "${module}" "${snapshot_created}" \
                    "Missing update-service.sh for dependency '${dep}': ${svc_script}"
            fi

            info "  Calling ${BL}${dep}${CL} update-service.sh for module '${module}'..."
            if "${svc_script}" "${module}"; then
                info "  ${GN}✓${CL} ${dep} update-service completed"
            else
                fatal_with_rollback "${module}" "${snapshot_created}" "Service updater failed: ${dep}"
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
                fatal_with_rollback "${module}" "${snapshot_created}" "Module update.sh failed"
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
        # Fatal test failure — roll back (shared helper, #307).
        fatal_with_rollback "${module}" "${snapshot_created}" "Post-update tests reported a fatal error"
    else
        # Non-fatal test failure — warn but don't rollback
        warn "Post-update tests failed (exit ${post_test_exit}) — update completed but module may have issues"
        finalize_config "${module}"
        prune_snapshots "${module}" "${snapshot_created}"
        exit 1
    fi

    # ── Success ───────────────────────────────────────────────────────
    finalize_config "${module}"
    prune_snapshots "${module}" "${snapshot_created}"

    echo ""
    info "${GN}${BOLD}Module '${module}' updated successfully${CL}"
}

main "$@"
