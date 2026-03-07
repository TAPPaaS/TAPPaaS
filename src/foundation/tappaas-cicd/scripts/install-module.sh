#!/usr/bin/env bash
#
# TAPPaaS Module Installer with Dependency Management
#
# Installs a TAPPaaS module by validating its JSON configuration,
# checking that all declared dependencies are satisfied, calling
# each dependency's install-service.sh script, and then running
# the module's own install.sh.
#
# Usage: install-module.sh <module-name> [--<field> <value>]...
#
# Arguments:
#   module-name   Name of the module to install (must have a
#                 <module-name>.json in the current directory)
#
# Options:
#   --<field> <value>  Override a JSON field (passed to copy-update-json.sh)
#   -h, --help         Show this help message
#
# Examples:
#   install-module.sh vaultwarden
#   install-module.sh litellm --node tappaas2
#
# The script performs these steps:
#   1. Copies and validates the module JSON config
#   2. Checks that every dependsOn service is provided by an installed module
#   3. Validates that the module has service scripts for each service it provides
#   4. Iterates dependsOn and calls each provider's install-service.sh
#   5. Calls the module's own install.sh (if present in the module directory)
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
Usage: ${SCRIPT_NAME} <module-name> [--<field> <value>]...

Install a TAPPaaS module with dependency validation and service wiring.

Arguments:
    module-name          Name of the module (expects ./<module-name>.json)

Options:
    --<field> <value>    Override a JSON field value
    -h, --help           Show this help message

Examples:
    ${SCRIPT_NAME} vaultwarden
    ${SCRIPT_NAME} litellm --node tappaas2
EOF
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    # Handle help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    # Validate module name argument
    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    local module="$1"

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Module Install: ${BL}${module}${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Copy JSON config and validate ────────────────────────
    info "\n${BOLD}Step 1: Copy and validate module configuration${CL}"

    . /home/tappaas/bin/copy-update-json.sh
    check_json "${CONFIG_DIR}/${module}.json" || die "JSON validation failed for ${module}"

    local module_json="${CONFIG_DIR}/${module}.json"

    # ── Step 2: Validate dependencies ────────────────────────────────
    info "\n${BOLD}Step 2: Validate dependencies${CL}"

    local depends_on
    depends_on=$(jq -r '.dependsOn // [] | .[]' "${module_json}" 2>/dev/null)

    local dep_errors=0
    if [[ -z "${depends_on}" ]]; then
        info "  No dependencies declared"
    else
        for dep in ${depends_on}; do
            if check_service_available "${dep}" "install-service.sh"; then
                info "  ${GN}✓${CL} ${dep}"
            else
                ((dep_errors++))
            fi
        done
    fi

    if [[ "${dep_errors}" -gt 0 ]]; then
        die "${dep_errors} dependency check(s) failed — cannot install ${module}"
    fi

    # ── Step 3: Validate provided services ───────────────────────────
    info "\n${BOLD}Step 3: Validate service scripts${CL}"

    local module_dir
    module_dir="$(pwd)"
    ensure_scripts_executable "${module_dir}"

    if ! validate_provided_services "${module_dir}" "${module_json}"; then
        die "Module service validation failed"
    fi

    local provides
    provides=$(jq -r '.provides // [] | .[]' "${module_json}" 2>/dev/null)
    if [[ -z "${provides}" ]]; then
        info "  Module does not provide any services"
    else
        for svc in ${provides}; do
            info "  ${GN}✓${CL} provides: ${svc}"
        done
    fi

    # ── Step 4: Call dependency install-service.sh scripts ───────────
    info "\n${BOLD}Step 4: Call dependency service installers${CL}"

    if [[ -z "${depends_on}" ]]; then
        info "  No dependency services to call"
    else
        for dep in ${depends_on}; do
            local provider_module="${dep%%:*}"
            local service_name="${dep##*:}"
            local provider_dir

            provider_dir=$(get_module_dir "${provider_module}")
            ensure_scripts_executable "${provider_dir}"
            local svc_script="${provider_dir}/services/${service_name}/install-service.sh"

            info "  Calling ${BL}${dep}${CL} install-service.sh for module '${module}'..."
            "${svc_script}" "${module}" || die "Service installer failed: ${dep}"
            info "  ${GN}✓${CL} ${dep} install-service completed"
        done
    fi

    # ── Step 5: Call the module's own install.sh ─────────────────────
    info "\n${BOLD}Step 5: Run module install.sh${CL}"

    if [[ -x "./install.sh" ]]; then
        info "  Running ${module}/install.sh..."
        ./install.sh "${module}" || die "Module install.sh failed"
        info "  ${GN}✓${CL} Module install.sh completed"
    else
        info "  No install.sh found in module directory — skipping"
    fi

    # ── Done ─────────────────────────────────────────────────────────
    echo ""
    info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${GN}${BOLD}║  Module '${module}' installed successfully     ${CL}"
    info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
}

main "$@"
