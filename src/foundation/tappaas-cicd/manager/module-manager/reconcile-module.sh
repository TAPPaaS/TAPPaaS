#!/usr/bin/env bash
#
# TAPPaaS Module Reconcile — the LEAF re-apply (ADR-007 #3 verb alignment).
#
# Re-applies an already-installed module's CURRENT config to its VM/service,
# idempotently, WITHOUT changing the config. This is the leaf the
# `reconcile --deep` cascade depends on (site → environment → module), so it
# MUST be safe to run anytime and converge to the same state.
#
# It deliberately does LESS than update-module.sh — that distinction is the
# whole point of `reconcile` vs `modify`:
#
#   reconcile-module.sh (this)     update-module.sh (= `module modify`)
#   ──────────────────────────     ────────────────────────────────────
#   NO snapshot                    pre-update VM snapshot + rollback
#   NO pre/post tests              pre + post test-module.sh
#   NO 3-way merge of config       3-way merge release source into config
#   NO updateTime bump             bumps updateTime
#   re-apply current config only   release update of the module
#
# What it DOES (in order):
#   1. Validate the module config exists.
#   2. Call each dependsOn provider's install-service.sh <module> — these are the
#      idempotent ensure/apply scripts (VM present, proxy wired, rules applied,
#      backup registered, …). Re-running them converges the live plane to the
#      module's current config.
#   3. Run the module's own update.sh (preferred) or install.sh as the in-VM
#      converge step, against the existing config.
#
# Usage: reconcile-module.sh [--environment <name>] [--debug] [--silent] <module>
#
# Exit codes: 0 = converged; 1 = a converge step failed.
#
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="/home/tappaas/config"

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [options] <module-name>

Re-apply (converge) an installed module's current config to its VM/service.
Idempotent leaf of the reconcile cascade — NO snapshot, NO tests, NO config
change (use update-module.sh / 'module modify' for a release update).

Arguments:
    module-name           Name of the installed module (config in ${CONFIG_DIR}/)

Options:
    --environment <name>  Target environment (ADR-007 P5). Resolves the installed
                          config name (<module>-<env> for a non-default/non-mgmt
                          env). Equivalent to naming the suffixed module directly.
    --variant <name>      DEPRECATED alias for --environment.
    --debug               Show Debug-level messages.
    --silent              Suppress Info-level messages.
    -h, --help            Show this help message.

Examples:
    ${SCRIPT_NAME} nextcloud
    ${SCRIPT_NAME} nextcloud --environment foo
EOF
}

# Compute the installed (effective) module name from a base module + environment
# (ADR-007 P5). Mirrors update-module.sh's resolution: no suffix for an empty
# env, 'mgmt', or the default environment; otherwise <module>-<env>.
resolve_effective_module_name() {
    local mod="$1" env="$2"
    local site_file="${CONFIG_DIR}/site.json"
    local default_env=""
    if [[ -n "$env" ]]; then
        if [[ -f "$site_file" ]]; then
            default_env="$(jq -r '.name // empty' "$site_file" 2>/dev/null)"
        fi
        if [[ "$env" != "mgmt" && ( -z "$default_env" || "$env" != "$default_env" ) ]]; then
            printf '%s\n' "${mod}-${env}"
            return 0
        fi
    fi
    printf '%s\n' "${mod}"
}

main() {
    local module=""
    local environment=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)  usage; exit 0 ;;
            --debug)    OPT_DEBUG=1; export TAPPAAS_DEBUG=1; shift ;;
            --silent)   OPT_SILENT=1; export TAPPAAS_SILENT=1; shift ;;
            --environment)
                [[ -n "${2:-}" ]] || die "--environment requires a value"
                environment="$2"; shift 2 ;;
            --variant)
                [[ -n "${2:-}" ]] || die "--variant requires a value"
                environment="$2"
                warn "--variant is deprecated; treating as --environment ${2} (ADR-007 P5)"
                shift 2 ;;
            -*) die "Unknown option: $1" ;;
            *)
                if [[ -z "${module}" ]]; then
                    module="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift ;;
        esac
    done

    [[ -n "${module}" ]] || { error "Module name is required"; usage; exit 1; }

    # ADR-007 P5: map a base module + --environment to the installed config name.
    if [[ -n "${environment}" ]]; then
        local _eff
        _eff="$(resolve_effective_module_name "${module}" "${environment}")"
        if [[ "${_eff}" != "${module}" && ! -f "${CONFIG_DIR}/${module}.json" ]]; then
            module="${_eff}"
        fi
    fi

    local module_json="${CONFIG_DIR}/${module}.json"

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Module Reconcile: ${BL}${module}${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Validate module config ───────────────────────────────
    echo ""
    info "${BOLD}Step 1: Validate module configuration${CL}"
    if [[ ! -f "${module_json}" ]]; then
        die "Module config not found: ${module_json} — is the module installed? (reconcile re-applies an EXISTING module; use install-module.sh to create one)"
    fi
    check_json "${module_json}" || die "JSON validation failed for ${module}"
    info "  ${GN}✓${CL} ${module_json}"

    # ── Step 2: Re-apply dependency services (idempotent ensure/apply) ──
    echo ""
    info "${BOLD}Step 2: Re-apply dependency services${CL}"

    local depends_on
    depends_on=$(read_module_config "${module}" | jq -r '.dependsOn // [] | .[]' 2>/dev/null)

    if [[ -z "${depends_on}" ]]; then
        info "  No dependency services to re-apply"
    else
        local failures=0
        for dep in ${depends_on}; do
            local provider_module="${dep%%:*}"
            local service_name="${dep##*:}"
            local provider_dir

            provider_module="$(resolve_provider_module "${provider_module}")"
            if ! provider_dir=$(get_module_dir "${provider_module}" 2>/dev/null); then
                warn "  Cannot find provider '${provider_module}' location — skipping ${dep}"
                continue
            fi
            ensure_scripts_executable "${provider_dir}"

            # install-service.sh is the idempotent ensure/apply entry (the same
            # one install-module.sh calls). Re-running it converges the plane to
            # the module's current config. Skip cleanly when a provider has none.
            local svc_script="${provider_dir}/services/${service_name}/install-service.sh"
            if [[ ! -x "${svc_script}" ]]; then
                info "  ${dep}: no install-service.sh — skipping"
                continue
            fi

            info "  Re-applying ${BL}${dep}${CL} for '${module}'..."
            if "${svc_script}" "${module}"; then
                info "  ${GN}✓${CL} ${dep} converged"
            else
                error "  ✗ ${dep} re-apply failed"
                failures=$((failures + 1))
            fi
        done
        if [[ "${failures}" -gt 0 ]]; then
            die "${failures} dependency service(s) failed to re-apply — reconcile of '${module}' did not converge"
        fi
    fi

    # ── Step 3: Re-apply the module itself (in-VM converge) ───────────
    echo ""
    info "${BOLD}Step 3: Re-apply the module${CL}"

    local module_dir
    if module_dir=$(get_module_dir "${module}" 2>/dev/null); then
        ensure_scripts_executable "${module_dir}"
        cd "${module_dir}"
        # Prefer update.sh (the steady-state converge) over install.sh. NO
        # updateTime bump, NO snapshot, NO test — that is what makes this a
        # reconcile, not an update.
        if [[ -x "${module_dir}/update.sh" ]]; then
            info "  Running ${module_dir}/update.sh (converge)..."
            ./update.sh "${module}" || die "Module update.sh failed during reconcile"
            info "  ${GN}✓${CL} module update.sh converged"
        elif [[ -x "${module_dir}/install.sh" ]]; then
            info "  No update.sh — running ${module_dir}/install.sh (idempotent re-apply)..."
            ./install.sh "${module}" || die "Module install.sh failed during reconcile"
            info "  ${GN}✓${CL} module install.sh converged"
        else
            info "  No update.sh/install.sh in module directory — nothing to re-apply in-VM"
        fi
    else
        warn "Cannot find module directory (missing .location) — skipping in-VM re-apply"
    fi

    echo ""
    info "${GN}${BOLD}Module '${module}' reconciled (converged to current config)${CL}"
}

main "$@"
