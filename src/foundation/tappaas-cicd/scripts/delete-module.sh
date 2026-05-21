#!/usr/bin/env bash
#
# TAPPaaS Module Deleter with Dependency Management
#
# Deletes a TAPPaaS module by running the module's own delete.sh,
# calling each dependency's delete-service.sh script in reverse order,
# and then removing the module's configuration files.
#
# Usage: delete-module.sh <module-name> [--archive|--remove] [--vmid <id>] [--yes] [--force]
#
# Arguments:
#   module-name   Name of the module to delete (must have a
#                 <module-name>.json in /home/tappaas/config/)
#
# Lifecycle mode (issue #215):
#   --archive      (DEFAULT, safe) Remove the VM from the cluster but KEEP the
#                  module config (marked "status": "archived") and KEEP its PBS
#                  backup entry — the module is restorable and inspect-cluster.sh
#                  shows it as [archived] rather than NOT RUNNING.
#   --remove       (destructive) Remove the VM, remove its VMID from the PBS
#                  backup job, AND delete the module config. Requires
#                  confirmation (unless --yes/--force). Intended for test VMs and
#                  decommissioned modules. NOTE: --force implies --remove.
#
# Options:
#   --vmid <id>    Target a specific VM instance by VMID (required when more
#                  than one VM in the cluster shares the module's name). When
#                  the VMID differs from the module config, ONLY that VM is
#                  destroyed and the module config is left intact.
#   --yes, -y      Skip the destroy confirmation prompt (for automation)
#   --force        Delete even if other modules depend on this module's
#                  services; also implies --yes AND --remove
#   -h, --help     Show this help message
#
# Examples:
#   delete-module.sh vaultwarden                 # archive (VM gone, config kept)
#   delete-module.sh litellm --remove            # full removal (prompts)
#   delete-module.sh test-vmdrift --force        # full removal, no prompt
#   delete-module.sh openwebui --vmid 313        # destroy the stray instance only
#
# The script performs these steps:
#   1. Validates the module JSON config exists
#   2. Resolves and CONFIRMS the target VM (detects duplicate names, requires
#      --vmid to disambiguate; prompts before destroying — issue #195)
#   3. Checks that no other modules depend on this module's services
#   4. Calls the module's own delete.sh (if present)
#   5. Iterates dependsOn in reverse and calls each provider's delete-service.sh
#      (--archive keeps the backup:vm registration; --remove drops it)
#   6. Archive: marks config "status":"archived". Remove: deletes the config.
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly CONFIG_DIR="/home/tappaas/config"

# Options (set by main; globals so helper functions can read them)
OPT_FORCE=false
OPT_YES=false
OPT_VMID=""
OPT_MODE="archive"        # archive (default, safe) | remove (destructive)
OPT_MODE_EXPLICIT=false   # true once --archive/--remove is seen

# shellcheck source=common-install-routines.sh disable=SC1091
. /home/tappaas/bin/common-install-routines.sh

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <module-name> [--archive|--remove] [--vmid <id>] [--yes] [--force]

Delete a TAPPaaS module with dependency-aware service teardown.

Arguments:
    module-name    Name of the module (must have config in ${CONFIG_DIR}/)

Lifecycle mode (default: --archive):
    --archive      Remove the VM but KEEP the config (status=archived) and its
                   PBS backup entry — restorable; shown as [archived] by
                   inspect-cluster.sh.
    --remove       Remove the VM, drop its PBS backup entry, and DELETE the
                   config. Requires confirmation (unless --yes/--force).

Options:
    --vmid <id>    Target a specific VM instance by VMID (required when several
                   VMs share the module name). If it differs from the config
                   VMID, only that VM is destroyed and the config is kept.
    --yes, -y      Skip the destroy confirmation prompt (for automation)
    --force        Delete despite dependent modules; also implies --yes AND --remove
    -h, --help     Show this help message

Examples:
    ${SCRIPT_NAME} vaultwarden               # archive (default)
    ${SCRIPT_NAME} litellm --remove          # full removal (prompts)
    ${SCRIPT_NAME} test-vmdrift --force      # full removal, no prompt
    ${SCRIPT_NAME} openwebui --vmid 313
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

readonly SSH_OPTS_DM="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# List every qemu VM in the cluster whose name matches $1.
# Emits one line per match: "<vmid> <node> <status>". Empty if none/unreachable.
find_vms_by_name() {
    local name="$1" node row
    # shellcheck disable=SC2086  # word-splitting of hostnames is intended
    for node in $(get_all_node_hostnames); do
        row=$(ssh ${SSH_OPTS_DM} "root@${node}.mgmt.internal" \
            "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
            | jq -r --arg n "${name}" \
                '.[] | select(.type=="qemu" and .name==$n) | "\(.vmid) \(.node) \(.status)"' 2>/dev/null) || true
        if [[ -n "${row}" ]]; then echo "${row}"; return 0; fi
    done
    return 0
}

# Prompt the operator before an irreversible VM destroy (skipped by --yes/--force).
# Refuses to proceed in a non-interactive shell unless --yes/--force is given.
confirm_destroy() {
    local name="$1" vmid="$2" node="$3"
    if [[ "${OPT_YES}" == true || "${OPT_FORCE}" == true ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Refusing to destroy VM ${vmid} (${name}) without confirmation in a non-interactive shell. Pass --yes (or --force)."
    fi
    warn "About to PERMANENTLY destroy VM ${BL}${name}${CL} (VMID: ${RD}${vmid}${CL}) on node ${BL}${node}${CL}."
    if [[ "${OPT_MODE}" == "remove" ]]; then
        warn "  Mode ${RD}--remove${CL}: the module config AND its PBS backup entry will ALSO be deleted (irreversible)."
    else
        warn "  Mode ${GN}--archive${CL}: config and PBS backups are kept — the module stays restorable."
    fi
    local reply
    read -r -p "  Confirm destroy of VM ${vmid}? [y/N] " reply
    case "${reply}" in
        y|Y|yes|Yes|YES) return 0 ;;
        *) die "Aborted by operator (no destroy performed)" ;;
    esac
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    local module=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -h|--help) usage; exit 0 ;;
            --force) OPT_FORCE=true; OPT_YES=true ;;
            -y|--yes) OPT_YES=true ;;
            --archive) OPT_MODE="archive"; OPT_MODE_EXPLICIT=true ;;
            --remove)  OPT_MODE="remove";  OPT_MODE_EXPLICIT=true ;;
            --vmid)
                [[ -n "${2:-}" ]] || die "--vmid requires a value"
                OPT_VMID="${2}"; shift ;;
            -*) die "Unknown option: ${1}" ;;
            *)
                if [[ -n "${module}" ]]; then
                    die "Unexpected argument: ${1} (module already set to '${module}')"
                fi
                module="${1}"
                ;;
        esac
        shift
    done

    # Validate module name argument
    if [[ -z "${module}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    if [[ -n "${OPT_VMID}" && ! "${OPT_VMID}" =~ ^[0-9]+$ ]]; then
        die "--vmid must be numeric (got '${OPT_VMID}')"
    fi

    # --force implies full removal (preserves the historical --force behaviour
    # and keeps test-cleanup callers working) unless --archive was explicit.
    if [[ "${OPT_FORCE}" == true && "${OPT_MODE_EXPLICIT}" == false ]]; then
        OPT_MODE="remove"
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

    # ── Step 2: Resolve & confirm target VM (issue #195) ─────────────
    info "\n${BOLD}Step 2: Resolve and confirm target VM${CL}"

    local config_vmid vmname target_vmid="" target_node="" vm_only=false
    config_vmid=$(jq -r '.vmid // empty' "${module_json}" 2>/dev/null)
    vmname=$(jq -r '.vmname // empty' "${module_json}" 2>/dev/null)
    [[ -z "${vmname}" ]] && vmname="${module}"

    if [[ -z "${config_vmid}" && -z "${OPT_VMID}" ]]; then
        info "  Module declares no VMID — no VM to destroy (config-only delete)"
    else
        # Discover every cluster VM sharing this module's name.
        local matches match_count
        matches=$(find_vms_by_name "${vmname}")
        match_count=$(grep -c . <<< "${matches}" 2>/dev/null || echo 0)
        [[ -z "${matches}" ]] && match_count=0

        if [[ -n "${matches}" ]]; then
            info "  VM(s) named '${vmname}' in cluster:"
            while read -r mv mn ms; do
                [[ -z "${mv}" ]] && continue
                info "    • VMID ${BL}${mv}${CL} on ${mn} (${ms})"
            done <<< "${matches}"
        fi

        if [[ -n "${OPT_VMID}" ]]; then
            target_vmid="${OPT_VMID}"
        elif [[ "${match_count}" -gt 1 ]]; then
            die "Multiple VMs named '${vmname}' exist — refusing to guess. Re-run with --vmid <id> to choose the instance to destroy."
        else
            target_vmid="${config_vmid}"
        fi

        # Resolve the node for the target VMID from the cluster listing.
        target_node=$(awk -v id="${target_vmid}" '$1==id {print $2; exit}' <<< "${matches}")
        if [[ -z "${target_node}" ]]; then
            warn "  VMID ${target_vmid} not found in the cluster (already gone?) — will still attempt cleanup"
            target_node=$(jq -r '.node // empty' "${module_json}" 2>/dev/null)
            [[ -z "${target_node}" || "${target_node}" == "null" ]] && target_node="$(get_node_hostname 0)"
        fi

        # If the operator targeted a VMID other than the module's own, destroy
        # ONLY that VM and leave the module config (it describes a different VM).
        if [[ -n "${config_vmid}" && "${target_vmid}" != "${config_vmid}" ]]; then
            vm_only=true
            warn "  Target VMID ${target_vmid} differs from config VMID ${config_vmid}:"
            warn "  destroying ONLY VM ${target_vmid}; module config '${module}' will be kept."
        fi

        confirm_destroy "${vmname}" "${target_vmid}" "${target_node}"

        # Hand the resolved target to the cluster:vm delete-service.
        export TAPPAAS_VMID_OVERRIDE="${target_vmid}"
        export TAPPAAS_NODE_OVERRIDE="${target_node}"

        # VM-only path: destroy the targeted VM and stop (no teardown, keep config).
        if [[ "${vm_only}" == true ]]; then
            local cluster_dir svc
            if cluster_dir=$(get_module_dir "cluster"); then
                svc="${cluster_dir}/services/vm/delete-service.sh"
                ensure_scripts_executable "${cluster_dir}"
                if [[ -x "${svc}" ]]; then
                    info "\n${BOLD}Destroying VM ${target_vmid} only (config preserved)${CL}"
                    "${svc}" "${module}" || die "VM destroy failed for VMID ${target_vmid}"
                else
                    die "cluster:vm delete-service.sh not found at ${svc}"
                fi
            else
                die "Cannot locate cluster module to destroy VM ${target_vmid}"
            fi
            info "${GN}${BOLD}VM ${target_vmid} destroyed; module '${module}' config left intact.${CL}"
            return 0
        fi
    fi

    # ── Step 3: Check reverse dependencies ───────────────────────────
    info "\n${BOLD}Step 3: Check reverse dependencies${CL}"

    local provides
    provides=$(jq -r '.provides // [] | .[]' "${module_json}" 2>/dev/null)

    if [[ -z "${provides}" ]]; then
        info "  Module provides no services — no reverse dependency check needed"
    else
        local rev_dep_count=0
        check_reverse_dependencies "${module}" || rev_dep_count=$?

        if [[ "${rev_dep_count}" -gt 0 ]]; then
            if [[ "${OPT_FORCE}" == "true" ]]; then
                warn "Proceeding with deletion despite ${rev_dep_count} dependent module(s) (--force)"
            else
                die "${rev_dep_count} module(s) depend on services from '${module}' — use --force to override"
            fi
        else
            info "  ${GN}✓${CL} No other modules depend on this module's services"
        fi
    fi

    # ── Step 4: Run the module's own delete.sh ───────────────────────
    info "\n${BOLD}Step 4: Run module delete.sh${CL}"

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

    # ── Step 5: Call dependency delete-service.sh scripts (reverse) ──
    info "\n${BOLD}Step 5: Call dependency service deleters (reverse order)${CL}"

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

            # Archive keeps the PBS backup so the module stays restorable —
            # skip the backup:vm deregistration (issue #215).
            if [[ "${OPT_MODE}" == "archive" && "${dep}" == "backup:vm" ]]; then
                info "  ${dep}: keeping PBS backup entry (--archive)"
                continue
            fi

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

    # ── Step 6: Archive (keep config) or Remove (delete config) ──────
    local config_orig="${CONFIG_DIR}/${module}.json.orig"

    if [[ "${OPT_MODE}" == "archive" ]]; then
        info "\n${BOLD}Step 6: Archive module configuration${CL}"
        local tmp
        tmp=$(mktemp)
        if jq '.status = "archived"' "${module_json}" > "${tmp}" && mv "${tmp}" "${module_json}"; then
            info "  ${GN}✓${CL} Marked ${module_json} as ${BL}status=archived${CL} (config + PBS backup kept)"
        else
            rm -f "${tmp}"
            warn "  Could not set status=archived on ${module_json} (config left as-is)"
        fi

        echo ""
        info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
        info "${GN}${BOLD}║  Module '${module}' archived (VM removed, restorable)${CL}"
        info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
        return 0
    fi

    info "\n${BOLD}Step 6: Remove module configuration${CL}"

    if [[ -f "${module_json}" ]]; then
        rm -f "${module_json}"
        info "  Removed ${module_json}"
    fi

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
