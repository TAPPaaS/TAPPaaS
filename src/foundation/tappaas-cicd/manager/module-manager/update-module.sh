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
#   3.5. Apply the dependsOn delta with the right verb: install-service.sh for a
#        newly-added dependency, delete-service.sh for a removed one (#511)
#   4+5. Apply the merged config via `module-manager reconcile --apply`
#        (each dependency's update-service.sh, then the module's update.sh) —
#        the SAME apply reconcile performs, not a second copy of it (#495)
#   6. Run post-update tests (rollback on fatal failure)
#   7. On success, prune old snapshots to tappaas.snapshotRetention (#353)
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="/home/tappaas/config"

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# #533: managers run as the tappaas operator, never root — under sudo, SSH
# resolves identity from /root/.ssh and fails (ADR-018). Refuse root up front.
tappaas_require_operator

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
    --environment <name>  Target environment (ADR-007 P5). The installed config
                          is <module>-<env>.json for a non-default/non-mgmt env;
                          <module>.json otherwise. Equivalent to naming the
                          suffixed module directly.
    --variant <name>      DEPRECATED alias for --environment.
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
    ${SCRIPT_NAME} nextcloud --environment foo
    ${SCRIPT_NAME} --no-snapshot nextcloud
    ${SCRIPT_NAME} --debug openwebui
EOF
}

# Compute the installed (effective) module name from a base module + environment
# (ADR-007 P5). No suffix for an empty env, 'mgmt', or the default environment;
# otherwise <module>-<env>. Mirrors install-module.sh's computation.
resolve_effective_module_name() {
    local mod="$1" env="$2"
    local site_file="${CONFIG_DIR}/site.json"
    local default_env=""
    if [[ -n "$env" ]]; then
        if [[ -f "$site_file" ]]; then
            default_env="$(jq -r '.defaultEnvironment // .name // empty' "$site_file" 2>/dev/null)"
        fi
        if [[ "$env" != "mgmt" && ( -z "$default_env" || "$env" != "$default_env" ) ]]; then
            printf '%s\n' "${mod}-${env}"
            return 0
        fi
    fi
    printf '%s\n' "${mod}"
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
        debug "  Set updateTime = ${update_time}"
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

# Apply the dependsOn delta between two states with the correct lifecycle verb
# (#511). reconcile (update-module Steps 4+5) runs update-service.sh — a RE-WIRE
# — blanket over the whole current dependsOn list. That is correct for a
# dependency already provisioned on this install, but wrong for one the release
# just ADDED: it has never been set up here, so it needs install-service.sh
# (create) first; one the release REMOVED needs delete-service.sh to tear the
# integration down. Both run here — called after the snapshot so an
# install-service failure rolls back — before the blanket reconcile, which then
# converges the freshly-created integration via update-service.sh as usual.
# Adopting the released list itself is unchanged; the merge already reported it.
#
# Args: <module> <snapshot_created> <dep_env> <deps_before> <deps_after> [integ_after]
#   deps_before/deps_after: newline-separated coordinates — the UNION of dependsOn
#   and integratesWith (#501), so a coordinate that merely moves between the two
#   lists is neither added nor removed. integ_after: the integratesWith subset,
#   used only to soften an added coordinate's failure from rollback to a warning.
apply_dependson_delta() {
    local module="$1" snap_created="$2" dep_env="$3" deps_before="$4" deps_after="$5"
    # integ_after (#501): the coordinates that are OPTIONAL after the merge. An
    # added coordinate in this set whose install-service.sh fails only warns —
    # an optional integration must never roll back the whole update.
    local integ_after="${6:-}"

    # added = in deps_after, not in deps_before (order preserved from deps_after).
    local deps_added deps_removed dep
    deps_added=""
    if [[ -n "${deps_after}" ]]; then
        while IFS= read -r dep; do
            [[ -n "${dep}" ]] || continue
            grep -Fxq -- "${dep}" <<<"${deps_before}" || deps_added+="${dep}"$'\n'
        done <<<"${deps_after}"
    fi
    deps_removed=""
    if [[ -n "${deps_before}" ]]; then
        while IFS= read -r dep; do
            [[ -n "${dep}" ]] || continue
            grep -Fxq -- "${dep}" <<<"${deps_after}" || deps_removed+="${dep}"$'\n'
        done <<<"${deps_before}"
    fi

    if [[ -z "${deps_added}${deps_removed}" ]]; then
        debug "  No dependsOn changes — nothing to install or delete"
        return 0
    fi

    # Removed first: tear the old integration down before the module re-converges.
    while IFS= read -r dep; do
        [[ -n "${dep}" ]] || continue
        local rprovider rservice rdir rscript
        rprovider="$(resolve_provider_module "${dep%%:*}" "${dep_env}")"
        rservice="${dep##*:}"
        if ! rdir="$(get_module_dir "${rprovider}" 2>/dev/null)"; then
            warn "  Cannot find provider '${rprovider}' for removed dependency '${dep}' — skipping delete-service.sh"
            continue
        fi
        ensure_scripts_executable "${rdir}"
        rscript="${rdir}/services/${rservice}/delete-service.sh"
        if [[ ! -x "${rscript}" ]]; then
            info "  ${dep}: removed, but provider ships no delete-service.sh — skipping"
            continue
        fi
        info "  Removed dependency ${BL}${dep}${CL} — running delete-service.sh for '${module}'..."
        if "${rscript}" "${module}"; then
            info "  ${GN}✓${CL} ${dep} delete-service completed"
        else
            warn "  ${dep} delete-service returned non-zero (continuing)"
        fi
    done <<<"${deps_removed}"

    # Added next: create the integration so reconcile's update-service.sh converges it.
    while IFS= read -r dep; do
        [[ -n "${dep}" ]] || continue
        local aprovider aservice adir ascript
        aprovider="$(resolve_provider_module "${dep%%:*}" "${dep_env}")"
        aservice="${dep##*:}"
        if ! adir="$(get_module_dir "${aprovider}" 2>/dev/null)"; then
            warn "  Cannot find provider '${aprovider}' for added dependency '${dep}' — skipping install-service.sh"
            continue
        fi
        ensure_scripts_executable "${adir}"
        ascript="${adir}/services/${aservice}/install-service.sh"
        if [[ ! -x "${ascript}" ]]; then
            info "  ${dep}: added, but provider ships no install-service.sh — reconcile will converge via update-service.sh"
            continue
        fi
        local a_optional=false
        grep -Fxq -- "${dep}" <<<"${integ_after}" && a_optional=true
        if [[ "${a_optional}" == "true" ]]; then
            info "  Newly-added integration ${BL}${dep}${CL} — running install-service.sh (create) for '${module}'..."
            if "${ascript}" "${module}"; then
                info "  ${GN}✓${CL} ${dep} integration wired"
            else
                warn "  ${dep} install-service returned non-zero — optional integration not wired (continuing)"
            fi
        else
            info "  Newly-added dependency ${BL}${dep}${CL} — running install-service.sh (create) for '${module}'..."
            if "${ascript}" "${module}"; then
                info "  ${GN}✓${CL} ${dep} install-service completed"
            else
                fatal_with_rollback "${module}" "${snap_created}" \
                    "install-service.sh failed for newly-added dependency '${dep}'"
            fi
        fi
    done <<<"${deps_added}"
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local module=""
    local environment=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)   usage; exit 0 ;;
            --force)        OPT_FORCE=1; shift ;;
            --no-snapshot)  OPT_NO_SNAPSHOT=1; shift ;;
            --debug)        OPT_DEBUG=1; export TAPPAAS_DEBUG=1; shift ;;
            --silent)    OPT_SILENT=1; export TAPPAAS_SILENT=1; shift ;;
            --environment)
                [[ -n "${2:-}" ]] || { fatal "--environment requires a value"; exit 2; }
                environment="$2"; shift 2 ;;
            --variant)
                [[ -n "${2:-}" ]] || { fatal "--variant requires a value"; exit 2; }
                environment="$2"
                warn "--variant is deprecated; treating as --environment ${2} (ADR-007 P5)"
                shift 2 ;;
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

    # ADR-007 P5: map a base module + --environment to the installed config name
    # (<module>-<env> for a non-default env). If the caller already passed the
    # suffixed name, this leaves it unchanged.
    if [[ -n "${environment}" ]]; then
        local _eff
        _eff="$(resolve_effective_module_name "${module}" "${environment}")"
        if [[ "${_eff}" != "${module}" && ! -f "${CONFIG_DIR}/${module}.json" ]]; then
            module="${_eff}"
        fi
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

    # ── Lifecycle guard (#441) ───────────────────────────────────────
    # archived (#215) and external (#216) modules are not in the update
    # lifecycle: the first has no VM (delete-module.sh --archive removed it and
    # kept the config for restore), the second is managed outside TAPPaaS. Both
    # used to run the whole update: Step 0 rewrote the config and advanced its
    # .orig baseline, Step 1's snapshot failed with only a warning, and Step 2's
    # pre-update test then aborted with exit 2 — so a decommissioned module was
    # reported as a FAILED update after its config had already been rewritten.
    #
    # Must sit BEFORE Step 0; that is the step doing the write. exit 0, because
    # "correctly not updated" is a success for every caller (update-tappaas
    # counts a non-zero rc as a failed module). --force is the escape hatch for
    # a deliberate restore-then-update.
    local module_status
    module_status="$(read_module_config "${module}" | jq -r '.status // ""' | tr '[:upper:]' '[:lower:]')"
    if [[ "${module_status}" == "archived" || "${module_status}" == "external" ]]; then
        if [[ "${OPT_FORCE}" -eq 1 ]]; then
            warn "Module '${module}' has status=${module_status} — updating anyway (--force)"
        else
            info "  Module '${module}' has ${BL}status=${module_status}${CL} — not in the update lifecycle; skipping."
            info "  Use ${YW}--force${CL} to update it anyway (e.g. after restoring an archived VM)."
            exit 0
        fi
    fi

    # ── Step 0: 3-way merge module config against new release source (#207) ──
    # Reconciles operator customizations with release updates BEFORE we
    # snapshot or run hooks, so the snapshot and all hooks see the merged
    # config. Per-leaf rule: adopt release for fields the operator hasn't
    # touched; pin fields the operator has customized. .orig advances to the
    # current release. If .orig is missing (pre-#207 install) we backfill it
    # from source so existing customizations remain pinned.
    info "${BOLD}Update Step 0: Reconcile module config (3-way merge)${CL}"
    # Capture dependsOn + integratesWith BEFORE the merge so Step 3.5 can act on
    # the delta with the correct verb: a newly-added coordinate has never been
    # provisioned on this install, so it needs install-service.sh (create), not
    # the update-service.sh re-wire reconcile runs blanket over the list (#511).
    # The delta is computed over the UNION of both lists so that RECLASSIFYING a
    # coordinate dependsOn⇄integratesWith (e.g. #501 migrating vllm-amd:inference
    # to optional) is a no-op — the wiring already in place is neither torn down
    # nor recreated, only the guard semantics change (#501).
    local deps_before
    deps_before="$(read_module_config "${module}" 2>/dev/null | jq -r '((.dependsOn // []) + (.integratesWith // [])) | .[]' 2>/dev/null || true)"
    if module_dir_pre=$(get_module_dir "${module}" 2>/dev/null); then
        if [[ -f /home/tappaas/bin/apply-json-merge.sh ]]; then
            # shellcheck disable=SC1091
            . /home/tappaas/bin/apply-json-merge.sh
            if apply_three_way_merge "${module}" "${module_dir_pre}"; then
                debug "  ${GN}✓${CL} Config reconciliation complete"
            else
                warn "  3-way merge reported an error — continuing with current config unchanged"
            fi
        else
            warn "  apply-json-merge.sh not available — skipping 3-way merge"
        fi
    else
        info "  Module location not resolved — skipping (first-update before location was set)"
    fi

    # dependsOn + integratesWith AFTER the merge — the delta vs deps_before is
    # applied in Step 3.5. integ_after alone classifies which added coordinates
    # are OPTIONAL, so their install-service.sh failure warns instead of rolling
    # back the whole update (#501).
    local deps_after integ_after
    deps_after="$(read_module_config "${module}" 2>/dev/null | jq -r '((.dependsOn // []) + (.integratesWith // [])) | .[]' 2>/dev/null || true)"
    integ_after="$(read_module_config "${module}" 2>/dev/null | jq -r '.integratesWith // [] | .[]' 2>/dev/null || true)"

    # ── Step 1: Pre-update snapshot (only for modules with a VM) ─────
    info "${BOLD}Update Step 1: Create pre-update snapshot: ${BL}${module}${CL}"

    local snapshot_created=false
    local has_vm=false
    if read_module_config "${module}" | jq -e '.dependsOn // [] | index("cluster:vm")' &>/dev/null; then
        has_vm=true
    fi

    local self_vm; self_vm="$(read_module_config "${module}" | jq -r '.vmname // empty')"
    [[ -n "${self_vm}" ]] || self_vm="${module}"

    if [[ "${OPT_NO_SNAPSHOT}" -eq 1 ]]; then
        debug "  Skipped (--no-snapshot)"
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
        # Capture snapshot-vm.sh (+ qm) output → [Debug] when green; surfaced on failure.
        local _snap_out _snap_rc _sl
        _snap_out="$(/home/tappaas/bin/snapshot-vm.sh "${module}" 2>&1)" && _snap_rc=0 || _snap_rc=$?
        if [[ ${_snap_rc} -eq 0 ]]; then
            if [[ -n "${_snap_out}" ]]; then while IFS= read -r _sl; do debug "  ${_sl}"; done <<<"${_snap_out}"; fi
            debug "  ${GN}✓${CL} Snapshot created"
            snapshot_created=true
        else
            if [[ -n "${_snap_out}" ]]; then printf '%s\n' "${_snap_out}" >&2; fi
            warn "Snapshot failed — continuing without rollback safety net"
        fi
    else
        debug "  Skipped (module has no VM)"
    fi

    # ── Step 2: Pre-update test ───────────────────────────────────────
    info "${BOLD}Update Step 2: Run pre-update tests${CL}"

    if [[ "${OPT_NO_SNAPSHOT}" -eq 1 ]]; then
        info "  Skipped (--no-snapshot)"
    else
        local pre_test_exit=0
        /home/tappaas/bin/test-module.sh "${module}" || pre_test_exit=$?

        if [[ "${pre_test_exit}" -eq 0 ]]; then
            debug "  ${GN}✓${CL} Pre-update tests passed"
        elif [[ "${OPT_FORCE}" -eq 1 ]]; then
            warn "Pre-update tests failed (exit ${pre_test_exit}) — continuing due to --force"
        else
            fatal "Pre-update tests failed (exit ${pre_test_exit}) — aborting update"
            error "  Use --force to override"
            exit 2
        fi
    fi

    # ── Step 3: Run pre-update.sh if present ─────────────────────────
    info "${BOLD}Update Step 3: Run pre-update hook${CL}"

    local module_dir=""
    if module_dir=$(get_module_dir "${module}" 2>/dev/null); then
        ensure_scripts_executable "${module_dir}"
        if [[ -x "${module_dir}/pre-update.sh" ]]; then
            debug "  Running ${module_dir}/pre-update.sh..."
            cd "${module_dir}"
            if ./pre-update.sh "${module}"; then
                info "  ${GN}✓${CL} pre-update.sh completed"
            else
                fatal_with_rollback "${module}" "${snapshot_created}" "Module pre-update.sh failed"
            fi
        else
            debug "  No pre-update.sh found — skipping"
        fi
    else
        info "  Module location not set — skipping"
    fi

    # ── Step 3.5: Apply the dependsOn delta with the correct verb (#511) ──
    # The delta between the pre-merge and post-merge dependsOn is applied here —
    # install-service.sh for an added dependency, delete-service.sh for a removed
    # one — after the snapshot (so a failure rolls back) and before the blanket
    # reconcile. See apply_dependson_delta for the full rationale.
    info "${BOLD}Update Step 3.5: Apply dependsOn delta (install added / delete removed)${CL}"
    local dep_env
    dep_env="$(read_module_config "${module}" 2>/dev/null | jq -r '.environment // ""')"
    apply_dependson_delta "${module}" "${snapshot_created}" "${dep_env}" "${deps_before}" "${deps_after}" "${integ_after}"

    # ── Steps 4+5: Apply the (now merged) config — delegated to reconcile ──
    #
    # `module reconcile --apply` IS this apply: it calls each dependency's
    # update-service.sh from the module directory, then the module's own
    # update.sh. This used to be re-implemented here, which is how the two paths
    # drifted apart — reconcile called install-service.sh (create semantics) and
    # was broken on every VM-backed module while this one worked (#495).
    # One apply, one place, exercised by both verbs.
    #
    # What stays HERE is everything that makes `modify` more than a re-apply:
    # the 3-way merge (Step 0), the snapshot, the pre/post tests, rollback, the
    # updateTime bump and snapshot pruning. reconcile deliberately does none of
    # those — see DESIGN.md, "reconcile vs modify".
    #
    # Behaviour delta worth knowing: this loop used to abort the update when a
    # provider shipped no update-service.sh. reconcile SKIPS such a dependency
    # instead (several dependsOn entries name providers with no services/
    # directory at all, e.g. sonos:audio, alfen:ui — those modules could not be
    # modified at all before). A dependency naming a provider that cannot serve
    # it is a config error, reported by `module validate`, not a runtime abort.
    info "${BOLD}Update Steps 4+5: Apply config via reconcile${CL}"

    if ! module-manager reconcile "${module}" --apply; then
        fatal_with_rollback "${module}" "${snapshot_created}" \
            "Apply failed (reconcile --apply did not converge '${module}')"
    fi
    debug "  ${GN}✓${CL} reconcile --apply converged"

    # ── Step 5.5: Wait for the module to be able to serve again (#509) ──
    #
    # The apply above can restart the module's services — a dependency's
    # update-service.sh re-wiring an integration, or the module's own update.sh
    # — and the post-update tests run immediately after. Readiness was only ever
    # gated on the REBOOT paths (cluster:vm subnet change, update-os), so a
    # restart triggered mid-apply had no gate at all: euro-office failed its own
    # /healthcheck with HTTP 502 on 2026-08-25 while the DocumentServer was
    # still starting after the OnlyOffice connector was re-wired, and passed
    # when re-checked seconds later.
    #
    # hook-only: a module with a ready.sh asserts real service health; one
    # without is not held up. The generic port fallback is the module's DECLARED
    # surface, not a readiness contract — unifi-os declares UDP ports a TCP
    # connect can never satisfy, network's 80/443 live on the firewall — so
    # after EVERY apply it costs the full timeout and still proves nothing (both
    # burned 180s here and then passed their own tests). The reboot callers keep
    # the port fallback, where it is a reasonable "did the guest come back".
    #
    # A timeout WARNS — "tests may be flaky", not "the update failed" —
    # matching how the reboot callers treat it.
    local ready_host ready_vm ready_zone
    ready_vm="$(read_module_config "${module}" | jq -r '.vmname // empty')"
    ready_zone="$(read_module_config "${module}" | jq -r '.zone0 // empty')"
    if [[ -n "${ready_vm}" && -n "${ready_zone}" ]]; then
        ready_host="${ready_vm}.${ready_zone}.internal"
        wait_for_module_ready "${module}" "${ready_host}" 180 hook-only \
            || warn "  '${module}' not ready after apply — post-update tests may see a starting service"
    else
        debug "  no vmname/zone0 for '${module}' — skipping the post-apply readiness gate"
    fi

    # ── Step 6: Post-update test ──────────────────────────────────────
    info "${BOLD}Update Step 6: Run post-update tests: ${BL}${module}${CL}"

    local post_test_exit=0
    /home/tappaas/bin/test-module.sh "${module}" || post_test_exit=$?

    if [[ "${post_test_exit}" -eq 0 ]]; then
        debug "  ${GN}✓${CL} Post-update tests passed"
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

    info "${GN}${BOLD}Module '${module}' updated successfully${CL}"
}

main "$@"
