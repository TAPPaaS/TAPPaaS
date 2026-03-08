#!/usr/bin/env bash
#
# TAPPaaS Module Updater with Dependency Management
#
# Updates a TAPPaaS module by validating its JSON configuration,
# calling each dependency's update-service.sh script, and then
# running the module's own update.sh.
#
# Usage: update-module.sh <module-name>
#
# Arguments:
#   module-name   Name of the module to update (must have a
#                 <module-name>.json in /home/tappaas/config/)
#
# Options:
#   -h, --help    Show this help message
#
# Examples:
#   update-module.sh vaultwarden
#   update-module.sh litellm
#
# The script performs these steps:
#   1. Validates the module JSON config
#   2. Checks that every dependsOn service is still available
#   3. Runs the module's pre-update.sh (if present)
#   4. Iterates dependsOn and calls each provider's update-service.sh
#   5. Calls the module's own update.sh
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
Usage: ${SCRIPT_NAME} <module-name>

Update a TAPPaaS module with dependency-aware service wiring.

Arguments:
    module-name    Name of the module (must have config in ${CONFIG_DIR}/)

Options:
    -h, --help     Show this help message

Examples:
    ${SCRIPT_NAME} vaultwarden
    ${SCRIPT_NAME} litellm
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
    local module_json="${CONFIG_DIR}/${module}.json"

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Module Update: ${BL}${module}${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Validate module config ───────────────────────────────
    info "\n${BOLD}Step 1: Validate module configuration${CL}"

    if [[ ! -f "${module_json}" ]]; then
        die "Module config not found: ${module_json} — is the module installed?"
    fi

    check_json "${module_json}" || die "JSON validation failed for ${module}"

    # Set updateTime (local time, YYYYMMDD-HH:MM:SS)
    local update_time tmp_file
    update_time=$(date +'%Y%m%d-%H:%M:%S')
    tmp_file=$(mktemp)
    if jq --arg t "${update_time}" '.updateTime = $t' "${module_json}" > "${tmp_file}"; then
        mv "${tmp_file}" "${module_json}"
        info "  Set updateTime = ${update_time}"
    else
        rm -f "${tmp_file}"
        warn "Could not set updateTime"
    fi

    # Reorder fields according to the standard field order from module-fields.json
    local schema_file="/home/tappaas/TAPPaaS/src/foundation/module-fields.json"
    if [[ -f "${schema_file}" ]]; then
        local order_json
        order_json=$(jq -c '.fieldOrder // empty' "${schema_file}" 2>/dev/null)
        if [[ -n "${order_json}" ]]; then
            tmp_file=$(mktemp)
            local jq_filter
            jq_filter=$(mktemp)
            cat > "${jq_filter}" << 'JQEOF'
. as $orig |
reduce $order[] as $key (
  {};
  if ($orig | has($key)) then . + {($key): $orig[$key]} else . end
) |
. + ($orig | to_entries | map(select(.key as $k | $order | index($k) | not)) | from_entries)
JQEOF
            if jq --argjson order "${order_json}" -f "${jq_filter}" "${module_json}" > "${tmp_file}"; then
                mv "${tmp_file}" "${module_json}"
                info "  Reordered fields to standard order"
            else
                rm -f "${tmp_file}"
                warn "Could not reorder fields — keeping current order"
            fi
            rm -f "${jq_filter}"
        fi
    fi

    # ── Step 2: Validate dependencies ────────────────────────────────
    info "\n${BOLD}Step 2: Validate dependencies${CL}"

    local depends_on
    depends_on=$(jq -r '.dependsOn // [] | .[]' "${module_json}" 2>/dev/null)

    local dep_errors=0
    if [[ -z "${depends_on}" ]]; then
        info "  No dependencies declared"
    else
        for dep in ${depends_on}; do
            if check_service_available "${dep}" "update-service.sh"; then
                info "  ${GN}✓${CL} ${dep}"
            else
                ((dep_errors++))
            fi
        done
    fi

    if [[ "${dep_errors}" -gt 0 ]]; then
        die "${dep_errors} dependency check(s) failed — cannot update ${module}"
    fi

    # ── Step 3: Run pre-update.sh if present ────────────────────────
    info "\n${BOLD}Step 3: Run pre-update hook${CL}"

    local module_dir
    if module_dir=$(get_module_dir "${module}"); then
        ensure_scripts_executable "${module_dir}"
        if [[ -x "${module_dir}/pre-update.sh" ]]; then
            info "  Running ${module_dir}/pre-update.sh..."
            cd "${module_dir}"
            ./pre-update.sh "${module}" || die "Module pre-update.sh failed"
            info "  ${GN}✓${CL} pre-update.sh completed"
        else
            info "  No pre-update.sh found — skipping"
        fi
    else
        info "  Module location not set — skipping"
    fi

    # ── Step 4: Call dependency update-service.sh scripts ────────────
    info "\n${BOLD}Step 4: Call dependency service updaters${CL}"

    if [[ -z "${depends_on}" ]]; then
        info "  No dependency services to call"
    else
        # cd to the module directory so service scripts can find module files
        # (e.g., update-os.sh looks for ./<vmname>.nix in the cwd)
        if [[ -n "${module_dir:-}" ]]; then
            cd "${module_dir}"
        fi

        for dep in ${depends_on}; do
            local provider_module="${dep%%:*}"
            local service_name="${dep##*:}"
            local provider_dir

            provider_dir=$(get_module_dir "${provider_module}")
            ensure_scripts_executable "${provider_dir}"
            local svc_script="${provider_dir}/services/${service_name}/update-service.sh"

            info "  Calling ${BL}${dep}${CL} update-service.sh for module '${module}'..."
            "${svc_script}" "${module}" || die "Service updater failed: ${dep}"
            info "  ${GN}✓${CL} ${dep} update-service completed"
        done
    fi

    # ── Step 5: Call the module's own update.sh ──────────────────────
    info "\n${BOLD}Step 5: Run module update.sh${CL}"

    if [[ -n "${module_dir:-}" ]]; then
        if [[ -x "${module_dir}/update.sh" ]]; then
            info "  Running ${module_dir}/update.sh..."
            cd "${module_dir}"
            ./update.sh "${module}" || die "Module update.sh failed"
            info "  ${GN}✓${CL} Module update.sh completed"
        else
            info "  No executable update.sh found — skipping"
        fi
    else
        warn "Cannot find module directory for '${module}' (missing .location in config) — skipping update.sh"
    fi

    # ── Done ─────────────────────────────────────────────────────────
    echo ""
    info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${GN}${BOLD}║  Module '${module}' updated successfully       ${CL}"
    info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
}

main "$@"
