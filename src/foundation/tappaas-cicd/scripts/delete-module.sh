#!/usr/bin/env bash
#
# TAPPaaS Module Deleter with Dependency Management
#
# Deletes a TAPPaaS module by running the module's own delete.sh,
# calling each dependency's delete-service.sh script in reverse order,
# and then removing the module's configuration files.
#
# Usage: delete-module.sh <module-name> [--force]
#
# Arguments:
#   module-name   Name of the module to delete (must have a
#                 <module-name>.json in /home/tappaas/config/)
#
# Options:
#   --force        Delete even if other modules depend on this module's services
#   -h, --help     Show this help message
#
# Examples:
#   delete-module.sh vaultwarden
#   delete-module.sh litellm --force
#
# The script performs these steps:
#   1. Validates the module JSON config exists
#   2. Checks that no other modules depend on this module's services
#   3. Calls the module's own delete.sh (if present)
#   4. Iterates dependsOn in reverse and calls each provider's delete-service.sh
#   5. Removes the module configuration files
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="/home/tappaas/config"

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <module-name> [--force]

Delete a TAPPaaS module with dependency-aware service teardown.

Arguments:
    module-name    Name of the module (must have config in ${CONFIG_DIR}/)

Options:
    --force        Delete even if other modules depend on this module's services
    -h, --help     Show this help message

Examples:
    ${SCRIPT_NAME} vaultwarden
    ${SCRIPT_NAME} litellm --force
EOF
}

# ── Helpers (delete-specific) ────────────────────────────────────────

# Check if any installed module depends on a service provided by this module.
# Arguments: <module-name>
# Returns the count of dependent modules found (0 = no dependents).
# Outputs dependent module names via error().
check_reverse_dependencies() {
    local module="$1"
    local module_json="${CONFIG_DIR}/${module}.json"
    local dependents_found=0

    # Get the services this module provides
    local provides
    provides=$(jq -r '.provides // [] | .[]' "${module_json}" 2>/dev/null)

    if [[ -z "${provides}" ]]; then
        return 0
    fi

    # Scan all installed module configs for dependsOn references
    for config_file in "${CONFIG_DIR}"/*.json; do
        [[ -f "${config_file}" ]] || continue

        local other_module
        other_module=$(basename "${config_file}" .json)

        # Skip self and .orig backup files
        [[ "${other_module}" == "${module}" ]] && continue
        [[ "${config_file}" == *.orig ]] && continue

        # Skip files that don't have a dependsOn array (not module configs)
        if ! jq -e '.dependsOn' "${config_file}" >/dev/null 2>&1; then
            continue
        fi

        for service in ${provides}; do
            local dep_ref="${module}:${service}"
            if jq -e --arg dep "${dep_ref}" '.dependsOn // [] | index($dep) != null' "${config_file}" >/dev/null 2>&1; then
                error "Module '${other_module}' depends on '${dep_ref}'"
                ((dependents_found++))
            fi
        done
    done

    return "${dependents_found}"
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local force=false
    local module=""

    # Parse arguments
    for arg in "$@"; do
        case "${arg}" in
            -h|--help) usage; exit 0 ;;
            --force) force=true ;;
            -*) die "Unknown option: ${arg}" ;;
            *)
                if [[ -n "${module}" ]]; then
                    die "Unexpected argument: ${arg} (module already set to '${module}')"
                fi
                module="${arg}"
                ;;
        esac
    done

    # Validate module name argument
    if [[ -z "${module}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    local module_json="${CONFIG_DIR}/${module}.json"

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Module Delete: ${BL}${module}${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Validate module config ───────────────────────────────
    info "\n${BOLD}Step 1: Validate module configuration${CL}"

    if [[ ! -f "${module_json}" ]]; then
        die "Module config not found: ${module_json} — is the module installed?"
    fi

    info "  ${GN}✓${CL} Module config found: ${module_json}"

    # ── Step 2: Check reverse dependencies ───────────────────────────
    info "\n${BOLD}Step 2: Check reverse dependencies${CL}"

    local provides
    provides=$(jq -r '.provides // [] | .[]' "${module_json}" 2>/dev/null)

    if [[ -z "${provides}" ]]; then
        info "  Module provides no services — no reverse dependency check needed"
    else
        local rev_dep_count=0
        check_reverse_dependencies "${module}" || rev_dep_count=$?

        if [[ "${rev_dep_count}" -gt 0 ]]; then
            if [[ "${force}" == "true" ]]; then
                warn "Proceeding with deletion despite ${rev_dep_count} dependent module(s) (--force)"
            else
                die "${rev_dep_count} module(s) depend on services from '${module}' — use --force to override"
            fi
        else
            info "  ${GN}✓${CL} No other modules depend on this module's services"
        fi
    fi

    # ── Step 3: Run the module's own delete.sh ───────────────────────
    info "\n${BOLD}Step 3: Run module delete.sh${CL}"

    local module_dir
    if module_dir=$(get_module_dir "${module}"); then
        ensure_scripts_executable "${module_dir}"
        if [[ -x "${module_dir}/delete.sh" ]]; then
            info "  Running ${module_dir}/delete.sh..."
            cd "${module_dir}"
            ./delete.sh "${module}" || die "Module delete.sh failed"
            info "  ${GN}✓${CL} Module delete.sh completed"
        else
            info "  No delete.sh found in module directory — skipping"
        fi
    else
        warn "Cannot find module directory (missing .location in config) — skipping delete.sh"
    fi

    # ── Step 4: Call dependency delete-service.sh scripts (reverse) ──
    info "\n${BOLD}Step 4: Call dependency service deleters (reverse order)${CL}"

    local depends_on
    depends_on=$(jq -r '.dependsOn // [] | .[]' "${module_json}" 2>/dev/null)

    if [[ -z "${depends_on}" ]]; then
        info "  No dependency services to call"
    else
        # Reverse the dependency list
        local reversed_deps
        reversed_deps=$(echo "${depends_on}" | tac)

        for dep in ${reversed_deps}; do
            local provider_module="${dep%%:*}"
            local service_name="${dep##*:}"
            local provider_dir

            if ! provider_dir=$(get_module_dir "${provider_module}"); then
                warn "  Cannot find provider '${provider_module}' location — skipping ${dep}"
                continue
            fi

            ensure_scripts_executable "${provider_dir}"
            local svc_script="${provider_dir}/services/${service_name}/delete-service.sh"

            if [[ ! -x "${svc_script}" ]]; then
                info "  ${dep}: no delete-service.sh found — skipping"
                continue
            fi

            info "  Calling ${BL}${dep}${CL} delete-service.sh for module '${module}'..."
            if "${svc_script}" "${module}"; then
                info "  ${GN}✓${CL} ${dep} delete-service completed"
            else
                warn "${dep} delete-service returned non-zero (continuing)"
            fi
        done
    fi

    # ── Step 5: Remove config files ──────────────────────────────────
    info "\n${BOLD}Step 5: Remove module configuration${CL}"

    if [[ -f "${module_json}" ]]; then
        rm -f "${module_json}"
        info "  Removed ${module_json}"
    fi

    local config_orig="${CONFIG_DIR}/${module}.json.orig"
    if [[ -f "${config_orig}" ]]; then
        rm -f "${config_orig}"
        info "  Removed ${config_orig}"
    fi

    # ── Done ─────────────────────────────────────────────────────────
    echo ""
    info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${GN}${BOLD}║  Module '${module}' deleted successfully        ${CL}"
    info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
}

main "$@"
