#!/usr/bin/env bash
#
# TAPPaaS Module Installer with Dependency Management
#
# Installs a TAPPaaS module by validating its JSON configuration,
# checking that all declared dependencies are satisfied, calling
# each dependency's install-service.sh script, and then running
# the module's own install.sh.
#
# Usage: install-module.sh <module-name> [--variant <name>] [--<field> <value>]...
#
# Arguments:
#   module-name   Name of the module to install (must have a
#                 <module-name>.json in the current directory)
#
# Options:
#   --variant <name>   Install a variant of the module (see copy-update-json.sh)
#   --force            Re-run the installer even if the module is already
#                      installed (alias: --reinstall)
#   --<field> <value>  Override a JSON field (passed to copy-update-json.sh)
#   -h, --help         Show this help message
#
# Examples:
#   install-module.sh vaultwarden
#   install-module.sh litellm --node tappaas2
#   install-module.sh openwebui --variant staging
#   install-module.sh openwebui --variant dev --zone0 srv-dev --vmid 315
#
# The script performs these steps:
#   1. Checks the module is not already installed (unless --force is given)
#   2. Copies and validates the module JSON config (variant-aware)
#   3. Checks that every dependsOn service is provided by an installed module
#   4. Validates that the module has service scripts for each service it provides
#   5. Iterates dependsOn and calls each provider's install-service.sh
#   6. Calls the module's own install.sh (if present in the module directory)
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
Usage: ${SCRIPT_NAME} <module-name> [--variant <name>] [--<field> <value>]...

Install a TAPPaaS module with dependency validation and service wiring.

Arguments:
    module-name              Name of the module (expects ./<module-name>.json)

Options:
    --variant <name>         Install a variant (output: <module>-<name>.json)
    --force, --reinstall     Install even if the module already exists
    --<field> <value>        Override a JSON field value
    -h, --help               Show this help message

Examples:
    ${SCRIPT_NAME} vaultwarden
    ${SCRIPT_NAME} litellm --node tappaas2
    ${SCRIPT_NAME} openwebui --variant staging
    ${SCRIPT_NAME} openwebui --variant dev --zone0 srv-dev --vmid 315
    ${SCRIPT_NAME} identity --force
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

    # Parse options: extract --force (consumed here) and capture --variant
    # (needed for the early existence check). All other arguments are passed
    # through unchanged to copy-update-json.sh, which reads "$@" when sourced.
    local force=false
    local variant=""
    local -a passthru=()
    shift  # drop the module name; re-added below
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|--reinstall)
                force=true
                ;;
            --variant)
                variant="${2:-}"
                passthru+=("$1")
                if [[ $# -ge 2 ]]; then passthru+=("$2"); shift; fi
                ;;
            *)
                passthru+=("$1")
                ;;
        esac
        shift
    done
    set -- "${module}" ${passthru[@]+"${passthru[@]}"}

    # ── Step 1: Check module not already installed ───────────────────
    echo ""
    info "${BOLD}Step 1: Check module not already installed${CL}"

    # The installed-marker is the config JSON in CONFIG_DIR, which Step 2
    # overwrites — so check before copying. Variant builds use the suffixed
    # name (matching copy-update-json.sh's <module>-<variant>.json naming).
    local precheck_module="${module}"
    [[ -n "${variant}" ]] && precheck_module="${module}-${variant}"

    if module_exists "${precheck_module}"; then
        if [[ "${force}" == true ]]; then
            warn "  '${precheck_module}' is already installed — continuing anyway (--force)"
        else
            die "Module '${precheck_module}' is already installed. Run 'delete-module.sh ${precheck_module}' first, or pass --force to re-run the installer against the existing deployment."
        fi
    else
        info "  ${GN}✓${CL} '${precheck_module}' is not yet installed"
    fi

    # ── Step 2: Copy JSON config and validate ────────────────────────
    echo ""
    info "${BOLD}Step 2: Copy and validate module configuration${CL}"

    . /home/tappaas/bin/copy-update-json.sh

    # Use effective module name (may differ from module when --variant is used)
    local effective_module="${EFFECTIVE_MODULE:-${module}}"
    if [[ "${effective_module}" != "${module}" ]]; then
        info "Variant active: effective module name is ${BL}${effective_module}${CL}"
    fi

    check_json "${CONFIG_DIR}/${effective_module}.json" || die "JSON validation failed for ${effective_module}"

    local module_json="${CONFIG_DIR}/${effective_module}.json"

    # ── Step 3: Validate dependencies ────────────────────────────────
    echo ""
    info "${BOLD}Step 3: Validate dependencies${CL}"

    local depends_on
    depends_on=$(read_module_config "${effective_module}" | jq -r '.dependsOn // [] | .[]' 2>/dev/null)

    # A module is either VM-backed or container-backed, never both (issue #203).
    if read_module_config "${effective_module}" | jq -e '(.dependsOn // []) as $d
              | (($d | index("cluster:vm")) != null)
                and (($d | index("cluster:lxc")) != null)' >/dev/null 2>&1; then
        die "Module '${effective_module}' declares both cluster:vm and cluster:lxc in dependsOn — choose one (a guest is a VM or a container, not both)"
    fi

    local dep_errors=0
    if [[ -z "${depends_on}" ]]; then
        info "  No dependencies declared"
    else
        for dep in ${depends_on}; do
            if check_service_available "${dep}" "install-service.sh"; then
                info "  ${GN}✓${CL} ${dep}"
            else
                dep_errors=$((dep_errors + 1))
            fi
        done
    fi

    if [[ "${dep_errors}" -gt 0 ]]; then
        die "${dep_errors} dependency check(s) failed — cannot install ${module}"
    fi

    # ── Step 4: Validate provided services ───────────────────────────
    echo ""
    info "${BOLD}Step 4: Validate service scripts${CL}"

    local module_dir
    module_dir="$(pwd)"
    ensure_scripts_executable "${module_dir}"

    if ! validate_provided_services "${module_dir}" "${module_json}"; then
        die "Module service validation failed"
    fi

    local provides
    provides=$(read_module_config "${effective_module}" | jq -r '.provides // [] | .[]' 2>/dev/null)
    if [[ -z "${provides}" ]]; then
        info "  Module does not provide any services"
    else
        for svc in ${provides}; do
            info "  ${GN}✓${CL} provides: ${svc}"
        done
    fi

    # ── Step 5: Call dependency install-service.sh scripts ───────────
    echo ""
    info "${BOLD}Step 5: Call dependency service installers${CL}"

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

            info "  Calling ${BL}${dep}${CL} install-service.sh for module '${effective_module}'..."
            "${svc_script}" "${effective_module}" || die "Service installer failed: ${dep}"
            info "  ${GN}✓${CL} ${dep} install-service completed"
        done
    fi

    # ── Step 6: Call the module's own install.sh ─────────────────────
    echo ""
    info "${BOLD}Step 6: Run module install.sh${CL}"

    if [[ -x "./install.sh" ]]; then
        info "  Running ${module}/install.sh for '${effective_module}'..."
        ./install.sh "${effective_module}" || die "Module install.sh failed"
        info "  ${GN}✓${CL} Module install.sh completed"
    else
        info "  No install.sh found in module directory — skipping"
    fi

    # ── Done ─────────────────────────────────────────────────────────
    echo ""
    info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${GN}${BOLD}║  Module '${effective_module}' installed successfully     ${CL}"
    info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
}

main "$@"
